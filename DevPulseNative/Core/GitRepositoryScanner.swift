import Foundation

// MARK: - Scan configuration

struct ScanConfig: Codable, Sendable {
    var enabledBuiltInPaths: Set<String>
    var customPaths: [String]
    let maxDepth: Int
    let changedPreviewLimit: Int
    /// Max concurrent git commands (batch size).
    let maxConcurrentGitOps: Int
    /// Per-git-command timeout in seconds.
    let gitCommandTimeout: TimeInterval
    /// Overall scan timeout in seconds.
    let scanTimeout: TimeInterval
    /// Repos flagged slow are skipped for this many seconds.
    let slowReposkipSeconds: TimeInterval
    /// Above this repo count, only scan recently-active repos.
    let activeRepoThreshold: Int

    static let `default` = ScanConfig(
        enabledBuiltInPaths: [],
        customPaths: [],
        maxDepth: 4,
        changedPreviewLimit: 5,
        maxConcurrentGitOps: 6,
        gitCommandTimeout: 5.0,
        scanTimeout: 60.0,
        slowReposkipSeconds: 600.0,
        activeRepoThreshold: 30
    )
}

// MARK: - Slow repo tracker (actor for concurrency safety)

private actor SlowRepoTracker {
    private var repos: [String: Date] = [:]
    private let defaultSkipSeconds: TimeInterval

    init(skipSeconds: TimeInterval = 600) {
        self.defaultSkipSeconds = skipSeconds
    }

    func filterActive(_ paths: [String]) -> (active: [String], skipped: [String]) {
        let now = Date()
        // Purge expired
        repos = repos.filter { $0.value > now }

        var active: [String] = []
        var skipped: [String] = []
        for path in paths {
            if let skipUntil = repos[path], skipUntil > now {
                skipped.append(path)
            } else {
                active.append(path)
            }
        }
        return (active, skipped)
    }

    func markSlow(_ path: String, skipSeconds: TimeInterval) {
        repos[path] = Date().addingTimeInterval(skipSeconds)
    }
}

private actor RepositoryDiscoveryCache {
    struct Entry {
        let paths: [String]
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]

    func cachedPaths(for key: String, now: Date = Date()) -> [String]? {
        if let entry = entries[key], entry.expiresAt > now {
            return entry.paths
        }

        entries.removeValue(forKey: key)
        return nil
    }

    func store(paths: [String], for key: String, ttl: TimeInterval, now: Date = Date()) {
        entries[key] = Entry(
            paths: paths,
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    func removeValue(for key: String) {
        entries.removeValue(forKey: key)
    }
}

private struct SnapshotReadResult: Sendable {
    let index: Int
    let snapshot: RepositorySnapshot
    let elapsed: TimeInterval
}

// MARK: - Scanner

enum GitRepositoryScanner {
    private static let slowTracker = SlowRepoTracker()
    private static let discoveryCache = RepositoryDiscoveryCache()
    private static let discoveryCacheTTL: TimeInterval = 10 * 60

    // MARK: - Public API

    /// Run a full scan with all low-power safeguards.
    /// Returns the scan result and an array of warning strings.
    static func scan(config: ScanConfig = .default,
                     scanRoots: [String]? = nil,
                     knownRepositoryPaths: [String]? = nil,
                     forceRepositoryDiscovery: Bool = false,
                     previousSnapshot: AppGroupData? = nil) async -> (data: AppGroupData, warnings: [String], discoveredRepositoryPaths: [String]) {
        let startTime = Date()
        var warnings: [String] = []
        let previous = previousSnapshot ?? (try? AppGroupStore.read().get())

        // Phase 1: discover all git repositories
        let discoveredPaths = await discoverRepositories(
            config: config,
            scanRoots: scanRoots,
            knownRepositoryPaths: knownRepositoryPaths,
            forceRefresh: forceRepositoryDiscovery,
            warnings: &warnings
        )
        if Task.isCancelled {
            return partialResult(
                discoveredPaths: discoveredPaths,
                snapshots: [],
                previousSnapshot: previous,
                warnings: &warnings
            )
        }
        var pathsToScan = discoveredPaths
        var retainedPaths: [String] = []

        // Throttle: if >30 repos, only scan changed/active ones
        if pathsToScan.count > config.activeRepoThreshold {
            if let previous {
                let changedPaths = Set(previous.repositories
                    .filter { $0.status == .changed || $0.status == .error }
                    .map { $0.path })
                let active = pathsToScan.filter { changedPaths.contains($0) }
                if !active.isEmpty {
                    warnings.append("Throttling: scanning \(active.count) active repos out of \(pathsToScan.count) total (threshold \(config.activeRepoThreshold))")
                    retainedPaths = pathsToScan.filter { !active.contains($0) }
                    pathsToScan = active
                }
            } else {
                warnings.append("Shared snapshot unavailable for throttling; scanning all discovered repositories.")
            }
        }

        // Phase 2: read git status in batches
        let snapshots = await readSnapshotsBatched(
            paths: pathsToScan,
            config: config,
            warnings: &warnings,
            overallDeadline: startTime.addingTimeInterval(config.scanTimeout),
            previousSnapshots: previous?.repositories ?? []
        )
        if Task.isCancelled {
            warnings.append("Scan cancelled; returning the completed portion with prior snapshots retained.")
            return partialResult(
                discoveredPaths: discoveredPaths,
                snapshots: snapshots,
                previousSnapshot: previous,
                warnings: &warnings
            )
        }

        let retainedSnapshots = retainedPaths.compactMap { path in
            previous?.repositories.first(where: { $0.path == path })
        }
        let completeSnapshots = mergeSnapshots(
            snapshots + retainedSnapshots,
            discoveredPaths: discoveredPaths,
            previousSnapshot: previous
        )

        // Phase 3: sort
        let sorted = RepositorySorter.sort(completeSnapshots)

        // Phase 4: build summary
        let changedCount = sorted.filter { $0.status == .changed }.count
        let errorCount = sorted.filter { $0.status == .error }.count
        let totalChangedFiles = sorted.reduce(0) { $0 + $1.changedFileCount }

        let summary = ScanSummary(
            totalRepositories: discoveredPaths.count,
            changedRepositories: changedCount,
            totalChangedFiles: totalChangedFiles,
            errorRepositories: errorCount
        )

        let result = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: DateFormatting.nowISO(),
            writtenAt: nil,
            scanSummary: summary,
            repositories: sorted
        )

        return (result, warnings, discoveredPaths)
    }

    private static func partialResult(
        discoveredPaths: [String],
        snapshots: [RepositorySnapshot],
        previousSnapshot: AppGroupData?,
        warnings: inout [String]
    ) -> (data: AppGroupData, warnings: [String], discoveredRepositoryPaths: [String]) {
        let merged = mergeSnapshots(
            snapshots,
            discoveredPaths: discoveredPaths,
            previousSnapshot: previousSnapshot
        )
        let sorted = RepositorySorter.sort(merged)
        let summary = ScanSummary(
            totalRepositories: discoveredPaths.count,
            changedRepositories: sorted.filter { $0.status == .changed }.count,
            totalChangedFiles: sorted.reduce(0) { $0 + $1.changedFileCount },
            errorRepositories: sorted.filter { $0.status == .error }.count
        )
        return (
            AppGroupData(
                schemaVersion: RepositorySnapshotSchema.version,
                generatedAt: DateFormatting.nowISO(),
                writtenAt: nil,
                scanSummary: summary,
                repositories: sorted
            ),
            warnings,
            discoveredPaths
        )
    }

    // MARK: - Repository discovery

    private static func discoverRepositories(config: ScanConfig,
                                             scanRoots: [String]?,
                                             knownRepositoryPaths: [String]?,
                                             forceRefresh: Bool,
                                             warnings: inout [String]) async -> [String] {
        var discovered = Set<String>()
        let allPaths = scanRoots ?? Array(config.enabledBuiltInPaths) + config.customPaths
        let normalizedRoots = allPaths.map(ScanLocationProvider.expandTilde)
        let cacheKey = discoveryCacheKey(for: normalizedRoots)

        if !forceRefresh,
           let knownRepositoryPaths,
           let reusedPaths = reusableKnownRepositoryPaths(
               knownRepositoryPaths,
               limitedTo: normalizedRoots
           ) {
            return reusedPaths
        }

        if forceRefresh {
            await discoveryCache.removeValue(for: cacheKey)
        } else if let cached = await discoveryCache.cachedPaths(for: cacheKey) {
            return cached
        }

        for root in normalizedRoots {
            if Task.isCancelled { break }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
                  isDir.boolValue else {
                warnings.append("Scan root unavailable: \(root)")
                continue
            }

            walkDirectory(root, config: config, discovered: &discovered, warnings: &warnings)
        }

        if discovered.isEmpty {
            if allPaths.isEmpty && scanRoots == nil {
                warnings.append("No scan roots configured. Add a directory in Settings.")
            } else if !allPaths.isEmpty {
                warnings.append("No Git repositories discovered in the configured scan roots.")
            }
        }

        let sorted = Array(discovered).sorted()
        await discoveryCache.store(paths: sorted, for: cacheKey, ttl: discoveryCacheTTL)
        return sorted
    }

    private static func reusableKnownRepositoryPaths(
        _ knownRepositoryPaths: [String],
        limitedTo scanRoots: [String]
    ) -> [String]? {
        let normalizedRoots = scanRoots.map(ScanLocationProvider.expandTilde)
        let filtered = Set(
            knownRepositoryPaths
                .map(ScanLocationProvider.expandTilde)
                .filter { path in
                    guard FileManager.default.fileExists(atPath: path) else {
                        return false
                    }

                    if normalizedRoots.isEmpty {
                        return true
                    }

                    return normalizedRoots.contains { root in
                        path == root || path.hasPrefix(root + "/")
                    }
                }
        )

        guard !filtered.isEmpty else {
            return nil
        }

        return Array(filtered).sorted()
    }

    private static func walkDirectory(_ directory: String,
                                      config: ScanConfig,
                                      depth: Int = 0,
                                      discovered: inout Set<String>,
                                      warnings: inout [String]) {
        guard !Task.isCancelled else { return }
        guard depth <= config.maxDepth else { return }

        if isGitRepository(directory) {
            discovered.insert(directory)
            return
        }

        let dirName = (directory as NSString).lastPathComponent
        if ExcludedDirectoryRules.isExcluded(dirName: dirName) {
            return
        }

        let directoryURL = URL(fileURLWithPath: directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        for entryURL in entries {
            if Task.isCancelled { return }
            let fullPath = entryURL.path
            let entryName = entryURL.lastPathComponent

            guard !ExcludedDirectoryRules.isExcluded(dirName: entryName) else { continue }

            let isDirectory = (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }

            walkDirectory(fullPath,
                          config: config,
                          depth: depth + 1,
                          discovered: &discovered,
                          warnings: &warnings)
        }
    }

    // MARK: - Git repository detection

    static func isGitRepository(_ directory: String) -> Bool {
        let gitPath = (directory as NSString).appendingPathComponent(".git")

        // Discovery is intentionally filesystem-only. A .git directory or
        // worktree file is sufficient to identify a repository; invoking
        // A Git discovery command for every ordinary directory turns a
        // bounded walk into one process per directory.
        return FileManager.default.fileExists(atPath: gitPath)
    }

    // MARK: - Batched snapshot reading

    /// Read git status in batches to limit concurrent git processes.
    private static func readSnapshotsBatched(paths: [String],
                                             config: ScanConfig,
                                             warnings: inout [String],
                                             overallDeadline: Date,
                                             previousSnapshots: [RepositorySnapshot]) async -> [RepositorySnapshot] {
        guard !paths.isEmpty else { return [] }

        let previousByPath = Dictionary(uniqueKeysWithValues: previousSnapshots.map { ($0.path, $0) })
        var resultsByIndex: [Int: SnapshotReadResult] = [:]

        // Filter out slow repos
        let (activePaths, skippedPaths) = await filterSlowRepos(paths)
        for skipped in skippedPaths {
            let index = paths.firstIndex(of: skipped) ?? 0
            let fallback = previousByPath[skipped] ?? placeholderSnapshot(
                for: skipped,
                errorMessage: "扫描已跳过"
            )
            resultsByIndex[index] = SnapshotReadResult(
                index: index,
                snapshot: fallback,
                elapsed: 0
            )
            warnings.append(
                previousByPath[skipped] == nil
                    ? "扫描已跳过：\(skipped)"
                    : "扫描已跳过：保留 \((skipped as NSString).lastPathComponent) 的上次结果"
            )
        }

        // Keep at most maxConcurrentGitOps read tasks in flight. Each task
        // invokes one Git command at a time, so this is also the process cap.
        let concurrency = max(1, config.maxConcurrentGitOps)
        var nextIndex = 0
        var timedOut = false
        var cancelled = false

        await withTaskGroup(of: SnapshotReadResult?.self) { group in
            if Task.isCancelled {
                cancelled = true
                group.cancelAll()
                return
            }

            func addNextTask() {
                guard nextIndex < activePaths.count else { return }
                let index = nextIndex
                let path = activePaths[index]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let remaining = overallDeadline.timeIntervalSinceNow
                    guard remaining > 0 else { return nil }
                    let startedAt = Date()
                    guard let snapshot = readSingleSnapshot(
                        repoPath: path,
                        config: config,
                        overallDeadline: overallDeadline
                    ) else {
                        return nil
                    }
                    return SnapshotReadResult(
                        index: paths.firstIndex(of: path) ?? index,
                        snapshot: snapshot,
                        elapsed: Date().timeIntervalSince(startedAt)
                    )
                }
            }

            for _ in 0..<min(concurrency, activePaths.count) {
                addNextTask()
            }

            while let result = await group.next() {
                if let result {
                    resultsByIndex[result.index] = result
                }

                if Task.isCancelled {
                    cancelled = true
                    group.cancelAll()
                    break
                }

                if Date() >= overallDeadline {
                    timedOut = true
                    group.cancelAll()
                    break
                }

                addNextTask()
            }
        }

        if !cancelled && !timedOut && Date() >= overallDeadline {
            timedOut = true
        }

        if timedOut {
            warnings.append("Scan timeout reached; preserving completed results and prior snapshots for unfinished repositories.")
        } else if cancelled {
            warnings.append("Scan cancelled; preserving completed results and prior snapshots.")
        }

        var results: [RepositorySnapshot] = []
        results.reserveCapacity(paths.count)
        for (index, path) in paths.enumerated() {
            if let result = resultsByIndex[index] {
                if result.elapsed > 3.0 {
                    await trackSlowRepo(path, skipSeconds: config.slowReposkipSeconds)
                    warnings.append("Slow repo: \(result.snapshot.name) (\(String(format: "%.1f", result.elapsed))s)")
                }
                results.append(result.snapshot)
                continue
            }

            if let previous = previousByPath[path] {
                results.append(previous)
                continue
            }

            let message = timedOut || Date() >= overallDeadline
                ? "扫描超时"
                : (cancelled ? "扫描已取消" : "读取失败")
            results.append(placeholderSnapshot(for: path, errorMessage: message))
        }

        // A cancellation can happen before a task group is entered. Keep the
        // result shape complete so callers can still explain what was kept.
        if results.count < paths.count {
            warnings.append("扫描结果不完整：已为未完成仓库保留可解释占位结果。")
        }
        return results
    }

    // MARK: - Slow repo tracking

    private static func filterSlowRepos(_ paths: [String]) async -> (active: [String], skipped: [String]) {
        await slowTracker.filterActive(paths)
    }

    private static func trackSlowRepo(_ path: String, skipSeconds: TimeInterval) async {
        await slowTracker.markSlow(path, skipSeconds: skipSeconds)
    }

    // MARK: - Single snapshot

    private static func readSingleSnapshot(repoPath: String,
                                           config: ScanConfig,
                                           overallDeadline: Date? = nil) -> RepositorySnapshot? {
        let name = (repoPath as NSString).lastPathComponent
        let id = stableHash(repoPath)
        let cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
        func commandTimeout() -> TimeInterval {
            guard let overallDeadline else { return config.gitCommandTimeout }
            return min(config.gitCommandTimeout, max(0, overallDeadline.timeIntervalSinceNow))
        }

        guard !Task.isCancelled else { return nil }

        guard let statusOutput = ProcessRunner.run(
            arguments: ["status", "--short", "--branch"],
            workingDirectory: repoPath,
            timeout: commandTimeout(),
            isCancelled: cancellationCheck
        ) else {
            guard !Task.isCancelled else { return nil }
            return RepositorySnapshot(
                id: id,
                name: name,
                path: repoPath,
                branch: "unknown",
                status: .error,
                modifiedFileCount: 0,
                addedFileCount: 0,
                deletedFileCount: 0,
                untrackedFileCount: 0,
                stagedFileCount: 0,
                unstagedFileCount: 0,
                conflictedFileCount: 0,
                aheadCount: 0,
                changedFileCount: 0,
                changedFilesPreview: [],
                risk: .low,
                lastScannedAt: DateFormatting.nowISO(),
                lastChangedAt: nil,
                errorMessage: "读取失败",
                isPinned: false
            )
        }

        let branchMetadata = GitStatusParser.parseBranchMetadata(statusOutput)
        let entries = GitStatusParser.parseStatusEntries(statusOutput)
        let summary = GitStatusParser.summarize(entries)
        let changedFiles = entries.map(\.path)
        let changedCount = summary.total

        let status: RepositoryStatus = changedCount > 0 ? .changed : .clean
        let risk = RiskHintEngine.assess(changedFiles: changedFiles)

        let lastCommitAt = ProcessRunner.run(
            arguments: ["log", "-1", "--pretty=%cI"],
            workingDirectory: repoPath,
            timeout: commandTimeout(),
            isCancelled: cancellationCheck
        )

        guard !Task.isCancelled else { return nil }

        // Preview capped at 5
        let preview = Array(changedFiles.prefix(config.changedPreviewLimit))

        return RepositorySnapshot(
            id: id,
            name: name,
            path: repoPath,
            branch: branchMetadata.branch,
            status: status,
            modifiedFileCount: summary.modified,
            addedFileCount: summary.added,
            deletedFileCount: summary.deleted,
            untrackedFileCount: summary.untracked,
            stagedFileCount: summary.staged,
            unstagedFileCount: summary.unstaged,
            conflictedFileCount: summary.conflicted,
            aheadCount: branchMetadata.aheadCount,
            changedFileCount: changedCount,
            changedFilesPreview: preview,
            risk: risk.level,
            lastScannedAt: DateFormatting.nowISO(),
            lastChangedAt: lastCommitAt,
            errorMessage: nil,
            isPinned: false
        )
    }

    private static func placeholderSnapshot(for path: String, errorMessage: String) -> RepositorySnapshot {
        RepositorySnapshot(
            id: stableHash(path),
            name: (path as NSString).lastPathComponent,
            path: path,
            branch: "unknown",
            status: .error,
            modifiedFileCount: 0,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 0,
            unstagedFileCount: 0,
            conflictedFileCount: 0,
            aheadCount: 0,
            changedFileCount: 0,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: DateFormatting.nowISO(),
            lastChangedAt: nil,
            errorMessage: errorMessage,
            isPinned: false
        )
    }

    private static func mergeSnapshots(
        _ snapshots: [RepositorySnapshot],
        discoveredPaths: [String],
        previousSnapshot: AppGroupData?
    ) -> [RepositorySnapshot] {
        var byPath = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.path, $0) })
        let previousByPath = Dictionary(uniqueKeysWithValues: (previousSnapshot?.repositories ?? []).map { ($0.path, $0) })

        for path in discoveredPaths where byPath[path] == nil {
            byPath[path] = previousByPath[path] ?? placeholderSnapshot(
                for: path,
                errorMessage: "本轮未完成扫描"
            )
        }

        return discoveredPaths.compactMap { byPath[$0] }
    }

    // MARK: - Helpers

    private static func stableHash(_ input: String) -> String {
        var hasher = Hasher()
        hasher.combine(input)
        let hashValue = hasher.finalize()
        return String(format: "%08x", hashValue)
    }

    private static func discoveryCacheKey(for roots: [String]) -> String {
        roots.sorted().joined(separator: "\n")
    }
}

import Foundation

// MARK: - Scan configuration

struct ScanConfig: Codable {
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
                     forceRepositoryDiscovery: Bool = false) async -> (data: AppGroupData, warnings: [String]) {
        let startTime = Date()
        var warnings: [String] = []

        // Phase 1: discover all git repositories
        let discoveredPaths = await discoverRepositories(
            config: config,
            scanRoots: scanRoots,
            forceRefresh: forceRepositoryDiscovery,
            warnings: &warnings
        )
        var pathsToScan = discoveredPaths

        // Throttle: if >30 repos, only scan changed/active ones
        if pathsToScan.count > config.activeRepoThreshold {
            switch AppGroupStore.read() {
            case .success(let previous):
                let changedPaths = Set(previous.repositories
                    .filter { $0.status == .changed || $0.status == .error }
                    .map { $0.path })
                let active = pathsToScan.filter { changedPaths.contains($0) }
                if !active.isEmpty {
                    warnings.append("Throttling: scanning \(active.count) active repos out of \(pathsToScan.count) total (threshold \(config.activeRepoThreshold))")
                    pathsToScan = active
                }
            case .failure(let error):
                warnings.append("Shared snapshot unavailable for throttling: \(error.localizedDescription)")
            }
        }

        // Phase 2: read git status in batches
        let snapshots = await readSnapshotsBatched(
            paths: pathsToScan,
            config: config,
            warnings: &warnings,
            overallDeadline: startTime.addingTimeInterval(config.scanTimeout)
        )

        // Phase 3: sort
        let sorted = RepositorySorter.sort(snapshots)

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

        return (result, warnings)
    }

    // MARK: - Repository discovery

    private static func discoverRepositories(config: ScanConfig,
                                             scanRoots: [String]?,
                                             forceRefresh: Bool,
                                             warnings: inout [String]) async -> [String] {
        var discovered = Set<String>()
        let allPaths = scanRoots ?? Array(config.enabledBuiltInPaths) + config.customPaths
        let normalizedRoots = allPaths.map(ScanLocationProvider.expandTilde)
        let cacheKey = discoveryCacheKey(for: normalizedRoots)

        if forceRefresh {
            await discoveryCache.removeValue(for: cacheKey)
        } else if let cached = await discoveryCache.cachedPaths(for: cacheKey) {
            return cached
        }

        for root in normalizedRoots {
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

    private static func walkDirectory(_ directory: String,
                                      config: ScanConfig,
                                      depth: Int = 0,
                                      discovered: inout Set<String>,
                                      warnings: inout [String]) {
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

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) {
            return true
        }

        if let topLevel = ProcessRunner.run(
            arguments: ["rev-parse", "--show-toplevel"],
            workingDirectory: directory
        ) {
            let resolved = ScanLocationProvider.expandTilde(
                (topLevel as NSString).resolvingSymlinksInPath
            )
            let dirResolved = (directory as NSString).resolvingSymlinksInPath
            return resolved == dirResolved
        }

        return false
    }

    // MARK: - Batched snapshot reading

    /// Read git status in batches to limit concurrent git processes.
    private static func readSnapshotsBatched(paths: [String],
                                             config: ScanConfig,
                                             warnings: inout [String],
                                             overallDeadline: Date) async -> [RepositorySnapshot] {
        var results: [RepositorySnapshot] = []
        results.reserveCapacity(paths.count)

        // Filter out slow repos
        let (activePaths, skippedPaths) = await filterSlowRepos(paths)
        let skippedSlow = skippedPaths
        for skipped in skippedSlow {
            let name = (skipped as NSString).lastPathComponent
            results.append(RepositorySnapshot(
                id: stableHash(skipped),
                name: name,
                path: skipped,
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
                errorMessage: "扫描已跳过",
                isPinned: false
            ))
        }

        // Process in batches
        let batchSize = max(1, config.maxConcurrentGitOps)
        for batchStart in stride(from: 0, to: activePaths.count, by: batchSize) {
            // Check overall timeout
            if Date() > overallDeadline {
                warnings.append("Scan timeout reached; \(activePaths.count - batchStart) repos skipped")
                for i in batchStart..<activePaths.count {
                    let path = activePaths[i]
                    let name = (path as NSString).lastPathComponent
                    results.append(RepositorySnapshot(
                        id: stableHash(path),
                        name: name,
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
                        errorMessage: "扫描超时",
                        isPinned: false
                    ))
                }
                break
            }

            let batchEnd = min(batchStart + batchSize, activePaths.count)
            let batch = Array(activePaths[batchStart..<batchEnd])

            // Scan batch concurrently via serial iteration (Process is synchronous)
            // Each git command has its own timeout
            for path in batch {
                let start = Date()
                let snapshot = readSingleSnapshot(repoPath: path, config: config, warnings: &warnings)
                let elapsed = Date().timeIntervalSince(start)

                // Track slow repos (>3s)
                if elapsed > 3.0 {
                    await trackSlowRepo(path, skipSeconds: config.slowReposkipSeconds)
                    warnings.append("Slow repo: \(snapshot.name) (\(String(format: "%.1f", elapsed))s)")
                }

                results.append(snapshot)
            }
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
                                           warnings: inout [String]) -> RepositorySnapshot {
        let name = (repoPath as NSString).lastPathComponent
        let id = stableHash(repoPath)

        guard let statusOutput = ProcessRunner.run(
            arguments: ["status", "--short", "--branch"],
            workingDirectory: repoPath,
            timeout: config.gitCommandTimeout
        ) else {
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
            timeout: config.gitCommandTimeout
        )

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

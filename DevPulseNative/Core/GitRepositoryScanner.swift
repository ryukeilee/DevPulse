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

    init(enabledBuiltInPaths: Set<String>,
         customPaths: [String],
         maxDepth: Int,
         changedPreviewLimit: Int,
         maxConcurrentGitOps: Int,
         gitCommandTimeout: TimeInterval,
         scanTimeout: TimeInterval,
         slowReposkipSeconds: TimeInterval,
         activeRepoThreshold: Int) {
        self.enabledBuiltInPaths = enabledBuiltInPaths
        self.customPaths = customPaths
        self.maxDepth = maxDepth
        self.changedPreviewLimit = changedPreviewLimit
        self.maxConcurrentGitOps = maxConcurrentGitOps
        self.gitCommandTimeout = gitCommandTimeout
        self.scanTimeout = scanTimeout
        self.slowReposkipSeconds = slowReposkipSeconds
        self.activeRepoThreshold = activeRepoThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ScanConfig.default
        enabledBuiltInPaths = try container.decodeIfPresent(Set<String>.self, forKey: .enabledBuiltInPaths)
            ?? defaults.enabledBuiltInPaths
        customPaths = try container.decodeIfPresent([String].self, forKey: .customPaths)
            ?? defaults.customPaths
        maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth) ?? defaults.maxDepth
        changedPreviewLimit = try container.decodeIfPresent(Int.self, forKey: .changedPreviewLimit)
            ?? defaults.changedPreviewLimit
        maxConcurrentGitOps = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentGitOps)
            ?? defaults.maxConcurrentGitOps
        gitCommandTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .gitCommandTimeout)
            ?? defaults.gitCommandTimeout
        scanTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .scanTimeout)
            ?? defaults.scanTimeout
        slowReposkipSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .slowReposkipSeconds)
            ?? defaults.slowReposkipSeconds
        activeRepoThreshold = try container.decodeIfPresent(Int.self, forKey: .activeRepoThreshold)
            ?? defaults.activeRepoThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case enabledBuiltInPaths
        case customPaths
        case maxDepth
        case changedPreviewLimit
        case maxConcurrentGitOps
        case gitCommandTimeout
        case scanTimeout
        case slowReposkipSeconds
        case activeRepoThreshold
    }
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

private enum RepositoryPathAvailability: Equatable {
    case repository
    case missing
    case notRepository
    case unavailable
}

private struct RepositoryDiscoveryResult {
    let readablePaths: [String]
    let unavailablePaths: [String]

    var retainedPaths: [String] {
        Array(Set(readablePaths + unavailablePaths)).sorted()
    }
}

private struct RepositoryMergeResult {
    let snapshots: [RepositorySnapshot]
    let unavailableSinceByPath: [String: String]
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
    static let incompleteDiscoveryWarning = "Repository discovery incomplete: one or more configured paths could not be read."

    static func discoveryWasIncomplete(_ warnings: [String]) -> Bool {
        warnings.contains(incompleteDiscoveryWarning)
    }

    // MARK: - Public API

    /// Run a full scan with all low-power safeguards.
    /// Returns the scan result and an array of warning strings.
    static func scan(config: ScanConfig = .default,
                     scanRoots: [String]? = nil,
                     knownRepositoryPaths: [String]? = nil,
                     ignoredRepositoryPaths: Set<String> = [],
                     forceRepositoryDiscovery: Bool = false,
                     previousSnapshot: AppGroupData? = nil) async -> (data: AppGroupData, warnings: [String], discoveredRepositoryPaths: [String]) {
        let startTime = Date()
        var warnings: [String] = []
        let previous = previousSnapshot ?? (try? AppGroupStore.read().get())
        let previousUnavailableSinceByPath = previous?.repositoryUnavailableSinceByPath ?? [:]
        let previousRepositoryPaths = (previous?.repositories.map(\.path) ?? [])
            + Array(previousUnavailableSinceByPath.keys)

        // Phase 1: discover all git repositories
        let discovery = await discoverRepositories(
            config: config,
            scanRoots: scanRoots,
            knownRepositoryPaths: knownRepositoryPaths,
            previousRepositoryPaths: previousRepositoryPaths,
            ignoredRepositoryPaths: ignoredRepositoryPaths,
            forceRefresh: forceRepositoryDiscovery,
            warnings: &warnings
        )
        if Task.isCancelled {
            return partialResult(
                discovery: discovery,
                snapshots: [],
                previousSnapshot: previous,
                warnings: &warnings
            )
        }
        // Phase 2: read git status in batches
        let snapshots = await readSnapshotsBatched(
            paths: discovery.readablePaths,
            config: config,
            warnings: &warnings,
            overallDeadline: startTime.addingTimeInterval(config.scanTimeout),
            previousSnapshots: previous?.repositories ?? [],
            previousUnavailableSinceByPath: previousUnavailableSinceByPath
        )
        if Task.isCancelled {
            warnings.append("Scan cancelled; returning the completed portion with prior snapshots retained.")
            return partialResult(
                discovery: discovery,
                snapshots: snapshots,
                previousSnapshot: previous,
                warnings: &warnings
            )
        }

        let mergeResult = mergeSnapshots(
            snapshots,
            discovery: discovery,
            previousSnapshot: previous,
            previousUnavailableSinceByPath: previousUnavailableSinceByPath
        )

        // Phase 3: sort
        let sorted = RepositorySorter.sort(mergeResult.snapshots)

        // Phase 4: build a summary from current observations only. Retained
        // values remain available for context but never count as current work.
        let summary = ScanSummary.build(
            from: sorted,
            totalRepositories: sorted.count
        )

        let result = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: DateFormatting.nowISO(),
            writtenAt: nil,
            lastSuccessfulRefreshAt: previous?.lastSuccessfulRefreshAt,
            scanSummary: summary,
            repositories: sorted,
            repositoryUnavailableSinceByPath: mergeResult.unavailableSinceByPath.isEmpty
                ? nil
                : mergeResult.unavailableSinceByPath
        )

        let retainedDiscoveryPaths = Array(Set(
            sorted.map(\.path) + Array(mergeResult.unavailableSinceByPath.keys)
        )).sorted()
        return (result, warnings, retainedDiscoveryPaths)
    }

    /// Re-read one previously known repository without rediscovering or
    /// changing the rest of the snapshot. A read failure is represented by a
    /// retained/unknown snapshot; `nil` is reserved for cancellation.
    static func retryRepository(
        config: ScanConfig = .default,
        previousSnapshot: RepositorySnapshot
    ) async -> RepositorySnapshot? {
        guard !Task.isCancelled else { return nil }

        let previous = RepositoryIdentity.normalize(previousSnapshot)
        let snapshot = readSingleSnapshot(
            repoPath: previous.path,
            config: config,
            overallDeadline: Date().addingTimeInterval(config.scanTimeout),
            previousSnapshot: previous,
            unavailableSince: previous.unavailableSince
        )

        guard !Task.isCancelled else { return nil }
        return snapshot
    }

    private static func partialResult(
        discovery: RepositoryDiscoveryResult,
        snapshots: [RepositorySnapshot],
        previousSnapshot: AppGroupData?,
        warnings: inout [String]
    ) -> (data: AppGroupData, warnings: [String], discoveredRepositoryPaths: [String]) {
        let mergeResult = mergeSnapshots(
            snapshots,
            discovery: discovery,
            previousSnapshot: previousSnapshot,
            previousUnavailableSinceByPath: previousSnapshot?.repositoryUnavailableSinceByPath ?? [:]
        )
        let sorted = RepositorySorter.sort(mergeResult.snapshots)
        let summary = ScanSummary.build(
            from: sorted,
            totalRepositories: sorted.count
        )
        return (
            AppGroupData(
                schemaVersion: RepositorySnapshotSchema.version,
                generatedAt: DateFormatting.nowISO(),
                writtenAt: nil,
                lastSuccessfulRefreshAt: previousSnapshot?.lastSuccessfulRefreshAt,
                scanSummary: summary,
                repositories: sorted,
                repositoryUnavailableSinceByPath: mergeResult.unavailableSinceByPath.isEmpty
                    ? nil
                    : mergeResult.unavailableSinceByPath
            ),
            warnings,
            Array(Set(
                sorted.map(\.path) + Array(mergeResult.unavailableSinceByPath.keys)
            )).sorted()
        )
    }

    // MARK: - Repository discovery

    private static func discoverRepositories(config: ScanConfig,
                                             scanRoots: [String]?,
                                             knownRepositoryPaths: [String]?,
                                             previousRepositoryPaths: [String],
                                             ignoredRepositoryPaths: Set<String>,
                                             forceRefresh: Bool,
                                             warnings: inout [String]) async -> RepositoryDiscoveryResult {
        var discovered = Set<String>()
        var unavailablePrefixes = Set<String>()
        let allPaths = scanRoots ?? Array(config.enabledBuiltInPaths) + config.customPaths
        let normalizedRoots = Array(Set(allPaths.map {
            ScanLocationProvider.canonicalExistingFilePath($0, resolveBuiltIn: true)
        })).sorted()
        let ignoredPaths = RepositoryScope.canonicalPathSet(ignoredRepositoryPaths)
        let cacheKey = discoveryCacheKey(for: normalizedRoots)
        let knownCandidates = Array(Set((knownRepositoryPaths ?? []) + previousRepositoryPaths))

        guard !normalizedRoots.isEmpty else {
            await discoveryCache.removeValue(for: cacheKey)
            if scanRoots == nil {
                warnings.append("No scan roots configured. Add a directory in Settings.")
            }
            return RepositoryDiscoveryResult(readablePaths: [], unavailablePaths: [])
        }

        if !forceRefresh,
           let reusedPaths = reusableKnownRepositoryPaths(
               knownCandidates,
               limitedTo: normalizedRoots,
               excluding: ignoredPaths
           ) {
            if !reusedPaths.unavailablePaths.isEmpty {
                warnings.append(incompleteDiscoveryWarning)
            }
            return reusedPaths
        }

        if forceRefresh {
            await discoveryCache.removeValue(for: cacheKey)
        } else if let cached = await discoveryCache.cachedPaths(for: cacheKey),
                  let reusableCached = reusableKnownRepositoryPaths(
                    cached,
                    limitedTo: normalizedRoots,
                    excluding: ignoredPaths
                  ) {
            if !reusableCached.unavailablePaths.isEmpty {
                warnings.append(incompleteDiscoveryWarning)
            }
            return reusableCached
        }

        for root in normalizedRoots {
            if Task.isCancelled { break }
            switch directoryAvailability(at: root) {
            case .repository:
                walkDirectory(
                    root,
                    config: config,
                    ignoredPaths: ignoredPaths,
                    discovered: &discovered,
                    unavailablePrefixes: &unavailablePrefixes,
                    warnings: &warnings
                )
            case .unavailable:
                unavailablePrefixes.insert(root)
                warnings.append("Scan root unavailable: \(root)")
            case .missing, .notRepository:
                warnings.append("Scan root unavailable: \(root)")
            }
        }

        if !unavailablePrefixes.isEmpty {
            warnings.append(incompleteDiscoveryWarning)
        }

        if discovered.isEmpty {
            if !allPaths.isEmpty && unavailablePrefixes.isEmpty {
                warnings.append("No Git repositories discovered in the configured scan roots.")
            }
        }

        let sorted = Array(discovered).sorted()
        await discoveryCache.store(paths: sorted, for: cacheKey, ttl: discoveryCacheTTL)
        let unavailablePaths = knownCandidates
            .map(RepositoryIdentity.canonicalPath)
            .filter { path in
                !RepositoryScope.contains(path, in: ignoredPaths)
                    && normalizedRoots.contains { RepositoryIdentity.isSameOrDescendantPath(path, of: $0) }
                    && unavailablePrefixes.contains { RepositoryIdentity.isSameOrDescendantPath(path, of: $0) }
            }
        return RepositoryDiscoveryResult(
            readablePaths: sorted,
            unavailablePaths: Array(Set(unavailablePaths)).sorted()
        )
    }

    private static func reusableKnownRepositoryPaths(
        _ knownRepositoryPaths: [String],
        limitedTo scanRoots: [String],
        excluding ignoredPaths: Set<String>
    ) -> RepositoryDiscoveryResult? {
        let normalizedRoots = scanRoots.map {
            ScanLocationProvider.canonicalExistingFilePath($0, resolveBuiltIn: true)
        }
        guard !normalizedRoots.isEmpty else {
            return RepositoryDiscoveryResult(readablePaths: [], unavailablePaths: [])
        }

        let candidates = Array(Set(knownRepositoryPaths.map(RepositoryIdentity.canonicalPath)))
            .filter { path in
                !RepositoryScope.contains(path, in: ignoredPaths)
                    && normalizedRoots.contains { RepositoryIdentity.isSameOrDescendantPath(path, of: $0) }
            }
        guard !candidates.isEmpty else { return nil }

        var readable: [String] = []
        var unavailable: [String] = []
        for path in candidates {
            switch repositoryAvailability(at: path) {
            case .repository:
                readable.append(path)
            case .unavailable:
                unavailable.append(path)
            case .missing, .notRepository:
                // A definitive disappearance invalidates the whole reuse set
                // so a move or replacement can be discovered immediately.
                return nil
            }
        }

        guard !readable.isEmpty || !unavailable.isEmpty else { return nil }
        return RepositoryDiscoveryResult(
            readablePaths: Array(Set(readable)).sorted(),
            unavailablePaths: Array(Set(unavailable)).sorted()
        )
    }

    private static func walkDirectory(_ directory: String,
                                      config: ScanConfig,
                                      depth: Int = 0,
                                      ignoredPaths: Set<String>,
                                      discovered: inout Set<String>,
                                      unavailablePrefixes: inout Set<String>,
                                      warnings: inout [String]) {
        guard !Task.isCancelled else { return }
        guard depth <= config.maxDepth else { return }

        let directory = ScanLocationProvider.canonicalExistingFilePath(directory, resolveBuiltIn: true)
        guard !RepositoryScope.contains(directory, in: ignoredPaths) else { return }

        let dirName = (directory as NSString).lastPathComponent
        if ExcludedDirectoryRules.isExcluded(dirName: dirName) {
            return
        }

        switch repositoryAvailability(at: directory) {
        case .repository:
            discovered.insert(directory)
            return
        case .unavailable:
            unavailablePrefixes.insert(directory)
            warnings.append("Repository path unavailable: \(directory)")
            return
        case .missing:
            return
        case .notRepository:
            break
        }

        let directoryURL = URL(fileURLWithPath: directory)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            )
        } catch {
            if !isMissingFileError(error) {
                unavailablePrefixes.insert(directory)
                warnings.append("Repository directory unavailable: \(directory)")
            }
            return
        }

        for entryURL in entries {
            if Task.isCancelled { return }
            let fullPath = ScanLocationProvider.canonicalExistingFilePath(entryURL.path, resolveBuiltIn: true)
            let entryName = entryURL.lastPathComponent

            guard !ExcludedDirectoryRules.isExcluded(dirName: entryName) else { continue }

            let isDirectory: Bool
            do {
                let values = try entryURL.resourceValues(forKeys: [.isDirectoryKey])
                isDirectory = values.isDirectory ?? false
            } catch {
                if !isMissingFileError(error) {
                    unavailablePrefixes.insert(fullPath)
                }
                continue
            }
            guard isDirectory else { continue }

            walkDirectory(fullPath,
                          config: config,
                          depth: depth + 1,
                          ignoredPaths: ignoredPaths,
                          discovered: &discovered,
                          unavailablePrefixes: &unavailablePrefixes,
                          warnings: &warnings)
        }
    }

    // MARK: - Git repository detection

    static func isGitRepository(_ directory: String) -> Bool {
        repositoryAvailability(at: directory) == .repository
    }

    private static func directoryAvailability(at path: String) -> RepositoryPathAvailability {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return attributes[.type] as? FileAttributeType == .typeDirectory
                ? .repository
                : .missing
        } catch {
            return isMissingFileError(error) ? .missing : .unavailable
        }
    }

    private static func repositoryAvailability(at directory: String) -> RepositoryPathAvailability {
        switch directoryAvailability(at: directory) {
        case .repository:
            break
        case .missing:
            return .missing
        case .unavailable:
            return .unavailable
        case .notRepository:
            return .notRepository
        }

        let gitPath = (directory as NSString).appendingPathComponent(".git")
        do {
            _ = try FileManager.default.attributesOfItem(atPath: gitPath)
            return .repository
        } catch {
            return isMissingFileError(error) ? .notRepository : .unavailable
        }
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError)
    }

    // MARK: - Batched snapshot reading

    /// Read git status in batches to limit concurrent git processes.
    private static func readSnapshotsBatched(paths: [String],
                                             config: ScanConfig,
                                             warnings: inout [String],
                                             overallDeadline: Date,
                                             previousSnapshots: [RepositorySnapshot],
                                             previousUnavailableSinceByPath: [String: String]) async -> [RepositorySnapshot] {
        guard !paths.isEmpty else { return [] }

        var previousByPath: [String: RepositorySnapshot] = [:]
        for previous in previousSnapshots {
            let normalized = RepositoryIdentity.normalize(previous)
            if let existing = previousByPath[normalized.path], existing.isPinned || normalized.isPinned {
                var merged = existing
                merged.isPinned = true
                previousByPath[normalized.path] = merged
            } else {
                previousByPath[normalized.path] = normalized
            }
        }
        var resultsByIndex: [Int: SnapshotReadResult] = [:]

        // Filter out slow repos
        let (activePaths, skippedPaths) = await filterSlowRepos(paths)
        for skipped in skippedPaths {
            let index = paths.firstIndex(of: skipped) ?? 0
            let canonicalPath = RepositoryIdentity.canonicalPath(skipped)
            let previous = previousByPath[canonicalPath]
            let fallback = failedSnapshot(
                for: canonicalPath,
                previousSnapshot: previous,
                unavailableSince: previousUnavailableSinceByPath[canonicalPath],
                errorMessage: "扫描已跳过"
            )
            resultsByIndex[index] = SnapshotReadResult(
                index: index,
                snapshot: fallback,
                elapsed: 0
            )
            warnings.append(
                previous == nil
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
                let canonicalPath = RepositoryIdentity.canonicalPath(path)
                let previousSnapshot = previousByPath[canonicalPath]
                let unavailableSince = previousUnavailableSinceByPath[canonicalPath]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let remaining = overallDeadline.timeIntervalSinceNow
                    guard remaining > 0 else { return nil }
                    let startedAt = Date()
                    guard let snapshot = readSingleSnapshot(
                        repoPath: path,
                        config: config,
                        overallDeadline: overallDeadline,
                        previousSnapshot: previousSnapshot,
                        unavailableSince: unavailableSince
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

            let message = timedOut || Date() >= overallDeadline
                ? "扫描超时"
                : (cancelled ? "扫描已取消" : "读取失败")
            results.append(
                failedSnapshot(
                    for: path,
                    previousSnapshot: previousByPath[RepositoryIdentity.canonicalPath(path)],
                    unavailableSince: previousUnavailableSinceByPath[
                        RepositoryIdentity.canonicalPath(path)
                    ],
                    errorMessage: message
                )
            )
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
                                           overallDeadline: Date? = nil,
                                           previousSnapshot: RepositorySnapshot? = nil,
                                           unavailableSince: String? = nil) -> RepositorySnapshot? {
        let repoPath = RepositoryIdentity.canonicalPath(repoPath)
        let name = (repoPath as NSString).lastPathComponent
        let id = RepositoryIdentity.id(for: repoPath)
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
            return failedSnapshot(
                for: repoPath,
                previousSnapshot: previousSnapshot,
                unavailableSince: unavailableSince,
                errorMessage: "读取失败"
            )
        }

        let branchMetadata = GitStatusParser.parseBranchMetadata(statusOutput)
        let entries = GitStatusParser.parseStatusEntries(statusOutput)
        let summary = GitStatusParser.summarize(entries)
        let changedFiles = entries.map(\.path)
        let changedCount = summary.total

        let status: RepositoryStatus = changedCount > 0 ? .changed : .clean
        let risk = RiskHintEngine.assess(changedFiles: changedFiles)

        let commitOutput = ProcessRunner.run(
            arguments: ["log", "-1", "--pretty=%H%x00%cI%x00%s"],
            workingDirectory: repoPath,
            timeout: commandTimeout(),
            isCancelled: cancellationCheck
        )
        let commitMetadata = GitStatusParser.parseLastCommitMetadata(commitOutput)
        let hasNoCommits = statusOutput.contains("No commits yet on ")
            || statusOutput.contains("Initial commit on ")
        let lastCommitMetadataAvailable = commitMetadata != nil || hasNoCommits
        let lastCommitAt = commitMetadata?.committedAt
            ?? (hasNoCommits ? nil : previousSnapshot?.lastChangedAt)
        let lastCommitID = commitMetadata?.commitID
            ?? (hasNoCommits ? nil : previousSnapshot?.lastCommitID)
        let lastCommitSummary = commitMetadata?.summary
            ?? (hasNoCommits ? nil : previousSnapshot?.lastCommitSummary)

        guard !Task.isCancelled else { return nil }

        // Preview capped at 5
        let preview = Array(changedFiles.prefix(config.changedPreviewLimit))
        let aheadCount = branchMetadata.hasUpstream ? branchMetadata.aheadCount : nil
        let behindCount = branchMetadata.hasUpstream ? branchMetadata.behindCount : nil
        let scannedAt = DateFormatting.nowISO()

        var snapshot = RepositorySnapshot(
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
            aheadCount: aheadCount,
            behindCount: behindCount,
            hasUpstream: branchMetadata.hasUpstream,
            changedFileCount: changedCount,
            changedFilesPreview: preview,
            risk: risk.level,
            lastScannedAt: scannedAt,
            dataSource: .current,
            lastSuccessfulScanAt: scannedAt,
            lastChangedAt: lastCommitAt,
            lastCommitID: lastCommitID,
            lastCommitSummary: lastCommitSummary,
            lastCommitMetadataAvailable: lastCommitMetadataAvailable,
            lastActivityAt: nil,
            errorMessage: nil,
            isPinned: previousSnapshot?.isPinned ?? false
        )
        snapshot.lastActivityAt = resolvedActivityTimestamp(
            previousSnapshot: previousSnapshot,
            currentSnapshot: snapshot,
            observedAt: scannedAt
        )
        return snapshot
    }

    private static func failedSnapshot(for path: String,
                                       previousSnapshot: RepositorySnapshot?,
                                       unavailableSince: String? = nil,
                                       errorMessage: String) -> RepositorySnapshot {
        let path = RepositoryIdentity.canonicalPath(path)
        let previous = previousSnapshot.map(RepositoryIdentity.normalize)
        let attemptedAt = DateFormatting.nowISO()
        if let previous {
            return previous.retainingLastSuccessfulData(
                attemptedAt: attemptedAt,
                errorMessage: errorMessage,
                unavailableSince: unavailableSince
            )
        }
        return RepositorySnapshot(
            id: RepositoryIdentity.id(for: path),
            name: (path as NSString).lastPathComponent,
            path: path,
            branch: "unknown",
            status: .error,
            modifiedFileCount: 0,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: nil,
            unstagedFileCount: nil,
            conflictedFileCount: nil,
            aheadCount: nil,
            behindCount: nil,
            hasUpstream: nil,
            changedFileCount: 0,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: attemptedAt,
            dataSource: .unknown,
            lastSuccessfulScanAt: nil,
            lastChangedAt: nil,
            lastCommitID: nil,
            lastCommitSummary: nil,
            lastCommitMetadataAvailable: false,
            lastActivityAt: nil,
            unavailableSince: unavailableSince ?? attemptedAt,
            errorMessage: errorMessage,
            isPinned: false
        )
    }

    private static func resolvedActivityTimestamp(
        previousSnapshot: RepositorySnapshot?,
        currentSnapshot: RepositorySnapshot,
        observedAt: String
    ) -> String? {
        guard let previousSnapshot else {
            return currentSnapshot.status == .changed
                ? observedAt
                : currentSnapshot.lastChangedAt
        }

        let statusChanged = previousSnapshot.status != .error
            && previousSnapshot.status != currentSnapshot.status
        let stateChanged = previousSnapshot.branch != currentSnapshot.branch
            || statusChanged
            || previousSnapshot.modifiedFileCount != currentSnapshot.modifiedFileCount
            || previousSnapshot.addedFileCount != currentSnapshot.addedFileCount
            || previousSnapshot.deletedFileCount != currentSnapshot.deletedFileCount
            || previousSnapshot.untrackedFileCount != currentSnapshot.untrackedFileCount
            || previousSnapshot.stagedFileCount != currentSnapshot.stagedFileCount
            || previousSnapshot.unstagedFileCount != currentSnapshot.unstagedFileCount
            || previousSnapshot.conflictedFileCount != currentSnapshot.conflictedFileCount
            || previousSnapshot.aheadCount != currentSnapshot.aheadCount
            || previousSnapshot.behindCount != currentSnapshot.behindCount
            || previousSnapshot.hasUpstream != currentSnapshot.hasUpstream
            || previousSnapshot.lastCommitID != currentSnapshot.lastCommitID
            || previousSnapshot.lastChangedAt != currentSnapshot.lastChangedAt
            || previousSnapshot.lastCommitSummary != currentSnapshot.lastCommitSummary

        if stateChanged {
            return observedAt
        }

        return previousSnapshot.lastActivityAt
            ?? previousSnapshot.lastChangedAt
            ?? currentSnapshot.lastChangedAt
    }

    private static func mergeSnapshots(
        _ snapshots: [RepositorySnapshot],
        discovery: RepositoryDiscoveryResult,
        previousSnapshot: AppGroupData?,
        previousUnavailableSinceByPath: [String: String]
    ) -> RepositoryMergeResult {
        var byPath: [String: RepositorySnapshot] = [:]
        for snapshot in snapshots.map(RepositoryIdentity.normalize) {
            if let existing = byPath[snapshot.path], existing.isPinned || snapshot.isPinned {
                var merged = existing
                merged.isPinned = true
                byPath[snapshot.path] = merged
            } else {
                byPath[snapshot.path] = snapshot
            }
        }
        var previousByPath: [String: RepositorySnapshot] = [:]
        for previous in previousSnapshot?.repositories ?? [] {
            let normalized = RepositoryIdentity.normalize(previous)
            if let existing = previousByPath[normalized.path], existing.isPinned || normalized.isPinned {
                var merged = existing
                merged.isPinned = true
                previousByPath[normalized.path] = merged
            } else {
                previousByPath[normalized.path] = normalized
            }
        }
        var unavailableSinceByPath: [String: String] = [:]
        for (path, timestamp) in previousUnavailableSinceByPath {
            let canonicalPath = RepositoryIdentity.canonicalPath(path)
            guard !canonicalPath.isEmpty else { continue }
            if let existing = unavailableSinceByPath[canonicalPath] {
                unavailableSinceByPath[canonicalPath] = min(existing, timestamp)
            } else {
                unavailableSinceByPath[canonicalPath] = timestamp
            }
        }

        for path in discovery.readablePaths {
            let normalizedPath = RepositoryIdentity.canonicalPath(path)
            guard byPath[normalizedPath] == nil else { continue }
            byPath[normalizedPath] = failedSnapshot(
                for: normalizedPath,
                previousSnapshot: previousByPath[normalizedPath],
                unavailableSince: unavailableSinceByPath[normalizedPath],
                errorMessage: "本轮未完成扫描"
            )
        }

        for path in discovery.unavailablePaths {
            let normalizedPath = RepositoryIdentity.canonicalPath(path)
            guard byPath[normalizedPath] == nil else { continue }
            byPath[normalizedPath] = failedSnapshot(
                for: normalizedPath,
                previousSnapshot: previousByPath[normalizedPath],
                unavailableSince: unavailableSinceByPath[normalizedPath],
                errorMessage: "仓库暂时不可访问"
            )
        }

        var seen = Set<String>()
        var retainedSnapshots: [RepositorySnapshot] = []
        var retainedUnavailability: [String: String] = [:]
        for path in discovery.retainedPaths {
            let normalizedPath = RepositoryIdentity.canonicalPath(path)
            guard seen.insert(normalizedPath).inserted,
                  let snapshot = byPath[normalizedPath] else { continue }

            if snapshot.resolvedDataSource == .current && snapshot.status != .error {
                retainedSnapshots.append(snapshot)
                continue
            }

            let firstUnavailableAt = snapshot.unavailableSince
                ?? unavailableSinceByPath[normalizedPath]
                ?? snapshot.lastScannedAt
            retainedUnavailability[normalizedPath] = firstUnavailableAt
            if RepositoryRetentionPolicy.shouldRetain(snapshot) {
                retainedSnapshots.append(snapshot)
            }
        }
        return RepositoryMergeResult(
            snapshots: retainedSnapshots,
            unavailableSinceByPath: retainedUnavailability
        )
    }

    // MARK: - Helpers

    private static func discoveryCacheKey(for roots: [String]) -> String {
        roots.sorted().joined(separator: "\n")
    }
}

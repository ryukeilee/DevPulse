import Foundation
import OSLog

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
    /// Deprecated compatibility field retained for decoding stored settings.
    /// Readable repositories are no longer skipped between full scans.
    let slowReposkipSeconds: TimeInterval
    /// Deprecated compatibility field. Full scans still read every repository.
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
    let mode: DiscoveryMode
    let isComplete: Bool

    init(readablePaths: [String],
         unavailablePaths: [String],
         mode: DiscoveryMode = .walked,
         isComplete: Bool = true) {
        self.readablePaths = readablePaths
        self.unavailablePaths = unavailablePaths
        self.mode = mode
        self.isComplete = isComplete
    }

    var retainedPaths: [String] {
        Array(Set(readablePaths + unavailablePaths)).sorted()
    }
}

private enum DiscoveryMode {
    case empty
    case reusedKnown
    case reusedCache
    case walked
    case incomplete
}

private enum RepositoryReuseAttempt {
    case reusable(RepositoryDiscoveryResult)
    case invalidated
}

private struct DiscoveryTraversalState {
    var isComplete = true
    var wasCancelled = false
    var timedOut = false

    mutating func shouldStop(deadline: Date) -> Bool {
        if Task.isCancelled {
            isComplete = false
            wasCancelled = true
            return true
        }
        if Date() >= deadline {
            isComplete = false
            timedOut = true
            return true
        }
        return false
    }

    mutating func markUnavailable() {
        isComplete = false
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
    typealias GitCommandRunner = @Sendable (
        _ arguments: [String],
        _ workingDirectory: String,
        _ timeout: TimeInterval,
        _ outputLimit: Int,
        _ isCancelled: @escaping @Sendable () -> Bool
    ) -> ProcessRunResult

    private static let discoveryCache = RepositoryDiscoveryCache()
    private static let discoveryCacheTTL: TimeInterval = 10 * 60
    private static let discoveryRulesVersion = 2
    private static let maximumConcurrentGitOps = 12
    private static let logger = Logger(subsystem: "local.devpulse.app", category: "RepositoryScan")
    static let defaultGitCommandRunner: GitCommandRunner = {
        arguments, workingDirectory, timeout, outputLimit, isCancelled in
        ProcessRunner.runDetailed(
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout,
            outputLimit: outputLimit,
            isCancelled: isCancelled
        )
    }
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
                     previousSnapshot: AppGroupData? = nil,
                     metrics: ScanMetricsCollector? = nil,
                     gitCommandRunner: @escaping GitCommandRunner = defaultGitCommandRunner) async -> (data: AppGroupData, warnings: [String], discoveredRepositoryPaths: [String]) {
        let startTime = Date()
        let collector = metrics ?? ScanMetricsCollector()
        let scanToken = collector.beginScan()
        defer {
            collector.endScan(scanToken)
            logScanSummary(collector.snapshot(), kind: "full")
        }
        var warnings: [String] = []
        let previous = previousSnapshot ?? (try? AppGroupStore.read().get())
        let previousUnavailableSinceByPath = previous?.repositoryUnavailableSinceByPath ?? [:]
        let previousRepositoryPaths = (previous?.repositories.map(\.path) ?? [])
            + Array(previousUnavailableSinceByPath.keys)

        // Phase 1: discover all git repositories
        let discoveryStartedAt = ProcessInfo.processInfo.systemUptime
        let discovery = await discoverRepositories(
            config: config,
            scanRoots: scanRoots,
            knownRepositoryPaths: knownRepositoryPaths,
            previousRepositoryPaths: previousRepositoryPaths,
            ignoredRepositoryPaths: ignoredRepositoryPaths,
            forceRefresh: forceRepositoryDiscovery,
            overallDeadline: startTime.addingTimeInterval(config.scanTimeout),
            warnings: &warnings
        )
        collector.recordDiscovery(
            mode: repositoryDiscoveryMode(discovery.mode),
            elapsed: ProcessInfo.processInfo.systemUptime - discoveryStartedAt,
            discoveredRepositoryCount: discovery.retainedPaths.count
        )
        if Task.isCancelled {
            return partialResult(
                discovery: discovery,
                snapshots: [],
                previousSnapshot: previous,
                metrics: collector,
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
            previousUnavailableSinceByPath: previousUnavailableSinceByPath,
            metrics: collector,
            gitCommandRunner: gitCommandRunner
        )
        if Task.isCancelled {
            warnings.append("Scan cancelled; returning the completed portion with prior snapshots retained.")
            return partialResult(
                discovery: discovery,
                snapshots: snapshots,
                previousSnapshot: previous,
                metrics: collector,
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
        collector.recordReusedRepositorySnapshot(
            count: sorted.filter { $0.resolvedDataSource == RepositoryDataSource.lastSuccessful }.count
        )

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
        previousSnapshot: RepositorySnapshot,
        metrics: ScanMetricsCollector? = nil,
        gitCommandRunner: GitCommandRunner = defaultGitCommandRunner
    ) async -> RepositorySnapshot? {
        let collector = metrics ?? ScanMetricsCollector()
        let scanToken = collector.beginScan(isFullScan: false)
        defer {
            collector.endScan(scanToken)
            logScanSummary(collector.snapshot(), kind: "retry")
        }
        guard !Task.isCancelled else { return nil }

        let previous = RepositoryIdentity.normalize(previousSnapshot)
        let snapshot = readSingleSnapshot(
            repoPath: previous.path,
            config: config,
            overallDeadline: Date().addingTimeInterval(config.scanTimeout),
            previousSnapshot: previous,
            unavailableSince: previous.unavailableSince,
            metrics: collector,
            gitCommandRunner: gitCommandRunner
        )

        guard !Task.isCancelled else { return nil }
        if let snapshot, snapshot.resolvedDataSource == .lastSuccessful {
            collector.recordReusedRepositorySnapshot()
        }
        return snapshot
    }

    private static func partialResult(
        discovery: RepositoryDiscoveryResult,
        snapshots: [RepositorySnapshot],
        previousSnapshot: AppGroupData?,
        metrics: ScanMetricsCollector,
        warnings: inout [String]
    ) -> (data: AppGroupData, warnings: [String], discoveredRepositoryPaths: [String]) {
        let mergeResult = mergeSnapshots(
            snapshots,
            discovery: discovery,
            previousSnapshot: previousSnapshot,
            previousUnavailableSinceByPath: previousSnapshot?.repositoryUnavailableSinceByPath ?? [:]
        )
        let sorted = RepositorySorter.sort(mergeResult.snapshots)
        metrics.recordReusedRepositorySnapshot(
            count: sorted.filter { $0.resolvedDataSource == RepositoryDataSource.lastSuccessful }.count
        )
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
                                             overallDeadline: Date,
                                             warnings: inout [String]) async -> RepositoryDiscoveryResult {
        var discovered = Set<String>()
        var unavailablePrefixes = Set<String>()
        var traversalState = DiscoveryTraversalState()
        let allPaths = scanRoots ?? Array(config.enabledBuiltInPaths) + config.customPaths
        let normalizedRoots = Array(Set(allPaths.map {
            ScanLocationProvider.canonicalExistingFilePath($0, resolveBuiltIn: true)
        })).sorted()
        let ignoredPaths = RepositoryScope.canonicalPathSet(ignoredRepositoryPaths)
        let cacheKey = discoveryCacheKey(for: normalizedRoots, maxDepth: config.maxDepth)
        let knownCandidates = Array(Set((knownRepositoryPaths ?? []) + previousRepositoryPaths))

        guard !normalizedRoots.isEmpty else {
            await discoveryCache.removeValue(for: cacheKey)
            if scanRoots == nil {
                warnings.append("No scan roots configured. Add a directory in Settings.")
            }
            return RepositoryDiscoveryResult(
                readablePaths: [],
                unavailablePaths: [],
                mode: .empty
            )
        }

        if !forceRefresh {
            switch reusableKnownRepositoryPaths(
                knownCandidates,
                limitedTo: normalizedRoots,
                excluding: ignoredPaths,
                overallDeadline: overallDeadline,
                successMode: .reusedKnown
            ) {
            case .reusable(let reusedPaths):
                if !reusedPaths.isComplete {
                    appendDiscoveryInterruptionWarning(
                        for: reusedPaths,
                        overallDeadline: overallDeadline,
                        warnings: &warnings
                    )
                }
                return reusedPaths
            case .invalidated:
                break
            }
        }

        if forceRefresh {
            await discoveryCache.removeValue(for: cacheKey)
        } else if let cached = await discoveryCache.cachedPaths(for: cacheKey) {
            switch reusableKnownRepositoryPaths(
                cached,
                limitedTo: normalizedRoots,
                excluding: ignoredPaths,
                overallDeadline: overallDeadline,
                successMode: .reusedCache
            ) {
            case .reusable(let reusableCached):
                if !reusableCached.isComplete {
                    appendDiscoveryInterruptionWarning(
                        for: reusableCached,
                        overallDeadline: overallDeadline,
                        warnings: &warnings
                    )
                }
                return reusableCached
            case .invalidated:
                break
            }
        }

        for root in normalizedRoots {
            if traversalState.shouldStop(deadline: overallDeadline) { break }
            switch directoryAvailability(at: root) {
            case .repository:
                walkDirectory(
                    root,
                    config: config,
                    ignoredPaths: ignoredPaths,
                    discovered: &discovered,
                    unavailablePrefixes: &unavailablePrefixes,
                    overallDeadline: overallDeadline,
                    traversalState: &traversalState,
                    warnings: &warnings
                )
            case .unavailable:
                unavailablePrefixes.insert(root)
                traversalState.markUnavailable()
                warnings.append("Scan root unavailable: \(root)")
            case .missing, .notRepository:
                unavailablePrefixes.insert(root)
                traversalState.markUnavailable()
                warnings.append("Scan root unavailable: \(root)")
            }
        }
        _ = traversalState.shouldStop(deadline: overallDeadline)

        if !traversalState.isComplete || !unavailablePrefixes.isEmpty {
            warnings.append(incompleteDiscoveryWarning)
        }
        if traversalState.timedOut {
            warnings.append("Repository discovery timeout reached; partial results were retained.")
        } else if traversalState.wasCancelled {
            warnings.append("Repository discovery cancelled; partial results were retained.")
        }

        if discovered.isEmpty {
            if !allPaths.isEmpty && traversalState.isComplete && unavailablePrefixes.isEmpty {
                warnings.append("No Git repositories discovered in the configured scan roots.")
            }
        }

        let sorted = Array(discovered).sorted()
        if traversalState.isComplete && unavailablePrefixes.isEmpty {
            await discoveryCache.store(paths: sorted, for: cacheKey, ttl: discoveryCacheTTL)
        }
        let unavailablePaths = knownCandidates
            .map(RepositoryIdentity.canonicalPath)
            .filter { path in
                !RepositoryScope.contains(path, in: ignoredPaths)
                    && normalizedRoots.contains { RepositoryIdentity.isSameOrDescendantPath(path, of: $0) }
                    && (!traversalState.isComplete
                        || unavailablePrefixes.contains { RepositoryIdentity.isSameOrDescendantPath(path, of: $0) })
                    && !discovered.contains(path)
            }
        return RepositoryDiscoveryResult(
            readablePaths: sorted,
            unavailablePaths: Array(Set(unavailablePaths)).sorted(),
            mode: traversalState.isComplete ? .walked : .incomplete,
            isComplete: traversalState.isComplete
        )
    }

    private static func reusableKnownRepositoryPaths(
        _ knownRepositoryPaths: [String],
        limitedTo scanRoots: [String],
        excluding ignoredPaths: Set<String>,
        overallDeadline: Date,
        successMode: DiscoveryMode
    ) -> RepositoryReuseAttempt {
        let normalizedRoots = scanRoots.map {
            ScanLocationProvider.canonicalExistingFilePath($0, resolveBuiltIn: true)
        }
        guard !normalizedRoots.isEmpty else {
            return .reusable(RepositoryDiscoveryResult(
                readablePaths: [],
                unavailablePaths: [],
                mode: .empty
            ))
        }

        let candidates = Array(Set(knownRepositoryPaths.map(RepositoryIdentity.canonicalPath)))
            .filter { path in
                !RepositoryScope.contains(path, in: ignoredPaths)
                    && normalizedRoots.contains { RepositoryIdentity.isSameOrDescendantPath(path, of: $0) }
            }
        guard !candidates.isEmpty else { return .invalidated }

        var readable: [String] = []
        var unavailable: [String] = []
        for (index, path) in candidates.enumerated() {
            if Task.isCancelled || Date() >= overallDeadline {
                unavailable.append(contentsOf: candidates[index...])
                return .reusable(RepositoryDiscoveryResult(
                    readablePaths: Array(Set(readable)).sorted(),
                    unavailablePaths: Array(Set(unavailable)).sorted(),
                    mode: .incomplete,
                    isComplete: false
                ))
            }
            switch repositoryAvailability(at: path) {
            case .repository:
                readable.append(path)
            case .unavailable:
                unavailable.append(path)
            case .missing, .notRepository:
                // A definitive disappearance invalidates the whole reuse set
                // so a move or replacement can be discovered immediately.
                return .invalidated
            }
        }

        if Task.isCancelled || Date() >= overallDeadline {
            return .reusable(RepositoryDiscoveryResult(
                readablePaths: Array(Set(readable)).sorted(),
                unavailablePaths: Array(Set(unavailable)).sorted(),
                mode: .incomplete,
                isComplete: false
            ))
        }

        guard !readable.isEmpty || !unavailable.isEmpty else { return .invalidated }
        let complete = unavailable.isEmpty
        return .reusable(RepositoryDiscoveryResult(
            readablePaths: Array(Set(readable)).sorted(),
            unavailablePaths: Array(Set(unavailable)).sorted(),
            mode: complete ? successMode : .incomplete,
            isComplete: complete
        ))
    }

    private static func walkDirectory(_ directory: String,
                                      config: ScanConfig,
                                      depth: Int = 0,
                                      ignoredPaths: Set<String>,
                                      discovered: inout Set<String>,
                                      unavailablePrefixes: inout Set<String>,
                                      overallDeadline: Date,
                                      traversalState: inout DiscoveryTraversalState,
                                      warnings: inout [String]) {
        guard !traversalState.shouldStop(deadline: overallDeadline) else { return }
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
            traversalState.markUnavailable()
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
                traversalState.markUnavailable()
                warnings.append("Repository directory unavailable: \(directory)")
            }
            return
        }

        for entryURL in entries {
            if traversalState.shouldStop(deadline: overallDeadline) { return }
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
                    traversalState.markUnavailable()
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
                          overallDeadline: overallDeadline,
                          traversalState: &traversalState,
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
                                             previousUnavailableSinceByPath: [String: String],
                                             metrics: ScanMetricsCollector,
                                             gitCommandRunner: @escaping GitCommandRunner) async -> [RepositorySnapshot] {
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

        // Preserve each repository's original index so task completion never
        // performs an O(n) lookup in the full path list.
        let indexedPaths = Array(paths.enumerated())

        // Keep at most maxConcurrentGitOps read tasks in flight. Each task
        // invokes one Git command at a time, so this is also the process cap.
        let concurrency = min(
            maximumConcurrentGitOps,
            max(1, config.maxConcurrentGitOps)
        )
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
                guard nextIndex < indexedPaths.count else { return }
                let (originalIndex, path) = indexedPaths[nextIndex]
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
                        unavailableSince: unavailableSince,
                        metrics: metrics,
                        gitCommandRunner: gitCommandRunner
                    ) else {
                        return nil
                    }
                    return SnapshotReadResult(
                        index: originalIndex,
                        snapshot: snapshot,
                        elapsed: Date().timeIntervalSince(startedAt)
                    )
                }
            }

            for _ in 0..<min(concurrency, indexedPaths.count) {
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

    // MARK: - Single snapshot

    private static func readSingleSnapshot(repoPath: String,
                                           config: ScanConfig,
                                           overallDeadline: Date? = nil,
                                           previousSnapshot: RepositorySnapshot? = nil,
                                           unavailableSince: String? = nil,
                                           metrics: ScanMetricsCollector,
                                           gitCommandRunner: GitCommandRunner) -> RepositorySnapshot? {
        let repoPath = RepositoryIdentity.canonicalPath(repoPath)
        let name = (repoPath as NSString).lastPathComponent
        let id = RepositoryIdentity.id(for: repoPath)
        let cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
        func commandTimeout() -> TimeInterval {
            guard let overallDeadline else { return config.gitCommandTimeout }
            return min(config.gitCommandTimeout, max(0, overallDeadline.timeIntervalSinceNow))
        }

        guard !Task.isCancelled else { return nil }
        metrics.recordRepositoryRead()

        let statusResult = runGitCommand(
            arguments: ["status", "--porcelain=v2", "--branch"],
            workingDirectory: repoPath,
            timeout: commandTimeout(),
            kind: .status,
            metrics: metrics,
            gitCommandRunner: gitCommandRunner,
            isCancelled: cancellationCheck
        )
        let statusOutput: String
        switch statusResult {
        case .success(let output):
            statusOutput = output
        case .cancelled:
            return nil
        case .nonZero, .timeout, .launch, .unavailable, .outputLimit:
            return failedSnapshot(
                for: repoPath,
                previousSnapshot: previousSnapshot,
                unavailableSince: unavailableSince,
                errorMessage: statusFailureMessage(statusResult)
            )
        }

        let branchMetadata = GitStatusParser.parseBranchMetadata(statusOutput)
        let entries = GitStatusParser.parseStatusEntries(statusOutput)
        let summary = GitStatusParser.summarize(entries)
        let changedFiles = entries.map(\.path)
        let changedCount = summary.total

        let status: RepositoryStatus = changedCount > 0 ? .changed : .clean
        let risk = RiskHintEngine.assess(changedFiles: changedFiles)

        let hasNoCommits = branchMetadata.hasNoCommits
            || statusOutput.contains("No commits yet on ")
            || statusOutput.contains("Initial commit on ")
        let canReuseCommitMetadata = branchMetadata.headOID != nil
            && branchMetadata.headOID == previousSnapshot?.lastCommitID
            && previousSnapshot?.lastCommitMetadataAvailable == true

        let commitMetadata: GitStatusParser.LastCommitMetadata?
        let lastCommitMetadataAvailable: Bool
        if hasNoCommits {
            commitMetadata = nil
            lastCommitMetadataAvailable = true
        } else if canReuseCommitMetadata {
            commitMetadata = GitStatusParser.LastCommitMetadata(
                commitID: previousSnapshot?.lastCommitID,
                committedAt: previousSnapshot?.lastChangedAt,
                summary: previousSnapshot?.lastCommitSummary
            )
            lastCommitMetadataAvailable = true
        } else {
            let logResult = runGitCommand(
                arguments: ["log", "-1", "--pretty=%H%x00%cI%x00%s"],
                workingDirectory: repoPath,
                timeout: commandTimeout(),
                kind: .log,
                metrics: metrics,
                gitCommandRunner: gitCommandRunner,
                isCancelled: cancellationCheck
            )
            switch logResult {
            case .success(let output):
                commitMetadata = GitStatusParser.parseLastCommitMetadata(output)
                lastCommitMetadataAvailable = commitMetadata != nil
            case .cancelled:
                return nil
            case .nonZero, .timeout, .launch, .unavailable, .outputLimit:
                commitMetadata = nil
                lastCommitMetadataAvailable = false
            }
        }

        let lastCommitAt: String?
        let lastCommitID: String?
        let lastCommitSummary: String?
        if hasNoCommits {
            lastCommitAt = nil
            lastCommitID = nil
            lastCommitSummary = nil
        } else if lastCommitMetadataAvailable {
            lastCommitAt = commitMetadata?.committedAt
            lastCommitID = commitMetadata?.commitID
            lastCommitSummary = commitMetadata?.summary
        } else {
            // Status already proved that HEAD differs, so reusing the old
            // commit time/summary would present stale metadata as current.
            // Keep the new OID from porcelain v2 and mark the descriptive
            // fields unavailable until a later retry succeeds.
            lastCommitAt = nil
            lastCommitID = branchMetadata.headOID
            lastCommitSummary = nil
        }

        guard !Task.isCancelled else { return nil }

        // Preview capped at 5
        let preview = Array(changedFiles.prefix(config.changedPreviewLimit)).map {
            ($0 as NSString).lastPathComponent
        }
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

    private static func runGitCommand(
        arguments: [String],
        workingDirectory: String,
        timeout: TimeInterval,
        kind: GitCommandKind,
        metrics: ScanMetricsCollector,
        gitCommandRunner: GitCommandRunner,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> ProcessRunResult {
        let token = metrics.recordGitCommandStart(kind: kind)
        let result = gitCommandRunner(
            arguments,
            workingDirectory,
            timeout,
            ProcessRunner.defaultOutputLimit,
            isCancelled
        )
        metrics.recordGitCommandFinish(token, result: result)
        return result
    }

    private static func statusFailureMessage(_ result: ProcessRunResult) -> String {
        switch result {
        case .timeout:
            return "读取超时"
        case .outputLimit:
            return "状态输出过大"
        case .cancelled:
            return "扫描已取消"
        case .success, .nonZero, .launch, .unavailable:
            return "读取失败"
        }
    }

    private static func appendDiscoveryInterruptionWarning(
        for result: RepositoryDiscoveryResult,
        overallDeadline: Date,
        warnings: inout [String]
    ) {
        guard !result.isComplete else { return }
        warnings.append(incompleteDiscoveryWarning)
        if Task.isCancelled {
            warnings.append("Repository discovery cancelled; partial results were retained.")
        } else if Date() >= overallDeadline {
            warnings.append("Repository discovery timeout reached; partial results were retained.")
        }
    }

    private static func repositoryDiscoveryMode(_ mode: DiscoveryMode) -> RepositoryDiscoveryMode {
        switch mode {
        case .empty: return .empty
        case .reusedKnown: return .reusedKnown
        case .reusedCache: return .reusedCache
        case .walked: return .walked
        case .incomplete: return .incomplete
        }
    }

    private static func logScanSummary(_ metrics: ScanMetrics, kind: String) {
        let successfulGitCommands = max(
            0,
            metrics.gitCommandCount
                - metrics.gitTimeoutCount
                - metrics.gitCancellationCount
                - metrics.gitFailureCount
        )
        let summary = String(
            format: "scan kind=%@ elapsed_ms=%.0f discovery=%@ discovery_ms=%.0f repos=%d reads=%d reused=%d git_total=%d git_status=%d git_log=%d git_success=%d git_timeout=%d git_cancelled=%d git_failure=%d git_peak=%d full_scan_peak=%d",
            kind,
            metrics.elapsed * 1_000,
            discoveryModeName(metrics.discoveryMode),
            metrics.discoveryElapsed * 1_000,
            metrics.discoveredRepositoryCount,
            metrics.repositoryReadCount,
            metrics.reusedRepositorySnapshotCount,
            metrics.gitCommandCount,
            metrics.gitStatusCommandCount,
            metrics.gitLogCommandCount,
            successfulGitCommands,
            metrics.gitTimeoutCount,
            metrics.gitCancellationCount,
            metrics.gitFailureCount,
            metrics.peakConcurrentGitCommandCount,
            metrics.peakConcurrentFullScanCount
        )
        logger.info("\(summary, privacy: .public)")
    }

    private static func discoveryModeName(_ mode: RepositoryDiscoveryMode) -> String {
        switch mode {
        case .empty: return "empty"
        case .reusedKnown: return "reused_known"
        case .reusedCache: return "reused_cache"
        case .walked: return "walked"
        case .incomplete: return "incomplete"
        }
    }

    private static func discoveryCacheKey(for roots: [String], maxDepth: Int) -> String {
        (["rules=\(discoveryRulesVersion)", "maxDepth=\(maxDepth)"] + roots.sorted())
            .joined(separator: "\n")
    }
}

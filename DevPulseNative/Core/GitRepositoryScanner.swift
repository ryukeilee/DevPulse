import Foundation
import OSLog

// MARK: - Scan configuration

struct ScanConfig: Codable, Sendable, Equatable {
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
        maxConcurrentGitOps: 10,
        gitCommandTimeout: 5.0,
        scanTimeout: 60.0,
        slowReposkipSeconds: 600.0,
        activeRepoThreshold: 30
    )

    // MARK: - Value clamping

    /// Clamp maxDepth to valid range.
    private static func clampMaxDepth(_ value: Int) -> Int {
        // Zero is meaningful: inspect only the configured root. Negative
        // values are invalid, while the upper bound prevents corrupted
        // settings from turning discovery into an unbounded walk.
        return min(max(value, 0), 64)
    }

    /// Clamp changedPreviewLimit to valid range.
    private static func clampChangedPreviewLimit(_ value: Int) -> Int {
        // Zero intentionally means that no file preview should be shown.
        return min(max(value, 0), 100)
    }

    /// Clamp maxConcurrentGitOps to valid range.
    private static func clampMaxConcurrentGitOps(_ value: Int) -> Int {
        // The scanner itself caps effective concurrency at ten.
        return min(max(value, 1), 10)
    }

    /// Clamp gitCommandTimeout to a finite, positive, bounded value.
    private static func clampGitCommandTimeout(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return ScanConfig.default.gitCommandTimeout }
        return max(0.1, min(value, 30))
    }

    /// Clamp scanTimeout to a finite, positive, bounded value.
    private static func clampScanTimeout(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return ScanConfig.default.scanTimeout }
        return max(0.1, min(value, 300))
    }

    /// Clamp the deprecated slow-repository setting as well. It is no longer
    /// used for skipping readable repositories, but malformed persisted data
    /// should not leak non-finite values into diagnostics or future migrations.
    private static func clampSlowRepoSkipSeconds(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value >= 0 else { return ScanConfig.default.slowReposkipSeconds }
        return min(value, 86_400)
    }

    /// Clamp activeRepoThreshold to valid range.
    private static func clampActiveRepoThreshold(_ value: Int) -> Int {
        guard value >= 1 else { return 1 }
        return value
    }

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
        self.maxDepth = Self.clampMaxDepth(maxDepth)
        self.changedPreviewLimit = Self.clampChangedPreviewLimit(changedPreviewLimit)
        self.maxConcurrentGitOps = Self.clampMaxConcurrentGitOps(maxConcurrentGitOps)
        self.gitCommandTimeout = Self.clampGitCommandTimeout(gitCommandTimeout)
        self.scanTimeout = Self.clampScanTimeout(scanTimeout)
        self.slowReposkipSeconds = Self.clampSlowRepoSkipSeconds(slowReposkipSeconds)
        self.activeRepoThreshold = Self.clampActiveRepoThreshold(activeRepoThreshold)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ScanConfig.default
        enabledBuiltInPaths = try container.decodeIfPresent(Set<String>.self, forKey: .enabledBuiltInPaths)
            ?? defaults.enabledBuiltInPaths
        customPaths = try container.decodeIfPresent([String].self, forKey: .customPaths)
            ?? defaults.customPaths
        maxDepth = Self.clampMaxDepth(try container.decodeIfPresent(Int.self, forKey: .maxDepth) ?? defaults.maxDepth)
        changedPreviewLimit = Self.clampChangedPreviewLimit(try container.decodeIfPresent(Int.self, forKey: .changedPreviewLimit)
            ?? defaults.changedPreviewLimit)
        maxConcurrentGitOps = Self.clampMaxConcurrentGitOps(try container.decodeIfPresent(Int.self, forKey: .maxConcurrentGitOps)
            ?? defaults.maxConcurrentGitOps)
        gitCommandTimeout = Self.clampGitCommandTimeout(try container.decodeIfPresent(TimeInterval.self, forKey: .gitCommandTimeout)
            ?? defaults.gitCommandTimeout)
        scanTimeout = Self.clampScanTimeout(try container.decodeIfPresent(TimeInterval.self, forKey: .scanTimeout)
            ?? defaults.scanTimeout)
        slowReposkipSeconds = Self.clampSlowRepoSkipSeconds(
            try container.decodeIfPresent(TimeInterval.self, forKey: .slowReposkipSeconds)
                ?? defaults.slowReposkipSeconds
        )
        activeRepoThreshold = Self.clampActiveRepoThreshold(
            try container.decodeIfPresent(Int.self, forKey: .activeRepoThreshold)
                ?? defaults.activeRepoThreshold
        )
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

struct GitWorktreeListRecord: Equatable {
    let path: String
    let isBare: Bool
}

enum GitWorktreeListParser {
    /// Parse `git worktree list --porcelain -z` without inspecting working-tree
    /// files. Newline-delimited porcelain is accepted for focused tests and
    /// compatibility, but production requests NUL-delimited output so paths
    /// containing whitespace remain unambiguous.
    static func parse(_ output: String) -> [GitWorktreeListRecord] {
        let fields: [String]
        if output.contains("\0") {
            fields = output.components(separatedBy: "\0")
        } else {
            fields = output.components(separatedBy: .newlines)
        }

        var records: [GitWorktreeListRecord] = []
        var currentPath: String?
        var currentIsBare = false

        func appendCurrentRecord() {
            guard let currentPath, !currentPath.isEmpty else { return }
            records.append(GitWorktreeListRecord(path: currentPath, isBare: currentIsBare))
        }

        for field in fields {
            if field.hasPrefix("worktree ") {
                appendCurrentRecord()
                currentPath = String(field.dropFirst("worktree ".count))
                currentIsBare = false
            } else if field == "bare" {
                currentIsBare = true
            }
        }
        appendCurrentRecord()
        return records
    }
}

private struct RepositoryDiscoveryResult {
    let readablePaths: [String]
    let unavailablePaths: [String]
    let mode: DiscoveryMode
    let isComplete: Bool
    let workspaceKindsByPath: [String: RepositoryWorkspaceKind]

    init(readablePaths: [String],
         unavailablePaths: [String],
         mode: DiscoveryMode = .walked,
         isComplete: Bool = true,
         workspaceKindsByPath: [String: RepositoryWorkspaceKind] = [:]) {
        self.readablePaths = readablePaths
        self.unavailablePaths = unavailablePaths
        self.mode = mode
        self.isComplete = isComplete
        self.workspaceKindsByPath = workspaceKindsByPath
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

/// Result from a parallel subdirectory walk.
private struct WalkResult: Sendable {
    let discovered: Set<String>
    let unavailablePrefixes: Set<String>
    let warnings: [String]
    let isComplete: Bool

    static func empty() -> WalkResult {
        WalkResult(discovered: [], unavailablePrefixes: [], warnings: [], isComplete: true)
    }

    static func merge(_ results: [WalkResult]) -> WalkResult {
        var discovered = Set<String>()
        var unavailablePrefixes = Set<String>()
        var warnings: [String] = []
        var isComplete = true
        for r in results {
            discovered.formUnion(r.discovered)
            unavailablePrefixes.formUnion(r.unavailablePrefixes)
            warnings.append(contentsOf: r.warnings)
            if !r.isComplete { isComplete = false }
        }
        return WalkResult(
            discovered: discovered,
            unavailablePrefixes: unavailablePrefixes,
            warnings: warnings,
            isComplete: isComplete
        )
    }
}

private struct SnapshotReadResult: Sendable {
    let index: Int
    let snapshot: RepositorySnapshot
    let elapsed: TimeInterval
}

/// Delivers the first result without making the synchronous operation a child
/// of the caller's structured task group. A timed-out FileManager call may
/// remain blocked on an unavailable volume, but it can no longer hold the scan
/// pipeline open or resume the continuation twice.
///
/// Value must be Sendable because finish(_:) crosses task boundaries through
/// the checked continuation. The generic constraint is replicated here so that
/// the Swift 6 compiler can verify the sending transfer through
/// CheckedContinuation.resume(returning:).
final class TimeoutResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFinished = false
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Value) {
        let continuation: CheckedContinuation<Value, Never>?
        lock.lock()
        if hasFinished {
            continuation = nil
        } else {
            hasFinished = true
            continuation = self.continuation
            self.continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: value)
    }
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
    private static let discoveryRulesVersion = 3
    private static let maximumWorktreeDiscoveryBudget: TimeInterval = 5
    private static let worktreeDiscoveryBudgetFraction = 0.2
    // Note: effective concurrency is governed by ScanConfig.maxConcurrentGitOps.
    // This fallback is used only when no config is available (static call paths).
    private static let maximumConcurrentGitOps = 10
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
    static let incompleteWorktreeDiscoveryWarning = "Linked worktree discovery was incomplete; affected worktrees will be retried."

    static func discoveryWasIncomplete(_ warnings: [String]) -> Bool {
        warnings.contains(incompleteDiscoveryWarning)
    }

    // MARK: - Public API

    // MARK: - Discovery-only entry point

    /// Perform repository discovery without running any git status or log
    /// commands. Returns discovered paths, workspace classifications, and
    /// any warnings. The caller is responsible for subsequent status reads.
    static func discoverOnly(
        config: ScanConfig = .default,
        scanRoots: [String]? = nil,
        knownRepositoryPaths: [String]? = nil,
        ignoredRepositoryPaths: Set<String> = [],
        forceRepositoryDiscovery: Bool = false,
        previousSnapshot: AppGroupData? = nil,
        overallDeadline: Date? = nil,
        metrics: ScanMetricsCollector? = nil,
        gitCommandRunner: @escaping GitCommandRunner = defaultGitCommandRunner
    ) async -> (
        readablePaths: [String],
        unavailablePaths: [String],
        workspaceKindsByPath: [String: RepositoryWorkspaceKind],
        allPaths: [String],
        warnings: [String],
        mode: RepositoryDiscoveryMode
    ) {
        let startTime = Date()
        let collector = metrics ?? ScanMetricsCollector()
        let scanToken = collector.beginScan()
        defer {
            collector.endScan(scanToken)
            logScanSummary(collector.snapshot(), kind: "discovery")
        }
        var warnings: [String] = []
        let previous = previousSnapshot ?? (try? AppGroupStore.read().get())
        let previousRepositoryPaths = (previous?.repositories.map(\.path) ?? [])
            + ((previous?.repositoryUnavailableSinceByPath?.keys).map { Array($0) } ?? [])
        var previousWorkspaceKindsByPath: [String: RepositoryWorkspaceKind] = [:]
        for repository in previous?.repositories ?? [] {
            guard let workspaceKind = repository.workspaceKind else { continue }
            previousWorkspaceKindsByPath[
                RepositoryIdentity.canonicalPath(repository.path)
            ] = workspaceKind
        }

        let discoveryStartedAt = ProcessInfo.processInfo.systemUptime
        let discovery = await discoverRepositories(
            config: config,
            scanRoots: scanRoots,
            knownRepositoryPaths: knownRepositoryPaths,
            previousRepositoryPaths: previousRepositoryPaths,
            previousWorkspaceKindsByPath: previousWorkspaceKindsByPath,
            ignoredRepositoryPaths: ignoredRepositoryPaths,
            forceRefresh: forceRepositoryDiscovery,
            overallDeadline: overallDeadline ?? startTime.addingTimeInterval(config.scanTimeout),
            metrics: collector,
            gitCommandRunner: gitCommandRunner,
            warnings: &warnings
        )
        collector.recordDiscovery(
            mode: repositoryDiscoveryMode(discovery.mode),
            elapsed: ProcessInfo.processInfo.systemUptime - discoveryStartedAt,
            discoveredRepositoryCount: discovery.retainedPaths.count
        )

        return (
            readablePaths: discovery.readablePaths,
            unavailablePaths: discovery.unavailablePaths,
            workspaceKindsByPath: discovery.workspaceKindsByPath,
            allPaths: discovery.retainedPaths,
            warnings: warnings,
            mode: repositoryDiscoveryMode(discovery.mode)
        )
    }

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
        var previousWorkspaceKindsByPath: [String: RepositoryWorkspaceKind] = [:]
        for repository in previous?.repositories ?? [] {
            guard let workspaceKind = repository.workspaceKind else { continue }
            previousWorkspaceKindsByPath[
                RepositoryIdentity.canonicalPath(repository.path)
            ] = workspaceKind
        }

        // Phase 1: discover all git repositories
        let discoveryStartedAt = ProcessInfo.processInfo.systemUptime
        let discovery = await discoverRepositories(
            config: config,
            scanRoots: scanRoots,
            knownRepositoryPaths: knownRepositoryPaths,
            previousRepositoryPaths: previousRepositoryPaths,
            previousWorkspaceKindsByPath: previousWorkspaceKindsByPath,
            ignoredRepositoryPaths: ignoredRepositoryPaths,
            forceRefresh: forceRepositoryDiscovery,
            overallDeadline: startTime.addingTimeInterval(config.scanTimeout),
            metrics: collector,
            gitCommandRunner: gitCommandRunner,
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
            workspaceKindsByPath: discovery.workspaceKindsByPath,
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
            historySchemaVersion: previous?.historySchemaVersion,
            historyRecordingEnabled: previous?.historyRecordingEnabled,
            scanSummary: summary,
            repositories: sorted,
            repositoryUnavailableSinceByPath: mergeResult.unavailableSinceByPath.isEmpty
                ? nil
                : mergeResult.unavailableSinceByPath,
            storageRevision: previous?.storageRevision ?? 0,
            persistenceState: .committed,
            pendingItemWidgetSummary: previous?.pendingItemWidgetSummary,
            isRefreshing: previous?.isRefreshing,
            appVersion: previous?.appVersion ?? RepositorySnapshotSchema.currentAppVersion,
            storageFormatVersion: previous?.storageFormatVersion ?? RepositorySnapshotSchema.storageFormatVersion
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
                historySchemaVersion: previousSnapshot?.historySchemaVersion,
                historyRecordingEnabled: previousSnapshot?.historyRecordingEnabled,
                scanSummary: summary,
                repositories: sorted,
                repositoryUnavailableSinceByPath: mergeResult.unavailableSinceByPath.isEmpty
                    ? nil
                    : mergeResult.unavailableSinceByPath,
                storageRevision: previousSnapshot?.storageRevision ?? 0,
                persistenceState: .committed,
                pendingItemWidgetSummary: previousSnapshot?.pendingItemWidgetSummary,
                isRefreshing: previousSnapshot?.isRefreshing,
                appVersion: previousSnapshot?.appVersion ?? RepositorySnapshotSchema.currentAppVersion,
                storageFormatVersion: previousSnapshot?.storageFormatVersion ?? RepositorySnapshotSchema.storageFormatVersion
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
                                             previousWorkspaceKindsByPath: [String: RepositoryWorkspaceKind],
                                             ignoredRepositoryPaths: Set<String>,
                                             forceRefresh: Bool,
                                             overallDeadline: Date,
                                             metrics: ScanMetricsCollector,
                                             gitCommandRunner: @escaping GitCommandRunner,
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
            switch await reusableKnownRepositoryPaths(
                knownCandidates,
                limitedTo: normalizedRoots,
                excluding: ignoredPaths,
                overallDeadline: overallDeadline,
                successMode: .reusedKnown
            ) {
            case .reusable(let reusedPaths):
                let topologyPlan = worktreeInspectionPlan(
                    paths: reusedPaths.readablePaths,
                    previousWorkspaceKindsByPath: previousWorkspaceKindsByPath
                )
                let enriched = await enrichWorktreeDiscovery(
                    reusedPaths,
                    scanRoots: normalizedRoots,
                    ignoredPaths: ignoredPaths,
                    previousWorkspaceKindsByPath: previousWorkspaceKindsByPath,
                    inspectTopology: topologyPlan.requiresInspection,
                    requiresListByPath: topologyPlan.requiresListByPath,
                    config: config,
                    overallDeadline: overallDeadline,
                    metrics: metrics,
                    gitCommandRunner: gitCommandRunner,
                    warnings: &warnings
                )
                if !enriched.isComplete {
                    appendDiscoveryInterruptionWarning(
                        for: enriched,
                        overallDeadline: overallDeadline,
                        warnings: &warnings
                    )
                }
                return enriched
            case .invalidated:
                break
            }
        }

        if forceRefresh {
            await discoveryCache.removeValue(for: cacheKey)
        } else if let cached = await discoveryCache.cachedPaths(for: cacheKey) {
            switch await reusableKnownRepositoryPaths(
                cached,
                limitedTo: normalizedRoots,
                excluding: ignoredPaths,
                overallDeadline: overallDeadline,
                successMode: .reusedCache
            ) {
            case .reusable(let reusableCached):
                let topologyPlan = worktreeInspectionPlan(
                    paths: reusableCached.readablePaths,
                    previousWorkspaceKindsByPath: previousWorkspaceKindsByPath
                )
                let enriched = await enrichWorktreeDiscovery(
                    reusableCached,
                    scanRoots: normalizedRoots,
                    ignoredPaths: ignoredPaths,
                    previousWorkspaceKindsByPath: previousWorkspaceKindsByPath,
                    inspectTopology: topologyPlan.requiresInspection,
                    requiresListByPath: topologyPlan.requiresListByPath,
                    config: config,
                    overallDeadline: overallDeadline,
                    metrics: metrics,
                    gitCommandRunner: gitCommandRunner,
                    warnings: &warnings
                )
                if !enriched.isComplete {
                    appendDiscoveryInterruptionWarning(
                        for: enriched,
                        overallDeadline: overallDeadline,
                        warnings: &warnings
                    )
                }
                return enriched
            case .invalidated:
                break
            }
        }

        for root in normalizedRoots {
            if traversalState.shouldStop(deadline: overallDeadline) { break }
            switch directoryAvailability(at: root) {
            case .repository:
                await walkDirectory(
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

        let unavailablePaths = knownCandidates
            .map(RepositoryIdentity.canonicalPath)
            .filter { path in
                !RepositoryScope.contains(path, in: ignoredPaths)
                    && normalizedRoots.contains { RepositoryIdentity.isSameOrDescendantPath(path, of: $0) }
                    && (!traversalState.isComplete
                        || unavailablePrefixes.contains { RepositoryIdentity.isSameOrDescendantPath(path, of: $0) })
                    && !discovered.contains(path)
            }
        let walked = RepositoryDiscoveryResult(
            readablePaths: Array(discovered).sorted(),
            unavailablePaths: Array(Set(unavailablePaths)).sorted(),
            mode: traversalState.isComplete ? .walked : .incomplete,
            isComplete: traversalState.isComplete
        )
        let enriched = await enrichWorktreeDiscovery(
            walked,
            scanRoots: normalizedRoots,
            ignoredPaths: ignoredPaths,
            previousWorkspaceKindsByPath: previousWorkspaceKindsByPath,
            inspectTopology: true,
            config: config,
            overallDeadline: overallDeadline,
            metrics: metrics,
            gitCommandRunner: gitCommandRunner,
            warnings: &warnings
        )

        if !enriched.isComplete || !unavailablePrefixes.isEmpty {
            if !warnings.contains(incompleteDiscoveryWarning) {
                warnings.append(incompleteDiscoveryWarning)
            }
        }
        if traversalState.timedOut {
            warnings.append("Repository discovery timeout reached; partial results were retained.")
        } else if traversalState.wasCancelled {
            warnings.append("Repository discovery cancelled; partial results were retained.")
        }

        if enriched.readablePaths.isEmpty,
           !allPaths.isEmpty,
           enriched.isComplete,
           unavailablePrefixes.isEmpty {
            warnings.append("No Git repositories discovered in the configured scan roots.")
        }

        if enriched.isComplete && unavailablePrefixes.isEmpty {
            await discoveryCache.store(
                paths: enriched.readablePaths,
                for: cacheKey,
                ttl: discoveryCacheTTL
            )
        }
        return enriched
    }

    /// Per-path worktree-topology inspection plan for one discovery pass.
    ///
    /// `requiresInspection` mirrors the previous gate (any known path that is
    /// not a standalone repository needs the topology loop), while
    /// `requiresListByPath` records the *real* `requiresWorktreeList`
    /// filesystem decision for standalone paths. `enrichWorktreeDiscovery`
    /// reuses those recorded decisions instead of stat'ing the same
    /// repositories twice within a single refresh; paths that are not in the
    /// plan (unknown kinds, ignored seeds) are still checked there exactly as
    /// before.
    private struct WorktreeInspectionPlan {
        let requiresInspection: Bool
        let requiresListByPath: [String: Bool]
    }

    private static func worktreeInspectionPlan(
        paths: [String],
        previousWorkspaceKindsByPath: [String: RepositoryWorkspaceKind]
    ) -> WorktreeInspectionPlan {
        var requiresInspection = false
        var requiresList: [String: Bool] = [:]
        requiresList.reserveCapacity(paths.count)
        for rawPath in paths {
            let path = RepositoryIdentity.canonicalPath(rawPath)
            switch previousWorkspaceKindsByPath[path] {
            case nil, .mainWorktree, .linkedWorktree:
                // Same gate as before: these kinds always warrant entering
                // the topology loop. The per-seed `requiresWorktreeList`
                // check still happens inside `enrichWorktreeDiscovery`,
                // preserving the existing reclassification behavior.
                requiresInspection = true
            case .standalone:
                // Registering the first linked worktree creates Git's
                // worktrees metadata directory. Checking that filesystem bit
                // keeps ordinary repositories at zero extra Git commands
                // while letting the next status refresh discover the new
                // workspace immediately.
                let requiresListForPath = requiresWorktreeList(at: path)
                requiresList[path] = requiresListForPath
                if requiresListForPath {
                    requiresInspection = true
                }
            }
        }
        return WorktreeInspectionPlan(
            requiresInspection: requiresInspection,
            requiresListByPath: requiresList
        )
    }

    private static func enrichWorktreeDiscovery(
        _ discovery: RepositoryDiscoveryResult,
        scanRoots: [String],
        ignoredPaths: Set<String>,
        previousWorkspaceKindsByPath: [String: RepositoryWorkspaceKind],
        inspectTopology: Bool,
        requiresListByPath: [String: Bool]? = nil,
        config: ScanConfig,
        overallDeadline: Date,
        metrics: ScanMetricsCollector,
        gitCommandRunner: @escaping GitCommandRunner,
        warnings: inout [String]
    ) async -> RepositoryDiscoveryResult {
        var readablePaths = Set(discovery.readablePaths.map(RepositoryIdentity.canonicalPath))
        var unavailablePaths = Set(discovery.unavailablePaths.map(RepositoryIdentity.canonicalPath))
        var workspaceKindsByPath: [String: RepositoryWorkspaceKind] = [:]
        for path in readablePaths {
            if let previousKind = previousWorkspaceKindsByPath[path] {
                workspaceKindsByPath[path] = previousKind
            }
        }

        guard inspectTopology else {
            return RepositoryDiscoveryResult(
                readablePaths: Array(readablePaths).sorted(),
                unavailablePaths: Array(unavailablePaths).sorted(),
                mode: discovery.mode,
                isComplete: discovery.isComplete,
                workspaceKindsByPath: workspaceKindsByPath
            )
        }

        let ignoredTopologySeeds = ignoredPaths.filter { path in
            scanRoots.contains { RepositoryIdentity.isSameOrDescendantPath(path, of: $0) }
                && repositoryAvailability(at: path) == .repository
        }
        let seeds = Array(readablePaths.union(ignoredTopologySeeds)).sorted()
        let topologyStartedAt = Date()
        let topologyBudget = min(
            maximumWorktreeDiscoveryBudget,
            max(0, overallDeadline.timeIntervalSince(topologyStartedAt))
                * worktreeDiscoveryBudgetFraction
        )
        let topologyDeadline = min(
            overallDeadline,
            topologyStartedAt.addingTimeInterval(topologyBudget)
        )
        var coveredPaths = Set<String>()
        var topologyIncomplete = false

        for seed in seeds {
            if coveredPaths.contains(seed) { continue }
            guard !Task.isCancelled, Date() < topologyDeadline else {
                topologyIncomplete = true
                break
            }

            // Use the precomputed decision for known readable paths; fall
            // back to a fresh check only for seeds (e.g. ignored topologies)
            // that were not part of the inspection plan.
            let requiresList: Bool
            if let planned = requiresListByPath?[seed] {
                requiresList = planned
            } else {
                requiresList = requiresWorktreeList(at: seed)
            }
            guard requiresList else {
                coveredPaths.insert(seed)
                if !RepositoryScope.contains(seed, in: ignoredPaths) {
                    workspaceKindsByPath[seed] = .standalone
                }
                continue
            }

            let remaining = min(
                config.gitCommandTimeout,
                max(0, topologyDeadline.timeIntervalSinceNow)
            )
            guard remaining > 0 else {
                topologyIncomplete = true
                break
            }

            let result = runGitCommand(
                arguments: ["worktree", "list", "--porcelain", "-z"],
                workingDirectory: seed,
                timeout: remaining,
                kind: .other,
                metrics: metrics,
                gitCommandRunner: gitCommandRunner,
                isCancelled: { Task.isCancelled }
            )
            guard case .success(let output) = result,
                  let topology = parsedWorktreeTopology(output, containing: seed) else {
                topologyIncomplete = true
                continue
            }

            coveredPaths.formUnion(topology.kindsByPath.keys)
            let worktreeCheckTimeout = min(config.gitCommandTimeout, max(0, topologyDeadline.timeIntervalSinceNow))
            for (path, kind) in topology.kindsByPath {
                guard scanRoots.contains(where: {
                    RepositoryIdentity.isSameOrDescendantPath(path, of: $0)
                }),
                !RepositoryScope.contains(path, in: ignoredPaths),
                await checkedAvailability(at: path, timeout: worktreeCheckTimeout) == .repository else { continue }

                readablePaths.insert(path)
                unavailablePaths.remove(path)
                workspaceKindsByPath[path] = kind
            }
        }

        if topologyIncomplete,
           !warnings.contains(incompleteWorktreeDiscoveryWarning) {
            warnings.append(incompleteWorktreeDiscoveryWarning)
        }

        let isComplete = discovery.isComplete && !topologyIncomplete
        return RepositoryDiscoveryResult(
            readablePaths: Array(readablePaths).sorted(),
            unavailablePaths: Array(unavailablePaths.subtracting(readablePaths)).sorted(),
            mode: isComplete ? discovery.mode : .incomplete,
            isComplete: isComplete,
            workspaceKindsByPath: workspaceKindsByPath
        )
    }

    private static func requiresWorktreeList(at repositoryPath: String) -> Bool {
        let gitPath = (repositoryPath as NSString).appendingPathComponent(".git")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: gitPath)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                // Linked worktrees and repositories created with
                // `--separate-git-dir` both use a .git file. Let Git itself
                // distinguish them instead of guessing from file type.
                return true
            }

            let registrationsPath = (gitPath as NSString).appendingPathComponent("worktrees")
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: registrationsPath)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    return true
                }
                return !(try FileManager.default.contentsOfDirectory(atPath: registrationsPath)).isEmpty
            } catch {
                return !isMissingFileError(error)
            }
        } catch {
            return true
        }
    }

    private static func parsedWorktreeTopology(
        _ output: String,
        containing seed: String
    ) -> (kindsByPath: [String: RepositoryWorkspaceKind], mainPath: String?)? {
        let records = GitWorktreeListParser.parse(output)
        guard !records.isEmpty else { return nil }

        var seenPaths = Set<String>()
        var normalized: [GitWorktreeListRecord] = []
        for record in records {
            guard record.path.hasPrefix("/") else { return nil }
            let path = RepositoryIdentity.canonicalPath(record.path)
            guard seenPaths.insert(path).inserted else { continue }
            normalized.append(GitWorktreeListRecord(path: path, isBare: record.isBare))
        }

        let workingTrees = normalized.filter { !$0.isBare }
        let canonicalSeed = RepositoryIdentity.canonicalPath(seed)
        guard workingTrees.contains(where: { $0.path == canonicalSeed }) else { return nil }

        let mainPath = normalized.first?.isBare == false ? normalized.first?.path : nil
        var kindsByPath: [String: RepositoryWorkspaceKind] = [:]
        for record in workingTrees {
            if workingTrees.count == 1, mainPath != nil {
                kindsByPath[record.path] = .standalone
            } else if record.path == mainPath {
                kindsByPath[record.path] = .mainWorktree
            } else {
                kindsByPath[record.path] = .linkedWorktree
            }
        }
        return (kindsByPath, mainPath)
    }

    private static func reusableKnownRepositoryPaths(
        _ knownRepositoryPaths: [String],
        limitedTo scanRoots: [String],
        excluding ignoredPaths: Set<String>,
        overallDeadline: Date,
        successMode: DiscoveryMode
    ) async -> RepositoryReuseAttempt {
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

        // Check every candidate concurrently with a per-path timeout.
        // A single unresponsive mount cannot block the healthy paths.
        let rawPool: TimeInterval = max(0, overallDeadline.timeIntervalSinceNow) / 2.0
        let perPathTimeout: TimeInterval = min(8.0, max(2.0, rawPool))

        let checkResults = await withTaskGroup(
            of: (path: String, availability: RepositoryPathAvailability).self
        ) { group in
            for path in candidates {
                guard !Task.isCancelled, Date() < overallDeadline else { break }
                group.addTask {
                    let availability = await checkedAvailability(
                        at: path,
                        timeout: perPathTimeout
                    )
                    return (path, availability)
                }
            }
            var results: [String: RepositoryPathAvailability] = [:]
            for await entry in group {
                results[entry.path] = entry.availability
            }
            return results
        }

        var readable: [String] = []
        var unavailable: [String] = []
        for path in candidates {
            switch checkResults[path] ?? .unavailable {
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
                                      warnings: inout [String]) async {
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
        let readTimeout: TimeInterval = min(
            config.gitCommandTimeout,
            max(1.0, overallDeadline.timeIntervalSinceNow / 2.0)
        )
        let (entries, isUnavailable) = await readDirectoryContents(
            at: directoryURL,
            timeout: readTimeout
        )

        guard let entries else {
            if isUnavailable {
                unavailablePrefixes.insert(directory)
                traversalState.markUnavailable()
                warnings.append("Repository directory unavailable: \(directory)")
            }
            return
        }

        // Collect subdirectories first, then walk them in parallel.
        var subdirectories: [String] = []
        for entryURL in entries {
            if Date() >= overallDeadline || Task.isCancelled { break }
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
            subdirectories.append(fullPath)
        }

        if !subdirectories.isEmpty {
            let results = await withTaskGroup(of: WalkResult.self) { group in
                for subdir in subdirectories {
                    group.addTask {
                        var localDiscovered = Set<String>()
                        var localUnavailable = Set<String>()
                        var localWarnings: [String] = []
                        var localTraversal = DiscoveryTraversalState()

                        await walkDirectory(subdir,
                                            config: config,
                                            depth: depth + 1,
                                            ignoredPaths: ignoredPaths,
                                            discovered: &localDiscovered,
                                            unavailablePrefixes: &localUnavailable,
                                            overallDeadline: overallDeadline,
                                            traversalState: &localTraversal,
                                            warnings: &localWarnings)

                        return WalkResult(
                            discovered: localDiscovered,
                            unavailablePrefixes: localUnavailable,
                            warnings: localWarnings,
                            isComplete: !localTraversal.wasCancelled && !localTraversal.timedOut
                        )
                    }
                }

                var merged = WalkResult.empty()
                for await result in group {
                    merged = WalkResult(
                        discovered: merged.discovered.union(result.discovered),
                        unavailablePrefixes: merged.unavailablePrefixes.union(result.unavailablePrefixes),
                        warnings: merged.warnings + result.warnings,
                        isComplete: merged.isComplete && result.isComplete
                    )
                }
                return merged
            }

            discovered.formUnion(results.discovered)
            unavailablePrefixes.formUnion(results.unavailablePrefixes)
            warnings.append(contentsOf: results.warnings)
            if !results.isComplete {
                traversalState.markUnavailable()
            }
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

    /// Fast filesystem-level check to determine whether a git repository's
    /// state has likely changed since the last scan.
    ///
    /// Checks the modification timestamps of `.git/HEAD` and `.git/index`.
    /// If both are older than `lastSuccessfulScanAt`, the repo is treated as
    /// unchanged and the `previousSnapshot` can be reused directly, avoiding
    /// an expensive `git status` call.
    ///
    /// Returns `true` when the repo can be skipped (no git commands needed).
    /// Returns `false` when changes are detected OR when the fast check
    /// cannot be performed (missing timestamps, unparseable dates, etc.)
    /// — in that case the caller should fall through to `git status`.
    static func repositoryCanSkipGitStatus(
        at repoPath: String,
        lastSuccessfulScanAt lastScanAt: String?,
        previousSnapshot: RepositorySnapshot?
    ) -> Bool {
        // Without a previous successful scan we must re-read.
        // Only skip repos that were previously .clean — repos with .changed status
        // might have had their working tree resolved without touching HEAD/index.
        guard let lastScanAt,
              let lastScanDate = DateFormatting.date(from: lastScanAt),
              let previousSnapshot,
              previousSnapshot.lastSuccessfulScanAt != nil,
              previousSnapshot.resolvedDataSource == .current,
              previousSnapshot.status == .clean else {
            return false
        }

        let repoURL = URL(fileURLWithPath: repoPath)
        let gitDirURL: URL

        // Determine the actual .git location (plain dir or worktree gitfile).
        let dotGitURL = repoURL.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: dotGitURL.path) {
            gitDirURL = dotGitURL
        } else {
            // Could be a worktree with a .git file; fall through to git status.
            return false
        }

        do {
            // Check HEAD modification time.
            let headURL = gitDirURL.appendingPathComponent("HEAD")
            guard let headAttrs = try? FileManager.default.attributesOfItem(atPath: headURL.path),
                  let headModDate = headAttrs[.modificationDate] as? Date else {
                return false
            }

            // If HEAD changed at or after the last scan, we must re-read.
            // Strict '<' ensures same-instant HEAD updates are not skipped.
            guard headModDate < lastScanDate else {
                return false
            }

            // Check index modification time (tracks working tree changes).
            let indexURL = gitDirURL.appendingPathComponent("index")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                guard let indexAttrs = try? FileManager.default.attributesOfItem(atPath: indexURL.path),
                      let indexModDate = indexAttrs[.modificationDate] as? Date else {
                    return false
                }
                guard indexModDate < lastScanDate else {
                    return false
                }
            }

            // HEAD and index both unchanged since last successful scan — safe to skip.
            return true
        } catch {
            return false
        }
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError)
    }

    // MARK: - Availability helpers with timeout

    /// Check whether a path contains a Git repository, with a per-call timeout
    /// so a single unresponsive filesystem mount cannot block the scan.
    /// Returns `.unavailable` when the check does not complete within `timeout`.
    private static func checkedAvailability(
        at path: String,
        timeout: TimeInterval
    ) async -> RepositoryPathAvailability {
        await runWithTimeout(
            timeout: timeout,
            operation: { repositoryAvailability(at: path) },
            timeoutValue: .unavailable
        )
    }

    /// Read directory entries with a timeout. FileManager operations are
    /// synchronous and do not observe Swift task cancellation. Running the
    /// operation in an unstructured utility task lets the caller return at
    /// the deadline even when a disconnected volume is stuck in the kernel.
    private static func readDirectoryContents(
        at url: URL,
        timeout: TimeInterval
    ) async -> (entries: [URL]?, isUnavailable: Bool) {
        await runWithTimeout(
            timeout: timeout,
            operation: {
                do {
                    let entries = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsPackageDescendants]
                    )
                    return (entries: entries, isUnavailable: false)
                } catch {
                    return (entries: nil, isUnavailable: !isMissingFileError(error))
                }
            },
            timeoutValue: (entries: nil, isUnavailable: true)
        )
    }

    private static func runWithTimeout<Value: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () -> Value,
        timeoutValue: Value
    ) async -> Value {
        guard timeout.isFinite, timeout > 0 else { return timeoutValue }
        guard !Task.isCancelled else { return timeoutValue }

        let nanoseconds = UInt64(
            min(timeout, TimeInterval(UInt64.max) / 1_000_000_000)
                * 1_000_000_000
        )
        return await withCheckedContinuation { continuation in
            let race = TimeoutResultBox(continuation)
            let timeoutTask = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: nanoseconds)
                race.finish(timeoutValue)
            }
            Task.detached(priority: .utility) {
                race.finish(operation())
                // Cancel the timeout task so it does not keep a process alive
                // after the operation has already produced a result.
                timeoutTask.cancel()
            }
        }
    }

    // MARK: - Batched snapshot reading

    /// Read git status in batches to limit concurrent git processes.
    /// Uses filesystem-level fast checks to skip unchanged repositories.
    private static func readSnapshotsBatched(paths: [String],
                                             config: ScanConfig,
                                             warnings: inout [String],
                                             overallDeadline: Date,
                                             previousSnapshots: [RepositorySnapshot],
                                             previousUnavailableSinceByPath: [String: String],
                                             workspaceKindsByPath: [String: RepositoryWorkspaceKind],
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
        // Use config value directly; static fallback only applies when config
        // is unavailable (static call paths that bypass RefreshEngine).
        let concurrency = max(1, min(config.maxConcurrentGitOps, maximumConcurrentGitOps))
        var nextIndex = 0
        var timedOut = false
        var cancelled = false

        // Pre-scan: identify repos where filesystem state is clearly unchanged
        // so we can skip git commands entirely.
        var skipIndexes = Set<Int>()
        for (index, path) in indexedPaths {
            let canonicalPath = RepositoryIdentity.canonicalPath(path)
            if let previousSnapshot = previousByPath[canonicalPath],
               repositoryCanSkipGitStatus(
                   at: canonicalPath,
                   lastSuccessfulScanAt: previousSnapshot.lastSuccessfulScanAt,
                   previousSnapshot: previousSnapshot
               ) {
                skipIndexes.insert(index)
                metrics.recordRepositorySkipped()
            }
        }

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
                let workspaceKind = workspaceKindsByPath[canonicalPath]
                    ?? previousSnapshot?.workspaceKind
                nextIndex += 1

                // Fast skip: if filesystem indicates no change, reuse previous snapshot.
                if skipIndexes.contains(originalIndex),
                   let previous = previousSnapshot {
                    // Preserve .current dataSource since the repo is genuinely
                    // unchanged — the fast filesystem check proves it.
                    let retained = RepositorySnapshot(
                        id: previous.id, name: previous.name, path: canonicalPath,
                        workspaceKind: workspaceKind ?? previous.workspaceKind,
                        branch: previous.branch, status: previous.status,
                        modifiedFileCount: previous.modifiedFileCount,
                        addedFileCount: previous.addedFileCount,
                        deletedFileCount: previous.deletedFileCount,
                        untrackedFileCount: previous.untrackedFileCount,
                        stagedFileCount: previous.stagedFileCount,
                        unstagedFileCount: previous.unstagedFileCount,
                        conflictedFileCount: previous.conflictedFileCount,
                        aheadCount: previous.aheadCount, behindCount: previous.behindCount,
                        hasUpstream: previous.hasUpstream,
                        changedFileCount: previous.changedFileCount,
                        changedFilesPreview: previous.changedFilesPreview,
                        risk: previous.risk,
                        lastScannedAt: previous.lastScannedAt,
                        dataSource: .current,
                        lastSuccessfulScanAt: previous.lastSuccessfulScanAt,
                        lastChangedAt: previous.lastChangedAt,
                        lastCommitID: previous.lastCommitID,
                        lastCommitSummary: previous.lastCommitSummary,
                        lastCommitMetadataAvailable: previous.lastCommitMetadataAvailable,
                        lastActivityAt: previous.lastActivityAt,
                        errorMessage: nil,
                        isPinned: previous.isPinned
                    )
                    resultsByIndex[originalIndex] = SnapshotReadResult(
                        index: originalIndex, snapshot: retained, elapsed: 0
                    )
                    return
                }

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
                        workspaceKind: workspaceKind,
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

            // yieldCounter periodically suspends to keep the UI responsive
            // during large scans. We yield every 8 completed results.
            var yieldCounter = 0
            while let result = await group.next() {
                if let result {
                    resultsByIndex[result.index] = result
                }

                yieldCounter += 1
                if yieldCounter % 8 == 0 {
                    await Task.yield()
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
                    workspaceKind: workspaceKindsByPath[
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
                                           workspaceKind: RepositoryWorkspaceKind? = nil,
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
                workspaceKind: workspaceKind,
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
            workspaceKind: workspaceKind ?? previousSnapshot?.workspaceKind,
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
                                       workspaceKind: RepositoryWorkspaceKind? = nil,
                                       errorMessage: String) -> RepositorySnapshot {
        let path = RepositoryIdentity.canonicalPath(path)
        let previous = previousSnapshot.map(RepositoryIdentity.normalize)
        let attemptedAt = DateFormatting.nowISO()
        if let previous {
            return previous.retainingLastSuccessfulData(
                attemptedAt: attemptedAt,
                errorMessage: errorMessage,
                unavailableSince: unavailableSince,
                workspaceKind: workspaceKind
            )
        }
        return RepositorySnapshot(
            id: RepositoryIdentity.id(for: path),
            name: (path as NSString).lastPathComponent,
            path: path,
            workspaceKind: workspaceKind,
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
                workspaceKind: discovery.workspaceKindsByPath[normalizedPath],
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

            if RepositoryRetentionPolicy.shouldRetain(snapshot) {
                let firstUnavailableAt = snapshot.unavailableSince
                    ?? unavailableSinceByPath[normalizedPath]
                    ?? snapshot.lastScannedAt
                retainedUnavailability[normalizedPath] = firstUnavailableAt
                retainedSnapshots.append(snapshot)
            }
            // When shouldRetain returns false the snapshot AND its
            // unavailableSince are dropped. This breaks the infinite tracking
            // loop for repos that never had a successful scan while avoiding
            // silent data loss — previously-known repos are always retained
            // (see RepositoryRetentionPolicy.shouldRetain).
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
        case .nonZero:
            return "Git 命令异常退出"
        case .launch:
            return "无法启动 Git 进程"
        case .unavailable:
            return "Git 可执行文件不可用"
        case .success:
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
            format: "scan kind=%@ elapsed_ms=%.0f discovery=%@ discovery_ms=%.0f repos=%d reads=%d skipped=%d reused=%d git_total=%d git_status=%d git_log=%d git_success=%d git_timeout=%d git_cancelled=%d git_failure=%d git_peak=%d full_scan_peak=%d",
            kind,
            metrics.elapsed * 1_000,
            discoveryModeName(metrics.discoveryMode),
            metrics.discoveryElapsed * 1_000,
            metrics.discoveredRepositoryCount,
            metrics.repositoryReadCount,
            metrics.repositorySkippedCount,
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

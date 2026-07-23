import Foundation
import OSLog
import os.lock

// MARK: - Refresh engine

/// Unified refresh engine that wraps the existing scanner with:
/// - Explicit pipeline stage progress (published for UI)
/// - Priority scheduling (fast/important repos first)
/// - Enhanced cancellation with generation isolation
/// - Per-stage diagnostics
///
/// Stages:
///   discovery → coreStatus → extendedInfo → merge → persistence → widgetSync
actor RefreshEngine {
    typealias GitCommandRunner = @Sendable (
        _ arguments: [String],
        _ workingDirectory: String,
        _ timeout: TimeInterval,
        _ outputLimit: Int,
        _ isCancelled: @escaping @Sendable () -> Bool
    ) -> ProcessRunResult

    // MARK: - Progress publisher

    private let progressContinuation: AsyncStream<RefreshProgress>.Continuation
    let progress: AsyncStream<RefreshProgress>

    // MARK: - Private state

    private var generation: UInt64 = 0
    private let cancelledLock = OSAllocatedUnfairLock(initialState: false)
    private var _isCancelled: Bool {
        get { cancelledLock.withLock { $0 } }
        set { cancelledLock.withLock { $0 = newValue } }
    }
    private let logger = Logger(subsystem: "local.devpulse.app", category: "RefreshEngine")

    init() {
        var continuation: AsyncStream<RefreshProgress>.Continuation!
        progress = AsyncStream { continuation = $0 }
        progressContinuation = continuation
    }

    deinit {
        progressContinuation.finish()
    }

    /// Stage time budget fractions as a proportion of the overall scan timeout.
    static let stageBudgetFractions: [RefreshPipelineStage: Double] = [
        .discovery: 0.25,
        .coreStatus: 0.40,
        .extendedInfo: 0.20,
        .merge: 0.05,
        .persistence: 0.05,
        .widgetSync: 0.05
    ]

    /// Cancel the current refresh. In-flight work completes cooperatively
    /// but the returned result will be marked as cancelled.
    func cancel() {
        cancelledLock.withLock { $0 = true }
    }

    nonisolated var isCancelled: Bool {
        cancelledLock.withLock { $0 }
    }

    // MARK: - Execute

    /// Run a full refresh with stage progress.
    /// Returns best-effort results even if cancelled or timed out.
    func execute(
        config: ScanConfig,
        scanRoots: [String],
        knownRepositoryPaths: [String]? = nil,
        ignoredRepositoryPaths: Set<String> = [],
        forceRepositoryDiscovery: Bool,
        previousSnapshot: AppGroupData? = nil,
        source: ScanRefreshSource = .manual,
        gitCommandRunner: @escaping GitCommandRunner = GitRepositoryScanner.defaultGitCommandRunner
    ) async -> RefreshResult {
        generation &+= 1
        let currentGeneration = generation
        _isCancelled = false
        let overallStart = ProcessInfo.processInfo.systemUptime
        let overallDeadline = overallStart + config.scanTimeout
        let isFastFirst = source == .manual || source == .configuration

        var warnings: [String] = []

        // ── Stage 1: Discovery ───────────────────────────────────────────
        let stage1Start = ProcessInfo.processInfo.systemUptime
        logger.debug("Stage .discovery starting")
        let stage1Budget = overallDeadline - stage1Start
        let stage1Slice = stage1Budget * Self.stageBudgetFractions[.discovery]!
        let stage1Deadline = stage1Start + stage1Slice
        let discoveryResult = await performDiscovery(
            config: config,
            scanRoots: scanRoots,
            knownRepositoryPaths: knownRepositoryPaths,
            ignoredRepositoryPaths: ignoredRepositoryPaths,
            forceRepositoryDiscovery: forceRepositoryDiscovery,
            previousSnapshot: previousSnapshot,
            overallDeadline: stage1Deadline,
            warnings: &warnings
        )
        let discoveryElapsed = ProcessInfo.processInfo.systemUptime - stage1Start
        let discoveryBudgetExhausted = discoveryElapsed > stage1Slice
        logger.debug("Stage .discovery finished elapsed_ms=\(Int(discoveryElapsed * 1000)) exhausted=\(discoveryBudgetExhausted)")

        publishProgress(stage: .discovery, total: discoveryResult.allPaths.count,
                        completed: discoveryResult.readablePaths.count,
                        elapsed: discoveryElapsed, finished: true, startedAt: overallStart)

        guard !isInvalidated(currentGeneration) else {
            return buildCancelled(previous: previousSnapshot, discoveredPaths: discoveryResult.allPaths)
        }

        // ── Stage 2: Core status (git status, priority-ordered) ──────────
        let stage2Start = ProcessInfo.processInfo.systemUptime
        logger.debug("Stage .coreStatus starting")
        let stage2Budget = overallDeadline - stage2Start
        let stage2Slice = stage2Budget * Self.stageBudgetFractions[.coreStatus]!
        let stage2Deadline = stage2Start + stage2Slice
        let coreResult = await readCoreStatusPriorityBatched(
            paths: isFastFirst
                ? prioritizePaths(discoveryResult.readablePaths, previous: previousSnapshot)
                : discoveryResult.readablePaths.map { PrioritizedRepository(path: $0) },
            config: config,
            previousSnapshot: previousSnapshot,
            workspaceKindsByPath: discoveryResult.workspaceKindsByPath,
            overallDeadline: stage2Deadline,
            generation: currentGeneration,
            gitCommandRunner: gitCommandRunner,
            warnings: &warnings
        )
        let coreElapsed = ProcessInfo.processInfo.systemUptime - stage2Start
        let coreBudgetExhausted = coreElapsed > stage2Slice
        logger.debug("Stage .coreStatus finished elapsed_ms=\(Int(coreElapsed * 1000)) exhausted=\(coreBudgetExhausted)")

        publishProgress(stage: .coreStatus, total: coreResult.total,
                        completed: coreResult.completed, elapsed: coreElapsed,
                        finished: true, startedAt: overallStart)

        guard !isInvalidated(currentGeneration) else {
            return buildPartialCancelled(
                discovery: discoveryResult,
                coreSnapshots: coreResult.snapshots,
                previous: previousSnapshot,
                warnings: &warnings
            )
        }

        // ── Stage 3: Extended info (git log for changed HEADs) ───────────
        let stage3Start = ProcessInfo.processInfo.systemUptime
        logger.debug("Stage .extendedInfo starting")
        let stage3Budget = overallDeadline - stage3Start
        let stage3Slice = stage3Budget * Self.stageBudgetFractions[.extendedInfo]!
        let stage3Deadline = stage3Start + stage3Slice
        let extendedResult = await readExtendedInfo(
            coreResult: coreResult,
            config: config,
            previousSnapshot: previousSnapshot,
            overallDeadline: stage3Deadline,
            generation: currentGeneration,
            gitCommandRunner: gitCommandRunner,
            warnings: &warnings
        )
        let extendedElapsed = ProcessInfo.processInfo.systemUptime - stage3Start
        let extendedBudgetExhausted = extendedElapsed > stage3Slice
        logger.debug("Stage .extendedInfo finished elapsed_ms=\(Int(extendedElapsed * 1000)) exhausted=\(extendedBudgetExhausted)")

        publishProgress(stage: .extendedInfo, total: extendedResult.total,
                        completed: extendedResult.completed, elapsed: extendedElapsed,
                        finished: true, startedAt: overallStart)

        // ── Stage 4: Merge ───────────────────────────────────────────────
        let stage4Start = ProcessInfo.processInfo.systemUptime
        logger.debug("Stage .merge starting")
        let stage4Budget = overallDeadline - stage4Start
        let stage4Slice = stage4Budget * Self.stageBudgetFractions[.merge]!
        let mergeResult = mergeResults(
            discovery: discoveryResult,
            coreSnapshots: extendedResult.snapshots.count > 0 ? extendedResult.snapshots : coreResult.snapshots,
            previousSnapshot: previousSnapshot
        )
        let sorted = RepositorySorter.sort(mergeResult.snapshots)
        let mergeElapsed = ProcessInfo.processInfo.systemUptime - stage4Start
        let mergeBudgetExhausted = mergeElapsed > stage4Slice
        logger.debug("Stage .merge finished elapsed_ms=\(Int(mergeElapsed * 1000)) exhausted=\(mergeBudgetExhausted)")

        let summary = ScanSummary.build(from: sorted, totalRepositories: sorted.count)
        let mergedData = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: DateFormatting.nowISO(),
            writtenAt: nil,
            lastSuccessfulRefreshAt: previousSnapshot?.lastSuccessfulRefreshAt,
            scanSummary: summary,
            repositories: sorted,
            repositoryUnavailableSinceByPath: mergeResult.unavailableSinceByPath.isEmpty
                ? nil : mergeResult.unavailableSinceByPath,
            storageRevision: previousSnapshot?.storageRevision ?? 0,
            persistenceState: .committed
        )
        let retainedPaths = Array(Set(
            sorted.map { $0.path } + Array(mergeResult.unavailableSinceByPath.keys)
        )).sorted()

        publishProgress(stage: .merge, total: sorted.count, completed: sorted.count,
                        elapsed: mergeElapsed, finished: true, startedAt: overallStart)

        // ── Stage 5: Persistence ─────────────────────────────────────────
        let stage5Start = ProcessInfo.processInfo.systemUptime
        logger.debug("Stage .persistence starting")
        let persistedData = mergedData.withWrittenAt(DateFormatting.nowISO())
        var persistError: String?
        switch AppGroupStore.write(persistedData) {
        case .success: break
        case .failure(let error):
            persistError = error.localizedDescription
            warnings.append("共享快照写入失败: \(persistError ?? "unknown")")
        }
        let persistElapsed = ProcessInfo.processInfo.systemUptime - stage5Start
        logger.debug("Stage .persistence finished elapsed_ms=\(Int(persistElapsed * 1000)) error=\(persistError ?? "nil")")

        publishProgress(stage: .persistence, total: 1, completed: persistError == nil ? 1 : 0,
                        elapsed: persistElapsed, finished: true, startedAt: overallStart)

        // ── Stage 6: Widget sync ─────────────────────────────────────────
        // Widget reload is handled by ScanScheduler.syncSharedSnapshot() to
        // avoid duplicate calls (the scheduler already decides whether changed
        // data warrants a reload). Stage 6 remains as a lightweight diagnostic
        // marker so the pipeline accounting stays consistent.
        let stage6Start = ProcessInfo.processInfo.systemUptime
        logger.debug("Stage .widgetSync starting (deferred to scheduler)")
        let widgetElapsed = ProcessInfo.processInfo.systemUptime - stage6Start
        logger.debug("Stage .widgetSync finished elapsed_ms=\(Int(widgetElapsed * 1000))")

        publishProgress(stage: .widgetSync, total: 1, completed: 1,
                        elapsed: widgetElapsed, finished: true, startedAt: overallStart)

        progressContinuation.finish()

        let totalElapsed = ProcessInfo.processInfo.systemUptime - overallStart
        logSummary(totalElapsed: totalElapsed, discovery: discoveryResult,
                   coreCount: coreResult.completed, warnings: warnings)

        let stageDurations: [RefreshPipelineStage: TimeInterval] = [
            .discovery: discoveryElapsed,
            .coreStatus: coreElapsed,
            .extendedInfo: extendedElapsed,
            .merge: mergeElapsed,
            .persistence: persistElapsed,
            .widgetSync: widgetElapsed
        ]

        let timeBudgetExhaustedByStage: [RefreshPipelineStage: Bool] = [
            .discovery: discoveryBudgetExhausted,
            .coreStatus: coreBudgetExhausted,
            .extendedInfo: extendedBudgetExhausted,
            .merge: mergeBudgetExhausted
        ]
        let diagnostics = Self.buildDiagnostics(
            from: RefreshResult(
                data: persistedData,
                warnings: warnings,
                discoveredRepositoryPaths: retainedPaths,
                stageDurations: stageDurations,
                isCancelled: false,
                timedOut: false,
                diagnostics: RefreshDiagnostics(
                    overallElapsed: totalElapsed,
                    discoveryElapsed: discoveryElapsed,
                    coreStatusElapsed: coreElapsed,
                    extendedInfoElapsed: extendedElapsed,
                    mergeElapsed: mergeElapsed,
                    persistenceElapsed: persistElapsed,
                    widgetSyncElapsed: widgetElapsed,
                    totalGitCalls: coreResult.gitStatusCount + extendedResult.completed,
                    totalGitTimeouts: coreResult.gitTimeoutCount,
                    totalGitCancellations: coreResult.gitCancelledCount,
                    totalGitFailures: coreResult.gitFailureCount,
                    totalRepositoryCount: sorted.count,
                    currentRepositoryCount: sorted.filter { $0.resolvedDataSource == .current }.count,
                    reusedSnapshotCount: extendedResult.reusedMetadataCount,
                    snapshotReuseRatio: sorted.count > 0
                        ? Double(extendedResult.reusedMetadataCount) / Double(sorted.count) : 0,
                    peakGitConcurrency: coreResult.peakConcurrency,
                    cancelled: false,
                    timedOut: false,
                    stageDiagnostics: []
                )
            ),
            overallElapsed: totalElapsed,
            overallTimedOut: false,
            totalRepositoryCount: sorted.count,
            currentRepositoryCount: sorted.filter { $0.resolvedDataSource == .current }.count,
            reusedSnapshotCount: extendedResult.reusedMetadataCount,
            repositoryRetryCount: 0,
            coreMetrics: coreResult,
            extendedMetrics: extendedResult,
            timeBudgetExhaustedByStage: timeBudgetExhaustedByStage,
            persistError: persistError,
            widgetSyncError: nil
        )

        return RefreshResult(
            data: persistedData,
            warnings: warnings,
            discoveredRepositoryPaths: retainedPaths,
            stageDurations: stageDurations,
            isCancelled: false,
            timedOut: false,
            diagnostics: diagnostics
        )
    }
}

// MARK: - Results

struct RefreshResult: Sendable {
    let data: AppGroupData
    let warnings: [String]
    let discoveredRepositoryPaths: [String]
    let stageDurations: [RefreshPipelineStage: TimeInterval]
    let isCancelled: Bool
    let timedOut: Bool
    let diagnostics: RefreshDiagnostics
}

struct DiscoveredRepositories: Sendable {
    let readablePaths: [String]
    let unavailablePaths: [String]
    let allPaths: [String]
    let workspaceKindsByPath: [String: RepositoryWorkspaceKind]
    let isComplete: Bool
}

struct CoreReadResult: Sendable {
    let snapshots: [RepositorySnapshot]  // in original path order
    let completed: Int
    let total: Int
    let gitStatusCount: Int
    let gitTimeoutCount: Int
    let gitCancelledCount: Int
    let gitFailureCount: Int
    let peakConcurrency: Int
}

struct ExtendedReadResult: Sendable {
    let snapshots: [RepositorySnapshot]
    let completed: Int
    let total: Int
    let reusedMetadataCount: Int
}

// MARK: - Stage 1: Discovery

extension RefreshEngine {
    private func performDiscovery(
        config: ScanConfig,
        scanRoots: [String],
        knownRepositoryPaths: [String]?,
        ignoredRepositoryPaths: Set<String>,
        forceRepositoryDiscovery: Bool,
        previousSnapshot: AppGroupData?,
        overallDeadline: TimeInterval,
        warnings: inout [String]
    ) async -> DiscoveredRepositories {
        let result = await GitRepositoryScanner.discoverOnly(
            config: config,
            scanRoots: scanRoots,
            knownRepositoryPaths: knownRepositoryPaths,
            ignoredRepositoryPaths: ignoredRepositoryPaths,
            forceRepositoryDiscovery: forceRepositoryDiscovery,
            previousSnapshot: previousSnapshot
        )

        // Build workspace kinds map from the discovery result
        var workspaceKindsByPath = result.workspaceKindsByPath

        // Check for incomplete discovery
        let isComplete = !result.warnings.contains(GitRepositoryScanner.incompleteDiscoveryWarning)
            && !result.warnings.contains(GitRepositoryScanner.incompleteWorktreeDiscoveryWarning)

        warnings.append(contentsOf: result.warnings)

        return DiscoveredRepositories(
            readablePaths: result.readablePaths,
            unavailablePaths: result.unavailablePaths,
            allPaths: result.allPaths,
            workspaceKindsByPath: workspaceKindsByPath,
            isComplete: isComplete
        )
    }
}

// MARK: - Stage 2: Core status with priority batching

extension RefreshEngine {
    private func readCoreStatusPriorityBatched(
        paths: [PrioritizedRepository],
        config: ScanConfig,
        previousSnapshot: AppGroupData?,
        workspaceKindsByPath: [String: RepositoryWorkspaceKind],
        overallDeadline: TimeInterval,
        generation: UInt64,
        gitCommandRunner: @escaping GitCommandRunner,
        warnings: inout [String]
    ) async -> CoreReadResult {
        guard !paths.isEmpty else {
            return CoreReadResult(snapshots: [], completed: 0, total: 0,
                                  gitStatusCount: 0, gitTimeoutCount: 0,
                                  gitCancelledCount: 0, gitFailureCount: 0,
                                  peakConcurrency: 0)
        }

        let previousByPath = indexPreviousSnapshots(previousSnapshot)
        let previousUnavailableSinceByPath = previousSnapshot?.repositoryUnavailableSinceByPath ?? [:]
        let concurrency = min(config.maxConcurrentGitOps, paths.count)
        var snapshotsByIndex: [Int: RepositorySnapshot] = [:]
        var counters = (status: 0, timeout: 0, cancelled: 0, failed: 0, peak: 0)

        // Process in priority order but with bounded concurrency
        await withTaskGroup(of: (Int, ProcessReadResult?).self) { group in
            var nextIdx = 0
            var pendingCount = 0

            func submit() {
                guard nextIdx < paths.count else { return }
                let idx = nextIdx
                let entry = paths[idx]
                nextIdx += 1
                pendingCount += 1

                group.addTask {
                    guard !Task.isCancelled, !self.isCancelled else { return (idx, nil) }
                    let remaining = overallDeadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { return (idx, nil) }

                    let canonical = RepositoryIdentity.canonicalPath(entry.path)
                    let previous = previousByPath[canonical]
                    let unavailableSince = previousUnavailableSinceByPath[canonical]
                    let workspaceKind = workspaceKindsByPath[canonical] ?? previous?.workspaceKind
                    let timeout = min(config.gitCommandTimeout, max(0.5, remaining))

                    let result = gitCommandRunner(
                        ["status", "--porcelain=v2", "--branch"],
                        canonical, timeout,
                        ProcessRunner.defaultOutputLimit,
                        { self.isCancelled || Task.isCancelled }
                    )

                    return (idx, ProcessReadResult(
                        result: result,
                        path: canonical,
                        previous: previous,
                        unavailableSince: unavailableSince,
                        workspaceKind: workspaceKind
                    ))
                }
            }

            for _ in 0..<min(concurrency, paths.count) { submit() }

            while let (idx, read) = await group.next() {
                pendingCount -= 1
                counters.peak = max(counters.peak, pendingCount + 1)
                defer { submit() }

                if let read {
                    switch read.result {
                    case .success(let output):
                        let snapshot = buildSnapshot(output: output, read: read,
                                                      scannedAt: DateFormatting.nowISO())
                        snapshotsByIndex[idx] = snapshot
                        counters.status += 1

                    case .timeout:
                        counters.timeout += 1
                        snapshotsByIndex[idx] = buildFailedSnapshot(read: read, error: "读取超时")

                    case .cancelled:
                        counters.cancelled += 1
                        snapshotsByIndex[idx] = buildFailedSnapshot(read: read, error: "扫描已取消")

                    case .nonZero, .launch, .unavailable, .outputLimit:
                        counters.failed += 1
                        snapshotsByIndex[idx] = buildFailedSnapshot(read: read, error: "读取失败")
                    }
                }

                if isCancelled || Task.isCancelled || ProcessInfo.processInfo.systemUptime >= overallDeadline {
                    group.cancelAll()
                    break
                }
            }
        }

        // Produce snapshots in original priority order, filling gaps with failed snapshots
        var orderedSnapshots: [RepositorySnapshot] = []
        for idx in paths.indices {
            if let snapshot = snapshotsByIndex[idx] {
                orderedSnapshots.append(snapshot)
            }
        }

        return CoreReadResult(
            snapshots: orderedSnapshots,
            completed: snapshotsByIndex.count,
            total: paths.count,
            gitStatusCount: counters.status + counters.timeout + counters.failed,
            gitTimeoutCount: counters.timeout,
            gitCancelledCount: counters.cancelled,
            gitFailureCount: counters.failed,
            peakConcurrency: counters.peak
        )
    }

    private struct ProcessReadResult {
        let result: ProcessRunResult
        let path: String
        let previous: RepositorySnapshot?
        let unavailableSince: String?
        let workspaceKind: RepositoryWorkspaceKind?
    }

    private func buildSnapshot(
        output: String,
        read: ProcessReadResult,
        scannedAt: String
    ) -> RepositorySnapshot {
        let name = (read.path as NSString).lastPathComponent
        let id = RepositoryIdentity.id(for: read.path)
        let branchMeta = GitStatusParser.parseBranchMetadata(output)
        let entries = GitStatusParser.parseStatusEntries(output)
        let summary = GitStatusParser.summarize(entries)
        let changedFiles = entries.map(\.path)
        let changedCount = summary.total
        let status: RepositoryStatus = changedCount > 0 ? .changed : .clean
        let risk = RiskHintEngine.assess(changedFiles: changedFiles)
        let preview = Array(changedFiles.prefix(5)).map { ($0 as NSString).lastPathComponent }
        let ahead = branchMeta.hasUpstream ? branchMeta.aheadCount : nil
        let behind = branchMeta.hasUpstream ? branchMeta.behindCount : nil
        let activityAt = computeActivity(
            previous: read.previous,
            currentStatus: status,
            currentBranch: branchMeta.branch,
            currentTotal: changedCount, scannedAt: scannedAt
        )

        return RepositorySnapshot(
            id: id, name: name, path: read.path,
            workspaceKind: read.workspaceKind ?? read.previous?.workspaceKind,
            branch: branchMeta.branch, status: status,
            modifiedFileCount: summary.modified,
            addedFileCount: summary.added,
            deletedFileCount: summary.deleted,
            untrackedFileCount: summary.untracked,
            stagedFileCount: summary.staged,
            unstagedFileCount: summary.unstaged,
            conflictedFileCount: summary.conflicted,
            aheadCount: ahead, behindCount: behind,
            hasUpstream: branchMeta.hasUpstream,
            changedFileCount: changedCount,
            changedFilesPreview: preview, risk: risk.level,
            lastScannedAt: scannedAt,
            dataSource: .current, lastSuccessfulScanAt: scannedAt,
            lastChangedAt: read.previous?.lastChangedAt,
            lastCommitID: branchMeta.headOID,
            lastCommitSummary: read.previous?.lastCommitSummary,
            lastCommitMetadataAvailable: read.previous?.lastCommitMetadataAvailable,
            lastActivityAt: activityAt,
            errorMessage: nil,
            isPinned: read.previous?.isPinned ?? false
        )
    }

    private func buildFailedSnapshot(read: ProcessReadResult, error: String) -> RepositorySnapshot {
        let path = RepositoryIdentity.canonicalPath(read.path)
        let prev = read.previous.map(RepositoryIdentity.normalize)
        let attemptedAt = DateFormatting.nowISO()
        if let prev {
            return prev.retainingLastSuccessfulData(
                attemptedAt: attemptedAt, errorMessage: error,
                unavailableSince: read.unavailableSince, workspaceKind: read.workspaceKind
            )
        }
        return RepositorySnapshot(
            id: RepositoryIdentity.id(for: path),
            name: (path as NSString).lastPathComponent, path: path,
            workspaceKind: read.workspaceKind, branch: "unknown",
            status: .error, modifiedFileCount: 0, addedFileCount: 0,
            deletedFileCount: 0, untrackedFileCount: 0,
            stagedFileCount: nil, unstagedFileCount: nil,
            conflictedFileCount: nil, aheadCount: nil, behindCount: nil,
            hasUpstream: nil, changedFileCount: 0,
            changedFilesPreview: [], risk: .low,
            lastScannedAt: attemptedAt, dataSource: .unknown,
            lastSuccessfulScanAt: nil, lastChangedAt: nil,
            lastCommitID: nil, lastCommitSummary: nil,
            lastCommitMetadataAvailable: false, lastActivityAt: nil,
            unavailableSince: read.unavailableSince ?? attemptedAt,
            errorMessage: error, isPinned: false
        )
    }

    private func computeActivity(
        previous: RepositorySnapshot?,
        currentStatus: RepositoryStatus,
        currentBranch: String,
        currentTotal: Int,
        scannedAt: String
    ) -> String? {
        guard let prev = previous else {
            return currentStatus == .changed ? scannedAt : nil
        }
        let changed = prev.branch != currentBranch
            || prev.modifiedFileCount != currentTotal
            || prev.status != currentStatus
        if changed { return scannedAt }
        return prev.lastActivityAt ?? prev.lastChangedAt
    }
}

// MARK: - Stage 3: Extended info

extension RefreshEngine {
    private func readExtendedInfo(
        coreResult: CoreReadResult,
        config: ScanConfig,
        previousSnapshot: AppGroupData?,
        overallDeadline: TimeInterval,
        generation: UInt64,
        gitCommandRunner: @escaping GitCommandRunner,
        warnings: inout [String]
    ) async -> ExtendedReadResult {
        guard !coreResult.snapshots.isEmpty else {
            return ExtendedReadResult(snapshots: [], completed: 0, total: 0, reusedMetadataCount: 0)
        }

        let previousByPath = indexPreviousSnapshots(previousSnapshot)
        var enriched: [RepositorySnapshot] = []
        var needsLog: [(Int, RepositorySnapshot)] = []
        var reusedCount = 0

        for (idx, snapshot) in coreResult.snapshots.enumerated() {
            guard snapshot.resolvedDataSource == .current, snapshot.status != .error else {
                enriched.append(snapshot)
                continue
            }

            let prev = previousByPath[snapshot.path]
            let headChanged = prev?.lastCommitID != snapshot.lastCommitID
            let canReuse = prev?.lastCommitMetadataAvailable == true && !headChanged

            if canReuse {
                let reused = snapshot.reusingCommitMetadata(from: prev!)
                enriched.append(reused)
                reusedCount += 1
            } else {
                needsLog.append((idx, snapshot))
            }
        }

        guard !needsLog.isEmpty else {
            return ExtendedReadResult(snapshots: enriched, completed: enriched.count,
                                      total: coreResult.snapshots.count, reusedMetadataCount: reusedCount)
        }

        let concurrency = min(config.maxConcurrentGitOps, needsLog.count)
        var logResults: [Int: RepositorySnapshot] = [:]

        await withTaskGroup(of: (Int, RepositorySnapshot?).self) { group in
            var nextIdx = 0

            func submit() {
                guard nextIdx < needsLog.count else { return }
                let (origIdx, snapshot) = needsLog[nextIdx]
                nextIdx += 1

                group.addTask {
                    guard !Task.isCancelled, !self.isCancelled else { return (origIdx, nil) }
                    let remaining = overallDeadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { return (origIdx, nil) }
                    let timeout = min(config.gitCommandTimeout, max(0.5, remaining))

                    let logResult = gitCommandRunner(
                        ["log", "-1", "--pretty=%H%x00%cI%x00%s"],
                        snapshot.path, timeout,
                        ProcessRunner.defaultOutputLimit,
                        { self.isCancelled || Task.isCancelled }
                    )

                    guard case .success(let output) = logResult else {
                        return (origIdx, snapshot) // keep status snapshot without log metadata
                    }

                    let parts = output
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: "\0")
                    let commitID = parts.count > 0 ? parts[0] : nil
                    let committedAt = parts.count > 1 ? parts[1] : nil
                    let summary = parts.count > 2 ? parts[2] : nil

                    let enriched = RepositorySnapshot(
                        id: snapshot.id, name: snapshot.name, path: snapshot.path,
                        workspaceKind: snapshot.workspaceKind,
                        branch: snapshot.branch, status: snapshot.status,
                        modifiedFileCount: snapshot.modifiedFileCount,
                        addedFileCount: snapshot.addedFileCount,
                        deletedFileCount: snapshot.deletedFileCount,
                        untrackedFileCount: snapshot.untrackedFileCount,
                        stagedFileCount: snapshot.stagedFileCount,
                        unstagedFileCount: snapshot.unstagedFileCount,
                        conflictedFileCount: snapshot.conflictedFileCount,
                        aheadCount: snapshot.aheadCount, behindCount: snapshot.behindCount,
                        hasUpstream: snapshot.hasUpstream,
                        changedFileCount: snapshot.changedFileCount,
                        changedFilesPreview: snapshot.changedFilesPreview,
                        risk: snapshot.risk,
                        lastScannedAt: snapshot.lastScannedAt,
                        dataSource: .current, lastSuccessfulScanAt: snapshot.lastScannedAt,
                        lastChangedAt: committedAt ?? snapshot.lastChangedAt,
                        lastCommitID: commitID ?? snapshot.lastCommitID,
                        lastCommitSummary: summary ?? snapshot.lastCommitSummary,
                        lastCommitMetadataAvailable: commitID != nil,
                        lastActivityAt: snapshot.lastActivityAt,
                        errorMessage: snapshot.errorMessage,
                        isPinned: snapshot.isPinned
                    )
                    return (origIdx, enriched)
                }
            }

            for _ in 0..<min(concurrency, needsLog.count) { submit() }

            while let (origIdx, result) = await group.next() {
                defer { submit() }
                if let result { logResults[origIdx] = result }
                if self.isCancelled || Task.isCancelled || ProcessInfo.processInfo.systemUptime >= overallDeadline {
                    group.cancelAll()
                    break
                }
            }
        }

        // Merge log results back into order
        var finalSnapshots: [RepositorySnapshot] = []
        for (idx, snapshot) in coreResult.snapshots.enumerated() {
            if let enriched = logResults[idx] {
                finalSnapshots.append(enriched)
            } else if idx < enriched.count {
                finalSnapshots.append(enriched[idx])
            } else {
                finalSnapshots.append(snapshot)
            }
        }

        return ExtendedReadResult(
            snapshots: finalSnapshots,
            completed: logResults.count,
            total: coreResult.snapshots.count,
            reusedMetadataCount: reusedCount
        )
    }
}

// MARK: - Stage 4: Merge

extension RefreshEngine {
    private struct MergeOutput {
        let snapshots: [RepositorySnapshot]
        let unavailableSinceByPath: [String: String]
    }

    private func mergeResults(
        discovery: DiscoveredRepositories,
        coreSnapshots: [RepositorySnapshot],
        previousSnapshot: AppGroupData?
    ) -> MergeOutput {
        var byPath: [String: RepositorySnapshot] = [:]
        for snapshot in coreSnapshots.map(RepositoryIdentity.normalize) {
            let path = snapshot.path
            if let existing = byPath[path], existing.isPinned || snapshot.isPinned {
                var merged = existing
                merged.isPinned = true
                byPath[path] = merged
            } else {
                byPath[path] = snapshot
            }
        }

        var previousByPath: [String: RepositorySnapshot] = [:]
        for prev in previousSnapshot?.repositories ?? [] {
            previousByPath[RepositoryIdentity.canonicalPath(prev.path)] = RepositoryIdentity.normalize(prev)
        }

        var previousUnavailableSinceByPath = previousSnapshot?.repositoryUnavailableSinceByPath ?? [:]

        // Add unavailable paths as failed
        for upath in discovery.unavailablePaths {
            let cpath = RepositoryIdentity.canonicalPath(upath)
            guard byPath[cpath] == nil else { continue }
            let prev = previousByPath[cpath]
            byPath[cpath] = RepositorySnapshot(
                id: RepositoryIdentity.id(for: cpath),
                name: (cpath as NSString).lastPathComponent, path: cpath,
                workspaceKind: discovery.workspaceKindsByPath[cpath],
                branch: "unknown", status: .error,
                modifiedFileCount: 0, addedFileCount: 0,
                deletedFileCount: 0, untrackedFileCount: 0,
                stagedFileCount: nil, unstagedFileCount: nil,
                conflictedFileCount: nil, aheadCount: nil, behindCount: nil,
                hasUpstream: nil, changedFileCount: 0,
                changedFilesPreview: [], risk: .low,
                lastScannedAt: DateFormatting.nowISO(),
                dataSource: prev?.resolvedDataSource ?? .unknown,
                lastSuccessfulScanAt: prev?.resolvedLastSuccessfulScanAt,
                lastChangedAt: prev?.lastChangedAt,
                lastCommitID: prev?.lastCommitID,
                lastCommitSummary: prev?.lastCommitSummary,
                lastCommitMetadataAvailable: prev?.lastCommitMetadataAvailable ?? false,
                lastActivityAt: prev?.lastActivityAt,
                unavailableSince: prev?.unavailableSince ?? DateFormatting.nowISO(),
                errorMessage: "仓库暂时不可访问",
                isPinned: prev?.isPinned ?? false
            )
        }

        var seen = Set<String>()
        var retained: [RepositorySnapshot] = []
        var unavailability: [String: String] = [:]

        for path in discovery.allPaths {
            let cpath = RepositoryIdentity.canonicalPath(path)
            guard seen.insert(cpath).inserted, let snap = byPath[cpath] else { continue }

            if snap.resolvedDataSource == .current && snap.status != .error {
                retained.append(snap)
                continue
            }

            let since = snap.unavailableSince
                ?? previousUnavailableSinceByPath[cpath]
                ?? snap.lastScannedAt
            unavailability[cpath] = since
            if RepositoryRetentionPolicy.shouldRetain(snap) {
                retained.append(snap)
            }
        }

        return MergeOutput(snapshots: retained, unavailableSinceByPath: unavailability)
    }
}

// MARK: - Helpers

extension RefreshEngine {
    private func prioritizePaths(
        _ paths: [String],
        previous: AppGroupData?
    ) -> [PrioritizedRepository] {
        let prevByPath = indexPreviousSnapshots(previous)
        return paths.map { path in
            let canonical = RepositoryIdentity.canonicalPath(path)
            let prev = prevByPath[canonical]
            let priority = RepositoryRefreshPriority(previous: prev)
            return PrioritizedRepository(path: canonical, priority: priority, previousSnapshot: prev)
        }.sorted { $0.priority < $1.priority }
    }

    private func indexPreviousSnapshots(_ previous: AppGroupData?) -> [String: RepositorySnapshot] {
        var byPath: [String: RepositorySnapshot] = [:]
        for repo in previous?.repositories ?? [] {
            let canonical = RepositoryIdentity.canonicalPath(repo.path)
            if let existing = byPath[canonical] {
                var merged = existing
                merged.isPinned = existing.isPinned || repo.isPinned
                byPath[canonical] = merged
            } else {
                byPath[canonical] = repo
            }
        }
        return byPath
    }

    private func isInvalidated(_ checkGeneration: UInt64) -> Bool {
        generation != checkGeneration || _isCancelled
    }

    private func publishProgress(stage: RefreshPipelineStage, total: Int,
                                  completed: Int, elapsed: TimeInterval,
                                  finished: Bool, startedAt: TimeInterval) {
        let progress = RefreshStageProgress(
            stage: stage, completedItems: completed, totalItems: total,
            elapsed: elapsed, isFinished: finished
        )
        progressContinuation.yield(RefreshProgress(
            phases: [stage: progress],
            overallElapsed: ProcessInfo.processInfo.systemUptime - startedAt,
            isCancelled: _isCancelled,
            currentStage: finished ? nil : stage
        ))
    }

    private func buildCancelled(previous: AppGroupData?, discoveredPaths: [String]) -> RefreshResult {
        progressContinuation.finish()
        return RefreshResult(
            data: previous ?? .empty(),
            warnings: ["扫描已取消，保留上次结果"],
            discoveredRepositoryPaths: discoveredPaths,
            stageDurations: [:],
            isCancelled: true,
            timedOut: false,
            diagnostics: RefreshDiagnostics(
                overallElapsed: 0, discoveryElapsed: 0, coreStatusElapsed: 0,
                extendedInfoElapsed: 0, mergeElapsed: 0, persistenceElapsed: 0,
                widgetSyncElapsed: 0, totalGitCalls: 0, totalGitTimeouts: 0,
                totalGitCancellations: 0, totalGitFailures: 0,
                totalRepositoryCount: previous?.repositories.count ?? 0,
                currentRepositoryCount: 0, reusedSnapshotCount: 0,
                snapshotReuseRatio: 0, peakGitConcurrency: 0,
                cancelled: true, timedOut: false, stageDiagnostics: []
            )
        )
    }

    private func buildPartialCancelled(
        discovery: DiscoveredRepositories,
        coreSnapshots: [RepositorySnapshot],
        previous: AppGroupData?,
        warnings: inout [String]
    ) -> RefreshResult {
        progressContinuation.finish()
        warnings.append("刷新取消; 已完成的部分仓库使用当前数据，其余保留上次成功结果。")

        let prevByPath = indexPreviousSnapshots(previous)
        var merged = coreSnapshots
        var seenPaths = Set(merged.map { RepositoryIdentity.canonicalPath($0.path) })

        for path in discovery.allPaths {
            let cpath = RepositoryIdentity.canonicalPath(path)
            guard !seenPaths.contains(cpath), let prev = prevByPath[cpath] else { continue }
            merged.append(prev)
            seenPaths.insert(cpath)
        }

        let sorted = RepositorySorter.sort(merged)
        return RefreshResult(
            data: AppGroupData(
                schemaVersion: previous?.schemaVersion ?? RepositorySnapshotSchema.version,
                generatedAt: DateFormatting.nowISO(), writtenAt: nil,
                lastSuccessfulRefreshAt: previous?.lastSuccessfulRefreshAt,
                scanSummary: ScanSummary.build(from: sorted),
                repositories: sorted,
                repositoryUnavailableSinceByPath: previous?.repositoryUnavailableSinceByPath,
                storageRevision: previous?.storageRevision ?? 0,
                persistenceState: .committed
            ),
            warnings: warnings,
            discoveredRepositoryPaths: discovery.allPaths,
            stageDurations: [:],
            isCancelled: true,
            timedOut: false,
            diagnostics: RefreshDiagnostics(
                overallElapsed: 0, discoveryElapsed: 0, coreStatusElapsed: 0,
                extendedInfoElapsed: 0, mergeElapsed: 0, persistenceElapsed: 0,
                widgetSyncElapsed: 0, totalGitCalls: 0, totalGitTimeouts: 0,
                totalGitCancellations: 0, totalGitFailures: 0,
                totalRepositoryCount: sorted.count,
                currentRepositoryCount: sorted.filter { $0.resolvedDataSource == .current }.count,
                reusedSnapshotCount: 0, snapshotReuseRatio: 0, peakGitConcurrency: 0,
                cancelled: true, timedOut: false, stageDiagnostics: []
            )
        )
    }

    private func logSummary(totalElapsed: TimeInterval, discovery: DiscoveredRepositories,
                             coreCount: Int, warnings: [String]) {
        logger.info("""
            refresh_engine elapsed_ms=\(Int(totalElapsed*1000)) \
            repos=\(discovery.allPaths.count) core=\(coreCount) \
            warnings=\(warnings.count) cancelled=\(self._isCancelled)
        """)
    }
}

// MARK: - RepositorySnapshot helpers

private extension RepositorySnapshot {
    func reusingCommitMetadata(from previous: RepositorySnapshot) -> RepositorySnapshot {
        RepositorySnapshot(
            id: id, name: name, path: path, workspaceKind: workspaceKind,
            branch: branch, status: status,
            modifiedFileCount: modifiedFileCount, addedFileCount: addedFileCount,
            deletedFileCount: deletedFileCount, untrackedFileCount: untrackedFileCount,
            stagedFileCount: stagedFileCount, unstagedFileCount: unstagedFileCount,
            conflictedFileCount: conflictedFileCount,
            aheadCount: aheadCount, behindCount: behindCount,
            hasUpstream: hasUpstream,
            changedFileCount: changedFileCount,
            changedFilesPreview: changedFilesPreview,
            risk: risk,
            lastScannedAt: lastScannedAt,
            dataSource: .current,
            lastSuccessfulScanAt: lastScannedAt,
            lastChangedAt: previous.lastChangedAt,
            lastCommitID: lastCommitID,
            lastCommitSummary: previous.lastCommitSummary,
            lastCommitMetadataAvailable: previous.lastCommitMetadataAvailable,
            lastActivityAt: previous.lastActivityAt,
            errorMessage: errorMessage,
            isPinned: isPinned
        )
    }
}

// MARK: - Diagnostics builder

extension RefreshEngine {
    /// Build a full diagnostics report from a completed refresh execution.
    static func buildDiagnostics(
        from result: RefreshResult,
        overallElapsed: TimeInterval,
        overallTimedOut: Bool,
        totalRepositoryCount: Int,
        currentRepositoryCount: Int,
        reusedSnapshotCount: Int,
        repositoryRetryCount: Int,
        coreMetrics: CoreReadResult?,
        extendedMetrics: ExtendedReadResult?,
        timeBudgetExhaustedByStage: [RefreshPipelineStage: Bool] = [:],
        persistError: String? = nil,
        widgetSyncError: String? = nil
    ) -> RefreshDiagnostics {
        let totalGitCalls = (coreMetrics?.gitStatusCount ?? 0) + (extendedMetrics?.completed ?? 0)
        let totalTimeouts = (coreMetrics?.gitTimeoutCount ?? 0)
        let totalCancellations = (coreMetrics?.gitCancelledCount ?? 0)
        let totalFailures = (coreMetrics?.gitFailureCount ?? 0)

        let stageDiagnostics = RefreshPipelineStage.allCases.map { stage in
            StageDiagnostics(
                stage: stage,
                elapsed: result.stageDurations[stage] ?? 0,
                gitCommandCount: stage == .coreStatus ? (coreMetrics?.gitStatusCount ?? 0)
                    : stage == .extendedInfo ? (extendedMetrics?.completed ?? 0) : 0,
                gitTimeoutCount: stage == .coreStatus ? (coreMetrics?.gitTimeoutCount ?? 0) : 0,
                gitCancellationCount: stage == .coreStatus ? (coreMetrics?.gitCancelledCount ?? 0) : 0,
                gitFailureCount: stage == .coreStatus ? (coreMetrics?.gitFailureCount ?? 0) : 0,
                repositoriesCompleted: stage == .coreStatus ? (coreMetrics?.completed ?? 0)
                    : stage == .extendedInfo ? (extendedMetrics?.completed ?? 0)
                    : stage == .merge ? totalRepositoryCount : 0,
                repositoriesSkipped: 0,
                snapshotReusedCount: stage == .extendedInfo ? (extendedMetrics?.reusedMetadataCount ?? 0) : 0,
                peakConcurrency: stage == .coreStatus ? (coreMetrics?.peakConcurrency ?? 0) : 0,
                cancelled: result.isCancelled && stage.rawValue < RefreshPipelineStage.merge.rawValue,
                timedOut: result.timedOut && stage.rawValue < RefreshPipelineStage.merge.rawValue,
                timeBudgetExhausted: timeBudgetExhaustedByStage[stage],
                persistenceError: stage == .persistence ? persistError : nil,
                widgetSyncError: stage == .widgetSync ? widgetSyncError : nil
            )
        }

        let snapshotReuseRatio = totalRepositoryCount > 0
            ? Double(reusedSnapshotCount) / Double(totalRepositoryCount)
            : 0

        return RefreshDiagnostics(
            overallElapsed: overallElapsed,
            discoveryElapsed: result.stageDurations[.discovery] ?? 0,
            coreStatusElapsed: result.stageDurations[.coreStatus] ?? 0,
            extendedInfoElapsed: result.stageDurations[.extendedInfo] ?? 0,
            mergeElapsed: result.stageDurations[.merge] ?? 0,
            persistenceElapsed: result.stageDurations[.persistence] ?? 0,
            widgetSyncElapsed: result.stageDurations[.widgetSync] ?? 0,
            totalGitCalls: totalGitCalls,
            totalGitTimeouts: totalTimeouts,
            totalGitCancellations: totalCancellations,
            totalGitFailures: totalFailures,
            totalRepositoryCount: totalRepositoryCount,
            currentRepositoryCount: currentRepositoryCount,
            reusedSnapshotCount: reusedSnapshotCount,
            snapshotReuseRatio: snapshotReuseRatio,
            peakGitConcurrency: coreMetrics?.peakConcurrency ?? 0,
            cancelled: result.isCancelled,
            timedOut: result.timedOut,
            stageDiagnostics: stageDiagnostics
        )
    }
}

// MARK: - Static discovery bridge on GitRepositoryScanner

extension GitRepositoryScanner {
    /// Re-expose the original scan function with a minimal interface for
    /// callers that need the full result tuple (data, warnings, paths).
    static func performFullScan(
        config: ScanConfig = .default,
        scanRoots: [String]? = nil,
        knownRepositoryPaths: [String]? = nil,
        ignoredRepositoryPaths: Set<String> = [],
        forceRepositoryDiscovery: Bool = false,
        previousSnapshot: AppGroupData? = nil
    ) async -> (data: AppGroupData, warnings: [String], discoveredRepositoryPaths: [String]) {
        await scan(
            config: config,
            scanRoots: scanRoots,
            knownRepositoryPaths: knownRepositoryPaths,
            ignoredRepositoryPaths: ignoredRepositoryPaths,
            forceRepositoryDiscovery: forceRepositoryDiscovery,
            previousSnapshot: previousSnapshot
        )
    }
}

import Foundation
import OSLog

// MARK: - Analysis error

struct AnalysisError: Error {
    let message: String
}

// MARK: - Change impact engine

// MARK: - Change impact engine

/// Main engine that orchestrates change impact analysis across all repositories.
///
/// Responsibilities:
/// - Accept scan results and trigger analysis
/// - Run the staged analysis pipeline per repository
/// - Manage incremental analysis (skip unchanged repos)
/// - Store and retrieve analysis results
/// - Integrate with existing RefreshEngine
///
/// Thread safety: Actor-based for state isolation; all public methods are async.
actor ChangeImpactEngine {
    private let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "ChangeImpact"
    )

    // MARK: - Dependencies

    private let pipeline: AnalysisPipeline
    private let store: ChangeImpactStore
    private let cache: AnalysisCache
    private let baselineManager: BaselineManager
    private let readinessEngine: ReleaseReadinessEngine

    // MARK: - State

    private var triggerMode: ImpactAnalysisTrigger = .afterChangedOnly
    private var config = AnalysisPipelineConfiguration.default
    private var scanFailureCounts: [String: Int] = [:]
    private var lastAnalysisTimes: [String: Double] = [:]
    private var totalAnalysesRun = 0
    private var totalAnalysesCached = 0
    private var lastErrors: [String] = []

    // MARK: - Initialization

    init(
        pipeline: AnalysisPipeline,
        store: ChangeImpactStore,
        cache: AnalysisCache,
        baselineManager: BaselineManager,
        readinessEngine: ReleaseReadinessEngine
    ) {
        self.pipeline = pipeline
        self.store = store
        self.cache = cache
        self.baselineManager = baselineManager
        self.readinessEngine = readinessEngine
    }

    // MARK: - Configuration

    func setTriggerMode(_ mode: ImpactAnalysisTrigger) {
        triggerMode = mode
    }

    func setPipelineConfig(_ config: AnalysisPipelineConfiguration) {
        self.config = config
    }

    // MARK: - Analysis trigger

    /// Analyze changes after a scan refresh completes.
    /// Only re-analyzes repositories that actually changed.
    func analyzeAfterRefresh(
        snapshots: [RepositorySnapshot],
        previousSnapshots: AppGroupData?,
        forceFull: Bool = false
    ) async -> AnalysisRunResult {
        let startTime = ProcessInfo.processInfo.systemUptime
        let requestID = "analysis-\(ISO8601DateFormatter().string(from: Date()))"
        var snapshotsByRepo: [String: ChangeImpactSnapshot] = [:]
        var errors: [String: String] = [:]
        var wasCancelled = false
        var timedOut = false

        // Advance cache generation to invalidate previous cycle's entries
        cache.advanceGeneration()

        // Determine which repos to analyze
        let reposToAnalyze: [RepositorySnapshot]
        if forceFull || triggerMode == .afterEveryScan {
            reposToAnalyze = Array(snapshots)
        } else {
            // Only analyze repos that changed or have errors
            reposToAnalyze = snapshots.filter { snapshot in
                let prev = previousSnapshots?.repositories.first(where: { $0.id == snapshot.id })
                return snapshot.status == .changed
                    || snapshot.status == .error
                    || prev?.status != snapshot.status
                    || prev?.lastCommitID != snapshot.lastCommitID
                    || prev?.branch != snapshot.branch
            }
        }

        logger.debug("Analyzing \(reposToAnalyze.count)/\(snapshots.count) repositories (forceFull: \(forceFull))")

        // Run analysis for each changed repo (with bounded concurrency)
        let maxConcurrent = min(config.maxConcurrency, reposToAnalyze.count)
        let semaphore = Semaphore(count: maxConcurrent)

        await withTaskGroup(of: (String, Result<ChangeImpactSnapshot, AnalysisError>).self) { group in
            for snapshot in reposToAnalyze {
                guard !Task.isCancelled else {
                    wasCancelled = true
                    break
                }

                // Skip error-state repos from analysis
                if snapshot.status == .error {
                    errors[snapshot.id] = snapshot.errorMessage ?? "仓库读取失败，跳过分析"
                    continue
                }

                await semaphore.wait()
                group.addTask { [self] in
                    defer { semaphore.signal() }
                    let result = await self.analyzeRepository(snapshot: snapshot)
                    return (snapshot.id, result)
                }
            }

            // Collect results
            for await (repoID, result) in group {
                switch result {
                case .success(let snapshot):
                    snapshotsByRepo[repoID] = snapshot
                    totalAnalysesRun += 1
                    // Store
                    let storeResult = store.store(snapshot: snapshot)
                    if case .failure(let error) = storeResult {
                        errors[repoID] = "存储失败: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    errors[repoID] = error.message
                }
            }
        }

        // Attempt to use cached results for unchanged repos
        for snapshot in snapshots where snapshotsByRepo[snapshot.id] == nil {
            if let cached = store.latestSnapshot(for: snapshot.id) {
                snapshotsByRepo[snapshot.id] = cached
                totalAnalysesCached += 1
            }
        }

        let elapsed = (ProcessInfo.processInfo.systemUptime - startTime) * 1000

        let diagnostics = AnalysisDiagnostics(
            totalElapsedMs: elapsed,
            stageTimings: [:],
            cacheHitCount: totalAnalysesCached,
            cacheMissCount: reposToAnalyze.count - snapshotsByRepo.count,
            reanalysisReason: forceFull ? "强制全量" : (triggerMode == .afterEveryScan ? "全量扫描" : "增量扫描"),
            affectedModuleCount: snapshotsByRepo.values.reduce(0) { $0 + $1.affectedModuleCount },
            dependencyGraphSize: snapshotsByRepo.values.reduce(0) { $0 + $1.impactEdges.count },
            timedOutStages: [],
            cancelledStages: wasCancelled ? ["analysis"] : [],
            degradedModules: [],
            recoveryResults: []
        )

        return AnalysisRunResult(
            requestID: requestID,
            completedAt: ISO8601DateFormatter().string(from: Date()),
            snapshots: snapshotsByRepo,
            workspaceAnalyses: [:],
            overallDiagnostics: diagnostics,
            wasCancelled: wasCancelled,
            timedOut: timedOut,
            errors: errors
        )
    }

    // MARK: - Single repo analysis

    /// Run analysis for a single repository.
    private func analyzeRepository(snapshot: RepositorySnapshot) async -> Result<ChangeImpactSnapshot, AnalysisError> {
        let startTime = ProcessInfo.processInfo.systemUptime

        // Build collection input from snapshot
        let input = ChangeCollectionInput(
            repositoryPath: snapshot.path,
            branch: snapshot.branch,
            status: snapshot.status,
            modifiedFiles: [],      // Would come from detailed git status
            addedFiles: [],
            deletedFiles: [],
            untrackedFiles: [],
            conflictedFiles: [],
            stagedFiles: [],
            unstagedFiles: [],
            lastCommitID: snapshot.lastCommitID,
            lastCommitSummary: snapshot.lastCommitSummary,
            aheadCount: snapshot.aheadCount,
            behindCount: snapshot.behindCount,
            hasUpstream: snapshot.hasUpstream,
            workspaceKind: snapshot.workspaceKind,
            recentCommits: nil
        )

        // Verify baseline
        let baselineState = baselineManager.verifyAndUpdate(
            repositoryPath: snapshot.path,
            currentBranch: snapshot.branch,
            lastValidAnalysisID: store.latestSnapshot(for: snapshot.id)?.id,
            isCancelled: { Task.isCancelled }
        )

        // Run pipeline
        let pipelineResult = await pipeline.runRepository(
            input: input,
            snapshot: snapshot,
            config: config,
            force: false
        )

        switch pipelineResult {
        case .success(let impactSnapshot, _):
            let elapsed = (ProcessInfo.processInfo.systemUptime - startTime) * 1000
            lastAnalysisTimes[snapshot.id] = elapsed
            scanFailureCounts[snapshot.id] = 0  // Reset on success

            // Update scan failure count in readiness assessment
            let updatedReadiness = readinessEngine.assessRepository(
                repositoryID: snapshot.id,
                snapshot: snapshot,
                changes: impactSnapshot.changes,
                baselineState: baselineState,
                scanFailureCount: 0,
                isFromCache: false
            )

            let finalSnapshot = ChangeImpactSnapshot(
                id: impactSnapshot.id,
                repositoryID: impactSnapshot.repositoryID,
                repositoryPath: impactSnapshot.repositoryPath,
                analysisVersion: impactSnapshot.analysisVersion,
                analyzedAt: impactSnapshot.analyzedAt,
                baselineState: baselineState,
                changes: impactSnapshot.changes,
                modules: impactSnapshot.modules,
                impactEdges: impactSnapshot.impactEdges,
                scope: impactSnapshot.scope,
                releaseReadiness: updatedReadiness,
                categoryBreakdown: impactSnapshot.categoryBreakdown,
                repositoryHealthSnapshot: impactSnapshot.repositoryHealthSnapshot,
                diagnostics: AnalysisDiagnostics(
                    totalElapsedMs: elapsed,
                    stageTimings: [:],
                    cacheHitCount: 0,
                    cacheMissCount: 1,
                    reanalysisReason: nil,
                    affectedModuleCount: impactSnapshot.affectedModuleCount,
                    dependencyGraphSize: impactSnapshot.impactEdges.count,
                    timedOutStages: [],
                    cancelledStages: [],
                    degradedModules: [],
                    recoveryResults: []
                ),
                isFromCache: false
            )

            return .success(finalSnapshot)

        case .cancelled:
            return .failure(AnalysisError(message: "分析已取消"))

        case .failed(let error, _):
            scanFailureCounts[snapshot.id, default: 0] += 1
            lastErrors.append("[\(snapshot.name)] \(error)")
            // Trim errors
            if lastErrors.count > 100 {
                lastErrors = Array(lastErrors.suffix(100))
            }
            return .failure(AnalysisError(message: error))
        }
    }

    // MARK: - Query API

    /// Get the latest analysis for a repository.
    func latestAnalysis(for repositoryID: String) -> ChangeImpactSnapshot? {
        store.latestSnapshot(for: repositoryID)
    }

    /// Get all analyses for a repository.
    func analyses(for repositoryID: String) -> [ChangeImpactSnapshot] {
        store.allSnapshots(for: repositoryID)
    }

    /// Get the release readiness for a repository.
    func readiness(for repositoryID: String) -> ReleaseReadiness? {
        store.latestSnapshot(for: repositoryID)?.releaseReadiness
    }

    /// Get diagnostics for the entire system.
    func getDiagnostics() -> ChangeImpactDiagnostics {
        let allAnalyses = store.storedRepositoryIDs
        var totalTime: Double = 0

        for (_, time) in lastAnalysisTimes {
            totalTime += time
        }

        return ChangeImpactDiagnostics(
            totalAnalysesRun: totalAnalysesRun,
            totalAnalysesCached: totalAnalysesCached,
            totalStageTimeouts: 0,
            totalStageCancellations: 0,
            totalStageFailures: 0,
            totalDegradations: 0,
            totalRecoveries: 0,
            averageAnalysisTimeMs: lastAnalysisTimes.isEmpty ? 0 : totalTime / Double(lastAnalysisTimes.count),
            lastAnalysisTimeMs: lastAnalysisTimes.values.sorted().last ?? 0,
            peakAnalysisTimeMs: lastAnalysisTimes.values.max() ?? 0,
            cacheDiagnostics: cache.diagnostics,
            storeDiagnostics: store.storeDiagnostics,
            cachedEntries: cache.count,
            storedAnalysesCount: store.totalAnalysisCount,
            managedRepositoryCount: allAnalyses.count,
            lastErrors: Array(lastErrors.suffix(10))
        )
    }

    /// Get verification scope (list of affected modules) for a repository.
    func verificationScope(for repositoryID: String) -> [String] {
        guard let snapshot = store.latestSnapshot(for: repositoryID) else { return [] }
        return snapshot.verificationScope
    }

    /// Get impacted target names for a repository.
    func impactedTargets(for repositoryID: String) -> [String] {
        guard let snapshot = store.latestSnapshot(for: repositoryID) else { return [] }
        return snapshot.impactedTargets
    }
}

// MARK: - Semaphore helper

private final class Semaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        self.count = count
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if count > 0 {
                count -= 1
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    nonisolated func signal() {
        var continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        if waiters.isEmpty {
            count += 1
        } else {
            continuation = waiters.removeFirst()
        }
        lock.unlock()
        continuation?.resume()
    }
}

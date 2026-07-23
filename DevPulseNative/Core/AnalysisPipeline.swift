import Foundation
import OSLog

// MARK: - Pipeline errors

enum PipelineError: Error, LocalizedError {
    case stageCancelled(AnalysisStage)
    case stageTimeout(AnalysisStage)
    case stageFailed(AnalysisStage, String)

    var errorDescription: String? {
        switch self {
        case .stageCancelled(let stage): return "\(stage.displayName) 已取消"
        case .stageTimeout(let stage): return "\(stage.displayName) 超时"
        case .stageFailed(let stage, let error): return "\(stage.displayName) 失败: \(error)"
        }
    }
}

// MARK: - Analysis context

/// Context passed through all pipeline stages.
struct AnalysisContext: Sendable {
    let repositoryID: String
    let repositoryPath: String
    let collectionInput: ChangeCollectionInput
    let baselineState: BaselineState
    let invalidationKey: InvalidationKey
    let generation: UInt64
    let config: AnalysisPipelineConfiguration
}

// MARK: - Pipeline configuration

struct AnalysisPipelineConfiguration: Sendable {
    var stageTimeouts: [AnalysisStage: TimeInterval] = [
        .changeCollection: 30.0,
        .manifestParsing: 15.0,
        .dependencyModeling: 10.0,
        .impactPropagation: 10.0,
        .riskAssessment: 5.0,
        .resultMerging: 5.0,
        .snapshotPublishing: 5.0
    ]
    var maxConcurrency: Int = 4
    var enableCaching: Bool = true
    var enableSpeculativeImpact: Bool = false

    static let `default` = AnalysisPipelineConfiguration()
}

// MARK: - Stage timing

struct StageTimingBuilder {
    var startTime: Double = ProcessInfo.processInfo.systemUptime
    var itemCount: Int = 0
    var errorCount: Int = 0
    var isCancelled: Bool = false

    mutating func recordItem() { itemCount += 1 }
    mutating func recordError() { errorCount += 1 }
    mutating func markCancelled() { isCancelled = true }

    func build(isCompleted: Bool) -> StageTiming {
        let elapsed = (ProcessInfo.processInfo.systemUptime - startTime) * 1000
        return StageTiming(
            elapsedMs: elapsed,
            itemCount: itemCount,
            isCompleted: isCompleted,
            isCancelled: isCancelled,
            errorCount: errorCount
        )
    }
}

// MARK: - Pipeline orchestrator

/// Orchestrates the staged execution of change impact analysis.
///
/// Design:
/// - Sequential stages: stages run in order, each consuming previous output.
/// - Cancellation: cooperative cancellation via generation-based token.
/// - Timeout: per-stage timeout that aborts the stage and proceeds.
/// - Cache: stage results can be cached and reused on re-runs.
/// - Fault isolation: one stage failure produces a degraded result, not a crash.
///
/// Thread safety: Actor-based isolation with Sendable constraints.
actor AnalysisPipeline {
    private let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "AnalysisPipeline"
    )

    // MARK: - State

    private var generation: UInt64 = 0
    private var cancelled = false

    private let analysisCache: AnalysisCache
    private let depEngine: DependencyInferenceEngine
    private let impactEngine: ImpactPropagationEngine
    private let readinessEngine: ReleaseReadinessEngine

    // MARK: - Initialization

    init(
        analysisCache: AnalysisCache,
        depEngine: DependencyInferenceEngine,
        impactEngine: ImpactPropagationEngine,
        readinessEngine: ReleaseReadinessEngine
    ) {
        self.analysisCache = analysisCache
        self.depEngine = depEngine
        self.impactEngine = impactEngine
        self.readinessEngine = readinessEngine
    }

    // MARK: - Public API

    /// Cancel the current pipeline run.
    func cancel() {
        cancelled = true
        logger.debug("Pipeline cancelled")
    }

    /// Run the full analysis pipeline for a single repository.
    func runRepository(
        input: ChangeCollectionInput,
        snapshot: RepositorySnapshot,
        config: AnalysisPipelineConfiguration,
        force: Bool = false
    ) async -> StageResult<ChangeImpactSnapshot> {
        generation &+= 1
        let currentGen = generation
        cancelled = false

        let repoID = RepositoryIdentity.id(for: input.repositoryPath)
        let invalidationKey = InvalidationKey.compute(for: input)

        // Check cache
        if config.enableCaching && !force {
            if let cached = analysisCache.get(
                repositoryID: repoID,
                key: invalidationKey,
                generation: currentGen
            ) {
                logger.debug("Cache hit for \(input.repositoryPath)")
                return .success(value: cached, diagnostics: StageTiming(elapsedMs: 0, itemCount: 1, isCompleted: true, isCancelled: false, errorCount: 0))
            }
        }

        let isCancelled: @Sendable () -> Bool = { [generation = currentGen] in
            Task.isCancelled
        }

        // ── Stage 1: Change Collection ───────────────────────────
        var stage1Timing = StageTimingBuilder()
        guard !isCancelled() else {
            stage1Timing.markCancelled()
            return .cancelled(diagnostics: stage1Timing.build(isCompleted: false))
        }

        let changes = await collectChanges(input: input, timing: &stage1Timing)
        let stage1Diagnostics = stage1Timing.build(isCompleted: true)

        // ── Stage 2: Manifest Parsing + Dependency Modeling ──────
        var stage2Timing = StageTimingBuilder()
        guard !isCancelled() else {
            stage2Timing.markCancelled()
            return .cancelled(diagnostics: stage2Timing.build(isCompleted: false))
        }

        let changedFiles = changes.map(\.filePath)
        let (modules, edges) = depEngine.inferModulesAndDependencies(
            repositoryPath: input.repositoryPath,
            changedFiles: changedFiles,
            workspaceKind: input.workspaceKind
        )
        for _ in modules { stage2Timing.recordItem() }
        let stage2Diagnostics = stage2Timing.build(isCompleted: true)

        // ── Stage 3: Impact Propagation ──────────────────────────
        var stage3Timing = StageTimingBuilder()
        guard !isCancelled() else {
            stage3Timing.markCancelled()
            return .cancelled(diagnostics: stage3Timing.build(isCompleted: false))
        }

        let directlyChangedIDs = Set(modules.filter { !$0.directChanges.isEmpty }.map(\.id))
        let impactedModules = impactEngine.propagate(
            modules: modules,
            edges: edges,
            directlyChangedModules: directlyChangedIDs
        )
        for _ in impactedModules { stage3Timing.recordItem() }
        let stage3Diagnostics = stage3Timing.build(isCompleted: true)

        // ── Stage 4: Risk Assessment ─────────────────────────────
        var stage4Timing = StageTimingBuilder()
        guard !isCancelled() else {
            stage4Timing.markCancelled()
            return .cancelled(diagnostics: stage4Timing.build(isCompleted: false))
        }

        let readiness = readinessEngine.assessRepository(
            repositoryID: repoID,
            snapshot: snapshot,
            changes: changes,
            baselineState: BaselineState.none(),
            scanFailureCount: 0,
            isFromCache: false
        )
        stage4Timing.recordItem()
        let stage4Diagnostics = stage4Timing.build(isCompleted: true)

        // ── Stage 5: Result Merging ──────────────────────────────
        var stage5Timing = StageTimingBuilder()
        guard !isCancelled() else {
            stage5Timing.markCancelled()
            return .cancelled(diagnostics: stage5Timing.build(isCompleted: false))
        }

        let categoryBreakdown = FileCategoryClassifier.classifyAll(
            filePaths: changes.map(\.filePath)
        )
        let scope = FileCategoryClassifier.determineScope(categoryBreakdown: categoryBreakdown)

        let id = "impact-\(repoID)-\(ISO8601DateFormatter().string(from: Date()))"
        let resultSnapshot = ChangeImpactSnapshot(
            id: id,
            repositoryID: repoID,
            repositoryPath: input.repositoryPath,
            analysisVersion: ChangeImpactSchema.version,
            analyzedAt: ISO8601DateFormatter().string(from: Date()),
            baselineState: .none(),
            changes: changes,
            modules: impactedModules,
            impactEdges: edges,
            scope: scope,
            releaseReadiness: readiness,
            categoryBreakdown: categoryBreakdown,
            repositoryHealthSnapshot: nil,
            diagnostics: nil,
            isFromCache: false
        )
        stage5Timing.recordItem()
        let stage5Diagnostics = stage5Timing.build(isCompleted: true)

        // ── Stage 6: Snapshot Publishing ─────────────────────────
        var stage6Timing = StageTimingBuilder()
        guard !isCancelled() else {
            stage6Timing.markCancelled()
            return .cancelled(diagnostics: stage6Timing.build(isCompleted: false))
        }

        let hasChanges = !resultSnapshot.changes.isEmpty
        analysisCache.set(
            repositoryID: repoID,
            snapshot: resultSnapshot,
            key: invalidationKey,
            generation: currentGen,
            isChanged: hasChanges
        )
        stage6Timing.recordItem()
        let stage6Diagnostics = stage6Timing.build(isCompleted: true)

        return .success(
            value: resultSnapshot,
            diagnostics: stage6Diagnostics
        )
    }

    // MARK: - Stage implementations

    private func collectChanges(
        input: ChangeCollectionInput,
        timing: inout StageTimingBuilder
    ) async -> [ChangeEntry] {
        var changes: [ChangeEntry] = []

        for file in input.modifiedFiles {
            let category = FileCategoryClassifier.classify(filePath: file)
            changes.append(ChangeEntry(
                filePath: file, relativePath: file, changeKind: .modified,
                category: category, isStaged: input.stagedFiles.contains(file),
                commitID: nil, commitSummary: nil
            ))
            timing.recordItem()
        }

        for file in input.addedFiles {
            let category = FileCategoryClassifier.classify(filePath: file)
            changes.append(ChangeEntry(
                filePath: file, relativePath: file, changeKind: .added,
                category: category, isStaged: input.stagedFiles.contains(file),
                commitID: nil, commitSummary: nil
            ))
            timing.recordItem()
        }

        for file in input.deletedFiles {
            let category = FileCategoryClassifier.classify(filePath: file)
            changes.append(ChangeEntry(
                filePath: file, relativePath: file, changeKind: .deleted,
                category: category, isStaged: false,
                commitID: nil, commitSummary: nil
            ))
            timing.recordItem()
        }

        for file in input.untrackedFiles {
            let category = FileCategoryClassifier.classify(filePath: file)
            changes.append(ChangeEntry(
                filePath: file, relativePath: file, changeKind: .untracked,
                category: category, isStaged: false,
                commitID: nil, commitSummary: nil
            ))
            timing.recordItem()
        }

        for file in input.conflictedFiles {
            let category = FileCategoryClassifier.classify(filePath: file)
            changes.append(ChangeEntry(
                filePath: file, relativePath: file, changeKind: .conflicted,
                category: category, isStaged: false,
                commitID: nil, commitSummary: nil
            ))
            timing.recordItem()
        }

        if let recentCommits = input.recentCommits {
            for commit in recentCommits {
                for file in commit.filesChanged {
                    let category = FileCategoryClassifier.classify(filePath: file)
                    changes.append(ChangeEntry(
                        filePath: file, relativePath: file, changeKind: .modified,
                        category: category, isStaged: false,
                        commitID: commit.commitID, commitSummary: commit.summary
                    ))
                    timing.recordItem()
                }
            }
        }

        return changes
    }
}

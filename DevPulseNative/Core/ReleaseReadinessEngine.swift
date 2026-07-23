import Foundation
import OSLog

// MARK: - Release readiness engine

/// Assesses release readiness for a repository or workspace by combining
/// multiple signals: uncommitted changes, unpushed commits, baseline status,
/// conflicts, test coverage, dependency changes, scan failures, and workspace
/// anomalies.
///
/// Design:
/// - Rule-based: each signal is independently evaluated with explainable evidence.
/// - Non-blocking: all signals are derived from existing snapshot data.
/// - Composable: signals can be aggregated across repositories for workspace view.
/// - Deterministic: same inputs always produce the same assessment.
///
/// Thread safety: Stateless and reentrant.
final class ReleaseReadinessEngine: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "ReleaseReadiness"
    )

    // MARK: - Configuration

    struct Configuration: Sendable {
        /// Fraction of changed files that should be tests to avoid "missing test" warning.
        var minTestFraction: Double = 0.1
        /// Maximum unpushed commits before blocking.
        var maxUnpushedCommits: Int = 20
        /// Maximum behind-count before blocking.
        var maxBehindCount: Int = 50
        /// Consecutive scan failures that trigger a warning.
        var scanFailureWarningThreshold: Int = 2
        /// Consecutive scan failures that trigger a block.
        var scanFailureBlockThreshold: Int = 5

        static let `default` = Configuration()
    }

    private let config: Configuration

    init(config: Configuration = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// Assess release readiness for a single repository.
    /// - Parameters:
    ///   - repositoryID: The repository's canonical ID.
    ///   - snapshot: The current repository snapshot.
    ///   - changes: The collected change entries for this repository.
    ///   - baselineState: Current baseline state.
    ///   - scanFailureCount: Number of consecutive scan failures.
    ///   - isFromCache: Whether this assessment is from cache.
    /// - Returns: A complete release readiness assessment.
    func assessRepository(
        repositoryID: String,
        snapshot: RepositorySnapshot,
        changes: [ChangeEntry],
        baselineState: BaselineState,
        scanFailureCount: Int,
        isFromCache: Bool
    ) -> ReleaseReadiness {
        var signals: [ReadinessSignal] = []
        let now = ISO8601DateFormatter().string(from: Date())

        // 1. Uncommitted changes
        if snapshot.changedFileCount > 0 {
            let level: ReleaseReadinessLevel = snapshot.changedFileCount > 10 ? .blocked : .attention
            let fileDetails = snapshot.changedFilesPreview.prefix(5).map {
                "  - \(($0 as NSString).lastPathComponent)"
            }
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-uncommitted",
                kind: .uncommittedChanges,
                level: level,
                title: "存在未提交变更",
                explanation: "检测到 \(snapshot.changedFileCount) 个未提交文件变更",
                evidence: [
                    "变更文件数: \(snapshot.changedFileCount)",
                    "未跟踪: \(snapshot.untrackedFileCount)",
                    "已暂存: \(snapshot.stagedFileCount ?? 0)",
                    "未暂存: \(snapshot.unstagedFileCount ?? 0)",
                    "冲突: \(snapshot.conflictedFileCount ?? 0)"
                ] + fileDetails,
                sourceRepositoryID: repositoryID
            ))
        }

        // 2. Unpushed commits
        if let aheadCount = snapshot.aheadCount, aheadCount > 0 {
            let level: ReleaseReadinessLevel = aheadCount > config.maxUnpushedCommits ? .blocked : .attention
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-unpushed",
                kind: .unpushedCommits,
                level: level,
                title: "存在未推送提交",
                explanation: "本地领先上游 \(aheadCount) 个提交未推送",
                evidence: ["领先推送数: \(aheadCount)"],
                sourceRepositoryID: repositoryID
            ))
        }

        // 3. Behind baseline / behind remote
        if let behindCount = snapshot.behindCount, behindCount > 0 {
            let level: ReleaseReadinessLevel = behindCount > config.maxBehindCount ? .blocked : .attention
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-behind",
                kind: .behindBaseline,
                level: level,
                title: "落后于上游分支",
                explanation: "本地落后上游 \(behindCount) 个提交",
                evidence: ["落后数: \(behindCount)"],
                sourceRepositoryID: repositoryID
            ))
        }

        // 4. Merge conflicts
        if let conflictedCount = snapshot.conflictedFileCount, conflictedCount > 0 {
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-conflicts",
                kind: .mergeConflict,
                level: .blocked,
                title: "存在合并冲突",
                explanation: "检测到 \(conflictedCount) 个冲突文件",
                evidence: ["冲突文件数: \(conflictedCount)"],
                sourceRepositoryID: repositoryID
            ))
        }

        // 5. Missing test changes
        let categoryBreakdown = FileCategoryClassifier.classifyAll(
            filePaths: changes.map(\.filePath)
        )
        let testCount = categoryBreakdown[.test] ?? 0
        let sourceCount = categoryBreakdown[.source] ?? 0
        let totalMeaningfulChanges = sourceCount + testCount

        if sourceCount > 0 && totalMeaningfulChanges > 0 {
            let testFraction = Double(testCount) / Double(totalMeaningfulChanges)
            if testFraction < config.minTestFraction {
                signals.append(ReadinessSignal(
                    id: "\(repositoryID)-missing-tests",
                    kind: .missingTestChanges,
                    level: .attention,
                    title: "缺少测试变更",
                    explanation: String(
                        format: "源码变更 %.0f%% 无对应测试 (测试占比 %.0f%%)",
                        (1 - testFraction) * 100,
                        testFraction * 100
                    ),
                    evidence: [
                        "源码变更数: \(sourceCount)",
                        "测试变更数: \(testCount)",
                        "测试覆盖率: \(String(format: "%.1f", testFraction * 100))%"
                    ],
                    sourceRepositoryID: repositoryID
                ))
            }
        }

        // 6. Dependency changes
        let depCount = categoryBreakdown[.dependency] ?? 0
        if depCount > 0 {
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-dep-changes",
                kind: .dependencyChange,
                level: .attention,
                title: "依赖已变更",
                explanation: "检测到 \(depCount) 个依赖文件变更",
                evidence: ["依赖变更数: \(depCount)"],
                sourceRepositoryID: repositoryID
            ))
        }

        // 7. Consecutive scan failures
        if scanFailureCount >= config.scanFailureBlockThreshold {
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-scan-failures",
                kind: .consecutiveScanFailures,
                level: .blocked,
                title: "连续扫描失败",
                explanation: "已连续 \(scanFailureCount) 次扫描失败",
                evidence: ["失败次数: \(scanFailureCount)"],
                sourceRepositoryID: repositoryID
            ))
        } else if scanFailureCount >= config.scanFailureWarningThreshold {
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-scan-failures-warn",
                kind: .consecutiveScanFailures,
                level: .attention,
                title: "扫描频繁失败",
                explanation: "连续 \(scanFailureCount) 次扫描遇到问题",
                evidence: ["失败次数: \(scanFailureCount)"],
                sourceRepositoryID: repositoryID
            ))
        }

        // 8. Detached HEAD
        if snapshot.branch == "HEAD" || snapshot.branch.isEmpty {
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-detached",
                kind: .detachedHead,
                level: .attention,
                title: "处于分离 HEAD 状态",
                explanation: "当前不在任何分支上，变更可能丢失",
                evidence: ["分支: \(snapshot.branch)"],
                sourceRepositoryID: repositoryID
            ))
        }

        // 9. No upstream
        if snapshot.hasUpstream == false {
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-no-upstream",
                kind: .noUpstream,
                level: .attention,
                title: "未关联上游分支",
                explanation: "当前分支未关联远程跟踪分支",
                evidence: ["分支: \(snapshot.branch)"],
                sourceRepositoryID: repositoryID
            ))
        }

        // 10. Diverged branch
        if let aheadCount = snapshot.aheadCount, let behindCount = snapshot.behindCount,
           aheadCount > 0 && behindCount > 0 {
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-diverged",
                kind: .divergedBranch,
                level: .blocked,
                title: "分支已偏离",
                explanation: "本地和上游同时存在未同步的提交",
                evidence: ["领先: \(aheadCount)", "落后: \(behindCount)"],
                sourceRepositoryID: repositoryID
            ))
        }

        // 11. Baseline degradation
        if baselineState.isDegraded {
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-baseline-degraded",
                kind: .baselineDegraded,
                level: .blocked,
                title: "基线分支异常",
                explanation: baselineState.degradationReason ?? "基线分支不可用",
                evidence: ["原因: \(baselineState.degradationReason ?? "未知")"],
                sourceRepositoryID: repositoryID
            ))
        } else if baselineState.baselineBranch == nil {
            signals.append(ReadinessSignal(
                id: "\(repositoryID)-baseline-missing",
                kind: .baselineMissing,
                level: .attention,
                title: "未设置基线分支",
                explanation: "未配置用于比较的基线分支，部分分析功能受限",
                evidence: [],
                sourceRepositoryID: repositoryID
            ))
        }

        // Determine overall level
        let level = determineOverallLevel(signals: signals)

        let summary = buildSummary(level: level, signals: signals)
        let explanation = buildExplanation(level: level, signals: signals)

        return ReleaseReadiness(
            scopeID: repositoryID,
            scopeKind: .repository,
            level: level,
            signals: signals,
            summary: summary,
            primaryExplanation: explanation,
            assessedAt: now,
            isFromCache: isFromCache
        )
    }

    /// Aggregate readiness across all repositories in a workspace.
    func aggregateWorkspaceReadiness(
        workspaceID: String,
        workspaceName: String,
        repositoryReadiness: [String: ReleaseReadiness],
        crossRepoSignals: [ReadinessSignal]
    ) -> ReleaseReadiness {
        let now = ISO8601DateFormatter().string(from: Date())
        var allSignals: [ReadinessSignal] = crossRepoSignals

        for (_, readiness) in repositoryReadiness {
            allSignals.append(contentsOf: readiness.signals)
        }

        let level = determineOverallLevel(signals: allSignals)
        let summary = buildSummary(level: level, signals: allSignals)
        let explanation = buildExplanation(level: level, signals: allSignals)

        return ReleaseReadiness(
            scopeID: workspaceID,
            scopeKind: .workspace,
            level: level,
            signals: allSignals,
            summary: summary,
            primaryExplanation: explanation,
            assessedAt: now,
            isFromCache: false
        )
    }

    // MARK: - Private

    private func determineOverallLevel(signals: [ReadinessSignal]) -> ReleaseReadinessLevel {
        guard !signals.isEmpty else { return .ready }

        if signals.contains(where: { $0.level == .blocked }) {
            return .blocked
        }
        if signals.contains(where: { $0.level == .attention }) {
            return .attention
        }
        return .ready
    }

    private func buildSummary(level: ReleaseReadinessLevel, signals: [ReadinessSignal]) -> String {
        let blockingCount = signals.filter { $0.level == .blocked }.count
        let attentionCount = signals.filter { $0.level == .attention }.count

        switch level {
        case .ready:
            return "发布就绪 — 未检测到阻塞或待关注事项"
        case .attention:
            return "需关注 — \(attentionCount) 个待关注事项" +
                (blockingCount > 0 ? "，\(blockingCount) 个阻塞项" : "")
        case .blocked:
            return "发布阻塞 — \(blockingCount) 个阻塞项" +
                (attentionCount > 0 ? "，\(attentionCount) 个待关注事项" : "")
        case .unknown:
            return "发布状态未知"
        }
    }

    private func buildExplanation(level: ReleaseReadinessLevel, signals: [ReadinessSignal]) -> String {
        guard !signals.isEmpty else {
            return "所有检查通过，可以发布"
        }

        var parts: [String] = []
        let blockingSignals = signals.filter { $0.level == .blocked }
        let attentionSignals = signals.filter { $0.level == .attention }

        if !blockingSignals.isEmpty {
            parts.append("阻塞项:")
            for signal in blockingSignals {
                parts.append("  - \(signal.title): \(signal.explanation)")
            }
        }

        if !attentionSignals.isEmpty {
            parts.append("待关注:")
            for signal in attentionSignals {
                parts.append("  - \(signal.title): \(signal.explanation)")
            }
        }

        return parts.joined(separator: "\n")
    }
}

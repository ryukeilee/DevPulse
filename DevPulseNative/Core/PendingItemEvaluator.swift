import Foundation
import OSLog

// MARK: - Evaluation result

struct PendingItemEvaluationResult: Sendable {
    let items: [PendingItem]
    let transitions: [PendingItemTransition]
    let notifications: [(item: PendingItem, transition: PendingItemTransition, reason: String)]
    let repositoryIdsExamined: Int
    let workspaceIdsExamined: Int
    let newItemCount: Int
    let resolvedItemCount: Int
    let escalatedCount: Int
    let deescalatedCount: Int
    let durationMs: Double
    let warnings: [String]
}

// MARK: - Context for evaluation

struct PendingItemEvaluationContext: Sendable {
    let repositories: [RepositorySnapshot]
    let workspaceAggregations: [String: WorkspaceAggregation]
    let workspaces: [Workspace]
    let healthAssessments: [String: RepositoryHealthAssessment]
    let previousItems: [PendingItem]
    let now: Date

    init(
        repositories: [RepositorySnapshot],
        workspaceAggregations: [String: WorkspaceAggregation] = [:],
        workspaces: [Workspace] = [],
        healthAssessments: [String: RepositoryHealthAssessment] = [:],
        previousItems: [PendingItem] = [],
        now: Date = Date()
    ) {
        self.repositories = repositories
        self.workspaceAggregations = workspaceAggregations
        self.workspaces = workspaces
        self.healthAssessments = healthAssessments
        self.previousItems = previousItems
        self.now = now
    }
}

// MARK: - Cached assessment helpers

private struct CachedHealth {
    let dirtyDuration: TimeInterval?
    let unpushedDuration: TimeInterval?
    let behindDuration: TimeInterval?
    let staleActivity: Bool
    let creepingChanges: Bool
    let frequentReadFailures: Int
    let recurringConflicts: Int
    let hasRecentRecovery: Bool
    let overallRisk: RiskLevel
}

// MARK: - Pending item evaluator

/// Background evaluator that generates pending items from scan results.
///
/// Design principles:
/// - Pure function: same input → same output
/// - Only evaluates conditions, never applies user actions
/// - Uses pre-computed data (no git commands)
/// - Bounded: per-repo and per-workspace rules are independent
enum PendingItemEvaluator {

    static let logger = Logger(subsystem: "local.devpulse.app", category: "PendingEvaluator")

    // MARK: - Main entry

    /// Evaluate all repositories and workspaces for pending items.
    ///
    /// - Parameters:
    ///   - context: Current scan results and previous items
    ///   - previousArchive: The prior full archive (for user-action preservation)
    /// - Returns: Evaluation result with items, transitions, and notifications
    static func evaluate(
        context: PendingItemEvaluationContext,
        previousArchive: PendingItemArchive? = nil
    ) -> PendingItemEvaluationResult {
        let start = Date()
        let warnings: [String] = []

        let previousByID = Dictionary(
            uniqueKeysWithValues: (previousArchive?.items ?? context.previousItems).map { ($0.id, $0) }
        )

        // Cache health assessments for fast lookup
        let healthByRepoID = context.healthAssessments

        var state = EvaluationState()

        // Keep explicit dispatch order; no per-repository rule arrays or escaping closures.
        for repo in context.repositories {
            let health = healthByRepoID[repo.id]
            let cached = extractSignals(from: health)
            func run(_ source: PendingItemSource, _ rule: RuleEvaluator) {
                evaluateRule(source: source, repo: repo, health: health, cached: cached,
                             previousByID: previousByID, context: context, state: &state, rule: rule)
            }

            run(.dirtyWorkspace, evaluateDirtyWorkspace)
            run(.unpushedCommits, evaluateUnpushedCommits)
            run(.behindRemote, evaluateBehindRemote)
            run(.mergeConflict, evaluateMergeConflict)
            run(.upstreamMissing, evaluateUpstreamMissing)
            run(.unavailable, evaluateUnavailable)
            run(.staleRepository, evaluateStaleRepository)
            run(.scanFailure, evaluateScanFailure)
            run(.creepingChanges, evaluateCreepingChanges)
            run(.staleActivity, evaluateStaleActivity)
            run(.healthTrend, evaluateHealthTrend)
        }

        for workspace in context.workspaces {
            let aggregation = context.workspaceAggregations[workspace.id]
            func run(_ source: PendingItemSource, _ rule: WorkspaceRuleEvaluator) {
                evaluateWorkspaceRule(source: source, workspace: workspace, aggregation: aggregation,
                                      previousByID: previousByID, context: context, state: &state, rule: rule)
            }

            run(.workspaceDegraded, evaluateWorkspaceDegraded)
            run(.workspaceConflicts, evaluateWorkspaceConflicts)
        }

        // Post-processing: carry forward firstDetectedAt from previous items
        // with a different source but the same repositoryID. This ensures
        // transitions like unavailable → staleRepository preserve the
        // original detection timestamp.
        // Also resolve previous items whose source changed to a different
        // category (e.g. .unavailable → .staleRepository).
        // Preserve the values traversal order within each bucket, including nil
        // repository IDs used by workspace items. Only these statuses can resolve.
        let resolvablePreviousByRepository = state.items.isEmpty ? [:] : Dictionary(grouping: previousByID.values.filter {
            switch $0.status {
            case .active, .acknowledged, .restored: return true
            case .snoozed, .muted, .resolved, .permanentlyIgnored: return false
            }
        }, by: \.repositoryID)

        for i in state.items.indices {
            let currentItem = state.items[i]
            let matchingPrev = resolvablePreviousByRepository[currentItem.repositoryID] ?? []

            for prev in matchingPrev {
                guard prev.source != currentItem.source else { continue }
                // Record a transition from the old source to the new one.
                // The old item is not added to state.items — the new item
                // replaces it with the preserved firstDetectedAt.
                let transition = PendingItemTransition(
                    from: prev.status,
                    to: .resolved,
                    severityChanged: true,
                    previousSeverity: prev.severity,
                    newSeverity: currentItem.severity,
                    reason: "仓库状态从 \(prev.source.displayName) 转为 \(currentItem.source.displayName)"
                )
                state.transitions.append(transition)
                state.resolvedCount += 1

                // Carry forward firstDetectedAt from the previous item
                if prev.firstDetectedAt != currentItem.firstDetectedAt {
                    state.items[i] = PendingItem(
                        id: currentItem.id,
                        source: currentItem.source,
                        severity: currentItem.severity,
                        repositoryID: currentItem.repositoryID,
                        repositoryName: currentItem.repositoryName,
                        workspaceID: currentItem.workspaceID,
                        workspaceName: currentItem.workspaceName,
                        title: currentItem.title,
                        explanation: currentItem.explanation,
                        evidence: currentItem.evidence,
                        firstDetectedAt: prev.firstDetectedAt,
                        lastConfirmedAt: currentItem.lastConfirmedAt,
                        status: currentItem.status,
                        snoozedUntil: currentItem.snoozedUntil,
                        duration: currentItem.duration,
                        lastTransition: currentItem.lastTransition
                    )
                }
            }
        }

        // Sort by severity descending then lastConfirmedAt descending
        state.items.sort { $0.severity > $1.severity || ($0.severity == $1.severity && $0.lastConfirmedAt > $1.lastConfirmedAt) }

        let duration = Date().timeIntervalSince(start) * 1000

        return PendingItemEvaluationResult(
            items: state.items,
            transitions: state.transitions,
            notifications: state.notifications,
            repositoryIdsExamined: context.repositories.count,
            workspaceIdsExamined: context.workspaces.count,
            newItemCount: state.newCount,
            resolvedItemCount: state.resolvedCount,
            escalatedCount: state.escalatedCount,
            deescalatedCount: state.deescalatedCount,
            durationMs: duration,
            warnings: warnings
        )
    }

    // MARK: - Rule evaluation helpers

    private typealias RuleEvaluator = (
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem?

    private typealias WorkspaceRuleEvaluator = (
        _ workspace: Workspace,
        _ aggregation: WorkspaceAggregation?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem?

    /// Mutable output shared by rule dispatch and post-processing. The repository
    /// position index intentionally excludes workspace appends, which are not deduplicated.
    private struct EvaluationState {
        var items: [PendingItem] = []
        var firstItemIndexByID: [String: Int] = [:]
        var transitions: [PendingItemTransition] = []
        var notifications: [(PendingItem, PendingItemTransition, String)] = []
        var newCount = 0
        var resolvedCount = 0
        var escalatedCount = 0
        var deescalatedCount = 0
    }

    private static func evaluateRule(
        source: PendingItemSource,
        repo: RepositorySnapshot,
        health: RepositoryHealthAssessment?,
        cached: CachedHealth?,
        previousByID: [String: PendingItem],
        context: PendingItemEvaluationContext,
        state: inout EvaluationState,
        rule: RuleEvaluator
    ) {
        processRule(candidate: rule(repo, health, cached, context),
                    expectedID: PendingItem(source: source, severity: .low, repositoryID: repo.id, title: "").id,
                    isRepositoryRule: true, previousByID: previousByID, context: context, state: &state)
    }

    private static func evaluateWorkspaceRule(
        source: PendingItemSource,
        workspace: Workspace,
        aggregation: WorkspaceAggregation?,
        previousByID: [String: PendingItem],
        context: PendingItemEvaluationContext,
        state: inout EvaluationState,
        rule: WorkspaceRuleEvaluator
    ) {
        processRule(candidate: rule(workspace, aggregation, context),
                    expectedID: PendingItem(source: source, severity: .low, workspaceID: workspace.id, title: "").id,
                    isRepositoryRule: false, previousByID: previousByID, context: context, state: &state)
    }

    // Repository rules also detect explanation changes and deduplicate candidates;
    // workspace rules retain every append and only compare severity/title.
    private static func processRule(
        candidate: PendingItem?,
        expectedID: @autoclosure () -> String,
        isRepositoryRule: Bool,
        previousByID: [String: PendingItem],
        context: PendingItemEvaluationContext,
        state: inout EvaluationState
    ) {
        guard let candidate else {
            // Condition not present — check if previous item needs resolution
            if let previous = previousByID[expectedID()],
               previous.status == .active || previous.status == .restored || previous.status == .acknowledged {
                let transition = PendingItemStatusTransition.evaluate(
                    current: previous,
                    conditionStillActive: false,
                    conditionChanged: false,
                    newSeverity: nil,
                    now: context.now
                )
                if transition.to == .resolved {
                    state.resolvedCount += 1
                }
                state.transitions.append(transition)
                var resolved = previous
                resolved.status = transition.to
                resolved.lastConfirmedAt = DateFormatting.nowISO()
                resolved.lastTransition = transition
                if isRepositoryRule && state.firstItemIndexByID[resolved.id] == nil {
                    state.firstItemIndexByID[resolved.id] = state.items.count
                }
                state.items.append(resolved)
            }
            return
        }

        // Generate or update
        let previous = previousByID[candidate.id]
        let conditionChanged: Bool
        if let prev = previous {
            conditionChanged = prev.severity != candidate.severity
                || prev.title != candidate.title
                || (isRepositoryRule && prev.explanation != candidate.explanation)
        } else {
            conditionChanged = true
        }

        let transition = PendingItemStatusTransition.evaluate(
            current: previous ?? candidate,
            conditionStillActive: true,
            conditionChanged: conditionChanged,
            newSeverity: candidate.severity,
            now: context.now
        )

        state.transitions.append(transition)

        if previous == nil { state.newCount += 1 }
        if transition.severityChanged {
            if let prevSeverity = transition.previousSeverity,
               let newSeverity = transition.newSeverity,
               newSeverity > prevSeverity {
                state.escalatedCount += 1
            } else {
                state.deescalatedCount += 1
            }
        }

        var finalItem = candidate
        if let prev = previous {
            finalItem = PendingItem(
                id: candidate.id,
                source: candidate.source,
                severity: candidate.severity,
                repositoryID: candidate.repositoryID,
                repositoryName: candidate.repositoryName,
                workspaceID: candidate.workspaceID,
                workspaceName: candidate.workspaceName,
                title: candidate.title,
                explanation: candidate.explanation,
                evidence: candidate.evidence,
                firstDetectedAt: prev.firstDetectedAt,
                lastConfirmedAt: DateFormatting.nowISO(),
                status: transition.to,
                snoozedUntil: transition.to == .snoozed ? prev.snoozedUntil : nil,
                duration: candidate.duration,
                lastTransition: transition
            )
        }

        // Deduplicate: if an item with the same ID already exists, keep the one with more evidence
        if !isRepositoryRule {
            state.items.append(finalItem)
        } else if let existingIdx = state.firstItemIndexByID[finalItem.id] {
            let existing = state.items[existingIdx]
            if finalItem.evidence.count > existing.evidence.count {
                state.items[existingIdx] = finalItem
            }
        } else {
            state.firstItemIndexByID[finalItem.id] = state.items.count
            state.items.append(finalItem)
        }

        // Check notification
        if transition.to.allowsNotification &&
            (previous == nil || transition.from != transition.to || transition.severityChanged) {
            state.notifications.append((finalItem, transition, transition.reason))
        }
    }

    // MARK: - Rule implementations

    private static func evaluateDirtyWorkspace(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        // Condition: changed files > 0 or health signal present
        let hasChanges = repo.resolvedDataSource == .current
            && repo.status == .changed
            && repo.changedFileCount > 0

        guard hasChanges || cached?.dirtyDuration != nil else { return nil }

        let duration = cached?.dirtyDuration ?? 0
        let severity: PendingItemSeverity
        if let health, health.overallRisk == .high {
            severity = .high
        } else if duration >= 24 * 3600 {
            severity = .high
        } else if duration >= 4 * 3600 {
            severity = .medium
        } else {
            severity = .low
        }

        let evidence = health?.signals
            .filter { $0.kind == .dirtyWorkspaceDuration }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .dirtyWorkspace,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "工作区存在长期改动",
            explanation: duration > 0
                ? "仓库 \(repo.name) 有 \(repo.changedFileCount) 个文件尚未提交，已持续 \(formatDuration(duration))。"
                : "仓库 \(repo.name) 有 \(repo.changedFileCount) 个文件尚未提交。",
            evidence: evidence + ["当前改动文件数：\(repo.changedFileCount)"],
            duration: duration
        )
    }

    private static func evaluateUnpushedCommits(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let ahead = repo.aheadCount ?? 0
        let hasAhead = repo.resolvedDataSource == .current && ahead > 0
        let hasHealthSignal = cached?.unpushedDuration != nil

        guard hasAhead || hasHealthSignal else { return nil }

        let duration = cached?.unpushedDuration ?? 0
        let severity: PendingItemSeverity
        if ahead >= 20 || (cached?.overallRisk == .high) {
            severity = .high
        } else if ahead >= 10 || duration >= 72 * 3600 {
            severity = .medium
        } else {
            severity = .low
        }

        let evidence = health?.signals
            .filter { $0.kind == .unpushedCommitsDuration }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .unpushedCommits,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "本地提交未推送",
            explanation: duration > 0
                ? "仓库 \(repo.name) 有 \(ahead) 个本地提交未推送到远端，已持续 \(formatDuration(duration))。"
                : "仓库 \(repo.name) 有 \(ahead) 个本地提交未推送到远端。",
            evidence: evidence + ["未推送提交数：\(ahead)"],
            duration: duration
        )
    }

    private static func evaluateBehindRemote(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let behind = repo.behindCount ?? 0
        let hasBehind = repo.resolvedDataSource == .current && behind > 0
        let hasHealthSignal = cached?.behindDuration != nil

        guard hasBehind || hasHealthSignal else { return nil }

        let duration = cached?.behindDuration ?? 0
        let severity: PendingItemSeverity
        if behind >= 50 || (cached?.overallRisk == .high) {
            severity = .high
        } else if behind >= 20 || duration >= 24 * 3600 {
            severity = .medium
        } else {
            severity = .low
        }

        let evidence = health?.signals
            .filter { $0.kind == .behindRemoteDuration }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .behindRemote,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "仓库落后远端",
            explanation: "仓库 \(repo.name) 落后远端 \(behind) 个提交，持续 \(formatDuration(duration))。",
            evidence: evidence + ["落后提交数：\(behind)"],
            duration: duration
        )
    }

    private static func evaluateMergeConflict(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let conflicted = repo.conflictedFileCount ?? 0
        let hasConflict = repo.resolvedDataSource == .current && conflicted > 0
        let recurringCount = cached?.recurringConflicts ?? 0

        guard hasConflict || recurringCount >= 2 else { return nil }

        let severity: PendingItemSeverity
        if conflicted > 5 || recurringCount >= 5 {
            severity = .critical
        } else if conflicted > 0 || recurringCount >= 3 {
            severity = .high
        } else {
            severity = .medium
        }

        let evidence = health?.signals
            .filter { $0.kind == .recurringConflicts }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .mergeConflict,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "存在合并冲突",
            explanation: conflicted > 0
                ? "仓库 \(repo.name) 当前有 \(conflicted) 个冲突文件需要解决。"
                : "仓库在过去 7 天出现了 \(recurringCount) 次冲突记录。",
            evidence: evidence + ["当前冲突文件数：\(conflicted)", "7天冲突次数：\(recurringCount)"],
            duration: 0
        )
    }

    private static func evaluateUpstreamMissing(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard repo.resolvedDataSource == .current,
              repo.hasUpstream == false,
              (repo.aheadCount ?? 0) > 0 || (repo.behindCount ?? 0) > 0 else {
            return nil
        }

        return PendingItem(
            source: .upstreamMissing,
            severity: .low,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "未关联上游分支",
            explanation: "仓库 \(repo.name) 当前分支未关联远端上游，无法正常推送/拉取。",
            evidence: ["当前分支：\(repo.branch)"],
            duration: 0
        )
    }

    private static func evaluateUnavailable(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let isUnavailable = repo.resolvedDataSource != .current || repo.status == .error
        guard isUnavailable else { return nil }

        let sinceDate: Date
        if let unavailableSince = repo.unavailableSince,
           let d = DateFormatting.date(from: unavailableSince) {
            sinceDate = d
        } else if let d = DateFormatting.date(from: repo.lastScannedAt) {
            sinceDate = d
        } else {
            sinceDate = context.now
        }
        let duration = context.now.timeIntervalSince(sinceDate)

        // Delegate to evaluateStaleRepository when duration exceeds retention window
        let retentionThreshold = RepositoryRetentionPolicy.unavailableRetentionInterval
        guard duration < retentionThreshold else { return nil }

        let severity: PendingItemSeverity
        if duration >= 24 * 3600 {
            severity = .high
        } else {
            severity = .medium
        }

        return PendingItem(
            source: .unavailable,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "仓库无法访问",
            explanation: "仓库 \(repo.name) 从 \(DateFormatting.displayString(from: sinceDate)) 起不可访问，持续 \(formatDuration(duration))。",
            evidence: ["错误信息：\(repo.errorMessage ?? "未知")"],
            duration: max(0, duration)
        )
    }

    private static func evaluateStaleRepository(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let isUnavailable = repo.resolvedDataSource != .current || repo.status == .error
        guard isUnavailable else { return nil }

        let sinceDate: Date
        if let unavailableSince = repo.unavailableSince,
           let d = DateFormatting.date(from: unavailableSince) {
            sinceDate = d
        } else if let d = DateFormatting.date(from: repo.lastScannedAt) {
            sinceDate = d
        } else {
            sinceDate = context.now
        }
        let duration = context.now.timeIntervalSince(sinceDate)

        // Only activate when unavailable duration exceeds the retention threshold
        let retentionThreshold = RepositoryRetentionPolicy.unavailableRetentionInterval
        guard duration >= retentionThreshold else { return nil }

        return PendingItem(
            source: .staleRepository,
            severity: .critical,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "仓库已长期无法访问",
            explanation: "仓库 \(repo.name) 从 \(DateFormatting.displayString(from: sinceDate)) 起已无法访问超过 7 天，持续 \(formatDuration(duration))。请在确认仓库本身已不存在后执行「清理」操作以移除跟踪。",
            evidence: ["错误信息：\(repo.errorMessage ?? "未知")", "持续时间：\(formatDuration(duration))"],
            duration: max(0, duration)
        )
    }

    private static func evaluateScanFailure(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let failureCount = cached?.frequentReadFailures ?? 0
        guard failureCount >= 2 else { return nil }

        let severity: PendingItemSeverity
        if failureCount >= 5 {
            severity = .high
        } else if failureCount >= 3 {
            severity = .medium
        } else {
            severity = .low
        }

        let evidence = health?.signals
            .filter { $0.kind == .frequentReadFailures }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .scanFailure,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "连续扫描失败",
            explanation: "仓库 \(repo.name) 在过去 24 小时内出现 \(failureCount) 次扫描失败。",
            evidence: evidence + ["24小时失败次数：\(failureCount)"],
            duration: 0
        )
    }

    private static func evaluateCreepingChanges(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard cached?.creepingChanges == true else { return nil }

        let evidence = health?.signals
            .filter { $0.kind == .creepingChanges }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .creepingChanges,
            severity: .medium,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "改动量持续堆积",
            explanation: "仓库 \(repo.name) 的改动文件数在多次扫描中持续增长。",
            evidence: evidence,
            duration: 0
        )
    }

    private static func evaluateStaleActivity(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard cached?.staleActivity == true else { return nil }

        let severity: PendingItemSeverity
        if cached?.overallRisk == .high {
            severity = .high
        } else {
            severity = .low
        }

        let evidence = health?.signals
            .filter { $0.kind == .staleActivity }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .staleActivity,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "仓库长期不活跃",
            explanation: "仓库 \(repo.name) 超过 7 天没有检测到任何活动。",
            evidence: evidence,
            duration: 0
        )
    }

    private static func evaluateHealthTrend(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard let health, health.hasSufficientHistory, !health.signals.isEmpty else { return nil }

        // Only generate a trend item if there are multiple medium+ signals
        let significantSignals = health.signals.filter { $0.level != .low }
        guard significantSignals.count >= 2 else { return nil }

        let severity: PendingItemSeverity
        switch health.overallRisk {
        case .high: severity = .high
        case .medium: severity = .medium
        case .low: severity = .low
        }

        let signalTitles = significantSignals.prefix(3).map(\.title)

        return PendingItem(
            source: .healthTrend,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "综合健康趋势异常",
            explanation: health.primaryExplanation,
            evidence: signalTitles + ["评估时间：\(health.assessedAt)"],
            duration: 0
        )
    }

    // MARK: - Workspace rules

    private static func evaluateWorkspaceDegraded(
        _ workspace: Workspace,
        _ aggregation: WorkspaceAggregation?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard let aggregation, aggregation.totalRepositories > 0 else { return nil }
        guard aggregation.overallHealth == .critical || aggregation.overallHealth == .warning else {
            return nil
        }

        let severity: PendingItemSeverity
        switch aggregation.overallHealth {
        case .critical: severity = .high
        case .warning: severity = .medium
        case .healthy, .unknown: return nil
        }

        let detail: String
        if aggregation.errorCount > 0 {
            detail = "\(aggregation.errorCount) 个仓库有错误，\(aggregation.warningCount) 个需要关注"
        } else {
            detail = "\(aggregation.warningCount) 个仓库需要关注"
        }

        return PendingItem(
            source: .workspaceDegraded,
            severity: severity,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            title: "工作空间状态异常",
            explanation: "工作空间「\(workspace.name)」当前状态：\(detail)。",
            evidence: [
                "健康仓库：\(aggregation.healthyCount)",
                "警告仓库：\(aggregation.warningCount)",
                "错误仓库：\(aggregation.errorCount)",
                "不可用仓库：\(aggregation.unavailableRepositoryCount)"
            ],
            duration: 0
        )
    }

    private static func evaluateWorkspaceConflicts(
        _ workspace: Workspace,
        _ aggregation: WorkspaceAggregation?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard let aggregation, aggregation.conflictCount > 0 else { return nil }

        let severity: PendingItemSeverity = aggregation.conflictCount > 3 ? .high : .medium

        return PendingItem(
            source: .workspaceConflicts,
            severity: severity,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            title: "工作空间存在合并冲突",
            explanation: "工作空间「\(workspace.name)」中有 \(aggregation.conflictCount) 个仓库存在冲突。",
            evidence: ["冲突仓库：\(aggregation.conflictRepositoryNames.joined(separator: "、"))"],
            duration: 0
        )
    }

    // MARK: - Helpers

    private static func extractSignals(from health: RepositoryHealthAssessment?) -> CachedHealth? {
        guard let health else { return nil }
        let signals = health.signals

        return CachedHealth(
            dirtyDuration: signals.first(where: { $0.kind == .dirtyWorkspaceDuration }).flatMap { $0.duration },
            unpushedDuration: signals.first(where: { $0.kind == .unpushedCommitsDuration }).flatMap { $0.duration },
            behindDuration: signals.first(where: { $0.kind == .behindRemoteDuration }).flatMap { $0.duration },
            staleActivity: signals.contains(where: { $0.kind == .staleActivity }),
            creepingChanges: signals.contains(where: { $0.kind == .creepingChanges }),
            frequentReadFailures: signals.first(where: { $0.kind == .frequentReadFailures }).flatMap { failure in
                Int(failure.currentValue.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
            } ?? 0,
            recurringConflicts: signals.first(where: { $0.kind == .recurringConflicts }).flatMap { conflict in
                Int(conflict.currentValue.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
            } ?? 0,
            hasRecentRecovery: signals.contains(where: { $0.kind == .recentRecovery }),
            overallRisk: health.overallRisk
        )
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60

        if days > 0 {
            return "\(days) 天 \(hours) 小时"
        } else if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        } else if minutes > 0 {
            return "\(minutes) 分"
        }
        return "< 1 分"
    }
}

import Foundation

enum CommitReadinessLevel: String, Codable, CaseIterable {
    case idle
    case review
    case ready
    case dirty
    case unknown

    var shortLabel: String {
        switch self {
        case .idle: return "Idle"
        case .review: return "Review"
        case .ready: return "Ready"
        case .dirty: return "Dirty"
        case .unknown: return "Unknown"
        }
    }
}

enum CommitReadinessReason: String, Codable, CaseIterable {
    case idleRepository
    case lightweightChanges
    case stagedChanges
    case mixedStagedAndUnstagedChanges
    case reviewBeforeCommit
    case deletedFiles
    case untrackedFiles
    case localAhead
    case remoteBehind
    case divergedBranch
    case conflictedFiles
    case scanError
    case branchNeedsConfirmation
    case largeWorkingTree
    case highRiskChanges
}

struct CommitReadinessAssessment: Equatable {
    let level: CommitReadinessLevel
    let reasons: [CommitReadinessReason]
    let shortLabel: String
    let detail: String
    let nextStep: String
    let widgetShortHint: String
    let basisSummary: String

    var reviewReceipt: ReviewReceipt {
        ReviewReceipt(
            level: level,
            summary: detail,
            nextStep: nextStep,
            basisSummary: basisSummary,
            widgetHint: widgetShortHint
        )
    }
}

struct ReviewReceipt: Equatable {
    let level: CommitReadinessLevel
    let summary: String
    let nextStep: String
    let basisSummary: String
    let widgetHint: String
}

enum RepositoryDecisionBlockingReason: Equatable {
    case retainedData
    case unavailableData
    case readFailure
    case conflicts(count: Int)
    case branchUnknown
    case detachedHead
    case divergedBranch(ahead: Int, behind: Int)
    case remoteUpdatesWithLocalChanges(count: Int)
    case remoteUpdates(count: Int)
}

enum RepositoryDecisionReminder: Equatable {
    case unpushedCommits(count: Int)
    case remoteUpdates(count: Int)
    case mixedStagedAndUnstagedChanges
    case untrackedFiles(count: Int)
    case deletedFiles(count: Int)
    case highRiskChanges
    case noUpstream
}

/// The canonical, deterministic interpretation of one repository snapshot.
/// Views may format facts, but must not derive a competing repository action.
struct RepositoryDecision: Equatable {
    let dataTrust: RepositoryDataSource
    let primaryAction: RepositoryActionState
    let blockingReason: RepositoryDecisionBlockingReason?
    let secondaryReminders: [RepositoryDecisionReminder]
    let commitReadiness: CommitReadinessAssessment
    let sortPriority: Int
    let summary: String
    let explanation: String
    let widgetSummary: String
}

enum RepositoryDecisionEngine {
    enum Thresholds {
        static let dirtyChangedFiles = 5
        static let dirtyLooseFiles = 3
    }

    private enum Priority {
        static let unavailable = 0
        static let conflict = 10
        static let branch = 20
        static let diverged = 30
        static let behindWithLocalChanges = 40
        static let push = 50
        static let localChanges = 60
        static let pull = 70
        static let idle = 80
    }

    private struct LocalDecision {
        let actionKind: RepositoryActionKind
        let actionTitle: String
        let readiness: CommitReadinessAssessment
        let explanation: String
        let widgetSummary: String
    }

    static func decide(snapshot: RepositorySnapshot) -> RepositoryDecision {
        let dataTrust = snapshot.resolvedDataSource
        let counts = snapshot.changeCounts
        let changedCount = max(
            max(snapshot.changedFileCount, counts.total),
            max(counts.staged, counts.unstaged + counts.untracked)
        )
        // Scanner status is the canonical working-tree verdict. Counts are
        // explanatory details and may be retained or inconsistent in legacy
        // payloads, so a clean verdict must not become a commit recommendation.
        let hasLocalChanges = snapshot.status != .clean && changedCount > 0
        let aheadCount = max(snapshot.aheadCount ?? 0, 0)
        let behindCount = max(snapshot.behindCount ?? 0, 0)
        let basis = basisSummary(snapshot: snapshot)

        switch dataTrust {
        case .lastSuccessful:
            let explanation = "先重新扫描确认当前状态；不要依据上次成功数据提交、push 或同步。"
            return decision(
                dataTrust: dataTrust,
                actionKind: .refreshRepositoryState,
                actionTitle: "先刷新确认状态",
                priority: Priority.unavailable,
                blocker: .retainedData,
                reminders: [],
                readiness: assessment(
                    level: .unknown,
                    reasons: [.scanError],
                    detail: "当前状态待确认，正在显示上次成功数据",
                    nextStep: "先重新扫描确认当前状态，再决定是否提交、push 或同步",
                    widgetShortHint: "上次成功数据，先刷新确认",
                    basisSummary: "数据来源：上次成功扫描；本轮读取未成功"
                ),
                summary: "当前状态待确认 · 显示上次成功数据",
                explanation: explanation,
                widgetSummary: "上次成功数据，先刷新确认",
                snapshot: snapshot
            )
        case .unknown:
            let explanation = "先看 Diagnostics 并重新扫描；当前没有可用于提交、push 或同步的可信数据。"
            return decision(
                dataTrust: dataTrust,
                actionKind: .diagnoseReadFailure,
                actionTitle: "检查读取异常",
                priority: Priority.unavailable,
                blocker: .unavailableData,
                reminders: [],
                readiness: assessment(
                    level: .unknown,
                    reasons: [.scanError],
                    detail: "当前仓库数据未知",
                    nextStep: "先打开 Diagnostics 并重新扫描，再决定是否操作仓库",
                    widgetShortHint: "数据未知，先看 Diagnostics",
                    basisSummary: "数据来源：未知；没有可用的成功扫描结果"
                ),
                summary: "仓库数据未知",
                explanation: explanation,
                widgetSummary: "数据未知，先看 Diagnostics",
                snapshot: snapshot
            )
        case .current:
            break
        }

        if snapshot.status == .error || snapshot.errorMessage != nil {
            let explanation = "先看 Diagnostics，确认 Git 读取失败原因。"
            return decision(
                dataTrust: dataTrust,
                actionKind: .diagnoseReadFailure,
                actionTitle: "检查读取异常",
                priority: Priority.unavailable,
                blocker: .readFailure,
                reminders: [],
                readiness: assessment(
                    level: .unknown,
                    reasons: [.scanError],
                    detail: "Git 状态读取失败",
                    nextStep: explanation,
                    widgetShortHint: "状态读取失败，先看 Diagnostics",
                    basisSummary: basis
                ),
                summary: snapshot.errorMessage ?? "Git 状态不可用",
                explanation: explanation,
                widgetSummary: "状态读取失败，先看 Diagnostics",
                snapshot: snapshot
            )
        }

        if counts.conflicted > 0 {
            let explanation = "先解决 \(countLabel(counts.conflicted, unit: "处冲突"))，再继续审查或提交。"
            return decision(
                dataTrust: dataTrust,
                actionKind: .resolveConflicts,
                actionTitle: "先解决 \(counts.conflicted) 处冲突",
                priority: Priority.conflict,
                blocker: .conflicts(count: counts.conflicted),
                reminders: reminders(snapshot: snapshot, primaryAction: .resolveConflicts),
                readiness: assessment(
                    level: .dirty,
                    reasons: [.conflictedFiles],
                    detail: "存在 Git 冲突，先整理后再提交",
                    nextStep: "先整理冲突，再继续审查或提交",
                    widgetShortHint: "有冲突，先整理改动",
                    basisSummary: basis
                ),
                summary: localSummary(snapshot: snapshot, changedCount: changedCount),
                explanation: explanation,
                widgetSummary: "有冲突，先整理改动",
                snapshot: snapshot
            )
        }

        if let branchBlocker = branchBlocker(snapshot.branch) {
            let explanation = "先确认当前分支，再决定是否继续审查、提交或同步。"
            return decision(
                dataTrust: dataTrust,
                actionKind: .confirmBranch,
                actionTitle: "确认当前分支",
                priority: Priority.branch,
                blocker: branchBlocker,
                reminders: reminders(snapshot: snapshot, primaryAction: .confirmBranch),
                readiness: assessment(
                    level: .review,
                    reasons: [.branchNeedsConfirmation],
                    detail: "当前分支需要先确认，再决定提交或 push",
                    nextStep: explanation,
                    widgetShortHint: "先确认当前分支",
                    basisSummary: basis
                ),
                summary: "当前分支待确认",
                explanation: explanation,
                widgetSummary: "先确认当前分支",
                snapshot: snapshot
            )
        }

        if aheadCount > 0, behindCount > 0 {
            let explanation = hasLocalChanges
                ? "本地和远端都有新提交，且工作区还有改动；先整理当前改动并确认分叉范围，再同步。"
                : "本地和远端都有新提交，先确认分叉范围再同步。"
            let readinessLevel: CommitReadinessLevel = hasLocalChanges ? .dirty : .review
            return decision(
                dataTrust: dataTrust,
                actionKind: .synchronizeDivergedBranch,
                actionTitle: "同步分叉分支",
                priority: Priority.diverged,
                blocker: .divergedBranch(ahead: aheadCount, behind: behindCount),
                reminders: reminders(snapshot: snapshot, primaryAction: .synchronizeDivergedBranch),
                readiness: assessment(
                    level: readinessLevel,
                    reasons: [.divergedBranch],
                    detail: hasLocalChanges
                        ? "本地与远端已分叉，工作区也有未整理改动"
                        : "本地与远端已分叉，需要先确认同步方案",
                    nextStep: explanation,
                    widgetShortHint: hasLocalChanges ? "分支已分叉，先整理再同步" : "分支已分叉，先同步",
                    basisSummary: basis
                ),
                summary: "领先 \(aheadCount) · 落后 \(behindCount)",
                explanation: explanation,
                widgetSummary: hasLocalChanges ? "分支已分叉，先整理再同步" : "分支已分叉，先同步",
                snapshot: snapshot
            )
        }

        if behindCount > 0, hasLocalChanges {
            let local = localDecision(snapshot: snapshot, changedCount: changedCount, basis: basis)
            let explanation = "本地还有改动且落后 \(countLabel(behindCount, unit: "个远端更新"))；先整理本地改动，再同步远端。"
            let readinessLevel: CommitReadinessLevel = local.readiness.level == .dirty ? .dirty : .review
            return decision(
                dataTrust: dataTrust,
                actionKind: .reviewLocalChanges,
                actionTitle: "先整理 \(changedCount) 个本地改动",
                priority: Priority.behindWithLocalChanges,
                blocker: .remoteUpdatesWithLocalChanges(count: behindCount),
                reminders: reminders(snapshot: snapshot, primaryAction: .reviewLocalChanges),
                readiness: assessment(
                    level: readinessLevel,
                    reasons: [.remoteBehind] + local.readiness.reasons,
                    detail: "落后远端且存在本地改动，不能直接提交或拉取",
                    nextStep: explanation,
                    widgetShortHint: "本地有改动且落后，先整理再同步",
                    basisSummary: basis
                ),
                summary: localSummary(snapshot: snapshot, changedCount: changedCount),
                explanation: explanation,
                widgetSummary: "本地有改动且落后，先整理再同步",
                snapshot: snapshot
            )
        }

        if hasLocalChanges {
            let local = localDecision(snapshot: snapshot, changedCount: changedCount, basis: basis)
            var explanation = local.explanation
            var widgetSummary = local.widgetSummary
            var readiness = local.readiness

            if aheadCount > 0 {
                let aheadReminder = "另有 \(countLabel(aheadCount, unit: "个本地提交"))尚未 push。"
                explanation = "\(explanation.trimmingCharacters(in: CharacterSet(charactersIn: "。")))；\(aheadReminder)"
                widgetSummary = "\(local.widgetSummary)；另有未 push 提交"
                readiness = replacingGuidance(
                    readiness,
                    nextStep: explanation,
                    widgetShortHint: widgetSummary,
                    appendingReason: .localAhead
                )
            }

            if snapshot.hasUpstream == false {
                explanation += " 当前分支未关联上游，分享前先确认远端关联。"
            }

            return decision(
                dataTrust: dataTrust,
                actionKind: local.actionKind,
                actionTitle: local.actionTitle,
                priority: Priority.localChanges,
                blocker: nil,
                reminders: reminders(snapshot: snapshot, primaryAction: local.actionKind),
                readiness: readiness,
                summary: localSummary(snapshot: snapshot, changedCount: changedCount),
                explanation: explanation,
                widgetSummary: widgetSummary,
                snapshot: snapshot
            )
        }

        if aheadCount > 0 {
            let explanation = "确认准备好后 push \(countLabel(aheadCount, unit: "个本地提交"))。"
            return decision(
                dataTrust: dataTrust,
                actionKind: .pushLocalCommits,
                actionTitle: "推送 \(aheadCount) 个本地提交",
                priority: Priority.push,
                blocker: nil,
                reminders: reminders(snapshot: snapshot, primaryAction: .pushLocalCommits),
                readiness: assessment(
                    level: .ready,
                    reasons: [.localAhead],
                    detail: aheadCount == 1 ? "有 1 个本地提交可 Push" : "有 \(aheadCount) 个本地提交可 Push",
                    nextStep: "如已准备好分享改动，再决定是否继续 push",
                    widgetShortHint: aheadCount == 1
                        ? "已有 1 个本地提交，再决定是否 push"
                        : "已有 \(aheadCount) 个本地提交，再决定是否 push",
                    basisSummary: basis
                ),
                summary: aheadCount == 1 ? "领先 1 个本地提交" : "领先 \(aheadCount) 个本地提交",
                explanation: explanation,
                widgetSummary: aheadCount == 1 ? "已有 1 个本地提交，可 push" : "已有 \(aheadCount) 个本地提交，可 push",
                snapshot: snapshot
            )
        }

        if behindCount > 0 {
            let explanation = "先拉取 \(countLabel(behindCount, unit: "个远端更新"))，再继续本地工作。"
            return decision(
                dataTrust: dataTrust,
                actionKind: .pullRemoteUpdates,
                actionTitle: "拉取 \(behindCount) 个远端更新",
                priority: Priority.pull,
                blocker: .remoteUpdates(count: behindCount),
                reminders: reminders(snapshot: snapshot, primaryAction: .pullRemoteUpdates),
                readiness: assessment(
                    level: .review,
                    reasons: [.remoteBehind],
                    detail: "远端有 \(behindCount) 个更新待同步",
                    nextStep: explanation,
                    widgetShortHint: "落后 \(behindCount) 个更新，先同步",
                    basisSummary: basis
                ),
                summary: behindCount == 1 ? "落后 1 个远端更新" : "落后 \(behindCount) 个远端更新",
                explanation: explanation,
                widgetSummary: "落后 \(behindCount) 个更新，先同步",
                snapshot: snapshot
            )
        }

        let noUpstream = snapshot.hasUpstream == false
        let explanation = noUpstream
            ? "当前无需操作；该分支未关联上游。"
            : "当前无需操作。"
        let widgetSummary = noUpstream ? "暂无改动 · 未关联上游" : "暂无改动"
        return decision(
            dataTrust: dataTrust,
            actionKind: .noActionNeeded,
            actionTitle: "无需处理",
            priority: Priority.idle,
            blocker: nil,
            reminders: reminders(snapshot: snapshot, primaryAction: .noActionNeeded),
            readiness: assessment(
                level: .idle,
                reasons: [.idleRepository],
                detail: "没有本地改动",
                nextStep: "暂无改动，暂时不用管",
                widgetShortHint: widgetSummary,
                basisSummary: basis
            ),
            summary: "没有本地改动",
            explanation: explanation,
            widgetSummary: widgetSummary,
            snapshot: snapshot
        )
    }

    private static func localDecision(
        snapshot: RepositorySnapshot,
        changedCount: Int,
        basis: String
    ) -> LocalDecision {
        let counts = snapshot.changeCounts
        let looseFileCount = counts.unstaged + counts.untracked

        if counts.staged > 0, looseFileCount == 0 {
            let explanation = "确认 \(countLabel(counts.staged, unit: "个已暂存改动"))后即可提交。"
            return LocalDecision(
                actionKind: .commitStagedChanges,
                actionTitle: "提交 \(counts.staged) 个已暂存改动",
                readiness: assessment(
                    level: .ready,
                    reasons: [.stagedChanges],
                    detail: counts.staged == 1
                        ? "有 1 个已暂存改动，看起来可以提交"
                        : "有 \(counts.staged) 个已暂存改动，看起来可以提交",
                    nextStep: "如已自查改动范围，看起来可以提交",
                    widgetShortHint: "看起来可以提交",
                    basisSummary: basis
                ),
                explanation: explanation,
                widgetSummary: "看起来可以提交"
            )
        }

        if counts.staged > 0 {
            return LocalDecision(
                actionKind: .reviewLocalChanges,
                actionTitle: "检查 \(changedCount) 个本地改动",
                readiness: assessment(
                    level: .review,
                    reasons: [.mixedStagedAndUnstagedChanges, .reviewBeforeCommit],
                    detail: "已有暂存改动，但工作区还有未整理内容，提交前先确认范围",
                    nextStep: "建议先审查暂存范围，再决定是否提交",
                    widgetShortHint: "建议先审查暂存范围",
                    basisSummary: basis
                ),
                explanation: "先拆清已暂存和未暂存改动，再决定是否提交。",
                widgetSummary: "建议先审查暂存范围"
            )
        }

        if changedCount >= Thresholds.dirtyChangedFiles
            || looseFileCount >= Thresholds.dirtyLooseFiles
            || snapshot.risk == .high {
            let reasons = dirtyReasons(snapshot: snapshot)
            let explanation: String
            if reasons.contains(.highRiskChanges) {
                explanation = "先收敛 \(countLabel(changedCount, unit: "处高风险改动"))，并跑一次验证。"
            } else {
                let targetCount = max(changedCount, looseFileCount)
                explanation = "先收敛 \(countLabel(targetCount, unit: "处改动"))，再继续审查或提交。"
            }
            return LocalDecision(
                actionKind: .reviewLocalChanges,
                actionTitle: "检查 \(changedCount) 个本地改动",
                readiness: assessment(
                    level: .dirty,
                    reasons: reasons,
                    detail: "未整理改动较多，建议先收敛再提交",
                    nextStep: "需要先整理改动，再继续审查或提交",
                    widgetShortHint: "需要整理改动",
                    basisSummary: basis
                ),
                explanation: explanation,
                widgetSummary: "需要整理改动"
            )
        }

        if counts.deleted > 0 {
            return LocalDecision(
                actionKind: .reviewLocalChanges,
                actionTitle: "检查 \(changedCount) 个本地改动",
                readiness: assessment(
                    level: .review,
                    reasons: [.deletedFiles, .reviewBeforeCommit],
                    detail: "提交前建议先检查删除项或跑一次验证",
                    nextStep: "建议先审查删除项，再决定是否提交",
                    widgetShortHint: "建议先审查删除项",
                    basisSummary: basis
                ),
                explanation: "先检查 \(countLabel(counts.deleted, unit: "个删除项"))，再决定是否提交。",
                widgetSummary: "建议先审查删除项"
            )
        }

        if counts.untracked > 0 {
            return LocalDecision(
                actionKind: .reviewLocalChanges,
                actionTitle: "检查 \(changedCount) 个本地改动",
                readiness: assessment(
                    level: .review,
                    reasons: [.untrackedFiles, .reviewBeforeCommit],
                    detail: "有未跟踪文件，建议先看 diff 或确认是否纳入提交",
                    nextStep: "建议先审查新文件，再决定是否提交",
                    widgetShortHint: "建议先审查新文件",
                    basisSummary: basis
                ),
                explanation: "先确认 \(countLabel(counts.untracked, unit: "个新文件"))是否纳入提交。",
                widgetSummary: "建议先审查新文件"
            )
        }

        if snapshot.risk == .medium {
            return LocalDecision(
                actionKind: .reviewLocalChanges,
                actionTitle: "检查 \(changedCount) 个本地改动",
                readiness: assessment(
                    level: .review,
                    reasons: [.highRiskChanges, .reviewBeforeCommit],
                    detail: "改动涉及中高风险区域，建议先看 diff 或跑验证",
                    nextStep: "建议先审查改动并跑验证，再决定是否提交",
                    widgetShortHint: "建议先审查并跑验证",
                    basisSummary: basis
                ),
                explanation: "先看 diff 并跑一次验证，再决定是否提交。",
                widgetSummary: "建议先审查并跑验证"
            )
        }

        return LocalDecision(
            actionKind: .reviewLocalChanges,
            actionTitle: "检查 \(changedCount) 个本地改动",
            readiness: assessment(
                level: .review,
                reasons: [.lightweightChanges, .reviewBeforeCommit],
                detail: "有少量改动，建议先看 diff 或跑验证",
                nextStep: "建议先审查改动，再决定是否提交",
                widgetShortHint: "建议先审查改动",
                basisSummary: basis
            ),
            explanation: "先看 \(countLabel(changedCount, unit: "处改动"))的 diff，再决定是否提交。",
            widgetSummary: "建议先审查改动"
        )
    }

    private static func decision(
        dataTrust: RepositoryDataSource,
        actionKind: RepositoryActionKind,
        actionTitle: String,
        priority: Int,
        blocker: RepositoryDecisionBlockingReason?,
        reminders: [RepositoryDecisionReminder],
        readiness: CommitReadinessAssessment,
        summary: String,
        explanation: String,
        widgetSummary: String,
        snapshot: RepositorySnapshot
    ) -> RepositoryDecision {
        let action = RepositoryActionState(kind: actionKind, title: actionTitle, sortPriority: priority)
        return RepositoryDecision(
            dataTrust: dataTrust,
            primaryAction: action,
            blockingReason: blocker,
            secondaryReminders: reminders,
            commitReadiness: readiness,
            sortPriority: priority,
            summary: summary,
            explanation: explanation,
            widgetSummary: widgetSummary
        )
    }

    private static func assessment(
        level: CommitReadinessLevel,
        reasons: [CommitReadinessReason],
        detail: String,
        nextStep: String,
        widgetShortHint: String,
        basisSummary: String
    ) -> CommitReadinessAssessment {
        CommitReadinessAssessment(
            level: level,
            reasons: reasons,
            shortLabel: level.shortLabel,
            detail: detail,
            nextStep: nextStep,
            widgetShortHint: widgetShortHint,
            basisSummary: basisSummary
        )
    }

    private static func replacingGuidance(
        _ readiness: CommitReadinessAssessment,
        nextStep: String,
        widgetShortHint: String,
        appendingReason: CommitReadinessReason? = nil
    ) -> CommitReadinessAssessment {
        var reasons = readiness.reasons
        if let appendingReason, !reasons.contains(appendingReason) {
            reasons.append(appendingReason)
        }
        return assessment(
            level: readiness.level,
            reasons: reasons,
            detail: readiness.detail,
            nextStep: nextStep,
            widgetShortHint: widgetShortHint,
            basisSummary: readiness.basisSummary
        )
    }

    private static func reminders(
        snapshot: RepositorySnapshot,
        primaryAction: RepositoryActionKind
    ) -> [RepositoryDecisionReminder] {
        let counts = snapshot.changeCounts
        let aheadCount = max(snapshot.aheadCount ?? 0, 0)
        let behindCount = max(snapshot.behindCount ?? 0, 0)
        var result: [RepositoryDecisionReminder] = []

        if aheadCount > 0,
           primaryAction != .pushLocalCommits,
           primaryAction != .synchronizeDivergedBranch {
            result.append(.unpushedCommits(count: aheadCount))
        }
        if behindCount > 0,
           primaryAction != .pullRemoteUpdates,
           primaryAction != .synchronizeDivergedBranch {
            result.append(.remoteUpdates(count: behindCount))
        }
        if counts.staged > 0, counts.unstaged + counts.untracked > 0 {
            result.append(.mixedStagedAndUnstagedChanges)
        }
        if counts.untracked > 0 {
            result.append(.untrackedFiles(count: counts.untracked))
        }
        if counts.deleted > 0 {
            result.append(.deletedFiles(count: counts.deleted))
        }
        if snapshot.risk == .high {
            result.append(.highRiskChanges)
        }
        if snapshot.hasUpstream == false {
            result.append(.noUpstream)
        }
        return result
    }

    private static func branchBlocker(_ branch: String) -> RepositoryDecisionBlockingReason? {
        let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "detached" { return .detachedHead }
        if normalized.isEmpty || normalized == "unknown" { return .branchUnknown }
        return nil
    }

    private static func dirtyReasons(snapshot: RepositorySnapshot) -> [CommitReadinessReason] {
        var reasons: [CommitReadinessReason] = [.largeWorkingTree]
        if snapshot.deletedFileCount > 0 { reasons.append(.deletedFiles) }
        if snapshot.untrackedFileCount > 0 { reasons.append(.untrackedFiles) }
        if snapshot.risk == .high { reasons.append(.highRiskChanges) }
        return reasons
    }

    private static func localSummary(snapshot: RepositorySnapshot, changedCount: Int) -> String {
        var parts = [changedCount == 1 ? "1 处改动" : "\(changedCount) 处改动"]
        let counts = snapshot.changeCounts
        if counts.staged > 0 { parts.append("已暂存 \(counts.staged)") }
        if counts.unstaged > 0 { parts.append("未暂存 \(counts.unstaged)") }
        if counts.untracked > 0 { parts.append("未跟踪 \(counts.untracked)") }
        if counts.conflicted > 0 { parts.append("冲突 \(counts.conflicted)") }
        return parts.joined(separator: " · ")
    }

    private static func countLabel(_ count: Int, unit: String) -> String {
        "\(max(count, 1)) \(unit)"
    }

    private static func basisSummary(snapshot: RepositorySnapshot) -> String {
        let counts = snapshot.changeCounts
        return [
            "branch \(snapshot.branch.isEmpty ? "unknown" : snapshot.branch)",
            "staged \(counts.staged)",
            "unstaged \(counts.unstaged)",
            "modified \(counts.modified)",
            "added \(counts.added)",
            "deleted \(counts.deleted)",
            "untracked \(counts.untracked)",
            "conflicted \(counts.conflicted)",
            "ahead \(snapshot.aheadCount ?? 0)",
            "behind \(snapshot.behindCount ?? 0)",
            "upstream \(snapshot.hasUpstream.map { String($0) } ?? "unknown")"
        ].joined(separator: " · ")
    }
}

/// Compatibility projection for existing readiness presentation components.
/// All repository business rules live in `RepositoryDecisionEngine`.
enum CommitReadinessEngine {
    static func assess(snapshot: RepositorySnapshot) -> CommitReadinessAssessment {
        RepositoryDecisionEngine.decide(snapshot: snapshot).commitReadiness
    }
}

enum RepositoryDecisionOrdering {
    static func precedes(
        _ lhs: RepositorySnapshot,
        _ rhs: RepositorySnapshot,
        prioritizePins: Bool = true
    ) -> Bool {
        if prioritizePins, lhs.isPinned != rhs.isPinned {
            return lhs.isPinned
        }

        let lhsDecision = lhs.decision
        let rhsDecision = rhs.decision
        if lhsDecision.sortPriority != rhsDecision.sortPriority {
            return lhsDecision.sortPriority < rhsDecision.sortPriority
        }

        let lhsReadiness = readinessPriority(lhsDecision.commitReadiness.level)
        let rhsReadiness = readinessPriority(rhsDecision.commitReadiness.level)
        if lhsReadiness != rhsReadiness {
            return lhsReadiness < rhsReadiness
        }

        let lhsSource = sourcePriority(lhsDecision.dataTrust)
        let rhsSource = sourcePriority(rhsDecision.dataTrust)
        if lhsSource != rhsSource {
            return lhsSource < rhsSource
        }

        // Retained values are useful for display, but they are not current
        // business facts and must not influence action-queue ranking.
        if lhsDecision.dataTrust != .current || rhsDecision.dataTrust != .current {
            let lhsAttempt = date(lhs.lastScannedAt)
            let rhsAttempt = date(rhs.lastScannedAt)
            if let lhsAttempt, let rhsAttempt, lhsAttempt != rhsAttempt {
                return lhsAttempt > rhsAttempt
            }
            if lhsAttempt != nil && rhsAttempt == nil { return true }
            if rhsAttempt != nil && lhsAttempt == nil { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        if lhs.risk != rhs.risk {
            return lhs.risk > rhs.risk
        }
        if (lhs.aheadCount ?? 0) != (rhs.aheadCount ?? 0) {
            return (lhs.aheadCount ?? 0) > (rhs.aheadCount ?? 0)
        }
        if lhs.changedFileCount != rhs.changedFileCount {
            return lhs.changedFileCount > rhs.changedFileCount
        }
        if (lhs.behindCount ?? 0) != (rhs.behindCount ?? 0) {
            return (lhs.behindCount ?? 0) > (rhs.behindCount ?? 0)
        }

        let lhsActivity = date(lhs.lastActivityAt ?? lhs.lastChangedAt)
        let rhsActivity = date(rhs.lastActivityAt ?? rhs.lastChangedAt)
        if let lhsActivity, let rhsActivity, lhsActivity != rhsActivity {
            return lhsActivity > rhsActivity
        }
        if lhsActivity != nil && rhsActivity == nil { return true }
        if rhsActivity != nil && lhsActivity == nil { return false }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func readinessPriority(_ level: CommitReadinessLevel) -> Int {
        switch level {
        case .unknown: return 0
        case .dirty: return 1
        case .review: return 2
        case .ready: return 3
        case .idle: return 4
        }
    }

    private static func sourcePriority(_ source: RepositoryDataSource) -> Int {
        switch source {
        case .unknown: return 0
        case .lastSuccessful: return 1
        case .current: return 2
        }
    }

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

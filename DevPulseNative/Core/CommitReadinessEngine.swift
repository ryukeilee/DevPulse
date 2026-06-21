import Foundation

enum CommitReadinessLevel: String, Codable, CaseIterable {
    case idle
    case review
    case ready
    case dirty
    case unknown

    var shortLabel: String {
        switch self {
        case .idle:
            return "Idle"
        case .review:
            return "Review"
        case .ready:
            return "Ready"
        case .dirty:
            return "Dirty"
        case .unknown:
            return "Unknown"
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

enum CommitReadinessEngine {
    enum Thresholds {
        static let dirtyChangedFiles = 5
        static let dirtyLooseFiles = 3
    }

    static func assess(snapshot: RepositorySnapshot) -> CommitReadinessAssessment {
        assess(
            status: snapshot.status,
            branch: snapshot.branch,
            risk: snapshot.risk,
            modifiedFileCount: snapshot.modifiedFileCount,
            addedFileCount: snapshot.addedFileCount,
            deletedFileCount: snapshot.deletedFileCount,
            untrackedFileCount: snapshot.untrackedFileCount,
            stagedFileCount: snapshot.stagedFileCount ?? 0,
            unstagedFileCount: snapshot.unstagedFileCount ?? (
                snapshot.modifiedFileCount + snapshot.addedFileCount + snapshot.deletedFileCount
            ),
            conflictedFileCount: snapshot.conflictedFileCount ?? 0,
            aheadCount: snapshot.aheadCount ?? 0,
            scanError: snapshot.errorMessage != nil
        )
    }

    static func assess(status: RepositoryStatus,
                       branch: String,
                       risk: RiskLevel,
                       modifiedFileCount: Int,
                       addedFileCount: Int,
                       deletedFileCount: Int,
                       untrackedFileCount: Int,
                       stagedFileCount: Int,
                       unstagedFileCount: Int,
                       conflictedFileCount: Int,
                       aheadCount: Int,
                       scanError: Bool) -> CommitReadinessAssessment {
        let changedFileCount = modifiedFileCount + addedFileCount + deletedFileCount + untrackedFileCount
        let branchNeedsConfirmation = branchNeedsConfirmation(branch)
        let looseFileCount = unstagedFileCount + untrackedFileCount
        let basis = basisSummary(
            branch: branch,
            modifiedFileCount: modifiedFileCount,
            addedFileCount: addedFileCount,
            deletedFileCount: deletedFileCount,
            untrackedFileCount: untrackedFileCount,
            stagedFileCount: stagedFileCount,
            unstagedFileCount: unstagedFileCount,
            conflictedFileCount: conflictedFileCount,
            aheadCount: aheadCount
        )

        if scanError || status == .error {
            return assessment(
                level: .unknown,
                reasons: [.scanError],
                detail: "Git 状态读取失败",
                nextStep: "先打开 Diagnostics，确认 Git 读取失败原因",
                widgetShortHint: "状态读取失败，先看 Diagnostics",
                basisSummary: basis
            )
        }

        if conflictedFileCount > 0 {
            return assessment(
                level: .dirty,
                reasons: [.conflictedFiles],
                detail: "存在 Git 冲突，先整理后再提交",
                nextStep: "先整理冲突，再继续审查或提交",
                widgetShortHint: "有冲突，先整理改动",
                basisSummary: basis
            )
        }

        if branchNeedsConfirmation {
            return assessment(
                level: .review,
                reasons: [.branchNeedsConfirmation],
                detail: "当前分支需要先确认，再决定提交或 push",
                nextStep: "先确认当前分支，再决定是否审查或提交",
                widgetShortHint: "先确认当前分支",
                basisSummary: basis
            )
        }

        if status == .clean || changedFileCount == 0 {
            if aheadCount > 0 {
                return assessment(
                    level: .ready,
                    reasons: [.localAhead],
                    detail: aheadCount == 1 ? "有 1 个本地提交可 Push" : "有 \(aheadCount) 个本地提交可 Push",
                    nextStep: "如已准备好分享改动，再决定是否继续 push",
                    widgetShortHint: aheadCount == 1 ? "已有 1 个本地提交，再决定是否 push" : "已有 \(aheadCount) 个本地提交，再决定是否 push",
                    basisSummary: basis
                )
            }

            return assessment(
                level: .idle,
                reasons: [.idleRepository],
                detail: "没有本地改动",
                nextStep: "暂无改动，暂时不用管",
                widgetShortHint: "暂无改动",
                basisSummary: basis
            )
        }

        if stagedFileCount > 0 && looseFileCount == 0 {
            return assessment(
                level: .ready,
                reasons: [.stagedChanges],
                detail: stagedFileCount == 1 ? "有 1 个已暂存改动，看起来可以提交" : "有 \(stagedFileCount) 个已暂存改动，看起来可以提交",
                nextStep: "如已自查改动范围，看起来可以提交",
                widgetShortHint: "看起来可以提交",
                basisSummary: basis
            )
        }

        if stagedFileCount > 0 {
            return assessment(
                level: .review,
                reasons: [.mixedStagedAndUnstagedChanges, .reviewBeforeCommit],
                detail: "已有暂存改动，但工作区还有未整理内容，提交前先确认范围",
                nextStep: "建议先审查暂存范围，再决定是否提交",
                widgetShortHint: "建议先审查暂存范围",
                basisSummary: basis
            )
        }

        if changedFileCount >= Thresholds.dirtyChangedFiles
            || looseFileCount >= Thresholds.dirtyLooseFiles
            || risk == .high {
            return assessment(
                level: .dirty,
                reasons: dirtyReasons(
                    risk: risk,
                    deletedFileCount: deletedFileCount,
                    untrackedFileCount: untrackedFileCount
                ),
                detail: "未整理改动较多，建议先收敛再提交",
                nextStep: "需要先整理改动，再继续审查或提交",
                widgetShortHint: "需要整理改动",
                basisSummary: basis
            )
        }

        if deletedFileCount > 0 {
            return assessment(
                level: .review,
                reasons: [.deletedFiles, .reviewBeforeCommit],
                detail: "提交前建议先检查删除项或跑一次验证",
                nextStep: "建议先审查删除项，再决定是否提交",
                widgetShortHint: "建议先审查删除项",
                basisSummary: basis
            )
        }

        if untrackedFileCount > 0 {
            return assessment(
                level: .review,
                reasons: [.untrackedFiles, .reviewBeforeCommit],
                detail: "有未跟踪文件，建议先看 diff 或确认是否纳入提交",
                nextStep: "建议先审查新文件，再决定是否提交",
                widgetShortHint: "建议先审查新文件",
                basisSummary: basis
            )
        }

        if risk == .medium {
            return assessment(
                level: .review,
                reasons: [.highRiskChanges, .reviewBeforeCommit],
                detail: "改动涉及中高风险区域，建议先看 diff 或跑验证",
                nextStep: "建议先审查改动并跑验证，再决定是否提交",
                widgetShortHint: "建议先审查并跑验证",
                basisSummary: basis
            )
        }

        return assessment(
            level: .review,
            reasons: [.lightweightChanges, .reviewBeforeCommit],
            detail: "有少量改动，建议先看 diff 或跑验证",
            nextStep: "建议先审查改动，再决定是否提交",
            widgetShortHint: "建议先审查改动",
            basisSummary: basis
        )
    }

    private static func assessment(level: CommitReadinessLevel,
                                   reasons: [CommitReadinessReason],
                                   detail: String,
                                   nextStep: String,
                                   widgetShortHint: String,
                                   basisSummary: String) -> CommitReadinessAssessment {
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

    private static func branchNeedsConfirmation(_ branch: String) -> Bool {
        let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "detached" || normalized == "unknown"
    }

    private static func dirtyReasons(risk: RiskLevel,
                                     deletedFileCount: Int,
                                     untrackedFileCount: Int) -> [CommitReadinessReason] {
        var reasons: [CommitReadinessReason] = [.largeWorkingTree]
        if deletedFileCount > 0 {
            reasons.append(.deletedFiles)
        }
        if untrackedFileCount > 0 {
            reasons.append(.untrackedFiles)
        }
        if risk == .high {
            reasons.append(.highRiskChanges)
        }
        return reasons
    }

    private static func basisSummary(branch: String,
                                     modifiedFileCount: Int,
                                     addedFileCount: Int,
                                     deletedFileCount: Int,
                                     untrackedFileCount: Int,
                                     stagedFileCount: Int,
                                     unstagedFileCount: Int,
                                     conflictedFileCount: Int,
                                     aheadCount: Int) -> String {
        [
            "branch \(branch.isEmpty ? "unknown" : branch)",
            "staged \(stagedFileCount)",
            "unstaged \(unstagedFileCount)",
            "modified \(modifiedFileCount)",
            "added \(addedFileCount)",
            "deleted \(deletedFileCount)",
            "untracked \(untrackedFileCount)",
            "conflicted \(conflictedFileCount)",
            "ahead \(aheadCount)"
        ].joined(separator: " · ")
    }
}

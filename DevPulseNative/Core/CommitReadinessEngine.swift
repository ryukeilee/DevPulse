import Foundation

enum CommitReadinessLevel: String, Codable, CaseIterable {
    case clean
    case inProgress
    case commitReady
    case needsReview
    case pushSuggested
    case attention

    var shortLabel: String {
        switch self {
        case .clean:
            return "干净"
        case .inProgress:
            return "开发中"
        case .commitReady:
            return "可提交"
        case .needsReview:
            return "待检查"
        case .pushSuggested:
            return "建议 Push"
        case .attention:
            return "需处理"
        }
    }
}

enum CommitReadinessReason: String, Codable, CaseIterable {
    case cleanRepository
    case smallWorkingChange
    case stagedChanges
    case moderateChangeSet
    case deletedFiles
    case untrackedFiles
    case highRiskChanges
    case localAhead
    case conflictedFiles
    case scanError
    case branchNeedsConfirmation
}

struct CommitReadinessAssessment: Equatable {
    let level: CommitReadinessLevel
    let reasons: [CommitReadinessReason]
    let shortLabel: String
    let detail: String
}

enum CommitReadinessEngine {
    enum Thresholds {
        static let inProgressMaxChangedFiles = 3
        static let commitReadyMinChangedFiles = 4
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
                       conflictedFileCount: Int,
                       aheadCount: Int,
                       scanError: Bool) -> CommitReadinessAssessment {
        let changedFileCount = modifiedFileCount + addedFileCount + deletedFileCount + untrackedFileCount
        let branchNeedsConfirmation = branchNeedsConfirmation(branch)

        if scanError || status == .error {
            return assessment(
                level: .attention,
                reasons: [.scanError],
                detail: "Git 状态读取失败"
            )
        }

        if conflictedFileCount > 0 {
            return assessment(
                level: .attention,
                reasons: [.conflictedFiles],
                detail: "请先处理 Git 冲突"
            )
        }

        if branchNeedsConfirmation {
            return assessment(
                level: .attention,
                reasons: [.branchNeedsConfirmation],
                detail: "请先确认当前分支状态"
            )
        }

        if status == .clean || changedFileCount == 0 {
            if aheadCount > 0 {
                return assessment(
                    level: .pushSuggested,
                    reasons: [.localAhead],
                    detail: aheadCount == 1 ? "有 1 个本地提交可 Push" : "有 \(aheadCount) 个本地提交可 Push"
                )
            }

            return assessment(
                level: .clean,
                reasons: [.cleanRepository],
                detail: "没有本地改动"
            )
        }

        if untrackedFileCount > 0 {
            return assessment(
                level: .needsReview,
                reasons: [.untrackedFiles],
                detail: "请先确认新增文件"
            )
        }

        if deletedFileCount > 0 {
            return assessment(
                level: .needsReview,
                reasons: [.deletedFiles],
                detail: "提交前请先检查删除项"
            )
        }

        if stagedFileCount > 0 {
            return assessment(
                level: .commitReady,
                reasons: [.stagedChanges],
                detail: stagedFileCount == 1 ? "有 1 个已暂存改动可提交" : "有 \(stagedFileCount) 个已暂存改动可提交"
            )
        }

        if changedFileCount >= Thresholds.commitReadyMinChangedFiles || risk != .low {
            let reasons: [CommitReadinessReason] = risk == .high ? [.highRiskChanges, .moderateChangeSet] : [.moderateChangeSet]
            return assessment(
                level: .commitReady,
                reasons: reasons,
                detail: "这组改动已经适合提交"
            )
        }

        if changedFileCount <= Thresholds.inProgressMaxChangedFiles {
            return assessment(
                level: .inProgress,
                reasons: [.smallWorkingChange],
                detail: "少量本地改动，仍在开发中"
            )
        }

        return assessment(
            level: .needsReview,
            reasons: [.highRiskChanges],
            detail: "请先检查当前改动集合"
        )
    }

    private static func assessment(level: CommitReadinessLevel,
                                   reasons: [CommitReadinessReason],
                                   detail: String) -> CommitReadinessAssessment {
        CommitReadinessAssessment(
            level: level,
            reasons: reasons,
            shortLabel: level.shortLabel,
            detail: detail
        )
    }

    private static func branchNeedsConfirmation(_ branch: String) -> Bool {
        let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "detached" || normalized == "unknown"
    }
}

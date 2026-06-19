import Foundation

enum CommitReadinessLevel: String, Codable, CaseIterable {
    case clean
    case ready
    case review
    case notReady

    var shortLabel: String {
        switch self {
        case .clean:
            return "Clean"
        case .ready:
            return "Ready"
        case .review:
            return "Review"
        case .notReady:
            return "Not Ready"
        }
    }
}

enum CommitReadinessReason: String, Codable, CaseIterable {
    case lowRiskSmallChange
    case mediumRisk
    case highRisk
    case manyChangedFiles
    case deletedFiles
    case manyDeletedFiles
    case untrackedFiles
    case manyUntrackedFiles
    case scanError
    case cleanRepository
    case unknown
}

struct CommitReadinessAssessment: Equatable {
    let level: CommitReadinessLevel
    let reasons: [CommitReadinessReason]
    let shortLabel: String
    let detail: String
}

enum CommitReadinessEngine {
    enum Thresholds {
        static let smallChangedFiles = 5
        static let manyChangedFiles = 20
        static let manyUntrackedFiles = 5
        static let manyDeletedFiles = 3
        static let smallUntrackedFiles = 2
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
                       scanError: Bool) -> CommitReadinessAssessment {
        let changedFileCount = modifiedFileCount + addedFileCount + deletedFileCount + untrackedFileCount
        let branchNeedsConfirmation = branchNeedsConfirmation(branch)

        if scanError || status == .error {
            return assessment(
                level: .notReady,
                reasons: [.scanError],
                detail: "Scan error"
            )
        }

        if status == .clean || changedFileCount == 0 {
            return assessment(
                level: .clean,
                reasons: [.cleanRepository],
                detail: "No local changes"
            )
        }

        if risk == .high
            || changedFileCount > Thresholds.manyChangedFiles
            || deletedFileCount > Thresholds.manyDeletedFiles
            || untrackedFileCount > Thresholds.manyUntrackedFiles {
            var reasons: [CommitReadinessReason] = []
            if risk == .high {
                reasons.append(.highRisk)
            }
            if changedFileCount > Thresholds.manyChangedFiles {
                reasons.append(.manyChangedFiles)
            }
            if deletedFileCount > Thresholds.manyDeletedFiles {
                reasons.append(.manyDeletedFiles)
            }
            if untrackedFileCount > Thresholds.manyUntrackedFiles {
                reasons.append(.manyUntrackedFiles)
            }

            return assessment(
                level: .notReady,
                reasons: reasons.isEmpty ? [.highRisk] : reasons,
                detail: "High-risk or large change set"
            )
        }

        var reviewReasons: [CommitReadinessReason] = []
        if risk == .medium {
            reviewReasons.append(.mediumRisk)
        }
        if changedFileCount > Thresholds.smallChangedFiles {
            reviewReasons.append(.manyChangedFiles)
        }
        if deletedFileCount > 0 {
            reviewReasons.append(.deletedFiles)
        }
        if untrackedFileCount > Thresholds.smallUntrackedFiles {
            reviewReasons.append(.untrackedFiles)
        }
        if branchNeedsConfirmation {
            reviewReasons.append(.unknown)
        }

        let qualifiesAsReady = risk == .low
            && changedFileCount <= Thresholds.smallChangedFiles
            && deletedFileCount == 0
            && untrackedFileCount <= Thresholds.smallUntrackedFiles
            && !branchNeedsConfirmation

        if qualifiesAsReady {
            return assessment(
                level: .ready,
                reasons: [.lowRiskSmallChange],
                detail: "Low-risk small change"
            )
        }

        if reviewReasons.isEmpty {
            reviewReasons = [.unknown]
        }

        return assessment(
            level: .review,
            reasons: reviewReasons,
            detail: reviewDetail(for: reviewReasons)
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

    private static func reviewDetail(for reasons: [CommitReadinessReason]) -> String {
        if reasons.contains(.manyChangedFiles) {
            return "Review larger change set"
        }
        if reasons.contains(.deletedFiles) || reasons.contains(.untrackedFiles) {
            return "Review deleted or untracked files"
        }
        if reasons.contains(.mediumRisk) {
            return "Medium-risk changes need review"
        }
        if reasons.contains(.unknown) {
            return "Review branch or status"
        }
        return "Review before committing"
    }
}

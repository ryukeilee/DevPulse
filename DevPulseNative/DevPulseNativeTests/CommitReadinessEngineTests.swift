import Foundation
import Testing
@testable import DevPulse

struct CommitReadinessEngineTests {
    @Test func cleanRepositoryIsClean() {
        let result = CommitReadinessEngine.assess(snapshot: snapshot())

        #expect(result.level == .clean)
        #expect(result.reasons == [.cleanRepository])
        #expect(result.shortLabel == "Clean")
        #expect(result.detail == "No local changes")
    }

    @Test func lowRiskSmallChangeIsReady() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 2,
                added: 1,
                risk: .low
            )
        )

        #expect(result.level == .ready)
        #expect(result.reasons == [.lowRiskSmallChange])
        #expect(result.shortLabel == "Ready")
        #expect(result.detail == "Low-risk small change")
    }

    @Test func mediumRiskIsReview() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 2,
                risk: .medium
            )
        )

        #expect(result.level == .review)
        #expect(result.reasons == [.mediumRisk])
        #expect(result.shortLabel == "Review")
        #expect(result.detail == "Medium-risk changes need review")
    }

    @Test func highRiskIsNotReady() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 1,
                risk: .high
            )
        )

        #expect(result.level == .notReady)
        #expect(result.reasons == [.highRisk])
        #expect(result.shortLabel == "Not Ready")
        #expect(result.detail == "High-risk or large change set")
    }

    @Test func manyChangedFilesIsNotReady() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 12,
                added: 10,
                risk: .low
            )
        )

        #expect(result.level == .notReady)
        #expect(result.reasons == [.manyChangedFiles])
    }

    @Test func deletedFilesAreReview() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 1,
                deleted: 1,
                risk: .low
            )
        )

        #expect(result.level == .review)
        #expect(result.reasons == [.deletedFiles])
        #expect(result.detail == "Review deleted or untracked files")
    }

    @Test func manyDeletedFilesAreNotReady() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 1,
                deleted: 4,
                risk: .low
            )
        )

        #expect(result.level == .notReady)
        #expect(result.reasons == [.manyDeletedFiles])
    }

    @Test func manyUntrackedFilesAreNotReady() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 1,
                untracked: 6,
                risk: .low
            )
        )

        #expect(result.level == .notReady)
        #expect(result.reasons == [.manyUntrackedFiles])
    }

    @Test func scanErrorIsNotReady() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                status: .error,
                errorMessage: "Failed to run git status"
            )
        )

        #expect(result.level == .notReady)
        #expect(result.reasons == [.scanError])
        #expect(result.detail == "Scan error")
    }

    private func snapshot(
        modified: Int = 0,
        added: Int = 0,
        deleted: Int = 0,
        untracked: Int = 0,
        risk: RiskLevel = .low,
        status: RepositoryStatus = .changed,
        branch: String = "main",
        errorMessage: String? = nil
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            id: "repo-1",
            name: "repo-1",
            path: "/tmp/repo-1",
            branch: branch,
            status: status,
            modifiedFileCount: modified,
            addedFileCount: added,
            deletedFileCount: deleted,
            untrackedFileCount: untracked,
            changedFileCount: modified + added + deleted + untracked,
            changedFilesPreview: [],
            risk: risk,
            lastScannedAt: "2026-06-19T00:00:00Z",
            lastChangedAt: nil,
            errorMessage: errorMessage,
            isPinned: false
        )
    }
}

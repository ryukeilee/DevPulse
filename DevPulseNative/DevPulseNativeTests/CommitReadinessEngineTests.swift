import Foundation
import Testing
@testable import DevPulse

struct CommitReadinessEngineTests {
    @Test func refreshStatusIsFreshWithinFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = now.addingTimeInterval(-4 * 60)

        #expect(RefreshStatusFormatter.freshness(for: snapshot, now: now) == .fresh)
        #expect(RefreshStatusFormatter.updateLabel(for: snapshot, now: now) == "4 分钟前更新")
    }

    @Test func refreshStatusBecomesAgingAfterFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = now.addingTimeInterval(-10 * 60)

        #expect(RefreshStatusFormatter.freshness(for: snapshot, now: now) == .aging)
        #expect(RefreshStatusFormatter.updateLabel(for: snapshot, now: now) == "10 分钟前更新")
    }

    @Test func refreshStatusBecomesStaleAfterFifteenMinutes() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = now.addingTimeInterval(-16 * 60)

        #expect(RefreshStatusFormatter.freshness(for: snapshot, now: now) == .stale)
    }

    @Test func refreshStatusUsesJustUpdatedWithinFirstMinute() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = now.addingTimeInterval(-20)

        #expect(RefreshStatusFormatter.updateLabel(for: snapshot, now: now) == "刚刚更新")
    }

    @Test func cleanRepositoryIsClean() {
        let result = CommitReadinessEngine.assess(snapshot: snapshot(status: .clean))

        #expect(result.level == .clean)
        #expect(result.reasons == [.cleanRepository])
        #expect(result.shortLabel == "干净")
        #expect(result.detail == "没有本地改动")
    }

    @Test func smallDirtyChangeIsInProgress() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 2,
                risk: .low
            )
        )

        #expect(result.level == .inProgress)
        #expect(result.reasons == [.smallWorkingChange])
        #expect(result.shortLabel == "开发中")
        #expect(result.detail == "少量本地改动，仍在开发中")
    }

    @Test func stagedChangesBecomeCommitReady() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 2,
                staged: 2,
                risk: .low
            )
        )

        #expect(result.level == .commitReady)
        #expect(result.reasons == [.stagedChanges])
        #expect(result.shortLabel == "可提交")
        #expect(result.detail == "有 2 个已暂存改动可提交")
    }

    @Test func moderateChangesBecomeCommitReady() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 4,
                risk: .low
            )
        )

        #expect(result.level == .commitReady)
        #expect(result.reasons == [.moderateChangeSet])
        #expect(result.detail == "这组改动已经适合提交")
    }

    @Test func untrackedFilesNeedReview() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 1,
                untracked: 1,
                risk: .low
            )
        )

        #expect(result.level == .needsReview)
        #expect(result.reasons == [.untrackedFiles])
        #expect(result.shortLabel == "待检查")
        #expect(result.detail == "请先确认新增文件")
    }

    @Test func aheadOfRemoteSuggestsPush() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                ahead: 2,
                status: .clean
            )
        )

        #expect(result.level == .pushSuggested)
        #expect(result.reasons == [.localAhead])
        #expect(result.shortLabel == "建议 Push")
        #expect(result.detail == "有 2 个本地提交可 Push")
    }

    @Test func scanErrorNeedsAttention() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                status: .error,
                errorMessage: "Failed to run git status"
            )
        )

        #expect(result.level == .attention)
        #expect(result.reasons == [.scanError])
        #expect(result.shortLabel == "需处理")
        #expect(result.detail == "Git 状态读取失败")
    }

    @Test func conflictedFilesNeedAttention() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 1,
                conflicted: 1
            )
        )

        #expect(result.level == .attention)
        #expect(result.reasons == [.conflictedFiles])
        #expect(result.detail == "请先处理 Git 冲突")
    }

    private func snapshot(
        modified: Int = 0,
        added: Int = 0,
        deleted: Int = 0,
        untracked: Int = 0,
        staged: Int = 0,
        conflicted: Int = 0,
        ahead: Int = 0,
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
            stagedFileCount: staged,
            conflictedFileCount: conflicted,
            aheadCount: ahead,
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

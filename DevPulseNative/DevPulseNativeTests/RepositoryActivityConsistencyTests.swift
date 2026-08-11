import Foundation
import Testing
@testable import DevPulse

/// 跨模块"最近活动时间"一致性测试：把同一份 `RepositorySnapshot` 夹具喂给
/// 项目健康概览（`RepositoryHealthOverviewBuilder`）、项目列表行
/// （`RepositoryListItemPresentationBuilder`）、Widget 侧共享派生
/// （`RepositorySnapshot.mostRecentActivityTimestamp` /
/// `ActivityTimelineItem.mostRecentActivityTimestamp`），断言各模块对
/// 同一输入产生一致的"最近活动"时间。
struct RepositoryActivityConsistencyTests {
    private let now = DateFormatting.date(from: "2026-07-16T12:00:00Z")!

    private func iso(_ offset: TimeInterval) -> String {
        DateFormatting.isoString(from: now.addingTimeInterval(offset))
    }

    private func snapshot(
        lastChangedAt: String?,
        lastActivityAt: String?,
        dataSource: RepositoryDataSource = .current
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            id: "repo-consistency",
            name: "Consistency",
            path: "/Users/test/Consistency",
            branch: "main",
            status: .changed,
            modifiedFileCount: 2,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 0,
            unstagedFileCount: 2,
            conflictedFileCount: 0,
            aheadCount: 0,
            behindCount: 0,
            hasUpstream: true,
            changedFileCount: 2,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: iso(0),
            dataSource: dataSource,
            lastSuccessfulScanAt: iso(0),
            lastChangedAt: lastChangedAt,
            lastCommitID: "0123456789abcdef",
            lastCommitSummary: "fixture commit",
            lastCommitMetadataAvailable: true,
            lastActivityAt: lastActivityAt,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )
    }

    // MARK: 新提交晚于旧活动标记 → 取较新的 lastChangedAt

    @Test func newerLastChangedAtWinsAcrossAllModules() {
        // 旧的 lastActivityAt（3 天前）不应遮住新提交（10 分钟前）。
        let repo = snapshot(
            lastChangedAt: iso(-600),
            lastActivityAt: iso(-3 * 86_400)
        )

        let expectedTimestamp = iso(-600)

        #expect(
            RepositorySnapshot.mostRecentActivityTimestamp(
                lastActivityAt: repo.lastActivityAt,
                lastChangedAt: repo.lastChangedAt,
                now: now
            ) == expectedTimestamp
        )
        #expect(
            RepositoryHealthOverviewBuilder.activityTimestamp(snapshot: repo, now: now)
                == expectedTimestamp
        )
        #expect(ActivityTimelineItem(from: repo).mostRecentActivityTimestamp == expectedTimestamp)

        let healthItem = RepositoryHealthOverviewBuilder.build(snapshots: [repo], now: now).first!
        let listPresentation = RepositoryListItemPresentationBuilder.build(snapshot: repo, now: now)
        #expect(healthItem.activityLabel == "10 分钟前")
        #expect(listPresentation.recentActivity == "10 分钟前")
    }

    // MARK: 工作区状态变化晚于最后提交 → 取较新的 lastActivityAt

    @Test func newerLastActivityAtWinsAcrossAllModules() {
        // 新提交较早（3 天前），工作区状态变化较新（10 分钟前）。
        let repo = snapshot(
            lastChangedAt: iso(-3 * 86_400),
            lastActivityAt: iso(-600)
        )

        let expectedTimestamp = iso(-600)

        #expect(
            RepositorySnapshot.mostRecentActivityTimestamp(
                lastActivityAt: repo.lastActivityAt,
                lastChangedAt: repo.lastChangedAt,
                now: now
            ) == expectedTimestamp
        )
        #expect(
            RepositoryHealthOverviewBuilder.activityTimestamp(snapshot: repo, now: now)
                == expectedTimestamp
        )
        #expect(ActivityTimelineItem(from: repo).mostRecentActivityTimestamp == expectedTimestamp)

        let healthItem = RepositoryHealthOverviewBuilder.build(snapshots: [repo], now: now).first!
        let listPresentation = RepositoryListItemPresentationBuilder.build(snapshot: repo, now: now)
        #expect(healthItem.activityLabel == "10 分钟前")
        #expect(listPresentation.recentActivity == "10 分钟前")
    }

    // MARK: 仅有一个时间戳

    @Test func singleTimestampIsUsedConsistently() {
        let repo = snapshot(lastChangedAt: iso(-7_200), lastActivityAt: nil)

        #expect(
            RepositoryHealthOverviewBuilder.activityTimestamp(snapshot: repo, now: now)
                == iso(-7_200)
        )
        #expect(ActivityTimelineItem(from: repo).mostRecentActivityTimestamp == iso(-7_200))

        let healthItem = RepositoryHealthOverviewBuilder.build(snapshots: [repo], now: now).first!
        let listPresentation = RepositoryListItemPresentationBuilder.build(snapshot: repo, now: now)
        #expect(healthItem.activityLabel == "2 小时前")
        #expect(listPresentation.recentActivity == "2 小时前")
    }

    // MARK: 无时间戳 / 未来时间戳

    @Test func missingTimestampsAreNoActivityInEveryModule() {
        let repo = snapshot(lastChangedAt: nil, lastActivityAt: nil)

        #expect(RepositorySnapshot.mostRecentActivityTimestamp(
            lastActivityAt: repo.lastActivityAt,
            lastChangedAt: repo.lastChangedAt,
            now: now
        ) == nil)
        #expect(
            RepositoryHealthOverviewBuilder.activityTimestamp(snapshot: repo, now: now) == nil
        )
        #expect(ActivityTimelineItem(from: repo).mostRecentActivityTimestamp == nil)

        let healthItem = RepositoryHealthOverviewBuilder.build(snapshots: [repo], now: now).first!
        let listPresentation = RepositoryListItemPresentationBuilder.build(snapshot: repo, now: now)
        #expect(healthItem.activityLabel == nil)
        #expect(listPresentation.recentActivity == "暂无活动记录")
    }

    @Test func futureTimestampsAreNotTreatedAsActivity() {
        // 未来时间戳（时钟偏差）不应显示为"刚刚活跃"，也不应遮住有效的旧时间戳。
        let futureOnly = snapshot(lastChangedAt: nil, lastActivityAt: iso(3_600))
        #expect(RepositorySnapshot.mostRecentActivityTimestamp(
            lastActivityAt: futureOnly.lastActivityAt,
            lastChangedAt: futureOnly.lastChangedAt,
            now: now
        ) == nil)
        let healthItem = RepositoryHealthOverviewBuilder.build(snapshots: [futureOnly], now: now).first!
        #expect(healthItem.activityDate == nil)

        let futureWithValid = snapshot(
            lastChangedAt: iso(-7_200),
            lastActivityAt: iso(3_600)
        )
        #expect(
            RepositoryHealthOverviewBuilder.activityTimestamp(snapshot: futureWithValid, now: now)
                == iso(-7_200)
        )
    }
}

import Foundation
import Testing
@testable import DevPulse

/// 项目健康概览派生逻辑测试：驱动真实的
/// `RepositoryHealthOverviewBuilder`（纯函数），以代表性 `RepositorySnapshot`
/// 断言活跃程度分级、扫描状态分类、仓库状态映射与混合集合的行组装排序。
struct RepositoryHealthOverviewTests {
    /// 固定参照时间，保证相对时间标签输出确定。
    private let now = DateFormatting.date(from: "2026-07-16T12:00:00Z")!

    private func iso(_ offset: TimeInterval) -> String {
        DateFormatting.isoString(from: now.addingTimeInterval(offset))
    }

    private func snapshot(
        id: String = "repo-1",
        name: String = "Repo",
        branch: String = "main",
        status: RepositoryStatus = .clean,
        modified: Int = 0,
        added: Int = 0,
        deleted: Int = 0,
        untracked: Int = 0,
        risk: RiskLevel = .low,
        dataSource: RepositoryDataSource = .current,
        lastSuccessfulScanAt: String? = nil,
        lastChangedAt: String? = nil,
        lastActivityAt: String? = nil,
        unavailableSince: String? = nil,
        errorMessage: String? = nil
    ) -> RepositorySnapshot {
        let changed = modified + added + deleted + untracked
        return RepositorySnapshot(
            id: id,
            name: name,
            path: "/Users/test/\(name)",
            branch: branch,
            status: status,
            modifiedFileCount: modified,
            addedFileCount: added,
            deletedFileCount: deleted,
            untrackedFileCount: untracked,
            stagedFileCount: 0,
            unstagedFileCount: 0,
            conflictedFileCount: 0,
            aheadCount: 0,
            behindCount: 0,
            hasUpstream: true,
            changedFileCount: changed,
            changedFilesPreview: [],
            risk: risk,
            lastScannedAt: iso(0),
            dataSource: dataSource,
            lastSuccessfulScanAt: lastSuccessfulScanAt,
            lastChangedAt: lastChangedAt,
            lastCommitID: nil,
            lastCommitSummary: nil,
            lastCommitMetadataAvailable: nil,
            lastActivityAt: lastActivityAt,
            unavailableSince: unavailableSince,
            errorMessage: errorMessage,
            isPinned: false
        )
    }

    // MARK: 活跃程度分级

    @Test func activityLevelActiveWithin24Hours() {
        let repo = snapshot(name: "Active", lastActivityAt: iso(-3_600))
        let item = RepositoryHealthOverviewBuilder.build(snapshots: [repo], now: now).first!
        #expect(item.activityLevel == .active)
        #expect(item.activityLabel == "1 小时前")
        #expect(item.activityDate == now.addingTimeInterval(-3_600))
    }

    @Test func activityLevelModerateWithinSevenDays() {
        let repo = snapshot(name: "Moderate", lastActivityAt: iso(-3 * 86_400))
        let item = RepositoryHealthOverviewBuilder.build(snapshots: [repo], now: now).first!
        #expect(item.activityLevel == .moderate)
        #expect(item.activityLabel == "3 天前")
    }

    @Test func activityLevelDormantBeyondSevenDays() {
        let repo = snapshot(name: "Dormant", lastActivityAt: iso(-10 * 86_400))
        let item = RepositoryHealthOverviewBuilder.build(snapshots: [repo], now: now).first!
        #expect(item.activityLevel == .dormant)
        #expect(item.activityLabel == "10 天前")
    }

    @Test func activityLevelNoActivityWithoutTimestamps() {
        let repo = snapshot(name: "NoActivity")
        let item = RepositoryHealthOverviewBuilder.build(snapshots: [repo], now: now).first!
        #expect(item.activityLevel == .noActivity)
        #expect(item.activityDate == nil)
        #expect(item.activityLabel == nil)
    }

    @Test func activityLevelDeterministicBoundaries() {
        let exactly24h = DateFormatting.date(from: iso(-86_400))
        let exactly7d = DateFormatting.date(from: iso(-7 * 86_400))
        let justOver7d = DateFormatting.date(from: iso(-7 * 86_400 - 1))

        #expect(RepositoryHealthOverviewBuilder.classifyActivityLevel(
            activityDate: exactly24h, now: now
        ) == .active)
        #expect(RepositoryHealthOverviewBuilder.classifyActivityLevel(
            activityDate: exactly7d, now: now
        ) == .moderate)
        #expect(RepositoryHealthOverviewBuilder.classifyActivityLevel(
            activityDate: justOver7d, now: now
        ) == .dormant)
        #expect(RepositoryHealthOverviewBuilder.classifyActivityLevel(
            activityDate: nil, now: now
        ) == .noActivity)
    }

    @Test func activityFallsBackToLastChangedAt() {
        let repo = snapshot(name: "Fallback", lastChangedAt: iso(-7_200))
        let item = RepositoryHealthOverviewBuilder.build(snapshots: [repo], now: now).first!
        #expect(item.activityLevel == .active)
        #expect(item.activityLabel == "2 小时前")
    }

    @Test func activityTimestampPrefersLastActivityAt() {
        let repo = snapshot(
            name: "Prefer",
            lastChangedAt: iso(-7_200),
            lastActivityAt: iso(-600)
        )
        let item = RepositoryHealthOverviewBuilder.build(snapshots: [repo], now: now).first!
        #expect(item.activityLabel == "10 分钟前")
        #expect(item.activityLevel == .active)
    }

    // MARK: 扫描状态分类

    @Test func scanStateCurrent() {
        let repo = snapshot(dataSource: .current)
        #expect(RepositoryHealthOverviewBuilder.classifyScanState(snapshot: repo) == .current)
    }

    @Test func scanStateLastSuccessful() {
        let repo = snapshot(
            dataSource: .lastSuccessful,
            lastSuccessfulScanAt: iso(-3_600)
        )
        #expect(RepositoryHealthOverviewBuilder.classifyScanState(snapshot: repo) == .lastSuccessful)
    }

    @Test func scanStateUnknown() {
        let repo = snapshot(dataSource: .unknown)
        #expect(RepositoryHealthOverviewBuilder.classifyScanState(snapshot: repo) == .unknown)
    }

    @Test func scanStateError() {
        let repo = snapshot(status: .error, dataSource: .unknown, errorMessage: "读取失败")
        #expect(RepositoryHealthOverviewBuilder.classifyScanState(snapshot: repo) == .error)
    }

    @Test func scanStateUnavailable() {
        let repo = snapshot(
            dataSource: .lastSuccessful,
            unavailableSince: iso(-3_600)
        )
        #expect(RepositoryHealthOverviewBuilder.classifyScanState(snapshot: repo) == .unavailable)
    }

    @Test func scanStateUnavailableTakesPriorityOverError() {
        let repo = snapshot(
            status: .error,
            dataSource: .unknown,
            unavailableSince: iso(-3_600),
            errorMessage: "仓库不可访问"
        )
        #expect(RepositoryHealthOverviewBuilder.classifyScanState(snapshot: repo) == .unavailable)
    }

    // MARK: 仓库状态映射

    @Test func repositoryStateClean() {
        let repo = snapshot(status: .clean)
        #expect(RepositoryHealthOverviewBuilder.repositoryState(for: repo) == .clean)
    }

    @Test func repositoryStateChangedCountsAllChanges() {
        let repo = snapshot(status: .changed, modified: 2, added: 1, untracked: 3)
        #expect(RepositoryHealthOverviewBuilder.repositoryState(for: repo) == .changed(count: 6))
    }

    @Test func repositoryStateError() {
        let repo = snapshot(status: .error, dataSource: .unknown, errorMessage: "读取失败")
        #expect(RepositoryHealthOverviewBuilder.repositoryState(for: repo) == .error)
    }

    // MARK: 行组装

    @Test func mixedCollectionOrdersByActivityDescending() {
        let active = snapshot(id: "a", name: "Active", lastActivityAt: iso(-600))
        let moderate = snapshot(id: "m", name: "Moderate", lastActivityAt: iso(-3 * 86_400))
        let dormant = snapshot(id: "d", name: "Dormant", lastActivityAt: iso(-20 * 86_400))
        let noActivity = snapshot(id: "n", name: "NoActivity")

        let items = RepositoryHealthOverviewBuilder.build(
            snapshots: [dormant, noActivity, active, moderate],
            now: now
        )

        #expect(items.map(\.id) == ["a", "m", "d", "n"])
        #expect(items[0].activityLevel == .active)
        #expect(items[1].activityLevel == .moderate)
        #expect(items[2].activityLevel == .dormant)
        #expect(items[3].activityLevel == .noActivity)
    }

    @Test func emptyCollectionProducesEmptyOverview() {
        let items = RepositoryHealthOverviewBuilder.build(snapshots: [], now: now)
        #expect(items.isEmpty)
    }

    @Test func itemCarriesAllFourDimensions() {
        let repo = snapshot(
            name: "AllDims",
            branch: "feature/x",
            status: .changed,
            modified: 3,
            risk: .medium,
            lastActivityAt: iso(-3_600)
        )
        let item = RepositoryHealthOverviewBuilder.build(snapshots: [repo], now: now).first!
        #expect(item.name == "AllDims")
        #expect(item.branch == "feature/x")
        #expect(item.risk == .medium)
        #expect(item.activityLabel == "1 小时前")
        #expect(item.repositoryState == .changed(count: 3))
        #expect(item.scanState == .current)
        #expect(item.activityLevel == .active)
    }

    // MARK: 文案（阈值与文案集中一处定义）

    @Test func dimensionLabels() {
        #expect(RepositoryHealthScanState.current.label == "当前数据")
        #expect(RepositoryHealthScanState.lastSuccessful.label == "上次成功")
        #expect(RepositoryHealthScanState.unknown.label == "来源未知")
        #expect(RepositoryHealthScanState.unavailable.label == "仓库不可用")
        #expect(RepositoryHealthScanState.error.label == "读取错误")

        #expect(RepositoryHealthRepoState.clean.label == "干净")
        #expect(RepositoryHealthRepoState.changed(count: 4).label == "4 处改动")
        #expect(RepositoryHealthRepoState.error.label == "读取错误")

        #expect(RepositoryActivityLevel.active.label == "活跃")
        #expect(RepositoryActivityLevel.moderate.label == "一般")
        #expect(RepositoryActivityLevel.dormant.label == "沉寂")
        #expect(RepositoryActivityLevel.noActivity.label == "无活动记录")
    }
}

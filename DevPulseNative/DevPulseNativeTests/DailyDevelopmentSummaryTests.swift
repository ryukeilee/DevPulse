import Foundation
import Testing
@testable import DevPulse

struct DailyDevelopmentSummaryTests {
    @Test func countsTodayCommitsProjectsAndIgnoresReadEvents() throws {
        let calendar = utcCalendar()
        let now = date("2026-07-20T12:00:00Z")
        let events = [
            event(id: "a-commit", repositoryID: "repo-a", name: "Alpha", kind: .newCommit, at: "2026-07-20T09:00:00Z"),
            event(id: "a-work", repositoryID: "repo-a", name: "Alpha", kind: .workingTreeChanged, at: "2026-07-20T09:10:00Z"),
            event(id: "b-branch", repositoryID: "repo-b", name: "Beta", kind: .branchChanged, at: "2026-07-20T10:00:00Z"),
            event(id: "b-read", repositoryID: "repo-b", name: "Beta", kind: .readFailed, at: "2026-07-20T10:30:00Z"),
            event(id: "old-commit", repositoryID: "repo-c", name: "Gamma", kind: .newCommit, at: "2026-07-19T09:00:00Z"),
            event(id: "old-work", repositoryID: "repo-c", name: "Gamma", kind: .workingTreeChanged, at: "2026-07-19T09:10:00Z")
        ]

        let summary = DailyDevelopmentSummaryBuilder.build(
            events: events,
            now: now,
            calendar: calendar
        )

        #expect(summary.commitCount == 1)
        #expect(summary.activeProjectCount == 2)
        #expect(summary.activityCount == 3)
        #expect(summary.focusMinutes == 30)
        #expect(summary.mostActiveProject?.id == "repo-a")
        #expect(summary.mostActiveProject?.name == "Alpha")
        #expect(summary.mostActiveProject?.activityCount == 2)
        #expect(summary.commitTrend.direction == .unchanged)
        #expect(summary.activeProjectTrend.direction == .increased)
        #expect(summary.focusTimeTrend.direction == .increased)
        #expect(summary.mostActiveProject?.trend.direction == .unavailable)
    }

    @Test func estimatesSeparateFocusSessionsWithMinimumDuration() {
        let calendar = utcCalendar()
        let now = date("2026-07-20T12:00:00Z")
        let events = [
            event(id: "first", repositoryID: "repo-a", name: "Alpha", kind: .workingTreeChanged, at: "2026-07-20T09:00:00Z"),
            event(id: "second", repositoryID: "repo-a", name: "Alpha", kind: .stagingChanged, at: "2026-07-20T09:30:00Z"),
            event(id: "third", repositoryID: "repo-a", name: "Alpha", kind: .branchChanged, at: "2026-07-20T11:00:00Z")
        ]

        let summary = DailyDevelopmentSummaryBuilder.build(
            events: events,
            now: now,
            calendar: calendar
        )

        // 09:00–09:30 plus one 15-minute single-event session.
        #expect(summary.focusMinutes == 45)
    }

    @Test func comparesWithRecentDailyAverageAndReportsUnchangedWhenEqual() {
        let calendar = utcCalendar()
        let now = date("2026-07-20T12:00:00Z")
        var events = [
            event(id: "today", repositoryID: "repo-a", name: "Alpha", kind: .newCommit, at: "2026-07-20T09:00:00Z")
        ]

        for offset in 1...DailyDevelopmentSummaryBuilder.recentComparisonDays {
            let day = calendar.date(
                byAdding: .day,
                value: -offset,
                to: calendar.startOfDay(for: now)
            )!
            events.append(event(
                id: "previous-\(offset)",
                repositoryID: "repo-a",
                name: "Alpha",
                kind: .newCommit,
                at: DateFormatting.isoString(from: day.addingTimeInterval(9 * 60 * 60))
            ))
        }

        let summary = DailyDevelopmentSummaryBuilder.build(
            events: events,
            now: now,
            calendar: calendar
        )

        #expect(summary.commitCount == 1)
        #expect(summary.commitTrend.direction == .unchanged)
        #expect(summary.commitTrend.recentDailyAverage == 1)
        #expect(summary.activeProjectTrend.direction == .unchanged)
    }

    @Test func sparseHistoryUsesOnlyDaysWithActivityForAverage() {
        let calendar = utcCalendar()
        let now = date("2026-07-20T12:00:00Z")
        let events = [
            event(id: "today", repositoryID: "repo-a", name: "Alpha", kind: .newCommit, at: "2026-07-20T09:00:00Z"),
            event(id: "previous", repositoryID: "repo-a", name: "Alpha", kind: .newCommit, at: "2026-07-18T09:00:00Z")
        ]

        let summary = DailyDevelopmentSummaryBuilder.build(
            events: events,
            now: now,
            calendar: calendar
        )

        #expect(summary.commitTrend.direction == .unchanged)
        #expect(summary.commitTrend.recentDailyAverage == 1)
        #expect(summary.comparisonActivityDayCount == 1)
    }

    @Test func excludesFutureAndReadOnlyEventsAndShowsUnavailableTrendWithoutHistory() {
        let calendar = utcCalendar()
        let now = date("2026-07-20T00:30:00Z")
        let events = [
            event(id: "yesterday", repositoryID: "repo-a", name: "Alpha", kind: .newCommit, at: "2026-07-19T23:59:00Z"),
            event(id: "today-read", repositoryID: "repo-b", name: "Beta", kind: .readRecovered, at: "2026-07-20T00:10:00Z"),
            event(id: "future", repositoryID: "repo-c", name: "Gamma", kind: .newCommit, at: "2026-07-20T01:00:00Z")
        ]

        let summary = DailyDevelopmentSummaryBuilder.build(
            events: events,
            now: now,
            calendar: calendar
        )

        #expect(summary.commitCount == 0)
        #expect(summary.activeProjectCount == 0)
        #expect(summary.focusMinutes == 0)
        #expect(summary.mostActiveProject == nil)
        #expect(summary.commitTrend.direction == .decreased)
        #expect(summary.activeProjectTrend.direction == .decreased)
        #expect(summary.focusTimeTrend.direction == .decreased)
    }

    @Test func readFailuresAreExcludedButExposedAsDataWarning() {
        let calendar = utcCalendar()
        let summary = DailyDevelopmentSummaryBuilder.build(
            events: [
                event(id: "failed", repositoryID: "repo-a", name: "Alpha", kind: .readFailed, at: "2026-07-20T09:00:00Z"),
                event(id: "work", repositoryID: "repo-b", name: "Beta", kind: .workingTreeChanged, at: "2026-07-20T10:00:00Z")
            ],
            now: date("2026-07-20T12:00:00Z"),
            calendar: calendar
        )

        #expect(summary.activityCount == 1)
        #expect(summary.activeProjectCount == 1)
        #expect(summary.unavailableProjectCount == 1)
        #expect(summary.hasDataWarning)
    }

    @Test func readFailureCarriesOverFromEarlierDayUntilRecovery() {
        // 昨日已失败、今日仍不可读的仓库没有新的 readFailed 事件，
        // 但今日统计确实缺该仓库数据，完整性警告不应漏报。
        let calendar = utcCalendar()
        let summary = DailyDevelopmentSummaryBuilder.build(
            events: [
                event(id: "failed-yesterday", repositoryID: "repo-a", name: "Alpha", kind: .readFailed, at: "2026-07-19T09:00:00Z")
            ],
            now: date("2026-07-20T12:00:00Z"),
            calendar: calendar
        )

        #expect(summary.activityCount == 0)
        #expect(summary.unavailableProjectCount == 1)
        #expect(summary.hasDataWarning)
    }

    @Test func readFailureClearedByLaterRecovery() {
        // 昨日失败后已恢复：最新读取状态为 readRecovered，不再计入警告。
        let calendar = utcCalendar()
        let summary = DailyDevelopmentSummaryBuilder.build(
            events: [
                event(id: "failed", repositoryID: "repo-a", name: "Alpha", kind: .readFailed, at: "2026-07-19T09:00:00Z"),
                event(id: "recovered", repositoryID: "repo-a", name: "Alpha", kind: .readRecovered, at: "2026-07-20T08:00:00Z")
            ],
            now: date("2026-07-20T12:00:00Z"),
            calendar: calendar
        )

        #expect(summary.unavailableProjectCount == 0)
        #expect(!summary.hasDataWarning)
    }

    @Test func readFailureRecountedAfterLatestFailure() {
        // 失败→恢复→再失败：最新读取状态为 readFailed，计入警告。
        let calendar = utcCalendar()
        let summary = DailyDevelopmentSummaryBuilder.build(
            events: [
                event(id: "failed-1", repositoryID: "repo-a", name: "Alpha", kind: .readFailed, at: "2026-07-18T09:00:00Z"),
                event(id: "recovered", repositoryID: "repo-a", name: "Alpha", kind: .readRecovered, at: "2026-07-19T09:00:00Z"),
                event(id: "failed-2", repositoryID: "repo-a", name: "Alpha", kind: .readFailed, at: "2026-07-20T09:00:00Z")
            ],
            now: date("2026-07-20T12:00:00Z"),
            calendar: calendar
        )

        #expect(summary.unavailableProjectCount == 1)
        #expect(summary.hasDataWarning)
    }

    @Test func readFailureOlderThanComparisonWindowStillCountsUntilRecovery() {
        // 仓库连续失败超过 7 天比较窗口（窗口外只有一条 readFailed，无新事件），
        // 今日统计确实缺该仓库数据，完整性警告不应漏报。
        let calendar = utcCalendar()
        let summary = DailyDevelopmentSummaryBuilder.build(
            events: [
                event(id: "failed-old", repositoryID: "repo-a", name: "Alpha", kind: .readFailed, at: "2026-07-10T09:00:00Z")
            ],
            now: date("2026-07-20T12:00:00Z"),
            calendar: calendar
        )

        #expect(summary.activityCount == 0)
        #expect(summary.unavailableProjectCount == 1)
        #expect(summary.hasDataWarning)
    }

    @Test func readFailureOlderThanWindowClearedByLaterRecovery() {
        // 窗口外失败、稍后已恢复：最新读取状态为 readRecovered，不再计入警告。
        let calendar = utcCalendar()
        let summary = DailyDevelopmentSummaryBuilder.build(
            events: [
                event(id: "failed-old", repositoryID: "repo-a", name: "Alpha", kind: .readFailed, at: "2026-07-08T09:00:00Z"),
                event(id: "recovered-old", repositoryID: "repo-a", name: "Alpha", kind: .readRecovered, at: "2026-07-12T09:00:00Z")
            ],
            now: date("2026-07-20T12:00:00Z"),
            calendar: calendar
        )

        #expect(summary.unavailableProjectCount == 0)
        #expect(!summary.hasDataWarning)
    }

    @Test func noActivityHistoryProducesUnavailableTrends() {
        let calendar = utcCalendar()
        let summary = DailyDevelopmentSummaryBuilder.build(
            events: [
                event(id: "read", repositoryID: "repo-a", name: "Alpha", kind: .readFailed, at: "2026-07-20T09:00:00Z")
            ],
            now: date("2026-07-20T12:00:00Z"),
            calendar: calendar
        )

        #expect(!summary.hasActivity)
        #expect(summary.commitTrend.direction == .unavailable)
        #expect(summary.activeProjectTrend.direction == .unavailable)
        #expect(summary.focusTimeTrend.direction == .unavailable)
    }

    // MARK: 展示层可信口径：未成功扫描当日不得伪装成 0 统计

    @Test func noSuccessfulScanTodayMeansTodayCountsAreUnknown() {
        let calendar = utcCalendar()
        let now = date("2026-07-20T12:00:00Z")

        // 首次运行（从未成功扫描）：今天没有观察，计数必须视为未知。
        #expect(!DailyDevelopmentSummaryPresentationBuilder.hasReliableTodayCounts(
            lastSuccessfulScanAt: nil,
            now: now,
            calendar: calendar
        ))
        // 上次成功扫描在昨天：今天尚未观察，不能把 0 当作真实统计。
        #expect(!DailyDevelopmentSummaryPresentationBuilder.hasReliableTodayCounts(
            lastSuccessfulScanAt: date("2026-07-19T12:00:00Z"),
            now: now,
            calendar: calendar
        ))
        // 今天任意时刻成功扫描过：今天计数可信（覆盖当日跨日边界两端）。
        #expect(DailyDevelopmentSummaryPresentationBuilder.hasReliableTodayCounts(
            lastSuccessfulScanAt: date("2026-07-20T00:00:01Z"),
            now: now,
            calendar: calendar
        ))
        #expect(DailyDevelopmentSummaryPresentationBuilder.hasReliableTodayCounts(
            lastSuccessfulScanAt: date("2026-07-20T23:59:59Z"),
            now: now,
            calendar: calendar
        ))
    }

    // MARK: 趋势文案：下降方向取绝对值，不出现 "↓ -N" 双重负号

    @Test func trendLabelUsesAbsoluteValueForDecreasedDirection() {
        let decreased = DailyDevelopmentSummary.Trend(
            direction: .decreased,
            delta: -5,
            recentDailyAverage: 8,
            comparisonDayCount: 3
        )
        #expect(DailyDevelopmentSummaryPresentationBuilder.trendValueLabel(
            for: decreased, unit: .count
        ) == "↓ 5")
        #expect(DailyDevelopmentSummaryPresentationBuilder.trendValueLabel(
            for: decreased, unit: .minutes
        ) == "↓ 5 分钟")

        let increased = DailyDevelopmentSummary.Trend(
            direction: .increased,
            delta: 3,
            recentDailyAverage: 1,
            comparisonDayCount: 3
        )
        #expect(DailyDevelopmentSummaryPresentationBuilder.trendValueLabel(
            for: increased, unit: .count
        ) == "↑ +3")
        #expect(DailyDevelopmentSummaryPresentationBuilder.trendValueLabel(
            for: increased, unit: .minutes
        ) == "↑ +3 分钟")

        let unchanged = DailyDevelopmentSummary.Trend(
            direction: .unchanged,
            delta: 0,
            recentDailyAverage: 2,
            comparisonDayCount: 3
        )
        #expect(DailyDevelopmentSummaryPresentationBuilder.trendValueLabel(
            for: unchanged, unit: .count
        ) == "→ 持平")

        let unavailable = DailyDevelopmentSummary.Trend.unavailable(comparisonDayCount: 0)
        #expect(DailyDevelopmentSummaryPresentationBuilder.trendValueLabel(
            for: unavailable, unit: .count
        ) == "— 暂无可比")
    }

    @Test func trendDeltaFormattingHandlesNilAndFractionalValues() {
        #expect(DailyDevelopmentSummaryPresentationBuilder.formattedDelta(nil, unit: .count) == "—")
        #expect(DailyDevelopmentSummaryPresentationBuilder.formattedDelta(2.5, unit: .count) == "2.5")
        #expect(DailyDevelopmentSummaryPresentationBuilder.formattedDelta(2.0, unit: .count) == "2")
        #expect(DailyDevelopmentSummaryPresentationBuilder.formattedDelta(-2.5, unit: .minutes) == "-2.5 分钟")
    }

    @Test func trendComparisonLabelUsesActivityDayCount() {
        let trend = DailyDevelopmentSummary.Trend(
            direction: .increased,
            delta: 2,
            recentDailyAverage: 1,
            comparisonDayCount: 3
        )
        #expect(DailyDevelopmentSummaryPresentationBuilder.trendComparisonLabel(for: trend) == "较 3 个有活动日")
        #expect(DailyDevelopmentSummaryPresentationBuilder.trendComparisonLabel(
            for: .unavailable(comparisonDayCount: 0)
        ) == "暂无历史活动")
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        DateFormatting.date(from: value)!
    }

    private func event(
        id: String,
        repositoryID: String,
        name: String,
        kind: ActivityEventKind,
        at: String
    ) -> ActivityEvent {
        ActivityEvent(
            id: id,
            repositoryID: repositoryID,
            repositoryName: name,
            kind: kind,
            occurredAt: at,
            before: state(commitID: "before-\(id)"),
            after: state(commitID: "after-\(id)")
        )
    }

    private func state(commitID: String) -> ActivityEventState {
        ActivityEventState(snapshot: RepositorySnapshot(
            id: "state-\(commitID)",
            name: "Fixture",
            path: "/tmp/fixture-\(commitID)",
            branch: "main",
            status: .clean,
            modifiedFileCount: 0,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 0,
            unstagedFileCount: 0,
            conflictedFileCount: 0,
            aheadCount: 0,
            behindCount: 0,
            hasUpstream: true,
            changedFileCount: 0,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: "2026-07-20T12:00:00Z",
            dataSource: .current,
            lastSuccessfulScanAt: "2026-07-20T12:00:00Z",
            lastChangedAt: nil,
            lastCommitID: commitID,
            lastCommitSummary: "activity",
            lastCommitMetadataAvailable: true,
            lastActivityAt: nil,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        ))
    }
}

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

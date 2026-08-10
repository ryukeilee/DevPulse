import Foundation

/// A compact, local-only view of the development activity already collected by
/// the refresh pipeline. It deliberately does not read repositories or start a
/// scan of its own.
struct DailyDevelopmentSummary: Equatable {
    enum TrendDirection: Equatable {
        case increased
        case decreased
        case unchanged
        case unavailable
    }

    struct Trend: Equatable {
        let direction: TrendDirection
        /// Today's value minus the recent daily average.
        let delta: Double?
        let recentDailyAverage: Double?
        let comparisonDayCount: Int

        static func unavailable(comparisonDayCount: Int) -> Trend {
            Trend(
                direction: .unavailable,
                delta: nil,
                recentDailyAverage: nil,
                comparisonDayCount: comparisonDayCount
            )
        }
    }

    struct MostActiveProject: Equatable, Identifiable {
        let id: String
        let name: String
        let activityCount: Int
        let trend: Trend
    }

    /// Number of scan-detected latest-commit transitions. This is not a full
    /// `git log` count because the refresh pipeline only records transitions.
    let commitCount: Int
    let activeProjectCount: Int
    /// Number of development-change records retained for today.
    let activityCount: Int
    /// Estimated minutes based on contiguous activity-event sessions.
    let focusMinutes: Int
    let mostActiveProject: MostActiveProject?
    let commitTrend: Trend
    let activeProjectTrend: Trend
    let focusTimeTrend: Trend
    let comparisonDayCount: Int
    /// Number of previous days that contain development-change records and
    /// therefore provide a meaningful daily-average comparison.
    let comparisonActivityDayCount: Int
    /// Repositories that had a read failure today. Development counts exclude
    /// those events, but the UI should still make the incomplete data visible.
    let unavailableProjectCount: Int

    var hasActivity: Bool {
        activityCount > 0
    }

    var hasDataWarning: Bool {
        unavailableProjectCount > 0
    }
}

enum DailyDevelopmentSummaryBuilder {
    /// The activity archive is bounded, so seven days is long enough to give
    /// the UI a useful comparison without implying a long-term history store.
    static let recentComparisonDays = 7

    /// Two events farther apart than this start separate focus sessions.
    static let focusSessionGap: TimeInterval = 45 * 60

    /// A single scan-discovered event represents a small unit of activity, not
    /// zero minutes. This prevents a one-event day from rendering as "0".
    static let minimumFocusSession: TimeInterval = 15 * 60

    static func build(
        events: [ActivityEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyDevelopmentSummary {
        let comparisonDayCount = recentComparisonDays
        let todayStart = calendar.startOfDay(for: now)
        let historyStart = calendar.date(
            byAdding: .day,
            value: -comparisonDayCount,
            to: todayStart
        ) ?? todayStart

        var buckets: [Date: DayBucket] = [:]
        for event in events {
            guard let date = DateFormatting.date(from: event.occurredAt),
                  date >= historyStart,
                  date <= now else {
                continue
            }

            let day = calendar.startOfDay(for: date)
            guard day <= todayStart else { continue }

            if event.kind == .readFailed {
                buckets[day, default: DayBucket()]
                    .unavailableProjectIDs
                    .insert(event.repositoryID)
                continue
            }
            guard isDevelopmentActivity(event.kind) else { continue }

            buckets[day, default: DayBucket()].add(
                event: event,
                date: date
            )
        }

        let today = buckets[todayStart] ?? DayBucket()
        let previousBuckets: [DayBucket] = (1...comparisonDayCount).compactMap { offset -> DayBucket? in
            guard let day = calendar.date(
                byAdding: .day,
                value: -offset,
                to: todayStart
            ) else {
                return nil
            }
            return buckets[day] ?? DayBucket()
        }
        let previousActivityBuckets = previousBuckets.filter { !$0.timestamps.isEmpty }
        let comparisonActivityDayCount = previousActivityBuckets.count

        let commitTrend = trend(
            value: Double(today.commitCount),
            previousValues: previousActivityBuckets.map { Double($0.commitCount) },
            comparisonDayCount: comparisonActivityDayCount
        )
        let activeProjectTrend = trend(
            value: Double(today.projectIDs.count),
            previousValues: previousActivityBuckets.map { Double($0.projectIDs.count) },
            comparisonDayCount: comparisonActivityDayCount
        )
        let focusTimeTrend = trend(
            value: Double(focusMinutes(for: today.timestamps)),
            previousValues: previousActivityBuckets.map {
                Double(focusMinutes(for: $0.timestamps))
            },
            comparisonDayCount: comparisonActivityDayCount
        )

        let mostActiveProject = topProject(
            in: today,
            previousBuckets: previousBuckets
        )

        return DailyDevelopmentSummary(
            commitCount: today.commitCount,
            activeProjectCount: today.projectIDs.count,
            activityCount: today.timestamps.count,
            focusMinutes: focusMinutes(for: today.timestamps),
            mostActiveProject: mostActiveProject,
            commitTrend: commitTrend,
            activeProjectTrend: activeProjectTrend,
            focusTimeTrend: focusTimeTrend,
            comparisonDayCount: comparisonDayCount,
            comparisonActivityDayCount: comparisonActivityDayCount,
            unavailableProjectCount: today.unavailableProjectIDs.count
        )
    }

    private struct DayBucket {
        var commitCount = 0
        var projectIDs = Set<String>()
        var timestamps: [Date] = []
        var activityCountsByProject: [String: Int] = [:]
        var namesByProject: [String: String] = [:]
        var latestActivityByProject: [String: Date] = [:]
        var unavailableProjectIDs = Set<String>()

        mutating func add(event: ActivityEvent, date: Date) {
            if event.kind == .newCommit {
                commitCount += 1
            }
            projectIDs.insert(event.repositoryID)
            timestamps.append(date)
            activityCountsByProject[event.repositoryID, default: 0] += 1

            if let previousDate = latestActivityByProject[event.repositoryID],
               previousDate >= date {
                return
            }
            latestActivityByProject[event.repositoryID] = date
            namesByProject[event.repositoryID] = event.repositoryName
        }
    }

    private static func isDevelopmentActivity(_ kind: ActivityEventKind) -> Bool {
        switch kind {
        case .readFailed, .readRecovered:
            return false
        case .newCommit, .workingTreeChanged, .stagingChanged, .branchChanged,
             .synchronizationChanged, .conflictStarted, .conflictResolved:
            return true
        }
    }

    private static func focusMinutes(for timestamps: [Date]) -> Int {
        let sorted = timestamps.sorted()
        guard let first = sorted.first else { return 0 }

        var sessionStart = first
        var lastActivity = first
        var total: TimeInterval = 0

        for date in sorted.dropFirst() {
            if date.timeIntervalSince(lastActivity) > focusSessionGap {
                total += sessionDuration(from: sessionStart, to: lastActivity)
                sessionStart = date
            }
            lastActivity = date
        }
        total += sessionDuration(from: sessionStart, to: lastActivity)

        return max(0, Int((total / 60).rounded()))
    }

    private static func sessionDuration(from start: Date, to end: Date) -> TimeInterval {
        max(minimumFocusSession, end.timeIntervalSince(start))
    }

    private static func topProject(
        in bucket: DayBucket,
        previousBuckets: [DayBucket]
    ) -> DailyDevelopmentSummary.MostActiveProject? {
        guard !bucket.activityCountsByProject.isEmpty else { return nil }

        let candidateIDs = bucket.activityCountsByProject.keys.sorted { lhs, rhs in
            let lhsCount = bucket.activityCountsByProject[lhs, default: 0]
            let rhsCount = bucket.activityCountsByProject[rhs, default: 0]
            if lhsCount != rhsCount { return lhsCount > rhsCount }

            let lhsDate = bucket.latestActivityByProject[lhs] ?? .distantPast
            let rhsDate = bucket.latestActivityByProject[rhs] ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }

            let lhsName = bucket.namesByProject[lhs] ?? lhs
            let rhsName = bucket.namesByProject[rhs] ?? rhs
            let nameOrder = lhsName.localizedStandardCompare(rhsName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs < rhs
        }

        guard let id = candidateIDs.first else { return nil }
        let previousValues = previousBuckets.compactMap { bucket -> Double? in
            guard let count = bucket.activityCountsByProject[id], count > 0 else {
                return nil
            }
            return Double(count)
        }

        return DailyDevelopmentSummary.MostActiveProject(
            id: id,
            name: bucket.namesByProject[id] ?? id,
            activityCount: bucket.activityCountsByProject[id, default: 0],
            trend: trend(
                value: Double(bucket.activityCountsByProject[id, default: 0]),
                previousValues: previousValues,
                comparisonDayCount: previousValues.count
            )
        )
    }

    private static func trend(
        value: Double,
        previousValues: [Double],
        comparisonDayCount: Int
    ) -> DailyDevelopmentSummary.Trend {
        guard !previousValues.isEmpty else {
            return .unavailable(comparisonDayCount: comparisonDayCount)
        }

        let average = previousValues.reduce(0, +) / Double(previousValues.count)
        let delta = value - average
        let direction: DailyDevelopmentSummary.TrendDirection
        if abs(delta) < 0.01 {
            direction = .unchanged
        } else if delta > 0 {
            direction = .increased
        } else {
            direction = .decreased
        }

        return DailyDevelopmentSummary.Trend(
            direction: direction,
            delta: delta,
            recentDailyAverage: average,
            comparisonDayCount: comparisonDayCount
        )
    }
}

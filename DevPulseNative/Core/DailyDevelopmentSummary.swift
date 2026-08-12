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
    /// Repositories whose latest read state within the comparison window is a
    /// read failure (including failures that started on earlier days and have
    /// not recovered). Development counts exclude those events, but the UI
    /// should still make the incomplete data visible.
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
        // 仓库读取状态按完整事件归档跟踪（不受 7 天比较窗口限制）：
        // 可读 → 不可读只产生一次 readFailed 事件，若仓库连续失败超过窗口，
        // 仅靠窗口内事件会漏掉"统计可能不完整"警告；readRecovered 为最新时
        // 说明已恢复，不计入警告。
        var latestReadStateByRepository: [String: (kind: ActivityEventKind, date: Date)] = [:]
        for event in events {
            guard let date = DateFormatting.date(from: event.occurredAt),
                  date <= now else {
                continue
            }

            if event.kind == .readFailed || event.kind == .readRecovered {
                if let existing = latestReadStateByRepository[event.repositoryID] {
                    if existing.date < date {
                        latestReadStateByRepository[event.repositoryID] = (kind: event.kind, date: date)
                    }
                } else {
                    latestReadStateByRepository[event.repositoryID] = (kind: event.kind, date: date)
                }
                continue
            }
            guard isDevelopmentActivity(event.kind), date >= historyStart else { continue }

            let day = calendar.startOfDay(for: date)
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

        let todayFocusMinutes = focusMinutes(for: today.timestamps)
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
            value: Double(todayFocusMinutes),
            previousValues: previousActivityBuckets.map {
                Double(focusMinutes(for: $0.timestamps))
            },
            comparisonDayCount: comparisonActivityDayCount
        )

        let mostActiveProject = topProject(
            in: today,
            previousBuckets: previousBuckets
        )

        let unavailableProjectCount = latestReadStateByRepository.values
            .filter { $0.kind == .readFailed }
            .count

        return DailyDevelopmentSummary(
            commitCount: today.commitCount,
            activeProjectCount: today.projectIDs.count,
            activityCount: today.timestamps.count,
            focusMinutes: todayFocusMinutes,
            mostActiveProject: mostActiveProject,
            commitTrend: commitTrend,
            activeProjectTrend: activeProjectTrend,
            focusTimeTrend: focusTimeTrend,
            comparisonDayCount: comparisonDayCount,
            comparisonActivityDayCount: comparisonActivityDayCount,
            unavailableProjectCount: unavailableProjectCount
        )
    }

    private struct DayBucket {
        var commitCount = 0
        var projectIDs = Set<String>()
        var timestamps: [Date] = []
        var activityCountsByProject: [String: Int] = [:]
        var namesByProject: [String: String] = [:]
        var latestActivityByProject: [String: Date] = [:]

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

// MARK: - 展示层可信口径与趋势文案（纯派生，无 I/O）

/// 「今日摘要」与「开发趋势」展示层共用的可信口径与文案。
///
/// 关键规则：只有当今天发生过一次成功扫描时，今天的事件计数才代表对今天
/// 的完整观察；否则这些数字是"未扫描"而非"0 活动"。视图据此把未知态显示
/// 为 "—"/等待扫描，而不是把未扫描伪装成 0 统计或"今天大幅下降"的趋势。
enum DailyDevelopmentSummaryPresentationBuilder {
    /// 今天是否已有一次成功扫描。返回 false 时，今日计数与今日相对历史的
    /// 趋势都不应作为真实观察展示（首次运行、跨日未扫描都属于这种情况）。
    static func hasReliableTodayCounts(
        lastSuccessfulScanAt: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let lastSuccessfulScanAt else { return false }
        return calendar.isDate(lastSuccessfulScanAt, inSameDayAs: now)
    }

    enum TrendUnit: Equatable {
        case count
        case minutes
    }

    /// 趋势主标签：上升 / 下降 / 持平 / 不可比。
    /// 下降方向取绝对值，避免 delta 为负时显示 "↓ -N" 双重负号。
    static func trendValueLabel(
        for trend: DailyDevelopmentSummary.Trend,
        unit: TrendUnit
    ) -> String {
        switch trend.direction {
        case .increased:
            return "↑ +\(formattedDelta(trend.delta, unit: unit))"
        case .decreased:
            return "↓ \(formattedDelta(trend.delta.map { -$0 }, unit: unit))"
        case .unchanged:
            return "→ 持平"
        case .unavailable:
            return "— 暂无可比"
        }
    }

    static func trendComparisonLabel(for trend: DailyDevelopmentSummary.Trend) -> String {
        guard trend.comparisonDayCount > 0 else { return "暂无历史活动" }
        return "较 \(trend.comparisonDayCount) 个有活动日"
    }

    static func formattedDelta(_ delta: Double?, unit: TrendUnit) -> String {
        guard let delta else { return "—" }
        let value: String
        if abs(delta.rounded() - delta) < 0.01 {
            value = String(Int(delta.rounded()))
        } else {
            value = String(format: "%.1f", delta)
        }
        return unit == .minutes ? "\(value) 分钟" : value
    }
}

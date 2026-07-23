import Foundation

// MARK: - Health signal

/// One specific, explainable health signal derived from history.
struct RepositoryHealthSignal: Codable, Equatable, Identifiable, Sendable {
    enum SignalKind: String, Codable, Equatable, Sendable {
        /// Repository has had uncommitted changes for an extended duration
        case dirtyWorkspaceDuration
        /// Unpushed commits have been accumulating without being pushed
        case unpushedCommitsDuration
        /// Repository is behind remote for an extended period
        case behindRemoteDuration
        /// No activity (commits or changes) for a long time
        case staleActivity
        /// Repeated conflicts over time
        case recurringConflicts
        /// Repeated read failures or scan issues
        case frequentReadFailures
        /// Branch has been switched frequently
        case branchInstability
        /// Repository was recently unavailable but has recovered
        case recentRecovery
        /// Changes have been growing monotonically (creeping)
        case creepingChanges
    }

    let kind: SignalKind
    let level: RiskLevel
    let title: String
    let explanation: String
    let evidence: String          // What specific data supports this signal
    let duration: TimeInterval?   // How long the condition has persisted (if applicable)
    let currentValue: String      // The observed value
    let threshold: String?        // The threshold that was exceeded (if applicable)

    var id: String { kind.rawValue }

    var systemImage: String {
        switch kind {
        case .dirtyWorkspaceDuration: return "pencil.and.outline"
        case .unpushedCommitsDuration: return "arrow.up.circle"
        case .behindRemoteDuration: return "arrow.down.circle"
        case .staleActivity: return "clock"
        case .recurringConflicts: return "exclamationmark.triangle"
        case .frequentReadFailures: return "xmark.octagon"
        case .branchInstability: return "arrow.triangle.branch"
        case .recentRecovery: return "arrow.clockwise.heart"
        case .creepingChanges: return "doc.text.magnifyingglass"
        }
    }
}

// MARK: - Health assessment result

struct RepositoryHealthAssessment: Codable, Equatable, Sendable {
    let repositoryID: String
    let repositoryName: String
    let assessedAt: String        // ISO8601
    let overallRisk: RiskLevel
    let signals: [RepositoryHealthSignal]
    let summary: String
    let primaryExplanation: String
    let hasSufficientHistory: Bool
}

// MARK: - Health engine thresholds

enum RepositoryHealthThresholds {
    /// Warn if dirty workspace persists beyond this duration
    static let dirtyWorkspaceWarningDuration: TimeInterval = 4 * 60 * 60       // 4 hours
    static let dirtyWorkspaceHighDuration: TimeInterval = 24 * 60 * 60         // 24 hours

    /// Warn if unpushed commits remain beyond this duration
    static let unpushedWarningDuration: TimeInterval = 8 * 60 * 60             // 8 hours
    static let unpushedHighDuration: TimeInterval = 72 * 60 * 60               // 3 days

    /// Warn if behind remote beyond this duration
    static let behindWarningDuration: TimeInterval = 4 * 60 * 60               // 4 hours
    static let behindHighDuration: TimeInterval = 24 * 60 * 60                 // 24 hours

    /// Warn if no activity beyond this duration
    static let staleWarningDuration: TimeInterval = 7 * 24 * 60 * 60           // 7 days
    static let staleHighDuration: TimeInterval = 30 * 24 * 60 * 60             // 30 days

    /// Warn if N+ conflicts occurred in the last 7 days
    static let recurringConflictThreshold: Int = 2

    /// Warn if N+ read failures occurred in the last 24 hours
    static let readFailureWarningThreshold: Int = 2
    static let readFailureHighThreshold: Int = 5

    /// Warn if branch changed N+ times in the last 24 hours
    static let branchChangeWarningThreshold: Int = 3
    static let branchChangeHighThreshold: Int = 6

    /// Minimum entries for a meaningful trend assessment
    static let minimumHistoryEntries: Int = 3

    /// Warning if changes have been growing across 3+ consecutive records
    static let creepingChangeWindow: Int = 3
}

// MARK: - Health engine

enum RepositoryHealthEngine {
    /// Assess repository health based on its history entries.
    ///
    /// Each signal includes the specific evidence (timestamps, values) that
    /// produced it. No opaque scoring — every conclusion is traceable.
    static func assess(
        repositoryID: String,
        repositoryName: String,
        entries: [RepositoryHistoryEntry],
        assessedAt: String = DateFormatting.nowISO()
    ) -> RepositoryHealthAssessment {
        guard entries.count >= RepositoryHealthThresholds.minimumHistoryEntries else {
            return RepositoryHealthAssessment(
                repositoryID: repositoryID,
                repositoryName: repositoryName,
                assessedAt: assessedAt,
                overallRisk: .low,
                signals: [],
                summary: "历史数据不足（当前 \(entries.count) 条，需要至少 \(RepositoryHealthThresholds.minimumHistoryEntries) 条才能评估趋势）",
                primaryExplanation: "继续扫描积累更多历史记录后将自动出现趋势分析",
                hasSufficientHistory: false
            )
        }

        let sorted = entries.sorted { $0.recordedAt < $1.recordedAt }
        let now = Date()
        var signals: [RepositoryHealthSignal] = []

        // Signal 1: Dirty workspace duration
        if let signal = assessDirtyWorkspaceDuration(entries: sorted, now: now) {
            signals.append(signal)
        }

        // Signal 2: Unpushed commits duration
        if let signal = assessUnpushedCommitsDuration(entries: sorted, now: now) {
            signals.append(signal)
        }

        // Signal 3: Behind remote duration
        if let signal = assessBehindRemoteDuration(entries: sorted, now: now) {
            signals.append(signal)
        }

        // Signal 4: Stale activity
        if let signal = assessStaleActivity(entries: sorted, now: now) {
            signals.append(signal)
        }

        // Signal 5: Recurring conflicts
        if let signal = assessRecurringConflicts(entries: sorted, now: now) {
            signals.append(signal)
        }

        // Signal 6: Frequent read failures
        if let signal = assessFrequentReadFailures(entries: sorted, now: now) {
            signals.append(signal)
        }

        // Signal 7: Branch instability
        if let signal = assessBranchInstability(entries: sorted, now: now) {
            signals.append(signal)
        }

        // Signal 8: Creeping changes
        if let signal = assessCreepingChanges(entries: sorted, now: now) {
            signals.append(signal)
        }

        // Signal 9: Recent recovery (informational)
        if let signal = assessRecentRecovery(entries: sorted, now: now) {
            signals.append(signal)
        }

        // Compute overall risk
        let overallRisk = computeOverallRisk(signals: signals)

        // Build summary and explanation
        let summary = buildSummary(repositoryName: repositoryName,
                                   signals: signals,
                                   overallRisk: overallRisk)
        let primaryExplanation = buildPrimaryExplanation(signals: signals,
                                                        overallRisk: overallRisk)

        return RepositoryHealthAssessment(
            repositoryID: repositoryID,
            repositoryName: repositoryName,
            assessedAt: assessedAt,
            overallRisk: overallRisk,
            signals: signals,
            summary: summary,
            primaryExplanation: primaryExplanation,
            hasSufficientHistory: true
        )
    }

    // MARK: - Individual signal assessments

    private static func assessDirtyWorkspaceDuration(
        entries: [RepositoryHistoryEntry],
        now: Date
    ) -> RepositoryHealthSignal? {
        // Find the earliest continuous period where the repo had changes
        var earliestDirtyDate: Date?
        var latestDirtyDate: Date?
        var recentDirtyCount = 0

        for entry in entries.reversed() {
            guard let date = DateFormatting.date(from: entry.recordedAt) else { continue }
            let hasChanges = entry.state.changedFileCount > 0
                && entry.state.dataSource == .current

            if hasChanges {
                if earliestDirtyDate == nil {
                    earliestDirtyDate = date
                    latestDirtyDate = date
                } else if date < earliestDirtyDate! {
                    earliestDirtyDate = date
                }
                recentDirtyCount += 1
            }
        }

        guard let earliest = earliestDirtyDate,
              let latest = latestDirtyDate else { return nil }

        // Check no more than 80% of recent entries show dirty state
        let recentEntries = entries.suffix(5)
        let dirtyRatio = recentEntries.isEmpty ? 0 :
            Double(recentEntries.filter { $0.state.changedFileCount > 0 }.count) / Double(recentEntries.count)
        guard dirtyRatio >= 0.6 else { return nil }

        let duration = now.timeIntervalSince(earliest)
        let level: RiskLevel
        let threshold: String

        if duration >= RepositoryHealthThresholds.dirtyWorkspaceHighDuration {
            level = .high
            threshold = "> \(formatDuration(RepositoryHealthThresholds.dirtyWorkspaceHighDuration))"
        } else if duration >= RepositoryHealthThresholds.dirtyWorkspaceWarningDuration {
            level = .medium
            threshold = "> \(formatDuration(RepositoryHealthThresholds.dirtyWorkspaceWarningDuration))"
        } else {
            return nil
        }

        let lastEntry = entries.last(where: { $0.state.changedFileCount > 0 })
        let fileCount = lastEntry?.state.changedFileCount ?? 0

        return RepositoryHealthSignal(
            kind: .dirtyWorkspaceDuration,
            level: level,
            title: "工作区长期存在改动",
            explanation: "仓库已有 \(formatDuration(duration)) 未清理的工作区改动。",
            evidence: earliestDirtyDate.map { "最早脏工作区从 \(DateFormatting.displayString(from: $0)) 开始" } ?? "状态持续超过阈值",
            duration: duration,
            currentValue: "\(fileCount) 个改动 · \(formatDuration(duration))",
            threshold: threshold
        )
    }

    private static func assessUnpushedCommitsDuration(
        entries: [RepositoryHistoryEntry],
        now: Date
    ) -> RepositoryHealthSignal? {
        var earliestAheadDate: Date?
        var maxAhead = 0

        for entry in entries.reversed() {
            guard let date = DateFormatting.date(from: entry.recordedAt) else { continue }
            let ahead = entry.state.aheadCount ?? 0
            if ahead > 0 {
                maxAhead = max(maxAhead, ahead)
                if earliestAheadDate == nil || date < earliestAheadDate! {
                    earliestAheadDate = date
                }
            }
        }

        guard let earliest = earliestAheadDate, maxAhead > 0 else { return nil }
        let duration = now.timeIntervalSince(earliest)

        let level: RiskLevel
        let threshold: String

        if duration >= RepositoryHealthThresholds.unpushedHighDuration {
            level = .high
            threshold = "> \(formatDuration(RepositoryHealthThresholds.unpushedHighDuration))"
        } else if duration >= RepositoryHealthThresholds.unpushedWarningDuration {
            level = .medium
            threshold = "> \(formatDuration(RepositoryHealthThresholds.unpushedWarningDuration))"
        } else {
            return nil
        }

        return RepositoryHealthSignal(
            kind: .unpushedCommitsDuration,
            level: level,
            title: "本地提交长时间未推送",
            explanation: "已有 \(maxAhead) 个本地提交未推送，持续 \(formatDuration(duration))。",
            evidence: earliestAheadDate.map { "最早未推送提交从 \(DateFormatting.displayString(from: $0)) 开始" } ?? "持续超过阈值",
            duration: duration,
            currentValue: "\(maxAhead) 个未推送 · \(formatDuration(duration))",
            threshold: threshold
        )
    }

    private static func assessBehindRemoteDuration(
        entries: [RepositoryHistoryEntry],
        now: Date
    ) -> RepositoryHealthSignal? {
        var earliestBehindDate: Date?
        var maxBehind = 0

        for entry in entries.reversed() {
            guard let date = DateFormatting.date(from: entry.recordedAt) else { continue }
            let behind = entry.state.behindCount ?? 0
            if behind > 0 {
                maxBehind = max(maxBehind, behind)
                if earliestBehindDate == nil || date < earliestBehindDate! {
                    earliestBehindDate = date
                }
            }
        }

        guard let earliest = earliestBehindDate, maxBehind > 0 else { return nil }
        let duration = now.timeIntervalSince(earliest)

        let level: RiskLevel
        let threshold: String

        if duration >= RepositoryHealthThresholds.behindHighDuration {
            level = .high
            threshold = "> \(formatDuration(RepositoryHealthThresholds.behindHighDuration))"
        } else if duration >= RepositoryHealthThresholds.behindWarningDuration {
            level = .medium
            threshold = "> \(formatDuration(RepositoryHealthThresholds.behindWarningDuration))"
        } else {
            return nil
        }

        return RepositoryHealthSignal(
            kind: .behindRemoteDuration,
            level: level,
            title: "落后远端持续时间过长",
            explanation: "仓库落后远端 \(maxBehind) 个提交，持续 \(formatDuration(duration))。",
            evidence: earliestBehindDate.map { "最早落后从 \(DateFormatting.displayString(from: $0)) 开始" } ?? "持续超过阈值",
            duration: duration,
            currentValue: "落后 \(maxBehind) · \(formatDuration(duration))",
            threshold: threshold
        )
    }

    private static func assessStaleActivity(
        entries: [RepositoryHistoryEntry],
        now: Date
    ) -> RepositoryHealthSignal? {
        // Find the latest entry where the repo had changes, commits, or upstream activity
        var latestActivityDate: Date?

        for entry in entries.reversed() {
            guard let date = DateFormatting.date(from: entry.recordedAt) else { continue }
            let hasActivity = entry.state.changedFileCount > 0
                || entry.state.lastCommitID != nil
                || entry.state.aheadCount ?? 0 > 0
                || entry.state.behindCount ?? 0 > 0
            if hasActivity {
                latestActivityDate = date
                break
            }
        }

        guard let latest = latestActivityDate else {
            // No activity at all since recording began
            if let firstDate = entries.first.flatMap({ DateFormatting.date(from: $0.recordedAt) }) {
                let duration = now.timeIntervalSince(firstDate)
                if duration >= RepositoryHealthThresholds.staleWarningDuration {
                    let level = duration >= RepositoryHealthThresholds.staleHighDuration ? RiskLevel.high : .medium
                    return RepositoryHealthSignal(
                        kind: .staleActivity,
                        level: level,
                        title: "仓库无活动",
                        explanation: "自记录以来从未检测到任何仓库活动。",
                        evidence: "从 \(DateFormatting.displayString(from: firstDate)) 至今无活动",
                        duration: duration,
                        currentValue: "无活动 · \(formatDuration(duration))",
                        threshold: "> \(formatDuration(RepositoryHealthThresholds.staleWarningDuration))"
                    )
                }
            }
            return nil
        }

        let duration = now.timeIntervalSince(latest)
        let level: RiskLevel
        let threshold: String

        if duration >= RepositoryHealthThresholds.staleHighDuration {
            level = .high
            threshold = "> \(formatDuration(RepositoryHealthThresholds.staleHighDuration))"
        } else if duration >= RepositoryHealthThresholds.staleWarningDuration {
            level = .medium
            threshold = "> \(formatDuration(RepositoryHealthThresholds.staleWarningDuration))"
        } else {
            return nil
        }

        return RepositoryHealthSignal(
            kind: .staleActivity,
            level: level,
            title: "仓库长期不活跃",
            explanation: "最后活跃时间为 \(DateFormatting.displayString(from: latest))（\(formatDuration(duration)) 前）。",
            evidence: latestActivityDate.map { "最后活跃：\(DateFormatting.displayString(from: $0))" } ?? "无活动记录超过阈值",
            duration: duration,
            currentValue: "无活动 · \(formatDuration(duration))",
            threshold: threshold
        )
    }

    private static func assessRecurringConflicts(
        entries: [RepositoryHistoryEntry],
        now: Date
    ) -> RepositoryHealthSignal? {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let recentConflicts = entries.filter {
            guard let date = DateFormatting.date(from: $0.recordedAt) else { return false }
            return date >= cutoff && ($0.state.conflictedFileCount ?? 0) > 0
        }

        guard recentConflicts.count >= RepositoryHealthThresholds.recurringConflictThreshold else {
            return nil
        }

        let level: RiskLevel = recentConflicts.count >= RepositoryHealthThresholds.recurringConflictThreshold * 2
            ? .high : .medium

        return RepositoryHealthSignal(
            kind: .recurringConflicts,
            level: level,
            title: "持续出现 Git 冲突",
            explanation: "最近 7 天出现了 \(recentConflicts.count) 次冲突记录。",
            evidence: recentConflicts.prefix(5).compactMap { entry in
                DateFormatting.date(from: entry.recordedAt).map { DateFormatting.displayString(from: $0) }
            }.joined(separator: "、"),
            duration: nil,
            currentValue: "\(recentConflicts.count) 次冲突",
            threshold: "≥ \(RepositoryHealthThresholds.recurringConflictThreshold) 次/7天"
        )
    }

    private static func assessFrequentReadFailures(
        entries: [RepositoryHistoryEntry],
        now: Date
    ) -> RepositoryHealthSignal? {
        let cutoff24h = now.addingTimeInterval(-24 * 60 * 60)
        let recentFailures = entries.filter {
            guard let date = DateFormatting.date(from: $0.recordedAt) else { return false }
            return date >= cutoff24h
                && ($0.kind == .becameUnavailable
                    || ($0.state.dataSource != .current && $0.state.errorMessage != nil))
        }

        let failureCount = recentFailures.count
        guard failureCount >= RepositoryHealthThresholds.readFailureWarningThreshold else {
            return nil
        }

        let level: RiskLevel
        let threshold: String

        if failureCount >= RepositoryHealthThresholds.readFailureHighThreshold {
            level = .high
            threshold = "≥ \(RepositoryHealthThresholds.readFailureHighThreshold) 次/24h"
        } else {
            level = .medium
            threshold = "≥ \(RepositoryHealthThresholds.readFailureWarningThreshold) 次/24h"
        }

        let lastError = recentFailures.last?.state.errorMessage ?? "未知"

        return RepositoryHealthSignal(
            kind: .frequentReadFailures,
            level: level,
            title: "频繁读取失败",
            explanation: "最近 24 小时出现 \(failureCount) 次读取失败。",
            evidence: "最近错误：\(lastError)。失败时间：\(recentFailures.prefix(3).compactMap { entry in DateFormatting.date(from: entry.recordedAt).map { DateFormatting.displayString(from: $0) } }.joined(separator: "、"))",
            duration: nil,
            currentValue: "\(failureCount) 次失败/24h",
            threshold: threshold
        )
    }

    private static func assessBranchInstability(
        entries: [RepositoryHistoryEntry],
        now: Date
    ) -> RepositoryHealthSignal? {
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        let recentEntries = entries.filter {
            guard let date = DateFormatting.date(from: $0.recordedAt) else { return false }
            return date >= cutoff
        }

        let branches = recentEntries.map(\.state.branch)
        let uniqueBranches = Set(branches)
        let changes = zip(branches, branches.dropFirst()).filter { $0 != $1 }.count

        guard changes >= RepositoryHealthThresholds.branchChangeWarningThreshold else {
            return nil
        }

        let level: RiskLevel = changes >= RepositoryHealthThresholds.branchChangeHighThreshold
            ? .high : .medium

        return RepositoryHealthSignal(
            kind: .branchInstability,
            level: level,
            title: "分支切换频繁",
            explanation: "最近 24 小时内分支切换了 \(changes) 次（涉及 \(uniqueBranches.count) 个不同分支）。",
            evidence: branches.isEmpty ? "无分支记录" : "分支：\(Array(uniqueBranches).joined(separator: "、"))",
            duration: nil,
            currentValue: "\(changes) 次切换",
            threshold: "≥ \(RepositoryHealthThresholds.branchChangeWarningThreshold) 次/24h"
        )
    }

    private static func assessCreepingChanges(
        entries: [RepositoryHistoryEntry],
        now: Date
    ) -> RepositoryHealthSignal? {
        let recentEntries = entries.suffix(RepositoryHealthThresholds.creepingChangeWindow)
        guard recentEntries.count >= 3 else { return nil }

        let changeCounts = recentEntries.compactMap { entry -> Int? in
            guard entry.state.dataSource == .current else { return nil }
            return entry.state.changedFileCount
        }

        guard changeCounts.count >= 3 else { return nil }

        // Check if changes have been trending upward (non-decreasing)
        var trendingUp = true
        for i in 1..<changeCounts.count {
            if changeCounts[i] < changeCounts[i - 1] {
                trendingUp = false
                break
            }
        }

        guard trendingUp, changeCounts.last! > changeCounts.first! else { return nil }

        let increase = changeCounts.last! - changeCounts.first!

        return RepositoryHealthSignal(
            kind: .creepingChanges,
            level: .medium,
            title: "改动持续堆积",
            explanation: "过去 \(changeCounts.count) 次扫描中改动量从 \(changeCounts.first!) 持续增长到 \(changeCounts.last!)。",
            evidence: changesDetail(changeCounts),
            duration: nil,
            currentValue: "+\(increase) 个文件",
            threshold: nil
        )
    }

    private static func assessRecentRecovery(
        entries: [RepositoryHistoryEntry],
        now: Date
    ) -> RepositoryHealthSignal? {
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        let recentRecoveries = entries.filter {
            guard let date = DateFormatting.date(from: $0.recordedAt) else { return false }
            return date >= cutoff && $0.kind == .recovery
        }

        guard !recentRecoveries.isEmpty else { return nil }

        // Informational only — always low risk
        return RepositoryHealthSignal(
            kind: .recentRecovery,
            level: .low,
            title: "最近已恢复",
            explanation: "仓库在最近 24 小时内从不可用状态恢复。",
            evidence: recentRecoveries.compactMap { entry in
                DateFormatting.date(from: entry.recordedAt).map { DateFormatting.displayString(from: $0) }
            }.joined(separator: "、"),
            duration: nil,
            currentValue: "\(recentRecoveries.count) 次恢复",
            threshold: nil
        )
    }

    // MARK: - Overall risk computation

    // Internal for testing access
    static func computeOverallRisk(signals: [RepositoryHealthSignal]) -> RiskLevel {
        guard !signals.isEmpty else { return .low }

        let hasHigh = signals.contains { $0.level == .high }
        let hasMedium = signals.contains { $0.level == .medium }

        if hasHigh { return .high }
        if hasMedium { return .medium }
        return .low
    }

    // MARK: - Summary building

    private static func buildSummary(
        repositoryName: String,
        signals: [RepositoryHealthSignal],
        overallRisk: RiskLevel
    ) -> String {
        guard !signals.isEmpty else {
            return "\(repositoryName) 近期无趋势预警"
        }

        let highCount = signals.filter { $0.level == .high }.count
        let mediumCount = signals.filter { $0.level == .medium }.count

        var parts: [String] = []
        if highCount > 0 {
            parts.append("\(highCount) 个高风险信号")
        }
        if mediumCount > 0 {
            parts.append("\(mediumCount) 个中风险信号")
        }
        if parts.isEmpty {
            parts.append("趋势正常")
        }

        let topSignal = signals.first { $0.level == .high } ?? signals.first
        if let top = topSignal {
            parts.append(top.title)
        }

        return parts.joined(separator: " · ")
    }

    private static func buildPrimaryExplanation(
        signals: [RepositoryHealthSignal],
        overallRisk: RiskLevel
    ) -> String {
        guard !signals.isEmpty else {
            return "暂无需要关注的风险信号"
        }

        let highSignals = signals.filter { $0.level == .high }
        let mediumSignals = signals.filter { $0.level == .medium }

        if !highSignals.isEmpty {
            let explanations = highSignals.map { $0.explanation }
            return "高风险：" + explanations.joined(separator: " ")
        }

        if !mediumSignals.isEmpty {
            let explanations = mediumSignals.map { $0.explanation }
            return "中风险：" + explanations.joined(separator: " ")
        }

        return signals.map { $0.explanation }.joined(separator: " ")
    }

    // MARK: - Formatting helpers

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60

        if days > 0 {
            return "\(days) 天 \(hours) 小时"
        } else if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        } else {
            return "\(minutes) 分"
        }
    }

    private static func changesDetail(_ counts: [Int]) -> String {
        counts.enumerated().map { (i, count) in
            "扫描\(i + 1): \(count)"
        }.joined(separator: " → ")
    }
}

// MARK: - Health diagnostics

struct HealthDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let totalAssessments: Int
    let totalSignals: Int
    let lastAssessmentDurationMs: Double
    let repositoriesWithSignals: Int

    static func empty() -> HealthDiagnosticsSnapshot {
        HealthDiagnosticsSnapshot(
            totalAssessments: 0,
            totalSignals: 0,
            lastAssessmentDurationMs: 0,
            repositoriesWithSignals: 0
        )
    }
}

// MARK: - Aggregated health view

struct RepositoryHealthSummary: Codable, Equatable, Sendable {
    let repositoryID: String
    let repositoryName: String
    let overallRisk: RiskLevel
    let signalCount: Int
    let topSignals: [RepositoryHealthSignal]
    let lastAssessedAt: String?
}

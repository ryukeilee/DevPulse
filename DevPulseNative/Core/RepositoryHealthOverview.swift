import Foundation

// MARK: - 项目健康概览（纯派生，无 I/O）

/// 健康概览与综合评分的派生逻辑。输入为内存中已存在的 `RepositorySnapshot`
/// 刷新结果（与 `scheduler.lastResult.repositories` 同源），不触发任何
/// 新的 Git 读取、文件读取或后台任务。

// MARK: 活跃程度分级

/// 基于两个已有活动时间戳中较新的有效值分级。
enum RepositoryActivityLevel: String, Equatable {
    /// 最近 24 小时内有活动
    case active
    /// 1–7 天内有活动
    case moderate
    /// 超过 7 天无活动（沉寂）
    case dormant
    /// 没有任何活动记录
    case noActivity

    var label: String {
        switch self {
        case .active: return "活跃"
        case .moderate: return "一般"
        case .dormant: return "沉寂"
        case .noActivity: return "无活动记录"
        }
    }
}

// MARK: 扫描状态分类

/// 概览中的扫描状态分类。分类依据：`unavailableSince`（仓库不可用）、
/// `resolvedDataSource`（current / lastSuccessful / unknown）与读取错误状态。
enum RepositoryHealthScanState: String, Equatable {
    /// 本轮扫描成功，数据为当前值
    case current
    /// 本轮读取失败，回退到上次成功数据
    case lastSuccessful
    /// 数据来源未知（从未成功读取）
    case unknown
    /// 仓库当前不可用
    case unavailable
    /// 读取错误
    case error

    var label: String {
        switch self {
        case .current: return "当前数据"
        case .lastSuccessful: return "上次成功"
        case .unknown: return "来源未知"
        case .unavailable: return "仓库不可用"
        case .error: return "读取错误"
        }
    }
}

// MARK: 仓库状态映射

/// 概览中的仓库状态映射，来自快照 `status` 与变更计数。
enum RepositoryHealthRepoState: Equatable {
    case clean
    case changed(count: Int)
    case error

    var label: String {
        switch self {
        case .clean: return "干净"
        case .changed(let count): return "\(count) 处改动"
        case .error: return "读取错误"
        }
    }
}

// MARK: 综合评分

/// 概览层的健康评分状态。评分只用于当前项目概览，不改变扫描结果中的
/// `risk`（后者仍表示当前变更文件风险）。
enum RepositoryHealthScoreStatus: String, Equatable {
    case healthy
    case attention
    case critical
    case insufficientData
    case unavailable

    var label: String {
        switch self {
        case .healthy: return "健康"
        case .attention: return "需关注"
        case .critical: return "风险较高"
        case .insufficientData: return "数据不足"
        case .unavailable: return "无法评估"
        }
    }
}

/// 可解释的项目健康评分。`value == nil` 表示现有扫描数据不足以给出
/// 可信分数，避免把读取异常伪装成低分或正常。
struct RepositoryHealthScore: Equatable {
    let value: Int?
    let status: RepositoryHealthScoreStatus
    let explanation: String

    var displayLabel: String {
        if let value {
            return "\(value) 分 · \(status.label)"
        }
        return status.label
    }
}

/// 概览头部使用的健康状态汇总。它只汇总已经生成的行，避免视图各自
/// 根据快照重新解释状态，确保数量与下面实际展示的项目完全一致。
struct RepositoryHealthOverviewSummary: Equatable {
    let totalCount: Int
    let healthyCount: Int
    let attentionCount: Int
    let criticalCount: Int
    let insufficientDataCount: Int
    let unavailableCount: Int

    /// 有健康分但需要处理的项目，不包含无法可靠评分的数据异常。
    var needsAttentionCount: Int {
        attentionCount + criticalCount
    }

    var dataIssueCount: Int {
        insufficientDataCount + unavailableCount
    }

    var hasDataIssues: Bool {
        dataIssueCount > 0
    }

    var hasIssues: Bool {
        needsAttentionCount > 0 || hasDataIssues
    }
}

// MARK: 概览行

/// 一个已扫描项目的健康概览行，同时携带最近活动、仓库状态、扫描状态、
/// 活跃程度和可解释的综合健康分。
struct RepositoryHealthOverviewItem: Identifiable, Equatable {
    let id: String
    let name: String
    let branch: String
    let risk: RiskLevel
    /// 最近活动时间（无活动记录或时间无效时为 nil）
    let activityDate: Date?
    /// 相对时间标签（如 "5 小时前"）；无活动记录或时间无效时为 nil
    let activityLabel: String?
    let repositoryState: RepositoryHealthRepoState
    let scanState: RepositoryHealthScanState
    let activityLevel: RepositoryActivityLevel
    let healthScore: RepositoryHealthScore
}

// MARK: Builder

/// 把 `[RepositorySnapshot]` 派生为概览行列表。纯函数：输入快照数组与
/// 可选参照时间，无 I/O、无状态，输出按健康严重度和分数优先排列；同一
/// 严重度内再按最近活动时间排序，同名按名称排序保持稳定。
enum RepositoryHealthOverviewBuilder {
    /// 活跃阈值：最近 24 小时内有活动为「活跃」
    static let activeThreshold: TimeInterval = 24 * 60 * 60
    /// 沉寂阈值：超过 7 天无活动为「沉寂」
    static let dormantThreshold: TimeInterval = 7 * 24 * 60 * 60

    /// 评分权重：活跃度 35、维护状态 35、数据可信度 20、变更风险 10。
    /// 权重集中在此处，便于审查和测试；所有输入仍来自已有快照。
    private enum ScoreWeights {
        static let activity = 35
        static let maintenance = 35
        static let reliability = 20
        static let changeRisk = 10
    }

    static func build(
        snapshots: [RepositorySnapshot],
        now: Date = Date()
    ) -> [RepositoryHealthOverviewItem] {
        snapshots
            .map { makeItem(snapshot: $0, now: now) }
            .sorted(by: ordering)
    }

    /// 汇总与 `build` 同一批行，供概览头部显示整体状态。
    static func summary(for items: [RepositoryHealthOverviewItem]) -> RepositoryHealthOverviewSummary {
        RepositoryHealthOverviewSummary(
            totalCount: items.count,
            healthyCount: items.filter { $0.healthScore.status == .healthy }.count,
            attentionCount: items.filter { $0.healthScore.status == .attention }.count,
            criticalCount: items.filter { $0.healthScore.status == .critical }.count,
            insufficientDataCount: items.filter { $0.healthScore.status == .insufficientData }.count,
            unavailableCount: items.filter { $0.healthScore.status == .unavailable }.count
        )
    }

    /// 扫描状态分类。优先级：unavailable > current > lastSuccessful > unknown/error。
    static func classifyScanState(snapshot: RepositorySnapshot) -> RepositoryHealthScanState {
        if snapshot.unavailableSince != nil {
            return .unavailable
        }
        switch snapshot.resolvedDataSource {
        case .current:
            return .current
        case .lastSuccessful:
            return .lastSuccessful
        case .unknown:
            return snapshot.status == .error ? .error : .unknown
        }
    }

    /// 活跃程度分级：按最近活动时间距今时长确定性分级。
    /// 边界：≤ 24 小时为活跃；≤ 7 天为一般；超过 7 天为沉寂；无活动记录为「无活动记录」。
    static func classifyActivityLevel(
        activityDate: Date?,
        now: Date
    ) -> RepositoryActivityLevel {
        guard let activityDate else { return .noActivity }
        let interval = now.timeIntervalSince(activityDate)
        guard interval >= -60 else { return .noActivity }
        if interval <= activeThreshold { return .active }
        if interval <= dormantThreshold { return .moderate }
        return .dormant
    }

    /// 取两个已有活动时间戳中较新的有效值，避免旧的活动标记遮住新提交。
    static func activityTimestamp(
        snapshot: RepositorySnapshot,
        now: Date = Date()
    ) -> String? {
        let candidates = [snapshot.lastActivityAt, snapshot.lastChangedAt]
            .compactMap { $0 }
            .compactMap { timestamp -> (String, Date)? in
                guard let date = DateFormatting.date(from: timestamp) else { return nil }
                guard now.timeIntervalSince(date) >= -60 else { return nil }
                return (timestamp, date)
            }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    /// 计算项目健康分。纯函数，不触发任何扫描或文件读取。
    static func healthScore(
        snapshot: RepositorySnapshot,
        now: Date
    ) -> RepositoryHealthScore {
        let scanState = classifyScanState(snapshot: snapshot)
        switch scanState {
        case .unavailable:
            return RepositoryHealthScore(
                value: nil,
                status: .unavailable,
                explanation: "仓库当前不可访问，无法可靠评估健康状态。"
            )
        case .error:
            return RepositoryHealthScore(
                value: nil,
                status: .unavailable,
                explanation: "最近一次读取失败，暂不显示健康分；完成一次成功刷新后再评估。"
            )
        case .unknown:
            return RepositoryHealthScore(
                value: nil,
                status: .insufficientData,
                explanation: "尚未获得可信的扫描数据，暂不显示健康分。"
            )
        case .current, .lastSuccessful:
            break
        }

        let activityDate = activityDate(snapshot: snapshot, now: now)
        let activityLevel = classifyActivityLevel(activityDate: activityDate, now: now)
        let activityPoints: Int
        switch activityLevel {
        case .active: activityPoints = ScoreWeights.activity
        case .moderate: activityPoints = 26
        case .dormant: activityPoints = 12
        case .noActivity: activityPoints = 4
        }

        var reasons: [String] = []
        if activityLevel == .moderate {
            reasons.append("最近 1–7 天有活动，活跃度一般")
        } else if activityLevel == .dormant {
            reasons.append("超过 7 天未检测到活动")
        } else if activityLevel == .noActivity {
            reasons.append("暂无可用活动时间，活跃度证据不足")
        }

        var maintenancePoints = ScoreWeights.maintenance
        switch snapshot.status {
        case .clean:
            break
        case .changed:
            let changedCount = max(0, snapshot.changedFileCount)
            let changePenalty = min(18, Int(ceil(Double(changedCount) * 1.5)))
            maintenancePoints -= changePenalty
            if changedCount > 0 {
                reasons.append("工作区有 \(changedCount) 处未提交改动")
            }
        case .error:
            maintenancePoints = 0
        }

        if let conflicts = snapshot.conflictedFileCount, conflicts > 0 {
            maintenancePoints -= min(25, conflicts * 8)
            reasons.append("存在 \(conflicts) 个冲突文件")
        }
        if let ahead = snapshot.aheadCount, ahead > 0 {
            maintenancePoints -= min(8, ahead * 2)
            reasons.append("有 \(ahead) 个本地提交未推送")
        }
        if let behind = snapshot.behindCount, behind > 0 {
            maintenancePoints -= min(12, behind * 2)
            reasons.append("落后远端 \(behind) 个提交")
        }
        maintenancePoints = max(0, maintenancePoints)

        let reliabilityPoints: Int
        switch scanState {
        case .current:
            reliabilityPoints = ScoreWeights.reliability
        case .lastSuccessful:
            reliabilityPoints = 10
            reasons.append("当前使用上次成功扫描数据，状态可能已变化")
        case .unknown, .unavailable, .error:
            reliabilityPoints = 0
        }

        let changeRiskPoints: Int
        switch snapshot.risk {
        case .low:
            changeRiskPoints = ScoreWeights.changeRisk
        case .medium:
            changeRiskPoints = 5
            reasons.append("当前改动包含需要关注的文件")
        case .high:
            changeRiskPoints = 0
            reasons.append("当前改动被判定为高风险")
        }

        var value = activityPoints + maintenancePoints + reliabilityPoints + changeRiskPoints
        // 上次成功数据不能呈现为“健康”，即使其保留字段看起来完整。
        if scanState == .lastSuccessful {
            value = min(value, 74)
        }
        value = min(100, max(0, value))

        let status: RepositoryHealthScoreStatus
        if value >= 80 {
            status = .healthy
        } else if value >= 60 {
            status = .attention
        } else {
            status = .critical
        }

        let explanation: String
        if reasons.isEmpty {
            explanation = "当前扫描数据显示项目活跃、工作区干净，未发现明显维护问题。"
        } else {
            explanation = reasons.prefix(2).joined(separator: "；")
        }

        return RepositoryHealthScore(value: value, status: status, explanation: explanation)
    }

    /// 仓库状态映射：`status` → clean / changed(变更计数) / error。
    static func repositoryState(for snapshot: RepositorySnapshot) -> RepositoryHealthRepoState {
        switch snapshot.status {
        case .clean: return .clean
        case .changed: return .changed(count: snapshot.changedFileCount)
        case .error: return .error
        }
    }

    // MARK: 内部实现

    private static func makeItem(
        snapshot: RepositorySnapshot,
        now: Date
    ) -> RepositoryHealthOverviewItem {
        let activityDate = activityDate(snapshot: snapshot, now: now)
        let timestamp = activityDate.map(DateFormatting.isoString(from:))
        let activityLabel = timestamp.flatMap {
            DateFormatting.relativeTimeChinese(from: $0, relativeTo: now)
        }
        let activityLevel = classifyActivityLevel(activityDate: activityDate, now: now)
        return RepositoryHealthOverviewItem(
            id: snapshot.id,
            name: snapshot.name,
            branch: snapshot.branch,
            risk: snapshot.risk,
            activityDate: activityDate,
            activityLabel: activityLabel,
            repositoryState: repositoryState(for: snapshot),
            scanState: classifyScanState(snapshot: snapshot),
            activityLevel: activityLevel,
            healthScore: healthScore(snapshot: snapshot, now: now)
        )
    }

    private static func activityDate(snapshot: RepositorySnapshot, now: Date) -> Date? {
        guard let timestamp = activityTimestamp(snapshot: snapshot, now: now),
              let date = DateFormatting.date(from: timestamp),
              now.timeIntervalSince(date) >= -60 else {
            return nil
        }
        return date
    }

    private static func ordering(
        _ lhs: RepositoryHealthOverviewItem,
        _ rhs: RepositoryHealthOverviewItem
    ) -> Bool {
        let lhsPriority = healthStatusPriority(lhs.healthScore.status)
        let rhsPriority = healthStatusPriority(rhs.healthScore.status)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        // 在同一严重度内先放分数更低的项目；用户打开 Overview 时，
        // 需要处理的问题不会被刚刚有活动的健康项目挤到后面。
        switch (lhs.healthScore.value, rhs.healthScore.value) {
        case let (lhsValue?, rhsValue?) where lhsValue != rhsValue:
            return lhsValue < rhsValue
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        default:
            break
        }

        switch (lhs.activityDate, rhs.activityDate) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case (nil, nil):
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case (nil, _):
            return false
        case (_, nil):
            return true
        }
    }

    private static func healthStatusPriority(_ status: RepositoryHealthScoreStatus) -> Int {
        switch status {
        case .unavailable, .critical:
            return 0
        case .attention:
            return 1
        case .insufficientData:
            return 2
        case .healthy:
            return 3
        }
    }
}

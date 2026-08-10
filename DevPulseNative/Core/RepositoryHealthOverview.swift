import Foundation

// MARK: - 项目健康概览（纯派生，无 I/O）

/// 四维健康概览的派生逻辑。输入为内存中已存在的 `RepositorySnapshot`
/// 刷新结果（与 `scheduler.lastResult.repositories` 同源），不触发任何
/// 新的 Git 读取、文件读取或后台任务。

// MARK: 活跃程度分级

/// 基于最近活动时间（`lastActivityAt` → `lastChangedAt` 兜底）的分级结论。
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

// MARK: 概览行

/// 一个已扫描项目的健康概览行，同时携带四维信息：
/// 最近活动时间、仓库状态、扫描状态、活跃程度。
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
}

// MARK: Builder

/// 把 `[RepositorySnapshot]` 派生为概览行列表。纯函数：输入快照数组与
/// 可选参照时间，无 I/O、无状态，输出按最近活动时间降序排列（无活动
/// 记录的排最后，同名按名称排序保持稳定）。
enum RepositoryHealthOverviewBuilder {
    /// 活跃阈值：最近 24 小时内有活动为「活跃」
    static let activeThreshold: TimeInterval = 24 * 60 * 60
    /// 沉寂阈值：超过 7 天无活动为「沉寂」
    static let dormantThreshold: TimeInterval = 7 * 24 * 60 * 60

    static func build(
        snapshots: [RepositorySnapshot],
        now: Date = Date()
    ) -> [RepositoryHealthOverviewItem] {
        snapshots
            .map { makeItem(snapshot: $0, now: now) }
            .sorted(by: ordering)
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
        if interval <= activeThreshold { return .active }
        if interval <= dormantThreshold { return .moderate }
        return .dormant
    }

    /// 取最近活动时间戳：`lastActivityAt` 优先，`lastChangedAt` 兜底。
    static func activityTimestamp(snapshot: RepositorySnapshot) -> String? {
        snapshot.lastActivityAt ?? snapshot.lastChangedAt
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
        let timestamp = activityTimestamp(snapshot: snapshot)
        let activityDate = timestamp.flatMap(DateFormatting.date(from:))
        let activityLabel = timestamp.flatMap {
            DateFormatting.relativeTimeChinese(from: $0, relativeTo: now)
        }
        return RepositoryHealthOverviewItem(
            id: snapshot.id,
            name: snapshot.name,
            branch: snapshot.branch,
            risk: snapshot.risk,
            activityDate: activityDate,
            activityLabel: activityLabel,
            repositoryState: repositoryState(for: snapshot),
            scanState: classifyScanState(snapshot: snapshot),
            activityLevel: classifyActivityLevel(activityDate: activityDate, now: now)
        )
    }

    private static func ordering(
        _ lhs: RepositoryHealthOverviewItem,
        _ rhs: RepositoryHealthOverviewItem
    ) -> Bool {
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
}

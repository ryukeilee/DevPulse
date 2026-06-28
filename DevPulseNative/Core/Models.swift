import Foundation

// MARK: - Schema constants

enum RepositorySnapshotSchema {
    static let version = 1
}

enum SharedSnapshotLocation {
    static let appGroupIdentifier = "group.local.devpulse"
    static let fileName = "repositories.json"
}

enum WidgetIdentity {
    static let kind = "DevPulseWidget"
}

// MARK: - Risk level

enum RiskLevel: String, Codable, Comparable {
    case low = "low"
    case medium = "medium"
    case high = "high"

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        let order: [RiskLevel] = [.low, .medium, .high]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - Repository status

enum RepositoryStatus: String, Codable {
    case clean = "clean"
    case changed = "changed"
    case error = "error"
}

// MARK: - Repository snapshot

struct RepositoryChangeCounts: Codable, Equatable {
    let modified: Int
    let added: Int
    let deleted: Int
    let untracked: Int
    let staged: Int
    let unstaged: Int
    let conflicted: Int

    var total: Int {
        modified + added + deleted + untracked
    }
}

struct RepositorySnapshot: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let branch: String
    let status: RepositoryStatus
    let modifiedFileCount: Int
    let addedFileCount: Int
    let deletedFileCount: Int
    let untrackedFileCount: Int
    let stagedFileCount: Int?
    let unstagedFileCount: Int?
    let conflictedFileCount: Int?
    let aheadCount: Int?
    let changedFileCount: Int
    let changedFilesPreview: [String]
    let risk: RiskLevel
    let lastScannedAt: String
    let lastChangedAt: String?
    let errorMessage: String?
    var isPinned: Bool

    static func == (lhs: RepositorySnapshot, rhs: RepositorySnapshot) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.path == rhs.path
            && lhs.branch == rhs.branch
            && lhs.status == rhs.status
            && lhs.modifiedFileCount == rhs.modifiedFileCount
            && lhs.addedFileCount == rhs.addedFileCount
            && lhs.deletedFileCount == rhs.deletedFileCount
            && lhs.untrackedFileCount == rhs.untrackedFileCount
            && lhs.stagedFileCount == rhs.stagedFileCount
            && lhs.unstagedFileCount == rhs.unstagedFileCount
            && lhs.conflictedFileCount == rhs.conflictedFileCount
            && lhs.aheadCount == rhs.aheadCount
            && lhs.changedFileCount == rhs.changedFileCount
            && lhs.changedFilesPreview == rhs.changedFilesPreview
            && lhs.risk == rhs.risk
            && lhs.lastScannedAt == rhs.lastScannedAt
            && lhs.lastChangedAt == rhs.lastChangedAt
            && lhs.errorMessage == rhs.errorMessage
            && lhs.isPinned == rhs.isPinned
    }

    var changeCounts: RepositoryChangeCounts {
        RepositoryChangeCounts(
            modified: modifiedFileCount,
            added: addedFileCount,
            deleted: deletedFileCount,
            untracked: untrackedFileCount,
            staged: stagedFileCount ?? 0,
            unstaged: unstagedFileCount ?? (modifiedFileCount + addedFileCount + deletedFileCount),
            conflicted: conflictedFileCount ?? 0
        )
    }

    var commitReadiness: CommitReadinessAssessment {
        CommitReadinessEngine.assess(snapshot: self)
    }

    var nextActionHint: String {
        RepositoryNextActionHintBuilder.build(snapshot: self)
    }

    var statusSummary: String {
        RepositoryStatusSummaryBuilder.build(snapshot: self)
    }
}

enum RepositoryNextActionHintBuilder {
    static func build(snapshot: RepositorySnapshot) -> String {
        let readiness = snapshot.commitReadiness

        if snapshot.status == .error || readiness.level == .unknown {
            return "先看 Diagnostics，确认 Git 读取失败原因。"
        }

        if readiness.reasons.contains(.conflictedFiles) {
            return "先解决 \(countLabel(snapshot.conflictedFileCount ?? 0, unit: "处冲突"))，再继续审查或提交。"
        }

        if readiness.reasons.contains(.branchNeedsConfirmation) {
            return "先确认当前分支，再决定是否继续审查或提交。"
        }

        if readiness.reasons.contains(.localAhead),
           let aheadCount = snapshot.aheadCount,
           aheadCount > 0 {
            return "确认准备好后 push \(countLabel(aheadCount, unit: "个本地提交"))。"
        }

        if readiness.reasons.contains(.stagedChanges) {
            return "确认 \(countLabel(snapshot.stagedFileCount ?? 0, unit: "个已暂存改动"))后即可提交。"
        }

        if readiness.reasons.contains(.mixedStagedAndUnstagedChanges) {
            return "先拆清已暂存和未暂存改动，再决定是否提交。"
        }

        if readiness.reasons.contains(.highRiskChanges), readiness.level == .dirty {
            return "先收敛 \(countLabel(snapshot.changedFileCount, unit: "处高风险改动"))，并跑一次验证。"
        }

        if readiness.reasons.contains(.largeWorkingTree) {
            let targetCount = max(snapshot.changedFileCount, snapshot.untrackedFileCount + (snapshot.unstagedFileCount ?? 0))
            return "先收敛 \(countLabel(targetCount, unit: "处改动"))，再继续审查或提交。"
        }

        if readiness.reasons.contains(.deletedFiles), snapshot.deletedFileCount > 0 {
            return "先检查 \(countLabel(snapshot.deletedFileCount, unit: "个删除项"))，再决定是否提交。"
        }

        if readiness.reasons.contains(.untrackedFiles), snapshot.untrackedFileCount > 0 {
            return "先确认 \(countLabel(snapshot.untrackedFileCount, unit: "个新文件"))是否纳入提交。"
        }

        if readiness.reasons.contains(.highRiskChanges) || snapshot.risk == .medium || snapshot.risk == .high {
            return "先看 diff 并跑一次验证，再决定是否提交。"
        }

        switch readiness.level {
        case .idle:
            return "当前无需操作。"
        case .ready:
            return "如范围确认无误，可以继续提交或分享改动。"
        case .review:
            if snapshot.changedFileCount > 0 {
                return "先看 \(countLabel(snapshot.changedFileCount, unit: "处改动"))的 diff，再决定是否提交。"
            }
            return "先审查当前改动，再决定是否提交。"
        case .dirty:
            return "先整理当前改动，再继续审查或提交。"
        case .unknown:
            return "先看 Diagnostics，确认 Git 读取失败原因。"
        }
    }

    private static func countLabel(_ count: Int, unit: String) -> String {
        "\(max(count, 1)) \(unit)"
    }
}

enum RepositoryStatusSummaryBuilder {
    static func build(snapshot: RepositorySnapshot) -> String {
        if snapshot.status == .error || snapshot.commitReadiness.level == .unknown {
            return snapshot.errorMessage ?? "Git 状态不可用"
        }

        if snapshot.changedFileCount == 0,
           let aheadCount = snapshot.aheadCount,
           aheadCount > 0 {
            return aheadCount == 1 ? "领先 1 个本地提交" : "领先 \(aheadCount) 个本地提交"
        }

        if snapshot.commitReadiness.level == .idle {
            return "没有本地改动"
        }

        var parts: [String] = []
        parts.append(snapshot.changedFileCount == 1 ? "1 处改动" : "\(snapshot.changedFileCount) 处改动")

        let stagedCount = snapshot.stagedFileCount ?? 0
        if stagedCount > 0 {
            parts.append("已暂存 \(stagedCount)")
        }

        let unstagedCount = snapshot.unstagedFileCount
            ?? (snapshot.modifiedFileCount + snapshot.addedFileCount + snapshot.deletedFileCount)
        if unstagedCount > 0 {
            parts.append("未暂存 \(unstagedCount)")
        }

        if snapshot.untrackedFileCount > 0 {
            parts.append("未跟踪 \(snapshot.untrackedFileCount)")
        }

        return parts.joined(separator: " · ")
    }
}

// MARK: - Activity timeline

enum ActivityTimelineState: String, Codable, Equatable {
    case neverScanned
    case noRepositories
    case allClean
    case active
}

struct ActivityTimelineFeed: Codable, Equatable {
    let state: ActivityTimelineState
    let items: [ActivityTimelineItem]

    var topItem: ActivityTimelineItem? {
        items.first
    }

    var hasItems: Bool {
        !items.isEmpty
    }
}

struct WidgetPrioritySummary: Equatable {
    let title: String
    let message: String
    let readinessLevel: CommitReadinessLevel?
    let auxiliary: String?
}

struct ActivityTimelineItem: Codable, Identifiable, Equatable {
    let id: String
    let repoName: String
    let repoPath: String
    let branch: String
    let status: RepositoryStatus
    let risk: RiskLevel
    let modifiedFileCount: Int
    let addedFileCount: Int
    let deletedFileCount: Int
    let untrackedFileCount: Int
    let stagedFileCount: Int
    let unstagedFileCount: Int
    let conflictedFileCount: Int
    let aheadCount: Int
    let changedFileCount: Int
    let changedFilesPreview: [String]
    let lastChangedAt: String?
    let lastScannedAt: String

    init(from snapshot: RepositorySnapshot) {
        id = snapshot.id
        repoName = snapshot.name
        repoPath = snapshot.path
        branch = snapshot.branch
        status = snapshot.status
        risk = snapshot.risk
        modifiedFileCount = snapshot.modifiedFileCount
        addedFileCount = snapshot.addedFileCount
        deletedFileCount = snapshot.deletedFileCount
        untrackedFileCount = snapshot.untrackedFileCount
        stagedFileCount = snapshot.stagedFileCount ?? 0
        unstagedFileCount = snapshot.unstagedFileCount ?? (snapshot.modifiedFileCount + snapshot.addedFileCount + snapshot.deletedFileCount)
        conflictedFileCount = snapshot.conflictedFileCount ?? 0
        aheadCount = snapshot.aheadCount ?? 0
        changedFileCount = snapshot.changedFileCount
        changedFilesPreview = ActivityTimelineItem.previewBasenames(from: snapshot.changedFilesPreview)
        lastChangedAt = snapshot.lastChangedAt
        lastScannedAt = snapshot.lastScannedAt
    }

    var activityDate: Date? {
        if let lastChangedAt, let date = DateFormatting.date(from: lastChangedAt) {
            return date
        }
        return DateFormatting.date(from: lastScannedAt)
    }

    var commitReadiness: CommitReadinessAssessment {
        CommitReadinessEngine.assess(
            status: status,
            branch: branch,
            risk: risk,
            modifiedFileCount: modifiedFileCount,
            addedFileCount: addedFileCount,
            deletedFileCount: deletedFileCount,
            untrackedFileCount: untrackedFileCount,
            stagedFileCount: stagedFileCount,
            unstagedFileCount: unstagedFileCount,
            conflictedFileCount: conflictedFileCount,
            aheadCount: aheadCount,
            scanError: status == .error
        )
    }

    private static func previewBasenames(from preview: [String]) -> [String] {
        var seen = Set<String>()
        var basenames: [String] = []

        for path in preview {
            let basename = (path as NSString).lastPathComponent
            guard !basename.isEmpty else { continue }
            if seen.insert(basename).inserted {
                basenames.append(basename)
            }
            if basenames.count == 3 {
                break
            }
        }

        return basenames
    }
}

enum ActivityTimelineBuilder {
    static func build(from repositories: [RepositorySnapshot],
                      lastScanAt: Date?) -> ActivityTimelineFeed {
        let items = repositories
            .map(ActivityTimelineItem.init(from:))
            .sorted(by: sort(_:_:))

        return ActivityTimelineFeed(
            state: classify(repositories: repositories, lastScanAt: lastScanAt),
            items: items
        )
    }

    static func build(from snapshot: AppGroupData, lastScanAt: Date? = nil) -> ActivityTimelineFeed {
        let fallbackLastScanAt = lastScanAt ?? DateFormatting.date(from: snapshot.writtenAt ?? snapshot.generatedAt)
        return build(from: snapshot.repositories, lastScanAt: fallbackLastScanAt)
    }

    private static func classify(repositories: [RepositorySnapshot],
                                 lastScanAt: Date?) -> ActivityTimelineState {
        guard !repositories.isEmpty else {
            return lastScanAt == nil ? .neverScanned : .noRepositories
        }

        let hasChanged = repositories.contains { $0.status == .changed }
        let hasError = repositories.contains { $0.status == .error }

        if !hasChanged && !hasError {
            return .allClean
        }

        return .active
    }

    private static func sort(_ lhs: ActivityTimelineItem,
                             _ rhs: ActivityTimelineItem) -> Bool {
        let lhsPriority = statusPriority(lhs.status)
        let rhsPriority = statusPriority(rhs.status)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        if let lhsDate = lhs.activityDate, let rhsDate = rhs.activityDate, lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        if lhs.activityDate != nil {
            return true
        }

        if rhs.activityDate != nil {
            return false
        }

        if lhs.changedFileCount != rhs.changedFileCount {
            return lhs.changedFileCount > rhs.changedFileCount
        }

        if lhs.risk != rhs.risk {
            return lhs.risk > rhs.risk
        }

        return lhs.repoName.localizedStandardCompare(rhs.repoName) == .orderedAscending
    }

    private static func statusPriority(_ status: RepositoryStatus) -> Int {
        switch status {
        case .changed:
            return 0
        case .error:
            return 1
        case .clean:
            return 2
        }
    }
}

enum WidgetPrioritySummaryBuilder {
    static func build(feed: ActivityTimelineFeed,
                      trustAssessment: SnapshotTrustAssessment?) -> WidgetPrioritySummary {
        switch trustAssessment?.state {
        case .stale, .expired:
            return WidgetPrioritySummary(
                title: "数据可能已过期",
                message: "刷新后再判断是否适合提交",
                readinessLevel: nil,
                auxiliary: nil
            )
        case .unknown, .failed, .none:
            return WidgetPrioritySummary(
                title: "状态未知",
                message: "打开 DevPulse 查看 Diagnostics",
                readinessLevel: nil,
                auxiliary: nil
            )
        case .fresh:
            break
        }

        switch feed.state {
        case .neverScanned:
            return WidgetPrioritySummary(
                title: "状态未知",
                message: "打开 DevPulse 执行一次刷新",
                readinessLevel: nil,
                auxiliary: nil
            )
        case .noRepositories:
            return WidgetPrioritySummary(
                title: "没有找到仓库",
                message: "检查扫描目录后重新刷新",
                readinessLevel: nil,
                auxiliary: nil
            )
        case .allClean:
            return WidgetPrioritySummary(
                title: "全部干净",
                message: "暂无改动",
                readinessLevel: .idle,
                auxiliary: feed.items.count == 1 ? "1 个仓库" : "\(feed.items.count) 个仓库"
            )
        case .active:
            guard let item = feed.topItem else {
                return WidgetPrioritySummary(
                    title: "打开 DevPulse",
                    message: "查看当前仓库状态",
                    readinessLevel: nil,
                    auxiliary: nil
                )
            }

            return WidgetPrioritySummary(
                title: item.repoName,
                message: item.commitReadiness.widgetShortHint,
                readinessLevel: item.commitReadiness.level,
                auxiliary: item.commitReadiness.level == .unknown
                    ? "状态异常"
                    : (item.changedFileCount == 1 ? "1 处改动" : "\(item.changedFileCount) 处改动")
            )
        }
    }
}

enum WidgetRepositoryPriorityBuilder {
    static func build(from repositories: [RepositorySnapshot]) -> [ActivityTimelineItem] {
        repositories
            .map(ActivityTimelineItem.init(from:))
            .sorted(by: sort(_:_:))
    }

    static func build(from snapshot: AppGroupData?) -> [ActivityTimelineItem] {
        build(from: snapshot?.repositories ?? [])
    }

    private static func sort(_ lhs: ActivityTimelineItem,
                             _ rhs: ActivityTimelineItem) -> Bool {
        let lhsStatusPriority = statusPriority(lhs.status)
        let rhsStatusPriority = statusPriority(rhs.status)
        if lhsStatusPriority != rhsStatusPriority {
            return lhsStatusPriority < rhsStatusPriority
        }

        if lhs.changedFileCount != rhs.changedFileCount {
            return lhs.changedFileCount > rhs.changedFileCount
        }

        if let lhsDate = lhs.activityDate, let rhsDate = rhs.activityDate, lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        if lhs.activityDate != nil {
            return true
        }

        if rhs.activityDate != nil {
            return false
        }

        let lhsReadinessPriority = readinessPriority(lhs.commitReadiness.level)
        let rhsReadinessPriority = readinessPriority(rhs.commitReadiness.level)
        if lhsReadinessPriority != rhsReadinessPriority {
            return lhsReadinessPriority < rhsReadinessPriority
        }

        if lhs.risk != rhs.risk {
            return lhs.risk > rhs.risk
        }

        return lhs.repoName.localizedStandardCompare(rhs.repoName) == .orderedAscending
    }

    private static func statusPriority(_ status: RepositoryStatus) -> Int {
        switch status {
        case .changed:
            return 0
        case .error:
            return 1
        case .clean:
            return 2
        }
    }

    private static func readinessPriority(_ level: CommitReadinessLevel) -> Int {
        switch level {
        case .dirty:
            return 0
        case .unknown:
            return 1
        case .review:
            return 2
        case .ready:
            return 3
        case .idle:
            return 4
        }
    }
}

struct RepositoryEmptyState: Equatable {
    let title: String
    let detail: String
    let systemImage: String
}

enum RepositoryEmptyStateBuilder {
    static func build(lastScanAt: Date?,
                      refreshPhase: RefreshPhase,
                      scanRoots: [String],
                      accessWarning: String?,
                      refreshFailureMessage: String?) -> RepositoryEmptyState {
        if scanRoots.isEmpty {
            return RepositoryEmptyState(
                title: "没有可用的扫描目录",
                detail: accessWarning ?? "DevPulse 没有找到可访问的默认目录。请在 Settings 添加真实的仓库根目录，然后重新刷新。",
                systemImage: "folder.badge.questionmark"
            )
        }

        if refreshPhase == .failure {
            return RepositoryEmptyState(
                title: "扫描未完成",
                detail: refreshFailureMessage ?? accessWarning ?? "请检查扫描目录后重新刷新。",
                systemImage: "exclamationmark.triangle"
            )
        }

        if lastScanAt == nil {
            return RepositoryEmptyState(
                title: "尚未开始扫描",
                detail: "执行 Rescan Now，DevPulse 会先扫描默认目录并尝试发现本机 Git 仓库。",
                systemImage: "magnifyingglass"
            )
        }

        return RepositoryEmptyState(
            title: "未发现 Git 仓库",
            detail: accessWarning ?? "已扫描当前目录，但没有发现可读取的 Git 仓库；可在 Settings 添加其他目录后重试。",
            systemImage: "tray"
        )
    }
}

// MARK: - Scan summary

struct ScanSummary: Codable, Equatable {
    let totalRepositories: Int
    let changedRepositories: Int
    let totalChangedFiles: Int
    let errorRepositories: Int
}

// MARK: - App Group root data

struct AppGroupData: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: String
    let writtenAt: String?
    let scanSummary: ScanSummary
    let repositories: [RepositorySnapshot]

    static func empty() -> AppGroupData {
        AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            writtenAt: nil,
            scanSummary: ScanSummary(
                totalRepositories: 0,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 0
            ),
            repositories: []
        )
    }

    func withWrittenAt(_ writtenAt: String) -> AppGroupData {
        AppGroupData(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            writtenAt: writtenAt,
            scanSummary: scanSummary,
            repositories: repositories
        )
    }
}

// MARK: - Refresh status

enum RefreshPhase: Equatable {
    case idle
    case refreshing
    case success
    case failure
}

enum SnapshotFreshness: Equatable {
    case fresh
    case stale
    case expired
    case unknown
}

enum SnapshotTrustState: Equatable {
    case fresh
    case stale
    case expired
    case unknown
    case failed
}

struct SnapshotTrustAssessment: Equatable {
    let state: SnapshotTrustState
    let title: String
    let detail: String
    let basis: String

    var isError: Bool {
        state != .fresh
    }
}

enum RefreshStatusFormatter {
    static let staleThreshold: TimeInterval = 10 * 60
    static let expiredThreshold: TimeInterval = 30 * 60

    static func freshness(for lastUpdatedAt: Date?, now: Date = Date()) -> SnapshotFreshness {
        guard let lastUpdatedAt else {
            return .unknown
        }

        let age = max(0, now.timeIntervalSince(lastUpdatedAt))

        if age > expiredThreshold {
            return .expired
        }

        if age >= staleThreshold {
            return .stale
        }

        return .fresh
    }

    static func refreshAssessment(
        lastUpdatedAt: Date?,
        now: Date = Date(),
        failureMessage: String? = nil
    ) -> SnapshotTrustAssessment {
        if let failureMessage, !failureMessage.isEmpty {
            let basis: String
            if let lastUpdatedAt {
                basis = "最近一次刷新失败：\(failureMessage)。当前仍显示 \(updateLabel(for: lastUpdatedAt, now: now)) 的成功结果。"
            } else {
                basis = "还没有成功刷新记录，最近一次刷新失败：\(failureMessage)。"
            }

            return SnapshotTrustAssessment(
                state: .failed,
                title: "刷新失败，建议打开 App 检查",
                detail: lastUpdatedAt.map { "上次成功刷新：\(updateLabel(for: $0, now: now))" } ?? "尚无成功刷新记录",
                basis: basis
            )
        }

        return datedAssessment(
            freshness: freshness(for: lastUpdatedAt, now: now),
            referenceDate: lastUpdatedAt,
            now: now,
            sourceLabel: "lastScanAt",
            missingReason: "还没有成功刷新记录。"
        )
    }

    static func snapshotAssessment(
        generatedAt: String?,
        writtenAt: String?,
        now: Date = Date(),
        readError: String? = nil,
        missingReason: String = "共享快照缺少可用时间。"
    ) -> SnapshotTrustAssessment {
        if let readError, !readError.isEmpty {
            return SnapshotTrustAssessment(
                state: .unknown,
                title: "状态未知",
                detail: "无法确认共享快照是否最新",
                basis: "共享快照读取失败：\(readError)"
            )
        }

        let generatedDate = generatedAt.flatMap(DateFormatting.date(from:))
        let writtenDate = writtenAt.flatMap(DateFormatting.date(from:))

        let reference: (label: String, date: Date)?
        switch (generatedDate, writtenDate) {
        case let (.some(generatedDate), .some(writtenDate)):
            reference = writtenDate >= generatedDate
                ? ("writtenAt", writtenDate)
                : ("generatedAt", generatedDate)
        case let (.some(generatedDate), .none):
            reference = ("generatedAt", generatedDate)
        case let (.none, .some(writtenDate)):
            reference = ("writtenAt", writtenDate)
        case (.none, .none):
            reference = nil
        }

        return datedAssessment(
            freshness: freshness(for: reference?.date, now: now),
            referenceDate: reference?.date,
            now: now,
            sourceLabel: reference?.label ?? "snapshotTime",
            missingReason: missingReason
        )
    }

    static func updateLabel(for lastUpdatedAt: Date, now: Date = Date()) -> String {
        let age = max(0, now.timeIntervalSince(lastUpdatedAt))

        if age < 60 {
            return "刚刚更新"
        }

        if age < 3600 {
            return "\(Int(age / 60)) 分钟前更新"
        }

        if age < 86400 {
            return "\(Int(age / 3600)) 小时前更新"
        }

        return "\(Int(age / 86400)) 天前更新"
    }

    private static func datedAssessment(
        freshness: SnapshotFreshness,
        referenceDate: Date?,
        now: Date,
        sourceLabel: String,
        missingReason: String
    ) -> SnapshotTrustAssessment {
        switch freshness {
        case .fresh:
            guard let referenceDate else {
                return SnapshotTrustAssessment(
                    state: .unknown,
                    title: "状态未知",
                    detail: "无法确认数据是否最新",
                    basis: missingReason
                )
            }

            return SnapshotTrustAssessment(
                state: .fresh,
                title: updateLabel(for: referenceDate, now: now),
                detail: "数据仍在可信时间窗内",
                basis: "基于 \(sourceLabel) 判断，最新时间是 \(formattedDate(referenceDate))。"
            )
        case .stale:
            guard let referenceDate else {
                return SnapshotTrustAssessment(
                    state: .unknown,
                    title: "状态未知",
                    detail: "无法确认数据是否最新",
                    basis: missingReason
                )
            }

            return SnapshotTrustAssessment(
                state: .stale,
                title: "数据可能已过期",
                detail: "最近一次更新在 \(updateLabel(for: referenceDate, now: now))",
                basis: "基于 \(sourceLabel) 判断，距离最近一次更新已超过 10 分钟。"
            )
        case .expired:
            guard let referenceDate else {
                return SnapshotTrustAssessment(
                    state: .unknown,
                    title: "状态未知",
                    detail: "无法确认数据是否最新",
                    basis: missingReason
                )
            }

            return SnapshotTrustAssessment(
                state: .expired,
                title: "数据可能已过期",
                detail: "最近一次更新在 \(updateLabel(for: referenceDate, now: now))",
                basis: "基于 \(sourceLabel) 判断，距离最近一次更新已超过 30 分钟。"
            )
        case .unknown:
            return SnapshotTrustAssessment(
                state: .unknown,
                title: "状态未知",
                detail: "无法确认数据是否最新",
                basis: missingReason
            )
        }
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Widget-specific display entry

struct WidgetRepositoryEntry: Codable {
    let id: String
    let name: String
    let branch: String
    let status: RepositoryStatus
    let changedFileCount: Int
    let risk: RiskLevel
    let topChangedFile: String?

    init(from snapshot: RepositorySnapshot) {
        self.id = snapshot.id
        self.name = snapshot.name
        self.branch = snapshot.branch
        self.status = snapshot.status
        self.changedFileCount = snapshot.changedFileCount
        self.risk = snapshot.risk
        self.topChangedFile = snapshot.changedFilesPreview.first
    }
}

// MARK: - Diagnostics

struct DiagnosticEvent: Identifiable, Equatable {
    enum Kind: String, Codable {
        case scanStarted
        case scanSucceeded
        case scanFailed
        case sharedDataWritten
        case sharedDataWriteFailed
        case sharedDataReadFailed
        case widgetReloadRequested
        case validationPassed
        case validationFailed
    }

    let id = UUID()
    let timestamp: String
    let kind: Kind
    let message: String
}

struct DiagnosticsSnapshot {
    var appBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "unknown"
    var widgetBundleIdentifier: String = "local.devpulse.app.widget"
    var appGroupIdentifier: String = SharedSnapshotLocation.appGroupIdentifier
    var appGroupContainerPath: String?
    var snapshotFilePath: String?
    var appGroupAvailable: Bool = false
    var snapshotExists: Bool = false
    var snapshotReadable: Bool = false
    var snapshotWritable: Bool = false
    var snapshotDecodable: Bool = false
    var lastScanAt: Date?
    var lastGeneratedAt: String?
    var lastWrittenAt: String?
    var lastSharedWriteAt: Date?
    var lastReloadRequestedAt: Date?
    var sharedDataReadAt: Date?
    var widgetSnapshotReadAt: Date?
    var sharedDataReadError: String?
    var sharedDataWriteError: String?
    var widgetSnapshotReadError: String?
    var validationIssues: [String] = []
    var scanRoots: [String] = []
    var scanRootWarnings: [String] = []
    var nextSteps: [String] = []
    var sharedDataSnapshot: AppGroupData?
    var widgetSnapshot: AppGroupData?

    var sharedDataReadSucceeded: Bool {
        sharedDataReadError == nil && sharedDataSnapshot != nil
    }

    var sharedDataWriteSucceeded: Bool {
        sharedDataWriteError == nil && lastSharedWriteAt != nil
    }

    var widgetSnapshotReadSucceeded: Bool {
        widgetSnapshotReadError == nil && widgetSnapshot != nil
    }
}

enum DiagnosticsSeverity: Equatable {
    case normal
    case warning
    case error
}

struct DiagnosticsStatusItem: Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let nextStep: String?
    let severity: DiagnosticsSeverity
}

struct DiagnosticsSectionModel: Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let severity: DiagnosticsSeverity
    let items: [DiagnosticsStatusItem]
}

struct DiagnosticsOverviewModel: Equatable {
    let headline: String
    let summary: String
    let severity: DiagnosticsSeverity
    let sections: [DiagnosticsSectionModel]
}

struct WidgetDataTrustModel: Equatable {
    let headline: String
    let summary: String
    let severity: DiagnosticsSeverity
    let evidence: [DiagnosticsStatusItem]
    let nextSteps: [String]
    let primaryAction: WidgetDataTrustPrimaryAction
}

enum WidgetDataTrustPrimaryActionKind: Equatable {
    case refreshData
    case rescan
    case viewDiagnostics
}

struct WidgetDataTrustPrimaryAction: Equatable {
    let kind: WidgetDataTrustPrimaryActionKind
    let title: String
    let systemImage: String
    let helpText: String

    var requiresScanning: Bool {
        switch kind {
        case .refreshData, .rescan:
            return true
        case .viewDiagnostics:
            return false
        }
    }
}

struct WidgetDataTrustPrimaryButtonModel: Equatable {
    let title: String
    let systemImage: String
    let helpText: String
    let isDisabled: Bool
    let actionKind: WidgetDataTrustPrimaryActionKind
}

enum WidgetDataTrustPrimaryButtonBuilder {
    static func build(
        action: WidgetDataTrustPrimaryAction,
        isScanning: Bool
    ) -> WidgetDataTrustPrimaryButtonModel {
        let title: String

        switch action.kind {
        case .refreshData:
            title = isScanning ? "刷新中…" : action.title
        case .rescan:
            title = isScanning ? "扫描中…" : action.title
        case .viewDiagnostics:
            title = action.title
        }

        return WidgetDataTrustPrimaryButtonModel(
            title: title,
            systemImage: action.systemImage,
            helpText: action.helpText,
            isDisabled: action.requiresScanning && isScanning,
            actionKind: action.kind
        )
    }
}

enum AppTab: Int, Equatable {
    case overview = 0
    case repositories = 1
    case settings = 2
}

enum SettingsScrollTarget: Hashable {
    case diagnostics
}

enum OverviewPrimaryActionKind: Equatable {
    case refreshData
    case rescan
    case openRepositories
    case openSettings
    case openDiagnostics
}

struct OverviewPrimaryAction: Equatable {
    let kind: OverviewPrimaryActionKind
    let title: String
    let systemImage: String
}

struct OverviewFocusModel: Equatable {
    let title: String
    let summary: String
    let detail: String?
    let severity: DiagnosticsSeverity
    let action: OverviewPrimaryAction
}

enum OverviewDiagnosticsNavigation {
    static let tab: AppTab = .settings
    static let scrollTarget: SettingsScrollTarget = .diagnostics
}

enum OverviewFocusBuilder {
    static func build(
        lastScanAt: Date?,
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: WidgetDataTrustModel,
        repositories: [RepositorySnapshot]
    ) -> OverviewFocusModel {
        if diagnostics.scanRoots.isEmpty {
            return OverviewFocusModel(
                title: "没有可用的扫描目录",
                summary: "当前还没有可访问的仓库根目录，Overview 暂时不会展示仓库状态。",
                detail: "去 Settings 添加真实仓库目录后，再执行一次刷新。",
                severity: .warning,
                action: OverviewPrimaryAction(
                    kind: .openSettings,
                    title: "打开 Settings",
                    systemImage: "gearshape"
                )
            )
        }

        if repositories.isEmpty {
            if lastScanAt == nil {
                return OverviewFocusModel(
                    title: "尚未开始扫描",
                    summary: "先建立一次当前快照，Overview 才能判断哪一个仓库最值得处理。",
                    detail: "执行一次 Rescan 后，会自动发现扫描目录里的 Git 仓库。",
                    severity: .warning,
                    action: OverviewPrimaryAction(
                        kind: .rescan,
                        title: "Rescan Now",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                )
            }

            return OverviewFocusModel(
                title: "还没有发现仓库",
                summary: "当前扫描目录里没有可读取的 Git 仓库。",
                detail: "去 Settings 调整扫描目录，或确认目录访问权限后再刷新。",
                severity: .warning,
                action: OverviewPrimaryAction(
                    kind: .openSettings,
                    title: "检查 Settings",
                    systemImage: "gearshape"
                )
            )
        }

        if widgetTrust.severity == .error {
            return widgetTrustFocus(widgetTrust)
        }

        if let repo = priorityRepository(in: repositories) {
            return repositoryFocus(repo)
        }

        if widgetTrust.severity == .warning {
            return widgetTrustFocus(widgetTrust)
        }

        let repoCountLabel = repositories.count == 1 ? "1 个仓库" : "\(repositories.count) 个仓库"
        return OverviewFocusModel(
            title: "当前没有需要处理的仓库",
            summary: "\(repoCountLabel) 当前都没有待审查的本地改动。",
            detail: "如果想逐个确认状态，可以去 Repositories 查看完整列表。",
            severity: .normal,
            action: OverviewPrimaryAction(
                kind: .openRepositories,
                title: "查看仓库列表",
                systemImage: "list.bullet.rectangle"
            )
        )
    }

    private static func widgetTrustFocus(_ widgetTrust: WidgetDataTrustModel) -> OverviewFocusModel {
        OverviewFocusModel(
            title: widgetTrust.headline,
            summary: widgetTrust.summary,
            detail: widgetTrust.nextSteps.first,
            severity: widgetTrust.severity,
            action: OverviewPrimaryAction(
                kind: mapActionKind(widgetTrust.primaryAction.kind),
                title: widgetTrust.primaryAction.title,
                systemImage: widgetTrust.primaryAction.systemImage
            )
        )
    }

    private static func repositoryFocus(_ repo: RepositorySnapshot) -> OverviewFocusModel {
        if repo.status == .error || repo.commitReadiness.level == .unknown {
            return OverviewFocusModel(
                title: "\(repo.name) 状态读取失败",
                summary: repo.statusSummary,
                detail: repo.nextActionHint,
                severity: .error,
                action: OverviewPrimaryAction(
                    kind: .openDiagnostics,
                    title: "查看诊断",
                    systemImage: "stethoscope"
                )
            )
        }

        return OverviewFocusModel(
            title: repo.name,
            summary: repo.statusSummary,
            detail: repo.nextActionHint,
            severity: severity(for: repo.commitReadiness.level),
            action: OverviewPrimaryAction(
                kind: .openRepositories,
                title: "查看仓库列表",
                systemImage: "list.bullet.rectangle"
            )
        )
    }

    private static func priorityRepository(in repositories: [RepositorySnapshot]) -> RepositorySnapshot? {
        if let brokenRepo = repositories.first(where: { $0.status == .error || $0.commitReadiness.level == .unknown }) {
            return brokenRepo
        }

        return repositories.sorted(by: repositoryPriority(_:_:)).first {
            $0.commitReadiness.level != .idle || (($0.aheadCount ?? 0) > 0)
        }
    }

    private static func repositoryPriority(_ lhs: RepositorySnapshot, _ rhs: RepositorySnapshot) -> Bool {
        let lhsReadinessPriority = readinessPriority(lhs.commitReadiness.level)
        let rhsReadinessPriority = readinessPriority(rhs.commitReadiness.level)
        if lhsReadinessPriority != rhsReadinessPriority {
            return lhsReadinessPriority < rhsReadinessPriority
        }

        if lhs.changedFileCount != rhs.changedFileCount {
            return lhs.changedFileCount > rhs.changedFileCount
        }

        if lhs.risk != rhs.risk {
            return lhs.risk > rhs.risk
        }

        if let lhsDate = isoDate(lhs.lastChangedAt), let rhsDate = isoDate(rhs.lastChangedAt), lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        if lhs.lastChangedAt != nil {
            return true
        }

        if rhs.lastChangedAt != nil {
            return false
        }

        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func mapActionKind(_ kind: WidgetDataTrustPrimaryActionKind) -> OverviewPrimaryActionKind {
        switch kind {
        case .refreshData:
            return .refreshData
        case .rescan:
            return .rescan
        case .viewDiagnostics:
            return .openDiagnostics
        }
    }

    private static func severity(for level: CommitReadinessLevel) -> DiagnosticsSeverity {
        switch level {
        case .ready:
            return .normal
        case .review, .idle:
            return .warning
        case .dirty, .unknown:
            return .error
        }
    }

    private static func readinessPriority(_ level: CommitReadinessLevel) -> Int {
        switch level {
        case .unknown:
            return 0
        case .dirty:
            return 1
        case .review:
            return 2
        case .ready:
            return 3
        case .idle:
            return 4
        }
    }

    private static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

enum DiagnosticsOverviewBuilder {
    static func build(
        diagnostics: DiagnosticsSnapshot,
        refreshTrust: SnapshotTrustAssessment,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> DiagnosticsOverviewModel {
        let sharedDataSection = sharedDataSection(
            diagnostics: diagnostics,
            repositories: repositories
        )
        let widgetSection = widgetSection(diagnostics: diagnostics, widgetTrust: widgetTrust)
        let scanSection = scanSection(
            diagnostics: diagnostics,
            refreshTrust: refreshTrust,
            repositories: repositories
        )

        let sections = [sharedDataSection, widgetSection, scanSection]
        let headline: (title: String, summary: String, severity: DiagnosticsSeverity)

        if let topError = sections.first(where: { $0.severity == .error }) {
            headline = (topError.title, topError.summary, .error)
        } else if let topWarning = sections.first(where: { $0.severity == .warning }) {
            headline = (topWarning.title, topWarning.summary, .warning)
        } else {
            headline = ("链路正常", "App、共享快照和 Widget 当前看起来一致。", .normal)
        }

        return DiagnosticsOverviewModel(
            headline: headline.title,
            summary: headline.summary,
            severity: headline.severity,
            sections: sections
        )
    }

    private static func sharedDataSection(
        diagnostics: DiagnosticsSnapshot,
        repositories: [RepositorySnapshot]
    ) -> DiagnosticsSectionModel {
        let appGroupSeverity: DiagnosticsSeverity = diagnostics.appGroupAvailable ? .normal : .error
        let isInitialSnapshotMissing = isInitialSnapshotMissing(
            diagnostics: diagnostics,
            repositories: repositories
        )
        let fileSeverity: DiagnosticsSeverity = diagnostics.snapshotExists
            ? .normal
            : (isInitialSnapshotMissing ? .warning : .error)
        let readSeverity: DiagnosticsSeverity
        if diagnostics.sharedDataReadError != nil {
            readSeverity = .error
        } else if diagnostics.sharedDataSnapshot != nil {
            readSeverity = .normal
        } else {
            readSeverity = .warning
        }

        let items = [
            DiagnosticsStatusItem(
                id: "app-group",
                title: "App Group",
                value: diagnostics.appGroupAvailable ? "可用" : "不可用",
                detail: diagnostics.appGroupContainerPath ?? "没有拿到共享容器路径。",
                nextStep: diagnostics.appGroupAvailable ? nil : "检查 App Group entitlement 和签名配置。",
                severity: appGroupSeverity
            ),
            DiagnosticsStatusItem(
                id: "snapshot-file",
                title: "数据文件",
                value: diagnostics.snapshotExists ? "已找到" : "缺失",
                detail: diagnostics.snapshotFilePath ?? "没有解析到 repositories.json 路径。",
                nextStep: diagnostics.snapshotExists ? nil : "先执行一次 Rescan，确认 repositories.json 已写入共享容器。",
                severity: fileSeverity
            ),
            DiagnosticsStatusItem(
                id: "shared-read",
                title: "共享读取",
                value: diagnostics.sharedDataSnapshot != nil ? "成功" : (diagnostics.sharedDataReadError == nil ? "等待中" : "失败"),
                detail: diagnostics.sharedDataReadError
                    ?? diagnostics.sharedDataReadAt.map { "最近读回：\(formattedDate($0))" }
                    ?? "启动后还没有完成一次共享快照读回。",
                nextStep: diagnostics.sharedDataReadError == nil ? nil : "检查数据文件是否可读，再重新执行一次 Rescan。",
                severity: readSeverity
            )
        ]

        let severity = maxSeverity(items.map(\.severity))
        let summary = items.first(where: { $0.severity == .error })?.detail
            ?? items.first(where: { $0.severity == .warning })?.detail
            ?? "App Group 与共享快照文件当前可访问。"

        return DiagnosticsSectionModel(
            id: "shared-data",
            title: "共享数据链路",
            summary: summary,
            severity: severity,
            items: items
        )
    }

    private static func widgetSection(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment
    ) -> DiagnosticsSectionModel {
        let trustSeverity = severity(for: widgetTrust.state)
        let snapshotSeverity: DiagnosticsSeverity
        if diagnostics.widgetSnapshotReadError != nil {
            snapshotSeverity = .error
        } else if diagnostics.widgetSnapshot != nil {
            snapshotSeverity = .normal
        } else {
            snapshotSeverity = .warning
        }
        let validationSeverity = diagnostics.validationIssues.isEmpty ? DiagnosticsSeverity.normal : .error

        let items = [
            DiagnosticsStatusItem(
                id: "widget-trust",
                title: "Widget 数据可信度",
                value: widgetTrust.title,
                detail: widgetTrust.basis,
                nextStep: widgetTrust.isError ? "如果 Widget 文案看起来不对，优先检查这里的时间戳和读取结果。" : nil,
                severity: trustSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-snapshot",
                title: "Widget 可读快照",
                value: diagnostics.widgetSnapshot != nil ? "可读取" : (diagnostics.widgetSnapshotReadError == nil ? "等待中" : "读取失败"),
                detail: diagnostics.widgetSnapshotReadError
                    ?? diagnostics.widgetSnapshotReadAt.map { "最近读取：\(formattedDate($0))" }
                    ?? "Widget 侧还没有拿到快照。",
                nextStep: diagnostics.widgetSnapshotReadError == nil ? nil : "先确认共享快照已写入，再重新打开 App 检查 Widget reload。",
                severity: snapshotSeverity
            ),
            DiagnosticsStatusItem(
                id: "validation",
                title: "数据一致性",
                value: diagnostics.validationIssues.isEmpty ? "一致" : "不一致",
                detail: diagnostics.validationIssues.isEmpty
                    ? "主 App、共享快照和 Widget 可读快照当前一致。"
                    : diagnostics.validationIssues.joined(separator: " "),
                nextStep: diagnostics.validationIssues.isEmpty ? nil : "按顺序检查 shared write、widget snapshot 和 reload requested 时间。",
                severity: validationSeverity
            )
        ]

        let severity = maxSeverity(items.map(\.severity))
        let summary = items.first(where: { $0.severity == .error })?.detail
            ?? items.first(where: { $0.severity == .warning })?.detail
            ?? "Widget 当前拿到的数据和主 App 一致。"

        return DiagnosticsSectionModel(
            id: "widget-state",
            title: "Widget 状态",
            summary: summary,
            severity: severity,
            items: items
        )
    }

    private static func scanSection(
        diagnostics: DiagnosticsSnapshot,
        refreshTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> DiagnosticsSectionModel {
        let repoErrors = repositories.filter { $0.status == .error || $0.commitReadiness.level == .unknown }
        let repoSeverity: DiagnosticsSeverity
        if !repoErrors.isEmpty {
            repoSeverity = .error
        } else if repositories.isEmpty {
            repoSeverity = .warning
        } else {
            repoSeverity = .normal
        }

        let items = [
            DiagnosticsStatusItem(
                id: "refresh-trust",
                title: "最近扫描",
                value: refreshTrust.title,
                detail: refreshTrust.basis,
                nextStep: refreshTrust.isError ? "如果数据过旧或刷新失败，先手动执行一次 Rescan。" : nil,
                severity: severity(for: refreshTrust.state)
            ),
            DiagnosticsStatusItem(
                id: "repo-detection",
                title: "仓库识别",
                value: repositories.isEmpty ? "没有仓库" : "识别到 \(repositories.count) 个仓库",
                detail: repoErrors.isEmpty
                    ? (repositories.isEmpty ? "当前快照里没有仓库。" : "当前没有仓库读取失败。")
                    : "有 \(repoErrors.count) 个仓库读取失败或状态未知。",
                nextStep: repositories.isEmpty
                    ? "检查扫描目录是否指向真实仓库根目录。"
                    : (repoErrors.isEmpty ? nil : "打开下方仓库列表，优先处理标红的 Git 读取失败项。"),
                severity: repoSeverity
            ),
            DiagnosticsStatusItem(
                id: "last-error",
                title: "最近一次异常",
                value: latestErrorMessage(diagnostics: diagnostics) == nil ? "无" : "已记录",
                detail: latestErrorMessage(diagnostics: diagnostics) ?? "当前没有新的错误原因。",
                nextStep: latestErrorMessage(diagnostics: diagnostics) == nil ? nil : "如果问题已经消失，再执行一次 Rescan 确认异常不会复现。",
                severity: latestErrorMessage(diagnostics: diagnostics) == nil ? .normal : .warning
            )
        ]

        let severity = maxSeverity(items.map(\.severity))
        let summary = items.first(where: { $0.severity == .error })?.detail
            ?? items.first(where: { $0.severity == .warning })?.detail
            ?? "最近一次扫描成功，仓库识别正常。"

        return DiagnosticsSectionModel(
            id: "scan-state",
            title: "扫描与仓库识别",
            summary: summary,
            severity: severity,
            items: items
        )
    }

    private static func latestErrorMessage(diagnostics: DiagnosticsSnapshot) -> String? {
        diagnostics.widgetSnapshotReadError
            ?? diagnostics.sharedDataWriteError
            ?? diagnostics.sharedDataReadError
            ?? diagnostics.validationIssues.first
    }

    private static func severity(for state: SnapshotTrustState) -> DiagnosticsSeverity {
        switch state {
        case .fresh:
            return .normal
        case .stale, .expired, .unknown:
            return .warning
        case .failed:
            return .error
        }
    }

    private static func isInitialSnapshotMissing(
        diagnostics: DiagnosticsSnapshot,
        repositories: [RepositorySnapshot]
    ) -> Bool {
        diagnostics.appGroupAvailable
            && !diagnostics.snapshotExists
            && repositories.isEmpty
            && diagnostics.sharedDataReadError == nil
            && diagnostics.sharedDataWriteError == nil
            && diagnostics.lastSharedWriteAt == nil
            && diagnostics.sharedDataSnapshot == nil
    }

    private static func maxSeverity(_ severities: [DiagnosticsSeverity]) -> DiagnosticsSeverity {
        if severities.contains(.error) {
            return .error
        }
        if severities.contains(.warning) {
            return .warning
        }
        return .normal
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

enum WidgetDataTrustBuilder {
    static func build(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> WidgetDataTrustModel {
        let evidence = buildEvidence(
            diagnostics: diagnostics,
            widgetTrust: widgetTrust,
            repositories: repositories
        )
        let severity = overallSeverity(
            diagnostics: diagnostics,
            widgetTrust: widgetTrust,
            repositories: repositories
        )
        let headline = headline(
            diagnostics: diagnostics,
            severity: severity,
            widgetTrust: widgetTrust,
            repositories: repositories
        )
        let summary = summary(
            diagnostics: diagnostics,
            widgetTrust: widgetTrust,
            repositories: repositories
        )
        let nextSteps = nextSteps(
            diagnostics: diagnostics,
            widgetTrust: widgetTrust,
            repositories: repositories
        )

        return WidgetDataTrustModel(
            headline: headline,
            summary: summary,
            severity: severity,
            evidence: evidence,
            nextSteps: nextSteps,
            primaryAction: primaryAction(
                diagnostics: diagnostics,
                widgetTrust: widgetTrust,
                repositories: repositories
            )
        )
    }

    private static func buildEvidence(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> [DiagnosticsStatusItem] {
        let isInitialSnapshotMissing = isInitialSnapshotMissing(
            diagnostics: diagnostics,
            repositories: repositories
        )
        let snapshotExistsSeverity: DiagnosticsSeverity = diagnostics.snapshotExists ? .normal : (isInitialSnapshotMissing ? .warning : .error)
        let snapshotReadableSeverity: DiagnosticsSeverity = diagnostics.snapshotReadable ? .normal : (isInitialSnapshotMissing ? .warning : .error)
        let snapshotWritableSeverity: DiagnosticsSeverity = diagnostics.snapshotWritable ? .normal : .error
        let snapshotDecodableSeverity: DiagnosticsSeverity = diagnostics.snapshotDecodable ? .normal : (isInitialSnapshotMissing ? .warning : .error)
        let freshnessSeverity = severity(for: widgetTrust.state)
        let consistencySeverity = diagnostics.validationIssues.isEmpty ? DiagnosticsSeverity.normal : .error

        return [
            DiagnosticsStatusItem(
                id: "widget-trust-snapshot-exists",
                title: "共享快照文件",
                value: diagnostics.snapshotExists ? "已生成" : "缺失",
                detail: diagnostics.snapshotFilePath ?? "还没有解析到 repositories.json 路径。",
                nextStep: diagnostics.snapshotExists ? nil : "先执行一次 Rescan Now，确认主 App 已生成共享快照。",
                severity: snapshotExistsSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-trust-snapshot-readable",
                title: "主 App 可读",
                value: diagnostics.snapshotReadable ? "可以读取" : "无法读取",
                detail: diagnostics.sharedDataReadError
                    ?? "主 App 可以读回共享快照。读取失败时这里会显示错误原因。",
                nextStep: diagnostics.snapshotReadable ? nil : "检查 App Group、签名和共享容器路径后再执行 Refresh Data。",
                severity: snapshotReadableSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-trust-snapshot-writable",
                title: "主 App 可写",
                value: diagnostics.snapshotWritable ? "可以重写" : "无法重写",
                detail: diagnostics.sharedDataWriteError
                    ?? diagnostics.lastSharedWriteAt.map { "最近一次确认写入：\(formattedDate($0))" }
                    ?? "主 App 还没有完成一次确认写入。",
                nextStep: diagnostics.snapshotWritable ? nil : "检查 App Group entitlement、签名和容器权限，再执行 Refresh Data。",
                severity: snapshotWritableSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-trust-snapshot-decodable",
                title: "快照可解码",
                value: diagnostics.snapshotDecodable ? "可以解码" : "无法解码",
                detail: diagnostics.snapshotDecodable
                    ? "共享快照 schema 和当前 App 一致。"
                    : (diagnostics.sharedDataReadError ?? "还没有拿到一份可解码的共享快照。"),
                nextStep: diagnostics.snapshotDecodable ? nil : "如果反复失败，清理构建产物并让 App 重写共享快照。",
                severity: snapshotDecodableSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-trust-freshness",
                title: "最新程度",
                value: widgetTrust.title,
                detail: widgetTrust.basis,
                nextStep: widgetTrust.state == .fresh ? nil : "如果时间已经过旧，优先执行 Refresh Data；仍异常再检查 Widget reload 和签名配置。",
                severity: freshnessSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-trust-consistency",
                title: "App / Widget 一致性",
                value: diagnostics.validationIssues.isEmpty ? "一致" : "不一致",
                detail: diagnostics.validationIssues.isEmpty
                    ? "主 App、共享快照和 Widget 当前看到的是同一份数据。"
                    : diagnostics.validationIssues.joined(separator: " "),
                nextStep: diagnostics.validationIssues.isEmpty ? nil : "先看 shared write、widget snapshot 和 reload requested 的时间是否连续成功。",
                severity: consistencySeverity
            )
        ]
    }

    private static func overallSeverity(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> DiagnosticsSeverity {
        let isInitialSnapshotMissing = isInitialSnapshotMissing(
            diagnostics: diagnostics,
            repositories: repositories
        )

        if !diagnostics.appGroupAvailable
            || (!diagnostics.snapshotExists && !isInitialSnapshotMissing)
            || (!diagnostics.snapshotReadable && !isInitialSnapshotMissing)
            || !diagnostics.snapshotWritable
            || (!diagnostics.snapshotDecodable && !isInitialSnapshotMissing)
            || diagnostics.sharedDataReadError != nil
            || diagnostics.sharedDataWriteError != nil
            || diagnostics.widgetSnapshotReadError != nil
            || !diagnostics.validationIssues.isEmpty {
            return .error
        }

        switch widgetTrust.state {
        case .fresh:
            return .normal
        case .stale, .expired, .unknown, .failed:
            return .warning
        }
    }

    private static func headline(
        diagnostics: DiagnosticsSnapshot,
        severity: DiagnosticsSeverity,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> String {
        switch severity {
        case .normal:
            return "当前 Widget 数据可信"
        case .warning:
            if isInitialSnapshotMissing(
                diagnostics: diagnostics,
                repositories: repositories
            ) {
                return "Widget 尚未生成快照"
            }
            switch widgetTrust.state {
            case .stale, .expired:
                return "当前 Widget 数据可能过期"
            case .unknown, .failed:
                return "当前无法确认 Widget 数据是否可信"
            case .fresh:
                return "当前 Widget 数据基本可信"
            }
        case .error:
            if !diagnostics.snapshotExists {
                return "Widget 还没有可用快照"
            }
            return "当前 Widget 数据不可信，建议先修复"
        }
    }

    private static func summary(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> String {
        switch overallSeverity(
            diagnostics: diagnostics,
            widgetTrust: widgetTrust,
            repositories: repositories
        ) {
        case .normal:
            let repoSummary = repositories.isEmpty ? "当前快照里还没有仓库" : "当前快照包含 \(repositories.count) 个仓库"
            return "\(repoSummary)，且共享快照存在、可读、可写、可解码，Widget 看到的数据仍在可信时间窗内。"
        case .warning:
            if isInitialSnapshotMissing(
                diagnostics: diagnostics,
                repositories: repositories
            ) {
                return "共享快照还没有生成，Widget 会提示先执行 Rescan Now；这是首次启动或清空快照后的正常待初始化状态。"
            }
            return widgetTrust.detail + "。共享链路基本正常，但你应先刷新后再判断 Widget 里的仓库状态。"
        case .error:
            if !diagnostics.appGroupAvailable {
                return "主 App 还拿不到共享容器，Widget 无法和 App 对齐同一份数据。"
            }
            if !diagnostics.snapshotExists {
                if repositories.isEmpty {
                    return "共享快照还没有生成，Widget 现在没有可验证的数据来源。"
                }
                return "主界面已经拿到扫描结果，但还没有写出 Widget 可读快照。先刷新数据，把当前结果共享给 Widget。"
            }
            if !diagnostics.snapshotReadable || diagnostics.sharedDataReadError != nil {
                return "主 App 读不回共享快照，当前无法确认 Widget 正在显示什么数据。"
            }
            if !diagnostics.snapshotWritable || diagnostics.sharedDataWriteError != nil {
                return "主 App 无法重写共享快照，所以你不能相信 Widget 会跟上新的扫描结果。"
            }
            if !diagnostics.snapshotDecodable {
                return "共享快照存在但无法解码，Widget 数据来源已经损坏或 schema 不一致。"
            }
            if let widgetSnapshotReadError = diagnostics.widgetSnapshotReadError {
                return "Widget 侧读取共享快照失败：\(widgetSnapshotReadError)"
            }
            return diagnostics.validationIssues.first
                ?? "主 App、共享快照和 Widget 之间出现不一致，当前状态需要先修复后再判断。"
        }
    }

    private static func nextSteps(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> [String] {
        if !diagnostics.appGroupAvailable {
            return [
                "先检查 DevPulse 与 Widget Extension 是否使用同一个 Team 和 `group.local.devpulse`。",
                "修正 Signing / App Group 后执行 Refresh Data，确认共享容器路径重新出现。",
                "如果仍然不可用，清理构建目录并重装 App。"
            ]
        }

        if !diagnostics.snapshotExists {
            if repositories.isEmpty {
                return [
                    "先执行一次 Rescan Now，让主 App 重新发现仓库并生成共享快照。",
                    "如果还是缺失，检查扫描目录是否指向真实仓库根目录。",
                    "若目录正常但快照仍未生成，再检查 App Group / Signing。"
                ]
            }
            return [
                "先执行 Refresh Data，把当前扫描结果写入共享快照。",
                "如果仍未生成，再检查 Diagnostics 里的 shared write、widget snapshot 和 App Group 状态。",
                "如仍异常，再执行一次重新扫描确认仓库结果能否稳定写入。"
            ]
        }

        if !diagnostics.snapshotReadable || diagnostics.sharedDataReadError != nil {
            return [
                "执行 Refresh Data，再看 shared read 是否恢复成功。",
                "如果仍然读取失败，检查 App Group 容器路径与签名是否一致。",
                "必要时清理构建目录并重装 App，让共享容器重新建立。"
            ]
        }

        if !diagnostics.snapshotWritable || diagnostics.sharedDataWriteError != nil {
            return [
                "先执行 Refresh Data，确认主 App 能重新写入共享快照。",
                "如果写入仍失败，检查 App Group entitlement、签名和容器写权限。",
                "必要时清理构建目录并重装 App。"
            ]
        }

        if !diagnostics.snapshotDecodable {
            return [
                "先执行 Refresh Data，让当前版本的 App 重写共享快照。",
                "如果仍无法解码，清理构建目录并同时重建 App 与 Widget。",
                "确认 App 与 Widget 使用同一份 schema 后再重新扫描。"
            ]
        }

        if let widgetSnapshotReadError = diagnostics.widgetSnapshotReadError, !widgetSnapshotReadError.isEmpty {
            return [
                "先执行 Refresh Data，确认 shared write 和 reload requested 都更新成功。",
                "如果 Widget 仍然读取失败，移除桌面上的旧 Widget 后重新添加。",
                "如仍异常，再检查 Signing / App Group 并清理构建目录。"
            ]
        }

        if !diagnostics.validationIssues.isEmpty {
            return [
                "先对照 shared write、widget snapshot 和 reload requested 的时间，确认链路在哪一步断开。",
                "执行 Refresh Data，观察一致性错误是否消失。",
                "如果仍不一致，移除旧 Widget 并重新添加，再重新扫描确认。"
            ]
        }

        switch widgetTrust.state {
        case .fresh:
            return ["当前可以信任 Widget 数据；如果桌面没有立即变化，等待 macOS 刷新时间线即可。"]
        case .stale, .expired:
            return [
                "先执行 Refresh Data，再重新判断 Widget 上的仓库状态。",
                "如果刷新后仍然过期，检查 Widget reload requested 是否更新。",
                "如桌面仍不变，可移除旧 Widget 后重新添加。"
            ]
        case .unknown, .failed:
            return [
                "先执行 Refresh Data，补齐 generatedAt / writtenAt 与 reload requested。",
                "如果仍无法确认，再检查 Diagnostics 中的共享快照与 Widget 读取结果。",
                "必要时清理构建目录并重建 App 与 Widget。"
            ]
        }
    }

    private static func primaryAction(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> WidgetDataTrustPrimaryAction {
        if !diagnostics.appGroupAvailable {
            return WidgetDataTrustPrimaryAction(
                kind: .viewDiagnostics,
                title: "查看诊断",
                systemImage: "stethoscope",
                helpText: "先看 Diagnostics，确认 App Group、签名和共享容器路径。"
            )
        }

        if !diagnostics.snapshotExists {
            if !repositories.isEmpty {
                return WidgetDataTrustPrimaryAction(
                    kind: .refreshData,
                    title: "Refresh Data",
                    systemImage: "arrow.clockwise",
                    helpText: "先把当前扫描结果写入共享快照，再确认 Widget 能否读到。"
                )
            }
            return WidgetDataTrustPrimaryAction(
                kind: .rescan,
                title: "Rescan Now",
                systemImage: "arrow.triangle.2.circlepath",
                helpText: "先重新发现仓库并生成共享快照。"
            )
        }

        if !diagnostics.snapshotReadable || diagnostics.sharedDataReadError != nil {
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "重试读取共享快照，并确认主 App 能读回最新数据。"
            )
        }

        if !diagnostics.snapshotWritable || diagnostics.sharedDataWriteError != nil {
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "重写共享快照并再次请求 Widget 更新时间线。"
            )
        }

        if !diagnostics.snapshotDecodable {
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "让当前版本的 App 重写共享快照，恢复可解码状态。"
            )
        }

        if let widgetSnapshotReadError = diagnostics.widgetSnapshotReadError, !widgetSnapshotReadError.isEmpty {
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "先重写共享快照，再确认 Widget reload 和读取状态。"
            )
        }

        if !diagnostics.validationIssues.isEmpty {
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "先刷新链路，再确认 shared write、widget snapshot 和 reload requested 是否恢复一致。"
            )
        }

        switch widgetTrust.state {
        case .fresh:
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "手动重写共享快照并请求 Widget 更新时间线。"
            )
        case .stale, .expired:
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "共享链路正常，但当前数据已经过旧，先刷新再判断。"
            )
        case .unknown, .failed:
            return WidgetDataTrustPrimaryAction(
                kind: .viewDiagnostics,
                title: "查看诊断",
                systemImage: "stethoscope",
                helpText: "先看 Diagnostics，确认 generatedAt / writtenAt、共享快照和 Widget 读取结果。"
            )
        }
    }

    private static func severity(for state: SnapshotTrustState) -> DiagnosticsSeverity {
        switch state {
        case .fresh:
            return .normal
        case .stale, .expired, .unknown:
            return .warning
        case .failed:
            return .error
        }
    }

    private static func isInitialSnapshotMissing(
        diagnostics: DiagnosticsSnapshot,
        repositories: [RepositorySnapshot]
    ) -> Bool {
        diagnostics.appGroupAvailable
            && !diagnostics.snapshotExists
            && repositories.isEmpty
            && diagnostics.sharedDataReadError == nil
            && diagnostics.sharedDataWriteError == nil
            && diagnostics.lastSharedWriteAt == nil
            && diagnostics.sharedDataSnapshot == nil
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Shared store errors

enum AppGroupStoreError: LocalizedError, Equatable {
    case appGroupUnavailable
    case snapshotMissing
    case schemaVersionMismatch(expected: Int, actual: Int)
    case readFailed(String)
    case decodeFailed(String)
    case writeFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group container is unavailable."
        case .snapshotMissing:
            return "Shared snapshot file is missing."
        case .schemaVersionMismatch(let expected, let actual):
            return "Shared snapshot schema mismatch. Expected v\(expected), found v\(actual)."
        case .readFailed(let reason):
            return "Failed to read shared snapshot: \(reason)"
        case .decodeFailed(let reason):
            return "Failed to decode shared snapshot: \(reason)"
        case .writeFailed(let reason):
            return "Failed to write shared snapshot: \(reason)"
        case .verificationFailed(let reason):
            return "Shared snapshot verification failed: \(reason)"
        }
    }
}

// MARK: - Scan-location toggle

struct ScanLocationToggle: Identifiable, Codable {
    let id: String
    let path: String
    var isEnabled: Bool
    let isBuiltIn: Bool
}

// MARK: - Custom scan directory

struct CustomScanDirectory: Identifiable, Codable, Equatable {
    let id: String
    let path: String
    let bookmarkData: Data?

    init(id: String = UUID().uuidString, path: String, bookmarkData: Data? = nil) {
        self.id = id
        self.path = path
        self.bookmarkData = bookmarkData
    }
}

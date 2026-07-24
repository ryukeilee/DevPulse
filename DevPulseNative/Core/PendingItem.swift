import CryptoKit
import Foundation

// MARK: - Schema

enum PendingItemSchema {
    static let version = 1
    static let oldestMigratableVersion = 1
}

// MARK: - Severity

enum PendingItemSeverity: String, Codable, Comparable, Sendable {
    case tip
    case low
    case medium
    case high
    case critical

    static func < (lhs: PendingItemSeverity, rhs: PendingItemSeverity) -> Bool {
        let order: [PendingItemSeverity] = [.tip, .low, .medium, .high, .critical]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }

    var displayName: String {
        switch self {
        case .tip: return "提示"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .critical: return "严重"
        }
    }

    var systemImage: String {
        switch self {
        case .tip: return "info.circle"
        case .low: return "exclamationmark.circle"
        case .medium: return "exclamationmark.triangle"
        case .high: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}

// MARK: - Source category

enum PendingItemSource: String, Codable, Sendable {
    /// Repository-level
    case dirtyWorkspace
    case unpushedCommits
    case behindRemote
    case mergeConflict
    case upstreamMissing
    case unavailable
    case scanFailure
    case creepingChanges
    case staleActivity
    case healthTrend
    /// Repository has been unavailable beyond the retention window
    /// and needs explicit user cleanup action.
    case staleRepository

    /// Workspace-level
    case workspaceDegraded
    case workspaceConflicts
    case workspaceAggregation

    var displayName: String {
        switch self {
        case .dirtyWorkspace: return "脏工作区"
        case .unpushedCommits: return "未推送提交"
        case .behindRemote: return "落后远端"
        case .mergeConflict: return "合并冲突"
        case .upstreamMissing: return "上游丢失"
        case .unavailable: return "仓库不可用"
        case .scanFailure: return "扫描失败"
        case .creepingChanges: return "改动持续堆积"
        case .staleActivity: return "长期无活动"
        case .healthTrend: return "健康趋势"
        case .staleRepository: return "陈旧仓库"
        case .workspaceDegraded: return "工作空间降级"
        case .workspaceConflicts: return "工作空间冲突"
        case .workspaceAggregation: return "工作空间综合"
        }
    }

    var systemImage: String {
        switch self {
        case .dirtyWorkspace: return "pencil.and.outline"
        case .unpushedCommits: return "arrow.up.circle"
        case .behindRemote: return "arrow.down.circle"
        case .mergeConflict: return "exclamationmark.triangle"
        case .upstreamMissing: return "link.slash"
        case .unavailable: return "folder.slash"
        case .scanFailure: return "xmark.octagon"
        case .creepingChanges: return "doc.text.magnifyingglass"
        case .staleActivity: return "clock"
        case .healthTrend: return "heart.text.clipboard"
        case .staleRepository: return "trash.slash"
        case .workspaceDegraded: return "rectangle.3.group.slash"
        case .workspaceConflicts: return "rectangle.3.group.fill"
        case .workspaceAggregation: return "rectangle.3.group"
        }
    }
}

// MARK: - Lifecycle status

enum PendingItemStatus: String, Codable, Sendable {
    case active
    case acknowledged
    case snoozed
    case muted
    case restored
    case resolved
    case permanentlyIgnored

    var displayName: String {
        switch self {
        case .active: return "待处理"
        case .acknowledged: return "已确认"
        case .snoozed: return "稍后提醒"
        case .muted: return "已静默"
        case .restored: return "恢复提醒"
        case .resolved: return "已自动恢复"
        case .permanentlyIgnored: return "永久忽略"
        }
    }

    var isUserAction: Bool {
        switch self {
        case .active, .resolved: return false
        case .acknowledged, .snoozed, .muted, .restored, .permanentlyIgnored: return true
        }
    }

    var isSuppressed: Bool {
        switch self {
        case .muted, .permanentlyIgnored: return true
        case .snoozed: return true
        case .active, .acknowledged, .restored, .resolved: return false
        }
    }

    var allowsNotification: Bool {
        switch self {
        case .active, .restored: return true
        case .acknowledged, .snoozed, .muted, .permanentlyIgnored, .resolved: return false
        }
    }
}

// MARK: - User action type

enum PendingItemUserAction: String, Codable, Sendable {
    case acknowledge
    case snooze
    case unmute
    case restoreReminder
    case permanentlyIgnore
    /// Remove a stale repository from tracking entirely — adds its path
    /// to the scan-ignore list and marks the pending item as resolved.
    case cleanupStaleRepository

    var displayName: String {
        switch self {
        case .acknowledge: return "确认"
        case .snooze: return "稍后处理"
        case .unmute: return "恢复提醒"
        case .restoreReminder: return "恢复提醒"
        case .permanentlyIgnore: return "永久忽略"
        case .cleanupStaleRepository: return "清理并移除跟踪"
        }
    }
}

// MARK: - Status transition

struct PendingItemTransition: Codable, Equatable, Sendable {
    let from: PendingItemStatus
    let to: PendingItemStatus
    let severityChanged: Bool
    let previousSeverity: PendingItemSeverity?
    let newSeverity: PendingItemSeverity?
    let reason: String
}

// MARK: - Core pending item

struct PendingItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let source: PendingItemSource
    var severity: PendingItemSeverity
    let repositoryID: String?
    let repositoryName: String?
    let workspaceID: String?
    let workspaceName: String?
    let title: String
    var explanation: String
    var evidence: [String]
    let firstDetectedAt: String
    var lastConfirmedAt: String
    var status: PendingItemStatus
    var snoozedUntil: String?
    var duration: TimeInterval
    var lastTransition: PendingItemTransition?

    init(
        id: String? = nil,
        source: PendingItemSource,
        severity: PendingItemSeverity,
        repositoryID: String? = nil,
        repositoryName: String? = nil,
        workspaceID: String? = nil,
        workspaceName: String? = nil,
        title: String,
        explanation: String = "",
        evidence: [String] = [],
        firstDetectedAt: String? = nil,
        lastConfirmedAt: String? = nil,
        status: PendingItemStatus = .active,
        snoozedUntil: String? = nil,
        duration: TimeInterval = 0,
        lastTransition: PendingItemTransition? = nil
    ) {
        let now = DateFormatting.nowISO()
        let identity = [
            source.rawValue,
            repositoryID ?? "",
            workspaceID ?? "",
            title
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.id = id ?? "pi-v1-\(digest)"
        self.source = source
        self.severity = severity
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.title = title
        self.explanation = explanation
        self.evidence = evidence
        self.firstDetectedAt = firstDetectedAt ?? now
        self.lastConfirmedAt = lastConfirmedAt ?? now
        self.status = status
        self.snoozedUntil = snoozedUntil
        self.duration = duration
        self.lastTransition = lastTransition
    }

    static func == (lhs: PendingItem, rhs: PendingItem) -> Bool {
        lhs.id == rhs.id
            && lhs.severity == rhs.severity
            && lhs.title == rhs.title
            && lhs.explanation == rhs.explanation
            && lhs.evidence == rhs.evidence
            && lhs.lastConfirmedAt == rhs.lastConfirmedAt
            && lhs.status == rhs.status
            && lhs.snoozedUntil == rhs.snoozedUntil
            && lhs.duration == rhs.duration
            && lhs.lastTransition == rhs.lastTransition
    }
}

// MARK: - Item archive

struct PendingItemArchive: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var items: [PendingItem]
    var dismissedItemIDs: Set<String>
    var migrationLog: [PendingItemMigrationRecord]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        items: [PendingItem] = [],
        dismissedItemIDs: Set<String> = [],
        migrationLog: [PendingItemMigrationRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.items = items
        self.dismissedItemIDs = dismissedItemIDs
        self.migrationLog = migrationLog
    }
}

// MARK: - Migration record

struct PendingItemMigrationRecord: Codable, Equatable, Sendable {
    let fromVersion: Int
    let toVersion: Int
    let migratedAt: String
    let success: Bool
    let detail: String
}

// MARK: - Widget summary (lightweight, embedded in shared snapshot)

struct PendingItemWidgetSummary: Codable, Equatable, Sendable {
    let totalCount: Int
    let criticalCount: Int
    let highCount: Int
    let mediumCount: Int
    let topItemTitle: String?
    let topItemSeverity: PendingItemSeverity?

    static func empty() -> PendingItemWidgetSummary {
        PendingItemWidgetSummary(
            totalCount: 0,
            criticalCount: 0,
            highCount: 0,
            mediumCount: 0,
            topItemTitle: nil,
            topItemSeverity: nil
        )
    }

    static func build(from items: [PendingItem]) -> PendingItemWidgetSummary {
        let activeItems = items.filter { $0.status == .active || $0.status == .restored }
        guard !activeItems.isEmpty else { return .empty() }

        let sorted = activeItems.sorted { $0.severity > $1.severity || ($0.severity == $1.severity && $0.lastConfirmedAt > $1.lastConfirmedAt) }
        let top = sorted.first

        return PendingItemWidgetSummary(
            totalCount: activeItems.count,
            criticalCount: activeItems.filter { $0.severity == .critical }.count,
            highCount: activeItems.filter { $0.severity == .high }.count,
            mediumCount: activeItems.filter { $0.severity == .medium }.count,
            topItemTitle: top?.title,
            topItemSeverity: top?.severity
        )
    }
}

// MARK: - Status transition decision

enum PendingItemStatusTransition {
    /// Determine the next status based on the current state and whether the
    /// underlying condition is still active.
    static func evaluate(
        current: PendingItem,
        conditionStillActive: Bool,
        conditionChanged: Bool,
        newSeverity: PendingItemSeverity?,
        now: Date = Date()
    ) -> PendingItemTransition {
        // Condition no longer present → auto-resolve if not user-suppressed
        if !conditionStillActive {
            guard current.status != .permanentlyIgnored else {
                return PendingItemTransition(
                    from: current.status, to: .permanentlyIgnored,
                    severityChanged: false, previousSeverity: current.severity,
                    newSeverity: nil,
                    reason: "条件已消失，但用户已永久忽略"
                )
            }

            let isAlreadyResolved = current.status == .resolved
            if !isAlreadyResolved {
                return PendingItemTransition(
                    from: current.status, to: .resolved,
                    severityChanged: false, previousSeverity: current.severity,
                    newSeverity: nil,
                    reason: "条件已消失，标记为自动恢复"
                )
            }
            return PendingItemTransition(
                from: current.status, to: current.status,
                severityChanged: false, previousSeverity: current.severity,
                newSeverity: nil, reason: "已恢复，状态不变"
            )
        }

        // Condition still active — determine new status
        let severityChanged = newSeverity.map { $0 != current.severity } ?? false
        let effectiveSeverity = newSeverity ?? current.severity

        switch current.status {
        case .active:
            if severityChanged && effectiveSeverity > current.severity {
                return PendingItemTransition(
                    from: .active, to: .active,
                    severityChanged: true,
                    previousSeverity: current.severity,
                    newSeverity: effectiveSeverity,
                    reason: "严重程度升级：\(current.severity.displayName) → \(effectiveSeverity.displayName)"
                )
            }
            if severityChanged && effectiveSeverity < current.severity {
                return PendingItemTransition(
                    from: .active, to: .active,
                    severityChanged: true,
                    previousSeverity: current.severity,
                    newSeverity: effectiveSeverity,
                    reason: "严重程度降级：\(current.severity.displayName) → \(effectiveSeverity.displayName)"
                )
            }
            return PendingItemTransition(
                from: .active, to: .active,
                severityChanged: false,
                previousSeverity: current.severity,
                newSeverity: nil,
                reason: "持续中"
            )

        case .acknowledged, .muted, .permanentlyIgnored:
            // User-set status stays until explicitly changed
            if severityChanged {
                return PendingItemTransition(
                    from: current.status, to: current.status,
                    severityChanged: true,
                    previousSeverity: current.severity,
                    newSeverity: effectiveSeverity,
                    reason: "严重程度变化（状态保持）"
                )
            }
            return PendingItemTransition(
                from: current.status, to: current.status,
                severityChanged: false,
                previousSeverity: current.severity,
                newSeverity: nil,
                reason: "状态保持（用户设置）"
            )

        case .snoozed:
            guard let snoozedUntil = current.snoozedUntil.flatMap(DateFormatting.date(from:)),
                  now >= snoozedUntil else {
                // Still snoozing
                if severityChanged {
                    return PendingItemTransition(
                        from: .snoozed, to: .snoozed,
                        severityChanged: true,
                        previousSeverity: current.severity,
                        newSeverity: effectiveSeverity,
                        reason: "严重程度变化（仍处于稍后处理状态）"
                    )
                }
                return PendingItemTransition(
                    from: .snoozed, to: .snoozed,
                    severityChanged: false,
                    previousSeverity: current.severity,
                    newSeverity: nil,
                    reason: "仍处于稍后处理状态"
                )
            }
            // Snooze period expired → restore
            return PendingItemTransition(
                from: .snoozed, to: .restored,
                severityChanged: false,
                previousSeverity: current.severity,
                newSeverity: nil,
                reason: "稍后处理期限已到，恢复提醒"
            )

        case .restored:
            return PendingItemTransition(
                from: .restored, to: .active,
                severityChanged: false,
                previousSeverity: current.severity,
                newSeverity: nil,
                reason: "恢复提醒后重新激活"
            )

        case .resolved:
            // Reappearance
            return PendingItemTransition(
                from: .resolved, to: .active,
                severityChanged: false,
                previousSeverity: current.severity,
                newSeverity: effectiveSeverity,
                reason: "条件重新出现"
            )
        }
    }
}

// MARK: - Item filtering for UI

struct PendingItemFilter: Equatable {
    var severities: Set<PendingItemSeverity> = []
    var sources: Set<PendingItemSource> = []
    var statuses: Set<PendingItemStatus> = []
    var repositoryID: String? = nil
    var workspaceID: String? = nil
    var searchText: String = ""

    static let `default` = PendingItemFilter()

    func apply(to items: [PendingItem]) -> [PendingItem] {
        var result = items

        if !severities.isEmpty {
            result = result.filter { severities.contains($0.severity) }
        }
        if !sources.isEmpty {
            result = result.filter { sources.contains($0.source) }
        }
        if !statuses.isEmpty {
            result = result.filter { statuses.contains($0.status) }
        }
        if let repoID = repositoryID {
            result = result.filter { $0.repositoryID == repoID }
        }
        if let wsID = workspaceID {
            result = result.filter { $0.workspaceID == wsID }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(query)
                || $0.explanation.lowercased().contains(query)
                || ($0.repositoryName?.lowercased().contains(query) ?? false)
                || ($0.workspaceName?.lowercased().contains(query) ?? false)
            }
        }

        return result
    }
}

// MARK: - Sort modes

enum PendingItemSortOrder: String, CaseIterable, Sendable {
    case severity
    case duration
    case firstDetected
    case lastConfirmed

    var displayName: String {
        switch self {
        case .severity: return "严重程度"
        case .duration: return "持续时间"
        case .firstDetected: return "首次发现"
        case .lastConfirmed: return "最近确认"
        }
    }

    func sort(_ items: [PendingItem]) -> [PendingItem] {
        switch self {
        case .severity:
            return items.sorted { $0.severity > $1.severity || ($0.severity == $1.severity && $0.lastConfirmedAt > $1.lastConfirmedAt) }
        case .duration:
            return items.sorted { $0.duration > $1.duration }
        case .firstDetected:
            return items.sorted { $0.firstDetectedAt > $1.firstDetectedAt }
        case .lastConfirmed:
            return items.sorted { $0.lastConfirmedAt > $1.lastConfirmedAt }
        }
    }
}

// MARK: - Notification state

struct PendingItemNotificationState: Codable, Equatable, Sendable {
    var lastNotifiedAt: String?          // When we last notified for this item
    var notificationCount: Int           // How many times we've notified
    var lastSeverityNotified: PendingItemSeverity?  // Severity of last notification
    var coolDownUntil: String?           // Don't notify again before this

    static func initial() -> PendingItemNotificationState {
        PendingItemNotificationState(
            lastNotifiedAt: nil,
            notificationCount: 0,
            lastSeverityNotified: nil,
            coolDownUntil: nil
        )
    }
}

// MARK: - Notification archive

struct PendingItemNotificationArchive: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var notificationStates: [String: PendingItemNotificationState]
    var lastGlobalNotification: String?    // When we last showed any notification
    var suppressionUntil: String?          // Global quiet hours end
    var suppressionEnabled: Bool

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        notificationStates: [String: PendingItemNotificationState] = [:],
        lastGlobalNotification: String? = nil,
        suppressionUntil: String? = nil,
        suppressionEnabled: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.notificationStates = notificationStates
        self.lastGlobalNotification = lastGlobalNotification
        self.suppressionUntil = suppressionUntil
        self.suppressionEnabled = suppressionEnabled
    }
}

// MARK: - Notification decision

enum PendingItemNotificationDecision: Equatable {
    case shouldNotify(reason: String)
    case suppressed(reason: String)
    case cooldownActive(until: String)
    case alreadyNotifiedForSeverity
    case globalSuppression

    var isNotification: Bool {
        if case .shouldNotify = self { return true }
        return false
    }
}

// MARK: - Notification strategy

enum PendingItemNotificationStrategy {
    static let defaultCooldownMinutes: TimeInterval = 30 * 60
    static let escalationCooldownMinutes: TimeInterval = 15 * 60

    /// Decide whether to notify for a pending item change.
    static func shouldNotify(
        item: PendingItem,
        transition: PendingItemTransition,
        state: PendingItemNotificationState?,
        archive: PendingItemNotificationArchive,
        now: Date = Date(),
        quietHoursStart: Date? = nil,
        quietHoursEnd: Date? = nil
    ) -> PendingItemNotificationDecision {
        // Check global suppression
        if archive.suppressionEnabled {
            if let until = archive.suppressionUntil.flatMap(DateFormatting.date(from:)),
               now < until {
                return .globalSuppression
            }
        }

        // Check quiet hours
        if let start = quietHoursStart, let end = quietHoursEnd {
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: now)
            let minute = calendar.component(.minute, from: now)
            let nowMinutes = hour * 60 + minute
            let startMinutes = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
            let endMinutes = calendar.component(.hour, from: end) * 60 + calendar.component(.minute, from: end)

            if startMinutes <= endMinutes {
                if nowMinutes >= startMinutes && nowMinutes < endMinutes {
                    return .suppressed(reason: "静默时段内")
                }
            } else {
                if nowMinutes >= startMinutes || nowMinutes < endMinutes {
                    return .suppressed(reason: "静默时段内")
                }
            }
        }

        // Only notify for active or restored items
        guard item.status == .active || item.status == .restored else {
            return .suppressed(reason: "状态不触发通知")
        }

        let notifState = state ?? .initial()

        // Check cool-down
        if let coolDownUntil = notifState.coolDownUntil.flatMap(DateFormatting.date(from:)),
           now < coolDownUntil {
            let remaining = coolDownUntil.timeIntervalSince(now)
            return .cooldownActive(until: "剩余 \(Int(remaining / 60)) 分钟")
        }

        // Check if this is a new item
        if notifState.lastNotifiedAt == nil {
            return .shouldNotify(reason: "新事项")
        }

        // Only notify for status transitions that change visibility
        switch (transition.from, transition.to) {
        case (.snoozed, .restored):
            return .shouldNotify(reason: "稍后处理到期")
        case (.snoozed, .active):
            return .shouldNotify(reason: "稍后处理到期，条件仍存在")
        case (.resolved, .active):
            return .shouldNotify(reason: "事项重新出现")
        case (.restored, .active):
            return .shouldNotify(reason: "恢复提醒后重新激活")
        default:
            break
        }

        // Check severity escalation
        if transition.severityChanged,
           let previous = transition.previousSeverity,
           let newSeverity = transition.newSeverity,
           newSeverity > previous {
            // Don't re-notify for the same severity level
            if notifState.lastSeverityNotified != newSeverity {
                return .shouldNotify(reason: "严重程度升级：\(previous.displayName) → \(newSeverity.displayName)")
            }
            return .alreadyNotifiedForSeverity
        }

        // Sustained with no change — no notification
        return .suppressed(reason: "无显著变化，无需通知")
    }

    /// Compute the cool-down period after a notification.
    static func cooldownPeriod(after transition: PendingItemTransition) -> TimeInterval {
        if transition.severityChanged,
           let newSeverity = transition.newSeverity,
           newSeverity >= .high {
            return escalationCooldownMinutes
        }
        return defaultCooldownMinutes
    }
}

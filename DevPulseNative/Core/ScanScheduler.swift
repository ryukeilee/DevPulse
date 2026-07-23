import AppKit
import Foundation
import SwiftUI
import IOKit.ps

#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Power state

private enum PowerState {
    case normal
    case lowPower
    case onBattery
}

enum ScanRefreshSource: Int, Sendable {
    case timer
    case startup
    case windowReopen
    case foreground
    case wake
    case lifecycleRecovery
    case pathRecovery
    case configuration
    case manual

    var taskPriority: TaskPriority {
        switch self {
        case .manual, .configuration:
            return .userInitiated
        case .pathRecovery, .lifecycleRecovery, .wake, .foreground, .windowReopen, .startup:
            return .utility
        case .timer:
            return .background
        }
    }

    var isAutomatic: Bool {
        switch self {
        case .startup, .timer, .windowReopen, .foreground, .wake, .lifecycleRecovery, .pathRecovery:
            return true
        case .manual, .configuration:
            return false
        }
    }

    fileprivate var preservesSuccessorForMatchingRun: Bool {
        self == .lifecycleRecovery
    }
}

enum ScanLifecycleRefreshEvent: Equatable, Sendable {
    case startup
    case windowReopened
    case applicationBecameActive
    case wake
    case systemTimeChanged
    case pathAvailabilityChanged(rootPath: String?, isAvailable: Bool)
}

struct ScanExecutionRequest: Sendable {
    let config: ScanConfig
    let roots: [String]
    let rootsSignature: String
    let knownRepositoryPaths: [String]
    let ignoredRepositoryPaths: Set<String>
    let forceRepositoryDiscovery: Bool
    let previousSnapshot: AppGroupData?
    let source: ScanRefreshSource
    let metrics: ScanMetricsCollector
    let progressHandler: (@Sendable (RefreshProgress) -> Void)?

    init(config: ScanConfig,
         roots: [String],
         rootsSignature: String,
         knownRepositoryPaths: [String],
         ignoredRepositoryPaths: Set<String> = [],
         forceRepositoryDiscovery: Bool,
         previousSnapshot: AppGroupData? = nil,
         source: ScanRefreshSource = .manual,
         metrics: ScanMetricsCollector = ScanMetricsCollector(),
         progressHandler: (@Sendable (RefreshProgress) -> Void)? = nil) {
        self.config = config
        self.roots = roots
        self.rootsSignature = rootsSignature
        self.knownRepositoryPaths = knownRepositoryPaths
        self.ignoredRepositoryPaths = ignoredRepositoryPaths
        self.forceRepositoryDiscovery = forceRepositoryDiscovery
        self.previousSnapshot = previousSnapshot
        self.source = source
        self.metrics = metrics
        self.progressHandler = progressHandler
    }
}
typealias ScanExecution = @Sendable (ScanExecutionRequest) async -> (data: AppGroupData, warnings: [String], discoveredRepositoryPaths: [String])
typealias RepositoryRetryExecution = @Sendable (
    _ config: ScanConfig,
    _ previousSnapshot: RepositorySnapshot
) async -> RepositorySnapshot?

private struct DeferredScanRefresh {
    let forceRepositoryDiscovery: Bool
    let source: ScanRefreshSource

    func merging(forceRepositoryDiscovery: Bool,
                 source: ScanRefreshSource) -> DeferredScanRefresh {
        DeferredScanRefresh(
            forceRepositoryDiscovery: self.forceRepositoryDiscovery || forceRepositoryDiscovery,
            source: self.source.rawValue >= source.rawValue ? self.source : source
        )
    }
}


/// Coalesces scan refresh requests without retaining UI or scanner state.
struct ScanRefreshCoordinator {
    struct Request: Equatable {
        let signature: String
        let forceRepositoryDiscovery: Bool
        let source: ScanRefreshSource

        init(signature: String,
             forceRepositoryDiscovery: Bool,
             source: ScanRefreshSource = .manual) {
            self.signature = signature
            self.forceRepositoryDiscovery = forceRepositoryDiscovery
            self.source = source
        }

        var taskPriority: TaskPriority { source.taskPriority }
        var isAutomatic: Bool { source.isAutomatic }

        fileprivate var preservesSuccessorForMatchingRun: Bool {
            forceRepositoryDiscovery || source.preservesSuccessorForMatchingRun
        }
    }

    private var scheduled: Request?
    private var running: Request?
    private var runningWasCancelled = false

    var nextRequest: Request? { scheduled }
    var runningRequest: Request? { running }
    var hasWork: Bool { scheduled != nil || running != nil }
    var isRunningCancelled: Bool { running != nil && runningWasCancelled }

    @discardableResult
    mutating func request(signature: String,
                          forceRepositoryDiscovery: Bool,
                          source: ScanRefreshSource = .manual) -> Bool {
        let incoming = Request(
            signature: signature,
            forceRepositoryDiscovery: forceRepositoryDiscovery,
            source: source
        )

        if let running, signature == running.signature {
            if runningWasCancelled {
                return mergeScheduled(incoming)
            }

            if let scheduled {
                if scheduled.signature == signature,
                   scheduled.preservesSuccessorForMatchingRun {
                    // A normal duplicate must not erase a forced or lifecycle
                    // recovery successor that was already retained.
                    return false
                }

                // The active run is still valid and scope returned to it before
                // cancellation. Drop the now-obsolete different-scope successor.
                self.scheduled = nil
                return false
            }

            if incoming.preservesSuccessorForMatchingRun {
                return mergeScheduled(incoming)
            }

            // The active run is still valid, so an ordinary same-signature
            // duplicate is redundant.
            return false
        }

        if let scheduled {
            let replacement = Request(
                signature: signature,
                forceRepositoryDiscovery: scheduled.forceRepositoryDiscovery || forceRepositoryDiscovery,
                source: dominantSource(scheduled.source, incoming.source)
            )
            guard replacement != scheduled else { return false }
            self.scheduled = replacement
            return true
        }

        guard let running else {
            scheduled = incoming
            return true
        }

        guard signature != running.signature || runningWasCancelled else { return false }
        scheduled = incoming
        return true
    }

    @discardableResult
    mutating func requestForced(signature: String,
                                source: ScanRefreshSource = .manual) -> Bool {
        request(
            signature: signature,
            forceRepositoryDiscovery: true,
            source: source
        )
    }

    mutating func markRunningCancelled() {
        guard running != nil else { return }
        runningWasCancelled = true
    }

    mutating func retainOnlyRecovery(signature: String,
                                     forceRepositoryDiscovery: Bool = false) {
        scheduled = Request(
            signature: signature,
            forceRepositoryDiscovery: forceRepositoryDiscovery,
            source: .lifecycleRecovery
        )
        markRunningCancelled()
    }

    mutating func discardScheduledAutomaticRequests() {
        if scheduled?.isAutomatic == true {
            scheduled = nil
        }
    }

    mutating func cancelAll() {
        scheduled = nil
        running = nil
        runningWasCancelled = false
    }

    mutating func beginNext() -> Request? {
        guard running == nil, let scheduled else { return nil }
        self.scheduled = nil
        running = scheduled
        runningWasCancelled = false
        return scheduled
    }

    mutating func completeCurrent() -> Request? {
        running = nil
        runningWasCancelled = false
        return scheduled
    }

    private mutating func mergeScheduled(_ incoming: Request) -> Bool {
        guard let scheduled else {
            self.scheduled = incoming
            return true
        }

        let replacement: Request
        if scheduled.signature == incoming.signature {
            replacement = Request(
                signature: incoming.signature,
                forceRepositoryDiscovery: scheduled.forceRepositoryDiscovery
                    || incoming.forceRepositoryDiscovery,
                source: dominantSource(scheduled.source, incoming.source)
            )
        } else {
            replacement = incoming
        }
        guard replacement != scheduled else { return false }
        self.scheduled = replacement
        return true
    }

    private func dominantSource(_ lhs: ScanRefreshSource,
                                _ rhs: ScanRefreshSource) -> ScanRefreshSource {
        lhs.rawValue >= rhs.rawValue ? lhs : rhs
    }
}

enum ScanSchedulerPolicy {
    static func migratedBuiltInPaths(configWasLoaded: Bool,
                                     configuredBuiltIns: Set<String>,
                                     directoryBuiltIns: Set<String>,
                                     defaultBuiltIns: Set<String>) -> Set<String> {
        if configWasLoaded { return configuredBuiltIns }
        return directoryBuiltIns.isEmpty ? defaultBuiltIns : directoryBuiltIns
    }
    struct StartupRefreshDecision: Equatable {
        let shouldRefreshImmediately: Bool
        let forceRepositoryDiscovery: Bool
    }

    static func startupRefreshDecision(snapshotIsFresh: Bool,
                                       currentRootsSignature: String,
                                       lastDiscoveryRootsSignature: String?) -> StartupRefreshDecision {
        let rootsChanged = currentRootsSignature != (lastDiscoveryRootsSignature ?? "")
        return StartupRefreshDecision(
            shouldRefreshImmediately: !snapshotIsFresh || rootsChanged,
            forceRepositoryDiscovery: rootsChanged
        )
    }

    static func shouldRefreshForLifecycle(lastSuccessfulRefreshAt: Date?,
                                          refreshPhase: RefreshPhase,
                                          now: Date = Date()) -> Bool {
        if refreshPhase == .failure || refreshPhase == .degraded {
            return true
        }

        return RefreshStatusFormatter.freshness(
            for: lastSuccessfulRefreshAt,
            now: now
        ) != .fresh
    }

    static func repositoriesNeedingPathRefresh(
        _ repositories: [RepositorySnapshot],
        under rootPath: String?,
        isAvailable: Bool,
        pathIsReachable: (String) -> Bool
    ) -> [RepositorySnapshot] {
        if !isAvailable, rootPath == nil {
            return []
        }
        let canonicalRoot = rootPath.map(RepositoryIdentity.canonicalPath)
        return repositories.filter { repository in
            if let canonicalRoot,
               !RepositoryIdentity.isSameOrDescendantPath(
                   repository.path,
                   of: canonicalRoot
               ) {
                return false
            }

            if isAvailable {
                return repository.needsReadRetry && pathIsReachable(repository.path)
            }
            return true
        }
    }

    static let repositoryRediscoveryInterval: TimeInterval = 60 * 60
    static let widgetReloadThrottleInterval: TimeInterval = 15 * 60

    static func allRepositoryDataUnavailable(_ repositories: [RepositorySnapshot]) -> Bool {
        RepositoryDataAvailability.allUnavailable(repositories)
    }

    struct WidgetReloadDecision: Equatable {
        let shouldRequest: Bool
        let detail: String
    }

    struct WakeRefreshDecision: Equatable {
        let shouldRefreshImmediately: Bool
        let forceRepositoryDiscovery: Bool
        let detail: String
    }

    static func shouldRediscoverRepositories(
        forceRepositoryDiscovery: Bool,
        knownRepositoryPaths: [String],
        lastRepositoryDiscoveryAt: Date?,
        currentScanRootsSignature: String = "",
        lastScanRootsSignature: String? = "",
        now: Date = Date()
    ) -> Bool {
        if forceRepositoryDiscovery || knownRepositoryPaths.isEmpty {
            return true
        }

        guard lastScanRootsSignature == currentScanRootsSignature else {
            return true
        }

        guard let lastRepositoryDiscoveryAt else {
            return true
        }

        return now.timeIntervalSince(lastRepositoryDiscoveryAt) >= repositoryRediscoveryInterval
    }

    static func shouldPreserveDiscoveryScopeAfterIncompleteRefresh(
        knownRepositoryPaths: [String],
        currentScanRootsSignature: String,
        lastScanRootsSignature: String?
    ) -> Bool {
        !knownRepositoryPaths.isEmpty
            && lastScanRootsSignature == currentScanRootsSignature
    }

    static func scanRootsSignature(_ scanRoots: [String]) -> String {
        scanRoots
            .map {
                ScanLocationProvider.canonicalExistingFilePath($0, resolveBuiltIn: true)
            }
            .sorted()
            .joined(separator: "\n")
    }

    static func shouldRequestWidgetReload(
        previousSnapshot: AppGroupData,
        nextSnapshot: AppGroupData,
        lastReloadRequestedAt: Date?,
        reason: String,
        now: Date = Date()
    ) -> Bool {
        widgetReloadDecision(
            previousSnapshot: previousSnapshot,
            nextSnapshot: nextSnapshot,
            lastReloadRequestedAt: lastReloadRequestedAt,
            reason: reason,
            now: now
        ).shouldRequest
    }

    static func widgetReloadDecision(
        previousSnapshot: AppGroupData,
        nextSnapshot: AppGroupData,
        lastReloadRequestedAt: Date?,
        reason: String,
        now: Date = Date()
    ) -> WidgetReloadDecision {
        guard reason == "scan" else {
            return WidgetReloadDecision(
                shouldRequest: true,
                detail: "此次同步由 \(reason) 触发，不走扫描节流，已直接请求 Widget reload。"
            )
        }

        if hasMeaningfulSnapshotChanges(previousSnapshot: previousSnapshot, nextSnapshot: nextSnapshot) {
            return WidgetReloadDecision(
                shouldRequest: true,
                detail: "共享快照内容发生变化，已请求 Widget reload。"
            )
        }

        return WidgetReloadDecision(
            shouldRequest: false,
            detail: "共享快照无实质变化，本次跳过 Widget reload。"
        )
    }

    static func wakeRefreshDecision(
        lastScanAt: Date?,
        refreshPhase: RefreshPhase,
        sleepBeganAt: Date?,
        refreshStartedAt: Date?,
        refreshCompletedAt: Date?,
        now: Date = Date()
    ) -> WakeRefreshDecision {
        if refreshPhase == .refreshing,
           let sleepBeganAt,
           let refreshStartedAt,
           refreshStartedAt <= sleepBeganAt,
           refreshCompletedAt == nil || refreshCompletedAt.map({ $0 < sleepBeganAt }) == true {
            return WakeRefreshDecision(
                shouldRefreshImmediately: true,
                forceRepositoryDiscovery: false,
                detail: "系统休眠前刷新尚未完成，唤醒后立即补一次刷新恢复状态。"
            )
        }

        if refreshPhase == .failure {
            return WakeRefreshDecision(
                shouldRefreshImmediately: true,
                forceRepositoryDiscovery: false,
                detail: "上次刷新处于失败状态，唤醒后立即重试恢复。"
            )
        }

        if refreshPhase == .degraded {
            return WakeRefreshDecision(
                shouldRefreshImmediately: true,
                forceRepositoryDiscovery: false,
                detail: "上次只有部分仓库刷新成功，唤醒后立即重试未确认项目。"
            )
        }

        switch RefreshStatusFormatter.freshness(for: lastScanAt, now: now) {
        case .fresh:
            return WakeRefreshDecision(
                shouldRefreshImmediately: false,
                forceRepositoryDiscovery: false,
                detail: "当前共享快照仍然新鲜，唤醒后仅恢复后台定时器。"
            )
        case .stale:
            return WakeRefreshDecision(
                shouldRefreshImmediately: true,
                forceRepositoryDiscovery: false,
                detail: "共享快照已超过 10 分钟未刷新，唤醒后立即补一次刷新。"
            )
        case .expired:
            return WakeRefreshDecision(
                shouldRefreshImmediately: true,
                forceRepositoryDiscovery: false,
                detail: "共享快照已超过 30 分钟未刷新，唤醒后立即补一次刷新。"
            )
        case .unknown:
            return WakeRefreshDecision(
                shouldRefreshImmediately: true,
                forceRepositoryDiscovery: false,
                detail: "还没有可用的刷新记录，唤醒后立即执行首次恢复刷新。"
            )
        }
    }

    static func hasMeaningfulSnapshotChanges(
        previousSnapshot: AppGroupData,
        nextSnapshot: AppGroupData
    ) -> Bool {
        guard previousSnapshot.scanSummary == nextSnapshot.scanSummary,
              previousSnapshot.repositories.count == nextSnapshot.repositories.count else {
            return true
        }

        return zip(previousSnapshot.repositories, nextSnapshot.repositories)
            .contains { !isMeaningfullySameRepository(previous: $0, next: $1) }
    }

    private static func isMeaningfullySameRepository(
        previous: RepositorySnapshot,
        next: RepositorySnapshot
    ) -> Bool {
        previous.id == next.id
            && previous.name == next.name
            && previous.path == next.path
            && previous.branch == next.branch
            && previous.status == next.status
            && previous.modifiedFileCount == next.modifiedFileCount
            && previous.addedFileCount == next.addedFileCount
            && previous.deletedFileCount == next.deletedFileCount
            && previous.untrackedFileCount == next.untrackedFileCount
            && previous.stagedFileCount == next.stagedFileCount
            && previous.unstagedFileCount == next.unstagedFileCount
            && previous.conflictedFileCount == next.conflictedFileCount
            && previous.aheadCount == next.aheadCount
            && previous.behindCount == next.behindCount
            && previous.hasUpstream == next.hasUpstream
            && previous.changedFileCount == next.changedFileCount
            && previous.changedFilesPreview == next.changedFilesPreview
            && previous.risk == next.risk
            && previous.resolvedDataSource == next.resolvedDataSource
            && (
                previous.resolvedDataSource == .current
                    || previous.resolvedLastSuccessfulScanAt == next.resolvedLastSuccessfulScanAt
            )
            && previous.lastChangedAt == next.lastChangedAt
            && previous.lastCommitID == next.lastCommitID
            && previous.lastCommitSummary == next.lastCommitSummary
            && previous.lastCommitMetadataAvailable == next.lastCommitMetadataAvailable
            && previous.lastActivityAt == next.lastActivityAt
            && previous.unavailableSince == next.unavailableSince
            && previous.errorMessage == next.errorMessage
            && previous.isPinned == next.isPinned
    }
}

struct ScanSelfCheckReport {
    let success: Bool
    let refreshPhase: RefreshPhase
    let snapshotStoreState: SnapshotStoreState
    let widgetReloadState: WidgetReloadState
    let generatedAt: String?
    let writtenAt: String?
    let reloadRequestedAt: Date?
    let sharedReadError: String?
    let sharedWriteError: String?
    let widgetSnapshotReadError: String?
    let validationIssues: [String]
    let repositoryCount: Int
    let scanMetrics: ScanMetrics?

    var renderedOutput: String {
        var lines = [
            "self_check.result=\(success ? "pass" : "fail")",
            "self_check.refresh_phase=\(label(for: refreshPhase))",
            "self_check.snapshot_store=\(label(for: snapshotStoreState))",
            "self_check.widget_reload=\(label(for: widgetReloadState))",
            "self_check.repository_count=\(repositoryCount)",
            "self_check.validation=\(validationIssues.isEmpty ? "pass" : "mismatch")"
        ]

        if let generatedAt {
            lines.append("self_check.generated_at=\(generatedAt)")
        }
        if let writtenAt {
            lines.append("self_check.written_at=\(writtenAt)")
        }
        if let reloadRequestedAt {
            lines.append("self_check.reload_requested_at=\(DateFormatting.displayString(from: reloadRequestedAt))")
        }
        if let sharedReadError, !sharedReadError.isEmpty {
            lines.append("self_check.shared_read_error=\(sharedReadError)")
        }
        if let sharedWriteError, !sharedWriteError.isEmpty {
            lines.append("self_check.shared_write_error=\(sharedWriteError)")
        }
        if let widgetSnapshotReadError, !widgetSnapshotReadError.isEmpty {
            lines.append("self_check.widget_snapshot_error=\(widgetSnapshotReadError)")
        }
        if !validationIssues.isEmpty {
            lines.append("self_check.validation_issues=\(validationIssues.joined(separator: " | "))")
        }
        if let scanMetrics {
            lines.append("self_check.scan_elapsed_ms=\(Int((scanMetrics.elapsed * 1_000).rounded()))")
            lines.append("self_check.scan_discovery=\(label(for: scanMetrics.discoveryMode))")
            lines.append("self_check.scan_discovery_ms=\(Int((scanMetrics.discoveryElapsed * 1_000).rounded()))")
            lines.append("self_check.scan_repository_count=\(scanMetrics.discoveredRepositoryCount)")
            lines.append("self_check.scan_repository_reads=\(scanMetrics.repositoryReadCount)")
            lines.append("self_check.scan_reused_snapshots=\(scanMetrics.reusedRepositorySnapshotCount)")
            lines.append("self_check.scan_git_calls=\(scanMetrics.gitCommandCount)")
            lines.append("self_check.scan_git_status_calls=\(scanMetrics.gitStatusCommandCount)")
            lines.append("self_check.scan_git_log_calls=\(scanMetrics.gitLogCommandCount)")
            lines.append("self_check.scan_git_timeouts=\(scanMetrics.gitTimeoutCount)")
            lines.append("self_check.scan_git_cancellations=\(scanMetrics.gitCancellationCount)")
            lines.append("self_check.scan_git_failures=\(scanMetrics.gitFailureCount)")
            lines.append("self_check.scan_peak_git_concurrency=\(scanMetrics.peakConcurrentGitCommandCount)")
            lines.append("self_check.scan_peak_full_concurrency=\(scanMetrics.peakConcurrentFullScanCount)")
        }

        return lines.joined(separator: "\n")
    }

    private func label(for refreshPhase: RefreshPhase) -> String {
        switch refreshPhase {
        case .idle:
            return "idle"
        case .refreshing:
            return "refreshing"
        case .success:
            return "success"
        case .degraded:
            return "degraded"
        case .failure:
            return "failure"
        }
    }

    private func label(for snapshotStoreState: SnapshotStoreState) -> String {
        switch snapshotStoreState {
        case .idle:
            return "idle"
        case .restored:
            return "restored"
        case .verified:
            return "verified"
        case .failed:
            return "failed"
        }
    }

    private func label(for widgetReloadState: WidgetReloadState) -> String {
        switch widgetReloadState {
        case .idle:
            return "idle"
        case .requested:
            return "requested"
        case .skipped:
            return "skipped"
        }
    }

    private func label(for discoveryMode: RepositoryDiscoveryMode) -> String {
        switch discoveryMode {
        case .empty:
            return "empty"
        case .reusedKnown:
            return "reused_known"
        case .reusedCache:
            return "reused_cache"
        case .walked:
            return "walked"
        case .incomplete:
            return "incomplete"
        }
    }
}

/// Manages background scan scheduling with low-power safeguards.
///
/// Key behaviors:
/// - Scan interval starts at 5 min, extends to 10/20/30 min when N consecutive
///   scans show no change.
/// - On low-power mode or battery, interval floor raises to 15 min.
/// - Per-git-command timeout enforced at 5s; overall scan timeout at 60s.
/// - Widget Extension only reads JSON, never scans.
@MainActor
final class ScanScheduler: ObservableObject {
    @Published var lastResult: AppGroupData = .empty()
    @Published var isScanning = false
    @Published var lastScanAt: Date?
    @Published var refreshPhase: RefreshPhase = .idle
    @Published var refreshFailureMessage: String?
    @Published private(set) var sharedSnapshotSyncFailureMessage: String?
    @Published var gitAvailable: Bool = true
    @Published var appGroupAvailable: Bool = true
    @Published var warnings: [String] = []
    @Published var scanRootAccessWarning: String?
    @Published private(set) var scanLocationConfiguration = ScanLocationConfiguration(
        enabledBuiltInPaths: [],
        customDirectories: []
    )
    var scanDirectories: [CustomScanDirectory] { scanLocationConfiguration.customDirectories }
    @Published var diagnostics = DiagnosticsSnapshot()
    @Published var diagnosticEvents: [DiagnosticEvent] = []
    @Published private(set) var activityEvents: [ActivityEvent] = []
    @Published private(set) var ignoredRepositories: [IgnoredRepository] = []
    @Published private(set) var retryingRepositoryIDs: Set<String> = []
    @Published private(set) var lastScanMetrics: ScanMetrics?
    @Published private(set) var lastRefreshDiagnostics: RefreshDiagnostics?
    @Published var scanIntervalSeconds: TimeInterval = 300
    @Published var powerState: String = "normal"

    /// Helper to compute a health assessment from history store data.
    func healthAssessment(for repositoryID: String,
                          repositoryName: String) async -> RepositoryHealthAssessment? {
        guard let historyStore else { return nil }
        switch historyStore.load(for: repositoryID) {
        case .success(let entries):
            return RepositoryHealthEngine.assess(
                repositoryID: repositoryID,
                repositoryName: repositoryName,
                entries: entries
            )
        case .failure:
            return nil
        }
    }

    var historyDiagnostics: HistoryDiagnosticsSnapshot? {
        historyStore?.diagnosticsSnapshot()
    }
    @Published private(set) var currentProgress: RefreshProgress?
    @Published var workspaces: [Workspace] = []
    @Published var workspaceAggregations: [String: WorkspaceAggregation] = [:]
    @Published private(set) var workspaceSuggestionCandidates: [WorkspaceAutoSuggestCandidate] = []
    @Published var pendingItems: [PendingItem] = []
    @Published var pendingItemWidgetSummary: PendingItemWidgetSummary = .empty()
    @Published var pendingItemEvaluationDurationMs: Double = 0
    private let workspaceStore: WorkspaceStore
    private let workspaceAggregationCache: WorkspaceAggregationCache
    let pendingItemStore: PendingItemStore
    let pendingItemNotificationStore: PendingItemNotificationStore

    private var backgroundTimer: Timer?
    private var consecutiveNoChanges = 0
    private var backgroundScanningEnabled = false
    // Notification tokens are created, replaced, and normally removed on the
    // main actor. `deinit` is nonisolated in Swift 6, so these opaque,
    // non-Sendable handles need unsafe storage solely for final unregistering.
    nonisolated(unsafe) private var powerStateObserver: NSObjectProtocol?
    nonisolated(unsafe) private var workspaceSleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var workspaceWakeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var workspaceSessionInactiveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var workspaceSessionActiveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var workspaceVolumeMountedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var workspaceVolumeUnmountedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var applicationDidBecomeActiveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var applicationTerminateObserver: NSObjectProtocol?
    nonisolated(unsafe) private var systemClockDidChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var systemTimeZoneDidChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var calendarDayChangedObserver: NSObjectProtocol?
    private var lastSystemSleepAt: Date?
    private(set) var lastFreshnessRecalculationAt: Date?
    private var refreshCoordinator = ScanRefreshCoordinator()
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var selfCheckTask: Task<ScanSelfCheckReport, Never>?
    private var selfCheckGeneration = 0
    private var refreshDebounceTask: Task<Void, Never>?
    private var deferredScanRefresh: DeferredScanRefresh?
    private var workSuspended = false
    private var sessionInactive = false
    private var terminating = false
    private let scanExecution: ScanExecution
    private var repositoryRetryExecution: RepositoryRetryExecution
    private var repositoryRetryTasks: [String: Task<Void, Never>] = [:]
    private var pendingRepositoryRefreshRequirements: [String: Bool] = [:]
    private var repositoryRetryGeneration = 0
    private var repositoryRetryDrainTask: Task<Void, Never>?
    private var repositoryRetryDrainGeneration = 0
    private var repositoryRetryDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private let activityEventStore: ActivityEventStore?
    let historyStore: RepositoryHistoryStore?
    private var workspaceLoadingAttempted = false
    private var configLoadedFromPersistence = false
    private var activityRepositoryIDMigrations: [String: String] = [:]
    private var requiresStartupScopeRefresh = false

    // Config persistence
    private let configKey = "scan_config_json"
    private let scanDirectoriesKey = "scan_directories_json"
    private let scanLocationsKey = "scan_locations_v1_json"
    private let pinnedKey = "pinned_repo_ids"
    private let lastScanIntervalKey = "last_scan_interval"
    private let lastRepositoryDiscoveryAtKey = "last_repository_discovery_at"
    private let lastDiscoveredRepositoryPathsKey = "last_discovered_repository_paths"
    private let lastRepositoryDiscoveryScanRootsKey = "last_repository_discovery_scan_roots"
    private let ignoredRepositoriesKey = "ignored_repositories_v1_json"
    private let legacyIgnoredRepositoryPathsKey = "ignored_repository_paths"

    // MARK: - Workspace management

    func loadWorkspaces() {
        guard !workspaceLoadingAttempted else { return }
        workspaceLoadingAttempted = true
        switch workspaceStore.load() {
        case .success(let archive):
            self.workspaces = archive.workspaces
            // Run initial migration for pinned repos not yet in workspaces
            let result = WorkspaceMigrationEngine.migrateFromExistingData(
                pinnedRepositoryIDs: pinnedRepoIDs,
                allRepositories: lastResult.repositories,
                existingWorkspaces: archive.workspaces
            )
            if result.workspacesCreated > 0 {
                for ws in archive.workspaces {
                    _ = workspaceStore.upsertWorkspace(ws)
                }
                // Create new workspaces for pinned repos
                for i in 0..<result.workspacesCreated {
                    let pinnedRepoIDs = Array(pinnedRepoIDs).sorted()
                    if i < pinnedRepoIDs.count {
                        let repoID = pinnedRepoIDs[i]
                        if let repo = lastResult.repositories.first(where: { $0.id == repoID }) {
                            let ws = Workspace(
                                name: repo.name,
                                sortOrder: workspaces.count + i,
                                isPinned: true,
                                repositoryIDs: [repoID],
                                groupingBasis: .singleRepository,
                                autoSuggestConfirmed: true
                            )
                            _ = workspaceStore.upsertWorkspace(ws)
                        }
                    }
                }
                // Reload
                if case .success(let updated) = workspaceStore.load() {
                    self.workspaces = updated.workspaces
                }
            }
        case .failure:
            self.workspaces = []
        }
    }

    /// Recompute workspace aggregations after a scan completes.
    private func refreshWorkspaceAggregations() {
        let repos = lastResult.repositories
        let confirmedWorkspaces = workspaces.filter { $0.autoSuggestConfirmed }
        let unconfirmed = workspaces.filter { !$0.autoSuggestConfirmed }
        Task.detached(priority: .utility) { @Sendable in
            let aggregations = WorkspaceAggregationEngine.aggregateAll(
                workspaces: confirmedWorkspaces,
                allRepositories: repos
            )
            let unconfirmedAggregations = WorkspaceAggregationEngine.aggregateAll(
                workspaces: unconfirmed,
                allRepositories: repos
            )
            var all = aggregations
            for (key, value) in unconfirmedAggregations {
                all[key] = value
            }
            Task { @MainActor [weak self] in
                self?.workspaceAggregations = all
            }
        }
    }

    /// Load pending items from disk.
    func loadPendingItems() {
        switch pendingItemStore.load() {
        case .success(let archive):
            self.pendingItems = archive.items
            self.pendingItemWidgetSummary = PendingItemWidgetSummary.build(from: archive.items)
        case .failure:
            self.pendingItems = []
            self.pendingItemWidgetSummary = .empty()
        }
    }

    /// Refresh pending items after a scan completes, in background.
    func refreshPendingItems(skipHealthAssessments: Bool = false) {
        let repos = lastResult.repositories
        let confirmWorkspaces = workspaces.filter { $0.autoSuggestConfirmed }
        let workspaceAggs = workspaceAggregations
        let historyStore = self.historyStore

        Task.detached(priority: .utility) { @Sendable [weak self] in
            guard let self else { return }

            // Gather health assessments for all repos.
            // Skip this expensive loading when repo state hasn't changed —
            // time-based rules (escalation, auto-recovery) still work from
            // previous items alone and don't need fresh health data.
            var healthAssessments: [String: RepositoryHealthAssessment] = [:]
            if !skipHealthAssessments, let historyStore {
                for repo in repos {
                    switch historyStore.load(for: repo.id) {
                    case .success(let entries):
                        let assessment = RepositoryHealthEngine.assess(
                            repositoryID: repo.id,
                            repositoryName: repo.name,
                            entries: entries
                        )
                        healthAssessments[repo.id] = assessment
                    case .failure:
                        break
                    }
                }
            }

            // Load previous items from store
            let previousArchive: PendingItemArchive?
            switch self.pendingItemStore.load() {
            case .success(let archive):
                previousArchive = archive
            case .failure:
                previousArchive = nil
            }

            let context = PendingItemEvaluationContext(
                repositories: repos,
                workspaceAggregations: workspaceAggs,
                workspaces: confirmWorkspaces,
                healthAssessments: healthAssessments,
                previousItems: previousArchive?.items ?? []
            )

            let result = PendingItemEvaluator.evaluate(
                context: context,
                previousArchive: previousArchive
            )

            // Save to store
            _ = self.pendingItemStore.replaceAll(with: result.items)

            // Compute widget summary
            let summary = PendingItemWidgetSummary.build(from: result.items)
            _ = self.pendingItemStore.widgetSummary()

            Task { @MainActor in
                self.pendingItems = result.items
                self.pendingItemWidgetSummary = summary
                self.pendingItemEvaluationDurationMs = result.durationMs
            }
        }
    }

    /// Apply a user action to a pending item.
    func applyUserAction(to itemID: String, action: PendingItemUserAction, snoozeDuration: TimeInterval? = nil) {
        switch pendingItemStore.applyUserAction(itemID: itemID, action: action, snoozeDuration: snoozeDuration) {
        case .success(let archive):
            self.pendingItems = archive.items
            self.pendingItemWidgetSummary = PendingItemWidgetSummary.build(from: archive.items)
        case .failure:
            break
        }
    }

    /// Generate auto-suggest candidates for workspace grouping.
    func refreshWorkspaceSuggestions() {
        let repos = lastResult.repositories
        let context = WorkspaceAutoSuggestEngine.SuggestionContext(
            repositories: repos,
            existingWorkspaces: workspaces,
            dismissedHashes: Set()  // loaded from store on demand
        )
        Task.detached(priority: .utility) { @Sendable [weak self] in
            guard let self else { return }
            let candidates = WorkspaceAutoSuggestEngine.generateCandidates(context: context)
            Task { @MainActor in
                self.workspaceSuggestionCandidates = candidates
            }
        }
    }

    func createWorkspace(name: String, repositoryIDs: [String], groupingBasis: WorkspaceGroupingBasis) {
        let ws = Workspace(
            name: name,
            sortOrder: workspaces.count,
            repositoryIDs: repositoryIDs,
            groupingBasis: groupingBasis
        )
        _ = workspaceStore.upsertWorkspace(ws)
        loadWorkspacesFromStore()
        refreshWorkspaceAggregations()
    }

    func deleteWorkspace(id: String) {
        _ = workspaceStore.deleteWorkspace(id: id)
        loadWorkspacesFromStore()
        refreshWorkspaceAggregations()
    }

    func renameWorkspace(id: String, name: String) {
        switch workspaceStore.load() {
        case .success(var archive):
            if let idx = archive.workspaces.firstIndex(where: { $0.id == id }) {
                archive.workspaces[idx].name = name
                archive.workspaces[idx].updatedAt = ISO8601DateFormatter().string(from: Date())
                _ = workspaceStore.save(archive)
                loadWorkspacesFromStore()
            }
        case .failure:
            break
        }
    }

    func moveRepositoryToWorkspace(repositoryID: String, fromWorkspaceID: String?, toWorkspaceID: String?) {
        _ = workspaceStore.moveRepository(id: repositoryID, from: fromWorkspaceID, to: toWorkspaceID)
        loadWorkspacesFromStore()
        refreshWorkspaceAggregations()
    }

    func confirmWorkspaceSuggestion(_ candidate: WorkspaceAutoSuggestCandidate) {
        let ws = Workspace(
            name: candidate.name,
            sortOrder: workspaces.count,
            repositoryIDs: candidate.repositoryIDs,
            groupingBasis: candidate.groupingBasis,
            autoSuggestConfirmed: true
        )
        _ = workspaceStore.upsertWorkspace(ws)
        loadWorkspacesFromStore()
        refreshWorkspaceAggregations()
        refreshWorkspaceSuggestions()
    }

    func dismissWorkspaceSuggestion(_ candidate: WorkspaceAutoSuggestCandidate) {
        _ = workspaceStore.addDismissedSuggestion(hash: candidate.id)
        refreshWorkspaceSuggestions()
    }

    func permanentlyIgnoreWorkspaceSuggestion(_ candidate: WorkspaceAutoSuggestCandidate) {
        _ = workspaceStore.addDismissedSuggestion(hash: candidate.id)
        refreshWorkspaceSuggestions()
    }

    func confirmUnconfirmedWorkspace(_ workspace: Workspace) {
        let updated = Workspace(
            id: workspace.id,
            name: workspace.name,
            sortOrder: workspace.sortOrder,
            isPinned: workspace.isPinned,
            repositoryIDs: workspace.repositoryIDs,
            groupingBasis: workspace.groupingBasis,
            autoSuggestConfirmed: true
        )
        _ = workspaceStore.upsertWorkspace(updated)
        loadWorkspacesFromStore()
        refreshWorkspaceAggregations()
        refreshWorkspaceSuggestions()
    }

    private func loadWorkspacesFromStore() {
        switch workspaceStore.load() {
        case .success(let archive):
            self.workspaces = archive.workspaces
        case .failure:
            break
        }
    }

    func mergeWorkspaces(fromID: String, intoID: String) {
        _ = workspaceStore.mergeWorkspaces(fromID: fromID, intoID: intoID)
        loadWorkspacesFromStore()
        refreshWorkspaceAggregations()
    }

    func splitWorkspace(sourceID: String, newName: String, moveRepositoryIDs: [String]) {
        _ = workspaceStore.splitWorkspace(sourceID: sourceID, newName: newName, moveRepositoryIDs: moveRepositoryIDs)
        loadWorkspacesFromStore()
        refreshWorkspaceAggregations()
    }

    func reorderWorkspaces(ids: [String]) {
        _ = workspaceStore.reorderWorkspaces(ids: ids)
        loadWorkspacesFromStore()
    }

    func toggleWorkspacePin(id: String) {
        switch workspaceStore.load() {
        case .success(var archive):
            if let idx = archive.workspaces.firstIndex(where: { $0.id == id }) {
                archive.workspaces[idx].isPinned.toggle()
                archive.workspaces[idx].updatedAt = ISO8601DateFormatter().string(from: Date())
                _ = workspaceStore.save(archive)
                loadWorkspacesFromStore()
            }
        case .failure:
            break
        }
    }

    /// Aggregation for a single workspace with drill-down support.
    func aggregation(for workspaceID: String) -> WorkspaceAggregation? {
        workspaceAggregations[workspaceID]
    }

    // MARK: - Adaptive interval constants

    private static let baseInterval: TimeInterval = 300       // 5 min
    private static let extendedInterval1: TimeInterval = 600  // 10 min
    private static let extendedInterval2: TimeInterval = 1200 // 20 min
    private static let maxInterval: TimeInterval = 1800       // 30 min (AC power)
    private static let batteryMaxInterval: TimeInterval = 3600 // 60 min (battery)
    private static let lowPowerBaseInterval: TimeInterval = 900 // 15 min
    private static let lowPowerMaxInterval: TimeInterval = 7200 // 120 min (low-power mode)
    private static let noChangeThreshold1 = 3  // scans w/o change → 10 min
    private static let noChangeThreshold2 = 8  // scans w/o change → 20 min
    private static let noChangeThreshold3 = 15 // scans w/o change → maxInterval
    private static let refreshCoalescingNanoseconds: UInt64 = 200_000_000

    @Published private(set) var config: ScanConfig = .default

    var pinnedRepoIDs: Set<String> {
        get {
            let raw = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
                .stringArray(forKey: pinnedKey) ?? []
            return Set(raw)
        }
        set {
            UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
                .set(newValue.sorted(), forKey: pinnedKey)
        }
    }

    private var ignoredRepositoryPaths: Set<String> {
        RepositoryScope.canonicalPathSet(ignoredRepositories.map(\.path))
    }

    init(commandMode: Bool = false,
         activityEventStore: ActivityEventStore? = nil,
         historyStore: RepositoryHistoryStore? = nil,
         scanExecution: @escaping ScanExecution = { request in
        let engine = RefreshEngine()

        // Forward progress reports if a handler is set
        if let handler = request.progressHandler {
            Task {
                for await progress in engine.progress {
                    handler(progress)
                }
            }
        }

        let result = await engine.execute(
            config: request.config,
            scanRoots: request.roots,
            knownRepositoryPaths: request.knownRepositoryPaths,
            ignoredRepositoryPaths: request.ignoredRepositoryPaths,
            forceRepositoryDiscovery: request.forceRepositoryDiscovery,
            previousSnapshot: request.previousSnapshot,
            source: request.source
        )
        return (data: result.data, warnings: result.warnings, discoveredRepositoryPaths: result.discoveredRepositoryPaths)
    }) {
        self.scanExecution = scanExecution
        self.repositoryRetryExecution = { config, previousSnapshot in
            await GitRepositoryScanner.retryRepository(
                config: config,
                previousSnapshot: previousSnapshot
            )
        }
        self.activityEventStore = commandMode ? nil : activityEventStore
        self.historyStore = commandMode ? nil : (historyStore ?? RepositoryHistoryStore.live())
        self.workspaceStore = commandMode ? WorkspaceStore(fileURL: URL(fileURLWithPath: "/dev/null")) : WorkspaceStore.live()
        self.pendingItemStore = commandMode ? PendingItemStore(fileURL: URL(fileURLWithPath: "/dev/null")) : PendingItemStore.live()
        self.pendingItemNotificationStore = commandMode ? PendingItemNotificationStore(fileURL: URL(fileURLWithPath: "/dev/null")) : PendingItemNotificationStore.live()
        self.workspaceAggregationCache = WorkspaceAggregationCache()
        if commandMode {
            appGroupAvailable = AppGroupStore.isAvailable
            gitAvailable = ProcessRunner.isGitAvailable()
            updatePowerState()
            return
        }

        loadWorkspaces()

        loadConfig()
        loadScanDirectories()
        loadIgnoredRepositories()
        loadWorkspaces()
        loadPendingItems()
        syncStoreInspection()
        appGroupAvailable = AppGroupStore.isAvailable
        gitAvailable = ProcessRunner.isGitAvailable()
        restorePersistedSnapshot()
        restoreActivityEvents()
        updatePowerState()
        startPowerMonitoring()
        startSleepWakeMonitoring()
        startApplicationLifecycleMonitoring()
    }

    convenience init(
        commandMode: Bool,
        activityEventStore: ActivityEventStore? = nil,
        repositoryRetryExecution: @escaping RepositoryRetryExecution,
        scanExecution: @escaping ScanExecution
    ) {
        self.init(
            commandMode: commandMode,
            activityEventStore: activityEventStore,
            scanExecution: scanExecution
        )
        self.repositoryRetryExecution = repositoryRetryExecution
    }

    deinit {
        scanTask?.cancel()
        selfCheckTask?.cancel()
        repositoryRetryDrainTask?.cancel()
        repositoryRetryDrainWaiters.forEach { $0.resume() }
        refreshDebounceTask?.cancel()
        repositoryRetryTasks.values.forEach { $0.cancel() }
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
        if let applicationTerminateObserver {
            NotificationCenter.default.removeObserver(applicationTerminateObserver)
        }
        if let applicationDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(applicationDidBecomeActiveObserver)
        }
        if let systemClockDidChangeObserver {
            NotificationCenter.default.removeObserver(systemClockDidChangeObserver)
        }
        if let systemTimeZoneDidChangeObserver {
            NotificationCenter.default.removeObserver(systemTimeZoneDidChangeObserver)
        }
        if let calendarDayChangedObserver {
            NotificationCenter.default.removeObserver(calendarDayChangedObserver)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let workspaceSleepObserver {
            workspaceCenter.removeObserver(workspaceSleepObserver)
        }
        if let workspaceWakeObserver {
            workspaceCenter.removeObserver(workspaceWakeObserver)
        }
        if let workspaceSessionInactiveObserver {
            workspaceCenter.removeObserver(workspaceSessionInactiveObserver)
        }
        if let workspaceSessionActiveObserver {
            workspaceCenter.removeObserver(workspaceSessionActiveObserver)
        }
        if let workspaceVolumeMountedObserver {
            workspaceCenter.removeObserver(workspaceVolumeMountedObserver)
        }
        if let workspaceVolumeUnmountedObserver {
            workspaceCenter.removeObserver(workspaceVolumeUnmountedObserver)
        }
    }

    var isWorkSuspended: Bool { workSuspended }
    var hasScheduledTimer: Bool { backgroundTimer != nil }
    var hasPendingLocationRefresh: Bool {
        refreshDebounceTask != nil && deferredScanRefresh?.source == .configuration
    }
    var pendingRepositoryRetryDrainWaiterCount: Int { repositoryRetryDrainWaiters.count }
    var pendingPathRefreshCount: Int { pendingRepositoryRefreshRequirements.count }
    var isSessionInactive: Bool { sessionInactive }
    var isShuttingDown: Bool { terminating }

    var lastSuccessfulRefreshAt: Date? {
        lastResult.lastSuccessfulRefreshAt.flatMap(DateFormatting.date(from:))
    }

    var snapshotFreshness: SnapshotFreshness? {
        RefreshStatusFormatter.freshness(for: lastSuccessfulRefreshAt)
    }

    var refreshTrustAssessment: SnapshotTrustAssessment {
        RefreshStatusFormatter.refreshAssessment(
            lastUpdatedAt: lastSuccessfulRefreshAt,
            failureMessage: refreshPhase == .failure ? refreshFailureMessage : nil
        )
    }

    var refreshStatusText: String {
        switch refreshPhase {
        case .refreshing:
            return "刷新中…"
        case .degraded:
            return "部分仓库读取失败"
        case .failure:
            return "刷新失败"
        case .success:
            return refreshTrustAssessment.state == .fresh
                ? "刷新成功"
                : refreshTrustAssessment.title
        case .idle:
            return refreshTrustAssessment.title
        }
    }

    var refreshDetailText: String? {
        switch refreshPhase {
        case .refreshing:
            let errorCount = lastResult.scanSummary.errorRepositories
            if errorCount > 0 {
                return "仍显示上次结果 · \(errorCount) 个仓库待重试"
            }
            if let lastSuccessfulRefreshAt {
                return "仍显示上次成功：\(RefreshStatusFormatter.updateLabel(for: lastSuccessfulRefreshAt))"
            }
            return lastResult.repositories.isEmpty ? nil : "仍显示上次结果"
        case .degraded:
            let errorCount = lastResult.scanSummary.errorRepositories
            if errorCount > 0 {
                return "\(errorCount) 个仓库待重试，其他仓库已更新"
            }
            return "部分扫描目录待重试，已发现仓库已更新"
        case .failure:
            let reason = refreshFailureMessage ?? "本轮未能建立可用结果"
            return "\(reason) · \(refreshTrustAssessment.detail)"
        case .success:
            return refreshTrustAssessment.state == .fresh
                ? lastSuccessfulRefreshAt.map { RefreshStatusFormatter.updateLabel(for: $0) }
                : refreshTrustAssessment.detail
        case .idle:
            return refreshTrustAssessment.state == .fresh ? nil : refreshTrustAssessment.detail
        }
    }

    func freshness(at now: Date) -> SnapshotFreshness {
        RefreshStatusFormatter.freshness(
            for: lastSuccessfulRefreshAt,
            now: now
        )
    }

    func handleLifecycleRefresh(
        _ event: ScanLifecycleRefreshEvent,
        now: Date = Date()
    ) {
        guard !terminating else { return }

        switch event {
        case .systemTimeChanged:
            lastFreshnessRecalculationAt = now
            objectWillChange.send()

        case .startup:
            let decision = ScanSchedulerPolicy.startupRefreshDecision(
                snapshotIsFresh: !shouldRunImmediateStartupScan,
                currentRootsSignature: ScanSchedulerPolicy.scanRootsSignature(scanRoots().roots),
                lastDiscoveryRootsSignature: lastRepositoryDiscoveryScanRootsSignature
            )
            if !decision.forceRepositoryDiscovery {
                let recoveredCount = requestPathAvailabilityRefreshes(
                    under: nil,
                    isAvailable: true
                )
                if recoveredCount > 0, freshness(at: now) == .fresh {
                    return
                }
            }
            if decision.shouldRefreshImmediately {
                submitScanRequest(
                    forceRepositoryDiscovery: decision.forceRepositoryDiscovery,
                    source: .startup,
                    coalescingNanoseconds: Self.refreshCoalescingNanoseconds
                )
            }

        case .windowReopened, .applicationBecameActive:
            let recoveredCount = requestPathAvailabilityRefreshes(
                under: nil,
                isAvailable: true
            )
            if recoveredCount > 0, freshness(at: now) == .fresh {
                return
            }
            guard ScanSchedulerPolicy.shouldRefreshForLifecycle(
                    lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
                    refreshPhase: refreshPhase,
                    now: now
                  ) else {
                return
            }
            submitScanRequest(
                forceRepositoryDiscovery: false,
                source: event == .windowReopened ? .windowReopen : .foreground,
                coalescingNanoseconds: Self.refreshCoalescingNanoseconds
            )

        case .wake:
            let decision = ScanSchedulerPolicy.wakeRefreshDecision(
                lastScanAt: lastSuccessfulRefreshAt,
                refreshPhase: refreshPhase,
                sleepBeganAt: lastSystemSleepAt,
                refreshStartedAt: diagnostics.lastRefreshStartedAt,
                refreshCompletedAt: diagnostics.lastRefreshCompletedAt,
                now: now
            )
            let recoveredCount = requestPathAvailabilityRefreshes(
                under: nil,
                isAvailable: true
            )
            if backgroundScanningEnabled,
               !(recoveredCount > 0 && freshness(at: now) == .fresh),
               decision.shouldRefreshImmediately {
                submitScanRequest(
                    forceRepositoryDiscovery: decision.forceRepositoryDiscovery,
                    source: .wake,
                    coalescingNanoseconds: Self.refreshCoalescingNanoseconds
                )
            }

        case .pathAvailabilityChanged(let rootPath, let isAvailable):
            if isAvailable,
               pathRecoveryRequiresDiscovery(under: rootPath) {
                submitScanRequest(
                    forceRepositoryDiscovery: true,
                    source: .pathRecovery,
                    coalescingNanoseconds: Self.refreshCoalescingNanoseconds
                )
                return
            }
            _ = requestPathAvailabilityRefreshes(
                under: rootPath,
                isAvailable: isAvailable
            )
        }
    }

    // MARK: - Scan (async, non-blocking)

    func scanNow(forceRepositoryDiscovery: Bool = false,
                 source: ScanRefreshSource = .manual) {
        submitScanRequest(
            forceRepositoryDiscovery: forceRepositoryDiscovery,
            source: source
        )
    }

    private func submitScanRequest(
        forceRepositoryDiscovery: Bool,
        source: ScanRefreshSource,
        coalescingNanoseconds: UInt64? = nil
    ) {
        guard !terminating else { return }

        if let coalescingNanoseconds {
            if let deferredScanRefresh {
                self.deferredScanRefresh = deferredScanRefresh.merging(
                    forceRepositoryDiscovery: forceRepositoryDiscovery,
                    source: source
                )
            } else {
                deferredScanRefresh = DeferredScanRefresh(
                    forceRepositoryDiscovery: forceRepositoryDiscovery,
                    source: source
                )
            }

            refreshDebounceTask?.cancel()
            refreshDebounceTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: coalescingNanoseconds)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, !self.terminating else { return }
                self.flushDeferredScanRequest()
            }
            return
        }

        var mergedRequest = DeferredScanRefresh(
            forceRepositoryDiscovery: forceRepositoryDiscovery,
            source: source
        )
        if let deferredScanRefresh {
            mergedRequest = deferredScanRefresh.merging(
                forceRepositoryDiscovery: forceRepositoryDiscovery,
                source: source
            )
        }
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        deferredScanRefresh = nil
        enqueueScanRequest(mergedRequest)
    }

    private func flushDeferredScanRequest() {
        guard let deferredScanRefresh else {
            refreshDebounceTask = nil
            return
        }
        self.deferredScanRefresh = nil
        refreshDebounceTask = nil
        enqueueScanRequest(deferredScanRefresh)
    }

    private func enqueueScanRequest(_ request: DeferredScanRefresh) {
        guard !terminating else { return }

        let waitsForRepositoryRetries = request.source.isAutomatic
            && (!repositoryRetryTasks.isEmpty || repositoryRetryDrainTask != nil)
        if !waitsForRepositoryRetries {
            cancelRepositoryRetries()
        }
        // Lightweight signature from configured paths, no file-system access.
        let lightweightRoots = ScanLocationProvider.expandAll(
            Array(scanLocationConfiguration.enabledBuiltInPaths)
                + scanLocationConfiguration.customDirectories.map(\.path)
        )
        let signature = ScanSchedulerPolicy.scanRootsSignature(lightweightRoots)
        let queued: Bool
        if request.forceRepositoryDiscovery {
            queued = refreshCoordinator.requestForced(
                signature: signature,
                source: request.source
            )
        } else {
            queued = refreshCoordinator.request(
                signature: signature,
                forceRepositoryDiscovery: false,
                source: request.source
            )
        }
        if queued, isScanning {
            // A newer roots/configuration request supersedes the current scan.
            // The scanner propagates cancellation into its Git processes, so
            // the old run stops before the queued request starts.
            refreshCoordinator.markRunningCancelled()
            scanTask?.cancel()
        }
        startNextCoalescedScanIfNeeded()
    }

    private func startNextCoalescedScanIfNeeded() {
        guard !terminating, !workSuspended else { return }
        // A self-check uses the same scanner and snapshot writer. Keep queued
        // requests scheduled until it has fully unwound instead of consuming
        // one into an unstartable coordinator running state.
        guard !isScanning else { return }
        // A cancelled repository retry may still be terminating its Git
        // process. Do not overlap it with the next full scan.
        guard repositoryRetryTasks.isEmpty, repositoryRetryDrainTask == nil else { return }
        if sessionInactive, refreshCoordinator.nextRequest?.isAutomatic == true {
            return
        }
        guard let request = refreshCoordinator.beginNext() else { return }
        performScanNow(request: request)
    }

    private func performScanNow(request: ScanRefreshCoordinator.Request) {
        guard !isScanning else { return }
        pendingRepositoryRefreshRequirements.removeAll()

        isScanning = true
        diagnostics.lastRefreshStartedAt = Date()
        diagnostics.lastRefreshCompletedAt = nil
        refreshPhase = .refreshing
        refreshFailureMessage = nil
        sharedSnapshotSyncFailureMessage = nil
        warnings = []
        diagnostics.validationIssues = []
        diagnostics.sharedDataWriteError = nil
        diagnostics.sharedDataReadError = nil
        diagnostics.widgetSnapshotReadError = nil
        diagnostics.snapshotDecodable = false
        lastScanMetrics = nil

        // Capture all values needed by the background task while on the
        // main actor so the detached task never touches isolated state.
        let capturedConfig = config
        let capturedLocationConfig = scanLocationConfiguration
        let capturedIgnoredPaths = ignoredRepositoryPaths
        let knownRepositoryPaths = lastDiscoveredRepositoryPaths
        let previousSnapshot = lastResult
        let capturedRootsSignature = lastRepositoryDiscoveryScanRootsSignature
        let capturedDiscoveryAt = lastRepositoryDiscoveryAt
        let execution = scanExecution
        let metricsCollector = ScanMetricsCollector()
        scanGeneration &+= 1
        let generation = scanGeneration
        recordEvent(.scanStarted, "Scan started")

        scanTask = Task.detached(priority: request.taskPriority) {
            // ---- Everything below runs OFF the main actor ----

            // 1. Git availability check (synchronous file check, off-main).
            let gitAvailable = ProcessRunner.isGitAvailable()
            guard gitAvailable else {
                await MainActor.run { [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.failRefresh("Git is not available", persistRepositoryTrustFailure: true)
                    self.completeCurrentScanAndDrain()
                }
                return
            }

            // 2. Resolve scan roots (synchronous FileManager checks, off-main).
            let resolvedRoots = Self.resolveScanRootsOffMain(
                locationConfig: capturedLocationConfig,
                capturedConfig: capturedConfig
            )
            let executionConfig: ScanConfig = {
                var c = capturedConfig
                c.enabledBuiltInPaths = capturedLocationConfig.enabledBuiltInPaths
                c.customPaths = capturedLocationConfig.customDirectories.map(\.path)
                return c
            }()
            let rootsSignature = ScanSchedulerPolicy.scanRootsSignature(resolvedRoots.roots)
            let forceDiscovery = request.forceRepositoryDiscovery
            let shouldRediscover = ScanSchedulerPolicy.shouldRediscoverRepositories(
                forceRepositoryDiscovery: forceDiscovery,
                knownRepositoryPaths: knownRepositoryPaths,
                lastRepositoryDiscoveryAt: capturedDiscoveryAt,
                currentScanRootsSignature: rootsSignature,
                lastScanRootsSignature: capturedRootsSignature
            )

            // 3. Run the actual scan (all I/O happens through the scanner inside).
            let progressHandler: (@Sendable (RefreshProgress) -> Void)? = { [weak scheduler = self] progress in
                Task { @MainActor in
                    scheduler?.currentProgress = progress
                }
            }
            let requestObj = ScanExecutionRequest(
                config: executionConfig,
                roots: resolvedRoots.roots,
                rootsSignature: rootsSignature,
                knownRepositoryPaths: knownRepositoryPaths,
                ignoredRepositoryPaths: capturedIgnoredPaths,
                forceRepositoryDiscovery: shouldRediscover,
                previousSnapshot: previousSnapshot,
                source: request.source,
                metrics: metricsCollector,
                progressHandler: progressHandler
            )
            let result = await execution(requestObj)
            let wasCancelled = Task.isCancelled

            // ---- Back on the main actor for result plumbing ----
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.scanGeneration == generation else { return }
                self.scanTask = nil
                self.lastScanMetrics = metricsCollector.snapshot()
                self.gitAvailable = true
                self.diagnostics.scanRoots = resolvedRoots.roots
                self.diagnostics.scanRootWarnings = resolvedRoots.warning.map { [$0] } ?? []

                if wasCancelled {
                    self.isScanning = false
                    self.currentProgress = nil
                    self.refreshPhase = .idle
                    self.refreshFailureMessage = nil
                    self.recordEvent(.scanFailed, "Scan cancelled by a newer refresh request")
                    self.completeCurrentScanAndDrain()
                    return
                }

                if let failureMessage = self.scanFailureMessage(
                    for: result.data,
                    scanRoots: resolvedRoots,
                    warnings: result.warnings
                ) {
                    let previous = self.lastResult
                    let combinedWarnings = self.summarizeWarnings(
                        result.warnings,
                        accessWarning: resolvedRoots.warning
                    )

                    self.isScanning = false
                    self.currentProgress = nil
                    self.refreshPhase = .failure
                    self.refreshFailureMessage = failureMessage
                    self.scanRootAccessWarning = resolvedRoots.warning
                    self.warnings = [failureMessage] + combinedWarnings.filter { $0 != failureMessage }
                    self.diagnostics.validationIssues = self.warnings
                    self.recordEvent(.scanFailed, failureMessage)
                    self.lastDiscoveredRepositoryPaths = result.discoveredRepositoryPaths
                    if shouldRediscover,
                       GitRepositoryScanner.discoveryWasIncomplete(result.warnings) {
                        self.lastRepositoryDiscoveryAt = ScanSchedulerPolicy
                            .shouldPreserveDiscoveryScopeAfterIncompleteRefresh(
                                knownRepositoryPaths: knownRepositoryPaths,
                                currentScanRootsSignature: rootsSignature,
                                lastScanRootsSignature: self.lastRepositoryDiscoveryScanRootsSignature
                            ) ? Date() : nil
                    }

                    self.persistRepositoryTrustFailure(
                        failureMessage,
                        fallbackSnapshot: result.data
                    )
                    self.cleanupRemovedRepositoryPins(
                        previous: previous,
                        current: self.lastResult
                    )
                    self.completeCurrentScanAndDrain()
                    return
                }

                let previous = self.lastResult
                let pinned = self.applyPins(result.data)
                let completedAt = DateFormatting.date(from: pinned.generatedAt)
                let isDegraded = pinned.scanSummary.errorRepositories > 0
                    || GitRepositoryScanner.discoveryWasIncomplete(result.warnings)
                let trustedResult = pinned.withLastSuccessfulRefreshAt(
                    !isDegraded && completedAt != nil
                        ? pinned.generatedAt
                        : previous.lastSuccessfulRefreshAt
                )
                let combinedWarnings = self.summarizeWarnings(
                    result.warnings,
                    accessWarning: resolvedRoots.warning
                )
                self.warnings = combinedWarnings
                let hadChanges = self.hadChanges(before: previous, after: trustedResult)
                let recorded = hadChanges
                    ? self.recordActivityEvents(
                        previous: previous,
                        current: trustedResult,
                        observedAt: trustedResult.generatedAt
                    )
                    : previous
                self.cleanupRemovedRepositoryPins(previous: previous, current: recorded)

                if hadChanges {
                    self.lastResult = recorded
                }
                // Record repository state history in background (skip when nothing changed)
                if hadChanges {
                    self.recordHistoryFromSnapshot(recorded)
                }
                self.lastScanAt = completedAt
                self.diagnostics.lastScanAt = self.lastScanAt
                self.isScanning = false
                self.currentProgress = nil
                self.refreshPhase = isDegraded ? .degraded : .success
                self.refreshFailureMessage = nil
                self.scanRootAccessWarning = resolvedRoots.warning
                self.diagnostics.validationIssues = self.warnings
                self.lastDiscoveredRepositoryPaths = result.discoveredRepositoryPaths
                if shouldRediscover {
                    if GitRepositoryScanner.discoveryWasIncomplete(result.warnings) {
                        self.lastRepositoryDiscoveryAt = ScanSchedulerPolicy
                            .shouldPreserveDiscoveryScopeAfterIncompleteRefresh(
                                knownRepositoryPaths: knownRepositoryPaths,
                                currentScanRootsSignature: rootsSignature,
                                lastScanRootsSignature: self.lastRepositoryDiscoveryScanRootsSignature
                            ) ? Date() : nil
                    } else {
                        self.lastRepositoryDiscoveryAt = Date()
                        self.lastRepositoryDiscoveryScanRootsSignature = rootsSignature
                    }
                }
                if hadChanges {
                    // Refresh workspace aggregations in background
                    self.refreshWorkspaceAggregations()
                    self.refreshWorkspaceSuggestions()
                    // Refresh pending items (uses health assessments and workspace aggregations)
                    self.refreshPendingItems()
                } else {
                    // Still refresh pending items for time-based rule evaluation (escalation, auto-recovery)
                    // but skip the expensive per-repo history loading since no state changed.
                    self.refreshPendingItems(skipHealthAssessments: true)
                }

                if self.warnings.isEmpty {
                    self.recordEvent(
                        .scanSucceeded,
                        "Scan success: \(recorded.scanSummary.totalRepositories) repos, \(recorded.scanSummary.changedRepositories) changed, \(recorded.scanSummary.totalChangedFiles) files"
                    )
                } else {
                    self.recordEvent(
                        .scanSucceeded,
                        "Scan success with \(self.warnings.count) warning(s): \(recorded.scanSummary.totalRepositories) repos"
                    )
                }

                if hadChanges {
                    self.consecutiveNoChanges = 0
                } else {
                    self.consecutiveNoChanges += 1
                }
                self.updateScanInterval()

                // Stop the background timer entirely after prolonged inactivity.
                // It will be restarted by the next lifecycle event or manual scan.
                if !hadChanges, self.consecutiveNoChanges >= Self.noChangeThreshold3 + 1 {
                    self.backgroundTimer?.invalidate()
                    self.backgroundTimer = nil
                }
                if hadChanges {
                    self.syncSharedSnapshot(from: recorded, previousSnapshot: previous, reason: "scan")
                } else {
                    self.diagnostics.lastRefreshCompletedAt = Date()
                    self.diagnostics.lastSnapshotStoreTrigger = "scan"
                    self.diagnostics.lastSnapshotStoreState = .verified
                    self.diagnostics.lastSnapshotStoreDetail = "仓库状态未变化，保留现有可信快照。"
                    self.diagnostics.lastWidgetReloadState = .skipped
                    self.diagnostics.lastWidgetReloadDetail = "仓库状态未变化，本次未写快照或刷新 Widget。"
                }
                self.completeCurrentScanAndDrain()
            }
        }
    }

    func rescan() {
        // Reset adaptive state so user gets a fresh full scan
        consecutiveNoChanges = 0
        updateScanInterval()
        scanNow(forceRepositoryDiscovery: true, source: .manual)
    }

    func isRetryingRepository(_ repositoryID: String) -> Bool {
        retryingRepositoryIDs.contains(repositoryID)
    }

    func retryRepository(_ repositoryID: String) {
        _ = startRepositoryRefresh(
            repositoryID,
            requiresRetryState: true
        )
    }

    @discardableResult
    private func startRepositoryRefresh(
        _ repositoryID: String,
        requiresRetryState: Bool
    ) -> Bool {
        let retryConfig = scanConfigForExecution()
        let maximumRetryCount = min(12, max(1, retryConfig.maxConcurrentGitOps))
        guard !terminating,
              !isScanning,
              repositoryRetryDrainTask == nil,
              !refreshCoordinator.hasWork,
              repositoryRetryTasks.count < maximumRetryCount,
              !retryingRepositoryIDs.contains(repositoryID),
              let previousRepository = lastResult.repositories.first(where: { $0.id == repositoryID }),
              !requiresRetryState || previousRepository.needsReadRetry else {
            return false
        }

        let execution = repositoryRetryExecution
        let generation = repositoryRetryGeneration
        retryingRepositoryIDs.insert(repositoryID)

        // Automatic retries use utility priority to avoid competing with
        // user-facing work. User-initiated retries (via retryRepository) still
        // use .userInitiated to feel responsive.
        let retryPriority: TaskPriority = requiresRetryState ? .userInitiated : .utility
        let task = Task.detached(priority: retryPriority) { [weak self] in
            let retriedRepository = await execution(retryConfig, previousRepository)
            let wasCancelled = Task.isCancelled

            await MainActor.run { [weak self] in
                guard let self,
                      self.repositoryRetryGeneration == generation else {
                    return
                }

                self.repositoryRetryTasks[repositoryID] = nil
                self.retryingRepositoryIDs.remove(repositoryID)
                defer {
                    self.drainPendingRepositoryRefreshes()
                    if self.repositoryRetryTasks.isEmpty, !self.terminating {
                        self.startNextCoalescedScanIfNeeded()
                    }
                }

                guard !wasCancelled,
                      var retriedRepository,
                      let currentRepository = self.lastResult.repositories.first(where: {
                          $0.id == repositoryID && $0.path == previousRepository.path
                      }) else {
                    return
                }

                retriedRepository.isPinned = currentRepository.isPinned
                let previousSnapshot = self.lastResult
                let repositories = RepositorySorter.sort(
                    previousSnapshot.repositories.map {
                        $0.id == repositoryID ? retriedRepository : $0
                    }
                )
                var unavailableSinceByPath = previousSnapshot.repositoryUnavailableSinceByPath ?? [:]
                if retriedRepository.resolvedDataSource == .current,
                   retriedRepository.status != .error {
                    unavailableSinceByPath[retriedRepository.path] = nil
                } else if unavailableSinceByPath[retriedRepository.path] == nil {
                    unavailableSinceByPath[retriedRepository.path] = retriedRepository.unavailableSince
                        ?? retriedRepository.lastScannedAt
                }

                let updated = AppGroupData(
                    schemaVersion: previousSnapshot.schemaVersion,
                    generatedAt: previousSnapshot.generatedAt,
                    writtenAt: previousSnapshot.writtenAt,
                    lastSuccessfulRefreshAt: previousSnapshot.lastSuccessfulRefreshAt,
                    scanSummary: ScanSummary.build(
                        from: repositories,
                        totalRepositories: max(
                            previousSnapshot.scanSummary.totalRepositories,
                            repositories.count
                        )
                    ),
                    repositories: repositories,
                    recentActivityEvents: previousSnapshot.recentActivityEvents,
                    repositoryUnavailableSinceByPath: unavailableSinceByPath.isEmpty
                        ? nil
                        : unavailableSinceByPath,
                    storageRevision: previousSnapshot.storageRevision,
                    persistenceState: repositories.contains {
                        $0.resolvedDataSource == .current && $0.status != .error
                    } ? .committed : previousSnapshot.persistenceState
                )
                let recorded = self.recordActivityEvents(
                    previous: previousSnapshot,
                    current: updated,
                    observedAt: retriedRepository.lastScannedAt
                )
                let completeWatermark = recorded.scanSummary.errorRepositories == 0
                    ? recorded.completeRepositorySuccessWatermark
                    : nil
                let finalSnapshot = completeWatermark == nil
                    ? recorded
                    : recorded.withLastSuccessfulRefreshAt(completeWatermark)
                self.lastResult = finalSnapshot

                let hasCurrentData = finalSnapshot.repositories.contains {
                    $0.resolvedDataSource == .current && $0.status != .error
                }
                if hasCurrentData {
                    if finalSnapshot.scanSummary.errorRepositories > 0 {
                        self.refreshPhase = .degraded
                    } else {
                        self.refreshPhase = completeWatermark == nil ? .idle : .success
                    }
                    self.refreshFailureMessage = nil
                } else {
                    self.refreshPhase = .failure
                    if self.refreshFailureMessage == nil {
                        self.refreshFailureMessage = "本轮未能读取任何仓库的当前 Git 状态"
                    }
                }

                self.syncSharedSnapshot(
                    from: finalSnapshot,
                    previousSnapshot: previousSnapshot,
                    reason: "repository-retry"
                )
            }
        }
        repositoryRetryTasks[repositoryID] = task
        return true
    }

    private func requestPathAvailabilityRefreshes(
        under rootPath: String?,
        isAvailable: Bool
    ) -> Int {
        var candidates = ScanSchedulerPolicy.repositoriesNeedingPathRefresh(
            lastResult.repositories,
            under: rootPath,
            isAvailable: isAvailable,
            pathIsReachable: { [weak self] path in
                self?.isAccessibleScanRoot(path) == true
            }
        )

        // A mount can race the read that was started by the matching unmount.
        // Until that read finishes, the in-memory snapshot still looks current,
        // so retain a follow-up intent for affected in-flight repositories.
        if isAvailable {
            let canonicalRoot = rootPath.map(RepositoryIdentity.canonicalPath)
            var candidateIDs = Set(candidates.map(\.id))
            let inFlightCandidates = lastResult.repositories.filter { repository in
                guard retryingRepositoryIDs.contains(repository.id),
                      isAccessibleScanRoot(repository.path) else {
                    return false
                }
                guard let canonicalRoot else { return true }
                return RepositoryIdentity.isSameOrDescendantPath(
                    repository.path,
                    of: canonicalRoot
                )
            }
            for repository in inFlightCandidates where candidateIDs.insert(repository.id).inserted {
                candidates.append(repository)
            }
        }

        for repository in candidates {
            let existingRequirement = pendingRepositoryRefreshRequirements[repository.id]
            pendingRepositoryRefreshRequirements[repository.id] = existingRequirement.map {
                $0 && isAvailable
            } ?? isAvailable
        }
        drainPendingRepositoryRefreshes()
        return candidates.count
    }

    private func drainPendingRepositoryRefreshes() {
        guard !terminating,
              !workSuspended,
              !sessionInactive,
              !isScanning,
              !refreshCoordinator.hasWork,
              repositoryRetryDrainTask == nil else {
            return
        }

        let maximumRetryCount = min(12, max(1, scanConfigForExecution().maxConcurrentGitOps))
        while repositoryRetryTasks.count < maximumRetryCount {
            guard let repositoryID = pendingRepositoryRefreshRequirements.keys
                .sorted()
                .first(where: { !retryingRepositoryIDs.contains($0) }),
                  let requiresRetryState = pendingRepositoryRefreshRequirements.removeValue(
                    forKey: repositoryID
                  ) else {
                return
            }
            _ = startRepositoryRefresh(
                repositoryID,
                requiresRetryState: requiresRetryState
            )
        }
    }

    private func pathRecoveryRequiresDiscovery(under rootPath: String?) -> Bool {
        guard let rootPath else { return false }
        let canonicalRoot = RepositoryIdentity.canonicalPath(rootPath)
        let configuredRootAffected = scanRoots().roots.contains { configuredRoot in
            RepositoryIdentity.isSameOrDescendantPath(configuredRoot, of: canonicalRoot)
                || RepositoryIdentity.isSameOrDescendantPath(canonicalRoot, of: configuredRoot)
        }
        guard configuredRootAffected else { return false }

        let affectedKnownPaths = lastDiscoveredRepositoryPaths.filter {
            RepositoryIdentity.isSameOrDescendantPath($0, of: canonicalRoot)
        }
        let visiblePaths = Set(lastResult.repositories.map {
            RepositoryIdentity.canonicalPath($0.path)
        })
        if affectedKnownPaths.contains(where: { !visiblePaths.contains($0) }) {
            return true
        }

        return affectedKnownPaths.isEmpty
    }

    private func cancelRepositoryRetries() {
        let tasks = Array(repositoryRetryTasks.values)
        guard !tasks.isEmpty else { return }
        repositoryRetryGeneration &+= 1
        tasks.forEach { $0.cancel() }
        repositoryRetryTasks.removeAll()
        retryingRepositoryIDs.removeAll()

        repositoryRetryDrainGeneration &+= 1
        let generation = repositoryRetryDrainGeneration
        let drainTask = Task.detached(priority: .utility) { [weak self] in
            for task in tasks {
                await task.value
            }
            await MainActor.run { [weak self] in
                self?.finishRepositoryRetryDrain(generation: generation)
            }
        }
        repositoryRetryDrainTask = drainTask
    }

    private func finishRepositoryRetryDrain(generation: Int) {
        guard repositoryRetryDrainGeneration == generation else { return }
        repositoryRetryDrainTask = nil
        resumeRepositoryRetryDrainWaiters()
        if !terminating {
            startNextCoalescedScanIfNeeded()
            drainPendingRepositoryRefreshes()
        }
    }

    private func waitForRepositoryRetryDrain() async {
        guard repositoryRetryDrainTask != nil else { return }
        await withCheckedContinuation { continuation in
            if repositoryRetryDrainTask == nil {
                continuation.resume()
            } else {
                repositoryRetryDrainWaiters.append(continuation)
            }
        }
    }

    private func resumeRepositoryRetryDrainWaiters() {
        let waiters = repositoryRetryDrainWaiters
        repositoryRetryDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func runSelfCheck() async -> ScanSelfCheckReport {
        guard !terminating, !workSuspended else { return makeSelfCheckReport() }
        if let selfCheckTask {
            return await selfCheckTask.value
        }
        if let scanTask {
            await scanTask.value
            return await runSelfCheck()
        }

        selfCheckGeneration &+= 1
        let generation = selfCheckGeneration
        let task = Task { @MainActor [self] in
            await performSelfCheck()
        }
        selfCheckTask = task

        return await withTaskCancellationHandler {
            let report = await task.value
            if selfCheckGeneration == generation {
                selfCheckTask = nil
                if !terminating {
                    startNextCoalescedScanIfNeeded()
                    drainPendingRepositoryRefreshes()
                }
            }
            return report
        } onCancel: {
            task.cancel()
        }
    }

    private func performSelfCheck() async -> ScanSelfCheckReport {
        guard !terminating else { return makeSelfCheckReport() }
        isScanning = true
        pendingRepositoryRefreshRequirements.removeAll()
        cancelRepositoryRetries()
        await waitForRepositoryRetryDrain()
        if Task.isCancelled || terminating {
            isScanning = false
            return makeSelfCheckReport()
        }
        gitAvailable = ProcessRunner.isGitAvailable()
        guard gitAvailable else {
            failRefresh("Git 不可用", persistRepositoryTrustFailure: true)
            return makeSelfCheckReport()
        }

        syncStoreInspection()
        appGroupAvailable = AppGroupStore.isAvailable
        diagnostics.validationIssues = []
        diagnostics.sharedDataWriteError = nil
        diagnostics.sharedDataReadError = nil
        diagnostics.widgetSnapshotReadError = nil
        diagnostics.snapshotDecodable = false
        diagnostics.lastRefreshStartedAt = Date()
        diagnostics.lastRefreshCompletedAt = nil
        isScanning = true
        refreshPhase = .refreshing
        refreshFailureMessage = nil
        sharedSnapshotSyncFailureMessage = nil
        warnings = []
        lastScanMetrics = nil

        let currentConfig = scanConfigForExecution()
        let currentScanRoots = scanRoots()
        let metricsCollector = ScanMetricsCollector()
        let execution = scanExecution
        let result = await execution(ScanExecutionRequest(
            config: currentConfig,
            roots: currentScanRoots.roots,
            rootsSignature: ScanSchedulerPolicy.scanRootsSignature(currentScanRoots.roots),
            knownRepositoryPaths: [],
            ignoredRepositoryPaths: ignoredRepositoryPaths,
            forceRepositoryDiscovery: true,
            previousSnapshot: lastResult,
            source: .manual,
            metrics: metricsCollector
        ))
        lastScanMetrics = metricsCollector.snapshot()

        if Task.isCancelled || terminating {
            isScanning = false
            if refreshPhase == .refreshing {
                refreshPhase = .idle
                refreshFailureMessage = nil
            }
            diagnostics.lastRefreshCompletedAt = Date()
            return makeSelfCheckReport()
        }

        if let failureMessage = scanFailureMessage(
            for: result.data,
            scanRoots: currentScanRoots,
            warnings: result.warnings
        ) {
            let previousSnapshot = lastResult
            let combinedWarnings = summarizeWarnings(
                result.warnings,
                accessWarning: currentScanRoots.warning
            )

            isScanning = false
            refreshPhase = .failure
            refreshFailureMessage = failureMessage
            scanRootAccessWarning = currentScanRoots.warning
            warnings = [failureMessage] + combinedWarnings.filter { $0 != failureMessage }
            diagnostics.validationIssues = warnings
            diagnostics.nextSteps = suggestedNextSteps(from: warnings)
            recordEvent(.scanFailed, "Self-check failed: \(failureMessage)")
            lastDiscoveredRepositoryPaths = result.discoveredRepositoryPaths
            lastRepositoryDiscoveryAt = nil
            persistRepositoryTrustFailure(
                failureMessage,
                fallbackSnapshot: result.data
            )
            cleanupRemovedRepositoryPins(previous: previousSnapshot, current: lastResult)
            return makeSelfCheckReport()
        }

        let previousSnapshot = lastResult
        let pinned = applyPins(result.data)
        let completedAt = DateFormatting.date(from: pinned.generatedAt)
        let isDegraded = pinned.scanSummary.errorRepositories > 0
            || GitRepositoryScanner.discoveryWasIncomplete(result.warnings)
        let trustedResult = pinned.withLastSuccessfulRefreshAt(
            !isDegraded && completedAt != nil
                ? pinned.generatedAt
                : previousSnapshot.lastSuccessfulRefreshAt
        )
        let combinedWarnings = summarizeWarnings(
            result.warnings,
            accessWarning: currentScanRoots.warning
        )
        warnings = combinedWarnings
        let recorded = recordActivityEvents(
            previous: previousSnapshot,
            current: trustedResult,
            observedAt: trustedResult.generatedAt
        )
        cleanupRemovedRepositoryPins(previous: previousSnapshot, current: recorded)

        lastResult = recorded
        lastScanAt = completedAt
        diagnostics.lastScanAt = lastScanAt
        isScanning = false
        refreshPhase = isDegraded ? .degraded : .success
        refreshFailureMessage = nil
        scanRootAccessWarning = currentScanRoots.warning
        diagnostics.validationIssues = warnings
        lastDiscoveredRepositoryPaths = result.discoveredRepositoryPaths
        if GitRepositoryScanner.discoveryWasIncomplete(result.warnings) {
            lastRepositoryDiscoveryAt = nil
        } else {
            lastRepositoryDiscoveryAt = Date()
            lastRepositoryDiscoveryScanRootsSignature = ScanSchedulerPolicy.scanRootsSignature(
                currentScanRoots.roots
            )
        }

        syncSharedSnapshot(from: recorded, previousSnapshot: previousSnapshot, reason: "self-check")
        recordEvent(.scanSucceeded, "Self-check refreshed \(recorded.scanSummary.totalRepositories) repos")

        return makeSelfCheckReport()
    }

    // MARK: - Background scheduling

    func startBackgroundScanning(refreshIfNeeded: Bool = true) {
        guard !terminating else { return }
        stopBackgroundScanning()
        backgroundScanningEnabled = true
        if refreshIfNeeded {
            handleLifecycleRefresh(.startup)
        }
        scheduleNextTimer()
    }

    func stopBackgroundScanning() {
        backgroundScanningEnabled = false
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    private func scheduleNextTimer() {
        guard backgroundScanningEnabled,
              !terminating,
              !workSuspended,
              !sessionInactive else {
            backgroundTimer?.invalidate()
            backgroundTimer = nil
            return
        }
        backgroundTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: scanIntervalSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.backgroundScanningEnabled,
                      !self.terminating,
                      !self.workSuspended,
                      !self.sessionInactive else {
                    return
                }
                self.backgroundTimer = nil
                self.scanNow(source: .timer)
                self.scheduleNextTimer()
            }
        }
        // Allow power-coalescing tolerance: 10 % of the interval
        // enables the system to align this timer with other wake sources.
        timer.tolerance = scanIntervalSeconds * 0.1
        backgroundTimer = timer
    }

    // MARK: - Adaptive interval

    private func updateScanInterval() {
        updatePowerState()

        let newInterval: TimeInterval

        switch consecutiveNoChanges {
        case Self.noChangeThreshold3...:
            newInterval = Self.maxInterval
        case Self.noChangeThreshold2...:
            newInterval = Self.extendedInterval2
        case Self.noChangeThreshold1...:
            newInterval = Self.extendedInterval1
        default:
            newInterval = Self.baseInterval
        }

        // Power-aware floor and ceiling
        let floor: TimeInterval
        let ceiling: TimeInterval?
        switch powerState {
        case "low-power":
            floor = Self.lowPowerBaseInterval
            ceiling = Self.lowPowerMaxInterval
        case "battery":
            floor = Self.lowPowerBaseInterval
            ceiling = Self.batteryMaxInterval
        default:
            floor = Self.baseInterval
            ceiling = nil
        }

        let clamped: TimeInterval = max(newInterval, floor)
        if let ceiling {
            scanIntervalSeconds = min(clamped, ceiling)
        } else {
            scanIntervalSeconds = clamped
        }
        UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .set(scanIntervalSeconds, forKey: lastScanIntervalKey)

        // Re-schedule if timer is active
        if backgroundTimer != nil {
            scheduleNextTimer()
        }
    }

    // MARK: - Change detection

    private func hadChanges(before: AppGroupData, after: AppGroupData) -> Bool {
        ScanSchedulerPolicy.hasMeaningfulSnapshotChanges(
            previousSnapshot: before,
            nextSnapshot: after
        )
    }

    /// Resolve scan roots without accessing any main-actor-isolated state.
    /// All FileManager calls run on the calling (background) thread.
    private nonisolated static func resolveScanRootsOffMain(
        locationConfig: ScanLocationConfiguration,
        capturedConfig: ScanConfig
    ) -> (roots: [String], warning: String?) {
        let enabledBuiltIn = ScanLocationProvider.builtInLocations
            .map(ScanLocationProvider.expandTilde)
            .filter { locationConfig.enabledBuiltInPaths.contains($0) }
        let customDirs = locationConfig.customDirectories

        var roots: [String] = []
        var inaccessibleCount = 0
        var containerPathCount = 0

        for path in enabledBuiltIn {
            let norm = ScanLocationProvider.canonicalExistingFilePath(path)
            if ScanLocationProvider.isLikelySandboxContainerPath(norm) {
                containerPathCount += 1
                continue
            }
            var isDir: ObjCBool = false
            if !(FileManager.default.fileExists(atPath: norm, isDirectory: &isDir) && isDir.boolValue) {
                inaccessibleCount += 1
            }
            roots.append(norm)
        }

        for dir in customDirs {
            let resolved: String
            if let bm = dir.bookmarkData {
                var stale = false
                if let url = try? URL(
                    resolvingBookmarkData: bm,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) {
                    resolved = ScanLocationProvider.canonicalExistingFilePath(url.path)
                } else {
                    resolved = ScanLocationProvider.canonicalExistingFilePath(dir.path)
                }
            } else {
                resolved = ScanLocationProvider.canonicalExistingFilePath(dir.path)
            }

            if ScanLocationProvider.isLikelySandboxContainerPath(resolved) {
                containerPathCount += 1
                continue
            }
            var isDir: ObjCBool = false
            if !(FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) && isDir.boolValue) {
                inaccessibleCount += 1
            }
            roots.append(resolved)
        }

        let deduped = Array(Set(roots)).sorted()
        let warning: String?
        if deduped.isEmpty {
            warning = "没有找到可用的扫描目录。请在设置中添加一个真实的仓库根目录。"
        } else if containerPathCount > 0 {
            warning = "检测到沙盒容器路径，已忽略。请把扫描目录改回真实用户目录。"
        } else if inaccessibleCount > 0 {
            warning = "部分目录权限失效，请在设置中重新授权。"
        } else {
            warning = nil
        }
        return (deduped, warning)
    }

    private func scanRoots() -> (roots: [String], warning: String?) {
        let enabledBuiltInRoots = ScanLocationProvider.builtInLocations
            .map(ScanLocationProvider.expandTilde)
            .filter { scanLocationConfiguration.enabledBuiltInPaths.contains($0) }
        let configuredDirectories = scanLocationConfiguration.customDirectories

        var configuredRoots: [String] = []
        var inaccessibleCount = 0
        var containerPathCount = 0

        for path in enabledBuiltInRoots {
            let normalizedPath = ScanLocationProvider.canonicalExistingFilePath(path)
            guard !isAppContainerPath(normalizedPath) else {
                containerPathCount += 1
                continue
            }
            if !isAccessibleScanRoot(normalizedPath) {
                inaccessibleCount += 1
            }
            configuredRoots.append(normalizedPath)
        }

        for directory in configuredDirectories {
            if let url = resolvedURL(for: directory) {
                let path = ScanLocationProvider.canonicalExistingFilePath(url.path)
                guard !isAppContainerPath(path) else {
                    containerPathCount += 1
                    continue
                }
                if !isAccessibleScanRoot(path) {
                    inaccessibleCount += 1
                }
                configuredRoots.append(path)
                continue
            }

            let normalizedPath = ScanLocationProvider.canonicalExistingFilePath(directory.path)
            guard !isAppContainerPath(normalizedPath) else {
                containerPathCount += 1
                continue
            }
            if !isAccessibleScanRoot(normalizedPath) {
                inaccessibleCount += 1
            }
            configuredRoots.append(normalizedPath)
        }

        let deduped = Array(Set(configuredRoots)).sorted()
        let warning: String?
        if deduped.isEmpty {
            warning = "未发现可用的扫描目录。请在 Settings 启用一个默认目录或添加真实的仓库根目录后再刷新。"
        } else if containerPathCount > 0 {
            warning = "检测到沙盒容器路径，已忽略。请把扫描目录改回真实用户目录。"
        } else if inaccessibleCount > 0 {
            warning = "部分目录权限失效，请在 Settings 重新授权。"
        } else {
            warning = nil
        }

        diagnostics.scanRoots = deduped
        diagnostics.scanRootWarnings = warning.map { [$0] } ?? []
        return (deduped, warning)
    }

    // MARK: - Shared snapshot sync

    private func restoreActivityEvents() {
        guard let activityEventStore else { return }
        switch activityEventStore.load() {
        case .success(let result):
            let migratedEvents = result.events.map { event in
                guard let migratedID = activityRepositoryIDMigrations[event.repositoryID] else {
                    return event
                }
                return event.remappingRepositoryID(to: migratedID)
            }
            let repositoryIDs = Set(lastResult.repositories.map(\.id))
            let scopedEvents = activityEventStore.pruning(
                migratedEvents,
                keepingRepositoryIDs: repositoryIDs
            )
            activityEvents = scopedEvents
            if scopedEvents != result.events,
               case .failure(let error) = activityEventStore.save(scopedEvents) {
                warnings.append(error.localizedDescription)
            }
            switch result.recovery {
            case .none:
                break
            case .migratedLegacy:
                warnings.append("已迁移旧版活动记录")
            case .recoveredCorruption:
                warnings.append("活动记录损坏，已恢复为空记录并继续运行")
            }
        case .failure(let error):
            warnings.append(error.localizedDescription)
        }
    }

    private func recordActivityEvents(
        previous: AppGroupData,
        current: AppGroupData,
        observedAt: String
    ) -> AppGroupData {
        let detected = ActivityEventDiffer.events(
            previous: previous,
            current: current,
            observedAt: observedAt
        )
        let merger = activityEventStore
            ?? ActivityEventStore(fileURL: URL(fileURLWithPath: "/dev/null"))
        let repositoryIDs = Set(current.repositories.map(\.id))
        let scopedExisting = merger.pruning(
            activityEvents,
            keepingRepositoryIDs: repositoryIDs
        )
        let newEvents = ActivityEventDeduplicator.newEvents(
            from: detected,
            comparedTo: scopedExisting
        )
        let merged = merger.pruning(
            merger.merging(existing: scopedExisting, newEvents: newEvents),
            keepingRepositoryIDs: repositoryIDs
        )

        activityEvents = merged

        if let eventStore = activityEventStore {
            Task.detached(priority: .utility) { @Sendable [weak self] in
                switch eventStore.save(merged) {
                case .success(let saved):
                    await MainActor.run { @MainActor in
                        self?.activityEvents = saved
                    }
                case .failure(let error):
                    let message = error.localizedDescription
                    await MainActor.run { @MainActor in
                        guard let self else { return }
                        if !self.warnings.contains(message) {
                            self.warnings.append(message)
                        }
                    }
                }
            }
        }

        let now = DateFormatting.date(from: observedAt) ?? Date()
        return current.withRecentActivityEvents(
            ActivityEventWidgetSummaryBuilder.build(from: activityEvents, now: now)
        )
    }

    /// Record repository state history points into the history store.
    /// Runs asynchronously on a utility queue to avoid blocking the main thread.
    private func recordHistoryFromSnapshot(_ snapshot: AppGroupData) {
        guard let historyStore else { return }
        let recordedAt = snapshot.generatedAt
        let repositories = snapshot.repositories

        Task.detached(priority: .utility) { @Sendable [weak self] in
            let loadResult = historyStore.load()
            let previousStates: [String: HistoryStatePoint]
            switch loadResult {
            case .success(let entries):
                var latest: [String: RepositoryHistoryEntry] = [:]
                for entry in entries {
                    if let existing = latest[entry.repositoryID] {
                        if entry.recordedAt > existing.recordedAt {
                            latest[entry.repositoryID] = entry
                        }
                    } else {
                        latest[entry.repositoryID] = entry
                    }
                }
                previousStates = latest.mapValues(\.state)
            case .failure:
                previousStates = [:]
            }

            var historyEntries: [RepositoryHistoryEntry] = []

            for repo in repositories {
                let point = HistoryStatePoint(snapshot: repo)
                let previousPoint = previousStates[repo.id]
                let previousDS = previousPoint?.dataSource
                let kind = HistoryEntryKindClassifier.classify(
                    previous: previousPoint,
                    current: point,
                    lastDataSource: previousDS,
                    currentDataSource: point.dataSource
                )

                let entry = RepositoryHistoryEntry(
                    repositoryID: repo.id,
                    recordedAt: recordedAt,
                    kind: kind,
                    state: point
                )
                historyEntries.append(entry)
            }

            guard !historyEntries.isEmpty else { return }

            switch historyStore.record(entries: historyEntries) {
            case .success(let added):
                if added > 0 {
                    _ = added
                    // Non-blocking background compaction if nearing limit
                    let currentCount = historyStore.count()
                    if currentCount > 8000 {
                        historyStore.compact()
                    }
                    // Non-blocking background note — diagnostics available via scheduler.historyDiagnostics
                    _ = historyStore.diagnosticsSnapshot()
                }
            case .failure:
                break
            }
        }
    }

    private func restorePersistedSnapshot() {
        syncStoreInspection()
        _ = AppGroupStore.cleanupTemporaryFiles()
        switch AppGroupStore.readDetailed() {
        case .success(let storedRead):
            let snapshot = storedRead.snapshot
            let migration = RepositoryIdentityMigration.migrate(
                snapshot: snapshot,
                pinnedIDs: pinnedRepoIDs
            )
            activityRepositoryIDMigrations = migration.repositoryIDMigrations
            if migration.pinnedIDs != pinnedRepoIDs {
                pinnedRepoIDs = migration.pinnedIDs
            }

            let migratedPinnedSnapshot = applyPins(migration.snapshot)
            let scopeChanged = migratedPinnedSnapshot != snapshot
            var restoredSnapshot = migratedPinnedSnapshot
            var sharedSnapshot = snapshot
            var startupWriteError: String?
            let storageSourceNeedsRewrite: Bool
            switch storedRead.source {
            case .primary:
                storageSourceNeedsRewrite = false
            case .migratedPrimary, .backup:
                storageSourceNeedsRewrite = true
            }
            if migration.changed || scopeChanged || storageSourceNeedsRewrite {
                requiresStartupScopeRefresh = true
                let written = migratedPinnedSnapshot.withWrittenAt(
                    snapshot.writtenAt ?? DateFormatting.nowISO()
                )
                switch AppGroupStore.write(written) {
                case .success(let verified):
                    restoredSnapshot = verified
                    sharedSnapshot = verified
                    requiresStartupScopeRefresh = false
                    if scopeChanged {
                        AppGroupStore.reloadWidgets()
                    }
                case .failure(let error):
                    startupWriteError = error.localizedDescription
                }
            }

            let pinned = applyPins(restoredSnapshot)
            lastResult = pinned
            if pinned.repositories.contains(where: { $0.workspaceKind == nil }) {
                // Snapshots written before workspace classification existed
                // need one prompt refresh. The scanner can then inspect the
                // known repositories and discover registered linked
                // worktrees without waiting for the normal discovery TTL.
                requiresStartupScopeRefresh = true
            }
            diagnostics.lastSnapshotStoreTrigger = "startup"
            diagnostics.lastSnapshotStoreState = startupWriteError == nil ? .restored : .failed
            diagnostics.lastSnapshotStoreDetail = startupWriteError
                ?? startupRestoreDetail(
                    source: storedRead.source,
                    repositoryCount: restoredSnapshot.repositories.count
                )
            diagnostics.sharedDataSnapshot = sharedSnapshot
            diagnostics.snapshotDecodable = true
            let now = Date()
            diagnostics.sharedDataReadAt = now
            diagnostics.sharedDataReadError = nil
            diagnostics.sharedDataWriteError = startupWriteError
            diagnostics.lastGeneratedAt = sharedSnapshot.generatedAt
            diagnostics.lastWrittenAt = sharedSnapshot.writtenAt
            if let writtenAt = sharedSnapshot.writtenAt.flatMap(DateFormatting.date(from:)) {
                diagnostics.lastSharedWriteAt = writtenAt
            }
            if let generatedAt = DateFormatting.date(from: restoredSnapshot.generatedAt) {
                lastScanAt = generatedAt
                diagnostics.lastScanAt = generatedAt
            }
            let retainedOnly = ScanSchedulerPolicy.allRepositoryDataUnavailable(pinned.repositories)
            if let startupWriteError {
                sharedSnapshotSyncFailureMessage = "启动时未能更新共享仓库范围"
                warnings = [sharedSnapshotSyncFailureMessage ?? "共享快照同步失败", startupWriteError]
            } else {
                sharedSnapshotSyncFailureMessage = nil
                warnings = []
            }

            if retainedOnly {
                let message = "上次扫描未能刷新仓库，当前显示上次成功或未知数据"
                refreshPhase = .failure
                refreshFailureMessage = message
                if !warnings.contains(message) {
                    warnings.insert(message, at: 0)
                }
            } else if pinned.scanSummary.errorRepositories > 0 {
                refreshPhase = .degraded
                refreshFailureMessage = nil
            } else {
                refreshPhase = .idle
                refreshFailureMessage = nil
            }
            setWidgetReadableSnapshot(sharedSnapshot, readAt: now)
            validateConsistency(expected: pinned, shared: sharedSnapshot, widget: diagnostics.widgetSnapshot, reason: "startup")
        case .failure(.snapshotMissing):
            diagnostics.snapshotDecodable = false
            diagnostics.sharedDataSnapshot = nil
            diagnostics.widgetSnapshot = nil
            diagnostics.sharedDataReadError = nil
            diagnostics.widgetSnapshotReadError = nil
            diagnostics.validationIssues = []
            refreshPhase = .idle
            refreshFailureMessage = nil
            sharedSnapshotSyncFailureMessage = nil
            warnings = []
        case .failure(let error):
            diagnostics.snapshotDecodable = false
            diagnostics.sharedDataReadError = error.localizedDescription
            diagnostics.widgetSnapshotReadError = error.localizedDescription
            diagnostics.validationIssues = [error.localizedDescription]
            refreshPhase = .failure
            refreshFailureMessage = "读取共享快照失败"
            sharedSnapshotSyncFailureMessage = nil
            recordEvent(.sharedDataReadFailed, "Shared snapshot read failed at startup: \(error.localizedDescription)")
        }
    }

    private func startupRestoreDetail(
        source: SharedSnapshotReadSource,
        repositoryCount: Int
    ) -> String {
        switch source {
        case .primary:
            return "启动时已恢复 \(repositoryCount) 个仓库的共享快照。"
        case .migratedPrimary:
            return "启动时已迁移旧版共享快照，并保守恢复 \(repositoryCount) 个仓库。"
        case .backup:
            return "主快照不可用，启动时已从最后验证备份恢复 \(repositoryCount) 个仓库。"
        }
    }

    private func syncSharedSnapshot(
        from snapshot: AppGroupData,
        previousSnapshot: AppGroupData? = nil,
        reason: String
    ) {
        let writtenAt = DateFormatting.nowISO()
        let snapshotToWrite = applyPins(snapshot)
            .withWrittenAt(writtenAt)
            .withPendingItemWidgetSummary(
                pendingItems.isEmpty ? nil : pendingItemWidgetSummary
            )
        let prevSnapshot = previousSnapshot ?? lastResult

        diagnostics.lastSnapshotStoreTrigger = reason
        diagnostics.lastSnapshotStoreState = .idle
        diagnostics.lastSnapshotStoreDetail = "正在把 \(snapshotToWrite.repositories.count) 个仓库写入共享快照…"

        Task.detached(priority: .utility) { @Sendable [weak self] in
            let writeResult = AppGroupStore.write(snapshotToWrite)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch writeResult {
                case .success(let readBack):
                    self.handleSyncSnapshotSuccess(
                        readBack: readBack,
                        prevSnapshot: prevSnapshot,
                        reason: reason
                    )
                case .failure(let error):
                    self.handleSyncSnapshotFailure(
                        error: error,
                        reason: reason
                    )
                }
            }
        }
    }

    private func handleSyncSnapshotSuccess(
        readBack: AppGroupData,
        prevSnapshot: AppGroupData?,
        reason: String
    ) {
        let now = Date()
        sharedSnapshotSyncFailureMessage = nil
        syncStoreInspection()
        appGroupAvailable = AppGroupStore.isAvailable
        diagnostics.lastRefreshCompletedAt = now
        diagnostics.lastSharedWriteAt = readBack.writtenAt
            .flatMap(DateFormatting.date(from:)) ?? now
        diagnostics.lastGeneratedAt = readBack.generatedAt
        diagnostics.lastWrittenAt = readBack.writtenAt
        diagnostics.sharedDataWriteError = nil
        diagnostics.snapshotDecodable = true
        diagnostics.lastSnapshotStoreState = .verified
        diagnostics.lastSnapshotStoreDetail = "已写入并读回校验成功：\(readBack.repositories.count) 个仓库，reason=\(reason)。"
        diagnostics.sharedDataReadAt = Date()
        diagnostics.sharedDataSnapshot = readBack
        diagnostics.sharedDataReadError = nil
        setWidgetReadableSnapshot(readBack, readAt: Date())
        validateConsistency(
            expected: readBack,
            shared: readBack,
            widget: diagnostics.widgetSnapshot,
            reason: reason
        )
        lastResult = applyPins(readBack)
        let prev = prevSnapshot ?? lastResult
        let reloadDecision = ScanSchedulerPolicy.widgetReloadDecision(
            previousSnapshot: prev,
            nextSnapshot: lastResult,
            lastReloadRequestedAt: diagnostics.lastReloadRequestedAt,
            reason: reason
        )
        diagnostics.lastWidgetReloadState = reloadDecision.shouldRequest ? .requested : .skipped
        diagnostics.lastWidgetReloadDetail = reloadDecision.detail
        if reloadDecision.shouldRequest {
            diagnostics.lastReloadRequestedAt = Date()
            recordEvent(.widgetReloadRequested, "Widget reload requested (\(reason)): \(reloadDecision.detail)")
            AppGroupStore.reloadWidgets()
        } else {
            recordEvent(.widgetReloadSkipped, "Widget reload skipped (\(reason)): \(reloadDecision.detail)")
        }
        recordEvent(
            .sharedDataWritten,
            "Shared snapshot written (\(readBack.repositories.count) repos, \(reason))"
        )
    }

    private func handleSyncSnapshotFailure(
        error: AppGroupStoreError,
        reason: String
    ) {
        syncStoreInspection()
        diagnostics.lastRefreshCompletedAt = Date()
        diagnostics.sharedDataWriteError = error.localizedDescription
        diagnostics.snapshotDecodable = false
        diagnostics.validationIssues = [error.localizedDescription]
        diagnostics.lastSnapshotStoreState = .failed
        diagnostics.lastSnapshotStoreDetail = error.localizedDescription
        diagnostics.lastWidgetReloadState = .idle
        diagnostics.lastWidgetReloadDetail = "共享快照写入失败，本次没有进入 Widget reload 判断。"
        markSharedSnapshotSyncFailure(error.localizedDescription)
        recordEvent(.sharedDataWriteFailed, "Shared snapshot write failed: \(error.localizedDescription)")
    }

    private func markSharedSnapshotSyncFailure(_ reason: String) {
        let message = "当前列表数据已保留，但 Widget 数据同步失败"
        sharedSnapshotSyncFailureMessage = message
        if !warnings.contains(message) {
            warnings.append(message)
        }
        if !warnings.contains(reason) {
            warnings.append(reason)
        }
    }

    private func syncStoreInspection() {
        let inspection = AppGroupStore.inspect()
        appGroupAvailable = inspection.containerURL != nil
        diagnostics.appBundleIdentifier = inspection.appBundleIdentifier
        diagnostics.widgetBundleIdentifier = inspection.widgetBundleIdentifier
        diagnostics.appGroupIdentifier = inspection.appGroupIdentifier
        diagnostics.appGroupContainerPath = inspection.containerPath
        diagnostics.snapshotFilePath = inspection.snapshotPath
        diagnostics.appGroupAvailable = appGroupAvailable
        diagnostics.snapshotExists = inspection.snapshotExists
        diagnostics.snapshotReadable = inspection.snapshotReadable
        diagnostics.snapshotWritable = inspection.snapshotWritable
    }

    private func refreshWidgetReadableSnapshot() {
        switch AppGroupStore.read() {
        case .success(let snapshot):
            setWidgetReadableSnapshot(snapshot, readAt: Date())
        case .failure(.snapshotMissing):
            diagnostics.widgetSnapshot = nil
            diagnostics.widgetSnapshotReadAt = nil
            diagnostics.widgetSnapshotReadError = "Widget 可读快照不存在。请先执行一次 Rescan。"
        case .failure(let error):
            diagnostics.widgetSnapshot = nil
            diagnostics.widgetSnapshotReadAt = nil
            diagnostics.widgetSnapshotReadError = error.localizedDescription
        }
    }

    private func setWidgetReadableSnapshot(_ snapshot: AppGroupData, readAt: Date) {
        diagnostics.widgetSnapshot = RepositoryScope.filtering(
            snapshot,
            excluding: ignoredRepositoryPaths
        )
        diagnostics.widgetSnapshotReadAt = readAt
        diagnostics.widgetSnapshotReadError = nil
    }

    private func validateConsistency(expected: AppGroupData,
                                     shared: AppGroupData?,
                                     widget: AppGroupData?,
                                     reason: String) {
        var issues: [String] = []

        if !appGroupAvailable {
            issues.append("App Group is unavailable.")
        }
        if let sharedDataWriteError = diagnostics.sharedDataWriteError {
            issues.append(sharedDataWriteError)
        }

        guard let shared else {
            issues.append("Shared snapshot is unavailable.")
            diagnostics.validationIssues = issues
            recordEvent(.validationFailed, "Validation failed (\(reason)): \(issues.joined(separator: " "))")
            return
        }

        if shared != expected {
            issues.append("Main app snapshot differs from shared snapshot.")
        }

        if let widgetSnapshotReadError = diagnostics.widgetSnapshotReadError {
            issues.append(widgetSnapshotReadError)
        } else if let widget, widget != shared, widget != expected {
            issues.append("Widget-facing snapshot differs from shared snapshot.")
        } else if widget == nil {
            issues.append("Widget-facing snapshot is unavailable.")
        }

        if issues.isEmpty {
            diagnostics.validationIssues = []
            recordEvent(.validationPassed, "Validation passed (\(reason))")
        } else {
            diagnostics.validationIssues = issues
            recordEvent(.validationFailed, "Validation failed (\(reason)): \(issues.joined(separator: " "))")
        }

        diagnostics.nextSteps = suggestedNextSteps(from: issues)
    }

    private func recordEvent(_ kind: DiagnosticEvent.Kind, _ message: String) {
        let event = DiagnosticEvent(
            timestamp: DateFormatting.nowISO(),
            kind: kind,
            message: message
        )
        diagnosticEvents.append(event)
        if diagnosticEvents.count > 20 {
            diagnosticEvents = Array(diagnosticEvents.suffix(20))
        }
    }

    private func summarizeWarnings(_ warnings: [String], accessWarning: String?) -> [String] {
        var summarized: [String] = []
        var sawRootUnavailable = false

        for warning in warnings {
            if warning.hasPrefix("Scan root unavailable:") {
                sawRootUnavailable = true
                continue
            }
            if warning == GitRepositoryScanner.incompleteDiscoveryWarning {
                let message = "部分扫描目录暂时不可访问，仓库发现将在后续刷新中重试。"
                if !summarized.contains(message) {
                    summarized.append(message)
                }
                continue
            }
            summarized.append(warning)
        }

        if sawRootUnavailable, let accessWarning, !summarized.contains(accessWarning) {
            summarized.append(accessWarning)
        }

        return summarized
    }

    private func scanFailureMessage(for data: AppGroupData,
                                    scanRoots: (roots: [String], warning: String?),
                                    warnings: [String]) -> String? {
        if scanRoots.roots.isEmpty {
            let hasConfiguredRoots = !scanLocationConfiguration.enabledBuiltInPaths.isEmpty
                || !scanLocationConfiguration.customDirectories.isEmpty
            if !hasConfiguredRoots {
                return nil
            }
            return scanRoots.warning ?? "刷新失败，无法访问扫描目录"
        }

        if data.repositories.isEmpty,
           GitRepositoryScanner.discoveryWasIncomplete(warnings) {
            return "部分扫描目录暂时不可访问，未能确认仓库范围"
        }

        if ScanSchedulerPolicy.allRepositoryDataUnavailable(data.repositories) {
            return "本轮未能读取任何仓库的当前 Git 状态"
        }

        return nil
    }

    private func persistRepositoryTrustFailure(
        _ message: String,
        fallbackSnapshot: AppGroupData? = nil
    ) {
        // Preserve the top-level generatedAt as the last successful scan time
        // while writing a new repository-level provenance state for Widget and
        // relaunch recovery. When no prior snapshot exists, keep the unknown
        // repositories from the failed attempt instead of dropping them.
        let previousSnapshot = lastResult
        // The scanner's fallback repository set is authoritative for scope:
        // it has already removed definitively deleted/moved/ignored paths and
        // retained only temporarily unavailable repositories. Fall back to the
        // previous set only for failures that happened before scanning began.
        let failureBasis = fallbackSnapshot ?? previousSnapshot
        let retained = failureBasis.repositories.isEmpty
            ? failureBasis
            : failureBasis.retainingLastSuccessfulRepositories(
                attemptedAt: DateFormatting.nowISO(),
                errorMessage: message
            )
        let previousHasRepositoryTrustState = !previousSnapshot.repositories.isEmpty
            || !(previousSnapshot.repositoryUnavailableSinceByPath?.isEmpty ?? true)
        let sortedRetained = AppGroupData(
            schemaVersion: retained.schemaVersion,
            generatedAt: previousHasRepositoryTrustState
                ? previousSnapshot.generatedAt
                : retained.generatedAt,
            writtenAt: previousHasRepositoryTrustState
                ? previousSnapshot.writtenAt
                : retained.writtenAt,
            lastSuccessfulRefreshAt: previousHasRepositoryTrustState
                ? previousSnapshot.lastSuccessfulRefreshAt
                : retained.lastSuccessfulRefreshAt,
            scanSummary: retained.scanSummary,
            repositories: RepositorySorter.sort(retained.repositories),
            recentActivityEvents: retained.recentActivityEvents,
            repositoryUnavailableSinceByPath: retained.repositoryUnavailableSinceByPath,
            storageRevision: retained.storageRevision,
            persistenceState: retained.persistenceState
        )
        let pinnedRetained = applyPins(sortedRetained)
        lastResult = recordActivityEvents(
            previous: previousSnapshot,
            current: pinnedRetained,
            observedAt: pinnedRetained.repositories.first?.lastScannedAt ?? DateFormatting.nowISO()
        )
        syncSharedSnapshot(
            from: lastResult,
            previousSnapshot: previousSnapshot,
            reason: "scan-failure"
        )
    }

    private func failRefresh(
        _ message: String,
        persistRepositoryTrustFailure shouldPersistRepositoryTrustFailure: Bool = false
    ) {
        isScanning = false
        currentProgress = nil
        refreshPhase = .failure
        refreshFailureMessage = message
        diagnostics.lastRefreshCompletedAt = Date()
        warnings = [message]
        diagnostics.validationIssues = [message]
        diagnostics.nextSteps = suggestedNextSteps(from: [message])
        recordEvent(.scanFailed, message)
        if shouldPersistRepositoryTrustFailure {
            persistRepositoryTrustFailure(message)
        }
    }

    // MARK: - Power monitoring

    private func updatePowerState() {
        let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let isOnBattery = isRunningOnBattery()

        if isLowPower {
            powerState = "low-power"
        } else if isOnBattery {
            powerState = "battery"
        } else {
            powerState = "normal"
        }
    }

    private func startPowerMonitoring() {
        // Observe low-power mode changes
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateScanInterval()
            }
        }
    }

    private func startSleepWakeMonitoring() {
        let center = NSWorkspace.shared.notificationCenter

        workspaceSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendForSleep()
            }
        }

        workspaceWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeAfterWake()
            }
        }

        workspaceSessionInactiveObserver = center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendAutomaticWorkForInactiveSession()
            }
        }

        workspaceSessionActiveObserver = center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeAutomaticWorkForActiveSession()
            }
        }

        workspaceVolumeMountedObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rootPath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            MainActor.assumeIsolated {
                self?.handleLifecycleRefresh(
                    .pathAvailabilityChanged(rootPath: rootPath, isAvailable: true)
                )
            }
        }

        workspaceVolumeUnmountedObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rootPath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            MainActor.assumeIsolated {
                self?.handleLifecycleRefresh(
                    .pathAvailabilityChanged(rootPath: rootPath, isAvailable: false)
                )
            }
        }
    }

    private func startApplicationLifecycleMonitoring() {
        applicationDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleLifecycleRefresh(.applicationBecameActive)
            }
        }

        applicationTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }

        systemClockDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleLifecycleRefresh(.systemTimeChanged)
            }
        }

        systemTimeZoneDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleLifecycleRefresh(.systemTimeChanged)
            }
        }

        calendarDayChangedObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleLifecycleRefresh(.systemTimeChanged)
            }
        }
    }

    func suspendForSleep(now: Date = Date()) {
        guard !terminating, !workSuspended else { return }
        workSuspended = true
        lastSystemSleepAt = now
        backgroundTimer?.invalidate()
        backgroundTimer = nil

        let interruptedFullScan = refreshCoordinator.hasWork || isScanning || selfCheckTask != nil
        let interruptedRetry = !repositoryRetryTasks.isEmpty
        let interruptedDeferredRefresh = refreshDebounceTask != nil
        let interruptedForcedDiscovery = deferredScanRefresh?.forceRepositoryDiscovery == true
            || selfCheckTask != nil
            || refreshCoordinator.runningRequest?.forceRepositoryDiscovery == true
            || refreshCoordinator.nextRequest?.forceRepositoryDiscovery == true
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        deferredScanRefresh = nil
        cancelRepositoryRetries()

        if interruptedFullScan || interruptedRetry || interruptedDeferredRefresh {
            let signature = ScanSchedulerPolicy.scanRootsSignature(scanRoots().roots)
            refreshCoordinator.retainOnlyRecovery(
                signature: signature,
                forceRepositoryDiscovery: interruptedForcedDiscovery
            )
        } else {
            refreshCoordinator.discardScheduledAutomaticRequests()
        }

        if scanTask != nil {
            refreshCoordinator.markRunningCancelled()
            scanTask?.cancel()
        }
        selfCheckTask?.cancel()
    }

    func resumeAfterWake(now: Date = Date()) {
        guard !terminating, workSuspended else { return }
        workSuspended = false

        updatePowerState()
        handleLifecycleRefresh(.wake, now: now)
        lastSystemSleepAt = nil

        startNextCoalescedScanIfNeeded()
        drainPendingRepositoryRefreshes()
        scheduleNextTimer()
    }

    func suspendAutomaticWorkForInactiveSession() {
        guard !terminating, !sessionInactive else { return }
        sessionInactive = true
        backgroundTimer?.invalidate()
        backgroundTimer = nil

        refreshCoordinator.discardScheduledAutomaticRequests()
        guard refreshCoordinator.runningRequest?.isAutomatic == true else { return }

        if refreshCoordinator.nextRequest?.isAutomatic == false {
            // Preserve an explicit manual/configuration successor; it is safe
            // to drain while the login session is inactive.
            refreshCoordinator.markRunningCancelled()
        } else {
            let signature = refreshCoordinator.runningRequest?.signature
                ?? ScanSchedulerPolicy.scanRootsSignature(scanRoots().roots)
            refreshCoordinator.retainOnlyRecovery(
                signature: signature,
                forceRepositoryDiscovery: refreshCoordinator.runningRequest?.forceRepositoryDiscovery == true
            )
        }
        scanTask?.cancel()
    }

    func resumeAutomaticWorkForActiveSession() {
        guard !terminating, sessionInactive else { return }
        sessionInactive = false
        handleLifecycleRefresh(.applicationBecameActive)
        startNextCoalescedScanIfNeeded()
        drainPendingRepositoryRefreshes()
        scheduleNextTimer()
    }

    func shutdown() {
        guard !terminating else { return }
        terminating = true
        backgroundScanningEnabled = false
        workSuspended = true
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        deferredScanRefresh = nil
        pendingRepositoryRefreshRequirements.removeAll()
        cancelRepositoryRetries()
        refreshCoordinator.markRunningCancelled()
        refreshCoordinator.cancelAll()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        selfCheckGeneration &+= 1
        selfCheckTask?.cancel()
        selfCheckTask = nil
        repositoryRetryDrainGeneration &+= 1
        repositoryRetryDrainTask?.cancel()
        repositoryRetryDrainTask = nil
        resumeRepositoryRetryDrainWaiters()
        isScanning = false
        if refreshPhase == .refreshing {
            refreshPhase = .idle
            refreshFailureMessage = nil
        }
        removeLifecycleObservers()
    }

    private func removeLifecycleObservers() {
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
        if let applicationTerminateObserver {
            NotificationCenter.default.removeObserver(applicationTerminateObserver)
            self.applicationTerminateObserver = nil
        }
        if let applicationDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(applicationDidBecomeActiveObserver)
            self.applicationDidBecomeActiveObserver = nil
        }
        if let systemClockDidChangeObserver {
            NotificationCenter.default.removeObserver(systemClockDidChangeObserver)
            self.systemClockDidChangeObserver = nil
        }
        if let systemTimeZoneDidChangeObserver {
            NotificationCenter.default.removeObserver(systemTimeZoneDidChangeObserver)
            self.systemTimeZoneDidChangeObserver = nil
        }
        if let calendarDayChangedObserver {
            NotificationCenter.default.removeObserver(calendarDayChangedObserver)
            self.calendarDayChangedObserver = nil
        }

        let center = NSWorkspace.shared.notificationCenter
        if let workspaceSleepObserver {
            center.removeObserver(workspaceSleepObserver)
            self.workspaceSleepObserver = nil
        }
        if let workspaceWakeObserver {
            center.removeObserver(workspaceWakeObserver)
            self.workspaceWakeObserver = nil
        }
        if let workspaceSessionInactiveObserver {
            center.removeObserver(workspaceSessionInactiveObserver)
            self.workspaceSessionInactiveObserver = nil
        }
        if let workspaceSessionActiveObserver {
            center.removeObserver(workspaceSessionActiveObserver)
            self.workspaceSessionActiveObserver = nil
        }
        if let workspaceVolumeMountedObserver {
            center.removeObserver(workspaceVolumeMountedObserver)
            self.workspaceVolumeMountedObserver = nil
        }
        if let workspaceVolumeUnmountedObserver {
            center.removeObserver(workspaceVolumeUnmountedObserver)
            self.workspaceVolumeUnmountedObserver = nil
        }
    }

    private func completeCurrentScanAndDrain() {
        _ = refreshCoordinator.completeCurrent()
        startNextCoalescedScanIfNeeded()
        drainPendingRepositoryRefreshes()
    }

    /// Check if the machine is running on battery via IOKit.
    private func isRunningOnBattery() -> Bool {
        // Use IOKit to read power source
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        guard let snapshot else { return false }
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any] ?? []
        for source in sources {
            if let info = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?
                .takeUnretainedValue() as? [String: Any] {
                if let type = info[kIOPSTypeKey] as? String,
                   type == kIOPSInternalBatteryType,
                   let powerSource = info[kIOPSPowerSourceStateKey] as? String,
                   powerSource == kIOPSBatteryPowerValue {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Pins

    private func applyPins(_ data: AppGroupData) -> AppGroupData {
        let scopedData = RepositoryScope.filtering(
            data,
            excluding: ignoredRepositoryPaths
        )
        let migration = RepositoryIdentityMigration.migrate(
            snapshot: scopedData,
            pinnedIDs: pinnedRepoIDs
        )
        if migration.pinnedIDs != pinnedRepoIDs {
            pinnedRepoIDs = migration.pinnedIDs
        }
        let pinnedIDs = migration.pinnedIDs
        var repos = migration.snapshot.repositories.map { repo -> RepositorySnapshot in
            var copy = repo
            copy.isPinned = pinnedIDs.contains(repo.id)
            return copy
        }
        repos = RepositorySorter.sort(repos)

        return AppGroupData(
            schemaVersion: migration.snapshot.schemaVersion,
            generatedAt: migration.snapshot.generatedAt,
            writtenAt: migration.snapshot.writtenAt,
            lastSuccessfulRefreshAt: migration.snapshot.lastSuccessfulRefreshAt,
            scanSummary: migration.snapshot.scanSummary,
            repositories: repos,
            recentActivityEvents: migration.snapshot.recentActivityEvents,
            repositoryUnavailableSinceByPath: migration.snapshot.repositoryUnavailableSinceByPath,
            storageRevision: migration.snapshot.storageRevision,
            persistenceState: migration.snapshot.persistenceState
        )
    }

    func togglePin(repoID: String) {
        var current = pinnedRepoIDs
        if current.contains(repoID) {
            current.remove(repoID)
        } else {
            current.insert(repoID)
        }
        pinnedRepoIDs = current
        let updated = applyPins(lastResult)
        lastResult = updated
        syncSharedSnapshot(from: updated, reason: "pin toggle")
    }

    private func cleanupRemovedRepositoryPins(previous: AppGroupData, current: AppGroupData) {
        let removedIDs = Set(previous.repositories.map(\.id))
            .subtracting(current.repositories.map(\.id))
        guard !removedIDs.isEmpty else { return }
        var pins = pinnedRepoIDs
        pins.subtract(removedIDs)
        pinnedRepoIDs = pins
    }

    // MARK: - Ignored repositories

    func ignoreRepository(path: String) {
        let canonicalPath = RepositoryIdentity.canonicalPath(path)
        guard !canonicalPath.isEmpty,
              !ignoredRepositoryPaths.contains(canonicalPath) else { return }

        let previousSnapshot = lastResult
        ignoredRepositories = (ignoredRepositories + [IgnoredRepository(path: canonicalPath)])
            .sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
        persistIgnoredRepositories()

        var pins = pinnedRepoIDs
        pins.remove(RepositoryIdentity.id(for: canonicalPath))
        pinnedRepoIDs = pins
        lastDiscoveredRepositoryPaths = lastDiscoveredRepositoryPaths.filter {
            RepositoryIdentity.canonicalPath($0) != canonicalPath
        }

        let scoped = applyPins(lastResult)
        lastResult = recordActivityEvents(
            previous: previousSnapshot,
            current: scoped,
            observedAt: DateFormatting.nowISO()
        )
        syncSharedSnapshot(
            from: lastResult,
            previousSnapshot: previousSnapshot,
            reason: "repository ignored"
        )
        scanNow(forceRepositoryDiscovery: true, source: .configuration)
    }

    func restoreIgnoredRepository(path: String) {
        let canonicalPath = RepositoryIdentity.canonicalPath(path)
        let restored = ignoredRepositories.filter {
            RepositoryIdentity.canonicalPath($0.path) != canonicalPath
        }
        guard restored.count != ignoredRepositories.count else { return }

        ignoredRepositories = restored
        persistIgnoredRepositories()
        // A forced discovery walks the existing roots, so users never need to
        // re-add a scan directory when restoring a repository.
        scanNow(forceRepositoryDiscovery: true, source: .configuration)
    }

    private func loadIgnoredRepositories() {
        let defaults = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)
        let archive: IgnoredRepositoryArchive
        if let data = defaults?.data(forKey: ignoredRepositoriesKey),
           let decoded = try? JSONDecoder().decode(IgnoredRepositoryArchive.self, from: data) {
            archive = decoded
        } else {
            archive = IgnoredRepositoryArchive(
                paths: defaults?.stringArray(forKey: legacyIgnoredRepositoryPathsKey) ?? []
            )
        }

        ignoredRepositories = archive.paths.map(IgnoredRepository.init(path:))
            .sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
        persistIgnoredRepositories()
        defaults?.removeObject(forKey: legacyIgnoredRepositoryPathsKey)
    }

    private func persistIgnoredRepositories() {
        let archive = IgnoredRepositoryArchive(paths: ignoredRepositories.map(\.path))
        guard let data = try? JSONEncoder().encode(archive) else { return }
        UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .set(data, forKey: ignoredRepositoriesKey)
    }

    // MARK: - Config persistence

    private func persistScanLocations() {
        guard let data = try? JSONEncoder().encode(scanLocationConfiguration) else { return }
        UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .set(data, forKey: scanLocationsKey)
    }

    private func loadConfig() {
        guard let data = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(ScanConfig.self, from: data) else {
            configLoadedFromPersistence = false
            config = defaultScanConfig()
            return
        }
        configLoadedFromPersistence = true
        config = normalizeConfig(decoded)

        // Load last interval
        if let saved = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .double(forKey: lastScanIntervalKey), saved >= 300 {
            scanIntervalSeconds = saved
        }
    }

    private func loadScanDirectories() {
        if let data = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?.data(forKey: scanLocationsKey),
           let decoded = try? JSONDecoder().decode(ScanLocationConfiguration.self, from: data) {
            scanLocationConfiguration = ScanLocationConfiguration(
                enabledBuiltInPaths: Set(decoded.enabledBuiltInPaths.map(ScanLocationProvider.normalizePersistedPath).filter(ScanLocationProvider.isBuiltInPath)),
                customDirectories: sanitizeScanDirectories(decoded.customDirectories)
            )
            scanRootAccessWarning = scanRoots().warning
            return
        }
        let configuredBuiltIns = config.enabledBuiltInPaths
            .map(ScanLocationProvider.normalizePersistedPath)
        let customDirectories: [CustomScanDirectory]
        if let data = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .data(forKey: scanDirectoriesKey),
           let decoded = try? JSONDecoder().decode([CustomScanDirectory].self, from: data) {
            let sanitized = sanitizeScanDirectories(decoded)
            let builtInPaths = Set(sanitized.map(\.path).filter(ScanLocationProvider.isBuiltInPath))
            customDirectories = sanitized.filter { !ScanLocationProvider.isBuiltInPath($0.path) }
            config.enabledBuiltInPaths = ScanSchedulerPolicy.migratedBuiltInPaths(
                configWasLoaded: configLoadedFromPersistence,
                configuredBuiltIns: Set(configuredBuiltIns),
                directoryBuiltIns: builtInPaths,
                defaultBuiltIns: ScanLocationProvider.builtInAbsoluteSet
            )
        } else {
            customDirectories = sanitizeScanDirectories(
                config.customPaths.map { CustomScanDirectory(path: $0, bookmarkData: nil) }
            )
            if !configLoadedFromPersistence && configuredBuiltIns.isEmpty && config.customPaths.isEmpty {
                config.enabledBuiltInPaths = ScanLocationProvider.builtInAbsoluteSet
            } else {
                config.enabledBuiltInPaths = Set(configuredBuiltIns)
            }
        }

        scanLocationConfiguration = ScanLocationConfiguration(
            enabledBuiltInPaths: config.enabledBuiltInPaths,
            customDirectories: customDirectories
        )
        scanRootAccessWarning = scanRoots().warning
        persistScanLocations()
    }

    // MARK: - Enabled toggles

    func isBuiltInEnabled(path: String) -> Bool {
        let normalized = ScanLocationProvider.normalizePersistedPath(path)
        return scanLocationConfiguration.enabledBuiltInPaths.contains(normalized)
    }

    func toggleBuiltIn(path: String, enabled: Bool) {
        let normalized = ScanLocationProvider.normalizePersistedPath(path)
        var updated = scanLocationConfiguration
        if enabled {
            updated.enabledBuiltInPaths.insert(normalized)
        } else {
            updated.enabledBuiltInPaths.remove(normalized)
        }
        guard updated != scanLocationConfiguration else { return }
        scanLocationConfiguration = updated
        persistScanLocations()
        scanRootAccessWarning = scanRoots().warning
        requestLocationRefresh()
    }

    func addCustomPath(_ path: String) {
        let expanded = ScanLocationProvider.canonicalExistingFilePath(path)
        guard !expanded.isEmpty else { return }
        guard !ScanLocationProvider.isBuiltInPath(expanded) else {
            toggleBuiltIn(path: expanded, enabled: true)
            return
        }
        guard !isAppContainerPath(expanded) else {
            scanRootAccessWarning = "不能把 DevPulse 自己的沙盒容器当作扫描目录，请选择真实的用户目录。"
            return
        }
        guard isAccessibleScanRoot(expanded) else {
            scanRootAccessWarning = "部分目录权限失效，请在 Settings 重新授权。"
            return
        }
        if let existingIndex = scanLocationConfiguration.customDirectories.firstIndex(where: { $0.path == expanded }) {
            if scanLocationConfiguration.customDirectories[existingIndex].bookmarkData == nil,
               let refreshed = bookmarkData(for: URL(fileURLWithPath: expanded)) {
                scanLocationConfiguration.customDirectories[existingIndex] = CustomScanDirectory(
                    id: scanLocationConfiguration.customDirectories[existingIndex].id,
                    path: expanded,
                    bookmarkData: refreshed
                )
                persistScanLocations()
                requestLocationRefresh()
            }
            scanRootAccessWarning = nil
            return
        }

        let bookmarkData = bookmarkData(for: URL(fileURLWithPath: expanded))
        let provisionalEntry = CustomScanDirectory(path: expanded, bookmarkData: bookmarkData)
        let entry = CustomScanDirectory(
            path: ScanLocationProvider.canonicalExistingFilePath(resolvedURL(for: provisionalEntry)?.path ?? expanded),
            bookmarkData: bookmarkData
        )
        scanLocationConfiguration.customDirectories.append(entry)
        scanRootAccessWarning = nil
        persistScanLocations()
        requestLocationRefresh()
    }

    func removeCustomPath(_ path: String) {
        let normalized = ScanLocationProvider.canonicalExistingFilePath(path)
        scanLocationConfiguration.customDirectories.removeAll { $0.path == normalized }
        persistScanLocations()
        requestLocationRefresh()
    }

    private func requestLocationRefresh() {
        submitScanRequest(
            forceRepositoryDiscovery: true,
            source: .configuration,
            coalescingNanoseconds: Self.refreshCoalescingNanoseconds
        )
    }

    private func normalizeConfig(_ config: ScanConfig) -> ScanConfig {
        var normalized = config
        let existingRoots = config.customPaths
            .map(ScanLocationProvider.normalizePersistedPath)
            .filter { isAccessibleScanRoot($0) && !isAppContainerPath($0) && !ScanLocationProvider.isBuiltInPath($0) }
        let enabledBuiltIns = config.enabledBuiltInPaths
            .map(ScanLocationProvider.normalizePersistedPath)
            .filter(ScanLocationProvider.isBuiltInPath)
        normalized.enabledBuiltInPaths = Set(enabledBuiltIns)
        normalized.customPaths = Array(Set(existingRoots)).sorted()
        return normalized
    }

    private func defaultScanConfig() -> ScanConfig {
        var defaultConfig = ScanConfig.default
        defaultConfig.enabledBuiltInPaths = ScanLocationProvider.builtInAbsoluteSet
        return defaultConfig
    }

    private func scanConfigForExecution() -> ScanConfig {
        var executionConfig = config
        executionConfig.enabledBuiltInPaths = scanLocationConfiguration.enabledBuiltInPaths
        executionConfig.customPaths = scanLocationConfiguration.customDirectories.map(\.path)
        return executionConfig
    }

    private func sanitizeScanDirectories(_ directories: [CustomScanDirectory]) -> [CustomScanDirectory] {
        var sanitized: [CustomScanDirectory] = []
        var inaccessibleCount = 0
        var containerCount = 0

        for directory in directories {
            let normalizedPath = ScanLocationProvider.canonicalExistingFilePath(resolvedURL(for: directory)?.path ?? directory.path)
            if isAppContainerPath(normalizedPath) {
                containerCount += 1
            } else {
                let accessible = isAccessibleScanRoot(normalizedPath)
                if !accessible { inaccessibleCount += 1 }
                let bookmarkData = directory.bookmarkData
                    ?? (accessible ? bookmarkData(for: URL(fileURLWithPath: normalizedPath)) : nil)
                sanitized.append(CustomScanDirectory(id: directory.id, path: normalizedPath, bookmarkData: bookmarkData))
            }
        }

        if containerCount > 0 {
            scanRootAccessWarning = "检测到旧的沙盒容器路径，已自动忽略。请确认扫描目录仍指向你的真实仓库根目录。"
        } else if inaccessibleCount > 0 {
            scanRootAccessWarning = "部分目录权限失效，请在 Settings 重新授权。"
        }

        return Array(Dictionary(grouping: sanitized, by: \.path).values.compactMap { $0.first })
            .sorted { $0.path < $1.path }
    }

    private func resolvedURL(for directory: CustomScanDirectory) -> URL? {
        if let bookmarkData = directory.bookmarkData {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else {
                return nil
            }
            let resolvedPath = ScanLocationProvider.canonicalExistingFilePath(url.path)
            if stale || resolvedPath != RepositoryIdentity.canonicalPath(directory.path) {
                let refreshed = self.bookmarkData(for: url) ?? bookmarkData
                updateBookmark(
                    for: directory.path,
                    resolvedPath: resolvedPath,
                    with: refreshed
                )
            }
            return url
        }

        return FileManager.default.fileExists(atPath: directory.path) ? URL(fileURLWithPath: directory.path) : nil
    }

    private func isAccessibleScanRoot(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        return true
    }


    private func bookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func updateBookmark(for path: String, resolvedPath: String, with data: Data) {
        let normalized = ScanLocationProvider.normalizePersistedPath(path)
        guard let index = scanLocationConfiguration.customDirectories.firstIndex(where: { $0.path == normalized }) else { return }
        scanLocationConfiguration.customDirectories[index] = CustomScanDirectory(
            id: scanLocationConfiguration.customDirectories[index].id,
            path: RepositoryIdentity.canonicalPath(resolvedPath),
            bookmarkData: data
        )
        scanLocationConfiguration.customDirectories = sanitizeScanDirectories(
            scanLocationConfiguration.customDirectories
        )
        persistScanLocations()
    }

    private func isAppContainerPath(_ path: String) -> Bool {
        ScanLocationProvider.isLikelySandboxContainerPath(path)
    }

    private var shouldRunImmediateStartupScan: Bool {
        if requiresStartupScopeRefresh { return true }
        guard refreshPhase != .failure, refreshPhase != .degraded else { return true }
        guard !lastResult.repositories.isEmpty else { return true }

        switch RefreshStatusFormatter.freshness(for: lastSuccessfulRefreshAt) {
        case .fresh:
            return false
        case .stale, .expired, .unknown:
            return true
        }
    }

    private var lastRepositoryDiscoveryAt: Date? {
        get {
            UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
                .object(forKey: lastRepositoryDiscoveryAtKey) as? Date
        }
        set {
            UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
                .set(newValue, forKey: lastRepositoryDiscoveryAtKey)
        }
    }

    private var lastDiscoveredRepositoryPaths: [String] {
        get {
            let defaults = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)
            let raw = defaults?.stringArray(forKey: lastDiscoveredRepositoryPathsKey) ?? []
            let normalized = Array(Set(raw.map(RepositoryIdentity.canonicalPath)))
                .filter { !ignoredRepositoryPaths.contains($0) }
                .sorted()
            if normalized != raw {
                defaults?.set(normalized, forKey: lastDiscoveredRepositoryPathsKey)
            }
            return normalized
        }
        set {
            let normalized = Array(Set(newValue.map(RepositoryIdentity.canonicalPath)))
                .filter { !ignoredRepositoryPaths.contains($0) }
                .sorted()
            UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
                .set(normalized, forKey: lastDiscoveredRepositoryPathsKey)
        }
    }

    private var lastRepositoryDiscoveryScanRootsSignature: String? {
        get {
            UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
                .string(forKey: lastRepositoryDiscoveryScanRootsKey)
        }
        set {
            UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
                .set(newValue, forKey: lastRepositoryDiscoveryScanRootsKey)
        }
    }

    private func suggestedNextSteps(from issues: [String]) -> [String] {
        if issues.isEmpty {
            if diagnostics.scanRoots.isEmpty {
                return ["在 Settings 添加至少一个真实的仓库根目录，然后执行 Rescan。"]
            }
            return ["当前链路看起来正常；如果 Widget 未立即变化，等待 macOS 刷新时间线或手动重新添加 Widget。"]
        }

        var steps: [String] = []

        if issues.contains(where: { $0.contains("沙盒容器路径") }) {
            steps.append("把扫描目录从 DevPulse 容器路径改回 `/Users/...` 下的真实目录。")
        }
        if issues.contains(where: { $0.contains("权限") || $0.contains("unavailable") }) {
            steps.append("在 Settings 重新选择扫描目录，确认目录可读且 App Group entitlement 生效。")
        }
        if issues.contains(where: { $0.contains("快照") || $0.contains("snapshot") }) {
            steps.append("先执行一次 Rescan，再检查 Diagnostics 里的 shared write、widget snapshot 和 reload requested。")
        }
        if issues.contains(where: { $0.contains("decode") || $0.contains("schema") }) {
            steps.append("删除损坏的共享快照后重新扫描，确认 App 与 Widget 使用同一份 schema。")
        }

        if steps.isEmpty {
            steps.append("根据 Diagnostics 的失败项重新执行一次 Rescan，并核对扫描目录、App Group 和共享快照文件路径。")
        }

        return steps
    }

    private func makeSelfCheckReport() -> ScanSelfCheckReport {
        ScanSelfCheckReport(
            success: refreshPhase == .success
                && diagnostics.validationIssues.isEmpty
                && diagnostics.sharedDataWriteError == nil
                && diagnostics.sharedDataReadError == nil
                && diagnostics.widgetSnapshotReadError == nil,
            refreshPhase: refreshPhase,
            snapshotStoreState: diagnostics.lastSnapshotStoreState,
            widgetReloadState: diagnostics.lastWidgetReloadState,
            generatedAt: diagnostics.lastGeneratedAt,
            writtenAt: diagnostics.lastWrittenAt,
            reloadRequestedAt: diagnostics.lastReloadRequestedAt,
            sharedReadError: diagnostics.sharedDataReadError,
            sharedWriteError: diagnostics.sharedDataWriteError,
            widgetSnapshotReadError: diagnostics.widgetSnapshotReadError,
            validationIssues: diagnostics.validationIssues,
            repositoryCount: lastResult.repositories.count,
            scanMetrics: lastScanMetrics
        )
    }
}

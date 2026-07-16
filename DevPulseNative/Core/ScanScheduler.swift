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

struct ScanExecutionRequest: Sendable {
    let config: ScanConfig
    let roots: [String]
    let rootsSignature: String
    let knownRepositoryPaths: [String]
    let forceRepositoryDiscovery: Bool
    let previousSnapshot: AppGroupData?

    init(config: ScanConfig,
         roots: [String],
         rootsSignature: String,
         knownRepositoryPaths: [String],
         forceRepositoryDiscovery: Bool,
         previousSnapshot: AppGroupData? = nil) {
        self.config = config
        self.roots = roots
        self.rootsSignature = rootsSignature
        self.knownRepositoryPaths = knownRepositoryPaths
        self.forceRepositoryDiscovery = forceRepositoryDiscovery
        self.previousSnapshot = previousSnapshot
    }
}
typealias ScanExecution = @Sendable (ScanExecutionRequest) async -> (data: AppGroupData, warnings: [String], discoveredRepositoryPaths: [String])


/// Coalesces scan refresh requests without retaining UI or scanner state.
struct ScanRefreshCoordinator {
    struct Request: Equatable {
        let signature: String
        let forceRepositoryDiscovery: Bool
    }

    private var scheduled: Request?
    private var running: Request?

    @discardableResult
    mutating func request(signature: String, forceRepositoryDiscovery: Bool) -> Bool {
        if let running, signature == running.signature {
            scheduled = nil
            return false
        }

        if var scheduled {
            scheduled = Request(
                signature: signature,
                forceRepositoryDiscovery: scheduled.forceRepositoryDiscovery || forceRepositoryDiscovery
            )
            self.scheduled = scheduled
            return true
        }

        guard let running else {
            scheduled = Request(signature: signature, forceRepositoryDiscovery: forceRepositoryDiscovery)
            return true
        }

        guard signature != running.signature else {
            scheduled = nil
            return false
        }

        scheduled = Request(signature: signature, forceRepositoryDiscovery: forceRepositoryDiscovery)
        return true
    }

    @discardableResult
    mutating func requestForced(signature: String) -> Bool {
        if let running, running.signature == signature {
            scheduled = Request(signature: signature, forceRepositoryDiscovery: true)
            return true
        }
        return request(signature: signature, forceRepositoryDiscovery: true)
    }

    mutating func beginNext() -> Request? {
        guard running == nil, let scheduled else { return nil }
        self.scheduled = nil
        running = scheduled
        return scheduled
    }

    mutating func completeCurrent() -> Request? {
        running = nil
        return scheduled
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

    static func scanRootsSignature(_ scanRoots: [String]) -> String {
        scanRoots
            .map(ScanLocationProvider.expandTilde)
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

        guard let lastReloadRequestedAt else {
            return WidgetReloadDecision(
                shouldRequest: true,
                detail: "还没有记录过 Widget reload，已补发第一次请求。"
            )
        }

        if now.timeIntervalSince(lastReloadRequestedAt) >= widgetReloadThrottleInterval {
            return WidgetReloadDecision(
                shouldRequest: true,
                detail: "共享快照无实质变化，但距上次 reload 已超过 15 分钟，已重新请求 Widget reload。"
            )
        }

        return WidgetReloadDecision(
            shouldRequest: false,
            detail: "共享快照无实质变化，且距上次 reload 未超过 15 分钟，本次跳过 Widget reload。"
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
    @Published var scanIntervalSeconds: TimeInterval = 300
    @Published var powerState: String = "normal"

    private var backgroundTimer: Timer?
    private var consecutiveNoChanges = 0
    private var backgroundScanningEnabled = false
    private var powerStateObserver: NSObjectProtocol?
    private var workspaceSleepObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var lastSystemSleepAt: Date?
    private var refreshCoordinator = ScanRefreshCoordinator()
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var locationRefreshDrainScheduled = false
    private let scanExecution: ScanExecution
    private let activityEventStore: ActivityEventStore?
    private var configLoadedFromPersistence = false

    // Config persistence
    private let configKey = "scan_config_json"
    private let scanDirectoriesKey = "scan_directories_json"
    private let scanLocationsKey = "scan_locations_v1_json"
    private let pinnedKey = "pinned_repo_ids"
    private let lastScanIntervalKey = "last_scan_interval"
    private let lastRepositoryDiscoveryAtKey = "last_repository_discovery_at"
    private let lastDiscoveredRepositoryPathsKey = "last_discovered_repository_paths"
    private let lastRepositoryDiscoveryScanRootsKey = "last_repository_discovery_scan_roots"

    // MARK: - Adaptive interval constants

    private static let baseInterval: TimeInterval = 300       // 5 min
    private static let extendedInterval1: TimeInterval = 600  // 10 min
    private static let extendedInterval2: TimeInterval = 1200 // 20 min
    private static let maxInterval: TimeInterval = 1800       // 30 min
    private static let lowPowerBaseInterval: TimeInterval = 900 // 15 min
    private static let noChangeThreshold1 = 3  // scans w/o change → 10 min
    private static let noChangeThreshold2 = 8  // scans w/o change → 20 min
    private static let noChangeThreshold3 = 15 // scans w/o change → 30 min

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

    init(commandMode: Bool = false,
         activityEventStore: ActivityEventStore? = nil,
         scanExecution: @escaping ScanExecution = { request in
        await GitRepositoryScanner.scan(
            config: request.config,
            scanRoots: request.roots,
            knownRepositoryPaths: request.knownRepositoryPaths,
            forceRepositoryDiscovery: request.forceRepositoryDiscovery,
            previousSnapshot: request.previousSnapshot
        )
    }) {
        self.scanExecution = scanExecution
        self.activityEventStore = commandMode ? nil : activityEventStore
        if commandMode {
            appGroupAvailable = AppGroupStore.isAvailable
            gitAvailable = ProcessRunner.isGitAvailable()
            updatePowerState()
            return
        }

        loadConfig()
        loadScanDirectories()
        syncStoreInspection()
        appGroupAvailable = AppGroupStore.isAvailable
        gitAvailable = ProcessRunner.isGitAvailable()
        restorePersistedSnapshot()
        restoreActivityEvents()
        updatePowerState()
        startPowerMonitoring()
        startSleepWakeMonitoring()
    }

    deinit {
        scanTask?.cancel()
    }

    var snapshotFreshness: SnapshotFreshness? {
        RefreshStatusFormatter.freshness(for: lastScanAt)
    }

    var refreshTrustAssessment: SnapshotTrustAssessment {
        RefreshStatusFormatter.refreshAssessment(
            lastUpdatedAt: lastScanAt,
            failureMessage: refreshPhase == .failure ? refreshFailureMessage : nil
        )
    }

    var refreshStatusText: String {
        switch refreshPhase {
        case .refreshing:
            return "刷新中…"
        case .failure, .idle, .success:
            return refreshTrustAssessment.title
        }
    }

    var refreshDetailText: String? {
        switch refreshPhase {
        case .refreshing:
            if let lastScanAt {
                return "上次成功刷新：\(RefreshStatusFormatter.updateLabel(for: lastScanAt))"
            }
            return nil
        case .failure, .idle, .success:
            return refreshTrustAssessment.state == .fresh ? nil : refreshTrustAssessment.detail
        }
    }

    // MARK: - Scan (async, non-blocking)

    func scanNow(forceRepositoryDiscovery: Bool = false) {
        let signature = ScanSchedulerPolicy.scanRootsSignature(scanRoots().roots)
        let queued: Bool
        if forceRepositoryDiscovery {
            queued = refreshCoordinator.requestForced(signature: signature)
        } else {
            queued = refreshCoordinator.request(signature: signature, forceRepositoryDiscovery: false)
        }
        if queued, isScanning {
            // A newer roots/configuration request supersedes the current scan.
            // The scanner propagates cancellation into its Git processes, so
            // the old run stops before the queued request starts.
            scanTask?.cancel()
        }
        startNextCoalescedScanIfNeeded()
    }

    private func startNextCoalescedScanIfNeeded() {
        guard let request = refreshCoordinator.beginNext() else { return }
        performScanNow(request: request)
    }

    private func performScanNow(request: ScanRefreshCoordinator.Request) {
        guard !isScanning else { return }

        gitAvailable = ProcessRunner.isGitAvailable()
        guard gitAvailable else {
            failRefresh("Git 不可用", persistRepositoryTrustFailure: true)
            _ = refreshCoordinator.completeCurrent()
            startNextCoalescedScanIfNeeded()
            return
        }

        isScanning = true
        diagnostics.lastRefreshStartedAt = Date()
        diagnostics.lastRefreshCompletedAt = nil
        refreshPhase = .refreshing
        refreshFailureMessage = nil
        warnings = []
        diagnostics.validationIssues = []
        diagnostics.sharedDataWriteError = nil
        diagnostics.sharedDataReadError = nil
        diagnostics.widgetSnapshotReadError = nil
        diagnostics.snapshotDecodable = false
        let currentConfig = scanConfigForExecution()
        let currentScanRoots = scanRoots()
        let knownRepositoryPaths = lastDiscoveredRepositoryPaths
        let currentScanRootsSignature = ScanSchedulerPolicy.scanRootsSignature(currentScanRoots.roots)
        let shouldRediscoverRepositories = ScanSchedulerPolicy.shouldRediscoverRepositories(
            forceRepositoryDiscovery: request.forceRepositoryDiscovery,
            knownRepositoryPaths: knownRepositoryPaths,
            lastRepositoryDiscoveryAt: lastRepositoryDiscoveryAt,
            currentScanRootsSignature: currentScanRootsSignature,
            lastScanRootsSignature: lastRepositoryDiscoveryScanRootsSignature
        )
        recordEvent(.scanStarted, "Scan started")

        let execution = scanExecution
        let executionRequest = ScanExecutionRequest(
            config: currentConfig,
            roots: currentScanRoots.roots,
            rootsSignature: currentScanRootsSignature,
            knownRepositoryPaths: knownRepositoryPaths,
            forceRepositoryDiscovery: shouldRediscoverRepositories,
            previousSnapshot: lastResult
        )
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await execution(executionRequest)
            let wasCancelled = Task.isCancelled

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.scanGeneration == generation else { return }
                self.scanTask = nil

                if wasCancelled {
                    self.isScanning = false
                    self.refreshPhase = .idle
                    self.refreshFailureMessage = nil
                    self.recordEvent(.scanFailed, "Scan cancelled by a newer refresh request")
                    self.triggerPendingWakeRefreshIfNeeded()
                    return
                }

                if let failureMessage = self.scanFailureMessage(
                    for: result.data,
                    scanRoots: currentScanRoots
                ) {
                    let combinedWarnings = self.summarizeWarnings(
                        result.warnings,
                        accessWarning: currentScanRoots.warning
                    )

                    self.isScanning = false
                    self.refreshPhase = .failure
                    self.refreshFailureMessage = failureMessage
                    self.scanRootAccessWarning = currentScanRoots.warning
                    self.warnings = [failureMessage] + combinedWarnings.filter { $0 != failureMessage }
                    self.diagnostics.validationIssues = self.warnings
                    self.recordEvent(.scanFailed, failureMessage)

                    self.persistRepositoryTrustFailure(
                        failureMessage,
                        fallbackSnapshot: result.data
                    )
                    self.triggerPendingWakeRefreshIfNeeded()
                    return
                }

                let previousSnapshot = self.lastResult
                let pinned = self.applyPins(result.data)
                let combinedWarnings = self.summarizeWarnings(
                    result.warnings,
                    accessWarning: currentScanRoots.warning
                )
                self.warnings = combinedWarnings
                let recorded = self.recordActivityEvents(
                    previous: previousSnapshot,
                    current: pinned,
                    observedAt: pinned.generatedAt
                )
                let hadChanges = self.hadChanges(before: previousSnapshot, after: recorded)

                self.lastResult = recorded
                self.lastScanAt = DateFormatting.date(from: recorded.generatedAt) ?? Date()
                self.diagnostics.lastScanAt = self.lastScanAt
                self.isScanning = false
                self.refreshPhase = .success
                self.refreshFailureMessage = nil
                self.scanRootAccessWarning = currentScanRoots.warning
                self.diagnostics.validationIssues = self.warnings
                self.lastDiscoveredRepositoryPaths = result.discoveredRepositoryPaths
                if shouldRediscoverRepositories {
                    self.lastRepositoryDiscoveryAt = Date()
                    self.lastRepositoryDiscoveryScanRootsSignature = currentScanRootsSignature
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

                // Adaptive interval
                if hadChanges {
                    self.consecutiveNoChanges = 0
                } else {
                    self.consecutiveNoChanges += 1
                }
                self.updateScanInterval()
                self.syncSharedSnapshot(from: recorded, previousSnapshot: previousSnapshot, reason: "scan")
                self.triggerPendingWakeRefreshIfNeeded()
            }
        }
    }

    func rescan() {
        // Reset adaptive state so user gets a fresh full scan
        consecutiveNoChanges = 0
        updateScanInterval()
        scanNow(forceRepositoryDiscovery: true)
    }

    func runSelfCheck() async -> ScanSelfCheckReport {
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
        warnings = []

        let currentConfig = scanConfigForExecution()
        let currentScanRoots = scanRoots()
        let result = await GitRepositoryScanner.scan(
            config: currentConfig,
            scanRoots: currentScanRoots.roots,
            knownRepositoryPaths: nil,
            forceRepositoryDiscovery: true
        )

        if let failureMessage = scanFailureMessage(
            for: result.data,
            scanRoots: currentScanRoots
        ) {
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
            persistRepositoryTrustFailure(
                failureMessage,
                fallbackSnapshot: result.data
            )
            return makeSelfCheckReport()
        }

        let previousSnapshot = lastResult
        let pinned = applyPins(result.data)
        let combinedWarnings = summarizeWarnings(
            result.warnings,
            accessWarning: currentScanRoots.warning
        )
        warnings = combinedWarnings
        let recorded = recordActivityEvents(
            previous: previousSnapshot,
            current: pinned,
            observedAt: pinned.generatedAt
        )

        lastResult = recorded
        lastScanAt = DateFormatting.date(from: recorded.generatedAt) ?? Date()
        diagnostics.lastScanAt = lastScanAt
        isScanning = false
        refreshPhase = .success
        refreshFailureMessage = nil
        scanRootAccessWarning = currentScanRoots.warning
        diagnostics.validationIssues = warnings

        syncSharedSnapshot(from: recorded, previousSnapshot: previousSnapshot, reason: "self-check")
        recordEvent(.scanSucceeded, "Self-check refreshed \(recorded.scanSummary.totalRepositories) repos")

        return makeSelfCheckReport()
    }

    // MARK: - Background scheduling

    func startBackgroundScanning() {
        stopBackgroundScanning()
        backgroundScanningEnabled = true
        let decision = ScanSchedulerPolicy.startupRefreshDecision(
            snapshotIsFresh: !shouldRunImmediateStartupScan,
            currentRootsSignature: ScanSchedulerPolicy.scanRootsSignature(scanRoots().roots),
            lastDiscoveryRootsSignature: lastRepositoryDiscoveryScanRootsSignature
        )
        if decision.shouldRefreshImmediately {
            scanNow(forceRepositoryDiscovery: decision.forceRepositoryDiscovery)
        }
        scheduleNextTimer()
    }

    func stopBackgroundScanning() {
        backgroundScanningEnabled = false
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    private func scheduleNextTimer() {
        guard backgroundScanningEnabled else { return }
        backgroundTimer?.invalidate()
        backgroundTimer = Timer.scheduledTimer(
            withTimeInterval: scanIntervalSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scanNow()
                self?.scheduleNextTimer()
            }
        }
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

        // Power-aware floor
        let floor: TimeInterval = powerState != "normal"
            ? Self.lowPowerBaseInterval
            : Self.baseInterval

        scanIntervalSeconds = max(newInterval, floor)
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

    private func scanRoots() -> (roots: [String], warning: String?) {
        let enabledBuiltInRoots = ScanLocationProvider.builtInLocations
            .map(ScanLocationProvider.expandTilde)
            .filter { scanLocationConfiguration.enabledBuiltInPaths.contains($0) }
            .filter { isAccessibleScanRoot($0) && !isAppContainerPath($0) }
        let configuredDirectories = scanLocationConfiguration.customDirectories

        var accessibleRoots = enabledBuiltInRoots
        var inaccessibleCount = 0
        var containerPathCount = 0

        for directory in configuredDirectories {
            if let url = resolvedURL(for: directory) {
                let path = ScanLocationProvider.canonicalExistingFilePath(url.path)
                guard !isAppContainerPath(path) else {
                    containerPathCount += 1
                    continue
                }
                guard isAccessibleScanRoot(path) else {
                    inaccessibleCount += 1
                    continue
                }
                accessibleRoots.append(path)
                continue
            }

            let normalizedPath = ScanLocationProvider.canonicalExistingFilePath(directory.path)
            guard !isAppContainerPath(normalizedPath) else {
                containerPathCount += 1
                continue
            }
            guard isAccessibleScanRoot(normalizedPath) else {
                inaccessibleCount += 1
                continue
            }

            accessibleRoots.append(normalizedPath)
        }

        let deduped = Array(Set(accessibleRoots)).sorted()
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
            activityEvents = result.events
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
        let newEvents = ActivityEventDeduplicator.newEvents(
            from: detected,
            comparedTo: activityEvents
        )
        let merger = activityEventStore
            ?? ActivityEventStore(fileURL: URL(fileURLWithPath: "/dev/null"))
        let merged = merger.merging(existing: activityEvents, newEvents: newEvents)

        if let activityEventStore {
            switch activityEventStore.save(merged) {
            case .success(let saved):
                activityEvents = saved
            case .failure(let error):
                activityEvents = merged
                if !warnings.contains(error.localizedDescription) {
                    warnings.append(error.localizedDescription)
                }
            }
        } else {
            activityEvents = merged
        }

        let now = DateFormatting.date(from: observedAt) ?? Date()
        return current.withRecentActivityEvents(
            ActivityEventWidgetSummaryBuilder.build(from: activityEvents, now: now)
        )
    }

    private func restorePersistedSnapshot() {
        syncStoreInspection()
        switch AppGroupStore.read() {
        case .success(let snapshot):
            let migration = RepositoryIdentityMigration.migrate(
                snapshot: snapshot,
                pinnedIDs: pinnedRepoIDs
            )
            if migration.pinnedIDs != pinnedRepoIDs {
                pinnedRepoIDs = migration.pinnedIDs
            }

            let migratedPinnedSnapshot = applyPins(migration.snapshot)
            var restoredSnapshot = migration.snapshot
            if migration.changed {
                let written = migratedPinnedSnapshot.withWrittenAt(
                    snapshot.writtenAt ?? DateFormatting.nowISO()
                )
                if case .success(let verified) = AppGroupStore.write(written) {
                    restoredSnapshot = verified
                }
            }

            let pinned = applyPins(restoredSnapshot)
            lastResult = pinned
            diagnostics.lastSnapshotStoreTrigger = "startup"
            diagnostics.lastSnapshotStoreState = .restored
            diagnostics.lastSnapshotStoreDetail = "启动时已恢复 \(restoredSnapshot.repositories.count) 个仓库的共享快照。"
            diagnostics.sharedDataSnapshot = restoredSnapshot
            diagnostics.snapshotDecodable = true
            let now = Date()
            diagnostics.sharedDataReadAt = now
            diagnostics.sharedDataReadError = nil
            diagnostics.lastGeneratedAt = restoredSnapshot.generatedAt
            diagnostics.lastWrittenAt = restoredSnapshot.writtenAt
            if let writtenAt = restoredSnapshot.writtenAt.flatMap(DateFormatting.date(from:)) {
                diagnostics.lastSharedWriteAt = writtenAt
            }
            let hasSuccessfulRepositoryData = pinned.repositories.contains {
                $0.resolvedLastSuccessfulScanAt != nil
            }
            if (pinned.repositories.isEmpty || hasSuccessfulRepositoryData),
               let generatedAt = DateFormatting.date(from: restoredSnapshot.generatedAt) {
                lastScanAt = generatedAt
                diagnostics.lastScanAt = generatedAt
            }
            let retainedOnly = ScanSchedulerPolicy.allRepositoryDataUnavailable(pinned.repositories)
            if retainedOnly {
                let message = "上次扫描未能刷新仓库，当前显示上次成功或未知数据"
                refreshPhase = .failure
                refreshFailureMessage = message
                warnings = [message]
            } else {
                refreshPhase = .idle
                refreshFailureMessage = nil
                warnings = []
            }
            setWidgetReadableSnapshot(restoredSnapshot, readAt: now)
            validateConsistency(expected: pinned, shared: restoredSnapshot, widget: diagnostics.widgetSnapshot, reason: "startup")
        case .failure(.snapshotMissing):
            diagnostics.snapshotDecodable = false
            diagnostics.sharedDataSnapshot = nil
            diagnostics.widgetSnapshot = nil
            diagnostics.sharedDataReadError = nil
            diagnostics.widgetSnapshotReadError = nil
            diagnostics.validationIssues = []
            refreshPhase = .idle
            refreshFailureMessage = nil
            warnings = []
        case .failure(let error):
            diagnostics.snapshotDecodable = false
            diagnostics.sharedDataReadError = error.localizedDescription
            diagnostics.widgetSnapshotReadError = error.localizedDescription
            diagnostics.validationIssues = [error.localizedDescription]
            refreshPhase = .failure
            refreshFailureMessage = "读取共享快照失败"
            recordEvent(.sharedDataReadFailed, "Shared snapshot read failed at startup: \(error.localizedDescription)")
        }
    }

    private func syncSharedSnapshot(
        from snapshot: AppGroupData,
        previousSnapshot: AppGroupData? = nil,
        reason: String
    ) {
        let writtenAt = DateFormatting.nowISO()
        let snapshotToWrite = snapshot.withWrittenAt(writtenAt)
        let previousSnapshot = previousSnapshot ?? lastResult
        var verifiedSnapshot: AppGroupData?
        diagnostics.lastSnapshotStoreTrigger = reason
        diagnostics.lastSnapshotStoreState = .idle
        diagnostics.lastSnapshotStoreDetail = "正在把 \(snapshotToWrite.repositories.count) 个仓库写入共享快照。"

        switch AppGroupStore.write(snapshotToWrite) {
        case .success(let readBack):
            let now = Date()
            syncStoreInspection()
            appGroupAvailable = AppGroupStore.isAvailable
            diagnostics.lastRefreshCompletedAt = now
            diagnostics.lastSharedWriteAt = now
            diagnostics.lastGeneratedAt = readBack.generatedAt
            diagnostics.lastWrittenAt = readBack.writtenAt
            diagnostics.sharedDataWriteError = nil
            diagnostics.snapshotDecodable = true
            diagnostics.lastSnapshotStoreState = .verified
            diagnostics.lastSnapshotStoreDetail = "已写入并读回校验成功：\(readBack.repositories.count) 个仓库，reason=\(reason)。"
            verifiedSnapshot = readBack
            recordEvent(
                .sharedDataWritten,
                "Shared snapshot written (\(snapshotToWrite.repositories.count) repos, \(reason))"
            )
        case .failure(let error):
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
            return
        }

        guard let verifiedSnapshot else {
            diagnostics.lastRefreshCompletedAt = Date()
            diagnostics.sharedDataWriteError = "Shared snapshot verification failed without a decoded payload."
            diagnostics.validationIssues = [diagnostics.sharedDataWriteError ?? "Verification failed."]
            diagnostics.lastSnapshotStoreState = .failed
            diagnostics.lastSnapshotStoreDetail = diagnostics.sharedDataWriteError
            diagnostics.lastWidgetReloadState = .idle
            diagnostics.lastWidgetReloadDetail = "共享快照校验失败，本次没有进入 Widget reload 判断。"
            markSharedSnapshotSyncFailure(diagnostics.sharedDataWriteError ?? "Verification failed.")
            recordEvent(.sharedDataWriteFailed, "Shared snapshot verification failed unexpectedly.")
            return
        }

        diagnostics.sharedDataReadAt = Date()
        diagnostics.sharedDataSnapshot = verifiedSnapshot
        diagnostics.sharedDataReadError = nil
        setWidgetReadableSnapshot(verifiedSnapshot, readAt: diagnostics.sharedDataReadAt ?? Date())
        validateConsistency(expected: snapshotToWrite, shared: verifiedSnapshot, widget: diagnostics.widgetSnapshot, reason: reason)
        lastResult = applyPins(verifiedSnapshot)
        let reloadDecision = ScanSchedulerPolicy.widgetReloadDecision(
            previousSnapshot: previousSnapshot,
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
    }

    private func markSharedSnapshotSyncFailure(_ reason: String) {
        let message = "扫描已完成，但 Widget 数据同步失败"
        refreshPhase = .failure
        refreshFailureMessage = message
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
        diagnostics.widgetSnapshot = snapshot
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
        } else if let widget, widget != shared {
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
            summarized.append(warning)
        }

        if sawRootUnavailable, let accessWarning, !summarized.contains(accessWarning) {
            summarized.append(accessWarning)
        }

        return summarized
    }

    private func scanFailureMessage(for data: AppGroupData,
                                    scanRoots: (roots: [String], warning: String?)) -> String? {
        if scanRoots.roots.isEmpty {
            return scanRoots.warning ?? "刷新失败，无法访问扫描目录"
        }

        if !lastResult.repositories.isEmpty,
           data.repositories.isEmpty,
           let warning = scanRoots.warning {
            return warning
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
        let failureBasis = previousSnapshot.repositories.isEmpty
            ? fallbackSnapshot
            : previousSnapshot
        guard let failureBasis, !failureBasis.repositories.isEmpty else { return }

        let retained = failureBasis.retainingLastSuccessfulRepositories(
            attemptedAt: DateFormatting.nowISO(),
            errorMessage: message
        )
        let sortedRetained = AppGroupData(
            schemaVersion: retained.schemaVersion,
            generatedAt: retained.generatedAt,
            writtenAt: retained.writtenAt,
            scanSummary: retained.scanSummary,
            repositories: RepositorySorter.sort(retained.repositories),
            recentActivityEvents: retained.recentActivityEvents
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
        triggerPendingWakeRefreshIfNeeded()
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
            Task { @MainActor in
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
            Task { @MainActor in
                self?.handleSystemWillSleep()
            }
        }

        workspaceWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemDidWake()
            }
        }
    }

    private func handleSystemWillSleep(now: Date = Date()) {
        guard backgroundScanningEnabled else { return }
        lastSystemSleepAt = now
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    private func handleSystemDidWake(now: Date = Date()) {
        guard backgroundScanningEnabled else { return }

        updatePowerState()

        let decision = ScanSchedulerPolicy.wakeRefreshDecision(
            lastScanAt: lastScanAt,
            refreshPhase: refreshPhase,
            sleepBeganAt: lastSystemSleepAt,
            refreshStartedAt: diagnostics.lastRefreshStartedAt,
            refreshCompletedAt: diagnostics.lastRefreshCompletedAt,
            now: now
        )
        lastSystemSleepAt = nil

        if decision.shouldRefreshImmediately {
            requestWakeRefresh(forceRepositoryDiscovery: decision.forceRepositoryDiscovery)
        }

        scheduleNextTimer()
    }

    private func triggerPendingWakeRefreshIfNeeded() {
        _ = refreshCoordinator.completeCurrent()
        startNextCoalescedScanIfNeeded()
    }

    private func requestWakeRefresh(forceRepositoryDiscovery: Bool) {
        let signature = ScanSchedulerPolicy.scanRootsSignature(scanRoots().roots)
        let queued: Bool
        if forceRepositoryDiscovery {
            queued = refreshCoordinator.requestForced(signature: signature)
        } else {
            queued = refreshCoordinator.request(signature: signature, forceRepositoryDiscovery: false)
        }
        if queued, isScanning {
            scanTask?.cancel()
        }
        startNextCoalescedScanIfNeeded()
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
        let migration = RepositoryIdentityMigration.migrate(
            snapshot: data,
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
            scanSummary: migration.snapshot.scanSummary,
            repositories: repos,
            recentActivityEvents: migration.snapshot.recentActivityEvents
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
        let signature = ScanSchedulerPolicy.scanRootsSignature(scanRoots().roots)
        let queued = refreshCoordinator.request(signature: signature, forceRepositoryDiscovery: true)
        if queued, isScanning {
            scanTask?.cancel()
        }
        guard !locationRefreshDrainScheduled else { return }
        locationRefreshDrainScheduled = true
        Task { @MainActor in
            await Task.yield()
            self.locationRefreshDrainScheduled = false
            self.startNextCoalescedScanIfNeeded()
        }
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
            } else if isAccessibleScanRoot(normalizedPath) {
                let bookmarkData = directory.bookmarkData ?? bookmarkData(for: URL(fileURLWithPath: normalizedPath))
                sanitized.append(CustomScanDirectory(id: directory.id, path: normalizedPath, bookmarkData: bookmarkData))
            } else {
                inaccessibleCount += 1
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
            if stale, let refreshed = self.bookmarkData(for: url) {
                updateBookmark(for: directory.path, with: refreshed)
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

    private func updateBookmark(for path: String, with data: Data) {
        let normalized = ScanLocationProvider.normalizePersistedPath(path)
        guard let index = scanLocationConfiguration.customDirectories.firstIndex(where: { $0.path == normalized }) else { return }
        scanLocationConfiguration.customDirectories[index] = CustomScanDirectory(
            id: scanLocationConfiguration.customDirectories[index].id,
            path: normalized,
            bookmarkData: data
        )
        persistScanLocations()
    }

    private func isAppContainerPath(_ path: String) -> Bool {
        ScanLocationProvider.isLikelySandboxContainerPath(path)
    }

    private var shouldRunImmediateStartupScan: Bool {
        guard refreshPhase != .failure else { return true }
        guard !lastResult.repositories.isEmpty else { return true }

        switch RefreshStatusFormatter.freshness(for: lastScanAt) {
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
            UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
                .stringArray(forKey: lastDiscoveredRepositoryPathsKey) ?? []
        }
        set {
            UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
                .set(newValue, forKey: lastDiscoveredRepositoryPathsKey)
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
            repositoryCount: lastResult.repositories.count
        )
    }
}

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
    @Published var scanDirectories: [CustomScanDirectory] = []
    @Published var diagnostics = DiagnosticsSnapshot()
    @Published var diagnosticEvents: [DiagnosticEvent] = []
    @Published var scanIntervalSeconds: TimeInterval = 300
    @Published var powerState: String = "normal"

    private var backgroundTimer: Timer?
    private var consecutiveNoChanges = 0

    // Config persistence
    private let configKey = "scan_config_json"
    private let scanDirectoriesKey = "scan_directories_json"
    private let pinnedKey = "pinned_repo_ids"
    private let lastScanIntervalKey = "last_scan_interval"

    // MARK: - Adaptive interval constants

    private static let baseInterval: TimeInterval = 300       // 5 min
    private static let extendedInterval1: TimeInterval = 600  // 10 min
    private static let extendedInterval2: TimeInterval = 1200 // 20 min
    private static let maxInterval: TimeInterval = 1800       // 30 min
    private static let lowPowerBaseInterval: TimeInterval = 900 // 15 min
    private static let noChangeThreshold1 = 3  // scans w/o change → 10 min
    private static let noChangeThreshold2 = 8  // scans w/o change → 20 min
    private static let noChangeThreshold3 = 15 // scans w/o change → 30 min

    @Published var config: ScanConfig = .default {
        didSet { persistConfig() }
    }

    var pinnedRepoIDs: Set<String> {
        get {
            let raw = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
                .stringArray(forKey: pinnedKey) ?? []
            return Set(raw)
        }
        set {
            UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
                .set(Array(newValue), forKey: pinnedKey)
        }
    }

    init(commandMode: Bool = false) {
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
        updatePowerState()
        startPowerMonitoring()
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

    func scanNow() {
        guard !isScanning else { return }

        gitAvailable = ProcessRunner.isGitAvailable()
        guard gitAvailable else {
            failRefresh("Git 不可用")
            return
        }

        isScanning = true
        refreshPhase = .refreshing
        refreshFailureMessage = nil
        warnings = []
        diagnostics.validationIssues = []
        diagnostics.sharedDataWriteError = nil
        diagnostics.sharedDataReadError = nil
        diagnostics.widgetSnapshotReadError = nil
        diagnostics.snapshotDecodable = false
        let currentConfig = config
        let currentScanRoots = scanRoots()
        recordEvent(.scanStarted, "Scan started")

        Task.detached(priority: .userInitiated) {
            let result = await GitRepositoryScanner.scan(config: currentConfig, scanRoots: currentScanRoots.roots)

            await MainActor.run {
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
                    return
                }

                let pinned = self.applyPins(result.data)
                let hadChanges = self.hadChanges(before: self.lastResult, after: pinned)
                let combinedWarnings = self.summarizeWarnings(
                    result.warnings,
                    accessWarning: currentScanRoots.warning
                )

                self.lastResult = pinned
                self.lastScanAt = DateFormatting.date(from: pinned.generatedAt) ?? Date()
                self.diagnostics.lastScanAt = self.lastScanAt
                self.warnings = combinedWarnings
                self.isScanning = false
                self.refreshPhase = .success
                self.refreshFailureMessage = nil
                self.scanRootAccessWarning = currentScanRoots.warning
                self.diagnostics.validationIssues = combinedWarnings.isEmpty ? [] : combinedWarnings

                if combinedWarnings.isEmpty {
                    self.recordEvent(
                        .scanSucceeded,
                        "Scan success: \(pinned.scanSummary.totalRepositories) repos, \(pinned.scanSummary.changedRepositories) changed, \(pinned.scanSummary.totalChangedFiles) files"
                    )
                } else {
                    self.recordEvent(
                        .scanSucceeded,
                        "Scan success with \(combinedWarnings.count) warning(s): \(pinned.scanSummary.totalRepositories) repos"
                    )
                }

                // Adaptive interval
                if hadChanges {
                    self.consecutiveNoChanges = 0
                } else {
                    self.consecutiveNoChanges += 1
                }
                self.updateScanInterval()
                self.syncSharedSnapshot(from: pinned, reason: "scan")
            }
        }
    }

    func rescan() {
        // Reset adaptive state so user gets a fresh full scan
        consecutiveNoChanges = 0
        updateScanInterval()
        scanNow()
    }

    // MARK: - Background scheduling

    func startBackgroundScanning() {
        stopBackgroundScanning()
        scanNow()
        scheduleNextTimer()
    }

    func stopBackgroundScanning() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    private func scheduleNextTimer() {
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
        before.scanSummary.totalChangedFiles != after.scanSummary.totalChangedFiles
            || before.scanSummary.changedRepositories != after.scanSummary.changedRepositories
            || before.scanSummary.totalRepositories != after.scanSummary.totalRepositories
    }

    private func scanRoots() -> (roots: [String], warning: String?) {
        let configuredDirectories = scanDirectories

        var accessibleRoots: [String] = []
        var inaccessibleCount = 0
        var containerPathCount = 0

        for directory in configuredDirectories {
            if let url = resolvedURL(for: directory) {
                let path = ScanLocationProvider.normalizePersistedPath(url.path)
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

            let normalizedPath = ScanLocationProvider.normalizePersistedPath(directory.path)
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
        if deduped.isEmpty && configuredDirectories.isEmpty {
            warning = "No scan roots configured. Add a directory in Settings."
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

    private func restorePersistedSnapshot() {
        syncStoreInspection()
        switch AppGroupStore.read() {
        case .success(let snapshot):
            let pinned = applyPins(snapshot)
            lastResult = pinned
            diagnostics.sharedDataSnapshot = snapshot
            diagnostics.snapshotDecodable = true
            let now = Date()
            diagnostics.sharedDataReadAt = now
            diagnostics.sharedDataReadError = nil
            diagnostics.lastGeneratedAt = snapshot.generatedAt
            diagnostics.lastWrittenAt = snapshot.writtenAt
            if let writtenAt = snapshot.writtenAt.flatMap(DateFormatting.date(from:)) {
                diagnostics.lastSharedWriteAt = writtenAt
            }
            if let generatedAt = DateFormatting.date(from: snapshot.generatedAt) {
                lastScanAt = generatedAt
                diagnostics.lastScanAt = generatedAt
            }
            refreshPhase = .idle
            refreshFailureMessage = nil
            warnings = []
            refreshWidgetReadableSnapshot()
            validateConsistency(expected: pinned, shared: snapshot, widget: diagnostics.widgetSnapshot, reason: "startup")
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

    private func syncSharedSnapshot(from snapshot: AppGroupData, reason: String) {
        let writtenAt = DateFormatting.nowISO()
        let snapshotToWrite = snapshot.withWrittenAt(writtenAt)
        var verifiedSnapshot: AppGroupData?

        switch AppGroupStore.write(snapshotToWrite) {
        case .success(let readBack):
            let now = Date()
            syncStoreInspection()
            appGroupAvailable = AppGroupStore.isAvailable
            diagnostics.lastSharedWriteAt = now
            diagnostics.lastGeneratedAt = readBack.generatedAt
            diagnostics.lastWrittenAt = readBack.writtenAt
            diagnostics.sharedDataWriteError = nil
            diagnostics.snapshotDecodable = true
            verifiedSnapshot = readBack
            recordEvent(
                .sharedDataWritten,
                "Shared snapshot written (\(snapshotToWrite.repositories.count) repos, \(reason))"
            )
        case .failure(let error):
            syncStoreInspection()
            diagnostics.sharedDataWriteError = error.localizedDescription
            diagnostics.snapshotDecodable = false
            diagnostics.validationIssues = [error.localizedDescription]
            markSharedSnapshotSyncFailure(error.localizedDescription)
            recordEvent(.sharedDataWriteFailed, "Shared snapshot write failed: \(error.localizedDescription)")
            return
        }

        guard let verifiedSnapshot else {
            diagnostics.sharedDataWriteError = "Shared snapshot verification failed without a decoded payload."
            diagnostics.validationIssues = [diagnostics.sharedDataWriteError ?? "Verification failed."]
            markSharedSnapshotSyncFailure(diagnostics.sharedDataWriteError ?? "Verification failed.")
            recordEvent(.sharedDataWriteFailed, "Shared snapshot verification failed unexpectedly.")
            return
        }

        diagnostics.sharedDataReadAt = Date()
        diagnostics.sharedDataSnapshot = verifiedSnapshot
        diagnostics.sharedDataReadError = nil
        refreshWidgetReadableSnapshot()
        validateConsistency(expected: snapshotToWrite, shared: verifiedSnapshot, widget: diagnostics.widgetSnapshot, reason: reason)
        lastResult = applyPins(verifiedSnapshot)
        diagnostics.lastReloadRequestedAt = Date()
        recordEvent(.widgetReloadRequested, "Widget reload requested (\(reason))")
        AppGroupStore.reloadWidgets()
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
            diagnostics.widgetSnapshot = snapshot
            diagnostics.widgetSnapshotReadAt = Date()
            diagnostics.widgetSnapshotReadError = nil
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

        return nil
    }

    private func failRefresh(_ message: String) {
        isScanning = false
        refreshPhase = .failure
        refreshFailureMessage = message
        warnings = [message]
        diagnostics.validationIssues = [message]
        diagnostics.nextSteps = suggestedNextSteps(from: [message])
        recordEvent(.scanFailed, message)
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
        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateScanInterval()
            }
        }
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
        let pinnedIDs = pinnedRepoIDs
        var repos = data.repositories.map { repo -> RepositorySnapshot in
            var copy = repo
            copy.isPinned = pinnedIDs.contains(repo.id)
            return copy
        }
        repos = RepositorySorter.sort(repos)

        return AppGroupData(
            schemaVersion: data.schemaVersion,
            generatedAt: data.generatedAt,
            writtenAt: data.writtenAt,
            scanSummary: data.scanSummary,
            repositories: repos
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

    private func persistConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .set(data, forKey: configKey)
    }

    private func persistScanDirectories() {
        guard let data = try? JSONEncoder().encode(scanDirectories) else { return }
        UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .set(data, forKey: scanDirectoriesKey)
    }

    private func loadConfig() {
        guard let data = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(ScanConfig.self, from: data) else {
            config = .default
            persistConfig()
            return
        }
        config = normalizeConfig(decoded)
        persistConfig()

        // Load last interval
        if let saved = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .double(forKey: lastScanIntervalKey), saved >= 300 {
            scanIntervalSeconds = saved
        }
    }

    private func loadScanDirectories() {
            if let data = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .data(forKey: scanDirectoriesKey),
           let decoded = try? JSONDecoder().decode([CustomScanDirectory].self, from: data) {
            scanDirectories = sanitizeScanDirectories(decoded)
        } else {
            scanDirectories = sanitizeScanDirectories(
                config.customPaths.map { CustomScanDirectory(path: $0, bookmarkData: nil) }
            )
        }

        syncConfigFromScanDirectories()
        scanRootAccessWarning = scanRoots().warning
        persistScanDirectories()
    }

    // MARK: - Enabled toggles

    func toggleBuiltIn(path: String, enabled: Bool) {
        if enabled {
            addCustomPath(path)
        } else {
            removeCustomPath(path)
        }
    }

    func addCustomPath(_ path: String) {
        let expanded = ScanLocationProvider.normalizePersistedPath(path)
        guard !expanded.isEmpty else { return }
        guard !isAppContainerPath(expanded) else {
            scanRootAccessWarning = "不能把 DevPulse 自己的沙盒容器当作扫描目录，请选择真实的用户目录。"
            return
        }
        guard isAccessibleScanRoot(expanded) else {
            scanRootAccessWarning = "部分目录权限失效，请在 Settings 重新授权。"
            return
        }
        if let existingIndex = scanDirectories.firstIndex(where: { $0.path == expanded }) {
            if scanDirectories[existingIndex].bookmarkData == nil,
               let refreshed = bookmarkData(for: URL(fileURLWithPath: expanded)) {
                scanDirectories[existingIndex] = CustomScanDirectory(
                    id: scanDirectories[existingIndex].id,
                    path: expanded,
                    bookmarkData: refreshed
                )
                syncConfigFromScanDirectories()
                persistScanDirectories()
            }
            scanRootAccessWarning = nil
            return
        }

        let bookmarkData = bookmarkData(for: URL(fileURLWithPath: expanded))
        let entry = CustomScanDirectory(path: expanded, bookmarkData: bookmarkData)
        scanDirectories.append(entry)
        syncConfigFromScanDirectories()
        scanRootAccessWarning = nil
        persistScanDirectories()
    }

    func removeCustomPath(_ path: String) {
        let normalized = ScanLocationProvider.normalizePersistedPath(path)
        scanDirectories.removeAll { $0.path == normalized }
        syncConfigFromScanDirectories()
        persistScanDirectories()
    }

    private func normalizeConfig(_ config: ScanConfig) -> ScanConfig {
        var normalized = config
        let existingRoots = config.customPaths
            .map(ScanLocationProvider.normalizePersistedPath)
            .filter { isAccessibleScanRoot($0) && !isAppContainerPath($0) }
        normalized.enabledBuiltInPaths = []
        normalized.customPaths = Array(Set(existingRoots)).sorted()
        return normalized
    }

    private func syncConfigFromScanDirectories() {
        config.enabledBuiltInPaths = []
        config.customPaths = scanDirectories.map(\.path).sorted()
    }

    private func sanitizeScanDirectories(_ directories: [CustomScanDirectory]) -> [CustomScanDirectory] {
        var sanitized: [CustomScanDirectory] = []
        var inaccessibleCount = 0
        var containerCount = 0

        for directory in directories {
            let normalizedPath = ScanLocationProvider.normalizePersistedPath(directory.path)
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
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
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
        guard let index = scanDirectories.firstIndex(where: { $0.path == normalized }) else { return }
        scanDirectories[index] = CustomScanDirectory(
            id: scanDirectories[index].id,
            path: normalized,
            bookmarkData: data
        )
        persistScanDirectories()
    }

    private func isAppContainerPath(_ path: String) -> Bool {
        ScanLocationProvider.isLikelySandboxContainerPath(path)
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
}

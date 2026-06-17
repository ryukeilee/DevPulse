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
    @Published var gitAvailable: Bool = true
    @Published var appGroupAvailable: Bool = true
    @Published var warnings: [String] = []
    @Published var scanIntervalSeconds: TimeInterval = 300
    @Published var powerState: String = "normal"

    private var backgroundTimer: Timer?
    private var consecutiveNoChanges = 0

    // Config persistence
    private let configKey = "scan_config_json"
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

    var config: ScanConfig = .default {
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

    init() {
        loadConfig()
        appGroupAvailable = AppGroupStore.isAvailable
        gitAvailable = ProcessRunner.isGitAvailable()
        updatePowerState()
        startPowerMonitoring()
    }

    // MARK: - Scan (async, non-blocking)

    func scanNow() {
        guard !isScanning else { return }

        isScanning = true
        warnings = []
        let currentConfig = config

        Task.detached(priority: .userInitiated) {
            let result = await GitRepositoryScanner.scan(config: currentConfig)

            await MainActor.run {
                let pinned = self.applyPins(result.data)
                let hadChanges = self.hadChanges(before: self.lastResult, after: pinned)

                self.lastResult = pinned
                self.lastScanAt = Date()
                self.warnings = result.warnings
                self.isScanning = false

                // Adaptive interval
                if hadChanges {
                    self.consecutiveNoChanges = 0
                } else {
                    self.consecutiveNoChanges += 1
                }
                self.updateScanInterval()
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

        print("[DevPulse] Scan interval: \(Int(scanIntervalSeconds))s "
              + "(no-change streak: \(consecutiveNoChanges), power: \(powerState))")

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
        AppGroupStore.write(updated)
    }

    // MARK: - Config persistence

    private func persistConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .set(data, forKey: configKey)
    }

    private func loadConfig() {
        guard let data = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(ScanConfig.self, from: data) else {
            config = .default
            return
        }
        config = decoded

        // Load last interval
        if let saved = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)?
            .double(forKey: lastScanIntervalKey), saved >= 300 {
            scanIntervalSeconds = saved
        }
    }

    // MARK: - Enabled toggles

    func toggleBuiltIn(path: String, enabled: Bool) {
        if enabled {
            config.enabledBuiltInPaths.insert(path)
        } else {
            config.enabledBuiltInPaths.remove(path)
        }
    }

    func addCustomPath(_ path: String) {
        let expanded = ScanLocationProvider.expandTilde(path)
        guard !config.customPaths.contains(expanded) else { return }
        config.customPaths.append(expanded)
    }

    func removeCustomPath(_ path: String) {
        config.customPaths.removeAll { $0 == path }
    }
}

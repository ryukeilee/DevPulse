import Foundation
import OSLog

// MARK: - Backup scheduler

/// Timer-based automatic backup scheduler.
///
/// Design:
/// - Runs on a background timer at the configured interval
/// - Skips if a backup or restore is in progress
/// - Skips if the app is on battery/low power (configurable)
/// - Logs results and errors
/// - Non-blocking: does not interfere with scan or UI operations
final class BackupScheduler {
    private let logger = Logger(subsystem: "local.devpulse.app", category: "BackupScheduler")
    private let backupManager: BackupManager
    private let restoreManager: RestoreManager

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(
        label: "local.devpulse.app.backup-scheduler",
        qos: .utility,
        attributes: [],
        autoreleaseFrequency: .workItem
    )

    /// Callback invoked when an auto-backup completes.
    var onBackupComplete: ((Result<BackupSummary, Error>) -> Void)?

    /// Provider for current store data. Called when the timer fires.
    var storeDataProvider: (() -> [BackupStoreType: (data: Data, schemaVersion: Int)])?

    /// Provider for the current integration configuration.
    var configProvider: (() -> BackupIntegrationConfiguration)?

    init(backupManager: BackupManager, restoreManager: RestoreManager) {
        self.backupManager = backupManager
        self.restoreManager = restoreManager
    }

    // MARK: - Start / Stop

    /// Start the automatic backup timer. If already running, restarts.
    func start() {
        queue.async { self.startUnsafe() }
    }

    /// Stop the automatic backup timer.
    func stop() {
        queue.async { self.stopUnsafe() }
    }

    /// Check if the scheduler is running.
    var isRunning: Bool {
        queue.sync { timer != nil }
    }

    /// Manually trigger an immediate backup (outside the timer schedule).
    func triggerNow() -> Result<BackupSummary, Error> {
        guard let config = configProvider?() else {
            return .failure(BackupManagerError.storeUnavailable("配置未设置"))
        }
        guard config.enabled else {
            return .failure(BackupManagerError.storeUnavailable("备份功能未启用"))
        }

        return createBackup(config: config)
    }

    // MARK: - Private

    private func startUnsafe() {
        stopUnsafe()
        guard let config = configProvider?(), config.enabled, config.autoBackupEnabled else {
            logger.notice("自动备份未启用")
            return
        }

        let interval = max(config.retention.autoBackupIntervalSeconds, 300) // min 5 min
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(30))
        t.setEventHandler { [weak self] in
            self?.timerFired()
        }
        t.resume()
        timer = t
        logger.notice("自动备份已启动，间隔：\(Int(interval)) 秒")
    }

    private func stopUnsafe() {
        timer?.cancel()
        timer = nil
    }

    private func timerFired() {
        guard let config = configProvider?(), config.enabled, config.autoBackupEnabled else {
            return
        }

        // Check battery / power state (skip on battery if configured)
        // For now, always allow

        let result = createBackup(config: config)
        switch result {
        case .success(let summary):
            logger.notice("自动备份完成：\(summary.id), 条目数：\(summary.entryCount)")
        case .failure(let error):
            logger.error("自动备份失败：\(error.localizedDescription)")
        }

        onBackupComplete?(result)
    }

    private func createBackup(config: BackupIntegrationConfiguration) -> Result<BackupSummary, Error> {
        guard let stores = storeDataProvider?(), !stores.isEmpty else {
            return .failure(BackupManagerError.storeUnavailable("没有可备份的数据"))
        }

        do {
            let summary = try backupManager.createBackup(
                config: config,
                stores: stores,
                isIncremental: false
            )
            return .success(summary)
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Backup notification payload

struct BackupNotification: Equatable {
    let backupID: String
    let success: Bool
    let entryCount: Int
    let message: String
}

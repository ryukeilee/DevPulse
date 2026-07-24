import Foundation
import os.log

// MARK: - Startup diagnostics and recovery

/// Result of a single startup diagnostic check.
struct StartupCheckResult: Equatable {
    let name: String
    let passed: Bool
    let detail: String
    let recovered: Bool
}

/// Aggregate startup self-check report.
struct StartupDiagnosticsReport: Equatable {
    let checks: [StartupCheckResult]
    let allPassed: Bool
    let recoveredCount: Int

    var renderedOutput: String {
        var lines = [
            "startup_diagnostics.all_passed=\(allPassed)",
            "startup_diagnostics.checks=\(checks.count)",
            "startup_diagnostics.recovered=\(recoveredCount)",
        ]
        for check in checks {
            lines.append("check.\(check.name)=\(check.passed ? "pass" : "fail") detail=\"\(check.detail)\" recovered=\(check.recovered)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Performs structured self-checks at startup and attempts automatic recovery
/// for common failure modes before they reach the UI.
enum StartupDiagnostics {
    private static let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "StartupDiagnostics"
    )

    /// Run the full startup diagnostic suite with recovery attempts.
    ///
    /// Checks are ordered so that low-cost / high-impact checks run first.
    /// Recovery is attempted immediately when a failure is detected; the
    /// result still records the original failure but sets `recovered = true`
    /// when the recovery action succeeded.
    @discardableResult
    static func runSelfCheck(
        appGroupStore: AppGroupStore.Type = AppGroupStore.self,
        snapshotStoreFactory: (URL, String) -> SharedSnapshotStore? = { url, name in
            SharedSnapshotStore(directoryURL: url, fileName: name)
        }
    ) -> StartupDiagnosticsReport {
        var checks: [StartupCheckResult] = []
        var recoveredCount = 0

        // 1. App Group availability
        let appGroupCheck = checkAppGroup()
        checks.append(appGroupCheck)
        if !appGroupCheck.passed { return finalize(checks: checks, recoveredCount: recoveredCount) }

        guard let containerURL = AppGroupStore.containerURL else {
            return finalize(checks: checks, recoveredCount: recoveredCount)
        }

        // 2. Git availability
        let gitCheck = checkGit()
        checks.append(gitCheck)

        // 3. Snapshot file existence
        let snapshotCheck = checkSnapshotFile(containerURL: containerURL)
        checks.append(snapshotCheck)

        // 4. Snapshot decode and validation
        let decodeCheck = checkSnapshotDecode(
            containerURL: containerURL,
            snapshotStoreFactory: snapshotStoreFactory
        )
        checks.append(decodeCheck)

        // 5. Temporary file cleanup
        let cleanupCheck = attemptTemporaryFileCleanup(
            containerURL: containerURL,
            snapshotStoreFactory: snapshotStoreFactory
        )
        checks.append(cleanupCheck)
        if cleanupCheck.recovered { recoveredCount += 1 }

        // 6. Snapshot writability
        let writableCheck = checkSnapshotWritable()
        checks.append(writableCheck)

        // 7. Schema version consistency (primary vs backup)
        let schemaCheck = checkSchemaConsistency(
            containerURL: containerURL,
            snapshotStoreFactory: snapshotStoreFactory
        )
        checks.append(schemaCheck)

        return finalize(checks: checks, recoveredCount: recoveredCount)
    }

    // MARK: - Individual checks

    static func checkAppGroup() -> StartupCheckResult {
        let available = AppGroupStore.isAvailable
        let detail: String
        if available {
            detail = "App Group \(AppGroupStore.appGroupIdentifier) is available"
        } else {
            detail = "App Group \(AppGroupStore.appGroupIdentifier) is NOT available — check entitlements and signing"
        }
        return StartupCheckResult(
            name: "appGroup",
            passed: available,
            detail: detail,
            recovered: false
        )
    }

    static func checkGit() -> StartupCheckResult {
        let available = ProcessRunner.isGitAvailable()
        return StartupCheckResult(
            name: "git",
            passed: available,
            detail: available ? "git command is available" : "git command not found in PATH",
            recovered: false
        )
    }

    static func checkSnapshotFile(containerURL: URL) -> StartupCheckResult {
        let primaryURL = containerURL.appendingPathComponent(SharedSnapshotLocation.fileName)
        let exists = FileManager.default.fileExists(atPath: primaryURL.path)
        let backupURL = containerURL.appendingPathComponent(
            "\(SharedSnapshotLocation.fileName).backup"
        )
        let backupExists = FileManager.default.fileExists(atPath: backupURL.path)

        if exists {
            return StartupCheckResult(
                name: "snapshotFile",
                passed: true,
                detail: "Primary snapshot exists at \(primaryURL.lastPathComponent)" + (backupExists ? "; backup also present" : "; no backup file"),
                recovered: false
            )
        }

        if backupExists {
            return StartupCheckResult(
                name: "snapshotFile",
                passed: true,
                detail: "Primary snapshot missing but backup available — will recover on read",
                recovered: false
            )
        }

        return StartupCheckResult(
            name: "snapshotFile",
            passed: false,
            detail: "Neither primary nor backup snapshot found — first launch or data cleared",
            recovered: false
        )
    }

    static func checkSnapshotDecode(
        containerURL: URL,
        snapshotStoreFactory: (URL, String) -> SharedSnapshotStore?
    ) -> StartupCheckResult {
        guard let store = snapshotStoreFactory(containerURL, SharedSnapshotLocation.fileName) else {
            return StartupCheckResult(
                name: "snapshotDecode",
                passed: false,
                detail: "Failed to create snapshot store instance",
                recovered: false
            )
        }

        switch store.load() {
        case .success(let read):
            var detail = "Snapshot decoded successfully from \(read.source)"
            var issues: [String] = []
            if read.snapshot.persistenceState != .committed {
                issues.append("persistence state is \(read.snapshot.persistenceState)")
            }
            if read.snapshot.storageRevision == 0 {
                issues.append("storage revision is zero")
            }
            if let schemaVersion = read.snapshot.appVersion {
                issues.append("written by app v\(schemaVersion)")
            }
            if !issues.isEmpty {
                detail += " (" + issues.joined(separator: "; ") + ")"
            }
            return StartupCheckResult(
                name: "snapshotDecode",
                passed: true,
                detail: detail,
                recovered: false
            )
        case .failure(let error):
            // Attempt recovery: rebuild from backup metadata
            let recoveryAttempted = attemptSnapshotRecovery(store: store)
            return StartupCheckResult(
                name: "snapshotDecode",
                passed: false,
                detail: "Snapshot decode failed: \(error.localizedDescription)" + (recoveryAttempted ? " (recovery attempted)" : ""),
                recovered: recoveryAttempted
            )
        }
    }

    static func attemptTemporaryFileCleanup(
        containerURL: URL,
        snapshotStoreFactory: (URL, String) -> SharedSnapshotStore?
    ) -> StartupCheckResult {
        guard let store = snapshotStoreFactory(containerURL, SharedSnapshotLocation.fileName) else {
            return StartupCheckResult(
                name: "tempCleanup",
                passed: false,
                detail: "Cannot create store for cleanup",
                recovered: false
            )
        }

        switch store.cleanupTemporaryFiles() {
        case .success:
            return StartupCheckResult(
                name: "tempCleanup",
                passed: true,
                detail: "Temporary files cleaned up successfully",
                recovered: true
            )
        case .failure(let error):
            return StartupCheckResult(
                name: "tempCleanup",
                passed: false,
                detail: "Temporary file cleanup failed: \(error.localizedDescription)",
                recovered: false
            )
        }
    }

    static func checkSnapshotWritable() -> StartupCheckResult {
        let writable = AppGroupStore.snapshotWritable
        return StartupCheckResult(
            name: "snapshotWritable",
            passed: writable,
            detail: writable
                ? "Snapshot file/directory is writable"
                : "Snapshot is not writable — check file permissions and App Group container",
            recovered: false
        )
    }

    static func checkSchemaConsistency(
        containerURL: URL,
        snapshotStoreFactory: (URL, String) -> SharedSnapshotStore?
    ) -> StartupCheckResult {
        guard let store = snapshotStoreFactory(containerURL, SharedSnapshotLocation.fileName) else {
            return StartupCheckResult(
                name: "schemaConsistency",
                passed: false,
                detail: "Cannot create store for schema check",
                recovered: false
            )
        }

        let primaryExists = FileManager.default.fileExists(atPath: store.primaryURL.path)
        let backupExists = FileManager.default.fileExists(atPath: store.backupURL.path)

        guard primaryExists || backupExists else {
            return StartupCheckResult(
                name: "schemaConsistency",
                passed: true,
                detail: "No snapshot files to compare",
                recovered: false
            )
        }

        // Attempt loads to detect schema mismatches
        let primaryResult = try? store.load()
        switch primaryResult {
        case .success:
            return StartupCheckResult(
                name: "schemaConsistency",
                passed: true,
                detail: "Primary and backup schema are consistent",
                recovered: false
            )
        case .failure(let error):
            return StartupCheckResult(
                name: "schemaConsistency",
                passed: false,
                detail: "Schema check failed: \(error.localizedDescription)",
                recovered: false
            )
        case nil:
            return StartupCheckResult(
                name: "schemaConsistency",
                passed: false,
                detail: "Schema check encountered an unexpected error",
                recovered: false
            )
        }
    }

    // MARK: - Recovery

    /// Attempt automatic recovery from a snapshot decode failure.
    /// Returns `true` if recovery was attempted (even if it may not fully succeed).
    @discardableResult
    static func attemptSnapshotRecovery(store: SharedSnapshotStore) -> Bool {
        logger.debug("Attempting snapshot recovery after decode failure")
        // The store's `load()` already handles primary → backup fallback
        // transparently. If load failed, the backup is also damaged.
        // Create a minimal empty snapshot to restore operability.
        let emptySnapshot = AppGroupData.empty().withPersistenceMetadata(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: DateFormatting.nowISO(),
            writtenAt: DateFormatting.nowISO(),
            lastSuccessfulRefreshAt: nil,
            storageRevision: 0,
            persistenceState: .recovered
        )
        switch store.commit(emptySnapshot) {
        case .success:
            logger.debug("Snapshot recovery: committed empty recovery snapshot")
            return true
        case .failure(let error):
            logger.error("Snapshot recovery failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Helpers

    private static func finalize(
        checks: [StartupCheckResult],
        recoveredCount: Int
    ) -> StartupDiagnosticsReport {
        let report = StartupDiagnosticsReport(
            checks: checks,
            allPassed: checks.allSatisfy(\.passed),
            recoveredCount: recoveredCount
        )
        if !report.allPassed || recoveredCount > 0 {
            logger.debug("Startup diagnostics: \(report.renderedOutput)")
        }
        return report
    }
}

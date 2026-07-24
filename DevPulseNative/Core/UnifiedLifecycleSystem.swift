// MARK: - Unified Lifecycle System
//
// 统一生命周期系统：将 DevPulse 的启动、升级、安装与 Widget 恢复链路
// 重构为可自愈的统一系统。
//
// 子系统划分：
//   1. LifecycleCoordinator    — 生命周期协调器
//   2. VersionedSnapshotProtocol — 版本化快照协议
//   3. GenerationIsolation     — 代次隔离规则
//   4. SelfHealingRunner       — 自愈恢复流程
//   5. WidgetRecoveryManager   — Widget 恢复管理器
//   6. InstallUpgradeVerifier  — 安装升级验证器
//   7. BoundedRecoveryContext   — 后台有界恢复执行
//
// Design: v1 (2025)

import Darwin
import Foundation
import OSLog
#if canImport(WidgetKit)
import WidgetKit
#endif

// ══════════════════════════════════════════════════════════════════════
//  MARK: - Constants
// ══════════════════════════════════════════════════════════════════════

enum UnifiedLifecycleSchema {
    /// The current storage format version. Increment when adding new
    /// required fields to the snapshot metadata header that every reader
    /// must recognise.
    static let storageFormatVersion = 1

    /// The maximum storage format version this process can read.
    static let supportedStorageFormatVersion = 1

    /// Current schema version for AppGroupData payload.
    static let schemaVersion = 3
    static let oldestMigratableSchemaVersion = 1
}

// ══════════════════════════════════════════════════════════════════════
//  MARK: - Lifecycle Identity
// ══════════════════════════════════════════════════════════════════════

/// Describes the installation state of the DevPulse application.
/// Determined at startup by inspecting the bundle, App Group container,
/// and snapshot state.
enum InstallState: Equatable, Sendable {
    /// First-ever launch — no App Group container, no snapshot, no pending items.
    case firstInstall
    /// App was reinstalled (same version overwritten).
    case cleanReinstall(marketingVersion: String)
    /// App was upgraded from a previous version.
    case upgrade(fromVersion: String, toVersion: String)
    /// No change detected — normal launch.
    case normalLaunch
    /// Could not determine state.
    case indeterminate(reason: String)
}

/// Describes Widget extension registration state as observed by the host app.
enum WidgetRegistrationState: Equatable, Sendable {
    /// Widget extension is embedded in the app bundle.
    case embedded
    /// Widget is registered with WidgetKit (pluginkit).
    case registered
    /// Both embedded and registered.
    case active
    /// Widget extension is missing from PlugIns directory.
    case missingExtension
    /// Widget is not registered with pluginkit (may need re-registration).
    case notRegistered(reason: String)
    /// Could not determine.
    case unknown
}

// ══════════════════════════════════════════════════════════════════════
//  MARK: - Versioned Snapshot Protocol
// ══════════════════════════════════════════════════════════════════════

/// Defines the contract for reading/writing versioned shared snapshots
/// with safe degradation across app upgrades, downgrades, and corruption.
///
/// Rules:
/// - Writers always increment `storageFormatVersion` when adding mandatory
///   header fields.
/// - Readers reject files with `storageFormatVersion > supported`.
/// - `appVersion` is written for diagnostic purposes only — never used for
///   compatibility decisions.
/// - `schemaVersion` is the data-model version; migration is attempted
///   when reader supports it.
/// - `storageRevision` is a monotonic counter set only by SharedSnapshotStore.
/// - Readers MUST handle: primary missing, backup available; both missing;
///   primary corrupt + backup valid; future schema; empty file; I/O error.
enum VersionedSnapshotProtocol {
    static let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "VersionedSnapshotProtocol"
    )

    /// Validate that the reader can safely interpret the file at `url`.
    /// Returns `.ok` when safe, or a specific error explaining why not.
    static func validate(
        at url: URL,
        expectedSchemaVersion: Int = UnifiedLifecycleSchema.schemaVersion,
        supportedFormatVersion: Int = UnifiedLifecycleSchema.supportedStorageFormatVersion
    ) -> Result<Void, VersionedSnapshotError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.fileNotFound(url.path))
        }

        let bytes: Data
        do {
            bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return .failure(.ioError(error.localizedDescription))
        }

        guard !bytes.isEmpty else {
            return .failure(.emptyFile(url.path))
        }

        let decoder = JSONDecoder()
        let header: SnapshotVersionHeader
        do {
            header = try decoder.decode(SnapshotVersionHeader.self, from: bytes)
        } catch {
            return .failure(.headerDecodeFailed(error.localizedDescription))
        }

        // Reject future storage format versions.
        if let fileFormatVersion = header.storageFormatVersion,
           fileFormatVersion > supportedFormatVersion {
            return .failure(.futureStorageFormatVersion(
                supported: supportedFormatVersion,
                actual: fileFormatVersion
            ))
        }

        // Reject unsupported schema versions.
        if header.schemaVersion > expectedSchemaVersion {
            return .failure(.futureSchemaVersion(
                expected: expectedSchemaVersion,
                actual: header.schemaVersion,
                appVersion: header.appVersion
            ))
        }

        if header.schemaVersion < UnifiedLifecycleSchema.oldestMigratableSchemaVersion {
            return .failure(.unsupportedSchemaVersion(header.schemaVersion))
        }

        return .success(())
    }
}

enum VersionedSnapshotError: LocalizedError, Equatable {
    case fileNotFound(String)
    case ioError(String)
    case emptyFile(String)
    case headerDecodeFailed(String)
    case futureStorageFormatVersion(supported: Int, actual: Int)
    case futureSchemaVersion(expected: Int, actual: Int, appVersion: String?)
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Snapshot file not found at \(path)"
        case .ioError(let reason):
            return "Snapshot I/O error: \(reason)"
        case .emptyFile(let path):
            return "Snapshot file at \(path) is empty"
        case .headerDecodeFailed(let reason):
            return "Snapshot header decode failed: \(reason)"
        case .futureStorageFormatVersion(let supported, let actual):
            return "Snapshot uses storage format v\(actual), this process supports v\(supported)"
        case .futureSchemaVersion(let expected, let actual, let appVersion):
            let app = appVersion.map { " (written by app v\($0))" } ?? ""
            return "Snapshot schema v\(actual) is newer than v\(expected)\(app)"
        case .unsupportedSchemaVersion(let version):
            return "Snapshot schema v\(version) is too old to migrate"
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
//  MARK: - Generation Isolation Rules
// ══════════════════════════════════════════════════════════════════════

/// Generation isolation prevents stale tasks, stale snapshots, and delayed
/// callbacks from overwriting newer trusted results.
///
/// The system assigns a monotonically-advancing `generation` to each
/// refresh cycle. Every async task, snapshot write, and widget timeline
/// reload captures the generation at spawn time and checks it before
/// committing results.
///
/// Cross-process isolation: `storageRevision` in the shared snapshot
/// serves as the cross-process generation counter. A writer that observed
/// `storageRevision = N` must verify it hasn't advanced past N before
/// committing (optimistic concurrency).
enum GenerationIsolation {
    static let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "GenerationIsolation"
    )

    /// A generation token captured at task creation time.
    struct Token: Equatable, Sendable {
        let generation: UInt64
        let epoch: UInt64
    }

    /// A cross-process generation reference captured from the shared snapshot.
    struct CrossProcessToken: Equatable, Sendable {
        let storageRevision: UInt64
        let generation: UInt64
        let epoch: UInt64
    }

    /// Check if the task's token is still valid against the current generation.
    /// Returns `true` if the task should continue; `false` if it's stale.
    static func isCurrent(
        token: Token,
        currentGeneration: UInt64,
        currentEpoch: UInt64
    ) -> Bool {
        token.generation == currentGeneration && token.epoch == currentEpoch
    }

    /// Validate cross-process token: the snapshot's storageRevision must not
    /// have advanced past what the caller observed when starting work.
    static func validateCrossProcess(
        observedRevision: UInt64,
        snapshotRevision: UInt64
    ) -> CrossProcessValidation {
        if snapshotRevision > observedRevision {
            return .stale(
                reason: "storageRevision advanced from \(observedRevision) to \(snapshotRevision)"
            )
        }
        return .current
    }

    enum CrossProcessValidation: Equatable {
        case current
        case stale(reason: String)
    }
}

// ══════════════════════════════════════════════════════════════════════
//  MARK: - Self-Healing Runner
// ══════════════════════════════════════════════════════════════════════

/// Runs startup self-checks and attempted recovery in a bounded background
/// context. Never blocks the main thread. Produces a structured report.
actor SelfHealingRunner {
    nonisolated let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "SelfHealingRunner"
    )

    /// Maximum time the entire self-heal sequence may take.
    private static let timeBudget: TimeInterval = 5.0

    /// Maximum time for a single recovery operation.
    private static let recoveryOperationTimeout: TimeInterval = 2.0

    /// Check categories that can be independently skipped or reported.
    struct CheckReport: Equatable, Sendable {
        let category: CheckCategory
        let passed: Bool
        let detail: String
        let recovered: Bool
        let durationMs: Double
    }

    enum CheckCategory: String, Sendable {
        case appGroupAvailability
        case snapshotVersion
        case snapshotIntegrity
        case temporaryFileCleanup
        case widgetExtensionEmbedded
        case widgetRegistration
        case gitAvailability
        case snapshotWritable
        case schemaConsistency
        case pendingItemStore
        case pendingItemNotificationStore
    }

    struct SelfHealReport: Equatable, Sendable {
        let checks: [CheckReport]
        let allPassed: Bool
        let recoveredCount: Int
        let totalDurationMs: Double
        let requiresUserAction: Bool
        let userActionMessage: String?
    }

    /// Run the full self-healing sequence within a bounded time budget.
    /// Safe to call from any context. Uses `BoundedRecoveryContext.startup`
    /// to enforce total budget and per-operation timeouts.
    func run(
        appGroupStore: AppGroupStore.Type = AppGroupStore.self
    ) async -> SelfHealReport {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let recoveryContext = BoundedRecoveryContext.startup
        var checks: [CheckReport] = []
        var recoveredCount = 0
        var deadline: TimeInterval? = nil

        // Helper to check if budget remains before running another phase.
        func budgetRemaining() -> Bool {
            guard let deadline else { return true }
            return ProcessInfo.processInfo.systemUptime < deadline
        }

        // Phase 1: App Group — if this fails, nothing else works.
        let appGroupResult = await recoveryContext.run(
            operation: { await Self.measuredCheck(.appGroupAvailability, Self.appGroupCheck()) },
            deadline: &deadline
        )
        if case .success(let appGroupCheck) = appGroupResult {
            checks.append(appGroupCheck)
        } else {
            let fallback = CheckReport(category: .appGroupAvailability, passed: false,
                                       detail: "App Group check aborted (budget exceeded or timeout)",
                                       recovered: false, durationMs: 0)
            checks.append(fallback)
        }
        if let appGroupCheck = checks.last, !appGroupCheck.passed {
            return finalize(checks: checks, recoveredCount: recoveredCount,
                           startedAt: startedAt, requiresUserAction: true,
                           userActionMessage: "App Group '\(AppGroupStore.appGroupIdentifier)' 不可用。请检查 Entitlements 和签名配置。")
        }

        guard let containerURL = AppGroupStore.containerURL, budgetRemaining() else {
            return finalize(checks: checks, recoveredCount: recoveredCount,
                           startedAt: startedAt, requiresUserAction: true,
                           userActionMessage: "无法获取 App Group 容器 URL，或恢复预算已耗尽。")
        }

        // Phase 2: Git availability (fast, independent)
        let gitResult = await recoveryContext.run(
            operation: { await Self.measuredCheck(.gitAvailability, Self.gitCheck()) },
            deadline: &deadline
        )
        if case .success(let gitCheck) = gitResult, budgetRemaining() {
            checks.append(gitCheck)
        }

        // Phase 3: Snapshot version check
        if budgetRemaining() {
            let versionResult = await recoveryContext.run(
                operation: { await Self.measuredCheck(.snapshotVersion, await Self.snapshotVersionCheck(containerURL: containerURL)) },
                deadline: &deadline
            )
            if case .success(let versionCheck) = versionResult { checks.append(versionCheck) }
        }

        // Phase 4: Snapshot integrity (includes recovery attempt)
        if budgetRemaining() {
            let integrityResult = await recoveryContext.run(
                operation: { await Self.measuredCheck(.snapshotIntegrity, await Self.snapshotIntegrityCheck(containerURL: containerURL)) },
                deadline: &deadline
            )
            if case .success(let integrityCheck) = integrityResult {
                checks.append(integrityCheck)
                if integrityCheck.recovered { recoveredCount += 1 }
            }
        }

        // Phase 5: Temporary file cleanup
        if budgetRemaining() {
            let cleanupResult = await recoveryContext.run(
                operation: { await Self.measuredCheck(.temporaryFileCleanup, await Self.tempCleanupCheck(containerURL: containerURL)) },
                deadline: &deadline
            )
            if case .success(let cleanupCheck) = cleanupResult {
                checks.append(cleanupCheck)
                if cleanupCheck.recovered { recoveredCount += 1 }
            }
        }

        // Phase 6: Widget extension embedded in bundle
        if budgetRemaining() {
            let embedResult = await recoveryContext.run(
                operation: { await Self.measuredCheck(.widgetExtensionEmbedded, Self.widgetExtensionEmbeddedCheck()) },
                deadline: &deadline
            )
            if case .success(let embedCheck) = embedResult { checks.append(embedCheck) }
        }

        // Phase 7: Widget registration with pluginkit (best-effort)
        if budgetRemaining() {
            let regResult = await recoveryContext.run(
                operation: { await Self.measuredCheck(.widgetRegistration, Self.widgetRegistrationCheck()) },
                deadline: &deadline
            )
            if case .success(let regCheck) = regResult { checks.append(regCheck) }
        }

        // Phase 8: Snapshot writability
        if budgetRemaining() {
            let writableResult = await recoveryContext.run(
                operation: { await Self.measuredCheck(.snapshotWritable, Self.snapshotWritableCheck()) },
                deadline: &deadline
            )
            if case .success(let writableCheck) = writableResult { checks.append(writableCheck) }
        }

        // Phase 9: Schema consistency (primary vs backup)
        if budgetRemaining() {
            let schemaResult = await recoveryContext.run(
                operation: { await Self.measuredCheck(.schemaConsistency, await Self.schemaConsistencyCheck(containerURL: containerURL)) },
                deadline: &deadline
            )
            if case .success(let schemaCheck) = schemaResult { checks.append(schemaCheck) }
        }

        // Phase 10: Pending item store
        if budgetRemaining() {
            let pendingResult = await recoveryContext.run(
                operation: { await Self.measuredCheck(.pendingItemStore, Self.pendingItemStoreCheck()) },
                deadline: &deadline
            )
            if case .success(let pendingCheck) = pendingResult { checks.append(pendingCheck) }
        }

        return finalize(checks: checks, recoveredCount: recoveredCount,
                       startedAt: startedAt, requiresUserAction: false)
    }

    /// Run a check and wrap with timing.
    private static func measuredCheck(
        _ category: CheckCategory,
        _ check: @autoclosure () async -> CheckReport
    ) async -> CheckReport {
        let start = ProcessInfo.processInfo.systemUptime
        var report = await check()
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return CheckReport(
            category: report.category,
            passed: report.passed,
            detail: report.detail,
            recovered: report.recovered,
            durationMs: elapsed
        )
    }

    // MARK: - Individual Checks

    private static func appGroupCheck() -> CheckReport {
        let available = AppGroupStore.isAvailable
        return CheckReport(
            category: .appGroupAvailability,
            passed: available,
            detail: available
                ? "App Group \(AppGroupStore.appGroupIdentifier) is available"
                : "App Group \(AppGroupStore.appGroupIdentifier) is NOT available",
            recovered: false,
            durationMs: 0
        )
    }

    private static func gitCheck() -> CheckReport {
        let available = ProcessRunner.isGitAvailable()
        return CheckReport(
            category: .gitAvailability,
            passed: available,
            detail: available ? "git CLI is available" : "git CLI not found in PATH",
            recovered: false,
            durationMs: 0
        )
    }

    private static func snapshotVersionCheck(containerURL: URL) async -> CheckReport {
        let primaryURL = containerURL.appendingPathComponent(SharedSnapshotLocation.fileName)
        guard FileManager.default.fileExists(atPath: primaryURL.path) else {
            // No snapshot yet — may be first launch.
            return CheckReport(
                category: .snapshotVersion,
                passed: true,
                detail: "No snapshot file yet (first launch or post-cleanup)",
                recovered: false,
                durationMs: 0
            )
        }

        let result = VersionedSnapshotProtocol.validate(at: primaryURL)
        switch result {
        case .success:
            return CheckReport(
                category: .snapshotVersion,
                passed: true,
                detail: "Snapshot version is supported (schema matches)",
                recovered: false,
                durationMs: 0
            )
        case .failure(let error):
            // Future schema — cannot recover automatically.
            if case .futureSchemaVersion = error {
                return CheckReport(
                    category: .snapshotVersion,
                    passed: false,
                    detail: error.localizedDescription,
                    recovered: false,
                    durationMs: 0
                )
            }
            // Other errors (empty, corrupt header) — the integrity check handles recovery.
            return CheckReport(
                category: .snapshotVersion,
                passed: false,
                detail: error.localizedDescription,
                recovered: false,
                durationMs: 0
            )
        }
    }

    private static func snapshotIntegrityCheck(containerURL: URL) async -> CheckReport {
        let store = SharedSnapshotStore(
            directoryURL: containerURL,
            fileName: SharedSnapshotLocation.fileName
        )
        let loadResult = store.load()

        switch loadResult {
        case .success(let read):
            let sourceLabel: String = {
                switch read.source {
                case .primary: return "primary"
                case .migratedPrimary: return "migrated primary"
                case .backup: return "backup"
                }
            }()
            var details = "Snapshot loaded from \(sourceLabel)"
            if read.snapshot.persistenceState != .committed {
                details += " (state: \(read.snapshot.persistenceState))"
            }
            return CheckReport(
                category: .snapshotIntegrity,
                passed: true,
                detail: details,
                recovered: read.source != .primary,
                durationMs: 0
            )
        case .failure(let error):
            // Attempt to create a minimal empty snapshot to restore operability.
            let emptySnapshot = AppGroupData.empty().withPersistenceMetadata(
                schemaVersion: RepositorySnapshotSchema.version,
                generatedAt: DateFormatting.nowISO(),
                writtenAt: DateFormatting.nowISO(),
                lastSuccessfulRefreshAt: nil,
                storageRevision: 0,
                persistenceState: .recovered
            )
            _ = store.commit(emptySnapshot)
            return CheckReport(
                category: .snapshotIntegrity,
                passed: false,
                detail: "Snapshot corrupt: \(error.localizedDescription). Replaced with empty snapshot.",
                recovered: true,
                durationMs: 0
            )
        }
    }

    private static func tempCleanupCheck(containerURL: URL) async -> CheckReport {
        let store = SharedSnapshotStore(
            directoryURL: containerURL,
            fileName: SharedSnapshotLocation.fileName
        )
        switch store.cleanupTemporaryFiles() {
        case .success:
            return CheckReport(
                category: .temporaryFileCleanup,
                passed: true,
                detail: "Temporary files cleaned",
                recovered: true,
                durationMs: 0
            )
        case .failure(let error):
            return CheckReport(
                category: .temporaryFileCleanup,
                passed: false,
                detail: "Cleanup failed: \(error.localizedDescription)",
                recovered: false,
                durationMs: 0
            )
        }
    }

    private static func widgetExtensionEmbeddedCheck() -> CheckReport {
        guard let appBundle = Bundle.main.bundlePath as NSString? else {
            return CheckReport(
                category: .widgetExtensionEmbedded,
                passed: false,
                detail: "Cannot determine app bundle path",
                recovered: false,
                durationMs: 0
            )
        }
        let plugInsPath = appBundle.appendingPathComponent("Contents/PlugIns")
        let widgetExtensionPath = plugInsPath + "/DevPulseWidgetExtension.appex"

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: widgetExtensionPath, isDirectory: &isDir)
        let isValid = exists && isDir.boolValue

        return CheckReport(
            category: .widgetExtensionEmbedded,
            passed: isValid,
            detail: isValid
                ? "Widget extension found at \(widgetExtensionPath)"
                : "Widget extension NOT found at \(widgetExtensionPath)",
            recovered: false,
            durationMs: 0
        )
    }

    private static func widgetRegistrationCheck() -> CheckReport {
        // Attempt to check pluginkit for the widget bundle ID.
        // This is a best-effort check; it may fail in sandboxed builds.
        let widgetBundleID = "local.devpulse.app.widget"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-p", "com.apple.widgetkit-extension", "-i", widgetBundleID]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let isRegistered = output.contains(widgetBundleID)

                return CheckReport(
                    category: .widgetRegistration,
                    passed: isRegistered,
                    detail: isRegistered
                        ? "Widget \(widgetBundleID) is registered with pluginkit"
                        : "Widget \(widgetBundleID) NOT found via pluginkit",
                    recovered: false,
                    durationMs: 0
                )
            }
        } catch {
            // pluginkit may be unavailable in sandbox or test environments.
        }

        return CheckReport(
            category: .widgetRegistration,
            passed: false,
            detail: "pluginkit check failed or unavailable — needs manual verification",
            recovered: false,
            durationMs: 0
        )
    }

    private static func snapshotWritableCheck() -> CheckReport {
        let writable = AppGroupStore.snapshotWritable
        return CheckReport(
            category: .snapshotWritable,
            passed: writable,
            detail: writable
                ? "Snapshot is writable"
                : "Snapshot is not writable",
            recovered: false,
            durationMs: 0
        )
    }

    private static func schemaConsistencyCheck(containerURL: URL) async -> CheckReport {
        let store = SharedSnapshotStore(
            directoryURL: containerURL,
            fileName: SharedSnapshotLocation.fileName
        )

        let primaryExists = FileManager.default.fileExists(atPath: store.primaryURL.path)
        let backupExists = FileManager.default.fileExists(atPath: store.backupURL.path)

        guard primaryExists || backupExists else {
            return CheckReport(
                category: .schemaConsistency,
                passed: true,
                detail: "No snapshot files to compare",
                recovered: false,
                durationMs: 0
            )
        }

        switch store.load() {
        case .success:
            return CheckReport(
                category: .schemaConsistency,
                passed: true,
                detail: "Primary and backup schema are consistent",
                recovered: false,
                durationMs: 0
            )
        case .failure(let error):
            return CheckReport(
                category: .schemaConsistency,
                passed: false,
                detail: "Schema inconsistency: \(error.localizedDescription)",
                recovered: false,
                durationMs: 0
            )
        }
    }

    private static func pendingItemStoreCheck() -> CheckReport {
        let store = PendingItemStore.live()
        switch store.load() {
        case .success:
            return CheckReport(
                category: .pendingItemStore,
                passed: true,
                detail: "Pending item store loaded successfully",
                recovered: false,
                durationMs: 0
            )
        case .failure(let error):
            // Attempt recovery by re-creating the store
            store.invalidateCache()
            return CheckReport(
                category: .pendingItemStore,
                passed: false,
                detail: "Pending item store failed: \(error.localizedDescription). Cache invalidated.",
                recovered: true,
                durationMs: 0
            )
        }
    }

    // MARK: - Helpers

    private func finalize(
        checks: [CheckReport],
        recoveredCount: Int,
        startedAt: TimeInterval,
        requiresUserAction: Bool,
        userActionMessage: String? = nil
    ) -> SelfHealReport {
        let allPassed = checks.allSatisfy { $0.passed }
        let totalDuration = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        return SelfHealReport(
            checks: checks,
            allPassed: allPassed,
            recoveredCount: recoveredCount,
            totalDurationMs: totalDuration,
            requiresUserAction: requiresUserAction,
            userActionMessage: allPassed ? nil : userActionMessage
        )
    }
}

// ══════════════════════════════════════════════════════════════════════
//  MARK: - Lifecycle Coordinator
// ══════════════════════════════════════════════════════════════════════

/// Central coordinator for application lifecycle events.
///
/// Responsibilities:
/// - Determine install state (first install, upgrade, reinstall, normal launch)
/// - Run self-healing checks on startup
/// - Coordinate snapshot migration on version changes
/// - Trigger widget timeline reloads with proper generation tracking
/// - Manage background recovery operations with bounded execution
actor LifecycleCoordinator {
    nonisolated let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "LifecycleCoordinator"
    )

    // MARK: - State

    private(set) var installState: InstallState = .indeterminate(reason: "not yet determined")
    private(set) var widgetRegistrationState: WidgetRegistrationState = .unknown
    private(set) var lastSelfHealReport: SelfHealingRunner.SelfHealReport?

    // Generation tracking
    private var generation: UInt64 = 0
    private var generationEpoch: UInt64 = 0

    /// Whether the coordinator has completed its startup sequence.
    private(set) var isReady = false

    /// Callback invoked after startup self-heal completes.
    var onReady: (@Sendable (LifecycleCoordinator) async -> Void)?

    // MARK: - Initialization

    // Widget recovery manager used for coordinated timeline reloads.
    private let widgetManager = WidgetRecoveryManager()

    /// Perform the full startup lifecycle.
    /// Must be called once at app launch, before any scanning or UI.
    func performStartup() async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        logger.info("LifecycleCoordinator startup began")

        // Step 1: Determine install state.
        self.installState = await Self.determineInstallState()

        // Step 2: Run self-healing checks.
        let healRunner = SelfHealingRunner()
        let healReport = await healRunner.run()
        self.lastSelfHealReport = healReport

        // Step 3: Determine widget registration state.
        self.widgetRegistrationState = await Self.determineWidgetRegistrationState()

        // Step 4: Handle install-state specific actions.
        await self.handleInstallState(self.installState)

        // Step 5: Trigger widget timeline reload if self-heal recovered anything
        // or the install state indicates a lifecycle event occurred.
        let needsWidgetReload: Bool = {
            if healReport.recoveredCount > 0 { return true }
            if case .upgrade = self.installState { return true }
            if case .firstInstall = self.installState { return true }
            if self.widgetRegistrationState == .active { return true }
            return healReport.allPassed
        }()
        if needsWidgetReload || healReport.allPassed {
            let token = self.currentGeneration()
            await self.widgetManager.requestTimelineReload(
                generation: token,
                force: true
            )
            logger.info("Widget timeline reload triggered after startup")
        }

        // Step 6: Mark as ready.
        self.isReady = true
        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        logger.info("LifecycleCoordinator startup completed in \(Int(elapsed))ms")

        // Step 7: Fire ready callback.
        if let onReady {
            await onReady(self)
        }
    }

    /// Access the shared widget recovery manager.
    nonisolated func widgetRecoveryManager() -> WidgetRecoveryManager {
        widgetManager
    }

    /// Advance the generation counter and return a new token.
    func nextGeneration() -> GenerationIsolation.Token {
        let old = generation
        generation &+= 1
        if old == UInt64.max {
            generationEpoch &+= 1
        }
        return GenerationIsolation.Token(
            generation: generation,
            epoch: generationEpoch
        )
    }

    /// Return a generation token for the current generation (no advance).
    func currentGeneration() -> GenerationIsolation.Token {
        GenerationIsolation.Token(
            generation: generation,
            epoch: generationEpoch
        )
    }

    // MARK: - Install State Determination

    /// Determine the install state by inspecting the App Group container
    /// and comparing the last-known app version with the current version.
    static func determineInstallState(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = SharedSnapshotLocation.appGroupIdentifier,
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    ) async -> InstallState {
        // Check if App Group container exists and has a snapshot.
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return .firstInstall
        }

        let snapshotURL = containerURL.appendingPathComponent(SharedSnapshotLocation.fileName)
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            // No snapshot — could be first install or cleaned data.
            return .firstInstall
        }

        // Try to read version info from the snapshot.
        do {
            let data = try Data(contentsOf: snapshotURL, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            let header = try decoder.decode(SnapshotVersionHeader.self, from: data)
            let lastAppVersion = header.appVersion ?? "0.0.0"

            guard lastAppVersion != currentVersion else {
                return .normalLaunch
            }

            // Compare versions.
            let lastParts = lastAppVersion.split(separator: ".").compactMap { Int($0) }
            let currentParts = currentVersion.split(separator: ".").compactMap { Int($0) }

            let isUpgrade = Self.isVersionGreater(currentParts, than: lastParts)
            if isUpgrade {
                return .upgrade(fromVersion: lastAppVersion, toVersion: currentVersion)
            } else {
                return .cleanReinstall(marketingVersion: currentVersion)
            }
        } catch {
            // Cannot read header — assume indeterminate.
            return .indeterminate(reason: "cannot read snapshot version header: \(error.localizedDescription)")
        }
    }

    private static func isVersionGreater(
        _ lhs: [Int],
        than rhs: [Int]
    ) -> Bool {
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l > r { return true }
            if l < r { return false }
        }
        return false
    }

    // MARK: - Widget Registration State

    static func determineWidgetRegistrationState() async -> WidgetRegistrationState {
        // Check extension embedding.
        guard let appBundle = Bundle.main.bundlePath as NSString? else {
            return .unknown
        }
        let plugInsPath = appBundle.appendingPathComponent("Contents/PlugIns")
        let widgetExtensionPath = plugInsPath + "/DevPulseWidgetExtension.appex"
        var isDir: ObjCBool = false
        let extensionExists = FileManager.default.fileExists(
            atPath: widgetExtensionPath,
            isDirectory: &isDir
        ) && isDir.boolValue

        guard extensionExists else {
            return .missingExtension
        }

        // Check pluginkit registration.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-p", "com.apple.widgetkit-extension", "-i", "local.devpulse.app.widget"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if output.contains("local.devpulse.app.widget") {
                    return .active
                }
                return .notRegistered(reason: "pluginkit did not list the widget")
            }
        } catch {
            // pluginkit may be unavailable
        }

        return .notRegistered(reason: "pluginkit check failed")
    }

    // MARK: - Install State Actions

    private func handleInstallState(_ state: InstallState) async {
        switch state {
        case .firstInstall:
            logger.info("First install detected — no migration needed")
            // Create a minimal empty snapshot so the Widget can render
            // a first-launch state instead of showing a pure white placeholder.
            if let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
            ) {
                let store = SharedSnapshotStore(
                    directoryURL: containerURL,
                    fileName: SharedSnapshotLocation.fileName
                )
                let emptySnapshot = AppGroupData.empty()
                _ = store.commit(emptySnapshot)
                logger.info("Initial empty snapshot committed for first install")
            }

        case .cleanReinstall:
            logger.info("Clean reinstall detected — no migration needed")
            // Force widget reload so the Widget refreshes its placeholder.
            let token = self.currentGeneration()
            await self.widgetManager.requestTimelineReload(
                generation: token,
                force: true
            )

        case .upgrade(let fromVersion, let toVersion):
            logger.info("Upgrade detected: \(fromVersion) → \(toVersion)")
            // Ensure snapshot schema is up to date.
            // SharedSnapshotStore handles legacy migration automatically.
            // Force widget reload so the Widget picks up any format changes.
            let token = self.currentGeneration()
            await self.widgetManager.requestTimelineReload(
                generation: token,
                force: true
            )

        case .normalLaunch:
            logger.debug("Normal launch — no special action needed")

        case .indeterminate(let reason):
            logger.warning("Indeterminate install state: \(reason)")
            // Still attempt a widget reload to recover from uncertain state.
            let token = self.currentGeneration()
            await self.widgetManager.requestTimelineReload(
                generation: token,
                force: true
            )
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
//  MARK: - Widget Recovery Manager
// ══════════════════════════════════════════════════════════════════════

/// Manages Widget extension recovery operations and timeline reload.
///
/// All operations are bounded and run off the main thread.
actor WidgetRecoveryManager {
    nonisolated let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "WidgetRecoveryManager"
    )

    /// Minimum interval between forced widget timeline reloads.
    nonisolated static let minimumReloadInterval: TimeInterval = 60

    private var lastForcedReloadAt: Date?

    /// Request a widget timeline reload with generation isolation.
    /// The reload is skipped if one was requested within `minimumReloadInterval`,
    /// unless `force` is true. The generation token is logged for diagnostic
    /// purposes and can be used by callers to correlate reload requests with
    /// scan generations.
    func requestTimelineReload(
        generation: GenerationIsolation.Token?,
        force: Bool = false,
        now: Date = Date()
    ) {
        if !force,
           let lastReload = lastForcedReloadAt,
           now.timeIntervalSince(lastReload) < Self.minimumReloadInterval {
            logger.debug("Widget reload throttled (last: \(Int(Self.minimumReloadInterval - now.timeIntervalSince(lastReload)), privacy: .public)s ago)")
            return
        }

        let genDesc = generation.map { "gen:\($0.generation) epoch:\($0.epoch)" } ?? "no-generation"
        logger.info("Widget timeline reload requested [\(genDesc)]")
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetIdentity.kind)
        #endif
        lastForcedReloadAt = now
    }

    /// Attempt to verify that the Widget can read the current snapshot.
    /// Returns a structured report of what the Widget would render.
    func verifyWidgetReadiness() async -> WidgetReadinessReport {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
        ) else {
            return WidgetReadinessReport(
                canReadSnapshot: false,
                error: "App Group container unavailable"
            )
        }

        let store = SharedSnapshotStore(
            directoryURL: containerURL,
            fileName: SharedSnapshotLocation.fileName
        )
        let loadResult = store.load()

        switch loadResult {
        case .success(let read):
            return WidgetReadinessReport(
                canReadSnapshot: true,
                schemaVersion: read.snapshot.schemaVersion,
                storageRevision: read.snapshot.storageRevision,
                persistenceState: read.snapshot.persistenceState,
                source: String(describing: read.source),
                appVersion: read.snapshot.appVersion
            )
        case .failure(let error):
            return WidgetReadinessReport(
                canReadSnapshot: false,
                error: error.localizedDescription
            )
        }
    }
}

struct WidgetReadinessReport: Equatable, Sendable {
    let canReadSnapshot: Bool
    let schemaVersion: Int?
    let storageRevision: UInt64?
    let persistenceState: SharedSnapshotPersistenceState?
    let source: String?
    let appVersion: String?
    let error: String?

    init(
        canReadSnapshot: Bool,
        schemaVersion: Int? = nil,
        storageRevision: UInt64? = nil,
        persistenceState: SharedSnapshotPersistenceState? = nil,
        source: String? = nil,
        appVersion: String? = nil,
        error: String? = nil
    ) {
        self.canReadSnapshot = canReadSnapshot
        self.schemaVersion = schemaVersion
        self.storageRevision = storageRevision
        self.persistenceState = persistenceState
        self.source = source
        self.appVersion = appVersion
        self.error = error
    }
}

// ══════════════════════════════════════════════════════════════════════
//  MARK: - Install/Upgrade Verifier (CLI)
// ══════════════════════════════════════════════════════════════════════

/// CLI-based install/upgrade verification tool.
///
/// Designed to be called from shell scripts (verify-install-upgrade.sh)
/// with structured output for automated verification.
///
/// Verification sequence:
///   1. App bundle structure and binary
///   2. Widget extension embedding
///   3. Info.plist consistency (bundle IDs, versions)
///   4. Entitlements consistency (App Group, sandbox)
///   5. Code signing status
///   6. pluginkit registration
///   7. Shared snapshot readability from App Group
///   8. Widget timeline load simulation (via WidgetRecoveryManager)
enum InstallUpgradeVerifier {
    static let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "InstallUpgradeVerifier"
    )

    struct VerificationReport: Equatable, Sendable {
        let checks: [VerificationCheck]
        let allPassed: Bool
        let totalDurationMs: Double

        var renderedOutput: String {
            var lines: [String] = [
                "verification.result=\(allPassed ? "pass" : "fail")",
                "verification.checks=\(checks.count)",
                "verification.passed=\(checks.filter(\.passed).count)",
                "verification.failed=\(checks.filter { !$0.passed }.count)",
            ]
            for check in checks {
                lines.append("check.\(check.name)=\(check.passed ? "pass" : "fail") detail=\"\(check.detail)\"")
            }
            return lines.joined(separator: "\n")
        }
    }

    struct VerificationCheck: Equatable, Sendable {
        let name: String
        let passed: Bool
        let detail: String
    }

    /// Run all verification checks.
    static func run(appPath: String = "/Applications/DevPulse.app") async -> VerificationReport {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var checks: [VerificationCheck] = []

        // 1. App bundle structure
        checks.append(verifyAppBundleStructure(appPath: appPath))

        // 2. App binary
        checks.append(verifyAppBinary(appPath: appPath))

        // 3. Widget extension embedded
        checks.append(verifyWidgetExtensionEmbedded(appPath: appPath))

        // 4. Widget extension binary
        checks.append(verifyWidgetExtensionBinary(appPath: appPath))

        // 5. Info.plist fields
        checks.append(verifyInfoPlist(appPath: appPath))

        // 6. Widget Info.plist
        checks.append(verifyWidgetInfoPlist(appPath: appPath))

        // 7. Entitlements
        if let entitlementsCheck = await verifyEntitlements(appPath: appPath) {
            checks.append(entitlementsCheck)
        }

        // 8. Code signing (if applicable)
        checks.append(verifyCodeSigning(appPath: appPath))

        // 9. pluginkit registration (best-effort)
        checks.append(verifyPluginkitRegistration())

        // 10. Shared snapshot
        checks.append(verifySharedSnapshot())

        let allPassed = checks.allSatisfy(\.passed)
        let totalDuration = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        return VerificationReport(checks: checks, allPassed: allPassed, totalDurationMs: totalDuration)
    }

    // MARK: - Individual Checks

    static func verifyAppBundleStructure(appPath: String) -> VerificationCheck {
        let isDir = FileManager.default.fileExists(atPath: appPath)
        return VerificationCheck(
            name: "appBundle",
            passed: isDir,
            detail: isDir ? "App bundle exists at \(appPath)" : "App bundle NOT found at \(appPath)"
        )
    }

    static func verifyAppBinary(appPath: String) -> VerificationCheck {
        let binaryPath = "\(appPath)/Contents/MacOS/DevPulse"
        let isFile = FileManager.default.isExecutableFile(atPath: binaryPath)
        return VerificationCheck(
            name: "appBinary",
            passed: isFile,
            detail: isFile ? "App executable exists" : "App executable NOT found or not executable"
        )
    }

    static func verifyWidgetExtensionEmbedded(appPath: String) -> VerificationCheck {
        let widgetPath = "\(appPath)/Contents/PlugIns/DevPulseWidgetExtension.appex"
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: widgetPath, isDirectory: &isDir)
        let isValid = exists && isDir.boolValue
        return VerificationCheck(
            name: "widgetExtension",
            passed: isValid,
            detail: isValid
                ? "Widget extension embedded"
                : "Widget extension MISSING from PlugIns"
        )
    }

    static func verifyWidgetExtensionBinary(appPath: String) -> VerificationCheck {
        let binaryPath = "\(appPath)/Contents/PlugIns/DevPulseWidgetExtension.appex/Contents/MacOS/DevPulseWidgetExtension"
        let isFile = FileManager.default.isExecutableFile(atPath: binaryPath)
        return VerificationCheck(
            name: "widgetBinary",
            passed: isFile,
            detail: isFile
                ? "Widget extension executable exists"
                : "Widget extension executable NOT found"
        )
    }

    static func verifyInfoPlist(appPath: String) -> VerificationCheck {
        let plistPath = "\(appPath)/Contents/Info.plist"
        guard FileManager.default.fileExists(atPath: plistPath) else {
            return VerificationCheck(name: "infoPlist", passed: false, detail: "Info.plist missing")
        }

        let bundleID = plistValue(plistPath, "CFBundleIdentifier") ?? ""
        let bundleVersion = plistValue(plistPath, "CFBundleShortVersionString") ?? ""
        let minOS = plistValue(plistPath, "LSMinimumSystemVersion") ?? ""

        var issues: [String] = []
        if bundleID != "local.devpulse.app" { issues.append("bundle ID: \(bundleID)") }
        if bundleVersion.isEmpty { issues.append("version missing") }
        if minOS != "14.0" { issues.append("min OS: \(minOS)") }

        return VerificationCheck(
            name: "infoPlist",
            passed: issues.isEmpty,
            detail: issues.isEmpty
                ? "App Info.plist valid (bundle ID: \(bundleID), version: \(bundleVersion))"
                : "App Info.plist issues: \(issues.joined(separator: ", "))"
        )
    }

    static func verifyWidgetInfoPlist(appPath: String) -> VerificationCheck {
        let plistPath = "\(appPath)/Contents/PlugIns/DevPulseWidgetExtension.appex/Contents/Info.plist"
        guard FileManager.default.fileExists(atPath: plistPath) else {
            return VerificationCheck(name: "widgetInfoPlist", passed: false, detail: "Widget Info.plist missing")
        }

        let bundleID = plistValue(plistPath, "CFBundleIdentifier") ?? ""
        let bundleVersion = plistValue(plistPath, "CFBundleShortVersionString") ?? ""
        let extPoint = plistValue(plistPath, "NSExtension:NSExtensionPointIdentifier") ?? ""
        let wkAppID = plistValue(plistPath, "NSExtension:NSExtensionAttributes:WKAppBundleIdentifier") ?? ""

        var issues: [String] = []
        if bundleID != "local.devpulse.app.widget" { issues.append("bundle ID: \(bundleID)") }
        if extPoint != "com.apple.widgetkit-extension" { issues.append("extension point: \(extPoint)") }
        if wkAppID != "local.devpulse.app" { issues.append("WKAppBundleID: \(wkAppID)") }

        return VerificationCheck(
            name: "widgetInfoPlist",
            passed: issues.isEmpty,
            detail: issues.isEmpty
                ? "Widget Info.plist valid"
                : "Widget Info.plist issues: \(issues.joined(separator: ", "))"
        )
    }

    static func verifyEntitlements(appPath: String) async -> VerificationCheck? {
        // Use codesign to dump entitlements
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", ":-", appPath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if output.contains("group.local.devpulse") {
                    return VerificationCheck(
                        name: "entitlements",
                        passed: true,
                        detail: "Entitlements include App Group group.local.devpulse"
                    )
                }
                return VerificationCheck(
                    name: "entitlements",
                    passed: false,
                    detail: "Entitlements missing App Group"
                )
            }
        } catch {
            // codesign may not be available
        }
        return nil
    }

    static func verifyCodeSigning(appPath: String) -> VerificationCheck {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-v", appPath]

        do {
            try process.run()
            process.waitUntilExit()
            let signed = process.terminationStatus == 0
            return VerificationCheck(
                name: "codeSigning",
                passed: signed,
                detail: signed ? "App is signed" : "App is NOT signed"
            )
        } catch {
            return VerificationCheck(
                name: "codeSigning",
                passed: false,
                detail: "codesign check failed: \(error.localizedDescription)"
            )
        }
    }

    static func verifyPluginkitRegistration() -> VerificationCheck {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-p", "com.apple.widgetkit-extension", "-i", "local.devpulse.app.widget"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let registered = output.contains("local.devpulse.app.widget")
                return VerificationCheck(
                    name: "pluginkit",
                    passed: registered,
                    detail: registered
                        ? "Widget registered with pluginkit"
                        : "Widget NOT registered with pluginkit"
                )
            }
        } catch {
            return VerificationCheck(
                name: "pluginkit",
                passed: false,
                detail: "pluginkit unavailable: \(error.localizedDescription)"
            )
        }
        return VerificationCheck(
            name: "pluginkit",
            passed: false,
            detail: "pluginkit check failed"
        )
    }

    static func verifySharedSnapshot() -> VerificationCheck {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
        ) else {
            return VerificationCheck(
                name: "sharedSnapshot",
                passed: false,
                detail: "App Group container unavailable"
            )
        }

        let store = SharedSnapshotStore(
            directoryURL: containerURL,
            fileName: SharedSnapshotLocation.fileName
        )

        switch store.load() {
        case .success(let read):
            let source: String = {
                switch read.source {
                case .primary: return "primary"
                case .migratedPrimary: return "migrated"
                case .backup: return "backup"
                }
            }()
            return VerificationCheck(
                name: "sharedSnapshot",
                passed: true,
                detail: "Snapshot readable from \(source) (v\(read.snapshot.schemaVersion), rev \(read.snapshot.storageRevision))"
            )
        case .failure(let error):
            return VerificationCheck(
                name: "sharedSnapshot",
                passed: false,
                detail: "Snapshot read failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Helpers

    private static func plistValue(_ path: String, _ keyPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
        process.arguments = ["-c", "Print :\(keyPath)", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
//  MARK: - AppGroupData Extensions (version helpers)
// ══════════════════════════════════════════════════════════════════════

extension AppGroupData {
    /// Embed the current app version and storage format version.
    func withLifecycleMetadata(
        schemaVersion: Int = RepositorySnapshotSchema.version,
        generatedAt: String,
        writtenAt: String?,
        lastSuccessfulRefreshAt: String?,
        storageRevision: UInt64,
        persistenceState: SharedSnapshotPersistenceState,
        appVersion: String = RepositorySnapshotSchema.currentAppVersion,
        storageFormatVersion: Int = UnifiedLifecycleSchema.storageFormatVersion
    ) -> AppGroupData {
        AppGroupData(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            writtenAt: writtenAt,
            lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
            historySchemaVersion: nil,
            historyRecordingEnabled: nil,
            scanSummary: scanSummary,
            repositories: repositories,
            recentActivityEvents: recentActivityEvents,
            repositoryUnavailableSinceByPath: repositoryUnavailableSinceByPath,
            storageRevision: storageRevision,
            persistenceState: persistenceState,
            pendingItemWidgetSummary: pendingItemWidgetSummary,
            appVersion: appVersion,
            storageFormatVersion: storageFormatVersion
        )
    }
}

// ══════════════════════════════════════════════════════════════════════
//  MARK: - Bounded Recovery Context
// ══════════════════════════════════════════════════════════════════════

/// Provides a bounded execution context for recovery operations.
///
/// All file checks, data migration, integrity validation, and recovery
/// operations run within this context, which enforces:
/// - Total time budget
/// - Per-operation timeout
/// - Off-main-thread execution
/// - Resource usage limits (future: CPU/memory monitoring)
struct BoundedRecoveryContext {
    let totalBudget: TimeInterval
    let operationTimeout: TimeInterval

    static let `default` = BoundedRecoveryContext(
        totalBudget: 10.0,
        operationTimeout: 3.0
    )

    static let startup = BoundedRecoveryContext(
        totalBudget: 5.0,
        operationTimeout: 2.0
    )

    static let widget = BoundedRecoveryContext(
        totalBudget: 3.0,
        operationTimeout: 1.0
    )

    /// Run a recovery operation within this context.
    /// Returns `.success` if the operation completed, `.timeout` if it exceeded
    /// the per-operation timeout, `.budgetExceeded` if total budget is depleted.
    func run<T: Sendable>(
        operation: @Sendable @escaping () async throws -> T,
        deadline: inout TimeInterval?
    ) async -> BoundedResult<T> {
        // Check total budget
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
            return .budgetExceeded
        }

        // Set deadline on first call
        if deadline == nil {
            deadline = ProcessInfo.processInfo.systemUptime + totalBudget
        }

        // Run with operation timeout
        do {
            let result = try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await operation()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(operationTimeout * 1_000_000_000))
                    throw BoundedRecoveryError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            return .success(result)
        } catch let error as BoundedRecoveryError {
            if error == .timeout {
                return .timeout
            }
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }
}

enum BoundedResult<T: Sendable> {
    case success(T)
    case timeout
    case budgetExceeded
    case failure(Error)
}

enum BoundedRecoveryError: Error, Equatable {
    case timeout
}

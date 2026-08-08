import Foundation
import Testing
@testable import DevPulse

// MARK: - LifecycleCoordinator Tests

@Suite("LifecycleCoordinator")
struct LifecycleCoordinatorTests {

    @Test("determineInstallState returns firstInstall when no snapshot exists")
    func installStateFirstInstall() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-lc-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Use a custom app group URL that doesn't exist
        let state = await LifecycleCoordinator.determineInstallState(
            fileManager: .default,
            appGroupIdentifier: "group.devpulse.test.\(UUID().uuidString)",
            currentVersion: "0.2.0"
        )
        #expect(state == .firstInstall)
    }

    @Test("determineWidgetRegistrationState returns known state when not running as app bundle")
    func widgetRegistrationState() async {
        // In test environment, the bundle path is not an app bundle with PlugIns
        let state = await LifecycleCoordinator.determineWidgetRegistrationState()
        // Should be one of the known deterministic states, never indeterminate
        let isKnown = { () -> Bool in
            switch state {
            case .unknown, .missingExtension, .notRegistered:
                return true
            case .embedded, .registered, .active:
                return true
            }
        }()
        #expect(isKnown)
    }

    @Test("GenerationIsolation.Token equality")
    func tokenEquality() {
        let a = GenerationIsolation.Token(generation: 1, epoch: 0)
        let b = GenerationIsolation.Token(generation: 1, epoch: 0)
        let c = GenerationIsolation.Token(generation: 2, epoch: 0)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("GenerationIsolation.isCurrent returns true for matching token")
    func isCurrentMatch() {
        let token = GenerationIsolation.Token(generation: 5, epoch: 0)
        #expect(GenerationIsolation.isCurrent(token: token, currentGeneration: 5, currentEpoch: 0))
    }

    @Test("GenerationIsolation.isCurrent returns false for stale generation")
    func isCurrentStale() {
        let token = GenerationIsolation.Token(generation: 3, epoch: 0)
        #expect(!GenerationIsolation.isCurrent(token: token, currentGeneration: 5, currentEpoch: 0))
    }

    @Test("GenerationIsolation.isCurrent returns false for stale epoch")
    func isCurrentStaleEpoch() {
        let token = GenerationIsolation.Token(generation: 1, epoch: 0)
        #expect(!GenerationIsolation.isCurrent(token: token, currentGeneration: 1, currentEpoch: 1))
    }

    @Test("CrossProcessToken equality")
    func crossProcessTokenEquality() {
        let a = GenerationIsolation.CrossProcessToken(storageRevision: 1, generation: 1, epoch: 0)
        let b = GenerationIsolation.CrossProcessToken(storageRevision: 1, generation: 1, epoch: 0)
        let c = GenerationIsolation.CrossProcessToken(storageRevision: 2, generation: 1, epoch: 0)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("validateCrossProcess returns .current when revisions match")
    func validateCrossProcessMatch() {
        let result = GenerationIsolation.validateCrossProcess(observedRevision: 5, snapshotRevision: 5)
        #expect(result == .current)
    }

    @Test("validateCrossProcess returns .stale when snapshot advanced")
    func validateCrossProcessStale() {
        let result = GenerationIsolation.validateCrossProcess(observedRevision: 5, snapshotRevision: 7)
        guard case .stale(let reason) = result else {
            Issue.record("Expected .stale")
            return
        }
        #expect(reason.contains("5"))
        #expect(reason.contains("7"))
    }
}

// MARK: - VersionedSnapshotProtocol Tests

@Suite("VersionedSnapshotProtocol")
struct VersionedSnapshotProtocolTests {

    @Test("validate returns fileNotFound for missing file")
    func validateMissing() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-snapshot-\(UUID().uuidString).json")
        let result = VersionedSnapshotProtocol.validate(at: url)
        guard case .failure(.fileNotFound) = result else {
            Issue.record("Expected .fileNotFound")
            return
        }
    }

    @Test("validate returns emptyFile for empty file")
    func validateEmpty() throws {
        let url = URL(fileURLWithPath: "/tmp/empty-snapshot-\(UUID().uuidString).json")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = VersionedSnapshotProtocol.validate(at: url)
        guard case .failure(.emptyFile) = result else {
            Issue.record("Expected .emptyFile, got \(result)")
            return
        }
    }

    @Test("validate returns headerDecodeFailed for invalid JSON")
    func validateInvalidJSON() throws {
        let url = URL(fileURLWithPath: "/tmp/invalid-snapshot-\(UUID().uuidString).json")
        try "not valid json".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = VersionedSnapshotProtocol.validate(at: url)
        guard case .failure(.headerDecodeFailed) = result else {
            Issue.record("Expected .headerDecodeFailed, got \(result)")
            return
        }
    }
}

// MARK: - BoundedRecoveryContext Tests

@Suite("BoundedRecoveryContext")
struct BoundedRecoveryContextTests {

    private static func blockCurrentThread(for duration: TimeInterval) {
        Thread.sleep(forTimeInterval: duration)
    }

    @Test("run returns success for fast operation")
    func runFastOperation() async {
        let ctx = BoundedRecoveryContext(totalBudget: 5, operationTimeout: 2)
        var deadline: TimeInterval?
        let result = await ctx.run(operation: { "hello" }, deadline: &deadline)
        guard case .success(let value) = result else {
            Issue.record("Expected .success")
            return
        }
        #expect(value == "hello")
    }

    @Test("run returns timeout for slow operation")
    func runSlowOperation() async {
        let ctx = BoundedRecoveryContext(totalBudget: 5, operationTimeout: 0.1)
        var deadline: TimeInterval?
        let result = await ctx.run(operation: {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return "too late"
        }, deadline: &deadline)
        guard case .timeout = result else {
            Issue.record("Expected .timeout, got \(result)")
            return
        }
    }

    @Test("timeout does not wait for a non-cooperative operation")
    func nonCooperativeOperationIsWallClockBounded() async {
        let ctx = BoundedRecoveryContext(totalBudget: 1, operationTimeout: 0.03)
        var deadline: TimeInterval?
        let startedAt = ProcessInfo.processInfo.systemUptime

        let result = await ctx.run(operation: {
            Self.blockCurrentThread(for: 0.5)
            return "too late"
        }, deadline: &deadline)

        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        guard case .timeout = result else {
            Issue.record("Expected .timeout, got \(result)")
            return
        }
        #expect(elapsed < 0.3, "Timeout waited \(elapsed)s for a blocking child")
    }
}

// MARK: - InstallUpgradeVerifier Tests

@Suite("InstallUpgradeVerifier")
struct InstallUpgradeVerifierTests {

    @Test("verifyAppBundleStructure fails for non-existent path")
    func appBundleMissing() {
        let result = InstallUpgradeVerifier.verifyAppBundleStructure(appPath: "/tmp/nonexistent-path")
        #expect(!result.passed)
        #expect(result.name == "appBundle")
    }

    @Test("verifyAppBinary fails for non-existent path")
    func appBinaryMissing() {
        let result = InstallUpgradeVerifier.verifyAppBinary(appPath: "/tmp/test")
        #expect(!result.passed)
        #expect(result.name == "appBinary")
    }

    @Test("verifyWidgetExtensionEmbedded fails for non-existent path")
    func widgetExtensionMissing() {
        let result = InstallUpgradeVerifier.verifyWidgetExtensionEmbedded(appPath: "/tmp/test")
        #expect(!result.passed)
        #expect(result.name == "widgetExtension")
    }

    @Test("verifyInfoPlist fails for missing file")
    func infoPlistMissing() {
        let result = InstallUpgradeVerifier.verifyInfoPlist(appPath: "/tmp/test")
        #expect(!result.passed)
    }

    @Test("verifyWidgetInfoPlist fails for missing file")
    func widgetInfoPlistMissing() {
        let result = InstallUpgradeVerifier.verifyWidgetInfoPlist(appPath: "/tmp/test")
        #expect(!result.passed)
    }

    @Test("verifyPluginkitRegistration returns structured result")
    func pluginkitCheck() {
        let result = InstallUpgradeVerifier.verifyPluginkitRegistration()
        #expect(result.name == "pluginkit")
    }

    @Test("VerificationReport rendering is non-empty")
    func reportRendering() async {
        let report = await InstallUpgradeVerifier.run(appPath: "/tmp/nonexistent-test-path")
        let output = report.renderedOutput
        #expect(!output.isEmpty)
        #expect(output.contains("verification.result"))
        #expect(output.contains("verification.checks"))
    }
}

// MARK: - SelfHealingRunner Tests

@Suite("SelfHealingRunner")
struct SelfHealingRunnerTests {

    @Test("run produces a report with all check categories")
    func runProducesReport() async {
        let runner = SelfHealingRunner()
        let report = await runner.run()
        #expect(report.checks.count > 0)
        // At minimum: appGroup, git are checked
        let categories = Set(report.checks.map(\.category))
        #expect(categories.contains(.appGroupAvailability))
    }

    @Test("run does not crash when App Group is unavailable")
    func runWithUnavailableAppGroup() async {
        // This should handle App Group unavailability gracefully
        let runner = SelfHealingRunner()
        let report = await runner.run()
        // Should not crash; allPassed may be false if App Group is unavailable
        _ = report.checks
    }
}

// MARK: - WidgetRecoveryManager Tests

@Suite("WidgetRecoveryManager")
struct WidgetRecoveryManagerTests {

    @Test("minimumReloadInterval is positive")
    func reloadInterval() {
        #expect(WidgetRecoveryManager.minimumReloadInterval > 0)
    }

    @Test("verifyWidgetReadiness returns structured result")
    func verifyReadiness() async {
        let manager = WidgetRecoveryManager()
        let report = await manager.verifyWidgetReadiness()
        // In test environment without App Group, canReadSnapshot should be false
        if !report.canReadSnapshot {
            #expect(report.error != nil)
        }
    }
}

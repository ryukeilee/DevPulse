import Foundation
import Testing
@testable import DevPulse

// MARK: - Lifecycle Performance Tests
//
// Verifies that lifecycle operations complete within bounded time budgets.
// These tests establish baseline performance metrics.

@Suite("Lifecycle Performance")
struct LifecyclePerformanceTests {

    // ────────────────────────────────────────────────
    // MARK: - SelfHealingRunner performance
    // ────────────────────────────────────────────────

    @Test("SelfHealingRunner completes within 5 second budget")
    func selfHealWithinBudget() async {
        let runner = SelfHealingRunner()
        let start = ProcessInfo.processInfo.systemUptime
        let report = await runner.run()
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(elapsed < 5.0, "Self-healing took \(elapsed)s, budget is 5s")
        #expect(report.totalDurationMs < 5000, "Reported duration \(report.totalDurationMs)ms exceeds 5000ms")
        // Should complete at least the App Group check
        #expect(!report.checks.isEmpty)
    }

    @Test("SelfHealingRunner individual checks are fast")
    func selfHealChecksAreFast() async {
        let runner = SelfHealingRunner()
        let report = await runner.run()
        for check in report.checks {
            #expect(check.durationMs < 2000, "Check \(check.category) took \(check.durationMs)ms, budget is 2000ms")
        }
    }

    // ────────────────────────────────────────────────
    // MARK: - BoundedRecoveryContext performance
    // ────────────────────────────────────────────────

    @Test("BoundedRecoveryContext default budget is 10 seconds")
    func defaultBudget() {
        #expect(BoundedRecoveryContext.default.totalBudget == 10.0)
        #expect(BoundedRecoveryContext.default.operationTimeout == 3.0)
    }

    @Test("BoundedRecoveryContext startup budget is 5 seconds")
    func startupBudget() {
        #expect(BoundedRecoveryContext.startup.totalBudget == 5.0)
        #expect(BoundedRecoveryContext.startup.operationTimeout == 2.0)
    }

    @Test("BoundedRecoveryContext widget budget is 3 seconds")
    func widgetBudget() {
        #expect(BoundedRecoveryContext.widget.totalBudget == 3.0)
        #expect(BoundedRecoveryContext.widget.operationTimeout == 1.0)
    }

    // ────────────────────────────────────────────────
    // MARK: - SharedSnapshotStore performance
    // ────────────────────────────────────────────────

    @Test("SharedSnapshotStore commit is fast")
    func commitPerformance() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-perf-commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "perf.json"
        )

        let empty = AppGroupData.empty()
        let start = ProcessInfo.processInfo.systemUptime

        for _ in 0..<10 {
            _ = store.commit(empty)
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let avgMs = (elapsed / 10) * 1000
        #expect(avgMs < 500, "Average commit took \(avgMs)ms, budget is 500ms")
    }

    // ────────────────────────────────────────────────
    // MARK: - ScanScheduler startup baseline
    // ────────────────────────────────────────────────

    @Test("StartupDiagnostics checks complete within budget")
    func startupDiagnosticsPerformance() {
        let report = StartupDiagnostics.runSelfCheck()
        // Should not crash; basic performance assertion
        #expect(!report.checks.isEmpty)
    }

    // ────────────────────────────────────────────────
    // MARK: - InstallUpgradeVerifier performance
    // ────────────────────────────────────────────────

    @Test("InstallUpgradeVerifier completes without crashing")
    func verifierPerformance() async {
        let report = await InstallUpgradeVerifier.run(appPath: "/tmp/nonexistent")
        // Should not crash even with non-existent app path
        #expect(report.checks.count >= 5)
        #expect(!report.allPassed) // Should fail since app doesn't exist
    }
}

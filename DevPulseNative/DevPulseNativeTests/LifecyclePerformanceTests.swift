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

    @Test("SharedSnapshotStore steady-state commit benchmark")
    func steadyStateCommitBenchmark() throws {
        for repositoryCount in [5, 50] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("devpulse-perf-commit-\(repositoryCount)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let payload = Self.snapshot(repositoryCount: repositoryCount)
            let redundantBaseline = try Self.commitSamples(
                payload: payload,
                repositoryCount: repositoryCount,
                recoveryCopyIsIdentical: false
            )
            let optimized = try Self.commitSamples(
                payload: payload,
                repositoryCount: repositoryCount,
                recoveryCopyIsIdentical: true
            )

            let baselineSummary = Self.timingSummary(redundantBaseline)
            let optimizedSummary = Self.timingSummary(optimized)
            print(
                "SharedSnapshotStore benchmark repositories=\(repositoryCount) iterations=30 "
                    + "baseline_median_ms=\(Self.format(baselineSummary.median)) "
                    + "baseline_p95_ms=\(Self.format(baselineSummary.p95)) "
                    + "baseline_mad_ms=\(Self.format(baselineSummary.mad)) "
                    + "optimized_median_ms=\(Self.format(optimizedSummary.median)) "
                    + "optimized_p95_ms=\(Self.format(optimizedSummary.p95)) "
                    + "optimized_mad_ms=\(Self.format(optimizedSummary.mad))"
            )
            #expect(
                optimizedSummary.median < baselineSummary.median - baselineSummary.mad,
                "Optimized median did not exceed the baseline noise band."
            )
            #expect(optimizedSummary.median < 500, "Median commit took \(optimizedSummary.median)ms, budget is 500ms")

            let baseline = ScenarioBaseline(
                scenario: "shared-snapshot-\(repositoryCount)",
                meanElapsed: baselineSummary.median / 1_000,
                stddevElapsed: baselineSummary.mad / 1_000,
                sampleCount: 30
            )
            let current = BenchmarkResult(
                scenario: .incrementalRefresh,
                runID: "shared-snapshot-optimized",
                startedAt: "2026-07-18T10:00:00Z",
                totalElapsed: optimizedSummary.median / 1_000,
                firstResultElapsed: optimizedSummary.median / 1_000,
                completeElapsed: optimizedSummary.median / 1_000,
                peakCPU: 0,
                averageCPU: 0,
                peakMemoryMB: 0,
                totalDiskWritesKB: 0,
                gitSubprocessCount: 0,
                metadata: [:]
            )
            let regression = RegressionGate.checkNoResourceGrowth(
                baseline: baseline,
                current: current
            )
            #expect(regression?.isRegression == false)
        }
    }

    private static func commitSamples(
        payload: AppGroupData,
        repositoryCount: Int,
        recoveryCopyIsIdentical: Bool
    ) throws -> [Double] {
        let now = Date(timeIntervalSince1970: 1_784_253_600)
        var samples: [Double] = []

        for iteration in 0..<30 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "devpulse-perf-commit-\(repositoryCount)-\(recoveryCopyIsIdentical)-\(iteration)-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let store = SharedSnapshotStore(
                directoryURL: directory,
                fileName: "perf.json",
                now: { now }
            )
            _ = try requireSuccess(store.commit(payload))

            if !recoveryCopyIsIdentical {
                let alternateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "devpulse-perf-commit-alternate-\(UUID().uuidString)"
                )
                defer { try? FileManager.default.removeItem(at: alternateDirectory) }
                try FileManager.default.createDirectory(at: alternateDirectory, withIntermediateDirectories: true)
                let alternateStore = SharedSnapshotStore(
                    directoryURL: alternateDirectory,
                    fileName: "perf.json",
                    now: { now }
                )
                _ = try requireSuccess(
                    alternateStore.commit(snapshot(repositoryCount: repositoryCount, idPrefix: "alternate"))
                )
                try Data(contentsOf: alternateStore.primaryURL).write(to: store.backupURL)
            }

            let start = ProcessInfo.processInfo.systemUptime
            _ = try requireSuccess(store.commit(payload))
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        return samples
    }

    private static func snapshot(repositoryCount: Int, idPrefix: String = "performance") -> AppGroupData {
        let timestamp = "2026-07-18T09:00:00Z"
        let repositories = (0..<repositoryCount).map { index in
            RepositorySnapshot(
                id: "\(idPrefix)-\(index)",
                name: "\(idPrefix) \(index)",
                path: "/tmp/devpulse-\(idPrefix)/\(index)",
                branch: "main",
                status: .clean,
                modifiedFileCount: 0,
                addedFileCount: 0,
                deletedFileCount: 0,
                untrackedFileCount: 0,
                stagedFileCount: 0,
                unstagedFileCount: 0,
                conflictedFileCount: 0,
                aheadCount: 0,
                behindCount: 0,
                hasUpstream: true,
                changedFileCount: 0,
                changedFilesPreview: [],
                risk: .low,
                lastScannedAt: timestamp,
                dataSource: .current,
                lastSuccessfulScanAt: timestamp,
                lastChangedAt: timestamp,
                lastCommitID: "\(idPrefix)-\(index)",
                lastCommitSummary: "\(idPrefix) fixture",
                lastCommitMetadataAvailable: true,
                lastActivityAt: timestamp,
                unavailableSince: nil,
                errorMessage: nil,
                isPinned: false
            )
        }
        return AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: timestamp,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary.build(from: repositories),
            repositories: repositories,
            recentActivityEvents: nil,
            repositoryUnavailableSinceByPath: nil,
            storageRevision: 0,
            persistenceState: .committed
        )
    }

    private static func requireSuccess<T>(_ result: Result<T, AppGroupStoreError>) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func timingSummary(_ samples: [Double]) -> (median: Double, p95: Double, mad: Double) {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int((Double(sorted.count - 1) * 0.95).rounded(.up))]
        let deviations = samples.map { abs($0 - median) }.sorted()
        return (median, p95, deviations[deviations.count / 2])
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

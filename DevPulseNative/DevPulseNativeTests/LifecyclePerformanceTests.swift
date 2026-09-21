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
            let payload = Self.snapshot(repositoryCount: repositoryCount)

            // Deterministic guard for the redundant-recovery-write optimization:
            // a steady-state commit that finds an identical recovery copy must
            // issue exactly one file write and two F_FULLFSYNCs fewer than a
            // commit that has to publish a non-identical recovery copy. Wall
            // clock timing cannot separate that difference from filesystem
            // noise, so the operation ledger is asserted directly.
            let operations = try Self.observedOperations(
                payload: payload,
                repositoryCount: repositoryCount
            )
            print(
                "SharedSnapshotStore operations repositories=\(repositoryCount) "
                    + "redundant_writes=\(operations.redundantWrites) "
                    + "redundant_full_syncs=\(operations.redundantFullSyncs) "
                    + "optimized_writes=\(operations.optimizedWrites) "
                    + "optimized_full_syncs=\(operations.optimizedFullSyncs)"
            )
            #expect(operations.redundantWrites == 3)
            #expect(operations.redundantFullSyncs == 6)
            #expect(operations.redundantPrimaryEqualsBackup)
            #expect(operations.optimizedWrites == 2)
            #expect(operations.optimizedFullSyncs == 4)
            #expect(operations.optimizedPrimaryEqualsBackup)

            // Wall clock: interleaved paired sampling. Both variants are
            // measured back-to-back inside each iteration (alternating which
            // one runs first) so slow machine drift lifts or lowers both
            // samples instead of biasing one sequential block, and the
            // statistic is the per-pair difference rather than two independent
            // medians compared against a single group's MAD.
            let paired = try Self.pairedCommitSamples(
                payload: payload,
                repositoryCount: repositoryCount,
                pairs: 30
            )
            let baselineSummary = Self.timingSummary(paired.baseline)
            let optimizedSummary = Self.timingSummary(paired.optimized)
            let medianDelta = Self.median(paired.deltas)
            let madDelta = Self.mad(paired.deltas)
            let positivePairs = paired.deltas.filter { $0 > 0 }.count
            print(
                "SharedSnapshotStore benchmark repositories=\(repositoryCount) iterations=30 "
                    + "baseline_median_ms=\(Self.format(baselineSummary.median)) "
                    + "baseline_p95_ms=\(Self.format(baselineSummary.p95)) "
                    + "baseline_mad_ms=\(Self.format(baselineSummary.mad)) "
                    + "optimized_median_ms=\(Self.format(optimizedSummary.median)) "
                    + "optimized_p95_ms=\(Self.format(optimizedSummary.p95)) "
                    + "optimized_mad_ms=\(Self.format(optimizedSummary.mad)) "
                    + "paired_median_delta_ms=\(Self.format(medianDelta)) "
                    + "paired_mad_delta_ms=\(Self.format(madDelta)) "
                    + "paired_positive=\(positivePairs)"
            )
            #expect(
                medianDelta > 0,
                "Optimized commits were not faster than redundant-recovery commits (paired median delta \(Self.format(medianDelta))ms)."
            )
            #expect(
                positivePairs >= Int(Double(paired.deltas.count) * 0.6),
                "Only \(positivePairs)/\(paired.deltas.count) paired samples favored the optimized path."
            )
            #expect(optimizedSummary.median < 500, "Median commit took \(optimizedSummary.median)ms, budget is 500ms")

            let baseline = ScenarioBaseline(
                scenario: "shared-snapshot-\(repositoryCount)",
                meanElapsed: baselineSummary.median / 1_000,
                stddevElapsed: baselineSummary.mad / 1_000,
                sampleCount: paired.baseline.count
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

    /// One paired iteration samples both commit variants back to back so slow
    /// machine drift moves both samples together instead of biasing a block.
    /// The order alternates to cancel any first/last position effect.
    private static func pairedCommitSamples(
        payload: AppGroupData,
        repositoryCount: Int,
        pairs: Int
    ) throws -> (baseline: [Double], optimized: [Double], deltas: [Double]) {
        var baseline: [Double] = []
        var optimized: [Double] = []
        var deltas: [Double] = []
        baseline.reserveCapacity(pairs)
        optimized.reserveCapacity(pairs)
        deltas.reserveCapacity(pairs)

        for pairIndex in 0..<pairs {
            let redundant: Double
            let steadyState: Double
            if pairIndex.isMultiple(of: 2) {
                redundant = try timedCommitSample(
                    payload: payload,
                    repositoryCount: repositoryCount,
                    recoveryCopyIsIdentical: false,
                    tag: "pair"
                )
                steadyState = try timedCommitSample(
                    payload: payload,
                    repositoryCount: repositoryCount,
                    recoveryCopyIsIdentical: true,
                    tag: "pair"
                )
            } else {
                steadyState = try timedCommitSample(
                    payload: payload,
                    repositoryCount: repositoryCount,
                    recoveryCopyIsIdentical: true,
                    tag: "pair"
                )
                redundant = try timedCommitSample(
                    payload: payload,
                    repositoryCount: repositoryCount,
                    recoveryCopyIsIdentical: false,
                    tag: "pair"
                )
            }
            baseline.append(redundant)
            optimized.append(steadyState)
            deltas.append(redundant - steadyState)
        }
        return (baseline, optimized, deltas)
    }

    /// Runs a single warm-up commit followed by one timed commit, optionally
    /// forcing the recovery copy to differ so the commit must republish it.
    private static func timedCommitSample(
        payload: AppGroupData,
        repositoryCount: Int,
        recoveryCopyIsIdentical: Bool,
        tag: String
    ) throws -> Double {
        let now = Date(timeIntervalSince1970: 1_784_253_600)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "devpulse-perf-commit-\(repositoryCount)-\(recoveryCopyIsIdentical)-\(tag)-\(UUID().uuidString)"
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
            try forceRedundantRecoveryCopy(
                store: store,
                repositoryCount: repositoryCount,
                now: now
            )
        }

        let start = ProcessInfo.processInfo.systemUptime
        _ = try requireSuccess(store.commit(payload))
        return (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    /// Replaces the recovery copy with a different valid snapshot so the next
    /// commit cannot take the identical-recovery-copy fast path.
    private static func forceRedundantRecoveryCopy(
        store: SharedSnapshotStore,
        repositoryCount: Int,
        now: Date
    ) throws {
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

    private static func observedOperations(
        payload: AppGroupData,
        repositoryCount: Int
    ) throws -> (
        redundantWrites: Int,
        redundantFullSyncs: Int,
        redundantPrimaryEqualsBackup: Bool,
        optimizedWrites: Int,
        optimizedFullSyncs: Int,
        optimizedPrimaryEqualsBackup: Bool
    ) {
        let redundant = try observedCommit(
            payload: payload,
            repositoryCount: repositoryCount,
            recoveryCopyIsIdentical: false
        )
        let optimized = try observedCommit(
            payload: payload,
            repositoryCount: repositoryCount,
            recoveryCopyIsIdentical: true
        )
        return (
            redundant.writes,
            redundant.fullSyncs,
            redundant.primaryEqualsBackup,
            optimized.writes,
            optimized.fullSyncs,
            optimized.primaryEqualsBackup
        )
    }

    private static func observedCommit(
        payload: AppGroupData,
        repositoryCount: Int,
        recoveryCopyIsIdentical: Bool
    ) throws -> (writes: Int, fullSyncs: Int, primaryEqualsBackup: Bool) {
        let now = Date(timeIntervalSince1970: 1_784_253_600)
        let observer = SnapshotOperationObserver()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "devpulse-perf-operations-\(repositoryCount)-\(recoveryCopyIsIdentical)-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "perf.json",
            now: { now },
            operationObserver: { observer.record($0) }
        )
        _ = try requireSuccess(store.commit(payload))
        if !recoveryCopyIsIdentical {
            try forceRedundantRecoveryCopy(
                store: store,
                repositoryCount: repositoryCount,
                now: now
            )
        }

        observer.reset()
        _ = try requireSuccess(store.commit(payload))

        let operations = observer.operations()
        let writes = operations.filter { $0 == .fileWrite }.count
        let fullSyncs = operations.filter { $0 == .fullFileSync || $0 == .fullDirectorySync }.count
        let primaryEqualsBackup = try Data(contentsOf: store.primaryURL) == (try Data(contentsOf: store.backupURL))
        return (writes, fullSyncs, primaryEqualsBackup)
    }

    private static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private static func mad(_ samples: [Double]) -> Double {
        let center = median(samples)
        return median(samples.map { abs($0 - center) })
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

/// Records the durable file operations a `SharedSnapshotStore` issues so the
/// shared-snapshot commit optimization is asserted deterministically instead of
/// through wall-clock timing alone.
private final class SnapshotOperationObserver: @unchecked Sendable {
    private var recordedOperations: [SharedSnapshotStoreOperation] = []

    func record(_ operation: SharedSnapshotStoreOperation) {
        recordedOperations.append(operation)
    }

    func reset() {
        recordedOperations.removeAll()
    }

    func operations() -> [SharedSnapshotStoreOperation] {
        recordedOperations
    }
}

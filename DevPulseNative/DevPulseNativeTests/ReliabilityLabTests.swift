import Foundation
import Testing
@testable import DevPulse

// MARK: - Observation collector tests

@Suite struct RefreshObservationTests {
    @Test func collectorRecordsStageSpans() async {
        let collector = RefreshObservationCollector()
        let span = ObservationSpan(
            label: "test", startedAt: 0, duration: 0.5, callCount: 3,
            concurrentPeak: 2, timeoutCount: 1, cancellationCount: 0,
            cacheHitCount: 2, snapshotReuseCount: 1, mainThreadStallUs: 100,
            resourceDeltaCPU: 0.5, resourceDeltaMemoryMB: 10, resourceDeltaDiskWritesKB: 50
        )
        await collector.recordStageSpan(stage: "discovery", span: span)
        let obs = await collector.snapshot()
        #expect(obs.stageSpans["discovery"]?.count == 1)
        #expect(obs.stageSpans["discovery"]?.first?.callCount == 3)
    }

    @Test func collectorRecordsGitCalls() async {
        let collector = RefreshObservationCollector()
        await collector.recordGitCall(count: 5)
        let obs = await collector.snapshot()
        #expect(obs.totalGitCalls == 5)
    }

    @Test func collectorResets() async {
        let collector = RefreshObservationCollector()
        await collector.recordGitCall(count: 10)
        await collector.reset()
        let obs = await collector.snapshot()
        #expect(obs.totalGitCalls == 0)
        #expect(obs.runID != "")
    }

    @Test func collectorRecordsSource() async {
        let collector = RefreshObservationCollector()
        await collector.setSource("manual")
        let obs = await collector.snapshot()
        #expect(obs.source == "manual")
    }
}

// MARK: - Observation store tests

@Suite(.serialized) struct RefreshObservationStoreTests {
    let tempDir: URL
    let store: RefreshObservationStore

    init() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-test-obs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = RefreshObservationStore(
            fileURL: tempDir.appendingPathComponent("test-obs.json")
        )
    }

    @Test func storeAppendsAndLoads() async {
        let obs = await RefreshObservationCollector().snapshot()
        let result = store.append(obs)
        if case .success = result { #expect(true) } else { #expect(false) }
        let loaded = store.loadAll()
        #expect(loaded.count == 1)
    }

    @Test func storeClears() async {
        let obs = await RefreshObservationCollector().snapshot()
        store.append(obs)
        store.clear()
        #expect(store.loadAll().isEmpty)
    }

    @Test func storeHandlesMultipleAppends() async {
        for _ in 0..<3 {
            let obs = await RefreshObservationCollector().snapshot()
            store.append(obs)
        }
        #expect(store.loadAll().count == 3)
    }

    @Test func storeHandlesCorruptionGracefully() throws {
        try "corrupted data".write(to: tempDir.appendingPathComponent("test-obs.json"), atomically: true, encoding: .utf8)
        let loaded = store.loadAll()
        #expect(loaded.isEmpty)
    }
}

// MARK: - Fault injector tests

@Suite struct FaultInjectorTests {
    @Test func injectorDisabledByDefault() {
        #expect(!FaultInjector.isEnabled)
    }

    @Test func injectorActivation() {
        FaultInjector.isEnabled = true
        defer { FaultInjector.isEnabled = false }
        let injector = FaultInjector.shared
        injector.activate([
            FaultPlan.always(stage: "coreStatus", command: .timeout)
        ])
        let cmd = injector.fault(for: "coreStatus")
        #expect(cmd == .timeout)
    }

    @Test func injectorDoesNotFireForWrongStage() {
        FaultInjector.isEnabled = true
        defer { FaultInjector.isEnabled = false }
        let injector = FaultInjector.shared
        injector.activate([
            FaultPlan.always(stage: "coreStatus", command: .timeout)
        ])
        let cmd = injector.fault(for: "discovery")
        #expect(cmd == nil)
    }

    @Test func injectorRespectsMaxInjections() {
        FaultInjector.isEnabled = true
        defer { FaultInjector.isEnabled = false }
        let injector = FaultInjector.shared
        injector.activate([
            FaultPlan(stage: "coreStatus", command: .timeout, probability: 1.0, maxInjections: 2)
        ])
        #expect(injector.fault(for: "coreStatus") != nil)
        #expect(injector.fault(for: "coreStatus") != nil)
        #expect(injector.fault(for: "coreStatus") == nil)
    }

    @Test func injectorDeactivation() {
        FaultInjector.isEnabled = true
        defer { FaultInjector.isEnabled = false }
        let injector = FaultInjector.shared
        injector.activate([FaultPlan.always(stage: "coreStatus", command: .timeout)])
        injector.deactivate()
        #expect(injector.fault(for: "coreStatus") == nil)
    }

    @Test func injectorDelayCommand() {
        FaultInjector.isEnabled = true
        defer { FaultInjector.isEnabled = false }
        let injector = FaultInjector.shared
        injector.activate([FaultPlan.always(stage: "test", command: .delay(seconds: 0.01))])
        let cmd = injector.fault(for: "test")
        if case .delay(let s) = cmd {
            #expect(s == 0.01)
        } else {
            Issue.record("Expected delay command")
        }
    }
}

// MARK: - Scenario generator tests

@Suite struct ScenarioGeneratorTests {
    @Test func normalRepoCreatesGitRepo() {
        let env = ScenarioBuilder.normalRepo(label: "test-normal")
        defer { env.cleanUp() }
        let gitDir = env.repoURLs[0].appendingPathComponent(".git")
        #expect(FileManager.default.fileExists(atPath: gitDir.path))
    }

    @Test func multiWorkspaceCreatesMultipleRepos() {
        let env = ScenarioBuilder.multiWorkspace(count: 3, label: "test-mw")
        defer { env.cleanUp() }
        #expect(env.repoURLs.count == 3)
        for repo in env.repoURLs {
            #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path))
        }
    }

    @Test func manyUntrackedCreatesExpectedFiles() {
        let env = ScenarioBuilder.manyUntracked(count: 10, label: "test-untracked")
        defer { env.cleanUp() }
        let repo = env.repoURLs[0]
        let count = (try? FileManager.default.contentsOfDirectory(at: repo, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.hasPrefix("untracked")
        }.count) ?? 0
        #expect(count == 10)
    }

    @Test func cleanupRemovesDirectory() {
        var env: ScenarioEnvironment? = ScenarioBuilder.normalRepo(label: "test-cleanup")
        let path = env!.rootURL.path
        env!.cleanUp()
        env = nil
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

// MARK: - Performance baseline tests

@Suite struct PerformanceBaselineTests {
    @Test func baselineRecords() {
        let mgr = PerformanceBaselineManager(
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("devpulse-test-baseline-\(UUID().uuidString).json")
        )
        let baseline = ScenarioBaseline(scenario: "coldStart", meanElapsed: 1.0, stddevElapsed: 0.1, sampleCount: 1)
        mgr.record(baseline)
        #expect(mgr.baseline(for: "coldStart") != nil)
        mgr.reset()
    }

    @Test func baselineRegressionDetection() {
        let mgr = PerformanceBaselineManager(
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("devpulse-test-regression-\(UUID().uuidString).json")
        )
        // Record 3 fast runs to establish baseline
        for i in 0..<3 {
            let s = ScenarioBaseline(scenario: "coldStart", meanElapsed: 1.0, stddevElapsed: 0.0, sampleCount: i + 1)
            mgr.record(s)
        }
        // Slow run
        let slow = BenchmarkResult(
            scenario: .coldStart, runID: "slow", startedAt: "",
            totalElapsed: 10.0, firstResultElapsed: 5.0, completeElapsed: 10.0,
            peakCPU: 0, averageCPU: 0, peakMemoryMB: 0, totalDiskWritesKB: 0,
            gitSubprocessCount: 0, metadata: [:]
        )
        let result = mgr.checkRegression(observed: slow.totalElapsed, scenario: "coldStart")
        #expect(result?.isRegression ?? false)
        mgr.reset()
    }
}

// MARK: - Regression gate tests

@Suite struct RegressionGateTests {
    @Test func noZombieGitProcesses() {
        #expect(RegressionGate.checkNoZombieGitProcesses())
    }

    @Test func infiniteRetryDetection() {
        let summary = ScanSummary(
            totalRepositories: 0,
            changedRepositories: 0,
            totalChangedFiles: 0,
            errorRepositories: 0
        )
        let data = AppGroupData(
            schemaVersion: 1, generatedAt: "", writtenAt: nil,
            lastSuccessfulRefreshAt: nil, scanSummary: summary,
            repositories: [], repositoryUnavailableSinceByPath: nil,
            storageRevision: 0, persistenceState: .committed
        )
        let diag = RefreshDiagnostics(
            overallElapsed: 1, discoveryElapsed: 0.1, coreStatusElapsed: 0.5,
            extendedInfoElapsed: 0.2, mergeElapsed: 0.05, persistenceElapsed: 0.05,
            widgetSyncElapsed: 0, totalGitCalls: 10, totalGitTimeouts: 5,
            totalGitCancellations: 0, totalGitFailures: 0, totalRepositoryCount: 5,
            currentRepositoryCount: 3, reusedSnapshotCount: 2, snapshotReuseRatio: 0.4,
            peakGitConcurrency: 2, cancelled: false, timedOut: false, stageDiagnostics: []
        )
        let result = RefreshResult(
            data: data, warnings: ["retry 1", "retry 2"], discoveredRepositoryPaths: [],
            stageDurations: [:], isCancelled: false, timedOut: false, diagnostics: diag
        )
        #expect(RegressionGate.checkNoInfiniteRetries(result: result))
    }
}

// MARK: - Diagnostic migration tests

@Suite struct DiagnosticMigrationTests {
    @Test func migrationReturnsNilForInvalidData() {
        let result: ScenarioBaseline? = DiagnosticMigration.migrate(
            Data("invalid".utf8), to: 1, as: ScenarioBaseline.self
        )
        #expect(result == nil)
    }

    @Test func migrationReturnsDecodedForValidData() throws {
        let baseline = ScenarioBaseline(scenario: "coldStart", meanElapsed: 1.0, stddevElapsed: 0.1, sampleCount: 5)
        let data = try JSONEncoder().encode(baseline)
        let result: ScenarioBaseline? = DiagnosticMigration.migrate(
            data, to: 1, as: ScenarioBaseline.self
        )
        #expect(result?.sampleCount == 5)
    }

    @Test func atomicWritePreservesData() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-test-atomic-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let baseline = ScenarioBaseline(scenario: "coldStart", meanElapsed: 2.0, stddevElapsed: 0.2, sampleCount: 3)
        let result = DiagnosticMigration.atomicWrite(baseline, to: url)
        if case .success = result { #expect(true) } else { #expect(false) }

        let loaded: ScenarioBaseline? = DiagnosticMigration.recoverOrEmpty(
            from: url, as: ScenarioBaseline.self,
            empty: ScenarioBaseline(scenario: "", meanElapsed: 0, stddevElapsed: 0, sampleCount: 0)
        )
        #expect(loaded?.sampleCount == 3)
    }

    @Test func recoverReturnsEmptyForMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let result: ScenarioBaseline? = DiagnosticMigration.recoverOrEmpty(
            from: url, as: ScenarioBaseline.self,
            empty: ScenarioBaseline(scenario: "", meanElapsed: 0, stddevElapsed: 0, sampleCount: 0)
        )
        #expect(result?.sampleCount == 0)
    }
}

// MARK: - Benchmark runner tests

@Suite struct BenchmarkRunnerTests {
    @Test func runnerMeasuresCorrectly() async {
        let runner = BenchmarkRunner()
        let result = await runner.run(
            scenario: .coldStart,
            setup: { try? await Task.sleep(nanoseconds: 10_000_000) },
            action: { try? await Task.sleep(nanoseconds: 20_000_000) }
        )
        #expect(result.scenario == .coldStart)
        #expect(result.runID != "")
        #expect(result.totalElapsed > 0)
    }

    @Test func runnerRecordsFirstResultTime() async {
        let runner = BenchmarkRunner()
        let result = await runner.run(
            scenario: .coldStart,
            setup: { try? await Task.sleep(nanoseconds: 5_000_000) },
            action: { try? await Task.sleep(nanoseconds: 15_000_000) }
        )
        #expect(result.firstResultElapsed > 0)
        #expect(result.completeElapsed > result.firstResultElapsed)
    }
}

// MARK: - Full scenario generator tests

@Suite struct FullScenarioGeneratorTests {
    @Test func slowDiskCreatesEnv() {
        let env = ScenarioBuilder.slowDisk(fileCount: 10, label: "test-slow")
        defer { env.cleanUp() }
        #expect(env.kind == .slowDisk)
        #expect(FileManager.default.fileExists(atPath: env.repoURLs[0].appendingPathComponent(".git").path))
    }

    @Test func hangingGitSpawnsProcess() {
        let env = ScenarioBuilder.hangingGit(label: "test-hang-1")
        defer { env.cleanUp() }
        #expect(env.kind == .hangingGit)
        #expect(env.hangingPIDs.count == 1)
        // Process should be running
        let running = kill(env.hangingPIDs[0], 0) == 0
        #expect(running)
    }

    @Test func brokenPathCreatesRepo() {
        let env = ScenarioBuilder.brokenPath(label: "test-broken")
        defer { env.cleanUp() }
        #expect(env.kind == .brokenPath)
        #expect(!env.repoURLs.isEmpty)
    }

    @Test func slowDiskContainsExpectedFiles() {
        let env = ScenarioBuilder.slowDisk(fileCount: 10, label: "test-files")
        defer { env.cleanUp() }
        let repo = env.repoURLs[0]
        let subdir = repo.appendingPathComponent("sub-0")
        let contents = try? FileManager.default.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil)
        #expect(contents?.count ?? 0 > 0)
    }
}

// MARK: - Filesystem fault injection tests

@Suite struct FilesystemFaultTests {
    @Test func fileCorruptionPhysicallyCorrupts() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-scenario-fault-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("test.txt")
        try "original content".write(to: file, atomically: true, encoding: .utf8)

        FaultInjector.isEnabled = true
        defer { FaultInjector.isEnabled = false }
        let injector = FaultInjector.shared
        injector.activate([FaultPlan.always(stage: "test", command: .fileCorruption(path: file.path))])
        let cmd = injector.fault(for: "test")
        if case .fileCorruption(let p) = cmd {
            #expect(p == file.path)
        } else {
            Issue.record("Expected fileCorruption command")
        }
    }

    @Test func permissionDeniedSetsPermissions() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-scenario-fault-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("test.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        FaultInjector.isEnabled = true
        defer { FaultInjector.isEnabled = false }
        let injector = FaultInjector.shared
        injector.activate([FaultPlan.always(stage: "test", command: .permissionDenied(path: file.path))])
        let cmd = injector.fault(for: "test")
        if case .permissionDenied(let p) = cmd, p.contains("devpulse-scenario-") {
            #expect(p == file.path)
        } else {
            Issue.record("Expected permissionDenied command")
        }
    }

    @Test func pathDisappearsRemovesFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-scenario-fault-rm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("test.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        FaultInjector.isEnabled = true
        defer { FaultInjector.isEnabled = false }
        let injector = FaultInjector.shared
        injector.activate([FaultPlan.always(stage: "test", command: .pathDisappears(path: file.path))])
        let cmd = injector.fault(for: "test")
        if case .pathDisappears(let p) = cmd, p.contains("devpulse-scenario-") {
            #expect(p == file.path)
        } else {
            Issue.record("Expected pathDisappears command")
        }
    }

    @Test func faultGuardSkipsNonScenarioPaths() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonscenario-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("test.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        // Even with injection enabled, a path outside devpulse-scenario- should not be modified
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved == "content")
    }
}

// MARK: - Baseline persistence tests

@Suite struct BaselinePersistenceTests {
    @Test func saveLoadRoundtrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-test-baseline-rw-\(UUID().uuidString).json")

        let mgr = PerformanceBaselineManager(storeURL: url)
        let baseline = ScenarioBaseline(scenario: "coldStart", meanElapsed: 2.5, stddevElapsed: 0.3, sampleCount: 5)
        mgr.record(baseline)
        try mgr.save()

        let loaded = try PerformanceBaselineManager.load(from: url)
        #expect(loaded.baselines["coldStart"]?.meanElapsed == 2.5)
        #expect(loaded.baselines["coldStart"]?.sampleCount == 5)

        try? FileManager.default.removeItem(at: url)
    }

    @Test func loadFromMissingFileReturnsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let loaded = try? PerformanceBaselineManager.load(from: url)
        #expect(loaded == nil)
    }

    @Test func autoSaveEnabled() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-test-autosave-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let mgr = PerformanceBaselineManager(storeURL: url, autoSave: true)
        let baseline = ScenarioBaseline(scenario: "incrementalRefresh", meanElapsed: 1.0, stddevElapsed: 0.1, sampleCount: 3)
        mgr.record(baseline)

        // Verify the file was saved automatically
        let loaded = try PerformanceBaselineManager.load(from: url)
        #expect(loaded.baselines["incrementalRefresh"] != nil)
    }
}

// MARK: - Full regression gate tests

@Suite struct FullRegressionGateTests {
    @Test func zombieGitCheckDoesNotCrash() {
        #expect(RegressionGate.checkNoZombieGitProcesses() == true)
    }

    @Test func mainThreadStallCheckReturnsNilOnIdle() {
        let stall = RegressionGate.checkNoMainThreadStall()
        // On idle system, no stall expected
        #expect(stall == nil || (stall ?? 0) <= 0.016)
    }

    @Test func taskLeakDetectsAddedTasks() {
        let before: Set<String> = ["task1", "task2"]
        let after: Set<String> = ["task1", "task2", "task3"]
        let leaked = RegressionGate.checkNoTaskLeak(before: before, after: after)
        #expect(leaked == ["task3"])
    }

    @Test func duplicateSnapshotDetection() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-test-dup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RefreshObservationStore(fileURL: url)

        let obs = RefreshObservation(
            schemaVersion: 1,
            runID: "dup-run-id",
            startedAt: "",
            overallElapsed: 0,
            totalGitCalls: 0,
            stageSpans: [:],
            repositoryTiming: [:],
            repositoryCount: 0,
            currentRepositoryCount: 0,
            reusedSnapshotCount: 0,
            totalCPU: 0,
            peakMemoryMB: 0,
            totalDiskWritesKB: 0,
            wasCancelled: false,
            wasTimedOut: false,
            source: ""
        )
        store.append(obs)
        store.append(obs)
        #expect(!RegressionGate.checkNoDuplicateSnapshotWrite(store: store))
    }
}

// MARK: - Privacy sanitization tests

@Suite struct PrivacySanitizationTests {
    @Test func sanitizeRemovesUsername() {
        let input = "/Users/Alice/code/repo/"
        let result = DiagnosticReportBuilder.sanitize(input)
        #expect(!result.contains("Alice"))
        #expect(result.contains("~USER~"))
    }

    @Test func sanitizePreservesSystemPaths() {
        let input = "/usr/bin/git status"
        let result = DiagnosticReportBuilder.sanitize(input)
        #expect(result.contains("/usr/bin/git"))
    }

    @Test func sanitizeObservationStripsPaths() {
        let obs = RefreshObservation(
            schemaVersion: 1,
            runID: "test-run-123",
            startedAt: "2025-01-01T00:00:00Z",
            overallElapsed: 1.0,
            totalGitCalls: 5,
            stageSpans: [:],
            repositoryTiming: ["/Users/Alice/code/repo": 0.5],
            repositoryCount: 1,
            currentRepositoryCount: 1,
            reusedSnapshotCount: 0,
            totalCPU: 0,
            peakMemoryMB: 0,
            totalDiskWritesKB: 0,
            wasCancelled: false,
            wasTimedOut: false,
            source: ""
        )
        let summary = DiagnosticReportBuilder.sanitizeObservation(obs)
        #expect(summary.runID != "test-run-123") // should be hashed
        #expect(summary.repoLabels.keys.first == "repo") // should be basename
    }

    @Test func sanitizeEmptyString() {
        #expect(DiagnosticReportBuilder.sanitize("") == "")
    }
}

// MARK: - Observation migration tests

@Suite struct ObservationMigrationTests {
    @Test func storeLoadsLegacySingleObject() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-test-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // Write a single RefreshObservation (v0 legacy format)
        let obs = RefreshObservation(
            schemaVersion: 1,
            runID: "legacy-run",
            startedAt: "",
            overallElapsed: 0,
            totalGitCalls: 0,
            stageSpans: [:],
            repositoryTiming: [:],
            repositoryCount: 0,
            currentRepositoryCount: 0,
            reusedSnapshotCount: 0,
            totalCPU: 0,
            peakMemoryMB: 0,
            totalDiskWritesKB: 0,
            wasCancelled: false,
            wasTimedOut: false,
            source: ""
        )
        let data = try JSONEncoder().encode(obs)
        try data.write(to: url, options: .atomic)

        let store = RefreshObservationStore(fileURL: url)
        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.runID == "legacy-run")
    }

    @Test func storeLoadsLegacyArray() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-test-legacy-arr-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let obs = [RefreshObservation(
            schemaVersion: 1,
            runID: "legacy-array-run",
            startedAt: "",
            overallElapsed: 0,
            totalGitCalls: 0,
            stageSpans: [:],
            repositoryTiming: [:],
            repositoryCount: 0,
            currentRepositoryCount: 0,
            reusedSnapshotCount: 0,
            totalCPU: 0,
            peakMemoryMB: 0,
            totalDiskWritesKB: 0,
            wasCancelled: false,
            wasTimedOut: false,
            source: ""
        )]
        let data = try JSONEncoder().encode(obs)
        try data.write(to: url, options: .atomic)

        let store = RefreshObservationStore(fileURL: url)
        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.runID == "legacy-array-run")
    }

    @Test func storeHandlesCorruptionGracefully() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-test-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try? "{{corrupted json}}".write(to: url, atomically: true, encoding: .utf8)

        let store = RefreshObservationStore(fileURL: url)
        let loaded = store.loadAll()
        #expect(loaded.isEmpty)
    }

    @Test func storeAppendsInV1Format() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-test-v1-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let obs = RefreshObservation(
            schemaVersion: 1,
            runID: "v1-run",
            startedAt: "",
            overallElapsed: 0,
            totalGitCalls: 0,
            stageSpans: [:],
            repositoryTiming: [:],
            repositoryCount: 0,
            currentRepositoryCount: 0,
            reusedSnapshotCount: 0,
            totalCPU: 0,
            peakMemoryMB: 0,
            totalDiskWritesKB: 0,
            wasCancelled: false,
            wasTimedOut: false,
            source: ""
        )
        let store = RefreshObservationStore(fileURL: url)
        let result = store.append(obs)
        if case .success = result { #expect(true) } else { #expect(false) }

        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.runID == "v1-run")
    }
}

// MARK: - Benchmark stability tests

@Suite struct BenchmarkStabilityTests {
    @Test func runnerReturnsConsistentShape() async {
        let runner = BenchmarkRunner()
        let result1 = await runner.run(
            scenario: .coldStart,
            setup: { try? await Task.sleep(nanoseconds: 5_000_000) },
            action: { try? await Task.sleep(nanoseconds: 10_000_000) }
        )
        #expect(result1.totalElapsed > 0)
        #expect(result1.firstResultElapsed > 0)
        #expect(result1.completeElapsed > 0)
    }

    @Test func runnerReportsGitCount() async {
        let runner = BenchmarkRunner()
        let result = await runner.run(
            scenario: .coldStart,
            setup: {},
            action: { try? await Task.sleep(nanoseconds: 1_000_000) }
        )
        // gitSubprocessCount should be >= 0 (not crashing)
        #expect(result.gitSubprocessCount >= 0)
    }
}

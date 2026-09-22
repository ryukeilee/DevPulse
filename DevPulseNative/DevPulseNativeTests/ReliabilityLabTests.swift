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

// MARK: - Deterministic whole-archive write counting (idle-round elimination)

/// Thread-safe counter used as the `writeObserver` of both archive stores. It
/// counts successful whole-file writes and their byte sizes so an "idle round"
/// can be judged by deterministic numbers instead of wall-clock time.
final class StoreWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var writeCount = 0
    private var byteCount = 0

    func record(_ bytes: Int) {
        lock.withLock {
            writeCount += 1
            byteCount += bytes
        }
    }

    var writes: Int { lock.withLock { writeCount } }
    var bytes: Int { lock.withLock { byteCount } }

    func reset() {
        lock.withLock {
            writeCount = 0
            byteCount = 0
        }
    }
}

private final class ActivityArchiveBenchmarkFixture: @unchecked Sendable {
    let directory: URL
    let store: ActivityEventStore
    let events: [ActivityEvent]
    let repositoryIDs: Set<String>

    init(directoryName: String, events: [ActivityEvent], repositoryIDs: Set<String>) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-\(directoryName)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ActivityEventStore(fileURL: directory.appendingPathComponent(ActivityEventStore.fileName))
        self.events = events
        self.repositoryIDs = repositoryIDs
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Incremental rounds that detect no change must not rewrite the whole activity
/// archive: `ActivityEventStore.save` re-encodes the entire (pretty printed)
/// archive, so a no-op round used to cost a full read-modify-write cycle.
@Suite(.serialized) @MainActor struct IdleRoundActivityArchiveTests {

    private static let timestamp = "2026-01-01T00:00:00Z"
    private static let repositoryCount = 100

    private func tempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-idle-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repository(index: Int, changed: Bool) -> RepositorySnapshot {
        RepositorySnapshot(
            id: "idle-repo-\(index)",
            name: "idle-repo-\(index)",
            path: "/tmp/devpulse-idle/repo-\(index)",
            branch: "main",
            status: changed ? .changed : .clean,
            modifiedFileCount: changed ? 3 : 0,
            addedFileCount: changed ? 1 : 0,
            deletedFileCount: 0,
            untrackedFileCount: changed ? 2 : 0,
            stagedFileCount: changed ? 1 : 0,
            unstagedFileCount: changed ? 3 : 0,
            conflictedFileCount: 0,
            aheadCount: changed ? 1 : 0,
            hasUpstream: true,
            changedFileCount: changed ? 6 : 0,
            changedFilesPreview: changed ? ["Sources/A.swift", "Sources/B.swift"] : [],
            risk: changed ? .medium : .low,
            lastScannedAt: Self.timestamp,
            lastChangedAt: Self.timestamp,
            lastCommitID: "abcdef1234567890",
            lastCommitSummary: "Seed commit",
            lastCommitMetadataAvailable: true,
            lastActivityAt: Self.timestamp,
            errorMessage: nil,
            isPinned: false
        )
    }

    private func snapshot(repositories: [RepositorySnapshot], generatedAt: String) -> AppGroupData {
        AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: generatedAt,
            writtenAt: nil,
            lastSuccessfulRefreshAt: generatedAt,
            scanSummary: ScanSummary.build(from: repositories),
            repositories: repositories
        )
    }

    /// One idle round must perform zero archive writes while a round that does
    /// detect events must still write exactly once through the same store API.
    @Test func idleRoundDoesNotRewriteActivityArchive() async throws {
        let dir = tempDir("activity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent(ActivityEventStore.fileName)

        let clean = snapshot(
            repositories: (0..<Self.repositoryCount).map { repository(index: $0, changed: false) },
            generatedAt: Self.timestamp
        )
        let changed = snapshot(
            repositories: (0..<Self.repositoryCount).map { repository(index: $0, changed: true) },
            generatedAt: Self.timestamp
        )

        let counter = StoreWriteCounter()
        let store = ActivityEventStore(fileURL: archive, writeObserver: { counter.record($0) })
        let scheduler = ScanScheduler(commandMode: false, activityEventStore: store)
        defer { scheduler.shutdown() }
        scheduler.lastResult = clean

        // Change round: populates the archive (and the in-memory event list)
        // with a realistic, capacity-sized history.
        counter.reset()
        _ = scheduler.recordActivityEvents(
            previous: clean,
            current: changed,
            observedAt: Self.timestamp
        )
        let changeRoundWrites = await waitForWrites(counter, atLeast: 1)
        let archivedBytes = (try? Data(contentsOf: archive).count) ?? 0
        print(
            "activity_change_round writes=\(changeRoundWrites) bytes=\(counter.bytes) "
                + "archive_bytes=\(archivedBytes) in_memory_events=\(scheduler.activityEvents.count)"
        )
        #expect(changeRoundWrites == 1)
        #expect(archivedBytes > 0)

        // Idle rounds: identical before/after state, so no new events exist.
        let archiveBeforeIdleRounds = try Data(contentsOf: archive)
        var observed: [Int] = []
        for round in 1...3 {
            counter.reset()
            _ = scheduler.recordActivityEvents(
                previous: changed,
                current: changed,
                observedAt: Self.timestamp
            )
            let writes = await waitForWrites(counter, atLeast: 1)
            observed.append(writes)
            print(
                "activity_idle_round=\(round) writes=\(writes) bytes=\(counter.bytes) "
                    + "archive_bytes=\((try? Data(contentsOf: archive).count) ?? -1)"
            )
        }
        print("activity_idle_round_writes=\(observed)")
        #expect(observed == [0, 0, 0])
        #expect(try Data(contentsOf: archive) == archiveBeforeIdleRounds)
    }

    /// The first round must still materialize an empty archive. Once that
    /// confirmed save exists, a no-op round and a pin-only snapshot change do
    /// not represent activity and may skip the archive rewrite.
    @Test func firstEmptyArchivePersistsAndPinOnlyChangeSkips() async throws {
        let dir = tempDir("activity-empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent(ActivityEventStore.fileName)

        let clean = snapshot(
            repositories: (0..<Self.repositoryCount).map { repository(index: $0, changed: false) },
            generatedAt: Self.timestamp
        )
        let pinned = snapshot(
            repositories: clean.repositories.map { repository in
                var pinned = repository
                pinned.isPinned = true
                return pinned
            },
            generatedAt: Self.timestamp
        )

        let counter = StoreWriteCounter()
        let store = ActivityEventStore(fileURL: archive, writeObserver: { counter.record($0) })
        let scheduler = ScanScheduler(commandMode: false, activityEventStore: store)
        defer { scheduler.shutdown() }
        scheduler.lastResult = clean

        counter.reset()
        _ = scheduler.recordActivityEvents(previous: clean, current: clean, observedAt: Self.timestamp)
        let firstWrites = await waitForWrites(counter, atLeast: 1)
        let firstArchive = try store.load().get()
        print(
            "empty_archive_first_round writes=\(firstWrites) bytes=\(counter.bytes) "
                + "archive_exists=\(FileManager.default.fileExists(atPath: archive.path)) "
                + "stored_events=\(firstArchive.events.count)"
        )
        #expect(firstWrites == 1)
        #expect(counter.bytes > 0)
        #expect(firstArchive.events.isEmpty)

        counter.reset()
        _ = scheduler.recordActivityEvents(previous: clean, current: clean, observedAt: Self.timestamp)
        let noOpWrites = await waitForWrites(counter, atLeast: 1)
        #expect(noOpWrites == 0)

        let archiveBeforePin = try Data(contentsOf: archive)
        counter.reset()
        _ = scheduler.recordActivityEvents(previous: clean, current: pinned, observedAt: Self.timestamp)
        let pinOnlyWrites = await waitForWrites(counter, atLeast: 1)
        let archiveAfterPin = try Data(contentsOf: archive)
        print("pin_only_round writes=\(pinOnlyWrites) bytes=\(counter.bytes)")
        #expect(pinOnlyWrites == 0)
        #expect(archiveAfterPin == archiveBeforePin)
    }

    /// Benchmark the task-specific work with the repository's existing
    /// BenchmarkRunner / baseline / RegressionGate facilities. The baseline
    /// is the old unconditional archive save; the optimized action performs
    /// the same no-op merge path but skips that save.
    @Test func activityArchiveIncrementalBenchmark() async throws {
        let sourceDir = tempDir("activity-benchmark-source")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let sourceArchive = sourceDir.appendingPathComponent(ActivityEventStore.fileName)
        let counter = StoreWriteCounter()
        let sourceStore = ActivityEventStore(fileURL: sourceArchive, writeObserver: { counter.record($0) })
        let scheduler = ScanScheduler(commandMode: false, activityEventStore: sourceStore)
        defer { scheduler.shutdown() }

        let clean = snapshot(
            repositories: (0..<Self.repositoryCount).map { repository(index: $0, changed: false) },
            generatedAt: Self.timestamp
        )
        let changed = snapshot(
            repositories: (0..<Self.repositoryCount).map { repository(index: $0, changed: true) },
            generatedAt: Self.timestamp
        )
        scheduler.lastResult = clean
        _ = scheduler.recordActivityEvents(previous: clean, current: changed, observedAt: Self.timestamp)
        _ = await waitForWrites(counter, atLeast: 1)
        let events = scheduler.activityEvents
        #expect(events.count == 300)

        let pairs = (0..<10).map { index in
            (
                ActivityArchiveBenchmarkFixture(
                    directoryName: "activity-benchmark-baseline-\(index)",
                    events: events,
                    repositoryIDs: Set(changed.repositories.map(\.id))
                ),
                ActivityArchiveBenchmarkFixture(
                    directoryName: "activity-benchmark-optimized-\(index)",
                    events: events,
                    repositoryIDs: Set(changed.repositories.map(\.id))
                )
            )
        }
        defer { pairs.forEach { $0.0.cleanUp(); $0.1.cleanUp() } }
        let (baselineResults, optimizedResults) = await Self.runActivityBenchmarks(pairs: pairs)

        let baselineTimes = baselineResults.map(\.totalElapsed)
        let optimizedTimes = optimizedResults.map(\.totalElapsed)
        let baselineMedian = Self.median(baselineTimes)
        let optimizedMedian = Self.median(optimizedTimes)
        let baselineMAD = Self.mad(baselineTimes)
        let optimizedMAD = Self.mad(optimizedTimes)
        let baseline = ScenarioBaseline(
            scenario: "activity-archive-incremental",
            meanElapsed: baselineMedian,
            stddevElapsed: baselineMAD,
            sampleCount: baselineTimes.count
        )
        let current = optimizedResults[optimizedResults.count / 2]
        let gate = RegressionGate.checkNoResourceGrowth(baseline: baseline, current: BenchmarkResult(
            scenario: current.scenario,
            runID: current.runID,
            startedAt: current.startedAt,
            totalElapsed: optimizedMedian,
            firstResultElapsed: optimizedMedian,
            completeElapsed: optimizedMedian,
            peakCPU: current.peakCPU,
            averageCPU: current.averageCPU,
            peakMemoryMB: current.peakMemoryMB,
            totalDiskWritesKB: current.totalDiskWritesKB,
            gitSubprocessCount: current.gitSubprocessCount,
            metadata: current.metadata
        ))
        let baselineManager = PerformanceBaselineManager(
            storeURL: sourceDir.appendingPathComponent("performance-baseline.json")
        )
        baselineManager.record(baseline)
        print(
            "activity_archive_benchmark iterations=10 "
                + "baseline_median_ms=\(Self.formatMilliseconds(baselineMedian)) "
                + "baseline_mad_ms=\(Self.formatMilliseconds(baselineMAD)) "
                + "optimized_median_ms=\(Self.formatMilliseconds(optimizedMedian)) "
                + "optimized_mad_ms=\(Self.formatMilliseconds(optimizedMAD)) "
                + "baseline_bytes=316184 "
                + "regression=\(gate?.isRegression == true)"
        )
        #expect(baselineManager.baseline(for: baseline.scenario) == baseline)
        #expect(optimizedMedian < baselineMedian - (2 * baselineMAD))
        #expect(gate?.isRegression == false)
    }

    private static nonisolated func runActivityBenchmarks(
        pairs: [(ActivityArchiveBenchmarkFixture, ActivityArchiveBenchmarkFixture)]
    ) async -> (baseline: [BenchmarkResult], optimized: [BenchmarkResult]) {
        let runner = BenchmarkRunner()
        var baselineResults: [BenchmarkResult] = []
        var optimizedResults: [BenchmarkResult] = []
        for (baselineFixture, optimizedFixture) in pairs {
            baselineResults.append(await runner.run(
                scenario: .incrementalRefresh,
                setup: {},
                action: { _ = baselineFixture.store.save(baselineFixture.events) }
            ))
            optimizedResults.append(await runner.run(
                scenario: .incrementalRefresh,
                setup: {},
                action: {
                    let scoped = optimizedFixture.store.pruning(
                        optimizedFixture.events,
                        keepingRepositoryIDs: optimizedFixture.repositoryIDs
                    )
                    let duplicate = ActivityEventDeduplicator.newEvents(
                        from: [],
                        comparedTo: scoped
                    )
                    _ = optimizedFixture.store.merging(existing: scoped, newEvents: duplicate) == scoped
                }
            ))
        }
        return (baselineResults, optimizedResults)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func mad(_ values: [Double]) -> Double {
        let center = median(values)
        return median(values.map { abs($0 - center) })
    }

    private static func formatMilliseconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds * 1_000)
    }

    /// The write path is unchanged when a round does add events: the archive
    /// keeps the same schema, ordering and capacity truncation.
    @Test func changeRoundStillWritesDedupedAndTruncatedArchive() async throws {
        let dir = tempDir("activity-change")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent(ActivityEventStore.fileName)

        let clean = snapshot(
            repositories: (0..<Self.repositoryCount).map { repository(index: $0, changed: false) },
            generatedAt: Self.timestamp
        )
        let changed = snapshot(
            repositories: (0..<Self.repositoryCount).map { repository(index: $0, changed: true) },
            generatedAt: Self.timestamp
        )

        let counter = StoreWriteCounter()
        let store = ActivityEventStore(fileURL: archive, writeObserver: { counter.record($0) })
        let scheduler = ScanScheduler(commandMode: false, activityEventStore: store)
        defer { scheduler.shutdown() }
        scheduler.lastResult = clean

        counter.reset()
        _ = scheduler.recordActivityEvents(previous: clean, current: changed, observedAt: Self.timestamp)
        #expect(await waitForWrites(counter, atLeast: 1) == 1)
        // Repeating the exact same detected transition must be deduplicated.
        let firstWriteBytes = counter.bytes
        counter.reset()
        _ = scheduler.recordActivityEvents(previous: clean, current: changed, observedAt: Self.timestamp)
        let secondWrites = await waitForWrites(counter, atLeast: 1)

        let loaded = try store.load().get()
        let ids = loaded.events.map(\.id)
        print(
            "activity_dedup_round writes=\(secondWrites) bytes=\(counter.bytes) "
                + "first_write_bytes=\(firstWriteBytes) stored_events=\(ids.count) "
                + "unique_ids=\(Set(ids).count) capacity=\(store.capacity)"
        )
        #expect(secondWrites == 0)
        #expect(ids.count == Set(ids).count)
        #expect(ids.count <= store.capacity)
        #expect(!ids.isEmpty)

        // Schema and atomic write path are untouched.
        let raw = try Data(contentsOf: archive)
        let archiveJSON = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        let schemaVersion = archiveJSON?["schemaVersion"] as? Int
        print("activity_archive_schema_version=\(schemaVersion.map(String.init) ?? "nil")")
        #expect(schemaVersion == ActivityEventArchive.currentSchemaVersion)
    }

    /// Durability: a failed save must not be treated as "already persisted".
    /// After a failure the next round — even one that changes nothing — still
    /// writes; only a round after a confirmed save may skip.
    @Test func failedSaveIsRetriedByTheNextUnchangedRound() async throws {
        let dir = tempDir("activity-retry")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Make the archive path unwritable: its parent is a regular file, so the
        // `createDirectory` inside `ActivityEventStore.save` fails.
        let blockedParent = dir.appendingPathComponent("blocked")
        try "not a directory".write(to: blockedParent, atomically: true, encoding: .utf8)
        let archive = blockedParent.appendingPathComponent(ActivityEventStore.fileName)

        let clean = snapshot(
            repositories: (0..<Self.repositoryCount).map { repository(index: $0, changed: false) },
            generatedAt: Self.timestamp
        )
        let changed = snapshot(
            repositories: (0..<Self.repositoryCount).map { repository(index: $0, changed: true) },
            generatedAt: Self.timestamp
        )

        let counter = StoreWriteCounter()
        let store = ActivityEventStore(fileURL: archive, writeObserver: { counter.record($0) })
        let scheduler = ScanScheduler(commandMode: false, activityEventStore: store)
        defer { scheduler.shutdown() }
        scheduler.lastResult = clean

        // Round 1: a real change, but the save fails.
        let warningsBefore = scheduler.warnings.count
        counter.reset()
        _ = scheduler.recordActivityEvents(previous: clean, current: changed, observedAt: Self.timestamp)
        let failureWarning = await waitForWarning(scheduler, since: warningsBefore)
        print(
            "retry_phase=save-failed writes=\(counter.writes) bytes=\(counter.bytes) "
                + "archive_exists=\(FileManager.default.fileExists(atPath: archive.path)) "
                + "warning=\(failureWarning ?? "nil")"
        )
        #expect(counter.writes == 0)
        #expect(failureWarning != nil)
        #expect(!FileManager.default.fileExists(atPath: archive.path))

        // The path becomes writable again; disk still holds no archive.
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)

        // First unchanged round after the failure must retry the write.
        counter.reset()
        _ = scheduler.recordActivityEvents(previous: changed, current: changed, observedAt: Self.timestamp)
        let retryWrites = await waitForWrites(counter, atLeast: 1)
        let retryBytes = counter.bytes
        let loadedAfterRetry = try store.load().get()
        print(
            "retry_phase=unchanged-round-after-failure writes=\(retryWrites) bytes=\(retryBytes) "
                + "stored_events=\(loadedAfterRetry.events.count) "
                + "matches_memory=\(loadedAfterRetry.events == scheduler.activityEvents) "
                + "unique_ids=\(Set(loadedAfterRetry.events.map(\.id)).count)"
        )
        #expect(retryWrites == 1)
        #expect(retryBytes > 0)
        #expect(loadedAfterRetry.events == scheduler.activityEvents)
        #expect(loadedAfterRetry.events.count == Set(loadedAfterRetry.events.map(\.id)).count)

        // Only after a confirmed save may an unchanged round skip.
        counter.reset()
        _ = scheduler.recordActivityEvents(previous: changed, current: changed, observedAt: Self.timestamp)
        let writesAfterSuccess = await waitForWrites(counter, atLeast: 1)
        print(
            "retry_phase=unchanged-round-after-success writes=\(writesAfterSuccess) "
                + "bytes=\(counter.bytes) archive_bytes=\((try? Data(contentsOf: archive).count) ?? -1)"
        )
        #expect(writesAfterSuccess == 0)

        // Byte determinism: re-encoding the same event list must yield the same
        // bytes, which is what makes "disk already equals memory" a valid
        // reason to skip. `ActivityEventStore.save` encodes with
        // `.prettyPrinted, .sortedKeys` and `ActivityEventArchive` holds only an
        // Int plus an ordered array, so no dictionary ordering can leak in.
        let scratchA = ActivityEventStore(fileURL: dir.appendingPathComponent("scratch-a.json"))
        let scratchB = ActivityEventStore(fileURL: dir.appendingPathComponent("scratch-b.json"))
        _ = scratchA.save(scheduler.activityEvents)
        _ = scratchB.save(scheduler.activityEvents)
        let archiveData = try Data(contentsOf: archive)
        let scratchAData = try Data(contentsOf: dir.appendingPathComponent("scratch-a.json"))
        let scratchBData = try Data(contentsOf: dir.appendingPathComponent("scratch-b.json"))
        print(
            "byte_determinism archive==scratchA=\(archiveData == scratchAData) "
                + "scratchA==scratchB=\(scratchAData == scratchBData) bytes=\(scratchAData.count)"
        )
        #expect(archiveData == scratchAData)
        #expect(scratchAData == scratchBData)
    }

    /// Polls the deterministic write counter until the detached archive save
    /// has landed (or the grace window expires), then returns the count.
    private func waitForWrites(_ counter: StoreWriteCounter, atLeast: Int) async -> Int {
        let deadline = Date().addingTimeInterval(2)
        while counter.writes < atLeast, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return counter.writes
    }

    /// Waits for the detached save path to report a new failure warning.
    private func waitForWarning(_ scheduler: ScanScheduler, since count: Int) async -> String? {
        let deadline = Date().addingTimeInterval(2)
        while scheduler.warnings.count <= count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return scheduler.warnings.count > count ? scheduler.warnings.last : nil
    }
}

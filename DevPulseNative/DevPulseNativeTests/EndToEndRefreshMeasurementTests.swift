import Foundation
import Testing
@testable import DevPulse

/// Manual paired measurement for one complete timer-driven incremental refresh.
/// `verify.sh final` runs this test as a no-op unless the measurement script
/// supplies its isolated sample directory and App Group overrides.
@Suite(.serialized)
struct EndToEndRefreshMeasurementTests {
    @MainActor
    @Test func scheduledIncrementalRefresh() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sampleRootPath = environment["DEVPULSE_E2E_SAMPLE_ROOT"],
              !sampleRootPath.isEmpty else {
            return
        }

        let sampleRoot = URL(fileURLWithPath: sampleRootPath, isDirectory: true)
        let expectedContainer = sampleRoot.appendingPathComponent("app-group", isDirectory: true)
        let expectedContainerPath = try #require(environment["DEVPULSE_APP_GROUP_CONTAINER_PATH"])
        let expectedSuite = try #require(environment["DEVPULSE_APP_GROUP_DEFAULTS_SUITE"])
        let actualContainer = try #require(AppGroupStore.containerURL)
        guard actualContainer.standardizedFileURL == expectedContainer.standardizedFileURL,
              URL(fileURLWithPath: expectedContainerPath).standardizedFileURL == expectedContainer.standardizedFileURL,
              expectedSuite.hasPrefix("local.devpulse.app.tests.") else {
            throw MeasurementError.appGroupIsolationMismatch
        }

        try FileManager.default.createDirectory(at: expectedContainer, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: expectedSuite))
        let workspace = sampleRoot.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let repositories = try (0..<4).map { index -> URL in
            let repository = workspace.appendingPathComponent("repo-\(index)", isDirectory: true)
            try createCommittedRepository(at: repository)
            return repository
        }

        let locationConfiguration = ScanLocationConfiguration(
            enabledBuiltInPaths: [],
            customDirectories: [CustomScanDirectory(path: workspace.path)]
        )
        defaults.set(try JSONEncoder().encode(locationConfiguration), forKey: "scan_locations_v1_json")
        defaults.synchronize()

        let executionRecorder = RefreshExecutionRecorder()
        let scanExecution: ScanExecution = { request in
            let engine = RefreshEngine()
            let progressStream = await engine.progress
            var progressTask: Task<Void, Never>?
            if let handler = request.progressHandler {
                progressTask = Task {
                    for await progress in progressStream {
                        guard !Task.isCancelled else { break }
                        handler(progress)
                    }
                }
            }

            let result = await engine.execute(
                config: request.config,
                scanRoots: request.roots,
                knownRepositoryPaths: request.knownRepositoryPaths,
                ignoredRepositoryPaths: request.ignoredRepositoryPaths,
                forceRepositoryDiscovery: request.forceRepositoryDiscovery,
                previousSnapshot: request.previousSnapshot,
                source: request.source
            )
            progressTask?.cancel()
            await executionRecorder.record(
                engineElapsed: result.diagnostics.overallElapsed,
                forcedDiscovery: request.forceRepositoryDiscovery,
                knownRepositoryCount: request.knownRepositoryPaths.count,
                repositoryCount: result.data.repositories.count
            )
            return (
                data: result.data,
                warnings: result.warnings,
                discoveredRepositoryPaths: result.discoveredRepositoryPaths
            )
        }

        let activityStore = ActivityEventStore(
            fileURL: expectedContainer.appendingPathComponent(ActivityEventStore.fileName)
        )
        let historyStore = RepositoryHistoryStore(
            fileURL: expectedContainer.appendingPathComponent("repository-history.json")
        )
        let scheduler = ScanScheduler(
            commandMode: false,
            activityEventStore: activityStore,
            historyStore: historyStore,
            scanExecution: scanExecution
        )
        scheduler.stopBackgroundScanning()
        defer { scheduler.stopBackgroundScanning() }

        let initialRevision = currentStoredRevision()
        scheduler.scanNow(forceRepositoryDiscovery: true, source: .manual)
        let initialSnapshot = try await waitForCommittedSnapshot(
            scheduler: scheduler,
            afterRevision: initialRevision,
            repositoryCount: repositories.count,
            requireWorkingTreeChanges: false
        )
        #expect(initialSnapshot.repositories.count == repositories.count)
        try await waitForArchive(at: activityStore.fileURL)
        try await waitForArchive(at: historyStoreArchiveURL(in: expectedContainer))

        let previousActivityArchive = try Data(contentsOf: activityStore.fileURL)
        let historyURL = historyStoreArchiveURL(in: expectedContainer)
        let previousHistoryArchive = try Data(contentsOf: historyURL)
        let changedFile = repositories[0].appendingPathComponent("README.md")
        try "daily incremental change\n".write(to: changedFile, atomically: true, encoding: .utf8)
        await executionRecorder.reset()

        let revisionBeforeRefresh = initialSnapshot.storageRevision
        let refreshStartedAt = ProcessInfo.processInfo.systemUptime
        scheduler.scanNow(forceRepositoryDiscovery: false, source: .timer)
        let finalSnapshot = try await waitForCommittedSnapshot(
            scheduler: scheduler,
            afterRevision: revisionBeforeRefresh,
            repositoryCount: repositories.count,
            requireWorkingTreeChanges: true
        )
        let updatedActivityArchive = try await waitForChangedArchive(
            at: activityStore.fileURL,
            comparedTo: previousActivityArchive
        )
        let updatedHistoryArchive = try await waitForChangedArchive(
            at: historyURL,
            comparedTo: previousHistoryArchive
        )
        let refreshElapsed = ProcessInfo.processInfo.systemUptime - refreshStartedAt
        let execution = try #require(await executionRecorder.snapshot())

        #expect(!execution.forcedDiscovery)
        #expect(execution.knownRepositoryCount == repositories.count)
        #expect(execution.repositoryCount == repositories.count)
        #expect(finalSnapshot.storageRevision > revisionBeforeRefresh)
        #expect(!updatedActivityArchive.isEmpty)
        #expect(!updatedHistoryArchive.isEmpty)
        #expect(scheduler.refreshPhase == .success)

        let sample = try #require(environment["DEVPULSE_E2E_SAMPLE_ID"])
        let output = [
            "e2e_refresh.sample=\(sample)",
            "scheduler_wall_ms=\(Self.format(refreshElapsed * 1_000))",
            "refresh_engine_ms=\(Self.format(execution.engineElapsed * 1_000))",
            "repositories=\(execution.repositoryCount)",
            "known_repositories=\(execution.knownRepositoryCount)",
            "forced_discovery=\(execution.forcedDiscovery)",
            "final_storage_revision=\(finalSnapshot.storageRevision)",
            "activity_and_history_archives=updated"
        ].joined(separator: " ")
        print(output)
    }

    @MainActor
    private func waitForCommittedSnapshot(
        scheduler: ScanScheduler,
        afterRevision: UInt64,
        repositoryCount: Int,
        requireWorkingTreeChanges: Bool
    ) async throws -> AppGroupData {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !scheduler.isScanning,
               scheduler.refreshPhase == .success,
               case .success(let snapshot) = AppGroupStore.read(),
               snapshot.storageRevision > afterRevision,
               snapshot.isRefreshing != true,
               snapshot.repositories.count == repositoryCount,
               !requireWorkingTreeChanges || snapshot.repositories.contains(where: {
                   $0.modifiedFileCount + $0.addedFileCount + $0.deletedFileCount + $0.untrackedFileCount > 0
               }) {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw MeasurementError.refreshDidNotCommit
    }

    private func waitForArchive(at url: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: url.path),
               (try? Data(contentsOf: url)) != nil {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw MeasurementError.archiveWasNotWritten
    }

    private func waitForChangedArchive(at url: URL, comparedTo previous: Data) async throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let current = try? Data(contentsOf: url), current != previous {
                return current
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw MeasurementError.archiveWasNotUpdated
    }

    private func currentStoredRevision() -> UInt64 {
        guard case .success(let snapshot) = AppGroupStore.read() else { return 0 }
        return snapshot.storageRevision
    }

    private func historyStoreArchiveURL(in container: URL) -> URL {
        container.appendingPathComponent("repository-history.json")
    }

    private func createCommittedRepository(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: url)
        try runGit(["config", "user.name", "DevPulse Benchmark"], in: url)
        try runGit(["config", "user.email", "devpulse-benchmark@example.invalid"], in: url)
        try "baseline\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], in: url)
        try runGit(["commit", "-q", "-m", "baseline"], in: url)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_CONFIG_NOSYSTEM": "1"],
            uniquingKeysWith: { _, new in new }
        )
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: error.isEmpty ? output : error, encoding: .utf8) ?? "unknown git error"
            throw MeasurementError.gitFixtureFailed(message)
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private actor RefreshExecutionRecorder {
    struct Observation: Sendable {
        let engineElapsed: TimeInterval
        let forcedDiscovery: Bool
        let knownRepositoryCount: Int
        let repositoryCount: Int
    }

    private var observation: Observation?

    func record(engineElapsed: TimeInterval, forcedDiscovery: Bool, knownRepositoryCount: Int, repositoryCount: Int) {
        observation = Observation(
            engineElapsed: engineElapsed,
            forcedDiscovery: forcedDiscovery,
            knownRepositoryCount: knownRepositoryCount,
            repositoryCount: repositoryCount
        )
    }

    func reset() {
        observation = nil
    }

    func snapshot() -> Observation? {
        observation
    }
}

private enum MeasurementError: Error {
    case appGroupIsolationMismatch
    case refreshDidNotCommit
    case archiveWasNotWritten
    case archiveWasNotUpdated
    case gitFixtureFailed(String)
}

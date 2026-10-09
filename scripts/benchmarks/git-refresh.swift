import CryptoKit
import Darwin
import Foundation

private final class GitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var peak = 0
    private(set) var statusCalls = 0
    private(set) var logCalls = 0

    func reset() {
        lock.withLock {
            precondition(active == 0)
            peak = 0
            statusCalls = 0
            logCalls = 0
        }
    }

    func runner(mock: Bool = false) -> RefreshEngine.GitCommandRunner {
        { [self] arguments, directory, timeout, limit, cancelled in
            lock.withLock {
                active += 1
                peak = max(peak, active)
                if arguments.first == "status" { statusCalls += 1 }
                if arguments.first == "log" { logCalls += 1 }
            }
            defer { lock.withLock { active -= 1 } }
            if mock {
                Thread.sleep(forTimeInterval: 0.02)
                if arguments.first == "status" {
                    return .success(output: "# branch.oid abc123\n# branch.head main")
                }
                return .success(output: "abc123\u{0}2026-01-01T00:00:00Z\u{0}Fixture commit")
            }
            return GitRepositoryScanner.defaultGitCommandRunner(arguments, directory, timeout, limit, cancelled)
        }
    }
}

private struct Sample: Codable {
    let wall_ms: Double
    let cpu_ms: Double
    let status_calls: Int
    let log_calls: Int
    let peak: Int
    let signature: String
}

@main
private struct GitRefreshBenchmark {
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }

    static func signature(_ data: AppGroupData) -> String {
        let fields = data.repositories.sorted { $0.name < $1.name }.map { repo in
            [repo.name, repo.branch, repo.status.rawValue, String(repo.changedFileCount),
             String(repo.stagedFileCount ?? -1), String(repo.unstagedFileCount ?? -1),
             repo.changedFilesPreview.joined(separator: ","), repo.lastCommitID ?? "",
             repo.lastCommitSummary ?? "", repo.lastChangedAt ?? ""].joined(separator: "|")
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(fields.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["BENCH_ROOT"]!
        let storage = environment["BENCH_STORAGE"]!
        let paths = try FileManager.default.contentsOfDirectory(atPath: root).sorted().map { root + "/" + $0 }
        let config = ScanConfig(enabledBuiltInPaths: [], customPaths: [], maxDepth: 0,
                                changedPreviewLimit: 5, maxConcurrentGitOps: 6,
                                gitCommandTimeout: 5, scanTimeout: 120,
                                slowReposkipSeconds: 0, activeRepoThreshold: 30)
        var samples: [String: Sample] = [:]
        let engine = RefreshEngine(observationStoreOverride: RefreshObservationStore(
            fileURL: URL(fileURLWithPath: storage + "/observations.json")))
        var previous: AppGroupData?
        for scenario in ["concurrency_probe", "cold_refresh", "incremental_refresh", "committed_incremental_refresh"] {
            let scenarioPaths = scenario == "committed_incremental_refresh"
                ? previous!.repositories.filter { $0.lastCommitID != nil }.map(\.path) : paths
            let probe = GitProbe()
            let started = ProcessInfo.processInfo.systemUptime
            let cpuBefore = cpu()
            let incremental = scenario.contains("incremental")
            let result = await engine.execute(config: config, scanRoots: scenarioPaths,
                                              knownRepositoryPaths: scenarioPaths,
                                              forceRepositoryDiscovery: false,
                                              previousSnapshot: incremental ? previous : nil,
                                              source: incremental ? .timer : .manual,
                                              gitCommandRunner: probe.runner(mock: scenario == "concurrency_probe"))
            guard !result.isCancelled, result.warnings.isEmpty,
                  result.data.repositories.count == scenarioPaths.count,
                  result.data.repositories.allSatisfy({ $0.status != .error }) else {
                fatalError("Incomplete refresh: \(scenario)")
            }
            samples[scenario] = Sample(wall_ms: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                       cpu_ms: cpu() - cpuBefore, status_calls: probe.statusCalls,
                                       log_calls: probe.logCalls, peak: probe.peak, signature: signature(result.data))
            if scenario == "cold_refresh" { previous = result.data }
        }
        let probe = GitProbe()
        let started = ProcessInfo.processInfo.systemUptime
        let cpuBefore = cpu()
        let scan = await GitRepositoryScanner.scan(config: config, scanRoots: paths,
                                                   knownRepositoryPaths: paths,
                                                   previousSnapshot: previous,
                                                   gitCommandRunner: probe.runner())
        guard scan.warnings.isEmpty, scan.data.repositories.count == paths.count else {
            fatalError("Incomplete scanner result")
        }
        samples["incremental_scanner"] = Sample(wall_ms: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                               cpu_ms: cpu() - cpuBefore, status_calls: probe.statusCalls,
                                               log_calls: probe.logCalls, peak: probe.peak,
                                               signature: signature(scan.data))
        if environment["BENCH_SCHEDULER"] == "1" {
            samples["scheduler_incremental_refresh"] = try await schedulerSample(paths: paths, storage: storage, config: config)
        }
        print(String(decoding: try JSONEncoder().encode(samples), as: UTF8.self))
    }

    @MainActor
    static func schedulerSample(paths: [String], storage: String, config: ScanConfig) async throws -> Sample {
        let suite = ProcessInfo.processInfo.environment["DEVPULSE_APP_GROUP_DEFAULTS_SUITE"]!
        let defaults = UserDefaults(suiteName: suite)!
        let locations = ScanLocationConfiguration(enabledBuiltInPaths: [],
                                                   customDirectories: paths.map { CustomScanDirectory(path: $0) })
        defaults.set(try JSONEncoder().encode(locations), forKey: "scan_locations_v1_json")
        defaults.set(try JSONEncoder().encode(config), forKey: "scan_config_json")
        defaults.synchronize()
        let probe = GitProbe()
        let activity = ActivityEventStore(fileURL: URL(fileURLWithPath: storage + "/activity.json"))
        let historyURL = URL(fileURLWithPath: storage + "/history.json")
        let history = RepositoryHistoryStore(fileURL: historyURL)
        let scheduler = ScanScheduler(commandMode: false, activityEventStore: activity, historyStore: history,
                                      scanExecution: { request in
            let engine = RefreshEngine()
            let stream = await engine.progress
            let progressTask = Task {
                for await progress in stream {
                    guard !Task.isCancelled else { break }
                    request.progressHandler?(progress)
                }
            }
            let result = await engine.execute(config: request.config, scanRoots: request.roots,
                                              knownRepositoryPaths: request.knownRepositoryPaths,
                                              ignoredRepositoryPaths: request.ignoredRepositoryPaths,
                                              forceRepositoryDiscovery: request.forceRepositoryDiscovery,
                                              previousSnapshot: request.previousSnapshot, source: request.source,
                                              gitCommandRunner: probe.runner())
            progressTask.cancel()
            return (result.data, result.warnings, result.discoveredRepositoryPaths)
        })
        scheduler.stopBackgroundScanning()
        defer { scheduler.shutdown() }
        func waitForCommit(after revision: UInt64) async throws -> AppGroupData {
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while ProcessInfo.processInfo.systemUptime < deadline {
                if !scheduler.isScanning, scheduler.refreshPhase == .success,
                   case .success(let data) = AppGroupStore.read(), data.storageRevision > revision,
                   data.isRefreshing != true, data.repositories.count == paths.count {
                    return data
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            fatalError("Scheduler did not commit")
        }
        scheduler.scanNow(forceRepositoryDiscovery: true, source: .manual)
        let initial = try await waitForCommit(after: 0)
        let archiveDeadline = ProcessInfo.processInfo.systemUptime + 10
        while !FileManager.default.fileExists(atPath: activity.fileURL.path)
                || !FileManager.default.fileExists(atPath: historyURL.path) {
            guard ProcessInfo.processInfo.systemUptime < archiveDeadline else { fatalError("Archive missing") }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Complete warm-up archive work before measuring unchanged persistence.
        _ = history.loadGrouped()
        let activityBefore = try Data(contentsOf: activity.fileURL)
        let historyBefore = try Data(contentsOf: historyURL)
        probe.reset()
        let started = ProcessInfo.processInfo.systemUptime
        let cpuBefore = cpu()
        scheduler.scanNow(forceRepositoryDiscovery: false, source: .timer)
        let result = try await waitForCommit(after: initial.storageRevision)
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let cpuElapsed = cpu() - cpuBefore
        guard try Data(contentsOf: activity.fileURL) == activityBefore,
              try Data(contentsOf: historyURL) == historyBefore,
              result.repositories.allSatisfy({ $0.status != .error && $0.resolvedDataSource == .current }),
              scheduler.warnings.isEmpty else { fatalError("Scheduler semantic mismatch") }
        return Sample(wall_ms: elapsed, cpu_ms: cpuElapsed, status_calls: probe.statusCalls,
                      log_calls: probe.logCalls, peak: probe.peak, signature: signature(result))
    }
}

import AppKit
import Darwin
import QuartzCore
import SwiftUI

@MainActor
enum BenchMetrics {
    static var counts: [String: Int] = [:]
    static func record(_ name: String) { counts[name, default: 0] += 1 }
}

enum BenchFixture {
    static var backupConfig: BackupIntegrationConfiguration {
        var config = BackupIntegrationConfiguration.default
        config.backupDirectory = ProcessInfo.processInfo.environment["BENCH_STORAGE"]! + "/backups"
        return config
    }

    static func repository(_ index: Int, revision: Int = 0) -> RepositorySnapshot {
        RepositorySnapshot(
            id: "repo-\(index)", name: "repo \(index)", path: "/synthetic/repo-\(index)",
            branch: "main", status: index % 3 == 0 ? .clean : .changed,
            modifiedFileCount: index % 4, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: index % 4,
            conflictedFileCount: index % 17 == 0 ? 1 : 0, aheadCount: index % 3,
            behindCount: 0, hasUpstream: true, changedFileCount: index % 4,
            changedFilesPreview: ["Feature.swift"], risk: .low,
            lastScannedAt: "2026-10-09T00:00:00Z", dataSource: .current,
            lastSuccessfulScanAt: "2026-10-09T00:00:00Z", lastChangedAt: "2026-10-08T00:00:00Z",
            lastCommitID: "fixture-\(revision)", lastCommitSummary: "fixture",
            lastCommitMetadataAvailable: true, lastActivityAt: "2026-10-08T00:00:00Z",
            unavailableSince: nil, errorMessage: nil, isPinned: false
        )
    }

    static func snapshot(count: Int, revision: Int = 0) -> AppGroupData {
        AppGroupData(schemaVersion: AppGroupData.empty().schemaVersion,
                     generatedAt: "2026-10-09T00:00:00Z", writtenAt: nil,
                     scanSummary: AppGroupData.empty().scanSummary,
                     repositories: (0..<count).map { repository($0, revision: revision) })
    }
}

@MainActor
final class BenchSelection: ObservableObject {
    @Published var tab: AppTab = .overview
}

struct BenchRoot: View {
    @ObservedObject var selection: BenchSelection
    var body: some View { ContentView(selectedTab: $selection.tab) }
}

@main
struct TabPerformanceBenchmark {
    @MainActor
    static func main() throws {
        func stage(_ text: String) {
            FileHandle.standardError.write(Data("tab-benchmark: \(text)\n".utf8))
        }
        stage("starting")
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let defaults = UserDefaults(suiteName: ProcessInfo.processInfo.environment["DEVPULSE_APP_GROUP_DEFAULTS_SUITE"]!)!
        let scheduler = ScanScheduler(commandMode: true)
        let selection = BenchSelection()
        let count = Int(ProcessInfo.processInfo.environment["BENCH_REPOS"]!)!
        scheduler.lastResult = BenchFixture.snapshot(count: count)
        stage("fixture ready: \(count) repositories")
        let host = NSHostingView(rootView: BenchRoot(selection: selection)
            .environmentObject(scheduler)
            .environmentObject(LaunchAtLoginController(
                pendingRequestStore: LaunchAtLoginPendingRequestStore(defaults: defaults))))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        stage("hosting view ready")
        window.orderFrontRegardless()
        stage("window ready")

        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        for _ in 0..<10 { settle() }
        stage("warmup complete")

        func cpuMilliseconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
        }
        var scenarios: [String: Any] = [:]
        func measure(_ name: String, iterations: Int, action: (Int) -> Void) {
            stage("\(name) starting")
            BenchMetrics.counts = [:]
            let cpu = cpuMilliseconds()
            var latencies: [Double] = []
            for index in 0..<iterations {
                let start = CFAbsoluteTimeGetCurrent()
                action(index)
                settle()
                latencies.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            let consumed = cpuMilliseconds() - cpu
            latencies.sort()
            scenarios[name] = ["cpu_ms": consumed, "iterations": iterations,
                               "settle_p95_ms": latencies[Int(Double(iterations - 1) * 0.95)],
                               "body_calls": BenchMetrics.counts]
            stage("\(name) complete")
        }
        let tabs: [AppTab] = [.repositories, .pending, .impact, .workspaces, .backup, .settings, .overview]
        measure("switch", iterations: tabs.count) { selection.tab = tabs[$0 % tabs.count] }
        selection.tab = .repositories
        settle()
        measure("background_progress", iterations: 10) { scheduler.isScanning = $0 % 2 == 0 }
        selection.tab = .settings
        settle()
        let snapshots = (0..<3).map { BenchFixture.snapshot(count: count, revision: $0 + 1) }
        measure("large_snapshot", iterations: snapshots.count) { scheduler.lastResult = snapshots[$0] }
        selection.tab = .repositories
        settle()
        precondition(scheduler.lastResult.repositories.first?.lastCommitID == "fixture-3")
        let result: [String: Any] = ["scenarios": scenarios, "repository_count": count]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        window.orderOut(nil)
        defaults.removePersistentDomain(forName: ProcessInfo.processInfo.environment["DEVPULSE_APP_GROUP_DEFAULTS_SUITE"]!)
    }
}

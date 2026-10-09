import AppKit
import Darwin
import QuartzCore
import SwiftUI

enum BenchCounts {
    nonisolated(unsafe) static var decisions = 0
    nonisolated(unsafe) static var bodies = 0
    static func recordBody() { bodies += 1 }
}

@MainActor
final class TimelineState: ObservableObject {
    @Published var repositories: [RepositorySnapshot] = []
    var events: [ActivityEvent] = []
}

struct TimelineRoot: View {
    @ObservedObject var state: TimelineState
    var body: some View {
        ActivityTimelineView(events: state.events, repositories: state.repositories,
                             lastScanAt: nil, isScanning: false, onRescan: {})
    }
}

@main
struct TimelineBenchmark {
    static func repository(_ index: Int, revision: Int) -> RepositorySnapshot {
        RepositorySnapshot(
            id: "repo-\(index)", name: "repo \(index)", path: "/synthetic/repo-\(index)",
            branch: "main", status: .changed,
            modifiedFileCount: revision + 1, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: revision + 1,
            conflictedFileCount: 0, aheadCount: 0, behindCount: 0, hasUpstream: true,
            changedFileCount: revision + 1, changedFilesPreview: ["Feature.swift"], risk: .low,
            lastScannedAt: "2026-10-09T00:00:00Z", dataSource: .current,
            lastChangedAt: nil, errorMessage: nil, isPinned: false
        )
    }

    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let count = Int(ProcessInfo.processInfo.environment["BENCH_REPOS"]!)!
        let snapshots = (0..<7).map { revision in
            (0..<count).map { repository($0, revision: revision) }
        }
        var results: [String: Any] = [:]
        for eventCount in [0, 120] {
            let state = TimelineState()
            state.repositories = snapshots[0]
            state.events = (0..<eventCount).map { index in
                let repository = snapshots[0][index % count]
                let eventState = ActivityEventState(snapshot: repository)
                return ActivityEvent(id: "event-\(index)", repositoryID: repository.id,
                    repositoryName: repository.name, kind: .workingTreeChanged,
                    occurredAt: "2026-10-09T00:00:00Z", before: eventState, after: eventState)
            }
            let host = NSHostingView(rootView: TimelineRoot(state: state))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            func settle() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                host.layoutSubtreeIfNeeded()
                CATransaction.flush()
            }
            for _ in 0..<5 { settle() }
            func cpuMS() -> Double {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
                    + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
            }
            BenchCounts.decisions = 0
            BenchCounts.bodies = 0
            let start = cpuMS()
            for snapshot in snapshots.dropFirst() {
                state.repositories = snapshot
                settle()
            }
            results[eventCount == 0 ? "empty" : "folded"] = [
                "cpu_ms": cpuMS() - start, "body_calls": BenchCounts.bodies,
                "decision_calls": BenchCounts.decisions, "updates": 6,
            ]
            precondition(BenchCounts.bodies == 6, "Every snapshot must reach the real view")
            window.orderOut(nil)
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

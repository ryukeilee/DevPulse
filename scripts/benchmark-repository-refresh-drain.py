#!/usr/bin/env python3
"""A/B the actual drain method against a Git revision with deterministic retry stubs.

Usage: python3 scripts/benchmark-repository-refresh-drain.py --baseline-git <ref>
Compiles both extracted method bodies with Swift -O in one process. Checks exact
attempt/start order, pending requirements and active IDs, then times alternating
pairs (median of 11). Measures queue scheduling only, not Git I/O or snapshot work.
No tracked files are rewritten. BENCH_ITERATIONS overrides the pair count.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline-git", required=True)
args = parser.parse_args()
relative = "DevPulseNative/Core/ScanScheduler.swift"
baseline = subprocess.check_output(
    ["git", "show", f"{args.baseline_git}:{relative}"], cwd=root, text=True
)


def method(source):
    start = source.index("    private func drainPendingRepositoryRefreshes() {")
    end = source.index("    private func pathRecoveryRequiresDiscovery", start)
    return source[start:end].replace("private func", "func", 1)


stub = """
import Foundation
struct Config { var maxConcurrentGitOps: Int }
struct Coordinator { var hasWork = false }
class QueueState {
    var terminating = false, workSuspended = false, sessionInactive = false, isScanning = false
    var refreshCoordinator = Coordinator()
    var repositoryRetryDrainTask: Bool? = nil
    var repositoryRetryTasks: [String: Bool] = [:]
    var retryingRepositoryIDs: Set<String> = []
    var pendingRepositoryRefreshRequirements: [String: Bool] = [:]
    var config = Config(maxConcurrentGitOps: 12)
    // nil means the repository disappeared; false means it no longer needs retry.
    var repositories: [String: Bool] = [:]
    var attempts: [String] = [], starts: [String] = []
    var record = true
    func scanConfigForExecution() -> Config { config }
    func startRepositoryRefresh(_ id: String, requiresRetryState: Bool) -> Bool {
        if record { attempts.append(id) }
        guard repositoryRetryTasks.count < min(12, max(1, config.maxConcurrentGitOps)),
              !retryingRepositoryIDs.contains(id), let needsRetry = repositories[id],
              !requiresRetryState || needsRetry else { return false }
        repositoryRetryTasks[id] = true
        retryingRepositoryIDs.insert(id)
        if record { starts.append(id) }
        return true
    }
}
"""
harness = """
struct Scenario {
    let name: String
    var count = 1000, limit = 12, inFlight = 0, missing = 0, healthy = 0
    var suspended = false, followUp = false
    var rounds: Int { missing > 0 ? 1 : count > 1000 ? 8 : count > 100 ? 40 : 400 }
    func prepare(_ queue: QueueState, record: Bool) {
        queue.record = record
        queue.config.maxConcurrentGitOps = limit
        queue.workSuspended = suspended
        // Reverse insertion makes dictionary iteration irrelevant to the ordering check.
        for i in (0..<count).reversed() {
            let id = String(format: "repo-%06d", i)
            queue.pendingRepositoryRefreshRequirements[id] = i % 2 == 0
            if i >= missing { queue.repositories[id] = i >= missing + healthy }
            if i < inFlight {
                queue.retryingRepositoryIDs.insert(id)
                queue.repositoryRetryTasks[id] = true
            }
        }
    }
}
func equal(_ a: QueueState, _ b: QueueState) -> Bool {
    a.attempts == b.attempts && a.starts == b.starts &&
    a.pendingRepositoryRefreshRequirements == b.pendingRepositoryRefreshRequirements &&
    a.repositoryRetryTasks == b.repositoryRetryTasks && a.retryingRepositoryIDs == b.retryingRepositoryIDs
}
let scenarios = [
    Scenario(name: "empty", count: 0),
    Scenario(name: "single", count: 1),
    Scenario(name: "batch-100", count: 100),
    Scenario(name: "batch-1000"),
    Scenario(name: "batch-10000", count: 10000),
    Scenario(name: "single-slot", limit: 1),
    Scenario(name: "in-flight-prefix", inFlight: 6),
    Scenario(name: "at-capacity", inFlight: 12),
    Scenario(name: "rejected-prefix", missing: 100, healthy: 100),
    Scenario(name: "all-rejected", missing: 1000),
    Scenario(name: "suspended", suspended: true),
    Scenario(name: "follow-up", inFlight: 6, followUp: true)
]
var checksum = 0
func time(_ scenario: Scenario, current: Bool) -> Double {
    // Setup and dictionary copy-on-write costs stay outside the measured region.
    let queues = (0..<scenario.rounds).map { _ -> QueueState in
        let queue: QueueState = current ? Current() : Baseline()
        scenario.prepare(queue, record: false)
        return queue
    }
    let clock = ContinuousClock()
    let start = clock.now
    for queue in queues {
        if let queue = queue as? Current { queue.drainPendingRepositoryRefreshes() }
        else { (queue as! Baseline).drainPendingRepositoryRefreshes() }
    }
    let elapsed = start.duration(to: clock.now).components
    for queue in queues { checksum &+= queue.pendingRepositoryRefreshRequirements.count + queue.repositoryRetryTasks.count }
    return (Double(elapsed.seconds) * 1e9 + Double(elapsed.attoseconds) / 1e9) / Double(queues.count)
}
func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
let iterations = max(3, Int(ProcessInfo.processInfo.environment["BENCH_ITERATIONS"] ?? "11") ?? 11)
print("queue-only Swift -O; alternating pairs=\\(iterations); time=median ns/drain")
for scenario in scenarios {
    let a = Baseline(), b = Current()
    scenario.prepare(a, record: true)
    scenario.prepare(b, record: true)
    a.drainPendingRepositoryRefreshes(); b.drainPendingRepositoryRefreshes()
    precondition(equal(a, b), "initial mismatch: \\(scenario.name)")
    // Simulate completions and merged follow-ups; compare every subsequent drain.
    for _ in 0..<min(24, scenario.count + 2) {
        guard let id = a.retryingRepositoryIDs.sorted().first else { break }
        for queue in [a as QueueState, b as QueueState] {
            queue.retryingRepositoryIDs.remove(id)
            queue.repositoryRetryTasks.removeValue(forKey: id)
            if scenario.followUp {
                queue.pendingRepositoryRefreshRequirements[id] = false
            }
        }
        a.drainPendingRepositoryRefreshes(); b.drainPendingRepositoryRefreshes()
        precondition(equal(a, b), "completion mismatch: \\(scenario.name)")
        if scenario.followUp { break }
    }
    _ = time(scenario, current: false); _ = time(scenario, current: true)
    var old: [Double] = [], new: [Double] = []
    for pair in 0..<iterations {
        if pair % 2 == 0 {
            old.append(time(scenario, current: false)); new.append(time(scenario, current: true))
        } else {
            new.append(time(scenario, current: true)); old.append(time(scenario, current: false))
        }
    }
    let before = median(old), after = median(new)
    print(String(format: "%@ equivalent=true baseline_ns=%.0f current_ns=%.0f speedup=%.2fx", scenario.name, before, after, before / max(1, after)))
}
print("checksum=\\(checksum)")
"""
with tempfile.TemporaryDirectory(prefix="devpulse-drain-bench-") as directory:
    tmp = Path(directory)
    source = tmp / "main.swift"
    source.write_text(
        stub + "\nfinal class Baseline: QueueState {\n" + method(baseline) + "}\n"
        + "final class Current: QueueState {\n" + method((root / relative).read_text())
        + "}\n" + harness
    )
    binary = tmp / "benchmark"
    subprocess.run(
        ["xcrun", "swiftc", "-O", "-module-cache-path", str(tmp / "cache"),
         str(source), "-o", str(binary)], check=True
    )
    subprocess.run([str(binary)], check=True, env=os.environ.copy())

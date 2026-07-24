import Foundation

// MARK: - Regression detection

/// Runs automated regression gates after a refresh.
public enum RegressionGate {

    /// Check no zombie git processes are lingering.
    public static func checkNoZombieGitProcesses() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "git status --porcelain"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = nil
        try? process.run()
        process.waitUntilExit()
        guard let data = try? out.fileHandleForReading.readToEnd() else { return true }
        let count = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").count ?? 0
        return count <= 2
    }

    /// Check for excessive retries in a refresh result.
    static func checkNoInfiniteRetries(result: RefreshResult) -> Bool {
        let maxExpectedRetries = 5
        let retryCount = result.warnings.filter { $0.contains("retry") }.count
        return retryCount <= maxExpectedRetries
    }

    /// Check if the main thread stalled longer than 16ms.
    /// Returns the stall duration in seconds if detected, nil otherwise.
    public static func checkNoMainThreadStall() -> TimeInterval? {
        let start = ProcessInfo.processInfo.systemUptime
        let semaphore = DispatchSemaphore(value: 0)

        // Dispatch sync to main — if it takes >16ms, main thread is busy
        DispatchQueue.main.async {
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 0.05) // 50ms timeout
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        // Subtract the intrinsic dispatch overhead (~1ms)
        let stall = elapsed - 0.001
        return stall > 0.016 ? stall : nil
    }

    /// Detect task leaks by comparing before/after task ID sets.
    /// - Returns: Array of leaked task descriptions (IDs from `after` not in `before`).
    public static func checkNoTaskLeak(before: Set<String>, after: Set<String>) -> [String] {
        let leaked = after.subtracting(before)
        return Array(leaked)
    }

    /// Check for duplicate run IDs in the observation store.
    static func checkNoDuplicateSnapshotWrite(store: RefreshObservationStore) -> Bool {
        let all = store.loadAll()
        let ids = all.map(\.runID)
        return Set(ids).count == ids.count
    }

    /// Check that resource usage did not grow beyond 20% of baseline.
    static func checkNoResourceGrowth(
        baseline: ScenarioBaseline,
        current: BenchmarkResult
    ) -> RegressionResult? {
        let delta = current.totalElapsed - baseline.meanElapsed
        let dp = baseline.meanElapsed > 0 ? (delta / baseline.meanElapsed) * 100 : 0
        let threshold = max(baseline.meanElapsed * 0.2, baseline.stddevElapsed * 2.0)
        let isRegression = delta > threshold

        return RegressionResult(
            scenario: baseline.scenario,
            isRegression: isRegression,
            deltaPercent: dp,
            degradedStage: "coreStatus",
            relevantCodePath: "BenchmarkRunner/RefreshEngine",
            evidence: [
                "observed: \(String(format: "%.3f", current.totalElapsed))",
                "baseline: \(String(format: "%.3f", baseline.meanElapsed))",
                "threshold: \(String(format: "%.3f", threshold))",
                "delta: \(String(format: "%.1f", dp))%"
            ],
            exceedsBudget: current.totalElapsed > baseline.meanElapsed * 1.5
        )
    }

    /// Run all regression gates and return a consolidated list of findings.
    static func checkAll(
        result: RefreshResult? = nil,
        baseline: ScenarioBaseline? = nil,
        current: BenchmarkResult? = nil,
        store: RefreshObservationStore? = nil,
        beforeTasks: Set<String>? = nil,
        afterTasks: Set<String>? = nil
    ) -> [RegressionResult] {
        var findings: [RegressionResult] = []

        // Zombie git check
        if !checkNoZombieGitProcesses() {
            findings.append(RegressionResult(
                scenario: "gate-zombie-git", isRegression: true, deltaPercent: 0,
                degradedStage: "processManagement", relevantCodePath: "RegressionGate.checkNoZombieGitProcesses",
                evidence: ["Zombie git processes detected"], exceedsBudget: true
            ))
        }

        // Main thread stall check
        if let stall = checkNoMainThreadStall() {
            findings.append(RegressionResult(
                scenario: "gate-main-stall", isRegression: true, deltaPercent: stall * 100,
                degradedStage: "mainThread", relevantCodePath: "RegressionGate.checkNoMainThreadStall",
                evidence: ["Main thread stalled for \(String(format: "%.1f", stall * 1000))ms"], exceedsBudget: true
            ))
        }

        // Infinite retries
        if let result = result, !checkNoInfiniteRetries(result: result) {
            findings.append(RegressionResult(
                scenario: "gate-infinite-retry", isRegression: true, deltaPercent: 0,
                degradedStage: "retry", relevantCodePath: "RegressionGate.checkNoInfiniteRetries",
                evidence: ["Excessive retries in refresh result"], exceedsBudget: true
            ))
        }

        // Duplicate snapshots
        if let store = store, !checkNoDuplicateSnapshotWrite(store: store) {
            findings.append(RegressionResult(
                scenario: "gate-duplicate-snapshot", isRegression: true, deltaPercent: 0,
                degradedStage: "persistence", relevantCodePath: "RegressionGate.checkNoDuplicateSnapshotWrite",
                evidence: ["Duplicate runIDs found in observation store"], exceedsBudget: true
            ))
        }

        // Resource growth
        if let baseline = baseline, let current = current,
           let growth = checkNoResourceGrowth(baseline: baseline, current: current) {
            findings.append(growth)
        }

        // Task leak
        if let before = beforeTasks, let after = afterTasks {
            let leaked = checkNoTaskLeak(before: before, after: after)
            if !leaked.isEmpty {
                findings.append(RegressionResult(
                    scenario: "gate-task-leak", isRegression: true, deltaPercent: Double(leaked.count),
                    degradedStage: "taskManagement", relevantCodePath: "RegressionGate.checkNoTaskLeak",
                    evidence: ["\(leaked.count) leaked tasks: \(leaked.joined(separator: ", "))"],
                    exceedsBudget: Double(leaked.count) > 3
                ))
            }
        }

        return findings
    }
}

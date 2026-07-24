import Foundation

// MARK: - Performance baseline

public struct ScenarioBaseline: Equatable, Sendable, Codable {
    public let scenario: String
    public let meanElapsed: Double
    public let stddevElapsed: Double
    public let sampleCount: Int
    public static let currentVersion: Int = 1
}

public struct BaselineCollection: Equatable, Sendable, Codable {
    public var baselines: [String: ScenarioBaseline]
    public var schemaVersion: Int
    public static let currentVersion: Int = 1
    public init() { baselines = [:]; schemaVersion = Self.currentVersion }
}

public struct RegressionResult: Equatable, Sendable {
    public let scenario: String
    public let isRegression: Bool
    public let deltaPercent: Double
    public let degradedStage: String
    public let relevantCodePath: String
    public let evidence: [String]
    public let exceedsBudget: Bool

    public var summary: String {
        guard isRegression else { return "No regression for \(scenario)" }
        return "REGRESSION: \(scenario) degraded \(String(format: "%.1f", deltaPercent))%"
    }
}

public final class PerformanceBaselineManager: @unchecked Sendable {
    private let storeURL: URL
    private var collection = BaselineCollection()
    private let lock = NSLock()
    private let autoSave: Bool

    public init(storeURL: URL? = nil, autoSave: Bool = false) {
        let url = storeURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("performance-baselines.json")
        self.storeURL = url
        self.autoSave = autoSave
        // Restore existing baselines if any
        if let loaded = try? Self.load(from: url) {
            collection = loaded
        }
    }

    /// Persist the current collection to disk.
    public func save(to url: URL? = nil) throws {
        let target = url ?? storeURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(collection)
        let tempURL = target.appendingPathExtension(".tmp")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: tempURL, backupItemName: nil)
    }

    /// Load a baseline collection from disk.
    public static func load(from url: URL) throws -> BaselineCollection {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(BaselineCollection.self, from: data)
    }

    public func record(_ snapshot: ScenarioBaseline) {
        lock.withLock {
            collection.baselines[snapshot.scenario] = snapshot
        }
        if autoSave { try? save() }
    }

    public func baseline(for scenario: String) -> ScenarioBaseline? {
        lock.withLock { collection.baselines[scenario] }
    }

    public func reset() {
        lock.withLock { collection.baselines = [:] }
        if autoSave { try? save() }
    }

    /// Check for regression with optional per-stage budget.
    /// - Parameters:
    ///   - observed: The observed elapsed time.
    ///   - scenario: Scenario name string.
    ///   - budget: Optional per-stage max durations (stage name -> seconds).
    ///   - stageContributions: Which stages contributed the most (stage -> elapsed).
    /// - Returns: A RegressionResult if regression is detected, or nil if insufficient data.
    public func checkRegression(
        observed: Double,
        scenario: String,
        budget: [String: Double]? = nil,
        stageContributions: [String: Double]? = nil
    ) -> RegressionResult? {
        lock.withLock {
            guard let base = collection.baselines[scenario], base.sampleCount >= 3 else { return nil }

            let threshold = max(base.meanElapsed * 0.2, base.stddevElapsed * 2.0)
            let delta = observed - base.meanElapsed
            let dp = base.meanElapsed > 0 ? (delta / base.meanElapsed) * 100 : 0

            // Determine which stage degraded
            var degradedStage = "unknown"
            var relevantCodePath = "RefreshEngine"
            var evidence = ["observed: \(String(format: "%.3f", observed))",
                            "baseline: \(String(format: "%.3f", base.meanElapsed))",
                            "threshold: \(String(format: "%.3f", threshold))",
                            "delta: \(String(format: "%.1f", dp))%"]

            // Check budget violations
            var exceedsBudget = false
            if let budget = budget {
                for (stage, maxSec) in budget {
                    let actual = stageContributions?[stage] ?? observed
                    evidence.append("budget[\(stage)]: \(String(format: "%.3f", maxSec))s actual: \(String(format: "%.3f", actual))s")
                    if actual > maxSec {
                        degradedStage = stage
                        relevantCodePath = "RefreshEngine.\(stage)"
                        exceedsBudget = true
                        evidence.append("BUDGET_EXCEEDED: \(stage) took \(String(format: "%.3f", actual))s vs budget \(String(format: "%.3f", maxSec))s")
                    }
                }
            }

            let isRegression = delta > threshold || exceedsBudget

            return RegressionResult(
                scenario: scenario,
                isRegression: isRegression,
                deltaPercent: dp,
                degradedStage: degradedStage,
                relevantCodePath: relevantCodePath,
                evidence: evidence,
                exceedsBudget: exceedsBudget
            )
        }
    }
}

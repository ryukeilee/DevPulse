import Foundation

// MARK: - Diagnostic report

public struct DiagnosticReport: Equatable, Sendable, Codable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let appVersion: String
    public let runCount: Int
    public let observations: [DiagnosticRunSummary]
    public let baselines: [String: ScenarioBaseline]
    public let regressionFindings: [String]
    public static let currentSchemaVersion: Int = 2
}

public struct DiagnosticRunSummary: Equatable, Sendable, Codable {
    public let runID: String          // hashed
    public let startedAt: String
    public let overallElapsed: Double
    public let totalGitCalls: Int
    public let repositoryCount: Int
    public let reusedSnapshotCount: Int
    public let wasCancelled: Bool
    public let wasTimedOut: Bool
    public let source: String
    public let stageCounts: [String: StageSummary]
    /// Repository timing with path-independent labels.
    public let repoLabels: [String: Double]
}

public struct StageSummary: Equatable, Sendable, Codable {
    public let callCount: Int
    public let timeoutCount: Int
    public let cancellationCount: Int
    public let cacheHitCount: Int
    public let mainThreadStallUs: Int
    public let duration: Double
}

// MARK: - Report builder with privacy sanitization

public enum DiagnosticReportBuilder {

    /// Sanitize a text string: remove usernames and absolute paths.
    public static func sanitize(_ text: String) -> String {
        var result = text
        // Replace /Users/<username> with ~USER~
        if let homeRange = result.range(of: "/Users/") {
            let afterHome = result[homeRange.upperBound...]
            if let slashIdx = afterHome.firstIndex(of: "/") {
                let userRange = homeRange.lowerBound..<slashIdx
                result.replaceSubrange(userRange, with: "~USER~")
            } else {
                // Username at end of string
                result.replaceSubrange(homeRange.lowerBound..<result.endIndex, with: "~USER~")
            }
        }
        // Replace remaining absolute paths with ~PATH~
        let pattern = try? NSRegularExpression(pattern: "(/[^\\s:]+)+")
        if let regex = pattern {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, range: nsRange)
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let path = String(result[range])
                if path.contains("~USER~") { continue }
                if path.contains("/usr/") || path.contains("/System/") || path.contains("/bin/") { continue }
                result.replaceSubrange(range, with: "~PATH~")
            }
        }
        return result
    }

    /// Sanitize an observation: hash the runID and strip paths from repo timing keys.
    static func sanitizeObservation(_ obs: RefreshObservation) -> DiagnosticRunSummary {
        let hashedID = String(obs.runID.hash.description.suffix(12))
        var stageCounts: [String: StageSummary] = [:]
        for (stage, spans) in obs.stageSpans {
            let totalCallCount = spans.reduce(0) { $0 + $1.callCount }
            let totalTimeout = spans.reduce(0) { $0 + $1.timeoutCount }
            let totalCancel = spans.reduce(0) { $0 + $1.cancellationCount }
            let totalCache = spans.reduce(0) { $0 + $1.cacheHitCount }
            let totalStall = spans.reduce(0) { $0 + $1.mainThreadStallUs }
            let totalDuration = spans.reduce(0.0) { $0 + $1.duration }
            stageCounts[stage] = StageSummary(
                callCount: totalCallCount,
                timeoutCount: totalTimeout,
                cancellationCount: totalCancel,
                cacheHitCount: totalCache,
                mainThreadStallUs: totalStall,
                duration: totalDuration
            )
        }

        // Strip paths from repo timing keys
        var repoLabels: [String: Double] = [:]
        for (path, elapsed) in obs.repositoryTiming {
            let label = URL(fileURLWithPath: path).lastPathComponent
            repoLabels[label] = elapsed
        }

        return DiagnosticRunSummary(
            runID: hashedID,
            startedAt: obs.startedAt,
            overallElapsed: obs.overallElapsed,
            totalGitCalls: obs.totalGitCalls,
            repositoryCount: obs.repositoryCount,
            reusedSnapshotCount: obs.reusedSnapshotCount,
            wasCancelled: obs.wasCancelled,
            wasTimedOut: obs.wasTimedOut,
            source: obs.source,
            stageCounts: stageCounts,
            repoLabels: repoLabels
        )
    }

    /// Build a full diagnostic report from raw data.
    static func generateReport(
        observations: [RefreshObservation],
        baselines: BaselineCollection,
        appVersion: String,
        regressionFindings: [String] = []
    ) -> DiagnosticReport {
        let summaries = observations.map(sanitizeObservation)
        return DiagnosticReport(
            schemaVersion: DiagnosticReport.currentSchemaVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion,
            runCount: observations.count,
            observations: summaries,
            baselines: baselines.baselines,
            regressionFindings: regressionFindings
        )
    }

    /// Export a report as JSON data.
    static func export(_ report: DiagnosticReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(report)
    }
}

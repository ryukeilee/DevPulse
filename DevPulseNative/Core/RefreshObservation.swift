import Foundation
import OSLog

struct ObservationSpan: Equatable, Sendable, Codable {
    let label: String
    let startedAt: Double
    let duration: Double
    let callCount: Int
    let concurrentPeak: Int
    let timeoutCount: Int
    let cancellationCount: Int
    let cacheHitCount: Int
    let snapshotReuseCount: Int
    let mainThreadStallUs: Int
    let resourceDeltaCPU: Double
    let resourceDeltaMemoryMB: Int
    let resourceDeltaDiskWritesKB: Int
}

struct RefreshObservation: Equatable, Sendable, Codable {
    let schemaVersion: Int
    let runID: String
    let startedAt: String
    let overallElapsed: Double
    let totalGitCalls: Int
    let stageSpans: [String: [ObservationSpan]]
    let repositoryTiming: [String: Double]
    let repositoryCount: Int
    let currentRepositoryCount: Int
    let reusedSnapshotCount: Int
    let totalCPU: Double
    let peakMemoryMB: Int
    let totalDiskWritesKB: Int
    let wasCancelled: Bool
    let wasTimedOut: Bool
    let source: String

    static let currentSchemaVersion: Int = 1
}

actor RefreshObservationCollector {
    private var stageSpans: [String: [ObservationSpan]] = [:]
    private var repositoryTiming: [String: Double] = [:]
    private var totalGitCalls: Int = 0
    private var totalCPU: Double = 0
    private var peakMemoryMB: Int = 0
    private var totalDiskWritesKB: Int = 0
    private var runToken: String = ""
    private var startedAtISO: String = ""
    private var startedAtUptime: Double = 0
    private var repositoryCount: Int = 0
    private var currentRepositoryCount: Int = 0
    private var reusedSnapshotCount: Int = 0
    private var wasCancelled: Bool = false
    private var wasTimedOut: Bool = false
    private var source: String = "unknown"

    init() {
        stageSpans = [:]
        repositoryTiming = [:]
        totalGitCalls = 0
        totalCPU = 0
        peakMemoryMB = 0
        totalDiskWritesKB = 0
        runToken = ""
        startedAtISO = ""
        startedAtUptime = 0
        repositoryCount = 0
        currentRepositoryCount = 0
        reusedSnapshotCount = 0
        wasCancelled = false
        wasTimedOut = false
        source = "unknown"
        runToken = "init-" + Date().timeIntervalSince1970.description
        startedAtISO = ISO8601DateFormatter().string(from: Date())
        startedAtUptime = ProcessInfo.processInfo.systemUptime
    }

    func recordStageSpan(stage: String, span: ObservationSpan) {
        var spans = stageSpans[stage] ?? []
        spans.append(span)
        stageSpans[stage] = spans
    }

    func recordRepositoryTiming(pathHash: String, elapsed: Double) {
        repositoryTiming[pathHash] = elapsed
    }

    func recordGitCall(count: Int = 1) {
        totalGitCalls += count
    }

    func recordResourceDelta(cpu: Double = 0, memoryMB: Int = 0, diskKB: Int = 0) {
        totalCPU += cpu
        peakMemoryMB = max(peakMemoryMB, memoryMB)
        totalDiskWritesKB += diskKB
    }

    func setRepositoryCounts(total: Int, current: Int, reused: Int) {
        repositoryCount = total
        currentRepositoryCount = current
        reusedSnapshotCount = reused
    }

    func setCompletion(cancelled: Bool, timedOut: Bool) {
        wasCancelled = cancelled
        wasTimedOut = timedOut
    }

    func setSource(_ s: String) {
        source = s
    }

    func snapshot() -> RefreshObservation {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAtUptime
        return RefreshObservation(
            schemaVersion: RefreshObservation.currentSchemaVersion,
            runID: runToken,
            startedAt: startedAtISO,
            overallElapsed: elapsed,
            totalGitCalls: totalGitCalls,
            stageSpans: stageSpans,
            repositoryTiming: repositoryTiming,
            repositoryCount: repositoryCount,
            currentRepositoryCount: currentRepositoryCount,
            reusedSnapshotCount: reusedSnapshotCount,
            totalCPU: totalCPU,
            peakMemoryMB: peakMemoryMB,
            totalDiskWritesKB: totalDiskWritesKB,
            wasCancelled: wasCancelled,
            wasTimedOut: wasTimedOut,
            source: source
        )
    }

    func reset() {
        stageSpans = [:]
        repositoryTiming = [:]
        totalGitCalls = 0
        totalCPU = 0
        peakMemoryMB = 0
        totalDiskWritesKB = 0
        runToken = "reset-" + ProcessInfo.processInfo.systemUptime.description
        startedAtISO = ISO8601DateFormatter().string(from: Date())
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        repositoryCount = 0
        currentRepositoryCount = 0
        reusedSnapshotCount = 0
        wasCancelled = false
        wasTimedOut = false
        source = "unknown"
    }
}

/// Store-level schema version for the on-disk envelope format.
///
/// Version history:
/// - v0 (legacy): raw `[RefreshObservation]` array or bare `RefreshObservation` object, no version marker.
/// - v1 (current): wrapped in `StoredObservations` envelope with explicit `schemaVersion`.
///
/// Migration from v0 to v1 happens automatically on load; the next save upgrades the file.
final class RefreshObservationStore: @unchecked Sendable {
    /// Current store envelope schema version.
    static let currentSchemaVersion: Int = 1

    private let fileURL: URL
    private let logger = Logger(subsystem: "local.devpulse.app", category: "ObservationStore")
    private let queue = DispatchQueue(label: "local.devpulse.app.observation-store", qos: .utility)
    private static let maxStored = 50

    /// Versioned storage envelope for the on-disk file.
    /// Allows forward/backward compatible reads and explicit version tracking.
    private struct StoredObservations: Codable {
        let schemaVersion: Int
        let observations: [RefreshObservation]
    }

    init(fileURL: URL? = nil) {
        let url = fileURL ?? (
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
            )?.appendingPathComponent("refresh-observations.json")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("refresh-observations.json")
        )
        self.fileURL = url
    }

    func append(_ observation: RefreshObservation) -> Result<Void, any Error> {
        queue.sync {
            var all = loadAllInternal()
            all.insert(observation, at: 0)
            if all.count > Self.maxStored {
                all = Array(all.prefix(Self.maxStored))
            }
            return save(all)
        }
    }

    func loadAll() -> [RefreshObservation] {
        queue.sync { loadAllInternal() }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Load observations with backward-compatible migration.
    ///
    /// Tries in order:
    /// 1. Versioned envelope (v1+)
    /// 2. Bare array (v0 legacy)
    /// 3. Single object (v0 legacy)
    /// 4. Empty on corruption or missing file
    private func loadAllInternal() -> [RefreshObservation] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()

        // Versioned envelope format (v1+).
        if let envelope = try? decoder.decode(StoredObservations.self, from: data) {
            return envelope.observations
        }

        // Migration: v0 bare array format.
        if let list = try? decoder.decode([RefreshObservation].self, from: data) {
            return list
        }

        // Migration: v0 single observation format.
        if let single = try? decoder.decode(RefreshObservation.self, from: data) {
            return [single]
        }

        return []
    }

    /// Save observations in the versioned envelope format.
    private func save(_ list: [RefreshObservation]) -> Result<Void, any Error> {
        let envelope = StoredObservations(
            schemaVersion: Self.currentSchemaVersion,
            observations: list
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(envelope)
            try data.write(to: fileURL, options: .atomic)
            return .success(())
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }
}

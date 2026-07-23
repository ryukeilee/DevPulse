import Foundation
import OSLog

// MARK: - Change impact store

/// Versioned, bounded persistent store for change impact analysis snapshots.
///
/// Design:
/// - Per-repository: each repo's analysis is stored independently.
/// - Versioned: schema version with migration support.
/// - Atomic writes: uses rename-based atomic write.
/// - Bounded: oldest analyses are compacted when limits are exceeded.
/// - Corrosion recovery: corrupted files are detected and a fresh store is created.
/// - Fallback: corrupted or incompatible stores return empty state with error.
///
/// Storage format: JSON in shared App Group container.
/// Thread safety: All I/O on a dedicated serial queue.
final class ChangeImpactStore: @unchecked Sendable {
    // MARK: - Configuration

    struct Configuration: Sendable {
        /// Maximum analyses per repository.
        var maxAnalysesPerRepo: Int = 50
        /// Maximum total analyses across all repositories.
        var maxTotalAnalyses: Int = 1000
        /// Retention period for analyses (nil = forever).
        var retentionDays: Int? = 90
        /// Automatically compact after every N writes if over threshold.
        var compactionInterval: Int = 20
        /// Fraction of maxTotalAnalyses triggering early compaction.
        var compactionThreshold: Double = 0.9

        static let `default` = Configuration()
    }

    // MARK: - File info

    private static let fileName = "change-impact-store.json"
    private static let lockFileName = ".change-impact-store.lock"

    // MARK: - Container

    private struct StoreContainer: Codable {
        var schemaVersion: Int
        var analysesByRepo: [String: [AnalysisRecord]]
        var migrationLog: [MigrationRecord]
        var lastCompactedAt: String?

        static func empty() -> StoreContainer {
            StoreContainer(
                schemaVersion: ChangeImpactSchema.version,
                analysesByRepo: [:],
                migrationLog: [],
                lastCompactedAt: nil
            )
        }
    }

    private struct AnalysisRecord: Codable {
        let id: String
        let analyzedAt: String
        let snapshot: ChangeImpactSnapshot
        let schemaVersion: Int
    }

    private struct MigrationRecord: Codable {
        let fromVersion: Int
        let toVersion: Int
        let migratedAt: String
        let recordCount: Int
        let success: Bool
    }

    // MARK: - Error

    enum StoreError: Error, LocalizedError {
        case corruptedData(String)
        case schemaMismatch(found: Int, expected: Int)
        case ioError(String)
        case lockFailed

        var errorDescription: String? {
            switch self {
            case .corruptedData(let detail): return "数据损坏: \(detail)"
            case .schemaMismatch(let found, let expected):
                return "Schema 版本不匹配: 当前 \(found), 期望 \(expected)"
            case .ioError(let detail): return "IO 错误: \(detail)"
            case .lockFailed: return "无法获取文件锁"
            }
        }
    }

    // MARK: - Private state

    private let fileURL: URL
    private let config: Configuration
    private let logger = Logger(subsystem: "local.devpulse.app", category: "ImpactStore")
    private let queue = DispatchQueue(label: "local.devpulse.app.impact-store", qos: .utility)
    private let processLock = NSLock()

    private var container: StoreContainer
    private var diagnostics = ImpactStoreDiagnostics.empty()
    private var writeCountSinceLastCompaction = 0

    // MARK: - Initialization

    init(fileURL: URL? = nil, config: Configuration = .default) {
        let url = fileURL ?? (FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
        )?.appendingPathComponent(Self.fileName))
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(Self.fileName)

        self.fileURL = url
        self.config = config
        self.container = StoreContainer.empty()

        // Load existing store
        loadStore()
    }

    // MARK: - Public API

    /// Store an analysis snapshot for a repository.
    func store(snapshot: ChangeImpactSnapshot) -> Result<Void, StoreError> {
        queue.sync { [self] in
            let record = AnalysisRecord(
                id: snapshot.id,
                analyzedAt: snapshot.analyzedAt,
                snapshot: snapshot,
                schemaVersion: ChangeImpactSchema.version
            )

            var repoAnalyses = self.container.analysesByRepo[snapshot.repositoryID, default: []]
            repoAnalyses.append(record)
            self.container.analysesByRepo[snapshot.repositoryID] = repoAnalyses

            self.writeCountSinceLastCompaction += 1
            self.diagnostics.totalWrites += 1

            // Check compaction
            let totalAnalyses = self.container.analysesByRepo.values.reduce(0) { $0 + $1.count }
            let shouldCompact = self.writeCountSinceLastCompaction >= self.config.compactionInterval
                && Double(totalAnalyses) > self.config.compactionThreshold * Double(self.config.maxTotalAnalyses)

            if shouldCompact || totalAnalyses > self.config.maxTotalAnalyses {
                self.compact()
            }

            return self.saveStore()
        }
    }

    /// Retrieve the latest analysis snapshot for a repository.
    func latestSnapshot(for repositoryID: String) -> ChangeImpactSnapshot? {
        queue.sync { [self] in
            guard let records = self.container.analysesByRepo[repositoryID], !records.isEmpty else {
                return nil
            }
            return records.last?.snapshot
        }
    }

    /// Retrieve all analysis snapshots for a repository.
    func allSnapshots(for repositoryID: String) -> [ChangeImpactSnapshot] {
        queue.sync { [self] in
            self.container.analysesByRepo[repositoryID]?.map(\.snapshot) ?? []
        }
    }

    /// Retrieve the analysis from before the given timestamp.
    func snapshot(before timestamp: String, repositoryID: String) -> ChangeImpactSnapshot? {
        queue.sync { [self] in
            guard let records = self.container.analysesByRepo[repositoryID] else { return nil }
            return records.last(where: { $0.analyzedAt < timestamp })?.snapshot
        }
    }

    /// Get the count of analyses for a repository.
    func analysisCount(for repositoryID: String) -> Int {
        queue.sync { [self] in
            self.container.analysesByRepo[repositoryID]?.count ?? 0
        }
    }

    /// Get total number of analyses across all repositories.
    var totalAnalysisCount: Int {
        queue.sync { [self] in
            self.container.analysesByRepo.values.reduce(0) { $0 + $1.count }
        }
    }

    /// Get the repositories with stored analyses.
    var storedRepositoryIDs: Set<String> {
        queue.sync { [self] in
            Set(self.container.analysesByRepo.keys)
        }
    }

    /// Compact old analyses according to retention policy.
    func compact() {
        queue.sync { [self] in
            let before = self.container.analysesByRepo.values.reduce(0) { $0 + $1.count }

            // Per-repo cap
            for (repoID, records) in self.container.analysesByRepo {
                if records.count > self.config.maxAnalysesPerRepo {
                    self.container.analysesByRepo[repoID] = Array(records.suffix(self.config.maxAnalysesPerRepo))
                }
            }

            // Retention period
            if let retentionDays = self.config.retentionDays {
                let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
                for (repoID, records) in self.container.analysesByRepo {
                    self.container.analysesByRepo[repoID] = records.filter { record in
                        guard let date = ISO8601DateFormatter().date(from: record.analyzedAt) else {
                            return false
                        }
                        return date >= cutoff
                    }
                }
            }

            // Total cap
            var allRecords: [(repoID: String, record: AnalysisRecord)] = []
            for (repoID, records) in self.container.analysesByRepo {
                for record in records {
                    allRecords.append((repoID, record))
                }
            }
            if allRecords.count > self.config.maxTotalAnalyses {
                let sorted = allRecords.sorted { $0.record.analyzedAt > $1.record.analyzedAt }
                let kept = Set(sorted.prefix(self.config.maxTotalAnalyses).map { "\($0.repoID)-\($0.record.id)" })
                for (repoID, records) in self.container.analysesByRepo {
                    self.container.analysesByRepo[repoID] = records.filter {
                        kept.contains("\(repoID)-\($0.id)")
                    }
                }
            }

            let after = self.container.analysesByRepo.values.reduce(0) { $0 + $1.count }
            let removed = before - after
            self.container.lastCompactedAt = ISO8601DateFormatter().string(from: Date())
            self.writeCountSinceLastCompaction = 0

            if removed > 0 {
                self.logger.debug("Compacted \(removed) old analyses (\(before) → \(after))")
                self.diagnostics.totalCompactions += 1
                self.diagnostics.totalCompactedRecords += removed
                _ = self.saveStore()
            }
        }
    }

    /// Rebuild the store from scratch, preserving only the latest analysis per repo.
    func rebuild() -> Result<Void, StoreError> {
        queue.sync { [self] in
            let before = self.container.analysesByRepo.values.reduce(0) { $0 + $1.count }

            var rebuilt: [String: [AnalysisRecord]] = [:]
            for (repoID, records) in self.container.analysesByRepo {
                if let latest = records.last {
                    rebuilt[repoID] = [latest]
                }
            }
            self.container.analysesByRepo = rebuilt
            self.container.migrationLog.append(MigrationRecord(
                fromVersion: before,
                toVersion: 1,
                migratedAt: ISO8601DateFormatter().string(from: Date()),
                recordCount: rebuilt.values.reduce(0) { $0 + $1.count },
                success: true
            ))

            self.diagnostics.totalRebuilds += 1
            self.logger.debug("Rebuild store: \(before) → \(rebuilt.values.reduce(0) { $0 + $1.count }) records")
            return self.saveStore()
        }
    }

    /// Clear all stored analyses.
    func clear() -> Result<Void, StoreError> {
        queue.sync { [self] in
            self.container = StoreContainer.empty()
            self.diagnostics.totalClears += 1
            self.logger.debug("Store cleared")
            return self.saveStore()
        }
    }

    /// Get store diagnostics.
    var storeDiagnostics: ImpactStoreDiagnostics {
        queue.sync { [self] in self.diagnostics }
    }

    /// Perform schema migration if needed.
    /// Returns true if migration was performed.
    func migrateIfNeeded() -> Bool {
        queue.sync {
            guard self.container.schemaVersion < ChangeImpactSchema.version else { return false }

            let fromVersion = self.container.schemaVersion
            self.logger.info("Migrating store schema from v\(fromVersion) to v\(ChangeImpactSchema.version)")

            // v1 → latest migration
            self.container.schemaVersion = ChangeImpactSchema.version

            self.container.migrationLog.append(MigrationRecord(
                fromVersion: fromVersion,
                toVersion: ChangeImpactSchema.version,
                migratedAt: ISO8601DateFormatter().string(from: Date()),
                recordCount: self.container.analysesByRepo.values.reduce(0) { $0 + $1.count },
                success: true
            ))

            self.diagnostics.totalMigrations += 1
            let result = self.saveStore()
            if case .failure(let error) = result {
                self.logger.error("Migration save failed: \(error.localizedDescription)")
                return false
            }
            return true
        }
    }

    // MARK: - Private

    private func loadStore() {
        let fm = FileManager.default
        let storeURL = self.fileURL
        guard fm.fileExists(atPath: storeURL.path) else {
            self.container = StoreContainer.empty()
            self.logger.debug("No existing store at \(storeURL.path), starting fresh")
            return
        }

        do {
            let data = try Data(contentsOf: storeURL)
            let decoded = try JSONDecoder().decode(StoreContainer.self, from: data)
            self.container = decoded

            // Check schema compatibility
            guard self.container.schemaVersion >= ChangeImpactSchema.oldestMigratableVersion else {
                self.logger.warning("Store schema v\(self.container.schemaVersion) is too old, rebuilding")
                self.container = StoreContainer.empty()
                self.diagnostics.schemaRecoveries += 1
                return
            }

            if self.container.schemaVersion < ChangeImpactSchema.version {
                self.logger.info("Store schema v\(self.container.schemaVersion) needs migration to v\(ChangeImpactSchema.version)")
                _ = self.migrateIfNeeded()
            }

            self.logger.debug("Loaded store with \(self.totalAnalysisCount) analyses across \(self.container.analysesByRepo.keys.count) repos")
        } catch {
            self.logger.error("Failed to load store: \(error.localizedDescription). Rebuilding from scratch.")
            self.container = StoreContainer.empty()
            self.diagnostics.corruptionRecoveries += 1
        }
    }

    @discardableResult
    private func saveStore() -> Result<Void, StoreError> {
        do {
            let data = try JSONEncoder().encode(container)
            try data.write(to: fileURL, options: .atomic)
            diagnostics.totalSaves += 1
            return .success(())
        } catch {
            logger.error("Failed to save store: \(error.localizedDescription)")
            diagnostics.totalSaveErrors += 1
            return .failure(.ioError(error.localizedDescription))
        }
    }
}

// MARK: - Diagnostics

struct ImpactStoreDiagnostics: Equatable, Sendable {
    var totalWrites: Int
    var totalSaves: Int
    var totalSaveErrors: Int
    var totalCompactions: Int
    var totalCompactedRecords: Int
    var totalMigrations: Int
    var totalRebuilds: Int
    var totalClears: Int
    var corruptionRecoveries: Int
    var schemaRecoveries: Int
    var lastError: String?

    static func empty() -> ImpactStoreDiagnostics {
        ImpactStoreDiagnostics(
            totalWrites: 0,
            totalSaves: 0,
            totalSaveErrors: 0,
            totalCompactions: 0,
            totalCompactedRecords: 0,
            totalMigrations: 0,
            totalRebuilds: 0,
            totalClears: 0,
            corruptionRecoveries: 0,
            schemaRecoveries: 0,
            lastError: nil
        )
    }
}

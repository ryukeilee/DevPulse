import Foundation
import OSLog

// MARK: - Bounded persistent history store

/// Thread-safe, bounded history store for repository state history.
///
/// Design:
/// - Each repository's history is stored as a flat list of entries.
/// - Consecutive identical `scanRecord` entries are skipped (dedup).
/// - Retention: entries older than `retentionDays` are removed during compaction.
/// - Per-repo cap: each repo keeps at most `maxEntriesPerRepo` entries after compaction.
/// - Total cap: the store never exceeds `maxTotalEntries` entries.
/// - Compaction is triggered automatically when the total exceeds 90% of maxTotalEntries
///   or after a configurable number of writes.
/// - All file I/O uses atomic writes (rename-based).
/// - All operations are performed on a dedicated serial queue.
final class RepositoryHistoryStore: @unchecked Sendable {
    // MARK: - Configuration

    struct Configuration: Sendable {
        let retentionDays: Int
        let maxEntriesPerRepo: Int
        let maxTotalEntries: Int
        /// Trigger compaction after every N writes when over the soft threshold.
        let compactionInterval: Int
        /// Fraction of maxTotalEntries that triggers early compaction.
        let softThresholdFraction: Double

        static let `default` = Configuration(
            retentionDays: 30,
            maxEntriesPerRepo: 500,
            maxTotalEntries: 10000,
            compactionInterval: 20,
            softThresholdFraction: 0.9
        )

        static let minimal = Configuration(
            retentionDays: 7,
            maxEntriesPerRepo: 100,
            maxTotalEntries: 2000,
            compactionInterval: 10,
            softThresholdFraction: 0.8
        )
    }

    // MARK: - File info

    private static let fileName = "repository-history.json"
    private static let lockFileName = ".repository-history.lock"

    // MARK: - Private state

    private let fileURL: URL
    private let lockURL: URL
    private let config: Configuration
    private let logger = Logger(subsystem: "local.devpulse.app", category: "HistoryStore")
    private let queue = DispatchQueue(label: "local.devpulse.app.history-store",
                                      qos: .utility,
                                      attributes: [],
                                      autoreleaseFrequency: .workItem)
    private let processLock = NSLock()

    // In-memory diagnostics counters (not persisted)
    private var _diagnostics = HistoryDiagnosticsSnapshot.empty()
    private var _loadMetrics = RepositoryHistoryLoadMetrics()
    private var writeCountSinceLastCompaction = 0

    var diagnostics: HistoryDiagnosticsSnapshot {
        queue.sync { _diagnostics }
    }

    // MARK: - Initialization

    init(fileURL: URL? = nil,
         config: Configuration = .default) {
        let url = fileURL ?? (SharedSnapshotLocation.containerURL?.appendingPathComponent(Self.fileName))
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(Self.fileName)

        self.fileURL = url
        self.lockURL = url.deletingLastPathComponent()
            .appendingPathComponent(Self.lockFileName)
        self.config = config
    }

    static func live() -> RepositoryHistoryStore? {
        guard let container = SharedSnapshotLocation.containerURL else { return nil }
        return RepositoryHistoryStore(fileURL: container.appendingPathComponent(fileName))
    }

    // MARK: - Public API

    /// Record one or more history entries for repositories, performing dedup
    /// against the latest entry for each repo. Runs compaction if needed.
    func record(entries: [RepositoryHistoryEntry]) -> Result<Int, HistoryStoreError> {
        guard !entries.isEmpty else { return .success(0) }

        return queue.sync {
            processLock.lock()
            defer { processLock.unlock() }

            return recordUnlocked(entries: entries, archive: loadArchiveForRecordingUnlocked())
                .map(\.addedCount)
        }
    }

    /// Record state points derived from one snapshot while the archive remains locked.
    /// This keeps classification and read-merge-write on the same archive decode.
    func recordSnapshotStates(
        repositories: [RepositorySnapshot],
        recordedAt: String
    ) -> Result<HistoryRecordOutcome, HistoryStoreError> {
        queue.sync {
            processLock.lock()
            defer { processLock.unlock() }

            switch loadUnlocked() {
            case .success(let archive):
                let latestStates = latestStates(in: archive.entries)
                let entries = snapshotEntries(
                    repositories: repositories,
                    recordedAt: recordedAt,
                    previousStates: latestStates
                )
                guard !entries.isEmpty else {
                    return .success(HistoryRecordOutcome(addedCount: 0, totalEntryCount: archive.entries.count))
                }
                return recordUnlocked(entries: entries, archive: archive)
            case .failure:
                // Preserve the existing retry behavior: classify with no prior state,
                // then let the read-merge-write path make one recovery attempt.
                let entries = snapshotEntries(
                    repositories: repositories,
                    recordedAt: recordedAt,
                    previousStates: [:]
                )
                guard !entries.isEmpty else {
                    return .success(HistoryRecordOutcome(addedCount: 0, totalEntryCount: 0))
                }
                return recordUnlocked(entries: entries, archive: loadArchiveForRecordingUnlocked())
            }
        }
    }

    /// Record a state point for a single repository, classified appropriately.
    func recordState(
        repositoryID: String,
        recordedAt: String,
        state: HistoryStatePoint,
        previousState: HistoryStatePoint? = nil,
        previousDataSource: RepositoryDataSource? = nil
    ) -> Result<Int, HistoryStoreError> {
        let kind = HistoryEntryKindClassifier.classify(
            previous: previousState,
            current: state,
            lastDataSource: previousDataSource,
            currentDataSource: state.dataSource
        )

        let entry = RepositoryHistoryEntry(
            repositoryID: repositoryID,
            recordedAt: recordedAt,
            kind: kind,
            state: state
        )

        return record(entries: [entry])
    }

    /// Load all history entries.
    func load() -> Result<[RepositoryHistoryEntry], HistoryStoreError> {
        queue.sync {
            processLock.lock()
            defer { processLock.unlock() }

            switch loadUnlocked() {
            case .success(let archive):
                return .success(archive.entries)
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    /// Load history for a specific repository.
    func load(for repositoryID: String) -> Result<[RepositoryHistoryEntry], HistoryStoreError> {
        queue.sync {
            processLock.lock()
            defer { processLock.unlock() }

            switch loadUnlocked() {
            case .success(let archive):
                let entries = archive.entries
                    .filter { $0.repositoryID == repositoryID }
                    .sorted { $0.recordedAt > $1.recordedAt }
                return .success(entries)
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    /// Load all history entries grouped by repository, newest first within each group.
    func loadGrouped() -> Result<[String: [RepositoryHistoryEntry]], HistoryStoreError> {
        queue.sync {
            processLock.lock()
            defer { processLock.unlock() }

            switch loadUnlocked() {
            case .success(let archive):
                return .success(Dictionary(grouping: archive.entries, by: \.repositoryID)
                    .mapValues { $0.sorted { $0.recordedAt > $1.recordedAt } })
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    /// Prune entries for repositories that are no longer tracked.
    func prune(keeping repositoryIDs: Set<String>) -> Result<Int, HistoryStoreError> {
        queue.sync {
            processLock.lock()
            defer { processLock.unlock() }

            var archive: RepositoryHistoryArchive
            switch loadUnlocked() {
            case .success(let loaded):
                archive = loaded
            case .failure:
                return .success(0)
            }

            let before = archive.entries.count
            archive.entries = archive.entries.filter { repositoryIDs.contains($0.repositoryID) }
            let removed = before - archive.entries.count

            guard removed > 0 else { return .success(0) }

            switch saveUnlocked(archive: archive) {
            case .success:
                _diagnostics.totalEntriesPurged += removed
                _diagnostics.currentEntryCount = archive.entries.count
                return .success(removed)
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    /// Force a compaction run.
    @discardableResult
    func compact() -> Result<Int, HistoryStoreError> {
        queue.sync {
            processLock.lock()
            defer { processLock.unlock() }

            var archive: RepositoryHistoryArchive
            switch loadUnlocked() {
            case .success(let loaded):
                archive = loaded
            case .failure(let error):
                return .failure(error)
            }

            let startTime = Date()
            switch compactUnlocked(entries: archive.entries) {
            case .success(let compacted):
                let duration = Date().timeIntervalSince(startTime) * 1000
                _diagnostics.lastCompactionDurationMs = duration
                _diagnostics.totalCompactionRuns += 1

                let purged = archive.entries.count - compacted.count
                _diagnostics.totalEntriesPurged += purged

                let archiveToSave = RepositoryHistoryArchive(
                    schemaVersion: RepositoryHistorySchema.version,
                    entries: compacted
                )

                switch saveUnlocked(archive: archiveToSave) {
                case .success:
                    _diagnostics.currentEntryCount = compacted.count
                    writeCountSinceLastCompaction = 0
                    return .success(purged)
                case .failure(let error):
                    return .failure(error)
                }
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    /// Clear all history entries.
    func clear() -> Result<Void, HistoryStoreError> {
        queue.sync {
            processLock.lock()
            defer { processLock.unlock() }

            let archive = RepositoryHistoryArchive(
                schemaVersion: RepositoryHistorySchema.version,
                entries: []
            )

            switch saveUnlocked(archive: archive) {
            case .success:
                _diagnostics.currentEntryCount = 0
                _diagnostics.totalRepositoryCount = 0
                return .success(())
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    /// Get the total number of entries currently stored.
    func count() -> Int {
        queue.sync {
            processLock.lock()
            defer { processLock.unlock() }

            switch loadUnlocked() {
            case .success(let archive):
                return archive.entries.count
            case .failure:
                return 0
            }
        }
    }

    // MARK: - Migration support

    /// Migrate from an older archive format. Currently supports v1 → v1 (no-op).
    static func migrate(_ archive: RepositoryHistoryArchive) -> Result<RepositoryHistoryArchive, HistoryStoreError> {
        guard archive.schemaVersion <= RepositoryHistorySchema.version else {
            return .failure(.schemaMismatch(
                expected: RepositoryHistorySchema.version,
                actual: archive.schemaVersion
            ))
        }
        guard archive.schemaVersion >= RepositoryHistorySchema.oldestMigratableVersion else {
            return .failure(.migrationFailed(
                "schema v\(archive.schemaVersion) is too old to migrate; supported from v\(RepositoryHistorySchema.oldestMigratableVersion)"
            ))
        }

        // Future migrations would go here. Currently all versions are identical.
        return .success(archive)
    }

    // MARK: - Private helpers

    private func loadUnlocked() -> Result<RepositoryHistoryArchive, HistoryStoreError> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .success(RepositoryHistoryArchive(entries: []))
        }

        do {
            let data = try Data(contentsOf: fileURL)
            _loadMetrics.archiveDecodeCount += 1
            _loadMetrics.archiveBytesRead += data.count
            let decoder = JSONDecoder()
            let archive = try decoder.decode(RepositoryHistoryArchive.self, from: data)

            guard archive.schemaVersion <= RepositoryHistorySchema.version else {
                return .failure(.schemaMismatch(
                    expected: RepositoryHistorySchema.version,
                    actual: archive.schemaVersion
                ))
            }

            if archive.schemaVersion < RepositoryHistorySchema.version,
               archive.schemaVersion >= RepositoryHistorySchema.oldestMigratableVersion {
                let migrated = try Self.migrate(archive).get()
                _diagnostics.lastMigrationVersion = archive.schemaVersion
                _diagnostics.lastMigrationSuccess = true
                // Persist migrated version
                if case .failure(let error) = saveUnlocked(archive: migrated) {
                    logger.warning("failed to persist migrated archive: \(error.localizedDescription)")
                }
                return .success(migrated)
            }

            return .success(archive)
        } catch let error as DecodingError {
            // File corruption — attempt recovery by starting fresh
            logger.warning("history archive decode failed, recovering: \(error.localizedDescription)")
            _diagnostics.lastRecoveryCount = (_diagnostics.lastRecoveryCount ?? 0) + 1
            let fresh = RepositoryHistoryArchive(entries: [])
            if case .failure(let saveError) = saveUnlocked(archive: fresh) {
                return .failure(.readFailed(
                    "decode failed: \(error.localizedDescription), recovery save failed: \(saveError.localizedDescription)"
                ))
            }
            return .success(fresh)
        } catch {
            // I/O read failure — attempt recovery by starting fresh
            logger.warning("history archive read failed, recovering: \(error.localizedDescription)")
            _diagnostics.lastRecoveryCount = (_diagnostics.lastRecoveryCount ?? 0) + 1
            let fresh = RepositoryHistoryArchive(entries: [])
            if case .failure(let saveError) = saveUnlocked(archive: fresh) {
                return .failure(.readFailed(
                    "read failed: \(error.localizedDescription), recovery save failed: \(saveError.localizedDescription)"
                ))
            }
            return .success(fresh)
        }
    }

    private func latestStates(in entries: [RepositoryHistoryEntry]) -> [String: HistoryStatePoint] {
        var latest: [String: RepositoryHistoryEntry] = [:]
        for entry in entries where entry.recordedAt > (latest[entry.repositoryID]?.recordedAt ?? "") {
            latest[entry.repositoryID] = entry
        }
        return latest.mapValues(\.state)
    }

    private func snapshotEntries(
        repositories: [RepositorySnapshot],
        recordedAt: String,
        previousStates: [String: HistoryStatePoint]
    ) -> [RepositoryHistoryEntry] {
        repositories.map { repository in
            let state = HistoryStatePoint(snapshot: repository)
            let previousState = previousStates[repository.id]
            return RepositoryHistoryEntry(
                repositoryID: repository.id,
                recordedAt: recordedAt,
                kind: HistoryEntryKindClassifier.classify(
                    previous: previousState,
                    current: state,
                    lastDataSource: previousState?.dataSource,
                    currentDataSource: state.dataSource
                ),
                state: state
            )
        }
    }

    private func loadArchiveForRecordingUnlocked() -> RepositoryHistoryArchive {
        switch loadUnlocked() {
        case .success(let archive):
            return archive
        case .failure(let error):
            logger.warning("history store load failed, starting fresh: \(error.localizedDescription)")
            return RepositoryHistoryArchive(entries: [])
        }
    }

    private func recordUnlocked(
        entries: [RepositoryHistoryEntry],
        archive: RepositoryHistoryArchive
    ) -> Result<HistoryRecordOutcome, HistoryStoreError> {
        let beforeCount = archive.entries.count

        // Group entries by repository, keep newest first for each.
        let grouped = Dictionary(grouping: entries, by: { $0.repositoryID })
        var entriesToAdd: [RepositoryHistoryEntry] = []

        for (repoID, repoEntries) in grouped {
            let sorted = repoEntries.sorted { $0.recordedAt > $1.recordedAt }
            guard let newest = sorted.first else { continue }

            // Check if the latest entry for this repo is identical.
            let lastForRepo = archive.entries
                .filter { $0.repositoryID == repoID }
                .max { $0.recordedAt < $1.recordedAt }

            if let last = lastForRepo,
               last.kind == .scanRecord,
               newest.kind == .scanRecord,
               last.state == newest.state {
                continue
            }

            entriesToAdd.append(newest)
        }

        var updated = archive.entries + entriesToAdd
        updated.sort { $0.recordedAt > $1.recordedAt }

        let added = updated.count - beforeCount
        let skipped = entries.count - added

        _diagnostics.totalEntriesWritten += entries.count
        _diagnostics.totalDedupSkipped += skipped

        let compactionNeeded = updated.count > Int(Double(config.maxTotalEntries) * config.softThresholdFraction)
            || writeCountSinceLastCompaction >= config.compactionInterval

        if compactionNeeded {
            switch compactUnlocked(entries: updated) {
            case .success(let compacted):
                updated = compacted
                _diagnostics.totalCompactionRuns += 1
                writeCountSinceLastCompaction = 0
            case .failure(let error):
                logger.error("compaction failed: \(error.localizedDescription)")
                _diagnostics.lastRecoveryCount = (_diagnostics.lastRecoveryCount ?? 0) + 1
            }
        } else {
            writeCountSinceLastCompaction += 1
        }

        let archiveToSave = RepositoryHistoryArchive(
            schemaVersion: RepositoryHistorySchema.version,
            entries: updated
        )

        switch saveUnlocked(archive: archiveToSave) {
        case .success:
            updateFileSizeDiagnostics()
            _diagnostics.currentEntryCount = updated.count
            _diagnostics.totalRepositoryCount = Set(updated.map(\.repositoryID)).count
            return .success(HistoryRecordOutcome(addedCount: added, totalEntryCount: updated.count))
        case .failure(let error):
            return .failure(error)
        }
    }

    private func saveUnlocked(archive: RepositoryHistoryArchive) -> Result<Void, HistoryStoreError> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)

            // Atomic write via temporary file + rename
            let tempURL = directory.appendingPathComponent(
                ".\(Self.fileName).tmp-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let data = try encoder.encode(archive)
            try data.write(to: tempURL, options: [.withoutOverwriting])

            // fsync
            let descriptor = Darwin.open(tempURL.path, O_RDONLY)
            if descriptor >= 0 {
                Darwin.fsync(descriptor)
                Darwin.close(descriptor)
            }

            guard Darwin.rename(tempURL.path, fileURL.path) == 0 else {
                throw HistoryStoreError.writeFailed(
                    "atomic rename failed: \(String(cString: strerror(errno)))"
                )
            }

            return .success(())
        } catch let error as HistoryStoreError {
            return .failure(error)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    /// Compact entries: apply retention, per-repo cap, dedup consecutive scan records.
    private func compactUnlocked(entries: [RepositoryHistoryEntry]) -> Result<[RepositoryHistoryEntry], HistoryStoreError> {
        let startTime = Date()

        // 1. Group by repository
        let grouped = Dictionary(grouping: entries, by: { $0.repositoryID })

        var compacted: [RepositoryHistoryEntry] = []
        let cutoffDate = Calendar.current.date(byAdding: .day,
                                                value: -config.retentionDays,
                                                to: Date()) ?? Date()

        for (_, repoEntries) in grouped {
            // Sort newest first
            let sorted = repoEntries.sorted { $0.recordedAt > $1.recordedAt }

            var filtered: [RepositoryHistoryEntry] = []

            for (index, entry) in sorted.enumerated() {
                // Skip if below the per-repo cap
                guard index < config.maxEntriesPerRepo else { break }

                // Skip if older than retention
                if let date = DateFormatting.date(from: entry.recordedAt),
                   date < cutoffDate {
                    continue
                }

                // Dedup consecutive scan records with identical state
                if entry.kind == .scanRecord,
                   let last = filtered.first,
                   last.kind == .scanRecord,
                   last.state == entry.state {
                    continue
                }

                filtered.append(entry)
            }

            compacted.append(contentsOf: filtered)
        }

        // 2. Apply total cap — keep newest entries only
        if compacted.count > config.maxTotalEntries {
            compacted.sort { $0.recordedAt > $1.recordedAt }
            compacted = Array(compacted.prefix(config.maxTotalEntries))
        }

        compacted.sort { $0.recordedAt > $1.recordedAt }

        let duration = Date().timeIntervalSince(startTime) * 1000
        _diagnostics.lastCompactionDurationMs = duration

        return .success(compacted)
    }

    private func updateFileSizeDiagnostics() {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let size = attributes[.size] as? Int {
                _diagnostics.storageFileSizeBytes = size
            }
        } catch {
            _diagnostics.storageFileSizeBytes = 0
        }
    }
}

struct HistoryRecordOutcome: Equatable, Sendable {
    let addedCount: Int
    let totalEntryCount: Int
}

struct RepositoryHistoryLoadMetrics: Equatable, Sendable {
    var archiveDecodeCount = 0
    var archiveBytesRead = 0
}

extension RepositoryHistoryStore {
    /// Reset diagnostics counters (for testing).
    func resetDiagnostics() {
        queue.sync {
            _diagnostics = HistoryDiagnosticsSnapshot.empty()
            _loadMetrics = RepositoryHistoryLoadMetrics()
            writeCountSinceLastCompaction = 0
        }
    }

    /// Get archive load metrics for deterministic performance tests.
    func loadMetrics() -> RepositoryHistoryLoadMetrics {
        queue.sync { _loadMetrics }
    }

    /// Get the current diagnostics snapshot.
    func diagnosticsSnapshot() -> HistoryDiagnosticsSnapshot {
        queue.sync { _diagnostics }
    }
}

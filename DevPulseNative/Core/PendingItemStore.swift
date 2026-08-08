import Darwin
import Foundation
import OSLog

// MARK: - Store error

enum PendingItemStoreError: LocalizedError, Equatable {
    case readFailed(String)
    case writeFailed(String)
    case schemaMismatch(expected: Int, actual: Int)
    case migrationFailed(String)
    case lockFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let reason):
            return "待处理事项读取失败：\(reason)"
        case .writeFailed(let reason):
            return "待处理事项写入失败：\(reason)"
        case .schemaMismatch(let expected, let actual):
            return "待处理事项 schema v\(actual) 不兼容，期望 v\(expected)"
        case .migrationFailed(let reason):
            return "待处理事项迁移失败：\(reason)"
        case .lockFailed(let reason):
            return "待处理事项锁失败：\(reason)"
        }
    }
}

// MARK: - Pending item store

/// Persistent store for pending items (待处理事项).
///
/// Design:
/// - Single JSON file in App Group container
/// - Atomic writes (temporary file + rename)
/// - In-memory cache for fast reads
/// - Thread-safe via serial queue + NSLock
/// - Schema versioned with migration support
/// - Corruption recovery via fresh archive
final class PendingItemStore: @unchecked Sendable {
    private static let fileName = "pending-items.json"
    private static let lockFileName = ".pending-items.lock"
    /// How long the in-memory cache is considered valid before a reload.
    private static let cacheTTL: TimeInterval = 30 // seconds

    private let fileURL: URL
    private let lockURL: URL
    private let queue: DispatchQueue
    // POSIX record locks are process-scoped; serialize independent store
    // instances in this process as well.
    private static let processLock = NSLock()
    private let logger = Logger(subsystem: "local.devpulse.app", category: "PendingItemStore")

    private var cachedArchive: PendingItemArchive?
    private var lastLoadResult: Result<PendingItemArchive, PendingItemStoreError>?
    private var cacheTimestamp: Date?

    init(fileURL: URL? = nil) {
        let url = fileURL ?? (FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
        )?.appendingPathComponent(Self.fileName))
        ?? {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(Self.fileName)
            Logger(subsystem: "local.devpulse.app", category: "PendingItemStore")
                .warning("App Group container unavailable; falling back to /tmp. Data will not persist across reboots.")
            return fallback
        }()

        self.fileURL = url
        self.lockURL = url.deletingLastPathComponent().appendingPathComponent(Self.lockFileName)
        queue = DispatchQueue(
            label: "local.devpulse.app.pending-item-store",
            qos: .utility,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
    }

    static func live() -> PendingItemStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
        ) else {
            return PendingItemStore()
        }
        return PendingItemStore(fileURL: container.appendingPathComponent(fileName))
    }

    // MARK: - Load

    func load() -> Result<PendingItemArchive, PendingItemStoreError> {
        queue.sync {
            if let cached = lastLoadResult, let ts = cacheTimestamp, -ts.timeIntervalSinceNow <= Self.cacheTTL {
                return cached
            }
            let result = loadUnsafe()
            lastLoadResult = result
            cacheTimestamp = Date()
            return result
        }
    }

    /// Evict in-memory cache so the next `load()` re-reads from disk.
    /// Safe to call on memory pressure — does not affect persisted data.
    func invalidateCache() {
        queue.sync {
            cachedArchive = nil
            lastLoadResult = nil
            cacheTimestamp = nil
        }
    }

    /// Returns true when the in-memory cache is expired and the next
    /// `load()` will trigger a fresh disk read.
    var isCacheExpired: Bool {
        queue.sync {
            guard let ts = cacheTimestamp else { return true }
            return -ts.timeIntervalSinceNow > Self.cacheTTL
        }
    }

    private func loadUnsafe() -> Result<PendingItemArchive, PendingItemStoreError> {
        withFileLock {
            loadUnsafeUnlocked()
        }
    }

    /// Reads while the caller already owns `withFileLock`.
    private func loadUnsafeUnlocked() -> Result<PendingItemArchive, PendingItemStoreError> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = PendingItemArchive()
            cachedArchive = empty
            return .success(empty)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            logger.warning("pending items read failed: \(error.localizedDescription)")
            logger.warning("recovering with empty archive — replacing corrupt file")
            let empty = PendingItemArchive()
            // Persist the empty archive so corrupt data is not retried forever.
            if case .failure(let writeError) = saveUnsafeUnlocked(empty) {
                logger.error("failed to replace corrupt pending items file: \(writeError.localizedDescription)")
            }
            cachedArchive = empty
            return .success(empty)
        }

        let decoder = JSONDecoder()
        guard let archive = try? decoder.decode(PendingItemArchive.self, from: data) else {
            logger.warning("pending items decode failed, recovering with empty archive — replacing corrupt file")
            let empty = PendingItemArchive()
            if case .failure(let writeError) = saveUnsafeUnlocked(empty) {
                logger.error("failed to replace corrupt pending items file: \(writeError.localizedDescription)")
            }
            cachedArchive = empty
            return .success(empty)
        }

        guard archive.schemaVersion <= PendingItemArchive.currentSchemaVersion else {
            return .failure(.schemaMismatch(
                expected: PendingItemArchive.currentSchemaVersion,
                actual: archive.schemaVersion
            ))
        }

        if archive.schemaVersion < PendingItemArchive.currentSchemaVersion {
            let migrated = migrate(archive: archive)
            switch saveUnsafeUnlocked(migrated) {
            case .success:
                cachedArchive = migrated
                return .success(migrated)
            case .failure(let error):
                return .failure(error)
            }
        }

        cachedArchive = archive
        cacheTimestamp = Date()
        return .success(archive)
    }

    // MARK: - Save

    @discardableResult
    func save(_ archive: PendingItemArchive) -> Result<PendingItemArchive, PendingItemStoreError> {
        queue.sync {
            let result = saveUnsafe(archive)
            if case .success(let saved) = result {
                cachedArchive = saved
                lastLoadResult = .success(saved)
                cacheTimestamp = Date()
            }
            return result
        }
    }

    private func saveUnsafe(_ archive: PendingItemArchive) -> Result<PendingItemArchive, PendingItemStoreError> {
        withFileLock {
            saveUnsafeUnlocked(archive)
        }
    }

    /// Write the archive to disk without acquiring any lock.
    /// Caller must already hold `withFileLock` (processLock + POSIX lock).
    private func saveUnsafeUnlocked(_ archive: PendingItemArchive) -> Result<PendingItemArchive, PendingItemStoreError> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(archive)
        } catch {
            return .failure(.writeFailed("encode failed: \(error.localizedDescription)"))
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.writeFailed("directory creation: \(error.localizedDescription)"))
        }

        let tmpURL = directory.appendingPathComponent(".pending-items.tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try data.write(to: tmpURL, options: [.withoutOverwriting])
            try fsyncFile(at: tmpURL)
        } catch {
            return .failure(.writeFailed("staging: \(error.localizedDescription)"))
        }

        guard Darwin.rename(tmpURL.path, fileURL.path) == 0 else {
            return .failure(.writeFailed("atomic rename: \(String(cString: strerror(errno)))"))
        }

        fsyncDirectory(at: directory)
        return .success(archive)
    }

    // MARK: - Mutations

    /// Read-modify-write an archive while holding one process/POSIX lock. This
    /// prevents evaluator writes and user actions from losing each other
    /// between separate `load()` and `save()` calls.
    private func mutateArchive(
        _ mutation: (inout PendingItemArchive) -> PendingItemStoreError?
    ) -> Result<PendingItemArchive, PendingItemStoreError> {
        queue.sync {
            withFileLock {
                var archive: PendingItemArchive
                switch loadUnsafeUnlocked() {
                case .success(let loaded):
                    archive = loaded
                case .failure(let error):
                    return .failure(error)
                }

                let original = archive
                if let error = mutation(&archive) {
                    return .failure(error)
                }
                if archive == original {
                    cachedArchive = archive
                    lastLoadResult = .success(archive)
                    cacheTimestamp = Date()
                    return .success(archive)
                }

                let result = saveUnsafeUnlocked(archive)
                if case .success(let saved) = result {
                    cachedArchive = saved
                    lastLoadResult = .success(saved)
                    cacheTimestamp = Date()
                }
                return result
            }
        }
    }

    /// Replace all items in bulk (used by evaluator after a refresh).
    func replaceAll(with items: [PendingItem]) -> Result<PendingItemArchive, PendingItemStoreError> {
        mutateArchive { archive in
            // Preserve dismissed IDs and user-set statuses for matching items.
            let existingByID = Dictionary(uniqueKeysWithValues: archive.items.map { ($0.id, $0) })

            var merged: [PendingItem] = []
            for item in items {
                if let existing = existingByID[item.id] {
                    let preservedStatus: PendingItemStatus
                    switch existing.status {
                    case .acknowledged, .muted, .permanentlyIgnored:
                        preservedStatus = existing.status
                    case .snoozed:
                        if let until = existing.snoozedUntil.flatMap(DateFormatting.date(from:)),
                           until <= Date() {
                            preservedStatus = .restored
                        } else {
                            preservedStatus = .snoozed
                        }
                    case .restored:
                        preservedStatus = item.status
                    case .active, .resolved:
                        preservedStatus = item.status
                    }

                    var mergedItem = item
                    mergedItem.status = preservedStatus
                    if preservedStatus == .snoozed {
                        mergedItem.snoozedUntil = existing.snoozedUntil
                    }
                    mergedItem = PendingItem(
                        id: mergedItem.id,
                        source: mergedItem.source,
                        severity: mergedItem.severity,
                        repositoryID: mergedItem.repositoryID,
                        repositoryName: mergedItem.repositoryName,
                        workspaceID: mergedItem.workspaceID,
                        workspaceName: mergedItem.workspaceName,
                        title: mergedItem.title,
                        explanation: mergedItem.explanation,
                        evidence: mergedItem.evidence,
                        firstDetectedAt: existing.firstDetectedAt,
                        lastConfirmedAt: mergedItem.lastConfirmedAt,
                        status: mergedItem.status,
                        snoozedUntil: mergedItem.snoozedUntil,
                        duration: mergedItem.duration,
                        lastTransition: mergedItem.lastTransition
                    )
                    merged.append(mergedItem)
                } else {
                    merged.append(item)
                }
            }

            archive.items = merged
            return nil
        }
    }

    /// Apply a user action to an item.
    func applyUserAction(
        itemID: String,
        action: PendingItemUserAction,
        snoozeDuration: TimeInterval? = nil
    ) -> Result<PendingItemArchive, PendingItemStoreError> {
        mutateArchive { archive in
            guard let idx = archive.items.firstIndex(where: { $0.id == itemID }) else {
                return .writeFailed("item not found")
            }

            var item = archive.items[idx]
            let now = DateFormatting.nowISO()

            switch action {
            case .acknowledge:
                item.status = .acknowledged
                item.lastConfirmedAt = now
            case .snooze:
                item.status = .snoozed
                if let duration = snoozeDuration {
                    let date = Date().addingTimeInterval(duration)
                    item.snoozedUntil = DateFormatting.isoString(from: date)
                } else {
                    let date = Date().addingTimeInterval(3600)
                    item.snoozedUntil = DateFormatting.isoString(from: date)
                }
                item.lastConfirmedAt = now
            case .unmute:
                item.status = .active
                item.lastConfirmedAt = now
            case .restoreReminder:
                item.status = .restored
                item.lastConfirmedAt = now
            case .permanentlyIgnore:
                item.status = .permanentlyIgnored
                item.lastConfirmedAt = now
            case .cleanupStaleRepository:
                item.status = .resolved
                item.lastConfirmedAt = now
                item.explanation += "（已清理并移除跟踪）"
            }

            archive.items[idx] = item
            return nil
        }
    }

    /// Get items matching a filter.
    func filteredItems(_ filter: PendingItemFilter) -> Result<[PendingItem], PendingItemStoreError> {
        switch load() {
        case .success(let archive):
            return .success(filter.apply(to: archive.items))
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Get active (not resolved, not permanently ignored) items.
    func activeItems() -> Result<[PendingItem], PendingItemStoreError> {
        switch load() {
        case .success(let archive):
            let active = archive.items.filter {
                $0.status != .resolved && $0.status != .permanentlyIgnored
            }
            return .success(active)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Get items for a specific repository.
    func items(for repositoryID: String) -> Result<[PendingItem], PendingItemStoreError> {
        switch load() {
        case .success(let archive):
            return .success(archive.items.filter { $0.repositoryID == repositoryID })
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Get items for a specific workspace.
    func workspaceItems(for workspaceID: String) -> Result<[PendingItem], PendingItemStoreError> {
        switch load() {
        case .success(let archive):
            return .success(archive.items.filter { $0.workspaceID == workspaceID })
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Compute lightweight summary for widget.
    func widgetSummary() -> Result<PendingItemWidgetSummary, PendingItemStoreError> {
        switch load() {
        case .success(let archive):
            return .success(PendingItemWidgetSummary.build(from: archive.items))
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Migration

    private func migrate(archive: PendingItemArchive) -> PendingItemArchive {
        var migrated = archive
        let record = PendingItemMigrationRecord(
            fromVersion: archive.schemaVersion,
            toVersion: PendingItemArchive.currentSchemaVersion,
            migratedAt: DateFormatting.nowISO(),
            success: true,
            detail: "migrated from schema v\(archive.schemaVersion) to v\(PendingItemArchive.currentSchemaVersion)"
        )
        migrated.schemaVersion = PendingItemArchive.currentSchemaVersion
        migrated.migrationLog.append(record)
        return migrated
    }

    // MARK: - File lock

    private func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return try body()
        }
        defer { Darwin.close(descriptor) }

        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            if errno == EINTR { continue }
            break
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    private func fsyncFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        Darwin.fsync(descriptor)
    }

    private func fsyncDirectory(at url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        Darwin.fsync(descriptor)
    }
}

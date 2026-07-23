import Darwin
import Foundation
import OSLog

// MARK: - Notification store

/// Persists notification state for pending items.
///
/// Separate from the item store because notification decisions need fast
/// reads and writes that must not block item store access.
final class PendingItemNotificationStore: @unchecked Sendable {
    private static let fileName = "pending-item-notifications.json"
    private static let lockFileName = ".pending-item-notifications.lock"

    private let fileURL: URL
    private let lockURL: URL
    private let queue: DispatchQueue
    private let processLock = NSLock()
    private let logger = Logger(subsystem: "local.devpulse.app", category: "PendingNotifStore")

    private var cachedArchive: PendingItemNotificationArchive?

    init(fileURL: URL? = nil) {
        let url = fileURL ?? (FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
        )?.appendingPathComponent(Self.fileName))
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(Self.fileName)

        self.fileURL = url
        self.lockURL = url.deletingLastPathComponent().appendingPathComponent(Self.lockFileName)
        self.queue = DispatchQueue(
            label: "local.devpulse.app.pending-notif-store",
            qos: .utility,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
    }

    static func live() -> PendingItemNotificationStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
        ) else {
            return PendingItemNotificationStore()
        }
        return PendingItemNotificationStore(fileURL: container.appendingPathComponent(fileName))
    }

    func load() -> Result<PendingItemNotificationArchive, PendingItemStoreError> {
        queue.sync {
            if let cached = cachedArchive {
                return .success(cached)
            }
            let result = loadUnsafe()
            if case .success(let archive) = result {
                cachedArchive = archive
            }
            return result
        }
    }

    func invalidateCache() {
        queue.sync {
            cachedArchive = nil
        }
    }

    private func loadUnsafe() -> Result<PendingItemNotificationArchive, PendingItemStoreError> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = PendingItemNotificationArchive()
            cachedArchive = empty
            return .success(empty)
        }

        return withFileLock {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                logger.warning("pending notif read failed, recovering: \(error.localizedDescription)")
                let empty = PendingItemNotificationArchive()
                cachedArchive = empty
                return .success(empty)
            }

            guard let archive = try? JSONDecoder().decode(PendingItemNotificationArchive.self, from: data) else {
                logger.warning("pending notif decode failed, recovering with empty")
                let empty = PendingItemNotificationArchive()
                cachedArchive = empty
                return .success(empty)
            }

            guard archive.schemaVersion <= PendingItemNotificationArchive.currentSchemaVersion else {
                return .failure(.schemaMismatch(
                    expected: PendingItemNotificationArchive.currentSchemaVersion,
                    actual: archive.schemaVersion
                ))
            }

            cachedArchive = archive
            return .success(archive)
        }
    }

    @discardableResult
    func save(_ archive: PendingItemNotificationArchive) -> Result<PendingItemNotificationArchive, PendingItemStoreError> {
        queue.sync {
            let result = saveUnsafe(archive)
            if case .success(let saved) = result {
                cachedArchive = saved
            }
            return result
        }
    }

    private func saveUnsafe(_ archive: PendingItemNotificationArchive) -> Result<PendingItemNotificationArchive, PendingItemStoreError> {
        withFileLock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data: Data
            do {
                data = try encoder.encode(archive)
            } catch {
                return .failure(.writeFailed("encode: \(error.localizedDescription)"))
            }

            let directory = fileURL.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return .failure(.writeFailed("dir: \(error.localizedDescription)"))
            }

            let tmpURL = directory.appendingPathComponent(".\(Self.fileName).tmp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            do {
                try data.write(to: tmpURL, options: [.withoutOverwriting])
                try fsyncFile(at: tmpURL)
            } catch {
                return .failure(.writeFailed("staging: \(error.localizedDescription)"))
            }

            guard Darwin.rename(tmpURL.path, fileURL.path) == 0 else {
                return .failure(.writeFailed("rename: \(String(cString: strerror(errno)))"))
            }

            fsyncDirectory(at: directory)
            return .success(archive)
        }
    }

    /// Record that a notification was sent for an item.
    func recordNotification(
        itemID: String,
        severity: PendingItemSeverity,
        transition: PendingItemTransition,
        now: Date = Date()
    ) -> Result<PendingItemNotificationArchive, PendingItemStoreError> {
        switch load() {
        case .success(var archive):
            var state = archive.notificationStates[itemID] ?? .initial()
            let nowISO = DateFormatting.nowISO()
            state.lastNotifiedAt = nowISO
            state.notificationCount = (state.notificationCount) + 1
            state.lastSeverityNotified = severity
            let cooldown = PendingItemNotificationStrategy.cooldownPeriod(after: transition)
            state.coolDownUntil = DateFormatting.isoString(from: now.addingTimeInterval(cooldown))
            archive.notificationStates[itemID] = state
            archive.lastGlobalNotification = nowISO
            return save(archive)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Update global suppression state.
    func setSuppression(
        enabled: Bool,
        until: Date? = nil
    ) -> Result<PendingItemNotificationArchive, PendingItemStoreError> {
        switch load() {
        case .success(var archive):
            archive.suppressionEnabled = enabled
            archive.suppressionUntil = until.map { DateFormatting.isoString(from: $0) }
            return save(archive)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        processLock.lock()
        defer { processLock.unlock() }

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return try body() }
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

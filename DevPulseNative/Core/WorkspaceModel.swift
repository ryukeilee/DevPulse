import CryptoKit
import Foundation
import OSLog

// MARK: - Schema

enum WorkspaceSchema {
    static let version = 1
    static let oldestMigratableVersion = 1
}

// MARK: - Grouping basis

/// Describes why repositories are grouped into one workspace.
enum WorkspaceGroupingBasis: String, Codable, Equatable, Sendable {
    case manual
    case parentDirectory
    case gitCommonDir
    case remoteIdentity
    case historicalAssociation
    case singleRepository

    var displayName: String {
        switch self {
        case .manual: return "手动分组"
        case .parentDirectory: return "相同父目录"
        case .gitCommonDir: return "共享 Git 存储"
        case .remoteIdentity: return "相同远程仓库"
        case .historicalAssociation: return "历史关联"
        case .singleRepository: return "单一仓库"
        }
    }

    var systemImage: String {
        switch self {
        case .manual: return "hand.raised"
        case .parentDirectory: return "folder"
        case .gitCommonDir: return "externaldrive.connected.to.line.below"
        case .remoteIdentity: return "cloud"
        case .historicalAssociation: return "clock.arrow.circlepath"
        case .singleRepository: return "shippingbox"
        }
    }
}

// MARK: - Workspace

struct Workspace: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var sortOrder: Int
    var isPinned: Bool
    var repositoryIDs: [String]  // ordered, canonical identity IDs
    var groupingBasis: WorkspaceGroupingBasis
    var autoSuggestConfirmed: Bool  // false = suggested but not yet confirmed
    var isExpanded: Bool
    var createdAt: String  // ISO8601
    var updatedAt: String  // ISO8601

    init(
        id: String? = nil,
        name: String,
        sortOrder: Int = 0,
        isPinned: Bool = false,
        repositoryIDs: [String],
        groupingBasis: WorkspaceGroupingBasis = .manual,
        autoSuggestConfirmed: Bool = true,
        isExpanded: Bool = true,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        let now = ISO8601DateFormatter().string(from: Date())
        let identity = [
            name,
            repositoryIDs.sorted().joined(separator: ","),
            now
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.id = id ?? "ws-v1-\(digest)"
        self.name = name
        self.sortOrder = sortOrder
        self.isPinned = isPinned
        self.repositoryIDs = repositoryIDs
        self.groupingBasis = groupingBasis
        self.autoSuggestConfirmed = autoSuggestConfirmed
        self.isExpanded = isExpanded
        self.createdAt = createdAt ?? now
        self.updatedAt = updatedAt ?? now
    }
}

// MARK: - Workspace archive

struct WorkspaceArchive: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var workspaces: [Workspace]
    /// Versioned migration history
    var migrationLog: [WorkspaceMigrationRecord]
    /// Set of suggestion hashes the user has permanently dismissed
    var dismissedSuggestionHashes: Set<String>

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        workspaces: [Workspace] = [],
        migrationLog: [WorkspaceMigrationRecord] = [],
        dismissedSuggestionHashes: Set<String> = []
    ) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.migrationLog = migrationLog
        self.dismissedSuggestionHashes = dismissedSuggestionHashes
    }
}

// MARK: - Migration record

struct WorkspaceMigrationRecord: Codable, Equatable, Sendable {
    let fromVersion: Int
    let toVersion: Int
    let migratedAt: String  // ISO8601
    let success: Bool
    let detail: String
}

// MARK: - Auto-suggest candidate

struct WorkspaceAutoSuggestCandidate: Codable, Equatable, Identifiable, Sendable {
    let id: String  // hash of the suggestion content
    let name: String
    let repositoryIDs: [String]
    let groupingBasis: WorkspaceGroupingBasis
    let evidence: String

    init(
        name: String,
        repositoryIDs: [String],
        groupingBasis: WorkspaceGroupingBasis,
        evidence: String
    ) {
        let canonical = [name] + repositoryIDs.sorted() + [groupingBasis.rawValue, evidence]
        let digest = SHA256.hash(data: Data(canonical.joined(separator: "\u{1F}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.id = "suggest-\(digest)"
        self.name = name
        self.repositoryIDs = repositoryIDs
        self.groupingBasis = groupingBasis
        self.evidence = evidence
    }
}

// MARK: - Workspace store error

enum WorkspaceStoreError: LocalizedError, Equatable {
    case readFailed(String)
    case writeFailed(String)
    case schemaMismatch(expected: Int, actual: Int)
    case migrationFailed(String)
    case lockFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let reason):
            return "工作空间读取失败：\(reason)"
        case .writeFailed(let reason):
            return "工作空间写入失败：\(reason)"
        case .schemaMismatch(let expected, let actual):
            return "工作空间 schema v\(actual) 不兼容，期望 v\(expected)"
        case .migrationFailed(let reason):
            return "工作空间迁移失败：\(reason)"
        case .lockFailed(let reason):
            return "工作空间锁失败：\(reason)"
        }
    }
}

// MARK: - Workspace store

/// Persistent, atomic workspace store. Lives in the App Group container so
/// both the app and widget can read it, though only the app writes.
final class WorkspaceStore: @unchecked Sendable {
    private static let fileName = "workspaces.json"
    private static let lockFileName = ".workspaces.lock"

    private let fileURL: URL
    private let lockURL: URL
    private let queue: DispatchQueue
    // POSIX record locks are process-scoped, so separate store instances need
    // a shared in-process lock to remain mutually exclusive.
    private static let processLock = NSLock()
    private let logger = Logger(subsystem: "local.devpulse.app", category: "WorkspaceStore")

    // In-memory cache
    private var cachedArchive: WorkspaceArchive?
    private var lastLoadResult: Result<WorkspaceArchive, WorkspaceStoreError>?

    init(fileURL: URL? = nil) {
        let url = fileURL ?? (FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
        )?.appendingPathComponent(Self.fileName))
        ?? {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(Self.fileName)
            Logger(subsystem: "local.devpulse.app", category: "WorkspaceStore")
                .warning("App Group container unavailable; falling back to /tmp. Data will not persist across reboots.")
            return fallback
        }()

        self.fileURL = url
        self.lockURL = url.deletingLastPathComponent().appendingPathComponent(Self.lockFileName)
        self.queue = DispatchQueue(
            label: "local.devpulse.app.workspace-store",
            qos: .utility,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
    }

    static func live() -> WorkspaceStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
        ) else {
            return WorkspaceStore()
        }
        return WorkspaceStore(fileURL: container.appendingPathComponent(fileName))
    }

    // MARK: - Load

    func load() -> Result<WorkspaceArchive, WorkspaceStoreError> {
        queue.sync {
            if let cached = lastLoadResult {
                return cached
            }
            let result = loadUnsafe()
            lastLoadResult = result
            return result
        }
    }

    func invalidateCache() {
        queue.sync {
            cachedArchive = nil
            lastLoadResult = nil
        }
    }

    private func loadUnsafe() -> Result<WorkspaceArchive, WorkspaceStoreError> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = WorkspaceArchive()
            cachedArchive = empty
            return .success(empty)
        }

        return withFileLock {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                return .failure(.readFailed(error.localizedDescription))
            }

            let decoder = JSONDecoder()
            guard let archive = try? decoder.decode(WorkspaceArchive.self, from: data) else {
                // Attempt to recover: empty archive on corruption
                logger.warning("workspace archive corrupted, recovering with empty archive")
                let empty = WorkspaceArchive()
                cachedArchive = empty
                return .success(empty)
            }

            guard archive.schemaVersion <= WorkspaceArchive.currentSchemaVersion else {
                return .failure(.schemaMismatch(
                    expected: WorkspaceArchive.currentSchemaVersion,
                    actual: archive.schemaVersion
                ))
            }

            // Migrate if needed
            if archive.schemaVersion < WorkspaceArchive.currentSchemaVersion {
                let migrated = migrate(archive: archive)
                // `loadUnsafe` already holds the file lock. Re-entering
                // `saveUnsafe` would try to acquire the non-recursive process
                // lock again and deadlock during migration.
                switch saveUnsafeUnlocked(migrated) {
                case .success:
                    cachedArchive = migrated
                    return .success(migrated)
                case .failure(let error):
                    return .failure(error)
                }
            }

            cachedArchive = archive
            return .success(archive)
        }
    }

    // MARK: - Save

    @discardableResult
    func save(_ archive: WorkspaceArchive) -> Result<WorkspaceArchive, WorkspaceStoreError> {
        queue.sync {
            let result = saveUnsafe(archive)
            if case .success(let saved) = result {
                cachedArchive = saved
                lastLoadResult = .success(saved)
            }
            return result
        }
    }

    private func saveUnsafe(_ archive: WorkspaceArchive) -> Result<WorkspaceArchive, WorkspaceStoreError> {
        withFileLock {
            saveUnsafeUnlocked(archive)
        }
    }

    /// Writes while the caller already owns `withFileLock`.
    private func saveUnsafeUnlocked(_ archive: WorkspaceArchive) -> Result<WorkspaceArchive, WorkspaceStoreError> {
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

        // Atomic write via temporary file + rename
        let tmpURL = directory.appendingPathComponent(".workspaces.tmp-\(UUID().uuidString)")
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

    func upsertWorkspace(_ workspace: Workspace) -> Result<WorkspaceArchive, WorkspaceStoreError> {
        switch load() {
        case .success(var archive):
            var updated = workspace
            updated.updatedAt = ISO8601DateFormatter().string(from: Date())
            if let idx = archive.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                archive.workspaces[idx] = updated
            } else {
                archive.workspaces.append(updated)
            }
            return save(archive)
        case .failure(let error):
            return .failure(error)
        }
    }

    func deleteWorkspace(id: String) -> Result<WorkspaceArchive, WorkspaceStoreError> {
        switch load() {
        case .success(var archive):
            archive.workspaces.removeAll { $0.id == id }
            return save(archive)
        case .failure(let error):
            return .failure(error)
        }
    }

    func reorderWorkspaces(ids: [String]) -> Result<WorkspaceArchive, WorkspaceStoreError> {
        switch load() {
        case .success(var archive):
            var ordered: [Workspace] = []
            var remaining = Dictionary(uniqueKeysWithValues: archive.workspaces.map { ($0.id, $0) })
            for id in ids {
                if let ws = remaining.removeValue(forKey: id) {
                    var copy = ws
                    copy.sortOrder = ordered.count
                    ordered.append(copy)
                }
            }
            // Append any workspaces not in the new order
            for (_, ws) in remaining.sorted(by: { $0.value.sortOrder < $1.value.sortOrder }) {
                var copy = ws
                copy.sortOrder = ordered.count
                ordered.append(copy)
            }
            archive.workspaces = ordered
            return save(archive)
        case .failure(let error):
            return .failure(error)
        }
    }

    func addRepositoryIDs(_ ids: [String], to workspaceID: String) -> Result<WorkspaceArchive, WorkspaceStoreError> {
        switch load() {
        case .success(var archive):
            guard let idx = archive.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                return .failure(.writeFailed("workspace not found"))
            }
            var ws = archive.workspaces[idx]
            var current = Set(ws.repositoryIDs)
            for id in ids { current.insert(id) }
            ws.repositoryIDs = Array(current).sorted()
            ws.updatedAt = ISO8601DateFormatter().string(from: Date())
            archive.workspaces[idx] = ws
            return save(archive)
        case .failure(let error):
            return .failure(error)
        }
    }

    func removeRepositoryIDs(_ ids: [String], from workspaceID: String) -> Result<WorkspaceArchive, WorkspaceStoreError> {
        switch load() {
        case .success(var archive):
            guard let idx = archive.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                return .failure(.writeFailed("workspace not found"))
            }
            var ws = archive.workspaces[idx]
            ws.repositoryIDs.removeAll { ids.contains($0) }
            ws.updatedAt = ISO8601DateFormatter().string(from: Date())
            archive.workspaces[idx] = ws
            return save(archive)
        case .failure(let error):
            return .failure(error)
        }
    }

    func moveRepository(id: String, from sourceID: String?, to targetID: String?) -> Result<WorkspaceArchive, WorkspaceStoreError> {
        switch load() {
        case .success(var archive):
            if let sourceID, let idx = archive.workspaces.firstIndex(where: { $0.id == sourceID }) {
                archive.workspaces[idx].repositoryIDs.removeAll { $0 == id }
                archive.workspaces[idx].updatedAt = ISO8601DateFormatter().string(from: Date())
            }
            if let targetID, let idx = archive.workspaces.firstIndex(where: { $0.id == targetID }) {
                if !archive.workspaces[idx].repositoryIDs.contains(id) {
                    archive.workspaces[idx].repositoryIDs.append(id)
                    archive.workspaces[idx].updatedAt = ISO8601DateFormatter().string(from: Date())
                }
            }
            return save(archive)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Merge workspace `fromID` into `intoID`.
    func mergeWorkspaces(fromID: String, intoID: String) -> Result<WorkspaceArchive, WorkspaceStoreError> {
        switch load() {
        case .success(var archive):
            guard let fromIdx = archive.workspaces.firstIndex(where: { $0.id == fromID }),
                  let intoIdx = archive.workspaces.firstIndex(where: { $0.id == intoID }) else {
                return .failure(.writeFailed("one or both workspaces not found"))
            }
            let from = archive.workspaces[fromIdx]
            var into = archive.workspaces[intoIdx]
            let combined = Set(into.repositoryIDs + from.repositoryIDs)
            into.repositoryIDs = Array(combined).sorted()
            into.updatedAt = ISO8601DateFormatter().string(from: Date())
            archive.workspaces[intoIdx] = into
            archive.workspaces.remove(at: fromIdx)
            return save(archive)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Split a workspace into two by moving `repositoryIDs` into a new workspace.
    func splitWorkspace(
        sourceID: String,
        newName: String,
        moveRepositoryIDs: [String]
    ) -> Result<WorkspaceArchive, WorkspaceStoreError> {
        switch load() {
        case .success(var archive):
            guard let idx = archive.workspaces.firstIndex(where: { $0.id == sourceID }) else {
                return .failure(.writeFailed("source workspace not found"))
            }
            var source = archive.workspaces[idx]
            source.repositoryIDs.removeAll { moveRepositoryIDs.contains($0) }
            source.updatedAt = ISO8601DateFormatter().string(from: Date())
            archive.workspaces[idx] = source

            let newWorkspace = Workspace(
                name: newName,
                sortOrder: archive.workspaces.count,
                repositoryIDs: moveRepositoryIDs,
                groupingBasis: .manual
            )
            archive.workspaces.append(newWorkspace)
            return save(archive)
        case .failure(let error):
            return .failure(error)
        }
    }

    func addDismissedSuggestion(hash: String) -> Result<WorkspaceArchive, WorkspaceStoreError> {
        switch load() {
        case .success(var archive):
            archive.dismissedSuggestionHashes.insert(hash)
            return save(archive)
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Migration

    private func migrate(archive: WorkspaceArchive) -> WorkspaceArchive {
        var migrated = archive
        let record = WorkspaceMigrationRecord(
            fromVersion: archive.schemaVersion,
            toVersion: WorkspaceArchive.currentSchemaVersion,
            migratedAt: ISO8601DateFormatter().string(from: Date()),
            success: true,
            detail: "migrated from schema v\(archive.schemaVersion) to v\(WorkspaceArchive.currentSchemaVersion)"
        )
        migrated.schemaVersion = WorkspaceArchive.currentSchemaVersion
        migrated.migrationLog.append(record)
        return migrated
    }

    // MARK: - File lock

    private func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            // If lock fails, proceed without it (best-effort)
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

// MARK: - Identity resolver

/// Resolves repository identities across moves, renames, and re-clones.
/// Uses canonical path as the stable anchor.
enum WorkspaceIdentityResolver {
    /// Given a set of previously-known repository IDs and the current scan
    /// results, map old IDs to new IDs where possible.
    static func resolveIdentities(
        previousIDs: [String: String],  // oldID -> oldPath
        currentSnapshots: [RepositorySnapshot]
    ) -> [String: String] {  // oldID -> newID
        var pathToNewID: [String: String] = [:]
        for snap in currentSnapshots {
            let canonicalPath = RepositoryIdentity.canonicalPath(snap.path)
            pathToNewID[canonicalPath] = snap.id
        }

        var migrations: [String: String] = [:]
        for (oldID, oldPath) in previousIDs {
            let canonicalOld = RepositoryIdentity.canonicalPath(oldPath)
            // Direct path match
            if let newID = pathToNewID[canonicalOld] {
                migrations[oldID] = newID
                continue
            }
            // Repo was re-cloned at same path (path still exists but ID changed)
            if FileManager.default.fileExists(atPath: canonicalOld),
               let snap = currentSnapshots.first(where: {
                   RepositoryIdentity.canonicalPath($0.path) == canonicalOld
               }) {
                migrations[oldID] = snap.id
            }
        }

        return migrations
    }
}

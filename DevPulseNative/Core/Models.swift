import Foundation
import CryptoKit
import Darwin

// MARK: - Schema constants

enum RepositorySnapshotSchema {
    static let version = 1
}

/// Stable repository identity shared by the app, scheduler, and Widget.
///
/// The identity is deliberately based on a canonical filesystem path rather
/// than process-seeded hashing. The version prefix makes future
/// migrations explicit and keeps IDs from older algorithms distinguishable.
enum RepositoryIdentity {
    static let version = 1
    private static let prefix = "repo-v\(version)-"

    static func isSameOrDescendantPath(_ path: String, of prefix: String) -> Bool {
        let normalizedPrefix: String
        if prefix.count > 1, prefix.hasSuffix("/") {
            normalizedPrefix = String(prefix.dropLast())
        } else {
            normalizedPrefix = prefix
        }
        guard !normalizedPrefix.isEmpty else { return false }
        if normalizedPrefix == "/" {
            return path.hasPrefix("/")
        }
        return path == normalizedPrefix || path.hasPrefix(normalizedPrefix + "/")
    }

    static func canonicalPath(_ rawPath: String) -> String {
        let expanded: String
        if rawPath == "~" {
            expanded = resolvedUserHomeDirectory()
        } else if rawPath.hasPrefix("~/") {
            expanded = resolvedUserHomeDirectory() + String(rawPath.dropFirst(1))
        } else {
            expanded = rawPath
        }

        let home = resolvedUserHomeDirectory()
        let legacyContainerPrefix = home + "/Library/Containers/local.devpulse.app/Data"
        let sandboxHome = NSHomeDirectory()
        let migratedPath: String
        if isSameOrDescendantPath(expanded, of: legacyContainerPrefix) {
            migratedPath = home + String(expanded.dropFirst(legacyContainerPrefix.count))
        } else if sandboxHome != home, isSameOrDescendantPath(expanded, of: sandboxHome) {
            migratedPath = home + String(expanded.dropFirst(sandboxHome.count))
        } else {
            migratedPath = expanded
        }

        let standardized = URL(fileURLWithPath: migratedPath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: standardized) else {
            return standardized
        }
        return URL(fileURLWithPath: standardized)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func resolvedUserHomeDirectory() -> String {
        let candidates: [String?] = [
            passwdHomeDirectory(),
            ProcessInfo.processInfo.environment["HOME"],
            NSHomeDirectory()
        ]
        for candidate in candidates.compactMap({ $0 }) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("/Library/Containers/"),
                  !trimmed.contains("/Containers/local.devpulse.app/") else { continue }
            return trimmed
        }
        let username = NSUserName()
        return username.isEmpty ? "/Users" : "/Users/\(username)"
    }

    private static func passwdHomeDirectory() -> String? {
        let uid = getuid()
        guard let entry = getpwuid(uid), let home = entry.pointee.pw_dir else { return nil }
        return String(cString: home)
    }

    static func id(for rawPath: String) -> String {
        let path = canonicalPath(rawPath)
        let digest = SHA256.hash(data: Data(path.utf8))
        return prefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func normalize(_ snapshot: RepositorySnapshot) -> RepositorySnapshot {
        let path = canonicalPath(snapshot.path)
        return RepositorySnapshot(
            id: id(for: path),
            name: snapshot.name,
            path: path,
            branch: snapshot.branch,
            status: snapshot.status,
            modifiedFileCount: snapshot.modifiedFileCount,
            addedFileCount: snapshot.addedFileCount,
            deletedFileCount: snapshot.deletedFileCount,
            untrackedFileCount: snapshot.untrackedFileCount,
            stagedFileCount: snapshot.stagedFileCount,
            unstagedFileCount: snapshot.unstagedFileCount,
            conflictedFileCount: snapshot.conflictedFileCount,
            aheadCount: snapshot.aheadCount,
            behindCount: snapshot.behindCount,
            hasUpstream: snapshot.hasUpstream,
            changedFileCount: snapshot.changedFileCount,
            changedFilesPreview: snapshot.changedFilesPreview,
            risk: snapshot.risk,
            lastScannedAt: snapshot.lastScannedAt,
            dataSource: snapshot.resolvedDataSource,
            lastSuccessfulScanAt: snapshot.resolvedLastSuccessfulScanAt,
            lastChangedAt: snapshot.lastChangedAt,
            lastCommitID: snapshot.lastCommitID,
            lastCommitSummary: snapshot.lastCommitSummary,
            lastCommitMetadataAvailable: snapshot.lastCommitMetadataAvailable,
            lastActivityAt: snapshot.lastActivityAt,
            unavailableSince: snapshot.unavailableSince,
            errorMessage: snapshot.errorMessage,
            isPinned: snapshot.isPinned
        )
    }

    static func normalize(_ data: AppGroupData) -> AppGroupData {
        var byPath: [String: RepositorySnapshot] = [:]
        var normalizedIDsByLegacyID: [String: Set<String>] = [:]
        for repository in data.repositories {
            let normalized = normalize(repository)
            normalizedIDsByLegacyID[repository.id, default: []].insert(normalized.id)
            if let existing = byPath[normalized.path] {
                byPath[normalized.path] = mergeDuplicate(existing, normalized)
            } else {
                byPath[normalized.path] = normalized
            }
        }

        var repositories: [RepositorySnapshot] = []
        var seenPaths: Set<String> = []
        for repository in data.repositories {
            let path = canonicalPath(repository.path)
            guard seenPaths.insert(path).inserted, let normalized = byPath[path] else { continue }
            repositories.append(normalized)
        }

        let summary = ScanSummary.build(from: repositories)
        let repositoryIDs = Set(repositories.map(\.id))
        var unavailableSinceByPath: [String: String] = [:]
        for (rawPath, timestamp) in data.repositoryUnavailableSinceByPath ?? [:] {
            let path = canonicalPath(rawPath)
            guard !path.isEmpty else { continue }
            if let existing = unavailableSinceByPath[path],
               let existingDate = DateFormatting.date(from: existing),
               let candidateDate = DateFormatting.date(from: timestamp),
               existingDate <= candidateDate {
                continue
            }
            unavailableSinceByPath[path] = timestamp
        }
        let recentActivityEvents = data.recentActivityEvents?.compactMap { event -> ActivityEventSummary? in
            let normalizedID: String
            if repositoryIDs.contains(event.repositoryID) {
                normalizedID = event.repositoryID
            } else if let candidates = normalizedIDsByLegacyID[event.repositoryID],
                      candidates.count == 1,
                      let migratedID = candidates.first,
                      repositoryIDs.contains(migratedID) {
                normalizedID = migratedID
            } else {
                return nil
            }
            return event.remappingRepositoryID(to: normalizedID)
        }
        return AppGroupData(
            schemaVersion: data.schemaVersion,
            generatedAt: data.generatedAt,
            writtenAt: data.writtenAt,
            scanSummary: summary,
            repositories: repositories,
            recentActivityEvents: recentActivityEvents,
            repositoryUnavailableSinceByPath: unavailableSinceByPath.isEmpty ? nil : unavailableSinceByPath
        )
    }

    private static func mergeDuplicate(_ lhs: RepositorySnapshot,
                                       _ rhs: RepositorySnapshot) -> RepositorySnapshot {
        guard !lhs.isPinned || rhs.isPinned else { return lhs }
        return RepositorySnapshot(
            id: lhs.id,
            name: lhs.name,
            path: lhs.path,
            branch: lhs.branch,
            status: lhs.status,
            modifiedFileCount: lhs.modifiedFileCount,
            addedFileCount: lhs.addedFileCount,
            deletedFileCount: lhs.deletedFileCount,
            untrackedFileCount: lhs.untrackedFileCount,
            stagedFileCount: lhs.stagedFileCount,
            unstagedFileCount: lhs.unstagedFileCount,
            conflictedFileCount: lhs.conflictedFileCount,
            aheadCount: lhs.aheadCount,
            behindCount: lhs.behindCount,
            hasUpstream: lhs.hasUpstream,
            changedFileCount: lhs.changedFileCount,
            changedFilesPreview: lhs.changedFilesPreview,
            risk: lhs.risk,
            lastScannedAt: lhs.lastScannedAt,
            dataSource: lhs.resolvedDataSource,
            lastSuccessfulScanAt: lhs.resolvedLastSuccessfulScanAt,
            lastChangedAt: lhs.lastChangedAt,
            lastCommitID: lhs.lastCommitID,
            lastCommitSummary: lhs.lastCommitSummary,
            lastCommitMetadataAvailable: lhs.lastCommitMetadataAvailable,
            lastActivityAt: lhs.lastActivityAt,
            unavailableSince: lhs.unavailableSince,
            errorMessage: lhs.errorMessage,
            isPinned: true
        )
    }
}

struct RepositoryIdentityMigrationResult: Equatable {
    let snapshot: AppGroupData
    let pinnedIDs: Set<String>
    let repositoryIDMigrations: [String: String]
    let changed: Bool
}

enum RepositoryIdentityMigration {
    /// Normalize one persisted snapshot and safely translate pins that can be
    /// unambiguously mapped from legacy ID -> path relationships.
    static func migrate(snapshot: AppGroupData,
                        pinnedIDs: Set<String>) -> RepositoryIdentityMigrationResult {
        var pathsByLegacyID: [String: Set<String>] = [:]
        var pinsFromSnapshot: Set<String> = []
        for repository in snapshot.repositories {
            let path = RepositoryIdentity.canonicalPath(repository.path)
            pathsByLegacyID[repository.id, default: []].insert(path)
            if repository.isPinned {
                pinsFromSnapshot.insert(RepositoryIdentity.id(for: path))
            }
        }

        var migratedPins = pinsFromSnapshot
        var repositoryIDMigrations: [String: String] = [:]
        for (legacyID, paths) in pathsByLegacyID where paths.count == 1 {
            guard let path = paths.first else { continue }
            repositoryIDMigrations[legacyID] = RepositoryIdentity.id(for: path)
        }
        for pinnedID in pinnedIDs {
            guard let paths = pathsByLegacyID[pinnedID], paths.count == 1,
                  let path = paths.first else {
                // Preserve unknown or ambiguous values. They cannot safely be
                // attached to a new repository identity yet.
                migratedPins.insert(pinnedID)
                continue
            }
            migratedPins.insert(RepositoryIdentity.id(for: path))
        }

        let normalizedSnapshot = RepositoryIdentity.normalize(snapshot)
        let pinnedSnapshot = AppGroupData(
            schemaVersion: normalizedSnapshot.schemaVersion,
            generatedAt: normalizedSnapshot.generatedAt,
            writtenAt: normalizedSnapshot.writtenAt,
            scanSummary: normalizedSnapshot.scanSummary,
            repositories: normalizedSnapshot.repositories.map { repository in
                var copy = repository
                copy.isPinned = migratedPins.contains(repository.id)
                return copy
            },
            recentActivityEvents: normalizedSnapshot.recentActivityEvents,
            repositoryUnavailableSinceByPath: normalizedSnapshot.repositoryUnavailableSinceByPath
        )

        return RepositoryIdentityMigrationResult(
            snapshot: pinnedSnapshot,
            pinnedIDs: migratedPins,
            repositoryIDMigrations: repositoryIDMigrations,
            changed: pinnedSnapshot != snapshot || migratedPins != pinnedIDs
        )
    }
}

// MARK: - Repository scan scope

struct IgnoredRepository: Identifiable, Equatable {
    let path: String

    var id: String { RepositoryIdentity.id(for: path) }
    var name: String { (path as NSString).lastPathComponent }
    var displayPath: String { RepositoryPathPresentation.compactPath(path) }
}

struct IgnoredRepositoryArchive: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let paths: [String]

    init(version: Int = IgnoredRepositoryArchive.currentVersion, paths: [String]) {
        self.version = version
        self.paths = Self.normalizedPaths(paths)
    }

    init(from decoder: Decoder) throws {
        if let legacyPaths = try? decoder.singleValueContainer().decode([String].self) {
            self.init(paths: legacyPaths)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentVersion
        let paths = try container.decodeIfPresent([String].self, forKey: .paths)
            ?? container.decodeIfPresent([String].self, forKey: .ignoredRepositoryPaths)
            ?? []
        self.init(version: version, paths: paths)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(paths, forKey: .paths)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case schemaVersion
        case paths
        case ignoredRepositoryPaths
    }

    private static func normalizedPaths(_ paths: [String]) -> [String] {
        Array(Set(paths.map(RepositoryIdentity.canonicalPath).filter { !$0.isEmpty })).sorted()
    }
}

enum RepositoryPathPresentation {
    static func compactPath(_ rawPath: String) -> String {
        let path = RepositoryIdentity.canonicalPath(rawPath)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if RepositoryIdentity.isSameOrDescendantPath(path, of: home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

enum RepositoryScope {
    static func canonicalPathSet(_ paths: some Sequence<String>) -> Set<String> {
        Set(paths.map(RepositoryIdentity.canonicalPath).filter { !$0.isEmpty })
    }

    static func contains(_ path: String, in canonicalPaths: Set<String>) -> Bool {
        canonicalPaths.contains(RepositoryIdentity.canonicalPath(path))
    }

    static func filtering(_ data: AppGroupData, excluding ignoredPaths: Set<String>) -> AppGroupData {
        let canonicalIgnored = canonicalPathSet(ignoredPaths)
        guard !canonicalIgnored.isEmpty else { return RepositoryIdentity.normalize(data) }

        let repositories = data.repositories.filter {
            !contains($0.path, in: canonicalIgnored)
        }
        let unavailability = data.repositoryUnavailableSinceByPath?.filter {
            !contains($0.key, in: canonicalIgnored)
        }
        let repositoryIDs = Set(repositories.map { RepositoryIdentity.id(for: $0.path) })
        let filtered = AppGroupData(
            schemaVersion: data.schemaVersion,
            generatedAt: data.generatedAt,
            writtenAt: data.writtenAt,
            scanSummary: ScanSummary.build(from: repositories),
            repositories: repositories,
            recentActivityEvents: data.recentActivityEvents?.filter {
                repositoryIDs.contains($0.repositoryID)
            },
            repositoryUnavailableSinceByPath: unavailability
        )
        return RepositoryIdentity.normalize(filtered)
    }
}

enum SharedSnapshotLocation {
    static let appGroupIdentifier = "group.local.devpulse"
    static let fileName = "repositories.json"
}

enum WidgetIdentity {
    static let kind = "DevPulseWidget"
}

// MARK: - Risk level

enum RiskLevel: String, Codable, Comparable {
    case low = "low"
    case medium = "medium"
    case high = "high"

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        let order: [RiskLevel] = [.low, .medium, .high]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - Repository status

enum RepositoryStatus: String, Codable {
    case clean = "clean"
    case changed = "changed"
    case error = "error"
}

/// Describes whether repository values came from the latest scan attempt.
///
/// The persisted property is optional on `RepositorySnapshot` so schema-v1
/// snapshots written before provenance was introduced remain decodable.
enum RepositoryDataSource: String, Codable, Equatable {
    case current
    case lastSuccessful
    case unknown
}

enum RepositoryDataAvailability {
    static func allUnavailable(_ repositories: [RepositorySnapshot]) -> Bool {
        !repositories.isEmpty
            && !repositories.contains { $0.resolvedDataSource == .current }
    }
}

// MARK: - Repository snapshot

struct RepositoryChangeCounts: Codable, Equatable {
    let modified: Int
    let added: Int
    let deleted: Int
    let untracked: Int
    let staged: Int
    let unstaged: Int
    let conflicted: Int

    var total: Int {
        modified + added + deleted + untracked
    }
}

struct RepositorySnapshot: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let branch: String
    let status: RepositoryStatus
    let modifiedFileCount: Int
    let addedFileCount: Int
    let deletedFileCount: Int
    let untrackedFileCount: Int
    let stagedFileCount: Int?
    let unstagedFileCount: Int?
    let conflictedFileCount: Int?
    let aheadCount: Int?
    let behindCount: Int?
    let hasUpstream: Bool?
    let changedFileCount: Int
    let changedFilesPreview: [String]
    let risk: RiskLevel
    let lastScannedAt: String
    let dataSource: RepositoryDataSource?
    let lastSuccessfulScanAt: String?
    let lastChangedAt: String?
    let lastCommitID: String?
    let lastCommitSummary: String?
    let lastCommitMetadataAvailable: Bool?
    var lastActivityAt: String?
    let unavailableSince: String?
    let errorMessage: String?
    var isPinned: Bool

    init(id: String,
         name: String,
         path: String,
         branch: String,
         status: RepositoryStatus,
         modifiedFileCount: Int,
         addedFileCount: Int,
         deletedFileCount: Int,
         untrackedFileCount: Int,
         stagedFileCount: Int?,
         unstagedFileCount: Int?,
         conflictedFileCount: Int?,
         aheadCount: Int?,
         behindCount: Int? = nil,
         hasUpstream: Bool? = nil,
         changedFileCount: Int,
         changedFilesPreview: [String],
         risk: RiskLevel,
         lastScannedAt: String,
         dataSource: RepositoryDataSource? = nil,
         lastSuccessfulScanAt: String? = nil,
         lastChangedAt: String?,
         lastCommitID: String? = nil,
         lastCommitSummary: String? = nil,
         lastCommitMetadataAvailable: Bool? = nil,
         lastActivityAt: String? = nil,
         unavailableSince: String? = nil,
         errorMessage: String?,
         isPinned: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.branch = branch
        self.status = status
        self.modifiedFileCount = modifiedFileCount
        self.addedFileCount = addedFileCount
        self.deletedFileCount = deletedFileCount
        self.untrackedFileCount = untrackedFileCount
        self.stagedFileCount = stagedFileCount
        self.unstagedFileCount = unstagedFileCount
        self.conflictedFileCount = conflictedFileCount
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.hasUpstream = hasUpstream
        self.changedFileCount = changedFileCount
        self.changedFilesPreview = changedFilesPreview
        self.risk = risk
        self.lastScannedAt = lastScannedAt
        let resolvedDataSource = dataSource
            ?? ((status == .error || errorMessage != nil) ? .unknown : .current)
        self.dataSource = resolvedDataSource
        self.lastSuccessfulScanAt = lastSuccessfulScanAt
            ?? (resolvedDataSource == .current ? lastScannedAt : nil)
        self.lastChangedAt = lastChangedAt
        self.lastCommitID = lastCommitID
        self.lastCommitSummary = lastCommitSummary
        self.lastCommitMetadataAvailable = lastCommitMetadataAvailable
        self.lastActivityAt = lastActivityAt
        self.unavailableSince = unavailableSince
        self.errorMessage = errorMessage
        self.isPinned = isPinned
    }

    static func == (lhs: RepositorySnapshot, rhs: RepositorySnapshot) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.path == rhs.path
            && lhs.branch == rhs.branch
            && lhs.status == rhs.status
            && lhs.modifiedFileCount == rhs.modifiedFileCount
            && lhs.addedFileCount == rhs.addedFileCount
            && lhs.deletedFileCount == rhs.deletedFileCount
            && lhs.untrackedFileCount == rhs.untrackedFileCount
            && lhs.stagedFileCount == rhs.stagedFileCount
            && lhs.unstagedFileCount == rhs.unstagedFileCount
            && lhs.conflictedFileCount == rhs.conflictedFileCount
            && lhs.aheadCount == rhs.aheadCount
            && lhs.behindCount == rhs.behindCount
            && lhs.hasUpstream == rhs.hasUpstream
            && lhs.changedFileCount == rhs.changedFileCount
            && lhs.changedFilesPreview == rhs.changedFilesPreview
            && lhs.risk == rhs.risk
            && lhs.lastScannedAt == rhs.lastScannedAt
            && lhs.dataSource == rhs.dataSource
            && lhs.lastSuccessfulScanAt == rhs.lastSuccessfulScanAt
            && lhs.lastChangedAt == rhs.lastChangedAt
            && lhs.lastCommitID == rhs.lastCommitID
            && lhs.lastCommitSummary == rhs.lastCommitSummary
            && lhs.lastCommitMetadataAvailable == rhs.lastCommitMetadataAvailable
            && lhs.lastActivityAt == rhs.lastActivityAt
            && lhs.unavailableSince == rhs.unavailableSince
            && lhs.errorMessage == rhs.errorMessage
            && lhs.isPinned == rhs.isPinned
    }

    var changeCounts: RepositoryChangeCounts {
        RepositoryChangeCounts(
            modified: modifiedFileCount,
            added: addedFileCount,
            deleted: deletedFileCount,
            untracked: untrackedFileCount,
            staged: stagedFileCount ?? 0,
            unstaged: unstagedFileCount ?? (modifiedFileCount + addedFileCount + deletedFileCount),
            conflicted: conflictedFileCount ?? 0
        )
    }

    var commitReadiness: CommitReadinessAssessment {
        CommitReadinessEngine.assess(snapshot: self)
    }

    var nextActionHint: String {
        RepositoryNextActionHintBuilder.build(snapshot: self)
    }

    var statusSummary: String {
        RepositoryStatusSummaryBuilder.build(snapshot: self)
    }

    var actionState: RepositoryActionState {
        RepositoryActionStateBuilder.build(snapshot: self)
    }

    /// Effective provenance for legacy and current schema-v1 payloads.
    /// Legacy successful snapshots did not persist provenance, so a non-error
    /// value is treated as current at the time that snapshot was generated.
    /// Legacy error snapshots remain unknown because their retained fields
    /// cannot be proven to have come from a successful scan.
    var resolvedDataSource: RepositoryDataSource {
        if let dataSource {
            return dataSource
        }
        return status == .error || errorMessage != nil ? .unknown : .current
    }

    var resolvedLastSuccessfulScanAt: String? {
        if let lastSuccessfulScanAt {
            return lastSuccessfulScanAt
        }
        guard dataSource == nil,
              status != .error,
              errorMessage == nil else {
            return nil
        }
        return lastScannedAt
    }

    var dataSourcePresentation: RepositoryDataSourcePresentation {
        RepositoryDataSourcePresentationBuilder.build(snapshot: self)
    }

    var branchDisplayLabel: String {
        RepositoryBranchPresentationBuilder.build(
            branch: branch,
            source: resolvedDataSource
        )
    }

    /// Preserve payload values after a failed attempt while making it
    /// impossible for consumers to treat them as current observations.
    func retainingLastSuccessfulData(
        attemptedAt: String,
        errorMessage: String,
        unavailableSince fallbackUnavailableSince: String? = nil
    ) -> RepositorySnapshot {
        let successfulAt = resolvedLastSuccessfulScanAt
        let retainedSource: RepositoryDataSource = successfulAt == nil
            ? .unknown
            : .lastSuccessful

        return RepositorySnapshot(
            id: id,
            name: name,
            path: path,
            branch: branch,
            status: .error,
            modifiedFileCount: modifiedFileCount,
            addedFileCount: addedFileCount,
            deletedFileCount: deletedFileCount,
            untrackedFileCount: untrackedFileCount,
            stagedFileCount: stagedFileCount,
            unstagedFileCount: unstagedFileCount,
            conflictedFileCount: conflictedFileCount,
            aheadCount: aheadCount,
            behindCount: behindCount,
            hasUpstream: hasUpstream,
            changedFileCount: changedFileCount,
            changedFilesPreview: changedFilesPreview,
            risk: risk,
            lastScannedAt: attemptedAt,
            dataSource: retainedSource,
            lastSuccessfulScanAt: successfulAt,
            lastChangedAt: lastChangedAt,
            lastCommitID: lastCommitID,
            lastCommitSummary: lastCommitSummary,
            lastCommitMetadataAvailable: false,
            lastActivityAt: lastActivityAt,
            unavailableSince: unavailableSince ?? fallbackUnavailableSince ?? attemptedAt,
            errorMessage: errorMessage,
            isPinned: isPinned
        )
    }
}

enum RepositoryRetentionPolicy {
    /// Keep a temporarily unreadable repository long enough to survive normal
    /// permission and sleep/wake interruptions, but never retain it forever.
    static let unavailableRetentionInterval: TimeInterval = 7 * 24 * 60 * 60

    static func shouldRetain(_ snapshot: RepositorySnapshot, now: Date = Date()) -> Bool {
        guard snapshot.resolvedDataSource != .current || snapshot.status == .error else {
            return true
        }

        let unavailableAt = snapshot.unavailableSince
            .flatMap(DateFormatting.date(from:))
            ?? DateFormatting.date(from: snapshot.lastScannedAt)
        guard let unavailableAt else { return false }
        return now.timeIntervalSince(unavailableAt) <= unavailableRetentionInterval
    }
}

struct RepositoryDataSourcePresentation: Equatable {
    let source: RepositoryDataSource
    let label: String
    let detail: String
}

enum RepositoryDataSourcePresentationBuilder {
    static func build(
        snapshot: RepositorySnapshot,
        now: Date = Date()
    ) -> RepositoryDataSourcePresentation {
        build(
            source: snapshot.resolvedDataSource,
            lastSuccessfulScanAt: snapshot.resolvedLastSuccessfulScanAt,
            lastAttemptedScanAt: snapshot.lastScannedAt,
            now: now
        )
    }

    static func build(
        source: RepositoryDataSource,
        lastSuccessfulScanAt: String?,
        lastAttemptedScanAt: String?,
        now: Date = Date()
    ) -> RepositoryDataSourcePresentation {
        switch source {
        case .current:
            return RepositoryDataSourcePresentation(
                source: .current,
                label: "当前数据",
                detail: "本轮扫描成功"
            )
        case .lastSuccessful:
            let relativeTime = lastSuccessfulScanAt.flatMap {
                DateFormatting.relativeTimeChinese(from: $0, relativeTo: now)
            } ?? "时间未知"
            return RepositoryDataSourcePresentation(
                source: .lastSuccessful,
                label: "上次成功",
                detail: "上次成功 · \(relativeTime)"
            )
        case .unknown:
            let relativeAttempt = lastAttemptedScanAt.flatMap {
                DateFormatting.relativeTimeChinese(from: $0, relativeTo: now)
            }
            return RepositoryDataSourcePresentation(
                source: .unknown,
                label: "数据未知",
                detail: relativeAttempt.map { "读取失败 · \($0)" }
                    ?? "当前读取失败，无可用成功数据"
            )
        }
    }
}

enum RepositoryBranchPresentationBuilder {
    static func build(branch: String, source: RepositoryDataSource) -> String {
        let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchIsKnown = !normalizedBranch.isEmpty
            && normalizedBranch.lowercased() != "unknown"

        guard source != .unknown, branchIsKnown else {
            return "分支未知"
        }

        return source == .lastSuccessful
            ? "上次 · \(normalizedBranch)"
            : normalizedBranch
    }
}

enum RepositoryActionKind: Equatable {
    case diagnoseReadFailure
    case refreshRepositoryState
    case resolveConflicts
    case confirmBranch
    case synchronizeDivergedBranch
    case pushLocalCommits
    case commitStagedChanges
    case reviewLocalChanges
    case pullRemoteUpdates
    case noActionNeeded
}

struct RepositoryActionState: Equatable {
    let kind: RepositoryActionKind
    let title: String
    let sortPriority: Int
}

enum RepositoryActionStateBuilder {
    static func build(snapshot: RepositorySnapshot) -> RepositoryActionState {
        switch snapshot.resolvedDataSource {
        case .lastSuccessful:
            return action(.refreshRepositoryState, title: "先刷新确认状态", priority: 0)
        case .unknown:
            return action(.diagnoseReadFailure, title: "检查读取异常", priority: 0)
        case .current:
            break
        }

        if snapshot.status == .error || snapshot.errorMessage != nil {
            return action(.diagnoseReadFailure, title: "检查读取异常", priority: 0)
        }

        if (snapshot.conflictedFileCount ?? 0) > 0 {
            return action(.resolveConflicts, title: "先解决合并冲突", priority: 1)
        }

        let normalizedBranch = snapshot.branch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedBranch.isEmpty || normalizedBranch == "unknown" || normalizedBranch == "detached" {
            return action(.confirmBranch, title: "确认当前分支", priority: 2)
        }

        let aheadCount = snapshot.aheadCount ?? 0
        let behindCount = snapshot.behindCount ?? 0
        if aheadCount > 0, behindCount > 0 {
            return action(.synchronizeDivergedBranch, title: "同步分叉分支", priority: 3)
        }

        if aheadCount > 0 {
            return action(
                .pushLocalCommits,
                title: "推送 \(aheadCount) 个本地提交",
                priority: 4
            )
        }

        if snapshot.changedFileCount > 0 {
            let stagedCount = snapshot.stagedFileCount ?? 0
            let looseCount = (snapshot.unstagedFileCount ?? 0) + snapshot.untrackedFileCount
            if stagedCount > 0, looseCount == 0 {
                return action(
                    .commitStagedChanges,
                    title: "提交 \(stagedCount) 个已暂存改动",
                    priority: 5
                )
            }

            return action(
                .reviewLocalChanges,
                title: "检查 \(snapshot.changedFileCount) 个本地改动",
                priority: 5
            )
        }

        if behindCount > 0 {
            return action(
                .pullRemoteUpdates,
                title: "拉取 \(behindCount) 个远端更新",
                priority: 6
            )
        }

        return action(.noActionNeeded, title: "无需处理", priority: 7)
    }

    private static func action(_ kind: RepositoryActionKind,
                               title: String,
                               priority: Int) -> RepositoryActionState {
        RepositoryActionState(kind: kind, title: title, sortPriority: priority)
    }
}

struct RepositoryListItemPresentation: Equatable {
    let dataSource: RepositoryDataSourcePresentation
    let action: RepositoryActionState
    let latestCommit: String
    let localChanges: String
    let synchronization: String
    let recentActivity: String
}

enum RepositoryListItemPresentationBuilder {
    static func build(snapshot: RepositorySnapshot, now: Date = Date()) -> RepositoryListItemPresentation {
        RepositoryListItemPresentation(
            dataSource: RepositoryDataSourcePresentationBuilder.build(snapshot: snapshot, now: now),
            action: snapshot.actionState,
            latestCommit: latestCommitLabel(snapshot: snapshot, now: now),
            localChanges: localChangesLabel(snapshot: snapshot),
            synchronization: synchronizationLabel(snapshot: snapshot),
            recentActivity: recentActivityLabel(snapshot: snapshot, now: now)
        )
    }

    private static func latestCommitLabel(snapshot: RepositorySnapshot, now: Date) -> String {
        let time = relativeTime(snapshot.lastChangedAt, now: now)
        let summary = snapshot.lastCommitSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        if snapshot.resolvedDataSource == .unknown {
            return "提交信息未知"
        }

        if snapshot.lastCommitMetadataAvailable == false {
            guard time != nil || summary != nil else { return "上次成功提交未知" }
            return "上次成功提交 · \(time ?? "时间未知") · \(summary ?? "摘要不可用")"
        }

        if snapshot.resolvedDataSource == .lastSuccessful {
            guard time != nil || summary != nil else { return "上次成功提交未知" }
            return "上次成功提交 · \(time ?? "时间未知") · \(summary ?? "摘要不可用")"
        }

        if time == nil, summary == nil {
            if snapshot.status == .error {
                return "提交信息暂不可用"
            }
            return snapshot.lastCommitMetadataAvailable == true
                ? "暂无提交记录"
                : "提交信息待刷新"
        }

        return "\(time ?? "时间未知") · \(summary ?? "摘要不可用")"
    }

    private static func localChangesLabel(snapshot: RepositorySnapshot) -> String {
        switch snapshot.resolvedDataSource {
        case .unknown:
            return "本地改动未知"
        case .lastSuccessful:
            return "上次成功 · \(snapshot.changedFileCount) 个文件"
        case .current:
            guard snapshot.status != .error else { return "本地改动未知" }
            return "\(snapshot.changedFileCount) 个文件"
        }
    }

    private static func synchronizationLabel(snapshot: RepositorySnapshot) -> String {
        switch snapshot.resolvedDataSource {
        case .unknown:
            return "同步状态未知"
        case .lastSuccessful:
            return "上次成功 · \(currentSynchronizationLabel(snapshot: snapshot))"
        case .current:
            guard snapshot.status != .error else { return "同步状态未知" }
            return currentSynchronizationLabel(snapshot: snapshot)
        }
    }

    private static func currentSynchronizationLabel(snapshot: RepositorySnapshot) -> String {
        if snapshot.hasUpstream == false {
            return "未关联上游"
        }

        if snapshot.hasUpstream == true,
           let aheadCount = snapshot.aheadCount,
           let behindCount = snapshot.behindCount {
            return "领先 \(aheadCount) · 落后 \(behindCount)"
        }

        if let aheadCount = snapshot.aheadCount,
           let behindCount = snapshot.behindCount {
            return "领先 \(aheadCount) · 落后 \(behindCount)"
        }

        return "同步状态待刷新"
    }

    private static func recentActivityLabel(snapshot: RepositorySnapshot, now: Date) -> String {
        if snapshot.resolvedDataSource == .unknown {
            return "当前活动未知"
        }
        let timestamp = snapshot.lastActivityAt ?? snapshot.lastChangedAt
        guard let timestamp else { return "暂无活动记录" }
        let label = relativeTime(timestamp, now: now) ?? "时间未知"
        return snapshot.resolvedDataSource == .lastSuccessful
            ? "上次活动 · \(label)"
            : label
    }

    private static func relativeTime(_ timestamp: String?, now: Date) -> String? {
        guard let timestamp else { return nil }
        return DateFormatting.relativeTimeChinese(from: timestamp, relativeTo: now)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum RepositoryNextActionHintBuilder {
    static func build(snapshot: RepositorySnapshot) -> String {
        switch snapshot.resolvedDataSource {
        case .lastSuccessful:
            return "先重新扫描确认当前状态；不要依据上次成功数据提交、push 或同步。"
        case .unknown:
            return "先看 Diagnostics 并重新扫描；当前没有可用于提交、push 或同步的可信数据。"
        case .current:
            break
        }

        let readiness = snapshot.commitReadiness

        if snapshot.status == .error || readiness.level == .unknown {
            return "先看 Diagnostics，确认 Git 读取失败原因。"
        }

        if readiness.reasons.contains(.conflictedFiles) {
            return "先解决 \(countLabel(snapshot.conflictedFileCount ?? 0, unit: "处冲突"))，再继续审查或提交。"
        }

        if readiness.reasons.contains(.branchNeedsConfirmation) {
            return "先确认当前分支，再决定是否继续审查或提交。"
        }

        let aheadCount = snapshot.aheadCount ?? 0
        let behindCount = snapshot.behindCount ?? 0
        if aheadCount > 0, behindCount > 0 {
            return "本地和远端都有新提交，先确认分叉范围再同步。"
        }

        if behindCount > 0 {
            return "先拉取 \(countLabel(behindCount, unit: "个远端更新"))，再继续本地工作。"
        }

        if readiness.reasons.contains(.localAhead),
           aheadCount > 0 {
            return "确认准备好后 push \(countLabel(aheadCount, unit: "个本地提交"))。"
        }

        if readiness.reasons.contains(.stagedChanges) {
            return "确认 \(countLabel(snapshot.stagedFileCount ?? 0, unit: "个已暂存改动"))后即可提交。"
        }

        if readiness.reasons.contains(.mixedStagedAndUnstagedChanges) {
            return "先拆清已暂存和未暂存改动，再决定是否提交。"
        }

        if readiness.reasons.contains(.highRiskChanges), readiness.level == .dirty {
            return "先收敛 \(countLabel(snapshot.changedFileCount, unit: "处高风险改动"))，并跑一次验证。"
        }

        if readiness.reasons.contains(.largeWorkingTree) {
            let targetCount = max(snapshot.changedFileCount, snapshot.untrackedFileCount + (snapshot.unstagedFileCount ?? 0))
            return "先收敛 \(countLabel(targetCount, unit: "处改动"))，再继续审查或提交。"
        }

        if readiness.reasons.contains(.deletedFiles), snapshot.deletedFileCount > 0 {
            return "先检查 \(countLabel(snapshot.deletedFileCount, unit: "个删除项"))，再决定是否提交。"
        }

        if readiness.reasons.contains(.untrackedFiles), snapshot.untrackedFileCount > 0 {
            return "先确认 \(countLabel(snapshot.untrackedFileCount, unit: "个新文件"))是否纳入提交。"
        }

        if readiness.reasons.contains(.highRiskChanges) || snapshot.risk == .medium || snapshot.risk == .high {
            return "先看 diff 并跑一次验证，再决定是否提交。"
        }

        switch readiness.level {
        case .idle:
            return "当前无需操作。"
        case .ready:
            return "如范围确认无误，可以继续提交或分享改动。"
        case .review:
            if snapshot.changedFileCount > 0 {
                return "先看 \(countLabel(snapshot.changedFileCount, unit: "处改动"))的 diff，再决定是否提交。"
            }
            return "先审查当前改动，再决定是否提交。"
        case .dirty:
            return "先整理当前改动，再继续审查或提交。"
        case .unknown:
            return "先看 Diagnostics，确认 Git 读取失败原因。"
        }
    }

    private static func countLabel(_ count: Int, unit: String) -> String {
        "\(max(count, 1)) \(unit)"
    }
}

enum RepositoryStatusSummaryBuilder {
    static func build(snapshot: RepositorySnapshot) -> String {
        switch snapshot.resolvedDataSource {
        case .lastSuccessful:
            return "当前状态待确认 · 显示上次成功数据"
        case .unknown:
            return "仓库数据未知"
        case .current:
            break
        }

        if snapshot.status == .error || snapshot.commitReadiness.level == .unknown {
            return snapshot.errorMessage ?? "Git 状态不可用"
        }

        if snapshot.changedFileCount == 0,
           let aheadCount = snapshot.aheadCount,
           aheadCount > 0 {
            return aheadCount == 1 ? "领先 1 个本地提交" : "领先 \(aheadCount) 个本地提交"
        }

        if snapshot.commitReadiness.level == .idle {
            return "没有本地改动"
        }

        var parts: [String] = []
        parts.append(snapshot.changedFileCount == 1 ? "1 处改动" : "\(snapshot.changedFileCount) 处改动")

        let stagedCount = snapshot.stagedFileCount ?? 0
        if stagedCount > 0 {
            parts.append("已暂存 \(stagedCount)")
        }

        let unstagedCount = snapshot.unstagedFileCount
            ?? (snapshot.modifiedFileCount + snapshot.addedFileCount + snapshot.deletedFileCount)
        if unstagedCount > 0 {
            parts.append("未暂存 \(unstagedCount)")
        }

        if snapshot.untrackedFileCount > 0 {
            parts.append("未跟踪 \(snapshot.untrackedFileCount)")
        }

        return parts.joined(separator: " · ")
    }
}

// MARK: - Activity timeline

enum ActivityTimelineState: String, Codable, Equatable {
    case neverScanned
    case noRepositories
    case allClean
    case active
}

struct ActivityTimelineFeed: Codable, Equatable {
    let state: ActivityTimelineState
    let items: [ActivityTimelineItem]

    var topItem: ActivityTimelineItem? {
        items.first
    }

    var hasItems: Bool {
        !items.isEmpty
    }
}

struct WidgetPrioritySummary: Equatable {
    let title: String
    let message: String
    let readinessLevel: CommitReadinessLevel?
    let auxiliary: String?
}

struct ActivityTimelineItem: Codable, Identifiable, Equatable {
    let id: String
    let repoName: String
    let repoPath: String
    let branch: String
    let status: RepositoryStatus
    let risk: RiskLevel
    let modifiedFileCount: Int
    let addedFileCount: Int
    let deletedFileCount: Int
    let untrackedFileCount: Int
    let stagedFileCount: Int
    let unstagedFileCount: Int
    let conflictedFileCount: Int
    let aheadCount: Int
    let changedFileCount: Int
    let changedFilesPreview: [String]
    let lastChangedAt: String?
    let lastScannedAt: String
    let dataSource: RepositoryDataSource?
    let lastSuccessfulScanAt: String?
    let lastActivityAt: String?
    let errorMessage: String?

    init(from snapshot: RepositorySnapshot) {
        id = snapshot.id
        repoName = snapshot.name
        repoPath = snapshot.path
        branch = snapshot.branch
        status = snapshot.status
        risk = snapshot.risk
        modifiedFileCount = snapshot.modifiedFileCount
        addedFileCount = snapshot.addedFileCount
        deletedFileCount = snapshot.deletedFileCount
        untrackedFileCount = snapshot.untrackedFileCount
        stagedFileCount = snapshot.stagedFileCount ?? 0
        unstagedFileCount = snapshot.unstagedFileCount ?? (snapshot.modifiedFileCount + snapshot.addedFileCount + snapshot.deletedFileCount)
        conflictedFileCount = snapshot.conflictedFileCount ?? 0
        aheadCount = snapshot.aheadCount ?? 0
        changedFileCount = snapshot.changedFileCount
        changedFilesPreview = ActivityTimelineItem.previewBasenames(from: snapshot.changedFilesPreview)
        lastChangedAt = snapshot.lastChangedAt
        lastScannedAt = snapshot.lastScannedAt
        dataSource = snapshot.resolvedDataSource
        lastSuccessfulScanAt = snapshot.resolvedLastSuccessfulScanAt
        lastActivityAt = snapshot.lastActivityAt
        errorMessage = snapshot.errorMessage
    }

    var resolvedDataSource: RepositoryDataSource {
        if let dataSource {
            return dataSource
        }
        return status == .error || errorMessage != nil ? .unknown : .current
    }

    var resolvedLastSuccessfulScanAt: String? {
        if let lastSuccessfulScanAt {
            return lastSuccessfulScanAt
        }
        guard dataSource == nil,
              status != .error,
              errorMessage == nil else {
            return nil
        }
        return lastScannedAt
    }

    var dataSourcePresentation: RepositoryDataSourcePresentation {
        RepositoryDataSourcePresentationBuilder.build(
            source: resolvedDataSource,
            lastSuccessfulScanAt: resolvedLastSuccessfulScanAt,
            lastAttemptedScanAt: lastScannedAt
        )
    }

    var branchDisplayLabel: String {
        RepositoryBranchPresentationBuilder.build(
            branch: branch,
            source: resolvedDataSource
        )
    }

    var activityDate: Date? {
        let candidates: [String?]
        switch resolvedDataSource {
        case .current:
            candidates = [lastActivityAt, lastChangedAt, lastScannedAt]
        case .lastSuccessful:
            candidates = [resolvedLastSuccessfulScanAt, lastActivityAt, lastChangedAt]
        case .unknown:
            candidates = [lastScannedAt]
        }
        for candidate in candidates.compactMap({ $0 }) {
            if let date = DateFormatting.date(from: candidate) {
                return date
            }
        }
        return nil
    }

    var commitReadiness: CommitReadinessAssessment {
        CommitReadinessEngine.assess(
            status: status,
            branch: branch,
            risk: risk,
            modifiedFileCount: modifiedFileCount,
            addedFileCount: addedFileCount,
            deletedFileCount: deletedFileCount,
            untrackedFileCount: untrackedFileCount,
            stagedFileCount: stagedFileCount,
            unstagedFileCount: unstagedFileCount,
            conflictedFileCount: conflictedFileCount,
            aheadCount: aheadCount,
            scanError: status == .error,
            dataSource: resolvedDataSource
        )
    }

    private static func previewBasenames(from preview: [String]) -> [String] {
        var seen = Set<String>()
        var basenames: [String] = []

        for path in preview {
            let basename = (path as NSString).lastPathComponent
            guard !basename.isEmpty else { continue }
            if seen.insert(basename).inserted {
                basenames.append(basename)
            }
            if basenames.count == 3 {
                break
            }
        }

        return basenames
    }
}

enum ActivityTimelineBuilder {
    static func build(from repositories: [RepositorySnapshot],
                      lastScanAt: Date?) -> ActivityTimelineFeed {
        let items = repositories
            .map(ActivityTimelineItem.init(from:))
            .sorted(by: sort(_:_:))

        return ActivityTimelineFeed(
            state: classify(repositories: repositories, lastScanAt: lastScanAt),
            items: items
        )
    }

    static func build(from snapshot: AppGroupData, lastScanAt: Date? = nil) -> ActivityTimelineFeed {
        let fallbackLastScanAt = lastScanAt ?? DateFormatting.date(from: snapshot.writtenAt ?? snapshot.generatedAt)
        return build(from: snapshot.repositories, lastScanAt: fallbackLastScanAt)
    }

    private static func classify(repositories: [RepositorySnapshot],
                                 lastScanAt: Date?) -> ActivityTimelineState {
        guard !repositories.isEmpty else {
            return lastScanAt == nil ? .neverScanned : .noRepositories
        }

        let hasChanged = repositories.contains {
            $0.resolvedDataSource == .current && $0.status == .changed
        }
        let hasUnavailableData = repositories.contains {
            $0.resolvedDataSource != .current || $0.status == .error
        }

        if !hasChanged && !hasUnavailableData {
            return .allClean
        }

        return .active
    }

    private static func sort(_ lhs: ActivityTimelineItem,
                             _ rhs: ActivityTimelineItem) -> Bool {
        let lhsPriority = itemPriority(lhs)
        let rhsPriority = itemPriority(rhs)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        if let lhsDate = lhs.activityDate, let rhsDate = rhs.activityDate, lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        if lhs.activityDate != nil {
            return true
        }

        if rhs.activityDate != nil {
            return false
        }

        if lhs.resolvedDataSource == .current,
           rhs.resolvedDataSource == .current,
           lhs.changedFileCount != rhs.changedFileCount {
            return lhs.changedFileCount > rhs.changedFileCount
        }

        if lhs.resolvedDataSource == .current,
           rhs.resolvedDataSource == .current,
           lhs.risk != rhs.risk {
            return lhs.risk > rhs.risk
        }

        return lhs.repoName.localizedStandardCompare(rhs.repoName) == .orderedAscending
    }

    private static func itemPriority(_ item: ActivityTimelineItem) -> Int {
        switch item.resolvedDataSource {
        case .unknown:
            return 0
        case .lastSuccessful:
            return 1
        case .current:
            switch item.status {
            case .error:
                return 0
            case .changed:
                return 2
            case .clean:
                return 3
            }
        }
    }
}

enum WidgetPrioritySummaryBuilder {
    static func build(feed: ActivityTimelineFeed,
                      trustAssessment: SnapshotTrustAssessment?) -> WidgetPrioritySummary {
        if trustAssessment == nil, feed.state == .neverScanned {
            return WidgetPrioritySummary(
                title: WidgetRefreshCopy.waitingFirstRefreshTitle,
                message: "打开 DevPulse 执行一次刷新",
                readinessLevel: nil,
                auxiliary: nil
            )
        }

        switch trustAssessment?.state {
        case .stale, .expired:
            return WidgetPrioritySummary(
                title: WidgetRefreshCopy.waitingRefreshTitle,
                message: WidgetRefreshCopy.waitingRefreshSummary,
                readinessLevel: nil,
                auxiliary: nil
            )
        case .unknown, .failed, .none:
            return WidgetPrioritySummary(
                title: WidgetRefreshCopy.pendingConfirmationTitle,
                message: WidgetRefreshCopy.pendingConfirmationSummary,
                readinessLevel: nil,
                auxiliary: nil
            )
        case .fresh:
            break
        }

        switch feed.state {
        case .neverScanned:
            return WidgetPrioritySummary(
                title: WidgetRefreshCopy.waitingFirstRefreshTitle,
                message: "打开 DevPulse 执行一次刷新",
                readinessLevel: nil,
                auxiliary: nil
            )
        case .noRepositories:
            return WidgetPrioritySummary(
                title: "没有找到仓库",
                message: "检查扫描目录后重新刷新",
                readinessLevel: nil,
                auxiliary: nil
            )
        case .allClean:
            return WidgetPrioritySummary(
                title: "全部干净",
                message: "暂无改动",
                readinessLevel: .idle,
                auxiliary: feed.items.count == 1 ? "1 个仓库" : "\(feed.items.count) 个仓库"
            )
        case .active:
            guard let item = feed.topItem else {
                return WidgetPrioritySummary(
                    title: "打开 DevPulse",
                    message: "查看当前仓库状态",
                    readinessLevel: nil,
                    auxiliary: nil
                )
            }

            return WidgetPrioritySummary(
                title: item.repoName,
                message: item.commitReadiness.widgetShortHint,
                readinessLevel: item.commitReadiness.level,
                auxiliary: auxiliaryLabel(for: item)
            )
        }
    }

    private static func auxiliaryLabel(for item: ActivityTimelineItem) -> String {
        switch item.resolvedDataSource {
        case .lastSuccessful:
            return "上次成功数据"
        case .unknown:
            return "数据未知"
        case .current:
            return item.changedFileCount == 1
                ? "1 处改动"
                : "\(item.changedFileCount) 处改动"
        }
    }
}

enum WidgetRepositoryPriorityBuilder {
    static func build(from repositories: [RepositorySnapshot]) -> [ActivityTimelineItem] {
        repositories
            .map(ActivityTimelineItem.init(from:))
            .sorted(by: sort(_:_:))
    }

    static func build(from snapshot: AppGroupData?) -> [ActivityTimelineItem] {
        build(from: snapshot?.repositories ?? [])
    }

    private static func sort(_ lhs: ActivityTimelineItem,
                             _ rhs: ActivityTimelineItem) -> Bool {
        let lhsStatusPriority = itemPriority(lhs)
        let rhsStatusPriority = itemPriority(rhs)
        if lhsStatusPriority != rhsStatusPriority {
            return lhsStatusPriority < rhsStatusPriority
        }

        if lhs.resolvedDataSource == .current,
           rhs.resolvedDataSource == .current,
           lhs.changedFileCount != rhs.changedFileCount {
            return lhs.changedFileCount > rhs.changedFileCount
        }

        if let lhsDate = lhs.activityDate, let rhsDate = rhs.activityDate, lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        if lhs.activityDate != nil {
            return true
        }

        if rhs.activityDate != nil {
            return false
        }

        let lhsReadinessPriority = readinessPriority(lhs.commitReadiness.level)
        let rhsReadinessPriority = readinessPriority(rhs.commitReadiness.level)
        if lhsReadinessPriority != rhsReadinessPriority {
            return lhsReadinessPriority < rhsReadinessPriority
        }

        if lhs.resolvedDataSource == .current,
           rhs.resolvedDataSource == .current,
           lhs.risk != rhs.risk {
            return lhs.risk > rhs.risk
        }

        return lhs.repoName.localizedStandardCompare(rhs.repoName) == .orderedAscending
    }

    private static func itemPriority(_ item: ActivityTimelineItem) -> Int {
        switch item.resolvedDataSource {
        case .unknown:
            return 0
        case .lastSuccessful:
            return 1
        case .current:
            switch item.status {
            case .error:
                return 0
            case .changed:
                return 2
            case .clean:
                return 3
            }
        }
    }

    private static func readinessPriority(_ level: CommitReadinessLevel) -> Int {
        switch level {
        case .dirty:
            return 0
        case .unknown:
            return 1
        case .review:
            return 2
        case .ready:
            return 3
        case .idle:
            return 4
        }
    }
}

struct RepositoryEmptyState: Equatable {
    let title: String
    let detail: String
    let systemImage: String
}

enum RepositoryEmptyStateBuilder {
    static func build(lastScanAt: Date?,
                      refreshPhase: RefreshPhase,
                      scanRoots: [String],
                      accessWarning: String?,
                      refreshFailureMessage: String?) -> RepositoryEmptyState {
        if scanRoots.isEmpty {
            return RepositoryEmptyState(
                title: "没有可用的扫描目录",
                detail: accessWarning ?? "DevPulse 没有找到可访问的默认目录。请在 Settings 添加真实的仓库根目录，然后重新刷新。",
                systemImage: "folder.badge.questionmark"
            )
        }

        if refreshPhase == .failure {
            return RepositoryEmptyState(
                title: "扫描未完成",
                detail: refreshFailureMessage ?? accessWarning ?? "请检查扫描目录后重新刷新。",
                systemImage: "exclamationmark.triangle"
            )
        }

        if lastScanAt == nil {
            return RepositoryEmptyState(
                title: "尚未开始扫描",
                detail: "执行 Rescan Now，DevPulse 会先扫描默认目录并尝试发现本机 Git 仓库。",
                systemImage: "magnifyingglass"
            )
        }

        return RepositoryEmptyState(
            title: "未发现 Git 仓库",
            detail: accessWarning ?? "已扫描当前目录，但没有发现可读取的 Git 仓库；可在 Settings 添加其他目录后重试。",
            systemImage: "tray"
        )
    }
}

// MARK: - Scan summary

struct ScanSummary: Codable, Equatable {
    let totalRepositories: Int
    let changedRepositories: Int
    let totalChangedFiles: Int
    let errorRepositories: Int

    static func build(
        from repositories: [RepositorySnapshot],
        totalRepositories: Int? = nil
    ) -> ScanSummary {
        let currentRepositories = repositories.filter {
            $0.resolvedDataSource == .current && $0.status != .error
        }
        return ScanSummary(
            totalRepositories: totalRepositories ?? repositories.count,
            changedRepositories: currentRepositories.filter { $0.status == .changed }.count,
            totalChangedFiles: currentRepositories.reduce(0) { $0 + $1.changedFileCount },
            errorRepositories: repositories.filter {
                $0.resolvedDataSource != .current || $0.status == .error
            }.count
        )
    }
}

// MARK: - App Group root data

struct AppGroupData: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: String
    let writtenAt: String?
    let scanSummary: ScanSummary
    let repositories: [RepositorySnapshot]
    /// Small Widget-facing projection only. The full local event history is
    /// persisted separately and is never embedded in the shared snapshot.
    let recentActivityEvents: [ActivityEventSummary]?
    /// Hidden discovery tombstones. They keep the first-unavailable time for
    /// repositories that aged out of every presentation, allowing a recovered
    /// path to return without periodically resurrecting an unreadable cache.
    let repositoryUnavailableSinceByPath: [String: String]?

    init(schemaVersion: Int,
         generatedAt: String,
         writtenAt: String?,
         scanSummary: ScanSummary,
         repositories: [RepositorySnapshot],
         recentActivityEvents: [ActivityEventSummary]? = nil,
         repositoryUnavailableSinceByPath: [String: String]? = nil) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.writtenAt = writtenAt
        self.scanSummary = scanSummary
        self.repositories = repositories
        self.recentActivityEvents = recentActivityEvents
        self.repositoryUnavailableSinceByPath = repositoryUnavailableSinceByPath
    }

    static func empty() -> AppGroupData {
        AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            writtenAt: nil,
            scanSummary: ScanSummary(
                totalRepositories: 0,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 0
            ),
            repositories: [],
            recentActivityEvents: nil,
            repositoryUnavailableSinceByPath: nil
        )
    }

    func withWrittenAt(_ writtenAt: String) -> AppGroupData {
        AppGroupData(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            writtenAt: writtenAt,
            scanSummary: scanSummary,
            repositories: repositories,
            recentActivityEvents: recentActivityEvents,
            repositoryUnavailableSinceByPath: repositoryUnavailableSinceByPath
        )
    }

    func withRecentActivityEvents(_ events: [ActivityEventSummary]) -> AppGroupData {
        AppGroupData(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            writtenAt: writtenAt,
            scanSummary: scanSummary,
            repositories: repositories,
            recentActivityEvents: events,
            repositoryUnavailableSinceByPath: repositoryUnavailableSinceByPath
        )
    }

    /// Retain the last payload after a scan-level failure and downgrade every
    /// repository's provenance. `generatedAt` remains the last successful scan
    /// time; only `writtenAt` changes when this health update is shared.
    func retainingLastSuccessfulRepositories(
        attemptedAt: String,
        errorMessage: String
    ) -> AppGroupData {
        let retainedRepositories = repositories.map {
            $0.retainingLastSuccessfulData(
                attemptedAt: attemptedAt,
                errorMessage: errorMessage
            )
        }
        return AppGroupData(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            writtenAt: writtenAt,
            scanSummary: ScanSummary.build(
                from: retainedRepositories,
                totalRepositories: max(scanSummary.totalRepositories, retainedRepositories.count)
            ),
            repositories: retainedRepositories,
            recentActivityEvents: recentActivityEvents,
            repositoryUnavailableSinceByPath: repositoryUnavailableSinceByPath
        )
    }
}

// MARK: - Refresh status

enum RefreshPhase: Equatable {
    case idle
    case refreshing
    case success
    case failure
}

enum SnapshotFreshness: Equatable {
    case fresh
    case stale
    case expired
    case unknown
}

enum SnapshotTrustState: Equatable {
    case fresh
    case stale
    case expired
    case unknown
    case failed
}

struct SnapshotTrustAssessment: Equatable {
    let state: SnapshotTrustState
    let title: String
    let detail: String
    let basis: String

    var isError: Bool {
        state != .fresh
    }
}

enum WidgetRefreshCopy {
    static let waitingFirstRefreshTitle = "等待首次刷新"
    static let waitingRefreshTitle = "等待刷新"
    static let pendingConfirmationTitle = "状态待确认"

    static let waitingFirstRefreshDetail = "打开 DevPulse 执行 Refresh Data 或 Rescan Now"
    static let pendingConfirmationDetail = "打开 DevPulse 查看 Diagnostics，并执行 Refresh Data 重写共享快照"
    static let waitingRefreshSummary = "先刷新后再判断是否适合提交"
    static let pendingConfirmationSummary = "打开 DevPulse 查看 Diagnostics"

    static func waitingRefreshDetail(from trustAssessment: SnapshotTrustAssessment?) -> String {
        if let trustAssessment {
            return "\(trustAssessment.detail)。打开 DevPulse 执行 Refresh Data"
        }
        return "打开 DevPulse 执行 Refresh Data，再判断当前状态"
    }

    static func diagnosticsLabel(for trustAssessment: SnapshotTrustAssessment) -> String {
        switch trustAssessment.state {
        case .fresh:
            return trustAssessment.title
        case .stale, .expired:
            return waitingRefreshTitle
        case .unknown, .failed:
            return pendingConfirmationTitle
        }
    }
}

enum RefreshStatusFormatter {
    static let staleThreshold: TimeInterval = 10 * 60
    static let expiredThreshold: TimeInterval = 30 * 60

    static func freshness(for lastUpdatedAt: Date?, now: Date = Date()) -> SnapshotFreshness {
        guard let lastUpdatedAt else {
            return .unknown
        }

        let age = max(0, now.timeIntervalSince(lastUpdatedAt))

        if age > expiredThreshold {
            return .expired
        }

        if age >= staleThreshold {
            return .stale
        }

        return .fresh
    }

    static func refreshAssessment(
        lastUpdatedAt: Date?,
        now: Date = Date(),
        failureMessage: String? = nil
    ) -> SnapshotTrustAssessment {
        if let failureMessage, !failureMessage.isEmpty {
            let basis: String
            if let lastUpdatedAt {
                basis = "最近一次刷新失败：\(failureMessage)。当前仍显示 \(updateLabel(for: lastUpdatedAt, now: now)) 的成功结果。"
            } else {
                basis = "还没有成功刷新记录，最近一次刷新失败：\(failureMessage)。"
            }

            return SnapshotTrustAssessment(
                state: .failed,
                title: "刷新失败，建议打开 App 检查",
                detail: lastUpdatedAt.map { "上次成功刷新：\(updateLabel(for: $0, now: now))" } ?? "尚无成功刷新记录",
                basis: basis
            )
        }

        return datedAssessment(
            freshness: freshness(for: lastUpdatedAt, now: now),
            referenceDate: lastUpdatedAt,
            now: now,
            sourceLabel: "lastScanAt",
            missingReason: "还没有成功刷新记录。"
        )
    }

    static func snapshotAssessment(
        generatedAt: String?,
        writtenAt: String?,
        now: Date = Date(),
        readError: String? = nil,
        missingReason: String = "共享快照缺少可用时间。"
    ) -> SnapshotTrustAssessment {
        if let readError, !readError.isEmpty {
            return SnapshotTrustAssessment(
                state: .unknown,
                title: "状态未知",
                detail: "无法确认共享快照是否最新",
                basis: "共享快照读取失败：\(readError)"
            )
        }

        let generatedDate = generatedAt.flatMap(DateFormatting.date(from:))
        let writtenDate = writtenAt.flatMap(DateFormatting.date(from:))

        let reference: (label: String, date: Date)?
        switch (generatedDate, writtenDate) {
        case let (.some(generatedDate), .some(writtenDate)):
            reference = writtenDate >= generatedDate
                ? ("writtenAt", writtenDate)
                : ("generatedAt", generatedDate)
        case let (.some(generatedDate), .none):
            reference = ("generatedAt", generatedDate)
        case let (.none, .some(writtenDate)):
            reference = ("writtenAt", writtenDate)
        case (.none, .none):
            reference = nil
        }

        return datedAssessment(
            freshness: freshness(for: reference?.date, now: now),
            referenceDate: reference?.date,
            now: now,
            sourceLabel: reference?.label ?? "snapshotTime",
            missingReason: missingReason
        )
    }

    static func snapshotAssessment(
        snapshot: AppGroupData,
        now: Date = Date(),
        readError: String? = nil,
        missingReason: String = "共享快照缺少 generatedAt / writtenAt，无法确认 Widget 数据是否最新。"
    ) -> SnapshotTrustAssessment {
        if let readError, !readError.isEmpty {
            return snapshotAssessment(
                generatedAt: snapshot.generatedAt,
                writtenAt: snapshot.writtenAt,
                now: now,
                readError: readError,
                missingReason: missingReason
            )
        }

        if RepositoryDataAvailability.allUnavailable(snapshot.repositories) {
            let lastSuccessfulCount = snapshot.repositories.filter {
                $0.resolvedDataSource == .lastSuccessful
            }.count
            let unknownCount = snapshot.repositories.filter {
                $0.resolvedDataSource == .unknown
            }.count
            let latestSuccessfulDate = snapshot.repositories
                .compactMap(\.resolvedLastSuccessfulScanAt)
                .compactMap { DateFormatting.date(from: $0) }
                .max()

            let title: String
            let detail: String
            if unknownCount == 0 {
                title = "显示上次成功数据"
                detail = latestSuccessfulDate.map {
                    "所有仓库状态待确认 · 上次成功刷新：\(updateLabel(for: $0, now: now))"
                } ?? "所有仓库状态待确认 · 上次成功时间未知"
            } else if lastSuccessfulCount == 0 {
                title = "仓库数据未知"
                detail = "没有可用的成功仓库数据"
            } else {
                title = "仓库数据待确认"
                detail = "\(lastSuccessfulCount) 个上次成功 · \(unknownCount) 个未知"
            }

            return SnapshotTrustAssessment(
                state: .failed,
                title: title,
                detail: detail,
                basis: "共享快照不含任何 current 仓库；writtenAt 仅表示可信度状态已写入，不代表仓库扫描成功。"
            )
        }

        return snapshotAssessment(
            generatedAt: snapshot.generatedAt,
            writtenAt: snapshot.writtenAt,
            now: now,
            readError: readError,
            missingReason: missingReason
        )
    }

    static func updateLabel(for lastUpdatedAt: Date, now: Date = Date()) -> String {
        let age = max(0, now.timeIntervalSince(lastUpdatedAt))

        if age < 60 {
            return "刚刚更新"
        }

        if age < 3600 {
            return "\(Int(age / 60)) 分钟前更新"
        }

        if age < 86400 {
            return "\(Int(age / 3600)) 小时前更新"
        }

        return "\(Int(age / 86400)) 天前更新"
    }

    private static func datedAssessment(
        freshness: SnapshotFreshness,
        referenceDate: Date?,
        now: Date,
        sourceLabel: String,
        missingReason: String
    ) -> SnapshotTrustAssessment {
        switch freshness {
        case .fresh:
            guard let referenceDate else {
                return SnapshotTrustAssessment(
                    state: .unknown,
                    title: "状态未知",
                    detail: "无法确认数据是否最新",
                    basis: missingReason
                )
            }

            return SnapshotTrustAssessment(
                state: .fresh,
                title: updateLabel(for: referenceDate, now: now),
                detail: "数据仍在可信时间窗内",
                basis: "基于 \(sourceLabel) 判断，最新时间是 \(formattedDate(referenceDate))。"
            )
        case .stale:
            guard let referenceDate else {
                return SnapshotTrustAssessment(
                    state: .unknown,
                    title: "状态未知",
                    detail: "无法确认数据是否最新",
                    basis: missingReason
                )
            }

            return SnapshotTrustAssessment(
                state: .stale,
                title: "数据可能已过期",
                detail: "最近一次更新在 \(updateLabel(for: referenceDate, now: now))",
                basis: "基于 \(sourceLabel) 判断，距离最近一次更新已超过 10 分钟。"
            )
        case .expired:
            guard let referenceDate else {
                return SnapshotTrustAssessment(
                    state: .unknown,
                    title: "状态未知",
                    detail: "无法确认数据是否最新",
                    basis: missingReason
                )
            }

            return SnapshotTrustAssessment(
                state: .expired,
                title: "数据可能已过期",
                detail: "最近一次更新在 \(updateLabel(for: referenceDate, now: now))",
                basis: "基于 \(sourceLabel) 判断，距离最近一次更新已超过 30 分钟。"
            )
        case .unknown:
            return SnapshotTrustAssessment(
                state: .unknown,
                title: "状态未知",
                detail: "无法确认数据是否最新",
                basis: missingReason
            )
        }
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Widget-specific display entry

struct WidgetRepositoryEntry: Codable {
    let id: String
    let name: String
    let branch: String
    let status: RepositoryStatus
    let changedFileCount: Int
    let risk: RiskLevel
    let topChangedFile: String?

    init(from snapshot: RepositorySnapshot) {
        self.id = snapshot.id
        self.name = snapshot.name
        self.branch = snapshot.branch
        self.status = snapshot.status
        self.changedFileCount = snapshot.changedFileCount
        self.risk = snapshot.risk
        self.topChangedFile = snapshot.changedFilesPreview.first
    }
}

// MARK: - Diagnostics

struct DiagnosticEvent: Identifiable, Equatable {
    enum Kind: String, Codable {
        case scanStarted
        case scanSucceeded
        case scanFailed
        case sharedDataWritten
        case sharedDataWriteFailed
        case sharedDataReadFailed
        case widgetReloadRequested
        case widgetReloadSkipped
        case validationPassed
        case validationFailed
    }

    let id = UUID()
    let timestamp: String
    let kind: Kind
    let message: String
}

struct DiagnosticsSnapshot {
    var lastRefreshStartedAt: Date?
    var lastRefreshCompletedAt: Date?
    var appBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "unknown"
    var widgetBundleIdentifier: String = "local.devpulse.app.widget"
    var appGroupIdentifier: String = SharedSnapshotLocation.appGroupIdentifier
    var appGroupContainerPath: String?
    var snapshotFilePath: String?
    var appGroupAvailable: Bool = false
    var snapshotExists: Bool = false
    var snapshotReadable: Bool = false
    var snapshotWritable: Bool = false
    var snapshotDecodable: Bool = false
    var lastScanAt: Date?
    var lastGeneratedAt: String?
    var lastWrittenAt: String?
    var lastSharedWriteAt: Date?
    var lastReloadRequestedAt: Date?
    var lastSnapshotStoreTrigger: String?
    var lastSnapshotStoreState: SnapshotStoreState = .idle
    var lastSnapshotStoreDetail: String?
    var lastWidgetReloadState: WidgetReloadState = .idle
    var lastWidgetReloadDetail: String?
    var sharedDataReadAt: Date?
    var widgetSnapshotReadAt: Date?
    var sharedDataReadError: String?
    var sharedDataWriteError: String?
    var widgetSnapshotReadError: String?
    var validationIssues: [String] = []
    var scanRoots: [String] = []
    var scanRootWarnings: [String] = []
    var nextSteps: [String] = []
    var sharedDataSnapshot: AppGroupData?
    var widgetSnapshot: AppGroupData?

    var sharedDataReadSucceeded: Bool {
        sharedDataReadError == nil && sharedDataSnapshot != nil
    }

    var sharedDataWriteSucceeded: Bool {
        sharedDataWriteError == nil && lastSharedWriteAt != nil
    }

    var widgetSnapshotReadSucceeded: Bool {
        widgetSnapshotReadError == nil && widgetSnapshot != nil
    }
}

enum SnapshotStoreState: Equatable {
    case idle
    case restored
    case verified
    case failed
}

enum WidgetReloadState: Equatable {
    case idle
    case requested
    case skipped
}

enum DiagnosticsSeverity: Equatable {
    case normal
    case warning
    case error
}

struct DiagnosticsStatusItem: Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let nextStep: String?
    let severity: DiagnosticsSeverity
}

struct DiagnosticsSectionModel: Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let severity: DiagnosticsSeverity
    let items: [DiagnosticsStatusItem]
}

struct DiagnosticsOverviewModel: Equatable {
    let headline: String
    let summary: String
    let severity: DiagnosticsSeverity
    let sections: [DiagnosticsSectionModel]
}

struct WidgetDataTrustModel: Equatable {
    let headline: String
    let summary: String
    let severity: DiagnosticsSeverity
    let evidence: [DiagnosticsStatusItem]
    let nextSteps: [String]
    let primaryAction: WidgetDataTrustPrimaryAction
}

enum WidgetDataTrustPrimaryActionKind: Equatable {
    case refreshData
    case rescan
    case viewDiagnostics
}

struct WidgetDataTrustPrimaryAction: Equatable {
    let kind: WidgetDataTrustPrimaryActionKind
    let title: String
    let systemImage: String
    let helpText: String

    var requiresScanning: Bool {
        switch kind {
        case .refreshData, .rescan:
            return true
        case .viewDiagnostics:
            return false
        }
    }
}

struct WidgetDataTrustPrimaryButtonModel: Equatable {
    let title: String
    let systemImage: String
    let helpText: String
    let isDisabled: Bool
    let actionKind: WidgetDataTrustPrimaryActionKind
}

enum WidgetDataTrustPrimaryButtonBuilder {
    static func build(
        action: WidgetDataTrustPrimaryAction,
        isScanning: Bool
    ) -> WidgetDataTrustPrimaryButtonModel {
        let title: String

        switch action.kind {
        case .refreshData:
            title = isScanning ? "刷新中…" : action.title
        case .rescan:
            title = isScanning ? "扫描中…" : action.title
        case .viewDiagnostics:
            title = action.title
        }

        return WidgetDataTrustPrimaryButtonModel(
            title: title,
            systemImage: action.systemImage,
            helpText: action.helpText,
            isDisabled: action.requiresScanning && isScanning,
            actionKind: action.kind
        )
    }
}

enum AppTab: Int, Equatable {
    case overview = 0
    case repositories = 1
    case settings = 2
}

enum SettingsScrollTarget: Hashable {
    case diagnostics
}

enum OverviewPrimaryActionKind: Equatable {
    case refreshData
    case rescan
    case openRepositories
    case openSettings
    case openDiagnostics
}

struct OverviewPrimaryAction: Equatable {
    let kind: OverviewPrimaryActionKind
    let title: String
    let systemImage: String
}

struct OverviewFocusModel: Equatable {
    let title: String
    let summary: String
    let detail: String?
    let severity: DiagnosticsSeverity
    let action: OverviewPrimaryAction
}

enum OverviewDiagnosticsNavigation {
    static let tab: AppTab = .settings
    static let scrollTarget: SettingsScrollTarget = .diagnostics
}

enum OverviewFocusBuilder {
    static func build(
        lastScanAt: Date?,
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: WidgetDataTrustModel,
        repositories: [RepositorySnapshot]
    ) -> OverviewFocusModel {
        if diagnostics.scanRoots.isEmpty {
            return OverviewFocusModel(
                title: "没有可用的扫描目录",
                summary: "当前还没有可访问的仓库根目录，Overview 暂时不会展示仓库状态。",
                detail: "去 Settings 添加真实仓库目录后，再执行一次刷新。",
                severity: .warning,
                action: OverviewPrimaryAction(
                    kind: .openSettings,
                    title: "打开 Settings",
                    systemImage: "gearshape"
                )
            )
        }

        if repositories.isEmpty {
            if lastScanAt == nil {
                return OverviewFocusModel(
                    title: "尚未开始扫描",
                    summary: "先建立一次当前快照，Overview 才能判断哪一个仓库最值得处理。",
                    detail: "执行一次 Rescan 后，会自动发现扫描目录里的 Git 仓库。",
                    severity: .warning,
                    action: OverviewPrimaryAction(
                        kind: .rescan,
                        title: "Rescan Now",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                )
            }

            return OverviewFocusModel(
                title: "还没有发现仓库",
                summary: "当前扫描目录里没有可读取的 Git 仓库。",
                detail: "去 Settings 调整扫描目录，或确认目录访问权限后再刷新。",
                severity: .warning,
                action: OverviewPrimaryAction(
                    kind: .openSettings,
                    title: "检查 Settings",
                    systemImage: "gearshape"
                )
            )
        }

        if widgetTrust.severity == .error {
            return widgetTrustFocus(widgetTrust)
        }

        if let repo = priorityRepository(in: repositories) {
            return repositoryFocus(repo)
        }

        if widgetTrust.severity == .warning {
            return widgetTrustFocus(widgetTrust)
        }

        let repoCountLabel = repositories.count == 1 ? "1 个仓库" : "\(repositories.count) 个仓库"
        return OverviewFocusModel(
            title: "当前没有需要处理的仓库",
            summary: "\(repoCountLabel) 当前都没有待审查的本地改动。",
            detail: "如果想逐个确认状态，可以去 Repositories 查看完整列表。",
            severity: .normal,
            action: OverviewPrimaryAction(
                kind: .openRepositories,
                title: "查看仓库列表",
                systemImage: "list.bullet.rectangle"
            )
        )
    }

    private static func widgetTrustFocus(_ widgetTrust: WidgetDataTrustModel) -> OverviewFocusModel {
        OverviewFocusModel(
            title: widgetTrust.headline,
            summary: widgetTrust.summary,
            detail: widgetTrust.nextSteps.first,
            severity: widgetTrust.severity,
            action: OverviewPrimaryAction(
                kind: mapActionKind(widgetTrust.primaryAction.kind),
                title: widgetTrust.primaryAction.title,
                systemImage: widgetTrust.primaryAction.systemImage
            )
        )
    }

    private static func repositoryFocus(_ repo: RepositorySnapshot) -> OverviewFocusModel {
        switch repo.resolvedDataSource {
        case .lastSuccessful:
            return OverviewFocusModel(
                title: "\(repo.name) 正显示上次成功数据",
                summary: repo.statusSummary,
                detail: repo.nextActionHint,
                severity: .warning,
                action: OverviewPrimaryAction(
                    kind: .refreshData,
                    title: "刷新确认",
                    systemImage: "arrow.clockwise"
                )
            )
        case .unknown:
            return OverviewFocusModel(
                title: "\(repo.name) 当前数据未知",
                summary: repo.statusSummary,
                detail: repo.nextActionHint,
                severity: .error,
                action: OverviewPrimaryAction(
                    kind: .openDiagnostics,
                    title: "查看诊断",
                    systemImage: "stethoscope"
                )
            )
        case .current:
            break
        }

        if repo.status == .error || repo.commitReadiness.level == .unknown {
            return OverviewFocusModel(
                title: "\(repo.name) 状态读取失败",
                summary: repo.statusSummary,
                detail: repo.nextActionHint,
                severity: .error,
                action: OverviewPrimaryAction(
                    kind: .openDiagnostics,
                    title: "查看诊断",
                    systemImage: "stethoscope"
                )
            )
        }

        return OverviewFocusModel(
            title: repo.name,
            summary: repo.statusSummary,
            detail: repo.nextActionHint,
            severity: severity(for: repo.commitReadiness.level),
            action: OverviewPrimaryAction(
                kind: .openRepositories,
                title: "查看仓库列表",
                systemImage: "list.bullet.rectangle"
            )
        )
    }

    private static func priorityRepository(in repositories: [RepositorySnapshot]) -> RepositorySnapshot? {
        if let brokenRepo = repositories.first(where: { $0.status == .error || $0.commitReadiness.level == .unknown }) {
            return brokenRepo
        }

        return repositories.sorted(by: repositoryPriority(_:_:)).first {
            $0.commitReadiness.level != .idle || (($0.aheadCount ?? 0) > 0)
        }
    }

    private static func repositoryPriority(_ lhs: RepositorySnapshot, _ rhs: RepositorySnapshot) -> Bool {
        let lhsReadinessPriority = readinessPriority(lhs.commitReadiness.level)
        let rhsReadinessPriority = readinessPriority(rhs.commitReadiness.level)
        if lhsReadinessPriority != rhsReadinessPriority {
            return lhsReadinessPriority < rhsReadinessPriority
        }

        if lhs.changedFileCount != rhs.changedFileCount {
            return lhs.changedFileCount > rhs.changedFileCount
        }

        if lhs.risk != rhs.risk {
            return lhs.risk > rhs.risk
        }

        if let lhsDate = isoDate(lhs.lastChangedAt), let rhsDate = isoDate(rhs.lastChangedAt), lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        if lhs.lastChangedAt != nil {
            return true
        }

        if rhs.lastChangedAt != nil {
            return false
        }

        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func mapActionKind(_ kind: WidgetDataTrustPrimaryActionKind) -> OverviewPrimaryActionKind {
        switch kind {
        case .refreshData:
            return .refreshData
        case .rescan:
            return .rescan
        case .viewDiagnostics:
            return .openDiagnostics
        }
    }

    private static func severity(for level: CommitReadinessLevel) -> DiagnosticsSeverity {
        switch level {
        case .ready:
            return .normal
        case .review, .idle:
            return .warning
        case .dirty, .unknown:
            return .error
        }
    }

    private static func readinessPriority(_ level: CommitReadinessLevel) -> Int {
        switch level {
        case .unknown:
            return 0
        case .dirty:
            return 1
        case .review:
            return 2
        case .ready:
            return 3
        case .idle:
            return 4
        }
    }

    private static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

enum DiagnosticsOverviewBuilder {
    static func build(
        diagnostics: DiagnosticsSnapshot,
        refreshTrust: SnapshotTrustAssessment,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> DiagnosticsOverviewModel {
        let sharedDataSection = sharedDataSection(
            diagnostics: diagnostics,
            repositories: repositories
        )
        let snapshotStoreSection = snapshotStoreSection(
            diagnostics: diagnostics,
            repositories: repositories
        )
        let widgetSection = widgetSection(diagnostics: diagnostics, widgetTrust: widgetTrust)
        let scanSection = scanSection(
            diagnostics: diagnostics,
            refreshTrust: refreshTrust,
            repositories: repositories
        )

        let sections = [sharedDataSection, snapshotStoreSection, widgetSection, scanSection]
        let headline: (title: String, summary: String, severity: DiagnosticsSeverity)

        if let topError = sections.first(where: { $0.severity == .error }) {
            headline = (topError.title, topError.summary, .error)
        } else if let topWarning = sections.first(where: { $0.severity == .warning }) {
            headline = (topWarning.title, topWarning.summary, .warning)
        } else {
            headline = ("链路正常", "App、共享快照和 Widget 当前看起来一致。", .normal)
        }

        return DiagnosticsOverviewModel(
            headline: headline.title,
            summary: headline.summary,
            severity: headline.severity,
            sections: sections
        )
    }

    private static func sharedDataSection(
        diagnostics: DiagnosticsSnapshot,
        repositories: [RepositorySnapshot]
    ) -> DiagnosticsSectionModel {
        let appGroupSeverity: DiagnosticsSeverity = diagnostics.appGroupAvailable ? .normal : .error
        let isInitialSnapshotMissing = isInitialSnapshotMissing(
            diagnostics: diagnostics,
            repositories: repositories
        )
        let fileSeverity: DiagnosticsSeverity = diagnostics.snapshotExists
            ? .normal
            : (isInitialSnapshotMissing ? .warning : .error)
        let readSeverity: DiagnosticsSeverity
        if diagnostics.sharedDataReadError != nil {
            readSeverity = .error
        } else if diagnostics.sharedDataSnapshot != nil {
            readSeverity = .normal
        } else {
            readSeverity = .warning
        }

        let items = [
            DiagnosticsStatusItem(
                id: "app-group",
                title: "App Group",
                value: diagnostics.appGroupAvailable ? "可用" : "不可用",
                detail: diagnostics.appGroupContainerPath ?? "没有拿到共享容器路径。",
                nextStep: diagnostics.appGroupAvailable ? nil : "检查 App Group entitlement 和签名配置。",
                severity: appGroupSeverity
            ),
            DiagnosticsStatusItem(
                id: "snapshot-file",
                title: "数据文件",
                value: diagnostics.snapshotExists ? "已找到" : "缺失",
                detail: diagnostics.snapshotFilePath ?? "没有解析到 repositories.json 路径。",
                nextStep: diagnostics.snapshotExists ? nil : "先执行一次 Rescan，确认 repositories.json 已写入共享容器。",
                severity: fileSeverity
            ),
            DiagnosticsStatusItem(
                id: "shared-read",
                title: "共享读取",
                value: diagnostics.sharedDataSnapshot != nil ? "成功" : (diagnostics.sharedDataReadError == nil ? "等待中" : "失败"),
                detail: diagnostics.sharedDataReadError
                    ?? diagnostics.sharedDataReadAt.map { "最近读回：\(formattedDate($0))" }
                    ?? "启动后还没有完成一次共享快照读回。",
                nextStep: diagnostics.sharedDataReadError == nil ? nil : "检查数据文件是否可读，再重新执行一次 Rescan。",
                severity: readSeverity
            )
        ]

        let severity = maxSeverity(items.map(\.severity))
        let summary = items.first(where: { $0.severity == .error })?.detail
            ?? items.first(where: { $0.severity == .warning })?.detail
            ?? "App Group 与共享快照文件当前可访问。"

        return DiagnosticsSectionModel(
            id: "shared-data",
            title: "共享数据链路",
            summary: summary,
            severity: severity,
            items: items
        )
    }

    private static func widgetSection(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment
    ) -> DiagnosticsSectionModel {
        let trustSeverity = severity(for: widgetTrust.state)
        let snapshotSeverity: DiagnosticsSeverity
        if diagnostics.widgetSnapshotReadError != nil {
            snapshotSeverity = .error
        } else if diagnostics.widgetSnapshot != nil {
            snapshotSeverity = .normal
        } else {
            snapshotSeverity = .warning
        }
        let validationSeverity = diagnostics.validationIssues.isEmpty ? DiagnosticsSeverity.normal : .error

        let items = [
            DiagnosticsStatusItem(
                id: "widget-trust",
                title: "Widget 数据可信度",
                value: WidgetRefreshCopy.diagnosticsLabel(for: widgetTrust),
                detail: widgetTrust.basis,
                nextStep: widgetTrust.isError ? "如果 Widget 文案看起来不对，优先检查这里的时间戳和读取结果。" : nil,
                severity: trustSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-snapshot",
                title: "Widget 可读快照",
                value: diagnostics.widgetSnapshot != nil ? "可读取" : (diagnostics.widgetSnapshotReadError == nil ? "等待中" : "读取失败"),
                detail: diagnostics.widgetSnapshotReadError
                    ?? diagnostics.widgetSnapshotReadAt.map { "最近读取：\(formattedDate($0))" }
                    ?? "Widget 侧还没有拿到快照。",
                nextStep: diagnostics.widgetSnapshotReadError == nil ? nil : "先确认共享快照已写入，再重新打开 App 检查 Widget reload。",
                severity: snapshotSeverity
            ),
            DiagnosticsStatusItem(
                id: "validation",
                title: "数据一致性",
                value: diagnostics.validationIssues.isEmpty ? "一致" : "不一致",
                detail: diagnostics.validationIssues.isEmpty
                    ? "主 App、共享快照和 Widget 可读快照当前一致。"
                    : diagnostics.validationIssues.joined(separator: " "),
                nextStep: diagnostics.validationIssues.isEmpty ? nil : "按顺序检查 shared write、widget snapshot 和 reload requested 时间。",
                severity: validationSeverity
            )
        ]

        let severity = maxSeverity(items.map(\.severity))
        let summary = items.first(where: { $0.severity == .error })?.detail
            ?? items.first(where: { $0.severity == .warning })?.detail
            ?? "Widget 当前拿到的数据和主 App 一致。"

        return DiagnosticsSectionModel(
            id: "widget-state",
            title: "Widget 状态",
            summary: summary,
            severity: severity,
            items: items
        )
    }

    private static func snapshotStoreSection(
        diagnostics: DiagnosticsSnapshot,
        repositories: [RepositorySnapshot]
    ) -> DiagnosticsSectionModel {
        let isInitialSnapshotMissing = isInitialSnapshotMissing(
            diagnostics: diagnostics,
            repositories: repositories
        )
        let storeSeverity = severity(
            for: diagnostics.lastSnapshotStoreState,
            snapshotExists: diagnostics.snapshotExists,
            isInitialSnapshotMissing: isInitialSnapshotMissing
        )
        let triggerSeverity: DiagnosticsSeverity = diagnostics.lastSnapshotStoreTrigger == nil
            ? (isInitialSnapshotMissing ? .warning : .normal)
            : .normal
        let reloadSeverity = severity(for: diagnostics.lastWidgetReloadState)

        let items = [
            DiagnosticsStatusItem(
                id: "snapshot-store-state",
                title: "Snapshot Store",
                value: label(for: diagnostics.lastSnapshotStoreState, snapshotExists: diagnostics.snapshotExists),
                detail: diagnostics.lastSnapshotStoreDetail
                    ?? defaultSnapshotStoreDetail(
                        state: diagnostics.lastSnapshotStoreState,
                        snapshotExists: diagnostics.snapshotExists,
                        isInitialSnapshotMissing: isInitialSnapshotMissing
                    ),
                nextStep: diagnostics.lastSnapshotStoreState == .failed ? "先执行 Refresh Data，再检查 shared write 和 validation。" : nil,
                severity: storeSeverity
            ),
            DiagnosticsStatusItem(
                id: "snapshot-store-trigger",
                title: "最近触发来源",
                value: diagnostics.lastSnapshotStoreTrigger.map(label(forTrigger:)) ?? "尚未记录",
                detail: triggerDetail(diagnostics: diagnostics),
                nextStep: diagnostics.lastSnapshotStoreTrigger == nil && !isInitialSnapshotMissing
                    ? "执行一次 Refresh Data 或 Rescan，建立第一条可追踪的快照写入记录。"
                    : nil,
                severity: triggerSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-reload-state",
                title: "Widget reload",
                value: label(for: diagnostics.lastWidgetReloadState),
                detail: diagnostics.lastWidgetReloadDetail
                    ?? defaultWidgetReloadDetail(state: diagnostics.lastWidgetReloadState),
                nextStep: diagnostics.lastWidgetReloadState == .skipped
                    ? "如果你预期桌面立刻变化，可手动执行 Refresh Data 再观察 reload requested 时间。"
                    : nil,
                severity: reloadSeverity
            )
        ]

        let severity = maxSeverity(items.map(\.severity))
        let summary = items.first(where: { $0.severity == .error })?.detail
            ?? items.first(where: { $0.severity == .warning })?.detail
            ?? "Snapshot Store 最近一次写入、校验和 Widget reload 决策都已记录。"

        return DiagnosticsSectionModel(
            id: "snapshot-store",
            title: "Snapshot Store",
            summary: summary,
            severity: severity,
            items: items
        )
    }

    private static func scanSection(
        diagnostics: DiagnosticsSnapshot,
        refreshTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> DiagnosticsSectionModel {
        let repoErrors = repositories.filter { $0.status == .error || $0.commitReadiness.level == .unknown }
        let repoSeverity: DiagnosticsSeverity
        if !repoErrors.isEmpty {
            repoSeverity = .error
        } else if repositories.isEmpty {
            repoSeverity = .warning
        } else {
            repoSeverity = .normal
        }

        let items = [
            DiagnosticsStatusItem(
                id: "refresh-trust",
                title: "最近扫描",
                value: refreshTrust.title,
                detail: refreshTrust.basis,
                nextStep: refreshTrust.isError ? "如果数据过旧或刷新失败，先手动执行一次 Rescan。" : nil,
                severity: severity(for: refreshTrust.state)
            ),
            DiagnosticsStatusItem(
                id: "repo-detection",
                title: "仓库识别",
                value: repositories.isEmpty ? "没有仓库" : "识别到 \(repositories.count) 个仓库",
                detail: repoErrors.isEmpty
                    ? (repositories.isEmpty ? "当前快照里没有仓库。" : "当前没有仓库读取失败。")
                    : "有 \(repoErrors.count) 个仓库读取失败或状态未知。",
                nextStep: repositories.isEmpty
                    ? "检查扫描目录是否指向真实仓库根目录。"
                    : (repoErrors.isEmpty ? nil : "打开下方仓库列表，优先处理标红的 Git 读取失败项。"),
                severity: repoSeverity
            ),
            DiagnosticsStatusItem(
                id: "last-error",
                title: "最近一次异常",
                value: latestErrorMessage(diagnostics: diagnostics) == nil ? "无" : "已记录",
                detail: latestErrorMessage(diagnostics: diagnostics) ?? "当前没有新的错误原因。",
                nextStep: latestErrorMessage(diagnostics: diagnostics) == nil ? nil : "如果问题已经消失，再执行一次 Rescan 确认异常不会复现。",
                severity: latestErrorMessage(diagnostics: diagnostics) == nil ? .normal : .warning
            )
        ]

        let severity = maxSeverity(items.map(\.severity))
        let summary = items.first(where: { $0.severity == .error })?.detail
            ?? items.first(where: { $0.severity == .warning })?.detail
            ?? "最近一次扫描成功，仓库识别正常。"

        return DiagnosticsSectionModel(
            id: "scan-state",
            title: "扫描与仓库识别",
            summary: summary,
            severity: severity,
            items: items
        )
    }

    private static func latestErrorMessage(diagnostics: DiagnosticsSnapshot) -> String? {
        diagnostics.widgetSnapshotReadError
            ?? diagnostics.sharedDataWriteError
            ?? diagnostics.sharedDataReadError
            ?? diagnostics.validationIssues.first
    }

    private static func severity(for state: SnapshotTrustState) -> DiagnosticsSeverity {
        switch state {
        case .fresh:
            return .normal
        case .stale, .expired, .unknown:
            return .warning
        case .failed:
            return .error
        }
    }

    private static func isInitialSnapshotMissing(
        diagnostics: DiagnosticsSnapshot,
        repositories: [RepositorySnapshot]
    ) -> Bool {
        diagnostics.appGroupAvailable
            && !diagnostics.snapshotExists
            && repositories.isEmpty
            && diagnostics.sharedDataReadError == nil
            && diagnostics.sharedDataWriteError == nil
            && diagnostics.lastSharedWriteAt == nil
            && diagnostics.sharedDataSnapshot == nil
    }

    private static func maxSeverity(_ severities: [DiagnosticsSeverity]) -> DiagnosticsSeverity {
        if severities.contains(.error) {
            return .error
        }
        if severities.contains(.warning) {
            return .warning
        }
        return .normal
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func severity(
        for state: SnapshotStoreState,
        snapshotExists: Bool,
        isInitialSnapshotMissing: Bool
    ) -> DiagnosticsSeverity {
        switch state {
        case .failed:
            return .error
        case .idle:
            return (!snapshotExists && isInitialSnapshotMissing) ? .warning : .normal
        case .restored, .verified:
            return .normal
        }
    }

    private static func severity(for state: WidgetReloadState) -> DiagnosticsSeverity {
        switch state {
        case .idle, .requested, .skipped:
            return .normal
        }
    }

    private static func label(for state: SnapshotStoreState, snapshotExists: Bool) -> String {
        switch state {
        case .idle:
            return snapshotExists ? "等待下一次写入" : "尚未建立"
        case .restored:
            return "启动时已恢复"
        case .verified:
            return "写入并校验成功"
        case .failed:
            return "写入或校验失败"
        }
    }

    private static func label(for state: WidgetReloadState) -> String {
        switch state {
        case .idle:
            return "尚未记录"
        case .requested:
            return "已请求"
        case .skipped:
            return "本次跳过"
        }
    }

    private static func label(forTrigger trigger: String) -> String {
        switch trigger {
        case "scan":
            return "扫描刷新"
        case "self-check":
            return "自检刷新"
        case "pin toggle":
            return "置顶状态变更"
        case "startup":
            return "启动恢复"
        default:
            return trigger
        }
    }

    private static func triggerDetail(diagnostics: DiagnosticsSnapshot) -> String {
        var parts: [String] = []

        if let startedAt = diagnostics.lastRefreshStartedAt {
            parts.append("开始于 \(formattedDate(startedAt))")
        }
        if let completedAt = diagnostics.lastRefreshCompletedAt {
            parts.append("完成于 \(formattedDate(completedAt))")
        }

        if parts.isEmpty {
            return "还没有记录过刷新开始/结束时间。"
        }

        return parts.joined(separator: " · ")
    }

    private static func defaultSnapshotStoreDetail(
        state: SnapshotStoreState,
        snapshotExists: Bool,
        isInitialSnapshotMissing: Bool
    ) -> String {
        switch state {
        case .idle:
            if !snapshotExists && isInitialSnapshotMissing {
                return "共享快照还没生成；这是首次启动或清空快照后的正常待初始化状态。"
            }
            return "当前还没有新的 Snapshot Store 写入记录。"
        case .restored:
            return "启动时已从共享容器恢复最近一次可读快照。"
        case .verified:
            return "最近一次共享快照写入成功，并且主 App 已读回同一份数据。"
        case .failed:
            return "最近一次共享快照写入或读回校验失败。"
        }
    }

    private static func defaultWidgetReloadDetail(state: WidgetReloadState) -> String {
        switch state {
        case .idle:
            return "还没有记录过 Widget reload 决策。"
        case .requested:
            return "最近一次共享快照同步后，主 App 已请求 Widget 更新时间线。"
        case .skipped:
            return "最近一次共享快照同步没有请求 Widget reload。"
        }
    }
}

enum WidgetDataTrustBuilder {
    static func build(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> WidgetDataTrustModel {
        let evidence = buildEvidence(
            diagnostics: diagnostics,
            widgetTrust: widgetTrust,
            repositories: repositories
        )
        let severity = overallSeverity(
            diagnostics: diagnostics,
            widgetTrust: widgetTrust,
            repositories: repositories
        )
        let headline = headline(
            diagnostics: diagnostics,
            severity: severity,
            widgetTrust: widgetTrust,
            repositories: repositories
        )
        let summary = summary(
            diagnostics: diagnostics,
            widgetTrust: widgetTrust,
            repositories: repositories
        )
        let nextSteps = nextSteps(
            diagnostics: diagnostics,
            widgetTrust: widgetTrust,
            repositories: repositories
        )

        return WidgetDataTrustModel(
            headline: headline,
            summary: summary,
            severity: severity,
            evidence: evidence,
            nextSteps: nextSteps,
            primaryAction: primaryAction(
                diagnostics: diagnostics,
                widgetTrust: widgetTrust,
                repositories: repositories
            )
        )
    }

    private static func buildEvidence(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> [DiagnosticsStatusItem] {
        let isInitialSnapshotMissing = isInitialSnapshotMissing(
            diagnostics: diagnostics,
            repositories: repositories
        )
        let snapshotExistsSeverity: DiagnosticsSeverity = diagnostics.snapshotExists ? .normal : (isInitialSnapshotMissing ? .warning : .error)
        let snapshotReadableSeverity: DiagnosticsSeverity = diagnostics.snapshotReadable ? .normal : (isInitialSnapshotMissing ? .warning : .error)
        let snapshotWritableSeverity: DiagnosticsSeverity = diagnostics.snapshotWritable ? .normal : .error
        let snapshotDecodableSeverity: DiagnosticsSeverity = diagnostics.snapshotDecodable ? .normal : (isInitialSnapshotMissing ? .warning : .error)
        let freshnessSeverity = severity(for: widgetTrust.state)
        let consistencySeverity = diagnostics.validationIssues.isEmpty ? DiagnosticsSeverity.normal : .error

        return [
            DiagnosticsStatusItem(
                id: "widget-trust-snapshot-exists",
                title: "共享快照文件",
                value: diagnostics.snapshotExists ? "已生成" : "缺失",
                detail: diagnostics.snapshotFilePath ?? "还没有解析到 repositories.json 路径。",
                nextStep: diagnostics.snapshotExists ? nil : "先执行一次 Rescan Now，确认主 App 已生成共享快照。",
                severity: snapshotExistsSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-trust-snapshot-readable",
                title: "主 App 可读",
                value: diagnostics.snapshotReadable ? "可以读取" : "无法读取",
                detail: diagnostics.sharedDataReadError
                    ?? "主 App 可以读回共享快照。读取失败时这里会显示错误原因。",
                nextStep: diagnostics.snapshotReadable ? nil : "检查 App Group、签名和共享容器路径后再执行 Refresh Data。",
                severity: snapshotReadableSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-trust-snapshot-writable",
                title: "主 App 可写",
                value: diagnostics.snapshotWritable ? "可以重写" : "无法重写",
                detail: diagnostics.sharedDataWriteError
                    ?? diagnostics.lastSharedWriteAt.map { "最近一次确认写入：\(formattedDate($0))" }
                    ?? "主 App 还没有完成一次确认写入。",
                nextStep: diagnostics.snapshotWritable ? nil : "检查 App Group entitlement、签名和容器权限，再执行 Refresh Data。",
                severity: snapshotWritableSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-trust-snapshot-decodable",
                title: "快照可解码",
                value: diagnostics.snapshotDecodable ? "可以解码" : "无法解码",
                detail: diagnostics.snapshotDecodable
                    ? "共享快照 schema 和当前 App 一致。"
                    : (diagnostics.sharedDataReadError ?? "还没有拿到一份可解码的共享快照。"),
                nextStep: diagnostics.snapshotDecodable ? nil : "如果反复失败，清理构建产物并让 App 重写共享快照。",
                severity: snapshotDecodableSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-trust-freshness",
                title: "最新程度",
                value: freshnessLabel(for: widgetTrust),
                detail: widgetTrust.basis,
                nextStep: widgetTrust.state == .fresh ? nil : "如果时间已经过旧，优先执行 Refresh Data；仍异常再检查 Widget reload 和签名配置。",
                severity: freshnessSeverity
            ),
            DiagnosticsStatusItem(
                id: "widget-trust-consistency",
                title: "App / Widget 一致性",
                value: diagnostics.validationIssues.isEmpty ? "一致" : "不一致",
                detail: diagnostics.validationIssues.isEmpty
                    ? "主 App、共享快照和 Widget 当前看到的是同一份数据。"
                    : diagnostics.validationIssues.joined(separator: " "),
                nextStep: diagnostics.validationIssues.isEmpty ? nil : "先看 shared write、widget snapshot 和 reload requested 的时间是否连续成功。",
                severity: consistencySeverity
            )
        ]
    }

    private static func overallSeverity(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> DiagnosticsSeverity {
        let isInitialSnapshotMissing = isInitialSnapshotMissing(
            diagnostics: diagnostics,
            repositories: repositories
        )

        if !diagnostics.appGroupAvailable
            || (!diagnostics.snapshotExists && !isInitialSnapshotMissing)
            || (!diagnostics.snapshotReadable && !isInitialSnapshotMissing)
            || !diagnostics.snapshotWritable
            || (!diagnostics.snapshotDecodable && !isInitialSnapshotMissing)
            || diagnostics.sharedDataReadError != nil
            || diagnostics.sharedDataWriteError != nil
            || diagnostics.widgetSnapshotReadError != nil
            || !diagnostics.validationIssues.isEmpty {
            return .error
        }

        switch widgetTrust.state {
        case .fresh:
            return .normal
        case .stale, .expired, .unknown, .failed:
            return .warning
        }
    }

    private static func headline(
        diagnostics: DiagnosticsSnapshot,
        severity: DiagnosticsSeverity,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> String {
        switch severity {
        case .normal:
            return "当前 Widget 数据可信"
        case .warning:
            if isInitialSnapshotMissing(
                diagnostics: diagnostics,
                repositories: repositories
            ) {
                return "Widget 正等待首次刷新"
            }
            switch widgetTrust.state {
            case .stale, .expired:
                return "当前 Widget 正等待刷新"
            case .unknown, .failed:
                return "当前 Widget 状态待确认"
            case .fresh:
                return "当前 Widget 数据基本可信"
            }
        case .error:
            if !diagnostics.snapshotExists {
                return "Widget 还没有可用快照"
            }
            return "当前 Widget 数据不可信，建议先修复"
        }
    }

    private static func summary(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> String {
        switch overallSeverity(
            diagnostics: diagnostics,
            widgetTrust: widgetTrust,
            repositories: repositories
        ) {
        case .normal:
            let repoSummary = repositories.isEmpty ? "当前快照里还没有仓库" : "当前快照包含 \(repositories.count) 个仓库"
            return "\(repoSummary)，且共享快照存在、可读、可写、可解码，Widget 看到的数据仍在可信时间窗内。"
        case .warning:
            if isInitialSnapshotMissing(
                diagnostics: diagnostics,
                repositories: repositories
            ) {
                return "共享快照还没有生成，Widget 当前正等待首次刷新；这是首次启动或清空快照后的正常待初始化状态。"
            }
            switch widgetTrust.state {
            case .stale, .expired:
                return "\(WidgetRefreshCopy.waitingRefreshDetail(from: widgetTrust))。共享链路基本正常，但你应先刷新后再判断 Widget 里的仓库状态。"
            case .unknown, .failed:
                return "当前还无法确认 Widget 数据是否已经追上主 App。先查看 Diagnostics，再决定是否需要重写共享快照。"
            case .fresh:
                return widgetTrust.detail + "。共享链路基本正常，但你应先刷新后再判断 Widget 里的仓库状态。"
            }
        case .error:
            if !diagnostics.appGroupAvailable {
                return "主 App 还拿不到共享容器，Widget 无法和 App 对齐同一份数据。"
            }
            if !diagnostics.snapshotExists {
                if repositories.isEmpty {
                    return "共享快照还没有生成，Widget 现在没有可验证的数据来源。"
                }
                return "主界面已经拿到扫描结果，但还没有写出 Widget 可读快照。先刷新数据，把当前结果共享给 Widget。"
            }
            if !diagnostics.snapshotReadable || diagnostics.sharedDataReadError != nil {
                return "主 App 读不回共享快照，当前无法确认 Widget 正在显示什么数据。"
            }
            if !diagnostics.snapshotWritable || diagnostics.sharedDataWriteError != nil {
                return "主 App 无法重写共享快照，所以你不能相信 Widget 会跟上新的扫描结果。"
            }
            if !diagnostics.snapshotDecodable {
                return "共享快照存在但无法解码，Widget 数据来源已经损坏或 schema 不一致。"
            }
            if let widgetSnapshotReadError = diagnostics.widgetSnapshotReadError {
                return "Widget 侧读取共享快照失败：\(widgetSnapshotReadError)"
            }
            return diagnostics.validationIssues.first
                ?? "主 App、共享快照和 Widget 之间出现不一致，当前状态需要先修复后再判断。"
        }
    }

    private static func nextSteps(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> [String] {
        if !diagnostics.appGroupAvailable {
            return [
                "先检查 DevPulse 与 Widget Extension 是否使用同一个 Team 和 `group.local.devpulse`。",
                "修正 Signing / App Group 后执行 Refresh Data，确认共享容器路径重新出现。",
                "如果仍然不可用，清理构建目录并重装 App。"
            ]
        }

        if !diagnostics.snapshotExists {
            if repositories.isEmpty {
                return [
                    "先执行一次 Rescan Now，让主 App 重新发现仓库并生成共享快照。",
                    "如果还是缺失，检查扫描目录是否指向真实仓库根目录。",
                    "若目录正常但快照仍未生成，再检查 App Group / Signing。"
                ]
            }
            return [
                "先执行 Refresh Data，把当前扫描结果写入共享快照。",
                "如果仍未生成，再检查 Diagnostics 里的 shared write、widget snapshot 和 App Group 状态。",
                "如仍异常，再执行一次重新扫描确认仓库结果能否稳定写入。"
            ]
        }

        if !diagnostics.snapshotReadable || diagnostics.sharedDataReadError != nil {
            return [
                "执行 Refresh Data，再看 shared read 是否恢复成功。",
                "如果仍然读取失败，检查 App Group 容器路径与签名是否一致。",
                "必要时清理构建目录并重装 App，让共享容器重新建立。"
            ]
        }

        if !diagnostics.snapshotWritable || diagnostics.sharedDataWriteError != nil {
            return [
                "先执行 Refresh Data，确认主 App 能重新写入共享快照。",
                "如果写入仍失败，检查 App Group entitlement、签名和容器写权限。",
                "必要时清理构建目录并重装 App。"
            ]
        }

        if !diagnostics.snapshotDecodable {
            return [
                "先执行 Refresh Data，让当前版本的 App 重写共享快照。",
                "如果仍无法解码，清理构建目录并同时重建 App 与 Widget。",
                "确认 App 与 Widget 使用同一份 schema 后再重新扫描。"
            ]
        }

        if let widgetSnapshotReadError = diagnostics.widgetSnapshotReadError, !widgetSnapshotReadError.isEmpty {
            return [
                "先执行 Refresh Data，确认 shared write 和 reload requested 都更新成功。",
                "如果 Widget 仍然读取失败，移除桌面上的旧 Widget 后重新添加。",
                "如仍异常，再检查 Signing / App Group 并清理构建目录。"
            ]
        }

        if !diagnostics.validationIssues.isEmpty {
            return [
                "先对照 shared write、widget snapshot 和 reload requested 的时间，确认链路在哪一步断开。",
                "执行 Refresh Data，观察一致性错误是否消失。",
                "如果仍不一致，移除旧 Widget 并重新添加，再重新扫描确认。"
            ]
        }

        switch widgetTrust.state {
        case .fresh:
            return ["当前可以信任 Widget 数据；如果桌面没有立即变化，等待 macOS 刷新时间线即可。"]
        case .stale, .expired:
            return [
                "Widget 当前正等待刷新；先执行 Refresh Data，再重新判断仓库状态。",
                "如果刷新后仍然过期，检查 Widget reload requested 是否更新。",
                "如桌面仍不变，可移除旧 Widget 后重新添加。"
            ]
        case .unknown, .failed:
            return [
                "先执行 Refresh Data，补齐 generatedAt / writtenAt 与 reload requested。",
                "如果仍无法确认，再检查 Diagnostics 中的共享快照与 Widget 读取结果。",
                "必要时清理构建目录并重建 App 与 Widget。"
            ]
        }
    }

    private static func primaryAction(
        diagnostics: DiagnosticsSnapshot,
        widgetTrust: SnapshotTrustAssessment,
        repositories: [RepositorySnapshot]
    ) -> WidgetDataTrustPrimaryAction {
        if !diagnostics.appGroupAvailable {
            return WidgetDataTrustPrimaryAction(
                kind: .viewDiagnostics,
                title: "查看诊断",
                systemImage: "stethoscope",
                helpText: "先看 Diagnostics，确认 App Group、签名和共享容器路径。"
            )
        }

        if !diagnostics.snapshotExists {
            if !repositories.isEmpty {
                return WidgetDataTrustPrimaryAction(
                    kind: .refreshData,
                    title: "Refresh Data",
                    systemImage: "arrow.clockwise",
                    helpText: "先把当前扫描结果写入共享快照，再确认 Widget 能否读到。"
                )
            }
            return WidgetDataTrustPrimaryAction(
                kind: .rescan,
                title: "Rescan Now",
                systemImage: "arrow.triangle.2.circlepath",
                helpText: "先重新发现仓库并生成共享快照。"
            )
        }

        if !diagnostics.snapshotReadable || diagnostics.sharedDataReadError != nil {
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "重试读取共享快照，并确认主 App 能读回最新数据。"
            )
        }

        if !diagnostics.snapshotWritable || diagnostics.sharedDataWriteError != nil {
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "重写共享快照并再次请求 Widget 更新时间线。"
            )
        }

        if !diagnostics.snapshotDecodable {
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "让当前版本的 App 重写共享快照，恢复可解码状态。"
            )
        }

        if let widgetSnapshotReadError = diagnostics.widgetSnapshotReadError, !widgetSnapshotReadError.isEmpty {
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "先重写共享快照，再确认 Widget reload 和读取状态。"
            )
        }

        if !diagnostics.validationIssues.isEmpty {
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "先刷新链路，再确认 shared write、widget snapshot 和 reload requested 是否恢复一致。"
            )
        }

        switch widgetTrust.state {
        case .fresh:
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "手动重写共享快照并请求 Widget 更新时间线。"
            )
        case .stale, .expired:
            return WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "Refresh Data",
                systemImage: "arrow.clockwise",
                helpText: "共享链路正常，但当前数据已经过旧，先刷新再判断。"
            )
        case .unknown, .failed:
            return WidgetDataTrustPrimaryAction(
                kind: .viewDiagnostics,
                title: "查看诊断",
                systemImage: "stethoscope",
                helpText: "先看 Diagnostics，确认 generatedAt / writtenAt、共享快照和 Widget 读取结果。"
            )
        }
    }

    private static func severity(for state: SnapshotTrustState) -> DiagnosticsSeverity {
        switch state {
        case .fresh:
            return .normal
        case .stale, .expired, .unknown:
            return .warning
        case .failed:
            return .error
        }
    }

    private static func freshnessLabel(for widgetTrust: SnapshotTrustAssessment) -> String {
        switch widgetTrust.state {
        case .fresh:
            return widgetTrust.title
        case .stale, .expired:
            return WidgetRefreshCopy.waitingRefreshTitle
        case .unknown, .failed:
            return WidgetRefreshCopy.pendingConfirmationTitle
        }
    }

    private static func isInitialSnapshotMissing(
        diagnostics: DiagnosticsSnapshot,
        repositories: [RepositorySnapshot]
    ) -> Bool {
        diagnostics.appGroupAvailable
            && !diagnostics.snapshotExists
            && repositories.isEmpty
            && diagnostics.sharedDataReadError == nil
            && diagnostics.sharedDataWriteError == nil
            && diagnostics.lastSharedWriteAt == nil
            && diagnostics.sharedDataSnapshot == nil
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Shared store errors

enum AppGroupStoreError: LocalizedError, Equatable {
    case appGroupUnavailable
    case snapshotMissing
    case schemaVersionMismatch(expected: Int, actual: Int)
    case readFailed(String)
    case decodeFailed(String)
    case writeFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group container is unavailable."
        case .snapshotMissing:
            return "Shared snapshot file is missing."
        case .schemaVersionMismatch(let expected, let actual):
            return "Shared snapshot schema mismatch. Expected v\(expected), found v\(actual)."
        case .readFailed(let reason):
            return "Failed to read shared snapshot: \(reason)"
        case .decodeFailed(let reason):
            return "Failed to decode shared snapshot: \(reason)"
        case .writeFailed(let reason):
            return "Failed to write shared snapshot: \(reason)"
        case .verificationFailed(let reason):
            return "Shared snapshot verification failed: \(reason)"
        }
    }
}

// MARK: - Scan-location toggle

struct ScanLocationToggle: Identifiable, Codable {
    let id: String
    let path: String
    var isEnabled: Bool
    let isBuiltIn: Bool
}

// MARK: - Custom scan directory

struct ScanLocationConfiguration: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    var enabledBuiltInPaths: Set<String>
    var customDirectories: [CustomScanDirectory]

    init(version: Int = ScanLocationConfiguration.currentVersion,
         enabledBuiltInPaths: Set<String>,
         customDirectories: [CustomScanDirectory]) {
        self.version = version
        self.enabledBuiltInPaths = enabledBuiltInPaths
        self.customDirectories = customDirectories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        enabledBuiltInPaths = try container.decodeIfPresent(Set<String>.self, forKey: .enabledBuiltInPaths) ?? []
        customDirectories = try container.decodeIfPresent([CustomScanDirectory].self, forKey: .customDirectories) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case enabledBuiltInPaths
        case customDirectories
    }
}

struct CustomScanDirectory: Identifiable, Codable, Equatable {
    let id: String
    let path: String
    let bookmarkData: Data?

    init(id: String = UUID().uuidString, path: String, bookmarkData: Data? = nil) {
        self.id = id
        self.path = path
        self.bookmarkData = bookmarkData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPath = try container.decode(String.self, forKey: .path)
        path = decodedPath
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? RepositoryIdentity.id(for: decodedPath)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case bookmarkData
    }
}

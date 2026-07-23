import Foundation
import CryptoKit

// MARK: - Schema constants

enum RepositoryHistorySchema {
    static let version = 1
    static let oldestMigratableVersion = 1
}

// MARK: - History entry kind

enum HistoryEntryKind: String, Codable, Equatable, Sendable {
    /// Regular periodic state recording (no meaningful change from previous)
    case scanRecord
    /// Notable state change detected (branch switch, new commits, conflict, etc.)
    case stateChange
    /// Recovery from a read failure or unavailable state
    case recovery
    /// Repository was discovered for the first time
    case firstSeen
    /// Repository became unavailable or scan failed
    case becameUnavailable
    /// Health trend summary record (aggregated)
    case summary

    var priority: Int {
        switch self {
        case .firstSeen: return 0
        case .stateChange: return 1
        case .becameUnavailable: return 2
        case .recovery: return 3
        case .scanRecord: return 4
        case .summary: return 5
        }
    }

    var title: String {
        switch self {
        case .scanRecord: return "定期记录"
        case .stateChange: return "状态变化"
        case .recovery: return "恢复"
        case .firstSeen: return "首次发现"
        case .becameUnavailable: return "不可访问"
        case .summary: return "汇总"
        }
    }
}

// MARK: - History state point

/// Compact snapshot of repository state at a point in time, stored in history.
struct HistoryStatePoint: Codable, Equatable, Sendable {
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
    let risk: RiskLevel
    let dataSource: RepositoryDataSource
    let changedFileCount: Int
    let lastCommitID: String?
    let errorMessage: String?

    init(snapshot: RepositorySnapshot) {
        self.branch = snapshot.branch
        self.status = snapshot.status
        self.modifiedFileCount = snapshot.modifiedFileCount
        self.addedFileCount = snapshot.addedFileCount
        self.deletedFileCount = snapshot.deletedFileCount
        self.untrackedFileCount = snapshot.untrackedFileCount
        self.stagedFileCount = snapshot.stagedFileCount
        self.unstagedFileCount = snapshot.unstagedFileCount
        self.conflictedFileCount = snapshot.conflictedFileCount
        self.aheadCount = snapshot.aheadCount
        self.behindCount = snapshot.behindCount
        self.hasUpstream = snapshot.hasUpstream
        self.risk = snapshot.risk
        self.dataSource = snapshot.resolvedDataSource
        self.changedFileCount = snapshot.changedFileCount
        self.lastCommitID = snapshot.lastCommitID
        self.errorMessage = snapshot.errorMessage
    }

    /// Returns true when this point is meaningfully different from another,
    /// ignoring fields that are inherently transient or unstable between scans.
    func isMeaningfullyDifferent(from other: HistoryStatePoint) -> Bool {
        branch != other.branch
            || status != other.status
            || changedFileCount != other.changedFileCount
            || conflictedFileCount != other.conflictedFileCount
            || aheadCount != other.aheadCount
            || behindCount != other.behindCount
            || hasUpstream != other.hasUpstream
            || risk != other.risk
            || dataSource != other.dataSource
            || lastCommitID != other.lastCommitID
            || errorMessage != other.errorMessage
    }
}

// MARK: - History entry

struct RepositoryHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let repositoryID: String
    let recordedAt: String      // ISO8601
    let kind: HistoryEntryKind
    let state: HistoryStatePoint

    init(repositoryID: String,
         recordedAt: String,
         kind: HistoryEntryKind,
         state: HistoryStatePoint) {
        let identity = [
            repositoryID,
            recordedAt,
            kind.rawValue,
            state.branch,
            state.lastCommitID ?? "nil",
            "\(state.changedFileCount)"
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        id = "history-v1-\(digest)"
        self.repositoryID = repositoryID
        self.recordedAt = recordedAt
        self.kind = kind
        self.state = state
    }

    static func == (lhs: RepositoryHistoryEntry, rhs: RepositoryHistoryEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.repositoryID == rhs.repositoryID
            && lhs.recordedAt == rhs.recordedAt
            && lhs.kind == rhs.kind
            && lhs.state == rhs.state
    }
}

// MARK: - Archive format

struct RepositoryHistoryArchive: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var entries: [RepositoryHistoryEntry]

    init(schemaVersion: Int = Self.currentSchemaVersion,
         entries: [RepositoryHistoryEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? 0
        let entries = try container.decode([RepositoryHistoryEntry].self, forKey: .entries)
        self.init(schemaVersion: schemaVersion, entries: entries)
    }
}

// MARK: - Entry kind determination

enum HistoryEntryKindClassifier {
    /// Classify what kind of entry to create based on state comparison.
    static func classify(
        previous: HistoryStatePoint?,
        current: HistoryStatePoint,
        lastDataSource: RepositoryDataSource?,
        currentDataSource: RepositoryDataSource
    ) -> HistoryEntryKind {
        guard let previous else {
            return .firstSeen
        }

        // Transition from unavailable/unknown → readable
        let wasReadable = lastDataSource == .current || lastDataSource == nil
        let isReadable = currentDataSource == .current
        if !wasReadable, isReadable {
            return .recovery
        }

        // Transition from readable → unavailable
        if wasReadable, !isReadable {
            return .becameUnavailable
        }

        // Still unavailable — check if error message changed
        if !isReadable, previous.errorMessage != current.errorMessage {
            return .stateChange
        }

        // Meaningful state change
        if current.isMeaningfullyDifferent(from: previous) {
            return .stateChange
        }

        return .scanRecord
    }
}

// MARK: - History diagnostics

struct HistoryDiagnosticsSnapshot: Codable, Equatable, Sendable {
    var totalEntriesWritten: Int         // Cumulative
    var totalDedupSkipped: Int           // Cumulative
    var totalCompactionRuns: Int         // Cumulative
    var totalEntriesPurged: Int          // Cumulative
    var lastCompactionDurationMs: Double
    var currentEntryCount: Int
    var storageFileSizeBytes: Int
    var totalRepositoryCount: Int
    var entriesPerRepositoryStats: [String: Int]
    var lastMigrationVersion: Int?
    var lastMigrationSuccess: Bool?
    var lastRecoveryCount: Int?
    var compactionFailedCount: Int?

    static func empty() -> HistoryDiagnosticsSnapshot {
        HistoryDiagnosticsSnapshot(
            totalEntriesWritten: 0,
            totalDedupSkipped: 0,
            totalCompactionRuns: 0,
            totalEntriesPurged: 0,
            lastCompactionDurationMs: 0,
            currentEntryCount: 0,
            storageFileSizeBytes: 0,
            totalRepositoryCount: 0,
            entriesPerRepositoryStats: [:],
            lastMigrationVersion: nil,
            lastMigrationSuccess: nil,
            lastRecoveryCount: nil,
            compactionFailedCount: nil
        )
    }
}

// MARK: - History store error

enum HistoryStoreError: LocalizedError, Equatable {
    case readFailed(String)
    case writeFailed(String)
    case compactionFailed(String)
    case schemaMismatch(expected: Int, actual: Int)
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let reason):
            return "历史记录读取失败：\(reason)"
        case .writeFailed(let reason):
            return "历史记录写入失败：\(reason)"
        case .compactionFailed(let reason):
            return "历史记录压缩失败：\(reason)"
        case .schemaMismatch(let expected, let actual):
            return "历史记录 schema v\(actual) 不兼容，期望 v\(expected)"
        case .migrationFailed(let reason):
            return "历史记录迁移失败：\(reason)"
        }
    }
}

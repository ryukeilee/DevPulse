import CryptoKit
import Foundation

// MARK: - Schema

enum BackupSchema {
    static let currentVersion = 1
    static let oldestCompatibleVersion = 1
}

// MARK: - Backup file layout

/// Backup is stored as a directory:
/// ```
/// DevPulseBackup_2026-07-24_120000/
/// ├── manifest.json
/// ├── entries/
/// │   ├── repositories.json
/// │   ├── pending-items.json
/// │   ├── ...
/// └── checksums.sha256
/// ```
enum BackupFileLayout {
    static let manifestFileName = "manifest.json"
    static let entriesDirectoryName = "entries"
    static let checksumsFileName = "checksums.sha256"
    static let backupPrefix = "DevPulseBackup_"

    static func backupDirectoryName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return backupPrefix + formatter.string(from: date)
    }
}

// MARK: - Backup store types

enum BackupStoreType: String, Codable, Sendable, CaseIterable {
    case repositorySnapshot
    case pendingItems
    case pendingItemNotifications
    case repositoryHistory
    case changeImpact
    case workspaces
    case scanConfig
    case scanLocations
    case ignoredRepositories
    case listPreferences
    case launchAtLogin
    case performanceBaselines
    case baselineConfig

    var displayName: String {
        switch self {
        case .repositorySnapshot: return "仓库快照"
        case .pendingItems: return "待处理事项"
        case .pendingItemNotifications: return "通知状态"
        case .repositoryHistory: return "仓库历史"
        case .changeImpact: return "变更影响分析"
        case .workspaces: return "工作空间"
        case .scanConfig: return "扫描配置"
        case .scanLocations: return "扫描目录"
        case .ignoredRepositories: return "忽略的仓库"
        case .listPreferences: return "列表偏好"
        case .launchAtLogin: return "登录启动"
        case .performanceBaselines: return "性能基线"
        case .baselineConfig: return "基线配置"
        }
    }

    var entryFileName: String {
        switch self {
        case .repositorySnapshot: return "repositories.json"
        case .pendingItems: return "pending-items.json"
        case .pendingItemNotifications: return "pending-item-notifications.json"
        case .repositoryHistory: return "repository-history.json"
        case .changeImpact: return "change-impact.json"
        case .workspaces: return "workspaces.json"
        case .scanConfig: return "scan-config.json"
        case .scanLocations: return "scan-locations.json"
        case .ignoredRepositories: return "ignored-repositories.json"
        case .listPreferences: return "list-preferences.json"
        case .launchAtLogin: return "launch-at-login.json"
        case .performanceBaselines: return "performance-baselines.json"
        case .baselineConfig: return "baseline-config.json"
        }
    }
}

// MARK: - Backup entry info

struct BackupEntryInfo: Codable, Equatable {
    let id: String
    let storeType: BackupStoreType
    let schemaVersion: Int
    let dataHash: String
    let compressedSizeBytes: Int64
    let uncompressedSizeBytes: Int64
    let entryCreatedAt: String

    init(
        storeType: BackupStoreType,
        schemaVersion: Int,
        dataHash: String,
        compressedSizeBytes: Int64,
        uncompressedSizeBytes: Int64,
        entryCreatedAt: String
    ) {
        self.id = "\(storeType.rawValue)-\(dataHash.prefix(12))"
        self.storeType = storeType
        self.schemaVersion = schemaVersion
        self.dataHash = dataHash
        self.compressedSizeBytes = compressedSizeBytes
        self.uncompressedSizeBytes = uncompressedSizeBytes
        self.entryCreatedAt = entryCreatedAt
    }
}

// MARK: - Content inventory

struct BackupContentInventory: Codable, Equatable {
    let entries: [String: BackupEntryInfo]
    let entryOrder: [String]
    let totalEntryCount: Int
    let totalPayloadSizeBytes: Int64

    init(entries: [BackupEntryInfo]) {
        var map: [String: BackupEntryInfo] = [:]
        var order: [String] = []
        var totalSize: Int64 = 0
        for entry in entries.sorted(by: { $0.storeType.rawValue < $1.storeType.rawValue }) {
            map[entry.id] = entry
            order.append(entry.id)
            totalSize += entry.compressedSizeBytes
        }
        self.entries = map
        self.entryOrder = order
        self.totalEntryCount = entries.count
        self.totalPayloadSizeBytes = totalSize
    }
}

// MARK: - Backup metadata

struct BackupMetadata: Codable, Equatable {
    var deviceName: String
    let systemVersion: String
    let appVersion: String
    let notes: String?
}

// MARK: - Backup manifest

struct BackupManifest: Codable, Equatable {
    let schemaVersion: Int
    let backupVersion: String
    let createdAt: String
    let appVersion: String
    let appBuildNumber: String?
    let contentHash: String
    let content: BackupContentInventory
    var metadata: BackupMetadata
    let isIncremental: Bool
    let parentBackupID: String?

    init(
        schemaVersion: Int = BackupSchema.currentVersion,
        backupVersion: String,
        createdAt: String,
        appVersion: String,
        appBuildNumber: String?,
        contentHash: String,
        content: BackupContentInventory,
        metadata: BackupMetadata,
        isIncremental: Bool,
        parentBackupID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.backupVersion = backupVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.appBuildNumber = appBuildNumber
        self.contentHash = contentHash
        self.content = content
        self.metadata = metadata
        self.isIncremental = isIncremental
        self.parentBackupID = parentBackupID
    }
}

// MARK: - Privacy configuration

struct BackupPrivacyConfiguration: Codable, Equatable, Sendable {
    var stripAbsolutePaths: Bool
    var stripUserNames: Bool
    var stripTempData: Bool
    var stripDiagnosticData: Bool
    var anonymizeDeviceName: Bool

    static let sanitized = BackupPrivacyConfiguration(
        stripAbsolutePaths: true,
        stripUserNames: true,
        stripTempData: true,
        stripDiagnosticData: true,
        anonymizeDeviceName: true
    )

    static let full = BackupPrivacyConfiguration(
        stripAbsolutePaths: false,
        stripUserNames: false,
        stripTempData: false,
        stripDiagnosticData: false,
        anonymizeDeviceName: false
    )
}

enum BackupPrivacyMode: String, Codable, Sendable {
    case standard
    case full
    case custom

    var configuration: BackupPrivacyConfiguration {
        switch self {
        case .standard: return .sanitized
        case .full: return .full
        case .custom: return .sanitized
        }
    }
}

// MARK: - Retention configuration

struct BackupRetentionConfiguration: Codable, Equatable, Sendable {
    var maxBackupCount: Int
    var maxTotalSizeBytes: Int64
    var minimumFreeSpaceBytes: Int64
    var retentionDays: Int
    var autoBackupIntervalSeconds: TimeInterval

    static let `default` = BackupRetentionConfiguration(
        maxBackupCount: 10,
        maxTotalSizeBytes: 500 * 1024 * 1024,
        minimumFreeSpaceBytes: 100 * 1024 * 1024,
        retentionDays: 30,
        autoBackupIntervalSeconds: 86400
    )
}

// MARK: - Integration configuration

struct BackupIntegrationConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var autoBackupEnabled: Bool
    var privacyMode: BackupPrivacyMode
    var retention: BackupRetentionConfiguration
    var backupDirectory: String

    static let `default` = BackupIntegrationConfiguration(
        enabled: true,
        autoBackupEnabled: true,
        privacyMode: .standard,
        retention: .default,
        backupDirectory: "~/Library/Application Support/local.devpulse.app/Backups"
    )
}

// MARK: - Backup summary (for listing)

struct BackupSummary: Identifiable, Equatable {
    let id: String
    let createdAt: Date
    let appVersion: String
    let backupVersion: Int
    let isIncremental: Bool
    let parentBackupID: String?
    let entryCount: Int
    let totalSizeBytes: Int64
    let contentHash: String
    let integrityVerified: Bool
    let integrityError: String?
    let isCompatible: Bool
    let storedAt: String
}

struct BackupDirectoryListing: Equatable {
    let backups: [BackupSummary]
    let retentionConfig: BackupRetentionConfiguration
    let totalBackupSizeBytes: Int64
    let freeSpaceBytes: Int64
}

// MARK: - Restore conflict types

enum RestoreConflictType: String, Codable, Sendable {
    case repositoryPathChanged
    case workspaceIdentityChanged
    case linkedWorktreeRecreated
    case duplicateRepositoryName
    case deviceUserNameDifferent
    case schemaVersionMismatch
    case dataHashMismatch
    case storeMissingInBackup
    case storeMissingInCurrent

    var displayName: String {
        switch self {
        case .repositoryPathChanged: return "仓库路径变化"
        case .workspaceIdentityChanged: return "工作空间身份变化"
        case .linkedWorktreeRecreated: return "Linked worktree 重建"
        case .duplicateRepositoryName: return "同名仓库"
        case .deviceUserNameDifferent: return "设备用户名不同"
        case .schemaVersionMismatch: return "Schema 版本不匹配"
        case .dataHashMismatch: return "数据哈希不一致"
        case .storeMissingInBackup: return "备份缺少该存储"
        case .storeMissingInCurrent: return "当前缺少该存储"
        }
    }
}

enum RestoreConflictResolution: String, Codable, Sendable {
    case useBackupVersion
    case useExistingVersion
    case merge
    case skip
    case userDecide

    var displayName: String {
        switch self {
        case .useBackupVersion: return "使用备份版本"
        case .useExistingVersion: return "保留当前版本"
        case .merge: return "合并"
        case .skip: return "跳过"
        case .userDecide: return "用户决定"
        }
    }
}

struct RestoreConflict: Codable, Equatable, Identifiable {
    let id: String
    let storeType: BackupStoreType
    let conflictType: RestoreConflictType
    let description: String
    let resolution: RestoreConflictResolution?

    var displayDescription: String {
        var desc = "[\(storeType.displayName)] \(conflictType.displayName)"
        if let resolution {
            desc += " → \(resolution.displayName)"
        }
        return desc
    }
}

// MARK: - Restore precheck result

struct RestorePrecheckResult: Equatable {
    let backupID: String
    let backupVersion: Int
    let isCompatible: Bool
    let incompatibleReason: String?
    let entriesToCreate: [String]
    let entriesToOverwrite: [String]
    let entriesToMerge: [String]
    let entriesToSkip: [String]
    let entriesInConflict: [String: [RestoreConflict]]
    let totalEntriesInBackup: Int
    let targetDeviceName: String?
    let sourceDeviceName: String?
    let requiresMigration: Bool
    let migrationDescription: String?
}

// MARK: - Restore phase

enum RestorePhase: String, Codable, Sendable {
    case precheck
    case snapshotExisting
    case writing
    case verifying
    case completed
    case failed
    case rolledBack
}

// MARK: - Restore transaction state

/// Persisted before any data modification. If the process crashes or is
/// cancelled, the rollback can recover all original files.
struct RestoreTransactionState: Codable, Equatable {
    let backupID: String
    let startedAt: String
    var phase: RestorePhase
    let snapshotDir: String
    var completedEntries: [String]
    var failedEntries: [String: String]
    var hasRolledBack: Bool

    init(
        backupID: String,
        startedAt: String,
        phase: RestorePhase,
        snapshotDir: String,
        completedEntries: [String] = [],
        failedEntries: [String: String] = [:],
        hasRolledBack: Bool = false
    ) {
        self.backupID = backupID
        self.startedAt = startedAt
        self.phase = phase
        self.snapshotDir = snapshotDir
        self.completedEntries = completedEntries
        self.failedEntries = failedEntries
        self.hasRolledBack = hasRolledBack
    }
}

// MARK: - Backup manager errors

enum BackupManagerError: LocalizedError, Equatable {
    case backupInProgress
    case backupNotFound(String)
    case backupCorrupted(String)
    case backupIncompatible(version: Int, expected: Int)
    case restoreInProgress
    case storageFull(available: Int64, needed: Int64)
    case permissionDenied(String)
    case serializationFailed(String)
    case deserializationFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case ioError(String)
    case storeUnavailable(String)
    case migrationRequired(from: Int, to: Int)
    case restoreRollbackRequired(reason: String)
    case lockFailed(String)
    case cancelled
    case manifestMissing(String)
    case entryMissing(String)
    case privacyFilterFailed(String)
    case retentionCullFailed(String)

    var errorDescription: String? {
        switch self {
        case .backupInProgress:
            return "备份正在进行中"
        case .backupNotFound(let id):
            return "备份未找到：\(id)"
        case .backupCorrupted(let detail):
            return "备份已损坏：\(detail)"
        case .backupIncompatible(let version, let expected):
            return "备份版本 v\(version) 不兼容，期望 v\(expected)"
        case .restoreInProgress:
            return "恢复正在进行中"
        case .storageFull(let available, let needed):
            let availMB = available / 1_048_576
            let needMB = needed / 1_048_576
            return "磁盘空间不足：可用 \(availMB) MB，需要 \(needMB) MB"
        case .permissionDenied(let path):
            return "权限不足：\(path)"
        case .serializationFailed(let detail):
            return "序列化失败：\(detail)"
        case .deserializationFailed(let detail):
            return "反序列化失败：\(detail)"
        case .checksumMismatch(let expected, let actual):
            return "校验和不匹配：期望 \(expected)，实际 \(actual)"
        case .ioError(let detail):
            return "IO 错误：\(detail)"
        case .storeUnavailable(let name):
            return "存储不可用：\(name)"
        case .migrationRequired(let from, let to):
            return "需要迁移：v\(from) → v\(to)"
        case .restoreRollbackRequired(let reason):
            return "需要回滚：\(reason)"
        case .lockFailed(let detail):
            return "锁失败：\(detail)"
        case .cancelled:
            return "操作已取消"
        case .manifestMissing(let id):
            return "备份清单缺失：\(id)"
        case .entryMissing(let name):
            return "备份条目缺失：\(name)"
        case .privacyFilterFailed(let detail):
            return "隐私过滤失败：\(detail)"
        case .retentionCullFailed(let detail):
            return "保留策略清理失败：\(detail)"
        }
    }
}

// MARK: - Integrity verification

struct BackupIntegrityResult: Equatable {
    let backupID: String
    let manifestValid: Bool
    let checksumsValid: Bool
    let allEntriesPresent: Bool
    let entryChecksumsMatch: Bool
    let overallIntegrity: Bool
    let errors: [String]
    let warnings: [String]

    static func valid(backupID: String) -> BackupIntegrityResult {
        BackupIntegrityResult(
            backupID: backupID,
            manifestValid: true,
            checksumsValid: true,
            allEntriesPresent: true,
            entryChecksumsMatch: true,
            overallIntegrity: true,
            errors: [],
            warnings: []
        )
    }
}

// MARK: - Diff preview item

struct RestoreDiffItem: Equatable, Identifiable {
    let id: String
    let storeType: BackupStoreType
    let action: RestoreDiffAction
    let backupEntryInfo: BackupEntryInfo?
    let currentSchemaVersion: Int?
    let backupSchemaVersion: Int?
    let detail: String?
}

enum RestoreDiffAction: String, Codable, Sendable {
    case create
    case overwrite
    case merge
    case skip
    case conflict
}

// MARK: - Compute content hash

extension BackupManifest {
    static func computeContentHash(entryHashes: [String: String]) -> String {
        let combined = entryHashes.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Free space helper

enum BackupFreeSpace {
    /// Get available free space at a directory path, or nil if it cannot be determined.
    static func availableBytes(at url: URL) -> Int64? {
        do {
            let resourceKeys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
            let values = try url.resourceValues(forKeys: resourceKeys)
            if let freeSpace = values.allValues[URLResourceKey.volumeAvailableCapacityForImportantUsageKey] as? Int64 {
                return freeSpace
            }
            // Fallback: use FileManager
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
            if let freeSize = attrs[FileAttributeKey.systemFreeSize] as? NSNumber {
                return freeSize.int64Value
            }
            return nil
        } catch {
            return nil
        }
    }
}

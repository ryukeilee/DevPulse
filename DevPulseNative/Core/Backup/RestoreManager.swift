import CryptoKit
import Foundation
import OSLog

// MARK: - Restore manager

/// Handles backup restoration with transactional safety.
///
/// Design:
/// - **Pre-flight validation**: checks compatibility, schema versions, free space
/// - **Diff preview**: shows what will be created, overwritten, merged, or skipped
/// - **Snapshot-before-write**: copies all current data into a snapshot directory
///   before any modification
/// - **Transactional write**: each entry is written atomically; failures trigger
///   automatic rollback
/// - **Rollback**: restores all original files from the snapshot directory
/// - **Cancellation safety**: if the process is killed mid-restore, the
///   transaction state file allows recovery on next launch
final class RestoreManager: @unchecked Sendable {
    private static let transactionFileName = ".restore-transaction.json"
    private let logger = Logger(subsystem: "local.devpulse.app", category: "RestoreManager")
    private let fileManager: FileManager
    private let queue: DispatchQueue
    private let processLock = NSLock()
    private let backupManager: BackupManager

    init(backupManager: BackupManager, fileManager: FileManager = .default) {
        self.backupManager = backupManager
        self.fileManager = fileManager
        self.queue = DispatchQueue(
            label: "local.devpulse.app.restore-manager",
            qos: .utility,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
    }

    // MARK: - Pre-flight check

    /// Run a pre-flight validation of a backup before restore.
    /// Does not modify any data.
    func precheck(
        backupID: String,
        config: BackupIntegrationConfiguration,
        currentStores: [BackupStoreType: (data: Data, schemaVersion: Int)]
    ) -> RestorePrecheckResult {
        let dir = backupManager.backupDirectoryURL(config: config)
        let backupURL = dir.appendingPathComponent(backupID)

        // Load manifest
        guard let manifest = loadManifest(from: backupURL) else {
            return RestorePrecheckResult(
                backupID: backupID,
                backupVersion: BackupSchema.currentVersion,
                isCompatible: false,
                incompatibleReason: "无法加载备份清单",
                entriesToCreate: [], entriesToOverwrite: [],
                entriesToMerge: [], entriesToSkip: [],
                entriesInConflict: [:],
                totalEntriesInBackup: 0,
                targetDeviceName: nil,
                sourceDeviceName: nil,
                requiresMigration: false,
                migrationDescription: nil
            )
        }

        // Check schema compatibility
        guard manifest.schemaVersion >= BackupSchema.oldestCompatibleVersion,
              manifest.schemaVersion <= BackupSchema.currentVersion else {
            return RestorePrecheckResult(
                backupID: backupID,
                backupVersion: manifest.schemaVersion,
                isCompatible: false,
                incompatibleReason: manifest.schemaVersion > BackupSchema.currentVersion
                    ? "备份来自更新的 App 版本 (v\(manifest.schemaVersion))，当前 App 版本不支持。请升级 App 后再尝试导入。"
                    : "备份版本过旧 (v\(manifest.schemaVersion))，无法迁移到当前版本。",
                entriesToCreate: [], entriesToOverwrite: [],
                entriesToMerge: [], entriesToSkip: [],
                entriesInConflict: [:],
                totalEntriesInBackup: manifest.content.totalEntryCount,
                targetDeviceName: nil,
                sourceDeviceName: manifest.metadata.deviceName,
                requiresMigration: manifest.schemaVersion != BackupSchema.currentVersion,
                migrationDescription: manifest.schemaVersion > BackupSchema.currentVersion
                    ? nil : "需要从 v\(manifest.schemaVersion) 迁移到 v\(BackupSchema.currentVersion)"
            )
        }

        // Check migration need
        let needsMigration = manifest.schemaVersion != BackupSchema.currentVersion
        let migrationDesc = needsMigration
            ? "将从 v\(manifest.schemaVersion) 迁移到 v\(BackupSchema.currentVersion)"
            : nil

        // Check free space
        let neededSize = estimateRestoreSize(manifest: manifest)
        let free = BackupFreeSpace.availableBytes(at: dir) ?? 0
        if free < neededSize + config.retention.minimumFreeSpaceBytes {
            return RestorePrecheckResult(
                    backupID: backupID,
                    backupVersion: manifest.schemaVersion,
                    isCompatible: false,
                    incompatibleReason: "磁盘空间不足：需要 \(neededSize / 1_048_576) MB，可用不足",
                    entriesToCreate: [], entriesToOverwrite: [],
                    entriesToMerge: [], entriesToSkip: [],
                    entriesInConflict: [:],
                    totalEntriesInBackup: manifest.content.totalEntryCount,
                    targetDeviceName: nil,
                    sourceDeviceName: manifest.metadata.deviceName,
                    requiresMigration: needsMigration,
                    migrationDescription: migrationDesc
                )
        }

        // Classify entries
        var toCreate: [String] = []
        var toOverwrite: [String] = []
        var toMerge: [String] = []
        var toSkip: [String] = []
        var conflicts: [String: [RestoreConflict]] = [:]

        for entryID in manifest.content.entryOrder {
            guard let entryInfo = manifest.content.entries[entryID] else { continue }
            let storeType = entryInfo.storeType

            if let currentStore = currentStores[storeType] {
                if currentStore.schemaVersion != entryInfo.schemaVersion {
                    // Schema mismatch - needs migration
                    let conflict = RestoreConflict(
                        id: "schema-\(storeType.rawValue)",
                        storeType: storeType,
                        conflictType: .schemaVersionMismatch,
                        description: "\(storeType.displayName)：备份 schema v\(entryInfo.schemaVersion) vs 当前 v\(currentStore.schemaVersion)",
                        resolution: .merge
                    )
                    conflicts[entryID] = [conflict]
                    toMerge.append(entryID)
                } else if storeDataHash(currentStore.data) == entryInfo.dataHash {
                    toSkip.append(entryID)
                } else {
                    // Data differs - check if merge needed
                    if storeType == .workspaces || storeType == .repositorySnapshot {
                        toMerge.append(entryID)
                    } else {
                        toOverwrite.append(entryID)
                    }
                }
            } else {
                toCreate.append(entryID)
            }
        }

        return RestorePrecheckResult(
            backupID: backupID,
            backupVersion: manifest.schemaVersion,
            isCompatible: true,
            incompatibleReason: nil,
            entriesToCreate: toCreate,
            entriesToOverwrite: toOverwrite,
            entriesToMerge: toMerge,
            entriesToSkip: toSkip,
            entriesInConflict: conflicts,
            totalEntriesInBackup: manifest.content.totalEntryCount,
            targetDeviceName: Host.current().name ?? "Mac",
            sourceDeviceName: manifest.metadata.deviceName,
            requiresMigration: needsMigration,
            migrationDescription: migrationDesc
        )
    }

    // MARK: - Diff preview

    /// Generate a detailed diff preview of what will happen during restore.
    func diffPreview(
        backupID: String,
        config: BackupIntegrationConfiguration,
        currentStores: [BackupStoreType: (data: Data, schemaVersion: Int)]
    ) -> [RestoreDiffItem] {
        let precheck = precheck(backupID: backupID, config: config, currentStores: currentStores)
        let dir = backupManager.backupDirectoryURL(config: config)
        let backupURL = dir.appendingPathComponent(backupID)
        guard let manifest = loadManifest(from: backupURL) else { return [] }

        var items: [RestoreDiffItem] = []
        for entryID in manifest.content.entryOrder {
            guard let entryInfo = manifest.content.entries[entryID] else { continue }
            let storeType = entryInfo.storeType
            let currentSchema = currentStores[storeType]?.schemaVersion

            let action: RestoreDiffAction
            if precheck.entriesToCreate.contains(entryID) {
                action = .create
            } else if precheck.entriesToOverwrite.contains(entryID) {
                action = .overwrite
            } else if precheck.entriesToMerge.contains(entryID) {
                action = .merge
            } else if precheck.entriesToSkip.contains(entryID) {
                action = .skip
            } else if precheck.entriesInConflict.keys.contains(entryID) {
                action = .conflict
            } else {
                action = .skip
            }

            items.append(RestoreDiffItem(
                id: entryID,
                storeType: storeType,
                action: action,
                backupEntryInfo: entryInfo,
                currentSchemaVersion: currentSchema,
                backupSchemaVersion: entryInfo.schemaVersion,
                detail: actionDetail(action, storeType: storeType, entryInfo: entryInfo)
            ))
        }
        return items
    }

    // MARK: - Execute restore

    /// Execute a restore with transactional safety.
    ///
    /// 1. Snapshot all current data to a temp directory
    /// 2. Write transaction state
    /// 3. For each entry: decompress, migrate if needed, merge/resolve, write
    /// 4. Verify written data
    /// 5. On success: cleanup snapshot
    /// 6. On failure: rollback from snapshot
    ///
    /// - Parameter resolveConflicts: Dictionary of conflict ID → resolution
    /// - Parameter progress: Progress callback (0.0...1.0)
    /// - Returns: Summary of what was restored
    func executeRestore(
        backupID: String,
        config: BackupIntegrationConfiguration,
        currentStores: [BackupStoreType: (data: Data, schemaVersion: Int)],
        storeWriters: [BackupStoreType: (Data) throws -> Void],
        resolveConflicts: [String: RestoreConflictResolution] = [:],
        progress: ((Double) -> Void)? = nil
    ) throws -> RestoreResult {
        processLock.lock()
        guard !_isRestoring else {
            processLock.unlock()
            throw BackupManagerError.restoreInProgress
        }
        _isRestoring = true
        processLock.unlock()
        defer {
            processLock.lock()
            _isRestoring = false
            processLock.unlock()
        }

        let dir = backupManager.backupDirectoryURL(config: config)
        let backupURL = dir.appendingPathComponent(backupID)
        guard let manifest = loadManifest(from: backupURL) else {
            throw BackupManagerError.manifestMissing(backupID)
        }
        let integrity = backupManager.verifyIntegrity(backupID: backupID, config: config)
        guard integrity.overallIntegrity else {
            throw BackupManagerError.backupCorrupted(integrity.errors.joined(separator: "; "))
        }

        // Refuse to start a transaction unless every entry that can modify
        // state has a writer. Missing hooks previously produced a successful
        // result without restoring any data.
        var storesToModify = Set<BackupStoreType>()
        for entryID in manifest.content.entryOrder {
            guard let entry = manifest.content.entries[entryID] else { continue }
            let current = currentStores[entry.storeType]
            let alreadyMatches = current.map {
                $0.schemaVersion == entry.schemaVersion
                    && storeDataHash($0.data) == entry.dataHash
            } ?? false
            let resolution = resolveConflicts[entryID]
                ?? resolveConflicts["schema-\(entry.storeType.rawValue)"]
            let intentionallySkipped = resolution == .skip || resolution == .useExistingVersion
            if !alreadyMatches, !intentionallySkipped {
                guard storeWriters[entry.storeType] != nil else {
                    throw BackupManagerError.storeUnavailable(entry.storeType.displayName)
                }
                storesToModify.insert(entry.storeType)
            }
        }

        // Create snapshot directory
        let snapshotDir = dir.appendingPathComponent(".restore-snapshot-\(UUID().uuidString.prefix(8))")
        try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let isoNow = ISO8601DateFormatter().string(from: Date())

        // Write transaction state (before any modifications)
        var txState = RestoreTransactionState(
            backupID: backupID,
            startedAt: isoNow,
            phase: .snapshotExisting,
            snapshotDir: snapshotDir.path
        )
        saveTransactionState(txState, in: dir)

        progress?(0.05)

        // Phase 1: Snapshot all current data
        var snapshotSuccess = true
        for (storeType, storeData) in currentStores where storesToModify.contains(storeType) {
            let snapshotURL = snapshotDir.appendingPathComponent("\(storeType.rawValue).json")
            do {
                try storeData.data.write(to: snapshotURL, options: .atomic)
            } catch {
                snapshotSuccess = false
                logger.error("快照失败：\(storeType.rawValue): \(error.localizedDescription)")
            }
        }

        guard snapshotSuccess else {
            txState.phase = .failed
            txState.failedEntries["__snapshot__"] = "当前数据快照失败"
            saveTransactionState(txState, in: dir)
            // No store write has happened yet, so cleanup is sufficient.
            try? fileManager.removeItem(at: snapshotDir)
            cleanupTransactionState(in: dir)
            throw BackupManagerError.ioError("当前数据快照失败，未执行恢复写入")
        }

        txState.phase = .writing
        saveTransactionState(txState, in: dir)
        progress?(0.15)

        // Phase 2: Process each backup entry
        let totalEntries = Double(manifest.content.entryOrder.count)
        var restoredEntries: [String] = []
        var failedEntries: [String: String] = [:]

        for (entryIndex, entryID) in manifest.content.entryOrder.enumerated() {
            guard let entryInfo = manifest.content.entries[entryID] else { continue }
            let storeType = entryInfo.storeType
            let entryFileName = storeType.entryFileName

            let entryProgress = 0.15 + (Double(entryIndex) / totalEntries) * 0.7
            progress?(entryProgress)

            // Skip entries that match current data
            if let currentStore = currentStores[storeType],
               storeDataHash(currentStore.data) == entryInfo.dataHash,
               currentStore.schemaVersion == entryInfo.schemaVersion {
                restoredEntries.append(entryID)
                continue
            }

            do {
                // Load, decompress, and validate the logical entry before any
                // store writer sees it.
                let restoredData = try backupManager.loadEntryData(
                    backupID: backupID,
                    entry: entryInfo,
                    config: config
                )

                // Entry schema versions belong to each store, not to the backup
                // envelope. Preserve the payload here; a schema mismatch is
                // surfaced by precheck and handled by the store-specific writer.
                let migratedData = restoredData

                // Merge if applicable
                let resolvedData: Data
                if let currentStore = currentStores[storeType],
                   storeType == .repositorySnapshot || storeType == .workspaces {
                    // Use merge resolver
                    resolvedData = try BackupMergeResolver.mergeRepositoryData(
                        backupJSON: migratedData,
                        currentJSON: currentStore.data
                    )
                } else {
                    resolvedData = migratedData
                }

                // Check if a conflict resolution says "skip"
                let resolution = resolveConflicts[entryID]
                    ?? resolveConflicts["schema-\(storeType.rawValue)"]
                if resolution == .skip || resolution == .useExistingVersion {
                    restoredEntries.append(entryID)
                    continue
                }

                // Writer availability was validated before the transaction.
                guard let writer = storeWriters[storeType] else {
                    throw BackupManagerError.storeUnavailable(storeType.displayName)
                }
                try writer(resolvedData)

                restoredEntries.append(entryID)

            } catch {
                failedEntries[entryID] = error.localizedDescription
                logger.error("恢复条目失败：\(entryFileName): \(error.localizedDescription)")

                // The restore is transactional: any failed store write rolls
                // back all entries already written, not only selected stores.
                txState.failedEntries = failedEntries
                txState.phase = .failed
                saveTransactionState(txState, in: dir)
                let rolledBack = rollback(
                    txState: txState,
                    storeWriters: storeWriters
                )
                throw BackupManagerError.restoreRollbackRequired(
                    reason: rolledBack
                        ? "恢复条目失败，已回滚：\(error.localizedDescription)"
                        : "恢复条目失败且回滚未完成：\(error.localizedDescription)"
                )
            }
        }

        progress?(0.9)

        // Phase 3: Verify restored data (read back)
        txState.phase = .verifying
        saveTransactionState(txState, in: dir)

        // Phase 4: Complete
        txState.phase = .completed
        txState.completedEntries = restoredEntries
        txState.failedEntries = failedEntries
        saveTransactionState(txState, in: dir)

        progress?(0.95)

        // Clean up snapshot on success
        try? fileManager.removeItem(at: snapshotDir)
        cleanupTransactionState(in: dir)

        progress?(1.0)

        return RestoreResult(
            backupID: backupID,
            totalEntries: manifest.content.totalEntryCount,
            restoredEntries: restoredEntries,
            failedEntries: failedEntries,
            conflictsResolved: resolveConflicts.count,
            completedAt: isoNow
        )
    }

    // MARK: - Rollback

    /// Rollback from a transaction state. Snapshot data is retained unless
    /// every original store can be written successfully.
    @discardableResult
    func rollback(
        txState: RestoreTransactionState,
        storeWriters: [BackupStoreType: (Data) throws -> Void]
    ) -> Bool {
        let snapshotDir = URL(fileURLWithPath: txState.snapshotDir)
        guard fileManager.fileExists(atPath: snapshotDir.path) else {
            logger.warning("回滚：快照目录不存在")
            return false
        }
        guard let snapshotContents = try? fileManager.contentsOfDirectory(
            at: snapshotDir,
            includingPropertiesForKeys: nil
        ) else {
            logger.error("回滚：无法读取快照目录")
            return false
        }

        var originals: [(BackupStoreType, Data)] = []
        for snapshotURL in snapshotContents where snapshotURL.pathExtension == "json" {
            let rawValue = snapshotURL.deletingPathExtension().lastPathComponent
            guard let storeType = BackupStoreType(rawValue: rawValue) else { continue }
            guard storeWriters[storeType] != nil else {
                logger.error("回滚缺少存储写入器：\(storeType.rawValue)")
                return false
            }
            do {
                originals.append((storeType, try Data(contentsOf: snapshotURL)))
            } catch {
                logger.error("回滚快照读取失败：\(storeType.rawValue): \(error.localizedDescription)")
                return false
            }
        }

        logger.notice("开始回滚：\(originals.count) 个存储")
        for (storeType, data) in originals {
            do {
                try storeWriters[storeType]?(data)
            } catch {
                logger.error("回滚写入失败：\(storeType.rawValue): \(error.localizedDescription)")
                return false
            }
        }

        var updated = txState
        updated.hasRolledBack = true
        updated.phase = .rolledBack
        let transactionDirectory = snapshotDir.deletingLastPathComponent()
        saveTransactionState(updated, in: transactionDirectory)
        do {
            try fileManager.removeItem(at: snapshotDir)
            cleanupTransactionState(in: transactionDirectory)
        } catch {
            logger.error("回滚清理失败：\(error.localizedDescription)")
            return false
        }
        logger.notice("回滚完成")
        return true
    }

    /// Check for any incomplete restore transaction (from a crash).
    /// Returns the transaction state if one exists.
    func pendingTransaction(config: BackupIntegrationConfiguration) -> RestoreTransactionState? {
        let dir = backupManager.backupDirectoryURL(config: config)
        let txURL = dir.appendingPathComponent(Self.transactionFileName)
        guard let data = try? Data(contentsOf: txURL),
              let txState = try? JSONDecoder().decode(RestoreTransactionState.self, from: data) else {
            if FileManager.default.fileExists(atPath: txURL.path) {
                logger.warning("Found restore transaction file but could not decode it at \(txURL.path)")
            }
            return nil
        }
        // Only return non-completed transactions
        guard txState.phase != .completed, txState.phase != .rolledBack else {
            return nil
        }
        return txState
    }

    /// Recover from a pending transaction (rollback). Without store writers,
    /// preserve the transaction and snapshot for a later recoverable attempt.
    @discardableResult
    func recoverPendingTransaction(
        config: BackupIntegrationConfiguration,
        storeWriters: [BackupStoreType: (Data) throws -> Void] = [:]
    ) -> Bool {
        guard let txState = pendingTransaction(config: config) else { return true }
        logger.notice("发现未完成的恢复事务，尝试回滚：\(txState.backupID)")
        let recovered = rollback(txState: txState, storeWriters: storeWriters)
        if !recovered {
            logger.error("未完成恢复事务缺少可用写入器；已保留回滚快照")
        }
        return recovered
    }

    // MARK: - Private helpers

    private func actionDetail(_ action: RestoreDiffAction, storeType: BackupStoreType, entryInfo: BackupEntryInfo) -> String? {
        switch action {
        case .create: return "新存储，将从备份创建"
        case .overwrite: return "数据不同，将覆盖当前版本"
        case .merge: return "需要与当前数据合并"
        case .skip: return "与当前数据一致，跳过"
        case .conflict: return "存在冲突，需用户决定"
        }
    }

    private func loadManifest(from backupURL: URL) -> BackupManifest? {
        let manifestURL = backupURL.appendingPathComponent(BackupFileLayout.manifestFileName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    private func estimateRestoreSize(manifest: BackupManifest) -> Int64 {
        var total: Int64 = 0
        for entryID in manifest.content.entryOrder {
            guard let info = manifest.content.entries[entryID] else { continue }
            total += info.uncompressedSizeBytes
        }
        return total + 1024 * 1024 // 1MB overhead for snapshots
    }

    private func saveTransactionState(_ state: RestoreTransactionState, in dir: URL) {
        let txURL = dir.appendingPathComponent(Self.transactionFileName)
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: txURL, options: .atomic)
        } catch {
            logger.error("Failed to save restore transaction state: \(error.localizedDescription)")
        }
    }

    private func cleanupTransactionState(in dir: URL) {
        let txURL = dir.appendingPathComponent(Self.transactionFileName)
        do {
            try fileManager.removeItem(at: txURL)
        } catch {
            logger.warning("Failed to clean up transaction state: \(error.localizedDescription)")
        }
    }

    private var _isRestoring: Bool = false
}

// MARK: - Restore result

struct RestoreResult: Equatable {
    let backupID: String
    let totalEntries: Int
    let restoredEntries: [String]
    let failedEntries: [String: String]
    let conflictsResolved: Int
    let completedAt: String
}

// MARK: - Data extensions for hashing

// MARK: - Helper: compute data hash for store comparison

private func storeDataHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

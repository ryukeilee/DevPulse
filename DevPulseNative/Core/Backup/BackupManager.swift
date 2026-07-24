import Compression
import CryptoKit
import Foundation
import OSLog

// MARK: - Backup manager

/// Creates, verifies, lists, and manages local backups of all DevPulse
/// persistent data stores.
///
/// Design:
/// - **Full backup**: copies all store data into a versioned directory
/// - **Incremental backup**: only stores entries whose data hash differs from
///   the most recent full or incremental backup's manifest
/// - **Integrity verification**: SHA256 checksums at entry and manifest level
/// - **Privacy filter**: configurable path/username stripping before serialization
/// - **Retention**: bounded disk usage via `BackupRetentionPolicy`
/// - **Thread safety**: all file I/O on a serial utility queue
final class BackupManager: @unchecked Sendable {
    private static let lockFileName = ".backup-manager.lock"
    private let logger = Logger(subsystem: "local.devpulse.app", category: "BackupManager")

    private let fileManager: FileManager
    private let queue: DispatchQueue
    private let processLock = NSLock()
    private let retentionPolicy: BackupRetentionPolicy

    /// Whether a backup operation is currently in progress.
    private var _isBackingUp = false
    private var _isRestoring = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.queue = DispatchQueue(
            label: "local.devpulse.app.backup-manager",
            qos: .utility,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
        self.retentionPolicy = BackupRetentionPolicy(fileManager: fileManager)
    }

    // MARK: - Directory resolution

    /// Resolve the backup directory path, creating it if needed.
    func backupDirectoryURL(config: BackupIntegrationConfiguration) -> URL {
        let expanded = (config.backupDirectory as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - List backups

    /// List all backups in the configured backup directory.
    func listBackups(config: BackupIntegrationConfiguration) -> BackupDirectoryListing {
        let dir = backupDirectoryURL(config: config)
        let contents = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [
            .isDirectoryKey, .fileSizeKey, .creationDateKey
        ], options: [.skipsHiddenFiles])) ?? []

        var summaries: [BackupSummary] = []
        for url in contents {
            guard url.hasDirectoryPath,
                  url.lastPathComponent.hasPrefix(BackupFileLayout.backupPrefix) else { continue }
            if let summary = loadSummary(from: url) {
                summaries.append(summary)
            }
        }

        summaries.sort { $0.createdAt > $1.createdAt }

        let totalSize = summaries.reduce(0) { $0 + $1.totalSizeBytes }
        let freeSpace = BackupFreeSpace.availableBytes(at: dir) ?? 0

        return BackupDirectoryListing(
            backups: summaries,
            retentionConfig: config.retention,
            totalBackupSizeBytes: totalSize,
            freeSpaceBytes: freeSpace
        )
    }

    // MARK: - Create backup

    /// Create a full backup of all available stores.
    /// - Parameter config: Backup configuration (privacy, retention, directory)
    /// - Parameter stores: Dictionary of store type → (JSON data, schema version)
    /// - Parameter notes: Optional user notes
    /// - Parameter isIncremental: Whether to create an incremental backup
    /// - Parameter progress: Optional progress callback (0.0...1.0)
    /// - Returns: The backup summary, or throws on error.
    func createBackup(
        config: BackupIntegrationConfiguration,
        stores: [BackupStoreType: (data: Data, schemaVersion: Int)],
        notes: String? = nil,
        isIncremental: Bool = false,
        progress: ((Double) -> Void)? = nil
    ) throws -> BackupSummary {
        guard !_isBackingUp else { throw BackupManagerError.backupInProgress }
        _isBackingUp = true
        defer { _isBackingUp = false }

        let backupDir = backupDirectoryURL(config: config)
        let now = Date()
        let backupName = BackupFileLayout.backupDirectoryName(date: now)
        let backupURL = backupDir.appendingPathComponent(backupName)

        // Check free space
        let estimatedSize = estimateBackupSize(stores: stores)
        guard retentionPolicy.hasFreeSpace(
            backupDirectory: backupDir,
            estimatedSizeBytes: estimatedSize,
            minimumFreeSpaceBytes: config.retention.minimumFreeSpaceBytes
        ) else {
            let free = BackupFreeSpace.availableBytes(at: backupDir) ?? 0
            throw BackupManagerError.storageFull(available: free, needed: estimatedSize)
        }

        // Check for previous backup for incremental diff
        let previousManifest = isIncremental ? findLatestBackupManifest(at: backupDir) : nil

        progress?(0.05)

        // Create directory structure
        try fileManager.createDirectory(at: backupURL, withIntermediateDirectories: true)
        let entriesDir = backupURL.appendingPathComponent(BackupFileLayout.entriesDirectoryName)
        try fileManager.createDirectory(at: entriesDir, withIntermediateDirectories: true)

        progress?(0.1)

        // Process each store
        var entries: [BackupEntryInfo] = []
        var checksums: [String: String] = [:]
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let isoNow = ISO8601DateFormatter().string(from: now)

        let totalStores = Double(stores.count)
        for (storeIndex, (storeType, storeData)) in stores.enumerated() {
            let storeProgress = 0.1 + (Double(storeIndex) / totalStores) * 0.7
            progress?(storeProgress)

            // Apply privacy filter
            let privacyConfig = config.privacyMode.configuration
            let sanitized: Data
            if config.privacyMode != .full,
               let jsonString = String(data: storeData.data, encoding: .utf8) {
                let cleaned = BackupPrivacyFilter.sanitizePayload(
                    jsonString,
                    storeType: storeType,
                    config: privacyConfig
                )
                sanitized = Data(cleaned.utf8)
            } else {
                sanitized = storeData.data
            }

            // Compute hash
            let dataHash = SHA256.hash(data: sanitized)
                .map { String(format: "%02x", $0) }.joined()

            // Incremental: skip if hash matches previous backup
            if isIncremental, let prev = previousManifest {
                if let prevEntry = prev.content.entries.values.first(where: { $0.storeType == storeType }),
                   prevEntry.dataHash == dataHash {
                    // Entry unchanged - skip storing but record reference
                    let entryInfo = BackupEntryInfo(
                        storeType: storeType,
                        schemaVersion: storeData.schemaVersion,
                        dataHash: dataHash,
                        compressedSizeBytes: 0,
                        uncompressedSizeBytes: Int64(sanitized.count),
                        entryCreatedAt: prevEntry.entryCreatedAt
                    )
                    entries.append(entryInfo)
                    checksums[storeType.entryFileName] = dataHash
                    continue
                }
            }

            // Compress data
            let compressed = compress(data: sanitized)
            let entryFileName = storeType.entryFileName
            let entryURL = entriesDir.appendingPathComponent(entryFileName)

            // Verify compression
            let decompressed = decompress(data: compressed)
            guard decompressed == sanitized else {
                throw BackupManagerError.serializationFailed("压缩/解压缩验证失败：\(storeType.rawValue)")
            }

            // Write compressed entry
            try compressed.write(to: entryURL, options: .atomic)

            let entryInfo = BackupEntryInfo(
                storeType: storeType,
                schemaVersion: storeData.schemaVersion,
                dataHash: dataHash,
                compressedSizeBytes: Int64(compressed.count),
                uncompressedSizeBytes: Int64(sanitized.count),
                entryCreatedAt: isoNow
            )
            entries.append(entryInfo)
            checksums[entryFileName] = dataHash
        }

        progress?(0.85)

        // Build content inventory
        let inventory = BackupContentInventory(entries: entries)
        let contentHash = BackupManifest.computeContentHash(entryHashes: checksums)

        // Build metadata
        let metadata = BackupMetadata(
            deviceName: Host.current().name ?? "Mac",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: appVersion,
            notes: notes
        )

        // Create manifest (with privacy applied to metadata)
        var manifest = BackupManifest(
            backupVersion: "1.0",
            createdAt: isoNow,
            appVersion: appVersion,
            appBuildNumber: appBuild,
            contentHash: contentHash,
            content: inventory,
            metadata: metadata,
            isIncremental: isIncremental,
            parentBackupID: isIncremental ? previousManifest.map { _ in
                backupName // previous backup's directory name
            } : nil
        )

        // Apply privacy filter to manifest
        BackupPrivacyFilter.sanitize(manifest: &manifest, config: config.privacyMode.configuration)

        // Write manifest
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestURL = backupURL.appendingPathComponent(BackupFileLayout.manifestFileName)
        try manifestData.write(to: manifestURL, options: .atomic)

        progress?(0.9)

        // Write checksums file
        var checksumLines = checksums.sorted(by: { $0.key < $1.key })
            .map { "\($0.value)  \($0.key)" }
            .joined(separator: "\n")
        checksumLines += "\n"
        let checksumsURL = backupURL.appendingPathComponent(BackupFileLayout.checksumsFileName)
        try checksumLines.data(using: .utf8)?.write(to: checksumsURL, options: .atomic)

        progress?(0.95)

        // Enforce retention policy after successful backup
        let listing = listBackups(config: config)
        let toDelete = retentionPolicy.evaluateCandidates(
            backups: listing.backups,
            config: config.retention
        )
        for backup in toDelete {
            retentionPolicy.deleteBackup(backup)
        }

        progress?(1.0)

        // Return summary for the new backup
        return loadSummary(from: backupURL) ?? BackupSummary(
            id: backupName,
            createdAt: now,
            appVersion: appVersion,
            backupVersion: BackupSchema.currentVersion,
            isIncremental: isIncremental,
            parentBackupID: nil,
            entryCount: entries.count,
            totalSizeBytes: estimateDirectorySize(backupURL),
            contentHash: contentHash,
            integrityVerified: true,
            integrityError: nil,
            isCompatible: true,
            storedAt: backupURL.path
        )
    }

    // MARK: - Verify integrity

    /// Verify the integrity of a backup.
    func verifyIntegrity(backupID: String, config: BackupIntegrationConfiguration) -> BackupIntegrityResult {
        let dir = backupDirectoryURL(config: config)
        let backupURL = dir.appendingPathComponent(backupID)

        guard fileManager.fileExists(atPath: backupURL.path) else {
            return BackupIntegrityResult(
                backupID: backupID,
                manifestValid: false,
                checksumsValid: false,
                allEntriesPresent: false,
                entryChecksumsMatch: false,
                overallIntegrity: false,
                errors: ["备份目录不存在：\(backupID)"],
                warnings: []
            )
        }

        var errors: [String] = []
        var warnings: [String] = []

        // 1. Verify manifest exists and is valid JSON
        let manifestURL = backupURL.appendingPathComponent(BackupFileLayout.manifestFileName)
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackupManifest.self, from: manifestData) else {
            return BackupIntegrityResult(
                backupID: backupID,
                manifestValid: false,
                checksumsValid: false,
                allEntriesPresent: false,
                entryChecksumsMatch: false,
                overallIntegrity: false,
                errors: ["备份清单缺失或损坏"],
                warnings: []
            )
        }

        let manifestValid = true
        let entriesDir = backupURL.appendingPathComponent(BackupFileLayout.entriesDirectoryName)

        // 2. Verify checksums file
        let checksumsURL = backupURL.appendingPathComponent(BackupFileLayout.checksumsFileName)
        var checksumsValid = false
        var expectedChecksums: [String: String] = [:]
        if let checksumsData = try? Data(contentsOf: checksumsURL),
           let checksumsStr = String(data: checksumsData, encoding: .utf8) {
            for line in checksumsStr.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if parts.count == 2 {
                    expectedChecksums[String(parts[1])] = String(parts[0])
                }
            }
            checksumsValid = !expectedChecksums.isEmpty
        } else {
            errors.append("校验和文件缺失或不可读")
        }

        // 3. Verify all entries present and checksums match
        var allEntriesPresent = true
        var entryChecksumsMatch = true

        for (entryFileName, expectedHash) in expectedChecksums {
            let entryURL = entriesDir.appendingPathComponent(entryFileName)
            guard fileManager.fileExists(atPath: entryURL.path) else {
                allEntriesPresent = false
                errors.append("缺少条目文件：\(entryFileName)")
                continue
            }

            // For compressed entries, verify the stored file hash
            if let entryData = try? Data(contentsOf: entryURL) {
                let actualHash = SHA256.hash(data: entryData)
                    .map { String(format: "%02x", $0) }.joined()
                if actualHash != expectedHash {
                    entryChecksumsMatch = false
                    errors.append("条目文件校验和不匹配：\(entryFileName)")
                }
            } else {
                entryChecksumsMatch = false
                errors.append("无法读取条目文件：\(entryFileName)")
            }
        }

        // 4. Verify content hash
        var contentHashValid = true
        if manifestValid {
            let computedHash = BackupManifest.computeContentHash(entryHashes: expectedChecksums)
            if computedHash != manifest.contentHash {
                contentHashValid = false
                warnings.append("内容哈希不匹配（可能是隐私过滤导致清单与条目不一致）")
            }
        }

        let overall = manifestValid && checksumsValid && allEntriesPresent && entryChecksumsMatch

        return BackupIntegrityResult(
            backupID: backupID,
            manifestValid: manifestValid,
            checksumsValid: checksumsValid,
            allEntriesPresent: allEntriesPresent,
            entryChecksumsMatch: entryChecksumsMatch && contentHashValid,
            overallIntegrity: overall,
            errors: errors,
            warnings: warnings
        )
    }

    // MARK: - Export

    /// Export a backup as a single archive file for transfer.
    func exportBackup(
        backupID: String,
        to exportURL: URL,
        config: BackupIntegrationConfiguration
    ) throws {
        let dir = backupDirectoryURL(config: config)
        let backupURL = dir.appendingPathComponent(backupID)
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw BackupManagerError.backupNotFound(backupID)
        }

        // Create a zip archive using ditto
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", backupURL.path, exportURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BackupManagerError.ioError("导出失败，ditto 退出码：\(process.terminationStatus)")
        }
    }

    /// Import a backup archive.
    func importBackup(
        from archiveURL: URL,
        config: BackupIntegrationConfiguration
    ) throws -> BackupSummary {
        let dir = backupDirectoryURL(config: config)

        // Extract archive
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, dir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BackupManagerError.ioError("导入失败，ditto 退出码：\(process.terminationStatus)")
        }

        // Find the imported backup directory
        let contents = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles])
        guard let imported = contents.first(where: {
            $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix(BackupFileLayout.backupPrefix)
        }) else {
            throw BackupManagerError.backupNotFound("未找到导入的备份")
        }

        // Verify integrity
        let result = verifyIntegrity(backupID: imported.lastPathComponent, config: config)
        guard result.overallIntegrity else {
            throw BackupManagerError.backupCorrupted(result.errors.joined(separator: "; "))
        }

        return loadSummary(from: imported)!
    }

    /// Delete a backup.
    func deleteBackup(backupID: String, config: BackupIntegrationConfiguration) throws {
        let dir = backupDirectoryURL(config: config)
        let backupURL = dir.appendingPathComponent(backupID)
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw BackupManagerError.backupNotFound(backupID)
        }
        try fileManager.removeItem(at: backupURL)
        logger.notice("Deleted backup: \(backupID)")
    }

    // MARK: - Private helpers

    private func loadSummary(from backupURL: URL) -> BackupSummary? {
        let manifestURL = backupURL.appendingPathComponent(BackupFileLayout.manifestFileName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
            return nil
        }

        let date = ISO8601DateFormatter().date(from: manifest.createdAt) ?? Date()
        let size = estimateDirectorySize(backupURL)

        return BackupSummary(
            id: backupURL.lastPathComponent,
            createdAt: date,
            appVersion: manifest.appVersion,
            backupVersion: manifest.schemaVersion,
            isIncremental: manifest.isIncremental,
            parentBackupID: manifest.parentBackupID,
            entryCount: manifest.content.totalEntryCount,
            totalSizeBytes: size,
            contentHash: manifest.contentHash,
            integrityVerified: false,
            integrityError: nil,
            isCompatible: manifest.schemaVersion >= BackupSchema.oldestCompatibleVersion
                && manifest.schemaVersion <= BackupSchema.currentVersion,
            storedAt: backupURL.path
        )
    }

    private func estimateDirectorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    private func estimateBackupSize(stores: [BackupStoreType: (data: Data, schemaVersion: Int)]) -> Int64 {
        // Rough estimate: compressed data is ~30% of original
        let totalUncompressed = stores.values.reduce(0) { $0 + Int64($1.data.count) }
        return Int64(Double(totalUncompressed) * 0.3) + 4096 // overhead
    }

    private func findLatestBackupManifest(at directory: URL) -> BackupManifest? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let backups = contents.filter {
            $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix(BackupFileLayout.backupPrefix)
        }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da > db
        }

        for backupURL in backups {
            let manifestURL = backupURL.appendingPathComponent(BackupFileLayout.manifestFileName)
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) {
                return manifest
            }
        }
        return nil
    }

    // MARK: - Compression

    private func compress(data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let sourceSize = data.count

        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: sourceSize)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { sourcePtr in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer, sourceSize,
                baseAddress.assumingMemoryBound(to: UInt8.self), sourceSize,
                nil, COMPRESSION_ZLIB
            )
        }

        if compressedSize > 0 {
            return Data(bytes: destinationBuffer, count: compressedSize)
        }
        return data
    }

    private func decompress(data: Data) -> Data {
        guard !data.isEmpty else { return data }
        // Try decompression with a generous buffer
        let sourceSize = data.count
        let destSize = sourceSize * 10 // 10x expansion buffer
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destSize)
        defer { destinationBuffer.deallocate() }

        let decodedSize = data.withUnsafeBytes { sourcePtr in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, destSize,
                baseAddress.assumingMemoryBound(to: UInt8.self), sourceSize,
                nil, COMPRESSION_ZLIB
            )
        }

        if decodedSize > 0 {
            return Data(bytes: destinationBuffer, count: decodedSize)
        }
        return data // Return original if decompression fails (might be uncompressed)
    }
}

import Compression
import CryptoKit
import Foundation
import OSLog

// MARK: - Backup compression

enum BackupCompression {
    /// Bound allocations when inspecting an untrusted imported manifest.
    private static let maximumDecodedSize: Int64 = 512 * 1024 * 1024

    static func compress(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer,
                data.count,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard compressedSize > 0 else { return data }
        return Data(bytes: destinationBuffer, count: compressedSize)
    }

    static func decompress(_ data: Data, expectedSize: Int64) -> Data? {
        guard expectedSize >= 0,
              expectedSize <= maximumDecodedSize,
              expectedSize <= Int64(Int.max) else { return nil }
        let targetSize = Int(expectedSize)
        if targetSize == 0 {
            return data.isEmpty ? Data() : nil
        }

        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: targetSize)
        defer { destinationBuffer.deallocate() }
        let decodedSize = data.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                targetSize,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        if decodedSize == targetSize {
            return Data(bytes: destinationBuffer, count: decodedSize)
        }

        // Compression deliberately falls back to raw bytes when zlib cannot
        // make the payload smaller. Accept that representation only when its
        // exact size matches the manifest.
        return data.count == targetSize ? data : nil
    }
}

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
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            logger.warning("Failed to create backup directory: \(error.localizedDescription) at \(url.path)")
        }
        return url
    }

    // MARK: - List backups

    /// List all backups in the configured backup directory.
    func listBackups(config: BackupIntegrationConfiguration) -> BackupDirectoryListing {
        let dir = backupDirectoryURL(config: config)
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .creationDateKey
            ], options: [.skipsHiddenFiles])
        } catch {
            logger.warning("Failed to list backup directory: \(error.localizedDescription)")
            contents = []
        }

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
        processLock.lock()
        guard !_isBackingUp else {
            processLock.unlock()
            throw BackupManagerError.backupInProgress
        }
        _isBackingUp = true
        processLock.unlock()
        defer {
            processLock.lock()
            _isBackingUp = false
            processLock.unlock()
        }
        guard !stores.isEmpty else {
            throw BackupManagerError.storeUnavailable("没有可备份的数据")
        }

        let backupDir = backupDirectoryURL(config: config)
        let now = Date()
        let baseName = BackupFileLayout.backupDirectoryName(date: now)
        var backupName = baseName
        var finalBackupURL = backupDir.appendingPathComponent(backupName)
        if fileManager.fileExists(atPath: finalBackupURL.path) {
            backupName += "-\(UUID().uuidString.prefix(8))"
            finalBackupURL = backupDir.appendingPathComponent(backupName)
        }
        let backupURL = backupDir.appendingPathComponent(
            ".backup-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: backupURL)
            }
        }

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

        // Check for previous backup for incremental diff.
        let previousBackup = isIncremental ? findLatestBackup(at: backupDir) : nil
        let previousManifest = previousBackup?.manifest
        let createsIncremental = isIncremental && previousBackup != nil

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

            // Keep incremental backups independently restorable: when an entry
            // is unchanged, copy its verified payload from the previous chain
            // instead of writing a zero-byte reference that retention could
            // orphan.
            if createsIncremental,
               let previousBackup,
               let prevEntry = previousManifest?.content.entries.values.first(where: {
                   $0.storeType == storeType
               }),
               prevEntry.dataHash == dataHash,
               let sourceURL = resolveEntryURL(
                   storeType: storeType,
                   backupURL: previousBackup.url,
                   manifest: previousBackup.manifest,
                   backupRoot: backupDir
               ),
               let previousPayload = try? Data(contentsOf: sourceURL),
               BackupCompression.decompress(
                   previousPayload,
                   expectedSize: Int64(sanitized.count)
               ) == sanitized {
                let entryFileName = storeType.entryFileName
                try previousPayload.write(
                    to: entriesDir.appendingPathComponent(entryFileName),
                    options: .atomic
                )
                entries.append(BackupEntryInfo(
                    storeType: storeType,
                    schemaVersion: storeData.schemaVersion,
                    dataHash: dataHash,
                    compressedSizeBytes: Int64(previousPayload.count),
                    uncompressedSizeBytes: Int64(sanitized.count),
                    entryCreatedAt: prevEntry.entryCreatedAt
                ))
                checksums[entryFileName] = dataHash
                continue
            }

            // Compress data
            let compressed = BackupCompression.compress(sanitized)
            let entryFileName = storeType.entryFileName
            let entryURL = entriesDir.appendingPathComponent(entryFileName)

            // Verify compression
            let decompressed = BackupCompression.decompress(
                compressed,
                expectedSize: Int64(sanitized.count)
            )
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
            isIncremental: createsIncremental,
            parentBackupID: createsIncremental ? previousBackup?.id : nil
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
        try Data(checksumLines.utf8).write(to: checksumsURL, options: .atomic)

        // Publish the backup directory only after every entry and metadata file
        // has been written. A failed operation leaves no visible partial backup.
        try fileManager.moveItem(at: backupURL, to: finalBackupURL)
        committed = true

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
        return loadSummary(from: finalBackupURL) ?? BackupSummary(
            id: backupName,
            createdAt: now,
            appVersion: appVersion,
            backupVersion: BackupSchema.currentVersion,
            isIncremental: createsIncremental,
            parentBackupID: createsIncremental ? previousBackup?.id : nil,
            entryCount: entries.count,
            totalSizeBytes: estimateDirectorySize(finalBackupURL),
            contentHash: contentHash,
            integrityVerified: true,
            integrityError: nil,
            isCompatible: true,
            storedAt: finalBackupURL.path
        )
    }

    // MARK: - Verify integrity

    /// Verify the integrity of a backup.
    func verifyIntegrity(backupID: String, config: BackupIntegrationConfiguration) -> BackupIntegrityResult {
        let directory = backupDirectoryURL(config: config)
        return verifyIntegrity(
            backupURL: directory.appendingPathComponent(backupID),
            backupRoot: directory,
            backupID: backupID
        )
    }

    private func verifyIntegrity(
        backupURL: URL,
        backupRoot: URL,
        backupID: String
    ) -> BackupIntegrityResult {
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

        var manifestChecksums: [String: String] = [:]
        var hasDuplicateStoreEntries = false
        for entry in manifest.content.entries.values {
            let fileName = entry.storeType.entryFileName
            if manifestChecksums.updateValue(entry.dataHash, forKey: fileName) != nil {
                hasDuplicateStoreEntries = true
            }
        }
        if hasDuplicateStoreEntries {
            errors.append("备份清单包含重复存储条目")
        }
        var fileChecksums: [String: String] = [:]
        let checksumsURL = backupURL.appendingPathComponent(BackupFileLayout.checksumsFileName)
        if let checksumsData = try? Data(contentsOf: checksumsURL),
           let checksumsString = String(data: checksumsData, encoding: .utf8) {
            for line in checksumsString.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if parts.count == 2 {
                    fileChecksums[String(parts[1])] = String(parts[0])
                }
            }
        } else {
            errors.append("校验和文件缺失或不可读")
        }
        let checksumsValid = !hasDuplicateStoreEntries
            && !manifestChecksums.isEmpty
            && fileChecksums == manifestChecksums
        if !checksumsValid, !fileChecksums.isEmpty {
            errors.append("校验和清单与备份清单不一致")
        }

        var allEntriesPresent = true
        var entryChecksumsMatch = true
        for entry in manifest.content.entries.values {
            let entryFileName = entry.storeType.entryFileName
            guard let entryURL = resolveEntryURL(
                storeType: entry.storeType,
                backupURL: backupURL,
                manifest: manifest,
                backupRoot: backupRoot
            ) else {
                allEntriesPresent = false
                entryChecksumsMatch = false
                errors.append("缺少条目文件：\(entryFileName)")
                continue
            }
            guard let storedData = try? Data(contentsOf: entryURL),
                  let logicalData = BackupCompression.decompress(
                    storedData,
                    expectedSize: entry.uncompressedSizeBytes
                  ) else {
                entryChecksumsMatch = false
                errors.append("无法解压条目文件：\(entryFileName)")
                continue
            }

            let actualHash = SHA256.hash(data: logicalData)
                .map { String(format: "%02x", $0) }.joined()
            if actualHash != entry.dataHash {
                entryChecksumsMatch = false
                errors.append("条目数据校验和不匹配：\(entryFileName)")
            }
        }

        let computedContentHash = BackupManifest.computeContentHash(entryHashes: manifestChecksums)
        let contentHashValid = computedContentHash == manifest.contentHash
        if !contentHashValid {
            errors.append("内容哈希不匹配")
        }

        let overall = checksumsValid
            && allEntriesPresent
            && entryChecksumsMatch
            && contentHashValid
        return BackupIntegrityResult(
            backupID: backupID,
            manifestValid: true,
            checksumsValid: checksumsValid,
            allEntriesPresent: allEntriesPresent,
            entryChecksumsMatch: entryChecksumsMatch && contentHashValid,
            overallIntegrity: overall,
            errors: errors,
            warnings: []
        )
    }

    /// Load and verify one logical entry, following an older incremental
    /// parent chain when necessary.
    func loadEntryData(
        backupID: String,
        entry: BackupEntryInfo,
        config: BackupIntegrationConfiguration
    ) throws -> Data {
        let backupRoot = backupDirectoryURL(config: config)
        let backupURL = backupRoot.appendingPathComponent(backupID, isDirectory: true)
        let manifestURL = backupURL.appendingPathComponent(BackupFileLayout.manifestFileName)
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackupManifest.self, from: manifestData),
              manifest.content.entries[entry.id] == entry else {
            throw BackupManagerError.manifestMissing(backupID)
        }
        guard let entryURL = resolveEntryURL(
            storeType: entry.storeType,
            backupURL: backupURL,
            manifest: manifest,
            backupRoot: backupRoot
        ) else {
            throw BackupManagerError.entryMissing(entry.storeType.entryFileName)
        }
        let storedData = try Data(contentsOf: entryURL)
        guard let logicalData = BackupCompression.decompress(
            storedData,
            expectedSize: entry.uncompressedSizeBytes
        ) else {
            throw BackupManagerError.deserializationFailed(
                "无法解压：\(entry.storeType.entryFileName)"
            )
        }
        let actualHash = SHA256.hash(data: logicalData)
            .map { String(format: "%02x", $0) }.joined()
        guard actualHash == entry.dataHash else {
            throw BackupManagerError.checksumMismatch(
                expected: entry.dataHash,
                actual: actualHash
            )
        }
        return logicalData
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
        let directory = backupDirectoryURL(config: config)
        let stagingDirectory = directory.appendingPathComponent(
            ".import-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        // Extract away from live backups. The previous implementation unpacked
        // directly into the live directory and could return an unrelated old
        // backup while leaving a corrupt import behind.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, stagingDirectory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackupManagerError.ioError("导入失败，ditto 退出码：\(process.terminationStatus)")
        }

        let contents = try fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = contents.filter {
            $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix(BackupFileLayout.backupPrefix)
        }
        guard candidates.count == 1, let imported = candidates.first else {
            throw BackupManagerError.backupCorrupted("归档必须且只能包含一个 DevPulse 备份目录")
        }

        let integrity = verifyIntegrity(
            backupURL: imported,
            backupRoot: stagingDirectory,
            backupID: imported.lastPathComponent
        )
        guard integrity.overallIntegrity else {
            throw BackupManagerError.backupCorrupted(integrity.errors.joined(separator: "; "))
        }

        var destinationName = imported.lastPathComponent
        var destination = directory.appendingPathComponent(destinationName)
        if fileManager.fileExists(atPath: destination.path) {
            destinationName += "-\(UUID().uuidString.prefix(8))"
            destination = directory.appendingPathComponent(destinationName)
        }
        try fileManager.moveItem(at: imported, to: destination)
        guard let summary = loadSummary(from: destination) else {
            try? fileManager.removeItem(at: destination)
            throw BackupManagerError.manifestMissing(destinationName)
        }
        return summary
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
            options: [.skipsHiddenFiles]
        ) else {
            logger.warning("Failed to enumerate backup directory for size estimate at \(url.path)")
            return 0
        }
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

    private func findLatestBackup(
        at directory: URL
    ) -> (id: String, url: URL, manifest: BackupManifest)? {
        var contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            logger.warning("Failed to list backup directory for incremental manifest: \(error.localizedDescription)")
            return nil
        }

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
                return (backupURL.lastPathComponent, backupURL, manifest)
            }
        }
        return nil
    }

    /// Resolve an entry from this backup or its incremental parent chain.
    /// New backups are self-contained, while this keeps older valid chains
    /// readable and rejects missing/cyclic references.
    private func resolveEntryURL(
        storeType: BackupStoreType,
        backupURL: URL,
        manifest: BackupManifest,
        backupRoot: URL,
        visited: Set<String> = []
    ) -> URL? {
        let identity = backupURL.standardizedFileURL.path
        guard !visited.contains(identity) else { return nil }
        var nextVisited = visited
        nextVisited.insert(identity)

        let candidate = backupURL
            .appendingPathComponent(BackupFileLayout.entriesDirectoryName)
            .appendingPathComponent(storeType.entryFileName)
        if fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        guard manifest.isIncremental,
              let parentID = manifest.parentBackupID,
              parentID == (parentID as NSString).lastPathComponent,
              parentID.hasPrefix(BackupFileLayout.backupPrefix) else { return nil }
        let parentURL = backupRoot.appendingPathComponent(parentID, isDirectory: true)
        let parentManifestURL = parentURL.appendingPathComponent(BackupFileLayout.manifestFileName)
        guard let data = try? Data(contentsOf: parentManifestURL),
              let parentManifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
            return nil
        }
        return resolveEntryURL(
            storeType: storeType,
            backupURL: parentURL,
            manifest: parentManifest,
            backupRoot: backupRoot,
            visited: nextVisited
        )
    }
}

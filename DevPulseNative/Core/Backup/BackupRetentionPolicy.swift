import Foundation
import OSLog

// MARK: - Backup retention policy

/// Manages bounded disk usage for backup storage.
///
/// Rules:
/// - Keep at most `maxBackupCount` backups (oldest removed first)
/// - Total backup size must not exceed `maxTotalSizeBytes`
/// - Delete backups older than `retentionDays`
/// - Do not delete the most recent full backup (not incremental)
/// - Refuse new backup if free space drops below `minimumFreeSpaceBytes`
final class BackupRetentionPolicy: @unchecked Sendable {
    private let logger = Logger(subsystem: "local.devpulse.app", category: "BackupRetention")
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Public API

    /// Evaluate the current backup directory and return a list of backups
    /// that should be removed to satisfy the retention policy.
    func evaluateCandidates(
        backups: [BackupSummary],
        config: BackupRetentionConfiguration
    ) -> [BackupSummary] {
        guard !backups.isEmpty else { return [] }

        var candidates = Set<String>() // track by backup ID
        let sortedByAge = backups.sorted { $0.createdAt < $1.createdAt }

        // 1. Remove backups older than retentionDays
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(config.retentionDays * 86400))
        for backup in sortedByAge where backup.createdAt < cutoffDate {
            candidates.insert(backup.id)
        }

        // 2. Enforce max count: remove oldest beyond limit
        let remaining = backups.filter { !candidates.contains($0.id) }
        if remaining.count > config.maxBackupCount {
            let sortedRemaining = remaining.sorted { $0.createdAt < $1.createdAt }
            let excess = sortedRemaining.prefix(remaining.count - config.maxBackupCount)
            for backup in excess {
                candidates.insert(backup.id)
            }
        }

        // 3. Ensure we keep at least one full (non-incremental) backup
        let keptBackups = backups.filter { !candidates.contains($0.id) }
        let hasFullBackup = keptBackups.contains { !$0.isIncremental }
        if !hasFullBackup {
            // Find the most recent full backup and remove it from candidates
            if let newestFull = backups.filter({ !$0.isIncremental })
                .sorted(by: { $0.createdAt > $1.createdAt }).first {
                candidates.remove(newestFull.id)
            }
        }

        // 4. Enforce max total size: remove oldest candidates until under limit
        let remainingAfterCount = backups.filter { !candidates.contains($0.id) }
        var totalSize = remainingAfterCount.reduce(0) { $0 + $1.totalSizeBytes }
        let oversizedByAge = remainingAfterCount.sorted { $0.createdAt < $1.createdAt }
        for backup in oversizedByAge where totalSize > config.maxTotalSizeBytes {
            candidates.insert(backup.id)
            totalSize -= backup.totalSizeBytes
        }

        return backups.filter { candidates.contains($0.id) }
    }

    /// Check if there is enough free space for a new backup.
    func hasFreeSpace(
        backupDirectory: URL,
        estimatedSizeBytes: Int64,
        minimumFreeSpaceBytes: Int64
    ) -> Bool {
        let free = BackupFreeSpace.availableBytes(at: backupDirectory) ?? 0
        return free >= estimatedSizeBytes + minimumFreeSpaceBytes
    }

    /// Delete backup files from disk.
    func deleteBackup(_ summary: BackupSummary) -> Bool {
        let url = URL(fileURLWithPath: summary.storedAt)
        do {
            try fileManager.removeItem(at: url)
            logger.notice("Deleted backup: \(summary.id)")
            return true
        } catch {
            logger.error("Failed to delete backup \(summary.id): \(error.localizedDescription)")
            return false
        }
    }

    /// Calculate total size of a backup directory.
    static func backupSize(at url: URL, fileManager: FileManager = .default) -> Int64 {
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
}

import Foundation
import OSLog

// MARK: - Backup migration engine

/// Handles cross-version migration of backup data.
///
/// Design:
/// - One-way migrations: old version → new version
/// - Each migration step is minimal and verifiable
/// - Unknown future versions are rejected (file preserved, error returned)
/// - Migration is applied per-entry in the backup, not to the whole backup at once
final class BackupMigrationEngine {
    private let logger = Logger(subsystem: "local.devpulse.app", category: "BackupMigration")

    // MARK: - Migration check

    /// Check if a backup can be migrated to the current schema version.
    /// Returns `nil` if no migration is needed or possible.
    static func migrationNeeded(
        from backupVersion: Int,
        to currentVersion: Int = BackupSchema.currentVersion
    ) -> MigrationPath? {
        guard backupVersion != currentVersion else { return nil }

        // Reject future versions
        guard backupVersion <= currentVersion else {
            return nil // caller should handle incompatibility
        }

        // Reject unsupported old versions
        guard backupVersion >= BackupSchema.oldestCompatibleVersion else {
            return nil // too old to migrate
        }

        return MigrationPath(from: backupVersion, to: currentVersion)
    }

    /// Migrate a backup entry's data from an older schema to the current version.
    /// Returns the migrated data, or throws if migration is impossible.
    static func migrateEntry(
        storeType: BackupStoreType,
        data: Data,
        fromVersion: Int,
        toVersion: Int = BackupSchema.currentVersion
    ) throws -> Data {
        guard fromVersion != toVersion else { return data }
        guard fromVersion < toVersion else {
            throw BackupManagerError.backupIncompatible(version: fromVersion, expected: toVersion)
        }
        guard fromVersion >= BackupSchema.oldestCompatibleVersion else {
            throw BackupManagerError.migrationRequired(from: fromVersion, to: toVersion)
        }

        var currentData = data
        // Apply migrations step by step
        for version in fromVersion..<toVersion {
            currentData = try migrateStep(storeType: storeType, data: currentData, from: version)
        }
        return currentData
    }

    // MARK: - Step migrations

    private static func migrateStep(
        storeType: BackupStoreType,
        data: Data,
        from version: Int
    ) throws -> Data {
        switch version {
        case 1:
            // v1 → v2 migration (placeholder for future)
            return try migrateV1ToV2(storeType: storeType, data: data)
        default:
            throw BackupManagerError.migrationRequired(from: version, to: version + 1)
        }
    }

    /// v1 → v2 migration. Currently a pass-through since v1 is the current version.
    private static func migrateV1ToV2(storeType: BackupStoreType, data: Data) throws -> Data {
        // Future: add actual v1→v2 transformation per store type
        // For now, all v1 data is already compatible with current schema
        return data
    }
}

// MARK: - Migration path

struct MigrationPath: Equatable {
    let from: Int
    let to: Int

    var requiresMigration: Bool { from != to }
    var description: String {
        "v\(from) → v\(to)"
    }
}

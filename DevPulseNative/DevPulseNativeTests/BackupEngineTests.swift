import CryptoKit
import Foundation
import Testing

@testable import DevPulse

// MARK: - Backup model tests

struct BackupModelTests {

    @Test func backupManifestRoundTrip() throws {
        let entries = [
            BackupEntryInfo(
                storeType: .repositorySnapshot,
                schemaVersion: 1,
                dataHash: "abcd1234",
                compressedSizeBytes: 100,
                uncompressedSizeBytes: 500,
                entryCreatedAt: "2026-07-24T12:00:00Z"
            ),
            BackupEntryInfo(
                storeType: .pendingItems,
                schemaVersion: 1,
                dataHash: "efgh5678",
                compressedSizeBytes: 50,
                uncompressedSizeBytes: 200,
                entryCreatedAt: "2026-07-24T12:00:00Z"
            )
        ]

        let inventory = BackupContentInventory(entries: entries)
        #expect(inventory.totalEntryCount == 2)
        #expect(inventory.totalPayloadSizeBytes == 150)
        #expect(inventory.entryOrder.count == 2)

        let metadata = BackupMetadata(
            deviceName: "TestMac",
            systemVersion: "macOS 15.0",
            appVersion: "0.2.0",
            notes: "Test backup"
        )

        let manifest = BackupManifest(
            backupVersion: "1.0",
            createdAt: "2026-07-24T12:00:00Z",
            appVersion: "0.2.0",
            appBuildNumber: "1",
            contentHash: "testhash",
            content: inventory,
            metadata: metadata,
            isIncremental: false
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(BackupManifest.self, from: data)

        #expect(decoded.schemaVersion == BackupSchema.currentVersion)
        #expect(decoded.backupVersion == "1.0")
        #expect(decoded.content.totalEntryCount == 2)
        #expect(decoded.metadata.deviceName == "TestMac")
        #expect(decoded.isIncremental == false)
    }

    @Test func contentHashIsDeterministic() {
        let hashes1 = ["a.json": "hash1", "b.json": "hash2"]
        let hashes2 = ["b.json": "hash2", "a.json": "hash1"]

        let hash1 = BackupManifest.computeContentHash(entryHashes: hashes1)
        let hash2 = BackupManifest.computeContentHash(entryHashes: hashes2)

        #expect(hash1 == hash2, "Content hash must be order-independent")
        #expect(!hash1.isEmpty)
    }

    @Test func backupDirectoryNameFormat() {
        let date = Date(timeIntervalSince1970: 0)
        let name = BackupFileLayout.backupDirectoryName(date: date)
        #expect(name.hasPrefix(BackupFileLayout.backupPrefix))
    }
}

// MARK: - Privacy filter tests

struct BackupPrivacyFilterTests {

    @Test func sanitizePayloadStripsAbsolutePaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let input = "{\"path\": \"\(home)/Projects/MyApp\"}"
        let config = BackupPrivacyConfiguration.sanitized
        let result = BackupPrivacyFilter.sanitizePayload(
            input,
            storeType: .repositorySnapshot,
            config: config
        )
        #expect(!result.contains(home))
        #expect(result.contains("~/Projects/MyApp") || result.contains("\"~"))
    }

    @Test func sanitizePayloadStripsUserNames() {
        let userName = NSUserName()
        let input = "{\"user\": \"\(userName)\", \"path\": \"/Users/\(userName)/Code\"}"
        let config = BackupPrivacyConfiguration.sanitized
        let result = BackupPrivacyFilter.sanitizePayload(
            input,
            storeType: .repositorySnapshot,
            config: config
        )
        #expect(!result.contains("/Users/\(userName)"), "Should strip /Users/username")
    }

    @Test func fullConfigPreservesAllData() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let input = "{\"path\": \"\(home)/Projects\"}"
        let config = BackupPrivacyConfiguration.full
        let result = BackupPrivacyFilter.sanitizePayload(
            input,
            storeType: .repositorySnapshot,
            config: config
        )
        #expect(result.contains(home), "Full config should preserve paths")
    }
}

// MARK: - Retention policy tests

struct BackupRetentionPolicyTests {

    private func makeSummary(id: String, daysAgo: Int, size: Int64, isIncremental: Bool = false) -> BackupSummary {
        BackupSummary(
            id: id,
            createdAt: Date().addingTimeInterval(-Double(daysAgo) * 86400),
            appVersion: "0.2.0",
            backupVersion: 1,
            isIncremental: isIncremental,
            parentBackupID: nil,
            entryCount: 1,
            totalSizeBytes: size,
            contentHash: "hash",
            integrityVerified: true,
            integrityError: nil,
            isCompatible: true,
            storedAt: "/tmp/\(id)"
        )
    }

    @Test func retainsMostRecentFullBackup() {
        let policy = BackupRetentionPolicy()
        let backups = [
            makeSummary(id: "old-full", daysAgo: 10, size: 1000),
            makeSummary(id: "old-inc", daysAgo: 9, size: 100, isIncremental: true),
            makeSummary(id: "new-full", daysAgo: 1, size: 1000),
        ]
        let config = BackupRetentionConfiguration(
            maxBackupCount: 2,
            maxTotalSizeBytes: 100_000,
            minimumFreeSpaceBytes: 0,
            retentionDays: 30,
            autoBackupIntervalSeconds: 86400
        )
        let candidates = policy.evaluateCandidates(backups: backups, config: config)
        let deletedIDs = Set(candidates.map(\.id))
        // Should delete old-full (oldest) but keep new-full (most recent full)
        #expect(deletedIDs.contains("old-full"))
        #expect(!deletedIDs.contains("new-full"))
    }

    @Test func enforcesMaxCount() {
        let policy = BackupRetentionPolicy()
        let backups = (0..<5).map { makeSummary(id: "b\($0)", daysAgo: $0, size: 100) }
        let config = BackupRetentionConfiguration(
            maxBackupCount: 3,
            maxTotalSizeBytes: 100_000,
            minimumFreeSpaceBytes: 0,
            retentionDays: 30,
            autoBackupIntervalSeconds: 86400
        )
        let candidates = policy.evaluateCandidates(backups: backups, config: config)
        #expect(candidates.count == 2, "Should delete oldest 2 backups to reach max count of 3")
    }

    @Test func enforcesMaxSize() {
        let policy = BackupRetentionPolicy()
        let backups = (0..<3).map { makeSummary(id: "b\($0)", daysAgo: $0, size: 100_000) }
        let config = BackupRetentionConfiguration(
            maxBackupCount: 10,
            maxTotalSizeBytes: 150_000,
            minimumFreeSpaceBytes: 0,
            retentionDays: 30,
            autoBackupIntervalSeconds: 86400
        )
        let candidates = policy.evaluateCandidates(backups: backups, config: config)
        #expect(!candidates.isEmpty, "Should delete backups to stay under size limit")
    }
}

// MARK: - Merge resolver tests

struct BackupMergeResolverTests {

    @Test func detectsPathChange() {
        let backupRepos: [String: Any] = [
            "/Users/olduser/Code/MyApp": ["id": "id1", "name": "MyApp"]
        ]
        let currentRepos: [String: Any] = [
            "/Users/newuser/Projects/MyApp": ["id": "id2", "name": "MyApp"]
        ]
        let conflicts = BackupMergeResolver.detectConflicts(
            backupRepositories: backupRepos,
            currentRepositories: currentRepos,
            backupWorkspaces: nil,
            currentWorkspaces: nil
        )
        let pathChanges = conflicts.filter { $0.conflictType == .repositoryPathChanged }
        #expect(!pathChanges.isEmpty, "Should detect path change for same-named repo")
    }

    @Test func detectsDuplicateNames() {
        let backupRepos: [String: Any] = [
            "/path/a/MyApp": ["id": "id1", "name": "MyApp"]
        ]
        let currentRepos: [String: Any] = [
            "/path/b/MyApp": ["id": "id2", "name": "MyApp"]
        ]
        let conflicts = BackupMergeResolver.detectConflicts(
            backupRepositories: backupRepos,
            currentRepositories: currentRepos,
            backupWorkspaces: nil,
            currentWorkspaces: nil
        )
        let dupNameConflicts = conflicts.filter { $0.conflictType == .duplicateRepositoryName }
        #expect(!dupNameConflicts.isEmpty, "Should detect duplicate name at different paths")
    }

    @Test func resolvesPathChangeToMerge() {
        let conflicts = [
            RestoreConflict(
                id: "c1",
                storeType: .repositorySnapshot,
                conflictType: .repositoryPathChanged,
                description: "Path changed",
                resolution: nil
            )
        ]
        let resolutions = BackupMergeResolver.resolveConflicts(conflicts, autoResolve: true)
        #expect(resolutions["c1"] == .merge)
    }

    @Test func resolvesDeviceUserDifference() {
        let conflicts = [
            RestoreConflict(
                id: "c1",
                storeType: .repositorySnapshot,
                conflictType: .deviceUserNameDifferent,
                description: "Different user",
                resolution: nil
            )
        ]
        let resolutions = BackupMergeResolver.resolveConflicts(conflicts, autoResolve: true)
        #expect(resolutions["c1"] == .useBackupVersion)
    }
}

// MARK: - Migration engine tests

struct BackupMigrationEngineTests {

    @Test func noMigrationNeededForCurrentVersion() {
        let path = BackupMigrationEngine.migrationNeeded(
            from: BackupSchema.currentVersion,
            to: BackupSchema.currentVersion
        )
        #expect(path == nil)
    }

    @Test func rejectsFutureVersions() {
        let path = BackupMigrationEngine.migrationNeeded(
            from: BackupSchema.currentVersion + 1,
            to: BackupSchema.currentVersion
        )
        #expect(path == nil, "Future versions should return nil (not migratable)")
    }

    @Test func migratesV1ToCurrent() throws {
        let data = try JSONEncoder().encode(["test": "data"])
        let migrated = try BackupMigrationEngine.migrateEntry(
            storeType: .repositorySnapshot,
            data: data,
            fromVersion: 1
        )
        let decoded = try JSONSerialization.jsonObject(with: migrated) as? [String: String]
        #expect(decoded?["test"] == "data")
    }
}

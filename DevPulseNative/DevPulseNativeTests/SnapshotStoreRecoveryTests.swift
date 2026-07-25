import Foundation
import Testing
@testable import DevPulse

@Suite("SnapshotStoreRecovery")
struct SnapshotStoreRecoveryTests {
    // ────────────────────────────────────────────────────────────────
    // MARK: - Helpers (copied from SharedSnapshotStoreTests)
    // ────────────────────────────────────────────────────────────────

    private func store(in directory: URL, now: Date) -> SharedSnapshotStore {
        SharedSnapshotStore(
            directoryURL: directory,
            fileName: "repositories.json",
            now: { now }
        )
    }

    private func fixture(label: String, timestamp: String) -> AppGroupData {
        let repository = RepositorySnapshot(
            id: label,
            name: "Repository \(label)",
            path: "/tmp/SharedSnapshotStoreTests/\(label)",
            workspaceKind: nil,
            branch: "main",
            status: .clean,
            modifiedFileCount: 1,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: nil,
            unstagedFileCount: nil,
            conflictedFileCount: nil,
            aheadCount: nil,
            behindCount: nil,
            hasUpstream: nil,
            changedFileCount: 1,
            changedFilesPreview: ["\(label).swift"],
            risk: .low,
            lastScannedAt: timestamp,
            dataSource: .current,
            lastSuccessfulScanAt: timestamp,
            lastChangedAt: nil,
            lastCommitID: nil,
            lastCommitSummary: nil,
            lastCommitMetadataAvailable: true,
            lastActivityAt: timestamp,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )
        return AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: timestamp,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary.build(from: [repository]),
            repositories: [repository],
            recentActivityEvents: nil,
            repositoryUnavailableSinceByPath: nil,
            storageRevision: 0,
            persistenceState: .committed,
            pendingItemWidgetSummary: nil,
            appVersion: RepositorySnapshotSchema.currentAppVersion,
            storageFormatVersion: RepositorySnapshotSchema.storageFormatVersion
        )
    }

    private func requireSuccess<T>(_ result: Result<T, AppGroupStoreError>) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw SnapshotTestFailure.unexpectedStoreError(error.localizedDescription)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-snapshot-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func temporaryFiles(in directory: URL, prefix: String) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix(prefix) } ?? []
    }

    private static func date(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601)!
    }

    private func date(_ iso8601: String) -> Date {
        Self.date(iso8601)
    }

    private func legacyV1JSON(from snapshot: AppGroupData) throws -> Data {
        var object = try jsonObject(from: snapshot)
        object["schemaVersion"] = RepositorySnapshotSchema.oldestMigratableVersion
        object.removeValue(forKey: "writtenAt")
        object.removeValue(forKey: "storageRevision")
        object.removeValue(forKey: "persistenceState")
        object.removeValue(forKey: "appVersion")
        object.removeValue(forKey: "storageFormatVersion")
        var repositories = try #require(object["repositories"] as? [[String: Any]])
        repositories[0].removeValue(forKey: "dataSource")
        object["repositories"] = repositories
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func jsonObject(from snapshot: AppGroupData) throws -> [String: Any] {
        let data = try JSONEncoder().encode(snapshot)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func crossRepositoryOverflowJSON(schemaVersion: Int) throws -> Data {
        var object = try jsonObject(
            from: fixture(label: "overflow-A", timestamp: "2026-07-18T09:00:00Z")
        )
        object["schemaVersion"] = schemaVersion
        object["storageRevision"] = 1

        var repositories = try #require(object["repositories"] as? [[String: Any]])
        var first = try #require(repositories.first)
        first["modifiedFileCount"] = Int.max
        first["changedFileCount"] = Int.max

        var second = first
        second["id"] = "overflow-B"
        second["name"] = "Repository overflow-B"
        second["path"] = "/tmp/SnapshotStoreRecoveryTests/overflow-B"
        second["changedFilesPreview"] = ["overflow-B.swift"]
        repositories = [first, second]
        object["repositories"] = repositories
        object["scanSummary"] = [
            "totalRepositories": 2,
            "changedRepositories": 2,
            "totalChangedFiles": Int.max,
            "errorRepositories": 0
        ]

        if schemaVersion == RepositorySnapshotSchema.oldestMigratableVersion {
            object.removeValue(forKey: "writtenAt")
            object.removeValue(forKey: "storageRevision")
            object.removeValue(forKey: "persistenceState")
            object.removeValue(forKey: "appVersion")
            object.removeValue(forKey: "storageFormatVersion")
            object["repositories"] = repositories.map { repository in
                var legacy = repository
                legacy.removeValue(forKey: "dataSource")
                return legacy
            }
        }

        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Tests
    // ────────────────────────────────────────────────────────────────

    @Test func crossProcessWriteDetection() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let store = self.store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let original = fixture(label: "A", timestamp: "2026-07-18T09:00:00Z")
        try requireSuccess(store.commit(original))

        // Simulate stale observed revision: after commit, revision is 1,
        // so observing revision 0 should be rejected.
        let staleCommit = fixture(label: "B", timestamp: "2026-07-18T10:01:00Z")
        let result = store.commit(staleCommit, observedStorageRevision: 0)

        switch result {
        case .success:
            Issue.record("Expected crossProcessWriteDetected error, got success")
        case .failure(let error):
            guard case .crossProcessWriteDetected = error else {
                Issue.record("Expected crossProcessWriteDetected error, got \(error)")
                return
            }
        }
    }

    @Test func autoRebuildCreatesBackupFile() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let store = self.store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try "damaged".data(using: .utf8)!.write(to: store.primaryURL)
        try "damaged".data(using: .utf8)!.write(to: store.backupURL)

        let read = try requireSuccess(store.load())
        #expect(read.source == .migratedPrimary)
        #expect(read.snapshot.persistenceState == .recovered)
        #expect(FileManager.default.fileExists(atPath: store.backupURL.path))
        #expect(FileManager.default.fileExists(atPath: store.primaryURL.path))

        // Both files now contain valid data
        let primaryBytes = try Data(contentsOf: store.primaryURL)
        let backupBytes = try Data(contentsOf: store.backupURL)
        #expect(!primaryBytes.isEmpty)
        #expect(primaryBytes == backupBytes)
    }

    @Test func futureSchemaRejected() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let store = self.store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let payload = fixture(label: "future", timestamp: "2026-07-18T09:00:00Z")
        try requireSuccess(store.commit(payload))

        // Modify the stored data to have a future schema version
        var object = try jsonObject(from: payload)
        object["schemaVersion"] = RepositorySnapshotSchema.version + 1
        let futureBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try futureBytes.write(to: store.primaryURL)

        let result = store.load()
        switch result {
        case .success:
            Issue.record("Expected schemaVersionMismatch error")
        case .failure(let error):
            guard case .schemaVersionMismatch = error else {
                Issue.record("Expected schemaVersionMismatch, got \(error)")
                return
            }
        }
    }

    @Test func temporaryFileCleanupAfterInterruptedWrite() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let store = self.store(in: directory, now: date("2026-07-18T10:00:00Z"))

        // Write a temporary file matching the store's prefix
        let tempURL = directory.appendingPathComponent("\(store.temporaryFilePrefix)stale-\(UUID().uuidString)")
        try "staging".data(using: .utf8)!.write(to: tempURL)
        #expect(!temporaryFiles(in: directory, prefix: store.temporaryFilePrefix).isEmpty)

        try requireSuccess(store.cleanupTemporaryFiles())
        #expect(temporaryFiles(in: directory, prefix: store.temporaryFilePrefix).isEmpty)
    }

    @Test func emptyBackupWithValidPrimary() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let store = self.store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let payload = fixture(label: "primary-only", timestamp: "2026-07-18T09:00:00Z")
        try requireSuccess(store.commit(payload))

        // Write empty data to backup path (should not affect primary load)
        try Data().write(to: store.backupURL)

        let read = try requireSuccess(store.load())
        #expect(read.source == .primary)
        #expect(read.snapshot.repositories.first?.id == "primary-only")
        #expect(read.snapshot.persistenceState == .committed)
    }

    @Test func primaryMissingValidBackup() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let store = self.store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let payload = fixture(label: "backup-only", timestamp: "2026-07-18T09:00:00Z")
        try requireSuccess(store.commit(payload))

        // Remove primary, backup still exists (commit creates backup)
        try FileManager.default.removeItem(at: store.primaryURL)
        #expect(!FileManager.default.fileExists(atPath: store.primaryURL.path))
        #expect(FileManager.default.fileExists(atPath: store.backupURL.path))

        let read = try requireSuccess(store.load())
        #expect(read.source == .backup)
        #expect(read.snapshot.persistenceState == .recovered)
        #expect(read.snapshot.repositories.first?.id == "backup-only")
        // Recovered snapshots mark data as non-current
        #expect(read.snapshot.repositories.first?.resolvedDataSource != .current)
    }

    @Test func commitAfterRecoveryAdvancesRevision() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let store = self.store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let payload = fixture(label: "original", timestamp: "2026-07-18T09:00:00Z")
        try requireSuccess(store.commit(payload))

        // Corrupt primary, load from backup
        try "corrupted".data(using: .utf8)!.write(to: store.primaryURL)
        let recovered = try requireSuccess(store.load())
        #expect(recovered.source == .backup)
        let recoveredRevision = recovered.snapshot.storageRevision

        // Commit fresh data after recovery
        let freshPayload = fixture(label: "fresh", timestamp: "2026-07-18T10:01:00Z")
        let committed = try requireSuccess(store.commit(freshPayload))
        #expect(committed.storageRevision >= recoveredRevision)
        #expect(committed.persistenceState == .committed)

        // Verify on reload
        let reloaded = try requireSuccess(store.load())
        #expect(reloaded.source == .primary)
        #expect(reloaded.snapshot.persistenceState == .committed)
        #expect(reloaded.snapshot.storageRevision >= committed.storageRevision)
        #expect(reloaded.snapshot.repositories.first?.id == "fresh")
    }

    @Test func legacyV1Migration() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let store = self.store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let payload = fixture(label: "legacy", timestamp: "2026-07-18T09:00:00Z")
        let legacyBytes = try legacyV1JSON(from: payload)
        try legacyBytes.write(to: store.primaryURL)

        let read = try requireSuccess(store.load())
        #expect(read.source == .migratedPrimary)
        #expect(read.snapshot.schemaVersion == RepositorySnapshotSchema.version)
        #expect(read.snapshot.persistenceState == .migrated)
    }

    @Test func widgetContentFromRecoveredSnapshot() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let snapshot = AppGroupData.empty().withPersistenceMetadata(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: now,
            writtenAt: now,
            lastSuccessfulRefreshAt: nil,
            storageRevision: 0,
            persistenceState: .recovered
        )
        let feed = ActivityTimelineFeed(state: .neverScanned, items: [])
        let entry = WidgetEntry.content(snapshot: snapshot, feed: feed)

        // Recovered snapshot is loadable (.ready) with degraded trust assessment.
        #expect(entry.loadState == .ready)
        #expect(entry.loadFailure != nil)
        #expect(entry.loadFailure?.title == "数据已恢复")
    }
}

private enum SnapshotTestFailure: Error, CustomStringConvertible {
    case unexpectedStoreError(String)

    var description: String {
        switch self {
        case .unexpectedStoreError(let reason):
            return "Unexpected store error: \(reason)"
        }
    }
}

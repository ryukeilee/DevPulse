import Foundation
import Testing
@testable import DevPulse

@Suite("PersistenceRecovery")
struct PersistenceRecoveryTests {
    // MARK: - PendingItemStore corruption recovery

    @Test func pendingItemStoreCorruptJSONPersistsEmptyArchive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-pending-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("pending-items.json")
        try "corrupt json {{invalid}".data(using: .utf8)!.write(to: fileURL)

        let store = PendingItemStore(fileURL: fileURL)
        let result = store.load()

        // Load should succeed with empty archive (recovery)
        guard case .success(let archive) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(archive.items.isEmpty)

        // File should now contain valid JSON (empty archive), not the corrupt data
        let fileData = try Data(contentsOf: fileURL)
        #expect(!fileData.isEmpty)
        let decoded = try JSONDecoder().decode(PendingItemArchive.self, from: fileData)
        #expect(decoded.items.isEmpty)
        #expect(decoded.schemaVersion == PendingItemArchive.currentSchemaVersion)
    }

    @Test func pendingItemStoreValidArchiveUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-pending-valid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("pending-items.json")
        let item = PendingItem(
            id: "test-1",
            source: .staleRepository,
            severity: .medium,
            repositoryID: "repo-1",
            repositoryName: "TestRepo",
            workspaceID: nil,
            workspaceName: nil,
            title: "Test pending item",
            explanation: "For testing",
            evidence: [],
            firstDetectedAt: ISO8601DateFormatter().string(from: Date()),
            lastConfirmedAt: nil,
            status: .active,
            snoozedUntil: nil,
            duration: 0,
            lastTransition: nil
        )
        let archive = PendingItemArchive(items: [item])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let originalData = try encoder.encode(archive)
        try originalData.write(to: fileURL)

        let store = PendingItemStore(fileURL: fileURL)
        let result = store.load()

        guard case .success(let loaded) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(loaded.items.count == 1)
        #expect(loaded.items[0].id == "test-1")

        // File content should remain unchanged (valid data not replaced)
        let fileData = try Data(contentsOf: fileURL)
        #expect(fileData == originalData)
    }

    // MARK: - PendingItemNotificationStore corruption recovery

    @Test func pendingItemNotifStoreCorruptJSONPersistsEmptyArchive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-notif-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("pending-item-notifications.json")
        try "garbage data !@#$%".data(using: .utf8)!.write(to: fileURL)

        let store = PendingItemNotificationStore(fileURL: fileURL)
        let result = store.load()

        guard case .success(let archive) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(archive.notificationStates.isEmpty)

        // File should now contain valid JSON (empty archive)
        let fileData = try Data(contentsOf: fileURL)
        #expect(!fileData.isEmpty)
        let decoded = try JSONDecoder().decode(PendingItemNotificationArchive.self, from: fileData)
        #expect(decoded.notificationStates.isEmpty)
    }

    @Test func pendingItemNotifStoreValidArchiveUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-notif-valid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("pending-item-notifications.json")
        let archive = PendingItemNotificationArchive(
            notificationStates: ["item-1": PendingItemNotificationState(
                lastNotifiedAt: ISO8601DateFormatter().string(from: Date()),
                notificationCount: 1,
                lastSeverityNotified: .medium,
                coolDownUntil: nil
            )],
            suppressionEnabled: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let originalData = try encoder.encode(archive)
        try originalData.write(to: fileURL)

        let store = PendingItemNotificationStore(fileURL: fileURL)
        let result = store.load()

        guard case .success(let loaded) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(loaded.notificationStates["item-1"] != nil)

        let fileData = try Data(contentsOf: fileURL)
        #expect(fileData == originalData)
    }

    // MARK: - RepositoryHistoryStore I/O error recovery

    @Test func historyStoreIOErrorRecoversWithFreshArchive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-history-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("repository-history.json")
        // Write an empty file (valid but empty data array) to test read recovery
        try Data().write(to: fileURL)

        let store = RepositoryHistoryStore(
            fileURL: fileURL,
            config: .minimal
        )
        switch store.load(for: "nonexistent") {
        case .success(let entries):
            #expect(entries.isEmpty)
        case .failure(let error):
            Issue.record("Expected success, got \(error)")
        }
    }

    // MARK: - Widget persistenceState awareness

    @Test func widgetContentRecoveredState() throws {
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

        #expect(entry.loadState == .ready)
        #expect(entry.loadFailure != nil)
        #expect(entry.loadFailure?.title == "数据已恢复")
    }

    @Test func widgetContentMigratedState() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let snapshot = AppGroupData.empty().withPersistenceMetadata(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: now,
            writtenAt: now,
            lastSuccessfulRefreshAt: nil,
            storageRevision: 0,
            persistenceState: .migrated
        )
        let feed = ActivityTimelineFeed(state: .neverScanned, items: [])
        let entry = WidgetEntry.content(snapshot: snapshot, feed: feed)

        #expect(entry.loadState == .ready)
        #expect(entry.loadFailure != nil)
        #expect(entry.loadFailure?.title == "数据已迁移")
    }

    @Test func widgetContentCommittedState() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let snapshot = AppGroupData.empty().withPersistenceMetadata(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: now,
            writtenAt: now,
            lastSuccessfulRefreshAt: now,
            storageRevision: 1,
            persistenceState: .committed
        )
        let feed = ActivityTimelineFeed(state: .neverScanned, items: [])
        let entry = WidgetEntry.content(snapshot: snapshot, feed: feed)

        #expect(entry.loadState == .ready)
        #expect(entry.loadFailure == nil)
    }
}

extension Result {
    func get() throws -> Success {
        switch self {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

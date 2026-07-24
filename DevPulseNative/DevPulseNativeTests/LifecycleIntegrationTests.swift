import Foundation
import Testing
@testable import DevPulse

// MARK: - Lifecycle Integration Tests
//
// Covers: startup diagnostics, generation isolation, widget timeline reload,
// and snapshot persistence recovery.

// MARK: - Mocks and helpers

private final class MockSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _loadResult: Result<SharedSnapshotRead, AppGroupStoreError>?
    private var _commitResult: Result<AppGroupData, AppGroupStoreError>?
    private var _cleanupResult: Result<Void, AppGroupStoreError>?
    private var _commitCount = 0
    private var _loadCount = 0

    var commitCount: Int { lock.withLock { _commitCount } }
    var loadCount: Int { lock.withLock { _loadCount } }

    func setLoadResult(_ result: Result<SharedSnapshotRead, AppGroupStoreError>) {
        lock.withLock { _loadResult = result }
    }

    func setCommitResult(_ result: Result<AppGroupData, AppGroupStoreError>) {
        lock.withLock { _commitResult = result }
    }

    func setCleanupResult(_ result: Result<Void, AppGroupStoreError>) {
        lock.withLock { _cleanupResult = result }
    }

    func load() -> Result<SharedSnapshotRead, AppGroupStoreError> {
        lock.withLock { _loadCount += 1; return _loadResult ?? .failure(.readFailed("not set")) }
    }

    func commit(_ data: AppGroupData) -> Result<AppGroupData, AppGroupStoreError> {
        lock.withLock { _commitCount += 1; return _commitResult ?? .failure(.writeFailed("not set")) }
    }

    func cleanupTemporaryFiles() -> Result<Void, AppGroupStoreError> {
        lock.withLock { _cleanupResult ?? .success(()) }
    }
}

// Helper: a minimal valid AppGroupData for testing
private func emptySnapshot(
    schemaVersion: Int = RepositorySnapshotSchema.version,
    storageRevision: UInt64 = 1
) -> AppGroupData {
    AppGroupData(
        schemaVersion: schemaVersion,
        generatedAt: DateFormatting.nowISO(),
        writtenAt: DateFormatting.nowISO(),
        scanSummary: ScanSummary(totalRepositories: 0, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
        repositories: [],
        storageRevision: storageRevision,
        persistenceState: .committed
    )
}

// ────────────────────────────────────────────────────────────────────
// MARK: - StartupDiagnostics tests
// ────────────────────────────────────────────────────────────────────

@Suite("StartupDiagnostics")
struct StartupDiagnosticsTests {

    @Test("Self-check passes when app group is available")
    func selfCheckAppGroup() {
        // Note: In a test environment without App Group entitlements,
        // AppGroupStore.isAvailable typically returns false.
        let check = StartupDiagnostics.checkAppGroup()
        // We verify the check produces a deterministic result, not
        // whether it passes or fails (that depends on test environment).
        #expect(check.name == "appGroup")
        #expect(check.recovered == false)
        #expect(check.passed == AppGroupStore.isAvailable)
    }

    @Test("Snapshot decode check reports failure for missing file")
    func snapshotDecodeMissing() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-startup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let check = StartupDiagnostics.checkSnapshotDecode(
            containerURL: tempDir,
            snapshotStoreFactory: { url, name in
                SharedSnapshotStore(directoryURL: url, fileName: name)
            }
        )
        #expect(check.name == "snapshotDecode")
        #expect(check.passed == false)
        #expect(check.detail.contains("snapshotMissing") || check.detail.contains("missing"))
    }

    @Test("Temp file cleanup succeeds even when directory is empty")
    func tempCleanupEmpty() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-startup-cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let check = StartupDiagnostics.attemptTemporaryFileCleanup(
            containerURL: tempDir,
            snapshotStoreFactory: { url, name in
                SharedSnapshotStore(directoryURL: url, fileName: name)
            }
        )
        #expect(check.name == "tempCleanup")
        #expect(check.recovered == true)
    }

    @Test("Git check reports availability")
    func gitCheck() {
        let check = StartupDiagnostics.checkGit()
        #expect(check.name == "git")
        // git is expected to be available in CI or developer environment
        #expect(check.passed == ProcessRunner.isGitAvailable())
    }

    @Test("Snapshot writable check is deterministic")
    func snapshotWritable() {
        let check = StartupDiagnostics.checkSnapshotWritable()
        #expect(check.name == "snapshotWritable")
        #expect(check.recovered == false)
    }

    @Test("Schema consistency check handles empty directory")
    func schemaConsistencyEmpty() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-startup-schema-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let check = StartupDiagnostics.checkSchemaConsistency(
            containerURL: tempDir,
            snapshotStoreFactory: { url, name in
                SharedSnapshotStore(directoryURL: url, fileName: name)
            }
        )
        #expect(check.name == "schemaConsistency")
        #expect(check.passed) // no files to compare => consistent
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Generation isolation tests
// ────────────────────────────────────────────────────────────────────

@Suite("RefreshEngine Generation Isolation")
struct GenerationIsolationTests {

    @Test("advanceGeneration produces unique tokens")
    func advanceGenerationUniqueness() async {
        let engine = RefreshEngine()
        let token1 = await engine.advanceGenerationForTesting()
        let token2 = await engine.advanceGenerationForTesting()

        #expect(token1.generation != token2.generation || token1.epoch != token2.epoch)
    }

    @Test("isInvalidated returns true for a stale token")
    func isInvalidatedStaleToken() async {
        let engine = RefreshEngine()
        let token1 = await engine.advanceGenerationForTesting()
        // Advance again so token1 is stale
        let _ = await engine.advanceGenerationForTesting()

        let invalidated = await engine.isInvalidatedForTesting(token: token1)
        #expect(invalidated)
    }

    @Test("isInvalidated returns false for the current token")
    func isInvalidatedCurrentToken() async {
        let engine = RefreshEngine()
        let token = await engine.advanceGenerationForTesting()

        let invalidated = await engine.isInvalidatedForTesting(token: token)
        #expect(invalidated == false)
    }

    @Test("isInvalidated returns true when cancelled")
    func isInvalidatedCancelled() async {
        let engine = RefreshEngine()
        let token = await engine.advanceGenerationForTesting()
        await engine.cancel()

        let invalidated = await engine.isInvalidatedForTesting(token: token)
        #expect(invalidated)
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Snapshot persistence recovery tests
// ────────────────────────────────────────────────────────────────────

@Suite("Snapshot Persistence Recovery")
struct SnapshotPersistenceRecoveryTests {

    @Test("Recovery commits a minimal empty snapshot on failure")
    func recoveryEmptySnapshot() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: tempDir,
            fileName: "repositories.json"
        )

        let attempted = StartupDiagnostics.attemptSnapshotRecovery(store: store)
        #expect(attempted)

        // Verify the recovery snapshot was committed
        switch store.load() {
        case .success(let read):
            #expect(read.snapshot.persistenceState == .recovered)
            #expect(read.snapshot.storageRevision > 0)
            #expect(read.snapshot.persistenceState == .recovered)
            #expect(read.snapshot.repositories.isEmpty)
            #expect(read.snapshot.schemaVersion == RepositorySnapshotSchema.version)
        case .failure(let error):
            Issue.record("Recovery snapshot should be readable, got: \(error)")
        }
    }

    @Test("Full self-check with recovery leaves store in consistent state")
    func fullSelfCheckWithRecovery() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-selfcheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: tempDir,
            fileName: "repositories.json"
        )

        // Commit a valid snapshot first
        let initial = emptySnapshot(storageRevision: 1)
        let committed = try #require(try? store.commit(initial).get())
        #expect(committed.storageRevision == 1)

        // Verify temp cleanup check passes
        let cleanupCheck = StartupDiagnostics.attemptTemporaryFileCleanup(
            containerURL: tempDir,
            snapshotStoreFactory: { url, name in
                SharedSnapshotStore(directoryURL: url, fileName: name)
            }
        )
        #expect(cleanupCheck.passed)

        // Verify decode check passes
        let decodeCheck = StartupDiagnostics.checkSnapshotDecode(
            containerURL: tempDir,
            snapshotStoreFactory: { url, name in
                SharedSnapshotStore(directoryURL: url, fileName: name)
            }
        )
        #expect(decodeCheck.passed)

        // Verify schema consistency
        let schemaCheck = StartupDiagnostics.checkSchemaConsistency(
            containerURL: tempDir,
            snapshotStoreFactory: { url, name in
                SharedSnapshotStore(directoryURL: url, fileName: name)
            }
        )
        #expect(schemaCheck.passed)
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Widget timeline reload integration tests
// ────────────────────────────────────────────────────────────────────

@Suite("Widget Timeline Reload")
struct WidgetTimelineReloadTests {

    @Test("AppGroupStore.reloadWidgets is callable without crash")
    func reloadWidgetsCallable() {
        // This test verifies the method exists and doesn't crash.
        // In a test environment without WidgetKit, the `#if canImport` guard
        // makes this a no-op.
        AppGroupStore.reloadWidgets()
        #expect(true)
    }
}



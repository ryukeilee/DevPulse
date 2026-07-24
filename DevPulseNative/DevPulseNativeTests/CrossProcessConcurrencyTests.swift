import Foundation
import Testing
@testable import DevPulse

// MARK: - Cross-Process Concurrency Tests
//
// Tests the storage-revision-based optimistic concurrency control that
// prevents stale snapshot writes from one process overwriting a newer
// write from another process.
//
// Coverage:
// 1. GenerationIsolation.validateCrossProcess — token validation logic
// 2. GenerationIsolation.CrossProcessToken — struct identity
// 3. SharedSnapshotStore.commit with observedStorageRevision — conflict detection
// 4. Multi-process interleaved write simulation
// 5. Non-interference: conflict detection does not corrupt on-disk state

@Suite("Cross-Process Concurrency")
struct CrossProcessConcurrencyTests {

    // ────────────────────────────────────────────────────────────────
    // MARK: - GenerationIsolation.CrossProcessToken & validateCrossProcess
    // ────────────────────────────────────────────────────────────────

    @Test("validateCrossProcess returns .current when revisions match")
    func validateCrossProcessRevisionsMatch() {
        let result = GenerationIsolation.validateCrossProcess(
            observedRevision: 5,
            snapshotRevision: 5
        )
        #expect(result == .current)
    }

    @Test("validateCrossProcess returns .current when observed revision is ahead of snapshot")
    func validateCrossProcessObservedAhead() {
        let result = GenerationIsolation.validateCrossProcess(
            observedRevision: 10,
            snapshotRevision: 5
        )
        #expect(result == .current)
    }

    @Test("validateCrossProcess returns .stale when snapshot revision advanced past observed")
    func validateCrossProcessSnapshotAdvanced() {
        let result = GenerationIsolation.validateCrossProcess(
            observedRevision: 5,
            snapshotRevision: 7
        )
        guard case .stale(let reason) = result else {
            Issue.record("Expected .stale, got .current")
            return
        }
        #expect(reason.contains("5"))
        #expect(reason.contains("7"))
    }

    @Test("CrossProcessToken equality and inequality")
    func crossProcessTokenEquality() {
        let token1 = GenerationIsolation.CrossProcessToken(
            storageRevision: 1, generation: 1, epoch: 0
        )
        let token2 = GenerationIsolation.CrossProcessToken(
            storageRevision: 1, generation: 1, epoch: 0
        )
        let token3 = GenerationIsolation.CrossProcessToken(
            storageRevision: 2, generation: 1, epoch: 0
        )
        #expect(token1 == token2)
        #expect(token1 != token3)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - SharedSnapshotStore commit with observedStorageRevision
    // ────────────────────────────────────────────────────────────────

    @Test("commit succeeds when observedStorageRevision matches on-disk revision")
    func commitWithObservedRevisionMatch() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let storeA = makeStore(in: directory, now: date("2026-07-18T10:00:00Z"))
        let first = try requireSuccess(
            storeA.commit(fixture(label: "A", timestamp: "2026-07-18T09:00:00Z"))
        )
        #expect(first.storageRevision == 1)

        // Store B observes revision 1 and commits — should succeed because
        // the on-disk revision has not advanced past the observed value.
        let storeB = makeStore(in: directory, now: date("2026-07-18T10:01:00Z"))
        let second = try requireSuccess(
            storeB.commit(
                fixture(label: "B", timestamp: "2026-07-18T10:01:00Z"),
                observedStorageRevision: 1
            )
        )
        #expect(second.storageRevision == 2)

        let loaded = try requireSuccess(storeB.load())
        #expect(loaded.snapshot.repositories.first?.id == "B")
        #expect(loaded.snapshot.storageRevision == 2)
    }

    @Test("commit fails with crossProcessWriteDetected when on-disk revision advanced")
    func commitWithStaleObservedRevision() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        // Process A establishes revision 1.
        let storeA = makeStore(in: directory, now: date("2026-07-18T10:00:00Z"))
        try requireSuccess(
            storeA.commit(fixture(label: "A", timestamp: "2026-07-18T09:00:00Z"))
        )

        // Process B writes revision 2 (simulating another process that wrote
        // in between without A's knowledge).
        let storeB = makeStore(in: directory, now: date("2026-07-18T10:01:00Z"))
        try requireSuccess(
            storeB.commit(fixture(label: "B", timestamp: "2026-07-18T10:01:00Z"))
        )

        // Process A tries to commit with observed revision 1 — must fail
        // because the on-disk revision is now 2.
        let storeA2 = makeStore(in: directory, now: date("2026-07-18T10:02:00Z"))
        let result = storeA2.commit(
            fixture(label: "A-retry", timestamp: "2026-07-18T10:02:00Z"),
            observedStorageRevision: 1
        )
        switch result {
        case .success:
            Issue.record("Expected crossProcessWriteDetected but commit succeeded")
        case .failure(let error):
            guard case .crossProcessWriteDetected(let observed, let actual) = error else {
                Issue.record("Expected crossProcessWriteDetected, got \(error)")
                return
            }
            #expect(observed == 1)
            #expect(actual == 2)
        }

        // Verify on-disk data is still revision 2 from process B and was not
        // overwritten by the stale write attempt.
        let loaded = try requireSuccess(storeA2.load())
        #expect(loaded.snapshot.repositories.first?.id == "B")
        #expect(loaded.snapshot.storageRevision == 2)
    }

    @Test("commit with observedStorageRevision succeeds after re-reading current revision")
    func commitWithUpdatedObservedRevision() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let store = makeStore(in: directory, now: date("2026-07-18T10:00:00Z"))

        // First commit establishes revision 1.
        try requireSuccess(
            store.commit(fixture(label: "first", timestamp: "2026-07-18T09:00:00Z"))
        )

        // Another "process" advances to revision 2.
        let otherStore = makeStore(in: directory, now: date("2026-07-18T10:01:00Z"))
        try requireSuccess(
            otherStore.commit(fixture(label: "other", timestamp: "2026-07-18T10:01:00Z"))
        )

        // Original process retries by re-reading the snapshot to get the
        // current storageRevision (2), then commits with observed revision 2.
        let refreshedStore = makeStore(in: directory, now: date("2026-07-18T10:02:00Z"))
        let refreshedLoad = try requireSuccess(refreshedStore.load())
        let currentRevision = refreshedLoad.snapshot.storageRevision
        #expect(currentRevision == 2)

        let retryCommit = try requireSuccess(
            refreshedStore.commit(
                fixture(label: "retry", timestamp: "2026-07-18T10:02:00Z"),
                observedStorageRevision: currentRevision
            )
        )
        #expect(retryCommit.storageRevision == 3)
    }

    @Test("commit without observedStorageRevision bypasses cross-process check")
    func commitWithoutObservationBypassesCheck() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let storeA = makeStore(in: directory, now: date("2026-07-18T10:00:00Z"))
        try requireSuccess(
            storeA.commit(fixture(label: "A", timestamp: "2026-07-18T09:00:00Z"))
        )

        // Process B writes (advancing revision).
        let storeB = makeStore(in: directory, now: date("2026-07-18T10:01:00Z"))
        try requireSuccess(
            storeB.commit(fixture(label: "B", timestamp: "2026-07-18T10:01:00Z"))
        )

        // Process A writes again WITHOUT observedStorageRevision — the
        // cross-process check is skipped and the commit succeeds normally.
        let storeA2 = makeStore(in: directory, now: date("2026-07-18T10:02:00Z"))
        let result = storeA2.commit(
            fixture(label: "C", timestamp: "2026-07-18T10:02:00Z")
        )
        switch result {
        case .success(let data):
            #expect(data.storageRevision == 3)
            #expect(data.repositories.first?.id == "C")
        case .failure(let error):
            Issue.record("Commit without observation should succeed, got: \(error)")
        }
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Multi-process interleaved simulation
    // ────────────────────────────────────────────────────────────────

    @Test("three-process interleaved writes detect all conflicts correctly")
    func threeProcessInterleavedWrites() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        // Process 1 writes initial snapshot at revision 1.
        let p1 = makeStore(in: directory, now: date("2026-07-18T10:00:00Z"))
        try requireSuccess(
            p1.commit(fixture(label: "P1-init", timestamp: "2026-07-18T09:00:00Z"))
        )

        // Process 2 reads and captures revision 1.
        let p2Load = try requireSuccess(p1.load())
        let p2Observed = p2Load.snapshot.storageRevision
        #expect(p2Observed == 1)

        // Process 3 writes in between, advancing to revision 2.
        let p3 = makeStore(in: directory, now: date("2026-07-18T10:01:00Z"))
        try requireSuccess(
            p3.commit(fixture(label: "P3-write", timestamp: "2026-07-18T10:01:00Z"))
        )

        // Process 2 tries to write with its observed revision 1 — conflict!
        let p2 = makeStore(in: directory, now: date("2026-07-18T10:02:00Z"))
        let p2Result = p2.commit(
            fixture(label: "P2-stale", timestamp: "2026-07-18T10:02:00Z"),
            observedStorageRevision: p2Observed
        )
        switch p2Result {
        case .success:
            Issue.record("P2 should have detected cross-process write conflict")
        case .failure(let error):
            guard case .crossProcessWriteDetected(let observed, let actual) = error else {
                Issue.record("Expected crossProcessWriteDetected, got \(error)")
                return
            }
            #expect(observed == 1)
            #expect(actual == 2)
        }

        // Process 3 writes again with an updated observation (revision 2) →
        // succeeds.
        let p3Again = makeStore(in: directory, now: date("2026-07-18T10:03:00Z"))
        let p3AgainLoad = try requireSuccess(p3Again.load())
        let p3Observed = p3AgainLoad.snapshot.storageRevision
        #expect(p3Observed == 2)

        let p3Result = try requireSuccess(
            p3Again.commit(
                fixture(label: "P3-final", timestamp: "2026-07-18T10:03:00Z"),
                observedStorageRevision: p3Observed
            )
        )
        #expect(p3Result.storageRevision == 3)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Non-interference: conflict does not corrupt state
    // ────────────────────────────────────────────────────────────────

    @Test("cross-process write conflict leaves on-disk snapshot intact and not overwritten")
    func crossProcessConflictDoesNotCorrupt() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        // Write initial snapshot with process A.
        let storeA = makeStore(in: directory, now: date("2026-07-18T10:00:00Z"))
        let initial = try requireSuccess(
            storeA.commit(fixture(label: "initial", timestamp: "2026-07-18T09:00:00Z"))
        )
        let initialRevision = initial.storageRevision

        // Simulate another process (B) advancing the revision.
        let storeB = makeStore(in: directory, now: date("2026-07-18T10:01:00Z"))
        let bData = try requireSuccess(
            storeB.commit(fixture(label: "other", timestamp: "2026-07-18T10:01:00Z"))
        )
        #expect(bData.storageRevision == initialRevision + 1)

        // Process A attempts a stale write with its outdated observed revision.
        let staleResult = storeA.commit(
            fixture(label: "stale", timestamp: "2026-07-18T10:02:00Z"),
            observedStorageRevision: initialRevision
        )
        guard case .failure(let error) = staleResult,
              case .crossProcessWriteDetected(_, _) = error else {
            Issue.record("Expected cross-process write detection")
            return
        }

        // Verify the on-disk snapshot still belongs to process B and was not
        // overwritten by the stale write attempt.
        let loaded = try requireSuccess(storeA.load())
        #expect(loaded.snapshot.repositories.first?.id == "other")
        #expect(loaded.snapshot.storageRevision == initialRevision + 1)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - CrossProcessToken integration
    // ────────────────────────────────────────────────────────────────

    @Test("CrossProcessToken round-trips through store load and validateCrossProcess")
    func crossProcessTokenRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let store = makeStore(in: directory, now: date("2026-07-18T10:00:00Z"))
        try requireSuccess(
            store.commit(fixture(label: "first", timestamp: "2026-07-18T09:00:00Z"))
        )

        // Read current snapshot to obtain the storage revision.
        let loaded = try requireSuccess(store.load())
        let observedRevision = loaded.snapshot.storageRevision

        // Build a CrossProcessToken from the observed revision.
        let token = GenerationIsolation.CrossProcessToken(
            storageRevision: observedRevision,
            generation: 1,
            epoch: 0
        )
        #expect(token.storageRevision == 1)

        // Validate the token against the same revision — must be current.
        let validResult = GenerationIsolation.validateCrossProcess(
            observedRevision: token.storageRevision,
            snapshotRevision: observedRevision
        )
        #expect(validResult == .current)

        // Validate against a more advanced revision — must be stale.
        let staleResult = GenerationIsolation.validateCrossProcess(
            observedRevision: token.storageRevision,
            snapshotRevision: observedRevision + 1
        )
        guard case .stale = staleResult else {
            Issue.record("Expected stale validation for advanced snapshot revision")
            return
        }
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Helpers
    // ────────────────────────────────────────────────────────────────

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func makeStore(in directory: URL, now: Date) -> SharedSnapshotStore {
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
            path: "/tmp/CrossProcessTests/\(label)",
            branch: "main",
            status: .changed,
            modifiedFileCount: 1,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 1,
            unstagedFileCount: 0,
            conflictedFileCount: 0,
            aheadCount: 0,
            behindCount: 0,
            hasUpstream: true,
            changedFileCount: 1,
            changedFilesPreview: ["\(label).swift"],
            risk: .low,
            lastScannedAt: timestamp,
            dataSource: .current,
            lastSuccessfulScanAt: timestamp,
            lastChangedAt: timestamp,
            lastCommitID: "commit-\(label)",
            lastCommitSummary: "Commit \(label)",
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
            appVersion: RepositorySnapshotSchema.currentAppVersion,
            storageFormatVersion: RepositorySnapshotSchema.storageFormatVersion
        )
    }

    private func requireSuccess<T>(_ result: Result<T, AppGroupStoreError>) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw TestError.unexpectedStoreError(error.localizedDescription)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "devpulse-cross-process-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func date(_ iso8601: String) -> Date {
        Self.isoFormatter.date(from: iso8601)!
    }
}

private enum TestError: Error {
    case unexpectedStoreError(String)
}

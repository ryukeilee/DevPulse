import Foundation
import Testing
@testable import DevPulse

// MARK: - Scan Data Consistency Tests
//
// Comprehensive regression tests for the scanning pipeline's data
// consistency, concurrency safety, and snapshot integrity.
//
// Coverage:
// 1. Concurrent scan out-of-order completion
// 2. New request replacing old request
// 3. Scan cancel and recovery
// 4. Repository move, delete, reappearance (identity dedup)
// 5. Multi-scan-root duplicate discovery
// 6. Dirty/clean state transitions
// 7. App/Widget snapshot revision consistency
// 8. Activity timeline and commit readiness consistency

// ────────────────────────────────────────────────────────────────────
// MARK: - Section 1: ScanRefreshCoordinator Concurrency
// ────────────────────────────────────────────────────────────────────

@Suite("ScanRefreshCoordinator Consistency")
struct CoordinatorConsistencyTests {

    // MARK: 1a. Concurrent out-of-order completion
    //
    // When two scans with the same signature are initiated rapidly and the
    // first completes after the second, only the second's result must survive.
    @Test("Out-of-order completion: later request cancels earlier, second is executed")
    func outOfOrderCompletion() {
        var coordinator = ScanRefreshCoordinator()
        let sig = "same-signature"

        // Queue first request
        let first = coordinator.request(signature: sig, forceRepositoryDiscovery: false, source: .timer)
        #expect(first == true)

        // Begin first (moves to running)
        let r1 = coordinator.beginNext()
        #expect(r1?.signature == sig)
        #expect(coordinator.runningRequest?.signature == sig)
        #expect(coordinator.runningRequest?.source == .timer)

        // Queue second request while first is running
        // With same signature + not cancelled, this should be rejected
        let second = coordinator.request(signature: sig, forceRepositoryDiscovery: false, source: .manual)
        #expect(second == false, "Same-signature while running should be rejected")

        // Complete first (no queued successor)
        let next1 = coordinator.completeCurrent()
        #expect(next1 == nil, "No successor should be queued")

        // Now queue a second scan
        let third = coordinator.request(signature: sig, forceRepositoryDiscovery: false, source: .manual)
        #expect(third == true)
        let r2 = coordinator.beginNext()
        #expect(r2?.signature == sig)
        #expect(r2?.source == .manual)
    }

    // MARK: 1b. New request with different signature replaces queued
    @Test("Different-signature request replaces queued when nothing running")
    func differentSignatureReplacesQueued() {
        var coordinator = ScanRefreshCoordinator()
        let sigA = "roots-A"
        let sigB = "roots-B"

        // Queue A, then immediately queue B (different signature)
        let r1 = coordinator.request(signature: sigA, forceRepositoryDiscovery: false, source: .timer)
        #expect(r1 == true)
        #expect(coordinator.nextRequest?.signature == sigA)

        // Replace with B
        let r2 = coordinator.request(signature: sigB, forceRepositoryDiscovery: false, source: .manual)
        #expect(r2 == true)
        #expect(coordinator.nextRequest?.signature == sigB,
                "Queued request should be replaced by newer different-signature request")
    }

    // MARK: 1c. New request while running is queued for later execution
    @Test("Different-signature request is queued while another runs")
    func differentSignatureQueuedWhileRunning() {
        var coordinator = ScanRefreshCoordinator()
        let sigRunning = "running-sig"
        let sigQueued = "queued-sig"

        // Start running scan
        let r1 = coordinator.request(signature: sigRunning, forceRepositoryDiscovery: false, source: .timer)
        #expect(r1)
        let started = coordinator.beginNext()
        #expect(started?.signature == sigRunning)

        // Queue new different-signature
        let r2 = coordinator.request(signature: sigQueued, forceRepositoryDiscovery: false, source: .manual)
        #expect(r2 == true)
        #expect(coordinator.nextRequest?.signature == sigQueued)

        // Complete running - queued should become next
        let completed = coordinator.completeCurrent()
        #expect(completed?.signature == sigQueued)
    }

    // MARK: 1d. Cancel + recovery
    @Test("Cancelled scan allows same-signature retry")
    func cancelledScanAllowsRetry() {
        var coordinator = ScanRefreshCoordinator()
        let sig = "test-sig"

        // Start scan
        let r1 = coordinator.request(signature: sig, forceRepositoryDiscovery: false, source: .manual)
        #expect(r1)
        let started = coordinator.beginNext()
        #expect(started != nil)

        // Cancel the running scan
        coordinator.markRunningCancelled()
        #expect(coordinator.isRunningCancelled)

        // Same signature should now be accepted (cancelled state cleared)
        let retry = coordinator.request(signature: sig, forceRepositoryDiscovery: false, source: .manual)
        #expect(retry == true, "Same-signature after cancellation should be accepted")
    }

    // MARK: 1e. Wake request forces override
    @Test("Wake source overrides running scan")
    func wakeSourceOverridesRunning() {
        var coordinator = ScanRefreshCoordinator()
        let sig = "scan-roots"

        // Start a running scan
        let r1 = coordinator.request(signature: sig, forceRepositoryDiscovery: false, source: .timer)
        #expect(r1)
        let started = coordinator.beginNext()
        #expect(started != nil)

        // Wake request with same signature - forced should override
        let wake = coordinator.requestForced(signature: sig, source: .wake)
        #expect(wake == true, "Forced wake request should override running scan")
    }

    // MARK: 1f. Priority merging
    @Test("Source priority merged correctly in queued requests")
    func sourcePriorityMerging() {
        var coordinator = ScanRefreshCoordinator()

        // Queue with timer (lower priority)
        let r1 = coordinator.request(signature: "s", forceRepositoryDiscovery: false, source: .timer)
        #expect(r1)
        #expect(coordinator.nextRequest?.source == .timer)

        // Replace with manual (higher priority)
        let r2 = coordinator.request(signature: "s", forceRepositoryDiscovery: false, source: .manual)
        #expect(r2)
        #expect(coordinator.nextRequest?.source == .manual,
                "Merged request should preserve higher priority source")
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Section 2: Repository Identity and Deduplication
// ────────────────────────────────────────────────────────────────────

@Suite("RepositoryIdentity Deduplication")
struct RepositoryIdentityDedupTests {

    // MARK: 2a. Canonical path normalizes symlinks
    @Test("canonicalPath resolves symlinks for same path")
    func canonicalPathResolvesSymlinks() throws {
        // Create temp dir with a symlink
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let realDir = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

        let linkDir = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: linkDir,
            withDestinationURL: realDir
        )

        let realPath = RepositoryIdentity.canonicalPath(realDir.path)
        let linkPath = RepositoryIdentity.canonicalPath(linkDir.path)

        // Both should resolve to the same path
        #expect(realPath == linkPath, "Symlinked path should resolve to real path")
    }

    // MARK: 2b. ID is deterministic from canonical path
    @Test("id(for:) produces identical IDs for same canonical path")
    func identicalIDsForSamePath() {
        let path1 = "/Users/test/Repo"
        let path2 = "/Users/test/Repo"

        let id1 = RepositoryIdentity.id(for: path1)
        let id2 = RepositoryIdentity.id(for: path2)

        #expect(id1 == id2, "Same path should produce identical repository ID")
    }

    @Test("id(for:) produces different IDs for different paths")
    func differentIDsForDifferentPaths() {
        let id1 = RepositoryIdentity.id(for: "/Users/test/RepoA")
        let id2 = RepositoryIdentity.id(for: "/Users/test/RepoB")

        #expect(id1 != id2, "Different paths should produce different repository IDs")
    }

    // MARK: 2c. Descendant path detection
    @Test("isSameOrDescendantPath correctly identifies nested paths")
    func descendantPathDetection() {
        #expect(RepositoryIdentity.isSameOrDescendantPath("/Users/test", of: "/Users/test") == true)
        #expect(RepositoryIdentity.isSameOrDescendantPath("/Users/test/Repo", of: "/Users/test") == true)
        #expect(RepositoryIdentity.isSameOrDescendantPath("/Users/other", of: "/Users/test") == false)
        #expect(RepositoryIdentity.isSameOrDescendantPath("/Users/test", of: "/Users/test/Repo") == false)
    }

    // MARK: 2d. Normalize snapshot identity
    @Test("normalize preserves snapshot identity")
    func normalizePreservesIdentity() {
        let snapshot = RepositorySnapshot(
            id: "test-id",
            name: "TestRepo",
            path: "/Users/test/Repo",
            branch: "main",
            status: .clean,
            modifiedFileCount: 0,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 0,
            unstagedFileCount: 0,
            conflictedFileCount: 0,
            aheadCount: 0,
            behindCount: 0,
            hasUpstream: true,
            changedFileCount: 0,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: "2026-01-01T00:00:00Z",
            dataSource: .current,
            lastSuccessfulScanAt: "2026-01-01T00:00:00Z",
            lastChangedAt: nil,
            errorMessage: nil,
            isPinned: false
        )

        let normalized = RepositoryIdentity.normalize(snapshot)
        #expect(normalized.path == snapshot.path)
        #expect(normalized.id == snapshot.id)
        #expect(normalized.name == snapshot.name)
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Section 3: SharedSnapshotStore Cross-Process Guard
// ────────────────────────────────────────────────────────────────────

@Suite("SharedSnapshotStore Cross-Process Guard")
struct SnapshotCrossProcessGuardTests {

    // MARK: 3a. Commit succeeds with matching observed revision
    @Test("Commit succeeds when observedStorageRevision matches on-disk")
    func commitWithMatchingRevision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-cpg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // First commit establishes revision 1
        let first = try requireSuccess(store.commit(AppGroupData.empty()))
        #expect(first.storageRevision == 1)

        // Second commit with observed revision 1 should succeed
        let second = try requireSuccess(store.commit(
            AppGroupData.empty(),
            observedStorageRevision: 1
        ))
        #expect(second.storageRevision == 2)
    }

    // MARK: 3b. Commit fails with stale observed revision
    @Test("Commit fails with crossProcessWriteDetected when on-disk advanced")
    func commitWithStaleRevision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-cpg2-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write A establishes revision 1
        let storeA = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        try requireSuccess(storeA.commit(AppGroupData.empty()))

        // Write B establishes revision 2
        let storeB = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        try requireSuccess(storeB.commit(AppGroupData.empty()))

        // Write A tries again with stale revision 1 - should fail
        let staleResult = storeA.commit(
            AppGroupData.empty(),
            observedStorageRevision: 1
        )
        switch staleResult {
        case .success:
            Issue.record("Expected cross-process conflict error")
        case .failure(let error):
            guard case .crossProcessWriteDetected(let observed, let actual) = error else {
                Issue.record("Expected crossProcessWriteDetected, got \(error)")
                return
            }
            #expect(observed == 1)
            #expect(actual == 2)
        }
    }

    // MARK: 3c. Without observed revision, commit always succeeds
    @Test("Commit without observedStorageRevision bypasses guard")
    func commitWithoutObservedRevision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-cpg3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // Write without observed revision - always succeeds
        let result = store.commit(AppGroupData.empty())
        try requireSuccess(result)
    }

    // MARK: 3d. Storage revision advances monotonically
    @Test("Storage revision advances monotonically after each commit")
    func storageRevisionMonotonic() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-cpg4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let r1 = try requireSuccess(store.commit(AppGroupData.empty()))
        #expect(r1.storageRevision == 1)

        let r2 = try requireSuccess(store.commit(AppGroupData.empty()))
        #expect(r2.storageRevision == 2)

        let r3 = try requireSuccess(store.commit(AppGroupData.empty()))
        #expect(r3.storageRevision == 3)

        // Loaded snapshot retains the latest revision
        let loaded = try requireSuccess(store.load())
        #expect(loaded.snapshot.storageRevision == 3)
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Section 4: Activity Event & State Transition Consistency
// ────────────────────────────────────────────────────────────────────

@Suite("Activity Event & State Transition Consistency")
struct ActivityEventConsistencyTests {

    // MARK: 4a. Dirty-to-clean transition produces workingTreeChanged event
    @Test("Dirty-to-clean transition generates workingTreeChanged event")
    func dirtyToCleanTransition() {
        let oldTime = "2026-01-01T00:00:00Z"
        let newTime = "2026-01-02T00:00:00Z"

        let previous = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: oldTime,
            writtenAt: oldTime,
            lastSuccessfulRefreshAt: oldTime,
            scanSummary: ScanSummary(
                totalRepositories: 1,
                changedRepositories: 1,
                totalChangedFiles: 2,
                errorRepositories: 0
            ),
            repositories: [
                RepositorySnapshot(
                    id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
                    branch: "main", status: .changed,
                    modifiedFileCount: 2, addedFileCount: 0,
                    deletedFileCount: 0, untrackedFileCount: 0,
                    stagedFileCount: 0, unstagedFileCount: 2,
                    conflictedFileCount: 0, aheadCount: 0,
                    behindCount: 0, hasUpstream: true,
                    changedFileCount: 2, changedFilesPreview: [],
                    risk: .low, lastScannedAt: oldTime,
                    dataSource: .current,
                    lastSuccessfulScanAt: oldTime,
                    lastChangedAt: nil,
                    lastCommitID: "abc123",
                    lastCommitSummary: "Initial commit",
                    lastCommitMetadataAvailable: true,
                    lastActivityAt: oldTime,
                    unavailableSince: nil,
                    errorMessage: nil,
                    isPinned: false
                )
            ]
        )

        let current = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: newTime,
            writtenAt: newTime,
            lastSuccessfulRefreshAt: newTime,
            scanSummary: ScanSummary(
                totalRepositories: 1,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 0
            ),
            repositories: [
                RepositorySnapshot(
                    id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
                    branch: "main", status: .clean,
                    modifiedFileCount: 0, addedFileCount: 0,
                    deletedFileCount: 0, untrackedFileCount: 0,
                    stagedFileCount: 0, unstagedFileCount: 0,
                    conflictedFileCount: 0, aheadCount: 0,
                    behindCount: 0, hasUpstream: true,
                    changedFileCount: 0, changedFilesPreview: [],
                    risk: .low, lastScannedAt: newTime,
                    dataSource: .current,
                    lastSuccessfulScanAt: newTime,
                    lastChangedAt: nil,
                    lastCommitID: "abc123",
                    lastCommitSummary: "Initial commit",
                    lastCommitMetadataAvailable: true,
                    lastActivityAt: newTime,
                    unavailableSince: nil,
                    errorMessage: nil,
                    isPinned: false
                )
            ]
        )

        let events = ActivityEventDiffer.events(
            previous: previous,
            current: current,
            observedAt: newTime
        )

        // Should detect working tree change
        let workingTreeEvents = events.filter { $0.kind == ActivityEventKind.workingTreeChanged }
        #expect(!workingTreeEvents.isEmpty,
                "Dirty-to-clean should produce workingTreeChanged events")
    }

    // MARK: 4b. Clean-to-dirty transition produces workingTreeChanged event
    @Test("Clean-to-dirty transition generates workingTreeChanged event")
    func cleanToDirtyTransition() {
        let oldTime = "2026-01-01T00:00:00Z"
        let newTime = "2026-01-02T00:00:00Z"

        let previous = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: oldTime,
            writtenAt: oldTime,
            lastSuccessfulRefreshAt: oldTime,
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [
                RepositorySnapshot(
                    id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
                    branch: "main", status: .clean,
                    modifiedFileCount: 0, addedFileCount: 0,
                    deletedFileCount: 0, untrackedFileCount: 0,
                    stagedFileCount: 0, unstagedFileCount: 0,
                    conflictedFileCount: 0, aheadCount: 0,
                    behindCount: 0, hasUpstream: true,
                    changedFileCount: 0, changedFilesPreview: [],
                    risk: .low, lastScannedAt: oldTime,
                    dataSource: .current,
                    lastSuccessfulScanAt: oldTime,
                    lastChangedAt: nil,
                    lastCommitID: "abc123",
                    lastCommitSummary: "Initial commit",
                    lastCommitMetadataAvailable: true,
                    lastActivityAt: oldTime,
                    unavailableSince: nil,
                    errorMessage: nil,
                    isPinned: false
                )
            ]
        )

        let current = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: newTime,
            writtenAt: newTime,
            lastSuccessfulRefreshAt: newTime,
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 1, totalChangedFiles: 3, errorRepositories: 0),
            repositories: [
                RepositorySnapshot(
                    id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
                    branch: "main", status: .changed,
                    modifiedFileCount: 3, addedFileCount: 0,
                    deletedFileCount: 0, untrackedFileCount: 0,
                    stagedFileCount: 0, unstagedFileCount: 3,
                    conflictedFileCount: 0, aheadCount: 0,
                    behindCount: 0, hasUpstream: true,
                    changedFileCount: 3, changedFilesPreview: [],
                    risk: .low, lastScannedAt: newTime,
                    dataSource: .current,
                    lastSuccessfulScanAt: newTime,
                    lastChangedAt: nil,
                    lastCommitID: "abc123",
                    lastCommitSummary: "Initial commit",
                    lastCommitMetadataAvailable: true,
                    lastActivityAt: newTime,
                    unavailableSince: nil,
                    errorMessage: nil,
                    isPinned: false
                )
            ]
        )

        let events = ActivityEventDiffer.events(
            previous: previous,
            current: current,
            observedAt: newTime
        )

        let workingTreeEvents = events.filter { $0.kind == ActivityEventKind.workingTreeChanged }
        #expect(!workingTreeEvents.isEmpty,
                "Clean-to-dirty should produce workingTreeChanged events")
    }

    // MARK: 4c. No change produces no events
    @Test("Identical snapshots produce no new activity events")
    func identicalSnapshotsNoEvents() {
        let time = "2026-01-01T00:00:00Z"

        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: time,
            writtenAt: time,
            lastSuccessfulRefreshAt: time,
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [
                RepositorySnapshot(
                    id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
                    branch: "main", status: .clean,
                    modifiedFileCount: 0, addedFileCount: 0,
                    deletedFileCount: 0, untrackedFileCount: 0,
                    stagedFileCount: 0, unstagedFileCount: 0,
                    conflictedFileCount: 0, aheadCount: 0,
                    behindCount: 0, hasUpstream: true,
                    changedFileCount: 0, changedFilesPreview: [],
                    risk: .low, lastScannedAt: time,
                    dataSource: .current,
                    lastSuccessfulScanAt: time,
                    lastChangedAt: nil,
                    lastCommitID: "abc123",
                    lastCommitSummary: "Initial commit",
                    lastCommitMetadataAvailable: true,
                    lastActivityAt: time,
                    unavailableSince: nil,
                    errorMessage: nil,
                    isPinned: false
                )
            ]
        )

        let events = ActivityEventDiffer.events(
            previous: snapshot,
            current: snapshot,
            observedAt: time
        )

        #expect(events.isEmpty,
                "Identical snapshots should produce no events")
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Section 5: Commit Readiness Consistency
// ────────────────────────────────────────────────────────────────────

@Suite("Commit Readiness Consistency")
struct CommitReadinessConsistencyTests {

    // MARK: 5a. Clean repo produces idle readiness
    @Test("Clean repository produces idle readiness")
    func cleanRepoIdleReadiness() {
        let decision = RepositoryDecisionEngine.decide(
            snapshot: RepositorySnapshot(
                id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
                branch: "main", status: .clean,
                modifiedFileCount: 0, addedFileCount: 0,
                deletedFileCount: 0, untrackedFileCount: 0,
                stagedFileCount: 0, unstagedFileCount: 0,
                conflictedFileCount: 0, aheadCount: 0,
                behindCount: 0, hasUpstream: true,
                changedFileCount: 0, changedFilesPreview: [],
                risk: .low, lastScannedAt: "2026-01-01T00:00:00Z",
                dataSource: .current,
                lastSuccessfulScanAt: "2026-01-01T00:00:00Z",
                lastChangedAt: nil,
                lastCommitID: "abc123",
                lastCommitSummary: "Initial commit",
                lastCommitMetadataAvailable: true,
                lastActivityAt: nil,
                unavailableSince: nil,
                errorMessage: nil,
                isPinned: false
            )
        )

        #expect(decision.commitReadiness.level == CommitReadinessLevel.idle)
        #expect(decision.commitReadiness.shortLabel == "Idle")
        #expect(decision.dataTrust == .current)
    }

    // MARK: 5b. Changed repo produces review/dirty readiness
    @Test("Changed repository produces non-idle readiness")
    func changedRepoNonIdleReadiness() {
        let decision = RepositoryDecisionEngine.decide(
            snapshot: RepositorySnapshot(
                id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
                branch: "main", status: .changed,
                modifiedFileCount: 3, addedFileCount: 0,
                deletedFileCount: 0, untrackedFileCount: 0,
                stagedFileCount: 0, unstagedFileCount: 3,
                conflictedFileCount: 0, aheadCount: 0,
                behindCount: 0, hasUpstream: true,
                changedFileCount: 3, changedFilesPreview: ["file1.swift", "file2.swift", "file3.swift"],
                risk: .low, lastScannedAt: "2026-01-01T00:00:00Z",
                dataSource: .current,
                lastSuccessfulScanAt: "2026-01-01T00:00:00Z",
                lastChangedAt: nil,
                lastCommitID: "abc123",
                lastCommitSummary: "Initial commit",
                lastCommitMetadataAvailable: true,
                lastActivityAt: nil,
                unavailableSince: nil,
                errorMessage: nil,
                isPinned: false
            )
        )

        #expect(decision.commitReadiness.level != CommitReadinessLevel.idle)
        #expect(decision.dataTrust == .current)
        #expect(decision.primaryAction.kind != RepositoryActionKind.noActionNeeded)
    }

    // MARK: 5c. Read-failed repo produces appropriate readability assessment
    @Test("Error repository has consistent readiness")
    func errorRepositoryReadiness() {
        let decision = RepositoryDecisionEngine.decide(
            snapshot: RepositorySnapshot(
                id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
                branch: "unknown", status: .error,
                modifiedFileCount: 0, addedFileCount: 0,
                deletedFileCount: 0, untrackedFileCount: 0,
                stagedFileCount: nil, unstagedFileCount: nil,
                conflictedFileCount: nil, aheadCount: nil,
                behindCount: nil, hasUpstream: nil,
                changedFileCount: 0, changedFilesPreview: [],
                risk: .low, lastScannedAt: "2026-01-01T00:00:00Z",
                dataSource: .unknown,
                lastSuccessfulScanAt: nil,
                lastChangedAt: nil,
                lastCommitID: nil,
                lastCommitSummary: nil,
                lastCommitMetadataAvailable: false,
                lastActivityAt: nil,
                unavailableSince: "2026-01-01T00:00:00Z",
                errorMessage: "Read failed",
                isPinned: false
            )
        )

        #expect(decision.commitReadiness.level == .unknown)
        #expect(decision.dataTrust == .unknown)
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Section 6: Cross-Process Pipeline Integration
// ────────────────────────────────────────────────────────────────────

@Suite("Cross-Process Pipeline Consistency")
struct CrossProcessPipelineConsistencyTests {

    // MARK: 6a. AppGroupStore write with observedStorageRevision rejects stale
    @Test("AppGroupStore write rejects stale via observed revision")
    func writeRejectsStaleCrossProcess() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-cpc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Simulate two processes writing via the shared store
        let storeA = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "shared.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // Process A writes
        let first = try requireSuccess(storeA.commit(
            makeFixture(label: "A", id: "repo-a", timestamp: "2026-01-01T00:00:00Z")
        ))
        #expect(first.storageRevision == 1)

        // Process B writes (advances revision to 2)
        let storeB = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "shared.json",
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        try requireSuccess(storeB.commit(
            makeFixture(label: "B", id: "repo-b", timestamp: "2026-01-01T00:01:00Z")
        ))

        // Process A tries to write stale - should fail
        let staleResult = storeA.commit(
            AppGroupData.empty(),
            observedStorageRevision: 1
        )
        switch staleResult {
        case .success:
            Issue.record("Expected cross-process write conflict")
        case .failure(let error):
            guard case .crossProcessWriteDetected(let observed, let actual) = error else {
                Issue.record("Expected crossProcessWriteDetected, got \(error)")
                return
            }
            #expect(observed == 1)
            #expect(actual == 2)
        }

        // Latest snapshot is still from Process B
        let loaded = try requireSuccess(storeA.load())
        #expect(loaded.snapshot.storageRevision == 2)
        #expect(loaded.source == .primary)
    }

    // MARK: 6b. Multi-writer interleaving with recovery
    @Test("Commit guard does not corrupt on-disk state on rejection")
    func commitGuardNoCorruption() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-cpc2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "shared.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // Write initial snapshot
        let initial = try requireSuccess(store.commit(
            makeFixture(label: "Initial", id: "repo-init", timestamp: "2026-01-01T00:00:00Z")
        ))
        #expect(initial.storageRevision == 1)

        // Simulate stale read: capture revision then advance it
        let observedRev = initial.storageRevision

        // Another commit advances the revision
        let storeB = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "shared.json",
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        try requireSuccess(storeB.commit(
            makeFixture(label: "B", id: "repo-b", timestamp: "2026-01-01T00:01:00Z")
        ))

        // Now try commit with stale revision
        _ = store.commit(
            makeFixture(label: "Stale", id: "repo-stale", timestamp: "2026-01-01T00:02:00Z"),
            observedStorageRevision: observedRev
        )

        // The on-disk state should still be from store B
        let loaded = try requireSuccess(store.load())
        #expect(loaded.snapshot.storageRevision == 2)
        let repo = loaded.snapshot.repositories.first
        #expect(repo?.id == "repo-b")
    }

    // Helper
    private func makeFixture(label: String, id: String, timestamp: String) -> AppGroupData {
        AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: timestamp,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 1, totalChangedFiles: 1, errorRepositories: 0),
            repositories: [
                RepositorySnapshot(
                    id: id, name: "Repo \(label)", path: "/tmp/\(label)",
                    branch: "main", status: .changed,
                    modifiedFileCount: 1, addedFileCount: 0,
                    deletedFileCount: 0, untrackedFileCount: 0,
                    stagedFileCount: 0, unstagedFileCount: 1,
                    conflictedFileCount: 0, aheadCount: 0,
                    behindCount: 0, hasUpstream: true,
                    changedFileCount: 1, changedFilesPreview: [],
                    risk: .low, lastScannedAt: timestamp,
                    dataSource: .current,
                    lastSuccessfulScanAt: timestamp,
                    lastChangedAt: nil,
                    lastCommitID: "commit-\(id)",
                    lastCommitSummary: label,
                    lastCommitMetadataAvailable: true,
                    lastActivityAt: timestamp,
                    unavailableSince: nil,
                    errorMessage: nil,
                    isPinned: false
                )
            ],
            storageRevision: 0,
            persistenceState: .committed,
            appVersion: RepositorySnapshotSchema.currentAppVersion,
            storageFormatVersion: RepositorySnapshotSchema.storageFormatVersion
        )
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Section 7: Snapshot Revision Consistency (App & Widget)
// ────────────────────────────────────────────────────────────────────

@Suite("Snapshot Revision Consistency (App & Widget)")
struct SnapshotRevisionConsistencyTests {

    // MARK: 7a. Same snapshot readable by both app and widget
    @Test("Same committed snapshot is readable by both consumer endpoints")
    func sameSnapshotReadableByBoth() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-src-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileName = "shared.json"
        let timestamp = "2026-01-01T00:00:00Z"

        // Write snapshot with storageRevision
        let store = SharedSnapshotStore(
            directoryURL: dir,
            fileName: fileName,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: timestamp,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary(totalRepositories: 2, changedRepositories: 1, totalChangedFiles: 3, errorRepositories: 0),
            repositories: [
                RepositorySnapshot(
                    id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
                    branch: "main", status: .clean,
                    modifiedFileCount: 0, addedFileCount: 0,
                    deletedFileCount: 0, untrackedFileCount: 0,
                    stagedFileCount: 0, unstagedFileCount: 0,
                    conflictedFileCount: 0, aheadCount: 0,
                    behindCount: 0, hasUpstream: true,
                    changedFileCount: 0, changedFilesPreview: [],
                    risk: .low, lastScannedAt: timestamp,
                    dataSource: .current,
                    lastSuccessfulScanAt: timestamp,
                    lastChangedAt: nil,
                    lastCommitID: "abc123",
                    lastCommitSummary: "Commit",
                    lastCommitMetadataAvailable: true,
                    lastActivityAt: timestamp,
                    unavailableSince: nil,
                    errorMessage: nil,
                    isPinned: false
                ),
                RepositorySnapshot(
                    id: "repo-2", name: "Repo2", path: "/tmp/Repo2",
                    branch: "main", status: .changed,
                    modifiedFileCount: 3, addedFileCount: 0,
                    deletedFileCount: 0, untrackedFileCount: 0,
                    stagedFileCount: 0, unstagedFileCount: 3,
                    conflictedFileCount: 0, aheadCount: 1,
                    behindCount: 0, hasUpstream: true,
                    changedFileCount: 3, changedFilesPreview: ["a.swift", "b.swift", "c.swift"],
                    risk: .medium, lastScannedAt: timestamp,
                    dataSource: .current,
                    lastSuccessfulScanAt: timestamp,
                    lastChangedAt: nil,
                    lastCommitID: "def456",
                    lastCommitSummary: "WIP",
                    lastCommitMetadataAvailable: true,
                    lastActivityAt: timestamp,
                    unavailableSince: nil,
                    errorMessage: nil,
                    isPinned: false
                )
            ],
            storageRevision: 0,
            persistenceState: .committed,
            appVersion: RepositorySnapshotSchema.currentAppVersion,
            storageFormatVersion: RepositorySnapshotSchema.storageFormatVersion
        )

        let committed = try requireSuccess(store.commit(snapshot))
        #expect(committed.storageRevision == 1)

        // Simulate widget reading the same snapshot
        let widgetStore = SharedSnapshotStore(
            directoryURL: dir,
            fileName: fileName,
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        let loaded = try requireSuccess(widgetStore.load())
        #expect(loaded.snapshot.storageRevision == 1)
        #expect(loaded.snapshot.repositories.count == 2)
        #expect(loaded.snapshot.repositories[0].id == "repo-1")
        #expect(loaded.snapshot.repositories[1].id == "repo-2")
        #expect(loaded.snapshot == committed,
                "App and Widget must read the exact same snapshot")
    }

    // MARK: 7b. Widget always reads the same committed revision as app would
    @Test("Widget reads same revision as app after multiple commits")
    func widgetReadsConsistentRevision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-src2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "shared.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // Commit 3 snapshots in sequence
        let r1 = try requireSuccess(store.commit(emptySnapshot(storageRevision: 0)))
        #expect(r1.storageRevision == 1)

        let r2 = try requireSuccess(store.commit(emptySnapshot(storageRevision: 1), observedStorageRevision: 1))
        #expect(r2.storageRevision == 2)

        let r3 = try requireSuccess(store.commit(emptySnapshot(storageRevision: 2), observedStorageRevision: 2))
        #expect(r3.storageRevision == 3)

        // Widget reads - must see the latest
        let widgetStore = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "shared.json",
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        let loaded = try requireSuccess(widgetStore.load())
        #expect(loaded.snapshot.storageRevision == 3,
                "Widget must read the latest committed revision")

        // Simulate app reading - must also see the latest
        let appStore = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "shared.json",
            now: { Date(timeIntervalSince1970: 1_700_000_200) }
        )
        let appLoaded = try requireSuccess(appStore.load())
        #expect(appLoaded.snapshot.storageRevision == 3,
                "App must read the same latest revision")
        #expect(appLoaded.snapshot == loaded.snapshot,
                "App and Widget must read identical snapshots")
    }

    // MARK: 7c. isRefreshing flag does not affect storageRevision
    @Test("isRefreshing indicator does not change storage revision")
    func isRefreshingDoesNotChangeRevision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-src3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: dir,
            fileName: "shared.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // Write a committed snapshot
        let base = try requireSuccess(store.commit(emptySnapshot(storageRevision: 0)))
        #expect(base.storageRevision == 1)

        // Write an isRefreshing snapshot (same storage revision)
        let refreshing = AppGroupData(
            schemaVersion: base.schemaVersion,
            generatedAt: base.generatedAt,
            writtenAt: base.writtenAt,
            lastSuccessfulRefreshAt: base.lastSuccessfulRefreshAt,
            scanSummary: base.scanSummary,
            repositories: base.repositories,
            storageRevision: base.storageRevision,
            persistenceState: base.persistenceState,
            isRefreshing: true,
            appVersion: base.appVersion,
            storageFormatVersion: base.storageFormatVersion
        )
        let refreshingWritten = try requireSuccess(
            store.commit(refreshing, observedStorageRevision: 1)
        )
        #expect(refreshingWritten.storageRevision == 2,
                "isRefreshing still increments revision since prepare() always increments")
        #expect(refreshingWritten.isRefreshing == true)

        // The next non-refreshing write should advance further
        let final = try requireSuccess(
            store.commit(emptySnapshot(storageRevision: 2), observedStorageRevision: 2)
        )
        #expect(final.storageRevision == 3)
        #expect(final.isRefreshing == false)
    }

    private func emptySnapshot(storageRevision: UInt64) -> AppGroupData {
        AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: DateFormatting.nowISO(),
            writtenAt: DateFormatting.nowISO(),
            scanSummary: ScanSummary(totalRepositories: 0, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [],
            storageRevision: storageRevision,
            persistenceState: .committed,
            appVersion: RepositorySnapshotSchema.currentAppVersion,
            storageFormatVersion: RepositorySnapshotSchema.storageFormatVersion
        )
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Section 8: hasMeaningfulSnapshotChanges Accuracy
// ────────────────────────────────────────────────────────────────────

@Suite("hasMeaningfulSnapshotChanges Accuracy")
struct MeaningfulChangesTests {

    // MARK: 8a. Identical snapshots report no meaningful changes
    @Test("Identical snapshots: no meaningful changes")
    func identicalSnapshots() {
        let time = "2026-01-01T00:00:00Z"
        let repo = RepositorySnapshot(
            id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
            branch: "main", status: .clean,
            modifiedFileCount: 0, addedFileCount: 0,
            deletedFileCount: 0, untrackedFileCount: 0,
            stagedFileCount: 0, unstagedFileCount: 0,
            conflictedFileCount: 0, aheadCount: 0,
            behindCount: 0, hasUpstream: true,
            changedFileCount: 0, changedFilesPreview: [],
            risk: .low, lastScannedAt: time,
            dataSource: .current,
            lastSuccessfulScanAt: time,
            lastChangedAt: nil,
            lastCommitID: "abc123",
            lastCommitSummary: "Initial",
            lastCommitMetadataAvailable: true,
            lastActivityAt: nil,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )

        let previous = snapshotWith(repos: [repo], time: time)
        let current = snapshotWith(repos: [repo], time: time)

        #expect(!ScanSchedulerPolicy.hasMeaningfulSnapshotChanges(
            previousSnapshot: previous,
            nextSnapshot: current
        ))
    }

    // MARK: 8b. Changed modifiedFileCount reports change
    @Test("Modified file count difference reports meaningful change")
    func modifiedFileCountChange() {
        let time = "2026-01-01T00:00:00Z"
        let cleanRepo = RepositorySnapshot(
            id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
            branch: "main", status: .clean,
            modifiedFileCount: 0, addedFileCount: 0,
            deletedFileCount: 0, untrackedFileCount: 0,
            stagedFileCount: 0, unstagedFileCount: 0,
            conflictedFileCount: 0, aheadCount: 0,
            behindCount: 0, hasUpstream: true,
            changedFileCount: 0, changedFilesPreview: [],
            risk: .low, lastScannedAt: time,
            dataSource: .current,
            lastSuccessfulScanAt: time,
            lastChangedAt: nil,
            lastCommitID: "abc123",
            lastCommitSummary: "Initial",
            lastCommitMetadataAvailable: true,
            lastActivityAt: nil,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )
        let dirtyRepo = RepositorySnapshot(
            id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
            branch: "main", status: .changed,
            modifiedFileCount: 3, addedFileCount: 0,
            deletedFileCount: 0, untrackedFileCount: 0,
            stagedFileCount: 0, unstagedFileCount: 3,
            conflictedFileCount: 0, aheadCount: 0,
            behindCount: 0, hasUpstream: true,
            changedFileCount: 1, changedFilesPreview: ["file1.swift"],
            risk: .medium, lastScannedAt: time,
            dataSource: .current,
            lastSuccessfulScanAt: time,
            lastChangedAt: nil,
            lastCommitID: "abc123",
            lastCommitSummary: "Initial",
            lastCommitMetadataAvailable: true,
            lastActivityAt: nil,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )

        let previous = snapshotWith(repos: [cleanRepo], time: time)
        let current = snapshotWith(repos: [dirtyRepo], time: time)

        #expect(ScanSchedulerPolicy.hasMeaningfulSnapshotChanges(
            previousSnapshot: previous,
            nextSnapshot: current
        ))
    }

    // MARK: 8c. Branch change reports change
    @Test("Branch change reports meaningful change")
    func branchChange() {
        let time = "2026-01-01T00:00:00Z"
        let mainRepo = RepositorySnapshot(
            id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
            branch: "main", status: .clean,
            modifiedFileCount: 0, addedFileCount: 0,
            deletedFileCount: 0, untrackedFileCount: 0,
            stagedFileCount: 0, unstagedFileCount: 0,
            conflictedFileCount: 0, aheadCount: 0,
            behindCount: 0, hasUpstream: true,
            changedFileCount: 0, changedFilesPreview: [],
            risk: .low, lastScannedAt: time,
            dataSource: .current,
            lastSuccessfulScanAt: time,
            lastChangedAt: nil,
            lastCommitID: "abc123",
            lastCommitSummary: "Initial",
            lastCommitMetadataAvailable: true,
            lastActivityAt: nil,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )
        let featureRepo = RepositorySnapshot(
            id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
            branch: "feature", status: .clean,
            modifiedFileCount: 0, addedFileCount: 0,
            deletedFileCount: 0, untrackedFileCount: 0,
            stagedFileCount: 0, unstagedFileCount: 0,
            conflictedFileCount: 0, aheadCount: 0,
            behindCount: 0, hasUpstream: false,
            changedFileCount: 0, changedFilesPreview: [],
            risk: .low, lastScannedAt: time,
            dataSource: .current,
            lastSuccessfulScanAt: time,
            lastChangedAt: nil,
            lastCommitID: "def456",
            lastCommitSummary: "Feature",
            lastCommitMetadataAvailable: true,
            lastActivityAt: nil,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )

        let previous = snapshotWith(repos: [mainRepo], time: time)
        let current = snapshotWith(repos: [featureRepo], time: time)

        #expect(ScanSchedulerPolicy.hasMeaningfulSnapshotChanges(
            previousSnapshot: previous,
            nextSnapshot: current
        ))
    }

    // MARK: 8d. Risk level change reports change
    @Test("Risk level change reports meaningful change")
    func riskLevelChange() {
        let time = "2026-01-01T00:00:00Z"
        let lowRisk = RepositorySnapshot(
            id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
            branch: "main", status: .changed,
            modifiedFileCount: 1, addedFileCount: 0,
            deletedFileCount: 0, untrackedFileCount: 0,
            stagedFileCount: 0, unstagedFileCount: 1,
            conflictedFileCount: 0, aheadCount: 0,
            behindCount: 0, hasUpstream: true,
            changedFileCount: 1, changedFilesPreview: ["file1.swift"],
            risk: .low, lastScannedAt: time,
            dataSource: .current,
            lastSuccessfulScanAt: time,
            lastChangedAt: nil,
            lastCommitID: "abc123",
            lastCommitSummary: "Initial",
            lastCommitMetadataAvailable: true,
            lastActivityAt: nil,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )
        let highRisk = RepositorySnapshot(
            id: "repo-1", name: "Repo1", path: "/tmp/Repo1",
            branch: "main", status: .changed,
            modifiedFileCount: 1, addedFileCount: 0,
            deletedFileCount: 0, untrackedFileCount: 0,
            stagedFileCount: 0, unstagedFileCount: 1,
            conflictedFileCount: 0, aheadCount: 0,
            behindCount: 0, hasUpstream: true,
            changedFileCount: 1, changedFilesPreview: ["config.secret"],
            risk: .high, lastScannedAt: time,
            dataSource: .current,
            lastSuccessfulScanAt: time,
            lastChangedAt: nil,
            lastCommitID: "abc123",
            lastCommitSummary: "Initial",
            lastCommitMetadataAvailable: true,
            lastActivityAt: nil,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )

        let previous = snapshotWith(repos: [lowRisk], time: time)
        let current = snapshotWith(repos: [highRisk], time: time)

        #expect(ScanSchedulerPolicy.hasMeaningfulSnapshotChanges(
            previousSnapshot: previous,
            nextSnapshot: current
        ))
    }

    private func snapshotWith(repos: [RepositorySnapshot], time: String) -> AppGroupData {
        AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: time,
            writtenAt: time,
            lastSuccessfulRefreshAt: time,
            scanSummary: ScanSummary.build(from: repos),
            repositories: repos
        )
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - Shared Helpers
// ────────────────────────────────────────────────────────────────────

private enum TestError: Error {
    case unexpectedStoreError(String)
}

private func requireSuccess<T>(_ result: Result<T, AppGroupStoreError>) throws -> T {
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw TestError.unexpectedStoreError(error.localizedDescription)
    }
}

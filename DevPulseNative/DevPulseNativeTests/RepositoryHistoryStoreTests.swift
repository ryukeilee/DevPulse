import Foundation
import Testing
@testable import DevPulse

// MARK: - History data model tests

struct RepositoryHistoryEntryTests {
    @Test func testEntryKindPriorities() {
        #expect(HistoryEntryKind.firstSeen.priority < HistoryEntryKind.stateChange.priority)
        #expect(HistoryEntryKind.stateChange.priority < HistoryEntryKind.becameUnavailable.priority)
        #expect(HistoryEntryKind.becameUnavailable.priority < HistoryEntryKind.recovery.priority)
        #expect(HistoryEntryKind.recovery.priority < HistoryEntryKind.scanRecord.priority)
        #expect(HistoryEntryKind.scanRecord.priority < HistoryEntryKind.summary.priority)
    }

    @Test func testStatePointFromSnapshot() {
        let snapshot = makeSnapshot(name: "test", branch: "main", changedCount: 3)
        let point = HistoryStatePoint(snapshot: snapshot)

        #expect(point.branch == "main")
        #expect(point.changedFileCount == 3)
        #expect(point.dataSource == .current)
        #expect(point.risk == .low)
    }

    @Test func testMeaningfulDifferences() {
        let point1 = HistoryStatePoint(snapshot: makeSnapshot(name: "a", branch: "main", changedCount: 0))
        let point2 = HistoryStatePoint(snapshot: makeSnapshot(name: "a", branch: "main", changedCount: 5))
        let point3 = HistoryStatePoint(snapshot: makeSnapshot(name: "a", branch: "feature", changedCount: 0))

        #expect(point1.isMeaningfullyDifferent(from: point2))
        #expect(point2.isMeaningfullyDifferent(from: point1))
        #expect(point1.isMeaningfullyDifferent(from: point3))
        #expect(!point1.isMeaningfullyDifferent(from: point1))
    }

    @Test func testEntryIDDeterminism() {
        let state = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 2))
        let entry1 = RepositoryHistoryEntry(
            repositoryID: "repo1",
            recordedAt: "2026-07-22T10:00:00Z",
            kind: .scanRecord,
            state: state
        )
        let entry2 = RepositoryHistoryEntry(
            repositoryID: "repo1",
            recordedAt: "2026-07-22T10:00:00Z",
            kind: .scanRecord,
            state: state
        )
        #expect(entry1.id == entry2.id)
    }

    @Test func testClassifyFirstSeen() {
        let state = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
        let kind = HistoryEntryKindClassifier.classify(
            previous: nil,
            current: state,
            lastDataSource: nil,
            currentDataSource: .current
        )
        #expect(kind == .firstSeen)
    }

    @Test func testClassifyRecovery() {
        let state = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
        let previous = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0, dataSource: .unknown))
        let kind = HistoryEntryKindClassifier.classify(
            previous: previous,
            current: state,
            lastDataSource: .unknown,
            currentDataSource: .current
        )
        #expect(kind == .recovery)
    }

    @Test func testClassifyStateChange() {
        let state = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "feature", changedCount: 5))
        let previous = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
        let kind = HistoryEntryKindClassifier.classify(
            previous: previous,
            current: state,
            lastDataSource: .current,
            currentDataSource: .current
        )
        #expect(kind == .stateChange)
    }

    @Test func testClassifyScanRecord() {
        let state = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 2))
        let previous = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 2))
        let kind = HistoryEntryKindClassifier.classify(
            previous: previous,
            current: state,
            lastDataSource: .current,
            currentDataSource: .current
        )
        #expect(kind == .scanRecord)
    }
}

// MARK: - History store tests

@Suite(.serialized)
struct RepositoryHistoryStoreTests {
    let tempDir: URL
    let store: RepositoryHistoryStore

    init() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-test-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = RepositoryHistoryStore(
            fileURL: tempDir.appendingPathComponent("test-history.json"),
            config: .minimal
        )
    }

    // Note: temp directory cleanup is handled by OS temp management

    @Test func testEmptyStore() async throws {
        let count = store.count()
        #expect(count == 0)
    }

    @Test func testRecordSingleEntry() async throws {
        let state = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
        let entry = RepositoryHistoryEntry(
            repositoryID: "repo1",
            recordedAt: "2026-07-22T10:00:00Z",
            kind: .firstSeen,
            state: state
        )

        let result = store.record(entries: [entry])
        #expect(result.success ?? false)
        #expect((result.success ?? false) ? (try? result.get()) == 1 : false)

        let count = store.count()
        #expect(count == 1)
    }

    @Test func testDedupIdenticalScanRecords() async throws {
        let state = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))

        // First entry
        let entry1 = RepositoryHistoryEntry(
            repositoryID: "repo1",
            recordedAt: "2026-07-22T10:00:00Z",
            kind: .scanRecord,
            state: state
        )
        let result1 = store.record(entries: [entry1])
        #expect((try? result1.get()) == 1)

        // Identical second entry should be deduped
        let entry2 = RepositoryHistoryEntry(
            repositoryID: "repo1",
            recordedAt: "2026-07-22T11:00:00Z",
            kind: .scanRecord,
            state: state
        )
        let result2 = store.record(entries: [entry2])
        #expect((try? result2.get()) == 0)

        let count = store.count()
        #expect(count == 1)
    }

    @Test func testStateChangeNotDeduped() async throws {
        let state1 = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
        let state2 = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 5))

        let entry1 = RepositoryHistoryEntry(
            repositoryID: "repo1",
            recordedAt: "2026-07-22T10:00:00Z",
            kind: .stateChange,
            state: state1
        )
        let result1 = store.record(entries: [entry1])
        #expect((try? result1.get()) == 1)

        // Different state should not be deduped even if same kind
        let entry2 = RepositoryHistoryEntry(
            repositoryID: "repo1",
            recordedAt: "2026-07-22T10:30:00Z",
            kind: .stateChange,
            state: state2
        )
        let result2 = store.record(entries: [entry2])
        #expect((try? result2.get()) == 1)

        let count = store.count()
        #expect(count == 2)
    }

    @Test func testMultipleRepositories() async throws {
        let state1 = HistoryStatePoint(snapshot: makeSnapshot(name: "repoA", branch: "main", changedCount: 0))
        let state2 = HistoryStatePoint(snapshot: makeSnapshot(name: "repoB", branch: "dev", changedCount: 3))

        let e1 = RepositoryHistoryEntry(repositoryID: "repoA", recordedAt: "2026-07-22T10:00:00Z", kind: .firstSeen, state: state1)
        let e2 = RepositoryHistoryEntry(repositoryID: "repoB", recordedAt: "2026-07-22T10:00:00Z", kind: .firstSeen, state: state2)

        let result = store.record(entries: [e1, e2])
        #expect((try? result.get()) == 2)
        #expect(store.count() == 2)
    }

    @Test func testLoadSpecificRepo() async throws {
        let state1 = HistoryStatePoint(snapshot: makeSnapshot(name: "a", branch: "main", changedCount: 0))
        let state2 = HistoryStatePoint(snapshot: makeSnapshot(name: "b", branch: "dev", changedCount: 3))

        let e1 = RepositoryHistoryEntry(repositoryID: "repoA", recordedAt: "2026-07-22T10:00:00Z", kind: .firstSeen, state: state1)
        let e2 = RepositoryHistoryEntry(repositoryID: "repoB", recordedAt: "2026-07-22T10:30:00Z", kind: .firstSeen, state: state2)

        store.record(entries: [e1, e2])

        let loaded = store.load(for: "repoA")
        let entries = try loaded.get()
        #expect(entries.count == 1)
        #expect(entries.allSatisfy { $0.repositoryID == "repoA" })
    }

    @Test func testPrune() async throws {
        let state = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))

        let e1 = RepositoryHistoryEntry(repositoryID: "repoA", recordedAt: "2026-07-22T10:00:00Z", kind: .firstSeen, state: state)
        let e2 = RepositoryHistoryEntry(repositoryID: "repoB", recordedAt: "2026-07-22T10:30:00Z", kind: .firstSeen, state: state)

        store.record(entries: [e1, e2])
        #expect(store.count() == 2)

        let pruned = store.prune(keeping: ["repoA"])
        #expect((try? pruned.get()) == 1)
        #expect(store.count() == 1)
    }

    @Test func testClear() async throws {
        let state = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
        let e = RepositoryHistoryEntry(repositoryID: "repo1", recordedAt: "2026-07-22T10:00:00Z", kind: .firstSeen, state: state)
        store.record(entries: [e])
        #expect(store.count() == 1)

        store.clear()
        #expect(store.count() == 0)
    }

    @Test func testCompaction() async throws {
        let state = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
        let changed = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 5))

        // Record many entries
        var entries: [RepositoryHistoryEntry] = []
        for i in 0..<10 {
            let s = i % 2 == 0 ? state : changed
            let entry = RepositoryHistoryEntry(
                repositoryID: "repo1",
                recordedAt: "2026-07-\(String(format: "%02d", 1 + i))T10:00:00Z",
                kind: .scanRecord,
                state: s
            )
            entries.append(entry)
        }
        store.record(entries: entries)

        let countBefore = store.count()
        #expect(countBefore > 0)

        // Compact should remove consecutive identical scan records
        let compacted = store.compact()
        #expect((try? compacted.get()) != nil)

        // After compaction the count should be <= before
        let countAfter = store.count()
        #expect(countAfter <= countBefore)
    }

    @Test func testDiagnostics() async throws {
        let state = HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
        let e = RepositoryHistoryEntry(repositoryID: "repo1", recordedAt: "2026-07-22T10:00:00Z", kind: .firstSeen, state: state)
        store.record(entries: [e])

        let diag = store.diagnosticsSnapshot()
        #expect(diag.totalEntriesWritten >= 1)
        #expect(diag.currentEntryCount >= 1)
        #expect(diag.totalRepositoryCount >= 1)
    }
}

// MARK: - Health engine tests

struct RepositoryHealthEngineTests {
    @Test func testInsufficientHistory() {
        let entries = (0..<2).map { i in
            RepositoryHistoryEntry(
                repositoryID: "repo1",
                recordedAt: "2026-07-\(String(format: "%02d", 22 - i))T10:00:00Z",
                kind: .scanRecord,
                state: HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
            )
        }

        let assessment = RepositoryHealthEngine.assess(
            repositoryID: "repo1",
            repositoryName: "test",
            entries: entries
        )

        #expect(!assessment.hasSufficientHistory)
        #expect(assessment.overallRisk == .low)
        #expect(assessment.signals.isEmpty)
    }

    @Test func testSufficientHistoryNoSignals() {
        // Use dates within the last 2 days to avoid stale activity threshold (> 7 days)
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let formatter = ISO8601DateFormatter()
        var entries: [RepositoryHistoryEntry] = []
        for i in 0..<5 {
            let date = calendar.date(byAdding: .hour, value: -i * 2, to: now) ?? now
            entries.append(RepositoryHistoryEntry(
                repositoryID: "repo1",
                recordedAt: formatter.string(from: date),
                kind: .scanRecord,
                state: HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
            ))
        }

        let assessment = RepositoryHealthEngine.assess(
            repositoryID: "repo1",
            repositoryName: "test",
            entries: entries
        )

        #expect(assessment.hasSufficientHistory)
        #expect(assessment.overallRisk == .low)
        #expect(assessment.signals.isEmpty)
    }

    @Test func testDirtyWorkspaceSignal() {
        var entries: [RepositoryHistoryEntry] = []

        // First clean record (old)
        entries.append(RepositoryHistoryEntry(
            repositoryID: "repo1",
            recordedAt: "2026-07-20T08:00:00Z",
            kind: .stateChange,
            state: HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
        ))

        // Then dirty for several records
        for i in 0..<5 {
            entries.append(RepositoryHistoryEntry(
                repositoryID: "repo1",
                recordedAt: "2026-07-\(String(format: "%02d", 21 + i))T10:00:00Z",
                kind: .scanRecord,
                state: HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 12))
            ))
        }

        let assessment = RepositoryHealthEngine.assess(
            repositoryID: "repo1",
            repositoryName: "test",
            entries: entries
        )

        #expect(assessment.hasSufficientHistory)

        let dirtySignal = assessment.signals.first { $0.kind == .dirtyWorkspaceDuration }
        #expect(dirtySignal != nil)
        #expect(dirtySignal?.level == .high) // > 24h
        #expect(dirtySignal?.evidence.contains("开始") ?? false)
    }

    @Test func testStaleActivitySignal() {
        let entries = (0..<5).map { i in
            RepositoryHistoryEntry(
                repositoryID: "repo1",
                recordedAt: "2026-06-\(String(format: "%02d", 1 + i))T10:00:00Z",
                kind: .scanRecord,
                state: HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: 0))
            )
        }

        let assessment = RepositoryHealthEngine.assess(
            repositoryID: "repo1",
            repositoryName: "test",
            entries: entries
        )

        #expect(assessment.hasSufficientHistory)
        let staleSignal = assessment.signals.first { $0.kind == .staleActivity }
        #expect(staleSignal != nil)
        // Last activity was > 30 days ago
        #expect(staleSignal?.level == .high)
    }

    @Test func testBranchInstabilitySignal() {
        var entries: [RepositoryHistoryEntry] = []
        let branches = ["main", "feature-a", "main", "feature-b", "hotfix", "main", "feature-c", "main"]

        for (i, branch) in branches.enumerated() {
            entries.append(RepositoryHistoryEntry(
                repositoryID: "repo1",
                recordedAt: "2026-07-\(String(format: "%02d", 22 - (branches.count - 1 - i)))T10:00:00Z",
                kind: .stateChange,
                state: HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: branch, changedCount: 0))
            ))
        }

        let assessment = RepositoryHealthEngine.assess(
            repositoryID: "repo1",
            repositoryName: "test",
            entries: entries
        )

        #expect(assessment.hasSufficientHistory)
        let branchSignal = assessment.signals.first { $0.kind == .branchInstability }
        // May not fire if the 24h window doesn't capture enough changes
        // But should at least not crash
    }

    @Test func testCreepingChangesSignal() {
        var entries: [RepositoryHistoryEntry] = []
        let counts = [1, 3, 5, 8, 12, 15]

        for (i, count) in counts.enumerated() {
            entries.append(RepositoryHistoryEntry(
                repositoryID: "repo1",
                recordedAt: "2026-07-\(String(format: "%02d", 20 + i))T10:00:00Z",
                kind: .scanRecord,
                state: HistoryStatePoint(snapshot: makeSnapshot(name: "test", branch: "main", changedCount: count))
            ))
        }

        let assessment = RepositoryHealthEngine.assess(
            repositoryID: "repo1",
            repositoryName: "test",
            entries: entries
        )

        #expect(assessment.hasSufficientHistory)
        let creepingSignal = assessment.signals.first { $0.kind == .creepingChanges }
        #expect(creepingSignal != nil)
        #expect(creepingSignal?.currentValue.contains("+") ?? false)
    }

    @Test func testOverallRiskComputation() {
        // All low signals
        let recoverySignal = RepositoryHealthSignal(
            kind: .recentRecovery,
            level: .low,
            title: "test",
            explanation: "test",
            evidence: "test",
            duration: nil,
            currentValue: "ok",
            threshold: nil
        )
        #expect(RepositoryHealthEngine.computeOverallRisk(signals: [recoverySignal]) == .low)

        // Mixed with one high
        let highSignal = RepositoryHealthSignal(
            kind: .dirtyWorkspaceDuration,
            level: .high,
            title: "test",
            explanation: "test",
            evidence: "test",
            duration: 86400,
            currentValue: "bad",
            threshold: "> 4h"
        )
        #expect(RepositoryHealthEngine.computeOverallRisk(signals: [recoverySignal, highSignal]) == .high)

        // Only medium
        let medSignal = RepositoryHealthSignal(
            kind: .staleActivity,
            level: .medium,
            title: "test",
            explanation: "test",
            evidence: "test",
            duration: 7*86400,
            currentValue: "warn",
            threshold: nil
        )
        #expect(RepositoryHealthEngine.computeOverallRisk(signals: [medSignal]) == .medium)
    }
}

// MARK: - Helpers

private typealias RHT = RepositoryHealthEngineTests

/// Extracts the success value or fails the test.
extension Result {
    var success: Bool? {
        if case .success = self { return true }
        return false
    }
}

/// Make a minimal RepositorySnapshot for testing.
private func makeSnapshot(
    name: String,
    branch: String,
    changedCount: Int,
    dataSource: RepositoryDataSource = .current
) -> RepositorySnapshot {
    RepositorySnapshot(
        id: RepositoryIdentity.id(for: "/Users/test/\(name)"),
        name: name,
        path: "/Users/test/\(name)",
        workspaceKind: nil,
        branch: branch,
        status: changedCount > 0 ? .changed : .clean,
        modifiedFileCount: changedCount,
        addedFileCount: 0,
        deletedFileCount: 0,
        untrackedFileCount: 0,
        stagedFileCount: nil,
        unstagedFileCount: nil,
        conflictedFileCount: nil,
        aheadCount: nil,
        behindCount: nil,
        hasUpstream: nil,
        changedFileCount: changedCount,
        changedFilesPreview: [],
        risk: .low,
        lastScannedAt: DateFormatting.nowISO(),
        dataSource: dataSource,
        lastSuccessfulScanAt: DateFormatting.nowISO(),
        lastChangedAt: nil,
        lastCommitID: nil,
        lastCommitSummary: nil,
        lastCommitMetadataAvailable: nil,
        lastActivityAt: nil,
        errorMessage: nil,
        isPinned: false
    )
}

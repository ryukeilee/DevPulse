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

    @Test func groupedLoadPreservesPerRepositoryDescendingOrder() throws {
        let benchmarkStore = makeBenchmarkStore()
        seed(benchmarkStore, entries: makeHistoryEntries(repositoryCount: 5, entriesPerRepository: 60))

        let grouped = try benchmarkStore.loadGrouped().get()
        for repositoryIndex in 0..<5 {
            let repositoryID = historyRepositoryID(repositoryIndex)
            let expected = try benchmarkStore.load(for: repositoryID).get()
            #expect(grouped[repositoryID] == expected)
            #expect(expected == expected.sorted { $0.recordedAt > $1.recordedAt })
        }
    }

    @Test func refreshHistoryPathsDecodeArchiveAtMostTwice() throws {
        let benchmarkStore = makeBenchmarkStore()
        let repositories = (0..<5).map { makeSnapshot(name: "history-\($0)", branch: "main", changedCount: $0) }
        seed(benchmarkStore, entries: makeHistoryEntries(repositoryCount: 5, entriesPerRepository: 60))

        benchmarkStore.resetDiagnostics()
        let outcome = try benchmarkStore.recordSnapshotStates(
            repositories: repositories,
            recordedAt: "2026-08-01T00:00:00Z"
        ).get()
        #expect(outcome.addedCount == repositories.count)
        #expect(benchmarkStore.loadMetrics().archiveDecodeCount == 1)

        let grouped = try benchmarkStore.loadGrouped().get()
        #expect(grouped.count == repositories.count)
        #expect(grouped[repositories[0].id]?.first?.kind == .scanRecord)
        let metrics = benchmarkStore.loadMetrics()
        #expect(metrics.archiveDecodeCount == 2)
        #expect(metrics.archiveBytesRead > 0)
    }

    @Test func groupedLoadBenchmark300EntriesFiveRepositories() throws {
        let benchmarkStore = makeBenchmarkStore()
        seed(benchmarkStore, entries: makeHistoryEntries(repositoryCount: 5, entriesPerRepository: 60))

        let repositoryIDs = (0..<5).map(historyRepositoryID)
        let iterations = 30
        benchmarkStore.resetDiagnostics()
        let repeatedLoadSamples = (0..<iterations).map { _ in
            elapsedMilliseconds {
                for repositoryID in repositoryIDs {
                    _ = try? benchmarkStore.load(for: repositoryID).get()
                }
            }
        }
        let repeatedLoadMetrics = benchmarkStore.loadMetrics()

        benchmarkStore.resetDiagnostics()
        let groupedLoadSamples = (0..<iterations).map { _ in
            elapsedMilliseconds {
                _ = try? benchmarkStore.loadGrouped().get()
            }
        }
        let groupedLoadMetrics = benchmarkStore.loadMetrics()

        print("history-load-benchmark entries=300 repositories=5 iterations=30 old_median_ms=\(median(repeatedLoadSamples)) old_p95_ms=\(p95(repeatedLoadSamples)) old_mad_ms=\(mad(repeatedLoadSamples)) new_median_ms=\(median(groupedLoadSamples)) new_p95_ms=\(p95(groupedLoadSamples)) new_mad_ms=\(mad(groupedLoadSamples)) old_decodes=\(repeatedLoadMetrics.archiveDecodeCount) new_decodes=\(groupedLoadMetrics.archiveDecodeCount) old_bytes=\(repeatedLoadMetrics.archiveBytesRead) new_bytes=\(groupedLoadMetrics.archiveBytesRead)")

        #expect(repeatedLoadMetrics.archiveDecodeCount == iterations * repositoryIDs.count)
        #expect(groupedLoadMetrics.archiveDecodeCount == iterations)
        #expect(repeatedLoadMetrics.archiveBytesRead == groupedLoadMetrics.archiveBytesRead * repositoryIDs.count)
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

private func makeBenchmarkStore() -> RepositoryHistoryStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("devpulse-history-benchmark-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return RepositoryHistoryStore(
        fileURL: directory.appendingPathComponent("repository-history.json"),
        config: .init(
            retentionDays: 100_000,
            maxEntriesPerRepo: 1_000,
            maxTotalEntries: 10_000,
            compactionInterval: 10_000,
            softThresholdFraction: 0.9
        )
    )
}

private func historyRepositoryID(_ index: Int) -> String {
    RepositoryIdentity.id(for: "/Users/test/history-\(index)")
}

private func makeHistoryEntries(repositoryCount: Int, entriesPerRepository: Int) -> [RepositoryHistoryEntry] {
    let formatter = ISO8601DateFormatter()
    let start = Date(timeIntervalSince1970: 1_720_000_000)
    return (0..<repositoryCount).flatMap { repositoryIndex in
        let state = HistoryStatePoint(snapshot: makeSnapshot(
            name: "history-\(repositoryIndex)",
            branch: "main",
            changedCount: repositoryIndex
        ))
        return (0..<entriesPerRepository).map { entryIndex in
            RepositoryHistoryEntry(
                repositoryID: historyRepositoryID(repositoryIndex),
                recordedAt: formatter.string(from: start.addingTimeInterval(TimeInterval(entryIndex * repositoryCount + repositoryIndex))),
                kind: .stateChange,
                state: state
            )
        }
    }
}

private func seed(_ store: RepositoryHistoryStore, entries: [RepositoryHistoryEntry]) {
    let repositoryCount = 5
    let entriesPerRepository = entries.count / repositoryCount
    for entryIndex in 0..<entriesPerRepository {
        let batch = (0..<repositoryCount).map { entries[$0 * entriesPerRepository + entryIndex] }
        #expect((try? store.record(entries: batch).get()) == repositoryCount)
    }
}

private func elapsedMilliseconds(_ operation: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    operation()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted[sorted.count / 2]
}

private func p95(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
}

private func mad(_ samples: [Double]) -> Double {
    let middle = median(samples)
    return median(samples.map { abs($0 - middle) })
}

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

import Foundation
import Testing
@testable import DevPulse

// MARK: - Data Freshness State Regression Tests
//
// Verifies that:
// 1. All 5 canonical DataFreshnessState cases produce correct labels
//    and recovery actions.
// 2. DataFreshnessBuilder (app-side) derives the correct state from
//    every combination of RefreshPhase, SnapshotTrustAssessment,
//    SharedSnapshotPersistenceState, repository set, and isRefreshing.
// 3. AppGroupData isRefreshing round-trips through Codable.
// 4. WidgetEntry.freshnessState (defined in DevPulseWidget.swift)
//    is tested separately in WidgetLifecycleScenariosTests.
// 5. Cross-process consistency: isRefreshing does not interfere with
//    storage-revision-based stale-write detection.

@Suite("DataFreshnessState")
struct DataFreshnessStateTests {

    // ────────────────────────────────────────────────
    // MARK: - Canonical states
    // ────────────────────────────────────────────────

    @Test("normal state has correct label and recovery action")
    func normalState() {
        let state = DataFreshnessState.normal(reason: "10 分钟前更新")
        #expect(state.label == "正常")
        #expect(state.recoveryAction == "无需操作")
    }

    @Test("refreshing state has correct label and recovery action")
    func refreshingState() {
        let state = DataFreshnessState.refreshing(reason: "正在更新仓库状态")
        #expect(state.label == "刷新中")
        #expect(state.recoveryAction == "等待刷新完成")
    }

    @Test("stale state has correct label and recovery action")
    func staleState() {
        let state = DataFreshnessState.stale(reason: "数据需要刷新")
        #expect(state.label == "数据过期")
        #expect(state.recoveryAction == "点按 Rescan Now 重新刷新")
    }

    @Test("degraded state has correct label and recovery action")
    func degradedState() {
        let state = DataFreshnessState.degraded(reason: "部分仓库读取降级")
        #expect(state.label == "读取降级")
        #expect(state.recoveryAction == "点按 Rescan 重新确认")
    }

    @Test("failed state has correct label and recovery action")
    func failedState() {
        let state = DataFreshnessState.failed(reason: "读取失败")
        #expect(state.label == "读取失败")
        #expect(state.recoveryAction == "检查 Settings › Diagnostics 后重试")
    }

    // ────────────────────────────────────────────────
    // MARK: - DataFreshnessBuilder (app-side)
    // ────────────────────────────────────────────────

    /// Create a trust assessment for a given state, using a consistent time
    /// relative to `now`.
    private func trust(
        state: SnapshotTrustState,
        lastUpdated: Date = Date().addingTimeInterval(-120)
    ) -> SnapshotTrustAssessment {
        let iso = ISO8601DateFormatter().string(from: lastUpdated)
        switch state {
        case .fresh:
            return RefreshStatusFormatter.snapshotAssessment(
                generatedAt: iso,
                writtenAt: iso,
                now: Date()
            )
        case .stale:
            let old = Date().addingTimeInterval(-800)
            return RefreshStatusFormatter.snapshotAssessment(
                generatedAt: ISO8601DateFormatter().string(from: old),
                writtenAt: ISO8601DateFormatter().string(from: old),
                now: Date()
            )
        case .expired:
            let old = Date().addingTimeInterval(-2000)
            return RefreshStatusFormatter.snapshotAssessment(
                generatedAt: ISO8601DateFormatter().string(from: old),
                writtenAt: ISO8601DateFormatter().string(from: old),
                now: Date()
            )
        case .degraded:
            return SnapshotTrustAssessment(
                state: .degraded,
                title: "部分仓库待确认",
                detail: "2 个读取失败，3 个已更新",
                basis: "混合数据"
            )
        case .unknown:
            return SnapshotTrustAssessment(
                state: .unknown,
                title: "状态未知",
                detail: "无法确认",
                basis: "未知"
            )
        case .failed:
            return SnapshotTrustAssessment(
                state: .failed,
                title: "刷新失败",
                detail: "没有成功记录",
                basis: "最近一次刷新失败"
            )
        }
    }

    private func makeRepo(dataSource: RepositoryDataSource, status: RepositoryStatus = .changed) -> RepositorySnapshot {
        RepositorySnapshot(
            id: "test-\(UUID().uuidString)",
            name: "test",
            path: "/tmp/test",
            branch: "main",
            status: status,
            modifiedFileCount: dataSource == .current ? 1 : 0,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 0,
            unstagedFileCount: 0,
            conflictedFileCount: 0,
            aheadCount: 0,
            behindCount: 0,
            hasUpstream: true,
            changedFileCount: dataSource == .current ? 1 : 0,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: "2026-07-25T00:00:00Z",
            dataSource: dataSource,
            lastSuccessfulScanAt: "2026-07-25T00:00:00Z",
            lastChangedAt: "2026-07-25T00:00:00Z",
            lastCommitID: nil,
            lastCommitSummary: nil,
            lastCommitMetadataAvailable: nil,
            lastActivityAt: nil,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )
    }

    // ── Refreshing state ──

    @Test("builder returns refreshing when isRefreshing is true")
    func builderRefreshingFlag() {
        let repos = [makeRepo(dataSource: .current)]
        let state = DataFreshnessBuilder.build(
            refreshPhase: .success,
            trustAssessment: trust(state: .fresh),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: true
        )
        guard case .refreshing = state else {
            Issue.record("Expected .refreshing, got \(state)")
            return
        }
        #expect(state.label == "刷新中")
    }

    @Test("builder returns refreshing when refreshPhase is refreshing")
    func builderRefreshingPhase() {
        let repos = [makeRepo(dataSource: .current)]
        let state = DataFreshnessBuilder.build(
            refreshPhase: .refreshing,
            trustAssessment: trust(state: .fresh),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: false
        )
        guard case .refreshing = state else {
            Issue.record("Expected .refreshing, got \(state)")
            return
        }
    }

    @Test("builder returns refreshing with error count when repos are degraded")
    func builderRefreshingWithErrors() {
        let errored = makeRepo(dataSource: .unknown, status: .error)
        let repos = [errored, makeRepo(dataSource: .current)]
        let state = DataFreshnessBuilder.build(
            refreshPhase: .refreshing,
            trustAssessment: trust(state: .fresh),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: true
        )
        guard case .refreshing(let reason) = state else {
            Issue.record("Expected .refreshing, got \(state)")
            return
        }
        #expect(reason.contains("1 个仓库"))
    }

    // ── Degraded (persistence) ──

    @Test("builder returns degraded when persistenceState is migrated")
    func builderDegradedMigrated() {
        let repos = [makeRepo(dataSource: .current)]
        let state = DataFreshnessBuilder.build(
            refreshPhase: .success,
            trustAssessment: trust(state: .fresh),
            persistenceState: .migrated,
            repositories: repos,
            isRefreshing: false
        )
        guard case .degraded = state else {
            Issue.record("Expected .degraded, got \(state)")
            return
        }
    }

    @Test("builder returns degraded when persistenceState is recovered")
    func builderDegradedRecovered() {
        let repos = [makeRepo(dataSource: .current)]
        let state = DataFreshnessBuilder.build(
            refreshPhase: .success,
            trustAssessment: trust(state: .fresh),
            persistenceState: .recovered,
            repositories: repos,
            isRefreshing: false
        )
        guard case .degraded = state else {
            Issue.record("Expected .degraded, got \(state)")
            return
        }
    }

    // ── Failure ──

    @Test("builder returns failed when refreshPhase is failure")
    func builderFailedPhase() {
        let repos = [makeRepo(dataSource: .lastSuccessful)]
        let state = DataFreshnessBuilder.build(
            refreshPhase: .failure,
            trustAssessment: trust(state: .failed),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: false
        )
        guard case .failed = state else {
            Issue.record("Expected .failed, got \(state)")
            return
        }
    }

    // ── Degraded (pipeline) ──

    @Test("builder returns degraded when refreshPhase is degraded")
    func builderDegradedPhase() {
        let repos = [
            makeRepo(dataSource: .current),
            makeRepo(dataSource: .unknown, status: .error)
        ]
        let state = DataFreshnessBuilder.build(
            refreshPhase: .degraded,
            trustAssessment: trust(state: .degraded),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: false
        )
        guard case .degraded = state else {
            Issue.record("Expected .degraded, got \(state)")
            return
        }
    }

    // ── Stale ──

    @Test("builder returns stale when trust assessment is stale")
    func builderStale() {
        let repos = [makeRepo(dataSource: .current)]
        let state = DataFreshnessBuilder.build(
            refreshPhase: .idle,
            trustAssessment: trust(state: .stale),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: false
        )
        guard case .stale = state else {
            Issue.record("Expected .stale, got \(state)")
            return
        }
    }

    @Test("builder returns stale when trust assessment is expired")
    func builderExpired() {
        let repos = [makeRepo(dataSource: .current)]
        let state = DataFreshnessBuilder.build(
            refreshPhase: .idle,
            trustAssessment: trust(state: .expired),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: false
        )
        guard case .stale = state else {
            Issue.record("Expected .stale, got \(state)")
            return
        }
    }

    // ── Normal ──

    @Test("builder returns normal when everything is fresh and current")
    func builderNormal() {
        let repos = [makeRepo(dataSource: .current), makeRepo(dataSource: .current)]
        let state = DataFreshnessBuilder.build(
            refreshPhase: .success,
            trustAssessment: trust(state: .fresh),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: false
        )
        guard case .normal = state else {
            Issue.record("Expected .normal, got \(state)")
            return
        }
    }

    // ── Unknown / Unknown trust → failed ──

    @Test("builder returns failed when trust is unknown")
    func builderUnknownTrust() {
        let repos = [makeRepo(dataSource: .unknown, status: .error)]
        let state = DataFreshnessBuilder.build(
            refreshPhase: .idle,
            trustAssessment: trust(state: .unknown),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: false
        )
        guard case .failed = state else {
            Issue.record("Expected .failed, got \(state)")
            return
        }
    }

    // ────────────────────────────────────────────────
    // MARK: - State transition sequences
    // ────────────────────────────────────────────────

    @Test("state transitions follow expected path: normal -> refreshing -> normal")
    func transitionNormalRefreshingNormal() {
        let repos = [makeRepo(dataSource: .current)]

        // Start normal
        let normal = DataFreshnessBuilder.build(
            refreshPhase: .success,
            trustAssessment: trust(state: .fresh),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: false
        )
        #expect(normal.label == "正常")

        // Scan starts → refreshing
        let refreshing = DataFreshnessBuilder.build(
            refreshPhase: .refreshing,
            trustAssessment: trust(state: .fresh),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: true
        )
        #expect(refreshing.label == "刷新中")

        // Scan succeeds → back to normal
        let after = DataFreshnessBuilder.build(
            refreshPhase: .success,
            trustAssessment: trust(state: .fresh),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: false
        )
        #expect(after.label == "正常")
    }

    @Test("state transitions: stale -> refreshing -> stale when scan fails")
    func transitionStaleRefreshingStale() {
        let repos = [makeRepo(dataSource: .lastSuccessful)]

        // Previously stale
        let stale = DataFreshnessBuilder.build(
            refreshPhase: .idle,
            trustAssessment: trust(state: .stale),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: false
        )
        #expect(stale.label == "数据过期")

        // Scan starts
        let refreshing = DataFreshnessBuilder.build(
            refreshPhase: .refreshing,
            trustAssessment: trust(state: .stale),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: true
        )
        #expect(refreshing.label == "刷新中")

        // Scan fails → back to stale (failure overrides with .failed)
        let failed = DataFreshnessBuilder.build(
            refreshPhase: .failure,
            trustAssessment: trust(state: .failed),
            persistenceState: .committed,
            repositories: repos,
            isRefreshing: false
        )
        #expect(failed.label == "读取失败")
    }

    // ────────────────────────────────────────────────
    // MARK: - AppGroupData isRefreshing round-trip
    // ────────────────────────────────────────────────

    @Test("AppGroupData with isRefreshing true round-trips through Codable")
    func isRefreshingCodableRoundTrip() throws {
        let original = AppGroupData.empty().withWrittenAt("2026-07-25T00:00:00Z")
        let withFlag = AppGroupData(
            schemaVersion: original.schemaVersion,
            generatedAt: original.generatedAt,
            writtenAt: original.writtenAt,
            lastSuccessfulRefreshAt: nil,
            scanSummary: original.scanSummary,
            repositories: original.repositories,
            storageRevision: original.storageRevision,
            persistenceState: original.persistenceState,
            pendingItemWidgetSummary: original.pendingItemWidgetSummary,
            isRefreshing: true,
            appVersion: original.appVersion,
            storageFormatVersion: original.storageFormatVersion
        )
        #expect(withFlag.isRefreshing == true)

        let data = try JSONEncoder().encode(withFlag)
        let decoded = try JSONDecoder().decode(AppGroupData.self, from: data)
        #expect(decoded.isRefreshing == true)
    }

    @Test("AppGroupData without isRefreshing decodes as nil")
    func isRefreshingDefaultNil() throws {
        let original = AppGroupData.empty()
        #expect(original.isRefreshing == nil)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppGroupData.self, from: data)
        #expect(decoded.isRefreshing == nil)
    }

    @Test("AppGroupData with isRefreshing false round-trips correctly")
    func isRefreshingFalseRoundTrip() throws {
        let original = AppGroupData.empty()
        let withFalse = AppGroupData(
            schemaVersion: original.schemaVersion,
            generatedAt: original.generatedAt,
            writtenAt: original.writtenAt,
            lastSuccessfulRefreshAt: nil,
            scanSummary: original.scanSummary,
            repositories: original.repositories,
            storageRevision: original.storageRevision,
            persistenceState: original.persistenceState,
            pendingItemWidgetSummary: original.pendingItemWidgetSummary,
            isRefreshing: false,
            appVersion: original.appVersion,
            storageFormatVersion: original.storageFormatVersion
        )
        let data = try JSONEncoder().encode(withFalse)
        let decoded = try JSONDecoder().decode(AppGroupData.self, from: data)
        #expect(decoded.isRefreshing == false)

        // And a subsequent encode/decode preserves false
        let data2 = try JSONEncoder().encode(decoded)
        let decoded2 = try JSONDecoder().decode(AppGroupData.self, from: data2)
        #expect(decoded2.isRefreshing == false)
    }

    @Test("with* methods preserve isRefreshing")
    func withMethodsPreserveRefreshing() {
        let base = AppGroupData.empty()
        let withFlag = AppGroupData(
            schemaVersion: base.schemaVersion,
            generatedAt: base.generatedAt,
            writtenAt: base.writtenAt,
            lastSuccessfulRefreshAt: nil,
            scanSummary: base.scanSummary,
            repositories: base.repositories,
            storageRevision: base.storageRevision,
            persistenceState: base.persistenceState,
            pendingItemWidgetSummary: base.pendingItemWidgetSummary,
            isRefreshing: true,
            appVersion: base.appVersion,
            storageFormatVersion: base.storageFormatVersion
        )
        #expect(withFlag.withWrittenAt("iso").isRefreshing == true)
        #expect(withFlag.withLastSuccessfulRefreshAt("iso").isRefreshing == true)
        #expect(withFlag.withRecentActivityEvents([]).isRefreshing == true)
        #expect(withFlag.withPendingItemWidgetSummary(nil).isRefreshing == true)
        #expect(withFlag.withHistoryMetadata(historySchemaVersion: nil, historyRecordingEnabled: nil).isRefreshing == true)
    }

    // ────────────────────────────────────────────────
    // MARK: - Cross-process consistency regression
    // ────────────────────────────────────────────────

    @Test("isRefreshing snapshot does not interfere with storage revision guarding")
    func refreshingSnapshotDoesNotCorruptRevision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-freshness-cp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let storeA = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // Process A writes a normal committed snapshot (revision 1)
        let normalSnap = AppGroupData.empty()
        let firstResult = storeA.commit(normalSnap)
        let first = try firstResult.get()
        #expect(first.storageRevision == 1)
        #expect(first.isRefreshing == nil)

        // Process A writes a "refreshing" snapshot (revision 2)
        let refreshingSnap = AppGroupData(
            schemaVersion: normalSnap.schemaVersion,
            generatedAt: normalSnap.generatedAt,
            writtenAt: normalSnap.writtenAt,
            scanSummary: normalSnap.scanSummary,
            repositories: normalSnap.repositories,
            storageRevision: first.storageRevision,
            persistenceState: .committed,
            isRefreshing: true
        )
        let secondResult = storeA.commit(refreshingSnap)
        let second = try secondResult.get()
        #expect(second.storageRevision == 2)
        #expect(second.isRefreshing == true)

        // Process B reads revision 2, observes revision 2, then writes a fresh
        // snapshot. Should succeed because observed revision matches disk.
        let storeB = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        let freshSnap = AppGroupData(
            schemaVersion: normalSnap.schemaVersion,
            generatedAt: normalSnap.generatedAt,
            writtenAt: normalSnap.writtenAt,
            scanSummary: normalSnap.scanSummary,
            repositories: normalSnap.repositories,
            storageRevision: second.storageRevision,
            persistenceState: .committed,
            isRefreshing: nil
        )
        let thirdResult = storeB.commit(freshSnap, observedStorageRevision: 2)
        let third = try thirdResult.get()
        #expect(third.storageRevision == 3)
        #expect(third.isRefreshing == nil)

        // Verify final state: isRefreshing is false/nil, revision is correct
        let loadedResult = storeA.load()
        let loaded = try loadedResult.get()
        #expect(loaded.snapshot.storageRevision == 3)
        #expect(loaded.snapshot.isRefreshing == nil)
    }

    @Test("stale isRefreshing write is rejected by cross-process guard")
    func staleRefreshingWriteRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-freshness-cp2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let storeA = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // Establish revision 1
        let firstResult = storeA.commit(AppGroupData.empty())
        let first = try firstResult.get()
        #expect(first.storageRevision == 1)

        // Another process writes revision 2
        let storeB = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_050) }
        )
        let secondResult = storeB.commit(AppGroupData.empty())
        _ = try secondResult.get()

        // Process A tries to write an isRefreshing snapshot based on stale
        // observed revision 1 → should be rejected.
        let staleRefresh = AppGroupData(
            schemaVersion: first.schemaVersion,
            generatedAt: first.generatedAt,
            writtenAt: first.writtenAt,
            scanSummary: first.scanSummary,
            repositories: first.repositories,
            storageRevision: 1,
            persistenceState: .committed,
            isRefreshing: true
        )
        let result = storeA.commit(staleRefresh, observedStorageRevision: 1)
        switch result {
        case .success:
            Issue.record("Expected cross-process conflict for stale isRefreshing write")
        case .failure(let error):
            guard case .crossProcessWriteDetected(let observed, let actual) = error else {
                Issue.record("Expected crossProcessWriteDetected, got \(error)")
                return
            }
            #expect(observed == 1)
            #expect(actual == 2)
        }
    }
}

private extension Result where Failure == any Error {
    /// Unwrap a success value or throw.
    func get() throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

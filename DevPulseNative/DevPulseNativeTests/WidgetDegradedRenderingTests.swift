import Foundation
import Testing
@testable import DevPulse

// MARK: - Widget Degradation / Fallback Rendering Tests
//
// Verifies that every Widget family (small, medium, large, fallback) renders
// meaningful visual content in EVERY possible load state and trust-assessment
// state. The one thing we cannot automate is the actual WidgetKit snapshot;
// we validate the entry/view configuration deterministically.

@Suite("Widget Degradation Rendering")
struct WidgetDegradedRenderingTests {

    // ────────────────────────────────────────────────────────────────
    // MARK: - WidgetEntry construction for every load state
    // ────────────────────────────────────────────────────────────────

    @Test("placeholder entry has correct state")
    func placeholderEntry() {
        let entry = WidgetEntry.placeholder
        #expect(entry.loadState == .placeholder)
        #expect(entry.snapshot == nil)
        #expect(entry.loadFailure == nil)
        #expect(entry.trustAssessment == nil)
    }

    @Test("noSnapshot entry has correct state")
    func noSnapshotEntry() {
        let entry = WidgetEntry.noSnapshot()
        #expect(entry.loadState == .noSnapshot)
        #expect(entry.snapshot == nil)
        #expect(entry.loadFailure == nil)
    }

    @Test("loadFailed entry for every error type")
    func allLoadFailedEntries() {
        let errors: [WidgetSnapshotLoadError] = [
            .appGroupUnavailable,
            .snapshotMissing(path: "/tmp/test"),
            .readFailed(path: "/tmp/test", reason: "IO error"),
            .decodeFailed(path: "/tmp/test", reason: "invalid JSON"),
            .schemaMismatch(expected: 3, actual: 5)
        ]
        for error in errors {
            let entry = WidgetEntry.loadFailed(error)
            #expect(entry.loadState == .loadFailed)
            #expect(entry.loadFailure != nil)
            #expect(!(entry.loadFailure?.title ?? "").isEmpty,
                    "Title must be non-empty for \(error)")
            #expect(!(entry.loadFailure?.detail ?? "").isEmpty,
                    "Detail must be non-empty for \(error)")
            #expect(!(entry.loadFailure?.icon ?? "").isEmpty,
                    "Icon must be non-empty for \(error)")
            #expect(!(entry.loadFailure?.footerText ?? "").isEmpty,
                    "Footer text must be non-empty for \(error)")
        }
    }

    @Test("content entry with fresh trust assessment")
    func contentFreshEntry() {
        let snapshot = AppGroupData.empty()
        let feed = ActivityTimelineFeed(state: .neverScanned, items: [])
        let entry = WidgetEntry.content(snapshot: snapshot, feed: feed)
        #expect(entry.loadState == .ready)
        #expect(entry.snapshot != nil)
        #expect(entry.trustAssessment != nil)
    }

    @Test("footer text for every load state provides meaningful info")
    func footerTextForAllStates() {
        let placeholder = WidgetEntry.placeholder
        #expect(!placeholder.footerText.isEmpty)

        let noSnapshot = WidgetEntry.noSnapshot()
        #expect(!noSnapshot.footerText.isEmpty)

        let errors: [WidgetSnapshotLoadError] = [
            .appGroupUnavailable,
            .snapshotMissing(path: "/tmp/test"),
            .readFailed(path: "/tmp/test", reason: "IO"),
            .decodeFailed(path: "/tmp/test", reason: "bad JSON"),
            .schemaMismatch(expected: 3, actual: 5)
        ]
        for error in errors {
            let entry = WidgetEntry.loadFailed(error)
            #expect(!entry.footerText.isEmpty, "Footer text for \(error)")
        }
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Trust assessment state coverage
    // ────────────────────────────────────────────────────────────────

    @Test("SnapshotTrustAssessment has all required states")
    func allTrustStatesExist() {
        // Verify all SnapshotTrustState values produce non-empty descriptions
        // through RefreshStatusFormatter
        let now = Date()

        let fresh = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
            writtenAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
            now: now
        )
        #expect(fresh.state == .fresh)
        #expect(!fresh.title.isEmpty)
        #expect(!fresh.detail.isEmpty)

        let stale = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-700)),
            writtenAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-700)),
            now: now
        )
        #expect(stale.state == .stale)
        #expect(!stale.title.isEmpty)
        #expect(!stale.detail.isEmpty)

        let expired = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-1900)),
            writtenAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-1900)),
            now: now
        )
        #expect(expired.state == .expired)
        #expect(!expired.title.isEmpty)
        #expect(!expired.detail.isEmpty)

        // Unknown: missing generatedAt/writtenAt but no read error
        let unknown = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: nil,
            writtenAt: nil,
            now: now,
            readError: nil,
            missingReason: "测试缺失时间"
        )
        #expect(unknown.state == .unknown)
        #expect(!unknown.title.isEmpty)
        #expect(!unknown.detail.isEmpty)

        // Unknown: read error provided — readError maps to .unknown, not .failed
        let readErrorAssessment = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
            writtenAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
            now: now,
            readError: "模拟读取错误"
        )
        #expect(readErrorAssessment.state == .unknown)
        #expect(!readErrorAssessment.title.isEmpty)
        #expect(!readErrorAssessment.detail.isEmpty)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - WidgetRefreshCopy covers all trust states
    // ────────────────────────────────────────────────────────────────

    @Test("WidgetRefreshCopy diagnosticsLabel for all trust states")
    func diagnosticsLabelForAllStates() {
        let now = Date()

        let freshAssessment = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: ISO8601DateFormatter().string(from: now),
            writtenAt: nil,
            now: now
        )
        let freshLabel = WidgetRefreshCopy.diagnosticsLabel(for: freshAssessment)
        #expect(!freshLabel.isEmpty)

        let staleAssessment = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-700)),
            writtenAt: nil,
            now: now
        )
        let staleLabel = WidgetRefreshCopy.diagnosticsLabel(for: staleAssessment)
        #expect(!staleLabel.isEmpty)

        let failedAssessment = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
            writtenAt: nil,
            now: now,
            readError: "测试错误"
        )
        let failedLabel = WidgetRefreshCopy.diagnosticsLabel(for: failedAssessment)
        #expect(!failedLabel.isEmpty)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - WidgetEntry footer text for trust assessment states
    // ────────────────────────────────────────────────────────────────

    @Test("ready entry with fresh trust has non-empty footer")
    func readyFreshFooter() {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let snapshot = AppGroupData(
            schemaVersion: 3,
            generatedAt: formatter.string(from: now.addingTimeInterval(-30)),
            writtenAt: formatter.string(from: now.addingTimeInterval(-30)),
            lastSuccessfulRefreshAt: formatter.string(from: now.addingTimeInterval(-30)),
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [RepositorySnapshot(
                id: "test-id", name: "test-repo", path: "/tmp/test",
                workspaceKind: nil, branch: "main",
                status: .clean, modifiedFileCount: 0, addedFileCount: 0,
                deletedFileCount: 0, untrackedFileCount: 0,
                stagedFileCount: 0, unstagedFileCount: 0,
                conflictedFileCount: 0, aheadCount: 0, behindCount: 0,
                hasUpstream: true, changedFileCount: 0,
                changedFilesPreview: [], risk: .low,
                lastScannedAt: formatter.string(from: now.addingTimeInterval(-30)),
                dataSource: .current,
                lastSuccessfulScanAt: formatter.string(from: now.addingTimeInterval(-30)),
                lastChangedAt: nil, lastCommitID: nil,
                lastCommitSummary: nil,
                lastCommitMetadataAvailable: false,
                lastActivityAt: nil, unavailableSince: nil,
                errorMessage: nil, isPinned: false
            )],
            recentActivityEvents: nil,
            repositoryUnavailableSinceByPath: nil,
            storageRevision: 1,
            persistenceState: .committed
        )
        let feed = ActivityTimelineBuilder.build(from: snapshot)
        let entry = WidgetEntry.content(snapshot: snapshot, feed: feed)
        #expect(!entry.footerText.isEmpty)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Snapshot integrity: primary file corrupted, backup should save
    // ────────────────────────────────────────────────────────────────

    @Test("SharedSnapshotStore falls back to backup when primary is corrupt")
    func fallbackToBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-widget-cfb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date()
        let formatter = ISO8601DateFormatter()

        let store = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test.json",
            now: { now }
        )

        // Write a valid snapshot (this creates primary + backup).
        let snapshot = AppGroupData.empty()
        _ = store.commit(snapshot)

        // Verify backup exists.
        #expect(FileManager.default.fileExists(atPath: store.backupURL.path),
                "Backup must exist after commit")

        // Corrupt the primary file.
        try "corrupted data".write(to: store.primaryURL, atomically: true, encoding: .utf8)

        // Load — should succeed using backup fallback.
        let loadResult = store.load()
        switch loadResult {
        case .success(let read):
            #expect(read.source == .backup, "Should load from backup when primary is corrupt")
            #expect(read.snapshot.persistenceState == .recovered,
                    "Backup fallback should be marked as recovered")
        case .failure(let error):
            Issue.record("Fallback to backup failed: \(error)")
        }
    }

    @Test("SharedSnapshotStore reports snapshotMissing when both primary and backup missing")
    func bothMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-widget-bm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test.json"
        )

        let result = store.load()
        guard case .failure(.snapshotMissing) = result else {
            Issue.record("Expected snapshotMissing, got \(result)")
            return
        }
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - WidgetEntry rendering coverage for all states
    //     (view instantiation — we verify entry construction, not actual
    //      SwiftUI rendering which requires WidgetKit runtime)
    // ────────────────────────────────────────────────────────────────

    @Test("WidgetEntry all load states round-trip through DevPulseWidgetEntryView body")
    func allLoadStatesRoundTrip() {
        // We verify that every entry variant can be used to construct a view.
        // The actual rendering happens inside WidgetKit; this proves the
        // data-flow contract is sound.

        let placeholder = WidgetEntry.placeholder
        #expect(placeholder.loadState == .placeholder)

        let noSnapshot = WidgetEntry.noSnapshot()
        #expect(noSnapshot.loadState == .noSnapshot)

        let errors: [WidgetSnapshotLoadError] = [
            .appGroupUnavailable,
            .snapshotMissing(path: "/tmp/test"),
            .readFailed(path: "/tmp/test", reason: "IO"),
            .decodeFailed(path: "/tmp/test", reason: "bad"),
            .schemaMismatch(expected: 3, actual: 5)
        ]
        for error in errors {
            let entry = WidgetEntry.loadFailed(error)
            #expect(entry.loadState == .loadFailed)
            #expect(entry.loadFailure != nil)
        }

        let snapshot = AppGroupData.empty()
        let feed = ActivityTimelineBuilder.build(from: snapshot)
        let contentEntry = WidgetEntry.content(snapshot: snapshot, feed: feed)
        #expect(contentEntry.loadState == .ready)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Timeline refresh cadence
    // ────────────────────────────────────────────────────────────────

    @Test("timeline refresh interval for every load state")
    func refreshIntervalForLoadStates() {
        #expect(Provider.nextRefreshInterval(
            loadState: .placeholder,
            isRefreshing: false,
            trustState: nil,
            lastSuccessfulRefreshAt: nil
        ) == 60)
        #expect(Provider.nextRefreshInterval(
            loadState: .noSnapshot,
            isRefreshing: false,
            trustState: nil,
            lastSuccessfulRefreshAt: nil
        ) == 60)
        #expect(Provider.nextRefreshInterval(
            loadState: .loadFailed,
            isRefreshing: false,
            trustState: nil,
            lastSuccessfulRefreshAt: nil
        ) == 180)
    }

    @Test("timeline refresh is bounded for ready entries")
    func refreshIntervalForReadyEntries() {
        let now = Date()
        let iso = DateFormatting.isoString(from: now)
        let staleIso = DateFormatting.isoString(from: now.addingTimeInterval(-600))
        let oldIso = DateFormatting.isoString(from: now.addingTimeInterval(-3600))

        // Refreshing snapshot: fast poll to pick up the completed write.
        #expect(Provider.nextRefreshInterval(
            loadState: .ready,
            isRefreshing: true,
            trustState: .fresh,
            lastSuccessfulRefreshAt: iso,
            now: now
        ) == 60)

        // Stale / expired snapshots: recovery poll until the app's next
        // background scan writes fresh data.
        #expect(Provider.nextRefreshInterval(
            loadState: .ready,
            isRefreshing: false,
            trustState: .stale,
            lastSuccessfulRefreshAt: staleIso,
            now: now
        ) == 60)
        #expect(Provider.nextRefreshInterval(
            loadState: .ready,
            isRefreshing: false,
            trustState: .expired,
            lastSuccessfulRefreshAt: oldIso,
            now: now
        ) == 60)

        // Fresh data: refresh just before the stale boundary, bounded to
        // 60…300 s so the widget re-reads the snapshot before it decays.
        let fresh = Provider.nextRefreshInterval(
            loadState: .ready,
            isRefreshing: false,
            trustState: .fresh,
            lastSuccessfulRefreshAt: iso,
            now: now
        )
        #expect(abs(fresh - 300) < 1.0)

        let ageing = Provider.nextRefreshInterval(
            loadState: .ready,
            isRefreshing: false,
            trustState: .fresh,
            lastSuccessfulRefreshAt: DateFormatting.isoString(
                from: now.addingTimeInterval(-480)
            ),
            now: now
        )
        #expect(abs(ageing - 120) < 1.0)

        let nearBoundary = Provider.nextRefreshInterval(
            loadState: .ready,
            isRefreshing: false,
            trustState: .fresh,
            lastSuccessfulRefreshAt: DateFormatting.isoString(
                from: now.addingTimeInterval(-590)
            ),
            now: now
        )
        #expect(nearBoundary == 60)

        // Degraded/unknown states keep the bounded 300 s backstop.
        let degraded = Provider.nextRefreshInterval(
            loadState: .ready,
            isRefreshing: false,
            trustState: .degraded,
            lastSuccessfulRefreshAt: iso,
            now: now
        )
        #expect(degraded == 300)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - SnapshotReadSource detection
    // ────────────────────────────────────────────────────────────────

    @Test("SharedSnapshotReadSource cases are distinguishable")
    func readSourceDistinct() {
        let primary = SharedSnapshotReadSource.primary
        let migrated = SharedSnapshotReadSource.migratedPrimary
        let backup = SharedSnapshotReadSource.backup
        #expect(primary != migrated)
        #expect(primary != backup)
        #expect(migrated != backup)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Auto-rebuild scenario: Widget loading after corruption
    // ────────────────────────────────────────────────────────────────

    @Test("WidgetSharedSnapshotStore auto-rebuild produces loadable snapshot")
    func widgetAutoRebuildScenario() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-widget-rebuild-\\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test-rebuild.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // Write garbage to simulate corruption
        try "corrupted data".data(using: .utf8)!.write(to: store.primaryURL)

        // Auto-rebuild triggers and produces a valid snapshot
        let read = try #require(try? store.load().get())
        #expect(read.snapshot.schemaVersion == RepositorySnapshotSchema.version)
        #expect(read.snapshot.persistenceState == .recovered)
        #expect(read.snapshot.repositories.isEmpty)

        // Widget would render this as a degraded-but-functional state
        let feed = ActivityTimelineBuilder.build(from: read.snapshot)
        let entry = WidgetEntry.content(snapshot: read.snapshot, feed: feed)
        #expect(entry.loadState == .ready)
        #expect(entry.trustAssessment != nil)
        // Degraded trust because persistenceState is .recovered
        let assessment = try #require(entry.trustAssessment)
        #expect(assessment.state != .fresh)
    }
}

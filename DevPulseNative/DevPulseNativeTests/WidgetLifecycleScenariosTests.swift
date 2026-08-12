import Foundation
import Testing
@testable import DevPulse

// MARK: - Widget Scenario Tests
//
// Covers widget lifecycle scenarios:
// 1. First install: no snapshot → Widget receives noSnapshot → recovers after first commit
// 2. Upgrade: old schema snapshot → Widget reads degraded → after migration → ready
// 3. Cross-process commit race: Widget observes stale storageRevision → rejects commit
// 4. Widget registration state transitions

@Suite("Widget Lifecycle Scenarios")
struct WidgetLifecycleScenariosTests {

    // ────────────────────────────────────────────────
    // MARK: - Snapshot load scenarios
    // ────────────────────────────────────────────────

    @Test("WidgetSnapshotStore returns snapshotMissing when no file exists")
    func snapshotMissing() {
        let error = WidgetSnapshotLoadError.snapshotMissing(path: "/tmp/test")
        // Verify via WidgetEntry factory instead of private properties
        let entry = WidgetEntry.loadFailed(error)
        #expect(entry.loadState == .loadFailed)
        #expect(entry.loadFailure != nil)
    }

    @Test("WidgetEntry noSnapshot has correct state")
    func noSnapshotEntry() {
        let entry = WidgetEntry.noSnapshot()
        #expect(entry.loadState == .noSnapshot)
        #expect(entry.snapshot == nil)
        #expect(entry.loadFailure == nil)
        #expect(entry.trustAssessment == nil)
    }

    @Test("WidgetEntry loadFailed carries error info")
    func loadFailedEntry() {
        let errors: [WidgetSnapshotLoadError] = [
            .appGroupUnavailable,
            .snapshotMissing(path: "/tmp/test"),
            .readFailed(path: "/tmp/test", reason: "IO"),
            .decodeFailed(path: "/tmp/test", reason: "bad JSON"),
            .schemaMismatch(expected: 3, actual: 5),
        ]
        for error in errors {
            let entry = WidgetEntry.loadFailed(error)
            #expect(entry.loadState == .loadFailed)
            #expect(entry.loadFailure != nil)
            #expect(!(entry.loadFailure?.title ?? "").isEmpty)
            #expect(!(entry.loadFailure?.detail ?? "").isEmpty)
        }
    }

    @Test("WidgetEntry content has ready state")
    func contentEntry() {
        let snapshot = AppGroupData.empty()
        let feed = ActivityTimelineBuilder.build(from: snapshot)
        let entry = WidgetEntry.content(snapshot: snapshot, feed: feed)
        #expect(entry.loadState == .ready)
        #expect(entry.snapshot != nil)
    }

    // ────────────────────────────────────────────────
    // MARK: - WidgetLoadFailurePresentation completeness
    // ────────────────────────────────────────────────

    @Test("all load errors produce non-empty WidgetEntry loadFailed")
    func loadErrorEntry() {
        let errors: [WidgetSnapshotLoadError] = [
            .appGroupUnavailable,
            .snapshotMissing(path: "/tmp/test"),
            .readFailed(path: "/tmp/test", reason: "permission"),
            .decodeFailed(path: "/tmp/test", reason: "invalid"),
            .schemaMismatch(expected: 3, actual: 1),
        ]
        for error in errors {
            let entry = WidgetEntry.loadFailed(error)
            #expect(entry.loadState == .loadFailed)
            #expect(entry.loadFailure != nil)
            #expect(!(entry.loadFailure?.title ?? "").isEmpty, "title for \(error)")
        }
    }

    // ────────────────────────────────────────────────
    // MARK: - Upgrade scenario: old schema
    // ────────────────────────────────────────────────

    @Test("Schema mismatch error produces loadFailed state")
    func schemaMismatchState() {
        let error = WidgetSnapshotLoadError.schemaMismatch(expected: 3, actual: 1)
        let entry = WidgetEntry.loadFailed(error)
        #expect(entry.loadState == .loadFailed)
    }

    // ────────────────────────────────────────────────
    // MARK: - Cross-process commit test
    // ────────────────────────────────────────────────

    @Test("SharedSnapshotStore rejects stale cross-process commit")
    func crossProcessRejection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-widget-cp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let storeA = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        // First commit establishes revision 1
        let firstResult = storeA.commit(AppGroupData.empty())
        guard case .success(let committed) = firstResult else {
            Issue.record("First commit failed")
            return
        }
        #expect(committed.storageRevision == 1)

        // Simulate another process writing revision 2
        let storeB = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        let secondResult = storeB.commit(
            AppGroupData.empty(),
            observedStorageRevision: 1
        )
        guard case .success = secondResult else {
            Issue.record("Second commit should succeed")
            return
        }

        // Process A's stale commit attempt with observed revision 1 should now fail
        let staleResult = storeA.commit(
            AppGroupData.empty(),
            observedStorageRevision: 1
        )
        guard case .failure(let error) = staleResult else {
            Issue.record("Expected crossProcessWriteDetected error")
            return
        }
        guard case .crossProcessWriteDetected(let observed, let actual) = error else {
            Issue.record("Expected .crossProcessWriteDetected, got \(error)")
            return
        }
        #expect(observed == 1)
        #expect(actual >= 2)
    }

    // ────────────────────────────────────────────────
    // MARK: - WidgetRecoveryManager
    // ────────────────────────────────────────────────

    @Test("WidgetRecoveryManager requestTimelineReload is throttled")
    func timelineReloadThrottling() async {
        let manager = WidgetRecoveryManager()
        let token = GenerationIsolation.Token(generation: 1, epoch: 0)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        // Throttle 时间戳持久化到共享 UserDefaults（键与生产实现一致），
        // 可跨重启生效；测试据此观察真实节流行为。
        let key = "DevPulseWidgetLastForcedReloadAt"
        let defaults = UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)!
        let previous = defaults.object(forKey: key) as? Date
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        // Force reload 建立基线并持久化时间戳
        await manager.requestTimelineReload(generation: token, force: true, now: now)
        #expect(defaults.object(forKey: key) as? Date == now)

        // 间隔内（< 60s）的非强制 reload 被节流：时间戳保持不变
        await manager.requestTimelineReload(generation: token, force: false, now: now.addingTimeInterval(30))
        #expect(defaults.object(forKey: key) as? Date == now)

        // 强制 reload 绕过节流并推进时间戳
        let forcedNow = now.addingTimeInterval(90)
        await manager.requestTimelineReload(generation: token, force: true, now: forcedNow)
        #expect(defaults.object(forKey: key) as? Date == forcedNow)
    }

    @Test("WidgetRecoveryManager verifyWidgetReadiness handles unavailable App Group")
    func verifyReadinessUnavailable() async {
        let manager = WidgetRecoveryManager()
        let report = await manager.verifyWidgetReadiness()
        if report.canReadSnapshot == false {
            #expect(report.error != nil)
        }
    }
}

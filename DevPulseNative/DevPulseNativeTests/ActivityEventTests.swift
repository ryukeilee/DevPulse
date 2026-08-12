import Foundation
import Testing
@testable import DevPulse

struct ActivityEventTests {
    @Test func unchangedSnapshotsDoNotProduceDuplicateEvents() {
        let baseline = snapshot()
        let previous = data([baseline], generatedAt: "2026-07-15T10:00:00Z")
        let current = data([baseline], generatedAt: "2026-07-15T10:05:00Z")

        #expect(ActivityEventDiffer.events(
            previous: previous,
            current: current,
            observedAt: current.generatedAt
        ).isEmpty)

        let legacyCounts = snapshot(modified: 1, staged: nil, unstaged: nil)
        let explicitCounts = snapshot(modified: 1, staged: 0, unstaged: 1)
        #expect(ActivityEventDiffer.events(
            previous: legacyCounts,
            current: explicitCounts,
            observedAt: "2026-07-15T10:10:00Z"
        ).isEmpty)
    }

    @Test func differDetectsCommitWorkingTreeStagingBranchSyncAndConflictTransitions() {
        let previous = snapshot(
            branch: "main",
            modified: 1,
            staged: 0,
            unstaged: 1,
            conflicted: 0,
            ahead: 0,
            behind: 0,
            lastCommitID: "old",
            lastCommitSummary: "Old"
        )
        let current = snapshot(
            branch: "feature",
            modified: 2,
            untracked: 1,
            staged: 1,
            unstaged: 2,
            conflicted: 1,
            ahead: 2,
            behind: 1,
            lastCommitID: "new",
            lastCommitSummary: "New"
        )

        let detected = ActivityEventDiffer.events(
            previous: previous,
            current: current,
            observedAt: "2026-07-16T10:00:00Z"
        )
        let kinds = Set(detected.map(\.kind))

        #expect(kinds == Set([
            .newCommit,
            .workingTreeChanged,
            .stagingChanged,
            .branchChanged,
            .synchronizationChanged,
            .conflictStarted
        ]))
        #expect(detected.map(\.kind) == [
            .conflictStarted,
            .newCommit,
            .branchChanged,
            .synchronizationChanged,
            .stagingChanged,
            .workingTreeChanged
        ])

        let resolved = snapshot(
            branch: "feature",
            modified: 2,
            untracked: 1,
            staged: 1,
            unstaged: 2,
            conflicted: 0,
            ahead: 2,
            behind: 1,
            lastCommitID: "new",
            lastCommitSummary: "New"
        )
        let resolutionKinds = ActivityEventDiffer.events(
            previous: current,
            current: resolved,
            observedAt: "2026-07-16T10:05:00Z"
        ).map(\.kind)
        #expect(resolutionKinds == [.conflictResolved])
        #expect(ActivityEventDiffer.events(
            previous: snapshot(modified: 2),
            current: snapshot(modified: 1),
            observedAt: "2026-07-16T10:10:00Z"
        ).map(\.kind) == [.workingTreeChanged])
    }

    @Test func readFailureIsDeduplicatedAndRecoveryIsRecorded() {
        let readable = snapshot(modified: 2, staged: 1, unstaged: 1)
        let failed = readable.retainingLastSuccessfulData(
            attemptedAt: "2026-07-16T11:00:00Z",
            errorMessage: "读取失败"
        )
        let repeatedFailure = failed.retainingLastSuccessfulData(
            attemptedAt: "2026-07-16T11:05:00Z",
            errorMessage: "读取失败"
        )

        #expect(ActivityEventDiffer.events(
            previous: readable,
            current: failed,
            observedAt: "2026-07-16T11:00:00Z"
        ).map(\.kind) == [.readFailed])
        #expect(ActivityEventDiffer.events(
            previous: failed,
            current: repeatedFailure,
            observedAt: "2026-07-16T11:05:00Z"
        ).isEmpty)
        #expect(ActivityEventDiffer.events(
            previous: repeatedFailure,
            current: readable,
            observedAt: "2026-07-16T11:10:00Z"
        ).map(\.kind) == [.readRecovered])
    }

    @Test func attentionCountCoversConflictsAndReadFailuresOnly() {
        // 「最近变化」提示条只统计需要优先确认的事件（冲突开始 / 读取失败），
        // 冲突解除、读取恢复与普通改动不计入，避免计数与提示口径漂移。
        let readable = snapshot(modified: 2, conflicted: 1)
        let failed = readable.retainingLastSuccessfulData(
            attemptedAt: "2026-07-16T11:00:00Z",
            errorMessage: "读取失败"
        )

        let conflictStarted = try? #require(event(
            previous: snapshot(modified: 2, conflicted: 0),
            current: snapshot(modified: 2, conflicted: 1),
            at: "2026-07-16T10:00:00Z",
            kind: .conflictStarted
        ))
        let conflictResolved = try? #require(event(
            previous: snapshot(modified: 2, conflicted: 1),
            current: snapshot(modified: 2, conflicted: 0),
            at: "2026-07-16T10:30:00Z",
            kind: .conflictResolved
        ))
        let readFailed = try? #require(event(
            previous: readable,
            current: failed,
            at: "2026-07-16T11:00:00Z",
            kind: .readFailed
        ))
        let readRecovered = try? #require(event(
            previous: failed,
            current: readable,
            at: "2026-07-16T11:30:00Z",
            kind: .readRecovered
        ))
        let changed = try? #require(makeWorkingTreeEvent(from: 1, to: 2, at: "2026-07-16T12:00:00Z"))

        let all = [conflictStarted, conflictResolved, readFailed, readRecovered, changed].compactMap { $0 }
        #expect(all.count == 5)
        #expect(ActivityTimelineAttention.count(in: all) == 2)

        #expect(ActivityTimelineAttention.count(
            in: [conflictStarted, readFailed].compactMap { $0 }
        ) == 2)
        #expect(ActivityTimelineAttention.count(
            in: [conflictResolved, readRecovered, changed].compactMap { $0 }
        ) == 0)
        #expect(ActivityTimelineAttention.count(in: []) == 0)
    }

    @Test func persistedTransitionPreventsReplayAfterSnapshotWriteFailureButAllowsCycles() throws {
        let first = try #require(makeWorkingTreeEvent(
            from: 0,
            to: 1,
            at: "2026-07-16T11:00:00Z"
        ))
        let replay = try #require(makeWorkingTreeEvent(
            from: 0,
            to: 1,
            at: "2026-07-16T11:05:00Z"
        ))
        let inverse = try #require(makeWorkingTreeEvent(
            from: 1,
            to: 0,
            at: "2026-07-16T11:10:00Z"
        ))
        let repeatedAfterCycle = try #require(makeWorkingTreeEvent(
            from: 0,
            to: 1,
            at: "2026-07-16T11:15:00Z"
        ))

        #expect(ActivityEventDeduplicator.newEvents(
            from: [replay],
            comparedTo: [first]
        ).isEmpty)
        #expect(ActivityEventDeduplicator.newEvents(
            from: [repeatedAfterCycle],
            comparedTo: [inverse, first]
        ) == [repeatedAfterCycle])
    }

    @Test func eventStoreDeduplicatesSortsAndTrimsWhileKeepingCrossDayEvents() throws {
        let url = temporaryURL()
        let store = ActivityEventStore(fileURL: url, capacity: 2)
        let older = try #require(makeWorkingTreeEvent(
            from: 0,
            to: 1,
            at: "2026-07-14T09:00:00Z"
        ))
        let middle = try #require(makeWorkingTreeEvent(
            from: 1,
            to: 2,
            at: "2026-07-15T09:00:00Z"
        ))
        let newest = try #require(makeWorkingTreeEvent(
            from: 2,
            to: 3,
            at: "2026-07-16T09:00:00Z"
        ))

        let merged = store.merging(
            existing: [older, middle],
            newEvents: [middle, newest]
        )
        #expect(merged.map(\.id) == [newest.id, middle.id])

        let saved = try store.save(merged).get()
        let loaded = try store.load().get()
        #expect(saved == loaded.events)
        #expect(loaded.events.map(\.occurredAt) == [
            "2026-07-16T09:00:00Z",
            "2026-07-15T09:00:00Z"
        ])
    }

    @Test func eventStoreMigratesLegacyArrayAndRecoversCorruption() throws {
        let url = temporaryURL()
        let store = ActivityEventStore(fileURL: url)
        let event = try #require(makeWorkingTreeEvent(
            from: 0,
            to: 1,
            at: "2026-07-16T09:00:00Z"
        ))
        try JSONEncoder().encode([event]).write(to: url, options: .atomic)

        let migrated = try store.load().get()
        #expect(migrated.recovery == .migratedLegacy)
        #expect(migrated.events == [event])
        let archive = try JSONDecoder().decode(
            ActivityEventArchive.self,
            from: Data(contentsOf: url)
        )
        #expect(archive.schemaVersion == ActivityEventArchive.currentSchemaVersion)

        try Data("not-json".utf8).write(to: url, options: .atomic)
        let recovered = try store.load().get()
        #expect(recovered.recovery == .recoveredCorruption)
        #expect(recovered.events.isEmpty)
        #expect(try store.save([event]).get() == [event])
        #expect(try store.load().get().events == [event])
    }

    @Test func widgetProjectionIsBoundedRecentPriorityOrderedAndRoundTrips() throws {
        let conflict = try #require(event(
            previous: snapshot(conflicted: 0),
            current: snapshot(conflicted: 1),
            at: "2026-07-15T08:00:00Z",
            kind: .conflictStarted
        ))
        let latest = try #require(makeWorkingTreeEvent(
            from: 0,
            to: 1,
            at: "2026-07-16T08:00:00Z"
        ))
        let old = try #require(makeWorkingTreeEvent(
            from: 1,
            to: 2,
            at: "2026-07-01T08:00:00Z"
        ))
        let summaries = ActivityEventWidgetSummaryBuilder.build(
            from: [latest, old, conflict],
            now: try #require(DateFormatting.date(from: "2026-07-16T09:00:00Z"))
        )

        #expect(summaries.count == 2)
        #expect(summaries.first?.kind == .conflictStarted)
        #expect(!summaries.contains { $0.id == old.id })

        let payload = data([snapshot()], generatedAt: "2026-07-16T09:00:00Z")
            .withRecentActivityEvents(summaries)
        let decoded = try JSONDecoder().decode(
            AppGroupData.self,
            from: JSONEncoder().encode(payload)
        )
        #expect(decoded.recentActivityEvents == summaries)
        #expect(ActivityEventWidgetSummaryBuilder.topSummary(
            from: decoded.recentActivityEvents ?? []
        )?.id == conflict.id)
    }

    @Test func normalizedSnapshotRemapsLegacyActivityIDsAndDropsRemovedSummaries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-normalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)

        let legacyRepository = snapshot(id: "legacy-repository", path: alias.path)
        let legacyEvent = ActivityEventSummary(
            id: "legacy-event",
            repositoryID: "legacy-repository",
            repositoryName: legacyRepository.name,
            kind: .workingTreeChanged,
            occurredAt: "2026-07-16T09:00:00Z",
            message: "旧路径活动",
            priority: ActivityEventKind.workingTreeChanged.priority
        )
        let removedEvent = ActivityEventSummary(
            id: "removed-event",
            repositoryID: "removed-repository",
            repositoryName: "Removed",
            kind: .workingTreeChanged,
            occurredAt: "2026-07-16T09:01:00Z",
            message: "已移除活动",
            priority: ActivityEventKind.workingTreeChanged.priority
        )
        let normalized = RepositoryIdentity.normalize(
            data([legacyRepository], generatedAt: "2026-07-16T09:05:00Z")
                .withRecentActivityEvents([legacyEvent, removedEvent])
        )

        let currentID = RepositoryIdentity.id(for: repository.path)
        let repositoryIDs = normalized.repositories.map { $0.id }
        let eventRepositoryIDs = normalized.recentActivityEvents?.map { $0.repositoryID } ?? []
        #expect(repositoryIDs == [currentID])
        #expect(eventRepositoryIDs == [currentID])
        #expect(normalized.recentActivityEvents?.first?.id == legacyEvent.id)
    }

    @Test func eventStorePruningKeepsOnlyCurrentRepositoryIDs() throws {
        let store = ActivityEventStore(fileURL: temporaryURL())
        let kept = try #require(makeWorkingTreeEvent(from: 0, to: 1, at: "2026-07-16T09:00:00Z"))
        let removed = kept.remappingRepositoryID(to: "removed-repository")

        let pruned = store.pruning(
            [kept, removed],
            keepingRepositoryIDs: [kept.repositoryID]
        )

        #expect(pruned.map(\.repositoryID) == [kept.repositoryID])
        #expect(pruned.map(\.id) == [kept.id])
    }

    @Test func linkedWorktreesProduceIsolatedEvents() {
        let worktreeA = snapshot(
            modified: 0, id: "worktree-A", path: "/tmp/worktree-A"
        )
        let worktreeB = snapshot(
            modified: 0, id: "worktree-B", path: "/tmp/worktree-B"
        )
        let previous = data([worktreeA, worktreeB], generatedAt: "2026-07-20T08:00:00Z")

        let changedA = snapshot(
            modified: 3, untracked: 1,
            id: "worktree-A", path: "/tmp/worktree-A"
        )
        let current = data([changedA, worktreeB], generatedAt: "2026-07-20T09:00:00Z")

        let events = ActivityEventDiffer.events(
            previous: previous,
            current: current,
            observedAt: current.generatedAt
        )

        #expect(events.map(\.repositoryID) == ["worktree-A"])
        #expect(events.count == 1)
        #expect(events.first?.kind == ActivityEventKind.workingTreeChanged)
    }

    @Test func bothWorktreesChangedProduceSeparateEvents() {
        let prevA = snapshot(
            modified: 0, id: "wt-A", path: "/tmp/wt-A"
        )
        let prevB = snapshot(
            modified: 1, id: "wt-B", path: "/tmp/wt-B"
        )
        let previous = data([prevA, prevB], generatedAt: "2026-07-20T08:00:00Z")

        let currA = snapshot(
            modified: 3, id: "wt-A", path: "/tmp/wt-A"
        )
        let currB = snapshot(
            modified: 0, id: "wt-B", path: "/tmp/wt-B"
        )
        let current = data([currA, currB], generatedAt: "2026-07-20T09:00:00Z")

        let events = ActivityEventDiffer.events(
            previous: previous,
            current: current,
            observedAt: current.generatedAt
        )

        let idsByKind: [String: [ActivityEventKind]] = Dictionary(
            grouping: events,
            by: \.repositoryID
        ).mapValues { $0.map(\.kind) }

        #expect(idsByKind["wt-A"] == [ActivityEventKind.workingTreeChanged])
        #expect(idsByKind["wt-B"] == [ActivityEventKind.workingTreeChanged])
    }

    @Test func eventStoreSaveLoadThenDedupPreventsReplay() throws {
        let url = temporaryURL()
        let store = ActivityEventStore(fileURL: url)

        let e1 = try #require(makeWorkingTreeEvent(
            from: 0, to: 1, at: "2026-07-20T09:00:00Z"
        ))
        #expect(try store.save([e1]).get() == [e1])

        let loaded = try store.load().get()
        #expect(loaded.events == [e1])

        let replay = try #require(makeWorkingTreeEvent(
            from: 0, to: 1, at: "2026-07-20T10:00:00Z"
        ))
        #expect(ActivityEventDeduplicator.newEvents(
            from: [replay],
            comparedTo: loaded.events
        ).isEmpty)

        let diff = try #require(makeWorkingTreeEvent(
            from: 1, to: 2, at: "2026-07-20T11:00:00Z"
        ))
        #expect(ActivityEventDeduplicator.newEvents(
            from: [diff],
            comparedTo: loaded.events
        ) == [diff])
    }

    @Test func unchangedStateAfterWakeOrRestartProducesNoEvents() {
        let snap = snapshot(modified: 2, staged: 1, unstaged: 1)
        let previous = data([snap], generatedAt: "2026-07-20T08:00:00Z")
        let current = data([snap], generatedAt: "2026-07-20T10:00:00Z")

        #expect(ActivityEventDiffer.events(
            previous: previous,
            current: current,
            observedAt: current.generatedAt
        ).isEmpty)
    }

    @Test func oldSharedSnapshotWithoutEventOrCommitFieldsStillDecodes() throws {
        let payload = data([
            snapshot(lastCommitID: "commit-id", lastCommitSummary: "Subject")
        ])
        let encoded = try JSONEncoder().encode(payload)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "recentActivityEvents")
        var repositories = try #require(object["repositories"] as? [[String: Any]])
        repositories[0].removeValue(forKey: "lastCommitID")
        object["repositories"] = repositories

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppGroupData.self, from: legacyData)
        #expect(decoded.recentActivityEvents == nil)
        #expect(decoded.repositories.first?.lastCommitID == nil)
        #expect(decoded.repositories.first?.lastCommitSummary == "Subject")
    }

    @Test func identicalActivityEventsAreDeduplicated() {
        // Pair 1: state change 0→2 produces one event
        let base = snapshot(modified: 0)
        let changed = snapshot(modified: 2)
        let events1 = ActivityEventDiffer.events(
            previous: data([base], generatedAt: "2026-07-20T08:00:00Z"),
            current: data([changed], generatedAt: "2026-07-20T09:00:00Z"),
            observedAt: "2026-07-20T09:00:00Z"
        )
        #expect(events1.count == 1)

        // Pair 2: identical state produces no differ events
        let events2 = ActivityEventDiffer.events(
            previous: data([changed], generatedAt: "2026-07-20T09:00:00Z"),
            current: data([changed], generatedAt: "2026-07-20T10:00:00Z"),
            observedAt: "2026-07-20T10:00:00Z"
        )
        #expect(events2.isEmpty)

        // Deduplicator: same event filtered when already in history
        #expect(ActivityEventDeduplicator.newEvents(from: events1, comparedTo: events1).isEmpty)

        // Change one value → event appears once
        let further = snapshot(modified: 3)
        let events3 = ActivityEventDiffer.events(
            previous: data([changed], generatedAt: "2026-07-20T09:00:00Z"),
            current: data([further], generatedAt: "2026-07-20T11:00:00Z"),
            observedAt: "2026-07-20T11:00:00Z"
        )
        #expect(events3.count == 1)
        #expect(ActivityEventDeduplicator.newEvents(from: events3, comparedTo: events1) == events3)
    }

    private func makeWorkingTreeEvent(
        from oldCount: Int,
        to newCount: Int,
        at: String
    ) -> ActivityEvent? {
        event(
            previous: snapshot(modified: oldCount),
            current: snapshot(modified: newCount),
            at: at,
            kind: .workingTreeChanged
        )
    }

    private func event(
        previous: RepositorySnapshot,
        current: RepositorySnapshot,
        at: String,
        kind: ActivityEventKind
    ) -> ActivityEvent? {
        ActivityEventDiffer.events(
            previous: previous,
            current: current,
            observedAt: at
        ).first { $0.kind == kind }
    }

    private func data(
        _ repositories: [RepositorySnapshot],
        generatedAt: String = "2026-07-16T08:00:00Z"
    ) -> AppGroupData {
        AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: generatedAt,
            writtenAt: nil,
            scanSummary: ScanSummary.build(from: repositories),
            repositories: repositories
        )
    }

    private func snapshot(
        branch: String = "main",
        modified: Int = 0,
        added: Int = 0,
        deleted: Int = 0,
        untracked: Int = 0,
        staged: Int? = 0,
        unstaged: Int? = 0,
        conflicted: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        dataSource: RepositoryDataSource = .current,
        lastCommitID: String? = "base",
        lastCommitSummary: String? = "Base",
        id: String = "repo-id",
        path: String = "/tmp/Repo"
    ) -> RepositorySnapshot {
        let changed = modified + added + deleted + untracked
        return RepositorySnapshot(
            id: id,
            name: "Repo",
            path: path,
            branch: branch,
            status: dataSource == .current ? (changed > 0 ? .changed : .clean) : .error,
            modifiedFileCount: modified,
            addedFileCount: added,
            deletedFileCount: deleted,
            untrackedFileCount: untracked,
            stagedFileCount: staged,
            unstagedFileCount: unstaged,
            conflictedFileCount: conflicted,
            aheadCount: ahead,
            behindCount: behind,
            hasUpstream: true,
            changedFileCount: changed,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: "2026-07-16T08:00:00Z",
            dataSource: dataSource,
            lastSuccessfulScanAt: dataSource == .current ? "2026-07-16T08:00:00Z" : nil,
            lastChangedAt: "2026-07-16T07:00:00Z",
            lastCommitID: lastCommitID,
            lastCommitSummary: lastCommitSummary,
            lastCommitMetadataAvailable: true,
            lastActivityAt: nil,
            errorMessage: dataSource == .current ? nil : "读取失败",
            isPinned: false
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-events-\(UUID().uuidString).json")
    }
}

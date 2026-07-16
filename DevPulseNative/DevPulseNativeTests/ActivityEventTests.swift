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
        lastCommitSummary: String? = "Base"
    ) -> RepositorySnapshot {
        let changed = modified + added + deleted + untracked
        return RepositorySnapshot(
            id: "repo-id",
            name: "Repo",
            path: "/tmp/Repo",
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

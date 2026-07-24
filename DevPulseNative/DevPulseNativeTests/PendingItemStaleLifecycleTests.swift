import Foundation
import Testing
@testable import DevPulse

// MARK: - Stale repository lifecycle tests

@Suite("Stale Repository Lifecycle")
struct PendingItemStaleLifecycleTests {

    // MARK: - PendingItemSource

    @Test func staleRepositorySourceHasCorrectIdentity() throws {
        let source = PendingItemSource.staleRepository
        #expect(source.displayName == "陈旧仓库")
        #expect(source.systemImage == "trash.slash")
        #expect(source.rawValue == "staleRepository")
    }

    // MARK: - PendingItemUserAction

    @Test func cleanupActionHasCorrectIdentity() throws {
        let action = PendingItemUserAction.cleanupStaleRepository
        #expect(action.displayName == "清理并移除跟踪")
        #expect(action.rawValue == "cleanupStaleRepository")
    }

    // MARK: - evaluator: unavailable for < 7 days

    @Test func evaluateUnavailableReturnsItemForShortTermUnavailability() throws {
        let now = DateFormatting.date(from: "2026-07-24T12:00:00Z")!
        let repo = RepositorySnapshot(
            id: "repo-test", name: "test-repo", path: "/tmp/test-repo",
            workspaceKind: nil, branch: "unknown", status: .error,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: nil, unstagedFileCount: nil,
            conflictedFileCount: nil, aheadCount: nil, behindCount: nil,
            hasUpstream: nil, changedFileCount: 0, changedFilesPreview: [],
            risk: .low,
            lastScannedAt: "2026-07-24T12:00:00Z",
            dataSource: .lastSuccessful, lastSuccessfulScanAt: "2026-07-20T12:00:00Z",
            lastChangedAt: nil, lastCommitID: nil, lastCommitSummary: nil,
            lastCommitMetadataAvailable: false, lastActivityAt: nil,
            unavailableSince: "2026-07-24T10:00:00Z",
            errorMessage: "读取超时", isPinned: false
        )

        let context = PendingItemEvaluationContext(
            repositories: [repo],
            previousItems: [],
            now: now
        )

        let result = PendingItemEvaluator.evaluate(context: context)
        let unavailableItems = result.items.filter { $0.source == .unavailable }

        // Should have an unavailable item (duration is only 2h)
        #expect(!unavailableItems.isEmpty)
        #expect(unavailableItems.count == 1)
        #expect(unavailableItems[0].severity == .medium)
        #expect(unavailableItems[0].title == "仓库无法访问")

        // Should NOT have a stale repository item yet
        let staleItems = result.items.filter { $0.source == .staleRepository }
        #expect(staleItems.isEmpty)
    }

    @Test func evaluateUnavailableReturnsHighAfterOneDay() throws {
        let now = DateFormatting.date(from: "2026-07-25T12:00:00Z")!
        let repo = RepositorySnapshot(
            id: "repo-test", name: "test-repo", path: "/tmp/test-repo",
            workspaceKind: nil, branch: "unknown", status: .error,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: nil, unstagedFileCount: nil,
            conflictedFileCount: nil, aheadCount: nil, behindCount: nil,
            hasUpstream: nil, changedFileCount: 0, changedFilesPreview: [],
            risk: .low,
            lastScannedAt: "2026-07-24T12:00:00Z",
            dataSource: .lastSuccessful, lastSuccessfulScanAt: "2026-07-20T12:00:00Z",
            lastChangedAt: nil, lastCommitID: nil, lastCommitSummary: nil,
            lastCommitMetadataAvailable: false, lastActivityAt: nil,
            unavailableSince: "2026-07-24T12:00:00Z",
            errorMessage: "读取超时", isPinned: false
        )

        let context = PendingItemEvaluationContext(
            repositories: [repo],
            previousItems: [],
            now: now
        )

        let result = PendingItemEvaluator.evaluate(context: context)
        let unavailableItems = result.items.filter { $0.source == .unavailable }

        // 24h → high severity
        #expect(!unavailableItems.isEmpty)
        #expect(unavailableItems[0].severity == .high)
    }

    // MARK: - evaluator: unavailable transforms to staleRepository at 7+ days

    @Test func evaluateUnavailableReturnsNilAtSevenDays_staleRepositoryTakesOver() throws {
        let unavailableSince = "2026-07-01T12:00:00Z"
        let now = DateFormatting.date(from: "2026-07-24T12:00:00Z")! // 23 days later

        // Create a repo unavailableSince 23 days ago
        let repo = RepositorySnapshot(
            id: "repo-stale", name: "stale-repo", path: "/tmp/stale-repo",
            workspaceKind: nil, branch: "unknown", status: .error,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: nil, unstagedFileCount: nil,
            conflictedFileCount: nil, aheadCount: nil, behindCount: nil,
            hasUpstream: nil, changedFileCount: 0, changedFilesPreview: [],
            risk: .low,
            lastScannedAt: "2026-07-24T12:00:00Z",
            dataSource: .lastSuccessful, lastSuccessfulScanAt: "2026-06-30T12:00:00Z",
            lastChangedAt: nil, lastCommitID: nil, lastCommitSummary: nil,
            lastCommitMetadataAvailable: false, lastActivityAt: nil,
            unavailableSince: unavailableSince,
            errorMessage: "已长期无法访问", isPinned: false
        )

        let context = PendingItemEvaluationContext(
            repositories: [repo],
            previousItems: [],
            now: now
        )

        let result = PendingItemEvaluator.evaluate(context: context)

        // Should have a stale repository item
        let staleItems = result.items.filter { $0.source == .staleRepository }
        #expect(!staleItems.isEmpty, "Expected staleRepository item for repo unavailable >7 days")
        #expect(staleItems[0].severity == .critical)
        #expect(staleItems[0].title == "仓库已长期无法访问")
        #expect(staleItems[0].repositoryID == "repo-stale")

        // Should NOT have an unavailable item
        let unavailableItems = result.items.filter { $0.source == .unavailable }
        #expect(unavailableItems.isEmpty, "evaluateUnavailable should return nil when duration >= retention threshold")
    }

    @Test func staleRepositoryItemTransitionsFromPreviousUnavailableItem() throws {
        let unavailableSince = "2026-07-01T12:00:00Z"
        let now = DateFormatting.date(from: "2026-07-24T12:00:00Z")!
        let repoID = "repo-stale"

        let repo = RepositorySnapshot(
            id: repoID, name: "stale-repo", path: "/tmp/stale-repo",
            workspaceKind: nil, branch: "unknown", status: .error,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: nil, unstagedFileCount: nil,
            conflictedFileCount: nil, aheadCount: nil, behindCount: nil,
            hasUpstream: nil, changedFileCount: 0, changedFilesPreview: [],
            risk: .low,
            lastScannedAt: "2026-07-24T12:00:00Z",
            dataSource: .lastSuccessful, lastSuccessfulScanAt: "2026-06-30T12:00:00Z",
            lastChangedAt: nil, lastCommitID: nil, lastCommitSummary: nil,
            lastCommitMetadataAvailable: false, lastActivityAt: nil,
            unavailableSince: unavailableSince,
            errorMessage: "已长期无法访问", isPinned: false
        )

        // Previous .unavailable item with active status
        let previousItem = PendingItem(
            source: .unavailable,
            severity: .critical,
            repositoryID: repoID,
            repositoryName: "stale-repo",
            title: "仓库无法访问",
            explanation: "仓库 stale-repo 从 7月1日 起不可访问，持续 22d 23h。",
            evidence: ["错误信息：已长期无法访问"],
            firstDetectedAt: "2026-07-01T12:00:00Z",
            lastConfirmedAt: "2026-07-22T12:00:00Z",
            status: .active,
            duration: 23 * 24 * 3600
        )

        let context = PendingItemEvaluationContext(
            repositories: [repo],
            previousItems: [previousItem],
            now: now
        )

        let result = PendingItemEvaluator.evaluate(context: context)
        let staleItems = result.items.filter { $0.source == .staleRepository }
        #expect(!staleItems.isEmpty)

        // The stale item should preserve firstDetectedAt from previous
        #expect(staleItems[0].firstDetectedAt == "2026-07-01T12:00:00Z")

        // The old .unavailable item should NOT be present
        let unavailableItems = result.items.filter { $0.source == .unavailable }
        #expect(unavailableItems.isEmpty)

        // There should be a transition from the old .unavailable item
        let unavailableTransitions = result.transitions.filter { $0.from == .active }
        // The transitioned item (old unavailable) moves to resolved
        #expect(result.resolvedItemCount >= 1)
    }

    // MARK: - RepositoryRetentionPolicy

    @Test func previouslyKnownRepoRetainedIndefinitely() throws {
        let unavailableAt = try #require(DateFormatting.date(from: "2026-06-01T00:00:00Z"))
        let retained = RepositorySnapshot(
            id: "repo-known", name: "known", path: "/tmp/known",
            workspaceKind: nil, branch: "main", status: .error,
            modifiedFileCount: 5, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: nil, unstagedFileCount: nil,
            conflictedFileCount: nil, aheadCount: nil, behindCount: nil,
            hasUpstream: nil, changedFileCount: 5, changedFilesPreview: [],
            risk: .low,
            lastScannedAt: "2026-07-24T12:00:00Z",
            dataSource: .lastSuccessful, lastSuccessfulScanAt: "2026-06-01T00:00:00Z",
            lastChangedAt: "2026-06-01T00:00:00Z", lastCommitID: "abc123",
            lastCommitSummary: "feat: work", lastCommitMetadataAvailable: false,
            lastActivityAt: "2026-06-01T00:00:00Z",
            unavailableSince: "2026-06-01T00:00:00Z",
            errorMessage: "无法访问", isPinned: false
        )

        // Should retain even 60 days later (previously known)
        #expect(RepositoryRetentionPolicy.shouldRetain(
            retained,
            now: unavailableAt.addingTimeInterval(60 * 24 * 60 * 60)
        ))
    }

    @Test func unknownRepoDroppedAfterGraceWindow() throws {
        let unavailableAt = try #require(DateFormatting.date(from: "2026-07-01T00:00:00Z"))
        let unknown = RepositorySnapshot(
            id: "repo-unknown", name: "unknown", path: "/tmp/unknown",
            workspaceKind: nil, branch: "unknown", status: .error,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: nil, unstagedFileCount: nil,
            conflictedFileCount: nil, aheadCount: nil, behindCount: nil,
            hasUpstream: nil, changedFileCount: 0, changedFilesPreview: [],
            risk: .low,
            lastScannedAt: DateFormatting.isoString(from: unavailableAt),
            dataSource: .unknown, lastSuccessfulScanAt: nil,
            lastChangedAt: nil, lastCommitID: nil, lastCommitSummary: nil,
            lastCommitMetadataAvailable: false, lastActivityAt: nil,
            unavailableSince: DateFormatting.isoString(from: unavailableAt),
            errorMessage: "无法访问", isPinned: false
        )

        #expect(RepositoryRetentionPolicy.shouldRetain(
            unknown,
            now: unavailableAt.addingTimeInterval(60 * 60)  // within grace window
        ))
        #expect(!RepositoryRetentionPolicy.shouldRetain(
            unknown,
            now: unavailableAt.addingTimeInterval(8 * 24 * 60 * 60)  // past grace window
        ))
    }

    // MARK: - PendingItemStore cleanup action

    @Test func cleanupStaleRepositoryActionMarksItemResolved() throws {
        let store = PendingItemStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("test-cleanup-\(UUID().uuidString).json"))

        // Create a stale repository item
        let staleItem = PendingItem(
            source: .staleRepository,
            severity: .critical,
            repositoryID: "repo-stale",
            repositoryName: "stale-repo",
            title: "仓库已长期无法访问",
            explanation: "仓库 stale-repo 已无法访问超过 7 天。",
            evidence: [],
            status: .active
        )

        // Save the item
        let saveResult = store.save(PendingItemArchive(items: [staleItem]))
        guard case .success(let archive) = saveResult else {
            Issue.record("Failed to save pending items: \(saveResult)")
            return
        }
        let itemID = try #require(archive.items.first?.id)

        // Apply cleanup action
        let result = store.applyUserAction(itemID: itemID, action: .cleanupStaleRepository)
        guard case .success(let updated) = result else {
            Issue.record("Failed to apply cleanup action: \(result)")
            return
        }

        let cleanedItem = try #require(updated.items.first)
        #expect(cleanedItem.status == .resolved)
        #expect(cleanedItem.explanation.contains("已清理"))
    }

    @Test func cleanupStaleRepositoryActionPreservesOtherItems() throws {
        let store = PendingItemStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("test-cleanup-preserve-\(UUID().uuidString).json"))

        let staleItem = PendingItem(
            source: .staleRepository,
            severity: .critical,
            repositoryID: "repo-stale",
            title: "仓库已长期无法访问"
        )
        let dirtyItem = PendingItem(
            source: .dirtyWorkspace,
            severity: .low,
            repositoryID: "repo-dirty",
            title: "工作区存在长期改动"
        )

        let saveResult = store.save(PendingItemArchive(items: [staleItem, dirtyItem]))
        guard case .success(let archive) = saveResult else {
            Issue.record("Failed to save: \(saveResult)")
            return
        }
        let staleID = try #require(archive.items.first { $0.source == .staleRepository })?.id

        let result = store.applyUserAction(itemID: staleID, action: .cleanupStaleRepository)
        guard case .success(let updated) = result else {
            Issue.record("Failed to apply: \(result)")
            return
        }

        let stale = try #require(updated.items.first { $0.source == .staleRepository })
        #expect(stale.status == .resolved)

        let dirty = try #require(updated.items.first { $0.source == .dirtyWorkspace })
        #expect(dirty.status == .active)  // unchanged
    }

    // MARK: - Mutual exclusion: unavailable vs staleRepository

    @Test func unavailableAndStaleRepositoryAreMutuallyExclusive() throws {
        let now = DateFormatting.date(from: "2026-07-24T12:00:00Z")!

        // A repo that's been unavailable for 3 days — should get .unavailable
        let shortTerm = RepositorySnapshot(
            id: "repo-short", name: "short", path: "/tmp/short",
            workspaceKind: nil, branch: "unknown", status: .error,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: nil, unstagedFileCount: nil,
            conflictedFileCount: nil, aheadCount: nil, behindCount: nil,
            hasUpstream: nil, changedFileCount: 0, changedFilesPreview: [],
            risk: .low,
            lastScannedAt: "2026-07-24T12:00:00Z",
            dataSource: .lastSuccessful, lastSuccessfulScanAt: "2026-07-10T12:00:00Z",
            lastChangedAt: nil, lastCommitID: nil, lastCommitSummary: nil,
            lastCommitMetadataAvailable: false, lastActivityAt: nil,
            unavailableSince: "2026-07-21T12:00:00Z",
            errorMessage: "读取超时", isPinned: false
        )

        // A repo that's been unavailable for 30 days — should get .staleRepository
        let longTerm = RepositorySnapshot(
            id: "repo-long", name: "long", path: "/tmp/long",
            workspaceKind: nil, branch: "unknown", status: .error,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: nil, unstagedFileCount: nil,
            conflictedFileCount: nil, aheadCount: nil, behindCount: nil,
            hasUpstream: nil, changedFileCount: 0, changedFilesPreview: [],
            risk: .low,
            lastScannedAt: "2026-07-24T12:00:00Z",
            dataSource: .lastSuccessful, lastSuccessfulScanAt: "2026-06-10T12:00:00Z",
            lastChangedAt: nil, lastCommitID: nil, lastCommitSummary: nil,
            lastCommitMetadataAvailable: false, lastActivityAt: nil,
            unavailableSince: "2026-06-24T12:00:00Z",
            errorMessage: "已长期无法访问", isPinned: false
        )

        let context = PendingItemEvaluationContext(
            repositories: [shortTerm, longTerm],
            previousItems: [],
            now: now
        )

        let result = PendingItemEvaluator.evaluate(context: context)

        let unavailableItems = result.items.filter { $0.source == .unavailable }
        let staleItems = result.items.filter { $0.source == .staleRepository }

        #expect(unavailableItems.count == 1)
        #expect(unavailableItems[0].repositoryID == "repo-short")

        #expect(staleItems.count == 1)
        #expect(staleItems[0].repositoryID == "repo-long")

        // Verify exact mutual exclusion
        let allUnavailableRepoIDs = Set(unavailableItems.map(\.repositoryID!))
        let allStaleRepoIDs = Set(staleItems.map(\.repositoryID!))
        #expect(allUnavailableRepoIDs.intersection(allStaleRepoIDs).isEmpty)
    }

    // MARK: - Widget summary includes stale items

    @Test func widgetSummaryIncludesStaleRepositoryItems() throws {
        let staleItem = PendingItem(
            source: .staleRepository,
            severity: .critical,
            repositoryID: "repo-stale",
            title: "仓库已长期无法访问",
            status: .active
        )
        let dirtyItem = PendingItem(
            source: .dirtyWorkspace,
            severity: .low,
            repositoryID: "repo-dirty",
            title: "工作区存在长期改动",
            status: .active
        )

        let summary = PendingItemWidgetSummary.build(from: [staleItem, dirtyItem])
        #expect(summary.totalCount == 2)
        #expect(summary.criticalCount == 1)
        #expect(summary.topItemTitle == "仓库已长期无法访问")
        #expect(summary.topItemSeverity == .critical)
    }
}

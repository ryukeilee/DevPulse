import Foundation
import Testing
@testable import DevPulse

// MARK: - Stale repository lifecycle tests

@Suite("Stale Repository Lifecycle")
struct PendingItemStaleLifecycleTests {

    @Test func evaluatorCreatesImmediateFinishingItemsFromCurrentGitState() throws {
        let dirty = repositorySnapshot(
            id: "repo-dirty",
            name: "dirty-repo",
            status: .changed,
            changedFileCount: 3
        )
        let unpushed = repositorySnapshot(
            id: "repo-unpushed",
            name: "unpushed-repo",
            status: .clean,
            aheadCount: 2,
            hasUpstream: true
        )

        let result = PendingItemEvaluator.evaluate(
            context: PendingItemEvaluationContext(repositories: [dirty, unpushed])
        )

        let dirtyItem = try #require(result.items.first { $0.source == .dirtyWorkspace })
        #expect(dirtyItem.repositoryID == dirty.id)
        #expect(dirtyItem.evidence.contains("当前改动文件数：3"))
        #expect(dirtyItem.explanation == "仓库 dirty-repo 有 3 个文件尚未提交。")

        let unpushedItem = try #require(result.items.first { $0.source == .unpushedCommits })
        #expect(unpushedItem.repositoryID == unpushed.id)
        #expect(unpushedItem.evidence.contains("未推送提交数：2"))
        #expect(unpushedItem.explanation == "仓库 unpushed-repo 有 2 个本地提交未推送到远端。")
    }

    @Test func evaluatorIncludesUnfinishedConflictState() throws {
        let conflicted = repositorySnapshot(
            id: "repo-conflict",
            name: "conflicted-repo",
            status: .changed,
            changedFileCount: 2,
            conflictedFileCount: 1
        )

        let result = PendingItemEvaluator.evaluate(
            context: PendingItemEvaluationContext(repositories: [conflicted])
        )

        let item = try #require(result.items.first { $0.source == .mergeConflict })
        #expect(item.repositoryID == conflicted.id)
        #expect(item.severity == .high)
    }

    @Test(arguments: [PendingItemStatus.active, .acknowledged, .restored,
                      .snoozed, .muted, .resolved, .permanentlyIgnored])
    func crossRuleResolutionPreservesStatusEligibility(status: PendingItemStatus) throws {
        let repo = repositorySnapshot(id: "target", name: "target", status: .changed, changedFileCount: 1)
        let previous = PendingItem(id: "historical", source: .unpushedCommits, severity: .high,
                                   repositoryID: repo.id, title: "old", firstDetectedAt: "2026-01-01T00:00:00Z",
                                   status: status)
        let unrelated = PendingItem(id: "unrelated", source: .mergeConflict, severity: .high,
                                    repositoryID: "other", title: "other", firstDetectedAt: "2025-01-01T00:00:00Z")
        let sameSource = PendingItem(id: "same-source", source: .dirtyWorkspace, severity: .low,
                                     repositoryID: repo.id, title: "same", firstDetectedAt: "2024-01-01T00:00:00Z")
        let result = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [repo], previousItems: [previous, unrelated, sameSource]))
        let item = try #require(result.items.first { $0.source == .dirtyWorkspace })
        let eligible = status == .active || status == .acknowledged || status == .restored
        #expect(result.resolvedItemCount == (eligible ? 1 : 0))
        #expect((item.firstDetectedAt == previous.firstDetectedAt) == eligible)
        #expect(result.notifications.count == 1)
        // Notifications retain the rule-produced item, before cross-rule timestamp carry-forward.
        #expect(result.notifications[0].item.firstDetectedAt != previous.firstDetectedAt)
    }

    @Test func crossRuleHistoryUsesArchiveAndPreservesTraversalOrder() throws {
        let repo = repositorySnapshot(id: "target", name: "target", status: .changed, changedFileCount: 1)
        let history = [PendingItemSource.unpushedCommits, .behindRemote, .mergeConflict].enumerated().map {
            PendingItem(id: "history-\($0.offset)", source: $0.element, severity: .high,
                        repositoryID: repo.id, title: "old", firstDetectedAt: "2026-01-0\($0.offset + 1)T00:00:00Z")
        }
        let result = PendingItemEvaluator.evaluate(
            context: PendingItemEvaluationContext(repositories: [repo], previousItems: [
                PendingItem(source: .unavailable, severity: .high, repositoryID: repo.id, title: "ignored")
            ]), previousArchive: PendingItemArchive(items: history))
        let crossRule = result.transitions.filter { $0.reason.hasPrefix("仓库状态从 ") }
        #expect(crossRule.count == history.count)
        #expect(result.resolvedItemCount == history.count)
        let last = try #require(crossRule.last)
        let previous = try #require(history.first { last.reason.contains($0.source.displayName) })
        #expect(result.items[0].firstDetectedAt == previous.firstDetectedAt)
    }

    @Test func workspaceCrossRuleMatchingRetainsNilRepositorySemantics() throws {
        let repo = repositorySnapshot(id: "conflict", name: "conflict", status: .changed,
                                      changedFileCount: 1, conflictedFileCount: 1)
        let workspace = Workspace(id: "current", name: "current", repositoryIDs: [repo.id])
        let aggregations = WorkspaceAggregationEngine.aggregateAll(workspaces: [workspace], allRepositories: [repo])
        let previous = PendingItem(id: "old-workspace", source: .workspaceDegraded, severity: .medium,
                                   workspaceID: "other-workspace", title: "old", firstDetectedAt: "2026-01-01T00:00:00Z")
        let result = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [], workspaceAggregations: aggregations, workspaces: [workspace], previousItems: [previous]))
        let conflict = try #require(result.items.first { $0.source == .workspaceConflicts })
        #expect(conflict.firstDetectedAt == previous.firstDetectedAt)
        #expect(result.resolvedItemCount == 1)
        #expect(result.items.first { $0.source == .workspaceDegraded }?.firstDetectedAt != previous.firstDetectedAt)
    }

    @Test func duplicateRepositoryIDsKeepFirstCandidateAndEveryNotification() throws {
        let first = repositorySnapshot(id: "duplicate", name: "first", status: .changed, changedFileCount: 1)
        let second = repositorySnapshot(id: "duplicate", name: "second", status: .changed, changedFileCount: 9)
        let other = repositorySnapshot(id: "other", name: "other", status: .changed, changedFileCount: 2)
        let result = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [first, other, second, first]))

        #expect(result.items.count == 2)
        let kept = try #require(result.items.first { $0.repositoryID == first.id })
        #expect(kept.repositoryName == "first")
        #expect(kept.evidence == ["当前改动文件数：1"])
        #expect(result.newItemCount == 4)
        #expect(result.transitions.count == 4)
        #expect(result.notifications.map { $0.item.repositoryName } == ["first", "other", "second", "first"])
        #expect(result.notifications[2].item.evidence == ["当前改动文件数：9"])
    }

    @Test(arguments: [PendingItemStatus.active, .acknowledged, .restored,
                      .snoozed, .muted, .resolved, .permanentlyIgnored])
    func duplicateRepositoryIDsPreserveArchiveLifecycle(status: PendingItemStatus) throws {
        let first = repositorySnapshot(id: "duplicate", name: "first", status: .changed, changedFileCount: 1)
        let second = repositorySnapshot(id: "duplicate", name: "second", status: .changed, changedFileCount: 9)
        let original = try #require(PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [first])).items.first)
        let previous = PendingItem(id: original.id, source: original.source, severity: original.severity,
                                   repositoryID: first.id, title: original.title, explanation: original.explanation,
                                   evidence: original.evidence, firstDetectedAt: "2025-01-01T00:00:00Z",
                                   lastConfirmedAt: "2026-01-01T00:00:00Z", status: status,
                                   snoozedUntil: "2099-01-01T00:00:00Z")
        let context = PendingItemEvaluationContext(repositories: [first, second], now: Date(timeIntervalSince1970: 1_770_000_000))
        let result = PendingItemEvaluator.evaluate(context: context, previousArchive: PendingItemArchive(items: [previous]))

        #expect(result.items.count == 1)
        #expect(result.items[0].repositoryName == "first")
        #expect(result.items[0].firstDetectedAt == previous.firstDetectedAt)
        #expect(result.items[0].snoozedUntil == (status == .snoozed ? previous.snoozedUntil : nil))
        let expected = PendingItemStatusTransition.evaluate(current: previous, conditionStillActive: true,
                                                            conditionChanged: false, newSeverity: original.severity,
                                                            now: context.now)
        #expect(result.items[0].status == expected.to)
        #expect(result.newItemCount == 0)
        #expect(result.transitions.count == 2)
        #expect(result.notifications.count == (expected.to.allowsNotification && expected.from != expected.to ? 2 : 0))
    }

    @Test func duplicateOccurrencesResolveTheAbsentSourceOnce() throws {
        let clean = repositorySnapshot(id: "duplicate", name: "clean", status: .clean)
        let dirty = repositorySnapshot(id: "duplicate", name: "dirty", status: .changed, changedFileCount: 1)
        // A stored item resolves by rule scope, not by a title-derived id, so an
        // empty title is no longer significant; duplicate repository occurrences
        // must not archive the same recovery twice (which would trap the next
        // evaluation's id dictionary).
        let previous = PendingItem(source: .dirtyWorkspace, severity: .low, repositoryID: clean.id,
                                   title: "", evidence: ["old"], firstDetectedAt: "2025-01-01T00:00:00Z")
        let result = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean, dirty, clean, dirty], previousItems: [previous]))
        let resolved = result.items.filter { $0.id == previous.id }
        #expect(resolved.count == 1)
        #expect(resolved.allSatisfy { $0.status == .resolved && $0.firstDetectedAt == previous.firstDetectedAt })
        #expect(result.items.filter { $0.id != previous.id }.count == 1)
        #expect(result.resolvedItemCount == 1)
        #expect(result.newItemCount == 2)
        #expect(result.transitions.count == 3)
        #expect(result.notifications.count == 2)
    }

    @Test func ruleDispatchPreservesHealthRuleAndNotificationOrder() throws {
        let repo = repositorySnapshot(id: "all-rules", name: "all-rules", status: .changed,
                                      changedFileCount: 2, aheadCount: 2, hasUpstream: false, conflictedFileCount: 1)
        let kinds: [RepositoryHealthSignal.SignalKind] = [.dirtyWorkspaceDuration, .unpushedCommitsDuration,
            .behindRemoteDuration, .staleActivity, .recurringConflicts, .frequentReadFailures, .creepingChanges]
        let health = RepositoryHealthAssessment(repositoryID: repo.id, repositoryName: repo.name,
            assessedAt: "2026-01-01T00:00:00Z", overallRisk: .high, signals: kinds.map {
                RepositoryHealthSignal(kind: $0, level: .high, title: $0.rawValue, explanation: "signal",
                                       evidence: "evidence", duration: 300000, currentValue: "5", threshold: nil)
            }, summary: "summary", primaryExplanation: "health", hasSufficientHistory: true)
        let workspace = Workspace(id: "all", name: "all", repositoryIDs: [repo.id])
        let aggregations = WorkspaceAggregationEngine.aggregateAll(workspaces: [workspace], allRepositories: [repo])
        let result = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [repo],
            workspaceAggregations: aggregations, workspaces: [workspace], healthAssessments: [repo.id: health]))
        let expected: [PendingItemSource] = [.dirtyWorkspace, .unpushedCommits, .behindRemote, .mergeConflict,
            .upstreamMissing, .scanFailure, .creepingChanges, .staleActivity, .healthTrend,
            .workspaceDegraded, .workspaceConflicts]
        #expect(result.notifications.map { $0.item.source } == expected)
        #expect(result.transitions.count == expected.count)
        #expect(result.newItemCount == expected.count)
        #expect(result.resolvedItemCount == 0)
        #expect(result.escalatedCount == 0)
        #expect(result.deescalatedCount == 0)
        #expect(result.items.map(\.severity) == result.items.map(\.severity).sorted(by: >))
    }

    @Test(arguments: [PendingItemStatus.active, .acknowledged, .restored,
                      .snoozed, .muted, .resolved, .permanentlyIgnored])
    func duplicateWorkspacesPreserveEveryAppendAndLifecycle(status: PendingItemStatus) throws {
        let repo = repositorySnapshot(id: "conflict", name: "conflict", status: .changed,
                                      changedFileCount: 1, conflictedFileCount: 1)
        let workspace = Workspace(id: "duplicate", name: "duplicate", repositoryIDs: [repo.id])
        let aggregations = WorkspaceAggregationEngine.aggregateAll(workspaces: [workspace], allRepositories: [repo])
        let seed = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [],
            workspaceAggregations: aggregations, workspaces: [workspace]))
        let previous = try #require(seed.items.first { $0.source == .workspaceConflicts })
        var historical = previous
        historical.status = status
        historical.snoozedUntil = "2099-01-01T00:00:00Z"
        let context = PendingItemEvaluationContext(repositories: [], workspaceAggregations: aggregations,
            workspaces: [workspace, workspace], previousItems: [historical])
        let result = PendingItemEvaluator.evaluate(context: context)
        let conflicts = result.items.filter { $0.source == .workspaceConflicts }
        let expected = PendingItemStatusTransition.evaluate(current: historical, conditionStillActive: true,
            conditionChanged: false, newSeverity: historical.severity, now: context.now)
        #expect(conflicts.count == 2)
        #expect(conflicts.allSatisfy { $0.status == expected.to && $0.firstDetectedAt == historical.firstDetectedAt })
        #expect(conflicts.allSatisfy { $0.snoozedUntil == (expected.to == .snoozed ? historical.snoozedUntil : nil) })
        #expect(result.notifications.filter { $0.item.source == .workspaceConflicts }.count
                == (expected.to.allowsNotification && expected.from != expected.to ? 2 : 0))
    }

    // MARK: - PendingItemSource

    @Test func staleRepositorySourceHasCorrectIdentity() throws {
        let source = PendingItemSource.staleRepository
        #expect(source.displayName == "陈旧仓库")
        #expect(source.systemImage == "trash.slash")
        #expect(source.rawValue == "staleRepository")
    }

    // MARK: - PendingItem identity

    /// `identityID` is the id the initializer mints, and the evaluator resolves
    /// one expected id per rule per repository. The two derivations must agree
    /// for every repository, workspace and auto-generated identity.
    @Test func identityIDMatchesInitializerMintedID() throws {
        let sources: [PendingItemSource] = [
            .dirtyWorkspace, .unpushedCommits, .behindRemote, .mergeConflict,
            .upstreamMissing, .unavailable, .staleRepository, .scanFailure,
            .creepingChanges, .staleActivity, .healthTrend,
            .workspaceDegraded, .workspaceConflicts, .workspaceAggregation
        ]
        for source in sources {
            for repositoryID in [nil, "repo-1"] {
                for workspaceID in [nil, "ws-1"] {
                    for title in ["", "已确认的标题"] {
                        let minted = PendingItem(
                            source: source, severity: .low,
                            repositoryID: repositoryID, workspaceID: workspaceID, title: title
                        ).id
                        #expect(minted == PendingItem.identityID(
                            source: source, repositoryID: repositoryID,
                            workspaceID: workspaceID, title: title
                        ))
                        #expect(minted.hasPrefix("pi-v1-"))
                        #expect(minted.count == "pi-v1-".count + 64)
                    }
                }
            }
        }
        // The repository-rule and workspace-rule expected ids of one source
        // must stay distinct, otherwise the two dispatches would resolve each
        // other's previous item.
        #expect(PendingItem.identityID(source: .dirtyWorkspace, repositoryID: "repo-1",
                                       workspaceID: nil, title: "")
                != PendingItem.identityID(source: .dirtyWorkspace, repositoryID: nil,
                                          workspaceID: "repo-1", title: ""))
    }

    /// A caller that already knows the id gets exactly that id back, and the
    /// auto-generated identity ignores the supplied severity.
    @Test func explicitIDIsPreservedAndSeverityDoesNotFeedIdentity() throws {
        let explicit = "pi-v1-" + String(repeating: "a", count: 64)
        let item = PendingItem(id: explicit, source: .unavailable, severity: .critical,
                               repositoryID: "repo-1", title: "ignored")
        #expect(item.id == explicit)
        #expect(item.severity == .critical)

        let low = PendingItem(source: .unavailable, severity: .low, repositoryID: "repo-1", title: "t")
        let critical = PendingItem(source: .unavailable, severity: .critical, repositoryID: "repo-1", title: "t")
        #expect(low.id == critical.id)
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
        let loadedStaleItem = try #require(archive.items.first { $0.source == .staleRepository })
        let staleID = loadedStaleItem.id
        let result = store.applyUserAction(itemID: staleID, action: PendingItemUserAction.cleanupStaleRepository)
        guard case .success(let updated) = result else {
            Issue.record("Failed to apply: \(result)")
            return
        }

        let stale = try #require(updated.items.first { $0.source == PendingItemSource.staleRepository })
        #expect(stale.status == PendingItemStatus.resolved)

        let dirty = try #require(updated.items.first { $0.source == PendingItemSource.dirtyWorkspace })
        #expect(dirty.status == PendingItemStatus.active)  // unchanged
    }

    @Test func evaluatorWritePreservesActionFromAnotherStoreInstance() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("pending-items.json")

        let actionStore = PendingItemStore(fileURL: fileURL)
        let evaluatorStore = PendingItemStore(fileURL: fileURL)
        let item = PendingItem(
            source: .dirtyWorkspace,
            severity: .medium,
            repositoryID: "repo-1",
            title: "工作区存在长期改动"
        )
        _ = actionStore.save(PendingItemArchive(items: [item]))
        // Prime the second instance's cache with the pre-action state.
        _ = evaluatorStore.load()

        guard case .success = actionStore.applyUserAction(
            itemID: item.id,
            action: .acknowledge
        ) else {
            Issue.record("Expected user action to persist")
            return
        }

        let reevaluated = PendingItem(
            id: item.id,
            source: item.source,
            severity: .high,
            repositoryID: item.repositoryID,
            title: item.title,
            explanation: "updated evidence",
            evidence: ["new"],
            status: .active
        )
        guard case .success(let merged) = evaluatorStore.replaceAll(with: [reevaluated]) else {
            Issue.record("Expected evaluator write to persist")
            return
        }

        #expect(merged.items.first?.status == .acknowledged)
        #expect(merged.items.first?.severity == .high)
        let reloaded = PendingItemStore(fileURL: fileURL).load()
        guard case .success(let archive) = reloaded else {
            Issue.record("Expected merged archive to reload")
            return
        }
        #expect(archive.items.first?.status == .acknowledged)
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

    // MARK: - Auto-recovery after a rule stops firing

    /// A repository rule mints its item id from the real, non-empty title, but
    /// resolution used to look the previous item up by an empty-title id. The
    /// dirty → clean transition therefore never completed. This pins the fix
    /// against the production path: evaluate dirty, feed the real items back as
    /// history, then evaluate clean.
    @Test func ruleAutoRecoversItemMintedFromRealTitle() throws {
        let dirty = repositorySnapshot(id: "repo-recover", name: "recover", status: .changed, changedFileCount: 2)
        let first = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [dirty]))
        let active = try #require(first.items.first { $0.source == .dirtyWorkspace })
        #expect(active.status == .active)
        #expect(active.title == "工作区存在长期改动")

        let clean = repositorySnapshot(id: "repo-recover", name: "recover", status: .clean)
        let second = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean], previousItems: first.items))

        #expect(second.resolvedItemCount == 1)
        #expect(second.transitions.count == 1)
        #expect(second.newItemCount == 0)
        let resolved = try #require(second.items.first { $0.id == active.id })
        #expect(resolved.status == .resolved)
        #expect(resolved.firstDetectedAt == active.firstDetectedAt)
        #expect(resolved.title == active.title)
    }

    /// A rule that keeps firing must not be reported as recovered, and each
    /// source keeps its own firstDetectedAt even with several rules active.
    @Test func sustainedMultipleRulesReportNoRecovery() throws {
        let repo = repositorySnapshot(id: "repo-multi", name: "multi", status: .changed,
                                      changedFileCount: 2, aheadCount: 3, hasUpstream: true)
        let first = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [repo]))
        #expect(first.items.count == 2)

        let second = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [repo], previousItems: first.items))
        #expect(second.resolvedItemCount == 0)
        #expect(second.newItemCount == 0)
        #expect(second.notifications.isEmpty)
        #expect(second.items.count == 2)
        for before in first.items {
            let after = try #require(second.items.first { $0.id == before.id })
            #expect(after.status == .active)
            #expect(after.firstDetectedAt == before.firstDetectedAt)
        }
    }

    /// When the same repository id appears twice with conflicting state, a live
    /// candidate must supersede the resolution an earlier clean occurrence
    /// carried forward, instead of leaving a resolved item for a dirty repo.
    @Test func resolvedCarryForwardYieldsToLiveCandidateWithSameID() throws {
        let dirty = repositorySnapshot(id: "duplicate", name: "dirty", status: .changed, changedFileCount: 1)
        let seed = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [dirty]))
        let previous = try #require(seed.items.first { $0.source == .dirtyWorkspace })
        let clean = repositorySnapshot(id: "duplicate", name: "clean", status: .clean)

        let result = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean, dirty], previousItems: [previous]))

        let matching = result.items.filter { $0.id == previous.id }
        #expect(matching.count == 1)
        #expect(matching.first?.status == .active)
        #expect(matching.first?.repositoryName == "dirty")
    }

    /// Auto-recovery must be durable: a second clean refresh neither re-resolves
    /// nor duplicates the item, so the completed list and the
    /// resolved → active reappearance path keep working.
    @Test func repeatedCleanRefreshKeepsResolvedItem() throws {
        let dirty = repositorySnapshot(id: "repo-stable", name: "stable", status: .changed, changedFileCount: 1)
        let clean = repositorySnapshot(id: "repo-stable", name: "stable", status: .clean)
        let first = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [dirty]))
        let active = try #require(first.items.first { $0.source == .dirtyWorkspace })
        let second = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean], previousItems: first.items))
        let third = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean], previousItems: second.items))

        #expect(third.resolvedItemCount == 0)
        #expect(third.newItemCount == 0)
        #expect(third.notifications.isEmpty)
        let recovered = third.items.filter { $0.id == active.id }
        #expect(recovered.count == 1)
        #expect(recovered.first?.status == .resolved)
        #expect(recovered.first?.firstDetectedAt == active.firstDetectedAt)
    }

    /// When the condition returns, the persisted resolved item reactivates
    /// instead of being recreated, and the reappearance notification fires.
    @Test func reappearingConditionReactivatesResolvedItem() throws {
        let dirty = repositorySnapshot(id: "repo-reappear", name: "reappear", status: .changed, changedFileCount: 1)
        let clean = repositorySnapshot(id: "repo-reappear", name: "reappear", status: .clean)
        let first = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [dirty]))
        let active = try #require(first.items.first { $0.source == .dirtyWorkspace })
        let second = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean], previousItems: first.items))
        let third = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [dirty], previousItems: second.items))

        let reactivated = try #require(third.items.first { $0.id == active.id })
        #expect(reactivated.status == .active)
        #expect(reactivated.firstDetectedAt == active.firstDetectedAt)
        #expect(third.transitions.contains { $0.from == .resolved && $0.to == .active })
        #expect(third.notifications.contains { $0.item.id == active.id })
        #expect(third.newItemCount == 0)
    }

    /// An archived item whose id predates the current rule title must still be
    /// resolvable by rule scope, and its stored id must not change.
    @Test func resolutionMatchesArchivedItemWithDifferentTitle() throws {
        let clean = repositorySnapshot(id: "repo-legacy", name: "legacy", status: .clean)
        let historical = PendingItem(
            id: "legacy-id", source: .dirtyWorkspace, severity: .low,
            repositoryID: "repo-legacy", repositoryName: "legacy", title: "旧标题",
            firstDetectedAt: "2025-01-01T00:00:00Z", status: .active
        )
        let result = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean], previousItems: [historical]))

        #expect(result.resolvedItemCount == 1)
        #expect(result.newItemCount == 0)
        let resolved = try #require(result.items.first { $0.id == "legacy-id" })
        #expect(resolved.status == .resolved)
        #expect(resolved.title == "旧标题")
        #expect(resolved.firstDetectedAt == "2025-01-01T00:00:00Z")
    }

    /// Workspace rules key identity by workspace instead of repository; the
    /// same auto-recovery must work with a nil repositoryID.
    @Test func workspaceRuleAutoRecoversWhenConditionDisappears() throws {
        let conflicted = repositorySnapshot(id: "repo-ws", name: "ws", status: .changed,
                                            changedFileCount: 1, conflictedFileCount: 1)
        let workspace = Workspace(id: "ws-1", name: "ws-1", repositoryIDs: [conflicted.id])
        let dirtyAggregations = WorkspaceAggregationEngine.aggregateAll(
            workspaces: [workspace], allRepositories: [conflicted])
        let first = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [], workspaceAggregations: dirtyAggregations, workspaces: [workspace]))
        let active = try #require(first.items.first { $0.source == .workspaceConflicts })

        let clean = repositorySnapshot(id: "repo-ws", name: "ws", status: .clean)
        let cleanAggregations = WorkspaceAggregationEngine.aggregateAll(
            workspaces: [workspace], allRepositories: [clean])
        let second = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [], workspaceAggregations: cleanAggregations,
            workspaces: [workspace], previousItems: first.items))

        #expect(second.resolvedItemCount >= 1)
        let resolved = try #require(second.items.first { $0.id == active.id })
        #expect(resolved.status == .resolved)
        #expect(resolved.workspaceID == "ws-1")
    }

    /// The evaluator's resolved decision must survive the store merge; a stored
    /// acknowledgement must not resurrect the item the evaluation resolved.
    @Test func acknowledgedItemAutoRecoverySurvivesStoreMerge() throws {
        let dirty = repositorySnapshot(id: "repo-ack", name: "ack", status: .changed, changedFileCount: 1)
        let first = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [dirty]))
        var acknowledged = try #require(first.items.first { $0.source == .dirtyWorkspace })
        acknowledged.status = .acknowledged

        let clean = repositorySnapshot(id: "repo-ack", name: "ack", status: .clean)
        let second = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean], previousItems: [acknowledged]))
        #expect(second.resolvedItemCount == 1)
        #expect(second.items.first { $0.id == acknowledged.id }?.status == .resolved)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-recover-\(UUID().uuidString).json")
        let store = PendingItemStore(fileURL: url)
        _ = store.save(PendingItemArchive(items: [acknowledged]))
        guard case .success(let merged) = store.replaceAll(with: second.items) else {
            Issue.record("Expected merge to persist")
            return
        }
        #expect(merged.items.first { $0.id == acknowledged.id }?.status == .resolved)
    }

    // MARK: - Auto-recovery robustness

    /// Duplicate clean occurrences must resolve a rule instance once; a second
    /// copy would put two items with one id in the archive and trap the next
    /// evaluation's id lookup.
    @Test func duplicateCleanOccurrencesResolveOnceWithoutDuplicateIDs() throws {
        let dirty = repositorySnapshot(id: "duplicate", name: "dirty", status: .changed, changedFileCount: 1)
        let seed = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [dirty]))
        let previous = try #require(seed.items.first { $0.source == .dirtyWorkspace })
        let clean = repositorySnapshot(id: "duplicate", name: "clean", status: .clean)

        let first = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean, clean], previousItems: [previous]))
        let matching = first.items.filter { $0.id == previous.id }
        #expect(matching.count == 1)
        #expect(matching.first?.status == .resolved)
        #expect(first.resolvedItemCount == 1)

        // Feeding the result back must not trap on a repeated id.
        let second = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean, clean], previousItems: first.items))
        #expect(second.items.filter { $0.id == previous.id }.count == 1)
        #expect(second.resolvedItemCount == 0)
    }

    /// Repository occurrences with conflicting states must still emit one item
    /// per id in either order, whether the stored item was active or resolved,
    /// so the archive never repeats an id.
    @Test func mixedDuplicateOccurrencesKeepOneItemPerID() throws {
        let dirty = repositorySnapshot(id: "duplicate", name: "dirty", status: .changed, changedFileCount: 1)
        let clean = repositorySnapshot(id: "duplicate", name: "clean", status: .clean)
        let seed = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [dirty]))
        let active = try #require(seed.items.first { $0.source == .dirtyWorkspace })
        let resolved = PendingItem(
            id: active.id, source: active.source, severity: active.severity,
            repositoryID: active.repositoryID, repositoryName: active.repositoryName,
            title: active.title, explanation: active.explanation, evidence: active.evidence,
            firstDetectedAt: active.firstDetectedAt, lastConfirmedAt: active.lastConfirmedAt,
            status: .resolved)

        for previous in [active, resolved] {
            for repositories in [[dirty, clean], [clean, dirty]] {
                let result = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
                    repositories: repositories, previousItems: [previous]))
                let matching = result.items.filter { $0.id == active.id }
                #expect(matching.count == 1)
                // A dirty occurrence means the condition is present.
                #expect(matching.first?.status == .active)
                // The archive stays valid for the next evaluation.
                _ = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
                    repositories: repositories, previousItems: result.items))
            }
        }
    }

    /// Workspace items have a nil repositoryID, so the cross-rule bucket must
    /// not match a recovery in one workspace against a new source in another.
    @Test func workspaceRecoveryDoesNotLeakAcrossWorkspaces() throws {
        let conflictedA = repositorySnapshot(id: "repo-a", name: "a", status: .changed,
                                            changedFileCount: 1, conflictedFileCount: 1)
        let workspaceA = Workspace(id: "ws-a", name: "ws-a", repositoryIDs: [conflictedA.id])
        let dirtyAggregations = WorkspaceAggregationEngine.aggregateAll(
            workspaces: [workspaceA], allRepositories: [conflictedA])
        let seed = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [], workspaceAggregations: dirtyAggregations, workspaces: [workspaceA]))
        let seededConflict = try #require(seed.items.first { $0.source == .workspaceConflicts })
        let previous = PendingItem(
            id: seededConflict.id, source: seededConflict.source, severity: seededConflict.severity,
            repositoryID: seededConflict.repositoryID, repositoryName: seededConflict.repositoryName,
            workspaceID: seededConflict.workspaceID, workspaceName: seededConflict.workspaceName,
            title: seededConflict.title, explanation: seededConflict.explanation,
            evidence: seededConflict.evidence,
            firstDetectedAt: "2025-01-01T00:00:00Z", lastConfirmedAt: seededConflict.lastConfirmedAt,
            status: .active
        )

        let healthyA = repositorySnapshot(id: "repo-a", name: "a", status: .clean)
        let conflictedB = repositorySnapshot(id: "repo-b", name: "b", status: .changed,
                                            changedFileCount: 1, conflictedFileCount: 1)
        let workspaceB = Workspace(id: "ws-b", name: "ws-b", repositoryIDs: [conflictedB.id])
        let aggregations = WorkspaceAggregationEngine.aggregateAll(
            workspaces: [workspaceA, workspaceB], allRepositories: [healthyA, conflictedB])
        let result = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [], workspaceAggregations: aggregations,
            workspaces: [workspaceA, workspaceB], previousItems: [previous]))

        let recovered = try #require(result.items.first { $0.id == previous.id })
        #expect(recovered.status == .resolved)
        #expect(recovered.workspaceID == "ws-a")
        #expect(result.resolvedItemCount == 1)
        let conflictsB = result.items.first { $0.source == .workspaceConflicts && $0.workspaceID == "ws-b" }
        #expect(conflictsB != nil)
        #expect(conflictsB?.firstDetectedAt != previous.firstDetectedAt)
    }

    /// One stored source replaced by two new sources is one recovery, not two,
    /// even though the cross-rule pass visits it once per new source.
    @Test func sourceChangeReportsOneRecovery() throws {
        let dirty = repositorySnapshot(id: "repo-swap", name: "swap", status: .changed, changedFileCount: 1)
        let seed = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [dirty]))
        let seededDirty = try #require(seed.items.first { $0.source == .dirtyWorkspace })
        let previous = PendingItem(
            id: seededDirty.id, source: seededDirty.source, severity: seededDirty.severity,
            repositoryID: seededDirty.repositoryID, repositoryName: seededDirty.repositoryName,
            title: seededDirty.title, explanation: seededDirty.explanation, evidence: seededDirty.evidence,
            firstDetectedAt: "2025-01-01T00:00:00Z", lastConfirmedAt: seededDirty.lastConfirmedAt,
            status: .active
        )

        let diverged = repositorySnapshot(id: "repo-swap", name: "swap", status: .clean,
                                          aheadCount: 2, behindCount: 3, hasUpstream: true)
        let result = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [diverged], previousItems: [previous]))

        #expect(result.resolvedItemCount == 1)
        #expect(result.items.filter { $0.id == previous.id }.isEmpty)
        #expect(result.items.filter { $0.firstDetectedAt == previous.firstDetectedAt }.count == 1)
    }

    /// A legacy scope holding both a resolved and a live item resolves the live
    /// one instead of silently dropping it behind the frozen history entry.
    @Test func liveStoredItemWinsOverResolvedItemForTheSameScope() throws {
        let clean = repositorySnapshot(id: "repo-degenerate", name: "degenerate", status: .clean)
        let resolvedOld = PendingItem(id: "resolved-old", source: .dirtyWorkspace, severity: .low,
                                      repositoryID: "repo-degenerate", title: "旧标题",
                                      firstDetectedAt: "2024-01-01T00:00:00Z", status: .resolved)
        let live = PendingItem(id: "live-current", source: .dirtyWorkspace, severity: .low,
                               repositoryID: "repo-degenerate", title: "工作区存在长期改动",
                               firstDetectedAt: "2025-01-01T00:00:00Z", status: .active)
        let result = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean], previousItems: [resolvedOld, live]))

        #expect(result.resolvedItemCount == 1)
        #expect(result.items.contains { $0.id == "live-current" && $0.status == .resolved })
    }

    /// A concurrent permanent ignore is user suppression and must survive the
    /// evaluator's auto-recovery merge.
    @Test func concurrentPermanentIgnoreSurvivesRecoveryMerge() throws {
        let dirty = repositorySnapshot(id: "repo-ignore", name: "ignore", status: .changed, changedFileCount: 1)
        let seed = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: [dirty]))
        let active = try #require(seed.items.first { $0.source == .dirtyWorkspace })

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-ignore-\(UUID().uuidString).json")
        let store = PendingItemStore(fileURL: url)
        _ = store.save(PendingItemArchive(items: [active]))
        guard case .success = store.applyUserAction(itemID: active.id, action: .permanentlyIgnore) else {
            Issue.record("Expected permanent ignore to persist")
            return
        }

        let clean = repositorySnapshot(id: "repo-ignore", name: "ignore", status: .clean)
        let reevaluated = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
            repositories: [clean], previousItems: [active]))
        #expect(reevaluated.items.first { $0.id == active.id }?.status == .resolved)

        guard case .success(let merged) = store.replaceAll(with: reevaluated.items) else {
            Issue.record("Expected merge to persist")
            return
        }
        #expect(merged.items.first { $0.id == active.id }?.status == .permanentlyIgnored)
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

    private func repositorySnapshot(
        id: String,
        name: String,
        status: RepositoryStatus,
        changedFileCount: Int = 0,
        aheadCount: Int? = 0,
        behindCount: Int? = 0,
        hasUpstream: Bool? = true,
        conflictedFileCount: Int? = 0
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            id: id,
            name: name,
            path: "/tmp/\(name)",
            workspaceKind: nil,
            branch: "main",
            status: status,
            modifiedFileCount: changedFileCount,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 0,
            unstagedFileCount: changedFileCount,
            conflictedFileCount: conflictedFileCount,
            aheadCount: aheadCount,
            behindCount: behindCount,
            hasUpstream: hasUpstream,
            changedFileCount: changedFileCount,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: DateFormatting.nowISO(),
            dataSource: .current,
            lastSuccessfulScanAt: DateFormatting.nowISO(),
            lastChangedAt: nil,
            lastCommitID: "abc123",
            lastCommitSummary: "test",
            lastCommitMetadataAvailable: true,
            lastActivityAt: nil,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )
    }
}

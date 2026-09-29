import Testing
@testable import DevPulse

@Suite("Workspace Pending Item Drilldown")
struct WorkspacePendingItemDrilldownTests {
    @Test func overlappingWorkspacesShowOnlyTheirActionableMemberRepositoryItems() {
        let workspaceA = Workspace(
            id: "workspace-a",
            name: "Synthetic Workspace A",
            repositoryIDs: ["repo-shared", "repo-a"]
        )
        let workspaceB = Workspace(
            id: "workspace-b",
            name: "Synthetic Workspace B",
            repositoryIDs: ["repo-shared", "repo-b"]
        )
        let summaryA = workspaceSummary(id: "summary-a", workspaceID: workspaceA.id)
        let summaryB = workspaceSummary(id: "summary-b", workspaceID: workspaceB.id)

        let sharedDirty = item(
            id: "shared-dirty",
            source: .dirtyWorkspace,
            severity: .low,
            repositoryID: "repo-shared",
            repositoryName: "Shared Repo",
            title: "Uncommitted changes"
        )
        let sharedBehind = item(
            id: "shared-behind",
            source: .behindRemote,
            severity: .high,
            repositoryID: "repo-shared",
            repositoryName: "Shared Repo",
            title: "Behind remote",
            status: .restored
        )
        // No snapshot/name is needed: persisted workspace membership still
        // connects a stale repository's actionable cleanup item.
        let staleRepository = item(
            id: "stale-repository",
            source: .staleRepository,
            severity: .critical,
            repositoryID: "repo-a",
            title: "Repository unavailable"
        )
        let repoBDirty = item(
            id: "repo-b-dirty",
            source: .dirtyWorkspace,
            severity: .medium,
            repositoryID: "repo-b",
            repositoryName: "Repo B",
            title: "Uncommitted changes"
        )
        let snoozed = item(
            id: "snoozed",
            source: .mergeConflict,
            severity: .high,
            repositoryID: "repo-a",
            title: "Snoozed conflict",
            status: .snoozed
        )
        let muted = item(
            id: "muted",
            source: .unpushedCommits,
            severity: .medium,
            repositoryID: "repo-a",
            title: "Muted commits",
            status: .muted
        )
        let acknowledged = item(
            id: "acknowledged",
            source: .upstreamMissing,
            severity: .medium,
            repositoryID: "repo-a",
            title: "Acknowledged upstream",
            status: .acknowledged
        )
        let resolved = item(
            id: "resolved",
            source: .dirtyWorkspace,
            severity: .critical,
            repositoryID: "repo-a",
            title: "Resolved changes",
            status: .resolved
        )
        let ignored = item(
            id: "ignored",
            source: .mergeConflict,
            severity: .critical,
            repositoryID: "repo-a",
            title: "Ignored conflict",
            status: .permanentlyIgnored
        )
        let outsideMember = item(
            id: "outside-member",
            source: .dirtyWorkspace,
            severity: .critical,
            repositoryID: "repo-outside",
            title: "Unrelated repository"
        )
        let missingRepository = item(
            id: "missing-repository",
            source: .dirtyWorkspace,
            severity: .critical,
            title: "Missing repository relation"
        )
        let workspaceLevel = item(
            id: "workspace-level",
            source: .workspaceConflicts,
            severity: .critical,
            repositoryID: "repo-shared",
            title: "Workspace-level item"
        )

        let pendingItems = [
            sharedDirty, sharedBehind, staleRepository, repoBDirty,
            snoozed, muted, acknowledged, resolved, ignored,
            outsideMember, missingRepository, workspaceLevel
        ]
        let relatedA = WorkspacePendingItemDrilldown.relatedItems(
            for: summaryA,
            workspaces: [workspaceA, workspaceB],
            pendingItems: pendingItems
        )
        let relatedB = WorkspacePendingItemDrilldown.relatedItems(
            for: summaryB,
            workspaces: [workspaceA, workspaceB],
            pendingItems: pendingItems
        )

        #expect(relatedA.map(\.id) == [staleRepository.id, sharedBehind.id, sharedDirty.id])
        #expect(relatedB.map(\.id) == [sharedBehind.id, repoBDirty.id, sharedDirty.id])
        #expect(relatedA.contains(where: { $0.id == staleRepository.id }))
        #expect(relatedA.allSatisfy { $0.status == .active || $0.status == .restored })
        #expect(relatedB.allSatisfy { $0.status == .active || $0.status == .restored })
    }

    @Test func missingOrUnconfirmedWorkspaceRelationsReturnNoItems() {
        let workspace = Workspace(
            id: "unconfirmed-workspace",
            name: "Unconfirmed Workspace",
            repositoryIDs: ["repo-a"],
            autoSuggestConfirmed: false
        )
        let repoItem = item(
            id: "repo-item",
            source: .dirtyWorkspace,
            severity: .low,
            repositoryID: "repo-a",
            title: "Uncommitted changes"
        )
        let missingWorkspaceSummary = workspaceSummary(id: "missing-summary", workspaceID: "missing-workspace")
        let unconfirmedSummary = workspaceSummary(id: "unconfirmed-summary", workspaceID: workspace.id)
        let repositorySummary = item(
            id: "repository-summary",
            source: .dirtyWorkspace,
            severity: .low,
            repositoryID: "repo-a",
            title: "Not a workspace summary"
        )

        #expect(WorkspacePendingItemDrilldown.relatedItems(
            for: missingWorkspaceSummary,
            workspaces: [workspace],
            pendingItems: [repoItem]
        ).isEmpty)
        #expect(WorkspacePendingItemDrilldown.relatedItems(
            for: unconfirmedSummary,
            workspaces: [workspace],
            pendingItems: [repoItem]
        ).isEmpty)
        #expect(WorkspacePendingItemDrilldown.relatedItems(
            for: repositorySummary,
            workspaces: [workspace],
            pendingItems: [repoItem]
        ).isEmpty)
    }

    @Test func relatedItemAccessibilityExplainsTargetAndAction() {
        let related = item(
            id: "accessible-item",
            source: .unpushedCommits,
            severity: .high,
            repositoryID: "repo-a",
            repositoryName: "Synthetic Repo",
            title: "Local commits not pushed",
            status: .restored
        )

        #expect(WorkspacePendingItemDrilldown.accessibilityLabel(for: related)
            == "Synthetic Repo，Local commits not pushed，严重程度 高，状态 恢复提醒")
        #expect(WorkspacePendingItemDrilldown.accessibilityHint(for: related)
            == "打开Synthetic Repo的事项详情和处理选项")
        #expect(WorkspacePendingItemDrilldown.accessibilityIdentifier(for: related)
            == "pending-center.related-item.accessible-item")
    }

    private func workspaceSummary(id: String, workspaceID: String) -> PendingItem {
        PendingItem(
            id: id,
            source: .workspaceDegraded,
            severity: .high,
            workspaceID: workspaceID,
            title: "Workspace degraded"
        )
    }

    private func item(
        id: String,
        source: PendingItemSource,
        severity: PendingItemSeverity,
        repositoryID: String? = nil,
        repositoryName: String? = nil,
        title: String,
        status: PendingItemStatus = .active
    ) -> PendingItem {
        PendingItem(
            id: id,
            source: source,
            severity: severity,
            repositoryID: repositoryID,
            repositoryName: repositoryName,
            title: title,
            status: status
        )
    }
}

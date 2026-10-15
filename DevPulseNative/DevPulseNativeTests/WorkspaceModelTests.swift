import Foundation
import Testing
@testable import DevPulse

// MARK: - Workspace Model Tests

struct WorkspaceModelTests {

    // MARK: - Creation and identity

    @Test func testWorkspaceCreation() {
        let ws = Workspace(
            name: "Test Project",
            repositoryIDs: ["repo-1", "repo-2"]
        )

        #expect(ws.name == "Test Project")
        #expect(ws.repositoryIDs.count == 2)
        #expect(ws.repositoryIDs.contains("repo-1"))
        #expect(ws.repositoryIDs.contains("repo-2"))
        #expect(ws.groupingBasis == .manual)
        #expect(ws.autoSuggestConfirmed == true)
        #expect(ws.isPinned == false)
        #expect(ws.id.hasPrefix("ws-v1-"))
        #expect(!ws.createdAt.isEmpty)
        #expect(!ws.updatedAt.isEmpty)
    }

    @Test func testWorkspaceDefaultValues() {
        let ws = Workspace(
            name: "Default Test",
            repositoryIDs: ["repo-a"]
        )

        #expect(ws.sortOrder == 0)
        #expect(ws.isExpanded == true)
        #expect(ws.autoSuggestConfirmed == true)
        #expect(ws.groupingBasis == .manual)
    }

    @Test func testWorkspaceEquality() {
        let ws1 = Workspace(id: "ws-v1-aaa", name: "Same", repositoryIDs: ["r1", "r2"])
        let ws2 = Workspace(id: "ws-v1-bbb", name: "Same", repositoryIDs: ["r1", "r2"])
        // Custom IDs ensure unique identity
        #expect(ws1.id != ws2.id)
        #expect(ws1.name == ws2.name)
    }

    @Test func testWorkspaceWithCustomID() {
        let ws = Workspace(
            id: "my-custom-id",
            name: "Custom",
            repositoryIDs: ["r1"]
        )
        #expect(ws.id == "my-custom-id")
    }

    @Test func testWorkspaceAutoSuggestCandidate() {
        let candidate = WorkspaceAutoSuggestCandidate(
            name: "Suggestion",
            repositoryIDs: ["r1", "r2"],
            groupingBasis: .parentDirectory,
            evidence: "Same parent folder"
        )

        #expect(candidate.name == "Suggestion")
        #expect(candidate.repositoryIDs.count == 2)
        #expect(candidate.groupingBasis == .parentDirectory)
        #expect(candidate.evidence == "Same parent folder")
        #expect(candidate.id.hasPrefix("suggest-"))
    }

    // MARK: - Grouping basis display

    @Test func testGroupingBasisDisplay() {
        #expect(WorkspaceGroupingBasis.manual.displayName == "手动分组")
        #expect(WorkspaceGroupingBasis.parentDirectory.displayName == "相同父目录")
        #expect(WorkspaceGroupingBasis.gitCommonDir.displayName == "共享 Git 存储")
        #expect(WorkspaceGroupingBasis.remoteIdentity.displayName == "相同远程仓库")
        #expect(WorkspaceGroupingBasis.historicalAssociation.displayName == "历史关联")
        #expect(WorkspaceGroupingBasis.singleRepository.displayName == "单一仓库")
    }

    // MARK: - Migration

    @Test func testMigrationFromPinnedRepos() {
        let pinnedIDs: Set<String> = ["repo-1", "repo-2"]
        let repos = [
            RepositorySnapshot.mock(id: "repo-1", name: "RepoA", path: "/Users/test/RepoA"),
            RepositorySnapshot.mock(id: "repo-2", name: "RepoB", path: "/Users/test/RepoB"),
            RepositorySnapshot.mock(id: "repo-3", name: "RepoC", path: "/Users/test/RepoC")
        ]

        let result = WorkspaceMigrationEngine.migrateFromExistingData(
            pinnedRepositoryIDs: pinnedIDs,
            allRepositories: repos,
            existingWorkspaces: []
        )

        #expect(result.workspacesCreated == 2)
        #expect(result.repositoriesAssigned == 2)
        #expect(result.success == true)
    }

    @Test func testMigrationWithExistingWorkspaces() {
        let existingWS = Workspace(
            name: "Existing",
            repositoryIDs: ["repo-1"],
            groupingBasis: .manual
        )

        let result = WorkspaceMigrationEngine.migrateFromExistingData(
            pinnedRepositoryIDs: ["repo-1", "repo-2"],
            allRepositories: [
                .mock(id: "repo-1", name: "RepoA", path: "/test/RepoA"),
                .mock(id: "repo-2", name: "RepoB", path: "/test/RepoB")
            ],
            existingWorkspaces: [existingWS]
        )

        // repo-1 is already assigned, only repo-2 should be migrated
        #expect(result.workspacesCreated == 1)
        #expect(result.conflicts.count >= 1)
    }

    @Test func testRecoveryFromCorruption() {
        let archive = WorkspaceArchive(
            workspaces: [
                Workspace(name: "Valid", repositoryIDs: ["repo-1", "repo-2"]),
                Workspace(name: "Invalid", repositoryIDs: ["repo-nonexistent"]),
                Workspace(name: "Partial", repositoryIDs: ["repo-1", "repo-nonexistent"])
            ]
        )

        let (recovered, conflicts) = WorkspaceMigrationEngine.recoverFromCorruption(
            corruptedArchive: archive,
            allRepositories: [
                .mock(id: "repo-1", name: "R1", path: "/test/R1"),
                .mock(id: "repo-2", name: "R2", path: "/test/R2")
            ]
        )

        #expect(recovered.workspaces.count == 2) // "Invalid" should be removed
        #expect(recovered.workspaces.contains { $0.name == "Valid" })
        #expect(!recovered.workspaces.contains { $0.name == "Invalid" })
        #expect(recovered.workspaces.contains { $0.name == "Partial" })
        #expect(conflicts.count >= 1)
    }

    @Test func testMigrationRecordCreation() {
        let record = WorkspaceMigrationRecord(
            fromVersion: 0,
            toVersion: 1,
            migratedAt: ISO8601DateFormatter().string(from: Date()),
            success: true,
            detail: "Test migration"
        )

        #expect(record.fromVersion == 0)
        #expect(record.toVersion == 1)
        #expect(record.success == true)
        #expect(record.detail == "Test migration")
    }
}

// MARK: - Identity Stability Tests

struct WorkspaceIdentityTests {

    @Test func testIdentityResolverDirectMatch() {
        let migrations = WorkspaceIdentityResolver.resolveIdentities(
            previousIDs: ["old-1": "/Users/test/RepoA"],
            currentSnapshots: [
                .mock(id: "new-1", name: "RepoA", path: "/Users/test/RepoA")
            ]
        )

        // Should map old-1 to new-1 (same path)
        #expect(migrations["old-1"] == "new-1")
    }

    @Test func testIdentityResolverNoMatch() {
        let migrations = WorkspaceIdentityResolver.resolveIdentities(
            previousIDs: ["old-1": "/Users/test/RepoA"],
            currentSnapshots: [
                .mock(id: "new-1", name: "RepoB", path: "/Users/test/RepoB")
            ]
        )

        #expect(migrations.isEmpty)
    }

    @Test func testIdentityResolverMultiple() {
        let migrations = WorkspaceIdentityResolver.resolveIdentities(
            previousIDs: [
                "old-1": "/Users/test/A",
                "old-2": "/Users/test/B",
                "old-3": "/Users/test/C"
            ],
            currentSnapshots: [
                .mock(id: "new-1", name: "A", path: "/Users/test/A"),
                .mock(id: "new-2", name: "B", path: "/Users/test/B")
            ]
        )

        #expect(migrations.count == 2)
        #expect(migrations["old-1"] == "new-1")
        #expect(migrations["old-2"] == "new-2")
        #expect(migrations["old-3"] == nil)
    }
}

// MARK: - Auto-Suggest Tests

struct WorkspaceAutoSuggestTests {

    @Test func testParentDirectoryGrouping() {
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "Frontend", path: "/Users/test/Project/web"),
            RepositorySnapshot.mock(id: "r2", name: "Backend", path: "/Users/test/Project/api"),
            RepositorySnapshot.mock(id: "r3", name: "Other", path: "/Users/test/Other/lib")
        ]

        let context = WorkspaceAutoSuggestEngine.SuggestionContext(
            repositories: repos,
            minGroupSize: 2
        )
        let candidates = WorkspaceAutoSuggestEngine.generateCandidates(context: context)

        let projectGroup = candidates.first { $0.name == "Project" }
        #expect(projectGroup != nil)
        #expect(projectGroup?.repositoryIDs.count == 2)
        #expect(projectGroup?.groupingBasis == .parentDirectory)
    }

    @Test func testEmptyRepositories() {
        let context = WorkspaceAutoSuggestEngine.SuggestionContext(
            repositories: [],
            minGroupSize: 2
        )
        let candidates = WorkspaceAutoSuggestEngine.generateCandidates(context: context)
        #expect(candidates.isEmpty)
    }

    @Test func testSingleRepository() {
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "Solo", path: "/Users/test/Solo")
        ]

        let context = WorkspaceAutoSuggestEngine.SuggestionContext(
            repositories: repos,
            minGroupSize: 2
        )
        let candidates = WorkspaceAutoSuggestEngine.generateCandidates(context: context)
        #expect(candidates.isEmpty) // No groups of 2+
    }

    @Test func testDismissedSuggestions() {
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "A", path: "/Users/test/Project/A"),
            RepositorySnapshot.mock(id: "r2", name: "B", path: "/Users/test/Project/B")
        ]

        // First, get the candidate ID
        let context1 = WorkspaceAutoSuggestEngine.SuggestionContext(
            repositories: repos,
            minGroupSize: 2
        )
        let candidates1 = WorkspaceAutoSuggestEngine.generateCandidates(context: context1)
        guard let firstCandidate = candidates1.first else {
            #expect(Bool(false), "Should have at least one candidate")
            return
        }

        // Now dismiss it
        let context2 = WorkspaceAutoSuggestEngine.SuggestionContext(
            repositories: repos,
            dismissedHashes: [firstCandidate.id],
            minGroupSize: 2
        )
        let candidates2 = WorkspaceAutoSuggestEngine.generateCandidates(context: context2)
        #expect(candidates2.count < candidates1.count)
    }

    @Test func testHistoricalAssociation() {
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "my-service-api", path: "/test/my-service-api"),
            RepositorySnapshot.mock(id: "r2", name: "my-service-web", path: "/test/my-service-web"),
            RepositorySnapshot.mock(id: "r3", name: "other-tool", path: "/test/other-tool")
        ]

        let context = WorkspaceAutoSuggestEngine.SuggestionContext(
            repositories: repos,
            minGroupSize: 2
        )
        let candidates = WorkspaceAutoSuggestEngine.generateCandidates(context: context)

        let historical = candidates.first { $0.groupingBasis == .historicalAssociation }
        #expect(historical != nil)
        #expect(historical?.name == "my")
        #expect(historical?.repositoryIDs.count ?? 0 >= 2)
    }

    @Test func testAlreadyGroupedRepos() {
        let existingWS = Workspace(
            name: "Existing",
            repositoryIDs: ["r1", "r2"],
            autoSuggestConfirmed: true
        )

        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "A", path: "/Users/test/Dir/A"),
            RepositorySnapshot.mock(id: "r2", name: "B", path: "/Users/test/Dir/B"),
            RepositorySnapshot.mock(id: "r3", name: "C", path: "/Users/test/Dir/C")
        ]

        let context = WorkspaceAutoSuggestEngine.SuggestionContext(
            repositories: repos,
            existingWorkspaces: [existingWS],
            minGroupSize: 2
        )
        let candidates = WorkspaceAutoSuggestEngine.generateCandidates(context: context)

        // r1 and r2 are already grouped, so r1+r2+r3 should not be suggested
        // but a group with only r3 doesn't meet min size
        let dirCandidate = candidates.first { $0.groupingBasis == .parentDirectory }
        #expect(dirCandidate == nil || dirCandidate!.repositoryIDs.count <= 1)
    }
}

// MARK: - Linked Worktree Tests

struct WorkspaceLinkedWorktreeTests {

    @Test func testMainAndLinkedWorktrees() {
        let repos = [
            RepositorySnapshot.mock(id: "main", name: "Project", path: "/Users/test/Project",
                                   workspaceKind: .mainWorktree),
            RepositorySnapshot.mock(id: "linked1", name: "Project-feature", path: "/Users/test/Project/feature",
                                   workspaceKind: .linkedWorktree),
            RepositorySnapshot.mock(id: "linked2", name: "Project-hotfix", path: "/Users/test/Project/hotfix",
                                   workspaceKind: .linkedWorktree)
        ]

        let context = WorkspaceAutoSuggestEngine.SuggestionContext(
            repositories: repos,
            minGroupSize: 2
        )
        let candidates = WorkspaceAutoSuggestEngine.generateCandidates(context: context)

        let gitCommonCandidates = candidates.filter { $0.groupingBasis == .gitCommonDir }
        #expect(!gitCommonCandidates.isEmpty)
    }

    @Test func testStandaloneReposNotGroupedWithWorktrees() {
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "Project", path: "/Users/test/Project",
                                   workspaceKind: .mainWorktree),
            RepositorySnapshot.mock(id: "r2", name: "Standalone", path: "/Users/test/Standalone",
                                   workspaceKind: .standalone)
        ]

        let context = WorkspaceAutoSuggestEngine.SuggestionContext(
            repositories: repos,
            minGroupSize: 2
        )
        let candidates = WorkspaceAutoSuggestEngine.generateCandidates(context: context)

        // Standalone should not be grouped with the main worktree
        let gitCommon = candidates.filter { $0.groupingBasis == .gitCommonDir }
        for candidate in gitCommon {
            #expect(!candidate.repositoryIDs.contains("r2"),
                    "Standalone repo should not be in git common dir group")
        }
    }
}

// MARK: - Aggregation Correctness Tests

struct WorkspaceAggregationTests {

    @Test func testCleanWorkspace() {
        let ws = Workspace(name: "Clean", repositoryIDs: ["r1", "r2"])
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "A", path: "/test/A", status: .clean,
                                   modified: 0, added: 0, deleted: 0, risk: .low),
            RepositorySnapshot.mock(id: "r2", name: "B", path: "/test/B", status: .clean,
                                   modified: 0, added: 0, deleted: 0, risk: .low)
        ]

        let agg = WorkspaceAggregationEngine.aggregate(workspace: ws, allRepositories: repos)

        #expect(agg.overallHealth == .healthy)
        #expect(agg.totalRepositories == 2)
        #expect(agg.activeRepositories == 0)
        #expect(agg.totalChangedFiles == 0)
        #expect(agg.highRiskCount == 0)
        #expect(agg.readErrorCount == 0)
        #expect(agg.conflictCount == 0)
    }

    @Test func testDirtyWorkspace() {
        let ws = Workspace(name: "Dirty", repositoryIDs: ["r1"])
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "Repo", path: "/test/Repo",
                                   status: .changed, modified: 5, added: 2, deleted: 1,
                                   changed: 8, ahead: 3, risk: .medium)
        ]

        let agg = WorkspaceAggregationEngine.aggregate(workspace: ws, allRepositories: repos)

        #expect(agg.overallHealth == WorkspaceHealthLevel.warning)
        #expect(agg.activeRepositories == 1)
        #expect(agg.totalChangedFiles == 8)
        #expect(agg.totalChangedFiles == 8)
    }

    @Test func testConflictedWorkspace() {
        let ws = Workspace(name: "Conflict", repositoryIDs: ["r1"])
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "Conflicting", path: "/test/Conflicting",
                                   conflicted: 3, risk: .high)
        ]

        let agg = WorkspaceAggregationEngine.aggregate(workspace: ws, allRepositories: repos)

        #expect(agg.conflictCount == 1)
        #expect(agg.conflictRepositoryNames.contains("Conflicting"))
        #expect(agg.overallHealth == .critical)
    }

    @Test func testWorkspaceWithErrors() {
        let ws = Workspace(name: "Errors", repositoryIDs: ["r1", "r2"])
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "OK", path: "/test/OK",
                                   status: .clean, modified: 0, dataSource: .current),
            RepositorySnapshot.mock(id: "r2", name: "Broken", path: "/test/Broken",
                                   status: .error, modified: 0, dataSource: .unknown)
        ]

        let agg = WorkspaceAggregationEngine.aggregate(workspace: ws, allRepositories: repos)

        #expect(agg.overallHealth == .critical)
        #expect(agg.readErrorCount >= 1)
        #expect(agg.errorCount >= 1)
    }

    @Test func testStaleRepositories() {
        let ws = Workspace(name: "Stale", repositoryIDs: ["r1", "r2"])
        let longAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 24 * 3600))
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "Active", path: "/test/Active",
                                   lastActivityAt: ISO8601DateFormatter().string(from: Date())),
            RepositorySnapshot.mock(id: "r2", name: "Inactive", path: "/test/Inactive",
                                   lastActivityAt: longAgo)
        ]

        let agg = WorkspaceAggregationEngine.aggregate(workspace: ws, allRepositories: repos)

        #expect(agg.staleRepositoryCount >= 1)
        #expect(agg.staleRepositories.contains { $0.name == "Inactive" })
    }

    /// Locks the staleness rules that the aggregation pass now evaluates in a
    /// single traversal: a stale activity timestamp feeds both the count and the
    /// drill-down list, while a stale last scan of a current repository only
    /// raises the count.
    @Test func testStalenessClassificationIsStable() {
        let ws = Workspace(name: "StaleRules", repositoryIDs: ["activity", "changed", "scanned", "fresh"])
        let longAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 24 * 3600))
        let repos = [
            RepositorySnapshot.mock(id: "activity", name: "Activity", path: "/test/Activity",
                                   lastActivityAt: longAgo),
            RepositorySnapshot.mock(id: "changed", name: "Changed", path: "/test/Changed",
                                   lastActivityAt: nil, lastScannedAt: nil,
                                   lastChangedAt: longAgo),
            RepositorySnapshot.mock(id: "scanned", name: "Scanned", path: "/test/Scanned",
                                   lastActivityAt: nil, lastScannedAt: longAgo),
            RepositorySnapshot.mock(id: "fresh", name: "Fresh", path: "/test/Fresh",
                                   lastActivityAt: ISO8601DateFormatter().string(from: Date()))
        ]

        let agg = WorkspaceAggregationEngine.aggregate(workspace: ws, allRepositories: repos)

        #expect(agg.totalRepositories == 4)
        #expect(agg.repositorySummaries.count == 4)
        #expect(agg.staleRepositoryCount == 3)
        #expect(agg.staleRepositories.map(\.name) == ["Activity", "Changed"])
    }

    @Test func testAggregationIsFromCache() {
        let ws = Workspace(name: "Test", repositoryIDs: ["r1"])
        let repos = [RepositorySnapshot.mock(id: "r1", name: "R", path: "/test/R")]

        let agg = WorkspaceAggregationEngine.aggregate(workspace: ws, allRepositories: repos)

        #expect(agg.isFromCache == false)
        #expect(agg.computationDurationMs >= 0)
    }

    @Test func testAggregateAll() {
        let workspaces = [
            Workspace(name: "WS1", repositoryIDs: ["r1"]),
            Workspace(name: "WS2", repositoryIDs: ["r2"])
        ]
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "R1", path: "/test/R1"),
            RepositorySnapshot.mock(id: "r2", name: "R2", path: "/test/R2")
        ]

        let aggs = WorkspaceAggregationEngine.aggregateAll(
            workspaces: workspaces,
            allRepositories: repos
        )

        #expect(aggs.count == 2)
        #expect(aggs.keys.contains(workspaces[0].id))
        #expect(aggs.keys.contains(workspaces[1].id))
    }

    /// `aggregateAll` resolves workspace membership in one pass over the scan
    /// result, so it must still produce exactly what one `aggregate` call per
    /// workspace produces — including repositories shared by several
    /// workspaces, ids no scan result contains, and empty workspaces.
    @Test func testAggregateAllMatchesPerWorkspaceAggregate() throws {
        let shared = "shared"
        let workspaces = [
            Workspace(name: "Alpha", repositoryIDs: [shared, "a1", "missing"]),
            Workspace(name: "Beta", repositoryIDs: [shared, "b1"]),
            Workspace(name: "Empty", repositoryIDs: []),
            Workspace(name: "OrphanFree", repositoryIDs: ["o1"])
        ]
        let repositories = [
            RepositorySnapshot.mock(id: shared, name: "Shared", path: "/test/Shared",
                                   status: .changed, modified: 4, changed: 4, conflicted: 1,
                                   ahead: 2, behind: 1, hasUpstream: false, risk: .high),
            RepositorySnapshot.mock(id: "a1", name: "A1", path: "/test/A1"),
            RepositorySnapshot.mock(id: "b1", name: "B1", path: "/test/B1",
                                   status: .changed, modified: 2, risk: .medium),
            RepositorySnapshot.mock(id: "o1", name: "O1", path: "/test/O1"),
            RepositorySnapshot.mock(id: "unowned", name: "Unowned", path: "/test/Unowned",
                                   status: .error, dataSource: .unknown)
        ]

        let combined = WorkspaceAggregationEngine.aggregateAll(
            workspaces: workspaces,
            allRepositories: repositories
        )

        #expect(combined.count == workspaces.count)
        for workspace in workspaces {
            let expected = WorkspaceAggregationEngine.aggregate(
                workspace: workspace,
                allRepositories: repositories
            )
            let actual = try #require(combined[workspace.id])
            #expect(try aggregationPayload(actual) == aggregationPayload(expected))
        }
    }

    /// Repository identity and order survive the single membership pass: a
    /// repeated id contributes one repository, an unknown id contributes none,
    /// and drill-down lists keep scan-result order.
    @Test func testAggregateAllPreservesRepositoryOrderAndMembership() throws {
        let duplicated = Workspace(name: "Duplicated", repositoryIDs: ["r1", "r1", "r2", "unknown"])
        let sharing = Workspace(name: "Sharing", repositoryIDs: ["r2"])
        let repositories = [
            RepositorySnapshot.mock(id: "r1", name: "First", path: "/test/First", conflicted: 1),
            RepositorySnapshot.mock(id: "r2", name: "Second", path: "/test/Second", conflicted: 1),
            RepositorySnapshot.mock(id: "r3", name: "Unowned", path: "/test/Unowned")
        ]

        let aggregations = WorkspaceAggregationEngine.aggregateAll(
            workspaces: [duplicated, sharing],
            allRepositories: repositories
        )

        let duplicateAggregation = try #require(aggregations[duplicated.id])
        #expect(duplicateAggregation.totalRepositories == 2)
        #expect(duplicateAggregation.repositorySummaries.keys.sorted() == ["r1", "r2"])
        #expect(duplicateAggregation.conflictRepositoryNames == ["First", "Second"])

        // A repository two workspaces claim is aggregated into both.
        let sharedAggregation = try #require(aggregations[sharing.id])
        #expect(sharedAggregation.totalRepositories == 1)
        #expect(sharedAggregation.conflictCount == 1)

        // Repositories no workspace claims are not attributed to any of them.
        for aggregation in aggregations.values {
            #expect(aggregation.repositorySummaries["r3"] == nil)
        }
    }

    /// Aggregating all workspaces in one call must equal aggregating the
    /// confirmed and unconfirmed subsets separately and merging them, which is
    /// why the scheduler no longer splits its refresh into two engine calls.
    /// A workspace id present in both subsets is included so the duplicated-id
    /// precedence (the unconfirmed entry wins) stays pinned as well.
    @Test func testAggregateAllIsIndependentOfWorkspacePartitioning() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)
        let duplicatedID = "duplicated-workspace"
        let confirmedWorkspaces = [
            Workspace(id: duplicatedID, name: "DuplicatedConfirmed", repositoryIDs: ["r1"]),
            Workspace(name: "Confirmed", repositoryIDs: ["r1", "r2"]),
            Workspace(name: "Empty", repositoryIDs: [])
        ]
        let unconfirmedWorkspaces = [
            Workspace(id: duplicatedID, name: "DuplicatedUnconfirmed", repositoryIDs: ["r2"],
                      autoSuggestConfirmed: false),
            Workspace(name: "Unconfirmed", repositoryIDs: ["r2", "r3"], autoSuggestConfirmed: false)
        ]
        let repositories = [
            RepositorySnapshot.mock(id: "r1", name: "R1", path: "/test/R1",
                                   status: .changed, modified: 3, risk: .high),
            RepositorySnapshot.mock(id: "r2", name: "R2", path: "/test/R2", conflicted: 1),
            RepositorySnapshot.mock(id: "r3", name: "R3", path: "/test/R3",
                                   status: .error, dataSource: .unknown)
        ]

        // The scheduler aggregates confirmed workspaces first and unconfirmed
        // workspaces second.
        let combined = WorkspaceAggregationEngine.aggregateAll(
            workspaces: confirmedWorkspaces + unconfirmedWorkspaces,
            allRepositories: repositories,
            now: fixedNow
        )
        let confirmed = WorkspaceAggregationEngine.aggregateAll(
            workspaces: confirmedWorkspaces,
            allRepositories: repositories,
            now: fixedNow
        )
        let unconfirmed = WorkspaceAggregationEngine.aggregateAll(
            workspaces: unconfirmedWorkspaces,
            allRepositories: repositories,
            now: fixedNow
        )
        var merged = confirmed
        for (key, value) in unconfirmed { merged[key] = value }

        #expect(merged.count == combined.count)
        for (workspaceID, aggregation) in combined {
            let mergedAggregation = try #require(merged[workspaceID])
            #expect(try aggregationPayload(aggregation) == aggregationPayload(mergedAggregation))
        }
        #expect(combined[duplicatedID]?.workspaceName == "DuplicatedUnconfirmed")
    }

    /// A refresh round serves both consumers from one partitioned pass, so its
    /// maps must equal the two single-set aggregations they replace, including
    /// each map's own duplicated-id precedence.
    @Test func testAggregateAllPartitionedMatchesSeparateAggregations() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)
        let duplicatedID = "duplicated-workspace"
        let confirmedWorkspaces = [
            Workspace(id: duplicatedID, name: "DuplicatedConfirmed", repositoryIDs: ["r1"]),
            Workspace(name: "Confirmed", repositoryIDs: ["r1", "r2"])
        ]
        let unconfirmedWorkspaces = [
            Workspace(id: duplicatedID, name: "DuplicatedUnconfirmed", repositoryIDs: ["r2"],
                      autoSuggestConfirmed: false),
            Workspace(name: "Unconfirmed", repositoryIDs: ["r3"], autoSuggestConfirmed: false)
        ]
        let repositories = [
            RepositorySnapshot.mock(id: "r1", name: "R1", path: "/test/R1",
                                   status: .changed, modified: 3, risk: .high),
            RepositorySnapshot.mock(id: "r2", name: "R2", path: "/test/R2", conflicted: 1),
            RepositorySnapshot.mock(id: "r3", name: "R3", path: "/test/R3",
                                   status: .error, dataSource: .unknown)
        ]

        // The scheduler passes confirmed workspaces first, then unconfirmed ones.
        let round = WorkspaceAggregationEngine.aggregateAllPartitioned(
            workspaces: confirmedWorkspaces + unconfirmedWorkspaces,
            allRepositories: repositories,
            now: fixedNow
        )

        // Independent oracle for both maps: one public single-workspace
        // aggregation per workspace, merged in the order each map iterates — a
        // duplicated id keeps the last entry, which is the unconfirmed one for the
        // published map and the confirmed one for the confirmed subset.
        var expectedAll: [String: WorkspaceAggregation] = [:]
        for workspace in confirmedWorkspaces + unconfirmedWorkspaces {
            expectedAll[workspace.id] = WorkspaceAggregationEngine.aggregate(
                workspace: workspace, allRepositories: repositories, now: fixedNow
            )
        }
        var expectedConfirmed: [String: WorkspaceAggregation] = [:]
        for workspace in confirmedWorkspaces {
            expectedConfirmed[workspace.id] = WorkspaceAggregationEngine.aggregate(
                workspace: workspace, allRepositories: repositories, now: fixedNow
            )
        }

        #expect(round.all.keys.sorted() == expectedAll.keys.sorted())
        for (workspaceID, aggregation) in round.all {
            let expected = try #require(expectedAll[workspaceID])
            #expect(try aggregationPayload(aggregation) == aggregationPayload(expected))
        }
        #expect(round.confirmed.keys.sorted() == expectedConfirmed.keys.sorted())
        for (workspaceID, aggregation) in round.confirmed {
            let expected = try #require(expectedConfirmed[workspaceID])
            #expect(try aggregationPayload(aggregation) == aggregationPayload(expected))
        }

        #expect(round.all[duplicatedID]?.workspaceName == "DuplicatedUnconfirmed")
        #expect(round.confirmed[duplicatedID]?.workspaceName == "DuplicatedConfirmed")
    }

    /// Empty input stays explicit: no workspaces yields no aggregations, and a
    /// workspace without repositories still reports an empty `.unknown` result.
    @Test func testAggregateAllHandlesEmptyInputs() throws {
        let unclaimed = RepositorySnapshot.mock(id: "r1", name: "R1", path: "/test/R1")
        #expect(WorkspaceAggregationEngine.aggregateAll(
            workspaces: [], allRepositories: [unclaimed]
        ).isEmpty)

        let workspace = Workspace(name: "Empty", repositoryIDs: ["r1"])
        let aggregations = WorkspaceAggregationEngine.aggregateAll(
            workspaces: [workspace], allRepositories: []
        )
        let aggregation = try #require(aggregations[workspace.id])
        #expect(aggregation.totalRepositories == 0)
        #expect(aggregation.overallHealth == .unknown)
    }

    /// Every field except the wall-clock duration, so two aggregations can be
    /// compared for identical output without depending on timing.
    private func aggregationPayload(_ aggregation: WorkspaceAggregation) throws -> String {
        let encoded = try JSONEncoder().encode(aggregation)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            return String(decoding: encoded, as: UTF8.self)
        }
        object.removeValue(forKey: "computationDurationMs")
        let normalized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: normalized, as: UTF8.self)
    }

    @Test func testOrphanRepositories() {
        let ws = Workspace(name: "WS", repositoryIDs: ["r1"])
        let repos = [
            RepositorySnapshot.mock(id: "r1", name: "Grouped", path: "/test/G"),
            RepositorySnapshot.mock(id: "r2", name: "Orphan", path: "/test/O")
        ]

        let orphans = WorkspaceAggregationEngine.orphanRepositories(
            workspaces: [ws],
            allRepositories: repos
        )

        #expect(orphans.count == 1)
        #expect(orphans.first?.name == "Orphan")
    }
}

// MARK: - Workspace Store Tests

struct WorkspaceStoreTests {

    @Test func testCreateAndLoadWorkspace() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = WorkspaceStore(fileURL: tmpDir.appendingPathComponent("test.json"))
        let ws = Workspace(name: "Test", repositoryIDs: ["r1", "r2"])

        let result = store.upsertWorkspace(ws)
        #expect(result.isSuccess)

        let loadResult = store.load()
        switch loadResult {
        case .success(let archive):
            #expect(archive.workspaces.count == 1)
            #expect(archive.workspaces.first?.name == "Test")
        case .failure:
            #expect(Bool(false), "Should load successfully")
        }
    }

    @Test func testOlderArchiveMigrationCompletes() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("test.json")
        let oldArchive = WorkspaceArchive(
            schemaVersion: 0,
            workspaces: [Workspace(name: "Migrated", repositoryIDs: ["r1"])]
        )
        try JSONEncoder().encode(oldArchive).write(to: fileURL, options: .atomic)

        let store = WorkspaceStore(fileURL: fileURL)
        guard case .success(let archive) = store.load() else {
            Issue.record("Expected old workspace archive to migrate")
            return
        }

        #expect(archive.schemaVersion == WorkspaceArchive.currentSchemaVersion)
        #expect(archive.workspaces.first?.name == "Migrated")
        #expect(archive.migrationLog.count == 1)

        let persisted = try JSONDecoder().decode(WorkspaceArchive.self, from: Data(contentsOf: fileURL))
        #expect(persisted.schemaVersion == WorkspaceArchive.currentSchemaVersion)
    }

    @Test func testDeleteWorkspace() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-del-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = WorkspaceStore(fileURL: tmpDir.appendingPathComponent("test.json"))
        let ws = Workspace(name: "ToDelete", repositoryIDs: ["r1"])
        _ = store.upsertWorkspace(ws)

        let deleteResult = store.deleteWorkspace(id: ws.id)
        #expect(deleteResult.isSuccess)

        let loadResult = store.load()
        if case .success(let archive) = loadResult {
            #expect(archive.workspaces.isEmpty)
        }
    }

    @Test func testReorderWorkspaces() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-reorder-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = WorkspaceStore(fileURL: tmpDir.appendingPathComponent("test.json"))
        let ws1 = Workspace(name: "B", sortOrder: 0, repositoryIDs: ["r1"])
        let ws2 = Workspace(name: "A", sortOrder: 1, repositoryIDs: ["r2"])
        _ = store.upsertWorkspace(ws1)
        _ = store.upsertWorkspace(ws2)

        _ = store.reorderWorkspaces(ids: [ws2.id, ws1.id])
        if case .success(let archive) = store.load() {
            #expect(archive.workspaces.count == 2)
            #expect(archive.workspaces[0].name == "A")
            #expect(archive.workspaces[1].name == "B")
        }
    }

    @Test func testMoveRepository() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-move-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = WorkspaceStore(fileURL: tmpDir.appendingPathComponent("test.json"))
        let ws1 = Workspace(name: "Source", repositoryIDs: ["r1", "r2"])
        let ws2 = Workspace(name: "Target", repositoryIDs: ["r3"])
        _ = store.upsertWorkspace(ws1)
        _ = store.upsertWorkspace(ws2)

        _ = store.moveRepository(id: "r1", from: ws1.id, to: ws2.id)

        if case .success(let archive) = store.load() {
            let source = archive.workspaces.first { $0.id == ws1.id }
            let target = archive.workspaces.first { $0.id == ws2.id }
            #expect(source?.repositoryIDs.contains("r1") == false)
            #expect(target?.repositoryIDs.contains("r1") == true)
        }
    }

    @Test func testMergeWorkspaces() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-merge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = WorkspaceStore(fileURL: tmpDir.appendingPathComponent("test.json"))
        let ws1 = Workspace(name: "WS1", repositoryIDs: ["r1", "r2"])
        let ws2 = Workspace(name: "WS2", repositoryIDs: ["r3"])
        _ = store.upsertWorkspace(ws1)
        _ = store.upsertWorkspace(ws2)

        _ = store.mergeWorkspaces(fromID: ws2.id, intoID: ws1.id)

        if case .success(let archive) = store.load() {
            #expect(archive.workspaces.count == 1)
            let merged = archive.workspaces.first
            #expect(merged?.repositoryIDs.count == 3)
            #expect(merged?.repositoryIDs.contains("r3") == true)
        }
    }

    @Test func testSplitWorkspace() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-split-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = WorkspaceStore(fileURL: tmpDir.appendingPathComponent("test.json"))
        let ws = Workspace(name: "Original", repositoryIDs: ["r1", "r2", "r3"])
        _ = store.upsertWorkspace(ws)

        _ = store.splitWorkspace(sourceID: ws.id, newName: "New", moveRepositoryIDs: ["r2", "r3"])

        if case .success(let archive) = store.load() {
            #expect(archive.workspaces.count == 2)
            let source = archive.workspaces.first { $0.name == "Original" }
            let new = archive.workspaces.first { $0.name == "New" }
            #expect(source?.repositoryIDs == ["r1"])
            #expect(new?.repositoryIDs.sorted() == ["r2", "r3"])
        }
    }
}

// MARK: - Recovery Tests

struct WorkspaceRecoveryTests {

    @Test func testRecoveryFromEmptyArchive() {
        let (recovered, conflicts) = WorkspaceMigrationEngine.recoverFromCorruption(
            corruptedArchive: nil,
            allRepositories: []
        )

        #expect(recovered.workspaces.isEmpty)
        #expect(conflicts.isEmpty)
    }

    @Test func testRecoveryPreservesValidWorkspaces() {
        let archive = WorkspaceArchive(
            workspaces: [Workspace(name: "Valid", repositoryIDs: ["r1"])]
        )

        let (recovered, _) = WorkspaceMigrationEngine.recoverFromCorruption(
            corruptedArchive: archive,
            allRepositories: [.mock(id: "r1", name: "R", path: "/test/R")]
        )

        #expect(recovered.workspaces.count == 1)
        #expect(recovered.workspaces.first?.name == "Valid")
    }

    @Test func testRecoveryWithDismissedHashes() {
        let archive = WorkspaceArchive(
            workspaces: [Workspace(name: "Valid", repositoryIDs: ["r1"])],
            dismissedSuggestionHashes: ["hash-1", "hash-2"]
        )

        let (recovered, _) = WorkspaceMigrationEngine.recoverFromCorruption(
            corruptedArchive: archive,
            allRepositories: [.mock(id: "r1", name: "R", path: "/test/R")]
        )

        #expect(recovered.dismissedSuggestionHashes.count == 2)
        #expect(recovered.dismissedSuggestionHashes.contains("hash-1"))
    }
}

// MARK: - Cache Tests

struct WorkspaceCacheTests {

    @Test func testCacheHit() async {
        let cache = WorkspaceAggregationCache(cacheTTL: 60)
        let ws = Workspace(name: "Test", repositoryIDs: ["r1"])
        let agg = WorkspaceAggregationEngine.aggregate(
            workspace: ws,
            allRepositories: [.mock(id: "r1", name: "R", path: "/test/R")]
        )

        await cache.set(agg)
        let cached = await cache.get(workspaceID: ws.id)

        #expect(cached != nil)
        #expect(cached?.workspaceName == "Test")
    }

    @Test func testCacheMiss() async {
        let cache = WorkspaceAggregationCache(cacheTTL: 60)

        let cached = await cache.get(workspaceID: "nonexistent")
        #expect(cached == nil)
    }

    @Test func testCacheInvalidation() async {
        let cache = WorkspaceAggregationCache(cacheTTL: 60)
        let ws = Workspace(name: "Test", repositoryIDs: ["r1"])
        let agg = WorkspaceAggregationEngine.aggregate(
            workspace: ws,
            allRepositories: [.mock(id: "r1", name: "R", path: "/test/R")]
        )

        await cache.set(agg)
        await cache.invalidate(workspaceID: ws.id)

        let cached = await cache.get(workspaceID: ws.id)
        #expect(cached == nil)
    }

    @Test func testCacheTTL() async {
        let cache = WorkspaceAggregationCache(cacheTTL: 0) // Immediate expiry
        let ws = Workspace(name: "Test", repositoryIDs: ["r1"])
        let agg = WorkspaceAggregationEngine.aggregate(
            workspace: ws,
            allRepositories: [.mock(id: "r1", name: "R", path: "/test/R")]
        )

        await cache.set(agg)
        // Wait a tiny bit
        try? await Task.sleep(nanoseconds: 10_000_000)
        let cached = await cache.get(workspaceID: ws.id)
        #expect(cached == nil)
    }
}

// MARK: - Mock helpers

extension RepositorySnapshot {
    static func mock(
        id: String,
        name: String,
        path: String,
        status: RepositoryStatus = .clean,
        workspaceKind: RepositoryWorkspaceKind? = nil,
        branch: String = "main",
        modified: Int = 0,
        added: Int = 0,
        deleted: Int = 0,
        untracked: Int = 0,
        changed: Int? = nil,
        staged: Int? = nil,
        conflicted: Int? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        hasUpstream: Bool? = nil,
        risk: RiskLevel = .low,
        dataSource: RepositoryDataSource = .current,
        lastActivityAt: String? = nil,
        lastScannedAt: String? = nil,
        lastChangedAt: String? = nil
    ) -> RepositorySnapshot {
        let changedCount = changed ?? (modified + added + deleted + untracked)
        return RepositorySnapshot(
            id: id,
            name: name,
            path: path,
            workspaceKind: workspaceKind,
            branch: branch,
            status: status,
            modifiedFileCount: modified,
            addedFileCount: added,
            deletedFileCount: deleted,
            untrackedFileCount: untracked,
            stagedFileCount: staged,
            unstagedFileCount: nil,
            conflictedFileCount: conflicted,
            aheadCount: ahead,
            behindCount: behind,
            hasUpstream: hasUpstream,
            changedFileCount: changedCount,
            changedFilesPreview: [],
            risk: risk,
            lastScannedAt: lastScannedAt ?? ISO8601DateFormatter().string(from: Date()),
            dataSource: dataSource,
            lastSuccessfulScanAt: dataSource == .current ? (lastScannedAt ?? ISO8601DateFormatter().string(from: Date())) : nil,
            lastChangedAt: lastChangedAt,
            lastCommitID: nil,
            lastCommitSummary: nil,
            lastCommitMetadataAvailable: nil,
            lastActivityAt: lastActivityAt,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )
    }
}

// MARK: - Result convenience

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

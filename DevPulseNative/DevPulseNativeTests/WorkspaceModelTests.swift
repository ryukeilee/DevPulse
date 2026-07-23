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
        lastScannedAt: String? = nil
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
            lastChangedAt: nil,
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

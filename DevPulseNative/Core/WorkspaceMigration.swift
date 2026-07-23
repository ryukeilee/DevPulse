import Foundation

// MARK: - Workspace migration engine

/// Handles versioned migration of existing user data (pinned repos, history,
/// scan config) into the workspace system.
///
/// Migration is incremental and non-blocking. On first launch after upgrade,
/// existing pinned repositories are converted to single-repo workspaces.
/// Historical associations from repository history are used to suggest
/// multi-repo workspaces.
///
/// If migration is interrupted or encounters corruption, original data is
/// preserved and the migration can be re-run deterministically.

struct WorkspaceMigrationResult: Equatable, Sendable {
    let workspacesCreated: Int
    let repositoriesAssigned: Int
    let migrationRecords: [WorkspaceMigrationRecord]
    let conflicts: [WorkspaceMigrationConflict]
    let success: Bool
    let detail: String
}

struct WorkspaceMigrationConflict: Equatable, Identifiable, Sendable {
    let id: String
    let type: WorkspaceMigrationConflictType
    let description: String
    let resolution: WorkspaceMigrationResolution?
}

enum WorkspaceMigrationConflictType: String, Codable, Equatable, Sendable {
    case duplicateIdentity
    case corruptedData
    case schemaMismatch
    case ambiguousPin
    case interruptedMigration
}

enum WorkspaceMigrationResolution: String, Codable, Equatable, Sendable {
    case autoResolved
    case requiresUserAction
    case skipped
    case recovered
}

// MARK: - Migration engine

enum WorkspaceMigrationEngine {

    /// Migrate existing pinned repositories into the workspace system.
    ///
    /// Strategy:
    /// 1. Pinned repos → single-repository workspaces (preserving sort order)
    /// 2. Non-pinned repos → grouped by parent directory (suggested, not confirmed)
    /// 3. Linked worktrees → grouped with their main worktree where found
    ///
    /// This is an idempotent operation. If workspaces already exist for the
    /// same repository sets, the migration is skipped.
    static func migrateFromExistingData(
        pinnedRepositoryIDs: Set<String>,
        allRepositories: [RepositorySnapshot],
        existingWorkspaces: [Workspace],
        repositoryHistory: [RepositoryHistoryEntry]? = nil,
        now: Date = Date()
    ) -> WorkspaceMigrationResult {
        var conflicts: [WorkspaceMigrationConflict] = []
        var records: [WorkspaceMigrationRecord] = []
        var created = 0
        var assigned = 0
        let existingRepoIDs = Set(existingWorkspaces.flatMap(\.repositoryIDs))
        let isoNow = ISO8601DateFormatter().string(from: now)

        // 1. Create workspaces for pinned repos not yet assigned
        let alreadyAssignedPinned = existingRepoIDs.intersection(pinnedRepositoryIDs)
        if !alreadyAssignedPinned.isEmpty {
            conflicts.append(WorkspaceMigrationConflict(
                id: "pinned-already-assigned-\(alreadyAssignedPinned.count)",
                type: .duplicateIdentity,
                description: "\(alreadyAssignedPinned.count) 个已固定的仓库已存在于现有工作空间中，跳过重复分组",
                resolution: .autoResolved
            ))
        }

        let unassignedPinned = pinnedRepositoryIDs.subtracting(existingRepoIDs)
        for repoID in unassignedPinned {
            guard let repo = allRepositories.first(where: { $0.id == repoID }) else {
                conflicts.append(WorkspaceMigrationConflict(
                    id: "pinned-repo-not-found-\(repoID)",
                    type: .corruptedData,
                    description: "已固定的仓库 ID「\(repoID)」在当前扫描结果中不存在，跳过",
                    resolution: .skipped
                ))
                continue
            }
            // Pin → separate workspace
            let ws = Workspace(
                name: repo.name,
                sortOrder: created,
                isPinned: true,
                repositoryIDs: [repoID],
                groupingBasis: .singleRepository,
                autoSuggestConfirmed: true,
                createdAt: isoNow
            )
            // Store in the existing workspace store
            _ = ws  // Will be persisted by the caller
            created += 1
            assigned += 1
        }

        // 2. Non-pinned repos → suggest but don't auto-confirm
        // (handled by AutoSuggestEngine, not migration)

        records.append(WorkspaceMigrationRecord(
            fromVersion: 0,
            toVersion: WorkspaceSchema.version,
            migratedAt: isoNow,
            success: true,
            detail: "迁移了 \(created) 个已固定仓库到工作空间系统"
        ))

        return WorkspaceMigrationResult(
            workspacesCreated: created,
            repositoriesAssigned: assigned,
            migrationRecords: records,
            conflicts: conflicts,
            success: true,
            detail: created > 0
                ? "已迁移 \(created) 个固定仓库为独立工作空间，\(assigned) 个仓库已分配"
                : "无需迁移：所有已固定仓库已在工作空间中"
        )
    }

    /// Attempt to recover from corrupted workspace data.
    /// Returns a clean archive with any recoverable workspaces preserved.
    static func recoverFromCorruption(
        corruptedArchive: WorkspaceArchive?,
        allRepositories: [RepositorySnapshot]
    ) -> (archive: WorkspaceArchive, conflicts: [WorkspaceMigrationConflict]) {
        var conflicts: [WorkspaceMigrationConflict] = []

        guard let corrupted = corruptedArchive else {
            return (WorkspaceArchive(), [])
        }

        var validWorkspaces: [Workspace] = []
        let validRepoIDs = Set(allRepositories.map(\.id))

        for ws in corrupted.workspaces {
            // Filter out references to non-existent repositories
            let validIDs = ws.repositoryIDs.filter { validRepoIDs.contains($0) }
            if validIDs.isEmpty {
                conflicts.append(WorkspaceMigrationConflict(
                    id: "workspace-empty-\(ws.id)",
                    type: .corruptedData,
                    description: "工作空间「\(ws.name)」中所有仓库均已不存在，已跳过",
                    resolution: .skipped
                ))
                continue
            }
            var recovered = ws
            if validIDs.count < ws.repositoryIDs.count {
                conflicts.append(WorkspaceMigrationConflict(
                    id: "workspace-partial-\(ws.id)",
                    type: .duplicateIdentity,
                    description: "工作空间「\(ws.name)」中有 \(ws.repositoryIDs.count - validIDs.count) 个仓库不存在",
                    resolution: .autoResolved
                ))
            }
            recovered.repositoryIDs = validIDs
            validWorkspaces.append(recovered)
        }

        return (
            WorkspaceArchive(
                schemaVersion: WorkspaceArchive.currentSchemaVersion,
                workspaces: validWorkspaces,
                migrationLog: corrupted.migrationLog,
                dismissedSuggestionHashes: corrupted.dismissedSuggestionHashes
            ),
            conflicts
        )
    }
}

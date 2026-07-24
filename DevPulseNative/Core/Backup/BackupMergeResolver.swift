import Foundation
import OSLog

// MARK: - Backup merge resolver

/// Deterministic conflict resolution rules for restoring backup data.
///
/// Handles:
/// - Repository path changes (repo moved between backup and restore)
/// - Linked worktree reconstruction
/// - Same-name repositories at different paths
/// - Device username differences
/// - Workspace identity changes
/// - Schema version migrations
final class BackupMergeResolver {
    private let logger = Logger(subsystem: "local.devpulse.app", category: "BackupMerge")

    // MARK: - Conflict detection

    /// Compare a backup's repository snapshots against current data and
    /// return all conflicts found.
    static func detectConflicts(
        backupRepositories: [String: Any],
        currentRepositories: [String: Any],
        backupWorkspaces: [String: Any]?,
        currentWorkspaces: [String: Any]?
    ) -> [RestoreConflict] {
        var conflicts: [RestoreConflict] = []
        var conflictId = 0

        // 1. Detect repository path changes
        let backupPaths = Set(backupRepositories.keys)
        let currentPaths = Set(currentRepositories.keys)

        // Repos in backup that also exist in current but at different canonical paths
        for backupPath in backupPaths {
            for currentPath in currentPaths {
                if pathsReferToSameRepo(backupPath, currentPath) && backupPath != currentPath {
                    conflictId += 1
                    conflicts.append(RestoreConflict(
                        id: "path-change-\(conflictId)",
                        storeType: .repositorySnapshot,
                        conflictType: .repositoryPathChanged,
                        description: "仓库路径从「\(backupPath)」变更为「\(currentPath)」",
                        resolution: .merge
                    ))
                }
            }
        }

        // 2. Detect duplicate repository names
        let backupNames = Set(backupRepositories.values.compactMap { ($0 as? [String: Any])?["name"] as? String })
        let currentNames = Set(currentRepositories.values.compactMap { ($0 as? [String: Any])?["name"] as? String })
        let commonNames = backupNames.intersection(currentNames)
        if !commonNames.isEmpty {
            // Check if the same names point to different paths
            for name in commonNames {
                let backupPathsForName = backupRepositories.compactMap { (path, repo) -> String? in
                    guard let repoDict = repo as? [String: Any],
                          repoDict["name"] as? String == name else { return nil }
                    return path
                }
                let currentPathsForName = currentRepositories.compactMap { (path, repo) -> String? in
                    guard let repoDict = repo as? [String: Any],
                          repoDict["name"] as? String == name else { return nil }
                    return path
                }
                for bPath in backupPathsForName {
                    for cPath in currentPathsForName where bPath != cPath {
                        conflictId += 1
                        conflicts.append(RestoreConflict(
                            id: "dup-name-\(conflictId)",
                            storeType: .repositorySnapshot,
                            conflictType: .duplicateRepositoryName,
                            description: "同名仓库「\(name)」：备份路径「\(bPath)」vs 当前路径「\(cPath)」",
                            resolution: .merge
                        ))
                    }
                }
            }
        }

        // 3. Detect workspace identity changes
        if let backupWorkspaces, let currentWorkspaces {
            let backupWsNames = Set(backupWorkspaces.values.compactMap { ($0 as? [String: Any])?["name"] as? String })
            let currentWsNames = Set(currentWorkspaces.values.compactMap { ($0 as? [String: Any])?["name"] as? String })
            let commonWsNames = backupWsNames.intersection(currentWsNames)
            for name in commonWsNames {
                let backupIds = backupWorkspaces.compactMap { (_, ws) -> String? in
                    guard let wsDict = ws as? [String: Any],
                          wsDict["name"] as? String == name else { return nil }
                    return wsDict["id"] as? String
                }
                let currentIds = currentWorkspaces.compactMap { (_, ws) -> String? in
                    guard let wsDict = ws as? [String: Any],
                          wsDict["name"] as? String == name else { return nil }
                    return wsDict["id"] as? String
                }
                if !backupIds.isEmpty, !currentIds.isEmpty, backupIds != currentIds {
                    conflictId += 1
                    conflicts.append(RestoreConflict(
                        id: "ws-identity-\(conflictId)",
                        storeType: .workspaces,
                        conflictType: .workspaceIdentityChanged,
                        description: "工作空间「\(name)」身份标识已变化，将合并仓库列表",
                        resolution: .merge
                    ))
                }
            }
        }

        // 4. Device user name check (informational)
        conflictId += 1
        conflicts.append(RestoreConflict(
            id: "device-user-\(conflictId)",
            storeType: .repositorySnapshot,
            conflictType: .deviceUserNameDifferent,
            description: "备份来源设备用户名可能与当前设备不同，仓库路径将按当前设备规范路径重新映射",
            resolution: .merge
        ))

        return conflicts
    }

    /// Resolve a set of conflicts deterministically.
    /// Returns a mapping of conflict ID → resolved action.
    static func resolveConflicts(
        _ conflicts: [RestoreConflict],
        autoResolve: Bool = true
    ) -> [String: RestoreConflictResolution] {
        var resolutions: [String: RestoreConflictResolution] = [:]

        for conflict in conflicts {
            switch conflict.conflictType {
            case .repositoryPathChanged:
                // Auto-merge: include backup data but remap path to current
                resolutions[conflict.id] = autoResolve ? .merge : .userDecide

            case .workspaceIdentityChanged:
                // Auto-merge: merge workspace contents
                resolutions[conflict.id] = autoResolve ? .merge : .userDecide

            case .linkedWorktreeRecreated:
                // Skip: the current worktree identity wins
                resolutions[conflict.id] = autoResolve ? .skip : .userDecide

            case .duplicateRepositoryName:
                // Merge: keep both, differentiate by path
                resolutions[conflict.id] = autoResolve ? .merge : .userDecide

            case .deviceUserNameDifferent:
                // Always auto-resolve: remap paths
                resolutions[conflict.id] = .useBackupVersion

            case .schemaVersionMismatch:
                // Requires migration, can't auto-resolve
                resolutions[conflict.id] = .userDecide

            case .dataHashMismatch:
                // Data integrity concern, user should decide
                resolutions[conflict.id] = .userDecide

            case .storeMissingInBackup:
                resolutions[conflict.id] = .skip

            case .storeMissingInCurrent:
                resolutions[conflict.id] = .useBackupVersion
            }
        }

        return resolutions
    }

    /// Merge backup repository data into current data.
    /// Backup data takes precedence for matching IDs; new entries from backup
    /// are added; entries only in current are preserved.
    static func mergeRepositoryData(
        backupJSON: Data,
        currentJSON: Data
    ) throws -> Data {
        let backupObj = try JSONSerialization.jsonObject(with: backupJSON)
        let currentObj = try JSONSerialization.jsonObject(with: currentJSON)

        guard var backupDict = backupObj as? [String: Any],
              var currentDict = currentObj as? [String: Any] else {
            // Non-dict format: return backup version (can't merge)
            return backupJSON
        }

        // Merge repositories array
        if let backupRepos = backupDict["repositories"] as? [[String: Any]],
           let currentRepos = currentDict["repositories"] as? [[String: Any]] {
            let mergedRepos = mergeRepositoryArrays(backup: backupRepos, current: currentRepos)
            currentDict["repositories"] = mergedRepos
        }

        // Merge workspaces array
        if let backupWorkspaces = backupDict["workspaces"] as? [[String: Any]],
           let currentWorkspaces = currentDict["workspaces"] as? [[String: Any]] {
            let mergedWorkspaces = mergeWorkspaceArrays(backup: backupWorkspaces, current: currentWorkspaces)
            currentDict["workspaces"] = mergedWorkspaces
        }

        // Preserve current metadata
        currentDict["generatedAt"] = ISO8601DateFormatter().string(from: Date())
        currentDict["writtenAt"] = ISO8601DateFormatter().string(from: Date())
        currentDict["persistenceState"] = "recovered"

        return try JSONSerialization.data(withJSONObject: currentDict, options: [.sortedKeys])
    }

    // MARK: - Private helpers

    private static func pathsReferToSameRepo(_ path1: String, _ path2: String) -> Bool {
        // Same basename is a strong signal
        let name1 = URL(fileURLWithPath: path1).lastPathComponent
        let name2 = URL(fileURLWithPath: path2).lastPathComponent
        return name1 == name2
    }

    private static func mergeRepositoryArrays(
        backup: [[String: Any]],
        current: [[String: Any]]
    ) -> [[String: Any]] {
        var byID: [String: [String: Any]] = [:]
        var byPath: [String: [String: Any]] = [:]

        // Index current repos by ID and path
        for repo in current {
            if let id = repo["id"] as? String { byID[id] = repo }
            if let path = repo["path"] as? String { byPath[path] = repo }
        }

        // Apply backup repos: new entries added, existing merged
        for repo in backup {
            guard let id = repo["id"] as? String else { continue }
            if let existing = byID[id] {
                // Merge: backup values win for non-nil fields
                var merged = existing
                for (key, value) in repo {
                    if !(value is NSNull) {
                        merged[key] = value
                    }
                }
                byID[id] = merged
                if let path = repo["path"] as? String {
                    byPath[path] = merged
                }
            } else {
                // New repo from backup
                byID[id] = repo
                if let path = repo["path"] as? String {
                    byPath[path] = repo
                }
            }
        }

        // Return merged repos preserving current order, then new ones
        var result: [[String: Any]] = []
        var seenIDs = Set<String>()
        for repo in current {
            if let id = repo["id"] as? String, let merged = byID[id] {
                result.append(merged)
                seenIDs.insert(id)
            } else {
                result.append(repo)
            }
        }
        for (id, repo) in byID where !seenIDs.contains(id) {
            result.append(repo)
        }

        return result
    }

    private static func mergeWorkspaceArrays(
        backup: [[String: Any]],
        current: [[String: Any]]
    ) -> [[String: Any]] {
        var byID: [String: [String: Any]] = [:]
        var byName: [String: [String: Any]] = [:]

        for ws in current {
            if let id = ws["id"] as? String { byID[id] = ws }
            if let name = ws["name"] as? String { byName[name] = ws }
        }

        for ws in backup {
            guard let id = ws["id"] as? String else { continue }
            let name = ws["name"] as? String

            if let existing = byID[id] {
                // Merge repository IDs
                var merged = existing
                if let backupIDs = ws["repositoryIDs"] as? [String],
                   var currentIDs = existing["repositoryIDs"] as? [String] {
                    let combined = Set(currentIDs).union(Set(backupIDs)).sorted()
                    merged["repositoryIDs"] = combined
                }
                byID[id] = merged
                if let name, byName[name] != nil { byName[name] = merged }
            } else if let name, let existing = byName[name] {
                // Same name, different ID - merge
                var merged = existing
                if let backupIDs = ws["repositoryIDs"] as? [String],
                   var currentIDs = existing["repositoryIDs"] as? [String] {
                    let combined = Set(currentIDs).union(Set(backupIDs)).sorted()
                    merged["repositoryIDs"] = combined
                }
                byID[id] = merged
                byName[name] = merged
            } else {
                byID[id] = ws
                if let name { byName[name] = ws }
            }
        }

        var result: [[String: Any]] = []
        var seenIDs = Set<String>()
        for ws in current {
            if let id = ws["id"] as? String, let merged = byID[id] {
                result.append(merged)
                seenIDs.insert(id)
            } else {
                result.append(ws)
            }
        }
        for (id, ws) in byID where !seenIDs.contains(id) {
            result.append(ws)
        }

        return result
    }
}

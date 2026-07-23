import Foundation

// MARK: - Auto-suggest engine

/// Generates workspace grouping candidates by analyzing repository paths,
/// Git common directories, remote identities, parent directory relationships,
/// and historical associations.
///
/// The engine NEVER modifies user groupings. It only produces candidates that
/// the user must explicitly confirm, reject, or permanently dismiss.
enum WorkspaceAutoSuggestEngine {

    // MARK: - Suggestion context

    struct SuggestionContext: Sendable {
        let repositories: [RepositorySnapshot]
        /// Existing workspaces to avoid duplicate suggestions
        let existingWorkspaces: [Workspace]
        /// Previously dismissed suggestion hashes
        let dismissedHashes: Set<String>
        /// Minimum repos to form a group suggestion
        let minGroupSize: Int

        init(
            repositories: [RepositorySnapshot],
            existingWorkspaces: [Workspace] = [],
            dismissedHashes: Set<String> = [],
            minGroupSize: Int = 2
        ) {
            self.repositories = repositories
            self.existingWorkspaces = existingWorkspaces
            self.dismissedHashes = dismissedHashes
            self.minGroupSize = minGroupSize
        }
    }

    // MARK: - Candidate generation

    /// Generate all candidates from all heuristics.
    static func generateCandidates(context: SuggestionContext) -> [WorkspaceAutoSuggestCandidate] {
        var candidates: [WorkspaceAutoSuggestCandidate] = []

        // 1. Parent directory grouping
        candidates.append(contentsOf: parentDirectoryCandidates(context: context))

        // 2. Git common directory (linked worktrees share object storage)
        candidates.append(contentsOf: gitCommonDirCandidates(context: context))

        // 3. Remote identity (same upstream remote URL)
        // Note: we can't read remotes without Git operations, but we can use
        // hasUpstream similarity as a weak signal. For full remote analysis,
        // we'd need to run `git remote get-url origin` per repo.
        // For now, defer this to future enhancement.

        // 4. Historical association (repos that have appeared together in activity)
        candidates.append(contentsOf: historicalAssociationCandidates(context: context))

        // 5. Single-repo workspaces for ungrouped repos
        candidates.append(contentsOf: orphanRepositoriesAsWorkspaces(context: context))

        // Filter out already-grouped and dismissed suggestions
        let existingRepoIDs = Set(context.existingWorkspaces.flatMap(\.repositoryIDs))
        let alreadyGroupedRepos = Set(context.existingWorkspaces
            .filter { $0.autoSuggestConfirmed }
            .flatMap(\.repositoryIDs))

        return candidates
            .filter { candidate in
                // Skip if all repos are already in a confirmed workspace
                let ungrouped = candidate.repositoryIDs.filter { !alreadyGroupedRepos.contains($0) }
                guard ungrouped.count >= context.minGroupSize else { return false }

                // Skip dismissed
                guard !context.dismissedHashes.contains(candidate.id) else { return false }

                // Skip if all repos are already in ONE confirmed workspace with matching basis
                let alreadyGroupedCount = candidate.repositoryIDs.filter { existingRepoIDs.contains($0) }.count
                guard alreadyGroupedCount < candidate.repositoryIDs.count else { return false }

                return true
            }
            .sorted { $0.repositoryIDs.count > $1.repositoryIDs.count }
    }

    // MARK: - Parent directory grouping

    /// Group repos that share the same immediate parent directory.
    private static func parentDirectoryCandidates(
        context: SuggestionContext
    ) -> [WorkspaceAutoSuggestCandidate] {
        let grouped = Dictionary(grouping: context.repositories) { repo in
            parentDirectory(path: repo.path)
        }

        var candidates: [WorkspaceAutoSuggestCandidate] = []
        for (dir, repos) in grouped where repos.count >= context.minGroupSize {
            let name = URL(fileURLWithPath: dir).lastPathComponent
            let evidence = "所有仓库位于同一父目录「\(dir)」下"
            candidates.append(WorkspaceAutoSuggestCandidate(
                name: name,
                repositoryIDs: repos.map(\.id),
                groupingBasis: .parentDirectory,
                evidence: evidence
            ))
        }
        return candidates
    }

    // MARK: - Git common directory grouping

    /// Group repos that share a Git common directory (linked worktrees).
    /// We identify this through workspaceKind and path heuristics:
    /// - A mainWorktree and its linkedWorktrees share Git storage
    /// - We find them by looking at repos whose paths differ below a `.git`
    ///   or whose `git rev-parse --git-common-dir` would resolve to the same place.
    /// - For linked worktrees, the .git file contains a path to the common dir.
    ///
    /// Since we don't read Git internals, we use the existing workspaceKind
    /// annotations from the scanner and group main+linked worktrees together.
    private static func gitCommonDirCandidates(
        context: SuggestionContext
    ) -> [WorkspaceAutoSuggestCandidate] {
        // Group by the main worktree reference
        // A main worktree's common dir is its own .git
        // A linked worktree's common dir is stored in .git as a file pointing
        // to the real common directory.
        //
        // For a practical heuristic: cluster repos by their parent until we
        // see a mainWorktree, then include all linkedWorktrees that share
        // the same parent directory tree structure.

        // Simplified approach: find worktree clusters
        let mainWorktrees = context.repositories.filter { $0.workspaceKind == .mainWorktree }
        let linkedWorktrees = context.repositories.filter { $0.workspaceKind == .linkedWorktree }
        var candidates: [WorkspaceAutoSuggestCandidate] = []

        // For each main worktree, find linked worktrees by proximity
        for main in mainWorktrees {
            let mainDir = parentDirectory(path: main.path)
            let siblings = linkedWorktrees.filter { linked in
                let linkedDir = parentDirectory(path: linked.path)
                return linkedDir == mainDir || isDescendant(path: linked.path, of: mainDir)
            }

            if !siblings.isEmpty {
                let all = [main] + siblings
                let evidence = "主工作区「\(main.name)」与 \(siblings.count) 个 linked worktree 共享 Git 对象存储"
                candidates.append(WorkspaceAutoSuggestCandidate(
                    name: main.name,
                    repositoryIDs: all.map(\.id),
                    groupingBasis: .gitCommonDir,
                    evidence: evidence
                ))
            }
        }

        // Also group linked worktrees without a detected main in the scan set
        // by matching their common directory paths (heuristic from parent dirs)
        let orphanLinked = linkedWorktrees.filter { linked in
            !candidates.contains { $0.repositoryIDs.contains(linked.id) }
        }

        if orphanLinked.count >= context.minGroupSize {
            // Group orphan linked worktrees by their parent directory
            let groupedByDir = Dictionary(grouping: orphanLinked) { parentDirectory(path: $0.path) }
            for (dir, repos) in groupedByDir where repos.count >= context.minGroupSize {
                let name = URL(fileURLWithPath: dir).lastPathComponent
                candidates.append(WorkspaceAutoSuggestCandidate(
                    name: name,
                    repositoryIDs: repos.map(\.id),
                    groupingBasis: .gitCommonDir,
                    evidence: "\(repos.count) 个 linked worktree 位于同一目录「\(dir)」"
                ))
            }
        }

        return candidates
    }

    // MARK: - Historical association

    /// Group repositories that have activity events at similar times,
    /// suggesting they are worked on together.
    private static func historicalAssociationCandidates(
        context: SuggestionContext
    ) -> [WorkspaceAutoSuggestCandidate] {
        // This is a placeholder for a more sophisticated analysis.
        // For now, we group repos whose names share a common prefix,
        // which is a strong signal (e.g., "my-service-api" and "my-service-web").
        var candidates: [WorkspaceAutoSuggestCandidate] = []

        let ungrouped = context.repositories.filter { repo in
            !context.existingWorkspaces.contains { $0.repositoryIDs.contains(repo.id) }
        }

        // Group by common name prefix (at least 3 chars, shared by >= minGroupSize repos)
        let prefixGroups = Dictionary(grouping: ungrouped) { repo -> String in
            let name = repo.name
            // Use first 2 path components or first 5 chars
            let components = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            return components.count > 1 ? String(components[0]).lowercased() : ""
        }

        for (prefix, repos) in prefixGroups where !prefix.isEmpty && repos.count >= context.minGroupSize {
            candidates.append(WorkspaceAutoSuggestCandidate(
                name: prefix,
                repositoryIDs: repos.map(\.id),
                groupingBasis: .historicalAssociation,
                evidence: "仓库名称共享前缀「\(prefix)」，可能属于同一项目"
            ))
        }

        return candidates
    }

    // MARK: - Orphan repositories

    /// Suggest single-repo workspaces for repos not yet in any workspace.
    private static func orphanRepositoriesAsWorkspaces(
        context: SuggestionContext
    ) -> [WorkspaceAutoSuggestCandidate] {
        let groupedRepoIDs = Set(context.existingWorkspaces.flatMap(\.repositoryIDs))
        let dismissedRepoIDs = extractDismissedRepoIDs(from: context.dismissedHashes)

        return context.repositories
            .filter { !groupedRepoIDs.contains($0.id) && !dismissedRepoIDs.contains($0.id) }
            .map { repo in
                WorkspaceAutoSuggestCandidate(
                    name: repo.name,
                    repositoryIDs: [repo.id],
                    groupingBasis: .singleRepository,
                    evidence: "仓库「\(repo.name)」尚未加入任何工作空间"
                )
            }
    }

    // MARK: - Helpers

    private static func parentDirectory(path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private static func isDescendant(path: String, of potentialParent: String) -> Bool {
        let normalized = RepositoryIdentity.canonicalPath(path)
        let parent = RepositoryIdentity.canonicalPath(potentialParent)
        guard !parent.isEmpty, parent != "/" else { return false }
        return normalized.hasPrefix(parent + "/") || normalized == parent
    }

    private static func extractDismissedRepoIDs(from hashes: Set<String>) -> Set<String> {
        // Dismissed repository hashes are stored as suggestion IDs.
        // We store the suggestion ID which is derived from content, so
        // we can't directly extract repo IDs from it. This is used for
        // an optimization pass; the full filtering happens via suggestion IDs.
        []
    }
}

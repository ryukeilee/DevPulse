import Foundation

enum RepositorySorter {
    /// Sort the shared action queue from the canonical repository decision.
    /// Explicit pins remain a user-controlled override.
    static func sort(_ repos: [RepositorySnapshot]) -> [RepositorySnapshot] {
        repos.sorted { lhs, rhs in
            RepositoryDecisionOrdering.precedes(lhs, rhs)
        }
    }
}

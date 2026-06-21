import Foundation

enum RepositorySorter {
    /// Sort repositories for widget display.
    ///
    /// Priority order:
    /// 1. Pinned repos first
    /// 2. Changed repos before clean repos
    /// 3. High risk > medium > low
    /// 4. More changed files first
    /// 5. Most recently changed first
    /// 6. Error repos last (unless all failed)
    static func sort(_ repos: [RepositorySnapshot]) -> [RepositorySnapshot] {
        repos.sorted { a, b in
            // Pinned first
            if a.isPinned != b.isPinned {
                return a.isPinned
            }

            let aReadinessPriority = readinessPriority(a.commitReadiness.level)
            let bReadinessPriority = readinessPriority(b.commitReadiness.level)
            if aReadinessPriority != bReadinessPriority {
                return aReadinessPriority < bReadinessPriority
            }

            // Changed before clean
            let aChanged = a.status == .changed
            let bChanged = b.status == .changed
            if aChanged != bChanged {
                return aChanged
            }

            // Higher risk first
            if a.risk != b.risk {
                return a.risk > b.risk
            }

            // More changed files first
            if a.changedFileCount != b.changedFileCount {
                return a.changedFileCount > b.changedFileCount
            }

            // More recent lastChangedAt first
            if let aDate = isoDate(a.lastChangedAt), let bDate = isoDate(b.lastChangedAt) {
                return aDate > bDate
            }
            if a.lastChangedAt != nil { return true }
            if b.lastChangedAt != nil { return false }

            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func readinessPriority(_ level: CommitReadinessLevel) -> Int {
        switch level {
        case .attention:
            return 0
        case .needsReview:
            return 1
        case .commitReady:
            return 2
        case .inProgress:
            return 3
        case .pushSuggested:
            return 4
        case .clean:
            return 5
        }
    }
}

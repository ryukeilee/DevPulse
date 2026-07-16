import Foundation

enum RepositorySorter {
    /// Sort repositories as an action queue while preserving explicit pins.
    ///
    /// Priority order:
    /// 1. Pinned repos first
    /// 2. Read failures and other abnormal states
    /// 3. Unpushed commits
    /// 4. Local working-tree changes
    /// 5. Remote-tracking updates
    /// 6. Risk, relevant counts, recent activity, then name
    static func sort(_ repos: [RepositorySnapshot]) -> [RepositorySnapshot] {
        repos.sorted { a, b in
            // Pinned first
            if a.isPinned != b.isPinned {
                return a.isPinned
            }

            let aActionPriority = a.actionState.sortPriority
            let bActionPriority = b.actionState.sortPriority
            if aActionPriority != bActionPriority {
                return aActionPriority < bActionPriority
            }

            // Unavailable observations are diagnostic work, not a queue of
            // commit/push/sync candidates. Never use retained risk or counts
            // to rank them as if those values were current.
            if a.resolvedDataSource != .current || b.resolvedDataSource != .current {
                let aSourcePriority = sourcePriority(a.resolvedDataSource)
                let bSourcePriority = sourcePriority(b.resolvedDataSource)
                if aSourcePriority != bSourcePriority {
                    return aSourcePriority < bSourcePriority
                }

                if let aDate = isoDate(a.lastScannedAt),
                   let bDate = isoDate(b.lastScannedAt),
                   aDate != bDate {
                    return aDate > bDate
                }

                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

            // Higher risk first
            if a.risk != b.risk {
                return a.risk > b.risk
            }

            // More actionable work first within the same action state.
            if (a.aheadCount ?? 0) != (b.aheadCount ?? 0) {
                return (a.aheadCount ?? 0) > (b.aheadCount ?? 0)
            }
            if a.changedFileCount != b.changedFileCount {
                return a.changedFileCount > b.changedFileCount
            }
            if (a.behindCount ?? 0) != (b.behindCount ?? 0) {
                return (a.behindCount ?? 0) > (b.behindCount ?? 0)
            }

            // More recent observed activity first.
            let aActivityAt = a.lastActivityAt ?? a.lastChangedAt
            let bActivityAt = b.lastActivityAt ?? b.lastChangedAt
            if let aDate = isoDate(aActivityAt), let bDate = isoDate(bActivityAt) {
                return aDate > bDate
            }
            if aActivityAt != nil { return true }
            if bActivityAt != nil { return false }

            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func sourcePriority(_ source: RepositoryDataSource) -> Int {
        switch source {
        case .unknown:
            return 0
        case .lastSuccessful:
            return 1
        case .current:
            return 2
        }
    }

}

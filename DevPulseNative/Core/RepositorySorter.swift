import Foundation

enum RepositoryListFilter: String, CaseIterable, Codable, Identifiable {
    case all
    case favorites
    case needsAttention = "needs_attention"
    case localChanges = "local_changes"
    case unsynchronized
    case errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .favorites:
            return "已收藏"
        case .needsAttention:
            return "需处理"
        case .localChanges:
            return "有本地改动"
        case .unsynchronized:
            return "未同步"
        case .errors:
            return "异常"
        }
    }

    fileprivate func includes(_ repository: RepositorySnapshot) -> Bool {
        switch self {
        case .all:
            return true
        case .favorites:
            return repository.isPinned
        case .needsAttention:
            return repository.actionState.kind != .noActionNeeded
        case .localChanges:
            guard repository.resolvedDataSource == .current,
                  repository.status != .error else {
                return false
            }
            let counts = repository.changeCounts
            let changedCount = max(
                max(repository.changedFileCount, counts.total),
                max(counts.staged, counts.unstaged + counts.untracked)
            )
            return repository.status != .clean && changedCount > 0
        case .unsynchronized:
            guard repository.resolvedDataSource == .current,
                  repository.status != .error else {
                return false
            }
            return repository.hasUpstream == false
                || max(repository.aheadCount ?? 0, 0) > 0
                || max(repository.behindCount ?? 0, 0) > 0
        case .errors:
            return repository.needsReadRetry
        }
    }
}

enum RepositoryListSortOrder: String, CaseIterable, Codable, Identifiable {
    case smart
    case recentActivity = "recent_activity"
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart:
            return "智能排序"
        case .recentActivity:
            return "最近活跃"
        case .name:
            return "名称"
        }
    }
}

struct RepositoryListPreferences: Codable, Equatable {
    static let currentVersion = 1
    static let defaultValue = RepositoryListPreferences()

    let version: Int
    var searchText: String
    var filter: RepositoryListFilter
    var sortOrder: RepositoryListSortOrder

    init(
        version: Int = currentVersion,
        searchText: String = "",
        filter: RepositoryListFilter = .all,
        sortOrder: RepositoryListSortOrder = .smart
    ) {
        self.version = version
        self.searchText = searchText
        self.filter = filter
        self.sortOrder = sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        searchText = try container.decode(String.self, forKey: .searchText)
        filter = try container.decode(RepositoryListFilter.self, forKey: .filter)
        sortOrder = try container.decodeIfPresent(
            RepositoryListSortOrder.self,
            forKey: .sortOrder
        ) ?? .smart
    }
}

struct RepositoryListPreferencesStore {
    static let storageKey = "repository_list_preferences_v1_json"

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = UserDefaults(
            suiteName: SharedSnapshotLocation.appGroupIdentifier
        ) ?? .standard
    ) {
        self.defaults = defaults
    }

    func load() -> RepositoryListPreferences {
        guard let data = defaults.data(forKey: Self.storageKey),
              let preferences = try? JSONDecoder().decode(
                RepositoryListPreferences.self,
                from: data
              ),
              preferences.version == RepositoryListPreferences.currentVersion else {
            return .defaultValue
        }
        return preferences
    }

    func save(_ preferences: RepositoryListPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

enum RepositoryListQuery {
    static func apply(
        to repositories: [RepositorySnapshot],
        searchText: String,
        filter: RepositoryListFilter,
        sortOrder: RepositoryListSortOrder = .smart
    ) -> [RepositorySnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = repositories.filter { repository in
            filter.includes(repository)
                && (query.isEmpty
                    || matches(repository.name, query: query)
                    || matches(repository.path, query: query))
        }
        return sort(filtered, by: sortOrder)
    }

    /// Ordering inputs for one repository, resolved once per query.
    ///
    /// The previous comparator re-parsed ISO-8601 timestamps on every pairwise
    /// comparison, and the stable wrapper evaluated the comparator twice per
    /// comparison. Precomputing dates removes that repeated parsing; name
    /// collation and pairwise ordering decisions remain unchanged.
    private struct OrderingKey {
        let isPinned: Bool
        let name: String
        let activityDate: Date?
    }

    private static func sort(
        _ repositories: [RepositorySnapshot],
        by sortOrder: RepositoryListSortOrder
    ) -> [RepositorySnapshot] {
        switch sortOrder {
        case .smart:
            return RepositorySorter.sort(repositories)
        case .recentActivity:
            // One parser and one reference instant for the whole query: every
            // timestamp is parsed once and the implausible-future guard is
            // applied consistently across repositories.
            let parser = DateFormatting.TimestampParser()
            let now = Date()
            let keys = repositories.map { repository in
                OrderingKey(
                    isPinned: repository.isPinned,
                    name: repository.name,
                    activityDate: RepositorySnapshot.mostRecentActivity(
                        lastActivityAt: repository.lastActivityAt,
                        lastChangedAt: repository.lastChangedAt,
                        now: now,
                        parser: parser
                    )?.date
                )
            }
            return stableSort(repositories, keys: keys) { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                if let lhsDate = lhs.activityDate,
                   let rhsDate = rhs.activityDate,
                   lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                if lhs.activityDate != nil && rhs.activityDate == nil { return true }
                if rhs.activityDate != nil && lhs.activityDate == nil { return false }
                return namePrecedes(lhs.name, rhs.name)
            }
        case .name:
            return stableSort(repositories) { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return namePrecedes(lhs.name, rhs.name)
            }
        }
    }

    /// Stable sort over precomputed keys. `precedes` is still evaluated in both
    /// directions — exactly like the snapshot-based comparator it replaces — so
    /// the pairwise outcomes, and therefore the resulting order, are unchanged.
    private static func stableSort(
        _ repositories: [RepositorySnapshot],
        keys: [OrderingKey],
        precedes: (OrderingKey, OrderingKey) -> Bool
    ) -> [RepositorySnapshot] {
        zip(repositories, keys)
            .enumerated()
            .sorted { lhs, rhs in
                if precedes(lhs.element.1, rhs.element.1) { return true }
                if precedes(rhs.element.1, lhs.element.1) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element.0)
    }

    private static func stableSort(
        _ repositories: [RepositorySnapshot],
        precedes: (RepositorySnapshot, RepositorySnapshot) -> Bool
    ) -> [RepositorySnapshot] {
        repositories.enumerated().sorted { lhs, rhs in
            if precedes(lhs.element, rhs.element) { return true }
            if precedes(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func namePrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func matches(_ candidate: String, query: String) -> Bool {
        candidate.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) != nil
    }
}

enum RepositorySorter {
    /// Sort the shared action queue from the canonical repository decision.
    /// Explicit pins remain a user-controlled override.
    ///
    /// Uses an explicit stable sort — when two repositories have equal priority
    /// under `RepositoryDecisionOrdering.precedes`, their original relative
    /// order is preserved. This prevents UI flickering between refreshes when
    /// repos rank identically on all meaningful criteria.
    /// Ordering keys are resolved once per repository. `precedes` is evaluated
    /// in both directions on every comparison, and rebuilding each snapshot's
    /// decision engine result and timestamps per call dominated large-list
    /// sorting.
    static func sort(_ repos: [RepositorySnapshot]) -> [RepositorySnapshot] {
        let parser = DateFormatting.TimestampParser()
        let keys = repos.map { RepositoryDecisionOrdering.Key(snapshot: $0, parser: parser) }
        return repos.enumerated().sorted { lhs, rhs in
            let (lIdx, _) = lhs
            let (rIdx, _) = rhs
            if RepositoryDecisionOrdering.precedes(keys[lIdx], keys[rIdx]) { return true }
            if RepositoryDecisionOrdering.precedes(keys[rIdx], keys[lIdx]) { return false }
            return lIdx < rIdx
        }.map(\.element)
    }
}

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

    private static func sort(
        _ repositories: [RepositorySnapshot],
        by sortOrder: RepositoryListSortOrder
    ) -> [RepositorySnapshot] {
        switch sortOrder {
        case .smart:
            return RepositorySorter.sort(repositories)
        case .recentActivity:
            return stableSort(repositories) { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                let lhsDate = activityDate(lhs)
                let rhsDate = activityDate(rhs)
                if let lhsDate, let rhsDate, lhsDate != rhsDate { return lhsDate > rhsDate }
                if lhsDate != nil && rhsDate == nil { return true }
                if rhsDate != nil && lhsDate == nil { return false }
                return namePrecedes(lhs, rhs)
            }
        case .name:
            return stableSort(repositories) { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return namePrecedes(lhs, rhs)
            }
        }
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

    private static func activityDate(_ repository: RepositorySnapshot) -> Date? {
        guard let timestamp = RepositorySnapshot.mostRecentActivityTimestamp(
            lastActivityAt: repository.lastActivityAt,
            lastChangedAt: repository.lastChangedAt
        ) else { return nil }
        return DateFormatting.date(from: timestamp)
    }

    private static func namePrecedes(
        _ lhs: RepositorySnapshot,
        _ rhs: RepositorySnapshot
    ) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
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
    static func sort(_ repos: [RepositorySnapshot]) -> [RepositorySnapshot] {
        repos.enumerated().sorted { lhs, rhs in
            let (lIdx, lRepo) = lhs
            let (rIdx, rRepo) = rhs
            if RepositoryDecisionOrdering.precedes(lRepo, rRepo) { return true }
            if RepositoryDecisionOrdering.precedes(rRepo, lRepo) { return false }
            return lIdx < rIdx
        }.map(\.element)
    }
}

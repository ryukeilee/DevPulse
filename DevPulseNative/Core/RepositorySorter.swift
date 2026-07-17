import Foundation

enum RepositoryListFilter: String, CaseIterable, Codable, Identifiable {
    case all
    case needsAttention = "needs_attention"
    case localChanges = "local_changes"
    case unsynchronized
    case errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
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

struct RepositoryListPreferences: Codable, Equatable {
    static let currentVersion = 1
    static let defaultValue = RepositoryListPreferences()

    let version: Int
    var searchText: String
    var filter: RepositoryListFilter

    init(
        version: Int = currentVersion,
        searchText: String = "",
        filter: RepositoryListFilter = .all
    ) {
        self.version = version
        self.searchText = searchText
        self.filter = filter
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
        filter: RepositoryListFilter
    ) -> [RepositorySnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = repositories.filter { repository in
            filter.includes(repository)
                && (query.isEmpty
                    || matches(repository.name, query: query)
                    || matches(repository.path, query: query))
        }
        return RepositorySorter.sort(filtered)
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
    static func sort(_ repos: [RepositorySnapshot]) -> [RepositorySnapshot] {
        repos.sorted { lhs, rhs in
            RepositoryDecisionOrdering.precedes(lhs, rhs)
        }
    }
}

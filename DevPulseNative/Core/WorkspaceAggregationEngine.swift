import Foundation

// MARK: - Workspace aggregation

/// Aggregate health and activity metrics across all repositories in a workspace.
/// Each aggregation result supports drill-down to specific repos and raw evidence.

struct WorkspaceAggregation: Codable, Equatable, Sendable {
    let workspaceID: String
    let workspaceName: String
    let computedAt: String  // ISO8601

    // Overall health
    let overallHealth: WorkspaceHealthLevel
    let healthyCount: Int
    let warningCount: Int
    let errorCount: Int

    // Activity
    let totalRepositories: Int
    let activeRepositories: Int  // repos with changes in current scan
    let totalChangedFiles: Int
    let totalCommittedFiles: Int  // staged files
    let totalUncommittedFiles: Int  // unstaged modified/added/deleted
    let totalUntrackedFiles: Int
    let totalConflictedFiles: Int

    // Sync
    let unpushedCommitCount: Int  // sum of aheadCount across repos
    let unpulledCommitCount: Int  // sum of behindCount
    let reposWithUnpushedCommits: Int
    let reposWithUnpulledChanges: Int
    let reposWithoutUpstream: Int

    // Risk
    let highRiskCount: Int
    let mediumRiskCount: Int
    let lowRiskCount: Int

    // Staleness
    let staleRepositoryCount: Int  // repos with no activity in > 7 days
    let unavailableRepositoryCount: Int

    // Errors
    let readErrorCount: Int
    let conflictCount: Int

    // Conflict summary
    let conflictRepositoryNames: [String]

    // Top items for drill-down
    let topChangedRepositories: [RepositoryAggregationSummary]
    let topRiskRepositories: [RepositoryAggregationSummary]
    let staleRepositories: [RepositoryAggregationSummary]
    let errorRepositories: [RepositoryAggregationSummary]

    // All workspace repository summaries (for full drill-down)
    let repositorySummaries: [String: RepositoryAggregationSummary]

    // Cache info
    let isFromCache: Bool
    let computationDurationMs: Double
}

enum WorkspaceHealthLevel: String, Codable, Equatable, Sendable {
    case healthy
    case warning
    case critical
    case unknown

    var displayName: String {
        switch self {
        case .healthy: return "健康"
        case .warning: return "需要注意"
        case .critical: return "需要处理"
        case .unknown: return "未知"
        }
    }

    var systemImage: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: String {
        switch self {
        case .healthy: return "green"
        case .warning: return "orange"
        case .critical: return "red"
        case .unknown: return "gray"
        }
    }
}

struct RepositoryAggregationSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let branch: String
    let status: RepositoryStatus
    let risk: RiskLevel
    let changedFileCount: Int
    let modifiedFileCount: Int
    let addedFileCount: Int
    let deletedFileCount: Int
    let untrackedFileCount: Int
    let stagedFileCount: Int
    let unstagedFileCount: Int
    let conflictedFileCount: Int
    let aheadCount: Int
    let behindCount: Int
    let hasUpstream: Bool?
    let lastActivityAt: String?
    let dataSource: RepositoryDataSource
    let isPinned: Bool
    let workspaceKind: RepositoryWorkspaceKind?
    let commitReadiness: CommitReadinessLevel

    init(from snapshot: RepositorySnapshot) {
        self.id = snapshot.id
        self.name = snapshot.name
        self.path = snapshot.path
        self.branch = snapshot.branch
        self.status = snapshot.status
        self.risk = snapshot.risk
        self.changedFileCount = snapshot.changedFileCount
        self.modifiedFileCount = snapshot.modifiedFileCount
        self.addedFileCount = snapshot.addedFileCount
        self.deletedFileCount = snapshot.deletedFileCount
        self.untrackedFileCount = snapshot.untrackedFileCount
        self.stagedFileCount = snapshot.stagedFileCount ?? 0
        self.unstagedFileCount = snapshot.unstagedFileCount ?? (snapshot.modifiedFileCount + snapshot.addedFileCount + snapshot.deletedFileCount)
        self.conflictedFileCount = snapshot.conflictedFileCount ?? 0
        self.aheadCount = snapshot.aheadCount ?? 0
        self.behindCount = snapshot.behindCount ?? 0
        self.hasUpstream = snapshot.hasUpstream
        self.lastActivityAt = snapshot.lastActivityAt
        self.dataSource = snapshot.resolvedDataSource
        self.isPinned = snapshot.isPinned
        self.workspaceKind = snapshot.workspaceKind
        self.commitReadiness = snapshot.decision.commitReadiness.level
    }
}

// MARK: - Aggregation engine

/// Aggregates workspace-level metrics from repository snapshots.
/// All computation is pure and runs synchronously for predictable
/// performance; callers are responsible for dispatching to background queues.
enum WorkspaceAggregationEngine {

    static let staleThresholdDays: TimeInterval = 7 * 24 * 60 * 60

    /// Compute the full aggregation for one workspace within a repository set.
    static func aggregate(
        workspace: Workspace,
        allRepositories: [RepositorySnapshot],
        now: Date = Date()
    ) -> WorkspaceAggregation {
        let startTime = Date()

        // Filter to the repositories belonging to this workspace
        let workspaceRepos = allRepositories.filter { workspace.repositoryIDs.contains($0.id) }
        let summaries = workspaceRepos.map(RepositoryAggregationSummary.init)
        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })

        // Health counts
        var healthy = 0
        var warnings = 0
        var errors = 0

        for repo in workspaceRepos {
            let decision = repo.decision
            // Conflicts escalate to error level regardless of other signals
            if (repo.conflictedFileCount ?? 0) > 0 {
                errors += 1
            } else {
                switch decision.commitReadiness.level {
                case .ready, .idle:
                    healthy += 1
                case .review, .dirty:
                    warnings += 1
                case .unknown:
                    errors += 1
                }
            }
        }

        // Aggregated counts
        var activeRepos = 0
        var totalChanged = 0
        var totalCommitted = 0
        var totalUncommitted = 0
        var totalUntracked = 0
        var totalConflicted = 0
        var unpushed = 0
        var unpulled = 0
        var reposUnpushed = 0
        var reposUnpulled = 0
        var reposNoUpstream = 0
        var highRisk = 0
        var mediumRisk = 0
        var lowRisk = 0
        var staleCount = 0
        var unavailableCount = 0
        var readErrors = 0
        var conflictRepoNames: [String] = []

        for repo in workspaceRepos {
            if repo.status == .changed { activeRepos += 1 }
            totalChanged += repo.changedFileCount
            totalCommitted += repo.stagedFileCount ?? 0
            let unstaged = repo.unstagedFileCount ?? (repo.modifiedFileCount + repo.addedFileCount + repo.deletedFileCount)
            totalUncommitted += unstaged
            totalUntracked += repo.untrackedFileCount
            totalConflicted += repo.conflictedFileCount ?? 0

            if repo.resolvedDataSource != .current || repo.status == .error {
                unavailableCount += 1
            }

            if repo.resolvedDataSource != .current {
                readErrors += 1
            }

            if let ahead = repo.aheadCount, ahead > 0 {
                unpushed += ahead
                reposUnpushed += 1
            }
            if let behind = repo.behindCount, behind > 0 {
                unpulled += behind
                reposUnpulled += 1
            }
            if repo.hasUpstream == false {
                reposNoUpstream += 1
            }

            switch repo.risk {
            case .high: highRisk += 1
            case .medium: mediumRisk += 1
            case .low: lowRisk += 1
            }

            // Staleness: no activity in 7+ days
            if let lastActivity = repo.lastActivityAt ?? repo.lastChangedAt,
               let activityDate = DateFormatting.date(from: lastActivity) {
                if now.timeIntervalSince(activityDate) > staleThresholdDays {
                    staleCount += 1
                }
            } else if repo.resolvedDataSource == .current {
                // For current repos with no activity timestamp, check lastScanAt
                if let scannedAt = DateFormatting.date(from: repo.lastScannedAt),
                   now.timeIntervalSince(scannedAt) > staleThresholdDays {
                    staleCount += 1
                }
            }

            if (repo.conflictedFileCount ?? 0) > 0 {
                conflictRepoNames.append(repo.name)
            }
        }

        // Sort for top-N drill-down
        let sortedByChanged = summaries
            .filter { $0.changedFileCount > 0 }
            .sorted { $0.changedFileCount > $1.changedFileCount }

        let sortedByRisk = summaries
            .filter { $0.risk == .high }
            .sorted { $0.changedFileCount > $1.changedFileCount }

        let staleRepos = summaries
            .filter { summary in
                staleRepositories(from: workspaceRepos, now: now).contains { $0.id == summary.id }
            }
            .sorted { $0.name < $1.name }

        let errorRepos = summaries
            .filter { $0.dataSource != .current || $0.commitReadiness == .unknown }
            .sorted { $0.name < $1.name }

        let health: WorkspaceHealthLevel
        if errors > 0 {
            health = .critical
        } else if warnings > 0 || activeRepos > 0 {
            health = .warning
        } else if summaries.isEmpty {
            health = .unknown
        } else {
            health = .healthy
        }

        let duration = Date().timeIntervalSince(startTime) * 1000

        return WorkspaceAggregation(
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            computedAt: ISO8601DateFormatter().string(from: now),
            overallHealth: health,
            healthyCount: healthy,
            warningCount: warnings,
            errorCount: errors,
            totalRepositories: workspaceRepos.count,
            activeRepositories: activeRepos,
            totalChangedFiles: totalChanged,
            totalCommittedFiles: totalCommitted,
            totalUncommittedFiles: totalUncommitted,
            totalUntrackedFiles: totalUntracked,
            totalConflictedFiles: totalConflicted,
            unpushedCommitCount: unpushed,
            unpulledCommitCount: unpulled,
            reposWithUnpushedCommits: reposUnpushed,
            reposWithUnpulledChanges: reposUnpulled,
            reposWithoutUpstream: reposNoUpstream,
            highRiskCount: highRisk,
            mediumRiskCount: mediumRisk,
            lowRiskCount: lowRisk,
            staleRepositoryCount: staleCount,
            unavailableRepositoryCount: unavailableCount,
            readErrorCount: readErrors,
            conflictCount: conflictRepoNames.count,
            conflictRepositoryNames: conflictRepoNames,
            topChangedRepositories: Array(sortedByChanged.prefix(5)),
            topRiskRepositories: Array(sortedByRisk.prefix(5)),
            staleRepositories: Array(staleRepos.prefix(10)),
            errorRepositories: Array(errorRepos.prefix(10)),
            repositorySummaries: summaryByID,
            isFromCache: false,
            computationDurationMs: duration
        )
    }

    /// Compute aggregations for ALL workspaces.
    static func aggregateAll(
        workspaces: [Workspace],
        allRepositories: [RepositorySnapshot],
        now: Date = Date()
    ) -> [String: WorkspaceAggregation] {
        var results: [String: WorkspaceAggregation] = [:]
        results.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            results[workspace.id] = aggregate(
                workspace: workspace,
                allRepositories: allRepositories,
                now: now
            )
        }
        return results
    }

    /// Find orphan repositories (not in any workspace).
    static func orphanRepositories(
        workspaces: [Workspace],
        allRepositories: [RepositorySnapshot]
    ) -> [RepositorySnapshot] {
        let groupedIDs = Set(workspaces.flatMap(\.repositoryIDs))
        return allRepositories.filter { !groupedIDs.contains($0.id) }
    }

    private static func staleRepositories(
        from repositories: [RepositorySnapshot],
        now: Date
    ) -> [RepositorySnapshot] {
        repositories.filter { repo in
            if let lastActivity = repo.lastActivityAt ?? repo.lastChangedAt,
               let activityDate = DateFormatting.date(from: lastActivity) {
                return now.timeIntervalSince(activityDate) > staleThresholdDays
            }
            return false
        }
    }
}

// MARK: - Workspace cache

/// Thread-safe cache for workspace aggregations. Runs computation on a
/// background queue and maintains a TTL-based cache.
actor WorkspaceAggregationCache {
    private var cache: [String: WorkspaceAggregation] = [:]
    private var cacheTimestamps: [String: Date] = [:]
    private let cacheTTL: TimeInterval

    init(cacheTTL: TimeInterval = 30.0) {
        self.cacheTTL = cacheTTL
    }

    func get(workspaceID: String, now: Date = Date()) -> WorkspaceAggregation? {
        guard let aggregation = cache[workspaceID],
              let timestamp = cacheTimestamps[workspaceID],
              now.timeIntervalSince(timestamp) < cacheTTL else {
            return nil
        }
        return aggregation
    }

    func set(_ aggregation: WorkspaceAggregation, now: Date = Date()) {
        cache[aggregation.workspaceID] = aggregation
        cacheTimestamps[aggregation.workspaceID] = now
    }

    func invalidate(workspaceID: String? = nil) {
        if let workspaceID {
            cache.removeValue(forKey: workspaceID)
            cacheTimestamps.removeValue(forKey: workspaceID)
        } else {
            cache.removeAll()
            cacheTimestamps.removeAll()
        }
    }

    func getAllValid(now: Date = Date()) -> [String: WorkspaceAggregation] {
        var result: [String: WorkspaceAggregation] = [:]
        for (id, aggregation) in cache {
            if let timestamp = cacheTimestamps[id],
               now.timeIntervalSince(timestamp) < cacheTTL {
                result[id] = aggregation
            }
        }
        return result
    }

    /// Returns a diagnostics description of the cache state.
    func diagnostics() -> WorkspaceCacheDiagnostics {
        WorkspaceCacheDiagnostics(
            cachedCount: cache.count,
            cacheTTLSeconds: cacheTTL,
            oldestTimestamp: cacheTimestamps.values.min(),
            newestTimestamp: cacheTimestamps.values.max()
        )
    }
}

struct WorkspaceCacheDiagnostics: Equatable, Sendable {
    let cachedCount: Int
    let cacheTTLSeconds: TimeInterval
    let oldestTimestamp: Date?
    let newestTimestamp: Date?
}

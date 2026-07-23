import Foundation

// MARK: - Refresh stages

/// Named stages in the unified refresh pipeline, ordered from first to last.
/// Each stage has bounded concurrency, time budget, and progress tracking.
enum RefreshPipelineStage: String, Codable, CaseIterable, Sendable {
    case discovery
    case coreStatus
    case extendedInfo
    case merge
    case persistence
    case widgetSync

    var displayName: String {
        switch self {
        case .discovery: return "发现仓库"
        case .coreStatus: return "读取状态"
        case .extendedInfo: return "扩展信息"
        case .merge: return "合并结果"
        case .persistence: return "持久化"
        case .widgetSync: return "同步 Widget"
        }
    }
}

// MARK: - Stage progress

/// Per-stage progress published during a refresh.
struct RefreshStageProgress: Equatable, Sendable {
    let stage: RefreshPipelineStage
    let completedItems: Int
    let totalItems: Int
    let elapsed: TimeInterval
    let isFinished: Bool

    var fraction: Double {
        guard totalItems > 0 else { return isFinished ? 1 : 0 }
        return min(1, Double(completedItems) / Double(totalItems))
    }
}

/// Full refresh progress, published on each meaningful state change.
struct RefreshProgress: Equatable, Sendable {
    let phases: [RefreshPipelineStage: RefreshStageProgress]
    let overallElapsed: TimeInterval
    let isCancelled: Bool
    let currentStage: RefreshPipelineStage?

    static let initial = RefreshProgress(
        phases: [:],
        overallElapsed: 0,
        isCancelled: false,
        currentStage: nil
    )
}

// MARK: - Priority class

/// Priority class for a repository within the refresh pipeline.
/// Fast/important repos progress first.
enum RepositoryRefreshPriority: Int, Comparable, Sendable {
    case pinned = 0
    case changed = 1
    case clean = 2
    case degraded = 3
    case unknown = 4

    static func < (lhs: RepositoryRefreshPriority, rhs: RepositoryRefreshPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(previous: RepositorySnapshot?) {
        guard let prev = previous else {
            self = .unknown
            return
        }
        if prev.isPinned {
            self = .pinned
        } else {
            switch prev.status {
            case .changed:
                self = .changed
            case .clean:
                self = .clean
            case .error:
                self = .degraded
            default:
                self = .unknown
            }
        }
    }
}

/// Repository entry with priority for the refresh queue.
struct PrioritizedRepository: Sendable {
    let path: String
    let priority: RepositoryRefreshPriority
    let previousSnapshot: RepositorySnapshot?

    init(path: String,
         priority: RepositoryRefreshPriority = .unknown,
         previousSnapshot: RepositorySnapshot? = nil) {
        self.path = path
        self.priority = priority
        self.previousSnapshot = previousSnapshot
    }
}

// MARK: - Stage diagnostics

/// Per-stage diagnostic snapshot.
struct StageDiagnostics: Equatable, Sendable {
    let stage: RefreshPipelineStage
    let elapsed: TimeInterval
    let gitCommandCount: Int
    let gitTimeoutCount: Int
    let gitCancellationCount: Int
    let gitFailureCount: Int
    let repositoriesCompleted: Int
    let repositoriesSkipped: Int
    let snapshotReusedCount: Int
    let peakConcurrency: Int
    let cancelled: Bool
    let timedOut: Bool
    let timeBudgetExhausted: Bool?
    let persistenceError: String?
    let widgetSyncError: String?
}

/// Full refresh diagnostics report.
struct RefreshDiagnostics: Equatable, Sendable {
    let overallElapsed: TimeInterval
    let discoveryElapsed: TimeInterval
    let coreStatusElapsed: TimeInterval
    let extendedInfoElapsed: TimeInterval
    let mergeElapsed: TimeInterval
    let persistenceElapsed: TimeInterval
    let widgetSyncElapsed: TimeInterval
    let totalGitCalls: Int
    let totalGitTimeouts: Int
    let totalGitCancellations: Int
    let totalGitFailures: Int
    let totalRepositoryCount: Int
    let currentRepositoryCount: Int
    let reusedSnapshotCount: Int
    let snapshotReuseRatio: Double
    let peakGitConcurrency: Int
    let cancelled: Bool
    let timedOut: Bool
    let stageDiagnostics: [StageDiagnostics]

    var totalErrors: Int {
        totalGitTimeouts + totalGitCancellations + totalGitFailures
    }
}

// MARK: - Refresh plan

/// Configuration for one refresh execution.
struct RefreshPlan: Sendable {
    let config: ScanConfig
    let roots: [String]
    let rootsSignature: String
    let knownRepositoryPaths: [String]
    let ignoredRepositoryPaths: Set<String>
    let forceRepositoryDiscovery: Bool
    let previousSnapshot: AppGroupData?
    let source: ScanRefreshSource
    let priorityOrder: RepositoryRefreshPriorityOrder

    var taskPriority: TaskPriority { source.taskPriority }
}

enum RepositoryRefreshPriorityOrder: Sendable {
    /// Fast repos first: changed → clean → degraded
    case fastFirst
    /// Preserve existing order
    case original
    /// Pinned before anything else
    case pinnedFirst
}

// MARK: - Refresh cancellation token

/// A refresh-scoped token that signals cancellation and generation changes.
/// Each new scan creates a fresh generation so stale results are discarded.
final class RefreshCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private(set) var generation: UInt64

    init(generation: UInt64 = 0) {
        self.generation = generation
    }

    var isCancelled: Bool {
        lock.withLock { _isCancelled }
    }

    func cancel() {
        lock.withLock { _isCancelled = true }
    }

    func advanceGeneration() -> UInt64 {
        lock.withLock {
            generation &+= 1
            _isCancelled = false
            return generation
        }
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

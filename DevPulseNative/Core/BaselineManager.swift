import Foundation
import OSLog

// MARK: - Baseline manager

/// Manages baseline branch configuration and state for a repository.
///
/// Design:
/// - Per-repository: each repository has its own baseline branch.
/// - User-configurable: the baseline branch can be set by the user.
/// - Graceful degradation: when the baseline is unavailable, the last valid
///   analysis is retained and the state is marked as degraded.
/// - Automatic recovery: when the baseline becomes available again,
///   re-analysis is triggered automatically.
///
/// Thread safety: Uses OSAllocatedUnfairLock for concurrent access.
final class BaselineManager: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "BaselineManager"
    )

    // MARK: - State

    private struct BaselineEntry {
        var branch: String
        var commitID: String?
        var state: BaselineState
    }

    private let lock = OSAllocatedUnfairLock(
        initialState: [String: BaselineEntry]()
    )

    private let gitRunner: GitCommandRunnerType

    typealias GitCommandRunnerType = @Sendable (
        _ arguments: [String],
        _ workingDirectory: String,
        _ timeout: TimeInterval,
        _ outputLimit: Int,
        _ isCancelled: @escaping @Sendable () -> Bool
    ) -> ProcessRunResult

    // MARK: - Initialization

    init(gitRunner: @escaping GitCommandRunnerType) {
        self.gitRunner = gitRunner
    }

    // MARK: - Public API

    /// Set the baseline branch for a repository.
    func setBaseline(for repositoryPath: String, branch: String) -> BaselineState {
        let id = RepositoryIdentity.id(for: repositoryPath)
        let commitID = resolveCommitID(repositoryPath: repositoryPath, ref: branch)

        let state = BaselineState.healthy(branch: branch, commitID: commitID)
        lock.withLock { $0[id] = BaselineEntry(branch: branch, commitID: commitID, state: state) }

        logger.debug("Set baseline for \(repositoryPath) to \(branch) (commit: \(commitID ?? "nil"))")
        return state
    }

    /// Remove the baseline configuration for a repository.
    func clearBaseline(for repositoryPath: String) {
        let id = RepositoryIdentity.id(for: repositoryPath)
        lock.withLock { $0.removeValue(forKey: id) }
        logger.debug("Cleared baseline for \(repositoryPath)")
    }

    /// Get the current baseline state for a repository.
    func baselineState(for repositoryPath: String) -> BaselineState {
        let id = RepositoryIdentity.id(for: repositoryPath)
        return lock.withLock { $0[id]?.state ?? .none() }
    }

    /// Verify the baseline is still valid and update its state.
    /// Returns the current (possibly degraded) state.
    func verifyAndUpdate(
        repositoryPath: String,
        currentBranch: String,
        lastValidAnalysisID: String?,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> BaselineState {
        let id = RepositoryIdentity.id(for: repositoryPath)

        let entry = lock.withLock { $0[id] }
        guard let entry, let baselineBranch = entry.state.baselineBranch else {
            return .none()
        }

        // Check if the baseline branch still exists
        let branchExists = checkBranchExists(
            repositoryPath: repositoryPath,
            branch: baselineBranch,
            isCancelled: isCancelled
        )

        if !branchExists {
            let now = ISO8601DateFormatter().string(from: Date())
            let degradedState = BaselineState(
                baselineBranch: baselineBranch,
                baselineCommitID: entry.commitID,
                baselineExists: false,
                baselineRewritten: false,
                baselineUnavailableSince: now,
                lastValidAnalysisID: lastValidAnalysisID,
                degradedAt: now,
                recoveredAt: nil,
                degradationReason: "基线分支 '\(baselineBranch)' 不存在或已被删除"
            )
            lock.withLock { $0[id] = BaselineEntry(
                branch: entry.branch,
                commitID: entry.commitID,
                state: degradedState
            )}
            logger.warning("Baseline branch '\(baselineBranch)' not found for \(repositoryPath)")
            return degradedState
        }

        // Check if the baseline commit has been rewritten
        let currentCommitID = resolveCommitID(repositoryPath: repositoryPath, ref: baselineBranch)
        if let oldCommitID = entry.commitID, let currentCommitID,
           oldCommitID != currentCommitID, !currentCommitID.isEmpty {
            // Branch was rewritten (force push, rebase)
            let now = ISO8601DateFormatter().string(from: Date())
            let degradedState = BaselineState(
                baselineBranch: baselineBranch,
                baselineCommitID: currentCommitID,
                baselineExists: true,
                baselineRewritten: true,
                baselineUnavailableSince: now,
                lastValidAnalysisID: lastValidAnalysisID,
                degradedAt: now,
                recoveredAt: nil,
                degradationReason: "基线分支 '\(baselineBranch)' 已被改写（提交从 \(oldCommitID.prefix(8)) 变为 \(currentCommitID.prefix(8))）"
            )
            lock.withLock { $0[id] = BaselineEntry(
                branch: entry.branch,
                commitID: currentCommitID,
                state: degradedState
            )}
            logger.warning("Baseline '\(baselineBranch)' was rewritten for \(repositoryPath)")
            return degradedState
        }

        // Baseline is healthy — check if recovering from degradation
        let oldState = entry.state
        if oldState.isDegraded {
            let now = ISO8601DateFormatter().string(from: Date())
            let healthyState = BaselineState(
                baselineBranch: baselineBranch,
                baselineCommitID: currentCommitID ?? entry.commitID,
                baselineExists: true,
                baselineRewritten: false,
                baselineUnavailableSince: oldState.baselineUnavailableSince,
                lastValidAnalysisID: oldState.lastValidAnalysisID,
                degradedAt: oldState.degradedAt,
                recoveredAt: now,
                degradationReason: oldState.degradationReason
            )
            lock.withLock { $0[id] = BaselineEntry(
                branch: entry.branch,
                commitID: currentCommitID ?? entry.commitID,
                state: healthyState
            )}
            logger.info("Baseline '\(baselineBranch)' recovered for \(repositoryPath)")
            return healthyState
        }

        return entry.state
    }

    /// Check if a repository has a configured baseline.
    func hasBaseline(for repositoryPath: String) -> Bool {
        let id = RepositoryIdentity.id(for: repositoryPath)
        return lock.withLock { $0[id]?.state.baselineBranch != nil }
    }

    /// Get the baseline branch name for a repository.
    func baselineBranch(for repositoryPath: String) -> String? {
        let id = RepositoryIdentity.id(for: repositoryPath)
        return lock.withLock { $0[id]?.state.baselineBranch }
    }

    // MARK: - Private helpers

    private func resolveCommitID(repositoryPath: String, ref: String) -> String? {
        let result = gitRunner(
            ["rev-parse", "--verify", ref],
            repositoryPath,
            3.0,
            1024,
            { false }
        )

        guard case .success(let output) = result else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func checkBranchExists(
        repositoryPath: String,
        branch: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        guard !isCancelled() else { return false }

        let result = gitRunner(
            ["rev-parse", "--verify", "refs/heads/\(branch)"],
            repositoryPath,
            3.0,
            1024,
            isCancelled
        )

        if case .success = result { return true }
        return false
    }
}

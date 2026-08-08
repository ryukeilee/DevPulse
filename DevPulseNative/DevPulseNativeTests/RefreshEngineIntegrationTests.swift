import Foundation
import Testing
@testable import DevPulse

// MARK: - Mock Git Command Runner

private final class MockGitCommandRunner: @unchecked Sendable {
    private let lock = NSLock()

    struct Call: Sendable, Equatable {
        let arguments: [String]
        let workingDirectory: String
    }

    private var _statusResults: [String: ProcessRunResult] = [:]
    private var _logResults: [String: ProcessRunResult] = [:]
    private var _defaultStatusResult: ProcessRunResult = .success(output: MockGitCommandRunner.cleanStatusOutput())
    private var _defaultLogResult: ProcessRunResult = .success(output: MockGitCommandRunner.defaultLogOutput())
    private var _delay: TimeInterval = 0
    private var _pollingPaths: Set<String> = []
    private var _pollingLogPaths: Set<String> = []
    private var _calls: [Call] = []
    private var _activeCount = 0
    private var _peakActive = 0

    var calls: [Call] { lock.withLock { _calls } }
    var peakActive: Int { lock.withLock { _peakActive } }

    var statusCallCount: Int {
        lock.withLock { _calls.filter { $0.arguments.first == "status" }.count }
    }

    var logCallCount: Int {
        lock.withLock { _calls.filter { $0.arguments.first == "log" }.count }
    }

    func setStatusResult(_ result: ProcessRunResult, for path: String) {
        lock.withLock { _statusResults[path] = result }
    }

    func setLogResult(_ result: ProcessRunResult, for path: String) {
        lock.withLock { _logResults[path] = result }
    }

    /// Add a uniform delay to every git command invocation.
    func setDelay(_ delay: TimeInterval) {
        lock.withLock { _delay = delay }
    }

    /// Mark a path so its git command polls `isCancelled` in a tight loop,
    /// returning `.cancelled` once the flag is raised.
    func setPollingPath(_ path: String) {
        lock.withLock { _pollingPaths.insert(path) }
    }

    /// Mark only the `git log` command for a path as polling cancellation.
    func setPollingLogPath(_ path: String) {
        lock.withLock { _pollingLogPaths.insert(path) }
    }

    /// Create the GitCommandRunner closure. The captured `mock` reference
    /// is safe because `MockGitCommandRunner` is `@unchecked Sendable`.
    nonisolated func runner() -> RefreshEngine.GitCommandRunner {
        { [mock = self] arguments, workingDirectory, _, _, isCancelled in
            guard !isCancelled() else { return .cancelled }

            let isStatus = arguments.first == "status"

            mock.lock.lock()
            mock._calls.append(Call(arguments: arguments, workingDirectory: workingDirectory))
            mock._activeCount += 1
            mock._peakActive = max(mock._peakActive, mock._activeCount)
            let delay = mock._delay
            let isPolling = mock._pollingPaths.contains(workingDirectory)
                || (!isStatus && mock._pollingLogPaths.contains(workingDirectory))
            let result: ProcessRunResult = isStatus
                ? (mock._statusResults[workingDirectory] ?? mock._defaultStatusResult)
                : (mock._logResults[workingDirectory] ?? mock._defaultLogResult)
            mock.lock.unlock()

            if isPolling {
                // Poll cancellation every 10 ms.
                for _ in 0..<2000 {
                    if isCancelled() {
                        mock.lock.lock()
                        mock._activeCount -= 1
                        mock.lock.unlock()
                        return .cancelled
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }

            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }

            guard !isCancelled() else {
                mock.lock.lock()
                mock._activeCount -= 1
                mock.lock.unlock()
                return .cancelled
            }

            mock.lock.lock()
            mock._activeCount -= 1
            mock.lock.unlock()

            return result
        }
    }

    // MARK: - Default output templates

    static func cleanStatusOutput(branch: String = "main", oid: String = "abc123def4567890") -> String {
        """
        # branch.oid \(oid)
        # branch.head \(branch)
        # branch.upstream origin/\(branch)
        # branch.ab +0 -0
        """
    }

    static func changedStatusOutput(
        files: [String] = ["file.txt"],
        branch: String = "main",
        oid: String = "def456abc1237890"
    ) -> String {
        let entries = files.map { "1 M. N... 100644 100644 100644 a b \($0)" }
            .joined(separator: "\n")
        return """
        # branch.oid \(oid)
        # branch.head \(branch)
        # branch.upstream origin/\(branch)
        # branch.ab +1 -0
        \(entries)
        """
    }

    static func defaultLogOutput(commitID: String = "abc123def4567890", summary: String = "Test commit") -> String {
        "\(commitID)\0\(ISO8601DateFormatter().string(from: Date()))\0\(summary)"
    }
}

// MARK: - Error type

private func isGitWorktreeAvailable(at url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["worktree", "list"]
        process.currentDirectoryURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private enum TestError: Error {
    case gitFailed([String], String)
}

// MARK: - Suite

@Suite(.serialized)
struct RefreshEngineIntegrationTests {

    // MARK: - Helpers

    private func createTempGitRepo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: url)
        try runGit(["config", "user.name", "DevPulse Tests"], in: url)
        try runGit(["config", "user.email", "devpulse-tests@example.com"], in: url)
        try "initial\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], in: url)
        try runGit(["commit", "-q", "-m", "Initial commit"], in: url)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw TestError.gitFailed(arguments, output)
        }
        return String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func scanConfig(
        maxConcurrent: Int = 3,
        commandTimeout: TimeInterval = 2,
        scanTimeout: TimeInterval = 30
    ) -> ScanConfig {
        ScanConfig(
            enabledBuiltInPaths: [],
            customPaths: [],
            maxDepth: 2,
            changedPreviewLimit: 5,
            maxConcurrentGitOps: maxConcurrent,
            gitCommandTimeout: commandTimeout,
            scanTimeout: scanTimeout,
            slowReposkipSeconds: 60,
            activeRepoThreshold: 30
        )
    }

    private func reposRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-refresh-\(name)-\(UUID().uuidString)")
    }

    // MARK: - 1. Basic Execution

    @Test func basicExecution() async throws {
        let root = reposRoot("basic")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<2).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()

        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            source: .manual,
            gitCommandRunner: mock.runner()
        )

        #expect(result.isCancelled == false)
        #expect(result.timedOut == false)
        #expect(result.data.repositories.count == 2)
        #expect(result.data.repositories.allSatisfy { $0.status == .clean })
        #expect(result.diagnostics.totalRepositoryCount == 2)
        #expect(result.diagnostics.discoveryElapsed > 0)
        #expect(result.diagnostics.coreStatusElapsed > 0)
        #expect(result.diagnostics.totalGitCalls >= 4)
        // 2 status + 2 log calls
        #expect(mock.statusCallCount == 2)
        #expect(mock.logCallCount == 2)
    }

    // MARK: - 2. Cancellation During Core Status

    @Test func cancellationDuringCoreStatus() async throws {
        let root = reposRoot("cancellation")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<4).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()
        // repo-2 and repo-3 will poll cancellation
        let repo2Canon = RepositoryIdentity.canonicalPath(repoURLs[2].path)
        let repo3Canon = RepositoryIdentity.canonicalPath(repoURLs[3].path)
        mock.setPollingPath(repo2Canon)
        mock.setPollingPath(repo3Canon)

        let engine = RefreshEngine()

        let executeTask = Task {
            await engine.execute(
                config: scanConfig(maxConcurrent: 2, commandTimeout: 5, scanTimeout: 60),
                scanRoots: [root.path],
                forceRepositoryDiscovery: true,
                source: .manual,
                gitCommandRunner: mock.runner()
            )
        }

        // Let discovery complete and the first batch of status calls begin
        try? await Task.sleep(for: .milliseconds(300))

        await engine.cancel()

        let result = await executeTask.value

        #expect(result.isCancelled)
        // At least some repos should have been processed before cancellation
        #expect(result.data.repositories.count >= 1)
        #expect(result.data.repositories.count <= 4)
        // The first two repos (processed before polling blocks) should be present
        #expect(mock.statusCallCount >= 2)
    }

    // MARK: - 3. Priority Ordering

    @Test func priorityOrdering() async throws {
        let root = reposRoot("priority")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<3).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        // Create a previous snapshot that defines priorities:
        //   repo-0 → pinned
        //   repo-1 → changed
        //   repo-2 → clean
        //
        // The last-successful-scan timestamp must lie in the past: the fast
        // filesystem skip compares .git/HEAD and .git/index mtimes against it
        // with a strict `<`. A "now" timestamp can straddle a second boundary
        // under load, flipping the comparison and skipping repos that this
        // test must observe in priority order.
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let repoSnapshots: [RepositorySnapshot] = try repoURLs.enumerated().map { (i, url) in
            let canonPath = RepositoryIdentity.canonicalPath(url.path)
            let id = RepositoryIdentity.id(for: canonPath)
            return RepositorySnapshot(
                id: id,
                name: "repo-\(i)",
                path: canonPath,
                branch: "main",
                status: i == 1 ? .changed : .clean,
                modifiedFileCount: i == 1 ? 1 : 0,
                addedFileCount: 0,
                deletedFileCount: 0,
                untrackedFileCount: 0,
                stagedFileCount: i == 1 ? 1 : 0,
                unstagedFileCount: 0,
                conflictedFileCount: nil,
                aheadCount: i == 1 ? 1 : nil,
                hasUpstream: true,
                changedFileCount: i == 1 ? 1 : 0,
                changedFilesPreview: i == 1 ? ["README.md"] : [],
                risk: .low,
                lastScannedAt: timestamp,
                lastChangedAt: timestamp,
                errorMessage: nil,
                isPinned: i == 0
            )
        }

        let previousSnapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: nil,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary.build(from: repoSnapshots),
            repositories: repoSnapshots,
            storageRevision: 0,
            persistenceState: .committed
        )

        let mock = MockGitCommandRunner()

        let engine = RefreshEngine()
        _ = await engine.execute(
            config: scanConfig(maxConcurrent: 1), // serial → deterministic ordering
            scanRoots: [root.path],
            knownRepositoryPaths: repoSnapshots.map(\.path),
            forceRepositoryDiscovery: false,
            previousSnapshot: previousSnapshot,
            source: .manual, // enables fast-first priority ordering
            gitCommandRunner: mock.runner()
        )

        let statusPaths = mock.calls
            .filter { $0.arguments.first == "status" }
            .map { $0.workingDirectory }

        // Freshly-created repos have HEAD/index mtimes equal to last scan time, so the
        // fast filesystem skip (< strict comparison) does not apply here.
        // All 3 repos are read in priority order.
        #expect(statusPaths.count == 3, "Expected 3 status calls, got \(statusPaths.count)")

        if statusPaths.count == 3 {
            // pinned (repo-0) first, changed (repo-1) second, clean (repo-2) third
            #expect(statusPaths[0].hasSuffix("/repo-0"), "Expected pinned repo first, got \(statusPaths[0])")
            #expect(statusPaths[1].hasSuffix("/repo-1"), "Expected changed repo second, got \(statusPaths[1])")
            #expect(statusPaths[2].hasSuffix("/repo-2"), "Expected clean repo third, got \(statusPaths[2])")
        }
    }

    // MARK: - 4. Bounded Concurrency

    @Test func boundedConcurrency() async throws {
        let root = reposRoot("bounded")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<6).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()
        mock.setDelay(0.05) // 50 ms per call → enough to observe concurrency

        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(maxConcurrent: 3, commandTimeout: 5),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            source: .manual,
            gitCommandRunner: mock.runner()
        )

        #expect(result.isCancelled == false)
        #expect(result.data.repositories.count == 6)
        #expect(mock.peakActive <= 3, "Peak concurrency \(mock.peakActive) exceeded limit 3")
        #expect(mock.statusCallCount == 6)
    }

    // MARK: - 5. Individual Repo Timeout

    @Test func individualRepoTimeout() async throws {
        let root = reposRoot("timeout")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<3).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()
        let repo2Canon = RepositoryIdentity.canonicalPath(repoURLs[2].path)
        mock.setStatusResult(.timeout, for: repo2Canon)

        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(maxConcurrent: 2, commandTimeout: 1),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            source: .manual,
            gitCommandRunner: mock.runner()
        )

        #expect(result.isCancelled == false)
        #expect(result.data.repositories.count == 3)

        let errorRepos = result.data.repositories.filter { $0.status == .error }
        #expect(errorRepos.count == 1)
        #expect(errorRepos[0].path == repo2Canon)

        let cleanRepos = result.data.repositories.filter { $0.status == .clean }
        #expect(cleanRepos.count == 2)

        #expect(result.diagnostics.totalGitTimeouts >= 1)
    }

    // MARK: - 6. Partial Failure

    @Test func partialFailure() async throws {
        let root = reposRoot("failure")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<4).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()

        let repo0Canon = RepositoryIdentity.canonicalPath(repoURLs[0].path)
        let repo1Canon = RepositoryIdentity.canonicalPath(repoURLs[1].path)
        let repo2Canon = RepositoryIdentity.canonicalPath(repoURLs[2].path)

        mock.setStatusResult(.timeout, for: repo0Canon)
        mock.setStatusResult(.nonZero(exitCode: 128), for: repo1Canon)
        mock.setStatusResult(.outputLimit, for: repo2Canon)
        // repo-3 uses the default success result

        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(maxConcurrent: 2),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            source: .manual,
            gitCommandRunner: mock.runner()
        )

        #expect(result.isCancelled == false)
        #expect(result.data.repositories.count == 4)

        let errorCount = result.data.repositories.filter { $0.status == .error }.count
        #expect(errorCount == 3)

        let cleanCount = result.data.repositories.filter { $0.status == .clean }.count
        #expect(cleanCount == 1)

        #expect(result.diagnostics.totalGitTimeouts >= 1)
        #expect(result.diagnostics.totalGitFailures >= 1)
    }

    // MARK: - 7. Progress Stream

    @Test func progressStream() async throws {
        let root = reposRoot("progress")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<2).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()

        let engine = RefreshEngine()

        let progressTask = Task {
            var events: [RefreshProgress] = []
            for await progress in await engine.progress {
                events.append(progress)
            }
            return events
        }

        _ = await engine.execute(
            config: scanConfig(),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            source: .manual,
            gitCommandRunner: mock.runner()
        )

        let events = await progressTask.value

        #expect(!events.isEmpty, "Should have received at least one progress event")

        let allStages = Set(events.flatMap { $0.phases.keys })
        #expect(allStages.contains(.discovery))
        #expect(allStages.contains(.coreStatus))
        #expect(allStages.contains(.extendedInfo))
        #expect(allStages.contains(.merge))
        #expect(allStages.contains(.persistence))
        #expect(allStages.contains(.widgetSync))

        // The final coreStatus progress should show 2/2 items
        let coreProgress = events.compactMap { $0.phases[.coreStatus] }.last
        #expect(coreProgress?.completedItems == 2)
        #expect(coreProgress?.totalItems == 2)
        #expect(coreProgress?.isFinished == true)

        // The final merge progress should show 2/2 items
        let mergeProgress = events.compactMap { $0.phases[.merge] }.last
        #expect(mergeProgress?.completedItems == 2)
        #expect(mergeProgress?.isFinished == true)
    }

    // MARK: - 8. Diagnostics Report

    @Test func diagnosticsReport() async throws {
        let root = reposRoot("diagnostics")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<3).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()

        let repo0Canon = RepositoryIdentity.canonicalPath(repoURLs[0].path)
        mock.setStatusResult(.timeout, for: repo0Canon)

        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(maxConcurrent: 2),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            source: .manual,
            gitCommandRunner: mock.runner()
        )

        let diag = result.diagnostics

        // Top-level summary
        #expect(diag.totalRepositoryCount == 3)
        #expect(diag.currentRepositoryCount >= 2)
        #expect(diag.totalGitCalls >= 3) // at least 3 status calls
        #expect(diag.totalGitTimeouts >= 1)
        #expect(diag.overallElapsed > 0)
        #expect(diag.cancelled == false)
        #expect(diag.timedOut == false)

        // Per-stage diagnostics
        #expect(diag.stageDiagnostics.count == RefreshPipelineStage.allCases.count)

        let coreStage = diag.stageDiagnostics.first { $0.stage == .coreStatus }
        #expect(coreStage != nil)
        #expect(coreStage!.gitTimeoutCount >= 1)
        #expect(coreStage!.repositoriesCompleted == 3)
        #expect(coreStage!.gitCommandCount == 3)

        let extStage = diag.stageDiagnostics.first { $0.stage == .extendedInfo }
        #expect(extStage != nil)
        // Only successfully scanned repos reach extended info
        #expect(extStage!.repositoriesCompleted == 2)
    }

    // MARK: - 9. Snapshot consistency across views

    @Test func snapshotConsistencyAcrossViews() async throws {
        let root = reposRoot("consistency")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<3).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()
        let repo1Canon = RepositoryIdentity.canonicalPath(repoURLs[1].path)
        let repo2Canon = RepositoryIdentity.canonicalPath(repoURLs[2].path)
        mock.setStatusResult(.success(output: MockGitCommandRunner.changedStatusOutput()), for: repo1Canon)
        mock.setStatusResult(.timeout, for: repo2Canon)

        let previousTimestamp = "2026-07-23T00:00:00Z"
        let previousSnapshot = AppGroupData.empty().withLastSuccessfulRefreshAt(previousTimestamp)

        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(),
            scanRoots: [root.path],
            knownRepositoryPaths: repoURLs.map { RepositoryIdentity.canonicalPath($0.path) },
            forceRepositoryDiscovery: false,
            previousSnapshot: previousSnapshot,
            source: .manual,
            gitCommandRunner: mock.runner()
        )

        let summary = result.data.scanSummary
        #expect(summary.totalRepositories == result.data.repositories.count)
        #expect(summary.totalRepositories == 3)
        #expect(summary.changedRepositories == 1)
        #expect(summary.errorRepositories == 1)

        let changedRepo = result.data.repositories.first { $0.status == .changed }
        #expect(changedRepo != nil)
        #expect(summary.totalChangedFiles == changedRepo?.changedFileCount ?? 0)

        for repo in result.data.repositories {
            #expect(repo.changeCounts.total == repo.changedFileCount, "Mismatch for \(repo.name)")
        }

        #expect(result.data.lastSuccessfulRefreshAt == previousTimestamp)
    }

    // MARK: - 10. Linked worktree discovery

    @Test func linkedWorktreeDiscovery() async throws {
        let root = reposRoot("worktree")
        defer { try? FileManager.default.removeItem(at: root) }

        let mainRepo = root.appendingPathComponent("main")
        try createTempGitRepo(at: mainRepo)

        guard isGitWorktreeAvailable(at: mainRepo) else { return }

        let branchName = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: mainRepo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Create a new branch for the worktree (cannot share the same branch)
        let worktreeBranch = "worktree-feature"
        try runGit(["branch", worktreeBranch], in: mainRepo)
        let worktreePath = root.appendingPathComponent("linked")
        try runGit(["worktree", "add", worktreePath.path, worktreeBranch], in: mainRepo)

        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            source: .manual
        )

        #expect(result.data.repositories.count == 2)

        let mainPath = RepositoryIdentity.canonicalPath(mainRepo.path)
        let linkedPath = RepositoryIdentity.canonicalPath(worktreePath.path)

        let mainRepoResult = result.data.repositories.first { $0.path == mainPath }
        let linkedRepoResult = result.data.repositories.first { $0.path == linkedPath }

        #expect(mainRepoResult != nil)
        #expect(linkedRepoResult != nil)
        #expect(mainRepoResult?.workspaceKind == .mainWorktree)
        #expect(linkedRepoResult?.workspaceKind == .linkedWorktree)
    }

    // MARK: - 11. Dirty workspace detection

    @Test func dirtyWorkspaceDetection() async throws {
        let root = reposRoot("dirty")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("repo")
        try createTempGitRepo(at: repoURL)

        let stagedFile = repoURL.appendingPathComponent("staged.txt")
        try "staged content".write(to: stagedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "staged.txt"], in: repoURL)

        try "unstaged content".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            source: .manual
        )

        #expect(result.data.repositories.count == 1)
        let repo = try #require(result.data.repositories.first)
        #expect(repo.status == .changed)
        #expect((repo.stagedFileCount ?? 0) > 0)
        #expect((repo.unstagedFileCount ?? 0) > 0)
    }

    // MARK: - 12. No upstream repository

    @Test func noUpstreamRepository() async throws {
        let root = reposRoot("no-upstream")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("repo")
        try createTempGitRepo(at: repoURL)

        // Remove any default remote so there is no upstream
        try? runGit(["remote", "remove", "origin"], in: repoURL)

        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            source: .manual
        )

        #expect(result.data.repositories.count == 1)
        let repo = try #require(result.data.repositories.first)
        #expect(repo.hasUpstream == false)
        #expect(repo.aheadCount == nil)
        #expect(repo.behindCount == nil)
    }

    // MARK: - 13. Per-stage time budget exhaustion

    // MARK: - 12. Cancelled scan does not produce isRefreshing snapshot

    @Test func cancelledScanIsRefreshingNil() async throws {
        let root = reposRoot("cancel-isrefreshing")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<2).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()
        // Make repos 1 poll cancellation so we can cancel mid-scan
        let repo1Canon = RepositoryIdentity.canonicalPath(repoURLs[1].path)
        mock.setPollingPath(repo1Canon)

        let engine = RefreshEngine()
        let executeTask = Task {
            await engine.execute(
                config: scanConfig(maxConcurrent: 2, commandTimeout: 5, scanTimeout: 30),
                scanRoots: [root.path],
                knownRepositoryPaths: repoURLs.map { RepositoryIdentity.canonicalPath($0.path) },
                forceRepositoryDiscovery: false,
                source: .manual,
                gitCommandRunner: mock.runner()
            )
        }

        // Let discovery complete and the first status calls begin
        try? await Task.sleep(for: .milliseconds(300))
        await engine.cancel()

        let result = await executeTask.value

        #expect(result.isCancelled)
        // The cancelled result's data should NOT have isRefreshing == true
        // (it defaults to nil from previousSnapshot?.isRefreshing which is nil)
        #expect(result.data.isRefreshing == nil || result.data.isRefreshing == false)
    }

    // MARK: - 13. Failed scan leaves isRefreshing nil in fallback snapshot

    @Test func failedScanIsRefreshingNil() async throws {
        let root = reposRoot("fail-isrefreshing")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<2).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()
        // All repos time out -> complete failure
        for url in repoURLs {
            let canonical = RepositoryIdentity.canonicalPath(url.path)
            mock.setStatusResult(.timeout, for: canonical)
        }

        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(maxConcurrent: 2, commandTimeout: 1, scanTimeout: 10),
            scanRoots: [root.path],
            knownRepositoryPaths: repoURLs.map { RepositoryIdentity.canonicalPath($0.path) },
            forceRepositoryDiscovery: false,
            source: .manual,
            gitCommandRunner: mock.runner()
        )

        #expect(result.data.isRefreshing == nil || result.data.isRefreshing == false)
        // Result data should still have entries with error status
        #expect(result.data.repositories.allSatisfy { $0.status == .error || $0.errorMessage != nil })
    }

    // MARK: - 14. Multiple successive cancellations produce clean final state

    @Test func multipleCancellationsIsRefreshingNil() async throws {
        let root = reposRoot("multi-cancel")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<3).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()
        // Both slow repos to ensure we can cancel mid-scan
        for url in repoURLs {
            let canonical = RepositoryIdentity.canonicalPath(url.path)
            mock.setPollingPath(canonical)
        }

        // First engine: cancelled immediately
        let engine1 = RefreshEngine()
        let task1 = Task {
            await engine1.execute(
                config: scanConfig(maxConcurrent: 2, commandTimeout: 5, scanTimeout: 30),
                scanRoots: [root.path],
                knownRepositoryPaths: repoURLs.map { RepositoryIdentity.canonicalPath($0.path) },
                forceRepositoryDiscovery: false,
                source: .manual,
                gitCommandRunner: mock.runner()
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        await engine1.cancel()
        let result1 = await task1.value
        #expect(result1.isCancelled)
        #expect(result1.data.isRefreshing == nil || result1.data.isRefreshing == false)

        // Second engine: cancelled after partial progress
        let mock2 = MockGitCommandRunner()
        for url in repoURLs {
            let canonical = RepositoryIdentity.canonicalPath(url.path)
            mock2.setPollingPath(canonical)
        }
        let engine2 = RefreshEngine()
        let task2 = Task {
            await engine2.execute(
                config: scanConfig(maxConcurrent: 2, commandTimeout: 5, scanTimeout: 30),
                scanRoots: [root.path],
                knownRepositoryPaths: repoURLs.map { RepositoryIdentity.canonicalPath($0.path) },
                forceRepositoryDiscovery: false,
                previousSnapshot: result1.data,
                source: .manual,
                gitCommandRunner: mock2.runner()
            )
        }
        try? await Task.sleep(for: .milliseconds(500))
        await engine2.cancel()
        let result2 = await task2.value
        #expect(result2.isCancelled)
        #expect(result2.data.isRefreshing == nil || result2.data.isRefreshing == false)
    }

    // MARK: - 15. Successful scan carries isRefreshing from previous snapshot

    @Test func successfulScanPreservesPreviousIsRefreshing() async throws {
        let root = reposRoot("success-isrefreshing")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<2).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()
        let engine = RefreshEngine()

        // Previous snapshot had isRefreshing: true
        let previous = AppGroupData.empty().withIsRefreshing(true)

        let result = await engine.execute(
            config: scanConfig(),
            scanRoots: [root.path],
            knownRepositoryPaths: repoURLs.map { RepositoryIdentity.canonicalPath($0.path) },
            forceRepositoryDiscovery: false,
            previousSnapshot: previous,
            source: .manual,
            gitCommandRunner: mock.runner()
        )

        #expect(result.isCancelled == false)
        #expect(result.data.repositories.count == 2)
        // The engine always sets isRefreshing to false in its output to
        // prevent stale "refreshing" flags from reaching the Widget.
        #expect(result.data.isRefreshing == false)
    }

    @Test func perStageTimeBudgetExhaustion() async throws {
        let root = reposRoot("budget")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<5).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let mock = MockGitCommandRunner()
        mock.setDelay(0.4)

        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(maxConcurrent: 1, commandTimeout: 0.3, scanTimeout: 0.8),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            source: .manual,
            gitCommandRunner: mock.runner()
        )

        let coreDiag = result.diagnostics.stageDiagnostics.first { $0.stage == .coreStatus }
        #expect(coreDiag != nil)
        // Budget exhaustion limited core status to fewer than 5 repos
        #expect(coreDiag!.repositoriesCompleted < 5)
        #expect(coreDiag!.repositoriesCompleted >= 1)
        #expect(coreDiag!.gitCommandCount >= coreDiag!.repositoriesCompleted)
        #expect(coreDiag!.elapsed > 0)

        // Extended info either reused or processed same/less than core status
        let extDiag = result.diagnostics.stageDiagnostics.first { $0.stage == .extendedInfo }
        #expect(extDiag != nil)
        #expect(extDiag!.repositoriesCompleted <= coreDiag!.repositoriesCompleted)

        // Every discovered path remains represented. Work that missed the
        // stage budget is explicitly degraded instead of silently disappearing.
        #expect(result.data.repositories.count == 5)
        #expect(result.data.repositories.contains { $0.status == .error })
        #expect(Set(result.data.repositories.map(\.path)).count == 5)
    }

    // MARK: - 17. Serial full scan reads every repository

    /// Every repository executes a status command even when a previous clean
    /// snapshot exists, and serial scheduling must retain the complete batch.
    @Test func serialFullScanReadsEveryRepository() async throws {
        let root = reposRoot("skip-batch")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<3).map { i in
            let url = root.appendingPathComponent("repo-\(i)")
            try createTempGitRepo(at: url)
            return url
        }

        let formatter = ISO8601DateFormatter()
        // repo-0 is pinned, so it always sorts first in priority order.
        let repoSnapshots: [RepositorySnapshot] = try repoURLs.enumerated().map { (i, url) in
            let canonPath = RepositoryIdentity.canonicalPath(url.path)
            let id = RepositoryIdentity.id(for: canonPath)
            let scannedAt = i == 0
                ? formatter.string(from: Date().addingTimeInterval(3600))
                : formatter.string(from: Date().addingTimeInterval(-3600))
            return RepositorySnapshot(
                id: id,
                name: "repo-\(i)",
                path: canonPath,
                branch: "main",
                status: .clean,
                modifiedFileCount: 0,
                addedFileCount: 0,
                deletedFileCount: 0,
                untrackedFileCount: 0,
                stagedFileCount: 0,
                unstagedFileCount: 0,
                conflictedFileCount: nil,
                aheadCount: nil,
                hasUpstream: true,
                changedFileCount: 0,
                changedFilesPreview: [],
                risk: .low,
                lastScannedAt: scannedAt,
                lastChangedAt: scannedAt,
                errorMessage: nil,
                isPinned: i == 0
            )
        }

        let previousSnapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: formatter.string(from: Date()),
            writtenAt: nil,
            lastSuccessfulRefreshAt: formatter.string(from: Date()),
            scanSummary: ScanSummary.build(from: repoSnapshots),
            repositories: repoSnapshots,
            storageRevision: 0,
            persistenceState: .committed
        )

        let mock = MockGitCommandRunner()
        let engine = RefreshEngine()
        let result = await engine.execute(
            config: scanConfig(maxConcurrent: 1), // serial → deterministic ordering
            scanRoots: [root.path],
            knownRepositoryPaths: repoSnapshots.map(\.path),
            forceRepositoryDiscovery: false,
            previousSnapshot: previousSnapshot,
            source: .manual,
            gitCommandRunner: mock.runner()
        )

        let statusPaths = mock.calls
            .filter { $0.arguments.first == "status" }
            .map { $0.workingDirectory }

        #expect(statusPaths.count == 3, "Expected 3 status calls, got \(statusPaths.count)")
        #expect(result.data.repositories.count == 3, "Expected all 3 repos retained, got \(result.data.repositories.count)")
        #expect(result.data.repositories.allSatisfy { $0.resolvedDataSource == .current })
    }
}

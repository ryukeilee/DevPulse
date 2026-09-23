import Foundation
import Testing
@testable import DevPulse

private final class GitCallLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []

    func record(_ arguments: [String]) {
        lock.lock()
        stored.append(arguments)
        lock.unlock()
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite(.serialized)
struct DiscoveryGitCallAccountingTests {
    private enum RepoError: Error { case git([String], String) }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RepoError.git(arguments, String(decoding: errorData, as: UTF8.self))
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    private func makeRepository(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try git(["init", "-q"], in: path)
        try git(["config", "user.name", "DevPulse Tests"], in: path)
        try git(["config", "user.email", "devpulse-tests@example.com"], in: path)
        try "tracked\n".write(to: path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "README.md"], in: path)
        try git(["commit", "-q", "-m", "initial"], in: path)
    }

    @Test func refreshDiagnosticsMatchRealGitRunnerCallsIncludingWorktreeTopology() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-git-accounting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let main = root.appendingPathComponent("main")
        let linked = root.appendingPathComponent("linked")
        try makeRepository(main)
        try git(["worktree", "add", "-q", "-b", "linked-branch", linked.path], in: main)

        let ledger = GitCallLedger()
        let actualRunner: RefreshEngine.GitCommandRunner = { arguments, directory, timeout, limit, cancelled in
            ledger.record(arguments)
            return GitRepositoryScanner.defaultGitCommandRunner(
                arguments, directory, timeout, limit, cancelled
            )
        }
        let observationURL = root.appendingPathComponent("observations.json")
        let engine = RefreshEngine(observationStoreOverride: RefreshObservationStore(fileURL: observationURL))
        let result = await engine.execute(
            config: ScanConfig(
                enabledBuiltInPaths: [], customPaths: [], maxDepth: 2,
                changedPreviewLimit: 5, maxConcurrentGitOps: 2,
                gitCommandTimeout: 5, scanTimeout: 60,
                slowReposkipSeconds: 60, activeRepoThreshold: 30
            ),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            gitCommandRunner: actualRunner
        )

        let calls = ledger.calls
        let statusCalls = calls.filter { $0.first == "status" }.count
        let logCalls = calls.filter { $0.first == "log" }.count
        let discoveryCalls = calls.filter { $0.first != "status" && $0.first != "log" }.count
        let total = statusCalls + logCalls + discoveryCalls
        let commandList = calls.map { $0.joined(separator: " ") }
        let evidence: [String: Any] = [
            "diagnostics_totalGitCalls": result.diagnostics.totalGitCalls,
            "a_core_gitStatusCount": statusCalls,
            "b_extended_completed": logCalls,
            "c_discovery_gitCommandCount": discoveryCalls,
            "a_plus_b_plus_c": total,
            "independent_runner_call_count": calls.count,
            "commands": commandList,
            "discovered_repository_count": result.data.repositories.count,
            "warnings": result.warnings
        ]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        print("DISCOVERY_GIT_ACCOUNTING_EVIDENCE \(String(decoding: data, as: UTF8.self))")

        #expect(result.diagnostics.totalGitCalls == calls.count)
        #expect(total == calls.count)
        #expect(discoveryCalls == 1)
        #expect(calls.contains { $0 == ["worktree", "list", "--porcelain", "-z"] })
        #expect(result.data.repositories.count == 2)
    }
}

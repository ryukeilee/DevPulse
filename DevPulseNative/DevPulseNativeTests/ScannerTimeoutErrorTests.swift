import Foundation
import Testing
@testable import DevPulse

// MARK: - TimeoutResultBox Tests
//
// Verifies that TimeoutResultBox (used by runWithTimeout) correctly prevents
// double-resume of a CheckedContinuation, which would otherwise crash.

@Suite("TimeoutResultBox")
struct TimeoutResultBoxTests {

    @Test("first finish wins, subsequent calls are no-ops")
    func firstFinishWins() async {
        let value: Int = await withCheckedContinuation { continuation in
            let box = TimeoutResultBox<Int>(continuation)
            box.finish(42)
            box.finish(999) // should be silently ignored
        }
        #expect(value == 42, "first finish should deliver its value")
    }

    @Test("concurrent finish does not double-resume")
    func concurrentFinish() async {
        let value = await withCheckedContinuation { continuation in
            let box = TimeoutResultBox<String>(continuation)
            // Simulate race between timeout and operation completion.
            // Both run synchronously but the lock inside TimeoutResultBox
            // ensures exactly one resume.
            box.finish("timeout")
            box.finish("operation")
        }
        #expect(value == "timeout" || value == "operation",
                "one of the two values should be delivered exactly once")
    }

    @Test("separate instances are independent")
    func independentInstances() async {
        async let v1: Int = withCheckedContinuation { continuation in
            let box = TimeoutResultBox<Int>(continuation)
            box.finish(1)
        }
        async let v2: Int = withCheckedContinuation { continuation in
            let box = TimeoutResultBox<Int>(continuation)
            box.finish(2)
        }
        let (r1, r2) = await (v1, v2)
        #expect(r1 == 1)
        #expect(r2 == 2)
    }
}

// MARK: - File system unavailability path tests
//
// Tests that the scanner discovery pipeline correctly handles filesystem
// unavailability and returns appropriate results, exercising the
// runWithTimeout → readDirectoryContents → directEntry traversal path.

@Suite("Scanner Discovery Unavailability")
struct ScannerDiscoveryUnavailabilityTests {

    @Test("discoverOnly returns empty readable paths for missing root")
    func missingRootReturnsEmpty() async {
        let missingPath = "/tmp/devpulse-test-missing-\(UUID().uuidString)"
        let result = await GitRepositoryScanner.discoverOnly(
            config: ScanConfig(
                enabledBuiltInPaths: [],
                customPaths: [],
                maxDepth: 1,
                changedPreviewLimit: 0,
                maxConcurrentGitOps: 1,
                gitCommandTimeout: 1.0,
                scanTimeout: 5.0,
                slowReposkipSeconds: 600,
                activeRepoThreshold: 1
            ),
            scanRoots: [missingPath]
        )
        // The path does not exist, so it should not appear in readablePaths.
        #expect(result.readablePaths.isEmpty,
                "non-existent scan root should not produce readable paths")
    }

    @Test("discoverOnly finds git repository in a configured root")
    func findsRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-test-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Create a minimal git repo inside the root.
        let repoURL = root.appendingPathComponent("test-repo")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try runGit(["init"], in: repoURL)
        try runGit(["config", "user.name", "Test"], in: repoURL)
        try runGit(["config", "user.email", "test@example.com"], in: repoURL)
        let readme = repoURL.appendingPathComponent("README.md")
        try "hello\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], in: repoURL)
        try runGit(["commit", "-m", "init"], in: repoURL)

        let result = await GitRepositoryScanner.discoverOnly(
            config: ScanConfig(
                enabledBuiltInPaths: [],
                customPaths: [],
                maxDepth: 2,
                changedPreviewLimit: 0,
                maxConcurrentGitOps: 1,
                gitCommandTimeout: 5.0,
                scanTimeout: 15.0,
                slowReposkipSeconds: 600,
                activeRepoThreshold: 1
            ),
            scanRoots: [root.path]
        )

        #expect(!result.readablePaths.isEmpty,
                "should find at least one readable path")
        #expect(result.readablePaths.contains(where: { $0.hasSuffix("test-repo") }),
                "should discover the test-repo directory")
    }
}

// MARK: - Helpers

private func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        throw TestGitError(arguments: arguments, output: output)
    }
}

private struct TestGitError: Error, CustomStringConvertible {
    let arguments: [String]
    let output: String

    var description: String {
        "git \(arguments.joined(separator: " ")) failed: \(output)"
    }
}

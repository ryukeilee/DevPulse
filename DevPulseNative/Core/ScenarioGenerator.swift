import Foundation
import OSLog

// MARK: - Scenario types

/// Types of test scenarios the generator can create.
public enum ScenarioKind: String, CaseIterable, Sendable, Codable {
    case normalRepo
    case linkedWorktree
    case multiWorkspace
    case largeRepo
    case deepDirectory
    case manyUntracked
    case conflictState
    case noUpstream
    case brokenPath
    case slowDisk
    case hangingGit
}

/// Describes a generated test scenario environment.
public struct ScenarioEnvironment: Sendable {
    public let kind: ScenarioKind
    public let rootURL: URL
    public let repoURLs: [URL]
    public let description: String
    public var hangingPIDs: [Int32] = []

    /// Remove all created files and kill any hanging processes.
    public func cleanUp() {
        for pid in hangingPIDs {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: rootURL)
    }
}

/// Builder that creates synthetic Git repositories for testing.
///
/// All repos are created under a temporary directory and can be
/// cleaned up via `ScenarioEnvironment.cleanUp()`.
public enum ScenarioBuilder {

    /// Create a normal repository with a single commit on main.
    public static func normalRepo(label: String = "normal") -> ScenarioEnvironment {
        let root = tempDir(label: label)
        let repo = root.appendingPathComponent("repo")
        createRepo(at: repo)
        commitFile(at: repo, name: "README.md", content: "# Normal Repo")
        return ScenarioEnvironment(
            kind: .normalRepo,
            rootURL: root,
            repoURLs: [repo],
            description: "Single normal repository with one commit"
        )
    }

    /// Create a repository with a linked worktree.
    public static func linkedWorktree(label: String = "worktree") -> ScenarioEnvironment {
        let root = tempDir(label: label)
        let main = root.appendingPathComponent("main")
        let wt = root.appendingPathComponent("worktree")
        createRepo(at: main)
        commitFile(at: main, name: "README.md", content: "# Worktree Test")
        git(main, "branch", "feature")
        _ = git(main, "worktree", "add", wt.path, "feature")
        return ScenarioEnvironment(
            kind: .linkedWorktree,
            rootURL: root,
            repoURLs: [main, wt],
            description: "Repository with one linked worktree on feature branch"
        )
    }

    /// Create multiple repositories to simulate a multi-workspace environment.
    public static func multiWorkspace(count: Int = 3, label: String = "workspace") -> ScenarioEnvironment {
        let root = tempDir(label: label)
        var repos: [URL] = []
        for i in 0..<count {
            let r = root.appendingPathComponent("repo-\(i)")
            createRepo(at: r)
            commitFile(at: r, name: "file-\(i).txt", content: "Workspace \(i)")
            repos.append(r)
        }
        return ScenarioEnvironment(
            kind: .multiWorkspace,
            rootURL: root,
            repoURLs: repos,
            description: "\(count) independent repositories"
        )
    }

    /// Create a large repository with many commits and files.
    public static func largeRepo(fileCount: Int = 200, commitCount: Int = 50, label: String = "large") -> ScenarioEnvironment {
        let root = tempDir(label: label)
        let repo = root.appendingPathComponent("large-repo")
        createRepo(at: repo)
        for c in 0..<commitCount {
            for _ in 0..<(fileCount / max(commitCount, 1)) {
                let f = root.appendingPathComponent("file-\(c)-\(Int.random(in: 0..<1000)).txt")
                try? "data".write(to: f, atomically: true, encoding: .utf8)
            }
            git(repo, "add", ".")
            git(repo, "commit", "-m", "commit \(c)")
        }
        return ScenarioEnvironment(
            kind: .largeRepo,
            rootURL: root,
            repoURLs: [repo],
            description: "Large repo with \(fileCount) files across \(commitCount) commits"
        )
    }

    /// Create a repo with deeply nested directories.
    public static func deepDirectory(depth: Int = 10, label: String = "deep") -> ScenarioEnvironment {
        let root = tempDir(label: label)
        let repo = root.appendingPathComponent("deep-repo")
        createRepo(at: repo)
        var dir = repo
        for _ in 0..<depth {
            dir = dir.appendingPathComponent("sub")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let f = dir.appendingPathComponent("leaf.txt")
        try? "leaf".write(to: f, atomically: true, encoding: .utf8)
        git(repo, "add", ".")
        git(repo, "commit", "-m", "deep dirs")
        return ScenarioEnvironment(
            kind: .deepDirectory,
            rootURL: root,
            repoURLs: [repo],
            description: "Repo with directory depth of \(depth)"
        )
    }

    /// Create a repo with many untracked files.
    public static func manyUntracked(count: Int = 500, label: String = "untracked") -> ScenarioEnvironment {
        let root = tempDir(label: label)
        let repo = root.appendingPathComponent("untracked-repo")
        createRepo(at: repo)
        commitFile(at: repo, name: "base.txt", content: "base")
        for i in 0..<count {
            let f = repo.appendingPathComponent("untracked-\(i).txt")
            try? "data-\(i)".write(to: f, atomically: true, encoding: .utf8)
        }
        return ScenarioEnvironment(
            kind: .manyUntracked,
            rootURL: root,
            repoURLs: [repo],
            description: "Repo with \(count) untracked files"
        )
    }

    /// Create a repo in a merge conflict state.
    public static func conflictState(label: String = "conflict") -> ScenarioEnvironment {
        let root = tempDir(label: label)
        let repo = root.appendingPathComponent("conflict-repo")
        createRepo(at: repo)
        commitFile(at: repo, name: "shared.txt", content: "base content")
        git(repo, "branch", "other")
        appendFile(at: repo, name: "shared.txt", content: "\nmain change")
        git(repo, "add", ".")
        git(repo, "commit", "-m", "main change")
        git(repo, "checkout", "other")
        appendFile(at: repo, name: "shared.txt", content: "\nother change")
        git(repo, "add", ".")
        git(repo, "commit", "-m", "other change")
        git(repo, "checkout", "main")
        _ = git(repo, "merge", "other")
        return ScenarioEnvironment(
            kind: .conflictState,
            rootURL: root,
            repoURLs: [repo],
            description: "Repo in merge conflict state"
        )
    }

    /// Create a repo with no remote upstream configured.
    public static func noUpstream(label: String = "noupstream") -> ScenarioEnvironment {
        let root = tempDir(label: label)
        let repo = root.appendingPathComponent("local-repo")
        createRepo(at: repo)
        commitFile(at: repo, name: "local.txt", content: "local only")
        return ScenarioEnvironment(
            kind: .noUpstream,
            rootURL: root,
            repoURLs: [repo],
            description: "Repo with no upstream remote"
        )
    }

    /// Create a scenario where a path is inaccessible.
    public static func brokenPath(label: String = "broken") -> ScenarioEnvironment {
        let root = tempDir(label: label)
        let repo = root.appendingPathComponent("broken-repo")
        createRepo(at: repo)
        commitFile(at: repo, name: "gone.txt", content: "will disappear")
        return ScenarioEnvironment(
            kind: .brokenPath,
            rootURL: root,
            repoURLs: [repo],
            description: "Repo at path that may become inaccessible"
        )
    }

    /// Create a repo with simulated slow-disk behavior (many tiny files).
    public static func slowDisk(fileCount: Int = 3000, label: String = "slow") -> ScenarioEnvironment {
        let root = tempDir(label: label)
        let repo = root.appendingPathComponent("slow-repo")
        createRepo(at: repo)
        commitFile(at: repo, name: "base.txt", content: "base")
        for i in 0..<fileCount {
            let subdir = repo.appendingPathComponent("sub-\(i / 500)")
            try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            let f = subdir.appendingPathComponent("file-\(i).txt")
            try? "small-data-\(i)".write(to: f, atomically: true, encoding: .utf8)
        }
        git(repo, "add", ".")
        git(repo, "commit", "-m", "add \(fileCount) small files")
        return ScenarioEnvironment(
            kind: .slowDisk,
            rootURL: root,
            repoURLs: [repo],
            description: "Repo with \(fileCount) small files simulating slow-disk enumeration"
        )
    }

    /// Create a repo with a hanging git-background process.
    public static func hangingGit(label: String = "hanging") -> ScenarioEnvironment {
        let root = tempDir(label: label)
        let repo = root.appendingPathComponent("hanging-repo")
        createRepo(at: repo)
        commitFile(at: repo, name: "readme.txt", content: "hanging test")
        // Launch a background sleep-then-git to simulate a stuck process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 600 && git status"]
        proc.currentDirectoryURL = repo
        try? proc.run()
        var env = ScenarioEnvironment(
            kind: .hangingGit,
            rootURL: root,
            repoURLs: [repo],
            description: "Repo with background git process that does not exit promptly"
        )
        env.hangingPIDs = [proc.processIdentifier]
        return env
    }

    // MARK: - Utilities

    private static func tempDir(label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-scenario-\(label)-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private static func git(_ cwd: URL, _ args: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try? process.run()
        process.waitUntilExit()
        return (try? out.fileHandleForReading.readToEnd()).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
    }

    private static func createRepo(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        git(url, "init", "-b", "main")
        git(url, "config", "user.email", "test@devpulse.local")
        git(url, "config", "user.name", "DevPulse Test")
    }

    private static func commitFile(at url: URL, name: String, content: String) {
        let f = url.appendingPathComponent(name)
        try? content.write(to: f, atomically: true, encoding: .utf8)
        git(url, "add", ".")
        git(url, "commit", "-m", "add \(name)")
    }

    private static func appendFile(at url: URL, name: String, content: String) {
        let f = url.appendingPathComponent(name)
        if let existing = try? String(contentsOf: f, encoding: .utf8) {
            try? (existing + content).write(to: f, atomically: true, encoding: .utf8)
        } else {
            try? content.write(to: f, atomically: true, encoding: .utf8)
        }
    }
}

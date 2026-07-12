import Foundation

enum ProcessRunner {
    /// Maximum time a single git command may run.
    static let gitTimeout: TimeInterval = 5.0
    private static let gitCandidates = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git"
    ]

    /// Resolve the first usable Git executable without relying on PATH.
    static func gitExecutablePath() -> String? {
        for candidate in gitCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return nil
    }

    /// Execute a process and return its stdout trimmed, or nil on failure.
    static func run(executable: String? = nil,
                    arguments: [String],
                    workingDirectory: String,
                    timeout: TimeInterval = gitTimeout,
                    isCancelled: @Sendable @escaping () -> Bool = { false }) -> String? {
        let executablePath = executable ?? gitExecutablePath()
        guard let executablePath,
              FileManager.default.isExecutableFile(atPath: executablePath),
              !isCancelled() else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // Wait with timeout
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline || isCancelled() {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output
    }

    /// Check whether git is available on this system.
    static func isGitAvailable() -> Bool {
        gitExecutablePath() != nil
    }
}

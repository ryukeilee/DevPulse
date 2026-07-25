import Darwin
import Foundation

enum ProcessRunResult: Sendable, Equatable {
    case success(output: String)
    case nonZero(exitCode: Int32)
    case timeout
    case cancelled
    case launch
    case unavailable
    case outputLimit
}

enum GitCommandKind: Sendable {
    case status
    case log
    case other
}

enum RepositoryDiscoveryMode: Sendable, Equatable {
    case empty
    case reusedKnown
    case reusedCache
    case walked
    case incomplete
}

struct ScanMetrics: Sendable, Equatable {
    let elapsed: TimeInterval
    let discoveryMode: RepositoryDiscoveryMode
    let discoveryElapsed: TimeInterval
    let discoveredRepositoryCount: Int
    let repositoryReadCount: Int
    let repositorySkippedCount: Int
    let reusedRepositorySnapshotCount: Int
    let gitCommandCount: Int
    let gitStatusCommandCount: Int
    let gitLogCommandCount: Int
    let gitTimeoutCount: Int
    let gitCancellationCount: Int
    let gitFailureCount: Int
    let currentConcurrentGitCommandCount: Int
    let peakConcurrentGitCommandCount: Int
    let peakConcurrentFullScanCount: Int
}

final class ScanMetricsCollector: @unchecked Sendable {
    struct ScanToken: Sendable {
        fileprivate let id: UInt64
    }

    struct GitCommandToken: Sendable {
        fileprivate let id: UInt64
    }

    private struct ActiveScan {
        let startedAt: TimeInterval
        let isFullScan: Bool
    }

    private struct State {
        var nextTokenID: UInt64 = 0
        var activeScans: [UInt64: ActiveScan] = [:]
        var completedScanElapsed: TimeInterval = 0
        var discoveryMode: RepositoryDiscoveryMode = .empty
        var discoveryElapsed: TimeInterval = 0
        var discoveredRepositoryCount = 0
        var repositoryReadCount = 0
        var repositorySkippedCount = 0
        var reusedRepositorySnapshotCount = 0
        var gitCommandCount = 0
        var gitStatusCommandCount = 0
        var gitLogCommandCount = 0
        var gitTimeoutCount = 0
        var gitCancellationCount = 0
        var gitFailureCount = 0
        var activeGitCommands: Set<UInt64> = []
        var peakConcurrentGitCommandCount = 0
    }

    private final class GlobalFullScanConcurrency: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private var peak = 0

        func begin() {
            lock.lock()
            current += 1
            peak = max(peak, current)
            lock.unlock()
        }

        func end() {
            lock.lock()
            current = max(0, current - 1)
            lock.unlock()
        }

        func peakCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return peak
        }
    }

    private static let fullScanConcurrency = GlobalFullScanConcurrency()
    private let lock = NSLock()
    private var state = State()

    @discardableResult
    func beginScan(isFullScan: Bool = true) -> ScanToken {
        let token: ScanToken
        lock.lock()
        state.nextTokenID &+= 1
        token = ScanToken(id: state.nextTokenID)
        state.activeScans[token.id] = ActiveScan(
            startedAt: ProcessInfo.processInfo.systemUptime,
            isFullScan: isFullScan
        )
        lock.unlock()

        if isFullScan {
            Self.fullScanConcurrency.begin()
        }
        return token
    }

    func endScan(_ token: ScanToken) {
        let activeScan: ActiveScan?
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        activeScan = state.activeScans.removeValue(forKey: token.id)
        if let activeScan {
            state.completedScanElapsed = max(
                state.completedScanElapsed,
                max(0, now - activeScan.startedAt)
            )
        }
        lock.unlock()

        if activeScan?.isFullScan == true {
            Self.fullScanConcurrency.end()
        }
    }

    func recordDiscovery(mode: RepositoryDiscoveryMode,
                         elapsed: TimeInterval,
                         discoveredRepositoryCount: Int) {
        lock.lock()
        state.discoveryMode = mode
        state.discoveryElapsed = Self.nonNegative(elapsed)
        state.discoveredRepositoryCount = max(0, discoveredRepositoryCount)
        lock.unlock()
    }

    func recordRepositoryRead(count: Int = 1) {
        guard count > 0 else { return }
        lock.lock()
        state.repositoryReadCount += count
        lock.unlock()
    }

    func recordRepositorySkipped(count: Int = 1) {
        guard count > 0 else { return }
        lock.lock()
        state.repositorySkippedCount += count
        lock.unlock()
    }

    func recordReusedRepositorySnapshot(count: Int = 1) {
        guard count > 0 else { return }
        lock.lock()
        state.reusedRepositorySnapshotCount += count
        lock.unlock()
    }

    @discardableResult
    func recordGitCommandStart(kind: GitCommandKind) -> GitCommandToken {
        let token: GitCommandToken
        lock.lock()
        state.nextTokenID &+= 1
        token = GitCommandToken(id: state.nextTokenID)
        state.activeGitCommands.insert(token.id)
        state.gitCommandCount += 1
        switch kind {
        case .status:
            state.gitStatusCommandCount += 1
        case .log:
            state.gitLogCommandCount += 1
        case .other:
            break
        }
        state.peakConcurrentGitCommandCount = max(
            state.peakConcurrentGitCommandCount,
            state.activeGitCommands.count
        )
        lock.unlock()
        return token
    }

    func recordGitCommandFinish(_ token: GitCommandToken, result: ProcessRunResult) {
        lock.lock()
        guard state.activeGitCommands.remove(token.id) != nil else {
            lock.unlock()
            return
        }

        switch result {
        case .success:
            break
        case .timeout:
            state.gitTimeoutCount += 1
        case .cancelled:
            state.gitCancellationCount += 1
        case .nonZero, .launch, .unavailable, .outputLimit:
            state.gitFailureCount += 1
        }
        lock.unlock()
    }

    func snapshot() -> ScanMetrics {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshotState: State
        lock.lock()
        snapshotState = state
        lock.unlock()

        let activeElapsed = snapshotState.activeScans.values.reduce(0) { elapsed, scan in
            max(elapsed, max(0, now - scan.startedAt))
        }
        return ScanMetrics(
            elapsed: max(snapshotState.completedScanElapsed, activeElapsed),
            discoveryMode: snapshotState.discoveryMode,
            discoveryElapsed: snapshotState.discoveryElapsed,
            discoveredRepositoryCount: snapshotState.discoveredRepositoryCount,
            repositoryReadCount: snapshotState.repositoryReadCount,
            repositorySkippedCount: snapshotState.repositorySkippedCount,
            reusedRepositorySnapshotCount: snapshotState.reusedRepositorySnapshotCount,
            gitCommandCount: snapshotState.gitCommandCount,
            gitStatusCommandCount: snapshotState.gitStatusCommandCount,
            gitLogCommandCount: snapshotState.gitLogCommandCount,
            gitTimeoutCount: snapshotState.gitTimeoutCount,
            gitCancellationCount: snapshotState.gitCancellationCount,
            gitFailureCount: snapshotState.gitFailureCount,
            currentConcurrentGitCommandCount: snapshotState.activeGitCommands.count,
            peakConcurrentGitCommandCount: snapshotState.peakConcurrentGitCommandCount,
            peakConcurrentFullScanCount: Self.fullScanConcurrency.peakCount()
        )
    }

    private static func nonNegative(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }
}

enum ProcessRunner {
    /// Maximum time a single git command may run.
    static let gitTimeout: TimeInterval = 5.0
    static let defaultOutputLimit = 8 * 1024 * 1024

    private static let gitCandidates = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git"
    ]
    private static let pollInterval: TimeInterval = 0.01
    private static let terminationGrace: TimeInterval = 0.20
    private static let killObservationGrace: TimeInterval = 0.20
    private static let outputDrainGrace: TimeInterval = 0.25

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
        guard case let .success(output) = runDetailed(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout,
            isCancelled: isCancelled
        ) else {
            return nil
        }
        return output
    }

    /// Execute a process with bounded output and a typed, stderr-free outcome.
    static func runDetailed(executable: String? = nil,
                            arguments: [String],
                            workingDirectory: String,
                            timeout: TimeInterval = gitTimeout,
                            outputLimit: Int = defaultOutputLimit,
                            isCancelled: @Sendable @escaping () -> Bool = { false }) -> ProcessRunResult {
        guard !isCancelled() else { return .cancelled }
        guard timeout.isFinite, timeout > 0 else { return .timeout }
        guard outputLimit > 0 else { return .outputLimit }

        let executablePath = executable ?? gitExecutablePath()
        guard let executablePath,
              FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .unavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outputCollector = ProcessOutputCollector(limit: outputLimit)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            outputCollector.consume(handle.availableData, stream: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            outputCollector.consume(handle.availableData, stream: .stderr)
        }

        do {
            try process.run()
        } catch {
            stopDraining(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            return .launch
        }

        // Only the child should retain the pipe write ends after launch.
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        let processGroupID = isolatedProcessGroupID(for: process)
        defer {
            stopDraining(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var forcedResult: ProcessRunResult?
        while process.isRunning {
            if isCancelled() {
                forcedResult = .cancelled
                break
            }
            if outputCollector.didExceedLimit {
                forcedResult = .outputLimit
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                forcedResult = .timeout
                break
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        if let forcedResult {
            terminate(process, isolatedProcessGroupID: processGroupID)
            return forcedResult
        }

        let drainDeadline = ProcessInfo.processInfo.systemUptime + outputDrainGrace
        while !outputCollector.didReachEOF,
              !outputCollector.didExceedLimit,
              ProcessInfo.processInfo.systemUptime < drainDeadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }

        let finalOutput = outputCollector.finalState()
        guard !finalOutput.didExceedLimit else { return .outputLimit }
        // A successful direct child is not enough: descendants may still hold
        // inherited pipe descriptors. Never report a truncated output as a
        // successful Git result.
        guard finalOutput.didReachEOF else {
            terminateDescendants(in: processGroupID)
            return .timeout
        }
        guard process.terminationStatus == 0 else {
            return .nonZero(exitCode: process.terminationStatus)
        }

        let output = String(decoding: finalOutput.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(output: output)
    }

    /// Check whether git is available on this system.
    static func isGitAvailable() -> Bool {
        gitExecutablePath() != nil
    }

    private static func isolatedProcessGroupID(for process: Process) -> pid_t? {
        let processID = process.processIdentifier
        guard processID > 0, Darwin.getpgid(processID) == processID else { return nil }
        return processID
    }

    private static func terminate(_ process: Process,
                                  isolatedProcessGroupID: pid_t?) {
        guard process.isRunning else { return }
        // Foundation documents terminate() as including subprocesses. The
        // recorded isolated process group provides the hard-kill fallback for
        // descendants that ignore SIGTERM.
        process.terminate()

        var deadline = ProcessInfo.processInfo.systemUptime + terminationGrace
        while (process.isRunning || processGroupExists(isolatedProcessGroupID)),
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }

        if process.isRunning || processGroupExists(isolatedProcessGroupID) {
            if let isolatedProcessGroupID {
                _ = Darwin.kill(-isolatedProcessGroupID, SIGKILL)
            } else if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            deadline = ProcessInfo.processInfo.systemUptime + killObservationGrace
            while (process.isRunning || processGroupExists(isolatedProcessGroupID)),
                  ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
    }

    private static func terminateDescendants(in isolatedProcessGroupID: pid_t?) {
        guard let isolatedProcessGroupID,
              processGroupExists(isolatedProcessGroupID) else { return }
        _ = Darwin.kill(-isolatedProcessGroupID, SIGTERM)
        var deadline = ProcessInfo.processInfo.systemUptime + terminationGrace
        while processGroupExists(isolatedProcessGroupID),
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        guard processGroupExists(isolatedProcessGroupID) else { return }
        _ = Darwin.kill(-isolatedProcessGroupID, SIGKILL)
        deadline = ProcessInfo.processInfo.systemUptime + killObservationGrace
        while processGroupExists(isolatedProcessGroupID),
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private static func processGroupExists(_ processGroupID: pid_t?) -> Bool {
        guard let processGroupID, processGroupID > 0 else { return false }
        if Darwin.kill(-processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func stopDraining(stdoutPipe: Pipe, stderrPipe: Pipe) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    enum Stream {
        case stdout
        case stderr
    }

    private let lock = NSLock()
    private let limit: Int
    private var receivedByteCount = 0
    private var stdoutData = Data()
    private var stdoutReachedEOF = false
    private var stderrReachedEOF = false
    private var exceededLimit = false

    init(limit: Int) {
        self.limit = limit
    }

    func consume(_ data: Data, stream: Stream) {
        lock.lock()
        defer { lock.unlock() }

        guard !data.isEmpty else {
            switch stream {
            case .stdout:
                stdoutReachedEOF = true
            case .stderr:
                stderrReachedEOF = true
            }
            return
        }

        guard !exceededLimit else { return }
        let remaining = limit - receivedByteCount
        guard data.count <= remaining else {
            exceededLimit = true
            return
        }

        receivedByteCount += data.count
        if stream == .stdout {
            stdoutData.append(data)
        }
    }

    var didExceedLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceededLimit
    }

    var didReachEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdoutReachedEOF && stderrReachedEOF
    }

    var stdout: Data {
        lock.lock()
        defer { lock.unlock() }
        return stdoutData
    }

    func finalState() -> (didReachEOF: Bool, didExceedLimit: Bool, stdout: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (
            stdoutReachedEOF && stderrReachedEOF,
            exceededLimit,
            stdoutData
        )
    }
}

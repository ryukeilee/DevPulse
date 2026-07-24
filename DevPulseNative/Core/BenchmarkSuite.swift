import Foundation
import OSLog

public enum BenchmarkScenario: String, CaseIterable, Sendable, Codable {
    case coldStart
    case firstDiscovery
    case incrementalRefresh
    case continuousManualRefresh
    case backgroundRefresh
    case pageSwitch
    case sleepWake
    case configChange
    case appRestart

    var displayName: String {
        switch self {
        case .coldStart: return "Cold Start"
        case .firstDiscovery: return "First Discovery"
        case .incrementalRefresh: return "Incremental Refresh"
        case .continuousManualRefresh: return "Continuous Manual Refresh"
        case .backgroundRefresh: return "Background Refresh"
        case .pageSwitch: return "Page Switch"
        case .sleepWake: return "Sleep/Wake"
        case .configChange: return "Configuration Change"
        case .appRestart: return "App Restart"
        }
    }
}

public struct BenchmarkResult: Equatable, Sendable, Codable {
    public let scenario: BenchmarkScenario
    public let runID: String
    public let startedAt: String
    public let totalElapsed: Double
    public let firstResultElapsed: Double
    public let completeElapsed: Double
    public let peakCPU: Double
    public let averageCPU: Double
    public let peakMemoryMB: Int
    public let totalDiskWritesKB: Int
    public let gitSubprocessCount: Int
    public let metadata: [String: String]

    public init(scenario: BenchmarkScenario, runID: String, startedAt: String,
                totalElapsed: Double, firstResultElapsed: Double, completeElapsed: Double,
                peakCPU: Double, averageCPU: Double, peakMemoryMB: Int, totalDiskWritesKB: Int,
                gitSubprocessCount: Int, metadata: [String: String]) {
        self.scenario = scenario
        self.runID = runID
        self.startedAt = startedAt
        self.totalElapsed = totalElapsed
        self.firstResultElapsed = firstResultElapsed
        self.completeElapsed = completeElapsed
        self.peakCPU = peakCPU
        self.averageCPU = averageCPU
        self.peakMemoryMB = peakMemoryMB
        self.totalDiskWritesKB = totalDiskWritesKB
        self.gitSubprocessCount = gitSubprocessCount
        self.metadata = metadata
    }
}

// MARK: - Mach / resource helpers

#if canImport(Darwin)
@preconcurrency import Darwin
import MachO

/// Read resident memory via task_info (TASK_VM_INFO).
private func readResidentMemory() -> UInt64 {
    let flavor = task_flavor_t(TASK_VM_INFO)
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, flavor, intPtr, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return info.resident_size
}

/// Read CPU load delta via host_cpu_load_info.
private func readCPULoad() -> (user: UInt32, system: UInt32, idle: UInt32) {
    var info = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, 0, 0) }
    return (info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2)
}

/// Read disk-write blocks via getrusage.
private func readDiskWriteBlocks() -> Int {
    var usage = rusage()
    let ret = withUnsafeMutablePointer(to: &usage) { ptr in
        getrusage(RUSAGE_SELF, ptr)
    }
    guard ret == 0 else { return 0 }
    return Int(usage.ru_oublock)
}
#endif

public actor BenchmarkRunner {
    private let logger = Logger(subsystem: "placeholder", category: "BenchmarkRunner")

    public init() {}

    public func run(
        scenario: BenchmarkScenario,
        setup: @escaping () async throws -> Void,
        action: @escaping () async throws -> Void,
        teardown: (() async -> Void)? = nil
    ) async -> BenchmarkResult {
        let runID = "bench-\(Date().timeIntervalSince1970)"
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let overallStart = ProcessInfo.processInfo.systemUptime

        // Capture before-measurements
        let memBefore = memoryUsageMB()
        let cpuBefore = readCPULoad()
        let diskBefore = readDiskWriteBlocks()
        let gitBefore = countGitSubprocesses()

        var firstResultTime: Double = -1
        var completeTime: Double = -1
        var peakMem = memBefore

        do {
            try await setup()
            firstResultTime = ProcessInfo.processInfo.systemUptime - overallStart
            peakMem = max(peakMem, memoryUsageMB())
            try await action()
            completeTime = ProcessInfo.processInfo.systemUptime - overallStart
        } catch {
            completeTime = ProcessInfo.processInfo.systemUptime - overallStart
        }

        if let t = teardown {
            await t()
        }

        let totalElapsed = ProcessInfo.processInfo.systemUptime - overallStart
        let memAfter = memoryUsageMB()
        peakMem = max(peakMem, memAfter)

        // Compute CPU delta
        let cpuAfter = readCPULoad()
        let totalTicks = (cpuAfter.user - cpuBefore.user)
            + (cpuAfter.system - cpuBefore.system)
            + (cpuAfter.idle - cpuBefore.idle)
        let busyTicks = (cpuAfter.user - cpuBefore.user)
            + (cpuAfter.system - cpuBefore.system)
        let cpuFraction = totalTicks > 0 ? Double(busyTicks) / Double(totalTicks) : 0.0

        // Disk delta
        let diskAfter = readDiskWriteBlocks()
        let diskBlocks = max(0, diskAfter - diskBefore)
        let diskKB = diskBlocks * 512 / 1024

        // Git subprocess count
        let gitAfter = countGitSubprocesses()

        return BenchmarkResult(
            scenario: scenario,
            runID: runID,
            startedAt: startedAt,
            totalElapsed: totalElapsed,
            firstResultElapsed: firstResultTime >= 0 ? firstResultTime : totalElapsed,
            completeElapsed: completeTime >= 0 ? completeTime : totalElapsed,
            peakCPU: cpuFraction * 100.0,
            averageCPU: cpuFraction * 100.0,
            peakMemoryMB: peakMem,
            totalDiskWritesKB: diskKB,
            gitSubprocessCount: gitAfter,
            metadata: [:]
        )
    }

    // MARK: - Measurement primitives

    /// Current resident memory in MB.
    private func memoryUsageMB() -> Int {
        #if canImport(Darwin)
        let bytes = readResidentMemory()
        return Int(bytes / 1024 / 1024)
        #else
        return 0
        #endif
    }

    /// Count active git subprocesses.
    private func countGitSubprocesses() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "git status --porcelain"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = nil
        try? process.run()
        process.waitUntilExit()
        guard let data = try? out.fileHandleForReading.readToEnd() else { return 0 }
        let count = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").count ?? 0
        return count
    }
}

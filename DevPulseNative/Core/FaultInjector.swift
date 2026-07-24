import Foundation
import OSLog

enum FaultCommand: Equatable, Sendable, Codable {
    case delay(seconds: Double)
    case timeout
    case cancellation
    case fileCorruption(path: String)
    case permissionDenied(path: String)
    case pathDisappears(path: String)
    case gitError(message: String)
    case processHang(seconds: Double)

    var label: String {
        switch self {
        case .delay: return "delay"
        case .timeout: return "timeout"
        case .cancellation: return "cancellation"
        case .fileCorruption: return "fileCorruption"
        case .permissionDenied: return "permissionDenied"
        case .pathDisappears: return "pathDisappears"
        case .gitError: return "gitError"
        case .processHang: return "processHang"
        }
    }
}

struct FaultPlan: Equatable, Sendable {
    let stage: String
    let command: FaultCommand
    let probability: Double
    let maxInjections: Int

    static func always(stage: String, command: FaultCommand) -> FaultPlan {
        FaultPlan(stage: stage, command: command, probability: 1.0, maxInjections: 1)
    }
}

final class FaultInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let logger = Logger(subsystem: "placeholder", category: "FaultInjector")

    private static let _enabledLock = NSLock()
    nonisolated(unsafe) static var isEnabled: Bool = false
    private var plans: [FaultPlan] = []
    private var counts: [String: Int] = [:]

    static let shared = FaultInjector()
    private init() {}

    func activate(_ plans: [FaultPlan]) {
        lock.withLock { self.plans = plans; self.counts = [:] }
    }

    func deactivate() {
        lock.withLock { plans = []; counts = [:] }
    }

    func fault(for stage: String) -> FaultCommand? {
        guard Self.isEnabled else { return nil }
        return lock.withLock {
            for p in plans where p.stage == stage {
                let k = "\(p.stage):\(p.command.label)"
                let c = counts[k] ?? 0
                guard c < p.maxInjections else { continue }
                if Double.random(in: 0...1) <= p.probability {
                    counts[k] = c + 1
                    return p.command
                }
            }
            return nil
        }
    }

    func wrappingRunner(
        _ base: @escaping RefreshEngine.GitCommandRunner,
        stage: String
    ) -> RefreshEngine.GitCommandRunner {
        { [self] args, wd, timeout, limit, isCancelled in
            if let cmd = fault(for: stage) {
                switch cmd {
                case .delay(let s):
                    Thread.sleep(forTimeInterval: s)
                case .timeout:
                    return .timeout
                case .cancellation:
                    return .cancelled
                case .fileCorruption(let path):
                    physicallyInject(.fileCorruption(path: path))
                case .permissionDenied(let path):
                    physicallyInject(.permissionDenied(path: path))
                case .pathDisappears(let path):
                    physicallyInject(.pathDisappears(path: path))
                case .gitError:
                    return .nonZero(exitCode: 128)
                case .processHang(let s):
                    let dl = Date().addingTimeInterval(s)
                    while Date() < dl && !isCancelled() {
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    return isCancelled() ? .cancelled : .timeout
                }
            }
            return base(args, wd, timeout, limit, isCancelled)
        }
    }

    /// Perform a physical filesystem fault injection.
    /// Only acts on paths under the devpulse scenario sandbox.
    private func physicallyInject(_ command: FaultCommand) {
        switch command {
        case .fileCorruption(let path):
            guard path.contains("devpulse-scenario-") else { return }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return }
            try? "CORRUPTED-DATA-\(UUID().uuidString)".write(to: url, atomically: true, encoding: .utf8)

        case .permissionDenied(let path):
            guard path.contains("devpulse-scenario-") else { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)

        case .pathDisappears(let path):
            guard path.contains("devpulse-scenario-") else { return }
            let backup = path + ".fault-backup"
            try? FileManager.default.moveItem(atPath: path, toPath: backup)

        default:
            break
        }
    }
}

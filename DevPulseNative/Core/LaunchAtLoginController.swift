import Foundation
import ServiceManagement

enum LaunchAtLoginCommand: Equatable {
    case status
    case enable
    case disable

    init?(arguments: [String]) {
        if arguments.contains("--launch-at-login-status") {
            self = .status
            return
        }
        if arguments.contains("--enable-launch-at-login") {
            self = .enable
            return
        }
        if arguments.contains("--disable-launch-at-login") {
            self = .disable
            return
        }
        return nil
    }
}

enum LaunchAtLoginStatus: String, Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown

    init(serviceStatus: SMAppService.Status) {
        switch serviceStatus {
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notRegistered:
            self = .notRegistered
        case .notFound:
            self = .notFound
        @unknown default:
            self = .unknown
        }
    }
}

enum LaunchAtLoginSeverity: Equatable {
    case normal
    case warning
    case error
}

struct LaunchAtLoginDiagnostics: Equatable {
    let isEnabled: Bool
    let status: LaunchAtLoginStatus
    let title: String
    let detail: String
    let nextStep: String?
    let severity: LaunchAtLoginSeverity
}

enum LaunchAtLoginDiagnosticsBuilder {
    static func build(
        status: LaunchAtLoginStatus,
        lastError: String?,
        lastOperationSucceeded: Bool?
    ) -> LaunchAtLoginDiagnostics {
        if let lastError, !lastError.isEmpty {
            return LaunchAtLoginDiagnostics(
                isEnabled: status == .enabled || status == .requiresApproval,
                status: status,
                title: "开机启动切换失败",
                detail: lastError,
                nextStep: "打开系统设置 > 登录项，确认 DevPulse 是否被系统拦截或移除。",
                severity: .error
            )
        }

        switch status {
        case .enabled:
            return LaunchAtLoginDiagnostics(
                isEnabled: true,
                status: status,
                title: "开机启动已启用",
                detail: lastOperationSucceeded == false ? "系统状态与上次操作结果不一致。" : "DevPulse 会在登录后自动启动。",
                nextStep: nil,
                severity: .normal
            )
        case .requiresApproval:
            return LaunchAtLoginDiagnostics(
                isEnabled: true,
                status: status,
                title: "等待系统批准",
                detail: "DevPulse 已请求加入登录项，但还需要你在系统设置里确认。",
                nextStep: "打开系统设置 > 登录项，允许 DevPulse 在登录后启动。",
                severity: .warning
            )
        case .notRegistered:
            return LaunchAtLoginDiagnostics(
                isEnabled: false,
                status: status,
                title: "开机启动未启用",
                detail: "当前不会在登录后自动启动 DevPulse。",
                nextStep: "如果你希望常驻菜单栏，可以打开上面的开关。",
                severity: .normal
            )
        case .notFound:
            return LaunchAtLoginDiagnostics(
                isEnabled: false,
                status: status,
                title: "系统尚未识别登录项注册",
                detail: "macOS 还没有返回可用的 DevPulse 登录项状态。这通常出现在首次启用前，或替换 App 后系统尚未刷新时。",
                nextStep: "如果 DevPulse 已在 /Applications，可先切换一次开关或重启 App，再到系统设置 > 登录项确认。",
                severity: .warning
            )
        case .unknown:
            return LaunchAtLoginDiagnostics(
                isEnabled: false,
                status: status,
                title: "无法确认开机启动状态",
                detail: "当前没有拿到明确的系统登录项状态。",
                nextStep: "重开设置页后再看一次；如果仍然未知，检查系统登录项。",
                severity: .warning
            )
        }
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus = .unknown
    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastOperationSucceeded: Bool?
    @Published private(set) var isUpdating = false

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        refreshStatus()
    }

    var diagnostics: LaunchAtLoginDiagnostics {
        LaunchAtLoginDiagnosticsBuilder.build(
            status: status,
            lastError: lastError,
            lastOperationSucceeded: lastOperationSucceeded
        )
    }

    func refreshStatus() {
        let nextStatus = LaunchAtLoginStatus(serviceStatus: service.status)
        status = nextStatus
        isEnabled = nextStatus == .enabled || nextStatus == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }

        isUpdating = true
        lastError = nil
        lastOperationSucceeded = nil

        defer {
            refreshStatus()
            isUpdating = false
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            lastOperationSucceeded = true
        } catch {
            lastError = describe(error)
            lastOperationSucceeded = false
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @discardableResult
    func run(command: LaunchAtLoginCommand) -> String {
        switch command {
        case .status:
            refreshStatus()
        case .enable:
            setEnabled(true)
        case .disable:
            setEnabled(false)
        }

        let diagnostics = diagnostics
        var lines = [
            "launch_at_login.command=\(command.label)",
            "launch_at_login.status=\(status.rawValue)",
            "launch_at_login.enabled=\(diagnostics.isEnabled ? "true" : "false")",
            "launch_at_login.severity=\(diagnostics.severity.label)",
            "launch_at_login.title=\(diagnostics.title)",
            "launch_at_login.detail=\(diagnostics.detail)"
        ]

        if let nextStep = diagnostics.nextStep {
            lines.append("launch_at_login.next_step=\(nextStep)")
        }
        if let lastError, !lastError.isEmpty {
            lines.append("launch_at_login.error=\(lastError)")
        }
        if let lastOperationSucceeded {
            lines.append("launch_at_login.last_operation_succeeded=\(lastOperationSucceeded ? "true" : "false")")
        }

        return lines.joined(separator: "\n")
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if !nsError.localizedDescription.isEmpty {
            return nsError.localizedDescription
        }
        return "未知错误（\(nsError.domain) \(nsError.code)）"
    }
}

private extension LaunchAtLoginCommand {
    var label: String {
        switch self {
        case .status:
            return "status"
        case .enable:
            return "enable"
        case .disable:
            return "disable"
        }
    }
}

private extension LaunchAtLoginSeverity {
    var label: String {
        switch self {
        case .normal:
            return "normal"
        case .warning:
            return "warning"
        case .error:
            return "error"
        }
    }
}

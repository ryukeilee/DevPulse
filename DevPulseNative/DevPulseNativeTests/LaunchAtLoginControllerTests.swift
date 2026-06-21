import Testing
@testable import DevPulse

struct LaunchAtLoginControllerTests {
    @Test func commandParserRecognizesStatusFlag() {
        #expect(LaunchAtLoginCommand(arguments: ["DevPulse", "--launch-at-login-status"]) == .status)
    }

    @Test func commandParserRecognizesEnableFlag() {
        #expect(LaunchAtLoginCommand(arguments: ["DevPulse", "--enable-launch-at-login"]) == .enable)
    }

    @Test func commandParserRecognizesDisableFlag() {
        #expect(LaunchAtLoginCommand(arguments: ["DevPulse", "--disable-launch-at-login"]) == .disable)
    }

    @Test func enabledStatusBuildsHealthyDiagnostics() {
        let diagnostics = LaunchAtLoginDiagnosticsBuilder.build(
            status: .enabled,
            lastError: nil,
            lastOperationSucceeded: true
        )

        #expect(diagnostics.isEnabled)
        #expect(diagnostics.severity == .normal)
        #expect(diagnostics.title == "开机启动已启用")
        #expect(diagnostics.nextStep == nil)
    }

    @Test func approvalRequiredBuildsWarningDiagnostics() {
        let diagnostics = LaunchAtLoginDiagnosticsBuilder.build(
            status: .requiresApproval,
            lastError: nil,
            lastOperationSucceeded: true
        )

        #expect(diagnostics.isEnabled)
        #expect(diagnostics.severity == .warning)
        #expect(diagnostics.title == "等待系统批准")
        #expect(diagnostics.nextStep?.contains("登录项") == true)
    }

    @Test func notFoundBuildsActionableWarningDiagnostics() {
        let diagnostics = LaunchAtLoginDiagnosticsBuilder.build(
            status: .notFound,
            lastError: nil,
            lastOperationSucceeded: nil
        )

        #expect(diagnostics.isEnabled == false)
        #expect(diagnostics.severity == .warning)
        #expect(diagnostics.title == "系统尚未识别登录项注册")
        #expect(diagnostics.nextStep?.contains("切换一次开关") == true)
    }

    @Test func explicitErrorOverridesStatusSummary() {
        let diagnostics = LaunchAtLoginDiagnosticsBuilder.build(
            status: .enabled,
            lastError: "operation failed",
            lastOperationSucceeded: false
        )

        #expect(diagnostics.severity == .error)
        #expect(diagnostics.title == "开机启动切换失败")
        #expect(diagnostics.detail == "operation failed")
    }
}

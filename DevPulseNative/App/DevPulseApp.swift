import AppKit
import Darwin
import SwiftUI

@main
struct DevPulseApp: App {
    @NSApplicationDelegateAdaptor(StartupCommandDelegate.self) private var startupCommandDelegate
    @StateObject private var scheduler: ScanScheduler
    @StateObject private var launchAtLoginController: LaunchAtLoginController
    @State private var mainWindow: NSWindow?
    private let lifecycleCoordinator: LifecycleCoordinator
    @State private var lifecycleReady = false

    init() {
        let startupCommand = AppCommand(arguments: ProcessInfo.processInfo.arguments)
        let eventStore = startupCommand == nil && !Self.isRunningTests
            ? ActivityEventStore.live()
            : nil
        let scheduler = ScanScheduler(
            commandMode: startupCommand != nil,
            activityEventStore: eventStore
        )
        let launchAtLoginController = LaunchAtLoginController()
        let coordinator = LifecycleCoordinator()

        if startupCommand == nil && !Self.isRunningTests {
            // Start lifecycle coordinator on a background task.
            // The `scheduler` reference is captured from the local
            // before it is wrapped in StateObject. After lifecycle
            // startup completes, trigger a lifecycle recovery scan
            // to pick up any snapshot issues found during self-heal.
            Task { @MainActor in
                await coordinator.performStartup()
                scheduler.handleLifecycleRefresh(.lifecycleRecovery)
            }
        }

        _scheduler = StateObject(wrappedValue: scheduler)
        _launchAtLoginController = StateObject(wrappedValue: launchAtLoginController)
        lifecycleCoordinator = coordinator
    }

    var body: some Scene {
        MenuBarExtra("DevPulse", systemImage: "waveform.path.ecg") {
            Button {
                openMainWindow()
            } label: {
                Label("Open DevPulse", systemImage: "macwindow")
            }

            Button {
                scheduler.rescan()
            } label: {
                Label(
                    scheduler.isScanning ? "Scanning..." : "Rescan Now",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(scheduler.isScanning)

            Divider()



            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit DevPulse", systemImage: "power")
            }
        }
    }

    private func openMainWindow() {
        launchAtLoginController.refreshStatus()
        scheduler.handleLifecycleRefresh(.windowReopened)

        if let mainWindow {
            show(window: mainWindow)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DevPulse"
        window.contentMinSize = NSSize(width: 600, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(scheduler)
                .environmentObject(launchAtLoginController)
                .frame(minWidth: 600, idealWidth: 720, minHeight: 480, idealHeight: 560)
        )
        window.center()

        mainWindow = window
        show(window: window)
    }

    private func show(window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

final class StartupCommandDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Recover any pending restore transaction from a previous crash
        let backupManager = BackupManager()
        let restoreManager = RestoreManager(backupManager: backupManager)
        restoreManager.recoverPendingTransaction(config: .default)

        guard let command = AppCommand(arguments: ProcessInfo.processInfo.arguments) else { return }

        Task { @MainActor in
            switch command {
            case .launchAtLogin(let launchAtLoginCommand):
                let controller = LaunchAtLoginController()
                print(controller.run(command: launchAtLoginCommand))
                fflush(stdout)
                Darwin.exit(EXIT_SUCCESS)
            case .selfCheck:
                let scheduler = ScanScheduler(activityEventStore: ActivityEventStore.live())
                let scanReport = await scheduler.runSelfCheck()

                // Run lifecycle self-heal and install verification
                let healRunner = SelfHealingRunner()
                let healReport = await healRunner.run()

                let installState = await LifecycleCoordinator.determineInstallState()
                let widgetReg = await LifecycleCoordinator.determineWidgetRegistrationState()

                var lines = [scanReport.renderedOutput]
                lines.append("lifecycle.install_state=\(installStateDescription(installState))")
                lines.append("lifecycle.widget_registration=\(widgetRegistrationDescription(widgetReg))")
                lines.append("lifecycle.self_heal=^\(healReport.allPassed ? "pass" : "fail")")
                lines.append("lifecycle.self_heal_checks=\(healReport.checks.count)")
                lines.append("lifecycle.self_heal_recovered=\(healReport.recoveredCount)")
                if let msg = healReport.userActionMessage {
                    lines.append("lifecycle.user_action=\(msg)")
                }
                if !healReport.allPassed {
                    for check in healReport.checks where !check.passed {
                        lines.append("lifecycle.failed_check.\(check.category.rawValue)=\(check.detail)")
                    }
                }

                let output = lines.joined(separator: "\n")
                print(output)
                fflush(stdout)
                Darwin.exit(healReport.allPassed && scanReport.success ? EXIT_SUCCESS : EXIT_FAILURE)
            }

            fflush(stdout)
        }
    }

    private func installStateDescription(_ state: InstallState) -> String {
        switch state {
        case .firstInstall: return "first_install"
        case .cleanReinstall(let version): return "reinstall_v\(version)"
        case .upgrade(let from, let to): return "upgrade_\(from)_to_\(to)"
        case .normalLaunch: return "normal"
        case .indeterminate(let reason): return "indeterminate_\(reason)"
        }
    }

    private func widgetRegistrationDescription(_ state: WidgetRegistrationState) -> String {
        switch state {
        case .embedded: return "embedded_only"
        case .registered: return "registered_only"
        case .active: return "active"
        case .missingExtension: return "missing_extension"
        case .notRegistered(let reason): return "not_registered_\(reason)"
        case .unknown: return "unknown"
        }
    }
}

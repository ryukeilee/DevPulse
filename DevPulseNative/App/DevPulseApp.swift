import AppKit
import Darwin
import SwiftUI

@main
struct DevPulseApp: App {
    @NSApplicationDelegateAdaptor(StartupCommandDelegate.self) private var startupCommandDelegate
    @StateObject private var scheduler: ScanScheduler
    @StateObject private var launchAtLoginController: LaunchAtLoginController
    @State private var mainWindow: NSWindow?

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
        if startupCommand == nil && !Self.isRunningTests {
            scheduler.startBackgroundScanning()
        }
        _scheduler = StateObject(wrappedValue: scheduler)
        _launchAtLoginController = StateObject(wrappedValue: launchAtLoginController)
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
                let report = await scheduler.runSelfCheck()
                print(report.renderedOutput)
                fflush(stdout)
                Darwin.exit(report.success ? EXIT_SUCCESS : EXIT_FAILURE)
            }

            fflush(stdout)
        }
    }
}

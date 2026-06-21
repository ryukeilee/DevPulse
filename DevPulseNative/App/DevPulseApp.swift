import AppKit
import SwiftUI

@main
struct DevPulseApp: App {
    @StateObject private var scheduler: ScanScheduler
    @State private var mainWindow: NSWindow?

    init() {
        let scheduler = ScanScheduler()
        scheduler.startBackgroundScanning()
        _scheduler = StateObject(wrappedValue: scheduler)
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
}

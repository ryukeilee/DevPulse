import SwiftUI

@main
struct DevPulseApp: App {
    @StateObject private var scheduler = ScanScheduler()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scheduler)
                .frame(minWidth: 600, idealWidth: 720, minHeight: 480, idealHeight: 560)
                .onAppear {
                    scheduler.startBackgroundScanning()
                }
                .onDisappear {
                    scheduler.stopBackgroundScanning()
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 560)
    }
}

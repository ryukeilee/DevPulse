import SwiftUI

struct ContentView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            StatusTab()
                .tabItem {
                    Label("Overview", systemImage: "square.grid.2x2")
                }
                .tag(0)

            RepositoryListView()
                .tabItem {
                    Label("Repositories", systemImage: "list.bullet.rectangle")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
        .environmentObject(scheduler)
    }
}

// MARK: - Status tab (overview)

struct StatusTab: View {
    @EnvironmentObject var scheduler: ScanScheduler

    var body: some View {
        VStack(spacing: 0) {
            ScanStatusView()
            Divider()
            if !scheduler.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(scheduler.warnings, id: \.self) { warning in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                            Text(warning)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.08))
                Divider()
            }
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 40))
                    .foregroundColor(iconColor)
                Text(statusMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
    }

    private var iconName: String {
        if !scheduler.gitAvailable { return "wrench.and.screwdriver" }
        if !scheduler.appGroupAvailable { return "xmark.shield" }
        let repos = scheduler.lastResult.repositories
        if repos.isEmpty { return "magnifyingglass" }
        let changed = scheduler.lastResult.scanSummary.changedRepositories
        if changed > 0 { return "doc.badge.ellipsis" }
        return "checkmark.circle"
    }

    private var iconColor: Color {
        if !scheduler.gitAvailable || !scheduler.appGroupAvailable { return .red }
        let repos = scheduler.lastResult.repositories
        if repos.isEmpty { return .secondary }
        let changed = scheduler.lastResult.scanSummary.changedRepositories
        if changed > 0 { return .orange }
        return .green
    }

    private var statusMessage: String {
        if !scheduler.gitAvailable {
            return "Git not found.\nInstall Xcode Command Line Tools or Git to continue."
        }
        if !scheduler.appGroupAvailable {
            return "App Group not available.\nCheck entitlements and provisioning profile."
        }
        let repos = scheduler.lastResult.repositories
        if repos.isEmpty {
            if scheduler.lastScanAt != nil {
                return "No Git repositories found.\nAdjust scan locations in Settings."
            }
            return "Ready to scan.\nPress Rescan Now to discover repositories."
        }
        let summary = scheduler.lastResult.scanSummary
        return "\(summary.totalRepositories) repositories · "
            + "\(summary.changedRepositories) changed · "
            + "\(summary.totalChangedFiles) files"
    }
}

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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScanStatusView()

                if !scheduler.warnings.isEmpty {
                    warningsPanel
                }

                ActivityTimelineView(
                    feed: ActivityTimelineBuilder.build(
                        from: scheduler.lastResult.repositories,
                        lastScanAt: scheduler.lastScanAt
                    ),
                    onRescan: { scheduler.rescan() }
                )
            }
            .padding(20)
        }
    }

    private var warningsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(scheduler.warnings, id: \.self) { warning in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.yellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @State private var selectedTab: AppTab = .overview
    @State private var settingsScrollTarget: SettingsScrollTarget?

    var body: some View {
        TabView(selection: $selectedTab) {
            StatusTab(
                openRepositories: openRepositories,
                openSettings: openSettings,
                openDiagnostics: openDiagnostics
            )
                .tabItem {
                    Label("Overview", systemImage: "square.grid.2x2")
                }
                .tag(AppTab.overview)

            RepositoryListView()
                .tabItem {
                    Label("Repositories", systemImage: "list.bullet.rectangle")
                }
                .tag(AppTab.repositories)

            SettingsView(scrollTarget: $settingsScrollTarget)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        .environmentObject(scheduler)
    }

    private func openDiagnostics() {
        selectedTab = OverviewDiagnosticsNavigation.tab
        settingsScrollTarget = OverviewDiagnosticsNavigation.scrollTarget
    }

    private func openRepositories() {
        selectedTab = .repositories
    }

    private func openSettings() {
        selectedTab = .settings
        settingsScrollTarget = nil
    }
}

// MARK: - Status tab (overview)

struct StatusTab: View {
    @EnvironmentObject var scheduler: ScanScheduler
    let openRepositories: () -> Void
    let openSettings: () -> Void
    let openDiagnostics: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OverviewFocusCard(
                    openRepositories: openRepositories,
                    openSettings: openSettings,
                    openDiagnostics: openDiagnostics
                )

                if let detail = scheduler.refreshDetailText {
                    Text("\(scheduler.refreshStatusText) · \(detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(scheduler.refreshStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}

private struct OverviewFocusCard: View {
    @EnvironmentObject var scheduler: ScanScheduler
    let openRepositories: () -> Void
    let openSettings: () -> Void
    let openDiagnostics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: severitySymbol)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(severityColor)
                    .frame(width: 26, height: 26)

                Text(focus.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()
            }

            Text(focus.summary)
                .font(.body)
                .foregroundStyle(.primary)

            if let detail = focus.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: performPrimaryAction) {
                Label(focus.action.title, systemImage: focus.action.systemImage)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isActionDisabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(severityBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(severityColor.opacity(0.18), lineWidth: 1)
        )
    }

    private var focus: OverviewFocusModel {
        OverviewFocusBuilder.build(
            lastScanAt: scheduler.lastScanAt,
            diagnostics: scheduler.diagnostics,
            widgetTrust: widgetDataTrust,
            repositories: scheduler.lastResult.repositories
        )
    }

    private var widgetDataTrust: WidgetDataTrustModel {
        WidgetDataTrustBuilder.build(
            diagnostics: scheduler.diagnostics,
            widgetTrust: widgetTrustAssessment,
            repositories: scheduler.lastResult.repositories
        )
    }

    private var widgetTrustAssessment: SnapshotTrustAssessment {
        RefreshStatusFormatter.snapshotAssessment(
            generatedAt: scheduler.diagnostics.widgetSnapshot?.generatedAt,
            writtenAt: scheduler.diagnostics.widgetSnapshot?.writtenAt,
            readError: scheduler.diagnostics.widgetSnapshotReadError,
            missingReason: "Widget 侧还没有拿到可用快照时间。"
        )
    }

    private func performPrimaryAction() {
        switch focus.action.kind {
        case .refreshData:
            scheduler.scanNow()
        case .rescan:
            scheduler.rescan()
        case .openRepositories:
            openRepositories()
        case .openSettings:
            openSettings()
        case .openDiagnostics:
            openDiagnostics()
        }
    }

    private var isActionDisabled: Bool {
        switch focus.action.kind {
        case .refreshData, .rescan:
            return scheduler.isScanning
        case .openRepositories, .openSettings, .openDiagnostics:
            return false
        }
    }

    private var severityColor: Color {
        switch focus.severity {
        case .normal:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var severityBackground: Color {
        switch focus.severity {
        case .normal:
            return Color.green.opacity(0.08)
        case .warning:
            return Color.orange.opacity(0.08)
        case .error:
            return Color.red.opacity(0.08)
        }
    }

    private var severitySymbol: String {
        switch focus.severity {
        case .normal:
            return "checkmark.seal.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }
}

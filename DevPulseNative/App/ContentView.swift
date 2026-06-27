import SwiftUI

struct ContentView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @State private var selectedTab: AppTab = .overview
    @State private var settingsScrollTarget: SettingsScrollTarget?

    var body: some View {
        TabView(selection: $selectedTab) {
            StatusTab(openDiagnostics: openDiagnostics)
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
}

// MARK: - Status tab (overview)

struct StatusTab: View {
    @EnvironmentObject var scheduler: ScanScheduler
    let openDiagnostics: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScanStatusView()
                WidgetDataTrustStatusBar(openDiagnostics: openDiagnostics)

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

private struct WidgetDataTrustStatusBar: View {
    @EnvironmentObject var scheduler: ScanScheduler
    let openDiagnostics: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: severitySymbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(severityColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Widget 数据")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(widgetDataTrust.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(severityColor)
                        .lineLimit(1)
                }

                Text(widgetDataTrust.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button(action: performPrimaryAction) {
                Label(primaryButtonModel.title, systemImage: primaryButtonModel.systemImage)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(primaryButtonModel.isDisabled)
            .help(primaryButtonModel.helpText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(severityBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(severityColor.opacity(0.18), lineWidth: 1)
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

    private var primaryButtonModel: WidgetDataTrustPrimaryButtonModel {
        WidgetDataTrustPrimaryButtonBuilder.build(
            action: widgetDataTrust.primaryAction,
            isScanning: scheduler.isScanning
        )
    }

    private func performPrimaryAction() {
        switch primaryButtonModel.actionKind {
        case .refreshData:
            scheduler.scanNow()
        case .rescan:
            scheduler.rescan()
        case .viewDiagnostics:
            openDiagnostics()
        }
    }

    private var severityColor: Color {
        switch widgetDataTrust.severity {
        case .normal:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var severityBackground: Color {
        switch widgetDataTrust.severity {
        case .normal:
            return Color.green.opacity(0.08)
        case .warning:
            return Color.orange.opacity(0.08)
        case .error:
            return Color.red.opacity(0.08)
        }
    }

    private var severitySymbol: String {
        switch widgetDataTrust.severity {
        case .normal:
            return "checkmark.seal.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }
}

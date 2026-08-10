import SwiftUI

enum DevPulseVisualStyle {
    static let pageInset: CGFloat = 20
    static let sectionCornerRadius: CGFloat = 12

    static var surface: Color {
        Color.primary.opacity(0.045)
    }

    static var strongerSurface: Color {
        Color.primary.opacity(0.075)
    }

    static var separator: Color {
        Color.primary.opacity(0.09)
    }
}

struct ContentView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @State private var selectedTab: AppTab = .overview
    @State private var settingsScrollTarget: SettingsScrollTarget?

    var body: some View {
        VStack(spacing: 0) {
            AppSectionBar(selection: $selectedTab)

            Divider()
                .overlay(DevPulseVisualStyle.separator)

            ZStack {
                StatusTab(
                    openRepositories: openRepositories,
                    openSettings: openSettings,
                    openDiagnostics: openDiagnostics
                )
                .tabContentVisibility(selectedTab == .overview)

                WorkspaceListView()
                    .tabContentVisibility(selectedTab == .workspaces)

                RepositoryListView()
                    .tabContentVisibility(selectedTab == .repositories)

                ImpactOverviewView()
                    .tabContentVisibility(selectedTab == .impact)

                BackupManagementView()
                    .tabContentVisibility(selectedTab == .backup)

                SettingsView(scrollTarget: $settingsScrollTarget)
                    .tabContentVisibility(selectedTab == .settings)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

private extension View {
    func tabContentVisibility(_ isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .disabled(!isVisible)
            .accessibilityHidden(!isVisible)
    }
}

private struct AppSectionBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack {
            Spacer()

            HStack(spacing: 2) {
                sectionButton(
                    tab: .overview,
                    title: "Overview",
                    systemImage: "square.grid.2x2"
                )
                sectionButton(
                    tab: .workspaces,
                    title: "Workspaces",
                    systemImage: "rectangle.3.group"
                )
                sectionButton(
                    tab: .repositories,
                    title: "Repositories",
                    systemImage: "list.bullet.rectangle"
                )
                sectionButton(
                    tab: .impact,
                    title: "Impact",
                    systemImage: "chart.bar.doc.horizontal"
                )
                sectionButton(
                    tab: .backup,
                    title: "Backup",
                    systemImage: "externaldrive"
                )
                sectionButton(
                    tab: .settings,
                    title: "Settings",
                    systemImage: "gearshape"
                )
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DevPulseVisualStyle.surface)
            )

            Spacer()
        }
        .padding(.horizontal, DevPulseVisualStyle.pageInset)
        .padding(.vertical, 8)
    }

    private func sectionButton(tab: AppTab, title: String, systemImage: String) -> some View {
        let isSelected = selection == tab

        return Button {
            selection = tab
        } label: {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .help(title)
        .animation(.easeOut(duration: 0.14), value: selection)
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
            VStack(alignment: .leading, spacing: 12) {
                OverviewFocusCard(
                    openRepositories: openRepositories,
                    openSettings: openSettings,
                    openDiagnostics: openDiagnostics
                )

                TodayDevelopmentSummaryView(events: scheduler.activityEvents)

                ActivityTimelineView(
                    events: scheduler.activityEvents,
                    repositories: scheduler.lastResult.repositories,
                    lastScanAt: scheduler.lastSuccessfulRefreshAt,
                    isScanning: scheduler.isScanning,
                    onRescan: scheduler.rescan
                )

                refreshStatus
            }
            .padding(DevPulseVisualStyle.pageInset)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var refreshStatus: some View {
        HStack(spacing: 7) {
            if scheduler.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .accessibilityHidden(true)
            }

            if let detail = scheduler.refreshDetailText {
                Text("\(scheduler.refreshStatusText) · \(detail)")
            } else {
                Text(scheduler.refreshStatusText)
            }

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

private struct OverviewFocusCard: View {
    @EnvironmentObject var scheduler: ScanScheduler
    let openRepositories: () -> Void
    let openSettings: () -> Void
    let openDiagnostics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(severityColor.opacity(0.12))

                    Image(systemName: severitySymbol)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(severityColor)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 5) {
                    Text(focus.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(focus.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 12)

                primaryActionButton
            }

            if let detail = focus.detail {
                Divider()
                    .overlay(DevPulseVisualStyle.separator)
                    .padding(.top, 14)
                    .padding(.bottom, 11)

                Label(detail, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DevPulseVisualStyle.sectionCornerRadius, style: .continuous)
                .fill(DevPulseVisualStyle.surface)
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(severityColor)
                .frame(width: 3)
                .padding(.vertical, 12)
        }
    }

    private var primaryActionButton: some View {
        Button(action: performPrimaryAction) {
            Label(focus.action.title, systemImage: focus.action.systemImage)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(severityColor)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(severityColor.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(severityColor.opacity(0.18), lineWidth: 1)
        )
        .opacity(isActionDisabled ? 0.48 : 1)
        .disabled(isActionDisabled)
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
        if let snapshot = scheduler.diagnostics.widgetSnapshot {
            return RefreshStatusFormatter.snapshotAssessment(
                snapshot: snapshot,
                readError: scheduler.diagnostics.widgetSnapshotReadError,
                missingReason: "Widget 侧还没有拿到可证明的完整成功刷新时间。"
            )
        }
        return RefreshStatusFormatter.snapshotAssessment(
            generatedAt: nil,
            writtenAt: nil,
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

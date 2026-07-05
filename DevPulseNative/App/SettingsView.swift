import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @EnvironmentObject var launchAtLoginController: LaunchAtLoginController
    @Binding var scrollTarget: SettingsScrollTarget?
    @State private var newCustomPath: String = ""
    @State private var builtInToggles: [ScanLocationToggle] = ScanLocationProvider.builtInToggles()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Section: Default scan locations
                    defaultScanLocationsSection

                    Divider()

                    // Section: Custom scan directories
                    customScanDirectoriesSection

                    Divider()

                    // Section: Launch At Login
                    launchAtLoginSection

                    Divider()

                    // Section: Diagnostics
                    diagnosticsSection
                        .id(SettingsScrollTarget.diagnostics)
                }
                .padding(20)
                .onAppear {
                    refreshBuiltInToggles()
                    launchAtLoginController.refreshStatus()
                    scrollToTargetIfNeeded(using: proxy)
                }
                .onChange(of: scheduler.scanDirectories) { _, _ in
                    refreshBuiltInToggles()
                }
                .onChange(of: scrollTarget) { _, _ in
                    scrollToTargetIfNeeded(using: proxy)
                }
            }
        }
    }

    private func scrollToTargetIfNeeded(using proxy: ScrollViewProxy) {
        guard let scrollTarget else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(scrollTarget, anchor: .top)
        }
        self.scrollTarget = nil
    }

    // MARK: - Default scan locations

    private var defaultScanLocationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Default Scan Locations", systemImage: "house")
                .font(.headline)

            Text("Toggle built-in directories to include or exclude from scanning.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach($builtInToggles) { $toggle in
                Toggle(isOn: $toggle.isEnabled) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.caption)
                        Text(toggle.path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !directoryExists(toggle.path) {
                            Text("(not found)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onChange(of: toggle.isEnabled) { _, newValue in
                    scheduler.toggleBuiltIn(path: toggle.path, enabled: newValue)
                }
            }
        }
    }

    // MARK: - Custom scan directories

    private var customScanDirectoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Custom Scan Directories", systemImage: "folder.badge.plus")
                .font(.headline)

            if scheduler.scanDirectories.isEmpty {
                Text("No custom directories added.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(scheduler.scanDirectories) { directory in
                    HStack {
                        Image(systemName: "folder")
                            .font(.caption)
                        Text(directory.path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !directoryExists(directory.path) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundColor(.yellow)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            scheduler.removeCustomPath(directory.path)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                TextField("/path/to/projects", text: $newCustomPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Add") {
                    let trimmed = newCustomPath.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    scheduler.addCustomPath(trimmed)
                    newCustomPath = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newCustomPath.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Choose…") {
                    chooseDirectory()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Launch At Login

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Launch At Login", systemImage: "power.circle")
                .font(.headline)

            Toggle(isOn: Binding(
                get: { launchAtLoginController.isEnabled },
                set: { launchAtLoginController.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start DevPulse automatically after login")
                        .font(.caption.weight(.semibold))
                    Text(launchAtLoginController.diagnostics.detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(launchAtLoginController.isUpdating)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: severitySymbol(launchAtLoginSeverity))
                    .foregroundColor(severityColor(launchAtLoginSeverity))
                VStack(alignment: .leading, spacing: 4) {
                    Text(launchAtLoginStatusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(severityColor(launchAtLoginSeverity))
                    Text(launchAtLoginOperationDetail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if launchAtLoginController.status == .requiresApproval || launchAtLoginController.status == .notFound {
                Button("Open Login Items in System Settings") {
                    launchAtLoginController.openSystemSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Widget Data Status", systemImage: "square.grid.2x2")
                    .font(.headline)
                Spacer()
                Button(action: { scheduler.scanNow() }) {
                    Label(
                        scheduler.isScanning ? "Refreshing..." : "Refresh Data",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(scheduler.isScanning)
            }

            widgetStatusSummarySection

            DisclosureGroup("Advanced Diagnostics") {
                VStack(alignment: .leading, spacing: 12) {
                    if let accessWarning = scheduler.scanRootAccessWarning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(accessWarning)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(8)
                    }

                    diagnosticsTopSummaryStrip
                    diagnosticsSnapshotFactsSection
                    diagnosticsSections
                    diagnosticsScanRootsSection
                    diagnosticsConsistencyIssuesSection
                    diagnosticsRepositoriesSection
                    diagnosticsEventsSection
                }
                .padding(.top, 8)
            }
            .font(.caption)
        }
    }

    private var widgetStatusSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(diagnosticsOverview.sections.first(where: { $0.id == "widget-state" })?.title ?? "Widget 状态",
                      systemImage: severitySymbol(widgetSummarySeverity))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(severityColor(widgetSummarySeverity))
                Spacer()
                if let timeHint = diagnosticsSectionTimeHint(widgetSummarySectionModel) {
                    Text(timeHint)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Text(widgetSummarySectionModel.summary)
                .font(.caption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(widgetSummaryHighlights) { item in
                diagnosticsStatusSummaryRow(item)
            }
        }
        .padding(10)
        .background(severityBackground(widgetSummarySeverity))
        .cornerRadius(8)
    }

    private var diagnosticsConsistencyIssuesSection: some View {
        Group {
            if !scheduler.diagnostics.validationIssues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Consistency issues")
                        .font(.caption.weight(.semibold))
                    ForEach(scheduler.diagnostics.validationIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
            }
        }
    }

    private var diagnosticsRepositoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Current repositories")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(diagnosticsRepositorySummary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if scheduler.lastResult.repositories.isEmpty {
                Text("No repositories in the latest snapshot.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(scheduler.lastResult.repositories) { repo in
                        diagnosticsRepositoryCompactRow(repo)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private var diagnosticsEventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent events")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(diagnosticsEventSummary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if scheduler.diagnosticEvents.isEmpty {
                Text("No diagnostic events yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(diagnosticsEventPreview) { event in
                        diagnosticsEventSummaryRow(event)
                    }

                    if scheduler.diagnosticEvents.count > diagnosticsEventPreview.count {
                        DisclosureGroup("Event log") {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(scheduler.diagnosticEvents.reversed())) { event in
                                        diagnosticsEventRow(event)
                                    }
                                }
                            }
                            .frame(maxHeight: 160)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private var diagnosticsTopSummaryStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(diagnosticsOverview.headline, systemImage: severitySymbol(diagnosticsOverview.severity))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(severityColor(diagnosticsOverview.severity))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(diagnosticsTopSummaryHint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                diagnosticsInlineStatusPill(
                    title: "Shared",
                    value: diagnosticsOverview.sections.first(where: { $0.id == "shared-data" })?.summary ?? "Unavailable",
                    severity: diagnosticsOverview.sections.first(where: { $0.id == "shared-data" })?.severity ?? .warning
                )
                diagnosticsInlineStatusPill(
                    title: "Widget",
                    value: diagnosticsOverview.sections.first(where: { $0.id == "widget-state" })?.summary ?? "Unavailable",
                    severity: diagnosticsOverview.sections.first(where: { $0.id == "widget-state" })?.severity ?? .warning
                )
                diagnosticsInlineStatusPill(
                    title: "Events",
                    value: diagnosticsEventHeadline,
                    severity: diagnosticsEventSeverity
                )
            }
        }
        .padding(8)
        .background(severityBackground(diagnosticsOverview.severity))
        .cornerRadius(8)
    }

    private var diagnosticsScanRootsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scan roots")
                .font(.caption.weight(.semibold))

            if scheduler.diagnostics.scanRoots.isEmpty {
                Text("No accessible scan roots.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(scheduler.diagnostics.scanRoots, id: \.self) { path in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(path)
                            .font(.caption)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }

            ForEach(scheduler.diagnostics.scanRootWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private var diagnosticsStatusGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            diagnosticsRow(
                title: "App Bundle",
                value: scheduler.diagnostics.appBundleIdentifier,
                detail: "Main app bundle identifier.",
                isError: false
            )
            diagnosticsRow(
                title: "Widget Bundle",
                value: scheduler.diagnostics.widgetBundleIdentifier,
                detail: "Widget extension bundle identifier.",
                isError: false
            )
            diagnosticsRow(
                title: "App Group",
                value: scheduler.diagnostics.appGroupIdentifier,
                detail: scheduler.diagnostics.appGroupContainerPath ?? "App Group container unavailable.",
                isError: !scheduler.appGroupAvailable
            )
            diagnosticsRow(
                title: "Container",
                value: scheduler.diagnostics.appGroupContainerPath ?? "Unavailable",
                detail: scheduler.diagnostics.appGroupAvailable ? "App Group container path." : "Check entitlements and signing.",
                isError: !scheduler.appGroupAvailable
            )
            diagnosticsRow(
                title: "Snapshot file",
                value: scheduler.diagnostics.snapshotFilePath ?? "Unavailable",
                detail: scheduler.diagnostics.snapshotExists ? "Shared repositories.json exists." : "Shared repositories.json is missing.",
                isError: !scheduler.diagnostics.snapshotExists
            )
            diagnosticsRow(
                title: "Snapshot exists",
                value: scheduler.diagnostics.snapshotExists ? "Yes" : "No",
                detail: scheduler.diagnostics.snapshotFilePath ?? "No snapshot path resolved.",
                isError: !scheduler.diagnostics.snapshotExists
            )
            diagnosticsRow(
                title: "Snapshot readable",
                value: scheduler.diagnostics.snapshotReadable ? "Yes" : "No",
                detail: scheduler.diagnostics.snapshotReadable ? "File is readable." : "File cannot be read by the app.",
                isError: !scheduler.diagnostics.snapshotReadable
            )
            diagnosticsRow(
                title: "Snapshot writable",
                value: scheduler.diagnostics.snapshotWritable ? "Yes" : "No",
                detail: scheduler.diagnostics.snapshotWritable ? "File or container is writable." : "File or container cannot be written.",
                isError: !scheduler.diagnostics.snapshotWritable
            )
            diagnosticsRow(
                title: "Snapshot decodable",
                value: scheduler.diagnostics.snapshotDecodable ? "Yes" : "No",
                detail: scheduler.diagnostics.snapshotDecodable ? "Shared snapshot decoded successfully." : (scheduler.diagnostics.sharedDataReadError ?? "Shared snapshot has not been decoded yet."),
                isError: !scheduler.diagnostics.snapshotDecodable
            )
            diagnosticsRow(
                title: "Shared read",
                value: sharedReadStatus,
                detail: sharedReadDetail,
                isError: sharedReadStatus == "Failed"
            )
            diagnosticsRow(
                title: "Shared write",
                value: sharedWriteStatus,
                detail: sharedWriteDetail,
                isError: sharedWriteStatus == "Failed"
            )
            diagnosticsRow(
                title: "Widget snapshot",
                value: widgetSnapshotStatus,
                detail: widgetSnapshotDetail,
                isError: widgetSnapshotStatus == "Failed"
            )
            diagnosticsRow(
                title: "Validation",
                value: scheduler.diagnostics.validationIssues.isEmpty ? "Pass" : "Mismatch",
                detail: scheduler.diagnostics.validationIssues.isEmpty ? "Main app, shared data, and widget-readable snapshot match." : scheduler.diagnostics.validationIssues.joined(separator: " "),
                isError: !scheduler.diagnostics.validationIssues.isEmpty
            )
            diagnosticsRow(
                title: "Refresh trust",
                value: scheduler.refreshTrustAssessment.title,
                detail: scheduler.refreshTrustAssessment.basis,
                isError: scheduler.refreshTrustAssessment.isError
            )
            diagnosticsRow(
                title: "Widget trust",
                value: widgetTrustAssessment.title,
                detail: widgetTrustAssessment.basis,
                isError: widgetTrustAssessment.isError
            )
            diagnosticsRow(
                title: "Last refresh",
                value: scheduler.lastScanAt.map { snapshotTimeLabel($0) } ?? "Unavailable",
                detail: scheduler.lastScanAt.map { formattedDate($0) } ?? "No successful refresh recorded yet.",
                isError: scheduler.lastScanAt == nil
            )
            diagnosticsRow(
                title: "Generated at",
                value: scheduler.diagnostics.lastGeneratedAt.map { snapshotTimeLabel($0) } ?? "Unavailable",
                detail: scheduler.diagnostics.lastGeneratedAt ?? "No generatedAt captured yet.",
                isError: scheduler.diagnostics.lastGeneratedAt == nil
            )
            diagnosticsRow(
                title: "Written at",
                value: scheduler.diagnostics.lastWrittenAt.map { snapshotTimeLabel($0) } ?? "Unavailable",
                detail: scheduler.diagnostics.lastWrittenAt ?? "No writtenAt captured yet.",
                isError: scheduler.diagnostics.lastWrittenAt == nil
            )
            diagnosticsRow(
                title: "Reload requested",
                value: scheduler.diagnostics.lastReloadRequestedAt.map { snapshotTimeLabel($0) } ?? "Unavailable",
                detail: scheduler.diagnostics.lastReloadRequestedAt.map { formattedDate($0) } ?? "Widget reload has not been requested yet.",
                isError: scheduler.diagnostics.lastReloadRequestedAt == nil
            )
        }
    }

    private var diagnosticsOverview: DiagnosticsOverviewModel {
        DiagnosticsOverviewBuilder.build(
            diagnostics: scheduler.diagnostics,
            refreshTrust: scheduler.refreshTrustAssessment,
            widgetTrust: widgetTrustAssessment,
            repositories: scheduler.lastResult.repositories
        )
    }

    private var widgetSummarySectionModel: DiagnosticsSectionModel {
        diagnosticsOverview.sections.first(where: { $0.id == "widget-state" })
            ?? DiagnosticsSectionModel(
                id: "widget-state",
                title: "Widget 状态",
                summary: "Widget 状态暂不可用。",
                severity: .warning,
                items: []
            )
    }

    private var widgetSummarySeverity: DiagnosticsSeverity {
        widgetSummarySectionModel.severity
    }

    private var widgetSummaryHighlights: [DiagnosticsStatusItem] {
        widgetSummarySectionModel.items.filter {
            $0.id == "widget-trust" || $0.id == "validation"
        }
    }

    private var diagnosticsSnapshotFactsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Snapshot facts")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(snapshotFactsUpdatedLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(snapshotFactsSummary)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(alignment: .top, spacing: 8) {
                diagnosticsCompactBadge(
                    title: "Chain",
                    value: snapshotChainSummary,
                    severity: snapshotChainSeverity
                )
                diagnosticsCompactBadge(
                    title: "Snapshot",
                    value: snapshotReadableSummary,
                    severity: snapshotReadableSeverity
                )
                diagnosticsCompactBadge(
                    title: "Consistency",
                    value: snapshotConsistencySummary,
                    severity: snapshotConsistencySeverity
                )
            }

            Text("Detailed evidence")
                .font(.caption.weight(.semibold))
            Text("Container paths, snapshot file paths, raw timestamps, and read/write evidence are kept here for deeper troubleshooting.")
                .font(.caption2)
                .foregroundColor(.secondary)

            DisclosureGroup("Show raw diagnostics details") {
                VStack(alignment: .leading, spacing: 8) {
                    diagnosticsStatusGrid
                }
                .padding(.top, 8)
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private var diagnosticsSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(diagnosticsOverview.sections) { section in
                diagnosticsSectionCard(section)
            }
        }
    }

    private var sharedReadStatus: String {
        if scheduler.diagnostics.sharedDataReadError != nil {
            return "Failed"
        }
        if scheduler.diagnostics.sharedDataSnapshot != nil {
            return "Success"
        }
        return "Pending"
    }

    private var sharedReadDetail: String {
        if scheduler.diagnostics.sharedDataReadError != nil {
            return scheduler.diagnostics.sharedDataReadError ?? "Shared data read failed."
        }
        if scheduler.diagnostics.sharedDataSnapshot != nil {
            return scheduler.diagnostics.sharedDataReadAt.map { "最近读回：\(formattedDate($0))" }
                ?? "共享快照已成功读回。"
        }
        return "Waiting for the first App Group read-back after launch."
    }

    private var sharedWriteStatus: String {
        if scheduler.diagnostics.sharedDataWriteError != nil {
            return "Failed"
        }
        if scheduler.diagnostics.lastSharedWriteAt != nil {
            return "Success"
        }
        return "Pending"
    }

    private var sharedWriteDetail: String {
        if scheduler.diagnostics.sharedDataWriteError != nil {
            return scheduler.diagnostics.sharedDataWriteError ?? "Shared data write failed."
        }
        if scheduler.diagnostics.lastSharedWriteAt != nil {
            return scheduler.diagnostics.lastSharedWriteAt.map { "最近写入：\(formattedDate($0))" }
                ?? "共享快照已成功写入。"
        }
        return "Waiting for the first verified snapshot write."
    }

    private var widgetSnapshotStatus: String {
        if scheduler.diagnostics.widgetSnapshotReadError != nil {
            return "Failed"
        }
        if scheduler.diagnostics.widgetSnapshot != nil {
            return "Readable"
        }
        return "Pending"
    }

    private var widgetSnapshotDetail: String {
        if scheduler.diagnostics.widgetSnapshotReadError != nil {
            return scheduler.diagnostics.widgetSnapshotReadError ?? "Widget snapshot read failed."
        }
        if let widgetSnapshot = scheduler.diagnostics.widgetSnapshot {
            let readSummary = scheduler.diagnostics.widgetSnapshotReadAt.map { "最近读取：\(formattedDate($0))" }
                ?? "Widget 已读到共享快照。"
            let timestampSummary = widgetSnapshot.writtenAt
                .map { "writtenAt: \($0)" }
                ?? "writtenAt 缺失"
            return "\(readSummary) · repos \(widgetSnapshot.repositories.count) · \(timestampSummary)"
        }
        return "Waiting for the widget-readable snapshot after launch."
    }

    private var widgetTrustAssessment: SnapshotTrustAssessment {
        RefreshStatusFormatter.snapshotAssessment(
            generatedAt: scheduler.diagnostics.widgetSnapshot?.generatedAt,
            writtenAt: scheduler.diagnostics.widgetSnapshot?.writtenAt,
            readError: scheduler.diagnostics.widgetSnapshotReadError,
            missingReason: "Widget 侧还没有拿到可用快照时间。"
        )
    }

    private var launchAtLoginSeverity: DiagnosticsSeverity {
        switch launchAtLoginController.diagnostics.severity {
        case .normal:
            return .normal
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }

    private var launchAtLoginStatusLabel: String {
        switch launchAtLoginController.status {
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Approval Required"
        case .notRegistered:
            return "Disabled"
        case .notFound:
            return "App Not Found"
        case .unknown:
            return "Unknown"
        }
    }

    private var launchAtLoginOperationLabel: String {
        if launchAtLoginController.isUpdating {
            return "Updating"
        }
        if launchAtLoginController.lastOperationSucceeded == true {
            return "Succeeded"
        }
        if launchAtLoginController.lastOperationSucceeded == false {
            return "Failed"
        }
        return "Not run"
    }

    private var launchAtLoginOperationDetail: String {
        if launchAtLoginController.isUpdating {
            return "正在更新系统登录项状态。"
        }
        if let lastError = launchAtLoginController.lastError {
            return lastError
        }
        if launchAtLoginController.lastOperationSucceeded == true {
            return "最近一次切换已被系统接受，并已刷新当前状态。"
        }
        return "尚未在本次启动中切换过开机启动。"
    }

    private var launchAtLoginOperationSeverity: DiagnosticsSeverity {
        if launchAtLoginController.lastOperationSucceeded == false {
            return .error
        }
        if launchAtLoginController.lastOperationSucceeded == true {
            return .normal
        }
        return .warning
    }

    private func diagnosticsRow(title: String, value: String, detail: String, isError: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(isError ? .red : .primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func diagnosticsSectionCard(_ section: DiagnosticsSectionModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(section.title, systemImage: severitySymbol(section.severity))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(severityColor(section.severity))
                Spacer()
                Text(section.summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }

            if let timeHint = diagnosticsSectionTimeHint(section) {
                Label(timeHint, systemImage: "clock")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(section.items) { item in
                        diagnosticsInsightRow(item)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private func diagnosticsCompactBadge(title: String, value: String, severity: DiagnosticsSeverity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundColor(severityColor(severity))
            Text(value)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.35))
        .cornerRadius(6)
    }

    private func diagnosticsInlineStatusPill(title: String, value: String, severity: DiagnosticsSeverity) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundColor(severityColor(severity))
            Text(value)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.3))
        .cornerRadius(6)
    }

    private func diagnosticsStatusSummaryRow(_ item: DiagnosticsStatusItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(item.value)
                .font(.caption.weight(.semibold))
                .foregroundColor(severityColor(item.severity))
            Spacer(minLength: 0)
        }
    }

    private func diagnosticsSectionTimeHint(_ section: DiagnosticsSectionModel) -> String? {
        switch section.id {
        case "shared-data":
            var parts: [String] = []

            if let writeAt = scheduler.diagnostics.lastSharedWriteAt {
                parts.append("最近写入 \(snapshotTimeLabel(writeAt))")
            }
            if let readAt = scheduler.diagnostics.sharedDataReadAt {
                parts.append("最近读回 \(snapshotTimeLabel(readAt))")
            }

            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "widget-state":
            var parts: [String] = []

            if let readAt = scheduler.diagnostics.widgetSnapshotReadAt {
                parts.append("最近读取 \(snapshotTimeLabel(readAt))")
            }
            if let reloadAt = scheduler.diagnostics.lastReloadRequestedAt {
                parts.append("最近 reload \(snapshotTimeLabel(reloadAt))")
            }

            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "scan-state":
            if let lastScanAt = scheduler.lastScanAt {
                return "最近刷新 \(snapshotTimeLabel(lastScanAt))"
            }
            return nil
        default:
            return nil
        }
    }

    private func diagnosticsInsightRow(_ item: DiagnosticsStatusItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(item.value)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(severityColor(item.severity))
            }

            Text(item.detail)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(3)

            if let nextStep = item.nextStep {
                Label(nextStep, systemImage: "arrow.right.circle")
                    .font(.caption2)
                    .foregroundColor(severityColor(item.severity))
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private var diagnosticsRepositorySummary: String {
        let repositories = scheduler.lastResult.repositories
        guard !repositories.isEmpty else { return "0 repos" }

        let changedCount = repositories.filter {
            $0.status != .clean || $0.changedFileCount > 0 || ($0.aheadCount ?? 0) > 0
        }.count

        return changedCount == 0
            ? "\(repositories.count) repos · all clean"
            : "\(repositories.count) repos · \(changedCount) active"
    }

    private func diagnosticsRepositoryCompactRow(_ repo: RepositorySnapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(repo.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    diagnosticsRepositoryBranchLabel(repo)
                }

                Text(repo.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(repo.statusSummary) · \(diagnosticsRepositoryActionSummary(repo))")
                    .font(.caption2)
                    .foregroundColor(diagnosticsRepositoryStatusColor(repo))
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("提交 \(snapshotTimeLabel(repo.lastChangedAt))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text("扫描 \(snapshotTimeLabel(repo.lastScannedAt))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func severityColor(_ severity: DiagnosticsSeverity) -> Color {
        switch severity {
        case .normal:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private func severityBackground(_ severity: DiagnosticsSeverity) -> Color {
        switch severity {
        case .normal:
            return Color.green.opacity(0.08)
        case .warning:
            return Color.orange.opacity(0.08)
        case .error:
            return Color.red.opacity(0.08)
        }
    }

    private func severitySymbol(_ severity: DiagnosticsSeverity) -> String {
        switch severity {
        case .normal:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.circle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private func diagnosticsRepositoryRow(_ repo: RepositorySnapshot) -> some View {
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(repo.name)
                    .font(.caption.weight(.semibold))

                Spacer()
                diagnosticsRepositoryBranchLabel(repo)
            }

            Text(repo.path)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("状态摘要 · \(repo.statusSummary)")
                .font(.caption2)
                .foregroundColor(diagnosticsRepositoryStatusColor(repo))

            Text("建议动作 · \(repo.nextActionHint)")
                .font(.caption2)
                .foregroundColor(diagnosticsRepositoryActionColor(repo))

            HStack(spacing: 8) {
                Text("最近提交 · \(snapshotTimeLabel(repo.lastChangedAt))")
                Text("扫描时间 · \(snapshotTimeLabel(repo.lastScannedAt))")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.white.opacity(0.35))
        .cornerRadius(6)
    }

    private func diagnosticsRepositoryBranchLabel(_ repo: RepositorySnapshot) -> some View {
        HStack(spacing: 4) {
            Image(systemName: diagnosticsRepositoryBranchIconName(repo))
                .font(.system(size: 10, weight: .medium))
            Text(repo.branch)
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(diagnosticsRepositoryBranchColor(repo))
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(
            Capsule()
                .fill(diagnosticsRepositoryBranchColor(repo).opacity(diagnosticsRepositoryBranchFillOpacity(repo)))
        )
    }

    private func diagnosticsRepositoryStatusColor(_ repo: RepositorySnapshot) -> Color {
        switch repo.commitReadiness.level {
        case .dirty, .unknown:
            return .red
        case .ready:
            return .green
        case .idle, .review:
            return .secondary
        }
    }

    private func diagnosticsRepositoryActionColor(_ repo: RepositorySnapshot) -> Color {
        switch repo.commitReadiness.level {
        case .unknown:
            return .red
        case .dirty, .review:
            return .orange
        case .ready:
            return .green
        case .idle:
            return .secondary
        }
    }

    private func diagnosticsRepositoryBranchIconName(_ repo: RepositorySnapshot) -> String {
        switch repo.commitReadiness.level {
        case .dirty, .unknown:
            return "exclamationmark.triangle.fill"
        case .ready:
            return "checkmark.circle.fill"
        case .idle, .review:
            return "arrow.triangle.branch"
        }
    }

    private func diagnosticsRepositoryBranchColor(_ repo: RepositorySnapshot) -> Color {
        switch repo.commitReadiness.level {
        case .dirty, .unknown:
            return .red
        case .ready:
            return .green
        case .idle, .review:
            return .secondary
        }
    }

    private func diagnosticsRepositoryBranchFillOpacity(_ repo: RepositorySnapshot) -> Double {
        switch repo.commitReadiness.level {
        case .dirty, .unknown:
            return 0.14
        case .ready:
            return 0.12
        case .idle, .review:
            return 0.08
        }
    }

    private func diagnosticsEventRow(_ event: DiagnosticEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(event.kind.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundColor(event.kind == .validationFailed || event.kind == .sharedDataWriteFailed || event.kind == .sharedDataReadFailed ? .red : .secondary)
                .frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message)
                    .font(.caption)
                Text(snapshotTimeLabel(DateFormatting.date(from: event.timestamp)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var diagnosticsEventPreview: [DiagnosticEvent] {
        Array(scheduler.diagnosticEvents.reversed().prefix(3))
    }

    private var diagnosticsEventSummary: String {
        scheduler.diagnosticEvents.isEmpty ? "No events" : "\(scheduler.diagnosticEvents.count) recorded"
    }

    private var diagnosticsEventHeadline: String {
        guard let latest = scheduler.diagnosticEvents.last else { return "No recent events" }
        return latest.message
    }

    private var diagnosticsTopSummaryHint: String {
        diagnosticsOverview.summary
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "，", with: " · ")
    }

    private var diagnosticsEventSeverity: DiagnosticsSeverity {
        if scheduler.diagnosticEvents.contains(where: {
            $0.kind == .validationFailed
                || $0.kind == .sharedDataWriteFailed
                || $0.kind == .sharedDataReadFailed
                || $0.kind == .scanFailed
        }) {
            return .error
        }
        return .normal
    }

    private func diagnosticsEventSummaryRow(_ event: DiagnosticEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.kind.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundColor(diagnosticsEventColor(event))
            Text(event.message)
                .font(.caption2)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(snapshotTimeLabel(DateFormatting.date(from: event.timestamp)))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func diagnosticsEventColor(_ event: DiagnosticEvent) -> Color {
        switch event.kind {
        case .validationFailed, .sharedDataWriteFailed, .sharedDataReadFailed, .scanFailed:
            return .red
        default:
            return .secondary
        }
    }

    private var snapshotFactsSummary: String {
        "\(snapshotChainSummary) · \(snapshotReadableSummary) · \(snapshotConsistencySummary)"
    }

    private func diagnosticsRepositoryActionSummary(_ repo: RepositorySnapshot) -> String {
        let readiness = repo.commitReadiness

        if repo.status == .error || readiness.level == .unknown {
            return "看 Diagnostics"
        }
        if readiness.reasons.contains(.conflictedFiles) {
            return "先解冲突"
        }
        if readiness.reasons.contains(.branchNeedsConfirmation) {
            return "确认分支"
        }
        if readiness.reasons.contains(.localAhead), (repo.aheadCount ?? 0) > 0 {
            return "准备好就 push"
        }
        if readiness.reasons.contains(.stagedChanges) {
            return "可提交"
        }
        if readiness.reasons.contains(.mixedStagedAndUnstagedChanges) {
            return "先整理暂存"
        }
        if readiness.reasons.contains(.highRiskChanges), readiness.level == .dirty {
            return "先收敛并验证"
        }
        if readiness.reasons.contains(.largeWorkingTree) {
            return "先收敛改动"
        }
        if readiness.reasons.contains(.deletedFiles), repo.deletedFileCount > 0 {
            return "检查删除项"
        }
        if readiness.reasons.contains(.untrackedFiles), repo.untrackedFileCount > 0 {
            return "确认新文件"
        }
        if readiness.reasons.contains(.highRiskChanges) || repo.risk == .medium || repo.risk == .high {
            return "先看 diff 并验证"
        }

        switch readiness.level {
        case .idle:
            return "无需操作"
        case .ready:
            return "可提交或分享"
        case .review:
            return "先看 diff"
        case .dirty:
            return "先整理改动"
        case .unknown:
            return "看 Diagnostics"
        }
    }

    private var snapshotFactsUpdatedLabel: String {
        if let lastWrittenAt = scheduler.diagnostics.lastWrittenAt {
            return "最近更新 \(snapshotTimeLabel(lastWrittenAt))"
        }
        if let lastGeneratedAt = scheduler.diagnostics.lastGeneratedAt {
            return "最近更新 \(snapshotTimeLabel(lastGeneratedAt))"
        }
        if let lastScanAt = scheduler.lastScanAt {
            return "最近更新 \(snapshotTimeLabel(lastScanAt))"
        }
        return "未更新"
    }

    private var snapshotChainSummary: String {
        snapshotChainSeverity == .normal ? "链路正常" : "链路异常"
    }

    private var snapshotChainSeverity: DiagnosticsSeverity {
        if !scheduler.appGroupAvailable || sharedWriteStatus == "Failed" || sharedReadStatus == "Failed" {
            return .error
        }
        if sharedWriteStatus == "Pending" || sharedReadStatus == "Pending" {
            return .warning
        }
        return .normal
    }

    private var snapshotReadableSummary: String {
        if scheduler.diagnostics.snapshotDecodable {
            return "快照可读"
        }
        if scheduler.diagnostics.snapshotReadable {
            return "快照可访问"
        }
        return "快照不可读"
    }

    private var snapshotReadableSeverity: DiagnosticsSeverity {
        if !scheduler.diagnostics.snapshotReadable || !scheduler.diagnostics.snapshotDecodable {
            return .error
        }
        return .normal
    }

    private var snapshotConsistencySummary: String {
        scheduler.diagnostics.validationIssues.isEmpty ? "数据一致" : "数据不一致"
    }

    private var snapshotConsistencySeverity: DiagnosticsSeverity {
        scheduler.diagnostics.validationIssues.isEmpty ? .normal : .error
    }

    private func refreshBuiltInToggles() {
        let enabledPaths = Set(scheduler.scanDirectories.map(\.path))
        builtInToggles = ScanLocationProvider.builtInToggles(enabledPaths)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            scheduler.addCustomPath(url.path)
            newCustomPath = ""
        }
    }

    private func snapshotTimeLabel(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return formattedDate(date)
    }

    private func snapshotTimeLabel(_ iso: String?) -> String {
        guard let iso, let date = DateFormatting.date(from: iso) else { return "unknown" }
        return formattedDate(date)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

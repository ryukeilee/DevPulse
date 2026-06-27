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
                Label("Diagnostics", systemImage: "stethoscope")
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

            launchAtLoginDiagnosticsSection
            diagnosticsOverviewCard
            diagnosticsSnapshotFactsSection
            diagnosticsSections
            diagnosticsScanRootsSection

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

            VStack(alignment: .leading, spacing: 8) {
                Text("Current repositories")
                    .font(.caption.weight(.semibold))

                if scheduler.lastResult.repositories.isEmpty {
                    Text("No repositories in the latest snapshot.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(scheduler.lastResult.repositories) { repo in
                            diagnosticsRepositoryRow(repo)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent events")
                    .font(.caption.weight(.semibold))

                if scheduler.diagnosticEvents.isEmpty {
                    Text("No diagnostic events yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(scheduler.diagnosticEvents.reversed())) { event in
                                diagnosticsEventRow(event)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
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

    private var diagnosticsOverviewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(diagnosticsOverview.headline, systemImage: severitySymbol(diagnosticsOverview.severity))
                .font(.caption.weight(.semibold))
                .foregroundColor(severityColor(diagnosticsOverview.severity))
            Text(diagnosticsOverview.summary)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding(10)
        .background(severityBackground(diagnosticsOverview.severity))
        .cornerRadius(8)
    }

    private var diagnosticsSnapshotFactsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Snapshot facts")
                .font(.caption.weight(.semibold))
            diagnosticsStatusGrid
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private var launchAtLoginDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Launch at login", systemImage: severitySymbol(launchAtLoginSeverity))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(severityColor(launchAtLoginSeverity))
                Spacer()
                Text(launchAtLoginStatusLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            diagnosticsInsightRow(
                DiagnosticsStatusItem(
                    id: "launch-at-login-system-status",
                    title: "System status",
                    value: launchAtLoginStatusLabel,
                    detail: launchAtLoginController.diagnostics.detail,
                    nextStep: launchAtLoginController.diagnostics.nextStep,
                    severity: launchAtLoginSeverity
                )
            )

            diagnosticsInsightRow(
                DiagnosticsStatusItem(
                    id: "launch-at-login-last-action",
                    title: "Last action",
                    value: launchAtLoginOperationLabel,
                    detail: launchAtLoginOperationDetail,
                    nextStep: launchAtLoginController.lastError == nil ? nil : "切换失败时不会读取仓库内容，只需检查系统登录项授权。",
                    severity: launchAtLoginOperationSeverity
                )
            )
        }
        .padding(10)
        .background(severityBackground(launchAtLoginSeverity))
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

            ForEach(section.items) { item in
                diagnosticsInsightRow(item)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
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
        let receipt = repo.commitReadiness.reviewReceipt

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(repo.name)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(repo.branch)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(repo.path)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("staged \(repo.stagedFileCount ?? 0) · unstaged \(repo.unstagedFileCount ?? (repo.modifiedFileCount + repo.addedFileCount + repo.deletedFileCount)) · untracked \(repo.untrackedFileCount) · total \(repo.changedFileCount)")
                .font(.caption2)
                .foregroundColor(.secondary)

            Text("readiness \(repo.commitReadiness.shortLabel) · \(receipt.summary)")
                .font(.caption2)
                .foregroundColor(repo.commitReadiness.level == .unknown ? .red : .secondary)

            Text("review receipt · \(receipt.nextStep)")
                .font(.caption2)
                .foregroundColor(repo.commitReadiness.level == .unknown ? .red : .secondary)

            Text(receipt.basisSummary)
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Text("status \(repo.status.rawValue)")
                if let lastChangedAt = repo.lastChangedAt {
                    Text("last commit \(snapshotTimeLabel(DateFormatting.date(from: lastChangedAt)))")
                }
            }
            .font(.caption2)
            .foregroundColor(repo.commitReadiness.level == .unknown ? .red : .secondary)

            Text("scan \(snapshotTimeLabel(DateFormatting.date(from: repo.lastScannedAt)))")
                .font(.caption2)
                .foregroundColor(.secondary)

            if let errorMessage = repo.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.35))
        .cornerRadius(6)
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

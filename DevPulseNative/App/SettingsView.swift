import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @EnvironmentObject var launchAtLoginController: LaunchAtLoginController
    @Binding var scrollTarget: SettingsScrollTarget?
    @State private var newCustomPath: String = ""
    @State private var expandedDefaultScanPaths: Set<String> = []
    @State private var pendingIgnoreRepository: RepositorySnapshot?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    defaultScanLocationsSection
                    customScanDirectoriesSection
                    repositoryScanScopeSection
                    launchAtLoginSection
                    diagnosticsSection
                        .id(SettingsScrollTarget.diagnostics)
                }
                .padding(DevPulseVisualStyle.pageInset)
                .onAppear {
                    launchAtLoginController.refreshStatus()
                    scrollToTargetIfNeeded(using: proxy)
                }
                .onChange(of: scrollTarget) { _, _ in
                    scrollToTargetIfNeeded(using: proxy)
                }
            }
            .alert(item: $pendingIgnoreRepository) { repository in
                Alert(
                    title: Text("忽略 \(repository.name)？"),
                    message: Text("确认后，DevPulse 将不再扫描或显示此仓库；可在本页恢复。"),
                    primaryButton: .destructive(Text("忽略")) {
                        scheduler.ignoreRepository(path: repository.path)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
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
        VStack(alignment: .leading, spacing: 12) {
            settingsSectionHeader(
                title: "默认扫描目录",
                subtitle: "按分组启用常见目录；未找到的目录会直接提示，并提供可执行操作。",
                systemImage: "house"
            )

            ForEach(defaultScanGroups) { group in
                defaultScanGroupSection(group)
            }
        }
        .settingsSectionSurface()
    }

    // MARK: - Custom scan directories

    private var customScanDirectoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsSectionHeader(
                title: "自定义扫描目录",
                subtitle: "添加需要持续扫描的本地仓库根目录。",
                systemImage: "folder.badge.plus"
            )

            if !scheduler.scanDirectories.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(scheduler.scanDirectories.enumerated()), id: \.element.id) { index, directory in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(directory.path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !directoryExists(directory.path) {
                                Text("当前不存在")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            Spacer()
                            Button(role: .destructive) {
                                scheduler.removeCustomPath(directory.path)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("移除扫描目录")
                        }
                        .frame(minHeight: 36)
                        .padding(.horizontal, 10)

                        if index < scheduler.scanDirectories.count - 1 {
                            Divider()
                                .overlay(DevPulseVisualStyle.separator)
                                .padding(.leading, 32)
                        }
                    }
                }
                .settingsInnerSurface()
            }

            HStack(spacing: 8) {
                TextField("输入仓库根目录路径", text: $newCustomPath)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(DevPulseVisualStyle.strongerSurface)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DevPulseVisualStyle.separator, lineWidth: 0.5)
                    }
                Button("添加") {
                    let trimmed = newCustomPath.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    scheduler.addCustomPath(trimmed)
                    newCustomPath = ""
                }
                .buttonStyle(SettingsCompactButtonStyle())
                .disabled(newCustomPath.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("选择…") {
                    chooseDirectory()
                }
                .buttonStyle(SettingsCompactButtonStyle())
            }
        }
        .settingsSectionSurface()
    }

    // MARK: - Repository scan scope

    private var repositoryScanScopeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsSectionHeader(
                title: "仓库扫描范围",
                subtitle: "从当前扫描结果中忽略不需要关注的仓库，也可随时恢复。",
                systemImage: "line.3.horizontal.decrease.circle"
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("当前扫描中的仓库")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if scheduler.isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在扫描")
                    }
                    Text("\(scheduler.lastResult.repositories.count) 个")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if scheduler.lastResult.repositories.isEmpty {
                    Text("最近一次扫描还没有可管理的仓库。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(scheduler.lastResult.repositories.enumerated()), id: \.element.id) { index, repository in
                            activeRepositoryScopeRow(repository)

                            if index < scheduler.lastResult.repositories.count - 1 {
                                Divider()
                                    .overlay(DevPulseVisualStyle.separator)
                                    .padding(.leading, 30)
                            }
                        }
                    }
                    .settingsInnerSurface()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("已忽略仓库")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(scheduler.ignoredRepositories.count) 个")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if scheduler.ignoredRepositories.isEmpty {
                    Text("还没有忽略的仓库。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(scheduler.ignoredRepositories.enumerated()), id: \.element.id) { index, ignored in
                            ignoredRepositoryScopeRow(ignored)

                            if index < scheduler.ignoredRepositories.count - 1 {
                                Divider()
                                    .overlay(DevPulseVisualStyle.separator)
                                    .padding(.leading, 30)
                            }
                        }
                    }
                    .settingsInnerSurface()
                }
            }
        }
        .settingsSectionSurface()
    }

    private func activeRepositoryScopeRow(_ repository: RepositorySnapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(repository.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(RepositoryPathPresentation.compactPath(repository.path))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button("忽略", role: .destructive) {
                pendingIgnoreRepository = repository
            }
            .buttonStyle(SettingsCompactButtonStyle(tint: .orange))
            .help("忽略此仓库")
            .accessibilityLabel("忽略仓库：\(repository.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func ignoredRepositoryScopeRow(_ ignored: IgnoredRepository) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(ignored.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(ignored.displayPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button("恢复") {
                scheduler.restoreIgnoredRepository(path: ignored.path)
            }
            .buttonStyle(SettingsCompactButtonStyle())
            .help("恢复并立即重新扫描此仓库")
            .accessibilityLabel("恢复仓库：\(ignored.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Launch At Login

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsSectionHeader(
                title: "登录后启动",
                subtitle: "控制 DevPulse 是否在登录 macOS 后自动运行。",
                systemImage: "power.circle"
            )

            HStack(alignment: .center, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { launchAtLoginController.isEnabled },
                    set: { launchAtLoginController.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动启动 DevPulse")
                            .font(.caption.weight(.semibold))
                        Text(launchAtLoginStatusDetail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .disabled(launchAtLoginController.isUpdating)
                .layoutPriority(1)

                Spacer(minLength: 8)

                Label(launchAtLoginStatusLabel, systemImage: severitySymbol(launchAtLoginSeverity))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(severityColor(launchAtLoginSeverity))
                    .fixedSize()

                if launchAtLoginController.status == .requiresApproval || launchAtLoginController.status == .notFound {
                    Button("打开系统设置") {
                        launchAtLoginController.openSystemSettings()
                    }
                    .buttonStyle(SettingsCompactButtonStyle(tint: severityColor(launchAtLoginSeverity)))
                    .fixedSize()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(severityBackground(launchAtLoginSeverity))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .settingsSectionSurface()
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                settingsSectionHeader(
                    title: "状态诊断",
                    subtitle: "查看共享快照、Widget 与扫描链路的运行状态。",
                    systemImage: "stethoscope"
                )
                Spacer()
                Button(action: { scheduler.scanNow() }) {
                    Label(
                        scheduler.isScanning ? "刷新中…" : "刷新数据",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(SettingsCompactButtonStyle())
                .disabled(scheduler.isScanning)
            }

            DisclosureGroup("查看诊断明细") {
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
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    diagnosticsTopSummaryStrip
                    diagnosticsSections
                    diagnosticsSnapshotFactsSection
                    diagnosticsScanRootsSection
                    diagnosticsRepositoriesSection
                    diagnosticsEventsSection
                }
                .padding(.top, 8)
            }
            .font(.caption)
        }
        .settingsSectionSurface()
    }

    private func settingsSectionHeader(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var diagnosticsRepositoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("当前仓库")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(diagnosticsRepositorySummary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if scheduler.lastResult.repositories.isEmpty {
                Text("最近一次快照里还没有仓库。")
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
        .settingsInnerSurface()
    }

    private var diagnosticsEventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近事件")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(diagnosticsEventSummary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if scheduler.diagnosticEvents.isEmpty {
                Text("还没有诊断事件。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(diagnosticsEventPreview) { event in
                        diagnosticsEventSummaryRow(event)
                    }

                    if scheduler.diagnosticEvents.count > diagnosticsEventPreview.count {
                        DisclosureGroup("查看完整事件日志") {
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
        .settingsInnerSurface()
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
                    title: "共享链路",
                    value: diagnosticsOverview.sections.first(where: { $0.id == "shared-data" })?.summary ?? "暂不可用",
                    severity: diagnosticsOverview.sections.first(where: { $0.id == "shared-data" })?.severity ?? .warning
                )
                diagnosticsInlineStatusPill(
                    title: "小组件",
                    value: diagnosticsOverview.sections.first(where: { $0.id == "widget-state" })?.summary ?? "暂不可用",
                    severity: diagnosticsOverview.sections.first(where: { $0.id == "widget-state" })?.severity ?? .warning
                )
                diagnosticsInlineStatusPill(
                    title: "扫描状态",
                    value: diagnosticsOverview.sections.first(where: { $0.id == "scan-state" })?.summary ?? "暂不可用",
                    severity: diagnosticsOverview.sections.first(where: { $0.id == "scan-state" })?.severity ?? .warning
                )
            }
        }
        .padding(8)
        .background(severityBackground(diagnosticsOverview.severity))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var diagnosticsScanRootsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("扫描根目录")
                .font(.caption.weight(.semibold))

            if scheduler.diagnostics.scanRoots.isEmpty {
                Text("当前没有可访问的扫描根目录。")
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
        .settingsInnerSurface()
    }

    private var diagnosticsStatusGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            diagnosticsRow(
                title: "主应用标识",
                value: scheduler.diagnostics.appBundleIdentifier,
                detail: "主应用的标识符。",
                isError: false
            )
            diagnosticsRow(
                title: "小组件标识",
                value: scheduler.diagnostics.widgetBundleIdentifier,
                detail: "小组件扩展的标识符。",
                isError: false
            )
            diagnosticsRow(
                title: "共享组",
                value: scheduler.diagnostics.appGroupIdentifier,
                detail: scheduler.diagnostics.appGroupContainerPath ?? "当前拿不到共享组容器路径。",
                isError: !scheduler.appGroupAvailable
            )
            diagnosticsRow(
                title: "共享容器",
                value: scheduler.diagnostics.appGroupContainerPath ?? "不可用",
                detail: scheduler.diagnostics.appGroupAvailable ? "当前解析到的共享组容器路径。" : "检查权限声明与签名配置。",
                isError: !scheduler.appGroupAvailable
            )
            diagnosticsRow(
                title: "快照文件",
                value: scheduler.diagnostics.snapshotFilePath ?? "不可用",
                detail: scheduler.diagnostics.snapshotExists ? "共享 `repositories.json` 已存在。" : "共享 `repositories.json` 缺失。",
                isError: !scheduler.diagnostics.snapshotExists
            )
            diagnosticsRow(
                title: "快照存在",
                value: scheduler.diagnostics.snapshotExists ? "是" : "否",
                detail: scheduler.diagnostics.snapshotFilePath ?? "还没有解析到快照路径。",
                isError: !scheduler.diagnostics.snapshotExists
            )
            diagnosticsRow(
                title: "快照可读",
                value: scheduler.diagnostics.snapshotReadable ? "是" : "否",
                detail: scheduler.diagnostics.snapshotReadable ? "主 App 可以读取该文件。" : "主 App 目前无法读取该文件。",
                isError: !scheduler.diagnostics.snapshotReadable
            )
            diagnosticsRow(
                title: "快照可写",
                value: scheduler.diagnostics.snapshotWritable ? "是" : "否",
                detail: scheduler.diagnostics.snapshotWritable ? "文件或容器当前可写。" : "文件或容器当前不可写。",
                isError: !scheduler.diagnostics.snapshotWritable
            )
            diagnosticsRow(
                title: "快照可解码",
                value: scheduler.diagnostics.snapshotDecodable ? "是" : "否",
                detail: scheduler.diagnostics.snapshotDecodable ? "共享快照已成功解码。" : (scheduler.diagnostics.sharedDataReadError ?? "共享快照尚未成功解码。"),
                isError: !scheduler.diagnostics.snapshotDecodable
            )
            diagnosticsRow(
                title: "共享读回",
                value: sharedReadStatus,
                detail: sharedReadDetail,
                isError: sharedReadStatus == "失败"
            )
            diagnosticsRow(
                title: "共享写入",
                value: sharedWriteStatus,
                detail: sharedWriteDetail,
                isError: sharedWriteStatus == "失败"
            )
            diagnosticsRow(
                title: "小组件快照",
                value: widgetSnapshotStatus,
                detail: widgetSnapshotDetail,
                isError: widgetSnapshotStatus == "失败"
            )
            diagnosticsRow(
                title: "一致性校验",
                value: scheduler.diagnostics.validationIssues.isEmpty ? "通过" : "不一致",
                detail: scheduler.diagnostics.validationIssues.isEmpty ? "主应用、共享数据与小组件可读快照当前一致。" : scheduler.diagnostics.validationIssues.joined(separator: " "),
                isError: !scheduler.diagnostics.validationIssues.isEmpty
            )
            diagnosticsRow(
                title: "刷新可信度",
                value: scheduler.refreshTrustAssessment.title,
                detail: scheduler.refreshTrustAssessment.basis,
                isError: scheduler.refreshTrustAssessment.isError
            )
            diagnosticsRow(
                title: "小组件可信度",
                value: widgetTrustAssessment.title,
                detail: widgetTrustAssessment.basis,
                isError: widgetTrustAssessment.isError
            )
            diagnosticsRow(
                title: "最近扫描完成",
                value: scheduler.lastScanAt.map { snapshotTimeLabel($0) } ?? "不可用",
                detail: scheduler.lastScanAt.map { formattedDate($0) } ?? "还没有扫描完成记录。",
                isError: scheduler.lastScanAt == nil
            )
            diagnosticsRow(
                title: "生成时间",
                value: scheduler.diagnostics.lastGeneratedAt.map { snapshotTimeLabel($0) } ?? "不可用",
                detail: scheduler.diagnostics.lastGeneratedAt ?? "还没有记录生成时间。",
                isError: scheduler.diagnostics.lastGeneratedAt == nil
            )
            diagnosticsRow(
                title: "写入时间",
                value: scheduler.diagnostics.lastWrittenAt.map { snapshotTimeLabel($0) } ?? "不可用",
                detail: scheduler.diagnostics.lastWrittenAt ?? "还没有记录写入时间。",
                isError: scheduler.diagnostics.lastWrittenAt == nil
            )
            diagnosticsRow(
                title: "请求重载",
                value: scheduler.diagnostics.lastReloadRequestedAt.map { snapshotTimeLabel($0) } ?? "不可用",
                detail: scheduler.diagnostics.lastReloadRequestedAt.map { formattedDate($0) } ?? "还没有请求过小组件重载。",
                isError: scheduler.diagnostics.lastReloadRequestedAt == nil
            )
            diagnosticsRow(
                title: "刷新开始",
                value: scheduler.diagnostics.lastRefreshStartedAt.map { snapshotTimeLabel($0) } ?? "不可用",
                detail: scheduler.diagnostics.lastRefreshStartedAt.map { formattedDate($0) } ?? "还没有刷新开始时间记录。",
                isError: scheduler.diagnostics.lastRefreshStartedAt == nil
            )
            diagnosticsRow(
                title: "刷新完成",
                value: scheduler.diagnostics.lastRefreshCompletedAt.map { snapshotTimeLabel($0) } ?? "不可用",
                detail: scheduler.diagnostics.lastRefreshCompletedAt.map { formattedDate($0) } ?? "还没有刷新完成时间记录。",
                isError: scheduler.diagnostics.lastRefreshCompletedAt == nil
            )
            diagnosticsRow(
                title: "快照存储",
                value: snapshotStoreStateLabel,
                detail: snapshotStoreStateDetail,
                isError: scheduler.diagnostics.lastSnapshotStoreState == .failed
            )
            diagnosticsRow(
                title: "触发来源",
                value: snapshotStoreTriggerLabel,
                detail: snapshotStoreTriggerDetail,
                isError: false
            )
            diagnosticsRow(
                title: "重载决策",
                value: widgetReloadStateLabel,
                detail: widgetReloadStateDetail,
                isError: false
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

    private var diagnosticsSnapshotFactsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("原始诊断证据")
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
                    title: "链路",
                    value: snapshotChainSummary,
                    severity: snapshotChainSeverity
                )
                diagnosticsCompactBadge(
                    title: "快照",
                    value: snapshotReadableSummary,
                    severity: snapshotReadableSeverity
                )
                diagnosticsCompactBadge(
                    title: "一致性",
                    value: snapshotConsistencySummary,
                    severity: snapshotConsistencySeverity
                )
            }

            Text("原始字段")
                .font(.caption.weight(.semibold))
            Text("共享容器路径、快照文件路径、原始时间戳与读写证据都保留在这里，用于进一步排查。")
                .font(.caption2)
                .foregroundColor(.secondary)

            DisclosureGroup("查看原始诊断字段") {
                VStack(alignment: .leading, spacing: 8) {
                    diagnosticsStatusGrid
                }
                .padding(.top, 8)
            }
            .font(.caption)
        }
        .padding(10)
        .settingsInnerSurface()
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
            return "失败"
        }
        if scheduler.diagnostics.sharedDataSnapshot != nil {
            return "成功"
        }
        return "等待中"
    }

    private var sharedReadDetail: String {
        if scheduler.diagnostics.sharedDataReadError != nil {
            return scheduler.diagnostics.sharedDataReadError ?? "共享数据读取失败。"
        }
        if scheduler.diagnostics.sharedDataSnapshot != nil {
            return scheduler.diagnostics.sharedDataReadAt.map { "最近读回：\(formattedDate($0))" }
                ?? "共享快照已成功读回。"
        }
        return "启动后还在等待第一次共享快照读回。"
    }

    private var sharedWriteStatus: String {
        if scheduler.diagnostics.sharedDataWriteError != nil {
            return "失败"
        }
        if scheduler.diagnostics.lastSharedWriteAt != nil {
            return "成功"
        }
        return "等待中"
    }

    private var sharedWriteDetail: String {
        if scheduler.diagnostics.sharedDataWriteError != nil {
            return scheduler.diagnostics.sharedDataWriteError ?? "共享数据写入失败。"
        }
        if scheduler.diagnostics.lastSharedWriteAt != nil {
            return scheduler.diagnostics.lastSharedWriteAt.map { "最近写入：\(formattedDate($0))" }
                ?? "共享快照已成功写入。"
        }
        return "还在等待第一次已校验的快照写入。"
    }

    private var widgetSnapshotStatus: String {
        if scheduler.diagnostics.widgetSnapshotReadError != nil {
            return "失败"
        }
        if scheduler.diagnostics.widgetSnapshot != nil {
            return "可读取"
        }
        return "等待中"
    }

    private var widgetSnapshotDetail: String {
        if scheduler.diagnostics.widgetSnapshotReadError != nil {
            return scheduler.diagnostics.widgetSnapshotReadError ?? "小组件快照读取失败。"
        }
        if let widgetSnapshot = scheduler.diagnostics.widgetSnapshot {
            let readSummary = scheduler.diagnostics.widgetSnapshotReadAt.map { "最近读取：\(formattedDate($0))" }
                ?? "小组件已读到共享快照。"
            let timestampSummary = widgetSnapshot.writtenAt
                .map { "写入时间：\($0)" }
                ?? "写入时间缺失"
            return "\(readSummary) · 仓库 \(widgetSnapshot.repositories.count) 个 · \(timestampSummary)"
        }
        return "启动后还在等待小组件可读快照。"
    }

    private var widgetTrustAssessment: SnapshotTrustAssessment {
        if let snapshot = scheduler.diagnostics.widgetSnapshot {
            return RefreshStatusFormatter.snapshotAssessment(
                snapshot: snapshot,
                readError: scheduler.diagnostics.widgetSnapshotReadError,
                missingReason: "小组件侧还没有拿到可证明的完整成功刷新时间。"
            )
        }
        return RefreshStatusFormatter.snapshotAssessment(
            generatedAt: nil,
            writtenAt: nil,
            readError: scheduler.diagnostics.widgetSnapshotReadError,
            missingReason: "小组件侧还没有拿到可用快照时间。"
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
            return "已启用"
        case .requiresApproval:
            return "等待批准"
        case .notRegistered:
            return "未启用"
        case .notFound:
            return "未找到应用"
        case .unknown:
            return "状态未知"
        }
    }

    private var launchAtLoginStatusDetail: String {
        if launchAtLoginController.isUpdating {
            return "正在更新系统登录项状态。"
        }
        return launchAtLoginController.diagnostics.detail
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

            DisclosureGroup("查看明细") {
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
        .settingsInnerSurface()
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
        .background(DevPulseVisualStyle.strongerSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        .background(DevPulseVisualStyle.strongerSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        case "snapshot-store":
            var parts: [String] = []

            if let startedAt = scheduler.diagnostics.lastRefreshStartedAt {
                parts.append("开始 \(snapshotTimeLabel(startedAt))")
            }
            if let completedAt = scheduler.diagnostics.lastRefreshCompletedAt {
                parts.append("结束 \(snapshotTimeLabel(completedAt))")
            }

            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "widget-state":
            var parts: [String] = []

            if let readAt = scheduler.diagnostics.widgetSnapshotReadAt {
                parts.append("最近读取 \(snapshotTimeLabel(readAt))")
            }
            if let reloadAt = scheduler.diagnostics.lastReloadRequestedAt {
                parts.append("最近重载 \(snapshotTimeLabel(reloadAt))")
            }

            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "scan-state":
            if let lastScanAt = scheduler.lastScanAt {
                return "最近扫描 \(snapshotTimeLabel(lastScanAt))"
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
        guard !repositories.isEmpty else { return "0 个仓库" }

        let currentActiveCount = repositories.filter {
            let decision = $0.decision
            return decision.dataTrust == .current
                && decision.primaryAction.kind != .noActionNeeded
        }.count
        let unavailableCount = repositories.filter {
            $0.decision.dataTrust != .current
        }.count

        if currentActiveCount == 0, unavailableCount == 0 {
            return "\(repositories.count) 个仓库 · 全部干净"
        }

        var parts = ["\(repositories.count) 个仓库"]
        if currentActiveCount > 0 {
            parts.append("\(currentActiveCount) 个当前有活动")
        }
        if unavailableCount > 0 {
            parts.append("\(unavailableCount) 个状态待确认")
        }
        return parts.joined(separator: " · ")
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
                Text(repositoryCommitTimeLabel(repo, compact: true))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(repositoryScanTimeLabel(repo))
                    .font(.caption2)
                    .foregroundColor(repositoryDataSourceColor(repo))
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
                Text(repositoryCommitTimeLabel(repo))
                Text(repositoryScanTimeLabel(repo))
            }
            .font(.caption2)
            .foregroundColor(repositoryDataSourceColor(repo))
        }
        .padding(8)
        .background(DevPulseVisualStyle.strongerSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func diagnosticsRepositoryBranchLabel(_ repo: RepositorySnapshot) -> some View {
        HStack(spacing: 4) {
            Image(systemName: diagnosticsRepositoryBranchIconName(repo))
                .font(.system(size: 10, weight: .medium))
            Text(repo.branchDisplayLabel)
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

    private func repositoryScanTimeLabel(_ repo: RepositorySnapshot) -> String {
        switch repo.resolvedDataSource {
        case .current:
            return "当前扫描 · \(snapshotTimeLabel(repo.lastScannedAt))"
        case .lastSuccessful:
            return "上次成功扫描 · \(snapshotTimeLabel(repo.resolvedLastSuccessfulScanAt))"
        case .unknown:
            return "扫描状态未知"
        }
    }

    private func repositoryCommitTimeLabel(
        _ repo: RepositorySnapshot,
        compact: Bool = false
    ) -> String {
        switch repo.resolvedDataSource {
        case .current:
            let prefix = compact ? "提交" : "最近提交 ·"
            return "\(prefix) \(snapshotTimeLabel(repo.lastChangedAt))"
        case .lastSuccessful:
            return "上次成功提交 · \(snapshotTimeLabel(repo.lastChangedAt))"
        case .unknown:
            return "提交时间未知"
        }
    }

    private func repositoryDataSourceColor(_ repo: RepositorySnapshot) -> Color {
        switch repo.resolvedDataSource {
        case .current:
            return .secondary
        case .lastSuccessful:
            return .orange
        case .unknown:
            return .red
        }
    }

    private func diagnosticsRepositoryBranchIconName(_ repo: RepositorySnapshot) -> String {
        switch repo.resolvedDataSource {
        case .lastSuccessful:
            return "clock.arrow.circlepath"
        case .unknown:
            return "questionmark.circle.fill"
        case .current:
            break
        }
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
        switch repo.resolvedDataSource {
        case .lastSuccessful:
            return .orange
        case .unknown:
            return .red
        case .current:
            break
        }
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
        switch repo.resolvedDataSource {
        case .lastSuccessful:
            return 0.12
        case .unknown:
            return 0.14
        case .current:
            break
        }
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
                .foregroundColor(diagnosticsEventColor(event))
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
        scheduler.diagnosticEvents.isEmpty ? "无事件" : "\(scheduler.diagnosticEvents.count) 条记录"
    }

    private var diagnosticsTopSummaryHint: String {
        diagnosticsOverview.summary
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "，", with: " · ")
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
        case .widgetReloadSkipped:
            return .orange
        default:
            return .secondary
        }
    }

    private var snapshotStoreStateLabel: String {
        switch scheduler.diagnostics.lastSnapshotStoreState {
        case .idle:
            return scheduler.diagnostics.snapshotExists ? "等待下一次写入" : "尚未初始化"
        case .restored:
            return "启动时已恢复"
        case .verified:
            return "写入并校验成功"
        case .failed:
            return "失败"
        }
    }

    private var snapshotStoreStateDetail: String {
        scheduler.diagnostics.lastSnapshotStoreDetail
            ?? "还没有快照存储明细记录。"
    }

    private var snapshotStoreTriggerLabel: String {
        guard let trigger = scheduler.diagnostics.lastSnapshotStoreTrigger else {
            return "尚未记录"
        }

        switch trigger {
        case "scan":
            return "扫描刷新"
        case "self-check":
            return "自检"
        case "pin toggle":
            return "置顶状态变更"
        case "startup":
            return "启动恢复"
        default:
            return trigger
        }
    }

    private var snapshotStoreTriggerDetail: String {
        var parts: [String] = []

        if let startedAt = scheduler.diagnostics.lastRefreshStartedAt {
            parts.append("开始于 \(formattedDate(startedAt))")
        }
        if let completedAt = scheduler.diagnostics.lastRefreshCompletedAt {
            parts.append("完成于 \(formattedDate(completedAt))")
        }

        return parts.isEmpty ? "还没有刷新时间记录。" : parts.joined(separator: " · ")
    }

    private var widgetReloadStateLabel: String {
        switch scheduler.diagnostics.lastWidgetReloadState {
        case .idle:
            return "尚未记录"
        case .requested:
            return "已请求"
        case .skipped:
            return "本次跳过"
        }
    }

    private var widgetReloadStateDetail: String {
        scheduler.diagnostics.lastWidgetReloadDetail
            ?? "还没有小组件重载决策记录。"
    }

    private var snapshotFactsSummary: String {
        "\(snapshotChainSummary) · \(snapshotReadableSummary) · \(snapshotConsistencySummary)"
    }

    private func diagnosticsRepositoryActionSummary(_ repo: RepositorySnapshot) -> String {
        repo.decision.primaryAction.title
    }

    private var snapshotFactsUpdatedLabel: String {
        if let lastWrittenAt = scheduler.diagnostics.lastWrittenAt {
            return "最近写入 \(snapshotTimeLabel(lastWrittenAt))"
        }
        if let lastGeneratedAt = scheduler.diagnostics.lastGeneratedAt {
            return "最近生成 \(snapshotTimeLabel(lastGeneratedAt))"
        }
        if let lastScanAt = scheduler.lastScanAt {
            return "最近扫描 \(snapshotTimeLabel(lastScanAt))"
        }
        return "未更新"
    }

    private var snapshotChainSummary: String {
        snapshotChainSeverity == .normal ? "链路正常" : "链路异常"
    }

    private var snapshotChainSeverity: DiagnosticsSeverity {
        if !scheduler.appGroupAvailable || sharedWriteStatus == "失败" || sharedReadStatus == "失败" {
            return .error
        }
        if sharedWriteStatus == "等待中" || sharedReadStatus == "等待中" {
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

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            scheduler.addCustomPath(url.path)
            newCustomPath = ""
        }
    }

    private func chooseDirectoryAndRefresh() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            addScanDirectoryAndRefresh(url.path)
            newCustomPath = ""
        }
    }

    private func setBuiltInDirectoryEnabled(_ path: String, enabled: Bool) {
        let normalized = ScanLocationProvider.normalizePersistedPath(path)
        let wasEnabled = scheduler.isBuiltInEnabled(path: normalized)
        guard wasEnabled != enabled else {
            return
        }

        scheduler.toggleBuiltIn(path: normalized, enabled: enabled)
    }

    private func addScanDirectoryAndRefresh(_ path: String) {
        let normalized = ScanLocationProvider.normalizePersistedPath(path)
        scheduler.addCustomPath(normalized)
    }

    private func createBuiltInDirectoryAndEnable(_ path: String) {
        let normalized = ScanLocationProvider.normalizePersistedPath(path)

        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: normalized),
                withIntermediateDirectories: true
            )
            addScanDirectoryAndRefresh(normalized)
        } catch {
            scheduler.scanRootAccessWarning = "无法创建目录：\(compactHomeRelativePath(normalized))。"
        }
    }


    private func snapshotTimeLabel(_ date: Date?) -> String {
        guard let date else { return "未知" }
        return formattedDate(date)
    }

    private func snapshotTimeLabel(_ iso: String?) -> String {
        guard let iso, let date = DateFormatting.date(from: iso) else { return "未知" }
        return formattedDate(date)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var defaultScanGroups: [DefaultScanGroup] {
        [
            DefaultScanGroup(
                title: "开发工作区",
                subtitle: "优先覆盖常见代码目录",
                layout: .standard,
                paths: [
                    ScanLocationProvider.expandTilde("~/Developer"),
                    ScanLocationProvider.expandTilde("~/Projects"),
                    ScanLocationProvider.expandTilde("~/Code"),
                    ScanLocationProvider.expandTilde("~/Workspace"),
                    ScanLocationProvider.expandTilde("~/GitHub")
                ]
            ),
            DefaultScanGroup(
                title: "常用位置",
                subtitle: "补充桌面和文稿等常见入口",
                layout: .compactDisclosure,
                paths: [
                    ScanLocationProvider.expandTilde("~/Desktop"),
                    ScanLocationProvider.expandTilde("~/Documents")
                ]
            )
        ]
    }

    @ViewBuilder
    private func defaultScanGroupSection(_ group: DefaultScanGroup) -> some View {
        switch group.layout {
        case .standard:
            let visiblePaths = group.paths.filter { path in
                return directoryExists(path) || scheduler.isBuiltInEnabled(path: path)
            }
            let missingPaths = group.paths.filter { path in
                return !directoryExists(path) && !scheduler.isBuiltInEnabled(path: path)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(group.subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                ForEach(visiblePaths, id: \.self) { path in
                    defaultScanToggleRow(for: path)
                }

                if !missingPaths.isEmpty {
                    DisclosureGroup("未找到的预设目录（\(missingPaths.count)）") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(missingPaths, id: \.self) { path in
                                missingDefaultScanRow(for: path)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption)
                }
            }
            .padding(10)
            .settingsInnerSurface()

        case .compactDisclosure:
            compactDefaultScanGroupSection(group)
        }
    }

    private func compactDefaultScanGroupSection(_ group: DefaultScanGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.title)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, 10)

            Divider()
                .overlay(DevPulseVisualStyle.separator)

            ForEach(Array(group.paths.enumerated()), id: \.element) { index, path in
                compactDefaultScanRow(for: path)

                if index < group.paths.count - 1 {
                    Divider()
                        .overlay(DevPulseVisualStyle.separator)
                        .padding(.leading, 10)
                }
            }
        }
        .settingsInnerSurface()
    }

    private func compactDefaultScanRow(for path: String) -> some View {
        let metadata = builtInDirectoryMetadata(for: path)
        let exists = directoryExists(path)
        let isExpanded = expandedDefaultScanPaths.contains(path)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    toggleDefaultScanDetails(for: path)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)

                        Text(metadata.title)
                            .font(.caption.weight(.semibold))

                        defaultScanStatusBadge(exists: exists)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "收起" : "展开")\(metadata.title)详情")

                Spacer(minLength: 8)

                Toggle("启用\(metadata.title)扫描", isOn: Binding(
                    get: { scheduler.isBuiltInEnabled(path: path) },
                    set: { setBuiltInDirectoryEnabled(path, enabled: $0) }
                ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!exists && !scheduler.isBuiltInEnabled(path: path))
            }
            .frame(minHeight: 38)
            .padding(.horizontal, 10)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metadata.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(compactHomeRelativePath(path))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !exists {
                        Text("路径不存在")
                            .font(.caption2)
                            .foregroundStyle(.red)

                        HStack(spacing: 8) {
                            Button("创建并启用") {
                                createBuiltInDirectoryAndEnable(path)
                            }
                            .buttonStyle(SettingsCompactButtonStyle())

                            Menu {
                                Button("选择其他位置") {
                                    chooseDirectoryAndRefresh()
                                }
                            } label: {
                                settingsMoreMenuLabel
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, 26)
                .padding(.trailing, 10)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func toggleDefaultScanDetails(for path: String) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if expandedDefaultScanPaths.contains(path) {
                expandedDefaultScanPaths.remove(path)
            } else {
                expandedDefaultScanPaths.insert(path)
            }
        }
    }

    @ViewBuilder
    private func defaultScanToggleRow(for path: String) -> some View {
        let metadata = builtInDirectoryMetadata(for: path)
        let exists = directoryExists(path)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    defaultScanDirectoryDetails(
                        title: metadata.title,
                        subtitle: metadata.subtitle,
                        path: path,
                        exists: exists
                    )

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 8) {
                        if exists {
                            Toggle("", isOn: Binding(
                                get: { scheduler.isBuiltInEnabled(path: path) },
                                set: { setBuiltInDirectoryEnabled(path, enabled: $0) }
                            ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                        } else {
                            Button("创建并启用") {
                                createBuiltInDirectoryAndEnable(path)
                            }
                            .buttonStyle(SettingsCompactButtonStyle())

                            Menu {
                                Button("选择其他位置") {
                                    chooseDirectoryAndRefresh()
                                }
                            } label: {
                                settingsMoreMenuLabel
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }
    }

    private func missingDefaultScanRow(for path: String) -> some View {
        let metadata = builtInDirectoryMetadata(for: path)

        return HStack(alignment: .top, spacing: 12) {
            defaultScanDirectoryDetails(
                title: metadata.title,
                subtitle: metadata.subtitle,
                path: path,
                exists: false
            )

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Button("创建并启用") {
                    createBuiltInDirectoryAndEnable(path)
                }
                .buttonStyle(SettingsCompactButtonStyle())

                Menu {
                    Button("选择其他位置") {
                        chooseDirectoryAndRefresh()
                    }
                } label: {
                    settingsMoreMenuLabel
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var settingsMoreMenuLabel: some View {
        Label("更多", systemImage: "ellipsis")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(DevPulseVisualStyle.strongerSurface)
            )
    }

    private func defaultScanDirectoryDetails(title: String,
                                             subtitle: String,
                                             path: String,
                                             exists: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                defaultScanStatusBadge(exists: exists)
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(compactHomeRelativePath(path))
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !exists {
                Text("路径不存在")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func defaultScanStatusBadge(exists: Bool) -> some View {
        Text(exists ? "可用" : "未找到")
            .font(.caption2)
            .foregroundColor(exists ? .secondary : .red)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(exists ? Color.secondary.opacity(0.08) : Color.red.opacity(0.08))
            .cornerRadius(6)
    }

    private func builtInDirectoryMetadata(for path: String) -> (title: String, subtitle: String) {
        switch URL(fileURLWithPath: path).lastPathComponent {
        case "Developer":
            return ("开发", "常见 Xcode 与本地开发目录")
        case "Projects":
            return ("项目", "通用项目根目录")
        case "Code":
            return ("代码", "轻量代码目录")
        case "Workspace":
            return ("工作区", "多项目工作区目录")
        case "GitHub":
            return ("GitHub", "克隆仓库常用位置")
        case "Desktop":
            return ("桌面", "临时放置的仓库目录")
        case "Documents":
            return ("文稿", "文稿中的项目目录")
        default:
            return (URL(fileURLWithPath: path).lastPathComponent, compactHomeRelativePath(path))
        }
    }

    private func compactHomeRelativePath(_ path: String) -> String {
        let home = ScanLocationProvider.resolvedUserHomeDirectory()
        guard path.hasPrefix(home) else { return path }

        let suffix = path.dropFirst(home.count)
        return suffix.isEmpty ? "~" : "~\(suffix)"
    }

    private func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

private extension View {
    func settingsSectionSurface() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DevPulseVisualStyle.sectionCornerRadius, style: .continuous)
                    .fill(DevPulseVisualStyle.surface)
            )
    }

    func settingsInnerSurface(cornerRadius: CGFloat = 8) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(DevPulseVisualStyle.strongerSurface)
        )
    }
}

private struct SettingsCompactButtonStyle: ButtonStyle {
    let tint: Color

    @Environment(\.isEnabled) private var isEnabled

    init(tint: Color = .accentColor) {
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.17 : 0.11))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(0.16), lineWidth: 0.5)
            }
            .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct DefaultScanGroup: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let layout: DefaultScanGroupLayout
    let paths: [String]
}

private enum DefaultScanGroupLayout {
    case standard
    case compactDisclosure
}

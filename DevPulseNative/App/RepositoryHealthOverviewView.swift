import SwiftUI

/// 项目健康状态概览：对每个已扫描项目渲染一条概览项，同时呈现
/// 综合健康分、最近活动时间、仓库状态、扫描状态与活跃程度。
///
/// 纯内存派生自 `scheduler.lastResult.repositories` 同源数据（经
/// `RepositoryHealthOverviewBuilder`），不订阅额外异步源，不触发任何
/// 新的扫描、Git 读取或文件读取。无已扫描项目时显示明确空态。
struct RepositoryHealthOverviewView: View {
    let repositories: [RepositorySnapshot]
    let now: Date
    let lastSuccessfulScanAt: Date?
    let isScanning: Bool
    let refreshPhase: RefreshPhase
    let refreshFailureMessage: String?

    init(
        repositories: [RepositorySnapshot],
        now: Date = Date(),
        lastSuccessfulScanAt: Date? = nil,
        isScanning: Bool = false,
        refreshPhase: RefreshPhase = .idle,
        refreshFailureMessage: String? = nil
    ) {
        self.repositories = repositories
        self.now = now
        self.lastSuccessfulScanAt = lastSuccessfulScanAt
        self.isScanning = isScanning
        self.refreshPhase = refreshPhase
        self.refreshFailureMessage = refreshFailureMessage
    }

    private var items: [RepositoryHealthOverviewItem] {
        RepositoryHealthOverviewBuilder.build(snapshots: repositories, now: now)
    }

    private var overviewSummary: RepositoryHealthOverviewSummary {
        RepositoryHealthOverviewBuilder.summary(for: items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if items.isEmpty {
                emptyState
            } else {
                statusSummary

                VStack(spacing: 0) {
                    ForEach(items) { item in
                        row(for: item)
                        if item.id != items.last?.id {
                            Divider()
                                .overlay(DevPulseVisualStyle.separator)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DevPulseVisualStyle.sectionCornerRadius, style: .continuous)
                .fill(DevPulseVisualStyle.surface)
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("项目健康状态")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: "heart.text.square")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("项目健康概览")
        }
    }

    private var headerSubtitle: String {
        guard !items.isEmpty else {
            return "优先显示需要确认的项目；健康分基于当前可用快照。"
        }
        return "共 \(overviewSummary.totalCount) 个项目 · \(statusSummaryText)"
    }

    private var statusSummaryText: String {
        var parts: [String] = []
        if overviewSummary.healthyCount > 0 {
            parts.append("\(overviewSummary.healthyCount) 个健康")
        }
        if overviewSummary.needsAttentionCount > 0 {
            parts.append("\(overviewSummary.needsAttentionCount) 个需关注")
        }
        if overviewSummary.dataIssueCount > 0 {
            parts.append("\(overviewSummary.dataIssueCount) 个数据待确认")
        }
        return parts.isEmpty ? "暂无可评估数据" : parts.joined(separator: " · ")
    }

    private var statusSummary: some View {
        HStack(spacing: 7) {
            Image(systemName: overviewSummary.hasIssues ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(overviewSummary.hasIssues ? Color.orange : Color.green)

            Text(
                overviewSummary.needsAttentionCount > 0
                    ? "已按需关注程度排序，先处理前面的项目。"
                    : overviewSummary.hasDataIssues
                        ? "部分项目数据待确认，健康分不会替代当前状态。"
                        : "当前项目没有明显需要优先处理的问题。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private var emptyState: some View {
        let state = emptyStateContent
        return VStack(alignment: .leading, spacing: 5) {
            Label(state.title, systemImage: state.systemImage)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(state.detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private var emptyStateContent: (title: String, detail: String, systemImage: String) {
        if isScanning || refreshPhase == .refreshing {
            return (
                "正在建立项目健康状态",
                "本轮扫描完成后，这里会展示项目健康分和需要确认的原因。",
                "arrow.triangle.2.circlepath"
            )
        }

        if refreshPhase == .failure {
            return (
                "扫描未完成，暂时无法评估项目",
                refreshFailureMessage ?? "请检查扫描目录或权限后重新刷新。",
                "exclamationmark.triangle"
            )
        }

        if refreshPhase == .degraded {
            return (
                "扫描部分完成",
                "当前没有可用的项目健康数据；请完成一次完整成功刷新后再判断状态。",
                "exclamationmark.triangle"
            )
        }

        if lastSuccessfulScanAt == nil {
            return (
                "等待首次成功扫描",
                "完成一次成功刷新后，这里会展示每个项目的健康状态。",
                "clock.badge.questionmark"
            )
        }

        return (
            "当前快照没有可评估项目",
            "最近一次成功刷新没有发现可读取的 Git 仓库；可在 Settings 检查扫描目录。",
            "tray"
        )
    }

    private func row(for item: RepositoryHealthOverviewItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if !item.branch.isEmpty {
                            Text(item.branch)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Label(activityText(for: item), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                healthScoreBadge(for: item.healthScore)
            }

            HStack(spacing: 10) {
                dimensionLabel(
                    systemImage: repositoryStateIcon(for: item),
                    text: item.repositoryState.label,
                    color: repositoryStateColor(for: item)
                )
                dimensionLabel(
                    systemImage: scanStateIcon(for: item.scanState),
                    text: item.scanState.label,
                    color: scanStateColor(for: item.scanState)
                )
                dimensionLabel(
                    systemImage: activityLevelIcon(for: item.activityLevel),
                    text: item.activityLevel.label,
                    color: activityLevelColor(for: item.activityLevel)
                )
                Spacer(minLength: 0)
            }

            if item.healthScore.status != .healthy {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: healthScoreIcon(for: item.healthScore.status))
                        .font(.caption2)
                        .foregroundStyle(healthScoreColor(for: item.healthScore.status))
                    Text(item.healthScore.explanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 9)
    }

    private func healthScoreBadge(for score: RepositoryHealthScore) -> some View {
        HStack(spacing: 4) {
            Image(systemName: healthScoreIcon(for: score.status))
                .font(.caption2.weight(.semibold))
            if let value = score.value {
                Text("\(value)")
                    .font(.headline.weight(.semibold))
                Text("分")
                    .font(.caption2)
            } else {
                Text(score.status.label)
                    .font(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(healthScoreColor(for: score.status))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(healthScoreColor(for: score.status).opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(healthScoreColor(for: score.status).opacity(0.18), lineWidth: 1)
        )
        .help(score.displayLabel)
    }

    private func dimensionLabel(
        systemImage: String,
        text: String,
        color: Color
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func activityText(for item: RepositoryHealthOverviewItem) -> String {
        item.activityLabel ?? "无活动记录"
    }

    // MARK: 图标与配色（仅展示层）

    private func repositoryStateIcon(for item: RepositoryHealthOverviewItem) -> String {
        switch item.repositoryState {
        case .clean: return "checkmark.circle"
        case .changed: return item.risk == .high ? "exclamationmark.triangle.fill" : "pencil.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func repositoryStateColor(for item: RepositoryHealthOverviewItem) -> Color {
        switch item.repositoryState {
        case .clean: return .green
        case .changed: return item.risk == .high ? .red : .orange
        case .error: return .red
        }
    }

    private func scanStateIcon(for state: RepositoryHealthScanState) -> String {
        switch state {
        case .current: return "checkmark.icloud"
        case .lastSuccessful: return "clock.arrow.circlepath"
        case .unknown: return "questionmark.circle"
        case .unavailable: return "xmark.octagon"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func scanStateColor(for state: RepositoryHealthScanState) -> Color {
        switch state {
        case .current: return .green
        case .lastSuccessful: return .orange
        case .unknown: return .secondary
        case .unavailable: return .red
        case .error: return .red
        }
    }

    private func activityLevelIcon(for level: RepositoryActivityLevel) -> String {
        switch level {
        case .active: return "bolt.fill"
        case .moderate: return "waveform"
        case .dormant: return "moon.zzz.fill"
        case .noActivity: return "minus.circle"
        }
    }

    private func activityLevelColor(for level: RepositoryActivityLevel) -> Color {
        switch level {
        case .active: return .green
        case .moderate: return .orange
        case .dormant: return .secondary
        case .noActivity: return .secondary.opacity(0.55)
        }
    }

    private func healthScoreIcon(for status: RepositoryHealthScoreStatus) -> String {
        switch status {
        case .healthy: return "checkmark.seal"
        case .attention: return "exclamationmark.circle"
        case .critical: return "exclamationmark.triangle.fill"
        case .insufficientData: return "questionmark.circle"
        case .unavailable: return "xmark.octagon"
        }
    }

    private func healthScoreColor(for status: RepositoryHealthScoreStatus) -> Color {
        switch status {
        case .healthy: return .green
        case .attention: return .orange
        case .critical, .unavailable: return .red
        case .insufficientData: return .secondary
        }
    }
}

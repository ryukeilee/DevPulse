import SwiftUI

/// 项目健康状态概览：对每个已扫描项目渲染一条概览项，同时呈现
/// 最近活动时间、仓库状态、扫描状态与活跃程度四维信息。
///
/// 纯内存派生自 `scheduler.lastResult.repositories` 同源数据（经
/// `RepositoryHealthOverviewBuilder`），不订阅额外异步源，不触发任何
/// 新的扫描、Git 读取或文件读取。无已扫描项目时显示明确空态。
struct RepositoryHealthOverviewView: View {
    let repositories: [RepositorySnapshot]

    private var items: [RepositoryHealthOverviewItem] {
        RepositoryHealthOverviewBuilder.build(snapshots: repositories)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if items.isEmpty {
                emptyState
            } else {
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
            VStack(alignment: .leading, spacing: 2) {
                Text("项目健康状态")
                    .font(.headline)
                Text("基于最近一次刷新结果，共 \(items.count) 个已扫描项目。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "heart.text.square")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("项目健康概览")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("暂无已扫描项目", systemImage: "tray")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("完成一次刷新后，这里将展示每个项目的健康状态概览。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private func row(for item: RepositoryHealthOverviewItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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

                Spacer(minLength: 8)

                Label(activityText(for: item), systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        }
        .padding(.vertical, 9)
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
}

import SwiftUI

struct ActivityTimelineView: View {
    let feed: ActivityTimelineFeed
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView

            switch feed.state {
            case .neverScanned:
                emptyState(
                    icon: "magnifyingglass",
                    title: "尚未开始扫描",
                    detail: "执行 Rescan Now，DevPulse 会先扫描默认目录并尝试发现本机 Git 仓库。",
                    actionTitle: "Rescan Now",
                    action: onRescan
                )
            case .noRepositories:
                emptyState(
                    icon: "tray",
                    title: "未发现 Git 仓库",
                    detail: "检查 Settings 里的扫描目录；如果默认目录里没有仓库，可手动添加其他目录后重新刷新。",
                    actionTitle: "Rescan Now",
                    action: onRescan
                )
            case .allClean:
                allCleanContent
            case .active:
                timelineRows
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var headerView: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity Timeline")
                    .font(.headline)
                Text("Sorted by recent repo activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let topItem = feed.topItem {
                Text(topItem.status == .changed ? "Dirty first" : "Top item")
                    .font(.caption2)
                    .foregroundStyle(topItem.status == .changed ? .orange : .secondary)
            }
        }
    }

    private var allCleanContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("All clean", systemImage: "checkmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)

            if let topItem = feed.topItem {
                ActivityTimelineRow(item: topItem)
            }

            if feed.items.count > 1 {
                Text("Showing the most recently scanned repositories even though there are no pending changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timelineRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            if feed.items.isEmpty {
                emptyState(
                    icon: "arrow.triangle.2.circlepath",
                    title: "时间线暂不可用",
                    detail: "打开 DevPulse 执行一次刷新，重建当前快照。",
                    actionTitle: nil,
                    action: nil
                )
            } else {
                ForEach(feed.items) { item in
                    ActivityTimelineRow(item: item)

                    if item.id != feed.items.last?.id {
                        Divider().opacity(0.25)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func emptyState(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

struct ActivityTimelineRow: View {
    let item: ActivityTimelineItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.repoName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                TimelineDataSourceBadge(
                    source: item.resolvedDataSource,
                    label: item.dataSourcePresentation.label,
                    detail: item.dataSourcePresentation.detail
                )

                Spacer(minLength: 8)

                Text(relativeTime)
                    .font(.caption2)
                    .foregroundStyle(relativeTimeTint)
            }

            HStack(spacing: 6) {
                statusLabel
                branchLabel
                if item.resolvedDataSource == .current {
                    RiskBadge(level: item.risk)
                }
                CommitReadinessBadge(level: displayedCommitReadiness, compact: true)
            }

            if item.resolvedDataSource == .unknown {
                Text("仓库状态暂不可用；刷新后再查看改动与提交建议。")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(item.commitReadiness.detail)
                    .font(.caption)
                    .foregroundStyle(item.resolvedDataSource == .lastSuccessful ? .orange : .secondary)
            }

            Text(changeSummary)
                .font(.caption)
                .foregroundStyle(changeSummaryTint)

            if item.resolvedDataSource != .unknown, !item.changedFilesPreview.isEmpty {
                HStack(spacing: 6) {
                    if item.resolvedDataSource == .lastSuccessful {
                        Text("上次成功文件")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    ForEach(item.changedFilesPreview.prefix(3), id: \.self) { file in
                        Text(file)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.12))
                            )
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var relativeTime: String {
        switch item.resolvedDataSource {
        case .current:
            if let lastChangedAt = item.lastChangedAt {
                return DateFormatting.relativeTime(from: lastChangedAt)
            }
            return "扫描 \(DateFormatting.relativeTime(from: item.lastScannedAt))"
        case .lastSuccessful:
            guard let lastSuccessfulScanAt = item.resolvedLastSuccessfulScanAt else {
                return "上次成功扫描时间未知"
            }
            return "上次成功扫描 \(DateFormatting.relativeTime(from: lastSuccessfulScanAt))"
        case .unknown:
            return "扫描状态未知"
        }
    }

    private var changeSummary: String {
        switch item.resolvedDataSource {
        case .current:
            return currentChangeSummary
        case .lastSuccessful:
            return "上次成功 · \(currentChangeSummary)"
        case .unknown:
            return "改动数量未知，等待刷新"
        }
    }

    private var currentChangeSummary: String {
        "modified \(item.modifiedFileCount) · added \(item.addedFileCount) · deleted \(item.deletedFileCount) · untracked \(item.untrackedFileCount)"
    }

    private var changeSummaryTint: Color {
        switch item.resolvedDataSource {
        case .current:
            return .secondary
        case .lastSuccessful:
            return .orange
        case .unknown:
            return .red
        }
    }

    private var relativeTimeTint: Color {
        switch item.resolvedDataSource {
        case .current:
            return .secondary
        case .lastSuccessful:
            return .orange
        case .unknown:
            return .red
        }
    }

    private var displayedCommitReadiness: CommitReadinessLevel {
        item.resolvedDataSource == .unknown ? .unknown : item.commitReadiness.level
    }

    private var statusLabel: some View {
        let tint: Color
        let label: String

        if item.resolvedDataSource == .unknown {
            tint = .red
            label = "unknown"
        } else {
            switch item.commitReadiness.level {
            case .dirty:
                tint = .orange
                label = "dirty"
            case .ready:
                tint = .green
                label = "ready"
            case .review:
                tint = .orange
                label = "review"
            case .idle:
                tint = .secondary
                label = "idle"
            case .unknown:
                tint = .red
                label = "unknown"
            }
        }

        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
            .foregroundStyle(tint)
    }

    private var branchLabel: some View {
        Text(item.branchDisplayLabel)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(branchTint.opacity(0.12)))
            .foregroundStyle(branchTint)
    }

    private var branchTint: Color {
        switch item.resolvedDataSource {
        case .current:
            return .secondary
        case .lastSuccessful:
            return .orange
        case .unknown:
            return .red
        }
    }
}

private struct TimelineDataSourceBadge: View {
    let source: RepositoryDataSource
    let label: String
    let detail: String

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.11)))
            .fixedSize(horizontal: true, vertical: false)
            .help(detail)
            .accessibilityLabel("数据来源：\(label)。\(detail)")
    }

    private var systemImage: String {
        switch source {
        case .current:
            return "checkmark.circle"
        case .lastSuccessful:
            return "clock.arrow.circlepath"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch source {
        case .current:
            return .secondary
        case .lastSuccessful:
            return .orange
        case .unknown:
            return .red
        }
    }
}

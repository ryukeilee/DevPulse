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

                Spacer(minLength: 8)

                Text(relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                statusLabel
                branchLabel
                RiskBadge(level: item.risk)
                CommitReadinessBadge(level: item.commitReadiness.level, compact: true)
            }

            Text(item.commitReadiness.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(changeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !item.changedFilesPreview.isEmpty {
                HStack(spacing: 6) {
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
        if let lastChangedAt = item.lastChangedAt {
            return DateFormatting.relativeTime(from: lastChangedAt)
        }
        return DateFormatting.relativeTime(from: item.lastScannedAt)
    }

    private var changeSummary: String {
        "modified \(item.modifiedFileCount) · added \(item.addedFileCount) · deleted \(item.deletedFileCount) · untracked \(item.untrackedFileCount)"
    }

    private var statusLabel: some View {
        let tint: Color
        let label: String

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

        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
            .foregroundStyle(tint)
    }

    private var branchLabel: some View {
        Text(item.branch.isEmpty ? "detached" : item.branch)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
    }
}

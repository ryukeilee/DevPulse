import SwiftUI

struct RepositoryListView: View {
    @EnvironmentObject var scheduler: ScanScheduler

    var body: some View {
        VStack(spacing: 0) {
            refreshHint

            if scheduler.lastResult.repositories.isEmpty {
                emptyView
            } else {
                List {
                    ForEach(scheduler.lastResult.repositories) { repo in
                        RepositoryRow(repo: repo)
                            .contextMenu {
                                Button(repo.isPinned ? "取消置顶" : "置顶") {
                                    scheduler.togglePin(repoID: repo.id)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var refreshHint: some View {
        if scheduler.lastScanAt != nil || scheduler.refreshPhase != .idle {
            HStack(spacing: 6) {
                if scheduler.refreshPhase == .refreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Text(scheduler.refreshStatusText)
                    .font(.caption)
                    .foregroundStyle(refreshHintTint)

                if let detail = scheduler.refreshDetailText {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.05))
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("配置的扫描目录中没有仓库")
                .font(.body)
                .foregroundColor(.secondary)
            Text("请在概览页点击“立即刷新”开始扫描。")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var refreshHintTint: Color {
        switch scheduler.refreshPhase {
        case .failure:
            return .orange
        case .refreshing:
            return .secondary
        case .idle, .success:
            switch scheduler.snapshotFreshness {
            case .stale, .expired, .unknown:
                return .orange
            case .fresh, .none:
                return .secondary
            }
        }
    }
}

struct RepositoryRow: View {
    let repo: RepositorySnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            pinIndicator

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(repo.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    if let topLineSummary {
                        Text(topLineSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    CommitReadinessBadge(level: repo.commitReadiness.level, compact: true)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    branchLabel

                    Text(bottomLineSummary)
                        .font(.caption)
                        .foregroundStyle(bottomLineColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var pinIndicator: some View {
        if repo.isPinned {
            Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 12, height: 20)
        } else {
            Color.clear
                .frame(width: 12, height: 20)
        }
    }

    private var topLineSummary: String? {
        if repo.status == .error {
            return nil
        }
        if repo.changedFileCount > 0 {
            return repo.changedFileCount == 1 ? "1 处改动" : "\(repo.changedFileCount) 处改动"
        }
        if let aheadCount = repo.aheadCount, aheadCount > 0 {
            return aheadCount == 1 ? "领先 1 个提交" : "领先 \(aheadCount) 个提交"
        }
        return nil
    }

    private var bottomLineSummary: String {
        if repo.status == .error {
            return repo.errorMessage ?? "Git 状态不可用"
        }

        if repo.commitReadiness.level == .idle {
            return "没有本地改动"
        }

        if repo.commitReadiness.level == .ready, repo.changedFileCount == 0, let aheadCount = repo.aheadCount, aheadCount > 0 {
            return aheadCount == 1 ? "可 Push 1 个本地提交" : "可 Push \(aheadCount) 个本地提交"
        }

        let parts = [
            stagedSummary,
            repo.modifiedFileCount > 0 ? "已修改 \(repo.modifiedFileCount)" : nil,
            repo.addedFileCount > 0 ? "已新增 \(repo.addedFileCount)" : nil,
            repo.deletedFileCount > 0 ? "已删除 \(repo.deletedFileCount)" : nil,
            repo.untrackedFileCount > 0 ? "未跟踪 \(repo.untrackedFileCount)" : nil
        ].compactMap { $0 }

        return parts.isEmpty ? repo.commitReadiness.detail : parts.joined(separator: " · ")
    }

    private var stagedSummary: String? {
        let stagedCount = repo.stagedFileCount ?? 0
        guard stagedCount > 0 else { return nil }
        return "已暂存 \(stagedCount)"
    }

    private var bottomLineColor: Color {
        switch repo.commitReadiness.level {
        case .dirty, .unknown:
            return .red
        case .ready:
            return .green
        case .idle, .review:
            return .secondary
        }
    }

    private var branchLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: branchIconName)
                .font(.system(size: 10, weight: .medium))
            Text(repo.branch)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(branchColor)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(
            Capsule()
                .fill(branchColor.opacity(branchFillOpacity))
        )
    }

    private var branchIconName: String {
        switch repo.commitReadiness.level {
        case .dirty, .unknown:
            return "exclamationmark.triangle.fill"
        case .ready:
            return "checkmark.circle.fill"
        case .idle, .review:
            return "arrow.triangle.branch"
        }
    }

    private var branchColor: Color {
        switch repo.commitReadiness.level {
        case .dirty, .unknown:
            return .red
        case .ready:
            return .green
        case .idle, .review:
            return .secondary
        }
    }

    private var branchFillOpacity: Double {
        switch repo.commitReadiness.level {
        case .dirty, .unknown:
            return 0.14
        case .ready:
            return 0.12
        case .idle, .review:
            return 0.08
        }
    }
}

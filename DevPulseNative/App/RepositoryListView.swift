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
        let state = RepositoryEmptyStateBuilder.build(
            lastScanAt: scheduler.lastScanAt,
            refreshPhase: scheduler.refreshPhase,
            scanRoots: scheduler.diagnostics.scanRoots,
            accessWarning: scheduler.scanRootAccessWarning,
            refreshFailureMessage: scheduler.refreshFailureMessage
        )

        return VStack(spacing: 12) {
            Spacer()
            Image(systemName: state.systemImage)
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(state.title)
                .font(.body)
                .foregroundColor(.secondary)
            Text(state.detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
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

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(repo.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    CommitReadinessBadge(level: repo.commitReadiness.level, compact: true)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    branchLabel

                    Text(repo.statusSummary)
                        .font(.caption)
                        .foregroundStyle(statusSummaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(repo.nextActionHint)
                    .font(.caption)
                    .foregroundStyle(nextActionColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var statusSummaryColor: Color {
        switch repo.commitReadiness.level {
        case .dirty, .unknown:
            return .red
        case .ready:
            return .green
        case .idle, .review:
            return .secondary
        }
    }

    private var nextActionColor: Color {
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

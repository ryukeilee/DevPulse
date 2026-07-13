import SwiftUI

private enum RepositoryListMetrics {
    static let pageInset: CGFloat = 16
    static let cardSpacing: CGFloat = 10
    static let cardPadding: CGFloat = 14
    static let cardCornerRadius: CGFloat = 12
}

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
                            .listRowInsets(EdgeInsets(
                                top: RepositoryListMetrics.cardSpacing / 2,
                                leading: RepositoryListMetrics.pageInset,
                                bottom: RepositoryListMetrics.cardSpacing / 2,
                                trailing: RepositoryListMetrics.pageInset
                            ))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button(repo.isPinned ? "取消置顶" : "置顶") {
                                    scheduler.togglePin(repoID: repo.id)
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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
            .padding(.horizontal, RepositoryListMetrics.pageInset)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) {
                Divider()
                    .opacity(0.45)
            }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Text(repo.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if repo.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Pinned")
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                RepositoryReadinessBadge(level: repo.commitReadiness.level)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                branchLabel

                localChangesLabel
            }

            Divider()
                .opacity(0.45)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                    .accessibilityHidden(true)

                Text(repo.nextActionHint)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
        }
        .padding(RepositoryListMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RepositoryListMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RepositoryListMetrics.cardCornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        )
        .contentShape(
            RoundedRectangle(cornerRadius: RepositoryListMetrics.cardCornerRadius, style: .continuous)
        )
    }

    private var branchLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .medium))
                .accessibilityHidden(true)

            Text(repo.branch)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            Capsule()
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityLabel("Branch: \(repo.branch)")
        .layoutPriority(1)
    }

    private var localChangesLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(readinessTint)
                .accessibilityHidden(true)

            Text(repo.statusSummary)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityLabel("Local changes: \(repo.statusSummary)")
    }

    private var readinessTint: Color {
        switch repo.commitReadiness.level {
        case .idle:
            return .secondary
        case .review:
            return .blue
        case .ready:
            return .green
        case .dirty:
            return .orange
        case .unknown:
            return .red
        }
    }
}

private struct RepositoryReadinessBadge: View {
    let level: CommitReadinessLevel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(level.shortLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(tint.opacity(0.09))
        )
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Commit readiness: \(level.shortLabel)")
    }

    private var systemImage: String {
        switch level {
        case .idle:
            return "pause.circle.fill"
        case .review:
            return "eye.fill"
        case .ready:
            return "checkmark.circle.fill"
        case .dirty:
            return "exclamationmark.triangle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch level {
        case .idle:
            return .secondary
        case .review:
            return .blue
        case .ready:
            return .green
        case .dirty:
            return .orange
        case .unknown:
            return .red
        }
    }
}

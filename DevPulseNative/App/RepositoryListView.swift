import SwiftUI

private enum RepositoryListMetrics {
    static let pageInset = DevPulseVisualStyle.pageInset
    static let groupSpacing: CGFloat = 10
    static let rowPadding: CGFloat = 14
    static let groupCornerRadius = DevPulseVisualStyle.sectionCornerRadius
}

struct RepositoryListView: View {
    @EnvironmentObject var scheduler: ScanScheduler

    var body: some View {
        VStack(spacing: 0) {
            refreshHint

            if scheduler.lastResult.repositories.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(scheduler.lastResult.repositories) { repo in
                            RepositoryRow(repo: repo)
                                .contextMenu {
                                    Button(repo.isPinned ? "取消置顶" : "置顶") {
                                        scheduler.togglePin(repoID: repo.id)
                                    }
                                }

                            if repo.id != scheduler.lastResult.repositories.last?.id {
                                Divider()
                                    .overlay(DevPulseVisualStyle.separator)
                                    .padding(.leading, RepositoryListMetrics.rowPadding)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(
                            cornerRadius: RepositoryListMetrics.groupCornerRadius,
                            style: .continuous
                        )
                        .fill(DevPulseVisualStyle.surface)
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: RepositoryListMetrics.groupCornerRadius,
                            style: .continuous
                        )
                    )
                    .padding(.horizontal, RepositoryListMetrics.pageInset)
                    .padding(.top, RepositoryListMetrics.groupSpacing)
                    .padding(.bottom, RepositoryListMetrics.pageInset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var refreshHint: some View {
        if scheduler.lastScanAt != nil || scheduler.refreshPhase != .idle {
            HStack(spacing: 7) {
                if scheduler.refreshPhase == .refreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                } else {
                    Circle()
                        .fill(refreshHintTint.opacity(0.8))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }

                Text(scheduler.refreshStatusText)
                    .font(.caption)
                    .foregroundStyle(refreshHintTint)

                if let detail = scheduler.refreshDetailText {
                    Text("· \(detail)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(scheduler.lastResult.repositories.count) 个仓库")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, RepositoryListMetrics.pageInset)
            .padding(.top, 11)
            .padding(.bottom, 1)
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
        VStack(alignment: .leading, spacing: 8) {
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

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)

                Text(repo.nextActionHint)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, RepositoryListMetrics.rowPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
                .fill(DevPulseVisualStyle.strongerSurface)
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
                .foregroundStyle(tint)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(tint.opacity(0.11))
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

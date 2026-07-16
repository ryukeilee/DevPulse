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

    private var presentation: RepositoryListItemPresentation {
        RepositoryListItemPresentationBuilder.build(snapshot: repo)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
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

                    RepositoryDataSourceBadge(
                        source: presentation.dataSource.source,
                        label: repo.dataSourcePresentation.label,
                        detail: repo.dataSourcePresentation.detail
                    )
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                RepositoryActionBadge(action: presentation.action)
                    .help(repo.nextActionHint)
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("最近提交")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)

                Text(presentation.latestCommit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)

            HStack(alignment: .center, spacing: 12) {
                branchLabel

                metadataLabel(
                    title: "本地",
                    value: presentation.localChanges,
                    systemImage: "doc.text"
                )

                metadataLabel(
                    title: "同步",
                    value: presentation.synchronization,
                    systemImage: "arrow.up.arrow.down"
                )

                Spacer(minLength: 4)

                metadataLabel(
                    title: "活跃",
                    value: presentation.recentActivity,
                    systemImage: "clock"
                )
            }
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

            Text(repo.branchDisplayLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(branchTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(DevPulseVisualStyle.strongerSurface)
        )
        .accessibilityLabel("分支：\(repo.branchDisplayLabel)")
    }

    private var branchTint: Color {
        switch repo.resolvedDataSource {
        case .current:
            return .secondary
        case .lastSuccessful:
            return .orange
        case .unknown:
            return .red
        }
    }

    private func metadataLabel(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text("\(title) \(value)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityLabel("\(title)：\(value)")
    }
}

private struct RepositoryActionBadge: View {
    let action: RepositoryActionState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(action.title)
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
        .accessibilityLabel("建议操作：\(action.title)")
    }

    private var systemImage: String {
        switch action.kind {
        case .refreshRepositoryState:
            return "arrow.clockwise.circle.fill"
        case .diagnoseReadFailure:
            return "exclamationmark.octagon.fill"
        case .resolveConflicts:
            return "exclamationmark.triangle.fill"
        case .confirmBranch:
            return "questionmark.circle.fill"
        case .synchronizeDivergedBranch:
            return "arrow.triangle.branch"
        case .pushLocalCommits:
            return "arrow.up.circle.fill"
        case .commitStagedChanges:
            return "checkmark.circle.fill"
        case .reviewLocalChanges:
            return "eye.fill"
        case .pullRemoteUpdates:
            return "arrow.down.circle.fill"
        case .noActionNeeded:
            return "checkmark.circle"
        }
    }

    private var tint: Color {
        switch action.kind {
        case .refreshRepositoryState:
            return .orange
        case .diagnoseReadFailure:
            return .red
        case .resolveConflicts, .confirmBranch, .synchronizeDivergedBranch, .reviewLocalChanges:
            return .orange
        case .pushLocalCommits, .pullRemoteUpdates:
            return .blue
        case .commitStagedChanges:
            return .green
        case .noActionNeeded:
            return .secondary
        }
    }
}

private struct RepositoryDataSourceBadge: View {
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

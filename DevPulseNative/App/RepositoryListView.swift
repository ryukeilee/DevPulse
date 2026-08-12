import SwiftUI

private enum RepositoryListMetrics {
    static let pageInset = DevPulseVisualStyle.pageInset
    static let groupSpacing: CGFloat = 10
    static let rowPadding: CGFloat = 14
    static let groupCornerRadius = DevPulseVisualStyle.sectionCornerRadius
}

/// A detail sheet stores an identity reference rather than a frozen payload.
/// Its contents are always resolved from the scheduler's trusted snapshot.
struct RepositoryDetailSelection: Identifiable, Equatable {
    let id: String
    let path: String

    init(repository: RepositorySnapshot) {
        id = repository.id
        path = RepositoryIdentity.canonicalPath(repository.path)
    }
}

enum RepositoryDetailSnapshotResolver {
    static func resolve(
        selection: RepositoryDetailSelection,
        repositories: [RepositorySnapshot]
    ) -> RepositorySnapshot? {
        let selectedPath = RepositoryIdentity.canonicalPath(selection.path)
        return repositories.first {
            RepositoryIdentity.canonicalPath($0.path) == selectedPath
        }
    }

    /// Safely follow an ID migration through the canonical repository path.
    /// A missing repository returns nil so callers cannot retain stale details.
    static func currentSelection(
        for selection: RepositoryDetailSelection,
        repositories: [RepositorySnapshot]
    ) -> RepositoryDetailSelection? {
        resolve(selection: selection, repositories: repositories).map(RepositoryDetailSelection.init)
    }
}

struct RepositoryListView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    private let preferencesStore: RepositoryListPreferencesStore
    @State private var searchText: String
    @State private var selectedFilter: RepositoryListFilter
    @State private var sortOrder: RepositoryListSortOrder
    @State private var selectedRepository: RepositoryDetailSelection?
    @State private var pendingIgnoreRepository: RepositorySnapshot?

    init(preferencesStore: RepositoryListPreferencesStore = RepositoryListPreferencesStore()) {
        self.preferencesStore = preferencesStore
        let preferences = preferencesStore.load()
        _searchText = State(initialValue: preferences.searchText)
        _selectedFilter = State(initialValue: preferences.filter)
        _sortOrder = State(initialValue: preferences.sortOrder)
    }

    var body: some View {
        let allRepositories = scheduler.lastResult.repositories
        let repositories = RepositoryListQuery.apply(
            to: allRepositories,
            searchText: searchText,
            filter: selectedFilter,
            sortOrder: sortOrder
        )

        VStack(spacing: 0) {
            refreshHint(displayedCount: repositories.count)
            repositoryControls

            if allRepositories.isEmpty {
                emptyView
            } else if repositories.isEmpty {
                noMatchesView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(repositories) { repo in
                            HStack(alignment: .top, spacing: 0) {
                                Button {
                                    selectedRepository = RepositoryDetailSelection(repository: repo)
                                } label: {
                                    RepositoryRow(repo: repo)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityHint("打开只读仓库详情")

                                favoriteButton(for: repo)

                                if repo.needsReadRetry {
                                    repositoryRetryButton(for: repo)
                                }
                            }
                            .contextMenu {
                                if repo.needsReadRetry {
                                    Button("重试读取") {
                                        scheduler.retryRepository(repo.id)
                                    }
                                    .disabled(
                                        scheduler.isScanning
                                            || scheduler.isRetryingRepository(repo.id)
                                    )

                                    Divider()
                                }

                                Button(repo.isPinned ? "取消收藏" : "收藏") {
                                    scheduler.togglePin(repoID: repo.id)
                                }

                                Divider()

                                Button("忽略此仓库", role: .destructive) {
                                    pendingIgnoreRepository = repo
                                }
                                .help("从扫描结果中忽略此仓库")
                            }

                            if repo.id != repositories.last?.id {
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
        .onChange(of: searchText) { _, _ in
            persistListPreferences()
        }
        .onChange(of: selectedFilter) { _, _ in
            persistListPreferences()
        }
        .onChange(of: sortOrder) { _, _ in
            persistListPreferences()
        }
        .onChange(of: scheduler.lastResult.repositories) { _, repositories in
            guard let selectedRepository else { return }
            self.selectedRepository = RepositoryDetailSnapshotResolver.currentSelection(
                for: selectedRepository,
                repositories: repositories
            )
        }
        .sheet(item: $selectedRepository) { selection in
            RepositoryDetailView(selection: selection)
        }
        .alert(item: $pendingIgnoreRepository) { repository in
            Alert(
                title: Text("忽略 \(repository.name)？"),
                message: Text("确认后，DevPulse 将不再扫描或显示此仓库；可在 Settings 中恢复。"),
                primaryButton: .destructive(Text("忽略")) {
                    scheduler.ignoreRepository(path: repository.path)
                    if selectedRepository?.id == repository.id {
                        selectedRepository = nil
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private var repositoryControls: some View {
        VStack(spacing: 8) {
            TextField("按项目名或路径搜索", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索项目名或路径")

            Picker("项目筛选", selection: $selectedFilter) {
                ForEach(RepositoryListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("项目筛选")

            HStack {
                Spacer()
                Picker("排序", selection: $sortOrder) {
                    ForEach(RepositoryListSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("项目排序")
            }
        }
        .padding(.horizontal, RepositoryListMetrics.pageInset)
        .padding(.top, 9)
        .padding(.bottom, 1)
    }

    private func favoriteButton(for repository: RepositorySnapshot) -> some View {
        Button {
            scheduler.togglePin(repoID: repository.id)
        } label: {
            Image(systemName: repository.isPinned ? "star.fill" : "star")
                .foregroundStyle(repository.isPinned ? Color.accentColor : .secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .padding(.top, 12)
        .padding(.trailing, repository.needsReadRetry ? 6 : RepositoryListMetrics.rowPadding)
        .help(repository.isPinned ? "取消收藏 \(repository.name)" : "收藏 \(repository.name)")
        .accessibilityLabel(repository.isPinned ? "取消收藏 \(repository.name)" : "收藏 \(repository.name)")
    }

    private func repositoryRetryButton(for repository: RepositorySnapshot) -> some View {
        let isRetrying = scheduler.isRetryingRepository(repository.id)

        return Button {
            scheduler.retryRepository(repository.id)
        } label: {
            HStack(spacing: 4) {
                if isRetrying {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(isRetrying ? "重试中" : "重试")
            }
            .font(.caption2.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(scheduler.isScanning || isRetrying)
        .padding(.top, 12)
        .padding(.trailing, RepositoryListMetrics.rowPadding)
        .help("只重新读取 \(repository.name)，不会阻塞其他仓库")
        .accessibilityLabel("重试读取 \(repository.name)")
        .accessibilityHint(repository.conciseReadFailureReason ?? "重新读取当前仓库状态")
    }

    @ViewBuilder
    private func refreshHint(displayedCount: Int) -> some View {
        if scheduler.lastScanAt != nil || scheduler.refreshPhase != .idle {
            VStack(spacing: 0) {
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

                    Text(repositoryCountLabel(displayedCount: displayedCount))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, RepositoryListMetrics.pageInset)
                .padding(.top, 11)
                .padding(.bottom, 1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    [scheduler.refreshStatusText, scheduler.refreshDetailText]
                        .compactMap { $0 }
                        .joined(separator: "，")
                )

                if scheduler.isScanning, let progress = scheduler.currentProgress, let currentStage = progress.currentStage, let stageProgress = progress.phases[currentStage] {
                    ProgressView(value: stageProgress.fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                        .scaleEffect(x: 1, y: 0.5, anchor: .center)
                        .padding(.horizontal, RepositoryListMetrics.pageInset)
                        .padding(.bottom, 6)
                        .animation(.easeOut(duration: 0.2), value: scheduler.currentProgress)
                }
            }
        }
    }

    private func repositoryCountLabel(displayedCount: Int) -> String {
        let totalCount = scheduler.lastResult.repositories.count
        guard displayedCount != totalCount else {
            return "\(totalCount) 个仓库"
        }
        return "显示 \(displayedCount) / \(totalCount) 个仓库"
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

    private var noMatchesView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("没有匹配的仓库")
                .font(.body)
                .foregroundStyle(.secondary)
            Text(noMatchesDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("清除搜索和筛选") {
                searchText = ""
                selectedFilter = .all
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesDetail: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, selectedFilter != .all {
            return "当前快照中没有名称或路径匹配“\(query)”且属于“\(selectedFilter.title)”的仓库。"
        }
        if !query.isEmpty {
            return "当前快照中没有项目名或路径匹配“\(query)”的仓库。"
        }
        return "当前快照中没有属于“\(selectedFilter.title)”的仓库。"
    }

    private func persistListPreferences() {
        preferencesStore.save(
            RepositoryListPreferences(
                searchText: searchText,
                filter: selectedFilter,
                sortOrder: sortOrder
            )
        )
    }

    private var refreshHintTint: Color {
        let freshness = DataFreshnessBuilder.build(
            refreshPhase: scheduler.refreshPhase,
            trustAssessment: scheduler.refreshTrustAssessment,
            persistenceState: scheduler.lastResult.persistenceState,
            repositories: scheduler.lastResult.repositories,
            isRefreshing: scheduler.isScanning
        )
        switch freshness {
        case .normal:
            return .secondary
        case .refreshing:
            return .secondary
        case .stale:
            return .orange
        case .degraded:
            return .orange
        case .failed:
            return .red
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

                    if let workspaceKind = repo.workspaceKind {
                        Text(workspaceKind.displayName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.secondary.opacity(0.1))
                            )
                            .fixedSize()
                            .accessibilityLabel("工作区类型：\(workspaceKind.displayName)")
                    }

                    RepositoryDataSourceBadge(
                        source: presentation.dataSource.source,
                        label: repo.dataSourcePresentation.label,
                        detail: repo.dataSourcePresentation.detail
                    )
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                if let failureReason = repo.conciseReadFailureReason {
                    RepositoryReadFailureBadge(reason: failureReason)
                } else {
                    RepositoryActionBadge(action: presentation.action)
                        .help(repo.nextActionHint)
                }
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

private struct RepositoryReadFailureBadge: View {
    let reason: String

    var body: some View {
        Label(reason, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.red)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.red.opacity(0.11)))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("仓库读取异常：\(reason)")
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

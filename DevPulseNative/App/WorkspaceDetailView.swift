import SwiftUI

// MARK: - Workspace detail view

/// Detail sheet for a single workspace with full drill-down to individual repos.
struct WorkspaceDetailView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    let workspace: Workspace
    @State private var searchText: String = ""
    @State private var showDeleteConfirmation = false
    @State private var showMergeSheet = false
    @State private var showSplitSheet = false
    @State private var showMoveRepoSheet = false
    @State private var selectedRepository: RepositoryDetailSelection?
    @State private var filterHealth: WorkspaceHealthFilter?

    var body: some View {
        let aggregation = scheduler.workspaceAggregations[workspace.id]
        let repos = scheduler.lastResult.repositories.filter { workspace.repositoryIDs.contains($0.id) }

        VStack(spacing: 0) {
            // Header
            headerView(aggregation: aggregation, repoCount: repos.count)

            Divider().overlay(DevPulseVisualStyle.separator)

            // Quick stats
            if let aggregation {
                quickStatsView(aggregation)
                Divider().overlay(DevPulseVisualStyle.separator)
            }

            // Search and filter
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索仓库…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(DevPulseVisualStyle.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Picker("筛选", selection: $filterHealth) {
                    Text("全部").tag(nil as WorkspaceHealthFilter?)
                    ForEach(WorkspaceHealthFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter as WorkspaceHealthFilter?)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }
            .padding(.horizontal, DevPulseVisualStyle.pageInset)
            .padding(.vertical, 6)

            // Risk summary
            if let aggregation, aggregation.highRiskCount > 0 || aggregation.warningCount > 0 {
                riskSummaryView(aggregation)
            }

            // Conflict alert
            if let aggregation, aggregation.conflictCount > 0 {
                conflictAlertView(aggregation)
            }

            // Stale repos
            if let aggregation, !aggregation.staleRepositories.isEmpty {
                staleReposBanner(aggregation)
            }

            // Repository list
            let filteredRepos = filterRepos(repos)
            if filteredRepos.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(repos.isEmpty ? "工作空间中还没有仓库" : "没有匹配的仓库")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredRepos) { repo in
                            RepositoryRow(repo: repo)
                                .padding(.horizontal, DevPulseVisualStyle.pageInset)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedRepository = RepositoryDetailSelection(repository: repo)
                                }
                                .contextMenu {
                                    Button("从工作空间移除") {
                                        scheduler.moveRepositoryToWorkspace(
                                            repositoryID: repo.id,
                                            fromWorkspaceID: workspace.id,
                                            toWorkspaceID: nil
                                        )
                                    }
                                    Button("移至其它工作空间…") {
                                        showMoveRepoSheet = true
                                    }
                                }

                            Divider()
                                .overlay(DevPulseVisualStyle.separator.opacity(0.5))
                                .padding(.leading, DevPulseVisualStyle.pageInset)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 520, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $selectedRepository) { selection in
            RepositoryDetailView(selection: selection)
                .environmentObject(scheduler)
        }
        .alert("删除工作空间", isPresented: $showDeleteConfirmation) {
            Button("删除", role: .destructive) {
                scheduler.deleteWorkspace(id: workspace.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定删除工作空间「\(workspace.name)」？仓库本身不会被删除。")
        }
        .sheet(isPresented: $showMergeSheet) {
            mergeSheet
        }
        .sheet(isPresented: $showSplitSheet) {
            splitSheet
        }
        .sheet(isPresented: $showMoveRepoSheet) {
            moveRepoSheet
        }
    }

    // MARK: - Header

    private func headerView(aggregation: WorkspaceAggregation?, repoCount: Int) -> some View {
        HStack(spacing: 12) {
            if let aggregation {
                Image(systemName: aggregation.overallHealth.systemImage)
                    .font(.title2)
                    .foregroundStyle(healthColor(aggregation.overallHealth))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 4) {
                    Text("\(repoCount) 个仓库")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(workspace.groupingBasis.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Menu {
                Button {
                    scheduler.toggleWorkspacePin(id: workspace.id)
                } label: {
                    Label(workspace.isPinned ? "取消置顶" : "置顶",
                          systemImage: workspace.isPinned ? "pin.slash" : "pin")
                }
                Button("重命名") {
                    renameWorkspace()
                }
                Button("合并工作空间…") {
                    showMergeSheet = true
                }
                Button("拆分工作空间…") {
                    showSplitSheet = true
                }
                Divider()
                Button("删除", role: .destructive) {
                    showDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(DevPulseVisualStyle.pageInset)
    }

    // MARK: - Quick stats

    private func quickStatsView(_ aggregation: WorkspaceAggregation) -> some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 8) {
            statItem(
                value: "\(aggregation.activeRepositories)",
                label: "活跃",
                icon: "bolt.fill",
                color: .orange
            )
            statItem(
                value: "\(aggregation.totalChangedFiles)",
                label: "改动文件",
                icon: "doc.text",
                color: .orange
            )
            statItem(
                value: "\(aggregation.unpushedCommitCount)",
                label: "未推送提交",
                icon: "arrow.up.doc",
                color: .blue
            )
            statItem(
                value: "\(aggregation.unpulledCommitCount)",
                label: "落后提交",
                icon: "arrow.down.doc",
                color: .purple
            )
            statItem(
                value: "\(aggregation.totalConflictedFiles)",
                label: "冲突",
                icon: "exclamationmark.triangle",
                color: .red
            )
            statItem(
                value: "\(aggregation.readErrorCount)",
                label: "读取失败",
                icon: "xmark.octagon",
                color: .red
            )
            statItem(
                value: "\(aggregation.staleRepositoryCount)",
                label: "长期无活动",
                icon: "clock",
                color: .secondary
            )
            statItem(
                value: "\(aggregation.unavailableRepositoryCount)",
                label: "不可用",
                icon: "questionmark",
                color: .gray
            )
        }
        .padding(DevPulseVisualStyle.pageInset)
    }

    private func statItem(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(value)
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Risk summary

    private func riskSummaryView(_ aggregation: WorkspaceAggregation) -> some View {
        HStack(spacing: 8) {
            if aggregation.highRiskCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(.caption2)
                    Text("\(aggregation.highRiskCount) 个高风险")
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if aggregation.warningCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("\(aggregation.warningCount) 个待关注")
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Spacer()
        }
        .padding(.horizontal, DevPulseVisualStyle.pageInset)
        .padding(.vertical, 4)
    }

    // MARK: - Conflict alert

    private func conflictAlertView(_ aggregation: WorkspaceAggregation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text("\(aggregation.conflictCount) 个仓库存在冲突：")
                .font(.callout.weight(.medium))
                .foregroundStyle(.red)
            Text(aggregation.conflictRepositoryNames.joined(separator: "、"))
                .font(.callout)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, DevPulseVisualStyle.pageInset)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.05))
    }

    // MARK: - Stale repos banner

    private func staleReposBanner(_ aggregation: WorkspaceAggregation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.caption)
                Text("\(aggregation.staleRepositoryCount) 个仓库超过 7 天无活动")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)

            ForEach(aggregation.staleRepositories.prefix(5)) { repo in
                Text("· \(repo.name) (\(repo.branch))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, DevPulseVisualStyle.pageInset)
        .padding(.vertical, 6)
    }

    // MARK: - Merge sheet

    private var mergeSheet: some View {
        let otherWorkspaces = scheduler.workspaces.filter { $0.id != workspace.id && $0.autoSuggestConfirmed }
        return VStack(spacing: 0) {
            HStack {
                Text("合并到其它工作空间")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("取消") {
                    showMergeSheet = false
                }
            }
            .padding()

            Divider()

            if otherWorkspaces.isEmpty {
                VStack {
                    Spacer()
                    Text("没有其它工作空间可供合并")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(otherWorkspaces) { target in
                            Button {
                                scheduler.mergeWorkspaces(fromID: workspace.id, intoID: target.id)
                                showMergeSheet = false
                            } label: {
                                HStack {
                                    Text(target.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(target.repositoryIDs.count) 个仓库")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 360, height: 300)
    }

    // MARK: - Split sheet

    private var splitSheet: some View {
        let repos = scheduler.lastResult.repositories.filter { workspace.repositoryIDs.contains($0.id) }
        @State var splitName: String = "\(workspace.name) (拆分)"
        @State var selectedIDs: Set<String> = []

        return VStack(spacing: 0) {
            HStack {
                Text("拆分工作空间")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("取消") {
                    showSplitSheet = false
                }
            }
            .padding()

            Divider()

            TextField("新工作空间名称", text: $splitName)
                .textFieldStyle(.roundedBorder)
                .padding()

            Divider()

            Text("选择要移出的仓库：")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 4)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(repos) { repo in
                        HStack {
                            Image(systemName: selectedIDs.contains(repo.id)
                                ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(repo.id)
                                    ? Color.accentColor : Color.secondary)
                            Text(repo.name)
                            Spacer()
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedIDs.contains(repo.id) {
                                selectedIDs.remove(repo.id)
                            } else {
                                selectedIDs.insert(repo.id)
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Text("将移出 \(selectedIDs.count) 个仓库")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("拆分") {
                    let name = splitName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, !selectedIDs.isEmpty else { return }
                    scheduler.splitWorkspace(
                        sourceID: workspace.id,
                        newName: name,
                        moveRepositoryIDs: Array(selectedIDs)
                    )
                    showSplitSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(splitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedIDs.isEmpty)
            }
            .padding()
        }
        .frame(width: 380, height: 450)
    }

    // MARK: - Move repo sheet

    private var moveRepoSheet: some View {
        let otherWorkspaces = scheduler.workspaces.filter {
            $0.id != workspace.id && $0.autoSuggestConfirmed
        }
        let repos = scheduler.lastResult.repositories.filter { workspace.repositoryIDs.contains($0.id) }
        @State var selectedRepoID: String?
        @State var targetWorkspaceID: String?

        return VStack(spacing: 0) {
            HStack {
                Text("移动仓库")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("取消") {
                    showMoveRepoSheet = false
                }
            }
            .padding()

            Divider()

            VStack(spacing: 8) {
                Text("选择要移动的仓库：")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("仓库", selection: $selectedRepoID) {
                    ForEach(repos) { repo in
                        Text(repo.name).tag(repo.id as String?)
                    }
                }
                .pickerStyle(.menu)

                Text("目标工作空间：")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("目标", selection: $targetWorkspaceID) {
                    ForEach(otherWorkspaces) { ws in
                        Text(ws.name).tag(ws.id as String?)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding()

            Spacer()

            HStack {
                Spacer()
                Button("移动") {
                    if let repoID = selectedRepoID, let targetID = targetWorkspaceID {
                        scheduler.moveRepositoryToWorkspace(
                            repositoryID: repoID,
                            fromWorkspaceID: workspace.id,
                            toWorkspaceID: targetID
                        )
                        showMoveRepoSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedRepoID == nil || targetWorkspaceID == nil)
            }
            .padding()
        }
        .frame(width: 340, height: 280)
    }

    // MARK: - Helpers

    private func filterRepos(_ repos: [RepositorySnapshot]) -> [RepositorySnapshot] {
        var result = repos
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(query) || $0.branch.lowercased().contains(query) }
        }
        if let filterHealth {
            switch filterHealth {
            case .changed:
                result = result.filter { $0.status == .changed }
            case .error:
                result = result.filter { $0.resolvedDataSource != .current || $0.status == .error }
            case .pinned:
                result = result.filter { $0.isPinned }
            case .conflicted:
                result = result.filter { ($0.conflictedFileCount ?? 0) > 0 }
            case .unpushed:
                result = result.filter { ($0.aheadCount ?? 0) > 0 }
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    private func healthColor(_ health: WorkspaceHealthLevel) -> Color {
        switch health {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .gray
        }
    }

    private func renameWorkspace() {
        let alert = NSAlert()
        alert.messageText = "重命名工作空间"
        alert.informativeText = "输入新名称"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 22))
        input.stringValue = workspace.name
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                scheduler.renameWorkspace(id: workspace.id, name: newName)
            }
        }
    }
}

// MARK: - Health filter

enum WorkspaceHealthFilter: String, CaseIterable {
    case changed
    case error
    case pinned
    case conflicted
    case unpushed

    var displayName: String {
        switch self {
        case .changed: return "有改动"
        case .error: return "有错误"
        case .pinned: return "已置顶"
        case .conflicted: return "有冲突"
        case .unpushed: return "未推送"
        }
    }
}

// MARK: - Repository row (reused from RepositoryListView)

// RepositoryRow is defined in RepositoryListView.swift and shared module-wide

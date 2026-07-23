import SwiftUI

// MARK: - Workspace list view

/// Main workspace overview tab. Displays all workspaces with aggregated
/// health metrics, search/filter/sort capabilities, and suggestion cards.
struct WorkspaceListView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @State private var searchText: String = ""
    @State private var sortOrder: WorkspaceSortOrder = .manual
    @State private var selectedWorkspace: Workspace?
    @State private var showCreateSheet = false
    @State private var showSuggestionSheet = false
    @State private var selectedSuggestion: WorkspaceAutoSuggestCandidate?

    var body: some View {
        let workspaces = filteredAndSortedWorkspaces

        VStack(spacing: 0) {
            // Header
            HStack {
                Text("工作空间")
                    .font(.title2.weight(.semibold))
                Spacer()
                if !scheduler.workspaceSuggestionCandidates.isEmpty {
                    Button {
                        showSuggestionSheet = true
                    } label: {
                        Label("建议 (\(scheduler.workspaceSuggestionCandidates.count))",
                              systemImage: "lightbulb")
                            .font(.callout)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button {
                    showCreateSheet = true
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, DevPulseVisualStyle.pageInset)
            .padding(.vertical, 8)

            // Search & sort
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索工作空间或仓库…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(DevPulseVisualStyle.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Picker("排序", selection: $sortOrder) {
                    ForEach(WorkspaceSortOrder.allCases, id: \.self) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }
            .padding(.horizontal, DevPulseVisualStyle.pageInset)
            .padding(.bottom, 8)

            Divider().overlay(DevPulseVisualStyle.separator)

            if workspaces.isEmpty && scheduler.workspaceSuggestionCandidates.isEmpty {
                emptyView
            } else if workspaces.isEmpty {
                suggestionsOnlyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Pinned workspaces
                        let pinned = workspaces.filter { $0.isPinned }
                        if !pinned.isEmpty {
                            sectionHeader("已置顶 (\(pinned.count))")
                            ForEach(pinned) { workspace in
                                workspaceCard(workspace)
                            }
                        }

                        // Regular workspaces
                        let regular = workspaces.filter { !$0.isPinned }
                        if !regular.isEmpty {
                            sectionHeader("工作空间 (\(regular.count))")
                            ForEach(regular) { workspace in
                                workspaceCard(workspace)
                            }
                        }

                        // Pending suggestions
                        let unconfirmed = scheduler.workspaces.filter { !$0.autoSuggestConfirmed }
                        if !unconfirmed.isEmpty {
                            sectionHeader("待确认的建议 (\(unconfirmed.count))")
                            ForEach(unconfirmed) { workspace in
                                workspaceSuggestionCard(workspace)
                            }
                        }

                        // New auto-suggest candidates
                        if !scheduler.workspaceSuggestionCandidates.isEmpty {
                            sectionHeader("自动归组建议")
                            ForEach(scheduler.workspaceSuggestionCandidates) { candidate in
                                suggestionCard(candidate)
                            }
                        }
                    }
                    .padding(DevPulseVisualStyle.pageInset)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showCreateSheet) {
            WorkspaceCreateSheet { name, repoIDs in
                scheduler.createWorkspace(
                    name: name,
                    repositoryIDs: repoIDs,
                    groupingBasis: .manual
                )
            }
        }
        .sheet(isPresented: $showSuggestionSheet) {
            suggestionSheet
        }
        .sheet(item: $selectedWorkspace) { workspace in
            WorkspaceDetailView(workspace: workspace)
        }
        .onAppear {
            scheduler.loadWorkspaces()
            scheduler.refreshWorkspaceSuggestions()
        }
    }

    // MARK: - Empty state

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("还没有工作空间")
                .font(.title3.weight(.medium))
            Text("将相关的仓库组织到工作空间中，方便统一查看项目状态。\n可以从自动建议开始，也可以手动创建。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showCreateSheet = true
            } label: {
                Label("创建第一个工作空间", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var suggestionsOnlyView: some View {
        ScrollView {
            VStack(spacing: 8) {
                sectionHeader("自动归组建议")
                ForEach(scheduler.workspaceSuggestionCandidates) { candidate in
                    suggestionCard(candidate)
                }
            }
            .padding(DevPulseVisualStyle.pageInset)
        }
    }

    // MARK: - Cards

    private func workspaceCard(_ workspace: Workspace) -> some View {
        let aggregation = scheduler.workspaceAggregations[workspace.id]
        let repos = scheduler.lastResult.repositories.filter { workspace.repositoryIDs.contains($0.id) }

        return VStack(spacing: 0) {
            Button {
                selectedWorkspace = workspace
            } label: {
                HStack(spacing: 12) {
                    // Health indicator
                    healthBadge(aggregation?.overallHealth ?? .unknown)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !workspace.repositoryIDs.isEmpty {
                            HStack(spacing: 4) {
                                Text("\(workspace.repositoryIDs.count) 个仓库")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let aggregation {
                                    if aggregation.activeRepositories > 0 {
                                        Text("·")
                                            .foregroundStyle(.tertiary)
                                        Text("\(aggregation.activeRepositories) 个有改动")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    if aggregation.conflictCount > 0 {
                                        Text("·")
                                            .foregroundStyle(.tertiary)
                                        Text("\(aggregation.conflictCount) 个冲突")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.red)
                                    }
                                    if aggregation.highRiskCount > 0 {
                                        Text("·")
                                            .foregroundStyle(.tertiary)
                                        Text("\(aggregation.highRiskCount) 个高风险")
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }

                    Spacer()

                    if workspace.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let aggregation {
                        compactMetrics(aggregation)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(DevPulseVisualStyle.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    scheduler.toggleWorkspacePin(id: workspace.id)
                } label: {
                    Label(workspace.isPinned ? "取消置顶" : "置顶",
                          systemImage: workspace.isPinned ? "pin.slash" : "pin")
                }
                Button {
                    renameWorkspace(workspace)
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button {
                    scheduler.deleteWorkspace(id: workspace.id)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Divider()
                if aggregation?.conflictCount ?? 0 > 0 {
                    Text("\(aggregation?.conflictCount ?? 0) 个冲突仓库")
                }
                Text("\(workspace.groupingBasis.displayName) · \(workspace.repositoryIDs.count) 个仓库")
            }
        }
    }

    private func workspaceSuggestionCard(_ workspace: Workspace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.body.weight(.semibold))
                Text("\(workspace.repositoryIDs.count) 个仓库 · \(workspace.groupingBasis.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("确认") {
                if let idx = scheduler.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                    let ws = scheduler.workspaces[idx]
                    let updated = Workspace(
                        id: ws.id,
                        name: ws.name,
                        sortOrder: ws.sortOrder,
                        isPinned: ws.isPinned,
                        repositoryIDs: ws.repositoryIDs,
                        groupingBasis: ws.groupingBasis,
                        autoSuggestConfirmed: true
                    )
                    scheduler.confirmUnconfirmedWorkspace(ws)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("忽略") {
                if let idx = scheduler.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                    scheduler.deleteWorkspace(id: workspace.id)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func suggestionCard(_ candidate: WorkspaceAutoSuggestCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .font(.body.weight(.semibold))
                    Text("\(candidate.repositoryIDs.count) 个仓库 · \(candidate.groupingBasis.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("确认") {
                    scheduler.confirmWorkspaceSuggestion(candidate)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("忽略") {
                    scheduler.dismissWorkspaceSuggestion(candidate)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("永久忽略") {
                    scheduler.permanentlyIgnoreWorkspaceSuggestion(candidate)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if !candidate.evidence.isEmpty {
                Text(candidate.evidence)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(DevPulseVisualStyle.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    private func healthBadge(_ health: WorkspaceHealthLevel) -> some View {
        ZStack {
            Circle()
                .fill(healthColor(health).opacity(0.15))
                .frame(width: 32, height: 32)
            Image(systemName: health.systemImage)
                .font(.caption)
                .foregroundStyle(healthColor(health))
        }
    }

    private func healthColor(_ health: WorkspaceHealthLevel) -> Color {
        switch health {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .gray
        }
    }

    private func compactMetrics(_ aggregation: WorkspaceAggregation) -> some View {
        HStack(spacing: 8) {
            if aggregation.totalChangedFiles > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                    Text("\(aggregation.totalChangedFiles)")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.orange)
            }
            if aggregation.unpushedCommitCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.doc")
                        .font(.caption2)
                    Text("\(aggregation.unpushedCommitCount)")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 6)
    }

    private var suggestionSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("自动归组建议")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("关闭") {
                    showSuggestionSheet = false
                }
            }
            .padding()

            Divider()

            if scheduler.workspaceSuggestionCandidates.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)
                    Text("当前没有新的归组建议")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(scheduler.workspaceSuggestionCandidates) { candidate in
                            suggestionCard(candidate)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 480, height: 400)
    }

    private func renameWorkspace(_ workspace: Workspace) {
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

    private var filteredAndSortedWorkspaces: [Workspace] {
        var result = scheduler.workspaces.filter { $0.autoSuggestConfirmed }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { ws in
                if ws.name.lowercased().contains(query) { return true }
                let repos = scheduler.lastResult.repositories.filter { ws.repositoryIDs.contains($0.id) }
                return repos.contains { $0.name.lowercased().contains(query) || $0.branch.lowercased().contains(query) }
            }
        }

        switch sortOrder {
        case .manual:
            break
        case .name:
            result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .health:
            result.sort { lhs, rhs in
                let lHealth = scheduler.workspaceAggregations[lhs.id]?.overallHealth ?? .unknown
                let rHealth = scheduler.workspaceAggregations[rhs.id]?.overallHealth ?? .unknown
                let lOrder = healthOrder(lHealth)
                let rOrder = healthOrder(rHealth)
                if lOrder != rOrder { return lOrder < rOrder }
                return lhs.name < rhs.name
            }
        case .activity:
            result.sort { lhs, rhs in
                let lChanged = scheduler.workspaceAggregations[lhs.id]?.totalChangedFiles ?? 0
                let rChanged = scheduler.workspaceAggregations[rhs.id]?.totalChangedFiles ?? 0
                if lChanged != rChanged { return lChanged > rChanged }
                return lhs.name < rhs.name
            }
        }

        return result
    }

    private func healthOrder(_ health: WorkspaceHealthLevel) -> Int {
        switch health {
        case .critical: return 0
        case .warning: return 1
        case .unknown: return 2
        case .healthy: return 3
        }
    }
}

// MARK: - Sort options

enum WorkspaceSortOrder: String, CaseIterable {
    case manual
    case name
    case health
    case activity

    var displayName: String {
        switch self {
        case .manual: return "手动"
        case .name: return "名称"
        case .health: return "健康度"
        case .activity: return "活跃度"
        }
    }
}

// MARK: - Create sheet

struct WorkspaceCreateSheet: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @State private var name: String = ""
    @State private var selectedRepoIDs: Set<String> = []
    @State private var searchText: String = ""
    @State private var createFromSuggestion: Bool = false
    let onCreate: (String, [String]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("创建工作空间")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("取消") {
                    if let window = NSApp.keyWindow {
                        window.close()
                    }
                }
            }
            .padding()

            Divider()

            VStack(spacing: 12) {
                TextField("工作空间名称", text: $name)
                    .textFieldStyle(.roundedBorder)

                TextField("搜索仓库…", text: $searchText)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(DevPulseVisualStyle.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding()

            Divider()

            let repos = filteredRepos
            if repos.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text("没有可用的仓库")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(repos) { repo in
                            HStack {
                                Image(systemName: selectedRepoIDs.contains(repo.id)
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .foregroundStyle(selectedRepoIDs.contains(repo.id)
                                        ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(repo.name)
                                        .font(.callout)
                                    Text(repo.branch)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedRepoIDs.contains(repo.id) {
                                    selectedRepoIDs.remove(repo.id)
                                } else {
                                    selectedRepoIDs.insert(repo.id)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }

            Divider()

            HStack {
                Text("已选 \(selectedRepoIDs.count) 个仓库")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("创建") {
                    let validName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !validName.isEmpty, !selectedRepoIDs.isEmpty else { return }
                    onCreate(validName, Array(selectedRepoIDs))
                    if let window = NSApp.keyWindow {
                        window.close()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedRepoIDs.isEmpty)
            }
            .padding()
        }
        .frame(width: 420, height: 500)
    }

    private var filteredRepos: [RepositorySnapshot] {
        let ungroupedIDs = Set(scheduler.workspaces.flatMap(\.repositoryIDs))
        var repos = scheduler.lastResult.repositories.filter { !ungroupedIDs.contains($0.id) }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            repos = repos.filter { $0.name.lowercased().contains(query) || $0.branch.lowercased().contains(query) }
        }
        return repos.sorted { $0.name < $1.name }
    }
}

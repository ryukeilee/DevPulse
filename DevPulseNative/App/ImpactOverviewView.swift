import SwiftUI

// MARK: - Impact overview view

/// Top-level view showing change impact analysis across all repositories.
struct ImpactOverviewView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @State private var selectedFilter: ImpactFilter = .all
    @State private var searchText = ""

    enum ImpactFilter: String, CaseIterable {
        case all = "全部"
        case blocked = "发布阻塞"
        case attention = "需关注"
        case changed = "有变更"
        case ready = "就绪"

        var displayName: String { rawValue }
    }

    var body: some View {
        let repos = scheduler.lastResult.repositories
        let impactAnalyses = retrieveAnalyses(from: repos)
        let readinessMap = buildReadinessMap(repos: repos, analyses: impactAnalyses)
        let filteredRepos = filterResults(repos, readinessMap: readinessMap)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Summary cards
                summaryCards(readinessMap: readinessMap, totalRepos: repos.count)
                    .padding(.horizontal, DevPulseVisualStyle.pageInset)

                // Filter bar
                filterBar

                // Affected repositories
                if filteredRepos.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(.green)
                        Text("没有匹配的结果")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredRepos, id: \.id) { repo in
                            impactRepoRow(repo: repo, analyses: impactAnalyses, readinessMap: readinessMap)
                        }
                    }
                    .padding(.horizontal, DevPulseVisualStyle.pageInset)
                    .padding(.bottom, 16)
                }
            }
            .padding(.vertical, DevPulseVisualStyle.pageInset)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Summary cards

    private func summaryCards(readinessMap: [String: ReleaseReadinessLevel], totalRepos: Int) -> some View {
        let blocked = readinessMap.values.filter { $0 == .blocked }.count
        let attention = readinessMap.values.filter { $0 == .attention }.count
        let ready = readinessMap.values.filter { $0 == .ready }.count
        let unknown = readinessMap.values.filter { $0 == .unknown }.count

        return LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 8) {
            summaryCard(
                title: "全部仓库",
                value: "\(totalRepos)",
                systemImage: "shippingbox",
                color: .primary
            )
            summaryCard(
                title: "发布阻塞",
                value: "\(blocked)",
                systemImage: "xmark.octagon.fill",
                color: .red
            )
            summaryCard(
                title: "需关注",
                value: "\(attention)",
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
            summaryCard(
                title: "发布就绪",
                value: "\(ready)",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        }
    }

    private func summaryCard(title: String, value: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: DevPulseVisualStyle.sectionCornerRadius))
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索仓库…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(DevPulseVisualStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Picker("筛选", selection: $selectedFilter) {
                ForEach(ImpactFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
        }
        .padding(.horizontal, DevPulseVisualStyle.pageInset)
    }

    // MARK: - Repository row

    private func impactRepoRow(repo: RepositorySnapshot, analyses: [String: ChangeImpactSnapshot], readinessMap: [String: ReleaseReadinessLevel]) -> some View {
        let level = readinessMap[repo.id] ?? .unknown
        let analysis = analyses[repo.id]
        let categoryBreakdown = analysis?.categoryBreakdown ?? [:]
        let moduleCount = analysis?.affectedModuleCount ?? 0

        return NavigationLink(destination: RepositoryImpactView(repository: repo, analysis: analysis)) {
            HStack(spacing: 10) {
                // Readiness indicator
                Image(systemName: level.systemImage)
                    .font(.title3)
                    .foregroundStyle(readinessColor(level))

                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .fontWeight(.medium)
                    HStack(spacing: 4) {
                        Text(level.displayName)
                            .font(.caption)
                            .foregroundStyle(readinessColor(level))
                        if !categoryBreakdown.isEmpty {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            impactCategoryLabels(categoryBreakdown)
                        }
                        if moduleCount > 0 {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("\(moduleCount) 模块")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if let analysis {
                    Text("\(analysis.changedFileCount) 文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(DevPulseVisualStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: DevPulseVisualStyle.sectionCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private func impactCategoryLabels(_ breakdown: [ChangeCategory: Int]) -> some View {
        let sorted = breakdown.sorted { $0.key.sortOrder < $1.key.sortOrder }
        let labels = sorted.prefix(3).map { "\($0.key.displayName):\($0.value)" }
        return Text(labels.joined(separator: " "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - Helpers

    private func retrieveAnalyses(from repos: [RepositorySnapshot]) -> [String: ChangeImpactSnapshot] {
        // In a real setup, this would come from ChangeImpactEngine
        // For now, return empty — the view gracefully shows no data
        [:]
    }

    private func buildReadinessMap(repos: [RepositorySnapshot], analyses: [String: ChangeImpactSnapshot]) -> [String: ReleaseReadinessLevel] {
        var map: [String: ReleaseReadinessLevel] = [:]
        for repo in repos {
            if let analysis = analyses[repo.id], let readiness = analysis.releaseReadiness {
                map[repo.id] = readiness.level
            } else {
                // Infer basic readiness from snapshot
                if repo.status == .error { map[repo.id] = .blocked }
                else if repo.conflictedFileCount ?? 0 > 0 { map[repo.id] = .blocked }
                else if repo.changedFileCount > 0 { map[repo.id] = .attention }
                else if repo.resolvedDataSource == .unknown { map[repo.id] = .unknown }
                else { map[repo.id] = .ready }
            }
        }
        return map
    }

    private func filterResults(_ repos: [RepositorySnapshot], readinessMap: [String: ReleaseReadinessLevel]) -> [RepositorySnapshot] {
        repos.filter { repo in
            // Text search
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                guard repo.name.lowercased().contains(query) || repo.path.lowercased().contains(query) else {
                    return false
                }
            }
            // Filter
            guard selectedFilter != .all else { return true }
            guard let level = readinessMap[repo.id] else { return false }

            switch selectedFilter {
            case .all: return true
            case .blocked: return level == .blocked
            case .attention: return level == .attention
            case .changed: return repo.changedFileCount > 0
            case .ready: return level == .ready
            }
        }
    }

    private func readinessColor(_ level: ReleaseReadinessLevel) -> Color {
        switch level {
        case .ready: return .green
        case .attention: return .orange
        case .blocked: return .red
        case .unknown: return .gray
        }
    }
}

// MARK: - Repository impact view

struct RepositoryImpactView: View {
    let repository: RepositorySnapshot
    let analysis: ChangeImpactSnapshot?

    @State private var selectedTab: RepoImpactTab = .overview

    enum RepoImpactTab: String, CaseIterable {
        case overview = "总览"
        case modules = "影响模块"
        case evidence = "证据溯源"
        case readiness = "发布准备"

        var systemImage: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .modules: return "square.3.layers.3d"
            case .evidence: return "doc.text.magnifyingglass"
            case .readiness: return "checklist"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider().overlay(DevPulseVisualStyle.separator)

            // Tab bar
            HStack(spacing: 2) {
                ForEach(RepoImpactTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selectedTab == tab
                                    ? Color.accentColor.opacity(0.14)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, DevPulseVisualStyle.pageInset)

            Divider().overlay(DevPulseVisualStyle.separator)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTab {
                    case .overview:
                        impactOverviewContent
                    case .modules:
                        impactModulesContent
                    case .evidence:
                        impactEvidenceContent
                    case .readiness:
                        readinessContent
                    }
                }
                .padding(DevPulseVisualStyle.pageInset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text("变更影响分析")
                    .font(.headline)
            }

            Text(repository.name)
                .font(.title2.weight(.semibold))

            if let analysis {
                HStack(spacing: 8) {
                    Label(analysis.scope.displayName, systemImage: "arrow.triangle.branch")
                    if let readiness = analysis.releaseReadiness {
                        Label(readiness.level.displayName, systemImage: readiness.level.systemImage)
                            .foregroundStyle(readinessColor(readiness.level))
                    }
                    Text("\(analysis.changedFileCount) 文件 · \(analysis.affectedModuleCount) 模块")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(DevPulseVisualStyle.pageInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var impactOverviewContent: some View {
        Group {
            if let analysis {
                // Category breakdown
                categoryBreakdownSection(analysis.categoryBreakdown)

                // Scope and risk
                HStack(spacing: 8) {
                    infoCard(
                        title: "变更范围",
                        value: analysis.scope.displayName,
                        detail: "影响 \(analysis.affectedModuleCount) 个模块"
                    )
                    infoCard(
                        title: "基线状态",
                        value: analysis.baselineState.stateLabel,
                        detail: analysis.baselineState.baselineBranch ?? "未设置"
                    )
                }

                // Verification scope
                if !analysis.verificationScope.isEmpty {
                    verificationScopeSection(analysis.verificationScope)
                }

                // Direct changes
                if !analysis.changes.isEmpty {
                    directChangesSection(analysis.changes)
                }
            } else {
                noAnalysisView
            }
        }
    }

    private var impactModulesContent: some View {
        Group {
            if let analysis, !analysis.modules.isEmpty {
                let sorted = analysis.modules.sorted {
                    $0.confidence.sortOrder < $1.confidence.sortOrder
                }
                ForEach(sorted, id: \.id) { module in
                    moduleRow(module)
                }
            } else {
                Text("暂未发现受影响模块")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private var impactEvidenceContent: some View {
        Group {
            if let analysis {
                VStack(alignment: .leading, spacing: 8) {
                    Text("证据溯源")
                        .font(.headline)

                    Text("以下证据支撑了当前的变更影响结论：")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Baseline evidence
                    evidenceCard(
                        title: "基线分支",
                        items: [
                            "基线: \(analysis.baselineState.baselineBranch ?? "未设置")",
                            "状态: \(analysis.baselineState.stateLabel)",
                            "降级: \(analysis.baselineState.isDegraded ? "是" : "否")"
                        ]
                    )

                    // Change evidence
                    evidenceCard(
                        title: "变更证据",
                        items: analysis.changes.prefix(10).map { change in
                            let status = change.changeKind.displayName
                            let category = change.category.displayName
                            let file = (change.filePath as NSString).lastPathComponent
                            return "\(status) [\(category)] \(file)"
                        } + (analysis.changes.count > 10 ? ["以及其它 \(analysis.changes.count - 10) 个文件"] : [])
                    )

                    // Module evidence
                    let evidenceModules = analysis.modules.filter { !$0.evidence.isEmpty }
                    if !evidenceModules.isEmpty {
                        evidenceCard(
                            title: "模块证据",
                            items: evidenceModules.flatMap { module in
                                ["\(module.name) (\(module.confidence.displayName)):"] + module.evidence.map { "  \($0)" }
                            }
                        )
                    }

                    // Propagation evidence
                    let propEdges = analysis.impactEdges
                    if !propEdges.isEmpty {
                        evidenceCard(
                            title: "依赖传播路径",
                            items: propEdges.prefix(10).map { edge in
                                "\(edge.kind.displayName): ... → \(edge.toModuleID) (\(String(format: "%.1f", edge.weight)))"
                            } + (propEdges.count > 10 ? ["以及其它 \(propEdges.count - 10) 条依赖"] : [])
                        )
                    }
                }
            } else {
                noAnalysisView
            }
        }
    }

    private var readinessContent: some View {
        Group {
            if let analysis, let readiness = analysis.releaseReadiness {
                VStack(alignment: .leading, spacing: 12) {
                    // Summary
                    HStack(spacing: 8) {
                        Image(systemName: readiness.level.systemImage)
                            .font(.title)
                            .foregroundStyle(readinessColor(readiness.level))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(readiness.summary)
                                .font(.headline)
                            Text(readiness.primaryExplanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DevPulseVisualStyle.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DevPulseVisualStyle.sectionCornerRadius))

                    // Blocking signals
                    if !readiness.blockingSignals.isEmpty {
                        Text("阻塞项")
                            .font(.headline)
                        ForEach(readiness.blockingSignals) { signal in
                            signalRow(signal)
                        }
                    }

                    // Attention signals
                    if !readiness.attentionSignals.isEmpty {
                        Text("待关注")
                            .font(.headline)
                        ForEach(readiness.attentionSignals) { signal in
                            signalRow(signal)
                        }
                    }

                    // All clear
                    if readiness.signals.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.green)
                            Text("所有检查通过")
                                .font(.headline)
                            Text("此仓库已准备好发布")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                }
            } else {
                noAnalysisView
            }
        }
    }

    private func categoryBreakdownSection(_ breakdown: [ChangeCategory: Int]) -> some View {
        let sorted = breakdown.sorted { $0.key.sortOrder < $1.key.sortOrder }
        return VStack(alignment: .leading, spacing: 6) {
            Text("变更分类")
                .font(.headline)
            HStack(spacing: 6) {
                ForEach(sorted, id: \.key) { category, count in
                    HStack(spacing: 4) {
                        Image(systemName: category.systemImage)
                            .font(.caption)
                        Text("\(category.displayName) \(count)")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DevPulseVisualStyle.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func infoCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: DevPulseVisualStyle.sectionCornerRadius))
    }

    private func verificationScopeSection(_ scope: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("验证范围")
                .font(.headline)
            ForEach(scope, id: \.self) { item in
                Label(item, systemImage: "target")
                    .font(.caption)
            }
        }
        .padding()
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: DevPulseVisualStyle.sectionCornerRadius))
    }

    private func directChangesSection(_ changes: [ChangeEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("直接变更 (\(changes.count))")
                .font(.headline)
            ForEach(changes.prefix(20)) { change in
                HStack(spacing: 6) {
                    changeKindBadge(change.changeKind)
                    Text("(\(change.category.displayName))", comment: "Change category label")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .hidden()
                    Image(systemName: change.category.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text((change.filePath as NSString).lastPathComponent)
                        .font(.caption)
                    if let commitSummary = change.commitSummary {
                        Text("· \(commitSummary)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            if changes.count > 20 {
                Text("以及其它 \(changes.count - 20) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func changeKindBadge(_ kind: ChangeKind) -> some View {
        Text(kind.displayName)
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(changeKindColor(kind).opacity(0.15))
            .foregroundStyle(changeKindColor(kind))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func changeKindColor(_ kind: ChangeKind) -> Color {
        switch kind {
        case .added: return .green
        case .modified: return .blue
        case .deleted: return .red
        case .renamed: return .orange
        case .copied: return .teal
        case .untracked: return .gray
        case .conflicted: return .purple
        }
    }

    private func moduleRow(_ module: AffectedModule) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: self.systemImage(for: module.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(module.name)
                        .fontWeight(.medium)
                    Text(module.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("置信度: \(module.confidence.displayName)")
                    Text("·")
                    Text("变更: \(module.changeCount) 文件")
                    if !module.propagatedFrom.isEmpty {
                        Text("·")
                        Text("传播来源: \(module.propagatedFrom.joined(separator: ", "))")
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(8)
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func signalRow(_ signal: ReadinessSignal) -> some View {
        HStack(spacing: 8) {
            Image(systemName: signal.systemImage)
                .foregroundStyle(readinessColor(signal.level))
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.title)
                    .fontWeight(.medium)
                Text(signal.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !signal.evidence.isEmpty {
                    ForEach(signal.evidence, id: \.self) { item in
                        Text(item)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(8)
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func evidenceCard(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var noAnalysisView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("尚无变更影响分析数据")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("执行仓库扫描后将自动生成分析")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func readinessColor(_ level: ReleaseReadinessLevel) -> Color {
        switch level {
        case .ready: return .green
        case .attention: return .orange
        case .blocked: return .red
        case .unknown: return .gray
        }
    }

    private func systemImage(for kind: ModuleKind) -> String {
        switch kind {
        case .app: return "app"
        case .framework: return "square.stack.3d.up"
        case .library: return "books.vertical"
        case .testTarget: return "checklist"
        case .widgetExtension: return "square.grid.2x2"
        case .package: return "shippingbox"
        case .workspace: return "rectangle.3.group"
        case .unknown: return "questionmark"
        }
    }
}

// MARK: - Workspace impact view

struct WorkspaceImpactView: View {
    let workspace: Workspace
    let analyses: [String: ChangeImpactSnapshot]

    @State private var showDetail = false

    var body: some View {
        let overallLevel = aggregateReadinessLevel()
        let totalChanges = analyses.values.reduce(0) { $0 + $1.changedFileCount }
        let totalModules = analyses.values.reduce(0) { $0 + $1.affectedModuleCount }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: overallLevel.systemImage)
                    .font(.title3)
                    .foregroundStyle(readinessColor(overallLevel))
                Text("工作区影响分析")
                    .font(.headline)
                Spacer()
                Text("\(analyses.count) 仓库 · \(totalChanges) 变更 · \(totalModules) 模块")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Category aggregation
            let aggregateCategories = aggregateCategories()
            if !aggregateCategories.isEmpty {
                HStack(spacing: 4) {
                    ForEach(aggregateCategories.prefix(5), id: \.0) { cat, count in
                        Label("\(cat.displayName):\(count)", systemImage: cat.systemImage)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DevPulseVisualStyle.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            // Cross-repo edges
            let crossEdges = analyses.values.flatMap(\.impactEdges)
            if !crossEdges.isEmpty {
                Text("跨仓库依赖: \(crossEdges.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: DevPulseVisualStyle.sectionCornerRadius))
    }

    private func aggregateReadinessLevel() -> ReleaseReadinessLevel {
        let levels = analyses.values.compactMap { $0.releaseReadiness?.level }
        if levels.contains(.blocked) { return .blocked }
        if levels.contains(.attention) { return .attention }
        if levels.contains(.ready) { return .ready }
        return .unknown
    }

    private func aggregateCategories() -> [(ChangeCategory, Int)] {
        var combined: [ChangeCategory: Int] = [:]
        for analysis in analyses.values {
            for (cat, count) in analysis.categoryBreakdown {
                combined[cat, default: 0] += count
            }
        }
        return combined.sorted { $0.key.sortOrder < $1.key.sortOrder }
    }

    private func readinessColor(_ level: ReleaseReadinessLevel) -> Color {
        switch level {
        case .ready: return .green
        case .attention: return .orange
        case .blocked: return .red
        case .unknown: return .gray
        }
    }
}

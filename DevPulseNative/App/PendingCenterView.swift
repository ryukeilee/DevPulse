import SwiftUI

private enum PendingCenterPagination {
    /// Maximum items displayed per page to keep memory bounded.
    static let pageSize = 200
}

private enum PendingCenterScope: String, CaseIterable {
    case current
    case completed
    case all

    var displayName: String {
        switch self {
        case .current: return "当前"
        case .completed: return "已完成"
        case .all: return "全部"
        }
    }

    func apply(to items: [PendingItem]) -> [PendingItem] {
        switch self {
        case .current:
            return items.filter { $0.status != .resolved && $0.status != .permanentlyIgnored }
        case .completed:
            return items.filter { $0.status == .resolved || $0.status == .permanentlyIgnored }
        case .all:
            return items
        }
    }
}

struct PendingCenterView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @State private var filter = PendingItemFilter()
    @State private var scope: PendingCenterScope = .current
    @State private var sortOrder: PendingItemSortOrder = .severity
    @State private var showDetailItem: PendingItem?
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DevPulseVisualStyle.separator)
            filterBar
            Divider().overlay(DevPulseVisualStyle.separator)
            contentList
        }
        .onAppear { scheduler.ensurePendingItemsLoaded() }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $showDetailItem) {
            PendingItemDetailView(item: $0).environmentObject(scheduler)
        }
        .onChange(of: filter.searchText) { _, _ in page = 0 }
        .onChange(of: scope) { _, _ in page = 0 }
        .onChange(of: sortOrder) { _, _ in page = 0 }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full").font(.title3).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("待收尾事项").font(.title3.weight(.semibold))
                Text(headerSummary).font(.caption).foregroundStyle(.secondary)
                if allItemsCount > PendingCenterPagination.pageSize {
                    Text("显示 \(min(pagedItems.count, allItemsCount))/\(allItemsCount)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }.padding(.horizontal, DevPulseVisualStyle.pageInset).padding(.vertical, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索项目或事项…", text: $filter.searchText).textFieldStyle(.plain)
            }.padding(6).background(DevPulseVisualStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(maxWidth: 260)

            Picker("范围", selection: $scope) {
                ForEach(PendingCenterScope.allCases, id: \.self) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            Spacer()

            Picker("排序", selection: $sortOrder) {
                ForEach(PendingItemSortOrder.allCases, id: \.self) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .frame(width: 130)
        }.padding(.horizontal, DevPulseVisualStyle.pageInset).padding(.vertical, 6)
    }

    @ViewBuilder
    private var contentList: some View {
        if sortedItems.isEmpty {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
                Text(emptyStateTitle).font(.headline)
                Text(emptyStateMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(pagedItems) { item in
                    PendingItemRowView(item: item)
                        .onTapGesture { showDetailItem = item }
                }
                if allItemsCount > (page + 1) * PendingCenterPagination.pageSize {
                    HStack {
                        Spacer()
                        Button("加载更多…") {
                            page += 1
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }.listStyle(.plain)
        }
    }

    private var activeItems: [PendingItem] {
        scheduler.pendingItems.filter { $0.status != .resolved && $0.status != .permanentlyIgnored }
    }

    private var headerSummary: String {
        if activeItems.isEmpty {
            return "当前没有需要收尾的事项"
        }
        let repositoryCount = Set(activeItems.compactMap(\.repositoryID)).count
        return "\(activeItems.count) 个事项 · \(repositoryCount) 个项目"
    }

    private var emptyStateTitle: String {
        filter.searchText.isEmpty ? "没有待收尾事项" : "没有匹配的事项"
    }

    private var emptyStateMessage: String {
        if !filter.searchText.isEmpty {
            return "尝试更换关键词或查看其他范围。"
        }
        switch scope {
        case .current: return "未提交改动、未推送提交和其他未完成状态会在扫描后自动出现在这里。"
        case .completed: return "自动恢复或永久忽略的事项会保留在这里。"
        case .all: return "扫描完成后，识别到的事项会集中显示在这里。"
        }
    }

    private var allItemsCount: Int { sortedItems.count }

    private var sortedItems: [PendingItem] {
        sortOrder.sort(scope.apply(to: filter.apply(to: scheduler.pendingItems)))
    }

    /// Only show a bounded page of items, loaded on demand.
    private var pagedItems: [PendingItem] {
        let all = sortedItems
        let end = min((page + 1) * PendingCenterPagination.pageSize, all.count)
        return Array(all[all.startIndex..<end])
    }
}

private struct PendingItemRowView: View {
    let item: PendingItem
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(severityColor.opacity(0.12)).frame(width: 32, height: 32)
                Image(systemName: item.source.systemImage).font(.caption).foregroundStyle(severityColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(item.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if let repositoryName = item.repositoryName {
                        Text(repositoryName)
                    } else if let workspaceName = item.workspaceName {
                        Text(workspaceName)
                    }
                    Text(item.source.displayName)
                    Text(item.status.displayName)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
        }.padding(.vertical, 4)
    }

    private var severityColor: Color {
        switch item.severity {
        case .tip: return .secondary
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        case .critical: return Color(red: 0.5, green: 0.0, blue: 0.0)
        }
    }
}

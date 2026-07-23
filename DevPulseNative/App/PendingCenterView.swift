import SwiftUI

struct PendingCenterView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @State private var filter = PendingItemFilter()
    @State private var sortOrder: PendingItemSortOrder = .severity
    @State private var showDetailItem: PendingItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DevPulseVisualStyle.separator)
            filterBar
            Divider().overlay(DevPulseVisualStyle.separator)
            contentList
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $showDetailItem) {
            PendingItemDetailView(item: $0).environmentObject(scheduler)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full").font(.title3).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("待处理中心").font(.title3.weight(.semibold))
                Text("\(activeItems.count) 个待处理").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.horizontal, DevPulseVisualStyle.pageInset).padding(.vertical, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索...", text: $filter.searchText).textFieldStyle(.plain)
            }.padding(6).background(DevPulseVisualStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Spacer()
        }.padding(.horizontal, DevPulseVisualStyle.pageInset).padding(.vertical, 6)
    }

    @ViewBuilder
    private var contentList: some View {
        if sortedItems.isEmpty {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("没有待处理事项").font(.headline)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(sortedItems) { item in
                    PendingItemRowView(item: item)
                        .onTapGesture { showDetailItem = item }
                }
            }.listStyle(.plain)
        }
    }

    private var activeItems: [PendingItem] {
        scheduler.pendingItems.filter { $0.status != .resolved && $0.status != .permanentlyIgnored }
    }

    private var sortedItems: [PendingItem] {
        sortOrder.sort(filter.apply(to: scheduler.pendingItems))
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

import Foundation
import SwiftUI
import WidgetKit

private enum WidgetSnapshotSchema {
    static let version = RepositorySnapshotSchema.version
}

private enum WidgetSnapshotStore {
    static let appGroupIdentifier = "group.local.devpulse"
    private static let snapshotFileName = "repositories.json"

    static func load() -> Result<AppGroupData, WidgetSnapshotLoadError> {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return .failure(.appGroupUnavailable)
        }

        let snapshotURL = containerURL.appendingPathComponent(snapshotFileName)
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            return .failure(.snapshotMissing(path: snapshotURL.path))
        }

        do {
            let data = try Data(contentsOf: snapshotURL)
            do {
                let snapshot = try JSONDecoder().decode(AppGroupData.self, from: data)
                guard snapshot.schemaVersion == WidgetSnapshotSchema.version else {
                    return .failure(.schemaMismatch(
                        expected: WidgetSnapshotSchema.version,
                        actual: snapshot.schemaVersion
                    ))
                }
                return .success(snapshot)
            } catch {
                return .failure(.decodeFailed(path: snapshotURL.path, reason: error.localizedDescription))
            }
        } catch {
            return .failure(.readFailed(path: snapshotURL.path, reason: error.localizedDescription))
        }
    }
}

private enum WidgetSnapshotLoadError: LocalizedError {
    case appGroupUnavailable
    case snapshotMissing(path: String)
    case readFailed(path: String, reason: String)
    case decodeFailed(path: String, reason: String)
    case schemaMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group container is unavailable."
        case .snapshotMissing(let path):
            return "Shared snapshot file is missing at \(path)."
        case .readFailed(let path, let reason):
            return "Shared snapshot read failed at \(path): \(reason)"
        case .decodeFailed(let path, let reason):
            return "Shared snapshot decode failed at \(path): \(reason)"
        case .schemaMismatch(let expected, let actual):
            return "Shared snapshot schema mismatch. Expected v\(expected), found v\(actual)."
        }
    }
}

enum WidgetLoadState: Equatable {
    case placeholder
    case noSnapshot
    case unavailable
    case ready
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (WidgetEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(loadEntry())
        }
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let entry = loadEntry()
        let nextRefresh = Date().addingTimeInterval(entry.loadState == .unavailable ? 300 : 900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadEntry() -> WidgetEntry {
        switch WidgetSnapshotStore.load() {
        case .success(let snapshot):
            return .content(
                snapshot: snapshot,
                feed: ActivityTimelineBuilder.build(from: snapshot)
            )
        case .failure(let error):
            switch error {
            case .snapshotMissing:
                return .noSnapshot()
            case .appGroupUnavailable, .readFailed, .decodeFailed, .schemaMismatch:
                return .unavailable()
            }
        }
    }
}

struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AppGroupData?
    let feed: ActivityTimelineFeed
    let loadState: WidgetLoadState

    static var placeholder: WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .placeholder
        )
    }

    static func content(snapshot: AppGroupData,
                        feed: ActivityTimelineFeed) -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: snapshot,
            feed: feed,
            loadState: .ready
        )
    }

    static func noSnapshot() -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .noSnapshot
        )
    }

    static func unavailable() -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .unavailable
        )
    }
}

struct DevPulseWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: WidgetEntry

    var body: some View {
        Group {
            switch widgetFamily {
            case .systemSmall:
                SmallGlanceWidgetView(entry: entry)
            case .systemMedium:
                MediumGlanceWidgetView(entry: entry)
            default:
                SmallGlanceWidgetView(entry: entry)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct WidgetChromeHeader: View {
    let trailingText: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption2.weight(.semibold))
            Text("DevPulse")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            if let trailingText {
                Text(trailingText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct SmallGlanceWidgetView: View {
    let entry: WidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetChromeHeader(trailingText: nil)

            content

            Spacer(minLength: 0)

            footer
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        switch entry.loadState {
        case .placeholder:
            placeholderContent
        case .noSnapshot:
            shortState(
                title: "打开 DevPulse",
                detail: nil,
                icon: "arrow.triangle.2.circlepath"
            )
        case .unavailable:
            shortState(
                title: "数据不可用",
                detail: "打开 DevPulse 以刷新",
                icon: "exclamationmark.triangle.fill"
            )
        case .ready:
            readyContent
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if entry.feed.state == .noRepositories {
            shortState(
                title: "没有仓库",
                detail: nil,
                icon: "tray"
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if entry.feed.state == .allClean {
                    Text("全部干净")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                }

                if let item = entry.feed.topItem {
                    HStack(alignment: .top, spacing: 8) {
                        WidgetReadinessBadge(level: item.commitReadiness.level, size: .large)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.repoName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)

                                Spacer(minLength: 0)

                                Text(item.fileCountLabel)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            HStack(alignment: .center, spacing: 6) {
                                WidgetBranchPill(text: item.branch)
                                Text(item.changeBreakdownLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                } else {
                    shortState(
                        title: "打开 DevPulse",
                        detail: nil,
                        icon: "arrow.triangle.2.circlepath"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var placeholderContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 84, height: 10)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 104, height: 20)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 132, height: 14)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 10)
        }
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private func shortState(title: String, detail: String?, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let updatedText = entry.updatedText {
            Text("更新于 \(updatedText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct MediumGlanceWidgetView: View {
    let entry: WidgetEntry

    private let maxItems = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetChromeHeader(trailingText: headerTrailingText)

            content

            Spacer(minLength: 0)

            footer
        }
        .padding(10)
    }

    private var headerTrailingText: String? {
        guard case .ready = entry.loadState, let summary = entry.snapshot?.scanSummary else {
            return nil
        }

        if summary.totalRepositories == 0 {
            return "没有仓库"
        }

        let activeRepos = summary.changedRepositories + summary.errorRepositories
        if activeRepos == 0 {
            return "全部干净"
        }

        if summary.totalChangedFiles > 0 {
            return "\(activeRepos) 个活跃仓库 · \(summary.totalChangedFiles) 个文件"
        }

        return "\(activeRepos) 个活跃仓库"
    }

    @ViewBuilder
    private var content: some View {
        switch entry.loadState {
        case .placeholder:
            placeholderRows
        case .noSnapshot:
            shortState(
                title: "打开 DevPulse",
                detail: nil,
                icon: "arrow.triangle.2.circlepath"
            )
        case .unavailable:
            shortState(
                title: "数据不可用",
                detail: "打开 DevPulse 以刷新",
                icon: "exclamationmark.triangle.fill"
            )
        case .ready:
            readyContent
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if entry.feed.state == .noRepositories {
            shortState(
                title: "没有仓库",
                detail: nil,
                icon: "tray"
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if entry.feed.state == .allClean {
                    Text("全部干净")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                }

                ForEach(entry.feed.items.prefix(maxItems), id: \.id) { item in
                    WidgetRepoRow(item: item)

                    if item.id != entry.feed.items.prefix(maxItems).last?.id {
                        Divider().opacity(0.25)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var placeholderRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                WidgetRepoRow(item: nil)
            }
        }
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private func shortState(title: String, detail: String?, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let updatedText = entry.updatedText {
            Text("更新于 \(updatedText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct WidgetRepoRow: View {
    let item: ActivityTimelineItem?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let item {
                WidgetReadinessBadge(level: item.commitReadiness.level, size: .compact)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.repoName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text(item.fileCountLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        WidgetBranchPill(text: item.branch)
                        Text(item.changeBreakdownLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            } else {
                WidgetReadinessBadge(level: .needsReview, size: .compact)

                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 92, height: 10)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.14))
                        .frame(width: 128, height: 9)
                }
            }
        }
    }
}

private struct WidgetBranchPill: View {
    let text: String

    var body: some View {
        Text(text.isEmpty ? "detached" : text)
            .textCase(nil)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )
            .foregroundStyle(.secondary)
    }
}

private struct WidgetReadinessBadge: View {
    enum Size {
        case compact
        case large
    }

    let level: CommitReadinessLevel
    var size: Size = .compact

    var body: some View {
        HStack(spacing: size == .large ? 5 : 4) {
            Image(systemName: symbolName)
                .font(size == .large ? .caption.weight(.semibold) : .caption2.weight(.semibold))
            Text(level.shortLabel)
                .font(badgeFont)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            Capsule().fill(tint.opacity(0.14))
        )
        .foregroundStyle(tint)
    }

    private var badgeFont: Font {
        switch size {
        case .compact:
            return .caption2.weight(.semibold)
        case .large:
            return .system(size: 13, weight: .semibold)
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .compact:
            return 6
        case .large:
            return 8
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .compact:
            return 2
        case .large:
            return 4
        }
    }

    private var tint: Color {
        switch level {
        case .clean:
            return .secondary
        case .inProgress:
            return .orange
        case .commitReady:
            return .blue
        case .needsReview:
            return .orange
        case .pushSuggested:
            return .green
        case .attention:
            return .red
        }
    }

    private var symbolName: String {
        switch level {
        case .clean:
            return "checkmark.circle.fill"
        case .inProgress:
            return "pencil.circle.fill"
        case .commitReady:
            return "checkmark.seal.fill"
        case .needsReview:
            return "questionmark.circle.fill"
        case .pushSuggested:
            return "arrow.up.circle.fill"
        case .attention:
            return "exclamationmark.triangle.fill"
        }
    }
}

private extension WidgetEntry {
    var updatedText: String? {
        guard let snapshot else { return nil }

        var timestamps: [(timestamp: String, date: Date)] = []
        if let writtenAt = snapshot.writtenAt, let writtenDate = DateFormatting.date(from: writtenAt) {
            timestamps.append((timestamp: writtenAt, date: writtenDate))
        }

        if let generatedDate = DateFormatting.date(from: snapshot.generatedAt) {
            timestamps.append((timestamp: snapshot.generatedAt, date: generatedDate))
        }

        guard let latest = timestamps.max(by: { $0.date < $1.date }) else {
            return nil
        }

        return DateFormatting.relativeTime(from: latest.timestamp, relativeTo: date)
    }
}

private extension ActivityTimelineItem {
    var fileCountLabel: String {
        changedFileCount == 1 ? "1 处改动" : "\(changedFileCount) 处改动"
    }

    var changeBreakdownLabel: String {
        let parts = [
            modifiedFileCount > 0 ? "已修改 \(modifiedFileCount)" : nil,
            addedFileCount > 0 ? "已新增 \(addedFileCount)" : nil,
            deletedFileCount > 0 ? "已删除 \(deletedFileCount)" : nil,
            untrackedFileCount > 0 ? "未跟踪 \(untrackedFileCount)" : nil
        ].compactMap { $0 }

        guard !parts.isEmpty else {
            return "没有本地改动"
        }

        if parts.count <= 2 {
            return parts.joined(separator: " · ")
        }

        return changedFileCount == 1 ? "1 处改动" : "\(changedFileCount) 处改动"
    }
}

@main
struct DevPulseWidget: Widget {
    let kind = "DevPulseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            DevPulseWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("DevPulse")
        .description("一眼查看本地 Git 仓库状态。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

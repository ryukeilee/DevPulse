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
    let trustAssessment: SnapshotTrustAssessment?

    static var placeholder: WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .placeholder,
            trustAssessment: nil
        )
    }

    static func content(snapshot: AppGroupData,
                        feed: ActivityTimelineFeed) -> WidgetEntry {
        let trustAssessment = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: snapshot.generatedAt,
            writtenAt: snapshot.writtenAt,
            missingReason: "共享快照缺少 generatedAt / writtenAt，无法确认 Widget 数据是否最新。"
        )

        return WidgetEntry(
            date: Date(),
            snapshot: snapshot,
            feed: feed,
            loadState: .ready,
            trustAssessment: trustAssessment
        )
    }

    static func noSnapshot() -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .noSnapshot,
            trustAssessment: nil
        )
    }

    static func unavailable() -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .unavailable,
            trustAssessment: nil
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

    private var summary: WidgetPrioritySummary {
        WidgetPrioritySummaryBuilder.build(
            feed: entry.feed,
            trustAssessment: entry.trustAssessment
        )
    }

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
                title: "尚未生成数据",
                detail: "打开 DevPulse 后执行一次刷新",
                icon: "arrow.triangle.2.circlepath"
            )
        case .unavailable:
            shortState(
                title: "共享数据异常",
                detail: "打开 DevPulse 查看 Diagnostics",
                icon: "exclamationmark.triangle.fill"
            )
        case .ready:
            guardedReadyContent
        }
    }

    @ViewBuilder
    private var guardedReadyContent: some View {
        switch entry.trustAssessment?.state {
        case .fresh:
            readyContent
        case .stale, .expired:
            shortState(
                title: "数据可能已过期",
                detail: "打开 DevPulse 刷新后再判断是否适合提交",
                icon: "clock.badge.exclamationmark"
            )
        case .unknown, .failed:
            shortState(
                title: "状态未知",
                detail: "打开 DevPulse 查看 Diagnostics",
                icon: "questionmark.circle"
            )
        case .none:
            shortState(
                title: "状态未知",
                detail: "打开 DevPulse 查看 Diagnostics",
                icon: "questionmark.circle"
            )
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        prioritySummary(summary, largeBadge: true, showAuxiliary: false)
    }

    @ViewBuilder
    private func prioritySummary(_ summary: WidgetPrioritySummary,
                                 largeBadge: Bool,
                                 showAuxiliary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let readinessLevel = summary.readinessLevel {
                WidgetReadinessBadge(level: readinessLevel, size: largeBadge ? .large : .compact)
            }

            Text(summary.title)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)

            Text(summary.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if showAuxiliary, let auxiliary = summary.auxiliary {
                Text(auxiliary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        Text(entry.footerText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct MediumGlanceWidgetView: View {
    let entry: WidgetEntry

    private var summary: WidgetPrioritySummary {
        WidgetPrioritySummaryBuilder.build(
            feed: entry.feed,
            trustAssessment: entry.trustAssessment
        )
    }

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
        guard
            case .ready = entry.loadState,
            entry.trustAssessment?.state == .fresh,
            let summary = entry.snapshot?.scanSummary
        else {
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
                title: "尚未生成数据",
                detail: "打开 DevPulse 后执行一次刷新",
                icon: "arrow.triangle.2.circlepath"
            )
        case .unavailable:
            shortState(
                title: "共享数据异常",
                detail: "打开 DevPulse 查看 Diagnostics",
                icon: "exclamationmark.triangle.fill"
            )
        case .ready:
            guardedReadyContent
        }
    }

    @ViewBuilder
    private var guardedReadyContent: some View {
        switch entry.trustAssessment?.state {
        case .fresh:
            readyContent
        case .stale, .expired:
            shortState(
                title: "数据可能已过期",
                detail: "打开 DevPulse 刷新后再判断是否适合提交",
                icon: "clock.badge.exclamationmark"
            )
        case .unknown, .failed:
            shortState(
                title: "状态未知",
                detail: "打开 DevPulse 查看 Diagnostics",
                icon: "questionmark.circle"
            )
        case .none:
            shortState(
                title: "状态未知",
                detail: "打开 DevPulse 查看 Diagnostics",
                icon: "questionmark.circle"
            )
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        prioritySummary(summary, largeBadge: false, showAuxiliary: true)
    }

    @ViewBuilder
    private func prioritySummary(_ summary: WidgetPrioritySummary,
                                 largeBadge: Bool,
                                 showAuxiliary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let readinessLevel = summary.readinessLevel {
                WidgetReadinessBadge(level: readinessLevel, size: largeBadge ? .large : .compact)
            }

            Text(summary.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            Text(summary.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if showAuxiliary, let auxiliary = summary.auxiliary {
                Text(auxiliary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var placeholderRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 70, height: 20)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 140, height: 12)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 190, height: 10)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 88, height: 9)
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
        Text(entry.footerText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
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
        case .idle:
            return .secondary
        case .review:
            return .orange
        case .ready:
            return .green
        case .dirty:
            return .red
        case .unknown:
            return .red
        }
    }

    private var symbolName: String {
        switch level {
        case .idle:
            return "checkmark.circle.fill"
        case .review:
            return "questionmark.circle.fill"
        case .ready:
            return "arrow.up.circle.fill"
        case .dirty:
            return "exclamationmark.triangle.fill"
        case .unknown:
            return "exclamationmark.triangle.fill"
        }
    }
}

private extension WidgetEntry {
    var footerText: String {
        switch loadState {
        case .placeholder:
            return "正在读取共享快照"
        case .noSnapshot:
            return "最近刷新: 尚未生成"
        case .unavailable:
            return "最近刷新: 读取失败"
        case .ready:
            if let trustAssessment, trustAssessment.state != .fresh {
                return trustAssessment.detail
            }

            guard let snapshot else {
                return "最近刷新: 未知"
            }

            var timestamps: [(timestamp: String, date: Date)] = []
            if let writtenAt = snapshot.writtenAt, let writtenDate = DateFormatting.date(from: writtenAt) {
                timestamps.append((timestamp: writtenAt, date: writtenDate))
            }

            if let generatedDate = DateFormatting.date(from: snapshot.generatedAt) {
                timestamps.append((timestamp: snapshot.generatedAt, date: generatedDate))
            }

            guard let latest = timestamps.max(by: { $0.date < $1.date }) else {
                return "最近刷新: 未知"
            }

            return "最近刷新 \(DateFormatting.relativeTime(from: latest.timestamp, relativeTo: date))"
        }
    }
}

private extension ActivityTimelineItem {
    var fileCountLabel: String {
        if commitReadiness.level == .unknown {
            return "状态异常"
        }
        return changedFileCount == 1 ? "1 处改动" : "\(changedFileCount) 处改动"
    }

    var changeBreakdownLabel: String {
        if commitReadiness.level == .unknown {
            return commitReadiness.detail
        }

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

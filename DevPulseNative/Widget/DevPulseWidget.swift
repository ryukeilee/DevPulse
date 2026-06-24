import Foundation
import SwiftUI
import WidgetKit

private enum WidgetSnapshotSchema {
    static let version = RepositorySnapshotSchema.version
}

private enum WidgetSnapshotStore {
    static let appGroupIdentifier = SharedSnapshotLocation.appGroupIdentifier
    private static let snapshotFileName = SharedSnapshotLocation.fileName

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

enum WidgetSnapshotLoadError: LocalizedError, Equatable {
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
    case loadFailed
    case ready
}

struct WidgetLoadFailurePresentation: Equatable {
    let title: String
    let detail: String
    let icon: String
    let footerText: String
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
        let nextRefreshInterval: TimeInterval
        switch entry.loadState {
        case .placeholder, .noSnapshot, .loadFailed:
            nextRefreshInterval = 300
        case .ready:
            nextRefreshInterval = 900
        }
        let nextRefresh = Date().addingTimeInterval(nextRefreshInterval)
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
                return .loadFailed(error)
            }
        }
    }
}

struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AppGroupData?
    let feed: ActivityTimelineFeed
    let loadState: WidgetLoadState
    let loadFailure: WidgetLoadFailurePresentation?
    let trustAssessment: SnapshotTrustAssessment?

    static var placeholder: WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .placeholder,
            loadFailure: nil,
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
            loadFailure: nil,
            trustAssessment: trustAssessment
        )
    }

    static func noSnapshot() -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .noSnapshot,
            loadFailure: nil,
            trustAssessment: nil
        )
    }

    static func loadFailed(_ error: WidgetSnapshotLoadError) -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .loadFailed,
            loadFailure: WidgetLoadFailurePresentation(
                title: error.widgetTitle,
                detail: error.widgetDetail,
                icon: error.widgetIcon,
                footerText: error.footerText
            ),
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
            case .systemLarge:
                LargeGlanceWidgetView(entry: entry)
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

private struct WidgetRepositoryBoard: View {
    let items: [ActivityTimelineItem]
    let limit: Int
    var prominentFirst: Bool = false
    var showHintOnFirst: Bool = false
    var hideSecondaryBadgeOnFirst: Bool = false

    var body: some View {
        let visibleItems = Array(items.prefix(limit))

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                WidgetRepositoryRow(
                    item: item,
                    prominent: prominentFirst && index == 0,
                    showHint: showHintOnFirst && index == 0,
                    hideSecondaryBadge: hideSecondaryBadgeOnFirst && index == 0
                )

                if index < visibleItems.count - 1 {
                    Divider()
                        .opacity(0.35)
                }
            }
        }
    }
}

private struct WidgetRepositoryRow: View {
    let item: ActivityTimelineItem
    var prominent: Bool = false
    var showHint: Bool = false
    var hideSecondaryBadge: Bool = false

    private var readiness: CommitReadinessAssessment {
        item.commitReadiness
    }

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 6 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.repoName)
                    .font(prominent ? .system(size: 16, weight: .semibold) : .system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(item.widgetChangeCountLabel)
                    .font(prominent ? .caption.weight(.semibold) : .caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                WidgetRepositoryStatusBadge(status: item.status)

                if !hideSecondaryBadge {
                    WidgetReadinessBadge(level: readiness.level, size: prominent ? .large : .compact)
                }

                Spacer(minLength: 4)

                Text(item.activityLabel)
                    .font(prominent ? .caption.weight(.medium) : .caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if showHint {
                Text(readiness.widgetShortHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(prominent ? 2 : 1)
            }
        }
    }
}

private struct WidgetRepositoryStatusBadge: View {
    let status: RepositoryStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(tint.opacity(backgroundOpacity))
            )
            .foregroundStyle(tint)
    }

    private var label: String {
        switch status {
        case .clean:
            return "Clean"
        case .changed:
            return "Dirty"
        case .error:
            return "Error"
        }
    }

    private var tint: Color {
        switch status {
        case .clean:
            return .secondary
        case .changed:
            return .orange
        case .error:
            return .red
        }
    }

    private var backgroundOpacity: Double {
        switch status {
        case .clean:
            return 0.1
        case .changed:
            return 0.14
        case .error:
            return 0.16
        }
    }
}

private struct SmallGlanceWidgetView: View {
    let entry: WidgetEntry

    private var prioritizedItems: [ActivityTimelineItem] {
        WidgetRepositoryPriorityBuilder.build(from: entry.snapshot)
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
                title: "尚未生成快照",
                detail: "打开 DevPulse 执行 Refresh Data 或 Rescan Now",
                icon: "arrow.triangle.2.circlepath"
            )
        case .loadFailed:
            shortState(
                title: entry.loadFailure?.title ?? "共享快照读取失败",
                detail: entry.loadFailure?.detail,
                icon: entry.loadFailure?.icon ?? "exclamationmark.triangle.fill"
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
                detail: staleDetail,
                icon: "clock.badge.exclamationmark"
            )
        case .unknown, .failed:
            shortState(
                title: "状态未知",
                detail: "打开 DevPulse 查看 Diagnostics，并执行 Refresh Data 重写共享快照",
                icon: "questionmark.circle"
            )
        case .none:
            shortState(
                title: "状态未知",
                detail: "打开 DevPulse 查看 Diagnostics，并执行 Refresh Data 重写共享快照",
                icon: "questionmark.circle"
            )
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if prioritizedItems.isEmpty {
            shortState(
                title: "没有找到仓库",
                detail: "检查扫描目录后重新刷新",
                icon: "folder"
            )
        } else {
            WidgetRepositoryBoard(
                items: prioritizedItems,
                limit: 1,
                prominentFirst: true,
                showHintOnFirst: true,
                hideSecondaryBadgeOnFirst: true
            )
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

    private var staleDetail: String {
        if let trustAssessment = entry.trustAssessment {
            return "\(trustAssessment.detail)。打开 DevPulse 执行 Refresh Data"
        }
        return "打开 DevPulse 执行 Refresh Data，再判断当前状态"
    }
}

private struct MediumGlanceWidgetView: View {
    let entry: WidgetEntry

    private var prioritizedItems: [ActivityTimelineItem] {
        WidgetRepositoryPriorityBuilder.build(from: entry.snapshot)
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
        if case .ready = entry.loadState,
           let trustAssessment = entry.trustAssessment,
           trustAssessment.state != .fresh {
            return trustAssessment.title
        }

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
                title: "尚未生成快照",
                detail: "打开 DevPulse 执行 Refresh Data 或 Rescan Now",
                icon: "arrow.triangle.2.circlepath"
            )
        case .loadFailed:
            shortState(
                title: entry.loadFailure?.title ?? "共享快照读取失败",
                detail: entry.loadFailure?.detail,
                icon: entry.loadFailure?.icon ?? "exclamationmark.triangle.fill"
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
                detail: staleDetail,
                icon: "clock.badge.exclamationmark"
            )
        case .unknown, .failed:
            shortState(
                title: "状态未知",
                detail: "打开 DevPulse 查看 Diagnostics，并执行 Refresh Data 重写共享快照",
                icon: "questionmark.circle"
            )
        case .none:
            shortState(
                title: "状态未知",
                detail: "打开 DevPulse 查看 Diagnostics，并执行 Refresh Data 重写共享快照",
                icon: "questionmark.circle"
            )
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if prioritizedItems.isEmpty {
            shortState(
                title: "没有找到仓库",
                detail: "检查扫描目录后重新刷新",
                icon: "folder"
            )
        } else {
            WidgetRepositoryBoard(items: prioritizedItems, limit: 2)
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

    private var staleDetail: String {
        if let trustAssessment = entry.trustAssessment {
            return "\(trustAssessment.detail)。打开 DevPulse 执行 Refresh Data"
        }
        return "打开 DevPulse 执行 Refresh Data，再判断当前状态"
    }
}

private struct LargeGlanceWidgetView: View {
    let entry: WidgetEntry

    private var prioritizedItems: [ActivityTimelineItem] {
        WidgetRepositoryPriorityBuilder.build(from: entry.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetChromeHeader(trailingText: headerTrailingText)

            content

            Spacer(minLength: 0)

            footer
        }
        .padding(12)
    }

    private var headerTrailingText: String? {
        if case .ready = entry.loadState,
           let trustAssessment = entry.trustAssessment,
           trustAssessment.state != .fresh {
            return trustAssessment.title
        }

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

        return "\(activeRepos) 个待看仓库"
    }

    @ViewBuilder
    private var content: some View {
        switch entry.loadState {
        case .placeholder:
            placeholderRows
        case .noSnapshot:
            shortState(
                title: "尚未生成快照",
                detail: "打开 DevPulse 执行 Refresh Data 或 Rescan Now",
                icon: "arrow.triangle.2.circlepath"
            )
        case .loadFailed:
            shortState(
                title: entry.loadFailure?.title ?? "共享快照读取失败",
                detail: entry.loadFailure?.detail,
                icon: entry.loadFailure?.icon ?? "exclamationmark.triangle.fill"
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
                detail: staleDetail,
                icon: "clock.badge.exclamationmark"
            )
        case .unknown, .failed:
            shortState(
                title: "状态未知",
                detail: "打开 DevPulse 查看 Diagnostics，并执行 Refresh Data 重写共享快照",
                icon: "questionmark.circle"
            )
        case .none:
            shortState(
                title: "状态未知",
                detail: "打开 DevPulse 查看 Diagnostics，并执行 Refresh Data 重写共享快照",
                icon: "questionmark.circle"
            )
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if prioritizedItems.isEmpty {
            shortState(
                title: "没有找到仓库",
                detail: "检查扫描目录后重新刷新",
                icon: "folder"
            )
        } else {
            WidgetRepositoryBoard(items: prioritizedItems, limit: 4)
        }
    }

    @ViewBuilder
    private var placeholderRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 170, height: 12)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 10)
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private func shortState(title: String, detail: String?, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
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

    private var staleDetail: String {
        if let trustAssessment = entry.trustAssessment {
            return "\(trustAssessment.detail)。打开 DevPulse 执行 Refresh Data"
        }
        return "打开 DevPulse 执行 Refresh Data，再判断当前状态"
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
            return "最近刷新: 尚未生成快照"
        case .loadFailed:
            return loadFailure?.footerText ?? "最近刷新: snapshot 读取失败"
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

private extension WidgetSnapshotLoadError {
    var widgetTitle: String {
        switch self {
        case .appGroupUnavailable:
            return "共享容器不可用"
        case .snapshotMissing:
            return "尚未生成快照"
        case .readFailed:
            return "共享快照读取失败"
        case .decodeFailed:
            return "共享快照损坏"
        case .schemaMismatch:
            return "快照版本不匹配"
        }
    }

    var widgetDetail: String {
        switch self {
        case .appGroupUnavailable:
            return "检查 App 与 Widget 是否使用同一 Team / App Group，然后打开 Diagnostics"
        case .snapshotMissing:
            return "打开 DevPulse 执行 Refresh Data 或 Rescan Now"
        case .readFailed:
            return "打开 Diagnostics 检查 snapshot 路径、权限和共享容器状态"
        case .decodeFailed:
            return "在 DevPulse 执行 Refresh Data，重写共享 snapshot"
        case .schemaMismatch:
            return "重新构建 App 与 Widget 后，再执行 Refresh Data"
        }
    }

    var widgetIcon: String {
        switch self {
        case .appGroupUnavailable:
            return "externaldrive.badge.exclamationmark"
        case .snapshotMissing:
            return "arrow.triangle.2.circlepath"
        case .readFailed:
            return "exclamationmark.triangle.fill"
        case .decodeFailed:
            return "doc.badge.gearshape"
        case .schemaMismatch:
            return "arrow.triangle.2.circlepath.circle"
        }
    }

    var footerText: String {
        switch self {
        case .appGroupUnavailable:
            return "最近刷新: 共享容器不可用"
        case .snapshotMissing:
            return "最近刷新: 尚未生成快照"
        case .readFailed:
            return "最近刷新: snapshot 读取失败"
        case .decodeFailed:
            return "最近刷新: snapshot 解码失败"
        case .schemaMismatch:
            return "最近刷新: snapshot 版本不匹配"
        }
    }
}

private extension ActivityTimelineItem {
    var widgetChangeCountLabel: String {
        changedFileCount == 1 ? "1 处改动" : "\(changedFileCount) 处改动"
    }

    var activityLabel: String {
        if let lastChangedAt {
            return DateFormatting.relativeTime(from: lastChangedAt)
        }

        return DateFormatting.relativeTime(from: lastScannedAt)
    }
}

@main
struct DevPulseWidget: Widget {
    let kind = WidgetIdentity.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            DevPulseWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("DevPulse")
        .description("一眼查看本地 Git 仓库状态。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

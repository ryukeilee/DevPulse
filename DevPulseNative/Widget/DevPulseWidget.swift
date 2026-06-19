import Foundation
import SwiftUI
import WidgetKit

private enum WidgetSnapshotSchema {
    static let version = RepositorySnapshotSchema.version
}

private enum WidgetSnapshotStore {
    static let appGroupIdentifier = "group.local.devpulse"
    private static let snapshotFileName = "repositories.json"
    static let staleThreshold: TimeInterval = 24 * 60 * 60

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

        let nextRefresh = Date().addingTimeInterval(entry.isError ? 300 : 900)
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }

    private func loadEntry() -> WidgetEntry {
        switch WidgetSnapshotStore.load() {
        case .success(let snapshot):
            let feed = ActivityTimelineBuilder.build(from: snapshot)
            if let staleDetail = staleDetail(for: snapshot) {
                return .errorState(
                    title: "Snapshot stale",
                    subtitle: "Open DevPulse and run a fresh scan.",
                    detail: staleDetail
                )
            }
            return .content(snapshot: snapshot, feed: feed)
        case .failure(let error):
            switch error {
            case .appGroupUnavailable:
                return .errorState(
                    title: "App Group unavailable",
                    subtitle: "Open DevPulse and verify entitlements.",
                    detail: error.localizedDescription
                )
            case .snapshotMissing:
                return .errorState(
                    title: "Snapshot missing",
                    subtitle: "Open DevPulse and run a scan to create repositories.json.",
                    detail: error.localizedDescription
                )
            case .readFailed, .decodeFailed, .schemaMismatch:
                return .errorState(
                    title: "Shared data invalid",
                    subtitle: "Open DevPulse and rescan to refresh the widget snapshot.",
                    detail: error.localizedDescription
                )
            }
        }
    }

    private func staleDetail(for snapshot: AppGroupData) -> String? {
        let latestTimestamp = [snapshot.writtenAt, snapshot.generatedAt]
            .compactMap { $0 }
            .compactMap { DateFormatting.date(from: $0) }
            .max()

        guard let latestTimestamp else { return nil }

        let age = Date().timeIntervalSince(latestTimestamp)
        guard age >= WidgetSnapshotStore.staleThreshold else { return nil }

        return "Latest shared snapshot is \(conciseTimeLabel(from: latestTimestamp)) old."
    }

    private func conciseTimeLabel(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "<1m ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AppGroupData?
    let feed: ActivityTimelineFeed
    let generatedAt: String?
    let isPlaceholder: Bool
    let isError: Bool
    let errorMessage: String?

    static var placeholder: WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .active, items: []),
            generatedAt: nil,
            isPlaceholder: true,
            isError: false,
            errorMessage: nil
        )
    }

    static func content(snapshot: AppGroupData, feed: ActivityTimelineFeed) -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: snapshot,
            feed: feed,
            generatedAt: snapshot.generatedAt,
            isPlaceholder: false,
            isError: false,
            errorMessage: nil
        )
    }

    static func errorState(title: String, subtitle: String, detail: String) -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .active, items: []),
            generatedAt: nil,
            isPlaceholder: false,
            isError: true,
            errorMessage: "\(title): \(subtitle) \(detail)"
        )
    }
}

struct DevPulseWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var entry: WidgetEntry

    var body: some View {
        Group {
            switch widgetFamily {
            case .systemSmall:
                SmallActivityWidgetView(entry: entry)
            case .systemMedium:
                MediumActivityWidgetView(entry: entry)
            default:
                SmallActivityWidgetView(entry: entry)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct WidgetHeader: View {
    let subtitle: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption2.weight(.semibold))
            Text("DevPulse")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SmallActivityWidgetView: View {
    let entry: WidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(subtitle: headerSubtitle)

            if entry.isPlaceholder {
                placeholderContent
            } else if let error = entry.errorMessage {
                errorContent(error)
            } else {
                smallContent
            }

            Spacer(minLength: 0)

            footerView
        }
        .padding(10)
    }

    private var headerSubtitle: String {
        switch entry.feed.state {
        case .neverScanned:
            return "Waiting"
        case .noRepositories:
            return "No repos"
        case .allClean:
            return "All clean"
        case .active:
            return "Timeline"
        }
    }

    @ViewBuilder
    private var smallContent: some View {
        switch entry.feed.state {
        case .neverScanned:
            emptyState(
                title: "No scan yet",
                detail: "Open DevPulse and press Rescan Now."
            )
        case .noRepositories:
            emptyState(
                title: "No repositories found",
                detail: "Check scan roots in Settings."
            )
        case .allClean:
            if let topItem = entry.feed.topItem {
                topItemCard(item: topItem, emphasizeClean: true)
                summaryLine
            } else {
                emptyState(title: "All clean", detail: "No repository activity right now.")
            }
        case .active:
            if let topItem = entry.feed.topItem {
                topItemCard(item: topItem, emphasizeClean: false)
                summaryLine
            } else {
                emptyState(title: "Timeline unavailable", detail: "Open DevPulse to refresh the snapshot.")
            }
        }
    }

    private var summaryLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let summary = entry.snapshot?.scanSummary {
                Text("\(summary.totalRepositories) repos · \(summary.changedRepositories) changed · \(summary.totalChangedFiles) files")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let topItem = entry.feed.topItem {
                Text(topItem.changedFilesPreview.prefix(3).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private func topItemCard(item: ActivityTimelineItem, emphasizeClean: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.repoName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(relativeTime(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                pill(text: item.branch, tint: .secondary)
                statusPill(item.status, emphasizeClean: emphasizeClean)
                RiskDot(level: item.risk)
                CommitReadinessBadge(level: item.commitReadiness.level, compact: true)
            }

            Text(item.commitReadiness.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(changeSummary(for: item))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private func changeSummary(for item: ActivityTimelineItem) -> String {
        "modified \(item.modifiedFileCount) · added \(item.addedFileCount) · deleted \(item.deletedFileCount) · untracked \(item.untrackedFileCount)"
    }

    private func relativeTime(for item: ActivityTimelineItem) -> String {
        if let changedAt = item.lastChangedAt {
            return DateFormatting.relativeTime(from: changedAt, relativeTo: entry.date)
        }
        return DateFormatting.relativeTime(from: item.lastScannedAt, relativeTo: entry.date)
    }

    @ViewBuilder
    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var placeholderContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 90, height: 12)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 132, height: 16)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 10)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 110, height: 10)
        }
    }

    @ViewBuilder
    private func errorContent(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }

    private var footerView: some View {
        HStack {
            Spacer(minLength: 0)
            if let generatedAt = entry.generatedAt {
                Text("Updated \(DateFormatting.relativeTime(from: generatedAt, relativeTo: entry.date))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pill(text: String, tint: Color) -> some View {
        Text(text.isEmpty ? "detached" : text)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(tint.opacity(0.12))
            )
            .foregroundStyle(tint)
    }

    private func statusPill(_ status: RepositoryStatus, emphasizeClean: Bool) -> some View {
        let title: String
        let tint: Color

        switch status {
        case .changed:
            title = "dirty"
            tint = .orange
        case .clean:
            title = emphasizeClean ? "all clean" : "clean"
            tint = .green
        case .error:
            title = "error"
            tint = .red
        }

        return pill(text: title, tint: tint)
    }
}

private struct MediumActivityWidgetView: View {
    let entry: WidgetEntry

    private let maxItems = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(subtitle: headerSubtitle)

            if entry.isPlaceholder {
                placeholderRows
            } else if let error = entry.errorMessage {
                errorContent(error)
            } else {
                mediumContent
            }

            Spacer(minLength: 0)

            footerView
        }
        .padding(10)
    }

    private var headerSubtitle: String {
        switch entry.feed.state {
        case .neverScanned:
            return "Waiting"
        case .noRepositories:
            return "No repos"
        case .allClean:
            return "All clean"
        case .active:
            return "Timeline"
        }
    }

    @ViewBuilder
    private var mediumContent: some View {
        switch entry.feed.state {
        case .neverScanned:
            emptyState(
                title: "No scan yet",
                detail: "Open DevPulse and press Rescan Now."
            )
        case .noRepositories:
            emptyState(
                title: "No repositories found",
                detail: "Check scan roots in Settings."
            )
        case .allClean, .active:
            VStack(alignment: .leading, spacing: 6) {
                if entry.feed.state == .allClean {
                    Text("All clean")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }

                ForEach(entry.feed.items.prefix(maxItems), id: \.id) { item in
                    timelineRow(item)

                    if item.id != entry.feed.items.prefix(maxItems).last?.id {
                        Divider().opacity(0.25)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: ActivityTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.repoName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(relativeTime(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                pill(text: item.branch, tint: .secondary)
                statusPill(item.status)
                RiskDot(level: item.risk)
                CommitReadinessBadge(level: item.commitReadiness.level, compact: true)
                Text(changeSummary(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !item.changedFilesPreview.isEmpty {
                Text(item.changedFilesPreview.prefix(3).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func relativeTime(for item: ActivityTimelineItem) -> String {
        if let changedAt = item.lastChangedAt {
            return DateFormatting.relativeTime(from: changedAt, relativeTo: entry.date)
        }
        return DateFormatting.relativeTime(from: item.lastScannedAt, relativeTo: entry.date)
    }

    private func changeSummary(for item: ActivityTimelineItem) -> String {
        "m \(item.modifiedFileCount) · a \(item.addedFileCount) · d \(item.deletedFileCount) · u \(item.untrackedFileCount)"
    }

    @ViewBuilder
    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var placeholderRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 92, height: 11)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 148, height: 9)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 9)
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private func errorContent(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }

    private var footerView: some View {
        HStack {
            if let summary = entry.snapshot?.scanSummary {
                Text("\(summary.totalRepositories) repos · \(summary.changedRepositories) changed · \(summary.totalChangedFiles) files")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let generatedAt = entry.generatedAt {
                Text("Updated \(DateFormatting.relativeTime(from: generatedAt, relativeTo: entry.date))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pill(text: String, tint: Color) -> some View {
        Text(text.isEmpty ? "detached" : text)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(tint.opacity(0.12))
            )
            .foregroundStyle(tint)
    }

    private func statusPill(_ status: RepositoryStatus) -> some View {
        let title: String
        let tint: Color

        switch status {
        case .changed:
            title = "dirty"
            tint = .orange
        case .clean:
            title = "clean"
            tint = .green
        case .error:
            title = "error"
            tint = .red
        }

        return pill(text: title, tint: tint)
    }
}

private struct RiskDot: View {
    let level: RiskLevel

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help("Risk: \(level.rawValue)")
    }

    private var color: Color {
        switch level {
        case .low:
            return .green
        case .medium:
            return .orange
        case .high:
            return .red
        }
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
        .description("See your local Git repository status at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

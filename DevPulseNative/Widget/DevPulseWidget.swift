import Foundation
import SwiftUI
import WidgetKit

private enum WidgetSnapshotStore {
    static let appGroupIdentifier = "group.local.devpulse"
    private static let snapshotFileName = "repositories.json"

    static func load() -> Result<WidgetSnapshot, WidgetSnapshotLoadError> {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return .failure(.message("App Group container is unavailable."))
        }

        let snapshotURL = containerURL.appendingPathComponent(snapshotFileName)
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            return .failure(.message("Shared snapshot file is missing."))
        }

        do {
            let data = try Data(contentsOf: snapshotURL)
            do {
                let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
                return .success(snapshot)
            } catch {
                return .failure(.message("Shared snapshot decode failed: \(error.localizedDescription)"))
            }
        } catch {
            return .failure(.message("Shared snapshot read failed: \(error.localizedDescription)"))
        }
    }
}

private enum WidgetSnapshotLoadError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

private struct WidgetSnapshot: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let writtenAt: String?
    let scanSummary: WidgetScanSummary
    let repositories: [WidgetRepositorySnapshot]
}

private struct WidgetScanSummary: Codable {
    let totalRepositories: Int
    let changedRepositories: Int
    let totalChangedFiles: Int
    let errorRepositories: Int
}

private struct WidgetRepositorySnapshot: Codable {
    let name: String
    let path: String
    let branch: String
    let status: String
    let modifiedFileCount: Int
    let addedFileCount: Int
    let deletedFileCount: Int
    let untrackedFileCount: Int
    let changedFileCount: Int
    let changedFilesPreview: [String]
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry.placeholder()
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let entry = loadEntry()
        completion(Timeline(entries: [entry], policy: timelinePolicy(for: entry)))
    }

    private func loadEntry() -> WidgetEntry {
        switch WidgetSnapshotStore.load() {
        case .success(let snapshot):
            return buildEntry(from: snapshot)
        case .failure(let error):
            return .errorState(
                title: "Shared data unavailable",
                subtitle: "Open DevPulse to refresh the snapshot.",
                detail: error.localizedDescription
            )
        }
    }

    private func buildEntry(from snapshot: WidgetSnapshot) -> WidgetEntry {
        guard let repo = snapshot.repositories.first else {
            return .emptyState(
                subtitle: "Open DevPulse to scan local Git repos.",
                detail: "Shared data is ready, but no repositories have been scanned yet."
            )
        }

        let summary = snapshot.scanSummary
        let repoLine = repo.branch.isEmpty ? repo.name : "\(repo.name) • \(repo.branch)"
        let changeLine = repo.changedFileCount == 1 ? "1 changed file" : "\(repo.changedFileCount) changed files"
        let breakdown = "modified \(repo.modifiedFileCount) · added \(repo.addedFileCount) · deleted \(repo.deletedFileCount) · untracked \(repo.untrackedFileCount)"
        let writtenAt = conciseTimeLabel(snapshot.writtenAt ?? snapshot.generatedAt)

        return WidgetEntry(
            date: Date(),
            title: repoLine,
            subtitle: "\(summary.changedRepositories) changed repos · \(summary.totalChangedFiles) files",
            detail: "\(changeLine) • \(breakdown) • written \(writtenAt)",
            isPlaceholder: false,
            isError: false
        )
    }

    private func timelinePolicy(for entry: WidgetEntry) -> TimelineReloadPolicy {
        if entry.isError {
            return .after(Date().addingTimeInterval(5 * 60))
        }
        return .after(Date().addingTimeInterval(15 * 60))
    }

    private func conciseTimeLabel(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString)
        guard let date else { return isoString }

        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "<1m ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

struct WidgetEntry: TimelineEntry {
    let date: Date
    let title: String
    let subtitle: String
    let detail: String
    let isPlaceholder: Bool
    let isError: Bool

    static func placeholder() -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            title: "No repository data",
            subtitle: "Open DevPulse to generate a scan.",
            detail: "The widget is waiting for App Group data.",
            isPlaceholder: true,
            isError: false
        )
    }

    static func emptyState(subtitle: String, detail: String) -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            title: "DevPulse",
            subtitle: subtitle,
            detail: detail,
            isPlaceholder: true,
            isError: false
        )
    }

    static func errorState(title: String, subtitle: String, detail: String) -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            title: title,
            subtitle: subtitle,
            detail: detail,
            isPlaceholder: true,
            isError: true
        )
    }
}

struct DevPulseWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var entry: WidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: entry.isError ? "exclamationmark.triangle.fill" : (entry.isPlaceholder ? "hourglass" : "terminal"))
                    .font(.caption)
                Text("DevPulse")
                    .font(.caption.weight(.semibold))
            }

            Text(entry.title)
                .font(widgetFamily == .systemSmall ? .headline : .title3.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(entry.isError ? .red : .primary)

            Text(entry.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if widgetFamily == .systemMedium {
                Text(entry.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            Text(entry.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
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

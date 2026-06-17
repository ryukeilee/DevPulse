import Foundation
import WidgetKit

/// TimelineProvider that reads the latest snapshot from the App Group
/// and produces entries for the widget.
struct DevPulseWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> DevPulseWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (DevPulseWidgetEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(loadEntry())
        }
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<DevPulseWidgetEntry>) -> Void) {
        let entry = loadEntry()

        // Refresh roughly every 10 minutes; WidgetKit manages actual cadence
        let nextRefresh = Date().addingTimeInterval(600)
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }

    // MARK: - Load from App Group

    private func loadEntry() -> DevPulseWidgetEntry {
        guard let url = AppGroupStore.snapshotURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppGroupData.self, from: data) else {
            return .needAccess
        }

        let repos = decoded.repositories

        // No repos found
        if repos.isEmpty {
            return .noReposFound
        }

        // Convert to widget entries (sorted already by scanner)
        let widgetRepos = repos.map { WidgetRepositoryEntry(from: $0) }

        return DevPulseWidgetEntry(
            date: Date(),
            scanSummary: decoded.scanSummary,
            repositories: widgetRepos,
            generatedAt: decoded.generatedAt,
            isPlaceholder: false,
            errorMessage: nil
        )
    }
}

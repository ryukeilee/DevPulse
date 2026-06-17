import Foundation
import WidgetKit

enum AppGroupStore {
    /// The App Group identifier shared with the Widget Extension.
    static let appGroupIdentifier = "local.devpulse.group"

    /// File name for the snapshot inside the group container.
    private static let snapshotFileName = "repositories.json"

    // MARK: - Container URL

    /// URL for the App Group container directory.
    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    /// Full URL for the snapshot JSON file.
    static var snapshotURL: URL? {
        containerURL?.appendingPathComponent(snapshotFileName)
    }

    // MARK: - Read

    /// Read the current app group snapshot.
    static func read() -> AppGroupData {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppGroupData.self, from: data) else {
            return .empty()
        }
        return decoded
    }

    // MARK: - Write

    /// Write a snapshot to the app group container and request a widget refresh.
    static func write(_ data: AppGroupData) {
        guard let url = snapshotURL else {
            print("[DevPulse] App Group container URL is nil — check entitlements")
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let json = try encoder.encode(data)
            try json.write(to: url, options: .atomic)
            print("[DevPulse] Wrote repositories.json (schema v\(data.schemaVersion), "
                  + "\(data.repositories.count) repos)")

            // Notify WidgetKit to reload
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        } catch {
            print("[DevPulse] Failed to write repositories.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Utility

    /// Check whether the app group is properly configured.
    static var isAvailable: Bool {
        containerURL != nil
    }
}

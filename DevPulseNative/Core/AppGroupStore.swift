import Foundation
import WidgetKit

enum AppGroupStore {
    /// The App Group identifier shared with the Widget Extension.
    static let appGroupIdentifier = "group.local.devpulse"

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
    static func read() -> Result<AppGroupData, AppGroupStoreError> {
        guard let url = snapshotURL else {
            return .failure(.appGroupUnavailable)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.snapshotMissing)
        }

        do {
            let data = try Data(contentsOf: url)
            do {
                let decoded = try JSONDecoder().decode(AppGroupData.self, from: data)
                return .success(decoded)
            } catch {
                return .failure(.decodeFailed(error.localizedDescription))
            }
        } catch {
            return .failure(.readFailed(error.localizedDescription))
        }
    }

    // MARK: - Write

    /// Write a snapshot to the app group container.
    static func write(_ data: AppGroupData) -> Result<Void, AppGroupStoreError> {
        guard let url = snapshotURL else {
            return .failure(.appGroupUnavailable)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let json = try encoder.encode(data)
            try json.write(to: url, options: .atomic)
            print("[DevPulse] Wrote repositories.json (schema v\(data.schemaVersion), "
                  + "\(data.repositories.count) repos)")
            return .success(())
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    /// Reload widget timelines after a successful write or manual refresh.
    static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: - Utility

    /// Check whether the app group is properly configured.
    static var isAvailable: Bool {
        containerURL != nil
    }
}

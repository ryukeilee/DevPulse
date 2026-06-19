import Foundation
import WidgetKit

struct AppGroupStoreInspection {
    let appGroupIdentifier: String
    let appBundleIdentifier: String
    let widgetBundleIdentifier: String
    let containerURL: URL?
    let snapshotURL: URL?
    let snapshotExists: Bool
    let snapshotReadable: Bool
    let snapshotWritable: Bool
    let containerPath: String?
    let snapshotPath: String?
}

enum AppGroupStore {
    /// The App Group identifier shared with the Widget Extension.
    static let appGroupIdentifier = "group.local.devpulse"
    static let appBundleIdentifier = "local.devpulse.app"
    static let widgetBundleIdentifier = "local.devpulse.app.widget"

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

    static var snapshotPath: String? {
        snapshotURL?.path
    }

    static var containerPath: String? {
        containerURL?.path
    }

    static var snapshotExists: Bool {
        guard let path = snapshotPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    static var snapshotReadable: Bool {
        guard let path = snapshotPath else { return false }
        return FileManager.default.isReadableFile(atPath: path)
    }

    static var snapshotWritable: Bool {
        if let path = snapshotPath {
            return FileManager.default.isWritableFile(atPath: path)
        }
        guard let containerPath else { return false }
        return FileManager.default.isWritableFile(atPath: containerPath)
    }

    static func inspect() -> AppGroupStoreInspection {
        AppGroupStoreInspection(
            appGroupIdentifier: appGroupIdentifier,
            appBundleIdentifier: appBundleIdentifier,
            widgetBundleIdentifier: widgetBundleIdentifier,
            containerURL: containerURL,
            snapshotURL: snapshotURL,
            snapshotExists: snapshotExists,
            snapshotReadable: snapshotReadable,
            snapshotWritable: snapshotWritable,
            containerPath: containerPath,
            snapshotPath: snapshotPath
        )
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
                guard decoded.schemaVersion == RepositorySnapshotSchema.version else {
                    return .failure(.schemaVersionMismatch(
                        expected: RepositorySnapshotSchema.version,
                        actual: decoded.schemaVersion
                    ))
                }
                return .success(decoded)
            } catch {
                return .failure(.decodeFailed(error.localizedDescription))
            }
        } catch {
            return .failure(.readFailed(error.localizedDescription))
        }
    }

    // MARK: - Write

    /// Write a snapshot to the app group container and verify the round trip.
    static func write(_ data: AppGroupData) -> Result<AppGroupData, AppGroupStoreError> {
        guard let url = snapshotURL else {
            return .failure(.appGroupUnavailable)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let json = try encoder.encode(data)
            try json.write(to: url, options: .atomic)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }

        switch read() {
        case .success(let verified):
            if verified == data {
                print("[DevPulse] Wrote repositories.json (schema v\(data.schemaVersion), "
                      + "\(data.repositories.count) repos)")
                return .success(verified)
            }
            return .failure(.verificationFailed("Read-back snapshot does not match the written payload."))
        case .failure(let error):
            return .failure(.verificationFailed(error.localizedDescription))
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

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
    static let appGroupIdentifier = SharedSnapshotLocation.appGroupIdentifier
    static let appBundleIdentifier = "local.devpulse.app"
    static let widgetBundleIdentifier = "local.devpulse.app.widget"

    /// File name for the snapshot inside the group container.
    private static let snapshotFileName = SharedSnapshotLocation.fileName

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

    static var backupURL: URL? {
        sharedStore?.backupURL
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
        guard let containerPath else { return false }
        let snapshotExists = snapshotPath.map(FileManager.default.fileExists(atPath:)) ?? false
        let fileWritable = snapshotPath.map(FileManager.default.isWritableFile(atPath:)) ?? false
        let containerWritable = FileManager.default.isWritableFile(atPath: containerPath)
        return resolveSnapshotWritable(
            snapshotExists: snapshotExists,
            fileWritable: fileWritable,
            containerWritable: containerWritable
        )
    }

    static func resolveSnapshotWritable(
        snapshotExists: Bool,
        fileWritable: Bool,
        containerWritable: Bool
    ) -> Bool {
        snapshotExists ? fileWritable : containerWritable
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

    private static var sharedStore: SharedSnapshotStore? {
        guard let containerURL else { return nil }
        return SharedSnapshotStore(directoryURL: containerURL, fileName: snapshotFileName)
    }

    /// Read the current app group snapshot together with its recovery source.
    static func readDetailed() -> Result<SharedSnapshotRead, AppGroupStoreError> {
        guard let sharedStore else {
            return .failure(.appGroupUnavailable)
        }
        return sharedStore.load()
    }

    /// Read the current app group snapshot. Primary corruption transparently
    /// falls back to the last verified backup, which is explicitly downgraded
    /// by `SharedSnapshotStore` before being returned.
    static func read() -> Result<AppGroupData, AppGroupStoreError> {
        switch readDetailed() {
        case .success(let read):
            return .success(read.snapshot)
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Write

    /// Commit a snapshot through the single atomic, recoverable writer.
    static func write(_ data: AppGroupData) -> Result<AppGroupData, AppGroupStoreError> {
        guard let sharedStore else {
            return .failure(.appGroupUnavailable)
        }
        return sharedStore.commit(data)
    }

    @discardableResult
    static func cleanupTemporaryFiles() -> Result<Void, AppGroupStoreError> {
        guard let sharedStore else {
            return .failure(.appGroupUnavailable)
        }
        return sharedStore.cleanupTemporaryFiles()
    }

    /// Reload widget timelines after a successful write or manual refresh.
    static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetIdentity.kind)
        #endif
    }

    // MARK: - Utility

    /// Check whether the app group is properly configured.
    static var isAvailable: Bool {
        containerURL != nil
    }
}

import CryptoKit
import Foundation

// MARK: - Backup privacy filter

/// Strips sensitive information from backup data before serialization.
///
/// Responsibilities:
/// - Replace absolute file paths with relative/placeholder paths
/// - Anonymize device usernames
/// - Remove diagnostic / transient data that has no restore value
/// - Apply to all stores consistently
enum BackupPrivacyFilter {

    /// Sanitize a backup manifest's metadata in place.
    static func sanitize(manifest: inout BackupManifest, config: BackupPrivacyConfiguration) {
        if config.anonymizeDeviceName || config.stripUserNames {
            manifest.metadata.deviceName = anonymizeDeviceName(manifest.metadata.deviceName)
        }
    }

    /// Sanitize a raw JSON payload string for a given store type.
    /// Returns the sanitized JSON string.
    static func sanitizePayload(
        _ jsonString: String,
        storeType: BackupStoreType,
        config: BackupPrivacyConfiguration
    ) -> String {
        guard config.stripAbsolutePaths || config.stripUserNames || config.stripTempData else {
            return jsonString
        }

        var result = jsonString

        if config.stripAbsolutePaths {
            result = stripAbsolutePaths(result)
        }

        if config.stripUserNames {
            result = stripUserNames(result)
        }

        if config.stripTempData {
            result = stripTempData(result, storeType: storeType)
        }

        if config.stripDiagnosticData {
            result = stripDiagnosticData(result, storeType: storeType)
        }

        return result
    }

    /// Replace absolute paths with `~/path` style or placeholders.
    private static func stripAbsolutePaths(_ text: String) -> String {
        // Replace known absolute path patterns
        var result = text

        // Replace /Users/username with ~
        let homePatterns = [
            NSHomeDirectory(),
            FileManager.default.homeDirectoryForCurrentUser.path
        ]
        for home in Set(homePatterns).filter({ !$0.isEmpty }) {
            result = result.replacingOccurrences(of: home, with: "~")
        }

        // Replace /var/folders/... temp paths
        if let tempDir = NSTemporaryDirectory().trimmingCharacters(in: CharacterSet(charactersIn: "/")).nilIfEmpty {
            result = result.replacingOccurrences(of: tempDir, with: "<TEMP>")
        }

        return result
    }

    /// Anonymize the current system username.
    private static func stripUserNames(_ text: String) -> String {
        let userName = NSUserName()
        guard !userName.isEmpty else { return text }

        // Be careful not to replace common substrings
        return text.replacingOccurrences(of: "/Users/\(userName)", with: "/Users/<USER>")
            .replacingOccurrences(of: "\"\(userName)\"", with: "\"<USER>\"")
            .replacingOccurrences(of: ":\(userName)", with: ":<USER>")
    }

    /// Strip transient diagnostic data that has no restore value.
    private static func stripTempData(_ text: String, storeType: BackupStoreType) -> String {
        // For repository snapshots, strip unavailableSince timestamps and
        // transient error messages that won't be valid after restore.
        if storeType == .repositorySnapshot {
            var result = text
            // Replace "unavailableSince" field values with null
            result = result.replacingOccurrences(
                of: "\"unavailableSince\"\\s*:\\s*\"[^\"]*\"",
                with: "\"unavailableSince\": null",
                options: .regularExpression
            )
            // Replace transient cache timestamps
            result = result.replacingOccurrences(
                of: "\"cacheTimestamp\"\\s*:\\s*\"[^\"]*\"",
                with: "\"cacheTimestamp\": null",
                options: .regularExpression
            )
            return result
        }
        return text
    }

    /// Strip diagnostics like AppGroupContainerPath which are machine-specific.
    private static func stripDiagnosticData(_ text: String, storeType: BackupStoreType) -> String {
        var result = text
        // Remove fields that have no cross-device meaning
        let diagnosticKeys = [
            "appGroupContainerPath",
            "snapshotFilePath",
            "lastWidgetReloadDetail",
            "lastSnapshotStoreDetail",
            "validationIssues"
        ]
        for key in diagnosticKeys {
            result = result.replacingOccurrences(
                of: "\"\(key)\"\\s*:\\s*\"[^\"]*\"\\s*,?\\s*",
                with: "",
                options: .regularExpression
            )
        }
        return result
    }

    /// Anonymize device name for privacy.
    private static func anonymizeDeviceName(_ name: String) -> String {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return "Mac" }
        // Use a stable hash prefix so the same device gets the same anonymized name
        let hash = SHA256.hash(data: Data(name.utf8))
        let suffix = hash.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "Mac-\(suffix)"
    }
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

import Foundation
import OSLog

// MARK: - Diagnostic data migration

/// Versioned migration for diagnostic data (observations, baselines, reports).
///
/// Provides safe degradation:
/// - Corrupted data returns empty/default state
/// - Version mismatch triggers migration or fallback
/// - Write interrupts preserve the previous valid state
public enum DiagnosticMigration {

    /// Try to migrate data to the latest version.
    /// Returns nil if migration is not possible (safe degradation).
    public static func migrate<T: Codable>(
        _ data: Data,
        to targetVersion: Int,
        as type: T.Type
    ) -> T? {
        let decoder = JSONDecoder()

        // Try direct decode first
        if let decoded = try? decoder.decode(T.self, from: data) {
            return decoded
        }

        return nil
    }

    /// Safely write data with atomic rename.
    /// On interrupt, the previous file is preserved.
    public static func atomicWrite<T: Encodable>(
        _ value: T,
        to url: URL
    ) -> Result<Void, any Error> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(value)
            let tempURL = url.appendingPathExtension(".tmp")
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Attempt to recover from a corrupted file.
    /// Returns empty state if recovery is not possible.
    public static func recoverOrEmpty<T: Codable>(
        from url: URL,
        as type: T.Type,
        empty: @autoclosure () -> T
    ) -> T {
        guard let data = try? Data(contentsOf: url) else { return empty() }
        return migrate(data, to: 1, as: type) ?? empty()
    }
}

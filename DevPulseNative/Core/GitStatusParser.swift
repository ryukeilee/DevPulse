import Foundation

enum GitStatusParser {
    /// Parse `git status --short` output into an array of file paths.
    static func parseStatusShort(_ output: String) -> [String] {
        parseStatusEntries(output).map(\.path)
    }

    /// Parse `git status --short` output into structured entries.
    static func parseStatusEntries(_ output: String) -> [StatusEntry] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0) }
            .compactMap { line -> StatusEntry? in
                guard line.count >= 3 else { return nil }
                let statusIndex = line.startIndex
                let statusEnd = line.index(statusIndex, offsetBy: 2)
                let status = line[statusIndex..<statusEnd]
                    .trimmingCharacters(in: .whitespaces)
                let rawPath = String(line[statusEnd...])
                    .trimmingCharacters(in: .whitespaces)

                // Handle rename "old -> new"
                let filePath: String
                if rawPath.contains(" -> ") {
                    filePath = String(rawPath.components(separatedBy: " -> ").last ?? rawPath)
                } else {
                    filePath = rawPath
                }

                let cleanStatus = status.isEmpty ? "??" : status
                let cleanPath = filePath.replacingOccurrences(of: "\"", with: "")
                guard !cleanPath.isEmpty else { return nil }

                return StatusEntry(status: cleanStatus, path: cleanPath)
            }
    }

    /// Structured entry from `git status`.
    struct StatusEntry {
        let status: String
        let path: String
    }
}

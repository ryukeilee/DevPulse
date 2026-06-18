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
                let status = String(line.prefix(2))
                let rawPath = String(line.dropFirst(3))
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

                return StatusEntry(statusCode: cleanStatus, path: cleanPath)
            }
    }

    /// Count Git status categories from parsed entries.
    static func summarize(_ entries: [StatusEntry]) -> StatusSummary {
        var modified = 0
        var added = 0
        var deleted = 0
        var untracked = 0

        for entry in entries {
            switch entry.category {
            case .untracked:
                untracked += 1
            case .added:
                added += 1
            case .deleted:
                deleted += 1
            case .modified:
                modified += 1
            case .other:
                modified += 1
            }
        }

        return StatusSummary(
            modified: modified,
            added: added,
            deleted: deleted,
            untracked: untracked
        )
    }

    /// Structured entry from `git status`.
    struct StatusEntry {
        let statusCode: String
        let path: String

        var category: StatusCategory {
            if statusCode == "??" {
                return .untracked
            }

            let characters = Array(statusCode)
            let indexStatus = characters.indices.contains(0) ? characters[0] : " "
            let worktreeStatus = characters.indices.contains(1) ? characters[1] : " "

            if indexStatus == "A" || worktreeStatus == "A" {
                return .added
            }
            if indexStatus == "D" || worktreeStatus == "D" {
                return .deleted
            }
            if indexStatus == "M" || worktreeStatus == "M" {
                return .modified
            }
            return .other
        }
    }

    struct StatusSummary: Codable, Equatable {
        let modified: Int
        let added: Int
        let deleted: Int
        let untracked: Int

        var total: Int {
            modified + added + deleted + untracked
        }
    }

    enum StatusCategory {
        case modified
        case added
        case deleted
        case untracked
        case other
    }
}

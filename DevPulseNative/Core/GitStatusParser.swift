import Foundation

enum GitStatusParser {
    struct BranchMetadata: Equatable {
        let branch: String
        let aheadCount: Int
        let behindCount: Int
        let isDetached: Bool
    }

    /// Parse `git status --short --branch` output into branch metadata.
    static func parseBranchMetadata(_ output: String) -> BranchMetadata {
        guard let firstLine = output.split(separator: "\n", omittingEmptySubsequences: false).first else {
            return BranchMetadata(branch: "unknown", aheadCount: 0, behindCount: 0, isDetached: false)
        }

        let line = String(firstLine)
        guard line.hasPrefix("## ") else {
            return BranchMetadata(branch: "unknown", aheadCount: 0, behindCount: 0, isDetached: false)
        }

        let descriptor = String(line.dropFirst(3))
        let branchSegment = descriptor
            .components(separatedBy: "...")
            .first?
            .components(separatedBy: " [")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"

        let isDetached = branchSegment.hasPrefix("HEAD (") || branchSegment == "HEAD"
        let branch = isDetached ? "detached" : (branchSegment.isEmpty ? "unknown" : branchSegment)

        return BranchMetadata(
            branch: branch,
            aheadCount: extractCount(label: "ahead", from: descriptor),
            behindCount: extractCount(label: "behind", from: descriptor),
            isDetached: isDetached
        )
    }

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
                guard !line.hasPrefix("## ") else { return nil }
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
        var staged = 0
        var unstaged = 0
        var conflicted = 0

        for entry in entries {
            if entry.isStaged {
                staged += 1
            }
            if entry.isUnstaged {
                unstaged += 1
            }
            if entry.isConflicted {
                conflicted += 1
            }

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
            untracked: untracked,
            staged: staged,
            unstaged: unstaged,
            conflicted: conflicted
        )
    }

    /// Structured entry from `git status`.
    struct StatusEntry {
        let statusCode: String
        let path: String

        var isStaged: Bool {
            let characters = Array(statusCode)
            guard characters.indices.contains(0) else { return false }
            let indexStatus = characters[0]
            return indexStatus != " " && indexStatus != "?"
        }

        var isConflicted: Bool {
            statusCode.contains("U") || statusCode == "AA" || statusCode == "DD"
        }

        var isUnstaged: Bool {
            if statusCode == "??" {
                return false
            }

            let characters = Array(statusCode)
            guard characters.indices.contains(1) else { return false }
            let worktreeStatus = characters[1]
            return worktreeStatus != " "
        }

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
        let staged: Int
        let unstaged: Int
        let conflicted: Int

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

    private static func extractCount(label: String, from descriptor: String) -> Int {
        guard let range = descriptor.range(of: "\(label) ") else {
            return 0
        }

        let suffix = descriptor[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }
}

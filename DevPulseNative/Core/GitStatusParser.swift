import Foundation

enum GitStatusParser {
    struct BranchMetadata: Equatable {
        let branch: String
        let aheadCount: Int
        let behindCount: Int
        let hasUpstream: Bool
        let isDetached: Bool
        /// The full HEAD object ID reported by porcelain v2, when one exists.
        let headOID: String?
        /// True only when Git explicitly reports an unborn branch.
        let hasNoCommits: Bool
    }

    struct LastCommitMetadata: Equatable {
        let commitID: String?
        let committedAt: String?
        let summary: String?
    }

    /// Parse `git status --short --branch` output into branch metadata.
    /// Porcelain v2 branch headers are preferred, while the legacy short
    /// representation remains accepted for existing callers and fixtures.
    static func parseBranchMetadata(_ output: String) -> BranchMetadata {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.contains(where: { $0.hasPrefix("# branch.") }) {
            return parsePorcelainV2BranchMetadata(lines)
        }

        guard let firstLine = lines.first else {
            return BranchMetadata(
                branch: "unknown",
                aheadCount: 0,
                behindCount: 0,
                hasUpstream: false,
                isDetached: false,
                headOID: nil,
                hasNoCommits: false
            )
        }

        let line = String(firstLine)
        guard line.hasPrefix("## ") else {
            return BranchMetadata(
                branch: "unknown",
                aheadCount: 0,
                behindCount: 0,
                hasUpstream: false,
                isDetached: false,
                headOID: nil,
                hasNoCommits: false
            )
        }

        let descriptor = String(line.dropFirst(3))
        let rawBranchSegment = descriptor
            .components(separatedBy: "...")
            .first?
            .components(separatedBy: " [")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let branchSegment: String
        if rawBranchSegment.hasPrefix("No commits yet on ") {
            branchSegment = String(rawBranchSegment.dropFirst("No commits yet on ".count))
        } else if rawBranchSegment.hasPrefix("Initial commit on ") {
            branchSegment = String(rawBranchSegment.dropFirst("Initial commit on ".count))
        } else {
            branchSegment = rawBranchSegment
        }

        let isDetached = branchSegment.hasPrefix("HEAD (") || branchSegment == "HEAD"
        let branch = isDetached ? "detached" : (branchSegment.isEmpty ? "unknown" : branchSegment)
        let hasNoCommits = rawBranchSegment.hasPrefix("No commits yet on ")
            || rawBranchSegment.hasPrefix("Initial commit on ")

        return BranchMetadata(
            branch: branch,
            aheadCount: extractCount(label: "ahead", from: descriptor),
            behindCount: extractCount(label: "behind", from: descriptor),
            hasUpstream: descriptor.contains("..."),
            isDetached: isDetached,
            headOID: nil,
            hasNoCommits: hasNoCommits
        )
    }

    /// Parse `git log -1 --pretty=%H%x00%cI%x00%s` into optional commit metadata.
    /// The legacy two-field date/subject representation remains accepted.
    static func parseLastCommitMetadata(_ output: String?) -> LastCommitMetadata? {
        guard let output, !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "\0")
        let commitIDPart: String
        let datePart: String
        let summaryPart: String
        if parts.count >= 3 {
            commitIDPart = parts[0]
            datePart = parts[1]
            summaryPart = parts.dropFirst(2).joined(separator: "\0")
        } else {
            commitIDPart = ""
            datePart = parts.first ?? output
            summaryPart = parts.count == 2 ? parts[1] : ""
        }

        let commitID = normalized(commitIDPart)
        let committedAt = normalized(datePart)
        let summary = normalized(summaryPart)
        guard commitID != nil || committedAt != nil || summary != nil else { return nil }
        return LastCommitMetadata(commitID: commitID, committedAt: committedAt, summary: summary)
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
                if let entry = parsePorcelainV2StatusEntry(line) {
                    return entry
                }
                if line.hasPrefix("# ") || line.hasPrefix("! ") {
                    return nil
                }
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
                let cleanPath = decodeGitPath(filePath)
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
            return indexStatus != " " && indexStatus != "." && indexStatus != "?"
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
            return worktreeStatus != " " && worktreeStatus != "."
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

    private static func parsePorcelainV2BranchMetadata(_ lines: [String]) -> BranchMetadata {
        var oid: String?
        var branch = "unknown"
        var hasUpstream = false
        var aheadCount = 0
        var behindCount = 0
        var isDetached = false
        var hasNoCommits = false

        for line in lines {
            if line.hasPrefix("# branch.oid ") {
                let value = String(line.dropFirst("# branch.oid ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value == "(initial)" {
                    hasNoCommits = true
                } else {
                    oid = normalized(value)
                }
            } else if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                isDetached = value == "(detached)"
                branch = isDetached ? "detached" : (value.isEmpty ? "unknown" : value)
            } else if line.hasPrefix("# branch.upstream ") {
                hasUpstream = normalized(String(line.dropFirst("# branch.upstream ".count))) != nil
            } else if line.hasPrefix("# branch.ab ") {
                let counts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for count in counts {
                    if count.first == "+" {
                        aheadCount = Int(count.dropFirst()) ?? 0
                    } else if count.first == "-" {
                        behindCount = Int(count.dropFirst()) ?? 0
                    }
                }
            }
        }

        return BranchMetadata(
            branch: branch,
            aheadCount: aheadCount,
            behindCount: behindCount,
            hasUpstream: hasUpstream,
            isDetached: isDetached,
            headOID: oid,
            hasNoCommits: hasNoCommits
        )
    }

    private static func parsePorcelainV2StatusEntry(_ line: String) -> StatusEntry? {
        let rawStatus: String
        let rawPath: String

        if line.hasPrefix("1 ") {
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9 else { return nil }
            rawStatus = String(fields[1])
            rawPath = String(fields[8])
        } else if line.hasPrefix("2 ") {
            let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
            guard fields.count == 10 else { return nil }
            rawStatus = String(fields[1])
            rawPath = String(fields[9].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        } else if line.hasPrefix("u ") {
            let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
            guard fields.count == 11 else { return nil }
            rawStatus = String(fields[1])
            rawPath = String(fields[10])
        } else if line.hasPrefix("? ") {
            rawStatus = "??"
            rawPath = String(line.dropFirst(2))
        } else {
            return nil
        }

        let path = decodeGitPath(rawPath.trimmingCharacters(in: .whitespaces))
        guard rawStatus.count >= 2, !path.isEmpty else { return nil }
        let normalizedStatus = String(rawStatus.prefix(2)).replacingOccurrences(of: ".", with: " ")
        return StatusEntry(statusCode: normalizedStatus, path: path)
    }

    /// Decode Git's default C-style path quoting without reading file contents.
    private static func decodeGitPath(_ value: String) -> String {
        let quote: UInt8 = 34
        let backslash: UInt8 = 92
        guard value.utf8.first == quote,
              value.utf8.last == quote,
              value.utf8.count >= 2 else {
            return value
        }

        let source = Array(value.utf8.dropFirst().dropLast())
        var decoded: [UInt8] = []
        decoded.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            let byte = source[index]
            guard byte == backslash, index + 1 < source.count else {
                decoded.append(byte)
                index += 1
                continue
            }

            index += 1
            let escaped = source[index]
            switch escaped {
            case 97: decoded.append(7)
            case 98: decoded.append(8)
            case 116: decoded.append(9)
            case 110: decoded.append(10)
            case 118: decoded.append(11)
            case 102: decoded.append(12)
            case 114: decoded.append(13)
            case backslash, quote:
                decoded.append(escaped)
            case 48...55:
                var octalValue = Int(escaped - 48)
                var octalDigits = 1
                while octalDigits < 3,
                      index + 1 < source.count,
                      (48...55).contains(source[index + 1]) {
                    index += 1
                    octalValue = octalValue * 8 + Int(source[index] - 48)
                    octalDigits += 1
                }
                decoded.append(UInt8(truncatingIfNeeded: octalValue))
            default:
                decoded.append(escaped)
            }
            index += 1
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

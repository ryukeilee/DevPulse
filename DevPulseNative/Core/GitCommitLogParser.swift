import Foundation
import OSLog

// MARK: - Git commit log parser

/// Parses `git log` output to extract commit history entries for change analysis.
///
/// Design:
/// - No I/O: pure parsing of pre-fetched output strings.
/// - Format: expects `git log --pretty=format:"%H||%s||%an||%ae||%ai" --name-only`
/// - Handles empty logs, malformed lines, and truncated output gracefully.
///
/// Thread safety: Stateless and reentrant.
enum GitCommitLogParser {
    private static let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "CommitLogParser"
    )

    // MARK: - Configuration

    enum Constants {
        /// Default number of recent commits to fetch for analysis.
        static let defaultCommitCount = 30
        /// Maximum number of commits to analyze.
        static let maxCommitCount = 100
    }

    // MARK: - Public API

    /// Parse git log output into structured commit entries.
    ///
    /// Expected input format (from `git log --pretty=format:"%H||%s||%an||%ae||%ai" --name-only -n <count>`):
    /// ```
    /// commit_hash||commit_summary||author_name||author_email||2024-01-15 10:30:00 +0800
    /// path/to/file1.swift
    /// path/to/file2.swift
    ///
    /// commit_hash2||summary2||author2||email2||2024-01-14 09:00:00 +0800
    /// path/to/file3.swift
    /// ```
    static func parse(logOutput: String) -> [CommitLogEntry] {
        guard !logOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var entries: [CommitLogEntry] = []
        let lines = logOutput.components(separatedBy: .newlines)
        var currentCommit: (line: String, files: [String])?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.contains("||") {
                // Save previous commit if exists
                if let (commitLine, files) = currentCommit {
                    if let entry = parseCommitLine(commitLine, files: files) {
                        entries.append(entry)
                    }
                }
                currentCommit = (trimmed, [])
            } else if !trimmed.isEmpty {
                // Accumulate file paths
                currentCommit?.files.append(trimmed)
            }
        }

        // Last commit
        if let (commitLine, files) = currentCommit {
            if let entry = parseCommitLine(commitLine, files: files) {
                entries.append(entry)
            }
        }

        return entries
    }

    /// Parse a single summary line and return aggregated changes.
    /// This is used when only `git log --oneline` output is available.
    static func parseSummaryLine(_ line: String) -> (commitID: String, summary: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let spaceIndex = trimmed.firstIndex(of: " ") else { return nil }
        let commitID = String(trimmed[..<spaceIndex])
        let summary = String(trimmed[trimmed.index(after: spaceIndex)...])
        guard !commitID.isEmpty, !summary.isEmpty else { return nil }
        return (commitID, summary)
    }

    /// Build the git log command arguments for fetching commit history.
    static func logCommandArguments(count: Int = Constants.defaultCommitCount) -> [String] {
        let limitedCount = min(count, Constants.maxCommitCount)
        return [
            "log",
            "--pretty=format:%H||%s||%an||%ae||%ai",
            "--name-only",
            "-n", String(limitedCount),
            "--skip", "1"  // skip the most recent commit (HEAD is already in snapshot)
        ]
    }

    // MARK: - Private

    private static func parseCommitLine(
        _ line: String,
        files: [String]
    ) -> CommitLogEntry? {
        let parts = line.components(separatedBy: "||")
        guard parts.count >= 5 else {
            logger.debug("Skipping malformed commit line: \(line.prefix(40))")
            return nil
        }

        let commitID = parts[0].trimmingCharacters(in: .whitespaces)
        let summary = parts[1].trimmingCharacters(in: .whitespaces)
        let authorName = parts[2].trimmingCharacters(in: .whitespaces)
        let authorEmail = parts[3].trimmingCharacters(in: .whitespaces)
        let dateStr = parts[4].trimmingCharacters(in: .whitespaces)

        guard !commitID.isEmpty else { return nil }

        // Parse git date format "2024-01-15 10:30:00 +0800" to ISO8601
        let isoDate = convertGitDateToISO(dateStr)

        // Get unique files (filter out empty strings)
        let uniqueFiles = Array(Set(files.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }))

        return CommitLogEntry(
            commitID: commitID,
            summary: summary,
            authorName: authorName,
            authorEmail: authorEmail,
            committedAt: isoDate,
            filesChanged: uniqueFiles,
            insertions: 0,  // Not available from --name-only
            deletions: 0
        )
    }

    private static func convertGitDateToISO(_ gitDate: String) -> String {
        // Git format: "2024-01-15 10:30:00 +0800"
        // ISO8601: "2024-01-15T10:30:00+08:00"
        let trimmed = gitDate.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 25 else { return trimmed }

        // Replace first space with T
        var iso = trimmed
        if let spaceIndex = iso.firstIndex(of: " ") {
            iso.replaceSubrange(spaceIndex...spaceIndex, with: "T")
        }

        // Insert : in timezone offset: +0800 -> +08:00
        if iso.hasSuffix("+") || iso.contains("+") {
            // Find the last + or - before timezone
            if let plusIndex = iso.lastIndex(of: "+"), plusIndex > iso.index(iso.endIndex, offsetBy: -6) {
                iso.insert(":", at: iso.index(plusIndex, offsetBy: 3))
            }
        } else if let minusIndex = iso.lastIndex(of: "-"), minusIndex > iso.index(iso.endIndex, offsetBy: -6) {
            iso.insert(":", at: iso.index(minusIndex, offsetBy: 3))
        }

        return iso
    }
}

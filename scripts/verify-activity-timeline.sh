#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-activity-timeline.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

HARNESS="$TMP_DIR/verify-activity-timeline.swift"
BIN="$TMP_DIR/verify-activity-timeline"
MODULE_CACHE="$TMP_DIR/module-cache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$MODULE_CACHE"

cat > "$HARNESS" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

func repo(
    _ name: String,
    status: RepositoryStatus,
    lastChangedAt: String?,
    lastScannedAt: String,
    preview: [String],
    risk: RiskLevel = .low
) -> RepositorySnapshot {
    RepositorySnapshot(
        id: name,
        name: name,
        path: "/tmp/\(name)",
        branch: "main",
        status: status,
        modifiedFileCount: 1,
        addedFileCount: 2,
        deletedFileCount: 3,
        untrackedFileCount: 4,
        stagedFileCount: 0,
        unstagedFileCount: 6,
        conflictedFileCount: 0,
        aheadCount: 0,
        changedFileCount: 10,
        changedFilesPreview: preview,
        risk: risk,
        lastScannedAt: lastScannedAt,
        lastChangedAt: lastChangedAt,
        errorMessage: status == .error ? "boom" : nil,
        isPinned: false
    )
}

let activeFeed = ActivityTimelineBuilder.build(
    from: [
        repo(
            "recent-changed",
            status: .changed,
            lastChangedAt: "2026-06-18T10:00:00Z",
            lastScannedAt: "2026-06-18T10:01:00Z",
            preview: ["src/core/timeline.swift", "README.md", "src/core/timeline.swift"]
        ),
        repo(
            "older-changed",
            status: .changed,
            lastChangedAt: "2026-06-17T10:00:00Z",
            lastScannedAt: "2026-06-18T11:00:00Z",
            preview: ["src/core/models.swift"]
        ),
        repo(
            "clean-repo",
            status: .clean,
            lastChangedAt: nil,
            lastScannedAt: "2026-06-18T12:00:00Z",
            preview: []
        ),
        repo(
            "error-repo",
            status: .error,
            lastChangedAt: nil,
            lastScannedAt: "2026-06-18T13:00:00Z",
            preview: []
        )
    ],
    lastScanAt: Date(timeIntervalSince1970: 1_750_240_000)
)

@main
struct Main {
    static func main() throws {
        expect(activeFeed.state == .active, "active feed should be active")
        expect(activeFeed.items.map(\.repoName) == ["recent-changed", "older-changed", "error-repo", "clean-repo"], "timeline sort order should prefer recent changes and keep Git read failures ahead of clean repos")
        expect(activeFeed.topItem?.changedFilesPreview == ["timeline.swift", "README.md"], "timeline preview should be normalized to basenames and deduplicated")

        let neverScanned = ActivityTimelineBuilder.build(from: [], lastScanAt: nil)
        expect(neverScanned.state == .neverScanned, "empty feed without last scan should be never scanned")
        expect(neverScanned.items.isEmpty, "never scanned feed should have no items")

        let noRepos = ActivityTimelineBuilder.build(from: [], lastScanAt: Date(timeIntervalSince1970: 1_750_240_000))
        expect(noRepos.state == .noRepositories, "empty feed with a scan date should report no repositories")

        let allCleanFeed = ActivityTimelineBuilder.build(
            from: [
                repo(
                    "clean-a",
                    status: .clean,
                    lastChangedAt: nil,
                    lastScannedAt: "2026-06-18T14:00:00Z",
                    preview: []
                )
            ],
            lastScanAt: Date(timeIntervalSince1970: 1_750_240_000)
        )
        expect(allCleanFeed.state == .allClean, "single clean repository should classify as all clean")

        let json = """
{
  "schemaVersion": 1,
  "generatedAt": "2026-06-18T10:00:00Z",
  "writtenAt": "2026-06-18T10:00:05Z",
  "scanSummary": {
    "totalRepositories": 2,
    "changedRepositories": 1,
    "totalChangedFiles": 10,
    "errorRepositories": 0
  },
  "repositories": [
    {
      "id": "decoded-changed",
      "name": "decoded-changed",
      "path": "/tmp/decoded-changed",
      "branch": "main",
      "status": "changed",
      "modifiedFileCount": 1,
      "addedFileCount": 0,
      "deletedFileCount": 0,
      "untrackedFileCount": 0,
      "changedFileCount": 1,
      "changedFilesPreview": ["src/app/entry.swift"],
      "risk": "medium",
      "lastScannedAt": "2026-06-18T10:00:00Z",
      "lastChangedAt": "2026-06-18T09:59:59Z",
      "errorMessage": null,
      "isPinned": false
    }
  ]
}
""".data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppGroupData.self, from: json)
        let decodedFeed = ActivityTimelineBuilder.build(from: decoded)
        expect(decodedFeed.state == .active, "decoded snapshot should build an active timeline")
        expect(decodedFeed.topItem?.changedFilesPreview == ["entry.swift"], "decoded snapshot should preserve widget-ready file basenames")

        print("Activity timeline verification passed")
    }
}
SWIFT

xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx14.0 \
    -module-cache-path "$MODULE_CACHE" \
    -o "$BIN" \
    "$ROOT_DIR/DevPulseNative/Utilities/DateFormatting.swift" \
    "$ROOT_DIR/DevPulseNative/Core/CommitReadinessEngine.swift" \
    "$ROOT_DIR/DevPulseNative/Core/Models.swift" \
    "$HARNESS"

"$BIN"

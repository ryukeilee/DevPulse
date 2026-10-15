#!/usr/bin/env bash
# A/B benchmark of the production recordSnapshotStates call, including archive I/O.
# Usage: ./scripts/benchmark-repository-history-recording.sh [--baseline-git <ref> | --baseline-root <path>]
# Tunables: BENCH_REPOS, BENCH_ARCHIVE_ENTRIES, BENCH_ITERATIONS (15), BENCH_WARMUP (3).
# Repos/archive defaults: 50/1000, 400/5000, 1200/10000. Overrides apply to all cases.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE_ROOT="${BASELINE_ROOT:-}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-history-bench.XXXXXX")"
BASELINE_WORKTREE=""
cleanup() {
    if [[ -n "$BASELINE_WORKTREE" ]]; then
        git -C "$ROOT_DIR" worktree remove "$BASELINE_WORKTREE" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-git)
            [[ -n "${2:-}" && -z "$BASELINE_ROOT" ]] || { echo "error: specify one baseline" >&2; exit 2; }
            BASELINE_WORKTREE="$TMP_DIR/baseline-checkout"
            git -C "$ROOT_DIR" worktree add --detach "$BASELINE_WORKTREE" "$2" >/dev/null
            BASELINE_ROOT="$BASELINE_WORKTREE"
            shift 2 ;;
        --baseline-root)
            [[ -n "${2:-}" && -z "$BASELINE_ROOT" ]] || { echo "error: specify one baseline" >&2; exit 2; }
            BASELINE_ROOT="$2"
            shift 2 ;;
        -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

HARNESS="$TMP_DIR/history-bench.swift"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="$TMP_DIR/module-cache"
mkdir -p "$MODULE_CACHE"
cat > "$HARNESS" <<'SWIFT'
import CryptoKit
import Foundation

func envInt(_ key: String, _ fallback: Int, minimum: Int = 1) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[key] else { return fallback }
    guard let value = Int(raw), value >= minimum else { fatalError("invalid \(key): \(raw)") }
    return value
}

func snapshot(_ index: Int, branch: String = "main") -> RepositorySnapshot {
    RepositorySnapshot(
        id: "repo-\(index)", name: "repo-\(index)", path: "/tmp/history-bench/repo-\(index)",
        branch: branch, status: .clean, modifiedFileCount: 0, addedFileCount: 0,
        deletedFileCount: 0, untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: 0,
        conflictedFileCount: 0, aheadCount: 0, behindCount: 0, hasUpstream: true,
        changedFileCount: 0, changedFilesPreview: [], risk: .low,
        lastScannedAt: "2026-01-01T00:00:00Z", dataSource: .current,
        lastChangedAt: nil, errorMessage: nil, isPinned: false
    )
}

@main
struct Main {
    static func main() throws {
        let iterations = envInt("BENCH_ITERATIONS", 15)
        let warmup = envInt("BENCH_WARMUP", 3, minimum: 0)
        let label = ProcessInfo.processInfo.environment["BENCH_LABEL"] ?? "current"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-round-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (defaultRepos, defaultArchive) in [(50, 1000), (400, 5000), (1200, 10000)] {
            let repos = envInt("BENCH_REPOS", defaultRepos)
            let archiveCount = envInt("BENCH_ARCHIVE_ENTRIES", defaultArchive)
            let repositories = (0..<repos).map { snapshot($0, branch: $0 % 3 == 2 ? "feature" : "main") }
            // Fixed, descending archive; every repository's latest point is in its first cycle.
            // Mix scanRecord dedup, same-state non-scanRecord, and changed-state recording.
            let entries = (0..<archiveCount).map { index in
                let repo = index % repos
                return RepositoryHistoryEntry(
                    repositoryID: "repo-\(repo)",
                    recordedAt: String(format: "2026-01-%02dT%02d:%02d:%02dZ",
                        28 - index / 86400, (86399 - index % 86400) / 3600,
                        (3599 - index % 3600) / 60, 59 - index % 60),
                    kind: repo % 3 == 1 ? .stateChange : .scanRecord,
                    state: HistoryStatePoint(snapshot: snapshot(repo))
                )
            }
            precondition(entries.allSatisfy { DateFormatting.date(from: $0.recordedAt) != nil },
                "fixture timestamps must be valid ISO8601")
            let fixture = directory.appendingPathComponent("fixture.json")
            try encoder.encode(RepositoryHistoryArchive(entries: entries)).write(to: fixture)
            // Keep retention/compaction out of these recording cost measurements.
            let config = RepositoryHistoryStore.Configuration(
                retentionDays: 365000, maxEntriesPerRepo: archiveCount + repos,
                maxTotalEntries: (archiveCount + repos) * 2,
                compactionInterval: 20, softThresholdFraction: 0.9
            )
            var elapsed: UInt64 = 0
            var signature: String?
            var metrics = ""
            for iteration in 0..<(warmup + iterations) {
                let target = directory.appendingPathComponent("store-\(iteration).json")
                try FileManager.default.copyItem(at: fixture, to: target)
                let store = RepositoryHistoryStore(fileURL: target, config: config)
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let result = store.recordSnapshotStates(repositories: repositories, recordedAt: "2026-02-01T00:00:00Z")
                let duration = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
                let outcome = try result.get()
                if iteration >= warmup { elapsed += duration }
                let loads = store.loadMetrics().archiveDecodeCount
                guard loads == 1 else { fatalError("expected one archive decode, got \(loads)") }
                // Hash the complete loaded array, including order, id, kind and every state field.
                let loaded = try store.load().get()
                let digest = SHA256.hash(data: try encoder.encode(loaded))
                    .map { String(format: "%02x", $0) }.joined()
                let d = store.diagnostics
                metrics = "totalEntriesWritten=\(d.totalEntriesWritten) totalDedupSkipped=\(d.totalDedupSkipped) "
                    + "totalRepositoryCount=\(d.totalRepositoryCount) currentEntryCount=\(d.currentEntryCount) "
                    + "addedCount=\(outcome.addedCount) totalEntryCount=\(outcome.totalEntryCount) archiveDecodeCount=\(loads)"
                let currentSignature = "fingerprint=\(digest) \(metrics)"
                if let signature, signature != currentSignature { fatalError("non-deterministic output") }
                signature = currentSignature
                try FileManager.default.removeItem(at: target)
            }
            print(String(format: "BENCH label=%@ repos=%d archive=%d iterations=%d warmup=%d mean_ms=%.3f %@",
                label, repos, archiveCount, iterations, warmup, Double(elapsed) / Double(iterations) / 1_000_000,
                signature!))
        }
    }
}
SWIFT

compile_and_run() {
    local label="$1" root="$2" binary="$TMP_DIR/bench-$1"
    if ! xcrun swiftc -O -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx14.0" \
        -module-cache-path "$MODULE_CACHE" -o "$binary" \
        "$root/DevPulseNative/Utilities/DateFormatting.swift" \
        "$root/DevPulseNative/Core/CommitReadinessEngine.swift" \
        "$root/DevPulseNative/Core/Models.swift" \
        "$root/DevPulseNative/Core/PendingItem.swift" \
        "$root/DevPulseNative/Core/ActivityEvent.swift" \
        "$root/DevPulseNative/Core/RepositoryHistoryEntry.swift" \
        "$root/DevPulseNative/Core/RepositoryHistoryStore.swift" \
        "$HARNESS" 2> "$TMP_DIR/compile-$label.log"; then
        echo "error: compilation failed for $label" >&2
        tail -50 "$TMP_DIR/compile-$label.log" >&2
        return 1
    fi
    cat "$TMP_DIR/compile-$label.log" >&2
    # Equal timestamps retain Dictionary iteration order in production. Fix hashing
    # in BOTH benchmark processes so that order can be compared reproducibly.
    SWIFT_DETERMINISTIC_HASHING=1 BENCH_LABEL="$label" "$binary" | tee "$TMP_DIR/$label.out"
}

echo "Repository history recording benchmark (recordSnapshotStates, copy excluded)"
if [[ -n "$BASELINE_ROOT" ]]; then
    compile_and_run baseline "$BASELINE_ROOT"
fi
compile_and_run current "$ROOT_DIR"
if [[ -n "$BASELINE_ROOT" ]]; then
    python3 - "$TMP_DIR/baseline.out" "$TMP_DIR/current.out" <<'PYCOMPARE'
import sys
from pathlib import Path

def rows(path):
    return [dict(token.split('=', 1) for token in line.split()[1:])
            for line in Path(path).read_text().splitlines() if line.startswith('BENCH ')]

baseline, current = map(rows, sys.argv[1:])
if len(baseline) != 3 or len(current) != 3:
    raise SystemExit('error: expected three benchmark cases')
for before, after in zip(baseline, current):
    for key in before.keys() - {'label', 'mean_ms'}:
        if before[key] != after[key]:
            raise SystemExit(f'output equivalence: MISMATCH repos={before["repos"]} field={key}')
    b, c = float(before['mean_ms']), float(after['mean_ms'])
    print(f'COMPARE repos={before["repos"]} archive={before["archive"]} '
          f'baseline_ms={b:.3f} current_ms={c:.3f} speedup={b/c:.2f}x equivalence=identical')
PYCOMPARE
fi

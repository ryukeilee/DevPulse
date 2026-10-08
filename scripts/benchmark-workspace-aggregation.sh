#!/usr/bin/env bash
# A/B benchmark for WorkspaceAggregationEngine.aggregateAll in multi-repository
# workspaces.
#
# Runs a standalone harness (same pattern as verify-activity-timeline.sh) against
# the current engine source, and optionally against a baseline engine source so
# a before/after comparison can be measured with a single command.
#
# Usage:
#   ./scripts/benchmark-workspace-aggregation.sh
#   BASELINE_ENGINE=<path-to-baseline-WorkspaceAggregationEngine.swift> \
#     ./scripts/benchmark-workspace-aggregation.sh
#   # or compare against a git ref of the current tree:
#   ./scripts/benchmark-workspace-aggregation.sh --baseline-git <ref>
#
# Tunables (env): BENCH_WORKSPACES, BENCH_REPOS_PER_WORKSPACE, BENCH_ITERATIONS,
#                 BENCH_WARMUP
#
# The harness also emits a content fingerprint of every aggregation (excluding
# the wall-clock computationDurationMs field) so an optimization can be proved
# behavior-preserving: equal fingerprints mean identical aggregation output.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_REL="DevPulseNative/Core/WorkspaceAggregationEngine.swift"
ENGINE_FILE="$ROOT_DIR/$ENGINE_REL"

BASELINE_ENGINE="${BASELINE_ENGINE:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-git)
            [[ -n "${2:-}" ]] || { echo "error: --baseline-git requires a ref" >&2; exit 2; }
            BASELINE_TMP="$(mktemp -t devpulse-baseline-engine.XXXXXX).swift"
            git -C "$ROOT_DIR" show "$2:$ENGINE_REL" > "$BASELINE_TMP"
            BASELINE_ENGINE="$BASELINE_TMP"
            shift 2
            ;;
        --baseline-engine)
            [[ -n "${2:-}" ]] || { echo "error: --baseline-engine requires a file path" >&2; exit 2; }
            BASELINE_ENGINE="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-ws-bench.XXXXXX")"
trap 'rm -rf "$TMP_DIR"; [[ -n "${BASELINE_TMP:-}" ]] && rm -f "$BASELINE_TMP"' EXIT

HARNESS="$TMP_DIR/bench-workspace-aggregation.swift"
MODULE_CACHE="$TMP_DIR/module-cache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$MODULE_CACHE"

cat > "$HARNESS" <<'SWIFT'
import CryptoKit
import Foundation

// MARK: - Tunables

func envInt(_ key: String, _ fallback: Int) -> Int {
    if let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw), value > 0 {
        return value
    }
    return fallback
}

let workspaceCount = envInt("BENCH_WORKSPACES", 8)
let reposPerWorkspace = envInt("BENCH_REPOS_PER_WORKSPACE", 25)
let iterations = envInt("BENCH_ITERATIONS", 20)
let warmupIterations = envInt("BENCH_WARMUP", 3)

// MARK: - Fixture

/// Fixed reference instant so staleness classification is deterministic.
let now = Date(timeIntervalSince1970: 1_770_000_000)
let day: TimeInterval = 24 * 60 * 60

func iso(_ date: Date, fractionalSeconds: Bool) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = fractionalSeconds
        ? [.withInternetDateTime, .withFractionalSeconds]
        : [.withInternetDateTime]
    return formatter.string(from: date)
}

func makeSnapshot(workspaceIndex: Int, repoIndex: Int, globalIndex: Int) -> RepositorySnapshot {
    let name = "repo-\(workspaceIndex)-\(repoIndex)"
    let staleActivity = iso(now.addingTimeInterval(-30 * day), fractionalSeconds: true)
    let staleActivityPlain = iso(now.addingTimeInterval(-21 * day), fractionalSeconds: false)
    let staleScan = iso(now.addingTimeInterval(-15 * day), fractionalSeconds: true)
    let freshActivity = iso(now.addingTimeInterval(-1 * day), fractionalSeconds: true)
    let freshScan = iso(now.addingTimeInterval(-3600), fractionalSeconds: false)

    // Seven rotating shapes cover every staleness branch (activity, legacy
    // lastChangedAt, lastScannedAt fallback, non-current data, conflicts,
    // unstaged sync counts) without inventing new behavior.
    switch globalIndex % 7 {
    case 0:
        return RepositorySnapshot(
            id: name, name: name, path: "/tmp/\(name)", branch: "main", status: .clean,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: 0,
            conflictedFileCount: 0, aheadCount: 0, changedFileCount: 0,
            changedFilesPreview: [], risk: .low,
            lastScannedAt: freshScan, dataSource: .current,
            lastChangedAt: nil, lastActivityAt: staleActivity, errorMessage: nil, isPinned: false
        )
    case 1:
        return RepositorySnapshot(
            id: name, name: name, path: "/tmp/\(name)", branch: "main", status: .changed,
            modifiedFileCount: 3, addedFileCount: 1, deletedFileCount: 0,
            untrackedFileCount: 2, stagedFileCount: 1, unstagedFileCount: 5,
            conflictedFileCount: 0, aheadCount: 1, changedFileCount: 6,
            changedFilesPreview: ["src/a.swift"], risk: .medium,
            lastScannedAt: freshScan, dataSource: .current,
            lastChangedAt: freshActivity, lastActivityAt: nil, errorMessage: nil, isPinned: false
        )
    case 2:
        return RepositorySnapshot(
            id: name, name: name, path: "/tmp/\(name)", branch: "main", status: .clean,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: 0,
            conflictedFileCount: 0, aheadCount: nil, changedFileCount: 0,
            changedFilesPreview: [], risk: .low,
            lastScannedAt: staleScan, dataSource: .current,
            lastChangedAt: nil, lastActivityAt: nil, errorMessage: nil, isPinned: false
        )
    case 3:
        return RepositorySnapshot(
            id: name, name: name, path: "/tmp/\(name)", branch: "main", status: .clean,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: 0,
            conflictedFileCount: 0, aheadCount: 0, behindCount: 0, hasUpstream: false,
            changedFileCount: 0, changedFilesPreview: [], risk: .low,
            lastScannedAt: freshScan, dataSource: .current,
            lastChangedAt: staleActivityPlain, lastActivityAt: nil, errorMessage: nil, isPinned: false
        )
    case 4:
        return RepositorySnapshot(
            id: name, name: name, path: "/tmp/\(name)", branch: "main", status: .error,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: 0,
            conflictedFileCount: 0, aheadCount: nil, changedFileCount: 0,
            changedFilesPreview: [], risk: .high,
            lastScannedAt: freshScan, dataSource: .unknown,
            lastChangedAt: nil, lastActivityAt: staleActivity, errorMessage: "boom", isPinned: false
        )
    case 5:
        return RepositorySnapshot(
            id: name, name: name, path: "/tmp/\(name)", branch: "feature", status: .changed,
            modifiedFileCount: 2, addedFileCount: 0, deletedFileCount: 1,
            untrackedFileCount: 0, stagedFileCount: 2, unstagedFileCount: 3,
            conflictedFileCount: 2, aheadCount: 4, changedFileCount: 4,
            changedFilesPreview: ["src/b.swift"], risk: .high,
            lastScannedAt: freshScan, dataSource: .current,
            lastChangedAt: nil, lastActivityAt: freshActivity, errorMessage: nil, isPinned: true
        )
    default:
        return RepositorySnapshot(
            id: name, name: name, path: "/tmp/\(name)", branch: "main", status: .changed,
            modifiedFileCount: 1, addedFileCount: 1, deletedFileCount: 0,
            untrackedFileCount: 1, stagedFileCount: 0, unstagedFileCount: 2,
            conflictedFileCount: 0, aheadCount: 2, behindCount: 1, hasUpstream: true,
            changedFileCount: 3, changedFilesPreview: ["README.md"], risk: .medium,
            lastScannedAt: freshScan, dataSource: .current,
            lastChangedAt: nil, lastActivityAt: staleActivityPlain, errorMessage: nil, isPinned: false
        )
    }
}

func makeFixture() -> (workspaces: [Workspace], repositories: [RepositorySnapshot]) {
    var workspaces: [Workspace] = []
    var repositories: [RepositorySnapshot] = []
    workspaces.reserveCapacity(workspaceCount)
    repositories.reserveCapacity(workspaceCount * reposPerWorkspace)
    var globalIndex = 0

    for workspaceIndex in 0..<workspaceCount {
        var ids: [String] = []
        ids.reserveCapacity(reposPerWorkspace)
        for repoIndex in 0..<reposPerWorkspace {
            let snapshot = makeSnapshot(
                workspaceIndex: workspaceIndex, repoIndex: repoIndex, globalIndex: globalIndex
            )
            repositories.append(snapshot)
            ids.append(snapshot.id)
            globalIndex += 1
        }
        // Explicit ids: the default Workspace identity digest embeds the current
        // timestamp, which would make the aggregation fingerprint unstable.
        workspaces.append(Workspace(
            id: "ws-\(workspaceIndex)", name: "ws-\(workspaceIndex)", repositoryIDs: ids
        ))
    }
    return (workspaces, repositories)
}

let fixture = makeFixture()
let workspaces = fixture.workspaces
let repositories = fixture.repositories

// MARK: - Fingerprint

/// Re-encodes the aggregation with sorted keys and drops the wall-clock
/// duration so two implementations can be compared for identical output.
func fingerprint(_ aggregations: [String: WorkspaceAggregation]) throws -> (digest: String, json: Data) {
    let encoded = try JSONEncoder().encode(aggregations)
    var object = try JSONSerialization.jsonObject(with: encoded)
    func strip(_ value: inout Any) {
        if var dictionary = value as? [String: Any] {
            dictionary.removeValue(forKey: "computationDurationMs")
            for key in dictionary.keys {
                var child = dictionary[key] as Any
                strip(&child)
                dictionary[key] = child
            }
            value = dictionary
        } else if var array = value as? [Any] {
            for index in array.indices {
                var child = array[index]
                strip(&child)
                array[index] = child
            }
            value = array
        }
    }
    strip(&object)
    let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let digest = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
    return (digest, json)
}

// MARK: - Bench

func uptimeNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

let label = ProcessInfo.processInfo.environment["BENCH_LABEL"] ?? "current"

@main
struct Main {
    static func main() throws {
        var lastResult: [String: WorkspaceAggregation] = [:]

        for _ in 0..<warmupIterations {
            lastResult = WorkspaceAggregationEngine.aggregateAll(
                workspaces: workspaces, allRepositories: repositories, now: now
            )
        }

        let start = uptimeNanoseconds()
        for _ in 0..<iterations {
            lastResult = WorkspaceAggregationEngine.aggregateAll(
                workspaces: workspaces, allRepositories: repositories, now: now
            )
        }
        let elapsed = uptimeNanoseconds() - start

        let (digest, json) = try fingerprint(lastResult)
        if let outPath = ProcessInfo.processInfo.environment["BENCH_JSON_OUT"] {
            try json.write(to: URL(fileURLWithPath: outPath))
        }

        let totalMs = Double(elapsed) / 1_000_000.0
        let meanMs = totalMs / Double(iterations)
        print(String(
            format: "BENCH label=%@ repos=%d workspaces=%d iterations=%d total_ms=%.3f mean_ms=%.3f fingerprint=%@",
            label, repositories.count, workspaces.count, iterations, totalMs, meanMs, digest
        ))
    }
}
SWIFT

compile_and_run() {
    local label="$1"
    local engine="$2"
    local binary="$TMP_DIR/bench-$label"
    xcrun swiftc \
        -O \
        -sdk "$SDK_PATH" \
        -target arm64-apple-macosx14.0 \
        -module-cache-path "$MODULE_CACHE" \
        -o "$binary" \
        "$ROOT_DIR/DevPulseNative/Utilities/DateFormatting.swift" \
        "$ROOT_DIR/DevPulseNative/Core/CommitReadinessEngine.swift" \
        "$ROOT_DIR/DevPulseNative/Core/Models.swift" \
        "$ROOT_DIR/DevPulseNative/Core/PendingItem.swift" \
        "$ROOT_DIR/DevPulseNative/Core/ActivityEvent.swift" \
        "$ROOT_DIR/DevPulseNative/Core/WorkspaceModel.swift" \
        "$engine" \
        "$HARNESS" \
        2> "$TMP_DIR/compile-$label.log" || {
            echo "error: compilation failed for $label (log: $TMP_DIR/compile-$label.log)" >&2
            tail -30 "$TMP_DIR/compile-$label.log" >&2
            return 1
        }
    BENCH_LABEL="$label" \
    BENCH_JSON_OUT="$TMP_DIR/$label.json" \
        "$binary"
}

echo "Workspace aggregation benchmark"
echo "  workspaces=${BENCH_WORKSPACES:-8} repos/workspace=${BENCH_REPOS_PER_WORKSPACE:-25} iterations=${BENCH_ITERATIONS:-20}"
echo

if [[ -z "$BASELINE_ENGINE" ]]; then
    compile_and_run current "$ENGINE_FILE"
    exit 0
fi

[[ -f "$BASELINE_ENGINE" ]] || { echo "error: baseline engine not found: $BASELINE_ENGINE" >&2; exit 2; }

BASELINE_OUT="$TMP_DIR/baseline.out"
CURRENT_OUT="$TMP_DIR/current.out"
compile_and_run baseline "$BASELINE_ENGINE" | tee "$BASELINE_OUT"
compile_and_run current "$ENGINE_FILE" | tee "$CURRENT_OUT"

baseline_ms="$(sed -n 's/.* mean_ms=\([0-9.]*\).*/\1/p' "$BASELINE_OUT")"
current_ms="$(sed -n 's/.* mean_ms=\([0-9.]*\).*/\1/p' "$CURRENT_OUT")"
baseline_fp="$(sed -n 's/.* fingerprint=\([0-9a-f]*\).*/\1/p' "$BASELINE_OUT")"
current_fp="$(sed -n 's/.* fingerprint=\([0-9a-f]*\).*/\1/p' "$CURRENT_OUT")"

echo
awk -v b="$baseline_ms" -v c="$current_ms" 'BEGIN {
    if (c > 0) {
        printf "speedup: %.2fx faster (%.3f ms -> %.3f ms per aggregateAll)\n", b / c, b, c
        printf "reduction: %.1f%% of baseline runtime\n", (1 - c / b) * 100
    }
}'

if [[ "$baseline_fp" == "$current_fp" ]]; then
    echo "output equivalence: identical aggregation fingerprint ($current_fp)"
else
    echo "output equivalence: MISMATCH" >&2
    echo "  baseline: $baseline_fp" >&2
    echo "  current:  $current_fp" >&2
    diff <(python3 -m json.tool "$TMP_DIR/baseline.json") \
         <(python3 -m json.tool "$TMP_DIR/current.json") >&2 || true
    exit 1
fi

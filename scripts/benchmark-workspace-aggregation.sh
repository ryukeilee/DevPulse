#!/usr/bin/env bash
# A/B benchmark for the workspace aggregation of one refresh round.
#
# `ScanScheduler` runs two aggregations per refresh: `refreshWorkspaceAggregations`
# publishes the map for the workspace UI (every workspace), and
# `refreshPendingItems` needs the confirmed-workspace subset for the
# pending-item evaluation. This harness measures that round — the two consumers
# the scheduler drives — not a single `aggregateAll` call:
#
#   legacy-two-call   aggregateAll(all workspaces) + aggregateAll(confirmed)
#                     (the previous wiring, and the baseline label)
#   partitioned       aggregateAllPartitioned(all workspaces), whose single pass
#                     returns both maps (the current label)
#
# It compiles the production aggregation engine with the current scheduler call
# pattern and prints the mean milliseconds per refresh round plus a content
# fingerprint of every aggregation in both maps (excluding the wall-clock
# computationDurationMs field), so an optimization can be proved
# behavior-preserving: equal fingerprints mean identical aggregation output.
#
# Usage:
#   ./scripts/benchmark-workspace-aggregation.sh
#   BASELINE_ENGINE=<path-to-baseline-WorkspaceAggregationEngine.swift> \
#     ./scripts/benchmark-workspace-aggregation.sh
#   # or compare against a git ref of the current tree:
#   ./scripts/benchmark-workspace-aggregation.sh --baseline-git <ref>
#
# Tunables (env): BENCH_WORKSPACES, BENCH_REPOS_PER_WORKSPACE, BENCH_ITERATIONS,
#                 BENCH_WARMUP, BENCH_TIMESTAMP_SHAPE, BENCH_UNCONFIRMED_WORKSPACES
#
# BENCH_UNCONFIRMED_WORKSPACES (default 0) adds auto-suggest candidate workspaces
# that re-group repositories already covered by a confirmed workspace. 0 is the
# state the app itself produces today — nothing creates an unconfirmed workspace
# — so both consumers aggregate the same set; a non-zero value measures the
# partial-overlap case where the reuse removes less than the whole second pass.
#
# BENCH_TIMESTAMP_SHAPE=mixed (default) keeps the fixture's fractional-second
# timestamps, which still take the Foundation formatter path. Set it to
# `canonical` to hold every timestamp in the shapes the app itself writes and
# reads (`nowISO()` and `git log --pretty=%cI`), which take the arithmetic fast
# path; the two shapes give very different cost profiles, so measure the one
# matching the data under investigation.
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
            sed -n '2,42p' "$0"
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
// Auto-suggest candidates re-group repositories that a confirmed workspace
// already covers, so they add workspace memberships but no repositories.
let requestedUnconfirmed = ProcessInfo.processInfo.environment["BENCH_UNCONFIRMED_WORKSPACES"]
    .flatMap { Int($0) } ?? 0
let unconfirmedCount = max(0, min(requestedUnconfirmed, workspaceCount - 1))
let confirmedCount = workspaceCount - unconfirmedCount

/// `mixed` (default) keeps the fixture's fractional-second timestamps; `canonical`
/// holds every timestamp in the `YYYY-MM-DDTHH:MM:SSZ` shape the app writes.
let canonicalTimestamps = ProcessInfo.processInfo.environment["BENCH_TIMESTAMP_SHAPE"] == "canonical"

// MARK: - Fixture

/// Fixed reference instant so staleness classification is deterministic.
let now = Date(timeIntervalSince1970: 1_770_000_000)
let day: TimeInterval = 24 * 60 * 60

func iso(_ date: Date, fractionalSeconds: Bool) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = (fractionalSeconds && !canonicalTimestamps)
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

func makeFixture() -> (
    confirmed: [Workspace],
    unconfirmed: [Workspace],
    repositories: [RepositorySnapshot]
) {
    // The fixture holds BENCH_WORKSPACES x BENCH_REPOS_PER_WORKSPACE repositories
    // for every unconfirmed setting, so an A/B pair measures the same scan result
    // and a partial-overlap run keeps the same repository count. The remainder
    // goes to the first workspaces so a configuration that does not divide evenly
    // still reaches the exact count.
    let totalRepositories = workspaceCount * reposPerWorkspace
    let repositoriesPerConfirmedWorkspace = totalRepositories / confirmedCount
    let remainderRepositories = totalRepositories % confirmedCount
    var workspaces: [Workspace] = []
    var repositories: [RepositorySnapshot] = []
    workspaces.reserveCapacity(confirmedCount)
    repositories.reserveCapacity(totalRepositories)
    var globalIndex = 0

    for workspaceIndex in 0..<confirmedCount {
        let bucketSize = repositoriesPerConfirmedWorkspace + (workspaceIndex < remainderRepositories ? 1 : 0)
        var ids: [String] = []
        ids.reserveCapacity(bucketSize)
        for repoIndex in 0..<bucketSize {
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

    // Unconfirmed workspaces cover a slice of the repositories above, the way an
    // auto-suggest candidate re-groups repositories the confirmed grouping
    // already contains.
    var unconfirmed: [Workspace] = []
    guard !repositories.isEmpty else { return (workspaces, unconfirmed, repositories) }
    let window = max(1, repositoriesPerConfirmedWorkspace / 2)
    for candidateIndex in 0..<unconfirmedCount {
        let start = (candidateIndex * window) % repositories.count
        let ids = (0..<window).map { repositories[(start + $0) % repositories.count].id }
        unconfirmed.append(Workspace(
            id: "ws-\(confirmedCount + candidateIndex)-unconfirmed",
            name: "ws-\(confirmedCount + candidateIndex)-unconfirmed",
            repositoryIDs: ids,
            autoSuggestConfirmed: false
        ))
    }
    return (workspaces, unconfirmed, repositories)
}

let fixture = makeFixture()
let confirmedWorkspaces = fixture.confirmed
let unconfirmedWorkspaces = fixture.unconfirmed
// The scheduler publishes the map for confirmed workspaces first and unconfirmed
// ones second; the pending-item evaluation reads the confirmed subset alone.
let allWorkspaces = confirmedWorkspaces + unconfirmedWorkspaces
let repositories = fixture.repositories

// MARK: - Fingerprint

/// Re-encodes one aggregation map with sorted keys and drops the wall-clock
/// duration so two implementations can be compared for identical output.
func fingerprint(_ aggregations: [String: WorkspaceAggregation], jsonOut: String?) throws -> String {
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
    if let jsonOut {
        try json.write(to: URL(fileURLWithPath: jsonOut))
    }
    return SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Round under measurement

#if PARTITIONED_AGGREGATION_ROUND
let mode = "partitioned"

/// One refresh round through the current call pattern: a single partitioned
/// pass that answers both consumers.
func measureRound() -> (all: [String: WorkspaceAggregation], confirmed: [String: WorkspaceAggregation]) {
    let round = WorkspaceAggregationEngine.aggregateAllPartitioned(
        workspaces: allWorkspaces, allRepositories: repositories, now: now
    )
    return (round.all, round.confirmed)
}
#else
let mode = "legacy-two-call"

/// One refresh round through the previous call pattern: the UI map and the
/// confirmed subset aggregated in two separate passes.
func measureRound() -> (all: [String: WorkspaceAggregation], confirmed: [String: WorkspaceAggregation]) {
    let all = WorkspaceAggregationEngine.aggregateAll(
        workspaces: allWorkspaces, allRepositories: repositories, now: now
    )
    let confirmed = WorkspaceAggregationEngine.aggregateAll(
        workspaces: confirmedWorkspaces, allRepositories: repositories, now: now
    )
    return (all, confirmed)
}
#endif

// MARK: - Bench

func uptimeNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

let label = ProcessInfo.processInfo.environment["BENCH_LABEL"] ?? "current"

@main
struct Main {
    static func main() throws {
        var lastRound = measureRound()

        for _ in 0..<warmupIterations {
            lastRound = measureRound()
        }

        let start = uptimeNanoseconds()
        for _ in 0..<iterations {
            lastRound = measureRound()
        }
        let elapsed = uptimeNanoseconds() - start

        let allDigest = try fingerprint(
            lastRound.all, jsonOut: ProcessInfo.processInfo.environment["BENCH_JSON_OUT"]
        )
        let confirmedDigest = try fingerprint(
            lastRound.confirmed, jsonOut: ProcessInfo.processInfo.environment["BENCH_CONFIRMED_JSON_OUT"]
        )

        let totalMs = Double(elapsed) / 1_000_000.0
        let meanMs = totalMs / Double(iterations)
        print(String(
            format: "BENCH label=%@ mode=%@ repos=%d workspaces=%d confirmed=%d iterations=%d "
                + "total_ms=%.3f mean_ms=%.3f fingerprint_all=%@ fingerprint_confirmed=%@ timestamps=%@",
            label, mode, repositories.count, allWorkspaces.count, confirmedWorkspaces.count,
            iterations, totalMs, meanMs, allDigest, confirmedDigest,
            canonicalTimestamps ? "canonical" : "mixed"
        ))
    }
}
SWIFT

compile_and_run() {
    local label="$1"
    local engine="$2"
    local defines="${3:-}"
    local binary="$TMP_DIR/bench-$label"
    # Only the current tree is compiled against `aggregateAllPartitioned`; the
    # baseline engine source predates it.
    xcrun swiftc \
        -O \
        $defines \
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
    BENCH_JSON_OUT="$TMP_DIR/$label-all.json" \
    BENCH_CONFIRMED_JSON_OUT="$TMP_DIR/$label-confirmed.json" \
        "$binary"
}

echo "Workspace aggregation benchmark (one refresh round: UI map + confirmed map)"
echo "  workspaces=${BENCH_WORKSPACES:-8} (unconfirmed=${BENCH_UNCONFIRMED_WORKSPACES:-0}) repos/workspace=${BENCH_REPOS_PER_WORKSPACE:-25} iterations=${BENCH_ITERATIONS:-20} timestamps=${BENCH_TIMESTAMP_SHAPE:-mixed}"
echo

if [[ -z "$BASELINE_ENGINE" ]]; then
    compile_and_run current "$ENGINE_FILE" "-D PARTITIONED_AGGREGATION_ROUND"
    exit 0
fi

[[ -f "$BASELINE_ENGINE" ]] || { echo "error: baseline engine not found: $BASELINE_ENGINE" >&2; exit 2; }

BASELINE_OUT="$TMP_DIR/baseline.out"
CURRENT_OUT="$TMP_DIR/current.out"
compile_and_run baseline "$BASELINE_ENGINE" | tee "$BASELINE_OUT"
compile_and_run current "$ENGINE_FILE" "-D PARTITIONED_AGGREGATION_ROUND" | tee "$CURRENT_OUT"

baseline_ms="$(sed -n 's/.* mean_ms=\([0-9.]*\).*/\1/p' "$BASELINE_OUT")"
current_ms="$(sed -n 's/.* mean_ms=\([0-9.]*\).*/\1/p' "$CURRENT_OUT")"
baseline_all_fp="$(sed -n 's/.* fingerprint_all=\([0-9a-f]*\).*/\1/p' "$BASELINE_OUT")"
current_all_fp="$(sed -n 's/.* fingerprint_all=\([0-9a-f]*\).*/\1/p' "$CURRENT_OUT")"
baseline_confirmed_fp="$(sed -n 's/.* fingerprint_confirmed=\([0-9a-f]*\).*/\1/p' "$BASELINE_OUT")"
current_confirmed_fp="$(sed -n 's/.* fingerprint_confirmed=\([0-9a-f]*\).*/\1/p' "$CURRENT_OUT")"

echo
awk -v b="$baseline_ms" -v c="$current_ms" 'BEGIN {
    if (c > 0) {
        printf "speedup: %.2fx faster (%.3f ms -> %.3f ms per refresh round)\n", b / c, b, c
        printf "reduction: %.1f%% of baseline runtime\n", (1 - c / b) * 100
    }
}'

status=0
if [[ "$baseline_all_fp" == "$current_all_fp" ]]; then
    echo "output equivalence (UI map): identical aggregation fingerprint ($current_all_fp)"
else
    echo "output equivalence (UI map): MISMATCH" >&2
    diff <(python3 -m json.tool "$TMP_DIR/baseline-all.json") \
         <(python3 -m json.tool "$TMP_DIR/current-all.json") >&2 || true
    status=1
fi
if [[ "$baseline_confirmed_fp" == "$current_confirmed_fp" ]]; then
    echo "output equivalence (confirmed map): identical aggregation fingerprint ($current_confirmed_fp)"
else
    echo "output equivalence (confirmed map): MISMATCH" >&2
    diff <(python3 -m json.tool "$TMP_DIR/baseline-confirmed.json") \
         <(python3 -m json.tool "$TMP_DIR/current-confirmed.json") >&2 || true
    status=1
fi
exit "$status"

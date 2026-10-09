#!/usr/bin/env bash
# A/B benchmark for RepositoryListQuery.apply (filter + sort) on large
# repository lists.
#
# Runs a standalone harness (same pattern as
# benchmark-workspace-aggregation.sh) against the current source, and
# optionally against a baseline source checkout so a before/after
# comparison can be measured with a single command.
#
# Usage:
#   ./scripts/benchmark-repository-list-query.sh
#   BASELINE_ROOT=<path-to-checkout> ./scripts/benchmark-repository-list-query.sh
#   # or compare against a git ref of the current tree:
#   ./scripts/benchmark-repository-list-query.sh --baseline-git <ref>
#
# Tunables (env): BENCH_REPOS, BENCH_ITERATIONS, BENCH_WARMUP
#
# The harness emits a content fingerprint of every query result so an
# optimization can be proved behavior-preserving: equal fingerprints mean
# identical output (order included) for every filter/sort mode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SORTER_REL="DevPulseNative/Core/RepositorySorter.swift"

BASELINE_ROOT="${BASELINE_ROOT:-}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-list-bench.XXXXXX")"
BASELINE_WORKTREE=""
cleanup() {
    if [[ -n "$BASELINE_WORKTREE" ]]; then
        git -C "$ROOT_DIR" worktree remove --force "$BASELINE_WORKTREE" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-git)
            [[ -n "${2:-}" ]] || { echo "error: --baseline-git requires a ref" >&2; exit 2; }
            BASELINE_WORKTREE="$TMP_DIR/baseline-checkout"
            git -C "$ROOT_DIR" worktree add --detach "$BASELINE_WORKTREE" "$2" >/dev/null
            BASELINE_ROOT="$BASELINE_WORKTREE"
            shift 2
            ;;
        --baseline-root)
            [[ -n "${2:-}" ]] || { echo "error: --baseline-root requires a path" >&2; exit 2; }
            BASELINE_ROOT="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

HARNESS="$TMP_DIR/bench-repository-list-query.swift"
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

let repositoryCount = envInt("BENCH_REPOS", 1200)
let iterations = envInt("BENCH_ITERATIONS", 15)
let warmupIterations = envInt("BENCH_WARMUP", 3)

// MARK: - Fixture

let day: TimeInterval = 24 * 60 * 60
/// Fixed reference instant, far enough in the past that every fixture timestamp
/// is either clearly valid or clearly filtered as an implausible future value.
let now = Date(timeIntervalSince1970: 1_770_000_000)

func iso(_ date: Date, fractionalSeconds: Bool) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = fractionalSeconds
        ? [.withInternetDateTime, .withFractionalSeconds]
        : [.withInternetDateTime]
    return formatter.string(from: date)
}

func name(for index: Int) -> String {
    // Numeric tokens, case, and diacritics exercise localizedStandardCompare.
    switch index % 6 {
    case 0: return "workspace-\(index) repo \(index % 37)"
    case 1: return "Café repo \(index)"
    case 2: return "ALPHA repo \(index % 13)"
    case 3: return "汉字 仓库 \(index)"
    case 4: return "zeta repo \(index % 11)"
    default: return "repo \(index)"
    }
}

func makeSnapshot(_ index: Int) -> RepositorySnapshot {
    let name = name(for: index)
    let status: RepositoryStatus
    switch index % 7 {
    case 0, 3: status = .clean
    case 5: status = .error
    default: status = .changed
    }
    let risk: RiskLevel = [.low, .medium, .high][index % 3]
    let dataSource: RepositoryDataSource?
    switch index % 9 {
    case 0: dataSource = nil
    case 4: dataSource = .lastSuccessful
    case 7: dataSource = .unknown
    default: dataSource = .current
    }
    // Rotate activity shapes so the recent-activity derivation exercises both
    // ISO-8601 formats, the lastChangedAt fallback, missing timestamps, and the
    // implausible-future filter.
    let activityOffset = TimeInterval(-(index % 240) * 3600)
    let activity = iso(now.addingTimeInterval(activityOffset), fractionalSeconds: index % 2 == 0)
    let changed = iso(now.addingTimeInterval(activityOffset - 7200), fractionalSeconds: index % 3 == 0)
    let future = "9999-01-01T00:00:00.000Z"
    let lastActivityAt: String?
    let lastChangedAt: String?
    switch index % 10 {
    case 0: lastActivityAt = nil; lastChangedAt = changed
    case 1: lastActivityAt = activity; lastChangedAt = nil
    case 2: lastActivityAt = future; lastChangedAt = nil
    case 3: lastActivityAt = nil; lastChangedAt = nil
    case 4: lastActivityAt = activity; lastChangedAt = changed
    default: lastActivityAt = activity; lastChangedAt = changed
    }

    return RepositorySnapshot(
        id: "repo-\(index)",
        name: name,
        path: "/Users/bench/workspaces/ws-\(index % 12)/repo-\(index)",
        branch: index % 5 == 0 ? "feature/\(index)" : "main",
        status: status,
        modifiedFileCount: index % 4,
        addedFileCount: index % 3,
        deletedFileCount: index % 2,
        untrackedFileCount: index % 5,
        stagedFileCount: index % 4,
        unstagedFileCount: index % 6,
        conflictedFileCount: index % 7 == 0 ? 2 : 0,
        aheadCount: index % 3,
        behindCount: index % 4,
        hasUpstream: index % 5 != 0,
        changedFileCount: index % 9,
        changedFilesPreview: index % 2 == 0 ? ["src/Feature\(index).swift"] : [],
        risk: risk,
        lastScannedAt: iso(now.addingTimeInterval(-TimeInterval(index % 48) * 3600),
                          fractionalSeconds: index % 2 == 1),
        dataSource: dataSource,
        lastSuccessfulScanAt: iso(now.addingTimeInterval(-day), fractionalSeconds: false),
        lastChangedAt: lastChangedAt,
        lastCommitID: "abc\(index)",
        lastCommitSummary: "commit \(index)",
        lastCommitMetadataAvailable: true,
        lastActivityAt: lastActivityAt,
        unavailableSince: nil,
        errorMessage: status == .error ? "read failed" : nil,
        isPinned: index % 20 == 0
    )
}

let repositories = (0..<repositoryCount).map(makeSnapshot)

// MARK: - Modes

struct Mode {
    let name: String
    let searchText: String
    let filter: RepositoryListFilter
    let sortOrder: RepositoryListSortOrder
}

let modes: [Mode] = [
    Mode(name: "all-smart", searchText: "", filter: .all, sortOrder: .smart),
    Mode(name: "all-name", searchText: "", filter: .all, sortOrder: .name),
    Mode(name: "all-recent", searchText: "", filter: .all, sortOrder: .recentActivity),
    Mode(name: "search-recent", searchText: "café repo 1", filter: .all, sortOrder: .recentActivity),
    Mode(name: "filter-recent", searchText: "", filter: .needsAttention, sortOrder: .recentActivity),
    Mode(name: "filter-local-name", searchText: "", filter: .localChanges, sortOrder: .name)
]

// MARK: - Fingerprint

func fingerprint(_ result: [RepositorySnapshot]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(result)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Bench

func uptimeNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

let label = ProcessInfo.processInfo.environment["BENCH_LABEL"] ?? "current"

@main
struct Main {
    static func main() throws {
        print("BENCH label=\(label) repos=\(repositories.count) iterations=\(iterations)")
        for mode in modes {
            var lastResult: [RepositorySnapshot] = []
            for _ in 0..<warmupIterations {
                lastResult = RepositoryListQuery.apply(
                    to: repositories,
                    searchText: mode.searchText,
                    filter: mode.filter,
                    sortOrder: mode.sortOrder
                )
            }
            let start = uptimeNanoseconds()
            for _ in 0..<iterations {
                lastResult = RepositoryListQuery.apply(
                    to: repositories,
                    searchText: mode.searchText,
                    filter: mode.filter,
                    sortOrder: mode.sortOrder
                )
            }
            let elapsed = uptimeNanoseconds() - start
            let digest = try fingerprint(lastResult)
            let totalMs = Double(elapsed) / 1_000_000.0
            let meanMs = totalMs / Double(iterations)
            print(String(
                format: "MODE %@ rows=%d total_ms=%.3f mean_ms=%.3f fingerprint=%@",
                mode.name, lastResult.count, totalMs, meanMs, digest
            ))
        }
    }
}
SWIFT

compile_and_run() {
    local label="$1"
    local root="$2"
    local binary="$TMP_DIR/bench-$label"
    xcrun swiftc \
        -O \
        -sdk "$SDK_PATH" \
        -target arm64-apple-macosx14.0 \
        -module-cache-path "$MODULE_CACHE" \
        -o "$binary" \
        "$root/DevPulseNative/Utilities/DateFormatting.swift" \
        "$root/DevPulseNative/Core/CommitReadinessEngine.swift" \
        "$root/DevPulseNative/Core/Models.swift" \
        "$root/DevPulseNative/Core/PendingItem.swift" \
        "$root/DevPulseNative/Core/ActivityEvent.swift" \
        "$root/DevPulseNative/Core/WorkspaceModel.swift" \
        "$root/$SORTER_REL" \
        "$HARNESS" \
        2> "$TMP_DIR/compile-$label.log" || {
            echo "error: compilation failed for $label (log: $TMP_DIR/compile-$label.log)" >&2
            tail -30 "$TMP_DIR/compile-$label.log" >&2
            return 1
        }
    BENCH_LABEL="$label" "$binary" | tee "$TMP_DIR/$label.out"
}

echo "Repository list query benchmark"
echo "  repos=${BENCH_REPOS:-1200} iterations=${BENCH_ITERATIONS:-15}"
echo

if [[ -z "$BASELINE_ROOT" ]]; then
    compile_and_run current "$ROOT_DIR"
    exit 0
fi

[[ -d "$BASELINE_ROOT" ]] || { echo "error: baseline root not found: $BASELINE_ROOT" >&2; exit 2; }

compile_and_run baseline "$BASELINE_ROOT"
compile_and_run current "$ROOT_DIR"

extract() {
    local file="$1" mode="$2" field="$3"
    sed -n "s/^MODE $mode .*$field=\([0-9a-f.]*\).*/\1/p" "$file"
}

status=0
while read -r mode; do
    baseline_ms="$(extract "$TMP_DIR/baseline.out" "$mode" mean_ms)"
    current_ms="$(extract "$TMP_DIR/current.out" "$mode" mean_ms)"
    baseline_fp="$(extract "$TMP_DIR/baseline.out" "$mode" fingerprint)"
    current_fp="$(extract "$TMP_DIR/current.out" "$mode" fingerprint)"
    awk -v m="$mode" -v b="$baseline_ms" -v c="$current_ms" 'BEGIN {
        if (b > 0 && c > 0) {
            printf "%-18s %6.3f ms -> %6.3f ms  (%.2fx faster, -%.1f%%)\n", m, b, c, b / c, (1 - c / b) * 100
        }
    }'
    if [[ "$baseline_fp" != "$current_fp" ]]; then
        echo "  output equivalence: MISMATCH for $mode" >&2
        echo "    baseline: $baseline_fp" >&2
        echo "    current:  $current_fp" >&2
        status=1
    fi
done < <(sed -n 's/^MODE \([^ ]*\) .*/\1/p' "$TMP_DIR/baseline.out")

if [[ "$status" -eq 0 ]]; then
    echo
    echo "output equivalence: all query fingerprints identical"
fi
exit "$status"

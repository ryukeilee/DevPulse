#!/usr/bin/env bash
# A/B benchmark for the scan-result collection, merge and reassembly bookkeeping
# in `RefreshEngine` stages `coreStatus` and `extendedInfo`.
#
# Both stages collect per-repository results that finish out of order and must
# be reassembled in priority/core-status order. The pre-change wiring used
# index-keyed dictionaries for that (`[Int: RepositorySnapshot]`) plus a final
# reassembly pass; the current wiring addresses dense slots in an array and
# updates the ordered output in place. This harness compiles both wirings
# against the production `RepositorySnapshot` type and the same arrival shape
# (out-of-order completion with indexes that never report back), so the
# difference measured is the container bookkeeping itself and not Git I/O,
# parsing, or snapshot construction.
#
#   stage2_dictionary   `readCoreStatusPriorityBatched` before the change
#   stage2_slots        `readCoreStatusPriorityBatched` as it is now
#   stage3_dictionary   `readExtendedInfo` before the change
#   stage3_inplace      `readExtendedInfo` as it is now
#
# Each wiring prints a SHA-256 fingerprint of the JSON encoding of its complete
# ordered output, so an optimization can be proved behavior-preserving: equal
# fingerprints mean identical snapshots (every field, order included). The
# script exits non-zero when a stage's two wirings disagree.
#
# Usage:
#   ./scripts/benchmark-refresh-stage-collection.sh
#
# Tunables (env): BENCH_REPOS, BENCH_ITERATIONS, BENCH_WARMUP
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

BENCH_REPOS="${BENCH_REPOS:-240}"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-101}"
BENCH_WARMUP="${BENCH_WARMUP:-3}"
export BENCH_REPOS BENCH_ITERATIONS BENCH_WARMUP

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-refresh-stage-bench.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

HARNESS="$TMP_DIR/bench-refresh-stage-collection.swift"
MODULE_CACHE="$TMP_DIR/module-cache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$MODULE_CACHE"

cat > "$HARNESS" <<'SWIFT'
import CryptoKit
import Foundation

func envInt(_ key: String, _ fallback: Int) -> Int {
    if let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw), value > 0 {
        return value
    }
    return fallback
}

let repositoryCount = envInt("BENCH_REPOS", 240)
let iterations = envInt("BENCH_ITERATIONS", 101)
let warmupIterations = envInt("BENCH_WARMUP", 3)

// MARK: - Fixture

/// Snapshot shape mirroring a real scan payload: populated commit metadata,
/// changed-file previews, optional fields, and pinned entries.
func makeSnapshot(_ index: Int) -> RepositorySnapshot {
    let scannedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_770_000_000))
    return RepositorySnapshot(
        id: "repo-v1-\(index)",
        name: "repo-\(index)",
        path: "/Users/bench/workspaces/ws-\(index % 12)/repo-\(index)",
        branch: index % 5 == 0 ? "feature/\(index)" : "main",
        status: index % 3 == 0 ? .clean : .changed,
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
        changedFilesPreview: index % 2 == 0 ? ["src/Feature\(index).swift", "README.md"] : [],
        risk: [.low, .medium, .high][index % 3],
        lastScannedAt: scannedAt,
        dataSource: .current,
        lastSuccessfulScanAt: scannedAt,
        lastChangedAt: scannedAt,
        lastCommitID: String(repeating: "a", count: 40),
        lastCommitSummary: "commit \(index)",
        lastCommitMetadataAvailable: true,
        lastActivityAt: scannedAt,
        unavailableSince: nil,
        errorMessage: nil,
        isPinned: index % 20 == 0
    )
}

let base = (0..<repositoryCount).map(makeSnapshot)

/// Completion order of the concurrent status tasks: last path finishes first,
/// then inward. Every reached index appears exactly once.
let arrivalOrder: [Int] = {
    var order: [Int] = []
    var low = 0
    var high = repositoryCount - 1
    while low <= high {
        order.append(high)
        if low != high { order.append(low) }
        low += 1
        high -= 1
    }
    return order
}()

/// Indexes whose task never reported back (stage budget exhausted / superseded).
func didReport(_ index: Int) -> Bool { index % 7 != 0 }

/// Repositories that need `git log` in stage 3: some are answered by a log
/// result, the rest keep their status snapshot.
let needsLog = base.indices.filter { !($0 % 3 == 0 || $0 % 5 == 0) }
let loggedIndexes = needsLog.filter { $0 % 4 != 0 }

/// Stand-in for the distinct content each stage-3 branch produces
/// (`reusingCommitMetadata` for reused metadata, the log-enriched snapshot for
/// a `git log` result). The tag is derived from the index, so a result that is
/// reassembled into the wrong slot, duplicated, or dropped entirely changes the
/// fingerprint instead of hiding behind identical contents.
func marked(_ snapshot: RepositorySnapshot, tag: String) -> RepositorySnapshot {
    var copy = snapshot
    copy.lastActivityAt = tag
    return copy
}

// MARK: - Fingerprint

/// Content fingerprint of the complete ordered output. Equal fingerprints mean
/// identical snapshots for every encoded field and for their order.
func fingerprint(_ snapshots: [RepositorySnapshot]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(snapshots)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

let snapshotStride = MemoryLayout<RepositorySnapshot>.stride
/// Approximate payload of a `[Int: RepositorySnapshot]` container: value stride
/// plus the per-bucket key/hash word.
func dictionaryPayloadBytes(_ capacity: Int) -> Int { capacity * (snapshotStride + 8) }
func slotsPayloadBytes(_ count: Int) -> Int { count * (snapshotStride + 1) }

// MARK: - Stage 2: previous wiring (index-keyed dictionary)

func stage2Dictionary() -> (snapshots: [RepositorySnapshot], completed: Int, extraBytes: Int) {
    var snapshotsByIndex: [Int: RepositorySnapshot] = [:]
    for idx in arrivalOrder where didReport(idx) {
        snapshotsByIndex[idx] = base[idx]
    }
    var orderedSnapshots: [RepositorySnapshot] = []
    for idx in base.indices {
        if let snapshot = snapshotsByIndex[idx] {
            orderedSnapshots.append(snapshot)
        }
    }
    return (orderedSnapshots, snapshotsByIndex.count,
            dictionaryPayloadBytes(snapshotsByIndex.capacity))
}

// MARK: - Stage 2: current wiring (index-addressed slots)

func stage2Slots() -> (snapshots: [RepositorySnapshot], completed: Int, extraBytes: Int) {
    var slots = [RepositorySnapshot?](repeating: nil, count: base.count)
    var completedCount = 0
    for idx in arrivalOrder where didReport(idx) {
        slots[idx] = base[idx]
        completedCount += 1
    }
    var orderedSnapshots: [RepositorySnapshot] = []
    orderedSnapshots.reserveCapacity(completedCount)
    for slot in slots {
        if let snapshot = slot {
            orderedSnapshots.append(snapshot)
        }
    }
    return (orderedSnapshots, completedCount, slotsPayloadBytes(slots.count))
}

// MARK: - Stage 3: previous wiring (baseline + log dictionaries + reassembly)

func stage3Dictionary() -> (snapshots: [RepositorySnapshot], completed: Int, extraBytes: Int) {
    var baselineByIndex: [Int: RepositorySnapshot] = [:]
    var needsLogList: [Int] = []
    for (idx, snapshot) in base.enumerated() {
        if idx % 3 == 0 || idx % 5 == 0 {
            baselineByIndex[idx] = marked(snapshot, tag: "reuse-\(idx)")
        } else {
            needsLogList.append(idx)
        }
    }
    var logResults: [Int: RepositorySnapshot] = [:]
    for idx in loggedIndexes { logResults[idx] = marked(base[idx], tag: "log-\(idx)") }

    var finalSnapshots: [RepositorySnapshot] = []
    for (idx, snapshot) in base.enumerated() {
        finalSnapshots.append(logResults[idx] ?? baselineByIndex[idx] ?? snapshot)
    }
    return (finalSnapshots, logResults.count,
            dictionaryPayloadBytes(baselineByIndex.capacity)
                + dictionaryPayloadBytes(logResults.capacity))
}

// MARK: - Stage 3: current wiring (ordered output mutated in place)

func stage3InPlace() -> (snapshots: [RepositorySnapshot], completed: Int, extraBytes: Int) {
    var orderedSnapshots = base
    var logCompleted = 0
    for (idx, snapshot) in base.enumerated() {
        if idx % 3 == 0 || idx % 5 == 0 {
            orderedSnapshots[idx] = marked(snapshot, tag: "reuse-\(idx)")
        }
    }
    for idx in loggedIndexes {
        orderedSnapshots[idx] = marked(base[idx], tag: "log-\(idx)")
        logCompleted += 1
    }
    return (orderedSnapshots, logCompleted, 0)
}

// MARK: - Bench

func uptimeNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

@main
struct Main {
    static func main() throws {
        let reported = arrivalOrder.filter(didReport).count
        print("BENCH repos=\(repositoryCount) stride=\(snapshotStride)B reported=\(reported) logged=\(loggedIndexes.count) iterations=\(iterations)")

        let wirings: [(name: String, run: () throws -> (snapshots: [RepositorySnapshot], completed: Int, extraBytes: Int))] = [
            ("stage2_dictionary", stage2Dictionary),
            ("stage2_slots", stage2Slots),
            ("stage3_dictionary", stage3Dictionary),
            ("stage3_inplace", stage3InPlace)
        ]

        for wiring in wirings {
            for _ in 0..<warmupIterations { _ = try wiring.run() }
            var samples: [Double] = []
            samples.reserveCapacity(iterations)
            var last: (snapshots: [RepositorySnapshot], completed: Int, extraBytes: Int)!
            for _ in 0..<iterations {
                let start = uptimeNanoseconds()
                last = try wiring.run()
                samples.append(Double(uptimeNanoseconds() - start) / 1000.0)
            }
            samples.sort()
            let median = samples[samples.count / 2]
            print(String(
                format: "MODE %@ rows=%d completed=%d median_us=%.2f p10_us=%.2f extra_bytes=%d fingerprint=%@",
                wiring.name, last.snapshots.count, last.completed, median,
                samples[samples.count / 10], last.extraBytes, try fingerprint(last.snapshots)
            ))
        }
    }
}
SWIFT

xcrun swiftc \
    -O \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx14.0 \
    -module-cache-path "$MODULE_CACHE" \
    -o "$TMP_DIR/bench-refresh-stage-collection" \
    "$ROOT_DIR/DevPulseNative/Utilities/DateFormatting.swift" \
    "$ROOT_DIR/DevPulseNative/Core/CommitReadinessEngine.swift" \
    "$ROOT_DIR/DevPulseNative/Core/Models.swift" \
    "$ROOT_DIR/DevPulseNative/Core/PendingItem.swift" \
    "$ROOT_DIR/DevPulseNative/Core/ActivityEvent.swift" \
    "$ROOT_DIR/DevPulseNative/Core/WorkspaceModel.swift" \
    "$ROOT_DIR/DevPulseNative/Core/RepositorySorter.swift" \
    "$HARNESS" \
    2> "$TMP_DIR/compile.log" || {
        echo "error: compilation failed (log: $TMP_DIR/compile.log)" >&2
        tail -30 "$TMP_DIR/compile.log" >&2
        exit 1
    }

echo "RefreshEngine stage collection benchmark"
echo "  repos=$BENCH_REPOS iterations=$BENCH_ITERATIONS"
echo
"$TMP_DIR/bench-refresh-stage-collection" | tee "$TMP_DIR/bench.out"
echo

extract() {
    local mode="$1" field="$2"
    sed -n "s/^MODE $mode .*$field=\([0-9a-f.]*\).*/\1/p" "$TMP_DIR/bench.out"
}

status=0
compare() {
    local stage="$1" before="$2" after="$3" label="$4"
    local before_us after_us
    before_us="$(extract "$before" median_us)"
    after_us="$(extract "$after" median_us)"
    awk -v s="$stage" -v l="$label" -v b="$before_us" -v c="$after_us" 'BEGIN {
        printf "  %-12s %-24s %8.2f us -> %8.2f us  (%.2fx faster, -%.1f%%)\n", s, l, b, c, b / c, (1 - c / b) * 100
    }'
    # Both containers must agree on the row count, the completed counter and the
    # full ordered payload; a divergence in any of them fails the run.
    for field in rows completed fingerprint; do
        local before_value after_value
        before_value="$(extract "$before" "$field")"
        after_value="$(extract "$after" "$field")"
        if [[ "$before_value" != "$after_value" ]]; then
            echo "  output equivalence: MISMATCH for $stage ($field)" >&2
            echo "    $before: $before_value" >&2
            echo "    $after:  $after_value" >&2
            status=1
        fi
    done
}

echo "median single-refresh bookkeeping cost:"
compare coreStatus stage2_dictionary stage2_slots "dictionary -> slots"
compare extendedInfo stage3_dictionary stage3_inplace "dictionary -> in-place"
echo
echo "extra temporary container payload beyond the ordered output:"
for mode in stage2_dictionary stage2_slots stage3_dictionary stage3_inplace; do
    printf '  %-18s %s bytes\n' "$mode" "$(extract "$mode" extra_bytes)"
done

if [[ "$status" -eq 0 ]]; then
    echo
    echo "output equivalence: rows, completed counters and ordered snapshot fingerprints identical for both stages"
fi
exit "$status"

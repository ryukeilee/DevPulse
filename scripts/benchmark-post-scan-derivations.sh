#!/usr/bin/env bash
# A/B benchmark for the post-scan repository derivation sequence.
#
# `ScanScheduler` derives the same scan result several times per refresh: the
# scan-completion pass, the pre-write pass, the post-write read-back pass and
# the widget projection. Each pass resolves every repository path to its
# canonical form; the question this harness answers is how much of that is
# repeated filesystem work, and whether feeding the passes one shared
# canonical-path reuse map changes any of their output.
#
# The harness compiles the production composition (`RepositoryScope.filtering`
# + `RepositoryIdentityMigration.migrate` + pin application + `RepositorySorter.sort`,
# which is what `ScanScheduler.applyPins` performs) and measures two call
# patterns over the same inputs:
#
#   sequence_per_pass_scope   one reuse map per pass (the previous wiring)
#   sequence_shared_scope     one reuse map for the whole sequence (this change)
#
# Each stage prints the reuse-map ledger (lookups/computations/reuses) and a
# SHA-256 fingerprint of its output, so equal fingerprints prove the shared map
# changed no identifier, no order and no snapshot field, and the ledger proves
# the removed work is path resolution rather than logic.
#
# Repository paths are created as real directories under the harness root, so
# `RepositoryIdentity.canonicalPath` exercises the same filesystem resolution
# (existence check plus symlink resolution) as it does for a real scan.
#
# Usage:
#   ./scripts/benchmark-post-scan-derivations.sh
#
# Tunables (env): BENCH_REPOS (space separated list), BENCH_ITERATIONS,
#                 BENCH_WARMUP, BENCH_RUNS
#
# Exits non-zero when the two call patterns disagree on output or when the
# ledgers do not show the expected resolution count.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

BENCH_REPOS="${BENCH_REPOS:-4 8 60 240}"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-21}"
BENCH_WARMUP="${BENCH_WARMUP:-3}"
BENCH_RUNS="${BENCH_RUNS:-3}"
export BENCH_REPOS BENCH_ITERATIONS BENCH_WARMUP

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-post-scan-bench.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

HARNESS="$TMP_DIR/main.swift"
MODULE_CACHE="$TMP_DIR/module-cache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$MODULE_CACHE"

SOURCES=(
    "DevPulseNative/Utilities/DateFormatting.swift"
    "DevPulseNative/Core/Models.swift"
    "DevPulseNative/Core/ActivityEvent.swift"
    "DevPulseNative/Core/PendingItem.swift"
    "DevPulseNative/Core/CommitReadinessEngine.swift"
    "DevPulseNative/Core/CommitReadinessBadge.swift"
    "DevPulseNative/Core/RiskHintEngine.swift"
    "DevPulseNative/Core/RepositorySorter.swift"
)

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

let repositoryCounts = (ProcessInfo.processInfo.environment["BENCH_REPOS"] ?? "4 8 60 240")
    .split(whereSeparator: { $0 == " " || $0 == "," })
    .compactMap { Int($0) }
    .filter { $0 > 0 }
let iterations = envInt("BENCH_ITERATIONS", 21)
let warmupIterations = envInt("BENCH_WARMUP", 3)

// MARK: - Fixture

/// Real directories, so every derivation pays the same existence check and
/// symlink resolution a scanned repository path does.
func makeFixturePaths(_ count: Int, root: URL) -> [String] {
    var paths: [String] = []
    for index in 0..<count {
        let directory = root.appendingPathComponent("ws-\(index % 12)/repo-\(index)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        paths.append(directory.path)
    }
    return paths
}

func fixtureRepository(_ index: Int, path: String) -> RepositorySnapshot {
    let status: RepositoryStatus
    switch index % 7 {
    case 0, 3: status = .clean
    case 5: status = .error
    default: status = .changed
    }
    return RepositorySnapshot(
        id: "repo-\(index)",
        name: "repo \(index)",
        path: path,
        workspaceKind: index % 3 == 0 ? .linkedWorktree : .standalone,
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
        risk: [.low, .medium, .high][index % 3],
        lastScannedAt: "2026-10-09T00:00:00Z",
        dataSource: .current,
        lastSuccessfulScanAt: "2026-10-08T00:00:00Z",
        lastChangedAt: index % 4 == 3 ? nil : "2026-10-08T00:00:00Z",
        lastCommitID: "abc\(index)",
        lastCommitSummary: "commit \(index)",
        lastCommitMetadataAvailable: true,
        lastActivityAt: "2026-10-08T12:00:00Z",
        unavailableSince: nil,
        errorMessage: status == .error ? "read failed" : nil,
        isPinned: index % 20 == 0
    )
}

func fixtureSnapshot(paths: [String]) -> AppGroupData {
    let repositories = paths.enumerated().map { fixtureRepository($0.offset, path: $0.element) }
    return AppGroupData(
        schemaVersion: RepositorySnapshotSchema.version,
        generatedAt: "2026-10-09T00:00:00Z",
        writtenAt: "2026-10-09T00:00:00Z",
        lastSuccessfulRefreshAt: "2026-10-09T00:00:00Z",
        historySchemaVersion: 1,
        historyRecordingEnabled: true,
        scanSummary: ScanSummary.build(from: repositories),
        repositories: repositories,
        recentActivityEvents: (0..<min(paths.count, 40)).map { index in
            ActivityEventSummary(
                id: "event-\(index)",
                repositoryID: "repo-\(index)",
                repositoryName: "repo \(index)",
                kind: .newCommit,
                occurredAt: "2026-10-09T00:00:00Z",
                message: "commit \(index)",
                priority: index % 5
            )
        },
        repositoryUnavailableSinceByPath: Dictionary(uniqueKeysWithValues: (0..<min(paths.count, 25)).map {
            (paths[$0], "2026-10-01T00:00:00Z")
        }),
        storageRevision: 7,
        persistenceState: .committed,
        pendingItemWidgetSummary: nil,
        isRefreshing: false,
        discoveryWasIncomplete: false,
        appVersion: "0.2.0",
        storageFormatVersion: RepositorySnapshotSchema.storageFormatVersion
    )
}

// MARK: - Production composition

/// Exactly what `ScanScheduler.applyPins` performs on one snapshot.
func applyPinsLike(_ data: AppGroupData, pinnedIDs: Set<String>) -> AppGroupData {
    let scoped = RepositoryScope.filtering(data, excluding: [])
    let migration = RepositoryIdentityMigration.migrate(snapshot: scoped, pinnedIDs: pinnedIDs)
    let ids = migration.pinnedIDs
    var repositories = migration.snapshot.repositories.map { repository -> RepositorySnapshot in
        var copy = repository
        copy.isPinned = ids.contains(repository.id)
        return copy
    }
    repositories = RepositorySorter.sort(repositories)
    let snapshot = migration.snapshot
    return AppGroupData(
        schemaVersion: snapshot.schemaVersion,
        generatedAt: snapshot.generatedAt,
        writtenAt: snapshot.writtenAt,
        lastSuccessfulRefreshAt: snapshot.lastSuccessfulRefreshAt,
        historySchemaVersion: snapshot.historySchemaVersion,
        historyRecordingEnabled: snapshot.historyRecordingEnabled,
        scanSummary: snapshot.scanSummary,
        repositories: repositories,
        recentActivityEvents: snapshot.recentActivityEvents,
        repositoryUnavailableSinceByPath: snapshot.repositoryUnavailableSinceByPath,
        storageRevision: snapshot.storageRevision,
        persistenceState: snapshot.persistenceState,
        pendingItemWidgetSummary: snapshot.pendingItemWidgetSummary,
        isRefreshing: snapshot.isRefreshing,
        discoveryWasIncomplete: snapshot.discoveryWasIncomplete,
        appVersion: snapshot.appVersion,
        storageFormatVersion: snapshot.storageFormatVersion
    )
}

struct SequenceOutcome {
    let result: AppGroupData
    let computations: Int
    let reuses: Int
    let lookups: Int
}

/// The production pass order: scan completion, pre-write, post-write read-back,
/// widget projection — the same four derivations `ScanScheduler` performs for
/// one scan generation.
func runSequence(
    _ data: AppGroupData,
    pinnedIDs: Set<String>,
    sharingOneScope: Bool
) -> SequenceOutcome {
    let shared = sharingOneScope ? RepositoryIdentity.CanonicalizationScope() : nil
    var computed = 0
    var reused = 0
    var lookups = 0
    var result = data
    func run(_ body: (AppGroupData) -> AppGroupData) {
        let scope = shared ?? RepositoryIdentity.CanonicalizationScope()
        result = RepositoryIdentity.withCanonicalizationScopeSync(scope) { body(result) }
        if shared == nil {
            let metrics = scope.metrics
            computed += metrics.computations
            reused += metrics.reuses
            lookups += metrics.lookups
        }
    }
    for _ in 0..<3 { run { applyPinsLike($0, pinnedIDs: pinnedIDs) } }
    run { RepositoryScope.filtering($0, excluding: []) }
    if let shared {
        let metrics = shared.metrics
        return SequenceOutcome(
            result: result,
            computations: metrics.computations,
            reuses: metrics.reuses,
            lookups: metrics.lookups
        )
    }
    return SequenceOutcome(result: result, computations: computed, reuses: reused, lookups: lookups)
}

// MARK: - Measurement helpers

func fingerprint(_ data: AppGroupData) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let bytes = try? encoder.encode(data) else { return "unavailable" }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(16).description
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[sorted.count / 2]
}

func uptimeNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

// MARK: - Main

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("devpulse-post-scan-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: root) }

print("BENCH repos=\(repositoryCounts.map(String.init).joined(separator: ",")) "
      + "iterations=\(iterations) warmup=\(warmupIterations)")

for count in repositoryCounts {
    let data = fixtureSnapshot(paths: makeFixturePaths(count, root: root))
    let pinnedIDs: Set<String> = Set((0..<count).filter { $0 % 20 == 0 }.map { "repo-\($0)" })

    func stage(
        _ name: String,
        _ body: () -> SequenceOutcome
    ) {
        var outcome = body()
        for _ in 0..<warmupIterations { outcome = body() }
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = uptimeNanoseconds()
            outcome = body()
            samples.append(Double(uptimeNanoseconds() - start) / 1_000_000.0)
        }
        print(String(
            format: "STAGE %@ repos=%d median_ms=%.4f min_ms=%.4f lookups=%d computations=%d reuses=%d fingerprint=%@",
            name,
            count,
            median(samples),
            samples.min() ?? 0,
            outcome.lookups,
            outcome.computations,
            outcome.reuses,
            fingerprint(outcome.result)
        ))
    }

    stage("one_pass_own_scope") {
        var result = data
        let scope = RepositoryIdentity.CanonicalizationScope()
        result = RepositoryIdentity.withCanonicalizationScopeSync(scope) {
            applyPinsLike(data, pinnedIDs: pinnedIDs)
        }
        let metrics = scope.metrics
        return SequenceOutcome(
            result: result,
            computations: metrics.computations,
            reuses: metrics.reuses,
            lookups: metrics.lookups
        )
    }
    stage("sequence_per_pass_scope") {
        runSequence(data, pinnedIDs: pinnedIDs, sharingOneScope: false)
    }
    stage("sequence_shared_scope") {
        runSequence(data, pinnedIDs: pinnedIDs, sharingOneScope: true)
    }
}
SWIFT

compile_and_run() {
    local label="$1"
    local binary="$TMP_DIR/bench-$label"
    local sources=()
    local relative
    for relative in "${SOURCES[@]}"; do
        sources+=("$ROOT_DIR/$relative")
    done
    xcrun swiftc \
        -O \
        -whole-module-optimization \
        -sdk "$SDK_PATH" \
        -target arm64-apple-macosx14.0 \
        -module-cache-path "$MODULE_CACHE" \
        -o "$binary" \
        "${sources[@]}" \
        "$HARNESS" \
        2> "$TMP_DIR/compile-$label.log" || {
            echo "error: compilation failed (log: $TMP_DIR/compile-$label.log)" >&2
            tail -30 "$TMP_DIR/compile-$label.log" >&2
            return 1
        }
    "$binary" > "$TMP_DIR/$label.out"
}

echo "Post-scan derivation benchmark"
echo "  repos=${BENCH_REPOS} iterations=${BENCH_ITERATIONS} warmup=${BENCH_WARMUP} runs=${BENCH_RUNS}"
echo

for run in $(seq 1 "$BENCH_RUNS"); do
    compile_and_run "run$run"
done

# Per-run medians of the per-iteration medians, so a single slow run cannot
# dominate the comparison.
python3 - "$TMP_DIR" "$BENCH_RUNS" "${BENCH_REPOS// / }" <<'PY'
import statistics
import sys
from collections import defaultdict

tmp_dir, runs, repo_list = sys.argv[1], int(sys.argv[2]), sys.argv[3].split()
stages = ("one_pass_own_scope", "sequence_per_pass_scope", "sequence_shared_scope")

samples = defaultdict(lambda: defaultdict(list))
fingerprints = defaultdict(set)
ledgers = {}
for run in range(1, runs + 1):
    with open(f"{tmp_dir}/run{run}.out") as handle:
        for line in handle:
            if not line.startswith("STAGE "):
                continue
            fields = dict(
                part.split("=", 1) for part in line.split()[1:] if "=" in part
            )
            name = line.split()[1]
            repos = fields["repos"]
            samples[(repos, name)][run].append(float(fields["median_ms"]))
            fingerprints[(repos, name)].add(fields["fingerprint"])
            ledgers[(repos, name)] = (
                int(fields["lookups"]),
                int(fields["computations"]),
                int(fields["reuses"]),
            )

print(f"{'repos':>6}  {'stage':<24} {'median_ms':>10} {'min_ms':>9} {'lookups':>8} {'computations':>13} {'reuses':>7}")
per_run = defaultdict(list)
for repos in repo_list:
    for name in stages:
        values = [statistics.median(v) for v in samples[(repos, name)].values()]
        flat = [x for v in samples[(repos, name)].values() for x in v]
        per_run[(repos, name)] = values
        lookups, computations, reuses = ledgers[(repos, name)]
        print(f"{repos:>6}  {name:<24} {statistics.median(values):>10.4f} {min(flat):>9.4f} "
              f"{lookups:>8} {computations:>13} {reuses:>7}")

print()
failures = []
for repos in repo_list:
    count = int(repos)
    per_pass = ledgers[(repos, "sequence_per_pass_scope")]
    shared = ledgers[(repos, "sequence_shared_scope")]
    if per_pass[0] != shared[0]:
        failures.append(f"repos={repos}: lookups differ ({per_pass[0]} vs {shared[0]})")
    if per_pass[1] != count * 4:
        failures.append(f"repos={repos}: per-pass computations {per_pass[1]} != 4x{count}")
    if shared[1] != count:
        failures.append(f"repos={repos}: shared computations {shared[1]} != {count}")
    if fingerprints[(repos, "sequence_per_pass_scope")] != fingerprints[(repos, "sequence_shared_scope")]:
        failures.append(
            f"repos={repos}: output fingerprints differ "
            f"({sorted(fingerprints[(repos, 'sequence_per_pass_scope')])} vs "
            f"{sorted(fingerprints[(repos, 'sequence_shared_scope')])})"
        )
    print(f"repos={repos} resolution_ledger per_pass={per_pass[1]} shared={shared[1]} "
          f"saved={per_pass[1] - shared[1]} fingerprint="
          f"{sorted(fingerprints[(repos, 'sequence_shared_scope')])[0]}")

if failures:
    for failure in failures:
        print(f"EQUIVALENCE/LEDGER MISMATCH: {failure}", file=sys.stderr)
    sys.exit(1)
print("equivalence=identical ledger=as_expected")
PY

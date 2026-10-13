#!/usr/bin/env bash
# A/B benchmark for the post-scan shared-snapshot persistence chain:
# SharedSnapshotStore.load() / commit(), the production
# "read revision -> commit" sequence ScanScheduler performs per refresh, and the
# raw I/O primitives those operations are built from.
#
# Runs a standalone harness against the current source and, with a baseline root
# or git ref, against that revision as well. Both variants are compiled with the
# same `swiftc -O -whole-module-optimization` invocation and run alternately.
#
# Usage:
#   ./scripts/benchmark-snapshot-persistence.sh
#   ./scripts/benchmark-snapshot-persistence.sh --baseline-git <ref>
#   BASELINE_ROOT=<path-to-checkout> ./scripts/benchmark-snapshot-persistence.sh
#
# Tunables (env): BENCH_REPOS (space separated list), BENCH_ITERATIONS,
#                 BENCH_WARMUP, BENCH_RUNS, BENCH_ROOT
#
# Every stage prints a SHA-256 fingerprint of the committed payload built from a
# canonical (formatting-independent) re-encode, so equal fingerprints across
# variants prove the commit produced identical shared data. Each stage also
# reports the F_FULLFSYNC/write ledger and whether the primary and recovery copy
# are byte-identical afterwards, which is the recovery invariant the optimization
# must not change.
#
# `io_*` stages exist to attribute the commit cost: they measure the raw
# primitives (payload write + F_FULLFSYNC, rename + directory F_FULLFSYNC,
# directory F_FULLFSYNC with nothing pending) that the store composes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE_ROOT="${BASELINE_ROOT:-}"

BENCH_REPOS="${BENCH_REPOS:-8 60 240}"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-15}"
BENCH_WARMUP="${BENCH_WARMUP:-3}"
BENCH_RUNS="${BENCH_RUNS:-3}"
export BENCH_REPOS BENCH_ITERATIONS BENCH_WARMUP

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-snapshot-bench.XXXXXX")"
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
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -n "$BASELINE_ROOT" && ! -d "$BASELINE_ROOT" ]]; then
    echo "error: baseline root not found: $BASELINE_ROOT" >&2
    exit 2
fi

HARNESS="$TMP_DIR/bench-snapshot-persistence.swift"
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
    "DevPulseNative/Core/SharedSnapshotStore.swift"
)

cat > "$HARNESS" <<'SWIFT'
import CryptoKit
import Darwin
import Foundation

// MARK: - Tunables

func environmentInt(_ key: String, _ fallback: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw), value > 0 else {
        return fallback
    }
    return value
}

let repositoryCounts = (ProcessInfo.processInfo.environment["BENCH_REPOS"] ?? "8 60 240")
    .split(whereSeparator: { $0 == " " || $0 == "," })
    .compactMap { Int($0) }
    .filter { $0 > 0 }
let iterations = environmentInt("BENCH_ITERATIONS", 15)
let warmupIterations = environmentInt("BENCH_WARMUP", 3)
let label = ProcessInfo.processInfo.environment["BENCH_LABEL"] ?? "current"
let rootOverride = ProcessInfo.processInfo.environment["BENCH_ROOT"] ?? ""

// MARK: - Fixture
//
// A deterministic payload shaped like a real `repositories.json`: canonical
// `YYYY-MM-DDTHH:MM:SSZ` timestamps (the shape the app writes), realistic
// absolute paths, branch names, commit summaries, change previews and a mix of
// clean / changed / error repositories.

let fixtureTimestamp = "2026-10-13T18:05:27Z"

func fixtureRepository(_ index: Int, sequence: Int) -> RepositorySnapshot {
    let status: RepositoryStatus
    switch index % 8 {
    case 0, 1, 2, 3: status = .clean
    case 5: status = .error
    default: status = .changed
    }
    let isClean = status == .clean
    let isError = status == .error
    let changedCount = isClean ? 0 : (index % 13) + 1
    let previewCount = min(changedCount, 5)
    let preview = (0..<previewCount).map { "File\(index)-\($0).swift" }
    let risk: RiskLevel
    switch index % 5 {
    case 0, 1: risk = .high
    case 2: risk = .medium
    default: risk = .low
    }
    return RepositorySnapshot(
        id: "repo-v1-\(String(format: "%064x", UInt(index) &* 0x9E37_79B9_7F4A_7C15 &+ UInt(sequence)))",
        name: "repository-with-a-realistic-name-\(index)",
        path: "/Users/example/Developer/Workspaces/team-\(index % 7)/repository-with-a-realistic-name-\(index)",
        workspaceKind: index % 4 == 0 ? .standalone : (index % 4 == 1 ? .linkedWorktree : nil),
        branch: index % 6 == 0
            ? "detached"
            : (index % 3 == 0 ? "feature/long-feature-branch-name-\(index)" : "main"),
        status: status,
        modifiedFileCount: isClean ? 0 : changedCount / 2,
        addedFileCount: isClean ? 0 : changedCount - changedCount / 2,
        deletedFileCount: 0,
        untrackedFileCount: 0,
        stagedFileCount: isClean ? 0 : changedCount / 3,
        unstagedFileCount: isClean ? 0 : changedCount - changedCount / 3,
        conflictedFileCount: 0,
        aheadCount: index % 5,
        behindCount: index % 3,
        hasUpstream: index % 6 != 0,
        changedFileCount: changedCount,
        changedFilesPreview: preview,
        risk: risk,
        lastScannedAt: fixtureTimestamp,
        dataSource: isError ? .lastSuccessful : .current,
        lastSuccessfulScanAt: fixtureTimestamp,
        lastChangedAt: isClean ? nil : "2026-10-13T12:43:33+08:00",
        lastCommitID: String(format: "%040x", UInt(index)),
        lastCommitSummary: "Merge pull request #5479 from deepseek-harness/worktree/release-\(index)",
        lastCommitMetadataAvailable: true,
        lastActivityAt: fixtureTimestamp,
        unavailableSince: nil,
        errorMessage: isError ? "git status timed out after 30.0s" : nil,
        isPinned: index % 11 == 0
    )
}

func fixtureSnapshot(repositoryCount: Int, sequence: Int) -> AppGroupData {
    let repositories = (0..<repositoryCount).map { fixtureRepository($0, sequence: sequence) }
    let events = (0..<min(repositoryCount, 20)).map { index in
        ActivityEventSummary(
            id: "activity-v1-\(String(format: "%064x", UInt(index) &* 31 &+ UInt(sequence)))",
            repositoryID: repositories[index].id,
            repositoryName: repositories[index].name,
            kind: .newCommit,
            occurredAt: fixtureTimestamp,
            message: "fix: enforce the bound in the canonical timestamp fast path → perf: encode repository identity digests",
            priority: 2
        )
    }
    return AppGroupData(
        schemaVersion: RepositorySnapshotSchema.version,
        generatedAt: fixtureTimestamp,
        writtenAt: nil,
        lastSuccessfulRefreshAt: fixtureTimestamp,
        historySchemaVersion: nil,
        historyRecordingEnabled: true,
        scanSummary: ScanSummary.build(from: repositories, totalRepositories: repositories.count),
        repositories: repositories,
        recentActivityEvents: events,
        repositoryUnavailableSinceByPath: nil,
        storageRevision: 0,
        persistenceState: .committed,
        pendingItemWidgetSummary: PendingItemWidgetSummary(
            totalCount: 16,
            criticalCount: 0,
            highCount: 15,
            mediumCount: 0,
            topItemTitle: "工作区存在长期改动",
            topItemSeverity: .high
        ),
        isRefreshing: false,
        discoveryWasIncomplete: false,
        appVersion: RepositorySnapshotSchema.currentAppVersion,
        storageFormatVersion: RepositorySnapshotSchema.storageFormatVersion
    )
}

// MARK: - Process accounting

func processUsage() -> rusage {
    var value = rusage()
    getrusage(RUSAGE_SELF, &value)
    return value
}

func cpuSeconds(_ usage: rusage) -> Double {
    Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
}

// MARK: - Operation ledger

struct OperationTally {
    var jsonDecode = 0
    var jsonEncode = 0
    var fileWrite = 0
    var fileSync = 0
    var directorySync = 0

    mutating func record(_ operation: SharedSnapshotStoreOperation) {
        switch operation {
        case .jsonDecode: jsonDecode += 1
        case .jsonEncode: jsonEncode += 1
        case .fileWrite: fileWrite += 1
        case .fullFileSync: fileSync += 1
        case .fullDirectorySync: directorySync += 1
        }
    }
}

final class OperationRecorder {
    private let lock = NSLock()
    private var tally = OperationTally()

    func record(_ operation: SharedSnapshotStoreOperation) {
        lock.lock()
        tally.record(operation)
        lock.unlock()
    }

    var snapshot: OperationTally {
        lock.lock()
        defer { lock.unlock() }
        return tally
    }

    func reset() {
        lock.lock()
        tally = OperationTally()
        lock.unlock()
    }
}

// MARK: - Stage runner

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Formatting-independent digest: identical shared data always produces the same
/// digest no matter how the file itself is laid out.
func canonicalFingerprint(_ snapshot: AppGroupData) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(sha256(try encoder.encode(snapshot)).prefix(16))
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 0
        ? (sorted[middle - 1] + sorted[middle]) / 2
        : sorted[middle]
}

func makeArea() throws -> URL {
    let base = rootOverride.isEmpty
        ? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        : URL(fileURLWithPath: rootOverride, isDirectory: true)
    let url = base.appendingPathComponent("devpulse-snapshot-bench-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeStore(in directory: URL, recorder: OperationRecorder) -> SharedSnapshotStore {
    // The clock is fixed so the committed payload — and therefore the
    // equivalence fingerprint — is deterministic across variants. Every
    // timestamp comparison the commit performs still runs; only the observed
    // wall-clock value is held constant.
    SharedSnapshotStore(
        directoryURL: directory,
        fileName: "repositories.json",
        now: { benchmarkClock },
        operationObserver: { recorder.record($0) }
    )
}

let benchmarkClock = Date(timeIntervalSince1970: 1_784_253_600)

func requireSuccess(_ result: Result<AppGroupData, AppGroupStoreError>) throws -> AppGroupData {
    switch result {
    case .success(let value): return value
    case .failure(let error): throw error
    }
}

struct StageOutcome {
    var fingerprint = ""
    var recoveryCopyIsIdentical = false
}

func runStage(
    _ name: String,
    repositoryCount: Int,
    payloadBytes: Int,
    setup: (SharedSnapshotStore, URL) throws -> Void,
    perIterationSetup: (SharedSnapshotStore, URL, Int) throws -> Void = { _, _, _ in },
    body: (SharedSnapshotStore, URL, Int) throws -> AppGroupData
) throws {
    let directory = try makeArea()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = OperationRecorder()
    let store = makeStore(in: directory, recorder: recorder)
    try setup(store, directory)

    var wallSamples: [Double] = []
    var cpuSamples: [Double] = []
    var blocksInSamples: [Double] = []
    var blocksOutSamples: [Double] = []
    var tally = OperationTally()
    var outcome = StageOutcome()

    for index in 0..<(iterations + warmupIterations) {
        try perIterationSetup(store, directory, index)
        recorder.reset()
        let usageBefore = processUsage()
        let clockBefore = ProcessInfo.processInfo.systemUptime
        let result = try body(store, directory, index)
        let clockAfter = ProcessInfo.processInfo.systemUptime
        let usageAfter = processUsage()
        if index >= warmupIterations {
            wallSamples.append((clockAfter - clockBefore) * 1000)
            cpuSamples.append((cpuSeconds(usageAfter) - cpuSeconds(usageBefore)) * 1000)
            blocksInSamples.append(Double(usageAfter.ru_inblock) - Double(usageBefore.ru_inblock))
            blocksOutSamples.append(Double(usageAfter.ru_oublock) - Double(usageBefore.ru_oublock))
            tally = recorder.snapshot
            outcome.fingerprint = try canonicalFingerprint(result)
        }
    }

    // Captured after the sampling window so it cannot pollute the next sample.
    if let primaryBytes = try? Data(contentsOf: store.primaryURL),
       let backupBytes = try? Data(contentsOf: store.backupURL) {
        outcome.recoveryCopyIsIdentical = primaryBytes == backupBytes
    }

    var line = "STAGE \(name) repos=\(repositoryCount)"
    line += " wall_ms=\(String(format: "%.4f", median(wallSamples)))"
    line += " cpu_ms=\(String(format: "%.4f", median(cpuSamples)))"
    line += " blocks_in=\(String(format: "%.1f", median(blocksInSamples)))"
    line += " blocks_out=\(String(format: "%.1f", median(blocksOutSamples)))"
    line += " json_decodes=\(tally.jsonDecode)"
    line += " json_encodes=\(tally.jsonEncode)"
    line += " file_writes=\(tally.fileWrite)"
    line += " file_syncs=\(tally.fileSync)"
    line += " dir_syncs=\(tally.directorySync)"
    line += " payload_bytes=\(payloadBytes)"
    line += " recovery_copy_identical=\(outcome.recoveryCopyIsIdentical ? 1 : 0)"
    line += " fingerprint=\(outcome.fingerprint)"
    print(line)
}

// MARK: - Raw I/O primitives (cost attribution only; not production code paths)

func rawSynchronize(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw POSIXError(.ENOENT) }
    defer { Darwin.close(descriptor) }
    if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    if Darwin.fsync(descriptor) == 0 { return }
    throw POSIXError(.EIO)
}

func rawAtomicWrite(payload: Data, in directory: URL, name: String) throws {
    let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
    let destination = directory.appendingPathComponent(name)
    try payload.write(to: temporary, options: [.withoutOverwriting])
    try rawSynchronize(temporary)
    guard Darwin.rename(temporary.path, destination.path) == 0 else { throw POSIXError(.EIO) }
    try rawSynchronize(directory)
}

func rawWriteSynchronizeOnly(payload: Data, in directory: URL) throws {
    let url = directory.appendingPathComponent(".sync-\(UUID().uuidString)")
    try payload.write(to: url, options: [.withoutOverwriting])
    try rawSynchronize(url)
    try? FileManager.default.removeItem(at: url)
}

func rawWriteSynchronizeRename(payload: Data, in directory: URL, name: String) throws {
    let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
    let destination = directory.appendingPathComponent(name)
    try payload.write(to: temporary, options: [.withoutOverwriting])
    try rawSynchronize(temporary)
    guard Darwin.rename(temporary.path, destination.path) == 0 else { throw POSIXError(.EIO) }
}

// MARK: - Main

@main
struct SnapshotPersistenceBenchmark {
    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        print(
            "BENCH label=\(label) iterations=\(iterations) warmup=\(warmupIterations) "
                + "root=\(rootOverride.isEmpty ? NSTemporaryDirectory() : rootOverride) "
                + "clock=\(Int(benchmarkClock.timeIntervalSince1970))"
        )

        for repositoryCount in repositoryCounts {
            let seedPayload = fixtureSnapshot(repositoryCount: repositoryCount, sequence: 0)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payloadBytes = try encoder.encode(seedPayload).count

            // Widget / app read path in the steady state left by a commit:
            // primary and recovery copy are byte-identical, so both files are
            // read but the payload is decoded once.
            try runStage(
                "load_steady",
                repositoryCount: repositoryCount,
                payloadBytes: payloadBytes,
                setup: { store, _ in
                    _ = try requireSuccess(store.commit(seedPayload))
                },
                body: { store, _, _ in
                    switch store.load() {
                    case .success(let read): return read.snapshot
                    case .failure(let error): throw error
                    }
                }
            )

            // The production ScanScheduler sequence: read the on-disk revision,
            // then commit the refreshed payload with that observed revision.
            try runStage(
                "read_then_commit",
                repositoryCount: repositoryCount,
                payloadBytes: payloadBytes,
                setup: { store, _ in
                    _ = try requireSuccess(store.commit(seedPayload))
                },
                body: { store, _, index in
                    let observed: UInt64
                    switch store.load() {
                    case .success(let read): observed = read.snapshot.storageRevision
                    case .failure(let error): throw error
                    }
                    return try requireSuccess(
                        store.commit(
                            fixtureSnapshot(repositoryCount: repositoryCount, sequence: index + 1),
                            observedStorageRevision: observed
                        )
                    )
                }
            )

            try runStage(
                "commit_only",
                repositoryCount: repositoryCount,
                payloadBytes: payloadBytes,
                setup: { store, _ in
                    _ = try requireSuccess(store.commit(seedPayload))
                },
                body: { store, _, index in
                    try requireSuccess(
                        store.commit(fixtureSnapshot(repositoryCount: repositoryCount, sequence: index + 1))
                    )
                }
            )

            // Divergent but valid recovery copy: the store must keep the
            // pre-commit safeguard instead of the byte-identical fast path.
            try runStage(
                "commit_divergent_recovery_copy",
                repositoryCount: repositoryCount,
                payloadBytes: payloadBytes,
                setup: { store, directory in
                    _ = try requireSuccess(store.commit(seedPayload))
                    let alternate = directory.appendingPathComponent("alternate", isDirectory: true)
                    try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
                    let alternateStore = makeStore(in: alternate, recorder: OperationRecorder())
                    _ = try requireSuccess(
                        alternateStore.commit(
                            fixtureSnapshot(repositoryCount: repositoryCount, sequence: 9_000)
                        )
                    )
                    try Data(contentsOf: alternateStore.primaryURL)
                        .write(to: directory.appendingPathComponent("divergent.bin"))
                },
                perIterationSetup: { store, directory, _ in
                    try Data(contentsOf: directory.appendingPathComponent("divergent.bin"))
                        .write(to: store.backupURL)
                },
                body: { store, _, index in
                    try requireSuccess(
                        store.commit(fixtureSnapshot(repositoryCount: repositoryCount, sequence: index + 1))
                    )
                }
            )

            // Recovery path: the primary is gone before the commit, so the
            // recovery copy is the only baseline.
            try runStage(
                "commit_after_primary_loss",
                repositoryCount: repositoryCount,
                payloadBytes: payloadBytes,
                setup: { store, _ in
                    _ = try requireSuccess(store.commit(seedPayload))
                },
                perIterationSetup: { store, _, _ in
                    try? FileManager.default.removeItem(at: store.primaryURL)
                },
                body: { store, _, index in
                    try requireSuccess(
                        store.commit(fixtureSnapshot(repositoryCount: repositoryCount, sequence: index + 1))
                    )
                }
            )

            try runStage(
                "json_encode",
                repositoryCount: repositoryCount,
                payloadBytes: payloadBytes,
                setup: { _, _ in },
                body: { _, _, _ in
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    _ = try encoder.encode(seedPayload)
                    return seedPayload
                }
            )

            try runStage(
                "json_decode_full",
                repositoryCount: repositoryCount,
                payloadBytes: payloadBytes,
                setup: { _, _ in },
                body: { _, _, _ in
                    let decoder = JSONDecoder()
                    return try decoder.decode(AppGroupData.self, from: try encoder.encode(seedPayload))
                }
            )

            try runStage(
                "json_decode_version_header",
                repositoryCount: repositoryCount,
                payloadBytes: payloadBytes,
                setup: { _, _ in },
                body: { _, _, _ in
                    let bytes = try encoder.encode(seedPayload)
                    let decoder = JSONDecoder()
                    _ = try decoder.decode(SnapshotVersionHeader.self, from: bytes)
                    return try decoder.decode(AppGroupData.self, from: bytes)
                }
            )

            try runStage(
                "io_atomic_write",
                repositoryCount: repositoryCount,
                payloadBytes: payloadBytes,
                setup: { _, _ in },
                body: { _, directory, index in
                    try rawAtomicWrite(
                        payload: try encoder.encode(
                            fixtureSnapshot(repositoryCount: repositoryCount, sequence: index)
                        ),
                        in: directory,
                        name: "target-atomic"
                    )
                    return seedPayload
                }
            )

            try runStage(
                "io_write_sync_rename_only",
                repositoryCount: repositoryCount,
                payloadBytes: payloadBytes,
                setup: { _, _ in },
                body: { _, directory, index in
                    try rawWriteSynchronizeRename(
                        payload: try encoder.encode(
                            fixtureSnapshot(repositoryCount: repositoryCount, sequence: index)
                        ),
                        in: directory,
                        name: "target-no-flush"
                    )
                    return seedPayload
                }
            )

            try runStage(
                "io_write_sync_only",
                repositoryCount: repositoryCount,
                payloadBytes: payloadBytes,
                setup: { _, _ in },
                body: { _, directory, index in
                    try rawWriteSynchronizeOnly(
                        payload: try encoder.encode(
                            fixtureSnapshot(repositoryCount: repositoryCount, sequence: index)
                        ),
                        in: directory
                    )
                    return seedPayload
                }
            )
        }
    }
}
SWIFT

compile() {
    local label="$1"
    local root="$2"
    local binary="$TMP_DIR/bench-$label"
    local sources=()
    local relative
    for relative in "${SOURCES[@]}"; do
        sources+=("$root/$relative")
    done
    xcrun swiftc \
        -O \
        -whole-module-optimization \
        -swift-version 6 \
        -parse-as-library \
        -sdk "$SDK_PATH" \
        -target arm64-apple-macosx14.0 \
        -module-cache-path "$MODULE_CACHE" \
        -o "$binary" \
        "${sources[@]}" \
        "$HARNESS" \
        2> "$TMP_DIR/compile-$label.log" || {
            echo "error: compilation failed for $label (log: $TMP_DIR/compile-$label.log)" >&2
            tail -30 "$TMP_DIR/compile-$label.log" >&2
            return 1
        }
}

run_variant() {
    local variant="$1"
    BENCH_LABEL="$variant" "$TMP_DIR/bench-$variant" >> "$TMP_DIR/$variant.out"
}

echo "Shared snapshot persistence benchmark"
echo "  repos=${BENCH_REPOS} iterations=${BENCH_ITERATIONS} warmup=${BENCH_WARMUP} runs=${BENCH_RUNS}"
echo

if [[ -z "$BASELINE_ROOT" ]]; then
    compile current "$ROOT_DIR"
    run_variant current
    cat "$TMP_DIR/current.out"
    exit 0
fi

compile baseline "$BASELINE_ROOT"
compile current "$ROOT_DIR"
: > "$TMP_DIR/baseline.out"
: > "$TMP_DIR/current.out"

for (( run = 1; run <= BENCH_RUNS; run++ )); do
    # Alternate which variant runs first so drift in machine load cancels out.
    if (( run % 2 == 1 )); then
        run_variant baseline
        run_variant current
    else
        run_variant current
        run_variant baseline
    fi
done

# Aggregate the per-run medians into a per-(stage, repos) median of medians and
# report the paired delta. Failures are loud: a stage present in only one
# variant is an error, not a silent omission.
python3 - "$TMP_DIR/baseline.out" "$TMP_DIR/current.out" <<'PY'
import collections
import statistics
import sys

def load(path):
    stages = collections.defaultdict(list)
    for line in open(path, encoding="utf-8"):
        if not line.startswith("STAGE "):
            continue
        fields = dict(part.split("=", 1) for part in line.split()[2:])
        fields["stage"] = line.split()[1]
        stages[(fields["stage"], int(fields["repos"]))].append(fields)
    return stages

baseline = load(sys.argv[1])
current = load(sys.argv[2])

keys = sorted(baseline, key=lambda item: (int(item[1]), item[0]))
missing = [key for key in keys if key not in current] + [key for key in current if key not in baseline]
if missing:
    raise SystemExit(f"error: stages differ between variants: {missing}")

def value(runs, field):
    return statistics.median(float(run[field]) for run in runs)

# Behaviour equivalence is a gate, not a printed observation.
#
# Two independent checks, both fatal on failure:
#   1. Per variant: every stage that ends in a commit must leave `primary` and
#      the recovery copy byte-identical. This is the recovery invariant, so it
#      has to hold in each variant on its own — two identically broken variants
#      would still pass a purely comparative check.
#   2. Across variants: the canonical payload fingerprint must match, so the
#      change provably commits identical shared data.
RECOVERY_INVARIANT_PREFIXES = ("load_", "read_", "commit_")
mismatches = []
recovery_stages = 0
for key in keys:
    base_run = baseline[key][-1]
    new_run = current[key][-1]
    if base_run["fingerprint"] != new_run["fingerprint"]:
        mismatches.append(
            f"{key[0]}/{key[1]}: fingerprint {base_run['fingerprint']} != {new_run['fingerprint']}"
        )
    if base_run["recovery_copy_identical"] != new_run["recovery_copy_identical"]:
        mismatches.append(
            f"{key[0]}/{key[1]}: recovery_copy_identical "
            f"{base_run['recovery_copy_identical']} != {new_run['recovery_copy_identical']}"
        )
    if key[0].startswith(RECOVERY_INVARIANT_PREFIXES):
        recovery_stages += 1
        for variant, run in (("baseline", base_run), ("current", new_run)):
            if run["recovery_copy_identical"] != "1":
                mismatches.append(
                    f"{key[0]}/{key[1]}: {variant} left primary and recovery copy "
                    f"byte-different (recovery_copy_identical={run['recovery_copy_identical']})"
                )

print(f"{'stage':<32}{'repos':>6}{'base ms':>10}{'new ms':>10}{'delta':>10}{'base cpu':>10}{'new cpu':>10}"
      f"{'syncs b':>9}{'syncs n':>9}{'writes b':>9}{'writes n':>9}{'identical':>11}{'fingerprint':>18}")
for key in keys:
    base_runs = baseline[key]
    new_runs = current[key]
    base_ms = value(base_runs, "wall_ms")
    new_ms = value(new_runs, "wall_ms")
    delta = (new_ms - base_ms) / base_ms * 100 if base_ms else 0.0
    base_syncs = int(base_runs[-1]["file_syncs"]) + int(base_runs[-1]["dir_syncs"])
    new_syncs = int(new_runs[-1]["file_syncs"]) + int(new_runs[-1]["dir_syncs"])
    identical = (
        base_runs[-1]["recovery_copy_identical"],
        new_runs[-1]["recovery_copy_identical"],
    )
    fingerprint = (
        f"{base_runs[-1]['fingerprint'][:8]}/{new_runs[-1]['fingerprint'][:8]}"
    )
    print(f"{key[0]:<32}{key[1]:>6}{base_ms:>10.3f}{new_ms:>10.3f}{delta:>9.1f}%"
          f"{value(base_runs, 'cpu_ms'):>10.3f}{value(new_runs, 'cpu_ms'):>10.3f}"
          f"{base_syncs:>9}{new_syncs:>9}{base_runs[-1]['file_writes']:>9}{new_runs[-1]['file_writes']:>9}"
          f"{identical[0] + '/' + identical[1]:>11}{fingerprint:>18}")

print()
if mismatches:
    for mismatch in mismatches:
        print(f"EQUIVALENCE MISMATCH: {mismatch}", file=sys.stderr)
    raise SystemExit("error: the variants did not produce identical shared data")
print(
    f"equivalence=identical stages={len(keys)} recovery_invariant_stages={recovery_stages} "
    f"runs={len(baseline[keys[0]])} fingerprints=matched recovery_copy=identical"
)
PY

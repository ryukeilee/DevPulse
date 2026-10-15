#!/usr/bin/env bash
# A/B benchmark + equivalence harness for `ActivityEventDeduplicator.newEvents`.
#
# `ScanScheduler.recordActivityEvents` calls `newEvents(from:comparedTo:)` once
# per refresh round with the whole activity archive (bounded by
# `ActivityEventStore.defaultCapacity`, 500) and the events one round detected.
# The previous implementation re-sorted that whole archive after every accepted
# candidate and then scanned it linearly:
#
#   legacy   history = sorted(existing); per candidate: linear scan + re-sort
#   indexed  fold `existing` into a newest-per-(repository, family) index once
#
# This harness compiles the same fixture against two `ActivityEvent.swift`
# revisions — the current tree and a baseline git ref — and prints, per case,
# the mean milliseconds and a content fingerprint of the accepted events. Equal
# fingerprints prove the accepted set, its order and its dedup decisions are
# unchanged; the wall-clock columns show the cost difference.
#
# It also runs randomized differential scenarios (out-of-order arrays, identical
# timestamps, exact replays, several candidates per family, cross-family kinds)
# and compares their fingerprint too. `BENCH_TIMESTAMP_SHAPE=mixed-invalid` adds
# unparseable timestamps to probe the ordering edge; that shape is reported
# separately because `ActivityEventOrdering.sorted` is only a total order when
# the timestamps are comparable.
#
# Usage:
#   ./scripts/benchmark-activity-event-dedup.sh
#   ./scripts/benchmark-activity-event-dedup.sh --baseline-git <ref>
#   BASELINE_ENGINE=<path-to-baseline-ActivityEvent.swift> \
#     ./scripts/benchmark-activity-event-dedup.sh
#
# Tunables (env): BENCH_ITERATIONS, BENCH_WARMUP, BENCH_SCENARIOS, BENCH_SEED,
#                 BENCH_TIMESTAMP_SHAPE
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EVENT_REL="DevPulseNative/Core/ActivityEvent.swift"
EVENT_FILE="$ROOT_DIR/$EVENT_REL"

BASELINE_ENGINE="${BASELINE_ENGINE:-}"
BASELINE_GIT="${BASELINE_GIT:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-git)
            [[ -n "${2:-}" ]] || { echo "error: --baseline-git requires a ref" >&2; exit 2; }
            BASELINE_GIT="$2"
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

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-dedup-bench.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ -z "$BASELINE_ENGINE" ]]; then
    [[ -n "$BASELINE_GIT" ]] || BASELINE_GIT="HEAD"
    BASELINE_ENGINE="$TMP_DIR/baseline-ActivityEvent.swift"
    git -C "$ROOT_DIR" show "$BASELINE_GIT:$EVENT_REL" > "$BASELINE_ENGINE"
fi
[[ -f "$BASELINE_ENGINE" ]] || { echo "error: baseline engine not found: $BASELINE_ENGINE" >&2; exit 2; }

HARNESS="$TMP_DIR/bench-activity-event-dedup.swift"
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

func envIntAllowZero(_ key: String, _ fallback: Int) -> Int {
    if let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw), value >= 0 {
        return value
    }
    return fallback
}

let iterations = envInt("BENCH_ITERATIONS", 300)
let warmupIterations = envInt("BENCH_WARMUP", 30)
let randomScenarios = envInt("BENCH_SCENARIOS", 400)
let seed = UInt64(envIntAllowZero("BENCH_SEED", 0x5EED_D3D0)) | 1
let timestampShape = ProcessInfo.processInfo.environment["BENCH_TIMESTAMP_SHAPE"] ?? "canonical"

// MARK: - Deterministic PRNG

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }
}

// MARK: - Fixture primitives

/// Canonical shape the app writes (`DateFormatting.nowISO()`), which takes the
/// arithmetic fast path. Fractional/invalid shapes take the formatter path.
let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

let fractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func timestamp(_ seconds: TimeInterval, shape: String) -> String {
    let date = Date(timeIntervalSince1970: seconds)
    switch shape {
    case "fractional": return fractionalFormatter.string(from: date)
    case "mixed-invalid":
        // Every fourth instant is deliberately unparseable, to probe the
        // ordering edge without changing the well-formed cases. The fixture uses
        // epoch multiples of 60, so `% 240` invalidates one instant in four
        // instead of all of them.
        return seconds.truncatingRemainder(dividingBy: 240) == 0
            ? "not-a-timestamp"
            : isoFormatter.string(from: date)
    default: return isoFormatter.string(from: date)
    }
}

func makeSnapshot(
    repositoryIndex: Int,
    variant: Int,
    modified: Int = 0,
    staged: Int = 0,
    conflicted: Int = 0,
    branch: String = "main",
    dataSource: RepositoryDataSource = .current,
    errorMessage: String? = nil
) -> RepositorySnapshot {
    let name = "repo-\(repositoryIndex)"
    return RepositorySnapshot(
        id: name,
        name: name,
        path: "/tmp/\(name)",
        branch: branch,
        status: .changed,
        modifiedFileCount: modified,
        addedFileCount: 0,
        deletedFileCount: 0,
        untrackedFileCount: 0,
        stagedFileCount: staged,
        unstagedFileCount: modified,
        conflictedFileCount: conflicted,
        aheadCount: 0,
        changedFileCount: modified,
        changedFilesPreview: [],
        risk: .low,
        lastScannedAt: timestamp(1_770_000_000, shape: "canonical"),
        dataSource: dataSource,
        lastChangedAt: nil,
        lastCommitID: "commit-\(repositoryIndex)-\(variant)",
        lastCommitSummary: "subject \(variant)",
        errorMessage: errorMessage,
        isPinned: false
    )
}

func makeEvent(
    id: String,
    repositoryIndex: Int,
    kind: ActivityEventKind,
    occurredAt: String,
    before: RepositorySnapshot,
    after: RepositorySnapshot
) -> ActivityEvent {
    ActivityEvent(
        id: id,
        repositoryID: "repo-\(repositoryIndex)",
        repositoryName: "repo-\(repositoryIndex)",
        kind: kind,
        occurredAt: occurredAt,
        before: ActivityEventState(snapshot: before),
        after: ActivityEventState(snapshot: after)
    )
}

/// State pair for a kind, so a "different" candidate really differs in
/// `before`/`after` for that kind's `summary(for:)` dimension.
func states(for kind: ActivityEventKind, variant: Int, repositoryIndex: Int)
    -> (before: RepositorySnapshot, after: RepositorySnapshot) {
    switch kind {
    case .newCommit:
        return (
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant * 2),
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant * 2 + 1)
        )
    case .workingTreeChanged:
        return (
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant, modified: variant),
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant, modified: variant + 1)
        )
    case .stagingChanged:
        return (
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant, staged: variant),
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant, staged: variant + 1)
        )
    case .branchChanged:
        return (
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant, branch: "main"),
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant, branch: "feature-\(variant)")
        )
    case .synchronizationChanged:
        return (
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant, modified: variant),
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant, modified: variant + 2)
        )
    case .conflictStarted, .conflictResolved:
        return (
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant, conflicted: variant),
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant, conflicted: variant + 1)
        )
    case .readFailed:
        return (
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant),
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant,
                         dataSource: .unknown, errorMessage: "boom-\(variant)")
        )
    case .readRecovered:
        return (
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant,
                         dataSource: .unknown, errorMessage: "boom-\(variant)"),
            makeSnapshot(repositoryIndex: repositoryIndex, variant: variant)
        )
    }
}

let familyKindPool: [ActivityEventKind] = [
    .newCommit, .workingTreeChanged, .stagingChanged, .branchChanged,
    .synchronizationChanged, .conflictStarted, .readFailed
]

let allKindPool: [ActivityEventKind] = [
    .newCommit, .workingTreeChanged, .stagingChanged, .branchChanged,
    .synchronizationChanged, .conflictStarted, .conflictResolved,
    .readFailed, .readRecovered
]

func familyKey(_ event: ActivityEvent) -> String {
    switch event.kind {
    case .conflictStarted, .conflictResolved: return "\(event.repositoryID)\u{1F}conflict"
    case .readFailed, .readRecovered: return "\(event.repositoryID)\u{1F}read"
    default: return "\(event.repositoryID)\u{1F}\(event.kind.rawValue)"
    }
}

// MARK: - Timing fixture

struct TimingCase {
    let label: String
    let history: Int
    let accepted: Int
    let replays: Int
    /// Hands the archive in the shape the app holds between rounds: the list
    /// the previous round produced, i.e. already sorted, de-duplicated and
    /// truncated. `false` keeps the shuffled archive the other cases use.
    var steadyState: Bool = false
}

let timingCases: [TimingCase] = [
    TimingCase(label: "quiet-round", history: 500, accepted: 0, replays: 5),
    TimingCase(label: "small-round", history: 500, accepted: 5, replays: 5),
    TimingCase(label: "busy-round", history: 500, accepted: 40, replays: 40),
    TimingCase(label: "bulk-round", history: 500, accepted: 200, replays: 200),
    TimingCase(label: "short-history", history: 100, accepted: 5, replays: 5),
    TimingCase(label: "steady-quiet", history: 500, accepted: 0, replays: 5, steadyState: true),
    TimingCase(label: "steady-small", history: 500, accepted: 5, replays: 5, steadyState: true),
    TimingCase(label: "steady-busy", history: 500, accepted: 40, replays: 40, steadyState: true),
    TimingCase(label: "steady-bulk", history: 500, accepted: 200, replays: 200, steadyState: true),
]

/// Sorts and de-duplicates `events` with a comparator written here rather than
/// with the engine's own, so both revisions receive byte-identical archives
/// even where their sorting differs. Mirrors `ActivityEventStore.normalized`
/// for the canonical shape the steady-state cases are built from.
func normalizedArchive(_ events: [ActivityEvent]) -> [ActivityEvent] {
    var byID: [String: ActivityEvent] = [:]
    byID.reserveCapacity(events.count)
    for event in events { byID[event.id] = event }
    return Array(byID.values).sorted { lhs, rhs in
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        let nameOrder = lhs.repositoryName.localizedStandardCompare(rhs.repositoryName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id < rhs.id
    }
}

/// Builds one deterministic `(existing, candidates)` pair with exactly
/// `accepted` genuinely-new candidates and `replays` exact replays of the
/// newest history entry of a family. Arrays are shuffled before being handed
/// in, so both implementations receive out-of-order input; a steady-state case
/// re-normalizes the archive afterwards instead.
func makeTimingFixture(_ timingCase: TimingCase, shape: String, seedOffset: UInt64)
    -> (existing: [ActivityEvent], candidates: [ActivityEvent]) {
    var rng = SplitMix64(seed: seed ^ seedOffset)
    let base = 1_770_000_000.0
    var existing: [ActivityEvent] = []
    var newestByFamily: [String: ActivityEvent] = [:]
    var nextID = 0

    // Distribute the history across 40 repositories, cycling families so a
    // repository usually has several families in flight.
    let repositories = max(1, min(40, timingCase.history))
    var index = 0
    while existing.count < timingCase.history {
        let repositoryIndex = index % repositories
        let kind = familyKindPool[(index / repositories) % familyKindPool.count]
        let variant = index / repositories
        let pair = states(for: kind, variant: variant, repositoryIndex: repositoryIndex)
        // Descending timestamps with occasional ties.
        let seconds = base - Double((index / 3) * 60)
        let event = makeEvent(
            id: "history-\(nextID)",
            repositoryIndex: repositoryIndex,
            kind: kind,
            occurredAt: timestamp(seconds, shape: shape),
            before: pair.before,
            after: pair.after
        )
        nextID += 1
        existing.append(event)
        let key = familyKey(event)
        if let current = newestByFamily[key] {
            if ActivityEventOrdering.sorted([event, current]).first?.id == event.id {
                newestByFamily[key] = event
            }
        } else {
            newestByFamily[key] = event
        }
        index += 1
    }

    var candidates: [ActivityEvent] = []
    // Sorted by family key: `Dictionary.values` iterates in a per-process
    // randomized order, which would hand the two binaries different fixtures.
    let replayPool = newestByFamily.keys.sorted().compactMap { newestByFamily[$0] }
    for replayIndex in 0..<timingCase.replays where !replayPool.isEmpty {
        let source = replayPool[replayIndex % replayPool.count]
        // Same kind/before/after, a newer timestamp and a fresh id: a replay.
        candidates.append(makeEvent(
            id: "replay-\(replayIndex)",
            repositoryIndex: Int(source.repositoryID.dropFirst("repo-".count)) ?? 0,
            kind: source.kind,
            occurredAt: timestamp(base + Double(replayIndex + 1) * 60, shape: shape),
            before: snapshotForState(source.before),
            after: snapshotForState(source.after)
        ))
    }
    for acceptedIndex in 0..<timingCase.accepted {
        let repositoryIndex = acceptedIndex % repositories
        let kind = allKindPool[acceptedIndex % allKindPool.count]
        let pair = states(for: kind, variant: 10_000 + acceptedIndex, repositoryIndex: repositoryIndex)
        candidates.append(makeEvent(
            id: "new-\(acceptedIndex)",
            repositoryIndex: repositoryIndex,
            kind: kind,
            occurredAt: timestamp(base + 3_600 + Double(acceptedIndex) * 60, shape: shape),
            before: pair.before,
            after: pair.after
        ))
    }

    existing.shuffle(using: &rng)
    candidates.shuffle(using: &rng)
    if timingCase.steadyState { existing = normalizedArchive(existing) }
    return (existing, candidates)
}

// MARK: - Fingerprint

func digest(_ events: [ActivityEvent]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = Data()
    for event in events {
        if let encoded = try? encoder.encode(event) {
            data.append(encoded)
        }
        data.append(0x0A)
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func checksum(_ events: [ActivityEvent]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for event in events {
        for byte in Array(event.id.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
    }
    return hash
}

// MARK: - Randomized differential scenarios

/// One adversarial scenario: out-of-order arrays, identical timestamps, exact
/// replays, several candidates per family and cross-family kinds.
func makeRandomScenario(rng: inout SplitMix64, shape: String)
    -> (existing: [ActivityEvent], candidates: [ActivityEvent]) {
    let base = 1_770_000_000.0
    let repositoryCount = 1 + rng.int(6)
    var existing: [ActivityEvent] = []
    var nextID = 0
    let existingCount = rng.int(40)
    for _ in 0..<existingCount {
        let repositoryIndex = rng.int(repositoryCount)
        let kind = allKindPool[rng.int(allKindPool.count)]
        let variant = rng.int(20)
        let pair = states(for: kind, variant: variant, repositoryIndex: repositoryIndex)
        // Only three distinct instants, so ties are common.
        let seconds = base - Double(rng.int(3)) * 60
        existing.append(makeEvent(
            id: "e-\(nextID)",
            repositoryIndex: repositoryIndex,
            kind: kind,
            occurredAt: timestamp(seconds, shape: shape),
            before: pair.before,
            after: pair.after
        ))
        nextID += 1
    }

    var candidates: [ActivityEvent] = []
    let candidateCount = rng.int(12)
    for _ in 0..<candidateCount {
        let repositoryIndex = rng.int(repositoryCount)
        let seconds = base - Double(rng.int(3)) * 60
        switch rng.int(3) {
        case 0 where !existing.isEmpty:
            // Exact replay of an existing event, with a new id/timestamp.
            let source = existing[rng.int(existing.count)]
            candidates.append(makeEvent(
                id: "r-\(nextID)",
                repositoryIndex: Int(source.repositoryID.dropFirst("repo-".count)) ?? 0,
                kind: source.kind,
                occurredAt: timestamp(seconds, shape: shape),
                before: snapshotForState(source.before),
                after: snapshotForState(source.after)
            ))
        case 1:
            // Same family as a random existing event, different state.
            let kind = rng.int(2) == 0 ? ActivityEventKind.conflictResolved : ActivityEventKind.readRecovered
            let pair = states(for: kind, variant: rng.int(20), repositoryIndex: repositoryIndex)
            candidates.append(makeEvent(
                id: "f-\(nextID)",
                repositoryIndex: repositoryIndex,
                kind: kind,
                occurredAt: timestamp(seconds, shape: shape),
                before: pair.before,
                after: pair.after
            ))
        default:
            let kind = allKindPool[rng.int(allKindPool.count)]
            let pair = states(for: kind, variant: rng.int(20), repositoryIndex: repositoryIndex)
            candidates.append(makeEvent(
                id: "c-\(nextID)",
                repositoryIndex: repositoryIndex,
                kind: kind,
                occurredAt: timestamp(seconds, shape: shape),
                before: pair.before,
                after: pair.after
            ))
        }
        nextID += 1
    }

    existing.shuffle(using: &rng)
    candidates.shuffle(using: &rng)
    return (existing, candidates)
}

/// Rebuilds a snapshot carrying the same event-relevant fields as `state`, so a
/// replay candidate compares equal to its source on `before`/`after`.
func snapshotForState(_ state: ActivityEventState) -> RepositorySnapshot {
    RepositorySnapshot(
        id: "repo-0",
        name: "repo-0", path: "/tmp/repo-0", branch: state.branch, status: .changed,
        modifiedFileCount: state.modified, addedFileCount: state.added,
        deletedFileCount: state.deleted, untrackedFileCount: state.untracked,
        stagedFileCount: state.staged, unstagedFileCount: state.unstaged,
        conflictedFileCount: state.conflicted, aheadCount: state.ahead,
        behindCount: state.behind, hasUpstream: state.hasUpstream,
        changedFileCount: state.modified, changedFilesPreview: [], risk: .low,
        lastScannedAt: "1970-01-01T00:00:00Z", dataSource: state.dataSource,
        lastChangedAt: nil, lastCommitID: state.lastCommitID,
        lastCommitSummary: state.lastCommitSummary, errorMessage: state.errorMessage,
        isPinned: false
    )
}

// MARK: - Ordering edge case

/// `ActivityEventOrdering.precedes` compares a parseable timestamp against an
/// unparseable one by raw string, which can cycle: here A (fractional, parses)
/// precedes B (canonical, parses), B precedes C (unparseable, string), and C
/// precedes A. `R` duplicates A's state pair with a newer timestamp, so an
/// implementation that folds the history into a pairwise-maximum index would
/// accept it while the original `first`-of-sorted result rejects it.
func cyclicOrderingCase() -> (existing: [ActivityEvent], candidates: [ActivityEvent]) {
    func workingTree(_ id: String, variant: Int, at: String) -> ActivityEvent {
        let pair = states(for: .workingTreeChanged, variant: variant, repositoryIndex: 0)
        return makeEvent(
            id: id, repositoryIndex: 0, kind: .workingTreeChanged,
            occurredAt: at, before: pair.before, after: pair.after
        )
    }
    let a = workingTree("cycle-a", variant: 1, at: "2026-10-16T00:00:00.500Z")
    let b = workingTree("cycle-b", variant: 2, at: "2026-10-16T00:00:00Z")
    let c = workingTree("cycle-c", variant: 3, at: "2026-10-16T00:00:00Q")
    let replayOfA = workingTree("cycle-replay-a", variant: 1, at: "2026-10-16T00:01:00Z")
    return ([a, b, c], [replayOfA])
}

// MARK: - Measurement

func uptimeNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

func dedup(_ existing: [ActivityEvent], _ candidates: [ActivityEvent]) -> [ActivityEvent] {
    ActivityEventDeduplicator.newEvents(from: candidates, comparedTo: existing)
}

/// Mirrors the dedup-bearing part of `ScanScheduler.recordActivityEvents`:
/// scope the in-memory archive, dedup, merge, re-scope.
func recorder(
    existing: [ActivityEvent],
    candidates: [ActivityEvent],
    repositoryIDs: Set<String>
) -> [ActivityEvent] {
    let store = ActivityEventStore(fileURL: URL(fileURLWithPath: "/dev/null"))
    let scopedExisting = store.pruning(existing, keepingRepositoryIDs: repositoryIDs)
    let newEvents = ActivityEventDeduplicator.newEvents(
        from: candidates,
        comparedTo: scopedExisting
    )
    return store.pruning(
        store.merging(existing: scopedExisting, newEvents: newEvents),
        keepingRepositoryIDs: repositoryIDs
    )
}

let label = ProcessInfo.processInfo.environment["BENCH_LABEL"] ?? "current"

@main
struct Main {
    static func main() {
        var overall = SHA256()
        var totalAccepted = 0
        var totalCandidates = 0

        for (offset, timingCase) in timingCases.enumerated() {
            let fixture = makeTimingFixture(
                timingCase, shape: timestampShape, seedOffset: UInt64(offset) &+ 1
            )
            let repositoryIDs = Set(fixture.existing.map(\.repositoryID))
                .union(fixture.candidates.map(\.repositoryID))

            var output: [ActivityEvent] = []
            var recorderOutput: [ActivityEvent] = []
            for _ in 0..<warmupIterations {
                output = dedup(fixture.existing, fixture.candidates)
                recorderOutput = recorder(
                    existing: fixture.existing, candidates: fixture.candidates,
                    repositoryIDs: repositoryIDs
                )
            }

            var sink = checksum(output) ^ checksum(recorderOutput)

            let dedupStart = uptimeNanoseconds()
            for _ in 0..<iterations {
                output = dedup(fixture.existing, fixture.candidates)
                sink ^= checksum(output)
            }
            let dedupElapsed = uptimeNanoseconds() - dedupStart

            let recorderStart = uptimeNanoseconds()
            for _ in 0..<iterations {
                recorderOutput = recorder(
                    existing: fixture.existing, candidates: fixture.candidates,
                    repositoryIDs: repositoryIDs
                )
                sink ^= checksum(recorderOutput)
            }
            let recorderElapsed = uptimeNanoseconds() - recorderStart

            totalAccepted += output.count
            totalCandidates += fixture.candidates.count
            overall.update(data: Data(digest(output).utf8))
            overall.update(data: Data(digest(recorderOutput).utf8))

            // `sink` is printed so the optimizer cannot elide the loop bodies.
            print(String(
                format: "BENCH label=%@ case=%@ history=%d candidates=%d accepted=%d "
                    + "iterations=%d dedup_mean_ms=%.4f recorder_mean_ms=%.4f "
                    + "digest=%@ sink=%llu",
                label, timingCase.label, fixture.existing.count, fixture.candidates.count,
                output.count, iterations,
                Double(dedupElapsed) / 1_000_000.0 / Double(iterations),
                Double(recorderElapsed) / 1_000_000.0 / Double(iterations),
                digest(output), sink
            ))
        }

        // Randomized differential scenarios, one digest per timestamp shape.
        for shape in ["canonical", "fractional", "mixed-invalid"] {
            var rng = SplitMix64(seed: seed &+ UInt64(shape.count) &* 7919)
            var combined = SHA256()
            var acceptedTotal = 0
            for _ in 0..<randomScenarios {
                let scenario = makeRandomScenario(rng: &rng, shape: shape)
                let accepted = dedup(scenario.existing, scenario.candidates)
                acceptedTotal += accepted.count
                combined.update(data: Data(digest(accepted).utf8))
            }
            let fingerprint = combined.finalize().map { String(format: "%02x", $0) }.joined()
            print("BENCH-RANDOM label=\(label) shape=\(shape) scenarios=\(randomScenarios) "
                + "accepted=\(acceptedTotal) fingerprint=\(fingerprint)")
        }

        let fingerprint = overall.finalize().map { String(format: "%02x", $0) }.joined()
        print("BENCH-SUMMARY label=\(label) accepted_total=\(totalAccepted) "
            + "candidates_total=\(totalCandidates) fingerprint=\(fingerprint) "
            + "timestamp_shape=\(timestampShape)")

        let cycle = cyclicOrderingCase()
        let cycleAccepted = dedup(cycle.existing, cycle.candidates)
        print("BENCH-EDGE label=\(label) case=cyclic-ordering "
            + "accepted=\(cycleAccepted.count) digest=\(digest(cycleAccepted))")
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
        "$engine" \
        "$HARNESS" \
        2> "$TMP_DIR/compile-$label.log" || {
            echo "error: compilation failed for $label (log: $TMP_DIR/compile-$label.log)" >&2
            tail -30 "$TMP_DIR/compile-$label.log" >&2
            return 1
        }
    BENCH_LABEL="$label" "$binary"
}

echo "Activity event dedup benchmark (newEvents + recordActivityEvents dedup stage)"
echo "  iterations=${BENCH_ITERATIONS:-300} warmup=${BENCH_WARMUP:-30} scenarios=${BENCH_SCENARIOS:-400} seed=${BENCH_SEED:-0x5EEDD3D0} timestamps=${BENCH_TIMESTAMP_SHAPE:-canonical}"
echo

BASELINE_OUT="$TMP_DIR/baseline.out"
CURRENT_OUT="$TMP_DIR/current.out"
compile_and_run baseline "$BASELINE_ENGINE" | tee "$BASELINE_OUT"
echo
compile_and_run current "$EVENT_FILE" | tee "$CURRENT_OUT"

echo
status=0

# Per-case speedup, matched by case label.
paste \
    <(sed -n 's/.*case=\([a-z-]*\) .*dedup_mean_ms=\([0-9.]*\).*recorder_mean_ms=\([0-9.]*\).*/\1 \2 \3/p' "$BASELINE_OUT") \
    <(sed -n 's/.*case=\([a-z-]*\) .*dedup_mean_ms=\([0-9.]*\).*recorder_mean_ms=\([0-9.]*\).*/\2 \3/p' "$CURRENT_OUT") \
| while read -r case_name base_dedup base_recorder cur_dedup cur_recorder; do
    awk -v c="$case_name" -v bd="$base_dedup" -v cd="$cur_dedup" \
        -v br="$base_recorder" -v cr="$cur_recorder" 'BEGIN {
        printf "%-14s dedup %8.4f -> %8.4f ms (%.2fx)   recorder %8.4f -> %8.4f ms (%.2fx)\n",
            c, bd, cd, (cd > 0 ? bd / cd : 0), br, cr, (cr > 0 ? br / cr : 0)
    }'
done

# Equivalence of the timing-case output and of the randomized scenarios.
for key in fingerprint; do
    base_value="$(sed -n "s/.*BENCH-SUMMARY .*${key}=\([0-9a-f]*\).*/\1/p" "$BASELINE_OUT")"
    current_value="$(sed -n "s/.*BENCH-SUMMARY .*${key}=\([0-9a-f]*\).*/\1/p" "$CURRENT_OUT")"
    if [[ "$base_value" == "$current_value" ]]; then
        echo "output equivalence (timing cases, accepted set + order): identical fingerprint ($current_value)"
    else
        echo "output equivalence (timing cases): MISMATCH ($base_value vs $current_value)" >&2
        status=1
    fi
done

for shape in canonical fractional mixed-invalid; do
    base_value="$(sed -n "s/.*BENCH-RANDOM .*shape=$shape .*fingerprint=\([0-9a-f]*\).*/\1/p" "$BASELINE_OUT")"
    current_value="$(sed -n "s/.*BENCH-RANDOM .*shape=$shape .*fingerprint=\([0-9a-f]*\).*/\1/p" "$CURRENT_OUT")"
    base_accepted="$(sed -n "s/.*BENCH-RANDOM .*shape=$shape .*accepted=\([0-9]*\).*/\1/p" "$BASELINE_OUT")"
    current_accepted="$(sed -n "s/.*BENCH-RANDOM .*shape=$shape .*accepted=\([0-9]*\).*/\1/p" "$CURRENT_OUT")"
    if [[ "$base_value" == "$current_value" && "$base_accepted" == "$current_accepted" ]]; then
        echo "output equivalence (randomized $shape, accepted=$current_accepted): identical fingerprint ($current_value)"
    else
        echo "output equivalence (randomized $shape): MISMATCH (baseline $base_accepted/$base_value vs current $current_accepted/$current_value)" >&2
        status=1
    fi
done

# The non-total-order case above: an implementation that dropped the
# `legacyNewEvents` fallback would accept the replay and fail here.
base_edge="$(sed -n 's/.*BENCH-EDGE .*digest=\([0-9a-f]*\).*/\1/p' "$BASELINE_OUT")"
current_edge="$(sed -n 's/.*BENCH-EDGE .*digest=\([0-9a-f]*\).*/\1/p' "$CURRENT_OUT")"
base_edge_accepted="$(sed -n 's/.*BENCH-EDGE .*accepted=\([0-9]*\).*/\1/p' "$BASELINE_OUT")"
current_edge_accepted="$(sed -n 's/.*BENCH-EDGE .*accepted=\([0-9]*\).*/\1/p' "$CURRENT_OUT")"
if [[ "$base_edge" == "$current_edge" && "$base_edge_accepted" == "$current_edge_accepted" ]]; then
    echo "output equivalence (cyclic-timestamp archive, accepted=$current_edge_accepted): identical fingerprint ($current_edge)"
else
    echo "output equivalence (cyclic-timestamp archive): MISMATCH (baseline $base_edge_accepted/$base_edge vs current $current_edge_accepted/$current_edge)" >&2
    status=1
fi

exit "$status"

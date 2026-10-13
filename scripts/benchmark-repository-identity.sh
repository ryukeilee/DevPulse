#!/usr/bin/env bash
# A/B benchmark for the post-scan repository derivation chain: repository
# identity hashing, scope filtering, identity migration and the sort that
# `ScanScheduler.applyPins()` performs after every scan.
#
# Runs a standalone harness against the current source and, with a baseline
# root or git ref, against that revision as well. Both variants are compiled
# with the same `swiftc -O -whole-module-optimization` invocation and run
# alternately; the driver reports the median of the per-run medians.
#
# Usage:
#   ./scripts/benchmark-repository-identity.sh
#   ./scripts/benchmark-repository-identity.sh --baseline-git <ref>
#   BASELINE_ROOT=<path-to-checkout> ./scripts/benchmark-repository-identity.sh
#
# Tunables (env): BENCH_REPOS (space separated list), BENCH_ITERATIONS,
# BENCH_WARMUP, BENCH_RUNS
#
# Every stage prints a SHA-256 fingerprint of its exact output, so equal
# fingerprints across variants prove the optimization did not change any
# identifier, filtered snapshot, migrated snapshot or sorted derivation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE_ROOT="${BASELINE_ROOT:-}"

BENCH_REPOS="${BENCH_REPOS:-4 100 1200}"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-15}"
BENCH_WARMUP="${BENCH_WARMUP:-3}"
BENCH_RUNS="${BENCH_RUNS:-3}"
export BENCH_REPOS BENCH_ITERATIONS BENCH_WARMUP

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-identity-bench.XXXXXX")"
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
            sed -n '2,24p' "$0"
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

HARNESS="$TMP_DIR/bench-repository-identity.swift"
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

let repositoryCounts = (ProcessInfo.processInfo.environment["BENCH_REPOS"] ?? "1200")
    .split(whereSeparator: { $0 == " " || $0 == "," })
    .compactMap { Int($0) }
    .filter { $0 > 0 }
let iterations = envInt("BENCH_ITERATIONS", 15)
let warmupIterations = envInt("BENCH_WARMUP", 3)
let label = ProcessInfo.processInfo.environment["BENCH_LABEL"] ?? "current"

// MARK: - Fixture

/// Fixture paths deliberately do not exist: `canonicalPath` then performs only
/// lexical standardization, so both variants resolve identically and the
/// measurement isolates the identity/digest work rather than filesystem state.
func fixtureRepository(_ index: Int) -> RepositorySnapshot {
    let status: RepositoryStatus
    switch index % 7 {
    case 0, 3: status = .clean
    case 5: status = .error
    default: status = .changed
    }
    let risk: RiskLevel = [.low, .medium, .high][index % 3]
    let branch: String = index % 5 == 0 ? "feature/\(index)" : "main"
    let preview: [String] = index % 2 == 0 ? ["src/Feature\(index).swift"] : []
    let errorMessage: String? = status == .error ? "read failed" : nil
    let lastChangedAt: String? = index % 4 == 3 ? nil : "2026-10-08T00:00:00Z"
    return RepositorySnapshot(
        id: "repo-\(index)",
        name: "repo \(index)",
        path: "/Users/bench/workspaces/ws-\(index % 12)/repo-\(index)",
        workspaceKind: index % 3 == 0 ? .linkedWorktree : .standalone,
        branch: branch,
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
        changedFilesPreview: preview,
        risk: risk,
        lastScannedAt: "2026-10-09T00:00:00Z",
        dataSource: .current,
        lastSuccessfulScanAt: "2026-10-08T00:00:00Z",
        lastChangedAt: lastChangedAt,
        lastCommitID: "abc\(index)",
        lastCommitSummary: "commit \(index)",
        lastCommitMetadataAvailable: true,
        lastActivityAt: "2026-10-08T12:00:00Z",
        unavailableSince: nil,
        errorMessage: errorMessage,
        isPinned: index % 20 == 0
    )
}

func fixtureSnapshot(_ count: Int) -> AppGroupData {
    let repositories = (0..<count).map(fixtureRepository)
    let summary = ScanSummary.build(from: repositories)
    let events: [ActivityEventSummary] = (0..<min(count, 40)).map { index in
        ActivityEventSummary(
            id: "event-\(index)",
            repositoryID: "repo-\(index)",
            repositoryName: "repo \(index)",
            kind: .newCommit,
            occurredAt: "2026-10-09T00:00:00Z",
            message: "commit \(index)",
            priority: index % 5
        )
    }
    return AppGroupData(
        schemaVersion: RepositorySnapshotSchema.version,
        generatedAt: "2026-10-09T00:00:00Z",
        writtenAt: "2026-10-09T00:00:00Z",
        lastSuccessfulRefreshAt: "2026-10-09T00:00:00Z",
        historySchemaVersion: 1,
        historyRecordingEnabled: true,
        scanSummary: summary,
        repositories: repositories,
        recentActivityEvents: events,
        repositoryUnavailableSinceByPath: Dictionary(
            uniqueKeysWithValues: (0..<min(count, 25)).map {
                ("/Users/bench/workspaces/ws-\($0 % 12)/repo-\($0)", "2026-10-01T00:00:00Z")
            }
        ),
        storageRevision: 7,
        persistenceState: .committed,
        pendingItemWidgetSummary: nil,
        isRefreshing: false,
        discoveryWasIncomplete: false,
        appVersion: "0.2.0",
        storageFormatVersion: RepositorySnapshotSchema.storageFormatVersion
    )
}

/// Mirrors `ScanScheduler.applyPins()` at its path-processing seam: scope
/// filtering, identity migration, pin application and the decision-based sort.
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

// MARK: - Fingerprints

func fingerprint(_ ids: [String]) -> String {
    let digest = SHA256.hash(data: Data(ids.joined(separator: "\u{1F}").utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func fingerprint(_ data: AppGroupData) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(data)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Measurement helpers

func uptimeNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted[sorted.count / 2]
}

@main
struct Main {
    static func main() throws {
        print("BENCH label=\(label) repos=\(repositoryCounts.map(String.init).joined(separator: ",")) "
              + "iterations=\(iterations) warmup=\(warmupIterations)")

        for count in repositoryCounts {
            let data = fixtureSnapshot(count)
            let rawPaths = data.repositories.map(\.path)
            let pinnedIDs: Set<String> = Set(
                (0..<count).filter { $0 % 20 == 0 }.map { "repo-\($0)" }
            )

            /// Times `body` after a warmup, then fingerprints its actual output.
            /// The fingerprint closure runs outside the timed loop.
            func stage(_ name: String, _ body: () -> Void, fingerprint output: () throws -> String) {
                for _ in 0..<warmupIterations { body() }
                var samples: [Double] = []
                for _ in 0..<iterations {
                    let start = uptimeNanoseconds()
                    body()
                    samples.append(Double(uptimeNanoseconds() - start) / 1_000_000.0)
                }
                let digest: String
                do { digest = try output() } catch { digest = "unavailable" }
                print(String(format: "STAGE %@ repos=%d median_ms=%.4f min_ms=%.4f fingerprint=%@",
                             name, count, median(samples), samples.min() ?? 0, digest))
            }

            // 1. Repository identity hashing with canonical paths already
            //    resolved: the steady state inside one derivation, where a
            //    refresh scope or `applyPins` scope has computed each path once
            //    and every later identity lookup is a reuse.
            var scopedIDs: [String] = []
            do {
                let scope = RepositoryIdentity.CanonicalizationScope()
                RepositoryIdentity.withCanonicalizationScopeSync(scope) {
                    for path in rawPaths { _ = RepositoryIdentity.canonicalPath(path) }
                }
                stage("identity_sweep_scoped", {
                    RepositoryIdentity.withCanonicalizationScopeSync(scope) {
                        scopedIDs = rawPaths.map { RepositoryIdentity.id(for: $0) }
                    }
                }, fingerprint: { fingerprint(scopedIDs) })
            }

            // 2. The same sweep without a scope: `canonicalPath` runs a
            //    filesystem resolution per call. Unchanged by the optimization;
            //    measured so the scoped figure above is attributable.
            var coldIDs: [String] = []
            stage("identity_sweep_unscoped", {
                coldIDs = rawPaths.map { RepositoryIdentity.id(for: $0) }
            }, fingerprint: { fingerprint(coldIDs) })

            // 3. Scope filtering (canonicalize + normalize + summary rebuild)
            //    as `applyPins` runs it: one scope per derivation.
            var filtered = data
            stage("scope_filtering", {
                RepositoryIdentity.withCanonicalizationScopeSync(
                    RepositoryIdentity.CanonicalizationScope()
                ) {
                    filtered = RepositoryScope.filtering(data, excluding: [])
                }
            }, fingerprint: { try fingerprint(filtered) })

            // 4. Identity migration (normalize + pin translation).
            var migrated = data
            stage("identity_migration", {
                RepositoryIdentity.withCanonicalizationScopeSync(
                    RepositoryIdentity.CanonicalizationScope()
                ) {
                    migrated = RepositoryIdentityMigration.migrate(
                        snapshot: data,
                        pinnedIDs: pinnedIDs
                    ).snapshot
                }
            }, fingerprint: { try fingerprint(migrated) })

            // 5. One full post-scan derivation set: the scan-completion pass,
            //    the pre-write pass, the post-write pass and the widget-filter
            //    pass all derive from the same scan result, each with its own
            //    scope exactly as the production call sites install them.
            var derivation = data
            stage("post_scan_derivations", {
                RepositoryIdentity.withCanonicalizationScopeSync(
                    RepositoryIdentity.CanonicalizationScope()
                ) {
                    derivation = applyPinsLike(data, pinnedIDs: pinnedIDs)
                }
                RepositoryIdentity.withCanonicalizationScopeSync(
                    RepositoryIdentity.CanonicalizationScope()
                ) {
                    derivation = applyPinsLike(data, pinnedIDs: pinnedIDs)
                }
                RepositoryIdentity.withCanonicalizationScopeSync(
                    RepositoryIdentity.CanonicalizationScope()
                ) {
                    derivation = applyPinsLike(data, pinnedIDs: pinnedIDs)
                }
                RepositoryIdentity.withCanonicalizationScopeSync(
                    RepositoryIdentity.CanonicalizationScope()
                ) {
                    derivation = RepositoryScope.filtering(data, excluding: [])
                }
            }, fingerprint: { try fingerprint(derivation) })
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
    local label="$1"
    local binary="$TMP_DIR/bench-$label"
    BENCH_LABEL="$label" "$binary" >> "$TMP_DIR/$label.out"
}

echo "Repository identity / post-scan derivation benchmark"
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

extract() {
    local file="$1" stage="$2" repos="$3" field="$4"
    sed -n "s/^STAGE $stage repos=$repos .*$field=\([0-9a-f.]*\).*/\1/p" "$file"
}

median_of() {
    local file="$1" stage="$2" repos="$3" field="$4"
    extract "$file" "$stage" "$repos" "$field" | sort -g | awk '{ values[NR] = $1 } END { print values[int((NR + 1) / 2)] }'
}

status=0
for repos in $BENCH_REPOS; do
    echo "repos=$repos"
    printf '  %-24s %12s %12s %10s\n' "stage" "baseline_ms" "current_ms" "speedup"
    while read -r stage; do
        baseline_ms="$(median_of "$TMP_DIR/baseline.out" "$stage" "$repos" median_ms)"
        current_ms="$(median_of "$TMP_DIR/current.out" "$stage" "$repos" median_ms)"
        baseline_fp="$(extract "$TMP_DIR/baseline.out" "$stage" "$repos" fingerprint | head -n 1)"
        current_fp="$(extract "$TMP_DIR/current.out" "$stage" "$repos" fingerprint | head -n 1)"
        awk -v s="$stage" -v b="$baseline_ms" -v c="$current_ms" 'BEGIN {
            if (b > 0 && c > 0) {
                printf "  %-24s %12.4f %12.4f %9.2fx\n", s, b, c, b / c
            } else {
                printf "  %-24s %12s %12s %10s\n", s, "n/a", "n/a", "n/a"
            }
        }'
        if [[ "$baseline_fp" != "$current_fp" ]]; then
            echo "    output equivalence: MISMATCH for $stage at repos=$repos" >&2
            echo "      baseline: $baseline_fp" >&2
            echo "      current:  $current_fp" >&2
            status=1
        else
            # A single run per variant would make a false match possible; the
            # fingerprints must also repeat identically within each variant.
            baseline_unique="$(extract "$TMP_DIR/baseline.out" "$stage" "$repos" fingerprint | sort -u | wc -l | tr -d ' ')"
            current_unique="$(extract "$TMP_DIR/current.out" "$stage" "$repos" fingerprint | sort -u | wc -l | tr -d ' ')"
            if [[ "$baseline_unique" != "1" || "$current_unique" != "1" ]]; then
                echo "    determinism: UNSTABLE fingerprint for $stage at repos=$repos" >&2
                status=1
            fi
        fi
    done < <(sed -n "s/^STAGE \([^ ]*\) repos=$repos .*/\1/p" "$TMP_DIR/baseline.out" | sort -u)
    echo
done

if [[ "$status" -eq 0 ]]; then
    echo "output equivalence: every stage fingerprint identical across variants and runs"
fi
exit "$status"

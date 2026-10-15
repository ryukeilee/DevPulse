#!/usr/bin/env bash
# A/B benchmark for the discovered-path normalization that drops ignored
# repositories.
#
# `ScanScheduler.lastDiscoveredRepositoryPaths` is read at the start of a scan
# and written on every completed scan, so its cost is paid at least twice per
# refresh round on the main actor. Its filter used to read the
# `ignoredRepositoryPaths` computed property per element; that property
# canonicalizes every ignored path (getpwuid, URL standardization, a
# filesystem existence check and symlink resolution) and builds a Set, so the
# accessor resolved `discovered x ignored` paths instead of
# `discovered + ignored`.
#
# This script compiles `scripts/benchmarks/ignored-path-lookup.swift` against
# the production models and runs it. The harness reports, per size:
#
#   inside-filter ms     the previous accessor (ignore set rebuilt per path)
#   once-per-access ms   the current accessor (ignore set resolved once)
#   resolutions          filesystem canonicalizations, counted by running both
#                        forms under a reuse-disabled CanonicalizationScope
#   equivalent           both forms returned the identical sorted array
#
# It exits non-zero when the two forms disagree, so equal output is a
# precondition for reading the timings.
#
# Usage:
#   ./scripts/benchmark-ignored-path-lookup.sh
#
# Tunables (env): BENCH_SIZES (space separated "discovered:ignored" pairs),
#                 BENCH_ITERATIONS
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-5}"
BENCH_SIZES="${BENCH_SIZES:-8:10 60:10 240:10 1200:10 240:0}"
export BENCH_ITERATIONS BENCH_SIZES

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-ignored-path-bench.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

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
SOURCE_PATHS=()
for relative in "${SOURCES[@]}"; do
    SOURCE_PATHS+=("$ROOT_DIR/$relative")
done

xcrun swiftc -O -whole-module-optimization \
    -module-cache-path "$TMP_DIR/module-cache" \
    -o "$TMP_DIR/benchmark" \
    "${SOURCE_PATHS[@]}" \
    "$ROOT_DIR/scripts/benchmarks/ignored-path-lookup.swift"

"$TMP_DIR/benchmark"

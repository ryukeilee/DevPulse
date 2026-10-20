#!/usr/bin/env bash
# Paired A/B end-to-end measurement of the timer refresh path
# (`ScanScheduler` → `RefreshEngine` → shared snapshot) between a baseline Git
# ref and the current working tree.
#
# `measure-end-to-end-refresh.sh` applies the working tree's diff of
# `ScanScheduler.swift`/`RefreshEngine.swift` onto the archived baseline so both
# sides expose the same measurement probes. That is correct for a benchmark-only
# change, but it copies production changes from those two files into the
# baseline and hides them from the comparison. This runner never patches the
# baseline: it checks out the ref into its own worktree and builds it unchanged,
# which is what a production change in those files needs.
#
# Usage:
#   REAL_REPOSITORIES_FILE=/path/repos.txt PAIRS=6 \
#     OUTPUT_DIR=/tmp/devpulse-refresh-ab DERIVED_DATA_PATH=/tmp/devpulse-refresh-ab-dd \
#     ./scripts/measure-refresh-execution-ab.sh
#
#   REF            baseline ref (default: HEAD)
#   PAIRS          >= 2, alternating order; 6 is enough for an exact two-sided
#                  sign test at p=0.03125 when every pair favours one side
#   REPOS_FILE     newline-separated repository directories used as custom scan
#                  directories by the measurement harness; the test requires the
#                  committed snapshot to contain exactly one repository per entry
#
# Every sample gets a fresh App Group container and defaults suite under the
# output directory. Each variant is built once into its own DerivedData
# subdirectory; samples use `test-without-building`, so build time is excluded.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REF="${REF:-HEAD}"
PAIRS="${PAIRS:-6}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/devpulse-refresh-ab-dd}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
REAL_REPOSITORIES_FILE="${REAL_REPOSITORIES_FILE:-${REPOS_FILE:-}}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"
TEST_SPEC='DevPulseTests/EndToEndRefreshMeasurementTests/scheduledIncrementalRefresh()'

if ! [[ "$PAIRS" =~ ^[0-9]+$ ]] || (( PAIRS < 2 )); then
    echo "PAIRS must be an integer >= 2 (paired samples); got: $PAIRS" >&2
    exit 2
fi
if [[ -z "$REAL_REPOSITORIES_FILE" ]] || [[ ! -r "$REAL_REPOSITORIES_FILE" ]] \
    || ! grep -q . "$REAL_REPOSITORIES_FILE"; then
    echo "REAL_REPOSITORIES_FILE must name a readable, non-empty repository list" >&2
    exit 2
fi
while IFS= read -r repository_path; do
    [[ -n "$repository_path" ]] || continue
    if [[ ! -d "$repository_path" ]]; then
        echo "A listed repository directory is unavailable" >&2
        exit 2
    fi
done < "$REAL_REPOSITORIES_FILE"
REPOSITORY_COUNT="$(grep -c . "$REAL_REPOSITORIES_FILE")"

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-refresh-ab.XXXXXX")"
else
    if [[ -e "$OUTPUT_DIR" ]] && [[ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        echo "OUTPUT_DIR must be absent or empty to avoid overwriting prior evidence: $OUTPUT_DIR" >&2
        exit 2
    fi
    mkdir -p "$OUTPUT_DIR"
fi
if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR/raw" "$OUTPUT_DIR/samples" "$DERIVED_DATA_PATH"

BASELINE_TREE="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-refresh-ab-tree.XXXXXX")"
cleanup() {
    git -C "$ROOT_DIR" worktree remove --force "$BASELINE_TREE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_with_timeout() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    else
        echo "timeout not found in PATH; running without timeout enforcement" >&2
        "$@"
    fi
}

build_variant() { # label project_root
    local label="$1" project_root="$2"
    local log="$OUTPUT_DIR/raw/build-$label.log"
    echo "building $label"
    if ! run_with_timeout "$BUILD_TIMEOUT" xcodebuild \
        -project "$project_root/DevPulseNative/DevPulseNative.xcodeproj" \
        -scheme DevPulse -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA_PATH/$label" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        build-for-testing >"$log" 2>&1; then
        echo "build-for-testing failed for $label; raw log: $log" >&2
        tail -n 120 "$log" >&2
        exit 1
    fi
}

run_sample() { # pair label project_root order
    local pair="$1" label="$2" project_root="$3" order="$4"
    local sample_id="pair-$pair-$label"
    local sample_root="$OUTPUT_DIR/samples/$sample_id"
    local container="$sample_root/app-group"
    local defaults_suite="local.devpulse.app.tests.$(uuidgen | tr 'A-Z' 'a-z')"
    local log="$OUTPUT_DIR/raw/run-$pair-$order-$label.log"

    mkdir -p "$container"
    if ! run_with_timeout "$TEST_TIMEOUT" env \
        "TEST_RUNNER_DEVPULSE_APP_GROUP_CONTAINER_PATH=$container" \
        "TEST_RUNNER_DEVPULSE_APP_GROUP_DEFAULTS_SUITE=$defaults_suite" \
        "TEST_RUNNER_DEVPULSE_E2E_SAMPLE_ROOT=$sample_root" \
        "TEST_RUNNER_DEVPULSE_E2E_SAMPLE_ID=$sample_id" \
        "TEST_RUNNER_DEVPULSE_E2E_MODE=real" \
        "TEST_RUNNER_DEVPULSE_E2E_REAL_REPOSITORIES_FILE=$REAL_REPOSITORIES_FILE" \
        xcodebuild \
            -project "$project_root/DevPulseNative/DevPulseNative.xcodeproj" \
            -scheme DevPulse -configuration Debug \
            -destination 'platform=macOS' \
            -derivedDataPath "$DERIVED_DATA_PATH/$label" \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
            -only-testing:"$TEST_SPEC" \
            test-without-building >"$log" 2>&1; then
        echo "sample $sample_id failed; raw log: $log" >&2
        tail -n 120 "$log" >&2
        exit 1
    fi
    local measurement
    measurement="$(grep '^e2e_refresh' "$log" | tail -n 1 || true)"
    if [[ -z "$measurement" ]]; then
        echo "sample $sample_id emitted no measurement; raw log: $log" >&2
        tail -n 80 "$log" >&2
        exit 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$pair" "$label" "$order" "$measurement" >>"$OUTPUT_DIR/samples.tsv"
    defaults delete "$defaults_suite" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$defaults_suite.plist" 2>/dev/null || true
}

git -C "$ROOT_DIR" worktree add --detach "$BASELINE_TREE" "$REF" >/dev/null
{
    printf 'baseline_ref=%s\n' "$(git -C "$BASELINE_TREE" rev-parse HEAD)"
    printf 'candidate_ref=%s\n' "$(git -C "$ROOT_DIR" rev-parse HEAD)"
    printf 'candidate_worktree_dirty=%s\n' "$(git -C "$ROOT_DIR" status --porcelain | grep -c . || true)"
    printf 'repository_count=%s\npairs=%s\n' "$REPOSITORY_COUNT" "$PAIRS"
    printf 'configuration=Debug\ntest_spec=%s\n\n' "$TEST_SPEC"
    sw_vers
    xcodebuild -version
    uname -m
    sysctl -n hw.model hw.ncpu machdep.cpu.brand_string 2>/dev/null || true
} >"$OUTPUT_DIR/metadata.txt" 2>&1

build_variant baseline "$BASELINE_TREE"
build_variant current "$ROOT_DIR"

: >"$OUTPUT_DIR/samples.tsv"
for pair in $(seq 1 "$PAIRS"); do
    if (( pair % 2 == 1 )); then
        run_sample "$pair" baseline "$BASELINE_TREE" baseline-first
        run_sample "$pair" current "$ROOT_DIR" current-second
    else
        run_sample "$pair" current "$ROOT_DIR" current-first
        run_sample "$pair" baseline "$BASELINE_TREE" baseline-second
    fi
    echo "pair $pair complete"
done

python3 - "$OUTPUT_DIR" <<'PY'
import json, math, re, statistics, sys
from pathlib import Path

output = Path(sys.argv[1])
METRICS = [
    "scheduler_wall_ms", "refresh_engine_ms", "discovery_ms", "core_status_ms",
    "core_status_git_runner_ms", "core_status_snapshot_build_ms", "extended_info_ms",
    "merge_ms", "scheduler_apply_pins_ms", "snapshot_prepare_apply_pins_ms",
    "snapshot_revision_read_ms", "snapshot_commit_and_verify_ms",
    "refresh_cpu_user_ms", "refresh_cpu_system_ms", "total_git_calls",
]
samples = {}
signatures = set()
for line in (output / "samples.tsv").read_text().splitlines():
    pair, label, order, measurement = line.split("\t", 3)
    values = dict(re.findall(r"([A-Za-z0-9_.]+)=([^\s,\]]+)", measurement.replace('"', "")))
    samples.setdefault(int(pair), {})[label] = values
    if "refresh_result_signature" in values:
        signatures.add(values["refresh_result_signature"])

def exact_sign_p(faster, total):
    smaller = min(faster, total - faster)
    return min(1.0, 2 * sum(math.comb(total, i) for i in range(smaller + 1)) / 2 ** total)

pairs = sorted(p for p, labels in samples.items() if {"baseline", "current"} <= labels.keys())
summary = {}
for metric in METRICS:
    baseline = [float(samples[p]["baseline"][metric]) for p in pairs]
    candidate = [float(samples[p]["current"][metric]) for p in pairs]
    deltas = [c - b for b, c in zip(baseline, candidate)]
    median_delta = statistics.median(deltas)
    faster = sum(1 for delta in deltas if delta < 0)
    summary[metric] = {
        "baseline_median": statistics.median(baseline),
        "candidate_median": statistics.median(candidate),
        "paired_median_delta": median_delta,
        "paired_mad": statistics.median(abs(delta - median_delta) for delta in deltas),
        "faster_pairs": faster,
        "slower_pairs": sum(1 for delta in deltas if delta > 0),
        "pairs": len(pairs),
        "two_sided_sign_p": exact_sign_p(faster, len(pairs)),
    }

report = {
    "description": "Paired end-to-end timer-refresh measurement produced by scripts/measure-refresh-execution-ab.sh",
    "baseline_ref": next(p for p in (output / "metadata.txt").read_text().splitlines() if p.startswith("baseline_ref=")).split("=", 1)[1],
    "candidate_ref": next(p for p in (output / "metadata.txt").read_text().splitlines() if p.startswith("candidate_ref=")).split("=", 1)[1],
    "repository_count": len(pairs) and int(next(p for p in (output / "metadata.txt").read_text().splitlines() if p.startswith("repository_count=")).split("=", 1)[1]),
    "configuration": "Debug",
    "samples": [
        {"pair": pair, "label": label, **{metric: values.get(metric) for metric in METRICS}}
        for pair in pairs for label, values in sorted(samples[pair].items())
    ],
    "summary": summary,
    "result_signatures": sorted(signatures),
    "cpu_scope": "RUSAGE_SELF + RUSAGE_CHILDREN increments over the measured refresh window (includes Git child processes)",
    "equivalence_note": "refresh_result_signature covers repository name, branch, status, file counts and pin state; identical signatures mean those fields matched, not that the whole payload was byte-identical.",
}
(output / "summary.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")

lines = ["metric\tbaseline_median\tcandidate_median\tpaired_median_delta\tpaired_MAD\tfaster_pairs\tpairs\ttwo_sided_sign_p"]
for metric, values in summary.items():
    lines.append("{}\t{:.3f}\t{:.3f}\t{:+.3f}\t{:.3f}\t{}/{}\t{:.5f}".format(
        metric, values["baseline_median"], values["candidate_median"],
        values["paired_median_delta"], values["paired_mad"], values["faster_pairs"],
        values["pairs"], values["two_sided_sign_p"]))
lines.append("")
lines.append("result_signatures\t" + ",".join(sorted(signatures)))
(output / "summary.txt").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
PY

echo "evidence: $OUTPUT_DIR"

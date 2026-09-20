#!/usr/bin/env bash
set -euo pipefail

# Repeatedly measures the existing, real GitRepositoryScanner incremental-refresh
# scenario. The selected Swift Testing case creates four temporary Git repositories,
# performs an initial discovery scan, then measures a refresh that reuses the known
# repository scope and prior snapshot. Its `scan_benchmark` line is the per-refresh
# measurement; /usr/bin/time -l supplies command-level maximum RSS.
#
# Prerequisite: build the test bundle once with:
#   DERIVED_DATA_PATH=/tmp/devpulse-incremental-refresh ./scripts/verify.sh build
#
# Optional environment:
#   RUNS=5 (minimum 5), DERIVED_DATA_PATH=/tmp/devpulse-incremental-refresh,
#   OUTPUT_DIR=/tmp/devpulse-incremental-refresh-results

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${RUNS:-5}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/devpulse-incremental-refresh}"
OUTPUT_DIR="${OUTPUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/devpulse-incremental-refresh.XXXXXX")}" 
TEST_SPEC='DevPulseTests/ScanPerformanceTests/unchangedKnownScopeReusesDiscoveryAndCommitMetadata()'

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || (( RUNS < 5 )); then
    echo "RUNS must be an integer >= 5; got: $RUNS" >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR/raw"
printf 'run\tincremental_elapsed_ms\tincremental_git_calls\tcommand_max_rss_bytes\tcommand_peak_footprint_bytes\n' > "$OUTPUT_DIR/samples.tsv"
printf 'test_spec=%s\nderived_data_path=%s\nruns=%s\n' "$TEST_SPEC" "$DERIVED_DATA_PATH" "$RUNS" > "$OUTPUT_DIR/metadata.txt"

for run in $(seq 1 "$RUNS"); do
    log="$OUTPUT_DIR/raw/run-$run.log"
    time_log="$OUTPUT_DIR/raw/run-$run.time.log"

    /usr/bin/time -l xcodebuild \
        -project "$ROOT_DIR/DevPulseNative/DevPulseNative.xcodeproj" \
        -scheme DevPulse \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        -only-testing:"$TEST_SPEC" \
        test-without-building >"$log" 2>"$time_log"

    benchmark="$(grep '^scan_benchmark\.' "$log" | tail -n 1 || true)"
    if [[ -z "$benchmark" ]]; then
        echo "run $run did not produce scan_benchmark output; raw log: $log" >&2
        exit 1
    fi

    elapsed="$(printf '%s\n' "$benchmark" | sed -n 's/.*incremental_elapsed_ms=\([0-9][0-9]*\).*/\1/p')"
    git_calls="$(printf '%s\n' "$benchmark" | sed -n 's/.*incremental_git_calls=\([0-9][0-9]*\).*/\1/p')"
    max_rss="$(awk '/maximum resident set size/ { print $1; exit }' "$time_log")"
    footprint="$(awk '/peak memory footprint/ { print $1; exit }' "$time_log")"
    if [[ -z "$elapsed" || -z "$git_calls" || -z "$max_rss" || -z "$footprint" ]]; then
        echo "run $run had incomplete measurement data; raw logs: $log, $time_log" >&2
        exit 1
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$run" "$elapsed" "$git_calls" "$max_rss" "$footprint" \
        | tee -a "$OUTPUT_DIR/samples.tsv"
done

awk -F '\t' '
NR == 1 { next }
{
    elapsed += $2; elapsed2 += $2 * $2
    git += $3; git2 += $3 * $3
    rss += $4; rss2 += $4 * $4
    footprint += $5; footprint2 += $5 * $5
    if (NR == 2 || $2 < elapsedMin) elapsedMin = $2
    if (NR == 2 || $2 > elapsedMax) elapsedMax = $2
    if (NR == 2 || $3 < gitMin) gitMin = $3
    if (NR == 2 || $3 > gitMax) gitMax = $3
    if (NR == 2 || $4 < rssMin) rssMin = $4
    if (NR == 2 || $4 > rssMax) rssMax = $4
    if (NR == 2 || $5 < footprintMin) footprintMin = $5
    if (NR == 2 || $5 > footprintMax) footprintMax = $5
    n++
}
END {
    if (n < 1) exit 1
    printf "metric\tmean\tstddev_population\tmin\tmax\tn\n"
    printf "incremental_elapsed_ms\t%.3f\t%.3f\t%d\t%d\t%d\n", elapsed/n, sqrt(elapsed2/n - (elapsed/n)^2), elapsedMin, elapsedMax, n
    printf "incremental_git_calls\t%.3f\t%.3f\t%d\t%d\t%d\n", git/n, sqrt(git2/n - (git/n)^2), gitMin, gitMax, n
    printf "command_max_rss_bytes\t%.3f\t%.3f\t%d\t%d\t%d\n", rss/n, sqrt(rss2/n - (rss/n)^2), rssMin, rssMax, n
    printf "command_peak_footprint_bytes\t%.3f\t%.3f\t%d\t%d\t%d\n", footprint/n, sqrt(footprint2/n - (footprint/n)^2), footprintMin, footprintMax, n
}' "$OUTPUT_DIR/samples.tsv" | tee "$OUTPUT_DIR/summary.tsv"

# Compatible with PerformanceBaselineManager.load(from:). Times are converted
# from this script's millisecond output to ScenarioBaseline seconds.
awk -F '\t' '$1 == "incremental_elapsed_ms" {
    printf "{\"baselines\":{\"incrementalRefresh\":{\"scenario\":\"incrementalRefresh\",\"meanElapsed\":%.9f,\"stddevElapsed\":%.9f,\"sampleCount\":%d}},\"schemaVersion\":1}\n", $2 / 1000, $3 / 1000, $6
}' "$OUTPUT_DIR/summary.tsv" > "$OUTPUT_DIR/performance-baselines.json"

echo "raw logs, statistics, and PerformanceBaselineManager-compatible JSON: $OUTPUT_DIR"

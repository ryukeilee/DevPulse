#!/usr/bin/env bash
set -euo pipefail

# Paired end-to-end measurement of the production ScanScheduler -> RefreshEngine
# timer-refresh path. Every measured sample gets a new repository tree, App Group
# container, and defaults suite. The baseline is exported with git archive; the
# same benchmark test source is injected into that pristine tree before building.
#
# Usage:
#   RUNS=10 DERIVED_DATA_PATH=/tmp/devpulse-refresh-e2e \
#     OUTPUT_DIR=/tmp/devpulse-refresh-e2e-results \
#     ./scripts/measure-end-to-end-refresh.sh
#
# RUNS counts baseline/current pairs and must be >= 5. Each revision is built
# once into a separate subdirectory of DERIVED_DATA_PATH; measured invocations
# use test-without-building so build time is excluded from refresh timing.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE_REV="${BASELINE_REV:-7f29c0f}"
RUNS="${RUNS:-10}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/devpulse-refresh-e2e}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
TEST_SPEC='DevPulseTests/EndToEndRefreshMeasurementTests/scheduledIncrementalRefresh()'
TEST_SOURCE='DevPulseNative/DevPulseNativeTests/EndToEndRefreshMeasurementTests.swift'
BASELINE_TREE=""

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || (( RUNS < 5 )); then
    echo "RUNS must be an integer >= 5 (paired runs); got: $RUNS" >&2
    exit 2
fi
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required to register the shared benchmark test in the baseline project" >&2
    exit 2
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-refresh-e2e.XXXXXX")"
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

mkdir -p "$OUTPUT_DIR/raw" "$OUTPUT_DIR/system" "$OUTPUT_DIR/samples" "$DERIVED_DATA_PATH"
BASELINE_TREE="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-refresh-e2e-baseline.XXXXXX")"
cleanup() {
    if [[ -n "$BASELINE_TREE" && -d "$BASELINE_TREE" ]]; then
        rm -rf "$BASELINE_TREE"
    fi
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

capture_system_state() {
    local name="$1"
    {
        printf 'timestamp='
        date '+%Y-%m-%dT%H:%M:%S%z'
        uptime
        printf '\nactive_build_and_test_processes:\n'
        ps -Ao pid,ppid,%cpu,%mem,etime,command \
            | grep -E '[x]codebuild|[x]ctest|[D]evPulse.*(Test|test)|[/]Applications/DevPulse[^ ]*\.app/' || true
    } > "$OUTPUT_DIR/system/$name.txt" 2>&1
}

build_for_testing() {
    local label="$1"
    local project_root="$2"
    local derived="$DERIVED_DATA_PATH/$label"
    local log="$OUTPUT_DIR/raw/build-$label.log"
    mkdir -p "$derived"
    if ! run_with_timeout "$BUILD_TIMEOUT" xcodebuild \
        -project "$project_root/DevPulseNative/DevPulseNative.xcodeproj" \
        -scheme DevPulse \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        build-for-testing >"$log" 2>&1; then
        echo "build-for-testing failed for $label; raw log: $log" >&2
        tail -n 120 "$log" >&2
        exit 1
    fi
    printf 'build_%s=passed\n' "$label"
}

run_sample() {
    local pair="$1"
    local label="$2"
    local order="$3"
    local project_root="$4"
    local sample_id="pair-$pair-$label-$order"
    local sample_root="$OUTPUT_DIR/samples/$sample_id"
    local container="$sample_root/app-group"
    local defaults_suite="local.devpulse.app.tests.$(uuidgen | tr 'A-Z' 'a-z')"
    local project="$project_root/DevPulseNative/DevPulseNative.xcodeproj"
    local derived="$DERIVED_DATA_PATH/$label"
    local log="$OUTPUT_DIR/raw/run-$pair-$order-$label.log"
    local time_log="$OUTPUT_DIR/raw/run-$pair-$order-$label.time.log"
    local system_tag="run-$pair-$order-$label"

    mkdir -p "$sample_root" "$container"
    capture_system_state "$system_tag-before"
    if ! run_with_timeout "$TEST_TIMEOUT" /usr/bin/time -l \
        env \
        "TEST_RUNNER_DEVPULSE_APP_GROUP_CONTAINER_PATH=$container" \
        "TEST_RUNNER_DEVPULSE_APP_GROUP_DEFAULTS_SUITE=$defaults_suite" \
        "TEST_RUNNER_DEVPULSE_E2E_SAMPLE_ROOT=$sample_root" \
        "TEST_RUNNER_DEVPULSE_E2E_SAMPLE_ID=$sample_id" \
        xcodebuild \
            -project "$project" \
            -scheme DevPulse \
            -configuration Debug \
            -destination 'platform=macOS' \
            -derivedDataPath "$derived" \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
            -only-testing:"$TEST_SPEC" \
            test-without-building >"$log" 2>"$time_log"; then
        echo "sample failed ($sample_id); raw logs: $log, $time_log" >&2
        tail -n 160 "$log" >&2
        exit 1
    fi

    local benchmark
    benchmark="$(grep '^e2e_refresh.sample=' "$log" | tail -n 1 || true)"
    if [[ -z "$benchmark" ]]; then
        echo "sample $sample_id did not emit e2e_refresh output; raw log: $log" >&2
        tail -n 120 "$log" >&2
        exit 1
    fi

    local elapsed engine_elapsed discovery core_status git_runner git_runner_calls snapshot_build snapshot_build_calls extended merge persist widget git_calls discovery_git_calls core_git_calls extended_git_calls apply_pins snapshot_pins snapshot_read snapshot_commit activity_save history_save widget_reload widget_reload_calls max_rss footprint cpu_seconds result_signature
    elapsed="$(printf '%s\n' "$benchmark" | sed -n 's/.*scheduler_wall_ms=\([0-9.][0-9.]*\).*/\1/p')"
    engine_elapsed="$(printf '%s\n' "$benchmark" | sed -n 's/.*refresh_engine_ms=\([0-9.][0-9.]*\).*/\1/p')"
    discovery="$(printf '%s\n' "$benchmark" | sed -n 's/.*discovery_ms=\([0-9.][0-9.]*\).*/\1/p')"
    core_status="$(printf '%s\n' "$benchmark" | sed -n 's/.*core_status_ms=\([0-9.][0-9.]*\).*/\1/p')"
    git_runner="$(printf '%s\n' "$benchmark" | sed -n 's/.*core_status_git_runner_ms=\([0-9.][0-9.]*\).*/\1/p')"
    git_runner_calls="$(printf '%s\n' "$benchmark" | sed -n 's/.*core_status_git_runner_calls=\([0-9][0-9]*\).*/\1/p')"
    snapshot_build="$(printf '%s\n' "$benchmark" | sed -n 's/.*core_status_snapshot_build_ms=\([0-9.][0-9.]*\).*/\1/p')"
    snapshot_build_calls="$(printf '%s\n' "$benchmark" | sed -n 's/.*core_status_snapshot_build_calls=\([0-9][0-9]*\).*/\1/p')"
    extended="$(printf '%s\n' "$benchmark" | sed -n 's/.*extended_info_ms=\([0-9.][0-9.]*\).*/\1/p')"
    merge="$(printf '%s\n' "$benchmark" | sed -n 's/.*merge_ms=\([0-9.][0-9.]*\).*/\1/p')"
    persist="$(printf '%s\n' "$benchmark" | sed -n 's/.*engine_persistence_prepare_ms=\([0-9.][0-9.]*\).*/\1/p')"
    widget="$(printf '%s\n' "$benchmark" | sed -n 's/.*engine_widget_deferred_ms=\([0-9.][0-9.]*\).*/\1/p')"
    git_calls="$(printf '%s\n' "$benchmark" | sed -n 's/.*total_git_calls=\([0-9][0-9]*\).*/\1/p')"
    discovery_git_calls="$(printf '%s\n' "$benchmark" | sed -n 's/.*discovery_git_calls=\([0-9][0-9]*\).*/\1/p')"
    core_git_calls="$(printf '%s\n' "$benchmark" | sed -n 's/.*core_status_git_calls=\([0-9][0-9]*\).*/\1/p')"
    extended_git_calls="$(printf '%s\n' "$benchmark" | sed -n 's/.*extended_info_git_calls=\([0-9][0-9]*\).*/\1/p')"
    apply_pins="$(printf '%s\n' "$benchmark" | sed -n 's/.*scheduler_apply_pins_ms=\([0-9.][0-9.]*\).*/\1/p')"
    snapshot_pins="$(printf '%s\n' "$benchmark" | sed -n 's/.*snapshot_prepare_apply_pins_ms=\([0-9.][0-9.]*\).*/\1/p')"
    snapshot_read="$(printf '%s\n' "$benchmark" | sed -n 's/.*snapshot_revision_read_ms=\([0-9.][0-9.]*\).*/\1/p')"
    snapshot_commit="$(printf '%s\n' "$benchmark" | sed -n 's/.*snapshot_commit_and_verify_ms=\([0-9.][0-9.]*\).*/\1/p')"
    activity_save="$(printf '%s\n' "$benchmark" | sed -n 's/.*activity_archive_save_queue_ms=\([0-9.][0-9.]*\).*/\1/p')"
    history_save="$(printf '%s\n' "$benchmark" | sed -n 's/.*repository_history_archive_update_ms=\([0-9.][0-9.]*\).*/\1/p')"
    widget_reload="$(printf '%s\n' "$benchmark" | sed -n 's/.*widget_reload_request_api_ms=\([0-9.][0-9.]*\).*/\1/p')"
    widget_reload_calls="$(printf '%s\n' "$benchmark" | sed -n 's/.*widget_reload_request_calls=\([0-9][0-9]*\).*/\1/p')"
    max_rss="$(awk '/maximum resident set size/ { print $1; exit }' "$time_log")"
    footprint="$(awk '/peak memory footprint/ { print $1; exit }' "$time_log")"
    cpu_seconds="$(awk '/ real / { print $3 + $5; exit }' "$time_log")"
    result_signature="$(printf '%s\n' "$benchmark" | sed -n 's/.*refresh_result_signature=\([^ ]*\).*/\1/p')"
    if [[ -z "$elapsed" || -z "$engine_elapsed" || -z "$discovery" || -z "$core_status" || -z "$git_runner" || -z "$git_runner_calls" || -z "$snapshot_build" || -z "$snapshot_build_calls" || -z "$extended" || -z "$merge" || -z "$persist" || -z "$widget" || -z "$git_calls" || -z "$discovery_git_calls" || -z "$core_git_calls" || -z "$extended_git_calls" || -z "$apply_pins" || -z "$snapshot_pins" || -z "$snapshot_read" || -z "$snapshot_commit" || -z "$activity_save" || -z "$history_save" || -z "$widget_reload" || -z "$widget_reload_calls" || -z "$max_rss" || -z "$footprint" || -z "$cpu_seconds" || -z "$result_signature" ]]; then
        echo "sample $sample_id had incomplete measurement data; raw logs: $log, $time_log" >&2
        exit 1
    fi

    defaults delete "$defaults_suite" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$defaults_suite.plist" 2>/dev/null || true
    capture_system_state "$system_tag-after"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$pair" "$label" "$order" "$elapsed" "$engine_elapsed" "$discovery" "$core_status" "$git_runner" "$git_runner_calls" "$snapshot_build" "$snapshot_build_calls" "$extended" "$merge" "$persist" "$widget" "$git_calls" "$discovery_git_calls" "$core_git_calls" "$extended_git_calls" "$apply_pins" "$snapshot_pins" "$snapshot_read" "$snapshot_commit" "$activity_save" "$history_save" "$widget_reload" "$widget_reload_calls" "$max_rss" "$footprint" "$cpu_seconds" "$result_signature" \
        | tee -a "$OUTPUT_DIR/samples.tsv"
    printf '%s\n' "$benchmark" >> "$OUTPUT_DIR/samples.tsv.raw"
}

apply_baseline_isolation_shim() {
    local tree="$1"
    local models="$tree/DevPulseNative/Core/Models.swift"

    # Older baselines predate App Group test isolation. Backport the existing
    # harness seam only when absent; current baselines already contain it.
    if ! grep -q 'containerPathOverrideKey' "$models"; then
        perl -0pi -e 's#enum SharedSnapshotLocation \{\n    static let appGroupIdentifier = "group\.local\.devpulse"\n    static let fileName = "repositories\.json"\n\}#enum SharedSnapshotLocation {\n    static let appGroupIdentifier = "group.local.devpulse"\n    static let fileName = "repositories.json"\n    private static let containerPathOverrideKey = "DEVPULSE_APP_GROUP_CONTAINER_PATH"\n    private static let defaultsSuiteOverrideKey = "DEVPULSE_APP_GROUP_DEFAULTS_SUITE"\n    static func containerURL(forGroupIdentifier identifier: String) -> URL? {\n        if identifier == appGroupIdentifier, let path = ProcessInfo.processInfo.environment[containerPathOverrideKey], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }\n        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)\n    }\n    static var containerURL: URL? { containerURL(forGroupIdentifier: appGroupIdentifier) }\n    static var defaults: UserDefaults? { UserDefaults(suiteName: ProcessInfo.processInfo.environment[defaultsSuiteOverrideKey] ?? appGroupIdentifier) }\n}#s or die "Could not install baseline SharedSnapshotLocation isolation seam\n"' "$models"

        find "$tree/DevPulseNative/Core" -name '*.swift' -exec perl -0pi -e \
            's#FileManager\.default\.containerURL\(\s*forSecurityApplicationGroupIdentifier:\s*(?:SharedSnapshotLocation|AppGroupStore)\.appGroupIdentifier\s*\)#SharedSnapshotLocation.containerURL#sg; s#FileManager\.default\.containerURL\(\s*forSecurityApplicationGroupIdentifier:\s*appGroupIdentifier\s*\)#SharedSnapshotLocation.containerURL(forGroupIdentifier: appGroupIdentifier)#sg; s#UserDefaults\(suiteName:\s*AppGroupStore\.appGroupIdentifier\)#SharedSnapshotLocation.defaults#g' {} +
    fi

    # The benchmark's scheduler probe is measurement-only instrumentation;
    # apply that exact diff to the archived baseline so both variants expose
    # the same observer without importing unrelated production changes.
    git diff "$BASELINE_REV" -- DevPulseNative/Core/ScanScheduler.swift DevPulseNative/Core/RefreshEngine.swift \
        | (cd "$tree" && git apply --directory=.)

    cp "$ROOT_DIR/$TEST_SOURCE" "$tree/$TEST_SOURCE"
    if grep -R -n -E 'FileManager\.default\.containerURL\(|UserDefaults\(suiteName: AppGroupStore\.appGroupIdentifier' \
        "$tree/DevPulseNative/Core" --include='*.swift' | grep -v 'Models.swift'; then
        echo "unredirected App Group storage access remains in the baseline archive" >&2
        exit 1
    fi
}

printf 'pair\tversion\torder\tscheduler_wall_ms\trefresh_engine_ms\tdiscovery_ms\tcore_status_ms\tcore_status_git_runner_sum_ms\tcore_status_git_runner_calls\tcore_status_snapshot_build_sum_ms\tcore_status_snapshot_build_calls\textended_info_ms\tmerge_ms\tengine_persistence_prepare_ms\tengine_widget_deferred_ms\ttotal_git_calls\tdiscovery_git_calls\tcore_status_git_calls\textended_info_git_calls\tscheduler_apply_pins_ms\tsnapshot_prepare_apply_pins_ms\tsnapshot_revision_read_ms\tsnapshot_commit_and_verify_ms\tactivity_archive_save_queue_ms\trepository_history_archive_update_ms\twidget_reload_request_api_ms\twidget_reload_request_calls\tcommand_max_rss_bytes\tcommand_peak_footprint_bytes\tcommand_cpu_user_sys_seconds\trefresh_result_signature\n' \
    > "$OUTPUT_DIR/samples.tsv"
: > "$OUTPUT_DIR/samples.tsv.raw"
{
    printf 'baseline_revision=%s\n' "$BASELINE_REV"
    printf 'candidate_revision='
    git log -1 --format='%H'
    printf 'runs_as_pairs=%s\ntest_spec=%s\n' "$RUNS" "$TEST_SPEC"
    printf 'derived_data_root=%s\noutput_dir=%s\n' "$DERIVED_DATA_PATH" "$OUTPUT_DIR"
    printf '\n'
    sw_vers
    xcodebuild -version
    uptime
    printf '\nhost_architecture='
    uname -m
    for setting in hw.model hw.ncpu hw.memsize machdep.cpu.brand_string; do
        printf '%s=' "$setting"
        sysctl -n "$setting" 2>/dev/null || echo unavailable
    done
    printf '\nactive_build_and_test_processes:\n'
    ps -Ao pid,ppid,%cpu,%mem,etime,command \
        | grep -E '[x]codebuild|[x]ctest|[D]evPulse.*(Test|test)|[/]Applications/DevPulse[^ ]*\.app/' || true
} > "$OUTPUT_DIR/metadata.txt" 2>&1

capture_system_state 'measurement-before-builds'
git archive "$BASELINE_REV" | tar -x -C "$BASELINE_TREE"
apply_baseline_isolation_shim "$BASELINE_TREE"

for project_root in "$BASELINE_TREE" "$ROOT_DIR"; do
    (cd "$project_root/DevPulseNative" && xcodegen generate) \
        > "$OUTPUT_DIR/raw/xcodegen-$( [[ "$project_root" == "$ROOT_DIR" ]] && echo current || echo baseline ).log" 2>&1
 done

build_for_testing baseline "$BASELINE_TREE"
build_for_testing current "$ROOT_DIR"
capture_system_state 'measurement-after-builds-before-samples'

for pair in $(seq 1 "$RUNS"); do
    if (( pair % 2 == 1 )); then
        run_sample "$pair" baseline baseline-first "$BASELINE_TREE"
        run_sample "$pair" current current-second "$ROOT_DIR"
    else
        run_sample "$pair" current current-first "$ROOT_DIR"
        run_sample "$pair" baseline baseline-second "$BASELINE_TREE"
    fi
done

capture_system_state 'measurement-after-samples'

awk -F '\t' '
function median(values, count, sorted, i, j, value) {
    for (i = 1; i <= count; i++) sorted[i] = values[i]
    for (i = 2; i <= count; i++) {
        value = sorted[i]
        j = i - 1
        while (j >= 1 && sorted[j] > value) {
            sorted[j + 1] = sorted[j]
            j--
        }
        sorted[j + 1] = value
    }
    if (count % 2) return sorted[(count + 1) / 2]
    return (sorted[count / 2] + sorted[count / 2 + 1]) / 2
}
NR == 1 { next }
{
    pair = $1
    version = $2
    elapsed = $4 + 0
    engineElapsed = $5 + 0
    discovery = $6 + 0
    coreStatus = $7 + 0
    gitRunner = $8 + 0
    gitRunnerCalls = $9 + 0
    snapshotBuild = $10 + 0
    snapshotBuildCalls = $11 + 0
    extended = $12 + 0
    merge = $13 + 0
    persist = $14 + 0
    widget = $15 + 0
    gitCalls = $16 + 0
    discoveryGitCalls = $17 + 0
    coreGitCalls = $18 + 0
    extendedGitCalls = $19 + 0
    applyPins = $20 + 0
    snapshotPins = $21 + 0
    snapshotRead = $22 + 0
    snapshotCommit = $23 + 0
    activitySave = $24 + 0
    historySave = $25 + 0
    widgetReload = $26 + 0
    widgetReloadCalls = $27 + 0
    rss = $28 + 0
    footprint = $29 + 0
    cpuSeconds = $30 + 0
    resultSignature = $31
    if (version == "baseline") {
        baselineElapsed[++baselineCount] = elapsed
        baselineEngineElapsed[baselineCount] = engineElapsed
        baselineDiscovery[baselineCount] = discovery
        baselineCoreStatus[baselineCount] = coreStatus
        baselineGitRunner[baselineCount] = gitRunner
        baselineGitRunnerCalls[baselineCount] = gitRunnerCalls
        baselineSnapshotBuild[baselineCount] = snapshotBuild
        baselineSnapshotBuildCalls[baselineCount] = snapshotBuildCalls
        baselineExtended[baselineCount] = extended
        baselineMerge[baselineCount] = merge
        baselinePersist[baselineCount] = persist
        baselineWidget[baselineCount] = widget
        baselineGitCalls[baselineCount] = gitCalls
        baselineDiscoveryGitCalls[baselineCount] = discoveryGitCalls
        baselineCoreGitCalls[baselineCount] = coreGitCalls
        baselineExtendedGitCalls[baselineCount] = extendedGitCalls
        baselineApplyPins[baselineCount] = applyPins
        baselineSnapshotPins[baselineCount] = snapshotPins
        baselineSnapshotRead[baselineCount] = snapshotRead
        baselineSnapshotCommit[baselineCount] = snapshotCommit
        baselineActivitySave[baselineCount] = activitySave
        baselineHistorySave[baselineCount] = historySave
        baselineWidgetReload[baselineCount] = widgetReload
        baselineWidgetReloadCalls[baselineCount] = widgetReloadCalls
        baselineRSS[baselineCount] = rss
        baselineFootprint[baselineCount] = footprint
        baselineCPUSec[baselineCount] = cpuSeconds
        if (!baselineSignature) baselineSignature = resultSignature
        if (baselineSignature != resultSignature) signatureMismatch = 1
        pairBaselineElapsed[pair] = elapsed
        pairBaselineEngineElapsed[pair] = engineElapsed
        pairBaselineRSS[pair] = rss
        pairBaselineFootprint[pair] = footprint
    } else {
        currentElapsed[++currentCount] = elapsed
        currentEngineElapsed[currentCount] = engineElapsed
        currentDiscovery[currentCount] = discovery
        currentCoreStatus[currentCount] = coreStatus
        currentGitRunner[currentCount] = gitRunner
        currentGitRunnerCalls[currentCount] = gitRunnerCalls
        currentSnapshotBuild[currentCount] = snapshotBuild
        currentSnapshotBuildCalls[currentCount] = snapshotBuildCalls
        currentExtended[currentCount] = extended
        currentMerge[currentCount] = merge
        currentPersist[currentCount] = persist
        currentWidget[currentCount] = widget
        currentGitCalls[currentCount] = gitCalls
        currentDiscoveryGitCalls[currentCount] = discoveryGitCalls
        currentCoreGitCalls[currentCount] = coreGitCalls
        currentExtendedGitCalls[currentCount] = extendedGitCalls
        currentApplyPins[currentCount] = applyPins
        currentSnapshotPins[currentCount] = snapshotPins
        currentSnapshotRead[currentCount] = snapshotRead
        currentSnapshotCommit[currentCount] = snapshotCommit
        currentActivitySave[currentCount] = activitySave
        currentHistorySave[currentCount] = historySave
        currentWidgetReload[currentCount] = widgetReload
        currentWidgetReloadCalls[currentCount] = widgetReloadCalls
        currentRSS[currentCount] = rss
        currentFootprint[currentCount] = footprint
        currentCPUSec[currentCount] = cpuSeconds
        if (!currentSignature) currentSignature = resultSignature
        if (currentSignature != resultSignature) signatureMismatch = 1
        pairCurrentElapsed[pair] = elapsed
        pairCurrentEngineElapsed[pair] = engineElapsed
        pairCurrentRSS[pair] = rss
        pairCurrentFootprint[pair] = footprint
    }
}
END {
    if (baselineCount < 5 || currentCount < 5 || baselineCount != currentCount) exit 1
    baselineSum = baselineSquareSum = currentSum = currentSquareSum = 0
    for (i = 1; i <= baselineCount; i++) {
        baselineSum += baselineElapsed[i]
        baselineSquareSum += baselineElapsed[i] * baselineElapsed[i]
        currentSum += currentElapsed[i]
        currentSquareSum += currentElapsed[i] * currentElapsed[i]
    }
    pairCount = 0
    fasterElapsed = slowerElapsed = tiedElapsed = 0
    fasterRSS = slowerRSS = tiedRSS = 0
    for (pair in pairBaselineElapsed) {
        n = ++pairCount
        elapsedDelta[n] = pairCurrentElapsed[pair] - pairBaselineElapsed[pair]
        engineElapsedDelta[n] = pairCurrentEngineElapsed[pair] - pairBaselineEngineElapsed[pair]
        rssDelta[n] = pairCurrentRSS[pair] - pairBaselineRSS[pair]
        footprintDelta[n] = pairCurrentFootprint[pair] - pairBaselineFootprint[pair]
        if (elapsedDelta[n] < 0) fasterElapsed++
        else if (elapsedDelta[n] > 0) slowerElapsed++
        else tiedElapsed++
        if (rssDelta[n] < 0) fasterRSS++
        else if (rssDelta[n] > 0) slowerRSS++
        else tiedRSS++
    }
    elapsedMedianDelta = median(elapsedDelta, pairCount)
    for (i = 1; i <= pairCount; i++) absoluteElapsedDelta[i] = (elapsedDelta[i] - elapsedMedianDelta) < 0 ? elapsedMedianDelta - elapsedDelta[i] : elapsedDelta[i] - elapsedMedianDelta
    elapsedMAD = median(absoluteElapsedDelta, pairCount)
    engineMedianDelta = median(engineElapsedDelta, pairCount)
    for (i = 1; i <= pairCount; i++) absoluteEngineDelta[i] = (engineElapsedDelta[i] - engineMedianDelta) < 0 ? engineMedianDelta - engineElapsedDelta[i] : engineElapsedDelta[i] - engineMedianDelta
    engineMAD = median(absoluteEngineDelta, pairCount)
    rssMedianDelta = median(rssDelta, pairCount)
    for (i = 1; i <= pairCount; i++) absoluteRSSDelta[i] = (rssDelta[i] - rssMedianDelta) < 0 ? rssMedianDelta - rssDelta[i] : rssDelta[i] - rssMedianDelta
    rssMAD = median(absoluteRSSDelta, pairCount)
    footprintMedianDelta = median(footprintDelta, pairCount)
    for (i = 1; i <= pairCount; i++) absoluteFootprintDelta[i] = (footprintDelta[i] - footprintMedianDelta) < 0 ? footprintMedianDelta - footprintDelta[i] : footprintDelta[i] - footprintMedianDelta
    footprintMAD = median(absoluteFootprintDelta, pairCount)

    # Exact two-sided sign test over non-tied paired differences. This tests
    # whether paired directions are consistent, not whether one group median
    # exceeds the other group MAD.
    signN = fasterElapsed + slowerElapsed
    minSide = fasterElapsed < slowerElapsed ? fasterElapsed : slowerElapsed
    choose = 1
    tail = 0
    for (k = 0; k <= signN; k++) {
        if (k <= minSide) tail += choose
        if (k < signN) choose = choose * (signN - k) / (k + 1)
    }
    elapsedSignP = signN == 0 ? 1 : 2 * tail / (2 ^ signN)
    if (elapsedSignP > 1) elapsedSignP = 1

    signRSSN = fasterRSS + slowerRSS
    minRSSSide = fasterRSS < slowerRSS ? fasterRSS : slowerRSS
    choose = 1
    tail = 0
    for (k = 0; k <= signRSSN; k++) {
        if (k <= minRSSSide) tail += choose
        if (k < signRSSN) choose = choose * (signRSSN - k) / (k + 1)
    }
    rssSignP = signRSSN == 0 ? 1 : 2 * tail / (2 ^ signRSSN)
    if (rssSignP > 1) rssSignP = 1

    baselineMean = baselineSum / baselineCount
    currentMean = currentSum / currentCount
    baselineSD = sqrt(baselineSquareSum / baselineCount - baselineMean * baselineMean)
    currentSD = sqrt(currentSquareSum / currentCount - currentMean * currentMean)
    printf "metric\tbaseline_median\tcurrent_median\tpaired_median_delta(current-baseline)\tpaired_MAD\tfaster_pairs\tslower_pairs\ttied_pairs\ttwo_sided_sign_p\n"
    printf "scheduler_wall_ms\t%.3f\t%.3f\t%.3f\t%.3f\t%d/%d\t%d/%d\t%d/%d\t%.5f\n", median(baselineElapsed, baselineCount), median(currentElapsed, currentCount), elapsedMedianDelta, elapsedMAD, fasterElapsed, pairCount, slowerElapsed, pairCount, tiedElapsed, pairCount, elapsedSignP
    printf "refresh_engine_ms\t%.3f\t%.3f\t%.3f\t%.3f\n", median(baselineEngineElapsed, baselineCount), median(currentEngineElapsed, currentCount), engineMedianDelta, engineMAD
    printf "stage_medians_ms\tbaseline/current\n"
    printf "discovery\t%.3f\t%.3f\n", median(baselineDiscovery, baselineCount), median(currentDiscovery, currentCount)
    printf "coreStatus\t%.3f\t%.3f\n", median(baselineCoreStatus, baselineCount), median(currentCoreStatus, currentCount)
    printf "coreStatusGitRunner_sum_ms\t%.3f\t%.3f\n", median(baselineGitRunner, baselineCount), median(currentGitRunner, currentCount)
    printf "coreStatusGitRunner_calls\t%.0f\t%.0f\n", median(baselineGitRunnerCalls, baselineCount), median(currentGitRunnerCalls, currentCount)
    printf "coreStatusSnapshotBuild_sum_ms\t%.3f\t%.3f\n", median(baselineSnapshotBuild, baselineCount), median(currentSnapshotBuild, currentCount)
    printf "coreStatusSnapshotBuild_calls\t%.0f\t%.0f\n", median(baselineSnapshotBuildCalls, baselineCount), median(currentSnapshotBuildCalls, currentCount)
    printf "extendedInfo\t%.3f\t%.3f\n", median(baselineExtended, baselineCount), median(currentExtended, currentCount)
    printf "merge\t%.3f\t%.3f\n", median(baselineMerge, baselineCount), median(currentMerge, currentCount)
    printf "enginePersistencePreparation\t%.3f\t%.3f\n", median(baselinePersist, baselineCount), median(currentPersist, currentCount)
    printf "engineWidgetDeferredPlaceholder\t%.3f\t%.3f\n", median(baselineWidget, baselineCount), median(currentWidget, currentCount)
    printf "totalGitCalls\t%.0f\t%.0f\n", median(baselineGitCalls, baselineCount), median(currentGitCalls, currentCount)
    printf "discoveryGitCalls\t%.0f\t%.0f\n", median(baselineDiscoveryGitCalls, baselineCount), median(currentDiscoveryGitCalls, currentCount)
    printf "coreStatusGitCalls\t%.0f\t%.0f\n", median(baselineCoreGitCalls, baselineCount), median(currentCoreGitCalls, currentCount)
    printf "extendedInfoGitCalls\t%.0f\t%.0f\n", median(baselineExtendedGitCalls, baselineCount), median(currentExtendedGitCalls, currentCount)
    printf "schedulerApplyPins\t%.3f\t%.3f\n", median(baselineApplyPins, baselineCount), median(currentApplyPins, currentCount)
    printf "snapshotPrepareApplyPins\t%.3f\t%.3f\n", median(baselineSnapshotPins, baselineCount), median(currentSnapshotPins, currentCount)
    printf "snapshotRevisionRead\t%.3f\t%.3f\n", median(baselineSnapshotRead, baselineCount), median(currentSnapshotRead, currentCount)
    printf "snapshotCommitAndVerify\t%.3f\t%.3f\n", median(baselineSnapshotCommit, baselineCount), median(currentSnapshotCommit, currentCount)
    printf "activityArchiveSaveQueue\t%.3f\t%.3f\n", median(baselineActivitySave, baselineCount), median(currentActivitySave, currentCount)
    printf "repositoryHistoryArchiveUpdate\t%.3f\t%.3f\n", median(baselineHistorySave, baselineCount), median(currentHistorySave, currentCount)
    printf "widgetReloadRequestAPI\t%.3f\t%.3f\n", median(baselineWidgetReload, baselineCount), median(currentWidgetReload, currentCount)
    printf "widgetReloadRequestCalls\t%.0f\t%.0f\n", median(baselineWidgetReloadCalls, baselineCount), median(currentWidgetReloadCalls, currentCount)
    printf "command_max_rss_bytes\t%.0f\t%.0f\t%.0f\t%.0f\t%d/%d\t%d/%d\t%d/%d\t%.5f\n", median(baselineRSS, baselineCount), median(currentRSS, currentCount), rssMedianDelta, rssMAD, fasterRSS, pairCount, slowerRSS, pairCount, tiedRSS, pairCount, rssSignP
    printf "command_peak_footprint_bytes\t%.0f\t%.0f\t%.0f\t%.0f\n", median(baselineFootprint, baselineCount), median(currentFootprint, currentCount), footprintMedianDelta, footprintMAD
    printf "command_cpu_user_sys_seconds\t%.3f\t%.3f\t%.3f\n", median(baselineCPUSec, baselineCount), median(currentCPUSec, currentCount), median(currentCPUSec, currentCount) - median(baselineCPUSec, baselineCount)
    printf "elapsed_group_summary\tbaseline_mean=%.3f\tbaseline_population_sd=%.3f\tcurrent_mean=%.3f\tcurrent_population_sd=%.3f\tpairs=%d\n", baselineMean, baselineSD, currentMean, currentSD, pairCount
    printf "refresh_result_equivalent=%s\n", (signatureMismatch || baselineSignature != currentSignature ? "no" : "yes")
    printf "baseline_result_signature=%s\ncurrent_result_signature=%s\n", baselineSignature, currentSignature
    if (signatureMismatch || baselineSignature != currentSignature) exit 1
    printf "elapsed_improvement_beyond_noise=%s\n", (elapsedMedianDelta < 0 && elapsedSignP < 0.05 ? "yes" : "no")
    printf "elapsed_improved_pairs=%d/%d\n", fasterElapsed, pairCount
    printf "elapsed_paired_median_delta_ms=%.3f\nelapsed_paired_MAD_ms=%.3f\nelapsed_exact_two_sided_sign_p=%.5f\n", elapsedMedianDelta, elapsedMAD, elapsedSignP
}' "$OUTPUT_DIR/samples.tsv" | tee "$OUTPUT_DIR/summary.txt"

awk -F '\t' '
NR == 1 { next }
$2 == "current" { n++; sum += $4; squares += $4 * $4 }
END {
    mean = sum / n
    sd = sqrt(squares / n - mean * mean)
    printf "{\"baselines\":{\"endToEndIncrementalRefresh\":{\"scenario\":\"endToEndIncrementalRefresh\",\"meanElapsed\":%.9f,\"stddevElapsed\":%.9f,\"sampleCount\":%d}},\"schemaVersion\":1}\n", mean / 1000, sd / 1000, n
}' "$OUTPUT_DIR/samples.tsv" > "$OUTPUT_DIR/performance-baselines.json"

printf '\nraw logs, system snapshots, samples, summary, and PerformanceBaselineManager-compatible JSON: %s\n' "$OUTPUT_DIR"

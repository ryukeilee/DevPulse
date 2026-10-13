#!/usr/bin/env bash
# A/B benchmark for the real Git scan chain that `ProcessRunner.runDetailed()`
# drives: process launch, exit/timeout/cancellation observation, output
# collection and child cleanup for every `git status` / `git log` command the
# repository scanner issues against real repositories.
#
# Runs a standalone harness against the current source and, with a baseline git
# ref, against that revision as well. Both variants are compiled with the same
# `swiftc -O -whole-module-optimization` invocation, then run alternately on the
# same real-repository fixture. The driver reports the median of the per-run
# medians plus the main-process CPU, the Git child CPU, the wakeup counts and
# the command counts, and it fails if the per-repository Git output no longer
# matches between variants.
#
# Usage:
#   ./scripts/benchmark-git-command-execution.sh
#   ./scripts/benchmark-git-command-execution.sh --baseline-git <ref>
#   BASELINE_ROOT=<path-to-checkout> ./scripts/benchmark-git-command-execution.sh
#
# Tunables (env): BENCH_REPOS, BENCH_PASSES, BENCH_WARMUP, BENCH_RUNS,
#                 BENCH_CONCURRENCY, BENCH_KEEP_FIXTURE
#
# Cost profile: `git status --porcelain=v2 --branch` plus `git log -1` per
# repository per pass, exactly as a cold scan issues them, executed through the
# scan pipeline's task-group pattern with `ScanConfig.maxConcurrentGitOps`
# concurrency (default 10).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER_REL="DevPulseNative/Utilities/ProcessRunner.swift"
BASELINE_ROOT="${BASELINE_ROOT:-}"

BENCH_REPOS="${BENCH_REPOS:-160}"
BENCH_PASSES="${BENCH_PASSES:-4}"
BENCH_WARMUP="${BENCH_WARMUP:-1}"
BENCH_RUNS="${BENCH_RUNS:-3}"
BENCH_CONCURRENCY="${BENCH_CONCURRENCY:-10}"
export BENCH_REPOS BENCH_PASSES BENCH_WARMUP BENCH_CONCURRENCY

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-git-exec-bench.XXXXXX")"
BASELINE_WORKTREE=""
cleanup() {
    if [[ -n "$BASELINE_WORKTREE" ]]; then
        git -C "$ROOT_DIR" worktree remove --force "$BASELINE_WORKTREE" >/dev/null 2>&1 || true
    fi
    [[ "${BENCH_KEEP_FIXTURE:-0}" == "1" ]] || rm -rf "$TMP_DIR"
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

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="$TMP_DIR/module-cache"
mkdir -p "$MODULE_CACHE"

HARNESS="$TMP_DIR/main.swift"
cat > "$HARNESS" <<'SWIFT'
import CryptoKit
import Darwin
import Foundation

// MARK: - Environment

func envInt(_ key: String, _ fallback: Int) -> Int {
    if let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw), value > 0 {
        return value
    }
    return fallback
}

// MARK: - CPU accounting

struct CPUUsage {
    let selfUser: Double
    let selfSystem: Double
    let childUser: Double
    let childSystem: Double
    let voluntary: Int
    let involuntary: Int

    var selfCPU: Double { selfUser + selfSystem }
    var childCPU: Double { childUser + childSystem }
}

func cpuUsage() -> CPUUsage {
    func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
    var selfUsage = rusage()
    var childUsage = rusage()
    getrusage(RUSAGE_SELF, &selfUsage)
    getrusage(RUSAGE_CHILDREN, &childUsage)
    return CPUUsage(
        selfUser: seconds(selfUsage.ru_utime),
        selfSystem: seconds(selfUsage.ru_stime),
        childUser: seconds(childUsage.ru_utime),
        childSystem: seconds(childUsage.ru_stime),
        voluntary: Int(selfUsage.ru_nvcsw),
        involuntary: Int(selfUsage.ru_nivcsw)
    )
}

func milliseconds(_ value: Double) -> String {
    String(format: "%.3f", value * 1_000)
}

func outcomeName(_ result: ProcessRunResult) -> String {
    switch result {
    case .success: return "success"
    case .nonZero(let code): return "nonZero(\(code))"
    case .timeout: return "timeout"
    case .cancelled: return "cancelled"
    case .launch: return "launch"
    case .unavailable: return "unavailable"
    case .outputLimit: return "outputLimit"
    }
}

// MARK: - Scan workload

struct RepositoryResult: Sendable {
    let index: Int
    let statusResult: ProcessRunResult
    let logResult: ProcessRunResult
    let statusOutput: String
    let logOutput: String
}

/// Mirrors `GitRepositoryScanner.readSingleSnapshot`'s Git usage: a mandatory
/// `git status --porcelain=v2 --branch` followed by the `git log -1` metadata
/// read that a cold scan performs when the head OID is not yet known.
func readRepository(at path: String, index: Int) -> RepositoryResult {
    let statusResult = ProcessRunner.runDetailed(
        arguments: ["status", "--porcelain=v2", "--branch"],
        workingDirectory: path,
        timeout: 5.0,
        outputLimit: ProcessRunner.defaultOutputLimit
    )
    let logResult = ProcessRunner.runDetailed(
        arguments: ["log", "-1", "--pretty=%H%x00%cI%x00%s"],
        workingDirectory: path,
        timeout: 5.0,
        outputLimit: ProcessRunner.defaultOutputLimit
    )
    var statusOutput = ""
    if case .success(let output) = statusResult { statusOutput = output }
    var logOutput = ""
    if case .success(let output) = logResult { logOutput = output }
    return RepositoryResult(
        index: index,
        statusResult: statusResult,
        logResult: logResult,
        statusOutput: statusOutput,
        logOutput: logOutput
    )
}

@main
struct GitCommandExecutionBench {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let fixtureRoot = environment["BENCH_FIXTURE"] ?? ""
        let repositoryCount = envInt("BENCH_REPOS", 160)
        let passCount = envInt("BENCH_PASSES", 4)
        let warmupCount = envInt("BENCH_WARMUP", 1)
        let concurrency = envInt("BENCH_CONCURRENCY", 10)
        let label = environment["BENCH_LABEL"] ?? "unknown"

        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(atPath: fixtureRoot)) ?? []
        let repositories = entries
            .filter { fileManager.fileExists(atPath: fixtureRoot + "/" + $0 + "/.git") }
            .sorted()
            .prefix(repositoryCount)
            .map { fixtureRoot + "/" + $0 }

        guard repositories.count >= repositoryCount else {
            FileHandle.standardError.write(
                Data("fixture incomplete: found \(repositories.count) repositories, need \(repositoryCount)\n".utf8)
            )
            exit(3)
        }

        /// Executes one pass over every repository with the scan pipeline's
        /// bounded task-group concurrency and returns the aggregated metrics.
        func runPass() async -> (wall: Double, fingerprint: String, results: [RepositoryResult]) {
            let startedAt = ProcessInfo.processInfo.systemUptime
            var results = [RepositoryResult](
                repeating: RepositoryResult(
                    index: -1,
                    statusResult: .cancelled,
                    logResult: .cancelled,
                    statusOutput: "",
                    logOutput: ""
                ),
                count: repositories.count
            )

            await withTaskGroup(of: RepositoryResult.self) { group in
                var nextIndex = 0
                func addNextTask() {
                    guard nextIndex < repositories.count else { return }
                    let index = nextIndex
                    let path = repositories[index]
                    nextIndex += 1
                    group.addTask {
                        readRepository(at: path, index: index)
                    }
                }

                for _ in 0..<min(concurrency, repositories.count) {
                    addNextTask()
                }

                var yieldCounter = 0
                while let result = await group.next() {
                    results[result.index] = result
                    yieldCounter += 1
                    if yieldCounter % 8 == 0 {
                        await Task.yield()
                    }
                    addNextTask()
                }
            }

            var hasher = SHA256()
            for result in results.sorted(by: { $0.index < $1.index }) {
                let line = "\(result.index)|\(outcomeName(result.statusResult))|\(result.statusOutput)"
                    + "|\(outcomeName(result.logResult))|\(result.logOutput)\n"
                hasher.update(data: Data(line.utf8))
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (ProcessInfo.processInfo.systemUptime - startedAt, digest, results)
        }

        print("# label=\(label) repos=\(repositories.count) concurrency=\(concurrency) passes=\(passCount) warmup=\(warmupCount)")

        for _ in 0..<warmupCount {
            _ = await runPass()
        }

        var statusCommandCount = 0
        var logCommandCount = 0
        var failureOutcomes: [String: Int] = [:]

        for pass in 1...passCount {
            let before = cpuUsage()
            let (wall, fingerprint, results) = await runPass()
            let after = cpuUsage()

            var passFailureCount = 0
            for result in results {
                statusCommandCount += 1
                logCommandCount += 1
                for outcome in [result.statusResult, result.logResult] {
                    if case .success = outcome { continue }
                    failureOutcomes[outcomeName(outcome), default: 0] += 1
                    passFailureCount += 1
                }
            }
            let failures = failureOutcomes.values.reduce(0, +)
            let passCommandCount = results.count * 2
            let passSelfCPU = after.selfCPU - before.selfCPU
            let passChildCPU = after.childCPU - before.childCPU
            let selfCPUPerCommand = passSelfCPU * 1_000_000 / Double(passCommandCount)
            let childCPUPerCommand = passChildCPU * 1_000_000 / Double(passCommandCount)
            let failureSummary = failureOutcomes.isEmpty
                ? "none"
                : failureOutcomes.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ",")

            print("STAGE git_scan pass=\(pass) wall_ms=\(milliseconds(wall))"
                + " self_user_ms=\(milliseconds(after.selfUser - before.selfUser))"
                + " self_sys_ms=\(milliseconds(after.selfSystem - before.selfSystem))"
                + " self_cpu_ms=\(milliseconds(after.selfCPU - before.selfCPU))"
                + " child_user_ms=\(milliseconds(after.childUser - before.childUser))"
                + " child_sys_ms=\(milliseconds(after.childSystem - before.childSystem))"
                + " child_cpu_ms=\(milliseconds(after.childCPU - before.childCPU))"
                + " voluntary_ctx_switches=\(after.voluntary - before.voluntary)"
                + " involuntary_ctx_switches=\(after.involuntary - before.involuntary)"
                + " commands=\(passCommandCount)"
                + " status_commands=\(results.count)"
                + " log_commands=\(results.count)"
                + " cumulative_commands=\(statusCommandCount + logCommandCount)"
                + " self_cpu_us_per_command=\(String(format: "%.3f", selfCPUPerCommand))"
                + " child_cpu_us_per_command=\(String(format: "%.3f", childCPUPerCommand))"
                + " pass_failures=\(passFailureCount) failures=\(failures) failure_kinds=\(failureSummary)"
                + " fingerprint=\(fingerprint)")
        }
    }
}
SWIFT

fixture_dir="$TMP_DIR/fixture"
echo "Preparing $BENCH_REPOS real Git repositories..."
mkdir -p "$fixture_dir"

make_repository() {
    local path="$1" index="$2"
    mkdir -p "$path/src/core" "$path/src/ui" "$path/docs"
    /usr/bin/git -C "$path" init -q -b main
    printf 'name: repo-%s\n' "$index" > "$path/README.md"
    local file
    for file in alpha beta gamma delta; do
        printf 'export const %s = %s;\n' "$file" "$index" > "$path/src/core/$file.ts"
    done
    for file in panel list; do
        printf 'export const %s = %s;\n' "$file" "$index" > "$path/src/ui/$file.ts"
    done
    printf '# Notes %s\n' "$index" > "$path/docs/notes.md"
    /usr/bin/git -C "$path" add -A
    /usr/bin/git -C "$path" -c user.name=DevPulse -c user.email=bench@example.invalid \
        commit -q -m "Initial commit for repo $index"
    printf 'export const alpha = %s0;\n' "$index" > "$path/src/core/alpha.ts"
    /usr/bin/git -C "$path" add -A
    /usr/bin/git -C "$path" -c user.name=DevPulse -c user.email=bench@example.invalid \
        commit -q -m "Refine alpha in repo $index"

    # Deterministic mix of clean, dirty and untracked working trees.
    case $((index % 4)) in
        0)
            ;;
        1)
            printf 'export const beta = %s1;\n' "$index" > "$path/src/core/beta.ts"
            printf 'pending %s\n' "$index" > "$path/docs/pending.md"
            ;;
        2)
            /usr/bin/git -C "$path" checkout -q -b feature/repo-"$index"
            printf 'export const gamma = %s2;\n' "$index" > "$path/src/core/gamma.ts"
            ;;
        3)
            printf 'export const list = %s3;\n' "$index" > "$path/src/ui/list.ts"
            printf 'scratch %s\n' "$index" > "$path/scratch.tmp"
            /usr/bin/git -C "$path" add "$path/src/ui/list.ts"
            ;;
    esac
}
export -f make_repository

seq 0 $((BENCH_REPOS - 1)) | xargs -P 8 -I {} bash -c 'make_repository "$0/repo-{}" "{}"' "$fixture_dir"

compile() {
    local label_name="$1"
    local root="$2"
    local binary="$TMP_DIR/bench-$label_name"
    xcrun swiftc \
        -O \
        -whole-module-optimization \
        -swift-version 6 \
        -parse-as-library \
        -sdk "$SDK_PATH" \
        -target arm64-apple-macosx14.0 \
        -module-cache-path "$MODULE_CACHE" \
        -o "$binary" \
        "$root/$RUNNER_REL" \
        "$HARNESS" \
        2> "$TMP_DIR/compile-$label_name.log" || {
            echo "error: compilation failed for $label_name (log: $TMP_DIR/compile-$label_name.log)" >&2
            tail -30 "$TMP_DIR/compile-$label_name.log" >&2
            return 1
        }
}

run_variant() {
    local label_name="$1"
    BENCH_LABEL="$label_name" BENCH_FIXTURE="$fixture_dir" "$TMP_DIR/bench-$label_name" >> "$TMP_DIR/$label_name.out"
}

echo "Git command execution benchmark (real repositories from $fixture_dir)"
echo "  repos=$BENCH_REPOS passes=$BENCH_PASSES warmup=$BENCH_WARMUP runs=$BENCH_RUNS concurrency=$BENCH_CONCURRENCY"
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

median_of() {
    local file="$1" field="$2"
    sed -n "s/^STAGE git_scan .*[ =]$field=\([0-9a-f.]*\).*/\1/p" "$file" \
        | sort -g \
        | awk '{ values[NR] = $1 } END { if (NR == 0) { print "n/a" } else { print values[int((NR + 1) / 2)] } }'
}

first_of() {
    local file="$1" field="$2"
    sed -n "s/^STAGE git_scan .*$field=\([0-9a-f.]*\).*/\1/p" "$file" | head -n 1
}

printf '  %-26s %14s %14s %12s\n' "metric" "baseline" "current" "change"
status=0
for field in wall_ms self_cpu_ms self_user_ms self_sys_ms self_cpu_us_per_command child_cpu_ms child_cpu_us_per_command voluntary_ctx_switches involuntary_ctx_switches commands status_commands log_commands pass_failures; do
    baseline_value="$(median_of "$TMP_DIR/baseline.out" "$field")"
    current_value="$(median_of "$TMP_DIR/current.out" "$field")"
    awk -v name="$field" -v b="$baseline_value" -v c="$current_value" 'BEGIN {
        if (b == "n/a" || c == "n/a" || b + 0 == 0) {
            printf "  %-26s %14s %14s %12s\n", name, b, c, "n/a"
        } else {
            printf "  %-26s %14.3f %14.3f %11.1f%%\n", name, b, c, ((c - b) / b) * 100
        }
    }'
done
echo

baseline_fingerprints="$(sed -n 's/^STAGE git_scan .*fingerprint=\([0-9a-f]*\).*/\1/p' "$TMP_DIR/baseline.out" | sort -u)"
current_fingerprints="$(sed -n 's/^STAGE git_scan .*fingerprint=\([0-9a-f]*\).*/\1/p' "$TMP_DIR/current.out" | sort -u)"
baseline_fingerprint_count="$(printf '%s\n' "$baseline_fingerprints" | grep -c .)"
current_fingerprint_count="$(printf '%s\n' "$current_fingerprints" | grep -c .)"

if [[ "$baseline_fingerprint_count" != "1" || "$current_fingerprint_count" != "1" ]]; then
    echo "determinism: UNSTABLE scan fingerprint within a variant (baseline variants: $baseline_fingerprint_count, current variants: $current_fingerprint_count)" >&2
    status=1
elif [[ "$baseline_fingerprints" != "$current_fingerprints" ]]; then
    echo "scan equivalence: MISMATCH" >&2
    echo "  baseline: $baseline_fingerprints" >&2
    echo "  current:  $current_fingerprints" >&2
    status=1
else
    echo "scan equivalence: identical Git output fingerprint across variants and passes ($current_fingerprints)"
fi

baseline_failures="$(median_of "$TMP_DIR/baseline.out" pass_failures)"
current_failures="$(median_of "$TMP_DIR/current.out" pass_failures)"

if [[ "$baseline_failures" != "$current_failures" ]]; then
    echo "failure parity: MISMATCH (baseline=$baseline_failures current=$current_failures)" >&2
    status=1
fi

exit "$status"

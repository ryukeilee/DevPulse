#!/usr/bin/env python3
"""Paired production RefreshEngine/scanner benchmark on isolated temporary repos."""
import argparse
import io
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def sources_at(target, revision):
    if revision:
        archive = subprocess.check_output([
            "git", "archive", revision, "DevPulseNative/App", "DevPulseNative/Core",
            "DevPulseNative/Utilities"], cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(archive)) as archive_file:
            for member in archive_file.getmembers():
                if member.isfile() and member.name.endswith(".swift"):
                    path = target / member.name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(archive_file.extractfile(member).read())
    else:
        for folder in ["App", "Core", "Utilities"]:
            for source in (ROOT / "DevPulseNative" / folder).rglob("*.swift"):
                path = target / source.relative_to(ROOT)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(source.read_bytes())
    return sorted(str(path) for path in target.rglob("*.swift")
                  if path.name != "DevPulseApp.swift")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-git", required=True)
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--repos", type=int, default=24)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--include-scheduler", action="store_true",
                        help="also explore standalone scheduler timing (requires working macOS WidgetKit services)")
    args = parser.parse_args()
    if args.runs < 5 or args.repos < 2:
        parser.error("runs must be >= 5 and repos must be >= 2")
    if args.output.exists():
        parser.error("output already exists; preserve prior evidence")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    report = {"baseline": args.baseline_git, "repos": args.repos, "unborn_repos": args.repos - args.repos // 2,
              "environment": {"sw_vers": subprocess.check_output(["sw_vers"], text=True).strip(),
                              "swift": subprocess.check_output(["xcrun", "swift", "--version"], text=True).strip(),
                              "machine": subprocess.check_output(["uname", "-m"], text=True).strip()},
              "cpu_scope": "RUSAGE_SELF user + system; excludes Git child CPU",
              "scheduler_included": args.include_scheduler, "runtime_diagnostics": [],
              "pairs": [], "summary": {}}
    with tempfile.TemporaryDirectory(prefix="devpulse-git-refresh-") as scratch:
        scratch = Path(scratch)
        binaries = {}
        for label, revision in [("baseline", args.baseline_git), ("candidate", None)]:
            target = scratch / label
            target.mkdir()
            sources = sources_at(target, revision)
            harness = target / "git-refresh.swift"
            harness.write_bytes((ROOT / "scripts/benchmarks/git-refresh.swift").read_bytes())
            binary = target / "benchmark"
            print(f"Compiling {label}…", flush=True)
            result = subprocess.run([
                "xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library",
                "-disable-sandbox", "-whole-module-optimization", "-sdk", sdk,
                "-module-cache-path", str(scratch / "module-cache"),
                *sources, str(harness), "-o", str(binary)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
            if result.returncode:
                log = args.output.with_suffix(".compile.log")
                log.write_text(result.stdout)
                raise SystemExit(f"Compile failed: {log}\n{result.stdout[-8000:]}")
            binaries[label] = binary

        git_environment = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                               GIT_AUTHOR_DATE="2026-01-01T00:00:00Z", GIT_COMMITTER_DATE="2026-01-01T00:00:00Z")
        fixture = scratch / "repos"
        fixture.mkdir()
        for index in range(args.repos):
            repo = fixture / f"repo-{index:03}"
            repo.mkdir()
            def git(*arguments):
                subprocess.run(["/usr/bin/git", "-c", "user.name=Benchmark", "-c",
                                "user.email=benchmark@example.invalid", *arguments], cwd=repo,
                               env=git_environment, check=True, stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE)
            git("init", "-q", "-b", "main")
            for file_index in range(100):
                (repo / f"file-{file_index}.txt").write_text("fixture\n")
            if index < args.repos // 2:
                git("add", ".")
                git("commit", "-q", "-m", "Fixture commit")
                (repo / "file-0.txt").write_text("working tree edit\n")
        for pair in range(args.runs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            data = {"order": order}
            for label in order:
                storage = scratch / f"storage-{pair}-{label}"
                storage.mkdir()
                suite = f"local.devpulse.app.tests.gitbench.{scratch.name}.{pair}.{label}"
                environment = dict(git_environment, BENCH_ROOT=str(fixture), BENCH_STORAGE=str(storage),
                                   BENCH_SCHEDULER="1" if args.include_scheduler else "0",
                                   DEVPULSE_APP_GROUP_CONTAINER_PATH=str(storage),
                                   DEVPULSE_APP_GROUP_DEFAULTS_SUITE=suite)
                run = subprocess.run([str(binaries[label])], env=environment,
                                     capture_output=True, text=True, timeout=120)
                if run.returncode:
                    log = args.output.with_suffix(".runtime.log")
                    log.write_text(run.stdout + run.stderr)
                    raise SystemExit(f"Benchmark failed; log preserved: {log}")
                output = run.stdout
                if run.stderr:
                    report["runtime_diagnostics"].append({"pair": pair + 1, "variant": label,
                        "stderr_lines": len(run.stderr.splitlines()),
                        "sandbox_extension_failure": "sandbox_extension_issue_file failed" in run.stderr})
                data[label] = json.loads(next(line for line in output.splitlines() if line.startswith("{")))
                subprocess.run(["defaults", "delete", suite], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, check=False)
            # Timestamps, paths, and the corrected unborn metadata availability are
            # excluded from the signature; file/branch/commit fields must match.
            for scenario in data["baseline"]:
                if data["baseline"][scenario]["signature"] != data["candidate"][scenario]["signature"]:
                    raise SystemExit(f"Semantic mismatch: pair {pair + 1}, {scenario}")
            report["pairs"].append(data)
            print(f"Pair {pair + 1}: {json.dumps(data, sort_keys=True)}", flush=True)
        for scenario in report["pairs"][0]["baseline"]:
            summary = {}
            for metric in ["wall_ms", "cpu_ms", "status_calls", "log_calls", "peak"]:
                baseline = [p["baseline"][scenario][metric] for p in report["pairs"]]
                candidate = [p["candidate"][scenario][metric] for p in report["pairs"]]
                deltas = [c - b for b, c in zip(baseline, candidate)]
                median_delta = statistics.median(deltas)
                nonzero = [d for d in deltas if d != 0]
                smaller_direction = min(sum(d < 0 for d in nonzero), sum(d > 0 for d in nonzero))
                sign_p = min(1, 2 * sum(math.comb(len(nonzero), k) for k in range(smaller_direction + 1))
                             / 2 ** len(nonzero)) if nonzero else 1
                summary[metric] = {"baseline_median": statistics.median(baseline),
                                   "candidate_median": statistics.median(candidate),
                                   "paired_median_delta": median_delta,
                                   "paired_mad": statistics.median(abs(d - median_delta) for d in deltas),
                                   "faster_pairs": sum(d < 0 for d in deltas), "two_sided_sign_p": sign_p}
            report["summary"][scenario] = summary
    report["scheduler_measurement_valid"] = args.include_scheduler and not any(
        item["sandbox_extension_failure"] for item in report["runtime_diagnostics"])
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report["summary"], indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

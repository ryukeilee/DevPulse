#!/usr/bin/env python3
"""Reproduce: python3 scripts/benchmark-repository-health-engine.py --baseline-git <ref>

A/B benchmark for `RepositoryHealthEngine.assess`, the per-repository health
assessment `ScanScheduler.refreshPendingItems` runs for every repository on a
state-changing refresh.

Each signal assessment needs the entry's `recordedAt` timestamp, and there are
eight such assessments, so the engine used to parse the same ISO-8601 strings up
to eight times per repository (plus the evidence re-parses). This harness
compiles the previous engine and the current one into one process and measures
one full pass over the same fixture:

  Baseline  `assess` parses per signal (the previous implementation)
  Current   `assess` parses each entry once and shares the dates

Both variants are compiled with an injected fixed clock, and the harness prints a
SHA-256 digest of every assessment. Equal digests prove the change is
behavior-preserving; exit status is non-zero when they differ. Timed passes
alternate order, and the fixture exercises all nine signals, including the ones
the unit tests do not cover (unpushed, behind, conflicts, read failures,
recovery).

Tunables (env): BENCH_ENTRIES (space separated entry counts, default "50 250 500"),
                 BENCH_REPOS, BENCH_ITERATIONS
"""
import argparse
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELATIVE = "DevPulseNative/Core/RepositoryHealthEngine.swift"
ENGINE_START = "// MARK: - Health engine\n"
ENGINE_END = "// MARK: - Health diagnostics"

# RepositoryHealthEngine.swift also declares the signal/assessment types and the
# thresholds, which both variants share; only the engine enum differs.
SOURCES = [
    "DevPulseNative/Core/Models.swift",
    "DevPulseNative/Core/ActivityEvent.swift",
    "DevPulseNative/Core/PendingItem.swift",
    "DevPulseNative/Core/CommitReadinessEngine.swift",
    "DevPulseNative/Core/RepositoryHistoryEntry.swift",
]


def shared_and_engine(source: str) -> tuple[str, str]:
    """Split the production file into the shared declarations and the engine."""
    start = source.index(ENGINE_START)
    end = source.index(ENGINE_END)
    shared = source[:start] + source[end:]
    engine = source[start:end]
    assert "let now = Date()" in engine, "engine no longer computes its own clock"
    # Both variants must derive identical durations from a fixed clock.
    engine = engine.replace("let now = Date()", "let now = BenchClock.now")
    return shared, engine


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-git", default="HEAD")
    args = parser.parse_args()

    current_source = (ROOT / RELATIVE).read_text()
    baseline_source = subprocess.check_output(
        ["git", "show", f"{args.baseline_git}:{RELATIVE}"], cwd=ROOT, text=True
    )
    shared, current_engine = shared_and_engine(current_source)
    baseline_shared, baseline_engine = shared_and_engine(baseline_source)
    # Only the engine may differ; if a shared declaration changed, comparing the
    # two engines alone would not prove anything about that change.
    assert baseline_shared == shared, "shared declarations differ; comparison is unsound"

    with tempfile.TemporaryDirectory(prefix="devpulse-health-bench-") as directory:
        tmp = Path(directory)
        (tmp / "Shared.swift").write_text("import Foundation\n" + shared)
        for label, engine in (("Baseline", baseline_engine), ("Current", current_engine)):
            assert "enum RepositoryHealthEngine" in engine
            (tmp / f"{label}.swift").write_text(
                "import Foundation\n" + engine.replace(
                    "enum RepositoryHealthEngine", f"enum {label}HealthEngine"
                )
            )
        binary = tmp / "benchmark"
        sources = [str(tmp / "Shared.swift"), str(tmp / "Baseline.swift"), str(tmp / "Current.swift")]
        sources += [str(ROOT / relative) for relative in SOURCES]
        sources.append(str(ROOT / "DevPulseNative/Utilities/DateFormatting.swift"))
        sources.append(str(ROOT / "scripts/benchmarks/repository-health-engine.swift"))
        subprocess.run(
            [
                "xcrun", "swiftc", "-O", "-whole-module-optimization",
                "-module-cache-path", str(tmp / "cache"),
                "-o", str(binary), *sources,
            ],
            check=True,
        )
        subprocess.run([str(binary)], check=True, env=os.environ.copy())


if __name__ == "__main__":
    main()

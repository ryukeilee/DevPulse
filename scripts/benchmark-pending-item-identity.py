#!/usr/bin/env python3
"""A/B benchmark for pending-item identity derivation.

Reproduce: python3 scripts/benchmark-pending-item-identity.py --baseline-git <ref>

`PendingItem` mints its identity by hashing four fields and hex-encoding the
SHA-256 digest. The encoder was `digest.map { String(format: "%02x", $0) }
.joined()`, which re-enters the C varargs formatter once per byte, and the
initializer computed that digest even when the caller supplied the id — and the
evaluator built a whole throwaway item per rule per repository just to obtain an
expected id. This harness compiles one measurement fixture against a baseline
tree and the working tree.

What the delta covers: every compiled input listed below. The driver prints the
ones whose bytes actually differ (`differing_files=`) rather than asserting a
scope it does not enforce. Against the commit this change was written on those
are `Models.swift` (the shared encoder), `PendingItem.swift` and
`PendingItemEvaluator.swift` (the identity change) plus the call-site swaps in
`WorkspaceModel.swift`, `ActivityEvent.swift` and `RepositoryHistoryEntry.swift`,
so the reported numbers are the composite effect of that set and not of the
initializer alone. `DateFormatting.swift` and `WorkspaceModel.swift` are patched
copies taken from each tree with the production clock pinned, so the evaluation
output is deterministic and byte-comparable.

Every scenario prints a SHA-256 fingerprint of its encoded result. A scenario
that produces no fingerprint is reported as a failure, never as empty-set
equality. The driver exits non-zero when any fingerprint differs, so equal
output is a precondition for reading the timings.

Tunables (env): BENCH_ITERATIONS (in-process rounds per scenario, default 9),
                 BENCH_PAIRS (alternating process pairs, default 5)
"""
import argparse
import difflib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# The harness compares a fingerprint of the encoded evaluation result per
# scenario, so a scenario that produces no fingerprint cannot be checked and is
# reported as a failure rather than as an empty-set equality.
DIFFERING = [
    "DevPulseNative/Core/Models.swift",
    "DevPulseNative/Core/PendingItem.swift",
    "DevPulseNative/Core/PendingItemEvaluator.swift",
]
SHARED = [
    "DevPulseNative/Core/ActivityEvent.swift",
    "DevPulseNative/Core/CommitReadinessEngine.swift",
    "DevPulseNative/Core/RepositoryHistoryEntry.swift",
    "DevPulseNative/Core/RepositoryHealthEngine.swift",
    "DevPulseNative/Core/WorkspaceAggregationEngine.swift",
]

# Compiled from each tree rather than from one shared copy: the only places the
# two builds can differ.
# Read from each tree and rewritten into a patched copy (the production clock is
# pinned in DateFormatting; WorkspaceModel is truncated before the store). They
# still contribute differences to the build, so they are part of the delta.
PATCHED_FROM_TREE = [
    "DevPulseNative/Utilities/DateFormatting.swift",
    "DevPulseNative/Core/WorkspaceModel.swift",
]

COMPILED_FROM_TREE = DIFFERING + SHARED + PATCHED_FROM_TREE


def differing_files(baseline_root: Path) -> list[str]:
    """Compiled inputs whose bytes differ from the working tree.

    The timing delta covers every difference in the compiled sources, so the
    driver states them instead of claiming a scope it does not enforce.
    """
    differing = []
    for relative in COMPILED_FROM_TREE:
        baseline = baseline_root / relative
        if not baseline.exists() or baseline.read_bytes() != (ROOT / relative).read_bytes():
            differing.append(relative)
    return differing

CLOCKED = "isoString(from: Date())"
PINNED = "isoString(from: Date(timeIntervalSince1970: 1770000000))"
WORKSPACE_TRUNCATION = "enum WorkspaceStoreError"


def sign_test_p(wins: int, losses: int) -> float:
    """Exact two-sided sign test p-value."""
    import math

    n = wins + losses
    if n == 0:
        return 1.0
    k = min(wins, losses)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / (2**n)
    return min(1.0, 2 * tail)


def prepare_tree(root: Path, tmp_dir: Path) -> list[str]:
    """Compile inputs for one source tree, with the production clock pinned."""
    tmp_dir.mkdir(parents=True, exist_ok=True)
    clocked = tmp_dir / "DateFormatting.swift"
    date_source = (root / "DevPulseNative/Utilities/DateFormatting.swift").read_text()
    assert CLOCKED in date_source, "DateFormatting no longer derives nowISO from isoString(from: Date())"
    clocked.write_text(date_source.replace(CLOCKED, PINNED))

    workspace = (root / "DevPulseNative/Core/WorkspaceModel.swift").read_text()
    workspace_trimmed = tmp_dir / "WorkspaceModel.swift"
    workspace_trimmed.write_text(workspace[: workspace.index(WORKSPACE_TRUNCATION)])

    return [str(clocked), str(workspace_trimmed)] + [
        str(root / relative) for relative in DIFFERING + SHARED
    ]


def build(tmp: Path, root: Path, label: str) -> Path:
    sources = prepare_tree(root, tmp / label)
    binary = tmp / f"{label}.bin"
    subprocess.run(
        [
            "xcrun", "swiftc", "-O", "-whole-module-optimization",
            "-module-cache-path", str(tmp / "cache"),
            "-o", str(binary),
            *sources,
            str(ROOT / "scripts/benchmarks/pending-item-identity.swift"),
        ],
        check=True,
    )
    return binary


def run(binary: Path, iterations: int, dump: Path | None = None) -> dict[str, tuple[float, str]]:
    environment = os.environ.copy()
    environment["BENCH_ITERATIONS"] = str(iterations)
    if dump is not None:
        dump.mkdir(parents=True, exist_ok=True)
        environment["BENCH_DUMP"] = str(dump)
    completed = subprocess.run(
        [str(binary)], check=True, capture_output=True, text=True, env=environment
    )
    scenarios: dict[str, tuple[float, str]] = {}
    for line in completed.stdout.splitlines():
        fields = dict(part.split("=", 1) for part in line.split())
        scenarios[fields["scenario"]] = (float(fields["median_ms"]), fields.get("fingerprint", ""))
    assert scenarios, f"no scenario output:\n{completed.stdout}\n{completed.stderr}"
    return scenarios


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-git", default="HEAD")
    parser.add_argument("--baseline-root", default="")
    parser.add_argument("--iterations", type=int, default=9)
    parser.add_argument("--pairs", type=int, default=5)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="devpulse-pending-identity-") as directory:
        tmp = Path(directory)
        baseline_root = args.baseline_root
        worktree = None
        if not baseline_root:
            worktree = tmp / "baseline-tree"
            subprocess.run(
                ["git", "-C", str(ROOT), "worktree", "add", "--detach", str(worktree), args.baseline_git],
                check=True, capture_output=True,
            )
            baseline_root = str(worktree)
        try:
            differing = differing_files(Path(baseline_root))
            print(f"differing_files={differing}")
            baseline_binary = build(tmp, Path(baseline_root), "baseline")
            current_binary = build(tmp, ROOT, "current")

            samples: dict[str, dict[str, list[float]]] = {}
            fingerprints: dict[str, dict[str, set[str]]] = {}
            for _ in range(args.pairs):
                for label, binary in (("baseline", baseline_binary), ("current", current_binary)):
                    for name, (ms, fingerprint) in run(binary, args.iterations).items():
                        samples.setdefault(name, {"baseline": [], "current": []})[label].append(ms)
                        if fingerprint:
                            fingerprints.setdefault(name, {"baseline": set(), "current": set()})[label].add(fingerprint)

            mismatching: list[str] = []
            print(f"iterations={args.iterations} pairs={args.pairs}")
            print(f"{'scenario':<26}{'baseline ms':>12}{'current ms':>12}{'paired delta':>14}{'faster':>8}{'p':>9}  equivalent")
            mismatches = 0
            for name in samples:
                baseline = sorted(samples[name]["baseline"])
                current = sorted(samples[name]["current"])
                mid = len(baseline) // 2
                baseline_median = baseline[mid]
                current_median = current[mid]
                deltas = [c - b for b, c in zip(samples[name]["baseline"], samples[name]["current"])]
                paired = sorted(deltas)[len(deltas) // 2]
                wins = sum(1 for delta in deltas if delta < 0)
                losses = sum(1 for delta in deltas if delta > 0)
                p_value = sign_test_p(wins, losses)
                baseline_prints = fingerprints.get(name, {}).get("baseline", set())
                current_prints = fingerprints.get(name, {}).get("current", set())
                if not baseline_prints or not current_prints:
                    equivalent = False
                    note = "NO FINGERPRINT"
                elif baseline_prints == current_prints:
                    equivalent = True
                    note = "yes"
                else:
                    equivalent = False
                    note = "MISMATCH"
                if not equivalent:
                    mismatches += 1
                    mismatching.append(name)
                print(
                    f"{name:<26}{baseline_median:>12.3f}{current_median:>12.3f}"
                    f"{paired:>+14.3f}{f'{wins}/{wins + losses}':>8}{p_value:>9.5f}"
                    f"  {note}"
                )
            print(f"fingerprint_mismatches={mismatches}")
            if mismatches:
                # Re-run both builds into separate dumps so the failing fields
                # are visible instead of only the fact that the digests differ.
                run(baseline_binary, 1, dump=tmp / "dump-baseline")
                run(current_binary, 1, dump=tmp / "dump-current")
                for name in mismatching:
                    left = (tmp / "dump-baseline" / f"{name}.json").read_text()
                    right = (tmp / "dump-current" / f"{name}.json").read_text()
                    print(f"--- {name} (baseline)")
                    print(f"+++ {name} (current)")
                    shown = 0
                    for line in difflib.unified_diff(
                        left.splitlines(), right.splitlines(), lineterm="", n=0
                    ):
                        if line.startswith("---") or line.startswith("+++"):
                            continue
                        print(f"  {line[:400]}")
                        shown += 1
                        if shown >= 12:
                            print("  ... (truncated)")
                            break
                    if shown == 0:
                        print("  identical text but different digests "
                              f"({len(left)} vs {len(right)} chars)")
                raise SystemExit("FAIL: evaluation output differs between baseline and current")
        finally:
            if worktree is not None:
                subprocess.run(
                    ["git", "-C", str(ROOT), "worktree", "remove", "--force", str(worktree)],
                    check=False, capture_output=True,
                )
                shutil.rmtree(worktree, ignore_errors=True)


if __name__ == "__main__":
    main()

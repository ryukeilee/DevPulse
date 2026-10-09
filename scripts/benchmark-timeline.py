#!/usr/bin/env python3
"""A/B the real ActivityTimelineView after in-memory scan result updates.

Only the three production files under optimization differ between variants.
No scheduler, user preferences, repository scanning or App Group I/O is used.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    "Utilities/DateFormatting.swift", "Core/CommitReadinessEngine.swift",
    "Core/Models.swift", "Core/PendingItem.swift", "Core/ActivityEvent.swift",
    "Core/WorkspaceModel.swift", "App/ActivityTimelineView.swift",
]
CHANGED = {"Core/Models.swift", "Core/ActivityEvent.swift", "App/ActivityTimelineView.swift"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-git", default="HEAD")
    parser.add_argument("--repos", type=int, default=1200)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.repos < 8 or args.runs < 1:
        parser.error("repos must be >= 8 and runs must be positive")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    results = {}
    with tempfile.TemporaryDirectory(prefix="devpulse-timeline-") as scratch:
        temp = Path(scratch)
        for label in ["baseline", "candidate"]:
            directory = temp / label
            directory.mkdir()
            sources = []
            for relative in SOURCES:
                source = ROOT / "DevPulseNative" / relative
                code = (subprocess.check_output([
                    "git", "show", f"{args.baseline_git}:DevPulseNative/{relative}"
                ], cwd=ROOT, text=True) if label == "baseline" and relative in CHANGED
                    else source.read_text())
                if relative == "Core/Models.swift":
                    code = code.replace("var decision: RepositoryDecision {", "var decision: RepositoryDecision {\n        BenchCounts.decisions += 1")
                    code = code.replace("RepositoryDecisionEngine.decide(snapshot: self)", "return RepositoryDecisionEngine.decide(snapshot: self)")
                if relative == "App/ActivityTimelineView.swift":
                    code = code.replace("var body: some View {", "var body: some View {\n        let _ = BenchCounts.recordBody()", 1)
                target = directory / source.name
                target.write_text(code)
                sources.append(str(target))
            # Use the production styling without bringing in other pages.
            content = (ROOT / "DevPulseNative/App/ContentView.swift").read_text()
            style = content[content.index("enum DevPulseVisualStyle"):content.index("struct ContentView")]
            styling = directory / "Style.swift"
            styling.write_text("import SwiftUI\n" + style)
            harness = directory / "TimelineBenchmark.swift"
            harness.write_bytes((ROOT / "scripts/benchmarks/timeline-performance.swift").read_bytes())
            binary = directory / "benchmark"
            print(f"Compiling {label}…", flush=True)
            compiled = subprocess.run([
                "xcrun", "swiftc", "-O", "-whole-module-optimization", "-swift-version", "6",
                "-parse-as-library", "-disable-sandbox", "-sdk", sdk,
                "-module-cache-path", str(temp / "modules"), *sources,
                str(styling), str(harness), "-o", str(binary),
            ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
            if compiled.returncode:
                with tempfile.NamedTemporaryFile(mode="w", prefix="devpulse-timeline-compile-", suffix=".log", delete=False) as log:
                    log.write(compiled.stdout)
                raise SystemExit(f"Compilation failed; log: {log.name}\n{compiled.stdout[-6000:]}")
            results[label] = []
            for run in range(args.runs):
                output = subprocess.check_output([str(binary)],
                    env=dict(os.environ, BENCH_REPOS=str(args.repos)), text=True, timeout=120)
                result = json.loads(output.strip())
                results[label].append(result)
                print(f"{label} run {run + 1}: {json.dumps(result, sort_keys=True)}", flush=True)
    report = json.dumps(results, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(report)


if __name__ == "__main__":
    main()

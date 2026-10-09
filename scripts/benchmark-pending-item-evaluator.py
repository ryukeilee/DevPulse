#!/usr/bin/env python3
"""Reproduce: rtk proxy python3 scripts/benchmark-pending-item-evaluator.py --baseline-git <ref>
Compile both evaluators with -O into one process; alternate measurement order.
Only temporary sources receive a fixed clock and an optional shared history index
(for exact ordered equivalence checks, never for timed calls). No git writes.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline-git", required=True)
args = parser.parse_args()
relative = "DevPulseNative/Core/PendingItemEvaluator.swift"
baseline = subprocess.check_output(["git", "show", f"{args.baseline_git}:{relative}"], cwd=root, text=True)
with tempfile.TemporaryDirectory(prefix="devpulse-pending-bench-") as directory:
    tmp = Path(directory)
    sources = []
    def write(name, content):
        path = tmp / name
        path.write_text(content)
        sources.append(str(path))
    for label, source in [("Baseline", baseline), ("Current", (root / relative).read_text())]:
        if label == "Baseline":
            source = "import Foundation\nimport OSLog\n" + source[source.index("// MARK: - Cached assessment helpers"):]
        source = source.replace("enum PendingItemEvaluator", f"enum {label}Evaluator")
        source = source.replace("CachedHealth", f"{label}CachedHealth")
        source = source.replace("previousArchive: PendingItemArchive? = nil", "previousArchive: PendingItemArchive? = nil, previousIndex: [String: PendingItem]? = nil")
        source = source.replace("let previousByID = Dictionary(", "let previousByID = previousIndex ?? Dictionary(")
        write(f"{label}.swift", source)
    date_source = (root / "DevPulseNative/Utilities/DateFormatting.swift").read_text()
    assert "isoString(from: Date())" in date_source
    write("DateFormatting.swift", date_source.replace("isoString(from: Date())", "isoString(from: Date(timeIntervalSince1970: 1770000000))"))
    # Pure workspace models only; persistence is irrelevant to this evaluator benchmark.
    workspace = (root / "DevPulseNative/Core/WorkspaceModel.swift").read_text()
    write("WorkspaceModel.swift", workspace[:workspace.index("enum WorkspaceStoreError")])
    for name in ["CommitReadinessEngine", "Models", "PendingItem", "ActivityEvent",
                 "WorkspaceAggregationEngine", "RepositoryHealthEngine", "RepositoryHistoryEntry"]:
        sources.append(str(root / f"DevPulseNative/Core/{name}.swift"))
    sources.append(str(root / "scripts/benchmarks/pending-item-evaluator.swift"))
    binary = str(tmp / "benchmark")
    subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(tmp / "cache"),
                    "-o", binary, *sources], check=True)
    subprocess.run([binary], check=True, env=os.environ.copy())

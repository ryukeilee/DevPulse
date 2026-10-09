#!/usr/bin/env python3
"""Measure real NSHostingView pages with synthetic data, without scanning user repos.

Usage: python3 scripts/benchmark-tabs.py [--baseline-git 7ada40e] [--repos 1200]
Both variants use identical fixture/instrumentation edits in temporary source copies.
Only tab selection is exposed as a Binding; body and initializer counters are added.
Backup paths and App Group storage are redirected to the temporary directory.
"""
import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PAGES = {
    "ContentView.swift": ["ContentView", "StatusTab", "OverviewFocusCard"],
    "WorkspaceListView.swift": ["WorkspaceListView"],
    "RepositoryListView.swift": ["RepositoryListView"],
    "PendingCenterView.swift": ["PendingCenterView"],
    "ImpactOverviewView.swift": ["ImpactOverviewView"],
    "BackupManagementView.swift": ["BackupManagementView"],
    "SettingsView.swift": ["SettingsView"],
}


def prepare(directory, ref):
    if ref:
        archive = subprocess.check_output([
            "git", "archive", ref, "DevPulseNative/App", "DevPulseNative/Core",
            "DevPulseNative/Utilities",
        ], cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            for member in source.getmembers():
                if member.isfile() and member.name.endswith(".swift"):
                    path = directory / member.name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(source.extractfile(member).read())
    else:
        for folder in ["App", "Core", "Utilities"]:
            for source in (ROOT / "DevPulseNative" / folder).rglob("*.swift"):
                target = directory / source.relative_to(ROOT)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read_bytes())
    app = directory / "DevPulseNative/App"
    for filename, structs in PAGES.items():
        path = app / filename
        code = path.read_text()
        for name in structs:
            start = code.index(f"struct {name}: View")
            position = code.index("var body: some View {", start) + len("var body: some View {")
            code = code[:position] + f'\n        let _ = BenchMetrics.record("{name}")' + code[position:]
        if filename == "ContentView.swift":
            code = code.replace("@State private var selectedTab: AppTab = .overview",
                                "@Binding var selectedTab: AppTab")
        if filename == "RepositoryListView.swift":
            code = code.replace("let preferences = preferencesStore.load()",
                                'BenchMetrics.record("preferencesLoad")\n        let preferences = preferencesStore.load()')
        path.write_text(code)
    backup = app / "BackupManagementView.swift"
    backup.write_text(backup.read_text().replace(
        "private let config: BackupIntegrationConfiguration = .default",
        "private let config: BackupIntegrationConfiguration = BenchFixture.backupConfig"))
    return sorted(str(p) for p in directory.rglob("*.swift") if p.name != "DevPulseApp.swift")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-git")
    parser.add_argument("--repos", type=int, default=1200)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.repos <= 0 or args.runs <= 0:
        parser.error("repos and runs must be positive")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    results = {}
    with tempfile.TemporaryDirectory(prefix="devpulse-tabs-") as scratch:
        temp = Path(scratch)
        variants = [("baseline", args.baseline_git)] if args.baseline_git else []
        variants.append(("candidate", None))
        for label, ref in variants:
            directory = temp / label
            directory.mkdir()
            sources = prepare(directory, ref)
            harness = directory / "tab-performance.swift"
            harness.write_bytes((ROOT / "scripts/benchmarks/tab-performance.swift").read_bytes())
            binary = directory / "devpulse-tab-benchmark"
            print(f"Compiling {label} (optimized Swift 6)…", flush=True)
            compile_result = subprocess.run([
                "xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library", "-disable-sandbox", "-whole-module-optimization",
                "-sdk", sdk, "-module-cache-path", str(temp / "module-cache"),
                *sources, str(harness),
                "-o", str(binary),
            ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
            if compile_result.returncode:
                with tempfile.NamedTemporaryFile(mode="w", prefix="devpulse-tab-compile-", suffix=".log", delete=False) as log:
                    log.write(compile_result.stdout)
                print(compile_result.stdout[-14000:])
                raise SystemExit(f"Compile failed; log preserved: {log.name}")
            results[label] = []
            for run in range(args.runs):
                storage = directory / f"storage-{run}"
                storage.mkdir()
                environment = dict(os.environ,
                    BENCH_REPOS=str(args.repos), BENCH_STORAGE=str(storage),
                    DEVPULSE_APP_GROUP_CONTAINER_PATH=str(storage),
                    DEVPULSE_APP_GROUP_DEFAULTS_SUITE=f"local.devpulse.tabbench.{temp.name}.{label}.{run}")
                output = subprocess.check_output([str(binary)], env=environment, text=True, timeout=180)
                data = json.loads(next(line for line in output.splitlines() if line.startswith('{')))
                results[label].append(data)
                print(f"{label} run {run + 1}: {json.dumps(data, sort_keys=True)}", flush=True)
                subprocess.run(["defaults", "delete", environment["DEVPULSE_APP_GROUP_DEFAULTS_SUITE"]],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    report = json.dumps(results, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(report + "\n")
    print(report)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compare actual root-resolution code and providers with a Git baseline.

Usage: python3 scripts/benchmark-scan-roots.py --baseline-git <ref>
Compiles extracted production Swift with -O, checks exact roots and warnings,
then times alternating pairs (median of 11). Uses temporary filesystem fixtures;
no app preferences, network, directory enumeration or repository-content reads.
Reports root resolution only, not end-to-end scan latency. BENCH_ITERATIONS
sets the pair count. Existing RepositoryIdentity canonicalization is unchanged.
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


def source(path, baseline=False):
    if baseline:
        return subprocess.check_output(["git", "show", f"{args.baseline_git}:{path}"], cwd=root, text=True)
    return (root / path).read_text()


provider_path = "DevPulseNative/Core/ScanLocationProvider.swift"
scheduler_path = "DevPulseNative/Core/ScanScheduler.swift"
models = source("DevPulseNative/Core/Models.swift")
# Real identity normalization, including the existing task-local reuse code.
identity = models[models.index("enum RepositoryIdentity {"):models.index("    static func normalize(_ snapshot:")] + "}\n"
models = models[models.index("struct ScanLocationConfiguration:"):]
baseline = source(scheduler_path, True)
start = baseline.index("    private nonisolated static func resolveScanRootsOffMain(")
end = baseline.index("    private func scanRoots()", start)
old_method = baseline[start:end].replace("private nonisolated static func", "static func", 1)
old_method = old_method.replace("ScanLocationProvider", "BaselineProvider")
current = source(scheduler_path)
start = current.index("enum ScanRootResolver {")
end = current.index("/// Manages background scan scheduling", start)
resolver = current[start:end].replace("ScanLocationProvider", "CurrentProvider")
start = current.index("    private nonisolated static func resolveScanRootsOffMain(")
end = current.index("    private func scanRoots()", start)
new_method = current[start:end].replace("private nonisolated static func", "static func", 1)

harness = r'''
struct Scenario {
    let name: String
    let configuration: ScanLocationConfiguration
    let rounds: Int
}
let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
let existing = fixture.appendingPathComponent("existing")
let alias = fixture.appendingPathComponent("alias")
let regularFile = fixture.appendingPathComponent("file")
let missing = fixture.appendingPathComponent("missing")
let container = fixture.appendingPathComponent("Library/Containers/other.app/root")
try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: existing)
try Data().write(to: regularFile)
// Real security-scoped bookmark resolution (both valid and invalid bytes).
let bookmark = try existing.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
func config(_ entries: [CustomScanDirectory], builtIns: Set<String> = []) -> ScanLocationConfiguration {
    ScanLocationConfiguration(enabledBuiltInPaths: builtIns, customDirectories: entries)
}
let scenarios = [
    Scenario(name: "empty", configuration: config([]), rounds: 100),
    Scenario(name: "built-ins", configuration: config([], builtIns: CurrentProvider.builtInAbsoluteSet), rounds: 40),
    Scenario(name: "custom", configuration: config([CustomScanDirectory(path: existing.path)]), rounds: 80),
    Scenario(name: "mixed-boundaries", configuration: config([
        CustomScanDirectory(path: alias.path), CustomScanDirectory(path: existing.path),
        CustomScanDirectory(path: missing.path), CustomScanDirectory(path: regularFile.path),
        CustomScanDirectory(path: container.path),
        CustomScanDirectory(path: missing.path, bookmarkData: bookmark),
        CustomScanDirectory(path: existing.path, bookmarkData: Data([9]))
    ]), rounds: 40),
    Scenario(name: "custom-100", configuration: config((0..<100).map {
        CustomScanDirectory(path: fixture.appendingPathComponent("missing-\($0)").path)
    }), rounds: 3),
    Scenario(name: "bookmark", configuration: config([CustomScanDirectory(path: missing.path, bookmarkData: bookmark)]), rounds: 40)
]
var checksum = 0
func resolve(_ config: ScanLocationConfiguration, current: Bool) -> (roots: [String], warning: String?) {
    if current { return Current.resolveScanRootsOffMain(locationConfig: config) }
    return Baseline.resolveScanRootsOffMain(locationConfig: config, capturedConfig: ScanConfig())
}
func time(_ scenario: Scenario, current: Bool) -> Double {
    let clock = ContinuousClock()
    let start = clock.now
    for _ in 0..<scenario.rounds {
        let result = resolve(scenario.configuration, current: current)
        checksum &+= result.roots.count + (result.warning?.utf8.count ?? 0)
    }
    let elapsed = start.duration(to: clock.now).components
    return (Double(elapsed.seconds) * 1e9 + Double(elapsed.attoseconds) / 1e9) / Double(scenario.rounds)
}
func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
let iterations = max(3, Int(ProcessInfo.processInfo.environment["BENCH_ITERATIONS"] ?? "11") ?? 11)
print("Swift -O root-resolution only; alternating pairs=\(iterations); median ns/call")
// A broader pure membership equivalence matrix, independent of timing.
let home = CurrentProvider.resolvedUserHomeDirectory()
for path in CurrentProvider.builtInLocations + CurrentProvider.builtInAbsolute + [
    "", "~", "~/Developer/", "~/Developer/child", " ~/Developer ",
    home + "/Library/Containers/local.devpulse.app/Data/Projects",
    home + "/Library/Containers/other.app/Data/Projects", fixture.path
] {
    precondition(BaselineProvider.isBuiltInPath(path) == CurrentProvider.isBuiltInPath(path))
    for force in [false, true] {
        precondition(BaselineProvider.canonicalExistingFilePath(path, resolveBuiltIn: force)
            == CurrentProvider.canonicalExistingFilePath(path, resolveBuiltIn: force))
    }
}
for scenario in scenarios {
    let old = resolve(scenario.configuration, current: false)
    let new = resolve(scenario.configuration, current: true)
    precondition(old.roots == new.roots && old.warning == new.warning, "mismatch: \(scenario.name)")
    _ = time(scenario, current: false); _ = time(scenario, current: true)
    var before: [Double] = [], after: [Double] = []
    for pair in 0..<iterations {
        if pair % 2 == 0 {
            before.append(time(scenario, current: false)); after.append(time(scenario, current: true))
        } else {
            after.append(time(scenario, current: true)); before.append(time(scenario, current: false))
        }
    }
    let a = median(before), b = median(after)
    print(String(format: "%@ equivalent=true baseline_ns=%.0f current_ns=%.0f speedup=%.2fx", scenario.name, a, b, a / max(1, b)))
}
print("checksum=\(checksum)")
'''
with tempfile.TemporaryDirectory(prefix="devpulse-roots-bench-") as directory:
    tmp = Path(directory)
    swift = tmp / "main.swift"
    swift.write_text(
        "import Foundation\nimport Darwin\nimport CryptoKit\n"
        + "struct ScanConfig {}\nstruct ScanLocationToggle { let id: String; let path: String; let isEnabled: Bool; let isBuiltIn: Bool }\n"
        + identity + models
        + source(provider_path, True).replace("ScanLocationProvider", "BaselineProvider")
        + source(provider_path).replace("ScanLocationProvider", "CurrentProvider")
        + resolver + "enum Baseline {\n" + old_method + "}\n"
        + "enum Current {\n" + new_method + "}\n" + harness
    )
    binary = tmp / "benchmark"
    subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(tmp / "cache"), str(swift), "-o", str(binary)], check=True)
    fixtures = tmp / "fixtures"
    fixtures.mkdir()
    subprocess.run([str(binary), str(fixtures)], check=True, env=os.environ.copy())

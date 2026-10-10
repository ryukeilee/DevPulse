#!/usr/bin/env python3
"""A/B benchmark for DateFormatting timestamp parsing and formatting.

Compiles the same driver twice — once against the DateFormatting from a baseline
git ref and once against the working tree — and alternates the measurement order
so per-run drift cannot favour either side. The driver also emits a fingerprint
of every derived value, so a reported speedup is only accepted when both sides
produced identical output.

Usage:
    python3 scripts/benchmark-date-formatting.py --baseline-git <ref>
    python3 scripts/benchmark-date-formatting.py --baseline-git <ref> --expectation non-regression

Tunables (env): BENCH_TIMESTAMPS (default 2000), BENCH_ROWS (default 250),
BENCH_ITERATIONS (default 5).
"""

import argparse
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
RELATIVE = "DevPulseNative/Utilities/DateFormatting.swift"

DRIVER = r'''
import Foundation

func envInt(_ key: String, _ fallback: Int) -> Int {
    if let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw), value > 0 {
        return value
    }
    return fallback
}

let timestampCount = envInt("BENCH_TIMESTAMPS", 2000)
// The per-row workload runs several derivations per item, so it uses a smaller
// slice. Both sides use the same slice, so the ratio stays comparable.
let rowCount = min(timestampCount, envInt("BENCH_ROWS", 250))

// Fixture shapes that mirror what the app stores and reads.
//  * `plain`     - DateFormatting.isoString output, and git `%cI` uses the same
//                  shape with an offset instead of `Z`.
//  * `offset`    - `%cI` output for a repository committed outside UTC.
//  * `fractional`- fractional-second strings, which take the fallback path.
let base = Date(timeIntervalSince1970: 1_770_000_000)

func plainStamps(_ count: Int) -> [String] {
    let formatter = ISO8601DateFormatter()
    return (0..<count).map { formatter.string(from: base.addingTimeInterval(Double($0) * 37)) }
}

func fractionalStamps(_ count: Int) -> [String] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (0..<count).map { formatter.string(from: base.addingTimeInterval(Double($0) * 37 + 0.125)) }
}

func offsetStamps(_ count: Int) -> [String] {
    // `%cI` shape: no fractional seconds, explicit numeric offset.
    let offsets = ["+08:00", "-05:00", "+05:30", "-08:00", "+01:00", "-03:00"]
    let dates = plainStamps(count)
    return dates.enumerated().map { index, stamp in
        String(stamp.dropLast()) + offsets[index % offsets.count]
    }
}

let plain = plainStamps(timestampCount)
let offset = offsetStamps(timestampCount)
let fractional = fractionalStamps(timestampCount)

// FNV-1a over every derived string: cheap enough not to distort the timing,
// while still catching any difference in the values either side produces.
var fingerprint: UInt64 = 0xcbf2_9ce4_8422_2325

func absorb(_ value: String) {
    for byte in value.utf8 {
        fingerprint = (fingerprint ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
    fingerprint = (fingerprint ^ 0x0A) &* 0x0000_0100_0000_01B3
}

// MARK: - Workloads

struct Workload {
    let name: String
    let body: () -> Void
}

// 1. Canonical `Z` timestamps: the shape this app writes.
let parseCanonical = Workload(name: "parse_canonical") {
    for stamp in plain {
        if let date = DateFormatting.date(from: stamp) {
            absorb(String(date.timeIntervalSince1970))
        } else {
            absorb("nil")
        }
    }
}

// 2. Canonical numeric-offset timestamps: the shape git `%cI` produces.
let parseOffset = Workload(name: "parse_offset") {
    for stamp in offset {
        if let date = DateFormatting.date(from: stamp) {
            absorb(String(date.timeIntervalSince1970))
        } else {
            absorb("nil")
        }
    }
}

// 3. Fractional-second timestamps: the fallback path.
let parseFractional = Workload(name: "parse_fractional") {
    for stamp in fractional {
        if let date = DateFormatting.date(from: stamp) {
            absorb(String(date.timeIntervalSince1970))
        } else {
            absorb("nil")
        }
    }
}

// 4. ISO output.
let iso = Workload(name: "iso_string") {
    for stamp in plain {
        if let date = DateFormatting.date(from: stamp) {
            absorb(DateFormatting.isoString(from: date))
        }
    }
}

// 5. Chinese relative labels, as rendered per repository row.
let relative = Workload(name: "relative_time_chinese") {
    for stamp in plain {
        absorb(DateFormatting.relativeTimeChinese(from: stamp, relativeTo: base) ?? "nil")
    }
}

// 6. Absolute display strings, as used by health evidence.
let display = Workload(name: "display_string") {
    for stamp in plain {
        if let date = DateFormatting.date(from: stamp) {
            absorb(DateFormatting.displayString(from: date))
        }
    }
}

// 7. One repository row worth of timestamp derivation, mirroring
//    RepositoryListItemPresentationBuilder: the data-source label and the
//    latest-commit label each format once on their own, and the recent-activity
//    label parses both candidate timestamps before formatting the winner.
let repositoryRow = Workload(name: "repository_row_derivation") {
    for index in 0..<rowCount {
        let lastActivityAt = index % 3 == 0 ? fractional[index] : plain[index]
        let lastChangedAt = plain[index]
        absorb(DateFormatting.relativeTimeChinese(from: plain[index], relativeTo: base) ?? "nil")
        absorb(DateFormatting.relativeTimeChinese(from: plain[index], relativeTo: base) ?? "nil")
        var winner: (String, Date)?
        let parser = DateFormatting.TimestampParser()
        for candidate in [lastActivityAt, lastChangedAt] {
            guard let date = parser.date(from: candidate) else { continue }
            if winner == nil || winner!.1 < date { winner = (candidate, date) }
        }
        if let winner {
            absorb(DateFormatting.relativeTimeChinese(from: winner.0, relativeTo: base) ?? "nil")
        }
    }
}

let workloads = [parseCanonical, parseOffset, parseFractional, iso, relative, display, repositoryRow]

// Warm up every workload, then time each one in isolation.
for workload in workloads { workload.body() }

var timings: [String: Double] = [:]
for workload in workloads {
    let start = ProcessInfo.processInfo.systemUptime
    workload.body()
    timings[workload.name] = ProcessInfo.processInfo.systemUptime - start
}

print(String(format: "FINGERPRINT %016llx", fingerprint))
for name in workloads.map(\.name) {
    print(String(format: "TIME %@ %.9f", name, timings[name]!))
}
'''


def build(directory: Path, date_source: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / "main.swift"
    source.write_text(DRIVER)
    formatting = directory / "DateFormatting.swift"
    formatting.write_text(date_source)
    binary = directory / "bench"
    subprocess.run(
        ["xcrun", "swiftc", "-O", "-o", str(binary), str(source), str(formatting)],
        check=True,
        cwd=directory,
    )
    return binary


def run(binary: Path) -> tuple[str, dict[str, float]]:
    output = subprocess.check_output([str(binary)], text=True,
                                     env={**os.environ})
    fingerprint = ""
    timings: dict[str, float] = {}
    for line in output.splitlines():
        if line.startswith("FINGERPRINT "):
            fingerprint = line.split(" ", 1)[1]
        elif line.startswith("TIME "):
            _, name, value = line.split(" ")
            timings[name] = float(value)
    return fingerprint, timings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--baseline-git", required=True)
    parser.add_argument("--expectation", choices=["gain", "non-regression"], default="gain")
    args = parser.parse_args()

    iterations = int(os.environ.get("BENCH_ITERATIONS", "5"))
    baseline_source = subprocess.check_output(
        ["git", "show", f"{args.baseline_git}:{RELATIVE}"], cwd=root, text=True
    )
    current_source = (root / RELATIVE).read_text()

    with tempfile.TemporaryDirectory(prefix="devpulse-date-bench-") as directory:
        tmp = Path(directory)
        baseline_binary = build(tmp / "baseline", baseline_source)
        current_binary = build(tmp / "current", current_source)

        baseline_samples: dict[str, list[float]] = {}
        current_samples: dict[str, list[float]] = {}
        fingerprints: dict[str, str] = {}

        for iteration in range(iterations):
            # Alternate which side is measured first.
            order = [(baseline_binary, baseline_samples, "baseline"),
                     (current_binary, current_samples, "current")]
            if iteration % 2:
                order.reverse()
            for binary, samples, label in order:
                fingerprint, timings = run(binary)
                fingerprints.setdefault(label, fingerprint)
                for name, value in timings.items():
                    samples.setdefault(name, []).append(value)

        if fingerprints.get("baseline") != fingerprints.get("current"):
            print("ERROR: baseline and current derived different values — "
                  "the change is not behavior-preserving.")
            return 2

    print(f"baseline ref: {args.baseline_git}")
    print(f"timestamps per workload: {os.environ.get('BENCH_TIMESTAMPS', '2000')}, "
          f"iterations: {iterations}")
    print(f"output fingerprint: {fingerprints['baseline']}")
    print()
    print(f"{'workload':<28}{'baseline ms':>13}{'current ms':>13}{'speedup':>10}")
    failed = False
    for name in baseline_samples:
        baseline_best = min(baseline_samples[name])
        current_best = min(current_samples[name])
        speedup = baseline_best / current_best if current_best > 0 else float("inf")
        print(f"{name:<28}{baseline_best * 1000:>13.3f}{current_best * 1000:>13.3f}{speedup:>9.2f}x")
        if args.expectation == "gain" and speedup <= 1.0:
            failed = True

    # Median across the repeated pairs, as a drift-resistant secondary signal.
    print()
    for name in baseline_samples:
        baseline_median = statistics.median(baseline_samples[name])
        current_median = statistics.median(current_samples[name])
        if current_median > baseline_median * 1.05:
            print(f"WARNING: {name} median regressed "
                  f"({baseline_median * 1000:.3f} ms -> {current_median * 1000:.3f} ms)")
            failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

import Foundation

// Fixture for `scripts/benchmark-ignored-path-lookup.sh`.
//
// `ScanScheduler.lastDiscoveredRepositoryPaths` normalizes the persisted
// discovered-path list, dropping ignored repositories. Its filter used to read
// the `ignoredRepositoryPaths` computed property inside the closure, and that
// property canonicalizes every ignored path against the filesystem — so the
// accessor resolved `discovered x ignored` paths instead of
// `discovered + ignored`.
//
// This harness reproduces both forms over real directories (so
// `RepositoryIdentity.canonicalPath` performs the same existence and symlink
// resolution as production), times them without a reuse scope, and counts the
// filesystem resolutions with a counting scope. Half of each ignored set is a
// subset of the discovered paths so the filter has to drop real entries; the
// other half is not, matching a repository ignored while outside the current
// discovery scope. Both forms must return the identical array or the run fails.

private let iterations = max(1, Int(ProcessInfo.processInfo.environment["BENCH_ITERATIONS"] ?? "5") ?? 5)
private let sizes: [(discovered: Int, ignored: Int)] =
    (ProcessInfo.processInfo.environment["BENCH_SIZES"] ?? "8:10 60:10 240:10 1200:10 240:0")
    .split(whereSeparator: { $0 == " " })
    .compactMap { entry -> (Int, Int)? in
        let parts = entry.split(separator: ":")
        guard parts.count == 2, let discovered = Int(parts[0]), let ignored = Int(parts[1]) else { return nil }
        return (discovered, ignored)
    }

private func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
}

private func makeDirectories(count: Int, prefix: String, root: URL) -> [String] {
    var paths: [String] = []
    for index in 0..<count {
        let url = root.appendingPathComponent("\(prefix)-\(index)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        paths.append(url.path)
    }
    return paths
}

/// The previous accessor: the ignore set is rebuilt for every discovered path.
private func ignoredSetInsideFilter(_ discovered: [String], _ ignored: [String]) -> [String] {
    Array(Set(discovered.map(RepositoryIdentity.canonicalPath)))
        .filter { !RepositoryScope.canonicalPathSet(ignored).contains($0) }
        .sorted()
}

/// The current accessor: the ignore set is resolved once per access.
private func ignoredSetResolvedOnce(_ discovered: [String], _ ignored: [String]) -> [String] {
    let ignoredPaths = RepositoryScope.canonicalPathSet(ignored)
    return Array(Set(discovered.map(RepositoryIdentity.canonicalPath)))
        .filter { !ignoredPaths.contains($0) }
        .sorted()
}

private func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted[sorted.count / 2]
}

/// Median wall time over `iterations` runs. The result is consumed so the
/// optimizer cannot elide the work; an empty result is legitimate when every
/// discovered path is ignored, so it is not treated as a failure.
private func time(_ sink: inout Int, _ body: () -> [String]) -> Double {
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        sink &+= result.count
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        samples.append(elapsed)
    }
    return median(samples)
}

/// Count filesystem resolutions by running with reuse disabled: every call then
/// reaches `computeCanonicalPath`, and the scope's ledger reports how often.
private func resolutions(_ body: () -> [String]) -> Int {
    let scope = RepositoryIdentity.CanonicalizationScope(reuseEnabled: false)
    _ = RepositoryIdentity.withCanonicalizationScopeSync(scope, body)
    return scope.metrics.computations
}

@main
struct Main {
    static func main() {
        // A per-run directory: a fixed path made two concurrent runs delete each
        // other's fixtures.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devpulse-ignored-path-bench-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        print("iterations=\(iterations)")
        print(pad("discovered:ignored", 20)
            + pad("inside-filter ms", 18)
            + pad("once-per-access ms", 20)
            + pad("resolutions", 26)
            + pad("kept", 9)
            + "equivalent")

        var sink = 0
        var mismatches = 0
        for (discoveredCount, ignoredCount) in sizes {
            let discovered = makeDirectories(count: discoveredCount, prefix: "repo", root: root)
            let fromDiscovered = min(ignoredCount / 2, discoveredCount)
            let ignored = Array(discovered.prefix(fromDiscovered))
                + makeDirectories(count: ignoredCount - fromDiscovered, prefix: "ignored", root: root)

            let previous = ignoredSetInsideFilter(discovered, ignored)
            let current = ignoredSetResolvedOnce(discovered, ignored)
            let equivalent = previous == current
            if !equivalent { mismatches += 1 }

            let previousResolutions = resolutions { ignoredSetInsideFilter(discovered, ignored) }
            let currentResolutions = resolutions { ignoredSetResolvedOnce(discovered, ignored) }

            print(pad("\(discoveredCount):\(ignoredCount)", 20)
                + pad(String(format: "%.3f", time(&sink) { ignoredSetInsideFilter(discovered, ignored) }), 18)
                + pad(String(format: "%.3f", time(&sink) { ignoredSetResolvedOnce(discovered, ignored) }), 20)
                + pad("\(previousResolutions) -> \(currentResolutions)", 26)
                + pad("\(current.count)/\(discoveredCount)", 9)
                + (equivalent ? "yes" : "MISMATCH"))
        }

        if sink == 0 {
            FileHandle.standardError.write(Data("FAIL: no work measured\n".utf8))
            exit(1)
        }
        if mismatches != 0 {
            FileHandle.standardError.write(Data("FAIL: \(mismatches) output mismatch(es)\n".utf8))
            exit(1)
        }
    }
}

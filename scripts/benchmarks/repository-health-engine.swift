import Foundation
import CryptoKit

/// Fixed clock injected into both engine variants, so every wall-clock-derived
/// duration (and therefore every evidence string) is identical across variants
/// and their output can be compared byte for byte.
enum BenchClock {
    static let now = Date(timeIntervalSince1970: 1_770_000_000)
}

/// Consumes the measurement result outside the timed interval so the optimizer
/// cannot discard the work being measured.
enum BenchSink {
    nonisolated(unsafe) static var value = 0
}

private let stamp = "2026-02-02T02:40:00Z"

private func snapshot(
    repositoryID: String,
    branch: String,
    changedCount: Int,
    aheadCount: Int,
    behindCount: Int,
    conflictedCount: Int,
    dataSource: RepositoryDataSource,
    lastCommitID: String?,
    errorMessage: String?
) -> RepositorySnapshot {
    RepositorySnapshot(
        id: repositoryID,
        name: repositoryID,
        path: "/synthetic/\(repositoryID)",
        workspaceKind: nil,
        branch: branch,
        status: changedCount > 0 ? .changed : .clean,
        modifiedFileCount: changedCount,
        addedFileCount: 0,
        deletedFileCount: 0,
        untrackedFileCount: 0,
        stagedFileCount: nil,
        unstagedFileCount: nil,
        conflictedFileCount: conflictedCount > 0 ? conflictedCount : nil,
        aheadCount: aheadCount,
        behindCount: behindCount,
        hasUpstream: true,
        changedFileCount: changedCount,
        changedFilesPreview: [],
        risk: .low,
        lastScannedAt: stamp,
        dataSource: dataSource,
        lastSuccessfulScanAt: stamp,
        lastChangedAt: nil,
        lastCommitID: lastCommitID,
        lastCommitSummary: nil,
        lastCommitMetadataAvailable: nil,
        lastActivityAt: nil,
        unavailableSince: nil,
        errorMessage: errorMessage,
        isPinned: false
    )
}

/// Three repository shapes cover every signal branch: an active repository
/// anchored at the clock (all recency-window signals), one that went quiet ten
/// days ago (stale activity via its latest activity), and one that was never
/// active (stale activity via its first record).
private func fixtureEntries(repositoryID: String, entryCount: Int, variant: Int) -> [RepositoryHistoryEntry] {
    let shape = variant % 3
    let offsetDays = shape == 0 ? 0 : (shape == 1 ? 10 : 40)
    let dormant = shape == 2
    return (0..<entryCount).map { index in
        // `ordinal` is 0 for the newest entry; the engine sorts oldest first.
        let ordinal = entryCount - 1 - index
        let recordedAt = DateFormatting.isoString(
            from: BenchClock.now
                .addingTimeInterval(-Double(offsetDays) * 86400)
                .addingTimeInterval(-Double(ordinal) * 1800)
        )
        // The newest three entries climb, which is the non-decreasing window the
        // creeping-changes signal reads.
        let isCreepingWindow = index >= entryCount - 3
        let changedCount = dormant
            ? 0
            : (isCreepingWindow ? (index - (entryCount - 3) + 1) * 4 : (index % 3 == 0 ? (index % 9) + 1 : 0))
        let branch = !dormant && index % 5 == 0 ? "feature/\((index + variant) % 11)" : "main"
        let readsFailed = !dormant && index % 17 == 0
        let kind: HistoryEntryKind
        if dormant || isCreepingWindow {
            kind = .scanRecord
        } else if readsFailed {
            kind = .becameUnavailable
        } else if index % 13 == 0 {
            kind = .recovery
        } else {
            kind = .scanRecord
        }
        return RepositoryHistoryEntry(
            repositoryID: repositoryID,
            recordedAt: recordedAt,
            kind: kind,
            state: HistoryStatePoint(snapshot: snapshot(
                repositoryID: repositoryID,
                branch: branch,
                changedCount: changedCount,
                aheadCount: dormant ? 0 : (index % 5 == 0 ? (index % 4) + 1 : 0),
                behindCount: dormant ? 0 : (index % 7 == 0 ? (index % 3) + 1 : 0),
                conflictedCount: dormant ? 0 : (index % 11 == 0 ? 1 : 0),
                dataSource: readsFailed && !isCreepingWindow ? .lastSuccessful : .current,
                lastCommitID: dormant ? nil : "commit-\(branch)-\(changedCount)",
                errorMessage: readsFailed ? "read failed at \(index)" : nil
            ))
        )
    }
}

private struct FixtureRepository {
    let id: String
    let name: String
    let entries: [RepositoryHistoryEntry]
}

private func makeFixture(repoCount: Int, entryCount: Int) -> [FixtureRepository] {
    (0..<repoCount).map { repoIndex in
        let id = "repo-\(repoIndex)"
        return FixtureRepository(
            id: id,
            name: "repo \(repoIndex)",
            entries: fixtureEntries(repositoryID: id, entryCount: entryCount, variant: repoIndex)
        )
    }
}

private func assess(
    _ fixture: [FixtureRepository],
    _ run: (String, String, [RepositoryHistoryEntry]) -> RepositoryHealthAssessment
) -> [RepositoryHealthAssessment] {
    fixture.map { run($0.id, $0.name, $0.entries) }
}

private func baselineAssessment(_ id: String, _ name: String, _ entries: [RepositoryHistoryEntry]) -> RepositoryHealthAssessment {
    BaselineHealthEngine.assess(repositoryID: id, repositoryName: name, entries: entries, assessedAt: stamp)
}

private func currentAssessment(_ id: String, _ name: String, _ entries: [RepositoryHistoryEntry]) -> RepositoryHealthAssessment {
    CurrentHealthEngine.assess(repositoryID: id, repositoryName: name, entries: entries, assessedAt: stamp)
}

private func digest(_ assessments: [RepositoryHealthAssessment]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(assessments)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func measure(_ operation: () -> [RepositoryHealthAssessment]) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = operation()
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    // Consume the result outside the measured interval.
    BenchSink.value &+= result.count
    return Double(elapsed) / 1_000_000
}

private func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted[sorted.count / 2]
}

/// The nine signals the engine can emit; the fixture must exercise all of them
/// so an equal digest is evidence about every assessment, not just the common
/// ones.
private let expectedSignalKinds: Set<String> = [
    "dirtyWorkspaceDuration", "unpushedCommitsDuration", "behindRemoteDuration",
    "staleActivity", "recurringConflicts", "frequentReadFailures",
    "branchInstability", "recentRecovery", "creepingChanges",
]

@main
struct Main {
    static func main() throws {
        let iterations = max(5, Int(ProcessInfo.processInfo.environment["BENCH_ITERATIONS"] ?? "11") ?? 11)
        let repoCount = max(1, Int(ProcessInfo.processInfo.environment["BENCH_REPOS"] ?? "50") ?? 50)
        let entryCounts = (ProcessInfo.processInfo.environment["BENCH_ENTRIES"] ?? "50 250 500")
            .split(separator: " ")
            .compactMap { Int($0) }
            .filter { $0 >= RepositoryHealthThresholds.minimumHistoryEntries }
        guard !entryCounts.isEmpty else {
            FileHandle.standardError.write(Data("FAIL: no usable BENCH_ENTRIES\n".utf8))
            exit(1)
        }

        var failures: [String] = []
        for entryCount in entryCounts {
            let fixture = makeFixture(repoCount: repoCount, entryCount: entryCount)
            let baselinePass = { assess(fixture, baselineAssessment) }
            let currentPass = { assess(fixture, currentAssessment) }

            // Warm up both variants before alternating the timed passes.
            for _ in 0..<2 {
                _ = baselinePass()
                _ = currentPass()
            }

            var baselineSamples: [Double] = []
            var currentSamples: [Double] = []
            for iteration in 0..<iterations {
                // Alternate the order so a thermal or scheduling drift does not
                // favour one variant.
                if iteration % 2 == 0 {
                    baselineSamples.append(measure(baselinePass))
                    currentSamples.append(measure(currentPass))
                } else {
                    currentSamples.append(measure(currentPass))
                    baselineSamples.append(measure(baselinePass))
                }
            }

            let baselineResult = baselinePass()
            let currentResult = currentPass()
            let baselineMs = median(baselineSamples)
            let currentMs = median(currentSamples)
            let baselineDigest = try digest(baselineResult)
            let currentDigest = try digest(currentResult)
            let equal = baselineDigest == currentDigest
            if !equal {
                failures.append("entries=\(entryCount): baseline \(baselineDigest) != current \(currentDigest)")
            }
            let ratio = currentMs > 0 ? baselineMs / currentMs : 0
            let signalCount = currentResult.reduce(0) { $0 + $1.signals.count }
            var histogram: [String: Int] = [:]
            for assessment in currentResult {
                for signal in assessment.signals {
                    histogram[signal.kind.rawValue, default: 0] += 1
                }
            }
            let missing = expectedSignalKinds.subtracting(histogram.keys)
            if !missing.isEmpty {
                failures.append("entries=\(entryCount): fixture missed signals \(missing.sorted())")
            }
            let coverage = histogram.keys.sorted().map { "\($0)=\(histogram[$0]!)" }.joined(separator: ",")
            print(String(
                format: "BENCH repos=%d entries=%d iterations=%d signals=%d baseline_ms=%.3f current_ms=%.3f speedup=%.2fx equivalent=%@",
                repoCount, entryCount, iterations, signalCount, baselineMs, currentMs, ratio, equal ? "yes" : "NO"
            ))
            print("      kinds: \(coverage)")
        }

        if !failures.isEmpty {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            exit(1)
        }
    }
}

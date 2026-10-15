import CryptoKit
import Foundation

// Fixture for `scripts/benchmark-pending-item-identity.py`.
//
// The driver compiles this harness twice — once against a baseline tree and
// once against the working tree — and compares both the timings and a
// fingerprint of every result. The production clock is pinned by the driver
// (`DateFormatting.isoString(from: Date())`), so the two builds produce
// byte-comparable output and any accidental behavior change fails the run.

private let now = Date(timeIntervalSince1970: 1_770_000_000)
private let stamp = "2026-02-02T02:40:00Z"

private func envInt(_ key: String, _ fallback: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw), value > 0 else {
        return fallback
    }
    return value
}

private func repo(_ i: Int, dirty: Bool, variant: Bool = false) -> RepositorySnapshot {
    RepositorySnapshot(
        id: "repo-\(i)", name: "repo-\(i)\(variant ? "-duplicate" : "")", path: "/tmp/bench-\(i)",
        branch: "main", status: dirty ? .changed : .clean,
        modifiedFileCount: dirty ? 2 : 0, addedFileCount: 0, deletedFileCount: 0,
        untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: dirty ? 2 : 0,
        conflictedFileCount: 0, aheadCount: dirty ? 1 : 0, behindCount: 0,
        hasUpstream: true, changedFileCount: dirty ? 2 : 0, changedFilesPreview: [],
        risk: .low, lastScannedAt: stamp, dataSource: .current,
        lastSuccessfulScanAt: stamp, lastChangedAt: nil, lastCommitMetadataAvailable: false,
        unavailableSince: nil, errorMessage: nil, isPinned: false
    )
}

private func historySources(_ j: Int) -> PendingItemSource {
    let all: [PendingItemSource] = [
        .dirtyWorkspace, .unpushedCommits, .behindRemote, .mergeConflict,
        .upstreamMissing, .unavailable, .staleRepository, .scanFailure,
        .creepingChanges, .staleActivity, .healthTrend
    ]
    return all[j % all.count]
}

private func historyStatuses(_ j: Int) -> PendingItemStatus {
    // Exactly one previous item per repository may be resolvable. The
    // evaluator walks the resolvable previous items of a repository through a
    // `Dictionary`'s values, so a bucket holding two of them appends their
    // transitions in per-process hash order and lets the last one overwrite
    // `firstDetectedAt`. That is a property of the evaluator, not of what this
    // harness measures, so the fixture keeps each bucket at one element to stay
    // reproducible across builds.
    if j == 0 { return .active }
    let suppressed: [PendingItemStatus] = [.snoozed, .muted, .resolved, .permanentlyIgnored]
    return suppressed[(j - 1) % suppressed.count]
}

private struct NotificationRow: Encodable {
    let itemID: String
    let transitionReason: String
    let transitionTo: String
    let severity: String
}

private struct Output: Encodable {
    let items: [PendingItem]
    let transitions: [PendingItemTransition]
    let notifications: [NotificationRow]
    let counts: [Int]
    let warnings: [String]

    init(_ r: PendingItemEvaluationResult) {
        items = r.items
        transitions = r.transitions
        notifications = r.notifications.map {
            NotificationRow(itemID: $0.item.id,
                            transitionReason: $0.transition.reason,
                            transitionTo: String(describing: $0.transition.to),
                            severity: String(describing: $0.item.severity))
        }
        counts = [r.repositoryIdsExamined, r.workspaceIdsExamined, r.newItemCount,
                  r.resolvedItemCount, r.escalatedCount, r.deescalatedCount]
        warnings = r.warnings
    }
}

private func encoded(_ r: PendingItemEvaluationResult, pretty: Bool = false) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
    return try encoder.encode(Output(r))
}

/// `BENCH_DUMP` turns a run into a diffable dump: the driver points it at a
/// directory and compares the two builds file by file when a fingerprint
/// differs, so a mismatch reports the differing fields instead of only that
/// they differ.
private func dump(_ scenario: String, _ data: Data) {
    guard let directory = ProcessInfo.processInfo.environment["BENCH_DUMP"], !directory.isEmpty else {
        return
    }
    let url = URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent("\(scenario).json")
    try? data.write(to: url)
}

private func fingerprint(_ r: PendingItemEvaluationResult) throws -> String {
    // Local encoder so the harness compiles against both trees; it is not part
    // of what is being measured.
    let digest = SHA256.hash(data: try encoded(r))
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func require(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted[sorted.count / 2]
}

/// Median wall time of `rounds` invocations; the result is consumed outside the
/// measured interval so the optimizer cannot elide the work.
private func measure(_ rounds: Int,
                     _ operation: () -> PendingItemEvaluationResult) -> Double {
    var samples: [Double] = []
    samples.reserveCapacity(rounds)
    for _ in 0..<rounds {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = operation()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        require(!(try! encoded(result)).isEmpty, "empty result")
        samples.append(elapsed)
    }
    return median(samples)
}

private func measureConstruct(_ rounds: Int, _ operation: () -> PendingItem) -> Double {
    var samples: [Double] = []
    samples.reserveCapacity(rounds)
    for _ in 0..<rounds {
        let start = DispatchTime.now().uptimeNanoseconds
        var sink = 0
        for i in 0..<5_000 { sink &+= operation().id.count &+ i }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        require(sink > 0, "empty construction sink")
        samples.append(elapsed)
    }
    return median(samples)
}

@main
struct Main {
    static func main() throws {
        let rounds = envInt("BENCH_ITERATIONS", 9)

        func report(_ name: String, ms: Double, fingerprintOf: (() throws -> String)? = nil) {
            var line = "scenario=\(name) median_ms=\(String(format: "%.3f", ms))"
            if let fingerprintOf {
                line += " fingerprint=\(try! fingerprintOf())"
            }
            print(line)
            fflush(stdout)
        }

        // ── Construction cost ────────────────────────────────────────────
        // Explicit-id rebuilds (the evaluator's update path) only need the id
        // the caller already has; auto-id constructions must keep hashing.
        let explicitID = "pi-v1-" + String(repeating: "0", count: 64)
        report("construct_explicit_id", ms: measureConstruct(rounds) {
            PendingItem(id: explicitID, source: .dirtyWorkspace, severity: .medium,
                        repositoryID: "repo-7", repositoryName: "repo-7",
                        title: "title", explanation: "explanation", evidence: ["a", "b"])
        })
        report("construct_auto_id", ms: measureConstruct(rounds) {
            PendingItem(source: .dirtyWorkspace, severity: .medium,
                        repositoryID: "repo-7", repositoryName: "repo-7",
                        title: "title", explanation: "explanation", evidence: ["a", "b"])
        })

        // ── End-to-end evaluation ────────────────────────────────────────
        for (name, count, dirty, historyPerRepo) in [
            ("evaluate_240_clean", 240, false, 7),
            ("evaluate_240_dirty", 240, true, 7),
            ("evaluate_1000_dirty", 1000, true, 7),
            ("evaluate_240_no_history", 240, true, 0)
        ] {
            let repositories = (0..<count).map { repo($0, dirty: dirty) }
            let workspaces = dirty ? [Workspace(id: "ws", name: "ws",
                                                 repositoryIDs: repositories.map(\.id))] : []
            let aggregations = WorkspaceAggregationEngine.aggregateAll(
                workspaces: workspaces, allRepositories: repositories, now: now
            )
            var history: [PendingItem] = []
            for i in 0..<count {
                for j in 0..<historyPerRepo {
                    history.append(PendingItem(
                        id: "old-\(i)-\(j)", source: historySources(j), severity: .high,
                        repositoryID: "repo-\(i)", title: "old-\(j)",
                        firstDetectedAt: "2025-01-01T00:00:00Z", lastConfirmedAt: stamp,
                        status: historyStatuses(j), snoozedUntil: nil
                    ))
                }
            }
            let context = PendingItemEvaluationContext(
                repositories: repositories, workspaceAggregations: aggregations,
                workspaces: workspaces, healthAssessments: [:],
                previousItems: history, now: now
            )
            let result = PendingItemEvaluator.evaluate(context: context)
            dump(name, try encoded(result, pretty: true))
            report(name, ms: measure(rounds) { PendingItemEvaluator.evaluate(context: context) },
                   fingerprintOf: { try fingerprint(result) })
        }
    }
}

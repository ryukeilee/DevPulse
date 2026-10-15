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
    hex(SHA256.hash(data: try encoded(r)))
}

/// Local encoder so the harness compiles against both trees; it is not part of
/// what is being measured.
private func hex(_ digest: SHA256Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
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

/// Fingerprint of a batch of constructed items, taken outside any timed region.
/// Without this the construction scenarios would report an equivalence that
/// compared two empty fingerprint sets.
private func constructionFingerprint(count: Int, _ operation: () -> PendingItem) throws -> String {
    var items: [PendingItem] = []
    items.reserveCapacity(count)
    for _ in 0..<count { items.append(operation()) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return hex(SHA256.hash(data: try encoder.encode(items)))
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
        // Both are fingerprinted so the driver's equivalence check is not a
        // comparison of two empty fingerprint sets.
        let explicitID = "pi-v1-" + String(repeating: "0", count: 64)
        let explicitConstruction = {
            PendingItem(id: explicitID, source: .dirtyWorkspace, severity: .medium,
                        repositoryID: "repo-7", repositoryName: "repo-7",
                        title: "title", explanation: "explanation", evidence: ["a", "b"])
        }
        let autoIDConstruction = {
            PendingItem(source: .dirtyWorkspace, severity: .medium,
                        repositoryID: "repo-7", repositoryName: "repo-7",
                        title: "title", explanation: "explanation", evidence: ["a", "b"])
        }
        report("construct_explicit_id",
               ms: measureConstruct(rounds, explicitConstruction),
               fingerprintOf: { try constructionFingerprint(count: 64, explicitConstruction) })
        report("construct_auto_id",
               ms: measureConstruct(rounds, autoIDConstruction),
               fingerprintOf: { try constructionFingerprint(count: 64, autoIDConstruction) })

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
            if historyPerRepo > 0 {
                // Seed the archive with items the evaluator itself mints, so the
                // history carries the same `pi-v1-` identities and titles the
                // production rules produce. Synthetic ids would never match a
                // candidate's id and would leave the same-id update path
                // (severity change, title change, `firstDetectedAt` carry-over)
                // unexercised.
                let seed = PendingItemEvaluator.evaluate(context: PendingItemEvaluationContext(
                    repositories: repositories, workspaceAggregations: aggregations,
                    workspaces: workspaces, healthAssessments: [:], now: now
                ))
                // At most one resolvable previous item per repository, and none
                // for the nil-repositoryID bucket workspace items share: the
                // evaluator walks a bucket through a `Dictionary`'s values, so a
                // bucket with two of them resolves in per-process hash order.
                var activatableRepositories: Set<String> = []
                for item in seed.items {
                    var status: PendingItemStatus = .snoozed
                    if let repositoryID = item.repositoryID,
                       activatableRepositories.insert(repositoryID).inserted {
                        status = .active
                    }
                    history.append(PendingItem(
                        id: item.id, source: item.source, severity: .high,
                        repositoryID: item.repositoryID, repositoryName: item.repositoryName,
                        workspaceID: item.workspaceID, workspaceName: item.workspaceName,
                        title: item.title, explanation: item.explanation, evidence: item.evidence,
                        firstDetectedAt: "2025-01-01T00:00:00Z", lastConfirmedAt: stamp,
                        status: status, snoozedUntil: nil
                    ))
                }
                require(historyPerRepo == 7,
                        "historyPerRepo \(historyPerRepo) is no longer derived from the seed")
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

import Foundation
import CryptoKit

private let now = Date(timeIntervalSince1970: 1_770_000_000)
private let stamp = "2026-02-02T02:40:00Z"

private func repo(_ i: Int, dirty: Bool, variant: Bool = false) -> RepositorySnapshot {
    RepositorySnapshot(id: "repo-\(i)", name: "repo-\(i)\(variant ? "-duplicate" : "")", path: "/tmp/bench-\(i)",
        branch: "main", status: dirty ? .changed : .clean,
        modifiedFileCount: dirty ? 2 : 0, addedFileCount: 0, deletedFileCount: 0,
        untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: dirty ? 2 : 0,
        conflictedFileCount: dirty ? 1 : 0, aheadCount: dirty ? 2 : 0, behindCount: dirty ? 3 : 0,
        hasUpstream: true, changedFileCount: dirty ? (variant ? 9 : 2) : 0, changedFilesPreview: [],
        risk: .low, lastScannedAt: stamp, dataSource: .current,
        lastSuccessfulScanAt: stamp, lastChangedAt: nil, lastCommitMetadataAvailable: false,
        errorMessage: nil, isPinned: false)
}

private struct Notification: Encodable {
    let item: PendingItem
    let transition: PendingItemTransition
    let reason: String
}
private struct Output: Encodable {
    let items: [PendingItem]
    let transitions: [PendingItemTransition]
    let notifications: [Notification]
    let counts: [Int]
    let warnings: [String]
    init(_ r: PendingItemEvaluationResult) {
        items = r.items; transitions = r.transitions
        notifications = r.notifications.map { Notification(item: $0.item, transition: $0.transition, reason: $0.reason) }
        counts = [r.repositoryIdsExamined, r.workspaceIdsExamined, r.newItemCount,
                  r.resolvedItemCount, r.escalatedCount, r.deescalatedCount]
        warnings = r.warnings
    }
}
private func data(_ r: PendingItemEvaluationResult) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(Output(r))
}
private func require(_ condition: Bool, _ message: String = "Benchmark validation failed") {
    guard condition else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
private func measure(_ operation: () -> PendingItemEvaluationResult) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = operation()
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    // Consume the result outside the measured interval.
    require(!(try! data(result)).isEmpty)
    return Double(elapsed) / 1_000_000
}
private func summary(_ samples: [Double]) -> String {
    let s = samples.sorted()
    return String(format: "median=%.3f range=%.3f...%.3f ms", s[s.count / 2], s.first!, s.last!)
}

@main
struct Main {
    static func main() throws {
        let iterations = max(5, Int(ProcessInfo.processInfo.environment["BENCH_ITERATIONS"] ?? "11") ?? 11)
        let statuses: [PendingItemStatus] = [.active, .acknowledged, .restored, .snoozed, .muted, .resolved, .permanentlyIgnored]
        let sources: [PendingItemSource] = [.dirtyWorkspace, .unpushedCommits, .behindRemote, .mergeConflict, .unavailable, .scanFailure, .staleRepository]
        // Exact-ID lifecycle preservation, including escalation/de-escalation,
        // user suppression, and a timestamp equal to the current rule timestamp.
        let oneRepo = [repo(0, dirty: true)]
        let seed = CurrentEvaluator.evaluate(context: PendingItemEvaluationContext(repositories: oneRepo, now: now))
        for status in statuses {
            let history = seed.items.enumerated().map { i, item in
                PendingItem(id: item.id, source: item.source, severity: i % 2 == 0 ? .critical : .low,
                    repositoryID: item.repositoryID, repositoryName: item.repositoryName,
                    title: item.title, explanation: item.explanation, evidence: item.evidence,
                    firstDetectedAt: i % 2 == 0 ? stamp : "2025-01-01T00:00:00Z",
                    lastConfirmedAt: stamp, status: status, snoozedUntil: "2099-01-01T00:00:00Z")
            }
            let context = PendingItemEvaluationContext(repositories: oneRepo, previousItems: history, now: now)
            let index = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
            let before = BaselineEvaluator.evaluate(context: context, previousIndex: index)
            let after = CurrentEvaluator.evaluate(context: context, previousIndex: index)
            let equal = try data(before) == data(after)
            require(equal, "Exact-ID mismatch: \(status)")
        }
        print("exact-ID lifecycle equivalence=PASS statuses=7")
        // Direct helper probes retain array order, first-position replacement,
        // every transition/notification, and repeated resolved appends.
        let expectedID = PendingItem(source: .dirtyWorkspace, severity: .low, repositoryID: "repo-0", title: "").id
        func candidate(_ title: String, evidenceCount: Int, id: String = expectedID) -> PendingItem {
            PendingItem(id: id, source: .dirtyWorkspace, severity: .low, repositoryID: "repo-0",
                        title: title, evidence: (0..<evidenceCount).map { "evidence-\($0)" })
        }
        let first = candidate("first", evidenceCount: 2)
        let equal = candidate("equal", evidenceCount: 2)
        let fewer = candidate("fewer", evidenceCount: 1)
        let more = candidate("more", evidenceCount: 3)
        let finalTie = candidate("final-tie", evidenceCount: 3)
        let other = candidate("other", evidenceCount: 1, id: "other")
        let probeContext = PendingItemEvaluationContext(repositories: oneRepo, now: now)
        for historyStatus in [nil] + statuses.map(Optional.some) {
            let history = historyStatus.map { [expectedID: PendingItem(id: expectedID, source: .dirtyWorkspace,
                severity: .high, repositoryID: "repo-0", title: "old", evidence: ["old"],
                firstDetectedAt: "2025-01-01T00:00:00Z", lastConfirmedAt: stamp, status: $0,
                snoozedUntil: "2099-01-01T00:00:00Z")] } ?? [:]
            for candidates: [PendingItem?] in [
                [first, other, equal, fewer, more, finalTie],
                [nil, nil, other, more, finalTie, fewer],
                [first, nil, nil, other, more, finalTie]
            ] {
                let before = BaselineEvaluator.deduplicationProbe(context: probeContext, candidates: candidates, previousIndex: history)
                let after = CurrentEvaluator.deduplicationProbe(context: probeContext, candidates: candidates, previousIndex: history)
                let equalOutput = try data(before) == data(after)
                require(equalOutput, "Deduplication helper mismatch")
                if historyStatus == nil {
                    require(after.items.first { $0.id == expectedID }?.title == "more")
                }
            }
        }
        print("deduplication helper equivalence=PASS scenarios=24 (ties, replacement, resolved appends, lifecycle)")
        fflush(stdout)
        for (name, count, dirty, historyCount, duplicates) in [
            ("small", 1, true, 7, false), ("100-repos", 100, true, 7, false),
            ("500-repos", 500, true, 7, false), ("1500-repos", 1500, true, 7, false),
            ("no-history", 100, true, 0, false), ("3000-no-history", 3000, true, 0, false),
            ("duplicate-IDs", 500, true, 7, true), ("no-candidates", 100, false, 7, false),
            ("history-only", 0, false, 700, false), ("large-bucket", 1, true, 700, false)
        ] {
            if let selection = ProcessInfo.processInfo.environment["BENCH_SCENARIOS"],
               !selection.split(separator: ",").contains(Substring(name)) { continue }
            var repos = (0..<count).map { repo($0, dirty: dirty) }
            if duplicates { repos += (0..<count).reversed().map { repo($0, dirty: dirty, variant: true) } }
            var history: [PendingItem] = []
            for i in 0..<max(1, count) {
                for j in 0..<historyCount {
                    history.append(PendingItem(id: "old-\(i)-\(j)", source: sources[j % sources.count],
                        severity: .high, repositoryID: "repo-\(i)", title: "old-\(j)",
                        firstDetectedAt: String(format: "2025-01-%02dT00:00:00Z", j % 28 + 1),
                        lastConfirmedAt: stamp, status: statuses[j % statuses.count], snoozedUntil: "2099-01-01T00:00:00Z"))
                }
            }
            // nil repository IDs intentionally match across workspace IDs in existing semantics.
            // Workspace aggregation requires unique repository IDs; only the evaluator
            // receives duplicates so this fixture exercises its deduplication semantics.
            let workspaceRepos = duplicates ? Array(repos.prefix(count)) : repos
            let workspaces = dirty ? [Workspace(id: "ws", name: "ws", repositoryIDs: workspaceRepos.map(\.id))] : []
            let aggregations = WorkspaceAggregationEngine.aggregateAll(workspaces: workspaces, allRepositories: workspaceRepos, now: now)
            if dirty && historyCount > 0 {
                history.append(PendingItem(id: "nil-history", source: .workspaceDegraded, severity: .high,
                    workspaceID: "another", title: "old workspace", firstDetectedAt: "2025-01-01T00:00:00Z", lastConfirmedAt: stamp))
            }
            let context = PendingItemEvaluationContext(repositories: repos, workspaceAggregations: aggregations,
                workspaces: workspaces, previousItems: history, now: now)
            // Share the exact dictionary traversal order: do not normalize away ordering or timestamps.
            let index = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
            for archive in [nil, PendingItemArchive(items: history)] {
                let before = BaselineEvaluator.evaluate(context: context, previousArchive: archive, previousIndex: index)
                let after = CurrentEvaluator.evaluate(context: context, previousArchive: archive, previousIndex: index)
                let equal = try data(before) == data(after)
                require(equal, "Output mismatch: \(name)")
            }
            for _ in 0..<3 {
                _ = BaselineEvaluator.evaluate(context: context)
                _ = CurrentEvaluator.evaluate(context: context)
            }
            var before: [Double] = []; var after: [Double] = []
            for i in 0..<iterations {
                if i % 2 == 0 {
                    before.append(measure { BaselineEvaluator.evaluate(context: context) })
                    after.append(measure { CurrentEvaluator.evaluate(context: context) })
                } else {
                    after.append(measure { CurrentEvaluator.evaluate(context: context) })
                    before.append(measure { BaselineEvaluator.evaluate(context: context) })
                }
            }
            let speedup = before.sorted()[iterations / 2] / after.sorted()[iterations / 2]
            print("\(name) repos=\(repos.count) history=\(history.count) equivalence=PASS samples=\(iterations)")
            print("  baseline \(summary(before)); current \(summary(after)); speedup=\(String(format: "%.2f", speedup))x")
            let differences = zip(before, after).map { $0 - $1 }.sorted()
            print(String(format: "  paired_gain_ms median=%.3f range=%.3f...%.3f positive_pairs=%d/%d",
                differences[iterations / 2], differences.first!, differences.last!,
                differences.filter { $0 > 0 }.count, iterations))
            let medianGain = differences[iterations / 2]
            let mad = differences.map { abs($0 - medianGain) }.sorted()[iterations / 2]
            let beyondNoise = differences.first! > 0 && medianGain > 3 * mad
            print(String(format: "  paired_mad_ms=%.3f gain_beyond_noise=%@", mad, beyondNoise ? "YES" : "NO"))
            fflush(stdout)
            if name == "1500-repos" || name == "3000-no-history" {
                require(beyondNoise, "Large-repository gain must be positive in every pair and exceed 3x paired MAD")
            }
        }
    }
}

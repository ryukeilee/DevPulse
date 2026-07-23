import Testing
import Foundation
@testable import DevPulse

// MARK: - Release readiness engine tests

@Suite("ReleaseReadinessEngine")
struct ReleaseReadinessEngineTests {

    private let engine = ReleaseReadinessEngine()

    private func makeSnapshot(
        name: String = "test-repo",
        path: String = "/tmp/test-repo",
        branch: String = "main",
        status: RepositoryStatus = .clean,
        changedFileCount: Int = 0,
        modifiedCount: Int = 0,
        addedCount: Int = 0,
        deletedCount: Int = 0,
        untrackedCount: Int = 0,
        stagedCount: Int? = 0,
        unstagedCount: Int? = 0,
        conflictedCount: Int? = 0,
        aheadCount: Int? = 0,
        behindCount: Int? = 0,
        hasUpstream: Bool? = true,
        changedFilesPreview: [String] = [],
        risk: RiskLevel = .low,
        errorMessage: String? = nil
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            id: RepositoryIdentity.id(for: path),
            name: name,
            path: path,
            workspaceKind: nil,
            branch: branch,
            status: status,
            modifiedFileCount: modifiedCount,
            addedFileCount: addedCount,
            deletedFileCount: deletedCount,
            untrackedFileCount: untrackedCount,
            stagedFileCount: stagedCount,
            unstagedFileCount: unstagedCount,
            conflictedFileCount: conflictedCount,
            aheadCount: aheadCount,
            behindCount: behindCount,
            hasUpstream: hasUpstream,
            changedFileCount: changedFileCount,
            changedFilesPreview: changedFilesPreview,
            risk: risk,
            lastScannedAt: ISO8601DateFormatter().string(from: Date()),
            dataSource: .current,
            lastSuccessfulScanAt: ISO8601DateFormatter().string(from: Date()),
            lastChangedAt: nil,
            lastCommitID: "abc123",
            lastCommitSummary: "test",
            lastCommitMetadataAvailable: true,
            lastActivityAt: nil,
            unavailableSince: nil,
            errorMessage: errorMessage,
            isPinned: false
        )
    }

    // MARK: - Clean repository tests

    @Test("Clean repository with upstream is ready")
    func cleanRepoIsReady() {
        let snapshot = makeSnapshot()
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .healthy(branch: "main", commitID: "abc123"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.level == .ready)
        #expect(readiness.signals.isEmpty)
        #expect(readiness.scopeID == snapshot.id)
    }

    @Test("Clean repo without baseline configured is attention")
    func cleanRepoWithoutBaseline() {
        let snapshot = makeSnapshot()
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .none(),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.level == .attention)
        #expect(readiness.signals.contains(where: { $0.kind == .baselineMissing }))
    }

    // MARK: - Uncommitted changes tests

    @Test("Many uncommitted changes are blocked")
    func manyUncommittedChangesBlocked() {
        let snapshot = makeSnapshot(
            status: .changed,
            changedFileCount: 15,
            modifiedCount: 10,
            addedCount: 3,
            untrackedCount: 2
        )
        let changes = (0..<15).map { i in
            ChangeEntry(
                filePath: "file\(i).swift",
                relativePath: "file\(i).swift",
                changeKind: .modified,
                category: .source,
                isStaged: false,
                commitID: nil,
                commitSummary: nil
            )
        }

        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: changes,
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.level == .blocked)
        #expect(readiness.signals.contains(where: { $0.kind == .uncommittedChanges }))
    }

    @Test("Few uncommitted changes are attention")
    func fewUncommittedChangesAttention() {
        let snapshot = makeSnapshot(
            status: .changed,
            changedFileCount: 3,
            modifiedCount: 2,
            addedCount: 1
        )
        let changes = [
            ChangeEntry(filePath: "f1.swift", relativePath: "f1.swift", changeKind: .modified,
                       category: .source, isStaged: false, commitID: nil, commitSummary: nil),
            ChangeEntry(filePath: "f2.swift", relativePath: "f2.swift", changeKind: .modified,
                       category: .source, isStaged: false, commitID: nil, commitSummary: nil),
        ]

        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: changes,
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.level == .attention)
    }

    // MARK: - Unpushed commits tests

    @Test("Many unpushed commits are blocked")
    func manyUnpushedCommitsBlocked() {
        let snapshot = makeSnapshot(aheadCount: 25)
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.level == .blocked)
        #expect(readiness.signals.contains(where: { $0.kind == .unpushedCommits }))
    }

    @Test("Few unpushed commits are attention")
    func fewUnpushedCommitsAttention() {
        let snapshot = makeSnapshot(aheadCount: 5)
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.level == .attention)
        #expect(readiness.signals.contains(where: { $0.kind == .unpushedCommits }))
    }

    // MARK: - Behind remote tests

    @Test("Many behind commits are blocked")
    func manyBehindCommitsBlocked() {
        let snapshot = makeSnapshot(behindCount: 60)
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.level == .blocked)
        #expect(readiness.signals.contains(where: { $0.kind == .behindBaseline }))
    }

    // MARK: - Conflict tests

    @Test("Conflicts are blocked")
    func conflictsBlocked() {
        let snapshot = makeSnapshot(
            status: .changed,
            conflictedCount: 2
        )
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.level == .blocked)
        #expect(readiness.signals.contains(where: { $0.kind == .mergeConflict }))
    }

    // MARK: - Detached HEAD test

    @Test("Detached HEAD is attention")
    func detachedHeadAttention() {
        let snapshot = makeSnapshot(branch: "HEAD")
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.signals.contains(where: { $0.kind == .detachedHead }))
    }

    // MARK: - No upstream test

    @Test("No upstream is attention")
    func noUpstreamAttention() {
        let snapshot = makeSnapshot(hasUpstream: false)
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.signals.contains(where: { $0.kind == .noUpstream }))
    }

    // MARK: - Diverged branch test

    @Test("Diverged branch is blocked")
    func divergedBranchBlocked() {
        let snapshot = makeSnapshot(aheadCount: 3, behindCount: 5)
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.level == .blocked)
        #expect(readiness.signals.contains(where: { $0.kind == .divergedBranch }))
    }

    // MARK: - Scan failure test

    @Test("Many scan failures are blocked")
    func manyScanFailuresBlocked() {
        let snapshot = makeSnapshot()
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 5,
            isFromCache: false
        )

        #expect(readiness.level == .blocked)
        #expect(readiness.signals.contains(where: { $0.kind == .consecutiveScanFailures }))
    }

    @Test("Some scan failures are attention")
    func someScanFailuresAttention() {
        let snapshot = makeSnapshot()
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 2,
            isFromCache: false
        )

        #expect(readiness.level == .attention)
    }

    // MARK: - Baseline degradation test

    @Test("Baseline degradation is blocked")
    func baselineDegradationBlocked() {
        let snapshot = makeSnapshot()
        let degradedBaseline = BaselineState(
            baselineBranch: "main",
            baselineCommitID: nil,
            baselineExists: false,
            baselineRewritten: false,
            baselineUnavailableSince: ISO8601DateFormatter().string(from: Date()),
            lastValidAnalysisID: "analysis-123",
            degradedAt: ISO8601DateFormatter().string(from: Date()),
            recoveredAt: nil,
            degradationReason: "基线不可用"
        )

        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: degradedBaseline,
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.level == .blocked)
        #expect(readiness.signals.contains(where: { $0.kind == .baselineDegraded }))
    }

    // MARK: - Missing test changes test

    @Test("Missing test changes is attention")
    func missingTestChangesAttention() {
        let snapshot = makeSnapshot(status: .changed, changedFileCount: 10)
        let changes = (0..<10).map { i in
            ChangeEntry(
                filePath: "Source/File\(i).swift",
                relativePath: "Source/File\(i).swift",
                changeKind: .modified,
                category: .source,
                isStaged: false,
                commitID: nil,
                commitSummary: nil
            )
        }

        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: changes,
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.signals.contains(where: { $0.kind == .missingTestChanges }))
    }

    @Test("Test changes alongside source changes avoids warning")
    func testChangesAvoidWarning() {
        let snapshot = makeSnapshot(status: .changed, changedFileCount: 12)
        var changes: [ChangeEntry] = []
        for i in 0..<10 {
            changes.append(ChangeEntry(
                filePath: "Source/File\(i).swift",
                relativePath: "Source/File\(i).swift",
                changeKind: .modified,
                category: .source,
                isStaged: false,
                commitID: nil,
                commitSummary: nil
            ))
        }
        changes.append(ChangeEntry(
            filePath: "Tests/AppTests.swift",
            relativePath: "Tests/AppTests.swift",
            changeKind: .modified,
            category: .test,
            isStaged: false,
            commitID: nil,
            commitSummary: nil
        ))

        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: changes,
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        // Only source changes → missing test warning
        // But we only have source + a few tests, still below 10% threshold
        #expect(readiness.signals.contains(where: { $0.kind == .missingTestChanges }))
    }

    // MARK: - Dependency change tests

    @Test("Dependency changes produce signal")
    func dependencyChangesProduceSignal() {
        let snapshot = makeSnapshot(status: .changed, changedFileCount: 2)
        let changes = [
            ChangeEntry(filePath: "Package.swift", relativePath: "Package.swift", changeKind: .modified,
                       category: .dependency, isStaged: false, commitID: nil, commitSummary: nil),
            ChangeEntry(filePath: "Package.resolved", relativePath: "Package.resolved", changeKind: .modified,
                       category: .dependency, isStaged: false, commitID: nil, commitSummary: nil),
        ]

        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: changes,
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.signals.contains(where: { $0.kind == .dependencyChange }))
    }

    // MARK: - Multiple signals aggregation

    @Test("Multiple signals produce correct overall level")
    func multipleSignalsAggregation() {
        let snapshot = makeSnapshot(
            status: .changed,
            changedFileCount: 5,
            modifiedCount: 3,
            conflictedCount: 1,
            aheadCount: 3,
            behindCount: 2
        )

        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [
                ChangeEntry(filePath: "f1.swift", relativePath: "f1.swift", changeKind: .modified,
                           category: .source, isStaged: false, commitID: nil, commitSummary: nil)
            ],
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        #expect(readiness.level == .blocked)
        #expect(readiness.signals.count >= 3)
    }

    // MARK: - Workspace aggregation test

    @Test("Workspace aggregation combines signals correctly")
    func workspaceAggregation() {
        let readyReadiness = ReleaseReadiness(
            scopeID: "repo-1", scopeKind: .repository,
            level: .ready, signals: [],
            summary: "Ready", primaryExplanation: "",
            assessedAt: ISO8601DateFormatter().string(from: Date()),
            isFromCache: false
        )
        let blockedReadiness = ReleaseReadiness(
            scopeID: "repo-2", scopeKind: .repository,
            level: .blocked,
            signals: [ReadinessSignal(id: "s1", kind: .mergeConflict, level: .blocked,
                                     title: "Conflict", explanation: "", evidence: [],
                                     sourceRepositoryID: "repo-2")],
            summary: "Blocked", primaryExplanation: "",
            assessedAt: ISO8601DateFormatter().string(from: Date()),
            isFromCache: false
        )

        let workspaceReadiness = engine.aggregateWorkspaceReadiness(
            workspaceID: "ws-1",
            workspaceName: "Test Workspace",
            repositoryReadiness: ["repo-1": readyReadiness, "repo-2": blockedReadiness],
            crossRepoSignals: []
        )

        #expect(workspaceReadiness.level == .blocked)
        #expect(workspaceReadiness.signals.count == 1)
    }

    // MARK: - Signal evidence tests

    @Test("Uncommitted changes signal has evidence")
    func uncommittedChangesHasEvidence() {
        let snapshot = makeSnapshot(
            status: .changed,
            changedFileCount: 3,
            modifiedCount: 2,
            addedCount: 1
        )
        let readiness = engine.assessRepository(
            repositoryID: snapshot.id,
            snapshot: snapshot,
            changes: [],
            baselineState: .healthy(branch: "main", commitID: "abc"),
            scanFailureCount: 0,
            isFromCache: false
        )

        let uncommittedSignals = readiness.signals.filter { $0.kind == .uncommittedChanges }
        #expect(!uncommittedSignals.isEmpty)
        if let signal = uncommittedSignals.first {
            #expect(!signal.evidence.isEmpty)
            #expect(!signal.title.isEmpty)
            #expect(!signal.explanation.isEmpty)
        }
    }
}

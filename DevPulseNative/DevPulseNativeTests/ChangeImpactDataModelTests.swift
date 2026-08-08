import Testing
import Foundation
@testable import DevPulse

// MARK: - Change impact data model tests

@Suite("Change Impact Data Models")
struct ChangeImpactDataModelTests {

    // MARK: - ChangeCategory

    @Test("ChangeCategory display names are non-empty")
    func changeCategoryDisplayNames() {
        for category in ChangeCategory.allCases {
            #expect(!category.displayName.isEmpty)
            #expect(!category.systemImage.isEmpty)
        }
    }

    @Test("ChangeCategory all cases are representable")
    func changeCategoryAllCases() {
        #expect(ChangeCategory.allCases.count == 9)
        #expect(ChangeCategory.allCases.contains(.source))
        #expect(ChangeCategory.allCases.contains(.test))
        #expect(ChangeCategory.allCases.contains(.configuration))
        #expect(ChangeCategory.allCases.contains(.dependency))
        #expect(ChangeCategory.allCases.contains(.resource))
        #expect(ChangeCategory.allCases.contains(.documentation))
        #expect(ChangeCategory.allCases.contains(.buildScript))
        #expect(ChangeCategory.allCases.contains(.migration))
        #expect(ChangeCategory.allCases.contains(.unknown))
    }

    // MARK: - ChangeEntry

    @Test("ChangeEntry creates unique IDs")
    func changeEntryUniqueIDs() {
        let entry1 = ChangeEntry(
            filePath: "/path/to/file.swift",
            relativePath: "file.swift",
            changeKind: .modified,
            category: .source,
            isStaged: true,
            commitID: nil,
            commitSummary: nil
        )
        let entry2 = ChangeEntry(
            filePath: "/path/to/file.swift",
            relativePath: "file.swift",
            changeKind: .modified,
            category: .source,
            isStaged: false,
            commitID: "abc123",
            commitSummary: "fix"
        )
        #expect(entry1.id != entry2.id)
        #expect(!entry1.id.isEmpty)
    }

    @Test("ChangeEntry Codable round-trip")
    func changeEntryCodableRoundTrip() throws {
        let entry = ChangeEntry(
            filePath: "/path/to/file.swift",
            relativePath: "file.swift",
            changeKind: .added,
            category: .source,
            isStaged: true,
            commitID: "abc123def",
            commitSummary: "Add new feature"
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ChangeEntry.self, from: data)

        #expect(decoded.filePath == entry.filePath)
        #expect(decoded.changeKind == entry.changeKind)
        #expect(decoded.category == entry.category)
        #expect(decoded.isStaged == entry.isStaged)
        #expect(decoded.commitID == entry.commitID)
    }

    // MARK: - ChangeKind

    @Test("ChangeKind display names and risk weights")
    func changeKindProperties() {
        #expect(ChangeKind.added.riskWeight == 1.2)
        #expect(ChangeKind.modified.riskWeight == 1.0)
        #expect(ChangeKind.deleted.riskWeight == 1.5)
        #expect(ChangeKind.conflicted.riskWeight == 3.0)
        #expect(ChangeKind.untracked.riskWeight == 0.7)

        for kind in [ChangeKind.added, .modified, .deleted, .renamed, .copied, .untracked, .conflicted] {
            #expect(!kind.displayName.isEmpty)
        }
    }

    // MARK: - ChangeScope

    @Test("ChangeScope risk multipliers are positive")
    func changeScopeRiskMultipliers() {
        for scope in [ChangeScope.singleFile, .multiFile, .moduleLocal, .crossModule, .crossWorkspace] {
            #expect(scope.riskMultiplier > 0)
            #expect(!scope.displayName.isEmpty)
        }
        #expect(ChangeScope.crossWorkspace.riskMultiplier > ChangeScope.singleFile.riskMultiplier)
    }

    // MARK: - AffectedModule

    @Test("AffectedModule has stable ID")
    func affectedModuleStableID() {
        let module = AffectedModule(
            id: "test-module",
            name: "TestModule",
            repositoryID: "repo-1",
            kind: .app,
            changeCount: 5,
            categoryBreakdown: [.source: 5],
            directChanges: ["file1.swift"],
            propagatedFrom: [],
            confidence: .direct,
            evidence: ["直接变更"]
        )
        #expect(module.stableID == "module-repo-1-test-module")
        #expect(!module.id.isEmpty)
    }

    @Test("AffectedModule Codable round-trip")
    func affectedModuleCodableRoundTrip() throws {
        let module = AffectedModule(
            id: "mod-1",
            name: "Core",
            repositoryID: "repo-abc",
            kind: .library,
            changeCount: 3,
            categoryBreakdown: [.source: 2, .test: 1],
            directChanges: ["Core/Engine.swift", "Core/Model.swift"],
            propagatedFrom: ["Utilities"],
            confidence: .high,
            evidence: ["3 files changed", "Imported by App target"]
        )

        let data = try JSONEncoder().encode(module)
        let decoded = try JSONDecoder().decode(AffectedModule.self, from: data)

        #expect(decoded.name == module.name)
        #expect(decoded.kind == module.kind)
        #expect(decoded.confidence == module.confidence)
        #expect(decoded.directChanges.count == 2)
    }

    // MARK: - ImpactConfidence

    @Test("ImpactConfidence ordering")
    func impactConfidenceOrdering() {
        #expect(ImpactConfidence.direct.sortOrder < ImpactConfidence.high.sortOrder)
        #expect(ImpactConfidence.high.sortOrder < ImpactConfidence.medium.sortOrder)
        #expect(ImpactConfidence.medium.sortOrder < ImpactConfidence.low.sortOrder)
        #expect(ImpactConfidence.low.sortOrder < ImpactConfidence.speculative.sortOrder)
    }

    // MARK: - ImpactEdge

    @Test("ImpactEdge properties")
    func impactEdgeProperties() {
        let edge = ImpactEdge(
            id: "edge-1",
            fromModuleID: "mod-a",
            toModuleID: "mod-b",
            via: ["import UIKit"],
            kind: .import,
            weight: 0.8
        )
        #expect(edge.fromModuleID == "mod-a")
        #expect(edge.toModuleID == "mod-b")
        #expect(edge.weight == 0.8)
        #expect(!edge.kind.displayName.isEmpty)
    }

    // MARK: - BaselineState

    @Test("BaselineState healthy state")
    func baselineStateHealthy() {
        let state = BaselineState.healthy(branch: "main", commitID: "abc123")
        #expect(state.baselineBranch == "main")
        #expect(state.baselineCommitID == "abc123")
        #expect(state.baselineExists)
        #expect(!state.isDegraded)
        #expect(!state.isRecovered)
        #expect(state.stateLabel == "基线正常")
    }

    @Test("BaselineState none state")
    func baselineStateNone() {
        let state = BaselineState.none()
        #expect(state.baselineBranch == nil)
        #expect(!state.baselineExists)
        #expect(!state.isDegraded)
        #expect(state.stateLabel == "未设置基线")
    }

    @Test("BaselineState degraded state")
    func baselineStateDegraded() {
        let state = BaselineState(
            baselineBranch: "main",
            baselineCommitID: nil,
            baselineExists: false,
            baselineRewritten: false,
            baselineUnavailableSince: ISO8601DateFormatter().string(from: Date()),
            lastValidAnalysisID: "analysis-123",
            degradedAt: ISO8601DateFormatter().string(from: Date()),
            recoveredAt: nil,
            degradationReason: "基线分支 'main' 不存在"
        )
        #expect(state.isDegraded)
        #expect(!state.isRecovered)
        #expect(state.stateLabel == "基线降级")
    }

    @Test("BaselineState recovered state")
    func baselineStateRecovered() {
        let state = BaselineState(
            baselineBranch: "main",
            baselineCommitID: "def456",
            baselineExists: true,
            baselineRewritten: false,
            baselineUnavailableSince: ISO8601DateFormatter().string(from: Date()),
            lastValidAnalysisID: "analysis-123",
            degradedAt: ISO8601DateFormatter().string(from: Date()),
            recoveredAt: ISO8601DateFormatter().string(from: Date()),
            degradationReason: "基线已恢复"
        )
        #expect(!state.isDegraded)
        #expect(state.isRecovered)
        #expect(state.stateLabel == "基线已恢复")
    }

    // MARK: - ReleaseReadinessLevel

    @Test("ReleaseReadinessLevel sorting")
    func readinessLevelSorting() {
        #expect(ReleaseReadinessLevel.blocked.sortOrder < ReleaseReadinessLevel.attention.sortOrder)
        #expect(ReleaseReadinessLevel.attention.sortOrder < ReleaseReadinessLevel.ready.sortOrder)
        #expect(ReleaseReadinessLevel.ready.sortOrder < ReleaseReadinessLevel.unknown.sortOrder)
    }

    // MARK: - ReadinessSignal

    @Test("ReadinessSignal properties")
    func readinessSignalProperties() {
        let signal = ReadinessSignal(
            id: "signal-1",
            kind: .uncommittedChanges,
            level: .blocked,
            title: "存在未提交变更",
            explanation: "检测到 5 个未提交文件变更",
            evidence: ["变更文件数: 5"],
            sourceRepositoryID: "repo-1"
        )
        #expect(signal.level == .blocked)
        #expect(signal.kind == .uncommittedChanges)
        #expect(!signal.systemImage.isEmpty)
    }

    // MARK: - ReleaseReadiness

    @Test("ReleaseReadiness signal classification")
    func readinessSignalClassification() {
        let readiness = ReleaseReadiness(
            scopeID: "repo-1",
            scopeKind: .repository,
            level: .blocked,
            signals: [
                ReadinessSignal(id: "s1", kind: .uncommittedChanges, level: .blocked,
                               title: "Blocked", explanation: "", evidence: [], sourceRepositoryID: nil),
                ReadinessSignal(id: "s2", kind: .behindBaseline, level: .attention,
                               title: "Attention", explanation: "", evidence: [], sourceRepositoryID: nil),
                ReadinessSignal(id: "s3", kind: .mergeConflict, level: .blocked,
                               title: "Also Blocked", explanation: "", evidence: [], sourceRepositoryID: nil),
            ],
            summary: "Summary",
            primaryExplanation: "Explanation",
            assessedAt: ISO8601DateFormatter().string(from: Date()),
            isFromCache: false
        )
        #expect(readiness.blockingSignals.count == 2)
        #expect(readiness.attentionSignals.count == 1)
    }

    // MARK: - ChangeImpactSnapshot

    @Test("ChangeImpactSnapshot computed properties")
    func snapshotComputedProperties() {
        let snapshot = ChangeImpactSnapshot(
            id: "snap-1",
            repositoryID: "repo-1",
            repositoryPath: "/path/to/repo",
            analysisVersion: 1,
            analyzedAt: ISO8601DateFormatter().string(from: Date()),
            baselineState: .none(),
            changes: [
                ChangeEntry(filePath: "f1.swift", relativePath: "f1.swift", changeKind: .modified,
                           category: .source, isStaged: false, commitID: nil, commitSummary: nil)
            ],
            modules: [
                AffectedModule(id: "m1", name: "App", repositoryID: "repo-1", kind: .app,
                              changeCount: 1, categoryBreakdown: [:], directChanges: ["f1.swift"],
                              propagatedFrom: [], confidence: .direct, evidence: [])
            ],
            impactEdges: [],
            scope: .singleFile,
            releaseReadiness: nil,
            categoryBreakdown: [.source: 1],
            repositoryHealthSnapshot: nil,
            diagnostics: nil,
            isFromCache: false
        )
        #expect(snapshot.changedFileCount == 1)
        #expect(snapshot.affectedModuleCount == 1)
        #expect(snapshot.moduleNames == ["App"])
        #expect(snapshot.impactedTargets == ["App"])
        #expect(snapshot.verificationScope == ["App"])
    }

    // MARK: - InvalidationKey

    @Test("InvalidationKey computed from same input is equal")
    func invalidationKeyEquality() {
        let input1 = ChangeCollectionInput(
            repositoryPath: "/path", branch: "main", status: .changed,
            modifiedFiles: ["a.swift"], addedFiles: [], deletedFiles: [],
            untrackedFiles: [], conflictedFiles: [],
            stagedFiles: [], unstagedFiles: [],
            lastCommitID: "abc", lastCommitSummary: "msg",
            aheadCount: nil, behindCount: nil, hasUpstream: nil,
            workspaceKind: nil, recentCommits: nil
        )
        let input2 = ChangeCollectionInput(
            repositoryPath: "/path", branch: "main", status: .changed,
            modifiedFiles: ["a.swift"], addedFiles: [], deletedFiles: [],
            untrackedFiles: [], conflictedFiles: [],
            stagedFiles: [], unstagedFiles: [],
            lastCommitID: "abc", lastCommitSummary: "msg",
            aheadCount: nil, behindCount: nil, hasUpstream: nil,
            workspaceKind: nil, recentCommits: nil
        )
        let key1 = InvalidationKey.compute(for: input1)
        let key2 = InvalidationKey.compute(for: input2)
        #expect(key1 == key2)
    }

    @Test("InvalidationKey changes when input changes")
    func invalidationKeyChanges() {
        let input1 = ChangeCollectionInput(
            repositoryPath: "/path", branch: "main", status: .changed,
            modifiedFiles: ["a.swift"], addedFiles: [], deletedFiles: [],
            untrackedFiles: [], conflictedFiles: [],
            stagedFiles: [], unstagedFiles: [],
            lastCommitID: "abc", lastCommitSummary: "msg",
            aheadCount: nil, behindCount: nil, hasUpstream: nil,
            workspaceKind: nil, recentCommits: nil
        )
        let input2 = ChangeCollectionInput(
            repositoryPath: "/path", branch: "feature", status: .changed,
            modifiedFiles: ["a.swift", "b.swift"], addedFiles: [], deletedFiles: [],
            untrackedFiles: [], conflictedFiles: [],
            stagedFiles: [], unstagedFiles: [],
            lastCommitID: "def", lastCommitSummary: "new msg",
            aheadCount: nil, behindCount: nil, hasUpstream: nil,
            workspaceKind: nil, recentCommits: nil
        )
        let key1 = InvalidationKey.compute(for: input1)
        let key2 = InvalidationKey.compute(for: input2)
        #expect(key1 != key2)
    }

    // MARK: - StageTiming

    @Test("StageTiming builder accumulates correctly")
    func stageTimingBuilder() {
        var builder = StageTimingBuilder()
        builder.recordItem()
        builder.recordItem()
        builder.recordItem()
        builder.recordError()

        let timing = builder.build(isCompleted: true)
        #expect(timing.itemCount == 3)
        #expect(timing.errorCount == 1)
        #expect(timing.isCompleted)
        #expect(!timing.isCancelled)
        #expect(timing.elapsedMs >= 0)
    }

    // MARK: - ModuleKind

    @Test("ModuleKind display names")
    func moduleKindDisplayNames() {
        for kind in [ModuleKind.app, .framework, .library, .testTarget, .widgetExtension, .package, .workspace, .unknown] {
            #expect(!kind.displayName.isEmpty)
        }
        #expect(ModuleKind.app.displayName == "应用")
        #expect(ModuleKind.testTarget.displayName == "测试目标")
    }

    // MARK: - DependencyKind

    @Test("DependencyKind display names")
    func dependencyKindDisplayNames() {
        for kind in [DependencyKind.import, .targetDependency, .packageDependency, .workspaceMember, .fileReference, .inferred] {
            #expect(!kind.displayName.isEmpty)
        }
    }

    // MARK: - ChangeImpactStore

    @Test("automatic compaction does not re-enter the store queue")
    func automaticCompactionCompletes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-impact-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = ChangeImpactStore.Configuration()
        configuration.maxAnalysesPerRepo = 1
        configuration.maxTotalAnalyses = 1
        configuration.retentionDays = nil
        configuration.compactionInterval = 1
        configuration.compactionThreshold = 0

        let store = ChangeImpactStore(
            fileURL: directory.appendingPathComponent("impact.json"),
            config: configuration
        )
        let snapshot = ChangeImpactSnapshot(
            id: "snapshot-1",
            repositoryID: "repo-1",
            repositoryPath: "/repo-1",
            analysisVersion: 1,
            analyzedAt: ISO8601DateFormatter().string(from: Date()),
            baselineState: .none(),
            changes: [],
            modules: [],
            impactEdges: [],
            scope: .singleFile,
            releaseReadiness: nil,
            categoryBreakdown: [:],
            repositoryHealthSnapshot: nil,
            diagnostics: nil,
            isFromCache: false
        )

        guard case .success = store.store(snapshot: snapshot) else {
            Issue.record("Expected store write to complete")
            return
        }
        #expect(store.totalAnalysisCount == 1)
    }

    // MARK: - AnalysisStage

    @Test("AnalysisStage ordering and completeness")
    func analysisStageOrdering() {
        let stages = AnalysisStage.allCases
        #expect(stages.count == 7)
        for i in 0..<(stages.count - 1) {
            #expect(stages[i].sortOrder < stages[i + 1].sortOrder)
        }
        #expect(AnalysisStage.changeCollection.sortOrder == 0)
        #expect(AnalysisStage.snapshotPublishing.sortOrder == 6)
    }
}

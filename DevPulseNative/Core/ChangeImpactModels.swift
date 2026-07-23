import Foundation
import CryptoKit

// MARK: - Schema constants

enum ChangeImpactSchema {
    static let version = 1
    static let oldestMigratableVersion = 1
}

// MARK: - Change category

/// Classifies a file change by its semantic role in the project.
enum ChangeCategory: String, Codable, Equatable, CaseIterable, Sendable {
    case source
    case test
    case configuration
    case dependency
    case resource
    case documentation
    case buildScript
    case migration
    case unknown

    var displayName: String {
        switch self {
        case .source: return "源码"
        case .test: return "测试"
        case .configuration: return "配置"
        case .dependency: return "依赖"
        case .resource: return "资源"
        case .documentation: return "文档"
        case .buildScript: return "构建脚本"
        case .migration: return "迁移文件"
        case .unknown: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .source: return "swift"
        case .test: return "checklist"
        case .configuration: return "gearshape"
        case .dependency: return "square.and.arrow.down"
        case .resource: return "photo"
        case .documentation: return "doc.text"
        case .buildScript: return "hammer"
        case .migration: return "arrow.triangle.swap"
        case .unknown: return "questionmark"
        }
    }

    var sortOrder: Int {
        switch self {
        case .source: return 0
        case .test: return 1
        case .dependency: return 2
        case .configuration: return 3
        case .buildScript: return 4
        case .migration: return 5
        case .resource: return 6
        case .documentation: return 7
        case .unknown: return 8
        }
    }
}

// MARK: - Change scope

/// Describes the breadth of a change within a repository.
enum ChangeScope: String, Codable, Equatable, Sendable {
    case singleFile
    case multiFile
    case moduleLocal
    case crossModule
    case crossWorkspace

    var displayName: String {
        switch self {
        case .singleFile: return "单文件"
        case .multiFile: return "多文件"
        case .moduleLocal: return "模块内"
        case .crossModule: return "跨模块"
        case .crossWorkspace: return "跨工作区"
        }
    }

    var riskMultiplier: Double {
        switch self {
        case .singleFile: return 1.0
        case .multiFile: return 1.5
        case .moduleLocal: return 1.8
        case .crossModule: return 3.0
        case .crossWorkspace: return 5.0
        }
    }
}

// MARK: - Change entry

/// One atomic file change within an impact analysis.
struct ChangeEntry: Codable, Equatable, Identifiable, Sendable {
    let filePath: String
    let relativePath: String
    let changeKind: ChangeKind
    let category: ChangeCategory
    let isStaged: Bool
    let commitID: String?
    let commitSummary: String?

    var id: String {
        let components = [filePath, changeKind.rawValue, commitID ?? "unstaged"]
        return components.joined(separator: "|")
    }
}

enum ChangeKind: String, Codable, Equatable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case untracked
    case conflicted

    var displayName: String {
        switch self {
        case .added: return "新增"
        case .modified: return "修改"
        case .deleted: return "删除"
        case .renamed: return "重命名"
        case .copied: return "复制"
        case .untracked: return "未跟踪"
        case .conflicted: return "冲突"
        }
    }

    var riskWeight: Double {
        switch self {
        case .added: return 1.2
        case .modified: return 1.0
        case .deleted: return 1.5
        case .renamed: return 0.8
        case .copied: return 0.6
        case .untracked: return 0.7
        case .conflicted: return 3.0
        }
    }
}

// MARK: - Affected module

/// A module or target inferred to be affected by a set of changes.
struct AffectedModule: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let repositoryID: String
    let kind: ModuleKind
    let changeCount: Int
    let categoryBreakdown: [ChangeCategory: Int]
    let directChanges: [String]    // file paths directly changed
    let propagatedFrom: [String]   // module IDs that propagated to this one
    let confidence: ImpactConfidence
    let evidence: [String]         // Human-readable evidence strings

    /// Unique identifier within the analysis scope.
    var stableID: String { "module-\(repositoryID)-\(id)" }
}

enum ModuleKind: String, Codable, Equatable, Sendable {
    case app
    case framework
    case library
    case testTarget
    case widgetExtension
    case package
    case workspace
    case unknown

    var displayName: String {
        switch self {
        case .app: return "应用"
        case .framework: return "框架"
        case .library: return "库"
        case .testTarget: return "测试目标"
        case .widgetExtension: return "Widget 扩展"
        case .package: return "包"
        case .workspace: return "工作区"
        case .unknown: return "未知"
        }
    }
}

enum ImpactConfidence: String, Codable, Equatable, Sendable {
    case direct
    case high
    case medium
    case low
    case speculative

    var displayName: String {
        switch self {
        case .direct: return "直接"
        case .high: return "高置信度"
        case .medium: return "中置信度"
        case .low: return "低置信度"
        case .speculative: return "推测"
        }
    }

    var sortOrder: Int {
        switch self {
        case .direct: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        case .speculative: return 4
        }
    }
}

// MARK: - Impact edge

/// A directed dependency edge in the impact propagation graph.
struct ImpactEdge: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let fromModuleID: String
    let toModuleID: String
    let via: [String]              // file paths establishing the dependency
    let kind: DependencyKind
    let weight: Double             // 0-1 scale
}

enum DependencyKind: String, Codable, Equatable, Sendable {
    case `import`        // Swift import statement
    case targetDependency // Xcode target dependency
    case packageDependency // SwiftPM package dependency
    case workspaceMember // Same workspace membership
    case fileReference   // File-level reference
    case inferred        // Heuristic-based inference

    var displayName: String {
        switch self {
        case .import: return "导入依赖"
        case .targetDependency: return "目标依赖"
        case .packageDependency: return "包依赖"
        case .workspaceMember: return "工作区成员"
        case .fileReference: return "文件引用"
        case .inferred: return "推断依赖"
        }
    }
}

// MARK: - Baseline state

/// Tracks the state of a user-configured baseline branch for comparison.
struct BaselineState: Codable, Equatable, Sendable {
    let baselineBranch: String?
    let baselineCommitID: String?
    let baselineExists: Bool
    let baselineRewritten: Bool
    let baselineUnavailableSince: String?  // ISO8601
    let lastValidAnalysisID: String?       // retained analysis when baseline is unavailable
    let degradedAt: String?                // ISO8601 when degradation started
    let recoveredAt: String?               // ISO8601 when recovery happened
    let degradationReason: String?

    var isDegraded: Bool {
        degradationReason != nil && recoveredAt == nil
    }

    var isRecovered: Bool {
        recoveredAt != nil
    }

    var stateLabel: String {
        if isDegraded { return "基线降级" }
        if isRecovered { return "基线已恢复" }
        if baselineBranch == nil { return "未设置基线" }
        if !baselineExists { return "基线不存在" }
        return "基线正常"
    }

    static func healthy(branch: String, commitID: String?) -> BaselineState {
        BaselineState(
            baselineBranch: branch,
            baselineCommitID: commitID,
            baselineExists: true,
            baselineRewritten: false,
            baselineUnavailableSince: nil,
            lastValidAnalysisID: nil,
            degradedAt: nil,
            recoveredAt: nil,
            degradationReason: nil
        )
    }

    static func none() -> BaselineState {
        BaselineState(
            baselineBranch: nil,
            baselineCommitID: nil,
            baselineExists: false,
            baselineRewritten: false,
            baselineUnavailableSince: nil,
            lastValidAnalysisID: nil,
            degradedAt: nil,
            recoveredAt: nil,
            degradationReason: nil
        )
    }
}

// MARK: - Release readiness

/// Overall release readiness for a repository or workspace.
enum ReleaseReadinessLevel: String, Codable, Equatable, Sendable {
    case ready
    case attention
    case blocked
    case unknown

    var displayName: String {
        switch self {
        case .ready: return "就绪"
        case .attention: return "需关注"
        case .blocked: return "阻塞"
        case .unknown: return "未知"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var sortOrder: Int {
        switch self {
        case .blocked: return 0
        case .attention: return 1
        case .ready: return 2
        case .unknown: return 3
        }
    }
}

/// A specific readiness signal with explainable evidence.
struct ReadinessSignal: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: ReadinessSignalKind
    let level: ReleaseReadinessLevel
    let title: String
    let explanation: String
    let evidence: [String]        // Drill-down: specific files, commits, or states
    let sourceRepositoryID: String?

    var systemImage: String { kind.systemImage }
}

enum ReadinessSignalKind: String, Codable, Equatable, Sendable {
    case uncommittedChanges
    case unpushedCommits
    case behindBaseline
    case mergeConflict
    case missingTestChanges
    case dependencyChange
    case consecutiveScanFailures
    case workspaceMemberAnomaly
    case detachedHead
    case noUpstream
    case divergedBranch
    case baselineDegraded
    case baselineMissing

    var systemImage: String {
        switch self {
        case .uncommittedChanges: return "pencil.and.outline"
        case .unpushedCommits: return "arrow.up.circle"
        case .behindBaseline: return "arrow.down.circle"
        case .mergeConflict: return "exclamationmark.triangle"
        case .missingTestChanges: return "checklist"
        case .dependencyChange: return "square.and.arrow.down"
        case .consecutiveScanFailures: return "xmark.octagon"
        case .workspaceMemberAnomaly: return "person.2.slash"
        case .detachedHead: return "arrow.triangle.branch"
        case .noUpstream: return "cloud.slash"
        case .divergedBranch: return "arrow.up.arrow.down"
        case .baselineDegraded: return "gauge.with.dots.needle.33percent"
        case .baselineMissing: return "questionmark.folder"
        }
    }
}

// MARK: - Release readiness result

/// The full release readiness assessment for one scope.
struct ReleaseReadiness: Codable, Equatable, Sendable {
    let scopeID: String
    let scopeKind: ReadinessScopeKind
    let level: ReleaseReadinessLevel
    let signals: [ReadinessSignal]
    let summary: String
    let primaryExplanation: String
    let assessedAt: String       // ISO8601
    let isFromCache: Bool

    var blockingSignals: [ReadinessSignal] {
        signals.filter { $0.level == .blocked }
    }

    var attentionSignals: [ReadinessSignal] {
        signals.filter { $0.level == .attention }
    }
}

enum ReadinessScopeKind: String, Codable, Equatable, Sendable {
    case repository
    case workspace
}

// MARK: - Impact analysis snapshot

/// The top-level result of a change impact analysis run for one repository.
struct ChangeImpactSnapshot: Codable, Equatable, Sendable {
    let id: String
    let repositoryID: String
    let repositoryPath: String
    let analysisVersion: Int
    let analyzedAt: String          // ISO8601
    let baselineState: BaselineState
    let changes: [ChangeEntry]
    let modules: [AffectedModule]
    let impactEdges: [ImpactEdge]
    let scope: ChangeScope
    let releaseReadiness: ReleaseReadiness?
    let categoryBreakdown: [ChangeCategory: Int]
    let repositoryHealthSnapshot: String? // JSON-serialized health at analysis time
    let diagnostics: AnalysisDiagnostics?
    let isFromCache: Bool

    var changedFileCount: Int { changes.count }
    var affectedModuleCount: Int { modules.count }
    var moduleNames: [String] { modules.map(\.name) }
    var impactedTargets: [String] {
        Array(Set(modules.filter { $0.confidence.sortOrder <= ImpactConfidence.high.sortOrder }.map(\.name)))
    }
    var verificationScope: [String] {
        // All directly + high-confidence affected modules
        let highConfModules = modules.filter { $0.confidence.sortOrder <= ImpactConfidence.high.sortOrder }
        return highConfModules.map(\.name)
    }
}

// MARK: - Workspace impact analysis

/// Aggregated impact analysis across all repositories in a workspace.
struct WorkspaceImpactAnalysis: Codable, Equatable, Sendable {
    let workspaceID: String
    let workspaceName: String
    let analyzedAt: String
    let analysisVersion: Int
    let repositoryAnalyses: [String: ChangeImpactSnapshot]  // keyed by repo ID
    let crossRepoEdges: [ImpactEdge]
    let overallReleaseReadiness: ReleaseReadiness?
    let aggregateCategoryBreakdown: [ChangeCategory: Int]
    let totalChangedFiles: Int
    let totalAffectedModules: Int
    let diagnostics: AnalysisDiagnostics?
    let isFromCache: Bool

    var repositoryCount: Int { repositoryAnalyses.count }
    var changedRepositories: Int {
        repositoryAnalyses.values.filter { !$0.changes.isEmpty }.count
    }
}

// MARK: - Diagnostics

/// Diagnostic information for one analysis run.
struct AnalysisDiagnostics: Codable, Equatable, Sendable {
    let totalElapsedMs: Double
    let stageTimings: [String: StageTiming]
    let cacheHitCount: Int
    let cacheMissCount: Int
    let reanalysisReason: String?
    let affectedModuleCount: Int
    let dependencyGraphSize: Int
    let timedOutStages: [String]
    let cancelledStages: [String]
    let degradedModules: [String]
    let recoveryResults: [String]
}

struct StageTiming: Codable, Equatable, Sendable {
    let elapsedMs: Double
    let itemCount: Int
    let isCompleted: Bool
    let isCancelled: Bool
    let errorCount: Int
}

// MARK: - Change collector input

/// Input to the change collection stage.
struct ChangeCollectionInput: Codable, Equatable, Sendable {
    let repositoryPath: String
    let branch: String
    let status: RepositoryStatus
    let modifiedFiles: [String]
    let addedFiles: [String]
    let deletedFiles: [String]
    let untrackedFiles: [String]
    let conflictedFiles: [String]
    let stagedFiles: [String]
    let unstagedFiles: [String]
    let lastCommitID: String?
    let lastCommitSummary: String?
    let aheadCount: Int?
    let behindCount: Int?
    let hasUpstream: Bool?
    let workspaceKind: RepositoryWorkspaceKind?
    /// Recent commit history log (parsed from git log)
    let recentCommits: [CommitLogEntry]?
}

struct CommitLogEntry: Codable, Equatable, Sendable {
    let commitID: String
    let summary: String
    let authorName: String
    let authorEmail: String
    let committedAt: String   // ISO8601
    let filesChanged: [String]
    let insertions: Int
    let deletions: Int

    var shortID: String { String(commitID.prefix(8)) }
}

// MARK: - Cache entry metadata

struct AnalysisCacheMetadata: Codable, Equatable {
    let analysisID: String
    let repositoryID: String
    let analyzedAt: String
    let changedFileHash: String   // hash of changed file paths + statuses
    let baselineHash: String?     // hash of baseline commit + branch
    let dependencyHash: String?   // hash of project file contents
    let generation: UInt64
    let hitCount: Int
    let ttlSeconds: TimeInterval
    let expiresAt: String         // ISO8601
    let schemaVersion: Int
}

// MARK: - Refresh integration

/// Enum controlling when impact analysis runs relative to the scan refresh.
enum ImpactAnalysisTrigger: String, Codable, Sendable {
    case afterEveryScan
    case afterChangedOnly
    case manualOnly
}

// MARK: - Pipeline stage definitions

enum AnalysisStage: String, Codable, CaseIterable, Sendable {
    case changeCollection
    case manifestParsing
    case dependencyModeling
    case impactPropagation
    case riskAssessment
    case resultMerging
    case snapshotPublishing

    var displayName: String {
        switch self {
        case .changeCollection: return "变更采集"
        case .manifestParsing: return "清单解析"
        case .dependencyModeling: return "依赖建模"
        case .impactPropagation: return "影响传播"
        case .riskAssessment: return "风险评估"
        case .resultMerging: return "结果合并"
        case .snapshotPublishing: return "快照发布"
        }
    }

    var sortOrder: Int {
        switch self {
        case .changeCollection: return 0
        case .manifestParsing: return 1
        case .dependencyModeling: return 2
        case .impactPropagation: return 3
        case .riskAssessment: return 4
        case .resultMerging: return 5
        case .snapshotPublishing: return 6
        }
    }
}

// MARK: - Stage result

/// Result of one pipeline stage.
enum StageResult<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case success(value: T, diagnostics: StageTiming)
    case cancelled(diagnostics: StageTiming)
    case failed(error: String, diagnostics: StageTiming)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var timing: StageTiming {
        switch self {
        case .success(_, let d): return d
        case .cancelled(let d): return d
        case .failed(_, let d): return d
        }
    }
}

// MARK: - Analysis request

/// A request to run change impact analysis for one or more repositories.
struct AnalysisRequest: Codable, Equatable, Sendable {
    let repositoryIDs: Set<String>
    let forceFullAnalysis: Bool
    let trigger: ImpactAnalysisTrigger
    let baselineOverrides: [String: String]?  // repoID -> branch name
    let timeoutSeconds: TimeInterval
    let maxConcurrency: Int
}

// MARK: - Analysis result

/// Top-level result of running the analysis pipeline.
struct AnalysisRunResult: Codable, Equatable, Sendable {
    let requestID: String
    let completedAt: String
    let snapshots: [String: ChangeImpactSnapshot]       // repoID -> snapshot
    let workspaceAnalyses: [String: WorkspaceImpactAnalysis]
    let overallDiagnostics: AnalysisDiagnostics
    let wasCancelled: Bool
    let timedOut: Bool
    let errors: [String: String]                        // repoID -> error message
}

// MARK: - Manifest file types for dependency inference

enum ManifestFileKind: String, Codable, Equatable, Sendable {
    /// XcodeGen project spec
    case xcodegenProject
    /// Xcode project.pbxproj (parsed heuristically)
    case xcodeProject
    /// SwiftPM Package.swift
    case swiftPackage
    /// CocoaPods Podfile
    case cocoapods
    /// Carthage Cartfile
    case carthage
    /// SPM Package.resolved
    case packageResolved
    /// Workspace file
    case workspace
    /// Compiled xcworkspace
    case xcworkspace

    var displayName: String {
        switch self {
        case .xcodegenProject: return "XcodeGen 项目"
        case .xcodeProject: return "Xcode 项目"
        case .swiftPackage: return "Swift 包"
        case .cocoapods: return "CocoaPods"
        case .carthage: return "Carthage"
        case .packageResolved: return "包解析"
        case .workspace: return "工作区"
        case .xcworkspace: return "Xcode 工作区"
        }
    }

    var fileNamePatterns: [String] {
        switch self {
        case .xcodegenProject: return ["project.yml"]
        case .xcodeProject: return [".xcodeproj"]
        case .swiftPackage: return ["Package.swift"]
        case .cocoapods: return ["Podfile"]
        case .carthage: return ["Cartfile", "Cartfile.resolved"]
        case .packageResolved: return ["Package.resolved"]
        case .workspace: return ["*.xcworkspace"]
        case .xcworkspace: return ["*.xcworkspace"]
        }
    }
}

// MARK: - Invalidation key

/// Key used to determine if a cached analysis is still valid.
struct InvalidationKey: Codable, Equatable, Hashable, Sendable {
    let repositoryID: String
    let currentBranchHash: String
    let statusHash: String          // hash of status (changed file count, etc.)
    let modifiedFilesHash: String   // hash of modified file paths
    let lastCommitHash: String?
    let baselineHash: String?
    let manifestHash: String?       // hash of manifest file contents

    static func compute(for repository: ChangeCollectionInput) -> InvalidationKey {
        let statusHash = InvalidationKey.simpleHash([
            repository.status.rawValue,
            String(repository.modifiedFiles.count),
            String(repository.addedFiles.count),
            String(repository.deletedFiles.count),
            String(repository.untrackedFiles.count),
            String(repository.conflictedFiles.count)
        ].joined(separator: "|"))

        let modifiedHash = InvalidationKey.simpleHash(
            repository.modifiedFiles.sorted().joined(separator: ",")
        )

        let branchHash = InvalidationKey.simpleHash(repository.branch)

        let lastCommitHash = repository.lastCommitID.map {
            InvalidationKey.simpleHash($0)
        }

        return InvalidationKey(
            repositoryID: "",
            currentBranchHash: branchHash,
            statusHash: statusHash,
            modifiedFilesHash: modifiedHash,
            lastCommitHash: lastCommitHash,
            baselineHash: nil,
            manifestHash: nil
        )
    }

    private static func simpleHash(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

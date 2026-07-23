import Foundation

// MARK: - Change impact diagnostics

/// Comprehensive diagnostic information for the change impact analysis system.
struct ChangeImpactDiagnostics: Equatable, Sendable {
    // Pipeline stats
    let totalAnalysesRun: Int
    let totalAnalysesCached: Int
    let totalStageTimeouts: Int
    let totalStageCancellations: Int
    let totalStageFailures: Int
    let totalDegradations: Int
    let totalRecoveries: Int

    // Timing
    let averageAnalysisTimeMs: Double
    let lastAnalysisTimeMs: Double
    let peakAnalysisTimeMs: Double

    // Cache
    let cacheDiagnostics: CacheDiagnostics

    // Store
    let storeDiagnostics: ImpactStoreDiagnostics

    // Current state
    let cachedEntries: Int
    let storedAnalysesCount: Int
    let managedRepositoryCount: Int

    // Errors
    let lastErrors: [String]

    var formattedSummary: String {
        """
        ═══ 变更影响分析诊断 ═══
        总分析次数: \(totalAnalysesRun) (缓存命中: \(totalAnalysesCached))
        阶段超时: \(totalStageTimeouts) | 取消: \(totalStageCancellations) | 失败: \(totalStageFailures)
        降级: \(totalDegradations) | 恢复: \(totalRecoveries)
        平均耗时: \(String(format: "%.1f", averageAnalysisTimeMs))ms
        缓存: \(cacheDiagnostics.currentEntries)/\(cacheDiagnostics.maxEntries) (命中率: \(String(format: "%.1f", cacheDiagnostics.hitRate * 100))%)
        存储: \(storedAnalysesCount) 条记录, \(managedRepositoryCount) 个仓库
        """
    }

    static func initial() -> ChangeImpactDiagnostics {
        ChangeImpactDiagnostics(
            totalAnalysesRun: 0,
            totalAnalysesCached: 0,
            totalStageTimeouts: 0,
            totalStageCancellations: 0,
            totalStageFailures: 0,
            totalDegradations: 0,
            totalRecoveries: 0,
            averageAnalysisTimeMs: 0,
            lastAnalysisTimeMs: 0,
            peakAnalysisTimeMs: 0,
            cacheDiagnostics: CacheDiagnostics(
                currentEntries: 0, maxEntries: 0,
                hitCount: 0, missCount: 0,
                evictionCount: 0, hitRate: 0, generation: 0
            ),
            storeDiagnostics: ImpactStoreDiagnostics.empty(),
            cachedEntries: 0,
            storedAnalysesCount: 0,
            managedRepositoryCount: 0,
            lastErrors: []
        )
    }
}

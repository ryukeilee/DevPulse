import Foundation
import Testing
@testable import DevPulse

struct CommitReadinessEngineTests {
    @Test func legacyBuiltInMigrationKeepsLoadedConfigAuthoritative() {
        let defaultBuiltIns: Set<String> = ["D"]
        #expect(ScanSchedulerPolicy.migratedBuiltInPaths(configWasLoaded: true, configuredBuiltIns: [], directoryBuiltIns: ["B"], defaultBuiltIns: defaultBuiltIns) == [])
        #expect(ScanSchedulerPolicy.migratedBuiltInPaths(configWasLoaded: true, configuredBuiltIns: ["A"], directoryBuiltIns: ["B"], defaultBuiltIns: defaultBuiltIns) == ["A"])
        #expect(ScanSchedulerPolicy.migratedBuiltInPaths(configWasLoaded: false, configuredBuiltIns: [], directoryBuiltIns: ["B"], defaultBuiltIns: defaultBuiltIns) == ["B"])
        #expect(ScanSchedulerPolicy.migratedBuiltInPaths(configWasLoaded: false, configuredBuiltIns: [], directoryBuiltIns: [], defaultBuiltIns: defaultBuiltIns) == defaultBuiltIns)
    }
    @Test func scanRefreshCoordinatorFailureDrainsOnlyLatestPendingRequest() {
        var coordinator = ScanRefreshCoordinator()
        coordinator.request(signature: "A", forceRepositoryDiscovery: false)
        _ = coordinator.beginNext()
        coordinator.request(signature: "B", forceRepositoryDiscovery: true)
        coordinator.request(signature: "C", forceRepositoryDiscovery: true)

        #expect(coordinator.completeCurrent() == .init(signature: "C", forceRepositoryDiscovery: true))
        _ = coordinator.beginNext()
        #expect(coordinator.completeCurrent() == nil)
    }

    @Test func startupRefreshPolicyForcesFreshSnapshotWhenRootsSignatureChanges() {
        #expect(
            ScanSchedulerPolicy.startupRefreshDecision(
                snapshotIsFresh: true,
                currentRootsSignature: "A",
                lastDiscoveryRootsSignature: "B"
            ).forceRepositoryDiscovery
        )
    }

    @Test func startupRefreshPolicyDoesNotForceMatchingOrAllOffRoots() {
        #expect(!ScanSchedulerPolicy.startupRefreshDecision(snapshotIsFresh: true, currentRootsSignature: "A", lastDiscoveryRootsSignature: "A").forceRepositoryDiscovery)
        #expect(ScanSchedulerPolicy.startupRefreshDecision(snapshotIsFresh: true, currentRootsSignature: "A", lastDiscoveryRootsSignature: nil).forceRepositoryDiscovery)
        #expect(!ScanSchedulerPolicy.startupRefreshDecision(snapshotIsFresh: true, currentRootsSignature: "", lastDiscoveryRootsSignature: "").forceRepositoryDiscovery)
    }

    @Test func lifecycleRefreshPolicyUsesSuccessfulWatermarkAndDegradedState() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!ScanSchedulerPolicy.shouldRefreshForLifecycle(
            lastSuccessfulRefreshAt: now.addingTimeInterval(-60),
            refreshPhase: .success,
            now: now
        ))
        #expect(ScanSchedulerPolicy.shouldRefreshForLifecycle(
            lastSuccessfulRefreshAt: now.addingTimeInterval(-11 * 60),
            refreshPhase: .success,
            now: now
        ))
        #expect(ScanSchedulerPolicy.shouldRefreshForLifecycle(
            lastSuccessfulRefreshAt: now,
            refreshPhase: .degraded,
            now: now
        ))
    }

    @Test func incompleteRefreshPreservesOnlyKnownUnchangedDiscoveryScope() {
        #expect(ScanSchedulerPolicy.shouldPreserveDiscoveryScopeAfterIncompleteRefresh(
            knownRepositoryPaths: ["/Volumes/Work/repo"],
            currentScanRootsSignature: "/Volumes/Work",
            lastScanRootsSignature: "/Volumes/Work"
        ))
        #expect(!ScanSchedulerPolicy.shouldPreserveDiscoveryScopeAfterIncompleteRefresh(
            knownRepositoryPaths: [],
            currentScanRootsSignature: "/Volumes/Work",
            lastScanRootsSignature: "/Volumes/Work"
        ))
        #expect(!ScanSchedulerPolicy.shouldPreserveDiscoveryScopeAfterIncompleteRefresh(
            knownRepositoryPaths: ["/Volumes/Work/repo"],
            currentScanRootsSignature: "/Volumes/New",
            lastScanRootsSignature: "/Volumes/Work"
        ))
    }

    @Test func scanRefreshCoordinatorCoalescesBurstToLatestForcedRequest() {
        var coordinator = ScanRefreshCoordinator()

        coordinator.requestForced(signature: "A")
        coordinator.request(signature: "B", forceRepositoryDiscovery: true)
        coordinator.request(signature: "C", forceRepositoryDiscovery: true)

        #expect(coordinator.beginNext() == .init(signature: "C", forceRepositoryDiscovery: true))
        #expect(coordinator.beginNext() == nil)
    }

    @Test func scanRefreshCoordinatorQueuesOnlyLatestDifferentSignatureWhileRunning() {
        var coordinator = ScanRefreshCoordinator()
        coordinator.request(signature: "A", forceRepositoryDiscovery: false)
        #expect(coordinator.beginNext() == .init(signature: "A", forceRepositoryDiscovery: false))

        coordinator.request(signature: "B", forceRepositoryDiscovery: true)
        coordinator.request(signature: "C", forceRepositoryDiscovery: true)
        #expect(coordinator.completeCurrent() == .init(signature: "C", forceRepositoryDiscovery: true))
    }

    @Test func scanRefreshCoordinatorCancelsFollowUpWhenRootsReturnToRunningSignature() {
        var coordinator = ScanRefreshCoordinator()
        coordinator.request(signature: "A", forceRepositoryDiscovery: false)
        _ = coordinator.beginNext()
        coordinator.request(signature: "B", forceRepositoryDiscovery: true)
        coordinator.request(signature: "A", forceRepositoryDiscovery: true)

        #expect(coordinator.completeCurrent() == nil)
    }

    @Test func scanRefreshCoordinatorOrsForceForSameScheduledSignature() {
        var coordinator = ScanRefreshCoordinator()
        coordinator.request(signature: "A", forceRepositoryDiscovery: false)
        coordinator.request(signature: "A", forceRepositoryDiscovery: true)

        #expect(coordinator.beginNext() == .init(signature: "A", forceRepositoryDiscovery: true))
    }

    @Test func scanRefreshCoordinatorDrainsWakeAndConfigurationAsOneForcedLatestRequest() {
        var coordinator = ScanRefreshCoordinator()
        coordinator.request(signature: "A", forceRepositoryDiscovery: false)
        _ = coordinator.beginNext()

        coordinator.request(signature: "B", forceRepositoryDiscovery: false)
        coordinator.request(signature: "C", forceRepositoryDiscovery: true)

        #expect(coordinator.completeCurrent() == .init(signature: "C", forceRepositoryDiscovery: true))
        #expect(coordinator.beginNext() == .init(signature: "C", forceRepositoryDiscovery: true))
        #expect(coordinator.completeCurrent() == nil)
    }

    @Test func scanRefreshCoordinatorPreservesForcedWakeForRunningSignature() {
        var coordinator = ScanRefreshCoordinator()
        coordinator.request(signature: "A", forceRepositoryDiscovery: false)
        _ = coordinator.beginNext()
        coordinator.requestForced(signature: "A")

        #expect(coordinator.completeCurrent() == .init(signature: "A", forceRepositoryDiscovery: true))
    }

    @Test func scanRefreshCoordinatorDoesNotEraseQueuedForcedScopeRefreshWithNormalRequest() {
        var coordinator = ScanRefreshCoordinator()
        coordinator.request(signature: "A", forceRepositoryDiscovery: false)
        _ = coordinator.beginNext()
        coordinator.requestForced(signature: "A")
        coordinator.request(signature: "A", forceRepositoryDiscovery: false)

        #expect(coordinator.completeCurrent() == .init(signature: "A", forceRepositoryDiscovery: true))
        #expect(coordinator.beginNext() == .init(signature: "A", forceRepositoryDiscovery: true))
    }
    @Test func refreshStatusIsFreshWithinTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = now.addingTimeInterval(-9 * 60)

        #expect(RefreshStatusFormatter.freshness(for: snapshot, now: now) == .fresh)
        #expect(RefreshStatusFormatter.updateLabel(for: snapshot, now: now) == "9 分钟前更新")
    }

    @Test func refreshStatusBecomesStaleAfterTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = now.addingTimeInterval(-10 * 60)

        #expect(RefreshStatusFormatter.freshness(for: snapshot, now: now) == .stale)
        #expect(RefreshStatusFormatter.updateLabel(for: snapshot, now: now) == "10 分钟前更新")
    }

    @Test func refreshStatusBecomesExpiredAfterThirtyMinutes() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = now.addingTimeInterval(-31 * 60)

        #expect(RefreshStatusFormatter.freshness(for: snapshot, now: now) == .expired)
    }

    @Test func refreshStatusIsUnknownWithoutSuccessfulScan() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)

        #expect(RefreshStatusFormatter.freshness(for: nil, now: now) == .unknown)
    }

    @Test func refreshStatusUsesJustUpdatedWithinFirstMinute() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = now.addingTimeInterval(-20)

        #expect(RefreshStatusFormatter.updateLabel(for: snapshot, now: now) == "刚刚更新")
    }

    @Test func refreshTrustAssessmentExplainsRefreshFailure() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = now.addingTimeInterval(-8 * 60)
        let assessment = RefreshStatusFormatter.refreshAssessment(
            lastUpdatedAt: snapshot,
            now: now,
            failureMessage: "Git 不可用"
        )

        #expect(assessment.state == .failed)
        #expect(assessment.title == "刷新失败")
        #expect(assessment.detail == "上次成功刷新：8 分钟前更新")
    }

    @Test func wakeRefreshDecisionTriggersImmediateRefreshWhenSnapshotIsStale() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let lastScanAt = now.addingTimeInterval(-12 * 60)

        let decision = ScanSchedulerPolicy.wakeRefreshDecision(
            lastScanAt: lastScanAt,
            refreshPhase: .success,
            sleepBeganAt: now.addingTimeInterval(-60),
            refreshStartedAt: nil,
            refreshCompletedAt: nil,
            now: now
        )

        #expect(decision.shouldRefreshImmediately == true)
        #expect(decision.forceRepositoryDiscovery == false)
        #expect(decision.detail.contains("超过 10 分钟"))
    }

    @Test func wakeRefreshDecisionRetriesFailedRefreshAfterWake() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let lastScanAt = now.addingTimeInterval(-5 * 60)

        let decision = ScanSchedulerPolicy.wakeRefreshDecision(
            lastScanAt: lastScanAt,
            refreshPhase: .failure,
            sleepBeganAt: now.addingTimeInterval(-120),
            refreshStartedAt: now.addingTimeInterval(-6 * 60),
            refreshCompletedAt: now.addingTimeInterval(-6 * 60 + 10),
            now: now
        )

        #expect(decision.shouldRefreshImmediately == true)
        #expect(decision.detail.contains("失败状态"))
    }

    @Test func wakeRefreshDecisionRecoversInterruptedRefreshAfterSleep() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let sleepBeganAt = now.addingTimeInterval(-90)
        let refreshStartedAt = now.addingTimeInterval(-120)

        let decision = ScanSchedulerPolicy.wakeRefreshDecision(
            lastScanAt: now.addingTimeInterval(-2 * 60),
            refreshPhase: .refreshing,
            sleepBeganAt: sleepBeganAt,
            refreshStartedAt: refreshStartedAt,
            refreshCompletedAt: nil,
            now: now
        )

        #expect(decision.shouldRefreshImmediately == true)
        #expect(decision.detail.contains("休眠前刷新尚未完成"))
    }

    @Test func wakeRefreshDecisionOnlyReschedulesWhenSnapshotIsStillFresh() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let decision = ScanSchedulerPolicy.wakeRefreshDecision(
            lastScanAt: now.addingTimeInterval(-3 * 60),
            refreshPhase: .success,
            sleepBeganAt: now.addingTimeInterval(-60),
            refreshStartedAt: nil,
            refreshCompletedAt: nil,
            now: now
        )

        #expect(decision.shouldRefreshImmediately == false)
        #expect(decision.detail.contains("仍然新鲜"))
    }

    @Test func snapshotTrustAssessmentMarksMissingTimeUnknown() {
        let assessment = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: nil,
            writtenAt: nil,
            missingReason: "Widget 没有时间戳"
        )

        #expect(assessment.state == .unknown)
        #expect(assessment.title == "状态未知")
        #expect(assessment.basis == "Widget 没有时间戳")
    }

    @Test func snapshotTrustAssessmentNeverUsesWrittenAtAsDataFreshness() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let formatter = ISO8601DateFormatter()
        let assessment = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: formatter.string(from: now.addingTimeInterval(-20 * 60)),
            writtenAt: formatter.string(from: now),
            now: now
        )

        #expect(assessment.state == .stale)
        #expect(assessment.title == "数据需要刷新")
        #expect(assessment.basis.contains("generatedAt"))
        #expect(!assessment.basis.contains("writtenAt"))
    }

    @Test func snapshotTrustAssessmentDoesNotTreatFailureHealthWriteAsFreshData() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let formatter = ISO8601DateFormatter()
        let lastSuccessfulAt = formatter.string(from: now.addingTimeInterval(-20 * 60))
        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: lastSuccessfulAt,
            writtenAt: formatter.string(from: now),
            lastSuccessfulRefreshAt: lastSuccessfulAt,
            scanSummary: ScanSummary(
                totalRepositories: 1,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 1
            ),
            repositories: [
                self.snapshot(
                    status: .error,
                    lastScannedAt: formatter.string(from: now),
                    dataSource: .lastSuccessful,
                    lastSuccessfulScanAt: lastSuccessfulAt,
                    errorMessage: "读取失败"
                )
            ]
        )

        let assessment = RefreshStatusFormatter.snapshotAssessment(
            snapshot: snapshot,
            now: now
        )

        #expect(assessment.state == .failed)
        #expect(assessment.title == "显示上次成功数据")
        #expect(assessment.detail.contains("上次成功刷新"))
        #expect(assessment.basis.contains("writtenAt"))
    }

    @Test func snapshotTrustAssessmentSurfacesPartialRepositoryFailureBeforeFreshTime() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let formatter = ISO8601DateFormatter()
        let successfulAt = formatter.string(from: now.addingTimeInterval(-25 * 60))
        let attemptedAt = formatter.string(from: now)
        let current = snapshot(
            id: "current",
            name: "current",
            status: .clean,
            lastScannedAt: attemptedAt,
            dataSource: .current,
            lastSuccessfulScanAt: attemptedAt
        )
        let failed = snapshot(
            id: "failed",
            name: "failed",
            status: .error,
            lastScannedAt: attemptedAt,
            dataSource: .lastSuccessful,
            lastSuccessfulScanAt: successfulAt,
            errorMessage: "读取超时"
        )
        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: attemptedAt,
            writtenAt: attemptedAt,
            lastSuccessfulRefreshAt: successfulAt,
            scanSummary: ScanSummary.build(from: [current, failed]),
            repositories: [current, failed]
        )

        let assessment = RefreshStatusFormatter.snapshotAssessment(snapshot: snapshot, now: now)

        #expect(assessment.state == .degraded)
        #expect(assessment.title == "部分仓库待确认")
        #expect(assessment.detail.contains("1 个读取失败"))
        #expect(assessment.detail.contains("上次完整成功"))
    }

    @Test func snapshotTrustAssessmentShowsDegradedForUnresolvedScanPaths() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let formatter = ISO8601DateFormatter()
        let successfulAt = formatter.string(from: now.addingTimeInterval(-20 * 60))
        let attemptedAt = formatter.string(from: now)
        // 仓库数据全部 current，但探索阶段有不可达路径：Widget 不应退化为
        // "数据过期"（旧 lastSuccessfulRefreshAt 被降级扫描冻结），应显示降级。
        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: attemptedAt,
            writtenAt: attemptedAt,
            lastSuccessfulRefreshAt: successfulAt,
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [
                snapshot(
                    status: .clean,
                    lastScannedAt: attemptedAt,
                    dataSource: .current,
                    lastSuccessfulScanAt: attemptedAt
                )
            ],
            repositoryUnavailableSinceByPath: ["/tmp/unreachable-root": successfulAt]
        )

        let assessment = RefreshStatusFormatter.snapshotAssessment(snapshot: snapshot, now: now)

        #expect(assessment.state == .degraded)
        #expect(assessment.title == "部分仓库待确认")
        #expect(assessment.detail.contains("部分扫描路径"))
    }

    @Test func snapshotTrustAssessmentShowsDegradedWhenScanReportsRepositoryErrors() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let formatter = ISO8601DateFormatter()
        let successfulAt = formatter.string(from: now.addingTimeInterval(-20 * 60))
        let attemptedAt = formatter.string(from: now)
        // scanSummary 报告有仓库读取错误，但快照里都是 current 数据：
        // 不能仅凭被冻结的 lastSuccessfulRefreshAt 判为过期。
        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: attemptedAt,
            writtenAt: attemptedAt,
            lastSuccessfulRefreshAt: successfulAt,
            scanSummary: ScanSummary(totalRepositories: 2, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 1),
            repositories: [
                snapshot(
                    status: .clean,
                    lastScannedAt: attemptedAt,
                    dataSource: .current,
                    lastSuccessfulScanAt: attemptedAt
                ),
                snapshot(
                    status: .clean,
                    lastScannedAt: attemptedAt,
                    dataSource: .current,
                    lastSuccessfulScanAt: attemptedAt
                )
            ]
        )

        let assessment = RefreshStatusFormatter.snapshotAssessment(snapshot: snapshot, now: now)

        #expect(assessment.state == .degraded)
        #expect(assessment.title == "部分仓库待确认")
    }

    @Test func snapshotTrustAssessmentStaysStaleWhenNoDegradedSignals() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let formatter = ISO8601DateFormatter()
        let successfulAt = formatter.string(from: now.addingTimeInterval(-20 * 60))
        let attemptedAt = formatter.string(from: now)
        // 完全健康的快照：lastSuccessfulRefreshAt 20 分钟前，应保持 stale。
        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: attemptedAt,
            writtenAt: attemptedAt,
            lastSuccessfulRefreshAt: successfulAt,
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [
                snapshot(
                    status: .clean,
                    lastScannedAt: attemptedAt,
                    dataSource: .current,
                    lastSuccessfulScanAt: attemptedAt
                )
            ]
        )

        let assessment = RefreshStatusFormatter.snapshotAssessment(snapshot: snapshot, now: now)

        #expect(assessment.state == .stale)
    }

    @Test func futureSuccessfulTimestampCannotAppearJustUpdated() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let future = now.addingTimeInterval(5 * 60)

        #expect(RefreshStatusFormatter.freshness(for: future, now: now) == .unknown)
        #expect(RefreshStatusFormatter.updateLabel(for: future, now: now) == "更新时间未知")
    }

    @Test func refreshStatusExactlyThirtyMinutesIsStaleNotExpired() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = now.addingTimeInterval(-30 * 60)

        // expiredThreshold 判定是严格大于：恰好 30 分钟仍属于 stale。
        #expect(RefreshStatusFormatter.freshness(for: snapshot, now: now) == .stale)
        #expect(RefreshStatusFormatter.updateLabel(for: snapshot, now: now) == "30 分钟前更新")
    }

    @Test func snapshotTrustAssessmentMarksMigratedSnapshotFailed() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-03T00:00:00Z",
            writtenAt: "2026-07-03T00:00:00Z",
            lastSuccessfulRefreshAt: "2026-07-03T00:00:00Z",
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [snapshot(status: .clean, dataSource: .current)],
            persistenceState: .migrated
        )

        let assessment = RefreshStatusFormatter.snapshotAssessment(snapshot: snapshot, now: now)

        #expect(assessment.state == .failed)
        #expect(assessment.title == "旧版快照待确认")
    }

    @Test func snapshotTrustAssessmentMarksRecoveredSnapshotFailed() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-03T00:00:00Z",
            writtenAt: "2026-07-03T00:00:00Z",
            lastSuccessfulRefreshAt: "2026-07-03T00:00:00Z",
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [snapshot(status: .clean, dataSource: .current)],
            persistenceState: .recovered
        )

        let assessment = RefreshStatusFormatter.snapshotAssessment(snapshot: snapshot, now: now)

        #expect(assessment.state == .failed)
        #expect(assessment.title == "显示恢复数据")
    }

    @Test func snapshotTrustAssessmentAllUnknownRepositoriesWithoutSuccessfulData() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-03T00:05:00Z",
            writtenAt: "2026-07-03T00:05:00Z",
            lastSuccessfulRefreshAt: "2026-07-02T00:00:00Z",
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 1),
            repositories: [
                snapshot(
                    id: "unknown",
                    name: "unknown",
                    status: .error,
                    lastScannedAt: "2026-07-03T00:05:00Z",
                    dataSource: .unknown,
                    lastSuccessfulScanAt: nil,
                    errorMessage: "读取失败"
                )
            ]
        )

        let assessment = RefreshStatusFormatter.snapshotAssessment(snapshot: snapshot, now: now)

        #expect(assessment.state == .failed)
        #expect(assessment.title == "仓库数据未知")
    }

    @Test func snapshotTrustAssessmentMixedLastSuccessfulAndUnknownRepositories() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-03T00:05:00Z",
            writtenAt: "2026-07-03T00:05:00Z",
            lastSuccessfulRefreshAt: "2026-07-02T00:00:00Z",
            scanSummary: ScanSummary(totalRepositories: 2, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 2),
            repositories: [
                snapshot(
                    id: "stale",
                    name: "stale",
                    status: .error,
                    lastScannedAt: "2026-07-03T00:05:00Z",
                    dataSource: .lastSuccessful,
                    lastSuccessfulScanAt: "2026-07-02T00:00:00Z",
                    errorMessage: "读取失败"
                ),
                snapshot(
                    id: "unknown",
                    name: "unknown",
                    status: .error,
                    lastScannedAt: "2026-07-03T00:05:00Z",
                    dataSource: .unknown,
                    lastSuccessfulScanAt: nil,
                    errorMessage: "读取失败"
                )
            ]
        )

        let assessment = RefreshStatusFormatter.snapshotAssessment(snapshot: snapshot, now: now)

        #expect(assessment.state == .failed)
        #expect(assessment.title == "仓库数据待确认")
        #expect(assessment.detail.contains("1 个上次成功"))
        #expect(assessment.detail.contains("1 个未知"))
    }

    @Test func repositoryReadFailureReasonIsConciseAndActionSafe() {
        #expect(RepositoryReadFailureReason.conciseMessage(from: "Git command timeout") == "读取超时")
        #expect(RepositoryReadFailureReason.conciseMessage(from: "仓库暂时不可访问：/private/path") == "暂时无法访问")
        #expect(RepositoryReadFailureReason.conciseMessage(from: "unexpected details") == "读取失败")
    }

    @Test func completeRepositoryWatermarkUsesOldestProvenSuccess() {
        let older = "2026-07-17T08:00:00Z"
        let newer = "2026-07-17T08:05:00Z"
        let repositories = [
            snapshot(
                id: "older",
                name: "older",
                status: .clean,
                lastScannedAt: older,
                dataSource: .current,
                lastSuccessfulScanAt: older
            ),
            snapshot(
                id: "newer",
                name: "newer",
                status: .clean,
                lastScannedAt: newer,
                dataSource: .current,
                lastSuccessfulScanAt: newer
            )
        ]
        let data = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: newer,
            writtenAt: nil,
            scanSummary: ScanSummary.build(from: repositories),
            repositories: repositories
        )

        #expect(data.completeRepositorySuccessWatermark == older)
    }

    @Test func widgetPrioritySummaryUsesReadyAdviceWhenFresh() {
        let summary = WidgetPrioritySummaryBuilder.build(
            feed: ActivityTimelineFeed(
                state: .active,
                items: [ActivityTimelineItem(from: snapshot(modified: 1, staged: 1, unstaged: 0))]
            ),
            trustAssessment: freshTrust()
        )

        #expect(summary.title == "repo-1")
        #expect(summary.readinessLevel == .ready)
        #expect(summary.message == "看起来可以提交")
        #expect(summary.auxiliary == "1 处改动")
    }

    @Test func widgetPrioritySummaryUsesReviewAdviceWhenFresh() {
        let summary = WidgetPrioritySummaryBuilder.build(
            feed: ActivityTimelineFeed(
                state: .active,
                items: [ActivityTimelineItem(from: snapshot(modified: 2))]
            ),
            trustAssessment: freshTrust()
        )

        #expect(summary.title == "repo-1")
        #expect(summary.readinessLevel == .review)
        #expect(summary.message == "建议先审查改动")
    }

    @Test func widgetPrioritySummaryUsesCanonicalCleanDecisionReminders() {
        let repository = snapshot(
            modified: 0,
            ahead: nil,
            behind: nil,
            hasUpstream: false,
            status: .clean
        )
        let feed = ActivityTimelineBuilder.build(
            from: [repository],
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000)
        )
        let summary = WidgetPrioritySummaryBuilder.build(
            feed: feed,
            trustAssessment: freshTrust()
        )

        #expect(feed.state == .allClean)
        #expect(summary.message == repository.decision.widgetSummary)
        #expect(summary.message == "暂无改动 · 未关联上游")
    }

    @Test func widgetPrioritySummaryPrioritizesStaleTrust() {
        let summary = WidgetPrioritySummaryBuilder.build(
            feed: ActivityTimelineFeed(
                state: .active,
                items: [ActivityTimelineItem(from: snapshot(modified: 1, staged: 1, unstaged: 0))]
            ),
            trustAssessment: SnapshotTrustAssessment(
                state: .stale,
                title: "数据可能已过期",
                detail: "最近一次更新在 12 分钟前更新",
                basis: "test"
            )
        )

        #expect(summary.title == WidgetRefreshCopy.waitingRefreshTitle)
        #expect(summary.readinessLevel == nil)
        #expect(summary.message == WidgetRefreshCopy.waitingRefreshSummary)
    }

    @Test func widgetPrioritySummaryFallsBackToUnknownTrust() {
        let summary = WidgetPrioritySummaryBuilder.build(
            feed: ActivityTimelineFeed(
                state: .active,
                items: [ActivityTimelineItem(from: snapshot(modified: 1, staged: 1, unstaged: 0))]
            ),
            trustAssessment: SnapshotTrustAssessment(
                state: .unknown,
                title: "状态未知",
                detail: "无法确认数据是否最新",
                basis: "test"
            )
        )

        #expect(summary.title == WidgetRefreshCopy.pendingConfirmationTitle)
        #expect(summary.readinessLevel == nil)
        #expect(summary.message == WidgetRefreshCopy.pendingConfirmationSummary)
    }

    @Test func widgetPrioritySummaryUsesWaitingFirstRefreshForNeverScanned() {
        let summary = WidgetPrioritySummaryBuilder.build(
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            trustAssessment: nil
        )

        #expect(summary.title == WidgetRefreshCopy.waitingFirstRefreshTitle)
        #expect(summary.message == "打开 DevPulse 执行一次刷新")
    }

    @Test func widgetRefreshCopyBuildsConsistentWaitingRefreshDetail() {
        let detail = WidgetRefreshCopy.waitingRefreshDetail(
            from: SnapshotTrustAssessment(
                state: .stale,
                title: "数据可能已过期",
                detail: "最近一次更新在 12 分钟前更新",
                basis: "test"
            )
        )

        #expect(detail == "最近一次更新在 12 分钟前更新。打开 DevPulse 执行 Refresh Data")
    }

    @Test func widgetPrioritySummaryKeepsGitReadFailureVisibleWhenFresh() {
        let summary = WidgetPrioritySummaryBuilder.build(
            feed: ActivityTimelineFeed(
                state: .active,
                items: [ActivityTimelineItem(from: snapshot(status: .error, errorMessage: "读取失败"))]
            ),
            trustAssessment: freshTrust()
        )

        #expect(summary.title == "repo-1")
        #expect(summary.readinessLevel == .unknown)
        #expect(summary.message == "数据未知，先看 Diagnostics")
    }

    @Test func widgetRepositoryPriorityBuilderPrefersDirtyRepos() {
        let repos = [
            snapshot(id: "clean", name: "clean", modified: 0, status: .clean, lastChangedAt: "2026-06-20T10:00:00Z"),
            snapshot(id: "dirty", name: "dirty", modified: 1, status: .changed, lastChangedAt: "2026-06-18T10:00:00Z")
        ]

        let items = WidgetRepositoryPriorityBuilder.build(from: repos)

        #expect(items.map(\.repoName) == ["dirty", "clean"])
    }

    @Test func widgetRepositoryPriorityBuilderUsesReadinessAndRiskBeforeRecency() {
        let repos = [
            snapshot(id: "review", name: "review", modified: 1, risk: .low, lastChangedAt: "2026-06-22T10:00:00Z"),
            snapshot(id: "dirty", name: "dirty", modified: 5, risk: .high, lastChangedAt: "2026-06-21T10:00:00Z")
        ]

        let items = WidgetRepositoryPriorityBuilder.build(from: repos)

        #expect(items.map(\.repoName) == ["dirty", "review"])
    }

    @Test func widgetRepositoryPriorityBuilderUsesCanonicalDecisionBeforeRecency() {
        let repos = [
            snapshot(id: "older-high-risk", name: "older-high-risk", modified: 1, risk: .high, lastChangedAt: "2026-06-20T10:00:00Z"),
            snapshot(id: "newer-low-risk", name: "newer-low-risk", modified: 1, risk: .low, lastChangedAt: "2026-06-22T10:00:00Z")
        ]

        let items = WidgetRepositoryPriorityBuilder.build(from: repos)

        #expect(items.map(\.repoName) == ["older-high-risk", "newer-low-risk"])
    }

    @Test func widgetRepositoryPriorityBuilderUsesRecentActivityAsStableTieBreaker() {
        let repos = [
            snapshot(id: "older", name: "older", modified: 1, risk: .low, lastChangedAt: "2026-06-20T10:00:00Z"),
            snapshot(id: "newer", name: "newer", modified: 1, risk: .low, lastChangedAt: "2026-06-22T10:00:00Z")
        ]

        let items = WidgetRepositoryPriorityBuilder.build(from: repos)

        #expect(items.map(\.repoName) == ["newer", "older"])
    }

    @Test func everyWidgetFamilyKeepsCanonicalDecisionsAheadOfRecentEvents() {
        let repositories = [
            snapshot(id: "conflict", name: "conflict", modified: 1, conflicted: 1),
            snapshot(id: "dirty", name: "dirty", modified: 2),
            snapshot(id: "ahead", name: "ahead", modified: 0, ahead: 2, status: .clean),
            snapshot(id: "event-repository", name: "event-repository", modified: 0, status: .clean)
        ]
        let feed = ActivityTimelineBuilder.build(
            from: repositories,
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000)
        )
        let recentEvent = ActivityEventSummary(
            id: "recent-conflict-event",
            repositoryID: "event-repository",
            repositoryName: "event-repository",
            kind: .conflictStarted,
            occurredAt: "2026-07-16T10:00:00Z",
            message: "历史事件不应覆盖当前仓库决策",
            priority: 0
        )
        for (family, expectedLimit) in [
            (WidgetPrimaryContentFamily.small, 1),
            (.medium, 2),
            (.large, 3)
        ] {
            let selection = WidgetPrimaryContentSelectionBuilder.build(
                feed: feed,
                recentActivityEvents: [recentEvent],
                family: family
            )
            guard case .repositories(let items) = selection else {
                Issue.record("\(family) should render canonical repository decisions")
                continue
            }

            #expect(items == Array(feed.items.prefix(expectedLimit)))
            #expect(items.first?.decision == repositories[0].decision)
            #expect(items.first?.id != recentEvent.repositoryID)
        }
    }

    @Test func diagnosticsOverviewShowsHealthySharedChain() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.appGroupContainerPath = "/tmp/group.local.devpulse"
        diagnostics.snapshotExists = true
        diagnostics.snapshotFilePath = "/tmp/group.local.devpulse/repositories.json"
        diagnostics.sharedDataSnapshot = AppGroupData.empty()
        diagnostics.sharedDataReadAt = Date(timeIntervalSince1970: 1_718_000_000)
        diagnostics.widgetSnapshot = AppGroupData.empty()
        diagnostics.widgetSnapshotReadAt = Date(timeIntervalSince1970: 1_718_000_000)

        let overview = DiagnosticsOverviewBuilder.build(
            diagnostics: diagnostics,
            refreshTrust: freshTrust(),
            widgetTrust: freshTrust(),
            repositories: [snapshot(status: .clean)]
        )

        #expect(overview.severity == .normal)
        #expect(overview.headline == "链路正常")
        #expect(overview.sections.first?.severity == .normal)
    }

    @Test func diagnosticsOverviewTreatsInitialMissingSnapshotAsSetupStep() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.appGroupContainerPath = "/tmp/group.local.devpulse"
        diagnostics.snapshotExists = false
        diagnostics.snapshotFilePath = "/tmp/group.local.devpulse/repositories.json"

        let overview = DiagnosticsOverviewBuilder.build(
            diagnostics: diagnostics,
            refreshTrust: freshTrust(),
            widgetTrust: SnapshotTrustAssessment(
                state: .unknown,
                title: "状态未知",
                detail: "无法确认共享快照是否最新",
                basis: "共享快照缺失"
            ),
            repositories: []
        )

        #expect(overview.severity == .warning)
        #expect(overview.headline == "共享数据链路")
        #expect(overview.sections.first?.items.contains(where: { $0.title == "数据文件" && $0.severity == .warning }) == true)
    }

    @Test func diagnosticsOverviewFlagsMissingSnapshotAfterRepositoriesExist() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.appGroupContainerPath = "/tmp/group.local.devpulse"
        diagnostics.snapshotExists = false
        diagnostics.snapshotFilePath = "/tmp/group.local.devpulse/repositories.json"

        let overview = DiagnosticsOverviewBuilder.build(
            diagnostics: diagnostics,
            refreshTrust: freshTrust(),
            widgetTrust: SnapshotTrustAssessment(
                state: .unknown,
                title: "状态未知",
                detail: "无法确认共享快照是否最新",
                basis: "共享快照缺失"
            ),
            repositories: [snapshot(modified: 1)]
        )

        #expect(overview.severity == .error)
        #expect(overview.headline == "共享数据链路")
        #expect(overview.sections.first?.items.contains(where: { $0.title == "数据文件" && $0.severity == .error }) == true)
    }

    @Test func diagnosticsOverviewExplainsStaleWidgetData() throws {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.snapshotExists = true
        diagnostics.sharedDataSnapshot = AppGroupData.empty()
        diagnostics.widgetSnapshot = AppGroupData.empty()

        let overview = DiagnosticsOverviewBuilder.build(
            diagnostics: diagnostics,
            refreshTrust: freshTrust(),
            widgetTrust: SnapshotTrustAssessment(
                state: .stale,
                title: "数据可能已过期",
                detail: "最近一次更新在 12 分钟前更新",
                basis: "基于 writtenAt 判断已超过 10 分钟。"
            ),
            repositories: [snapshot(modified: 1)]
        )

        let widgetSection = try #require(overview.sections.first(where: { $0.id == "widget-state" }))
        #expect(widgetSection.severity == .warning)
        #expect(widgetSection.items.contains(where: { $0.title == "Widget 数据可信度" && $0.value == WidgetRefreshCopy.waitingRefreshTitle }) == true)
    }

    @Test func diagnosticsOverviewHighlightsGitReadFailure() throws {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.snapshotExists = true
        diagnostics.sharedDataSnapshot = AppGroupData.empty()
        diagnostics.widgetSnapshot = AppGroupData.empty()

        let overview = DiagnosticsOverviewBuilder.build(
            diagnostics: diagnostics,
            refreshTrust: freshTrust(),
            widgetTrust: freshTrust(),
            repositories: [snapshot(status: .error, errorMessage: "读取失败")]
        )

        let scanSection = try #require(overview.sections.first(where: { $0.id == "scan-state" }))
        #expect(scanSection.severity == .error)
        #expect(scanSection.items.contains(where: { $0.title == "仓库识别" && $0.detail.contains("读取失败") }) == true)
    }

    @Test func diagnosticsOverviewHandlesNoRepositoryState() throws {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.snapshotExists = true
        diagnostics.sharedDataSnapshot = AppGroupData.empty()
        diagnostics.widgetSnapshot = AppGroupData.empty()

        let overview = DiagnosticsOverviewBuilder.build(
            diagnostics: diagnostics,
            refreshTrust: freshTrust(),
            widgetTrust: freshTrust(),
            repositories: []
        )

        let scanSection = try #require(overview.sections.first(where: { $0.id == "scan-state" }))
        #expect(scanSection.severity == .warning)
        #expect(scanSection.items.contains(where: { $0.title == "仓库识别" && $0.value == "没有仓库" }) == true)
    }

    @Test func widgetDataTrustBuilderMarksHealthySnapshotAsTrusted() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.snapshotExists = true
        diagnostics.snapshotReadable = true
        diagnostics.snapshotWritable = true
        diagnostics.snapshotDecodable = true
        diagnostics.snapshotFilePath = "/tmp/group.local.devpulse/repositories.json"
        diagnostics.sharedDataSnapshot = AppGroupData.empty()
        diagnostics.widgetSnapshot = AppGroupData.empty()
        diagnostics.lastSharedWriteAt = Date(timeIntervalSince1970: 1_718_000_000)

        let trust = WidgetDataTrustBuilder.build(
            diagnostics: diagnostics,
            widgetTrust: freshTrust(),
            repositories: [snapshot(status: .clean)]
        )

        #expect(trust.severity == .normal)
        #expect(trust.headline == "当前 Widget 数据可信")
        #expect(trust.nextSteps.first == "当前可以信任 Widget 数据；如果桌面没有立即变化，等待 macOS 刷新时间线即可。")
        #expect(trust.primaryAction.kind == .refreshData)
        #expect(trust.primaryAction.title == "Refresh Data")
    }

    @Test func widgetDataTrustBuilderTreatsInitialMissingSnapshotAsSetupStep() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.snapshotExists = false
        diagnostics.snapshotReadable = false
        diagnostics.snapshotWritable = true
        diagnostics.snapshotDecodable = false

        let trust = WidgetDataTrustBuilder.build(
            diagnostics: diagnostics,
            widgetTrust: SnapshotTrustAssessment(
                state: .unknown,
                title: "状态未知",
                detail: "无法确认数据是否最新",
                basis: "共享快照缺失"
            ),
            repositories: []
        )

        #expect(trust.severity == .warning)
        #expect(trust.headline == "Widget 正等待首次刷新")
        #expect(trust.summary.contains("首次启动"))
        #expect(trust.nextSteps.first?.contains("Rescan Now") == true)
        #expect(trust.primaryAction.kind == .rescan)
        #expect(trust.primaryAction.title == "Rescan Now")
    }

    @Test func diagnosticsOverviewIncludesSnapshotStoreObservabilitySection() throws {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.snapshotExists = true
        diagnostics.snapshotReadable = true
        diagnostics.snapshotWritable = true
        diagnostics.snapshotDecodable = true
        diagnostics.sharedDataSnapshot = AppGroupData.empty()
        diagnostics.widgetSnapshot = AppGroupData.empty()
        diagnostics.lastSnapshotStoreTrigger = "scan"
        diagnostics.lastSnapshotStoreState = .verified
        diagnostics.lastSnapshotStoreDetail = "已写入并读回校验成功：1 个仓库，reason=scan。"
        diagnostics.lastWidgetReloadState = .skipped
        diagnostics.lastWidgetReloadDetail = "共享快照无实质变化，且距上次 reload 未超过 15 分钟，本次跳过 Widget reload。"
        diagnostics.lastRefreshStartedAt = Date(timeIntervalSince1970: 1_718_000_000)
        diagnostics.lastRefreshCompletedAt = Date(timeIntervalSince1970: 1_718_000_010)

        let overview = DiagnosticsOverviewBuilder.build(
            diagnostics: diagnostics,
            refreshTrust: freshTrust(),
            widgetTrust: freshTrust(),
            repositories: [snapshot(modified: 1)]
        )

        let section = try #require(overview.sections.first(where: { $0.id == "snapshot-store" }))
        #expect(section.severity == .normal)
        #expect(section.items.contains(where: { $0.title == "Snapshot Store" && $0.value == "写入并校验成功" }) == true)
        #expect(section.items.contains(where: { $0.title == "最近触发来源" && $0.value == "扫描刷新" }) == true)
        #expect(section.items.contains(where: { $0.title == "Widget reload" && $0.value == "本次跳过" }) == true)
    }

    @Test func missingSharedSnapshotUsesContainerWritableState() {
        #expect(AppGroupStore.resolveSnapshotWritable(
            snapshotExists: false,
            fileWritable: false,
            containerWritable: true
        ))
    }

    @Test func existingSharedSnapshotUsesFileWritableState() {
        #expect(AppGroupStore.resolveSnapshotWritable(
            snapshotExists: true,
            fileWritable: false,
            containerWritable: true
        ) == false)
    }

    @Test func widgetReloadDecisionRequestsReloadForManualRefreshPaths() {
        let decision = ScanSchedulerPolicy.widgetReloadDecision(
            previousSnapshot: AppGroupData.empty(),
            nextSnapshot: AppGroupData.empty(),
            reason: "pin toggle"
        )

        #expect(decision.shouldRequest)
        #expect(decision.detail.contains("pin toggle"))
    }

    /// 无变化扫描（"scan-nochanges"）仍需写回快照以清除 isRefreshing，
    /// 但快照内容无实质变化时不应触发 Widget reload（否则空闲扫描每小时
    /// 产生 6–12 次无意义 reload）。
    @Test func widgetReloadDecisionSkipsNoChangeScanWriteBack() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let baseline = snapshot(modified: 1)
        let previousSnapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-06-18T10:00:00Z",
            writtenAt: "2026-06-18T10:00:05Z",
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 1, totalChangedFiles: 1, errorRepositories: 0),
            repositories: [baseline]
        )
        let nextSnapshot = previousSnapshot

        let decision = ScanSchedulerPolicy.widgetReloadDecision(
            previousSnapshot: previousSnapshot,
            nextSnapshot: nextSnapshot,
            reason: "scan-nochanges"
        )

        #expect(decision.shouldRequest == false)
        #expect(decision.detail.contains("本次跳过"))
    }

    /// 无变化扫描但快照内容确实发生变化（例如分支切换）时，仍然必须 reload。
    @Test func widgetReloadDecisionReloadsNoChangeScanWhenContentChanged() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let previousSnapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-06-18T10:00:00Z",
            writtenAt: "2026-06-18T10:00:05Z",
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [snapshot(modified: 1, branch: "main")]
        )
        let nextSnapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-06-18T10:05:00Z",
            writtenAt: "2026-06-18T10:05:00Z",
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [snapshot(modified: 1, branch: "feature")]
        )

        let decision = ScanSchedulerPolicy.widgetReloadDecision(
            previousSnapshot: previousSnapshot,
            nextSnapshot: nextSnapshot,
            reason: "scan-nochanges"
        )

        #expect(decision.shouldRequest)
        #expect(decision.detail.contains("内容发生变化"))
    }

    @Test func widgetDataTrustBuilderUsesRefreshWhenResultsExistButSnapshotMissing() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.snapshotExists = false
        diagnostics.snapshotReadable = false
        diagnostics.snapshotWritable = true
        diagnostics.snapshotDecodable = false

        let trust = WidgetDataTrustBuilder.build(
            diagnostics: diagnostics,
            widgetTrust: SnapshotTrustAssessment(
                state: .unknown,
                title: "状态未知",
                detail: "无法确认数据是否最新",
                basis: "共享快照缺失"
            ),
            repositories: [snapshot(modified: 1)]
        )

        #expect(trust.severity == .error)
        #expect(trust.headline == "Widget 还没有可用快照")
        #expect(trust.summary.contains("主界面已经拿到扫描结果"))
        #expect(trust.nextSteps.first?.contains("Refresh Data") == true)
        #expect(trust.primaryAction.kind == .refreshData)
        #expect(trust.primaryAction.title == "Refresh Data")
    }

    @Test func widgetDataTrustBuilderFlagsStaleButReadableData() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.snapshotExists = true
        diagnostics.snapshotReadable = true
        diagnostics.snapshotWritable = true
        diagnostics.snapshotDecodable = true
        diagnostics.sharedDataSnapshot = AppGroupData.empty()
        diagnostics.widgetSnapshot = AppGroupData.empty()

        let trust = WidgetDataTrustBuilder.build(
            diagnostics: diagnostics,
            widgetTrust: SnapshotTrustAssessment(
                state: .stale,
                title: "数据可能已过期",
                detail: "最近一次更新在 12 分钟前更新",
                basis: "基于 writtenAt 判断已超过 10 分钟。"
            ),
            repositories: [snapshot(modified: 1)]
        )

        #expect(trust.severity == .warning)
        #expect(trust.headline == "当前 Widget 正等待刷新")
        #expect(trust.nextSteps.first?.contains("Refresh Data") == true)
        #expect(trust.primaryAction.kind == .refreshData)
        #expect(trust.primaryAction.title == "Refresh Data")
    }

    @Test func widgetDataTrustBuilderRoutesUnknownTrustToDiagnostics() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.appGroupAvailable = true
        diagnostics.snapshotExists = true
        diagnostics.snapshotReadable = true
        diagnostics.snapshotWritable = true
        diagnostics.snapshotDecodable = true

        let trust = WidgetDataTrustBuilder.build(
            diagnostics: diagnostics,
            widgetTrust: SnapshotTrustAssessment(
                state: .unknown,
                title: "状态未知",
                detail: "无法确认数据是否最新",
                basis: "Widget 缺少时间戳"
            ),
            repositories: []
        )

        #expect(trust.severity == .warning)
        #expect(trust.primaryAction.kind == .viewDiagnostics)
        #expect(trust.primaryAction.title == "查看诊断")
    }

    @Test func widgetPrimaryButtonShowsRescanAndDisablesWhileScanning() {
        let action = WidgetDataTrustPrimaryAction(
            kind: .rescan,
            title: "Rescan Now",
            systemImage: "arrow.triangle.2.circlepath",
            helpText: "先重新发现仓库并生成共享快照。"
        )

        let idleButton = WidgetDataTrustPrimaryButtonBuilder.build(action: action, isScanning: false)
        let scanningButton = WidgetDataTrustPrimaryButtonBuilder.build(action: action, isScanning: true)

        #expect(idleButton.title == "Rescan Now")
        #expect(idleButton.actionKind == .rescan)
        #expect(idleButton.isDisabled == false)
        #expect(scanningButton.title == "扫描中…")
        #expect(scanningButton.isDisabled)
    }

    @Test func widgetPrimaryButtonKeepsDiagnosticsAvailableDuringScanning() {
        let action = WidgetDataTrustPrimaryAction(
            kind: .viewDiagnostics,
            title: "查看诊断",
            systemImage: "stethoscope",
            helpText: "先看 Diagnostics，确认 generatedAt / writtenAt、共享快照和 Widget 读取结果。"
        )

        let button = WidgetDataTrustPrimaryButtonBuilder.build(action: action, isScanning: true)

        #expect(button.title == "查看诊断")
        #expect(button.actionKind == .viewDiagnostics)
        #expect(button.isDisabled == false)
    }

    @Test func widgetPrimaryButtonShowsRefreshingStateForRefreshAction() {
        let action = WidgetDataTrustPrimaryAction(
            kind: .refreshData,
            title: "Refresh Data",
            systemImage: "arrow.clockwise",
            helpText: "手动重写共享快照并请求 Widget 更新时间线。"
        )

        let button = WidgetDataTrustPrimaryButtonBuilder.build(action: action, isScanning: true)

        #expect(button.title == "刷新中…")
        #expect(button.actionKind == .refreshData)
        #expect(button.isDisabled)
    }

    @Test func overviewDiagnosticsNavigationTargetsSettingsDiagnostics() {
        #expect(OverviewDiagnosticsNavigation.tab == .settings)
        #expect(OverviewDiagnosticsNavigation.scrollTarget == .diagnostics)
    }

    @Test func repositoryStatusSummaryKeepsStatusAndAdviceSeparated() {
        let repo = snapshot(
            modified: 2,
            untracked: 1,
            staged: 1,
            unstaged: 1
        )

        #expect(repo.statusSummary == "3 处改动 · 已暂存 1 · 未暂存 1 · 未跟踪 1")
        #expect(repo.nextActionHint == "先拆清已暂存和未暂存改动，再决定是否提交。")
    }

    @Test func gitMetadataParserKeepsAheadBehindAndUpstreamAvailabilityDistinct() {
        let tracked = GitStatusParser.parseBranchMetadata(
            "## main...origin/main [ahead 2, behind 3]\n"
        )
        let localOnly = GitStatusParser.parseBranchMetadata("## feature/local\n")
        let initial = GitStatusParser.parseBranchMetadata("## No commits yet on trunk\n")

        #expect(tracked.branch == "main")
        #expect(tracked.aheadCount == 2)
        #expect(tracked.behindCount == 3)
        #expect(tracked.hasUpstream)
        #expect(localOnly.branch == "feature/local")
        #expect(localOnly.hasUpstream == false)
        #expect(initial.branch == "trunk")
        #expect(initial.hasUpstream == false)
    }

    @Test func gitMetadataParserReadsCommitTimeAndSummaryTogether() {
        let metadata = GitStatusParser.parseLastCommitMetadata(
            "2026-07-13T09:30:00+08:00\0修复项目优先级"
        )
        let currentMetadata = GitStatusParser.parseLastCommitMetadata(
            "0123456789abcdef\02026-07-14T09:30:00+08:00\0记录增量活动"
        )

        #expect(metadata?.commitID == nil)
        #expect(metadata?.committedAt == "2026-07-13T09:30:00+08:00")
        #expect(metadata?.summary == "修复项目优先级")
        #expect(currentMetadata?.commitID == "0123456789abcdef")
        #expect(currentMetadata?.committedAt == "2026-07-14T09:30:00+08:00")
        #expect(currentMetadata?.summary == "记录增量活动")
        #expect(GitStatusParser.parseLastCommitMetadata(nil) == nil)
    }

    @Test func repositoryListPresentationShowsRequiredSignalsWithoutEnglishReadinessLabels() {
        let repo = snapshot(
            modified: 0,
            ahead: 2,
            behind: 1,
            hasUpstream: true,
            status: .clean,
            lastChangedAt: "2026-07-13T08:00:00Z",
            lastCommitSummary: "Refine repository dashboard",
            lastActivityAt: "2026-07-13T09:30:00Z"
        )
        let presentation = RepositoryListItemPresentationBuilder.build(
            snapshot: repo,
            now: DateFormatting.date(from: "2026-07-13T10:00:00Z")!
        )

        #expect(presentation.action.kind == .synchronizeDivergedBranch)
        #expect(presentation.action.title == "同步分叉分支")
        #expect(presentation.latestCommit == "2 小时前 · Refine repository dashboard")
        #expect(presentation.localChanges == "0 处改动")
        #expect(presentation.synchronization == "领先 2 · 落后 1")
        #expect(presentation.recentActivity == "30 分钟前")
    }

    @Test func repositoryListPresentationUsesExplicitMissingDataFallbacks() {
        let failed = snapshot(
            modified: 0,
            ahead: nil,
            status: .error,
            branch: "unknown",
            errorMessage: "读取失败"
        )
        let failedPresentation = RepositoryListItemPresentationBuilder.build(snapshot: failed)
        let localOnlyPresentation = RepositoryListItemPresentationBuilder.build(
            snapshot: snapshot(
                modified: 0,
                ahead: nil,
                behind: nil,
                hasUpstream: false,
                status: .clean
            )
        )
        let lastKnownPresentation = RepositoryListItemPresentationBuilder.build(
            snapshot: snapshot(
                modified: 0,
                status: .clean,
                lastChangedAt: "2026-07-13T08:00:00Z",
                lastCommitSummary: "Last known subject",
                lastCommitMetadataAvailable: false
            ),
            now: DateFormatting.date(from: "2026-07-13T10:00:00Z")!
        )

        #expect(failedPresentation.action.title == "检查读取异常")
        #expect(failedPresentation.latestCommit == "提交信息未知")
        #expect(failedPresentation.localChanges == "本地改动未知")
        #expect(failedPresentation.synchronization == "同步状态未知")
        #expect(failedPresentation.recentActivity == "当前活动未知")
        #expect(localOnlyPresentation.synchronization == "未关联上游")
        #expect(localOnlyPresentation.action.title == "无需处理")
        #expect(lastKnownPresentation.latestCommit == "上次成功提交 · 2 小时前 · Last known subject")
    }

    @Test func currentRepositoryWithPartialCommitMetadataFailureKeepsCurrentReadiness() {
        let repository = snapshot(
            modified: 1,
            status: .changed,
            lastCommitSummary: "Last successful subject",
            lastCommitMetadataAvailable: false,
            dataSource: .current
        )
        let presentation = RepositoryListItemPresentationBuilder.build(snapshot: repository)

        #expect(repository.resolvedDataSource == .current)
        #expect(repository.commitReadiness.level == .review)
        #expect(repository.actionState.kind == .reviewLocalChanges)
        #expect(presentation.latestCommit.contains("上次成功提交"))
        #expect(presentation.dataSource.source == .current)
    }

    @Test func repositoryDetailMapsCleanAndUntrackedStatesFromExistingSnapshotFields() throws {
        let clean = RepositoryDetailPresentationBuilder.build(
            snapshot: snapshot(
                modified: 0,
                ahead: nil,
                behind: nil,
                hasUpstream: false,
                status: .clean
            )
        )
        let untracked = RepositoryDetailPresentationBuilder.build(
            snapshot: snapshot(
                modified: 0,
                untracked: 2,
                changedFilesPreview: ["Sources/NewFile.swift", "Docs/Notes.md"]
            )
        )

        #expect(clean.localSummary == "没有本地改动")
        #expect(clean.synchronization == "未关联上游")
        #expect(clean.changedFileNames.isEmpty)
        #expect(try #require(clean.changeItems.first(where: { $0.kind == .untracked })).count == 0)
        #expect(untracked.localSummary.contains("未跟踪 2"))
        #expect(try #require(untracked.changeItems.first(where: { $0.kind == .untracked })).count == 2)
        #expect(untracked.changedFileNames == ["NewFile.swift", "Notes.md"])
        #expect(untracked.nextAction == "先确认 2 个新文件是否纳入提交。")
    }

    @Test func repositoryDetailMapsMixedStagingAndConflictWithoutDuplicatingAdviceRules() throws {
        let mixedSnapshot = snapshot(
            modified: 2,
            untracked: 1,
            staged: 1,
            unstaged: 1
        )
        let conflictSnapshot = snapshot(
            modified: 1,
            staged: 1,
            unstaged: 1,
            conflicted: 1
        )
        let mixed = RepositoryDetailPresentationBuilder.build(snapshot: mixedSnapshot)
        let conflict = RepositoryDetailPresentationBuilder.build(snapshot: conflictSnapshot)

        #expect(try #require(mixed.changeItems.first(where: { $0.kind == .staged })).count == 1)
        #expect(try #require(mixed.changeItems.first(where: { $0.kind == .unstaged })).count == 1)
        #expect(mixed.nextAction == mixedSnapshot.nextActionHint)
        #expect(mixed.nextAction == "先拆清已暂存和未暂存改动，再决定是否提交。")
        #expect(try #require(conflict.changeItems.first(where: { $0.kind == .conflicted })).count == 1)
        #expect(conflict.nextAction == "先解决 1 处冲突，再继续审查或提交。")
    }

    @Test func repositoryDetailKeepsUpstreamAheadBehindStatesDistinct() {
        let noUpstream = RepositoryDetailPresentationBuilder.build(
            snapshot: snapshot(ahead: nil, behind: nil, hasUpstream: false)
        )
        let ahead = RepositoryDetailPresentationBuilder.build(
            snapshot: snapshot(modified: 0, ahead: 2, behind: 0, hasUpstream: true, status: .clean)
        )
        let behind = RepositoryDetailPresentationBuilder.build(
            snapshot: snapshot(modified: 0, ahead: 0, behind: 3, hasUpstream: true, status: .clean)
        )
        let diverged = RepositoryDetailPresentationBuilder.build(
            snapshot: snapshot(modified: 0, ahead: 2, behind: 3, hasUpstream: true, status: .clean)
        )

        #expect(noUpstream.synchronization == "未关联上游")
        #expect(ahead.synchronization == "领先 2 · 落后 0")
        #expect(ahead.nextAction == "确认准备好后 push 2 个本地提交。")
        #expect(behind.synchronization == "领先 0 · 落后 3")
        #expect(behind.nextAction == "先拉取 3 个远端更新，再继续本地工作。")
        #expect(diverged.synchronization == "领先 2 · 落后 3")
        #expect(diverged.nextAction == "本地和远端都有新提交，先确认分叉范围再同步。")
    }

    @Test func repositoryDetailSeparatesFailedAndRetainedData() throws {
        let failed = RepositoryDetailPresentationBuilder.build(
            snapshot: snapshot(
                modified: 0,
                staged: 0,
                ahead: nil,
                status: .error,
                branch: "unknown",
                dataSource: .unknown,
                errorMessage: "读取失败"
            )
        )
        let retained = RepositoryDetailPresentationBuilder.build(
            snapshot: snapshot(
                modified: 2,
                staged: 2,
                unstaged: 0,
                ahead: 1,
                behind: 0,
                hasUpstream: true,
                status: .error,
                dataSource: .lastSuccessful,
                lastSuccessfulScanAt: "2026-07-15T10:00:00Z",
                errorMessage: "本轮扫描失败",
                changedFilesPreview: ["Sources/A.swift", "Tests/ATests.swift"]
            )
        )

        #expect(failed.dataSource.source == .unknown)
        #expect(failed.branch == "分支未知")
        #expect(failed.changedFileNames.isEmpty)
        #expect(failed.changeItems.allSatisfy { $0.count == nil })
        #expect(failed.nextAction.contains("当前没有可用于提交、push 或同步的可信数据"))
        #expect(failed.diagnosticMessage == "读取失败")

        #expect(retained.dataSource.source == .lastSuccessful)
        #expect(retained.branch == "上次 · main")
        #expect(retained.changedFileNames == ["A.swift", "ATests.swift"])
        #expect(try #require(retained.changeItems.first(where: { $0.kind == .staged })).count == 2)
        #expect(retained.localSummary == "当前状态待确认 · 显示上次成功数据")
        #expect(retained.nextAction.contains("先重新扫描确认当前状态"))
    }

    @Test func repositoryDetailFilePreviewExposesBasenamesOnly() {
        let names = RepositoryDetailPresentationBuilder.privacySafeBasenames([
            "Sources/Feature/Secret.swift",
            "/Users/example/private/Config.plist",
            "Other/Secret.swift",
            "README.md",
            "  "
        ])

        #expect(names == ["Secret.swift", "Config.plist", "README.md"])
        #expect(names.allSatisfy { !$0.contains("/") })
    }

    @Test func repositoryDetailExternalActionsOnlyOpenDirectoryTargets() throws {
        let finder = try #require(
            RepositoryExternalOpenRequestBuilder.build(
                action: .finder,
                repositoryPath: "/tmp/example-repository"
            )
        )
        let terminal = try #require(
            RepositoryExternalOpenRequestBuilder.build(
                action: .terminal,
                repositoryPath: "/tmp/example-repository"
            )
        )

        #expect(RepositoryExternalOpenAction.allCases == [.finder, .terminal])
        #expect(finder.repositoryURL.isFileURL)
        #expect(finder.applicationURL == nil)
        #expect(terminal.repositoryURL == finder.repositoryURL)
        #expect(terminal.applicationURL == RepositoryExternalOpenRequestBuilder.terminalApplicationURL)
        #expect(RepositoryExternalOpenRequestBuilder.build(action: .terminal, repositoryPath: "relative/path") == nil)
    }

    @Test func legacyV1SnapshotsInferTrustSourceFromRepositoryStatus() throws {
        let repositories = [
            snapshot(id: "clean", name: "clean", status: .clean),
            snapshot(id: "changed", name: "changed", modified: 1),
            snapshot(id: "error", name: "error", status: .error, errorMessage: "读取失败")
        ]
        let current = AppGroupData(
            schemaVersion: 1,
            generatedAt: "2026-07-14T00:00:00Z",
            writtenAt: "2026-07-14T00:00:01Z",
            scanSummary: ScanSummary(totalRepositories: 3, changedRepositories: 3, totalChangedFiles: 99, errorRepositories: 0),
            repositories: repositories
        )
        let encoded = try JSONEncoder().encode(current)
        var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var legacyRepositories = try #require(legacyObject["repositories"] as? [[String: Any]])
        for index in legacyRepositories.indices {
            legacyRepositories[index].removeValue(forKey: "dataSource")
            legacyRepositories[index].removeValue(forKey: "lastSuccessfulScanAt")
        }
        legacyObject["repositories"] = legacyRepositories

        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(AppGroupData.self, from: legacyData)

        #expect(decoded.repositories.first(where: { $0.id == "clean" })?.resolvedDataSource == .current)
        #expect(decoded.repositories.first(where: { $0.id == "changed" })?.resolvedDataSource == .current)
        let errored = try #require(decoded.repositories.first(where: { $0.id == "error" }))
        #expect(errored.resolvedDataSource == .unknown)
        #expect(errored.commitReadiness.level == .unknown)

        let normalizedForWidget = RepositoryIdentity.normalize(decoded)
        #expect(normalizedForWidget.scanSummary.changedRepositories == 1)
        #expect(normalizedForWidget.scanSummary.totalChangedFiles == 1)
        #expect(normalizedForWidget.scanSummary.errorRepositories == 1)
    }

    @Test func staleAndUnknownSourcesUseRefreshSafetyAcrossPresentationsAndWidgetPriority() throws {
        let current = snapshot(
            id: "current",
            name: "current",
            modified: 1,
            lastChangedAt: "2026-07-14T10:00:00Z",
            dataSource: .current
        )
        let stale = snapshot(
            id: "stale",
            name: "stale",
            modified: 5,
            staged: 5,
            ahead: 2,
            dataSource: .lastSuccessful,
            lastSuccessfulScanAt: "2026-07-14T08:00:00Z"
        )
        let unknown = snapshot(
            id: "unknown",
            name: "unknown",
            status: .error,
            dataSource: .unknown,
            errorMessage: "读取失败"
        )

        let stalePresentation = RepositoryListItemPresentationBuilder.build(snapshot: stale)
        #expect(stalePresentation.dataSource.source == .lastSuccessful)
        #expect(stalePresentation.action.kind == .refreshRepositoryState)
        #expect(stale.commitReadiness.level == .unknown)

        let unknownPresentation = RepositoryListItemPresentationBuilder.build(snapshot: unknown)
        #expect(unknownPresentation.dataSource.source == .unknown)
        #expect(unknownPresentation.action.kind == .diagnoseReadFailure)
        #expect(unknown.commitReadiness.level == .unknown)

        let timeline = ActivityTimelineBuilder.build(
            from: [stale, current, unknown],
            lastScanAt: DateFormatting.date(from: "2026-07-14T10:00:00Z")
        )
        let staleItem = try #require(timeline.items.first(where: { $0.id == "stale" }))
        let unknownItem = try #require(timeline.items.first(where: { $0.id == "unknown" }))
        #expect(staleItem.resolvedDataSource == .lastSuccessful)
        #expect(staleItem.commitReadiness.level == .unknown)
        #expect(unknownItem.resolvedDataSource == .unknown)
        #expect(unknownItem.commitReadiness.level == .unknown)

        let widgetItems = WidgetRepositoryPriorityBuilder.build(from: [stale, current, unknown])
        #expect(widgetItems.first(where: { $0.id == "stale" })?.resolvedDataSource == .lastSuccessful)
        #expect(widgetItems.first(where: { $0.id == "unknown" })?.commitReadiness.level == .unknown)
        #expect(Set(widgetItems.map(\.id)) == Set(timeline.items.map(\.id)))
    }

    @Test func appGroupRetentionKeepsOriginalSuccessfulTimestampAcrossFailures() throws {
        let successfulAt = "2026-07-14T08:00:00Z"
        let initial = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: successfulAt,
            writtenAt: successfulAt,
            lastSuccessfulRefreshAt: successfulAt,
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 1, totalChangedFiles: 1, errorRepositories: 0),
            repositories: [
                snapshot(
                    modified: 1,
                    staged: 1,
                    lastScannedAt: successfulAt,
                    dataSource: .current
                )
            ]
        )

        let firstFailure = initial.retainingLastSuccessfulRepositories(
            attemptedAt: "2026-07-14T09:00:00Z",
            errorMessage: "Git 读取失败"
        )
        let secondFailure = firstFailure.retainingLastSuccessfulRepositories(
            attemptedAt: "2026-07-14T10:00:00Z",
            errorMessage: "Git 读取失败"
        )
        let firstRepository = try #require(firstFailure.repositories.first)
        let secondRepository = try #require(secondFailure.repositories.first)

        #expect(firstRepository.resolvedDataSource == .lastSuccessful)
        #expect(firstRepository.resolvedLastSuccessfulScanAt == successfulAt)
        #expect(firstRepository.actionState.kind == .refreshRepositoryState)
        #expect(secondRepository.resolvedDataSource == .lastSuccessful)
        #expect(secondRepository.resolvedLastSuccessfulScanAt == successfulAt)
        #expect(secondRepository.lastScannedAt == "2026-07-14T10:00:00Z")
        #expect(secondRepository.commitReadiness.level == .unknown)
        #expect(secondFailure.generatedAt == successfulAt)
        #expect(secondFailure.lastSuccessfulRefreshAt == successfulAt)
        #expect(secondFailure.scanSummary.changedRepositories == 0)
        #expect(secondFailure.scanSummary.totalChangedFiles == 0)
        #expect(secondFailure.scanSummary.errorRepositories == 1)
    }

    @Test func schedulerPolicyTreatsOnlyUnavailableRepositoriesAsScanFailure() {
        let stale = snapshot(
            id: "stale",
            name: "stale",
            modified: 3,
            dataSource: .lastSuccessful,
            lastSuccessfulScanAt: "2026-07-14T08:00:00Z"
        )
        let unknown = snapshot(
            id: "unknown",
            name: "unknown",
            status: .error,
            dataSource: .unknown,
            errorMessage: "读取失败"
        )
        let current = snapshot(id: "current", name: "current", modified: 1, dataSource: .current)

        #expect(ScanSchedulerPolicy.allRepositoryDataUnavailable([stale, unknown]))
        #expect(!ScanSchedulerPolicy.allRepositoryDataUnavailable([stale, current]))
        #expect(!ScanSchedulerPolicy.allRepositoryDataUnavailable([]))
    }

    @Test func branchPresentationNeverShowsRetainedBranchAsCurrent() {
        let current = snapshot(branch: "main", dataSource: .current)
        let stale = snapshot(
            branch: "feature/stale",
            dataSource: .lastSuccessful,
            lastSuccessfulScanAt: "2026-07-14T08:00:00Z"
        )
        let unknown = snapshot(
            status: .error,
            branch: "feature/unverified",
            dataSource: .unknown,
            errorMessage: "读取失败"
        )

        #expect(current.branchDisplayLabel == "main")
        #expect(stale.branchDisplayLabel == "上次 · feature/stale")
        #expect(unknown.branchDisplayLabel == "分支未知")
        #expect(ActivityTimelineItem(from: stale).branchDisplayLabel == stale.branchDisplayLabel)
    }

    @Test func repositorySorterPreservesPinsThenOrdersTheActionQueue() {
        let repositories = [
            snapshot(id: "clean", name: "clean", modified: 0, ahead: 0, behind: 0, hasUpstream: true, status: .clean),
            snapshot(id: "behind", name: "behind", modified: 0, ahead: 0, behind: 2, hasUpstream: true, status: .clean),
            snapshot(id: "changed", name: "changed", modified: 1, ahead: 0, behind: 0, hasUpstream: true),
            snapshot(id: "ahead", name: "ahead", modified: 0, ahead: 2, behind: 0, hasUpstream: true, status: .clean),
            snapshot(id: "error", name: "error", modified: 0, ahead: nil, status: .error, branch: "unknown", errorMessage: "读取失败"),
            snapshot(id: "pinned", name: "pinned", modified: 0, ahead: 0, behind: 0, hasUpstream: true, status: .clean, isPinned: true)
        ]

        let sorted = RepositorySorter.sort(repositories)

        #expect(sorted.map(\.name) == ["pinned", "error", "ahead", "changed", "behind", "clean"])
    }

    @Test func repositoryListQuerySearchesNamesAndPathsFromSnapshots() {
        let repositories = [
            snapshot(
                id: "path-match",
                name: "Workspace",
                path: "/Users/test/Client/DevPulse",
                modified: 0,
                status: .clean
            ),
            snapshot(
                id: "name-match",
                name: "CaféKit",
                path: "/Users/test/Libraries/CafeKit",
                modified: 0,
                status: .clean,
                isPinned: true
            ),
            snapshot(id: "other", name: "Other", modified: 0, status: .clean)
        ]

        let nameMatches = RepositoryListQuery.apply(
            to: repositories,
            searchText: "  cafe  ",
            filter: .all
        )
        let pathMatches = RepositoryListQuery.apply(
            to: repositories,
            searchText: "/CLIENT/devpulse",
            filter: .all
        )
        let noMatches = RepositoryListQuery.apply(
            to: repositories,
            searchText: "missing",
            filter: .all
        )

        #expect(nameMatches.map(\.id) == ["name-match"])
        #expect(pathMatches.map(\.id) == ["path-match"])
        #expect(noMatches.isEmpty)
    }

    @Test func repositoryListFiltersUseCanonicalSnapshotSemantics() {
        let clean = snapshot(
            id: "clean",
            name: "clean",
            modified: 0,
            ahead: 0,
            behind: 0,
            hasUpstream: true,
            status: .clean
        )
        let noUpstream = snapshot(
            id: "no-upstream",
            name: "no-upstream",
            modified: 0,
            ahead: 0,
            behind: 0,
            hasUpstream: false,
            status: .clean
        )
        let changed = snapshot(
            id: "changed",
            name: "changed",
            modified: 2,
            ahead: 0,
            behind: 0,
            hasUpstream: true
        )
        let ahead = snapshot(
            id: "ahead",
            name: "ahead",
            modified: 0,
            ahead: 2,
            behind: 0,
            hasUpstream: true,
            status: .clean
        )
        let retained = snapshot(
            id: "retained",
            name: "retained",
            modified: 3,
            dataSource: .lastSuccessful,
            lastSuccessfulScanAt: "2026-06-18T00:00:00Z",
            errorMessage: "读取超时"
        )
        let repositories = [clean, noUpstream, changed, ahead, retained]

        func ids(for filter: RepositoryListFilter) -> Set<String> {
            Set(RepositoryListQuery.apply(
                to: repositories,
                searchText: "",
                filter: filter
            ).map(\.id))
        }

        #expect(ids(for: .all) == ["clean", "no-upstream", "changed", "ahead", "retained"])
        #expect(ids(for: .needsAttention) == ["changed", "ahead", "retained"])
        #expect(ids(for: .localChanges) == ["changed"])
        #expect(ids(for: .unsynchronized) == ["no-upstream", "ahead"])
        #expect(ids(for: .errors) == ["retained"])
    }

    @Test func repositoryListPreferencesRoundTripAndRecoverFromInvalidData() throws {
        let suiteName = "DevPulseTests.RepositoryListPreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RepositoryListPreferencesStore(defaults: defaults)
        #expect(store.load() == .defaultValue)

        let expected = RepositoryListPreferences(
            searchText: "client/repository",
            filter: .unsynchronized
        )
        store.save(expected)

        let rebuiltStore = RepositoryListPreferencesStore(defaults: defaults)
        #expect(rebuiltStore.load() == expected)

        defaults.set(
            Data("not-json".utf8),
            forKey: RepositoryListPreferencesStore.storageKey
        )
        #expect(rebuiltStore.load() == .defaultValue)

        defaults.set(
            try JSONEncoder().encode(RepositoryListPreferences(
                version: RepositoryListPreferences.currentVersion + 1,
                searchText: "future",
                filter: .errors
            )),
            forKey: RepositoryListPreferencesStore.storageKey
        )
        #expect(rebuiltStore.load() == .defaultValue)
    }

    @Test func overviewFocusPrioritizesWidgetTrustErrors() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.scanRoots = ["/tmp/projects"]

        let focus = OverviewFocusBuilder.build(
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000),
            diagnostics: diagnostics,
            widgetTrust: WidgetDataTrustModel(
                headline: "当前 Widget 数据不可信，建议先修复",
                summary: "共享快照缺失，当前无法确认桌面 Widget 是否展示了最新状态。",
                severity: .error,
                evidence: [],
                nextSteps: ["先执行一次 Rescan Now，确认主 App 已生成共享快照。"],
                primaryAction: WidgetDataTrustPrimaryAction(
                    kind: .rescan,
                    title: "重新扫描",
                    systemImage: "arrow.triangle.2.circlepath",
                    helpText: "先重新发现仓库并生成共享快照。"
                )
            ),
            repositories: [snapshot(modified: 1)]
        )

        #expect(focus.title == "当前 Widget 数据不可信，建议先修复")
        #expect(focus.action.kind == .rescan)
        #expect(focus.severity == .error)
    }

    @Test func overviewFocusPrioritizesMissingScanRootsBeforeWidgetErrors() {
        let focus = OverviewFocusBuilder.build(
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000),
            diagnostics: DiagnosticsSnapshot(),
            widgetTrust: WidgetDataTrustModel(
                headline: "Widget 还没有可用快照",
                summary: "共享快照缺失。",
                severity: .error,
                evidence: [],
                nextSteps: ["先执行一次 Rescan Now。"],
                primaryAction: WidgetDataTrustPrimaryAction(
                    kind: .rescan,
                    title: "重新扫描",
                    systemImage: "arrow.triangle.2.circlepath",
                    helpText: "test"
                )
            ),
            repositories: []
        )

        #expect(focus.title == "没有可用的扫描目录")
        #expect(focus.action.kind == .openSettings)
    }

    @Test func overviewFocusPrioritizesFirstScanBeforeWidgetErrors() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.scanRoots = ["/tmp/projects"]

        let focus = OverviewFocusBuilder.build(
            lastScanAt: nil,
            diagnostics: diagnostics,
            widgetTrust: WidgetDataTrustModel(
                headline: "Widget 还没有可用快照",
                summary: "共享快照缺失。",
                severity: .error,
                evidence: [],
                nextSteps: ["先执行一次 Rescan Now。"],
                primaryAction: WidgetDataTrustPrimaryAction(
                    kind: .rescan,
                    title: "重新扫描",
                    systemImage: "arrow.triangle.2.circlepath",
                    helpText: "test"
                )
            ),
            repositories: []
        )

        #expect(focus.title == "尚未开始扫描")
        #expect(focus.action.kind == .rescan)
        #expect(focus.action.title == "Rescan Now")
    }

    @Test func overviewFocusPrioritizesRepositoryDiscoveryBeforeWidgetErrors() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.scanRoots = ["/tmp/projects"]

        let focus = OverviewFocusBuilder.build(
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000),
            diagnostics: diagnostics,
            widgetTrust: WidgetDataTrustModel(
                headline: "Widget 还没有可用快照",
                summary: "共享快照缺失。",
                severity: .error,
                evidence: [],
                nextSteps: ["先执行一次 Rescan Now。"],
                primaryAction: WidgetDataTrustPrimaryAction(
                    kind: .rescan,
                    title: "重新扫描",
                    systemImage: "arrow.triangle.2.circlepath",
                    helpText: "test"
                )
            ),
            repositories: []
        )

        #expect(focus.title == "还没有发现仓库")
        #expect(focus.action.kind == .openSettings)
    }

    @Test func overviewFocusRoutesBrokenRepositoryToDiagnostics() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.scanRoots = ["/tmp/projects"]

        let focus = OverviewFocusBuilder.build(
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000),
            diagnostics: diagnostics,
            widgetTrust: WidgetDataTrustModel(
                headline: "当前 Widget 数据可信",
                summary: "test",
                severity: .normal,
                evidence: [],
                nextSteps: [],
                primaryAction: WidgetDataTrustPrimaryAction(
                    kind: .refreshData,
                    title: "刷新数据",
                    systemImage: "arrow.clockwise",
                    helpText: "test"
                )
            ),
            repositories: [snapshot(status: .error, errorMessage: "读取失败")]
        )

        #expect(focus.title == "repo-1 当前数据未知")
        #expect(focus.action.kind == .openDiagnostics)
        #expect(focus.detail == "先看 Diagnostics 并重新扫描；当前没有可用于提交、push 或同步的可信数据。")
    }

    @Test func overviewFocusProjectsCanonicalUnavailableDecisions() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.scanRoots = ["/tmp/projects"]
        let widgetTrust = WidgetDataTrustModel(
            headline: "当前 Widget 数据可信",
            summary: "test",
            severity: .normal,
            evidence: [],
            nextSteps: [],
            primaryAction: WidgetDataTrustPrimaryAction(
                kind: .refreshData,
                title: "刷新数据",
                systemImage: "arrow.clockwise",
                helpText: "test"
            )
        )
        let rows: [(RepositorySnapshot, String, OverviewPrimaryActionKind)] = [
            (
                snapshot(
                    id: "overview-retained",
                    name: "overview-retained",
                    status: .error,
                    dataSource: .lastSuccessful,
                    lastSuccessfulScanAt: "2026-07-15T10:00:00Z",
                    errorMessage: "读取失败"
                ),
                "overview-retained 正显示上次成功数据",
                .refreshData
            ),
            (
                snapshot(
                    id: "overview-unknown",
                    name: "overview-unknown",
                    status: .error,
                    dataSource: .unknown,
                    errorMessage: "读取失败"
                ),
                "overview-unknown 当前数据未知",
                .openDiagnostics
            ),
            (
                snapshot(
                    id: "overview-current-failure",
                    name: "overview-current-failure",
                    status: .error,
                    dataSource: .current,
                    errorMessage: "读取失败"
                ),
                "overview-current-failure 状态读取失败",
                .openDiagnostics
            )
        ]

        for (repository, title, actionKind) in rows {
            let focus = OverviewFocusBuilder.build(
                lastScanAt: Date(timeIntervalSince1970: 1_718_000_000),
                diagnostics: diagnostics,
                widgetTrust: widgetTrust,
                repositories: [repository]
            )

            #expect(focus.title == title)
            #expect(focus.summary == repository.decision.summary)
            #expect(focus.detail == repository.decision.explanation)
            #expect(focus.action.kind == actionKind)
        }
    }

    @Test func overviewFocusUsesRepositoriesAsPrimaryActionWhenWorkExists() {
        var diagnostics = DiagnosticsSnapshot()
        diagnostics.scanRoots = ["/tmp/projects"]

        let focus = OverviewFocusBuilder.build(
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000),
            diagnostics: diagnostics,
            widgetTrust: WidgetDataTrustModel(
                headline: "当前 Widget 正等待刷新",
                summary: "桌面 Widget 看到的数据可能不是最新一轮扫描结果。",
                severity: .warning,
                evidence: [],
                nextSteps: ["如果只看主界面，可以先处理当前仓库。"],
                primaryAction: WidgetDataTrustPrimaryAction(
                    kind: .refreshData,
                    title: "刷新数据",
                    systemImage: "arrow.clockwise",
                    helpText: "手动重写共享快照并请求 Widget 更新时间线。"
                )
            ),
            repositories: [snapshot(modified: 2)]
        )

        #expect(focus.title == "repo-1")
        #expect(focus.action.kind == .openRepositories)
        #expect(focus.summary == "2 处改动 · 未暂存 2")
    }

    @Test func overviewFocusSendsMissingRepositoriesToSettings() {
        let focus = OverviewFocusBuilder.build(
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000),
            diagnostics: DiagnosticsSnapshot(),
            widgetTrust: WidgetDataTrustModel(
                headline: "当前 Widget 数据可信",
                summary: "test",
                severity: .normal,
                evidence: [],
                nextSteps: [],
                primaryAction: WidgetDataTrustPrimaryAction(
                    kind: .refreshData,
                    title: "刷新数据",
                    systemImage: "arrow.clockwise",
                    helpText: "test"
                )
            ),
            repositories: []
        )

        #expect(focus.title == "没有可用的扫描目录")
        #expect(focus.action.kind == .openSettings)
        #expect(focus.severity == .warning)
    }

    @Test func repositoryDecisionTableCoversCriticalStateCombinations() {
        let retained = snapshot(
            id: "retained",
            modified: 2,
            staged: 2,
            unstaged: 0,
            status: .error,
            dataSource: .lastSuccessful,
            lastSuccessfulScanAt: "2026-07-15T10:00:00Z",
            errorMessage: "本轮读取失败"
        )
        let unknown = snapshot(
            id: "unknown",
            status: .error,
            branch: "unknown",
            dataSource: .unknown,
            errorMessage: "读取失败"
        )
        let currentReadFailure = snapshot(
            id: "read-failure",
            status: .error,
            dataSource: .current,
            errorMessage: "读取失败"
        )
        let conflict = snapshot(id: "conflict", modified: 1, conflicted: 1)
        let unknownBranch = snapshot(id: "unknown-branch", modified: 1, branch: "unknown")
        let detached = snapshot(id: "detached", modified: 1, branch: "detached")
        let diverged = snapshot(
            id: "diverged",
            modified: 0,
            ahead: 2,
            behind: 3,
            hasUpstream: true,
            status: .clean
        )
        let behindWithChanges = snapshot(
            id: "behind-with-changes",
            modified: 1,
            ahead: 0,
            behind: 2,
            hasUpstream: true
        )
        let aheadWithChanges = snapshot(
            id: "ahead-with-changes",
            modified: 1,
            ahead: 2,
            behind: 0,
            hasUpstream: true
        )
        let stagedOnly = snapshot(
            id: "staged-only",
            modified: 2,
            staged: 2,
            unstaged: 0,
            ahead: 0,
            behind: 0,
            hasUpstream: true
        )
        let mixed = snapshot(
            id: "mixed",
            modified: 2,
            staged: 1,
            unstaged: 1,
            ahead: 0,
            behind: 0,
            hasUpstream: true
        )
        let untracked = snapshot(
            id: "untracked",
            untracked: 1,
            ahead: 0,
            behind: 0,
            hasUpstream: true
        )
        let aheadOnly = snapshot(
            id: "ahead-only",
            modified: 0,
            ahead: 2,
            behind: 0,
            hasUpstream: true,
            status: .clean
        )
        let behindOnly = snapshot(
            id: "behind-only",
            modified: 0,
            ahead: 0,
            behind: 2,
            hasUpstream: true,
            status: .clean
        )
        let noUpstream = snapshot(
            id: "no-upstream",
            modified: 0,
            ahead: nil,
            behind: nil,
            hasUpstream: false,
            status: .clean
        )
        let clean = snapshot(
            id: "clean-decision",
            modified: 0,
            ahead: 0,
            behind: 0,
            hasUpstream: true,
            status: .clean
        )

        let rows: [(
            snapshot: RepositorySnapshot,
            trust: RepositoryDataSource,
            action: RepositoryActionKind,
            blocker: RepositoryDecisionBlockingReason?,
            readiness: CommitReadinessLevel
        )] = [
            (retained, .lastSuccessful, .refreshRepositoryState, .retainedData, .unknown),
            (unknown, .unknown, .diagnoseReadFailure, .unavailableData, .unknown),
            (currentReadFailure, .current, .diagnoseReadFailure, .readFailure, .unknown),
            (conflict, .current, .resolveConflicts, .conflicts(count: 1), .dirty),
            (unknownBranch, .current, .confirmBranch, .branchUnknown, .review),
            (detached, .current, .confirmBranch, .detachedHead, .review),
            (diverged, .current, .synchronizeDivergedBranch, .divergedBranch(ahead: 2, behind: 3), .review),
            (behindWithChanges, .current, .reviewLocalChanges, .remoteUpdatesWithLocalChanges(count: 2), .review),
            (aheadWithChanges, .current, .reviewLocalChanges, nil, .review),
            (stagedOnly, .current, .commitStagedChanges, nil, .ready),
            (mixed, .current, .reviewLocalChanges, nil, .review),
            (untracked, .current, .reviewLocalChanges, nil, .review),
            (aheadOnly, .current, .pushLocalCommits, nil, .ready),
            (behindOnly, .current, .pullRemoteUpdates, .remoteUpdates(count: 2), .review),
            (noUpstream, .current, .noActionNeeded, nil, .idle),
            (clean, .current, .noActionNeeded, nil, .idle)
        ]

        for row in rows {
            let decision = row.snapshot.decision
            #expect(decision == RepositoryDecisionEngine.decide(snapshot: row.snapshot))
            #expect(decision.dataTrust == row.trust)
            #expect(decision.primaryAction.kind == row.action)
            #expect(decision.blockingReason == row.blocker)
            #expect(decision.commitReadiness.level == row.readiness)
            #expect(decision.sortPriority == decision.primaryAction.sortPriority)
            #expect(!decision.summary.isEmpty)
            #expect(!decision.explanation.isEmpty)
            #expect(!decision.widgetSummary.isEmpty)
        }

        #expect(aheadWithChanges.decision.secondaryReminders.contains(.unpushedCommits(count: 2)))
        #expect(!aheadWithChanges.decision.explanation.contains("确认准备好后 push"))
        #expect(behindWithChanges.decision.secondaryReminders.contains(.remoteUpdates(count: 2)))
        #expect(!behindWithChanges.decision.explanation.contains("可以提交"))
        #expect(mixed.decision.secondaryReminders.contains(.mixedStagedAndUnstagedChanges))
        #expect(untracked.decision.secondaryReminders.contains(.untrackedFiles(count: 1)))
        #expect(noUpstream.decision.secondaryReminders == [.noUpstream])
        #expect(clean.decision.secondaryReminders.isEmpty)
        #expect(ActivityTimelineBuilder.build(from: [aheadOnly], lastScanAt: Date()).state == .active)
        #expect(ActivityTimelineBuilder.build(from: [behindOnly], lastScanAt: Date()).state == .active)
        #expect(ActivityTimelineBuilder.build(from: [clean], lastScanAt: Date()).state == .allClean)
    }

    @Test func repositoryDecisionPriorityIsStableAcrossAllPrimaryStates() {
        let repositories = [
            snapshot(id: "idle", name: "idle", modified: 0, ahead: 0, behind: 0, hasUpstream: true, status: .clean),
            snapshot(id: "pull", name: "pull", modified: 0, ahead: 0, behind: 2, hasUpstream: true, status: .clean),
            snapshot(id: "local", name: "local", modified: 1, ahead: 0, behind: 0, hasUpstream: true),
            snapshot(id: "push", name: "push", modified: 0, ahead: 2, behind: 0, hasUpstream: true, status: .clean),
            snapshot(id: "behind-local", name: "behind-local", modified: 1, ahead: 0, behind: 2, hasUpstream: true),
            snapshot(id: "diverged-order", name: "diverged-order", modified: 0, ahead: 1, behind: 1, hasUpstream: true, status: .clean),
            snapshot(id: "branch-order", name: "branch-order", modified: 1, branch: "detached"),
            snapshot(id: "conflict-order", name: "conflict-order", modified: 1, conflicted: 1),
            snapshot(
                id: "retained-order",
                name: "retained-order",
                status: .error,
                dataSource: .lastSuccessful,
                lastSuccessfulScanAt: "2026-07-15T10:00:00Z",
                errorMessage: "本轮读取失败"
            ),
            snapshot(id: "unknown-order", name: "unknown-order", status: .error, dataSource: .unknown, errorMessage: "读取失败")
        ]

        #expect(
            RepositorySorter.sort(repositories).map(\.id) == [
                "unknown-order",
                "retained-order",
                "conflict-order",
                "branch-order",
                "diverged-order",
                "behind-local",
                "push",
                "local",
                "pull",
                "idle"
            ]
        )
    }

    @Test func unavailableDecisionOrderingNeverUsesRetainedBusinessFacts() {
        let olderHighRisk = snapshot(
            id: "older-high-risk-retained",
            name: "older-high-risk-retained",
            modified: 9,
            ahead: 5,
            risk: .high,
            status: .error,
            lastScannedAt: "2026-07-15T09:00:00Z",
            dataSource: .lastSuccessful,
            lastSuccessfulScanAt: "2026-07-14T09:00:00Z",
            errorMessage: "读取失败"
        )
        let newerLowRisk = snapshot(
            id: "newer-low-risk-retained",
            name: "newer-low-risk-retained",
            modified: 1,
            ahead: 0,
            risk: .low,
            status: .error,
            lastScannedAt: "2026-07-16T09:00:00Z",
            dataSource: .lastSuccessful,
            lastSuccessfulScanAt: "2026-07-14T09:00:00Z",
            errorMessage: "读取失败"
        )

        #expect(
            RepositorySorter.sort([olderHighRisk, newerLowRisk]).map(\.id) == [
                "newer-low-risk-retained",
                "older-high-risk-retained"
            ]
        )
    }

    @Test func listDetailTimelineWidgetAndCompatibilityProjectionsShareOneDecision() {
        let repositories = [
            snapshot(id: "shared-retained", status: .error, dataSource: .lastSuccessful, lastSuccessfulScanAt: "2026-07-15T10:00:00Z", errorMessage: "读取失败"),
            snapshot(id: "shared-unknown", status: .error, dataSource: .unknown, errorMessage: "读取失败"),
            snapshot(id: "shared-current-failure", status: .error, dataSource: .current, errorMessage: "读取失败"),
            snapshot(id: "shared-conflict", modified: 1, conflicted: 1),
            snapshot(id: "shared-detached", modified: 1, branch: "detached"),
            snapshot(id: "shared-diverged", modified: 0, ahead: 1, behind: 1, hasUpstream: true, status: .clean),
            snapshot(id: "shared-behind-local", modified: 1, ahead: 0, behind: 1, hasUpstream: true),
            snapshot(id: "shared-ahead-local", modified: 1, ahead: 1, behind: 0, hasUpstream: true),
            snapshot(id: "shared-mixed", modified: 2, staged: 1, unstaged: 1, ahead: 0, behind: 0, hasUpstream: true),
            snapshot(id: "shared-untracked", untracked: 1, ahead: 0, behind: 0, hasUpstream: true),
            snapshot(id: "shared-no-upstream", modified: 0, ahead: nil, behind: nil, hasUpstream: false, status: .clean),
            snapshot(id: "shared-clean", modified: 0, ahead: 0, behind: 0, hasUpstream: true, status: .clean)
        ]
        let timeline = ActivityTimelineBuilder.build(
            from: repositories,
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000)
        )
        let timelineContext = ActivityTimelineDecisionContextBuilder.build(from: repositories)
        let widgetItems = WidgetRepositoryPriorityBuilder.build(from: repositories)

        for repository in repositories {
            let decision = repository.decision
            let list = RepositoryListItemPresentationBuilder.build(snapshot: repository)
            let detail = RepositoryDetailPresentationBuilder.build(snapshot: repository)

            #expect(list.action == decision.primaryAction)
            #expect(detail.localSummary == decision.summary)
            #expect(detail.nextAction == decision.explanation)
            #expect(timeline.items.first(where: { $0.id == repository.id })?.decision == decision)
            #expect(timelineContext[repository.id] == decision)
            #expect(widgetItems.first(where: { $0.id == repository.id })?.decision == decision)
            #expect(repository.actionState == decision.primaryAction)
            #expect(repository.nextActionHint == decision.explanation)
            #expect(repository.statusSummary == decision.summary)
            #expect(repository.commitReadiness == decision.commitReadiness)
        }
    }

    @Test func repositoryDetailSelectionResolvesTheLatestTrustedSnapshotAfterRefreshOrRetry() {
        let selected = snapshot(
            id: "before-refresh",
            name: "Project",
            path: "/tmp/devpulse-detail-refresh/Project",
            modified: 1,
            lastScannedAt: "2026-07-15T10:00:00Z"
        )
        let refreshed = snapshot(
            id: selected.id,
            name: "Project",
            path: selected.path,
            modified: 4,
            lastScannedAt: "2026-07-15T10:05:00Z"
        )

        let resolved = RepositoryDetailSnapshotResolver.resolve(
            selection: RepositoryDetailSelection(repository: selected),
            repositories: [refreshed]
        )

        #expect(resolved?.modifiedFileCount == 4)
        #expect(resolved?.lastScannedAt == "2026-07-15T10:05:00Z")
    }

    @Test func repositoryDetailSelectionFollowsIdentityMigrationByCanonicalPath() {
        let legacy = snapshot(
            id: "legacy-id",
            name: "Project",
            path: "/tmp/devpulse-detail-migration/Project"
        )
        let migrated = snapshot(
            id: "repo-v1-migrated",
            name: "Project",
            path: legacy.path,
            modified: 2
        )
        let selection = RepositoryDetailSelection(repository: legacy)

        #expect(
            RepositoryDetailSnapshotResolver.resolve(
                selection: selection,
                repositories: [migrated]
            )?.id == migrated.id
        )
        #expect(
            RepositoryDetailSnapshotResolver.currentSelection(
                for: selection,
                repositories: [migrated]
            ) == RepositoryDetailSelection(repository: migrated)
        )
    }

    @Test func repositoryDetailSelectionSafelyClearsWhenRepositoryDisappears() {
        let selected = snapshot(
            id: "removed",
            name: "Project",
            path: "/tmp/devpulse-detail-removed/Project"
        )

        #expect(
            RepositoryDetailSnapshotResolver.currentSelection(
                for: RepositoryDetailSelection(repository: selected),
                repositories: []
            ) == nil
        )
    }

    @Test func cleanRepositoryIsClean() {
        let result = CommitReadinessEngine.assess(snapshot: snapshot(status: .clean))

        #expect(result.level == .idle)
        #expect(result.reasons == [.idleRepository])
        #expect(result.shortLabel == "Idle")
        #expect(result.detail == "没有本地改动")
        #expect(result.reviewReceipt.nextStep == "暂无改动，暂时不用管")
        #expect(result.widgetShortHint == "暂无改动")
        #expect(snapshot(status: .clean).nextActionHint == "当前无需操作。")
    }

    @Test func smallDirtyChangeNeedsReview() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 2,
                risk: .low
            )
        )

        #expect(result.level == .review)
        #expect(result.reasons == [.lightweightChanges, .reviewBeforeCommit])
        #expect(result.shortLabel == "Review")
        #expect(result.detail == "有少量改动，建议先看 diff 或跑验证")
        #expect(result.reviewReceipt.nextStep == "建议先审查改动，再决定是否提交")
    }

    @Test func stagedChangesBecomeReady() {
        let repo = snapshot(
            modified: 2,
            added: 1,
            deleted: 1,
            staged: 4,
            unstaged: 0,
            risk: .low
        )
        let result = CommitReadinessEngine.assess(snapshot: repo)

        #expect(result.level == .ready)
        #expect(result.reasons == [.stagedChanges])
        #expect(result.shortLabel == "Ready")
        #expect(result.detail == "有 4 个已暂存改动，看起来可以提交")
        #expect(result.reviewReceipt.nextStep == "如已自查改动范围，看起来可以提交")
        #expect(result.widgetShortHint == "看起来可以提交")
        #expect(repo.nextActionHint == "确认 4 个已暂存改动后即可提交。")
    }

    @Test func mixedStagedAndUnstagedChangesNeedReview() {
        let repo = snapshot(
            modified: 2,
            untracked: 1,
            staged: 1,
            risk: .low
        )
        let result = CommitReadinessEngine.assess(snapshot: repo)

        #expect(result.level == .review)
        #expect(result.reasons == [.mixedStagedAndUnstagedChanges, .reviewBeforeCommit])
        #expect(result.shortLabel == "Review")
        #expect(result.detail == "已有暂存改动，但工作区还有未整理内容，提交前先确认范围")
        #expect(result.reviewReceipt.nextStep == "建议先审查暂存范围，再决定是否提交")
        #expect(repo.nextActionHint == "先拆清已暂存和未暂存改动，再决定是否提交。")
    }

    @Test func moderateChangesBecomeDirty() {
        let repo = snapshot(
            modified: 4,
            untracked: 1,
            risk: .low
        )
        let result = CommitReadinessEngine.assess(snapshot: repo)

        #expect(result.level == .dirty)
        #expect(result.reasons.contains(.largeWorkingTree))
        #expect(result.detail == "未整理改动较多，建议先收敛再提交")
        #expect(result.reviewReceipt.nextStep == "需要先整理改动，再继续审查或提交")
        #expect(result.widgetShortHint == "需要整理改动")
        #expect(repo.nextActionHint == "先收敛 5 处改动，再继续审查或提交。")
    }

    @Test func highRiskChangesMentionValidationInNextActionHint() {
        let repo = snapshot(
            modified: 1,
            risk: .high
        )

        let result = CommitReadinessEngine.assess(snapshot: repo)

        #expect(result.level == .dirty)
        #expect(result.reasons.contains(.highRiskChanges))
        #expect(repo.nextActionHint == "先收敛 1 处高风险改动，并跑一次验证。")
    }

    @Test func untrackedFilesNeedReview() {
        let repo = snapshot(
            modified: 1,
            untracked: 1,
            risk: .low
        )
        let result = CommitReadinessEngine.assess(snapshot: repo)

        #expect(result.level == .review)
        #expect(result.reasons == [.untrackedFiles, .reviewBeforeCommit])
        #expect(result.shortLabel == "Review")
        #expect(result.detail == "有未跟踪文件，建议先看 diff 或确认是否纳入提交")
        #expect(result.reviewReceipt.nextStep == "建议先审查新文件，再决定是否提交")
        #expect(repo.nextActionHint == "先确认 1 个新文件是否纳入提交。")
    }

    @Test func mediumRiskChangesNeedValidationHint() {
        let repo = snapshot(
            modified: 2,
            risk: .medium
        )

        let result = CommitReadinessEngine.assess(snapshot: repo)

        #expect(result.level == .review)
        #expect(result.reasons.contains(.highRiskChanges))
        #expect(repo.nextActionHint == "先看 diff 并跑一次验证，再决定是否提交。")
    }

    @Test func aheadOfRemoteIsReadyToPush() {
        let repo = snapshot(
            ahead: 2,
            status: .clean
        )
        let result = CommitReadinessEngine.assess(snapshot: repo)

        #expect(result.level == .ready)
        #expect(result.reasons == [.localAhead])
        #expect(result.shortLabel == "Ready")
        #expect(result.detail == "有 2 个本地提交可 Push")
        #expect(result.reviewReceipt.nextStep == "如已准备好分享改动，再决定是否继续 push")
        #expect(repo.nextActionHint == "确认准备好后 push 2 个本地提交。")
    }

    @Test func scanErrorIsUnknown() {
        let repo = snapshot(
            status: .error,
            errorMessage: "Failed to run git status"
        )
        let result = CommitReadinessEngine.assess(snapshot: repo)

        #expect(result.level == .unknown)
        #expect(result.reasons == [.scanError])
        #expect(result.shortLabel == "Unknown")
        #expect(result.detail == "当前仓库数据未知")
        #expect(result.reviewReceipt.nextStep == "先打开 Diagnostics 并重新扫描，再决定是否操作仓库")
        #expect(result.widgetShortHint == "数据未知，先看 Diagnostics")
        #expect(repo.nextActionHint == "先看 Diagnostics 并重新扫描；当前没有可用于提交、push 或同步的可信数据。")
    }

    @Test func conflictedFilesAreDirty() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 1,
                conflicted: 1
            )
        )

        #expect(result.level == .dirty)
        #expect(result.reasons == [.conflictedFiles])
        #expect(result.detail == "存在 Git 冲突，先整理后再提交")
        #expect(result.reviewReceipt.nextStep == "先整理冲突，再继续审查或提交")
    }

    @Test func activityTimelinePrioritizesErrorsOverCleanRepos() {
        let feed = ActivityTimelineBuilder.build(
            from: [
                snapshot(
                    status: .clean,
                    branch: "main"
                ),
                snapshot(
                    modified: 0,
                    status: .error,
                    branch: "feature/error",
                    errorMessage: "Failed to run git status"
                )
            ],
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000)
        )

        #expect(feed.state == .active)
        #expect(feed.topItem?.status == .error)
        #expect(feed.items.first?.branch == "feature/error")
    }

    @Test func activityTimelineUsesNoRepositoriesStateAfterFirstScan() {
        let feed = ActivityTimelineBuilder.build(
            from: [],
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000)
        )

        #expect(feed.state == .noRepositories)
        #expect(feed.items.isEmpty)
    }

    @Test func gitScannerKeepsCleanRepositoryIdle() async throws {
        let root = try temporaryDirectory(named: "scanner-clean")
        defer { try? FileManager.default.removeItem(at: root) }

        let cleanRepo = root.appendingPathComponent("clean-repo")
        try createCommittedRepository(at: cleanRepo)

        let result = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path]
        )

        let repo = try #require(result.data.repositories.first(where: { $0.name == "clean-repo" }))
        #expect(repo.status == .clean)
        #expect(repo.commitReadiness.level == .idle)
        #expect(repo.changedFileCount == 0)
        #expect(repo.lastChangedAt != nil)
        #expect(repo.lastCommitSummary == "Initial commit")
        #expect(repo.lastCommitMetadataAvailable == true)
        #expect(repo.lastActivityAt == repo.lastChangedAt)
        #expect(repo.hasUpstream == false)
        #expect(repo.aheadCount == nil)
        #expect(repo.behindCount == nil)
    }

    @Test func gitScannerRepositoryRetryReusesSingleRepositoryReadPath() async throws {
        let root = try temporaryDirectory(named: "scanner-single-retry")
        defer { try? FileManager.default.removeItem(at: root) }

        let repositoryURL = root.appendingPathComponent("retry-repo")
        try createCommittedRepository(at: repositoryURL)
        let baseline = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )
        let previous = try #require(baseline.data.repositories.first)
        try "retry change\n".write(
            to: repositoryURL.appendingPathComponent("retry.txt"),
            atomically: true,
            encoding: .utf8
        )

        let retried = try #require(await GitRepositoryScanner.retryRepository(
            config: testScanConfig,
            previousSnapshot: previous
        ))

        #expect(retried.id == previous.id)
        #expect(retried.resolvedDataSource == .current)
        #expect(retried.status == .changed)
        #expect(retried.untrackedFileCount == 1)
        #expect(retried.errorMessage == nil)
    }

    @Test func gitScannerKeepsActivityStableUntilRepositoryStateChanges() async throws {
        let root = try temporaryDirectory(named: "scanner-activity")
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = root.appendingPathComponent("repo")
        try createCommittedRepository(at: repository)
        let first = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path]
        )
        let firstRepo = try #require(first.data.repositories.first)

        let second = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data
        )
        let secondRepo = try #require(second.data.repositories.first)

        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "local work\n".write(
            to: repository.appendingPathComponent("local.txt"),
            atomically: true,
            encoding: .utf8
        )
        let changed = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: second.data
        )
        let changedRepo = try #require(changed.data.repositories.first)

        #expect(secondRepo.lastActivityAt == firstRepo.lastActivityAt)
        #expect(changedRepo.status == .changed)
        #expect(changedRepo.lastActivityAt != secondRepo.lastActivityAt)
        #expect(changedRepo.lastCommitSummary == "Initial commit")
    }

    @Test func gitScannerPublishesAheadAndBehindFromLocalTrackingReferences() async throws {
        let root = try temporaryDirectory(named: "scanner-sync-state")
        defer { try? FileManager.default.removeItem(at: root) }

        let remote = root.appendingPathComponent("remote.git")
        let local = root.appendingPathComponent("local")
        let peer = root.appendingPathComponent("peer")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try runGit(["init", "--bare"], in: remote)
        try createCommittedRepository(at: local)
        try runGit(["remote", "add", "origin", remote.path], in: local)
        try runGit(["push", "-u", "origin", "HEAD:main"], in: local)
        try runGit(["clone", "--branch", "main", remote.path, peer.path], in: root)
        try runGit(["config", "user.name", "DevPulse Tests"], in: peer)
        try runGit(["config", "user.email", "devpulse-tests@example.com"], in: peer)

        try "local commit\n".write(
            to: local.appendingPathComponent("local.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "local.txt"], in: local)
        try runGit(["commit", "-m", "Local only commit"], in: local)

        try "remote commit\n".write(
            to: peer.appendingPathComponent("remote.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "remote.txt"], in: peer)
        try runGit(["commit", "-m", "Remote tracking commit"], in: peer)
        try runGit(["push", "origin", "main"], in: peer)
        try runGit(["fetch", "origin"], in: local)

        let result = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )
        let repository = try #require(
            result.data.repositories.first(where: { $0.name == "local" })
        )

        #expect(repository.hasUpstream == true)
        #expect(repository.aheadCount == 1)
        #expect(repository.behindCount == 1)
        #expect(repository.actionState.kind == .synchronizeDivergedBranch)
    }

    @Test func gitScannerRefreshesPreviouslyCleanRepositoriesAboveActiveThreshold() async throws {
        let root = try temporaryDirectory(named: "scanner-full-refresh")
        defer { try? FileManager.default.removeItem(at: root) }

        let alreadyChanged = root.appendingPathComponent("already-changed")
        let newlyChanged = root.appendingPathComponent("newly-changed")
        try createCommittedRepository(at: alreadyChanged)
        try createCommittedRepository(at: newlyChanged)
        try "first change\n".write(
            to: alreadyChanged.appendingPathComponent("first.txt"),
            atomically: true,
            encoding: .utf8
        )

        let config = ScanConfig(
            enabledBuiltInPaths: [],
            customPaths: [],
            maxDepth: testScanConfig.maxDepth,
            changedPreviewLimit: testScanConfig.changedPreviewLimit,
            maxConcurrentGitOps: testScanConfig.maxConcurrentGitOps,
            gitCommandTimeout: testScanConfig.gitCommandTimeout,
            scanTimeout: testScanConfig.scanTimeout,
            slowReposkipSeconds: testScanConfig.slowReposkipSeconds,
            activeRepoThreshold: 1
        )
        let first = await GitRepositoryScanner.scan(
            config: config,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )
        try "second change\n".write(
            to: newlyChanged.appendingPathComponent("second.txt"),
            atomically: true,
            encoding: .utf8
        )
        // An untracked write does not update `.git/HEAD` or `.git/index`.
        // A full refresh must still execute `git status` and discover it.

        let refreshed = await GitRepositoryScanner.scan(
            config: config,
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data
        )
        let refreshedRepo = try #require(
            refreshed.data.repositories.first(where: { $0.name == "newly-changed" })
        )

        #expect(refreshedRepo.status == .changed)
        #expect(refreshedRepo.changedFileCount == 1)
    }

    @Test func gitWorktreeListParserHandlesNULTerminatedPathsAndBareRepositories() {
        let output = [
            "worktree /tmp/Main Project",
            "HEAD 0123456789abcdef",
            "branch refs/heads/main",
            "",
            "worktree /tmp/任务 worktree",
            "HEAD fedcba9876543210",
            "detached",
            "locked managed by tool",
            "",
            "worktree /tmp/project.git",
            "bare",
            ""
        ].joined(separator: "\0")

        #expect(GitWorktreeListParser.parse(output) == [
            GitWorktreeListRecord(path: "/tmp/Main Project", isBare: false),
            GitWorktreeListRecord(path: "/tmp/任务 worktree", isBare: false),
            GitWorktreeListRecord(path: "/tmp/project.git", isBare: true)
        ])
        #expect(GitWorktreeListParser.parse("HEAD without a worktree record\0").isEmpty)
    }

    @Test func gitScannerDiscoversClassifiesAndScopesHiddenLinkedWorktreeIndependently() async throws {
        let root = try temporaryDirectory(named: "scanner-linked-worktree")
        defer { try? FileManager.default.removeItem(at: root) }
        let externalRoot = try temporaryDirectory(named: "scanner-external-worktree")
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        let main = root.appendingPathComponent("Project")
        let linkedParent = main.appendingPathComponent(".codex/worktrees")
        let linked = linkedParent.appendingPathComponent("task one")
        let externalLinked = externalRoot.appendingPathComponent("outside task")
        try createCommittedRepository(at: main)
        try ".codex/\n".write(
            to: main.appendingPathComponent(".git/info/exclude"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: linkedParent, withIntermediateDirectories: true)
        try runGit(
            ["worktree", "add", "-b", "codex/task-\(UUID().uuidString)", linked.path],
            in: main
        )
        try runGit(
            ["worktree", "add", "-b", "codex/outside-\(UUID().uuidString)", externalLinked.path],
            in: main
        )
        try "linked only\n".write(
            to: linked.appendingPathComponent("linked-only.txt"),
            atomically: true,
            encoding: .utf8
        )

        let canonicalMain = RepositoryIdentity.canonicalPath(main.path)
        let canonicalLinked = RepositoryIdentity.canonicalPath(linked.path)
        let canonicalExternalLinked = RepositoryIdentity.canonicalPath(externalLinked.path)
        let legacyMain = snapshot(
            id: RepositoryIdentity.id(for: canonicalMain),
            name: "Project",
            path: canonicalMain,
            status: .clean
        )
        let legacySnapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-21T00:00:00Z",
            writtenAt: "2026-07-21T00:00:00Z",
            scanSummary: ScanSummary.build(from: [legacyMain]),
            repositories: [legacyMain]
        )
        let upgradedKnownScope = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: [canonicalMain],
            previousSnapshot: legacySnapshot
        )
        #expect(
            Set(upgradedKnownScope.data.repositories.map(\.path))
                == Set([canonicalMain, canonicalLinked])
        )
        #expect(
            upgradedKnownScope.data.repositories.first(where: { $0.path == canonicalMain })?.workspaceKind
                == .mainWorktree
        )
        #expect(
            upgradedKnownScope.data.repositories.first(where: { $0.path == canonicalLinked })?.workspaceKind
                == .linkedWorktree
        )

        let baseline = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            previousSnapshot: upgradedKnownScope.data
        )
        let mainSnapshot = try #require(
            baseline.data.repositories.first(where: { $0.path == canonicalMain })
        )
        let linkedSnapshot = try #require(
            baseline.data.repositories.first(where: { $0.path == canonicalLinked })
        )

        #expect(baseline.data.repositories.count == 2)
        #expect(Set(baseline.discoveredRepositoryPaths) == [canonicalMain, canonicalLinked])
        #expect(!baseline.discoveredRepositoryPaths.contains(canonicalExternalLinked))
        #expect(mainSnapshot.workspaceKind == .mainWorktree)
        #expect(linkedSnapshot.workspaceKind == .linkedWorktree)
        #expect(mainSnapshot.status == .clean)
        #expect(linkedSnapshot.status == .changed)
        #expect(mainSnapshot.id != linkedSnapshot.id)
        #expect(mainSnapshot.id == RepositoryIdentity.id(for: canonicalMain))
        #expect(linkedSnapshot.id == RepositoryIdentity.id(for: canonicalLinked))

        let externalOnly = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [externalRoot.path],
            forceRepositoryDiscovery: true
        )
        #expect(externalOnly.data.repositories.map(\.path) == [canonicalExternalLinked])
        #expect(externalOnly.data.repositories.first?.workspaceKind == .linkedWorktree)

        let pinnedMain = RepositoryIdentityMigration.migrate(
            snapshot: baseline.data,
            pinnedIDs: [mainSnapshot.id]
        )
        #expect(
            pinnedMain.snapshot.repositories.first(where: { $0.path == canonicalMain })?.isPinned == true
        )
        #expect(
            pinnedMain.snapshot.repositories.first(where: { $0.path == canonicalLinked })?.isPinned == false
        )

        let ignoredMain = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            ignoredRepositoryPaths: [canonicalMain],
            forceRepositoryDiscovery: true,
            previousSnapshot: baseline.data
        )
        #expect(ignoredMain.data.repositories.map(\.path) == [canonicalLinked])
        #expect(ignoredMain.data.repositories.first?.workspaceKind == .linkedWorktree)

        let ignoredLinked = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            ignoredRepositoryPaths: [canonicalLinked],
            forceRepositoryDiscovery: true,
            previousSnapshot: baseline.data
        )
        #expect(ignoredLinked.data.repositories.map(\.path) == [canonicalMain])
        #expect(ignoredLinked.data.repositories.first?.workspaceKind == .mainWorktree)
    }

    @Test func gitScannerKeepsReadableRepositoryWhenWorktreeMetadataTimesOut() async throws {
        let root = try temporaryDirectory(named: "scanner-worktree-timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("separate-git-dir-repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try "gitdir: /tmp/unreadable-git-dir\n".write(
            to: repository.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let metrics = ScanMetricsCollector()

        let result = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            metrics: metrics,
            gitCommandRunner: { arguments, _, _, _, _ in
                switch arguments.first {
                case "worktree":
                    return .timeout
                case "status":
                    return .success(output: "# branch.oid (initial)\n# branch.head main")
                default:
                    Issue.record("Unexpected Git command: \(arguments)")
                    return .nonZero(exitCode: 1)
                }
            }
        )

        #expect(result.data.repositories.count == 1)
        #expect(result.data.repositories.first?.resolvedDataSource == .current)
        #expect(result.data.repositories.first?.workspaceKind == nil)
        #expect(result.warnings.contains(GitRepositoryScanner.incompleteWorktreeDiscoveryWarning))
        #expect(GitRepositoryScanner.discoveryWasIncomplete(result.warnings))
        #expect(metrics.snapshot().gitStatusCommandCount == 1)
        #expect(metrics.snapshot().gitTimeoutCount == 1)
    }

    @Test func worktreeMetadataBudgetPreservesStatusReadsAcrossManyTimeouts() async throws {
        let root = try temporaryDirectory(named: "scanner-worktree-timeout-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryCount = 12
        for index in 0..<repositoryCount {
            let repository = root.appendingPathComponent("repo-\(index)")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try "gitdir: /tmp/unreadable-git-dir-\(index)\n".write(
                to: repository.appendingPathComponent(".git"),
                atomically: true,
                encoding: .utf8
            )
        }
        let config = ScanConfig(
            enabledBuiltInPaths: [],
            customPaths: [],
            maxDepth: 2,
            changedPreviewLimit: 5,
            maxConcurrentGitOps: 4,
            gitCommandTimeout: 0.1,
            scanTimeout: 1,
            slowReposkipSeconds: 60,
            activeRepoThreshold: 30
        )
        let metrics = ScanMetricsCollector()

        let result = await GitRepositoryScanner.scan(
            config: config,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            metrics: metrics,
            gitCommandRunner: { arguments, _, timeout, _, _ in
                switch arguments.first {
                case "worktree":
                    Thread.sleep(forTimeInterval: max(0, timeout))
                    return .timeout
                case "status":
                    return .success(output: "# branch.oid (initial)\n# branch.head main")
                default:
                    Issue.record("Unexpected Git command: \(arguments)")
                    return .nonZero(exitCode: 1)
                }
            }
        )
        let snapshot = metrics.snapshot()

        #expect(result.data.repositories.count == repositoryCount)
        #expect(result.data.repositories.allSatisfy { $0.resolvedDataSource == .current })
        #expect(snapshot.gitStatusCommandCount == repositoryCount)
        #expect(snapshot.gitTimeoutCount < repositoryCount)
        #expect(GitRepositoryScanner.discoveryWasIncomplete(result.warnings))
    }

    @Test func gitScannerDetectsFirstLinkedWorktreeDuringKnownPathRefresh() async throws {
        let root = try temporaryDirectory(named: "scanner-worktree-topology-change")
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("Project")
        let linkedParent = main.appendingPathComponent(".codex/worktrees")
        let linked = linkedParent.appendingPathComponent("new task")
        try createCommittedRepository(at: main)
        try ".codex/\n".write(
            to: main.appendingPathComponent(".git/info/exclude"),
            atomically: true,
            encoding: .utf8
        )

        let standalone = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )
        #expect(standalone.data.repositories.count == 1)
        #expect(standalone.data.repositories.first?.workspaceKind == .standalone)

        try FileManager.default.createDirectory(at: linkedParent, withIntermediateDirectories: true)
        try runGit(
            ["worktree", "add", "-b", "codex/new-\(UUID().uuidString)", linked.path],
            in: main
        )
        let refreshed = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: standalone.discoveredRepositoryPaths,
            previousSnapshot: standalone.data
        )
        let canonicalMain = RepositoryIdentity.canonicalPath(main.path)
        let canonicalLinked = RepositoryIdentity.canonicalPath(linked.path)

        #expect(Set(refreshed.data.repositories.map(\.path)) == Set([canonicalMain, canonicalLinked]))
        #expect(
            refreshed.data.repositories.first(where: { $0.path == canonicalMain })?.workspaceKind
                == .mainWorktree
        )
        #expect(
            refreshed.data.repositories.first(where: { $0.path == canonicalLinked })?.workspaceKind
                == .linkedWorktree
        )
    }

    @Test func gitScannerDeduplicatesSymlinkRootsAndKeepsIdentityAcrossRescan() async throws {
        let root = try temporaryDirectory(named: "scanner-identity-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo")
        let alias = root.appendingPathComponent("repo-alias")
        try createCommittedRepository(at: repository)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)

        let first = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [repository.path, alias.path],
            forceRepositoryDiscovery: true
        )
        let second = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [alias.path],
            forceRepositoryDiscovery: true,
            previousSnapshot: first.data
        )
        let timeoutConfig = ScanConfig(
            enabledBuiltInPaths: [],
            customPaths: [],
            maxDepth: testScanConfig.maxDepth,
            changedPreviewLimit: testScanConfig.changedPreviewLimit,
            maxConcurrentGitOps: testScanConfig.maxConcurrentGitOps,
            gitCommandTimeout: testScanConfig.gitCommandTimeout,
            scanTimeout: 0,
            slowReposkipSeconds: testScanConfig.slowReposkipSeconds,
            activeRepoThreshold: testScanConfig.activeRepoThreshold
        )
        let timedOut = await GitRepositoryScanner.scan(
            config: timeoutConfig,
            scanRoots: [alias.path],
            knownRepositoryPaths: [alias.path],
            forceRepositoryDiscovery: true,
            previousSnapshot: first.data
        )
        let firstRepo = try #require(first.data.repositories.first)
        let secondRepo = try #require(second.data.repositories.first)
        let timedOutRepo = try #require(timedOut.data.repositories.first)

        #expect(first.data.repositories.count == 1)
        #expect(second.data.repositories.count == 1)
        #expect(firstRepo.workspaceKind == .standalone)
        #expect(secondRepo.workspaceKind == .standalone)
        #expect(firstRepo.path == RepositoryIdentity.canonicalPath(repository.path))
        #expect(secondRepo.path == firstRepo.path)
        #expect(secondRepo.id == firstRepo.id)
        #expect(secondRepo.id == RepositoryIdentity.id(for: repository.path))
        #expect(ScanLocationProvider.canonicalExistingFilePath(alias.path, resolveBuiltIn: true) == firstRepo.path)
        #expect(timedOutRepo.path == firstRepo.path)
        #expect(timedOutRepo.id == firstRepo.id)
    }

    @Test func gitScannerMarksMixedStagedRepositoryForReview() async throws {
        let root = try temporaryDirectory(named: "scanner-mixed")
        defer { try? FileManager.default.removeItem(at: root) }

        let mixedRepo = root.appendingPathComponent("mixed-repo")
        try createCommittedRepository(at: mixedRepo)

        let stagedFile = mixedRepo.appendingPathComponent("staged.txt")
        try "staged change\n".write(to: stagedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "staged.txt"], in: mixedRepo)

        let unstagedFile = mixedRepo.appendingPathComponent("unstaged.txt")
        try "new file\n".write(to: unstagedFile, atomically: true, encoding: .utf8)

        let result = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path]
        )

        let repo = try #require(result.data.repositories.first(where: { $0.name == "mixed-repo" }))
        #expect(repo.status == .changed)
        #expect(repo.stagedFileCount == 1)
        #expect(repo.untrackedFileCount == 1)
        #expect(repo.commitReadiness.level == .review)
        #expect(repo.commitReadiness.reasons == [.mixedStagedAndUnstagedChanges, .reviewBeforeCommit])
        #expect(repo.commitReadiness.reviewReceipt.nextStep == "建议先审查暂存范围，再决定是否提交")
    }

    @Test func gitScannerMarksStagedRepositoryReady() async throws {
        let root = try temporaryDirectory(named: "scanner-staged")
        defer { try? FileManager.default.removeItem(at: root) }

        let stagedRepo = root.appendingPathComponent("staged-repo")
        try createCommittedRepository(at: stagedRepo)

        let stagedFile = stagedRepo.appendingPathComponent("staged.txt")
        try "staged change\n".write(to: stagedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "staged.txt"], in: stagedRepo)

        let result = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path]
        )

        let repo = try #require(result.data.repositories.first(where: { $0.name == "staged-repo" }))
        #expect(repo.status == .changed)
        #expect(repo.stagedFileCount == 1)
        #expect(repo.unstagedFileCount == 0)
        #expect(repo.commitReadiness.level == .ready)
        #expect(repo.commitReadiness.reviewReceipt.nextStep == "如已自查改动范围，看起来可以提交")
    }

    @Test func gitScannerMarksUntrackedRepositoryForReview() async throws {
        let root = try temporaryDirectory(named: "scanner-untracked")
        defer { try? FileManager.default.removeItem(at: root) }

        let untrackedRepo = root.appendingPathComponent("untracked-repo")
        try createCommittedRepository(at: untrackedRepo)

        let newFile = untrackedRepo.appendingPathComponent("new-file.txt")
        try "new file\n".write(to: newFile, atomically: true, encoding: .utf8)

        let result = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path]
        )

        let repo = try #require(result.data.repositories.first(where: { $0.name == "untracked-repo" }))
        #expect(repo.status == .changed)
        #expect(repo.untrackedFileCount == 1)
        #expect(repo.commitReadiness.level == .review)
        #expect(repo.commitReadiness.reviewReceipt.nextStep == "建议先审查新文件，再决定是否提交")
    }

    @Test func gitScannerMarksBrokenRepositoryUnknown() async throws {
        let root = try temporaryDirectory(named: "scanner-broken")
        defer { try? FileManager.default.removeItem(at: root) }

        let brokenRepo = root.appendingPathComponent("broken-repo")
        try FileManager.default.createDirectory(at: brokenRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: brokenRepo.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        let result = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path]
        )

        let repo = try #require(result.data.repositories.first(where: { $0.name == "broken-repo" }))
        #expect(repo.status == .error)
        #expect(repo.errorMessage == "Git 命令异常退出")
        #expect(repo.resolvedDataSource == .unknown)
        #expect(repo.commitReadiness.level == .unknown)
        #expect(repo.actionState.kind == .diagnoseReadFailure)
        #expect(repo.commitReadiness.reviewReceipt.nextStep == "先打开 Diagnostics 并重新扫描，再决定是否操作仓库")
    }

    @Test func gitScannerReusesDiscoveryCacheUntilForcedRescan() async throws {
        let root = try temporaryDirectory(named: "scanner-discovery-cache")
        defer { try? FileManager.default.removeItem(at: root) }

        let firstRepo = root.appendingPathComponent("first-repo")
        try createCommittedRepository(at: firstRepo)

        let firstScan = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path]
        )
        #expect(firstScan.data.scanSummary.totalRepositories == 1)
        #expect(normalizeRepositoryPaths(firstScan.discoveredRepositoryPaths) == normalizeRepositoryPaths([firstRepo.path]))

        let secondRepo = root.appendingPathComponent("second-repo")
        try createCommittedRepository(at: secondRepo)

        let cachedScan = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path]
        )
        #expect(cachedScan.data.scanSummary.totalRepositories == 1)

        let forcedScan = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )
        #expect(forcedScan.data.scanSummary.totalRepositories == 2)
    }

    @Test func gitScannerReusesKnownRepositoryPathsBetweenAutomaticScans() async throws {
        let root = try temporaryDirectory(named: "scanner-known-paths")
        defer { try? FileManager.default.removeItem(at: root) }

        let firstRepo = root.appendingPathComponent("first-repo")
        try createCommittedRepository(at: firstRepo)

        let firstScan = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path]
        )
        #expect(firstScan.data.scanSummary.totalRepositories == 1)

        let secondRepo = root.appendingPathComponent("second-repo")
        try createCommittedRepository(at: secondRepo)

        let reusedKnownPathsScan = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: firstScan.data.repositories.map(\.path)
        )
        #expect(reusedKnownPathsScan.data.scanSummary.totalRepositories == 1)
        #expect(normalizeRepositoryPaths(reusedKnownPathsScan.discoveredRepositoryPaths) == normalizeRepositoryPaths([firstRepo.path]))

        let rediscoveredScan = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: firstScan.data.repositories.map(\.path),
            forceRepositoryDiscovery: true
        )
        #expect(rediscoveredScan.data.scanSummary.totalRepositories == 2)
        #expect(
            normalizeRepositoryPaths(rediscoveredScan.discoveredRepositoryPaths)
                == normalizeRepositoryPaths([firstRepo.path, secondRepo.path])
        )
    }

    @Test func gitScannerExcludesCanonicalIgnoredPathAndRestoresOnForcedDiscovery() async throws {
        let root = try temporaryDirectory(named: "scanner-ignore-restore")
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = root.appendingPathComponent("repository")
        let alias = root.appendingPathComponent("repository-alias")
        try createCommittedRepository(at: repository)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)

        let baseline = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )
        #expect(baseline.data.repositories.count == 1)

        let ignored = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: baseline.discoveredRepositoryPaths,
            ignoredRepositoryPaths: [alias.path],
            previousSnapshot: baseline.data
        )
        #expect(ignored.data.repositories.isEmpty)
        #expect(ignored.discoveredRepositoryPaths.isEmpty)
        #expect(ignored.data.scanSummary.totalRepositories == 0)

        let ignoredRediscovery = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            ignoredRepositoryPaths: [alias.path],
            forceRepositoryDiscovery: true,
            previousSnapshot: baseline.data
        )
        #expect(ignoredRediscovery.data.repositories.isEmpty)
        #expect(ignoredRediscovery.discoveredRepositoryPaths.isEmpty)

        let restored = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            ignoredRepositoryPaths: [],
            forceRepositoryDiscovery: true,
            previousSnapshot: ignored.data
        )
        #expect(restored.data.repositories.map(\.path) == [RepositoryIdentity.canonicalPath(repository.path)])
    }

    @Test func gitScannerInvalidatesKnownPathsAndCacheAfterRepositoryMoves() async throws {
        let root = try temporaryDirectory(named: "scanner-move")
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("original")
        let moved = root.appendingPathComponent("moved")
        try createCommittedRepository(at: original)
        let first = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )

        try FileManager.default.moveItem(at: original, to: moved)
        let rediscovered = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data
        )

        #expect(rediscovered.data.repositories.map(\.path) == [RepositoryIdentity.canonicalPath(moved.path)])
        #expect(!rediscovered.data.repositories.contains { $0.path == RepositoryIdentity.canonicalPath(original.path) })
    }

    @Test func gitScannerDropsDeletedRepositoryAndRemovedGitDirectoryWithoutWaitingForCacheTTL() async throws {
        let root = try temporaryDirectory(named: "scanner-delete")
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = root.appendingPathComponent("repository")
        try createCommittedRepository(at: repository)
        let first = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )

        try FileManager.default.removeItem(at: repository.appendingPathComponent(".git"))
        let noLongerRepository = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data
        )
        #expect(noLongerRepository.data.repositories.isEmpty)
        #expect(noLongerRepository.discoveredRepositoryPaths.isEmpty)

        try FileManager.default.removeItem(at: repository)
        let deleted = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data
        )
        #expect(deleted.data.repositories.isEmpty)
        #expect(deleted.discoveredRepositoryPaths.isEmpty)
    }

    @Test func emptyScanRootsAreAStrictScopeBarrierForKnownRepositories() async throws {
        let root = try temporaryDirectory(named: "scanner-empty-roots")
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = root.appendingPathComponent("repository")
        try createCommittedRepository(at: repository)
        let first = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )

        let empty = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data
        )
        #expect(empty.data.repositories.isEmpty)
        #expect(empty.discoveredRepositoryPaths.isEmpty)
        #expect(empty.data.scanSummary.totalRepositories == 0)
    }

    @Test func unreadableRootMarksRepositoryDiscoveryIncompleteInsteadOfSuccessfulEmpty() async throws {
        let root = try temporaryDirectory(named: "scanner-unreadable-root")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)

        let result = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )

        #expect(result.data.repositories.isEmpty)
        #expect(GitRepositoryScanner.discoveryWasIncomplete(result.warnings))
    }

    @Test func retentionKeepsPreviouslyKnownRepoIndefinitely() throws {
        // Repos that had at least one successful scan are retained until
        // the user explicitly cleans them up via scan-ignore.
        let unavailableAt = try #require(DateFormatting.date(from: "2026-07-01T00:00:00Z"))
        let retained = snapshot().retainingLastSuccessfulData(
            attemptedAt: "2026-07-01T00:00:00Z",
            errorMessage: "权限暂时不可用"
        )

        // Should retain within the old grace window
        #expect(RepositoryRetentionPolicy.shouldRetain(
            retained,
            now: unavailableAt.addingTimeInterval(60 * 60)
        ))
        // Should still retain long after the old 7-day window
        #expect(RepositoryRetentionPolicy.shouldRetain(
            retained,
            now: unavailableAt.addingTimeInterval(60 * 24 * 60 * 60)
        ))
    }

    @Test func retentionDropsUnknownRepoAfterGraceWindow() throws {
        // Repos that never had a successful scan follow the time-based
        // retention window.
        let unavailableAt = try #require(DateFormatting.date(from: "2026-07-01T00:00:00Z"))
        let unknown = RepositorySnapshot(
            id: "repo-unknown", name: "unknown", path: "/tmp/unknown",
            workspaceKind: nil, branch: "unknown", status: .error,
            modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0,
            untrackedFileCount: 0, stagedFileCount: nil, unstagedFileCount: nil,
            conflictedFileCount: nil, aheadCount: nil, behindCount: nil,
            hasUpstream: nil, changedFileCount: 0, changedFilesPreview: [],
            risk: .low,
            lastScannedAt: DateFormatting.isoString(from: unavailableAt),
            dataSource: .unknown, lastSuccessfulScanAt: nil,
            lastChangedAt: nil, lastCommitID: nil, lastCommitSummary: nil,
            lastCommitMetadataAvailable: false, lastActivityAt: nil,
            unavailableSince: DateFormatting.isoString(from: unavailableAt),
            errorMessage: "无法访问", isPinned: false
        )

        #expect(RepositoryRetentionPolicy.shouldRetain(
            unknown,
            now: unavailableAt.addingTimeInterval(60 * 60)
        ))
        #expect(!RepositoryRetentionPolicy.shouldRetain(
            unknown,
            now: unavailableAt.addingTimeInterval(8 * 24 * 60 * 60)
        ))
    }

    @Test func gitScannerFindsChangesAcrossManyRepositoriesWithinOneRefresh() async throws {
        let root = try temporaryDirectory(named: "scanner-many-repos")
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<50 {
            try createCommittedRepository(at: root.appendingPathComponent("repo-\(index)"))
        }

        let config = ScanConfig(
            enabledBuiltInPaths: [],
            customPaths: [],
            maxDepth: testScanConfig.maxDepth,
            changedPreviewLimit: testScanConfig.changedPreviewLimit,
            maxConcurrentGitOps: 6,
            gitCommandTimeout: testScanConfig.gitCommandTimeout,
            scanTimeout: 60,
            slowReposkipSeconds: testScanConfig.slowReposkipSeconds,
            activeRepoThreshold: 100
        )

        let first = await GitRepositoryScanner.scan(
            config: config,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )
        #expect(first.data.repositories.count == 50)

        let changedRepo = root.appendingPathComponent("repo-25")
        try "new change\n".write(
            to: changedRepo.appendingPathComponent("changed.txt"),
            atomically: true,
            encoding: .utf8
        )

        let refreshed = await GitRepositoryScanner.scan(
            config: config,
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths
        )
        let changed = try #require(refreshed.data.repositories.first(where: { $0.name == "repo-25" }))
        #expect(changed.status == .changed)
        #expect(changed.untrackedFileCount == 1)
        #expect(refreshed.data.repositories.count == 50)
    }

    @Test func gitScannerTimeoutRetainsPriorRepositorySnapshot() async throws {
        let root = try temporaryDirectory(named: "scanner-timeout-retain")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try createCommittedRepository(at: repo)

        let conf = ScanConfig(
            enabledBuiltInPaths: [],
            customPaths: [],
            maxDepth: testScanConfig.maxDepth,
            changedPreviewLimit: testScanConfig.changedPreviewLimit,
            maxConcurrentGitOps: testScanConfig.maxConcurrentGitOps,
            gitCommandTimeout: testScanConfig.gitCommandTimeout,
            scanTimeout: testScanConfig.scanTimeout,
            slowReposkipSeconds: testScanConfig.slowReposkipSeconds,
            activeRepoThreshold: 100
        )
        let baseline = await GitRepositoryScanner.scan(
            config: conf,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )
        let baselineRepo = try #require(baseline.data.repositories.first)

        // Use a git command runner that always returns .timeout to simulate
        // unresponsive git commands regardless of the configured timeout.
        let timeoutRunner: GitRepositoryScanner.GitCommandRunner = { _, _, _, _, _ in
            .timeout
        }

        let timedOut = await GitRepositoryScanner.scan(
            config: conf,
            scanRoots: [root.path],
            knownRepositoryPaths: baseline.discoveredRepositoryPaths,
            previousSnapshot: baseline.data,
            gitCommandRunner: timeoutRunner
        )

        let retained = try #require(timedOut.data.repositories.first)
        #expect(timedOut.data.repositories.count == 1)
        // Verify the timeout path was exercised through the snapshot reuse.
        #expect(retained.id == RepositoryIdentity.id(for: retained.path))
        #expect(baselineRepo.resolvedDataSource == .current)
        #expect(retained.resolvedDataSource == .lastSuccessful,
                "Timed-out repo should retain the last successful snapshot")
        #expect(retained.resolvedLastSuccessfulScanAt == baselineRepo.resolvedLastSuccessfulScanAt)
        // The retained snapshot from a failed read shows unknown readiness
        // and an actionable state prompting the user to refresh.
        #expect(retained.commitReadiness.level == .unknown)
        #expect(retained.actionState.kind == .refreshRepositoryState)
    }

    @Test func gitScannerFailureRetainsLastSuccessfulSnapshotUntilRecovery() async throws {
        let root = try temporaryDirectory(named: "scanner-read-failure-retain")
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = root.appendingPathComponent("repo")
        try createCommittedRepository(at: repository)
        try "staged change\n".write(
            to: repository.appendingPathComponent("staged.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "staged.txt"], in: repository)

        let baseline = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )
        let baselineRepository = try #require(baseline.data.repositories.first)
        let gitDirectory = repository.appendingPathComponent(".git")
        let originalPermissions = try #require(
            (try FileManager.default.attributesOfItem(atPath: gitDirectory.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: gitDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: gitDirectory.path
            )
        }

        let firstFailure = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: baseline.discoveredRepositoryPaths,
            previousSnapshot: baseline.data
        )
        let firstRetained = try #require(firstFailure.data.repositories.first)

        let secondFailure = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: baseline.discoveredRepositoryPaths,
            previousSnapshot: firstFailure.data
        )
        let secondRetained = try #require(secondFailure.data.repositories.first)

        #expect(baselineRepository.resolvedDataSource == .current)
        #expect(baselineRepository.actionState.kind == .commitStagedChanges)
        #expect(firstRetained.resolvedDataSource == .lastSuccessful)
        #expect(firstRetained.resolvedLastSuccessfulScanAt == baselineRepository.resolvedLastSuccessfulScanAt)
        #expect(firstRetained.commitReadiness.level == .unknown)
        #expect(firstRetained.actionState.kind == .refreshRepositoryState)
        #expect(secondRetained.resolvedDataSource == .lastSuccessful)
        #expect(secondRetained.resolvedLastSuccessfulScanAt == firstRetained.resolvedLastSuccessfulScanAt)
        #expect(secondRetained.commitReadiness.level == .unknown)
        #expect(secondRetained.actionState.kind == .refreshRepositoryState)

        try FileManager.default.setAttributes(
            [.posixPermissions: originalPermissions],
            ofItemAtPath: gitDirectory.path
        )
        let recovered = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: baseline.discoveredRepositoryPaths,
            previousSnapshot: secondFailure.data
        )
        let recoveredRepository = try #require(recovered.data.repositories.first)

        #expect(recoveredRepository.resolvedDataSource == .current)
        #expect(recoveredRepository.commitReadiness.level == .ready)
        #expect(recoveredRepository.actionState.kind == .commitStagedChanges)
    }

    @Test func agedOutUnreadableRepositoryStaysHiddenUntilItRecovers() async throws {
        let root = try temporaryDirectory(named: "scanner-aged-unavailable")
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = root.appendingPathComponent("repo")
        try createCommittedRepository(at: repository)
        let baseline = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )
        let baselineRepository = try #require(baseline.data.repositories.first)
        let canonicalPath = RepositoryIdentity.canonicalPath(repository.path)
        let unavailableSince = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-(8 * 24 * 60 * 60))
        )
        let agedFailure = baselineRepository.retainingLastSuccessfulData(
            attemptedAt: unavailableSince,
            errorMessage: "权限暂时不可用",
            unavailableSince: unavailableSince
        )
        let agedPrevious = AppGroupData(
            schemaVersion: baseline.data.schemaVersion,
            generatedAt: baseline.data.generatedAt,
            writtenAt: baseline.data.writtenAt,
            scanSummary: ScanSummary.build(from: [agedFailure]),
            repositories: [agedFailure],
            repositoryUnavailableSinceByPath: [canonicalPath: unavailableSince]
        )

        let gitDirectory = repository.appendingPathComponent(".git")
        let originalPermissions = try #require(
            (try FileManager.default.attributesOfItem(atPath: gitDirectory.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: gitDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: gitDirectory.path
            )
        }

        let firstHidden = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: baseline.discoveredRepositoryPaths,
            previousSnapshot: agedPrevious
        )
        // Previously-known repos (with a prior successful scan) are retained
        // indefinitely so the evaluator can surface a staleRepository item and
        // recovery auto-reassociates when the path becomes accessible again.
        #expect(!firstHidden.data.repositories.isEmpty, "Previously-known repo should be retained")
        let retainedFirst = try #require(firstHidden.data.repositories.first(where: { $0.path == canonicalPath }))
        #expect(retainedFirst.resolvedDataSource == .lastSuccessful)
        #expect(firstHidden.data.repositoryUnavailableSinceByPath?[canonicalPath] == unavailableSince)
        #expect(firstHidden.discoveredRepositoryPaths == [canonicalPath])

        let secondHidden = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: firstHidden.discoveredRepositoryPaths,
            previousSnapshot: firstHidden.data
        )
        #expect(!secondHidden.data.repositories.isEmpty, "Previously-known repo should still be retained on second scan")
        let retainedSecond = try #require(secondHidden.data.repositories.first(where: { $0.path == canonicalPath }))
        #expect(retainedSecond.resolvedDataSource == .lastSuccessful)
        #expect(secondHidden.data.repositoryUnavailableSinceByPath?[canonicalPath] == unavailableSince)
        #expect(secondHidden.discoveredRepositoryPaths == [canonicalPath])

        try FileManager.default.setAttributes(
            [.posixPermissions: originalPermissions],
            ofItemAtPath: gitDirectory.path
        )
        let recovered = await GitRepositoryScanner.scan(
            config: testScanConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: secondHidden.discoveredRepositoryPaths,
            previousSnapshot: secondHidden.data
        )

        #expect(recovered.data.repositories.map(\.path) == [canonicalPath])
        #expect(recovered.data.repositories.first?.resolvedDataSource == .current)
        #expect(recovered.data.repositoryUnavailableSinceByPath == nil)
    }

    @Test func processRunnerStopsCancelledCommand() async throws {
        let task = Task.detached {
            ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 5"],
                workingDirectory: "/tmp",
                timeout: 30,
                isCancelled: { Task.isCancelled }
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        #expect(result == nil)
    }

    @Test func schedulerPolicySkipsRediscoveryInsideCooldown() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)

        #expect(
            ScanSchedulerPolicy.shouldRediscoverRepositories(
                forceRepositoryDiscovery: false,
                knownRepositoryPaths: ["/tmp/repo-a"],
                lastRepositoryDiscoveryAt: now.addingTimeInterval(-10 * 60),
                now: now
            ) == false
        )
    }

    @Test func schedulerPolicyRediscoveriesAfterCooldownExpires() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)

        #expect(
            ScanSchedulerPolicy.shouldRediscoverRepositories(
                forceRepositoryDiscovery: false,
                knownRepositoryPaths: ["/tmp/repo-a"],
                lastRepositoryDiscoveryAt: now.addingTimeInterval(-61 * 60),
                now: now
            ) == true
        )
    }

    @Test func schedulerPolicyRediscoveriesWhenScanRootsChangeInsideCooldown() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)

        #expect(
            ScanSchedulerPolicy.shouldRediscoverRepositories(
                forceRepositoryDiscovery: false,
                knownRepositoryPaths: ["/tmp/repo-a"],
                lastRepositoryDiscoveryAt: now.addingTimeInterval(-10 * 60),
                currentScanRootsSignature: ScanSchedulerPolicy.scanRootsSignature(["/tmp/root-a", "/tmp/root-b"]),
                lastScanRootsSignature: ScanSchedulerPolicy.scanRootsSignature(["/tmp/root-a"]),
                now: now
            ) == true
        )
    }

    @Test func schedulerPolicyThrottlesWidgetReloadForUnchangedAutomaticScan() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-03T00:00:00Z",
            writtenAt: "2026-07-03T00:00:00Z",
            scanSummary: ScanSummary(
                totalRepositories: 1,
                changedRepositories: 1,
                totalChangedFiles: 2,
                errorRepositories: 0
            ),
            repositories: [
                RepositorySnapshot(
                    id: "repo-1",
                    name: "repo-1",
                    path: "/tmp/repo-1",
                    branch: "main",
                    status: .changed,
                    modifiedFileCount: 2,
                    addedFileCount: 0,
                    deletedFileCount: 0,
                    untrackedFileCount: 0,
                    stagedFileCount: 0,
                    unstagedFileCount: 2,
                    conflictedFileCount: 0,
                    aheadCount: 0,
                    changedFileCount: 2,
                    changedFilesPreview: ["README.md"],
                    risk: .low,
                    lastScannedAt: "2026-07-03T00:00:00Z",
                    lastChangedAt: nil,
                    errorMessage: nil,
                    isPinned: false
                )
            ]
        )

        #expect(
            ScanSchedulerPolicy.shouldRequestWidgetReload(
                previousSnapshot: snapshot,
                nextSnapshot: snapshot.withWrittenAt("2026-07-03T00:05:00Z"),
                reason: "scan"
            ) == false
        )
    }

    @Test func schedulerPolicyIgnoresVolatileScanTimestampsForWidgetReloadThrottle() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let summary = ScanSummary(
            totalRepositories: 1,
            changedRepositories: 1,
            totalChangedFiles: 2,
            errorRepositories: 0
        )
        let previous = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-03T00:00:00Z",
            writtenAt: "2026-07-03T00:00:00Z",
            scanSummary: summary,
            repositories: [
                snapshot(
                    modified: 2,
                    unstaged: 2,
                    lastScannedAt: "2026-07-03T00:00:00Z"
                )
            ]
        )
        let next = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-03T00:05:00Z",
            writtenAt: "2026-07-03T00:05:00Z",
            scanSummary: summary,
            repositories: [
                snapshot(
                    modified: 2,
                    unstaged: 2,
                    lastScannedAt: "2026-07-03T00:05:00Z"
                )
            ]
        )

        #expect(
            ScanSchedulerPolicy.shouldRequestWidgetReload(
                previousSnapshot: previous,
                nextSnapshot: next,
                reason: "scan"
            ) == false
        )
    }

    @Test func schedulerPolicyReloadsWhenRepositoryContentChangesInsideThrottleWindow() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let summary = ScanSummary(
            totalRepositories: 1,
            changedRepositories: 1,
            totalChangedFiles: 1,
            errorRepositories: 0
        )
        let previous = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-03T00:00:00Z",
            writtenAt: "2026-07-03T00:00:00Z",
            scanSummary: summary,
            repositories: [
                snapshot(
                    modified: 1,
                    unstaged: 1,
                    branch: "main",
                    lastScannedAt: "2026-07-03T00:00:00Z"
                )
            ]
        )
        let next = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-03T00:05:00Z",
            writtenAt: "2026-07-03T00:05:00Z",
            scanSummary: summary,
            repositories: [
                snapshot(
                    modified: 1,
                    unstaged: 1,
                    branch: "feature",
                    lastScannedAt: "2026-07-03T00:05:00Z"
                )
            ]
        )

        #expect(
            ScanSchedulerPolicy.shouldRequestWidgetReload(
                previousSnapshot: previous,
                nextSnapshot: next,
                reason: "scan"
            ) == true
        )
    }

    @Test func schedulerPolicyKeepsImmediateWidgetReloadForRealChanges() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let previous = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-03T00:00:00Z",
            writtenAt: "2026-07-03T00:00:00Z",
            scanSummary: ScanSummary(
                totalRepositories: 1,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 0
            ),
            repositories: [
                RepositorySnapshot(
                    id: "repo-1",
                    name: "repo-1",
                    path: "/tmp/repo-1",
                    branch: "main",
                    status: .clean,
                    modifiedFileCount: 0,
                    addedFileCount: 0,
                    deletedFileCount: 0,
                    untrackedFileCount: 0,
                    stagedFileCount: 0,
                    unstagedFileCount: 0,
                    conflictedFileCount: 0,
                    aheadCount: 0,
                    changedFileCount: 0,
                    changedFilesPreview: [],
                    risk: .low,
                    lastScannedAt: "2026-07-03T00:00:00Z",
                    lastChangedAt: nil,
                    errorMessage: nil,
                    isPinned: false
                )
            ]
        )
        let next = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-03T00:05:00Z",
            writtenAt: "2026-07-03T00:05:00Z",
            scanSummary: ScanSummary(
                totalRepositories: 1,
                changedRepositories: 1,
                totalChangedFiles: 1,
                errorRepositories: 0
            ),
            repositories: [
                RepositorySnapshot(
                    id: "repo-1",
                    name: "repo-1",
                    path: "/tmp/repo-1",
                    branch: "main",
                    status: .changed,
                    modifiedFileCount: 1,
                    addedFileCount: 0,
                    deletedFileCount: 0,
                    untrackedFileCount: 0,
                    stagedFileCount: 0,
                    unstagedFileCount: 1,
                    conflictedFileCount: 0,
                    aheadCount: 0,
                    changedFileCount: 1,
                    changedFilesPreview: ["README.md"],
                    risk: .low,
                    lastScannedAt: "2026-07-03T00:05:00Z",
                    lastChangedAt: nil,
                    errorMessage: nil,
                    isPinned: false
                )
            ]
        )

        #expect(
            ScanSchedulerPolicy.shouldRequestWidgetReload(
                previousSnapshot: previous,
                nextSnapshot: next,
                reason: "scan"
            ) == true
        )
    }

    @Test func repositoryIdentityUsesStableVersionedVectorsAndSeparatesPaths() {
        #expect(RepositoryIdentity.version == 1)
        #expect(
            RepositoryIdentity.id(for: "/tmp/devpulse/repo-a")
                == "repo-v1-9daedea3d77b063f6e809b4aa098d6dbc4310c076f6e803c08a5dcc93cab70df"
        )
        #expect(
            RepositoryIdentity.id(for: "/tmp/devpulse/repo-b")
                == "repo-v1-859523e533d3e1b18365db670bd71098f137e2832bad6881cd761bb96b6081b8"
        )
        #expect(RepositoryIdentity.id(for: "/tmp/devpulse/repo-a") != RepositoryIdentity.id(for: "/tmp/devpulse/repo-b"))
    }

    @Test func repositoryIdentityResolvesExistingSymlinkAliases() throws {
        let root = try temporaryDirectory(named: "identity-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)

        #expect(RepositoryIdentity.canonicalPath(alias.path) == RepositoryIdentity.canonicalPath(repository.path))
        #expect(RepositoryIdentity.id(for: alias.path) == RepositoryIdentity.id(for: repository.path))
    }

    @Test func repositoryIdentityDeduplicationDoesNotInventAPinForUnpinnedAliases() throws {
        let root = try temporaryDirectory(named: "identity-unpinned-alias")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)
        let repositories = [
            snapshot(id: "legacy-a", name: "repository", path: repository.path),
            snapshot(id: "legacy-b", name: "alias", path: alias.path)
        ]
        let normalized = RepositoryIdentity.normalize(AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-21T00:00:00Z",
            writtenAt: "2026-07-21T00:00:00Z",
            scanSummary: ScanSummary.build(from: repositories),
            repositories: repositories
        ))

        #expect(normalized.repositories.count == 1)
        #expect(normalized.repositories.first?.isPinned == false)
    }

    @Test func repositoryIdentityLegacyContainerMigrationRequiresComponentBoundary() {
        let home = ScanLocationProvider.resolvedUserHomeDirectory()
        let suffix = "/DevPulseTests-boundary-\(UUID().uuidString)"
        let legacyDataPrefix = home + "/Library/Containers/local.devpulse.app/Data"
        let validLegacyPath = legacyDataPrefix + suffix
        let dataBackupPath = legacyDataPrefix + "Backup" + suffix
        let databasePath = legacyDataPrefix + "Database" + suffix

        #expect(RepositoryIdentity.canonicalPath(validLegacyPath) == home + suffix)
        #expect(RepositoryIdentity.canonicalPath(dataBackupPath) == dataBackupPath)
        #expect(RepositoryIdentity.canonicalPath(databasePath) == databasePath)
        #expect(ScanLocationProvider.normalizePersistedPath(validLegacyPath) == home + suffix)
        #expect(ScanLocationProvider.normalizePersistedPath(dataBackupPath) == dataBackupPath)
        #expect(ScanLocationProvider.normalizePersistedPath(databasePath) == databasePath)
    }

    @Test func repositoryIdentityMigrationPreservesSafePinsAndAmbiguity() throws {
        let root = try temporaryDirectory(named: "identity-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let safe = root.appendingPathComponent("safe")
        let safeAlias = root.appendingPathComponent("safe-alias")
        let ambiguousA = root.appendingPathComponent("ambiguous-a")
        let ambiguousB = root.appendingPathComponent("ambiguous-b")
        try [safe, ambiguousA, ambiguousB].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: safeAlias, withDestinationURL: safe)

        let now = DateFormatting.nowISO()
        let repositories = [
            snapshot(id: "legacy-safe", name: "safe", path: safe.path),
            snapshot(id: "legacy-safe", name: "safe-alias", path: safeAlias.path),
            snapshot(id: "legacy-ambiguous", name: "ambiguous-a", path: ambiguousA.path),
            snapshot(id: "legacy-ambiguous", name: "ambiguous-b", path: ambiguousB.path)
        ]
        let data = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: now,
            writtenAt: now,
            scanSummary: ScanSummary(totalRepositories: repositories.count, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: repositories
        )

        let unknown = "legacy-unknown"
        let migration = RepositoryIdentityMigration.migrate(
            snapshot: data,
            pinnedIDs: ["legacy-safe", "legacy-ambiguous", unknown]
        )
        let safeID = RepositoryIdentity.id(for: safe.path)

        #expect(migration.snapshot.repositories.count == 3)
        #expect(migration.pinnedIDs.contains(safeID))
        #expect(!migration.pinnedIDs.contains("legacy-safe"))
        #expect(migration.pinnedIDs.contains("legacy-ambiguous"))
        #expect(migration.pinnedIDs.contains(unknown))
        #expect(migration.snapshot.repositories.filter { $0.id == safeID }.count == 1)
        #expect(migration.snapshot.repositories.first(where: { $0.id == safeID })?.isPinned == true)
    }

    @Test func repositoryIdentityMigrationDoesNotExpandAmbiguousSnapshotPinsAcrossWorktrees() throws {
        let root = try temporaryDirectory(named: "identity-ambiguous-worktrees")
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main")
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)

        let legacyID = "legacy-colliding-worktree-id"
        let repositories = [
            snapshot(id: legacyID, name: "main", path: main.path, isPinned: true),
            snapshot(id: legacyID, name: "linked", path: linked.path, isPinned: true)
        ]
        let data = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-21T00:00:00Z",
            writtenAt: "2026-07-21T00:00:00Z",
            scanSummary: ScanSummary.build(from: repositories),
            repositories: repositories
        )

        let migration = RepositoryIdentityMigration.migrate(
            snapshot: data,
            pinnedIDs: [legacyID]
        )
        let mainID = RepositoryIdentity.id(for: main.path)
        let linkedID = RepositoryIdentity.id(for: linked.path)

        #expect(migration.pinnedIDs.contains(legacyID))
        #expect(!migration.pinnedIDs.contains(mainID))
        #expect(!migration.pinnedIDs.contains(linkedID))
        #expect(migration.snapshot.repositories.allSatisfy { !$0.isPinned })
    }

    @Test func repositoryWorkspaceKindSurvivesFailureRetentionAndSupportsTopologyUpgrade() {
        let linked = snapshot(
            name: "linked",
            workspaceKind: .linkedWorktree,
            dataSource: .current,
            lastSuccessfulScanAt: "2026-07-21T00:00:00Z"
        )
        let retained = linked.retainingLastSuccessfulData(
            attemptedAt: "2026-07-21T00:05:00Z",
            errorMessage: "读取失败"
        )
        let upgraded = snapshot(name: "legacy-main").retainingLastSuccessfulData(
            attemptedAt: "2026-07-21T00:05:00Z",
            errorMessage: "读取失败",
            workspaceKind: .mainWorktree
        )

        #expect(retained.workspaceKind == .linkedWorktree)
        #expect(upgraded.workspaceKind == .mainWorktree)
    }

    @Test func repositoryIdentityRoundTripsThroughWidgetSnapshotCodable() throws {
        let repository = snapshot(
            id: "legacy",
            name: "widget-repo",
            workspaceKind: .linkedWorktree
        )
        let data = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-12T00:00:00Z",
            writtenAt: "2026-07-12T00:00:00Z",
            lastSuccessfulRefreshAt: "2026-07-12T00:00:00Z",
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 1, totalChangedFiles: 1, errorRepositories: 0),
            repositories: [RepositoryIdentity.normalize(repository)]
        )
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(AppGroupData.self, from: encoded)

        #expect(decoded.repositories.count == 1)
        #expect(decoded.repositories[0].id == RepositoryIdentity.id(for: decoded.repositories[0].path))
        #expect(decoded.repositories[0].path == RepositoryIdentity.canonicalPath(repository.path))
        #expect(decoded.repositories[0].workspaceKind == .linkedWorktree)
        #expect(decoded.lastSuccessfulRefreshAt == "2026-07-12T00:00:00Z")
    }

    private func snapshot(
        id: String = "repo-1",
        name: String = "repo-1",
        path: String? = nil,
        workspaceKind: RepositoryWorkspaceKind? = nil,
        modified: Int = 0,
        added: Int = 0,
        deleted: Int = 0,
        untracked: Int = 0,
        staged: Int = 0,
        unstaged: Int? = nil,
        conflicted: Int = 0,
        ahead: Int? = 0,
        behind: Int? = nil,
        hasUpstream: Bool? = nil,
        risk: RiskLevel = .low,
        status: RepositoryStatus = .changed,
        branch: String = "main",
        lastScannedAt: String = "2026-06-19T00:00:00Z",
        lastChangedAt: String? = nil,
        lastCommitSummary: String? = nil,
        lastCommitMetadataAvailable: Bool? = nil,
        lastActivityAt: String? = nil,
        dataSource: RepositoryDataSource? = nil,
        lastSuccessfulScanAt: String? = nil,
        errorMessage: String? = nil,
        changedFilesPreview: [String] = [],
        isPinned: Bool = false
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            id: id,
            name: name,
            path: path ?? "/tmp/\(name)",
            workspaceKind: workspaceKind,
            branch: branch,
            status: status,
            modifiedFileCount: modified,
            addedFileCount: added,
            deletedFileCount: deleted,
            untrackedFileCount: untracked,
            stagedFileCount: staged,
            unstagedFileCount: unstaged ?? (modified + added + deleted),
            conflictedFileCount: conflicted,
            aheadCount: ahead,
            behindCount: behind,
            hasUpstream: hasUpstream,
            changedFileCount: modified + added + deleted + untracked,
            changedFilesPreview: changedFilesPreview,
            risk: risk,
            lastScannedAt: lastScannedAt,
            dataSource: dataSource,
            lastSuccessfulScanAt: lastSuccessfulScanAt,
            lastChangedAt: lastChangedAt,
            lastCommitSummary: lastCommitSummary,
            lastCommitMetadataAvailable: lastCommitMetadataAvailable,
            lastActivityAt: lastActivityAt,
            errorMessage: errorMessage,
            isPinned: isPinned
        )
    }

    private func freshTrust() -> SnapshotTrustAssessment {
        SnapshotTrustAssessment(
            state: .fresh,
            title: "刚刚更新",
            detail: "数据仍在可信时间窗内",
            basis: "test"
        )
    }

    private var testScanConfig: ScanConfig {
        ScanConfig(
            enabledBuiltInPaths: [],
            customPaths: [],
            maxDepth: 2,
            changedPreviewLimit: 5,
            maxConcurrentGitOps: 1,
            gitCommandTimeout: 5.0,
            scanTimeout: 15.0,
            slowReposkipSeconds: 60.0,
            activeRepoThreshold: 30
        )
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevPulseTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func normalizeRepositoryPaths(_ paths: [String]) -> [String] {
        paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    private func createCommittedRepository(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init"], in: url)
        try runGit(["config", "user.name", "DevPulse Tests"], in: url)
        try runGit(["config", "user.email", "devpulse-tests@example.com"], in: url)

        let readme = url.appendingPathComponent("README.md")
        try "initial\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], in: url)
        try runGit(["commit", "-m", "Initial commit"], in: url)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw TestGitError(arguments: arguments, output: output)
        }
    }
}

private struct TestGitError: Error, CustomStringConvertible {
    let arguments: [String]
    let output: String

    var description: String {
        "git \(arguments.joined(separator: " ")) failed: \(output)"
    }
}

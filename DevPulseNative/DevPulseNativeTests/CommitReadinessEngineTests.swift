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
        #expect(assessment.title == "刷新失败，建议打开 App 检查")
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

    @Test func snapshotTrustAssessmentPrefersWrittenAtForStaleness() {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let formatter = ISO8601DateFormatter()
        let assessment = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: formatter.string(from: now.addingTimeInterval(-20 * 60)),
            writtenAt: formatter.string(from: now.addingTimeInterval(-12 * 60)),
            now: now
        )

        #expect(assessment.state == .stale)
        #expect(assessment.title == "数据可能已过期")
        #expect(assessment.basis.contains("writtenAt"))
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
        #expect(summary.message == "状态读取失败，先看 Diagnostics")
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

    @Test func widgetRepositoryPriorityBuilderUsesRecentActivityBeforeRawRisk() {
        let repos = [
            snapshot(id: "older-high-risk", name: "older-high-risk", modified: 1, risk: .high, lastChangedAt: "2026-06-20T10:00:00Z"),
            snapshot(id: "newer-low-risk", name: "newer-low-risk", modified: 1, risk: .low, lastChangedAt: "2026-06-22T10:00:00Z")
        ]

        let items = WidgetRepositoryPriorityBuilder.build(from: repos)

        #expect(items.map(\.repoName) == ["newer-low-risk", "older-high-risk"])
    }

    @Test func widgetRepositoryPriorityBuilderUsesRecentActivityAsStableTieBreaker() {
        let repos = [
            snapshot(id: "older", name: "older", modified: 1, risk: .low, lastChangedAt: "2026-06-20T10:00:00Z"),
            snapshot(id: "newer", name: "newer", modified: 1, risk: .low, lastChangedAt: "2026-06-22T10:00:00Z")
        ]

        let items = WidgetRepositoryPriorityBuilder.build(from: repos)

        #expect(items.map(\.repoName) == ["newer", "older"])
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
            lastReloadRequestedAt: Date(timeIntervalSince1970: 1_718_000_000),
            reason: "pin toggle",
            now: Date(timeIntervalSince1970: 1_718_000_100)
        )

        #expect(decision.shouldRequest)
        #expect(decision.detail.contains("pin toggle"))
    }

    @Test func widgetReloadDecisionSkipsUnchangedScanWithinThrottleWindow() {
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
            lastReloadRequestedAt: now.addingTimeInterval(-60),
            reason: "scan",
            now: now
        )

        #expect(decision.shouldRequest == false)
        #expect(decision.detail.contains("本次跳过"))
    }

    @Test func widgetReloadDecisionRequestsUnchangedScanAfterThrottleExpires() {
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
            lastReloadRequestedAt: now.addingTimeInterval(-(ScanSchedulerPolicy.widgetReloadThrottleInterval + 1)),
            reason: "scan",
            now: now
        )

        #expect(decision.shouldRequest)
        #expect(decision.detail.contains("已重新请求"))
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

        #expect(metadata?.committedAt == "2026-07-13T09:30:00+08:00")
        #expect(metadata?.summary == "修复项目优先级")
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
        #expect(presentation.localChanges == "0 个文件")
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
        #expect(failedPresentation.latestCommit == "提交信息暂不可用")
        #expect(failedPresentation.localChanges == "本地改动未知")
        #expect(failedPresentation.synchronization == "同步状态未知")
        #expect(failedPresentation.recentActivity == "暂无活动记录")
        #expect(localOnlyPresentation.synchronization == "未关联上游")
        #expect(localOnlyPresentation.action.title == "无需处理")
        #expect(lastKnownPresentation.latestCommit == "上次记录 · 2 小时前 · Last known subject")
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

        #expect(focus.title == "repo-1 状态读取失败")
        #expect(focus.action.kind == .openDiagnostics)
        #expect(focus.detail == "先看 Diagnostics，确认 Git 读取失败原因。")
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
        #expect(result.detail == "Git 状态读取失败")
        #expect(result.reviewReceipt.nextStep == "先打开 Diagnostics，确认 Git 读取失败原因")
        #expect(result.widgetShortHint == "状态读取失败，先看 Diagnostics")
        #expect(repo.nextActionHint == "先看 Diagnostics，确认 Git 读取失败原因。")
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
        #expect(repo.errorMessage == "读取失败")
        #expect(repo.commitReadiness.level == .unknown)
        #expect(repo.commitReadiness.reviewReceipt.nextStep == "先打开 Diagnostics，确认 Git 读取失败原因")
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

        let baselineConfig = ScanConfig(
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
            config: baselineConfig,
            scanRoots: [root.path],
            forceRepositoryDiscovery: true
        )
        let baselineRepo = try #require(baseline.data.repositories.first)

        let timeoutConfig = ScanConfig(
            enabledBuiltInPaths: baselineConfig.enabledBuiltInPaths,
            customPaths: baselineConfig.customPaths,
            maxDepth: baselineConfig.maxDepth,
            changedPreviewLimit: baselineConfig.changedPreviewLimit,
            maxConcurrentGitOps: baselineConfig.maxConcurrentGitOps,
            gitCommandTimeout: baselineConfig.gitCommandTimeout,
            scanTimeout: 0,
            slowReposkipSeconds: baselineConfig.slowReposkipSeconds,
            activeRepoThreshold: baselineConfig.activeRepoThreshold
        )
        let timedOut = await GitRepositoryScanner.scan(
            config: timeoutConfig,
            scanRoots: [root.path],
            knownRepositoryPaths: baseline.discoveredRepositoryPaths,
            previousSnapshot: baseline.data
        )

        let retained = try #require(timedOut.data.repositories.first)
        #expect(retained == baselineRepo)
        #expect(timedOut.data.repositories.count == 1)
        #expect(timedOut.warnings.contains { $0.contains("timeout") })
        #expect(retained.id == RepositoryIdentity.id(for: retained.path))
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
                lastReloadRequestedAt: now.addingTimeInterval(-5 * 60),
                reason: "scan",
                now: now
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
                lastReloadRequestedAt: now.addingTimeInterval(-5 * 60),
                reason: "scan",
                now: now
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
                lastReloadRequestedAt: now.addingTimeInterval(-5 * 60),
                reason: "scan",
                now: now
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
                lastReloadRequestedAt: now.addingTimeInterval(-5 * 60),
                reason: "scan",
                now: now
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

    @Test func repositoryIdentityRoundTripsThroughWidgetSnapshotCodable() throws {
        let repository = snapshot(id: "legacy", name: "widget-repo")
        let data = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-12T00:00:00Z",
            writtenAt: "2026-07-12T00:00:00Z",
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 1, totalChangedFiles: 1, errorRepositories: 0),
            repositories: [RepositoryIdentity.normalize(repository)]
        )
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(AppGroupData.self, from: encoded)

        #expect(decoded.repositories.count == 1)
        #expect(decoded.repositories[0].id == RepositoryIdentity.id(for: decoded.repositories[0].path))
        #expect(decoded.repositories[0].path == RepositoryIdentity.canonicalPath(repository.path))
    }

    private func snapshot(
        id: String = "repo-1",
        name: String = "repo-1",
        path: String? = nil,
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
        errorMessage: String? = nil,
        isPinned: Bool = false
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            id: id,
            name: name,
            path: path ?? "/tmp/\(name)",
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
            changedFilesPreview: [],
            risk: risk,
            lastScannedAt: lastScannedAt,
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

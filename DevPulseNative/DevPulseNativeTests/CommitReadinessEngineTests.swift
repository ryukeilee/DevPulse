import Foundation
import Testing
@testable import DevPulse

struct CommitReadinessEngineTests {
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

        #expect(summary.title == "数据可能已过期")
        #expect(summary.readinessLevel == nil)
        #expect(summary.message == "刷新后再判断是否适合提交")
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

        #expect(summary.title == "状态未知")
        #expect(summary.readinessLevel == nil)
        #expect(summary.message == "打开 DevPulse 查看 Diagnostics")
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
        #expect(widgetSection.items.contains(where: { $0.title == "Widget 数据可信度" && $0.value == "数据可能已过期" }) == true)
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
        #expect(trust.headline == "Widget 尚未生成快照")
        #expect(trust.summary.contains("首次启动"))
        #expect(trust.nextSteps.first?.contains("Rescan Now") == true)
        #expect(trust.primaryAction.kind == .rescan)
        #expect(trust.primaryAction.title == "Rescan Now")
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
        #expect(trust.headline == "当前 Widget 数据可能过期")
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
                headline: "当前 Widget 数据可能过期",
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

    private func snapshot(
        id: String = "repo-1",
        name: String = "repo-1",
        modified: Int = 0,
        added: Int = 0,
        deleted: Int = 0,
        untracked: Int = 0,
        staged: Int = 0,
        unstaged: Int? = nil,
        conflicted: Int = 0,
        ahead: Int = 0,
        risk: RiskLevel = .low,
        status: RepositoryStatus = .changed,
        branch: String = "main",
        lastScannedAt: String = "2026-06-19T00:00:00Z",
        lastChangedAt: String? = nil,
        errorMessage: String? = nil
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            id: id,
            name: name,
            path: "/tmp/\(name)",
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
            changedFileCount: modified + added + deleted + untracked,
            changedFilesPreview: [],
            risk: risk,
            lastScannedAt: lastScannedAt,
            lastChangedAt: lastChangedAt,
            errorMessage: errorMessage,
            isPinned: false
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

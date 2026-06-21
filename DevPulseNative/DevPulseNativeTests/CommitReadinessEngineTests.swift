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

    @Test func diagnosticsOverviewFlagsMissingSnapshotFile() {
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

    @Test func cleanRepositoryIsClean() {
        let result = CommitReadinessEngine.assess(snapshot: snapshot(status: .clean))

        #expect(result.level == .idle)
        #expect(result.reasons == [.idleRepository])
        #expect(result.shortLabel == "Idle")
        #expect(result.detail == "没有本地改动")
        #expect(result.reviewReceipt.nextStep == "暂无改动，暂时不用管")
        #expect(result.widgetShortHint == "暂无改动")
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
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 2,
                added: 1,
                deleted: 1,
                staged: 4,
                unstaged: 0,
                risk: .low
            )
        )

        #expect(result.level == .ready)
        #expect(result.reasons == [.stagedChanges])
        #expect(result.shortLabel == "Ready")
        #expect(result.detail == "有 4 个已暂存改动，看起来可以提交")
        #expect(result.reviewReceipt.nextStep == "如已自查改动范围，看起来可以提交")
        #expect(result.widgetShortHint == "看起来可以提交")
    }

    @Test func mixedStagedAndUnstagedChangesNeedReview() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 2,
                untracked: 1,
                staged: 1,
                risk: .low
            )
        )

        #expect(result.level == .review)
        #expect(result.reasons == [.mixedStagedAndUnstagedChanges, .reviewBeforeCommit])
        #expect(result.shortLabel == "Review")
        #expect(result.detail == "已有暂存改动，但工作区还有未整理内容，提交前先确认范围")
        #expect(result.reviewReceipt.nextStep == "建议先审查暂存范围，再决定是否提交")
    }

    @Test func moderateChangesBecomeDirty() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 4,
                untracked: 1,
                risk: .low
            )
        )

        #expect(result.level == .dirty)
        #expect(result.reasons.contains(.largeWorkingTree))
        #expect(result.detail == "未整理改动较多，建议先收敛再提交")
        #expect(result.reviewReceipt.nextStep == "需要先整理改动，再继续审查或提交")
        #expect(result.widgetShortHint == "需要整理改动")
    }

    @Test func untrackedFilesNeedReview() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                modified: 1,
                untracked: 1,
                risk: .low
            )
        )

        #expect(result.level == .review)
        #expect(result.reasons == [.untrackedFiles, .reviewBeforeCommit])
        #expect(result.shortLabel == "Review")
        #expect(result.detail == "有未跟踪文件，建议先看 diff 或确认是否纳入提交")
        #expect(result.reviewReceipt.nextStep == "建议先审查新文件，再决定是否提交")
    }

    @Test func aheadOfRemoteIsReadyToPush() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                ahead: 2,
                status: .clean
            )
        )

        #expect(result.level == .ready)
        #expect(result.reasons == [.localAhead])
        #expect(result.shortLabel == "Ready")
        #expect(result.detail == "有 2 个本地提交可 Push")
        #expect(result.reviewReceipt.nextStep == "如已准备好分享改动，再决定是否继续 push")
    }

    @Test func scanErrorIsUnknown() {
        let result = CommitReadinessEngine.assess(
            snapshot: snapshot(
                status: .error,
                errorMessage: "Failed to run git status"
            )
        )

        #expect(result.level == .unknown)
        #expect(result.reasons == [.scanError])
        #expect(result.shortLabel == "Unknown")
        #expect(result.detail == "Git 状态读取失败")
        #expect(result.reviewReceipt.nextStep == "先打开 Diagnostics，确认 Git 读取失败原因")
        #expect(result.widgetShortHint == "状态读取失败，先看 Diagnostics")
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

    private func snapshot(
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
        errorMessage: String? = nil
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            id: "repo-1",
            name: "repo-1",
            path: "/tmp/repo-1",
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
            lastScannedAt: "2026-06-19T00:00:00Z",
            lastChangedAt: nil,
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

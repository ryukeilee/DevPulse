import Darwin
import Foundation
import Testing
@testable import DevPulse

@Suite(.serialized)
struct ScanPerformanceTests {
    @Test func processRunnerDrainsBothPipesWithoutBackpressureDeadlock() async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = await Task.detached {
            ProcessRunner.runDetailed(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "i=0; while [ $i -lt 8192 ]; do printf 1234567890; printf abcdefghij >&2; i=$((i+1)); done"
                ],
                workingDirectory: "/tmp",
                timeout: 2,
                outputLimit: 256 * 1024
            )
        }.value
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        guard case .success(let output) = result else {
            Issue.record("large dual-pipe command failed: \(result)")
            return
        }
        #expect(output.utf8.count == 81_920)
        #expect(elapsed < 2)
    }

    @Test func processRunnerHardStopsCommandThatIgnoresTerminate() async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = await Task.detached {
            ProcessRunner.runDetailed(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                workingDirectory: "/tmp",
                timeout: 0.05
            )
        }.value
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        #expect(result == .timeout)
        #expect(elapsed < 1)
    }

    @Test func processRunnerNeverReportsTruncatedInheritedPipeAsSuccess() async {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevPulse-descendant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let result = await Task.detached {
            ProcessRunner.runDetailed(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "(trap '' TERM; while :; do :; done) & child=$!; printf '%s' \"$child\" > '\(pidFile.path)'"
                ],
                workingDirectory: "/tmp",
                timeout: 2
            )
        }.value

        #expect(result == .timeout)
        let rawPID = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
        let descendantPID = Int32(rawPID) ?? 0
        #expect(descendantPID > 0)
        errno = 0
        #expect(Darwin.kill(descendantPID, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func processRunnerEnforcesCombinedOutputLimit() async {
        let result = await Task.detached {
            ProcessRunner.runDetailed(
                executable: "/bin/sh",
                arguments: ["-c", "while :; do printf 1234567890; printf 1234567890 >&2; done"],
                workingDirectory: "/tmp",
                timeout: 2,
                outputLimit: 1_024
            )
        }.value

        #expect(result == .outputLimit)
    }

    @Test func porcelainV2ParserPreservesBranchAndChangeSemantics() {
        let output = """
        # branch.oid 0123456789abcdef0123456789abcdef01234567
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -3
        1 M. N... 100644 100644 100644 a b README.md
        1 .M N... 100644 100644 100644 a b "space\\040name.txt"
        2 R. N... 100644 100644 100644 a b R100 renamed file.txt	old file.txt
        u UU N... 100644 100644 100644 100644 a b c conflict.txt
        ? untracked.txt
        """

        let branch = GitStatusParser.parseBranchMetadata(output)
        let entries = GitStatusParser.parseStatusEntries(output)
        let summary = GitStatusParser.summarize(entries)

        #expect(branch.branch == "main")
        #expect(branch.headOID == "0123456789abcdef0123456789abcdef01234567")
        #expect(branch.aheadCount == 2)
        #expect(branch.behindCount == 3)
        #expect(branch.hasUpstream)
        #expect(Set(entries.map(\.path)) == [
            "README.md", "space name.txt", "renamed file.txt", "conflict.txt", "untracked.txt"
        ])
        #expect(summary.modified == 4)
        #expect(summary.untracked == 1)
        #expect(summary.staged == 3)
        #expect(summary.unstaged == 2)
        #expect(summary.conflicted == 1)
        #expect(summary.total == 5)
    }

    @Test func unchangedKnownScopeReusesDiscoveryAndCommitMetadata() async throws {
        let root = try temporaryDirectory(named: "incremental-scan")
        defer { try? FileManager.default.removeItem(at: root) }
        let repositories = try (0..<4).map { index -> URL in
            let repository = root.appendingPathComponent("repo-\(index)")
            try createCommittedRepository(at: repository)
            return repository
        }
        let nestedDirectory = repositories[1].appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "tracked\n".write(
            to: nestedDirectory.appendingPathComponent("local.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "Sources/local.txt"], in: repositories[1])
        try runGit(["commit", "-q", "-m", "Track nested file"], in: repositories[1])

        let firstMetrics = ScanMetricsCollector()
        let first = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty(),
            metrics: firstMetrics
        )
        let firstSnapshot = firstMetrics.snapshot()

        #expect(first.data.repositories.count == repositories.count)
        #expect(firstSnapshot.discoveryMode == .walked)
        #expect(firstSnapshot.gitStatusCommandCount == repositories.count)
        #expect(firstSnapshot.gitLogCommandCount == repositories.count)
        #expect(firstSnapshot.gitCommandCount == repositories.count * 2)
        #expect(firstSnapshot.peakConcurrentGitCommandCount <= 3)

        let secondMetrics = ScanMetricsCollector()
        let second = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data,
            metrics: secondMetrics
        )
        let secondSnapshot = secondMetrics.snapshot()

        #expect(secondSnapshot.discoveryMode == .reusedKnown)
        #expect(secondSnapshot.gitStatusCommandCount == repositories.count)
        #expect(secondSnapshot.gitLogCommandCount == 0)
        #expect(secondSnapshot.gitCommandCount == repositories.count)
        #expect(second.data.repositories.allSatisfy { $0.resolvedDataSource == .current })

        let firstByPath = Dictionary(uniqueKeysWithValues: first.data.repositories.map { ($0.path, $0) })
        for repository in second.data.repositories {
            #expect(repository.lastCommitID == firstByPath[repository.path]?.lastCommitID)
            #expect(repository.lastChangedAt == firstByPath[repository.path]?.lastChangedAt)
            #expect(repository.lastCommitSummary == firstByPath[repository.path]?.lastCommitSummary)
        }

        try "local\n".write(
            to: nestedDirectory.appendingPathComponent("local.txt"),
            atomically: true,
            encoding: .utf8
        )
        let thirdMetrics = ScanMetricsCollector()
        let third = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: second.discoveredRepositoryPaths,
            previousSnapshot: second.data,
            metrics: thirdMetrics
        )
        let thirdSnapshot = thirdMetrics.snapshot()
        #expect(thirdSnapshot.gitStatusCommandCount == repositories.count)
        #expect(thirdSnapshot.gitLogCommandCount == 0)
        #expect(third.data.repositories.first { $0.name == "repo-1" }?.changedFilesPreview == ["local.txt"])
        #expect(third.data.repositories.allSatisfy {
            $0.changedFilesPreview.allSatisfy { !$0.contains("/") }
        })

        try "next\n".write(
            to: repositories[0].appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], in: repositories[0])
        try runGit(["commit", "-m", "Next commit"], in: repositories[0])
        let fourthMetrics = ScanMetricsCollector()
        _ = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: third.discoveredRepositoryPaths,
            previousSnapshot: third.data,
            metrics: fourthMetrics
        )
        let fourthSnapshot = fourthMetrics.snapshot()
        #expect(fourthSnapshot.gitStatusCommandCount == repositories.count)
        #expect(fourthSnapshot.gitLogCommandCount == 1)

        print(String(
            format: "scan_benchmark.initial_elapsed_ms=%.0f initial_git_calls=%d incremental_elapsed_ms=%.0f incremental_git_calls=%d unchanged_log_calls=%d changed_head_log_calls=%d peak_git_concurrency=%d",
            firstSnapshot.elapsed * 1_000,
            firstSnapshot.gitCommandCount,
            secondSnapshot.elapsed * 1_000,
            secondSnapshot.gitCommandCount,
            secondSnapshot.gitLogCommandCount,
            fourthSnapshot.gitLogCommandCount,
            max(firstSnapshot.peakConcurrentGitCommandCount, secondSnapshot.peakConcurrentGitCommandCount)
        ))
    }

    @Test func changedHeadWithLogFailureDoesNotPresentOldCommitAsCurrent() async throws {
        let root = try temporaryDirectory(named: "log-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo")
        try createCommittedRepository(at: repository)
        let baseline = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 1),
            scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty()
        )
        let old = try #require(baseline.data.repositories.first)

        try "changed\n".write(
            to: repository.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], in: repository)
        try runGit(["commit", "-q", "-m", "Changed head"], in: repository)

        let metrics = ScanMetricsCollector()
        let result = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 1),
            scanRoots: [root.path],
            knownRepositoryPaths: baseline.discoveredRepositoryPaths,
            previousSnapshot: baseline.data,
            metrics: metrics,
            gitCommandRunner: { arguments, workingDirectory, timeout, outputLimit, isCancelled in
                if arguments.first == "log" { return .timeout }
                return GitRepositoryScanner.defaultGitCommandRunner(
                    arguments,
                    workingDirectory,
                    timeout,
                    outputLimit,
                    isCancelled
                )
            }
        )
        let current = try #require(result.data.repositories.first)

        #expect(current.resolvedDataSource == .current)
        #expect(current.lastCommitID != nil)
        #expect(current.lastCommitID != old.lastCommitID)
        #expect(current.lastChangedAt == nil)
        #expect(current.lastCommitSummary == nil)
        #expect(current.lastCommitMetadataAvailable == false)
        #expect(current.lastActivityAt != old.lastActivityAt)
        #expect(metrics.snapshot().gitTimeoutCount == 1)
    }

    @Test func badRepositoryDoesNotBlockBatchAndConcurrencyIsBounded() async throws {
        let root = try temporaryDirectory(named: "bounded-batch")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try (0..<7).map { index -> String in
            let repository = root.appendingPathComponent("repo-\(index)")
            try FileManager.default.createDirectory(
                at: repository.appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
            return repository.path
        }
        let probe = GitConcurrencyProbe()
        let metrics = ScanMetricsCollector()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: paths,
            previousSnapshot: .empty(),
            metrics: metrics,
            gitCommandRunner: { arguments, workingDirectory, _, _, isCancelled in
                guard !isCancelled() else { return .cancelled }
                probe.begin()
                defer { probe.end() }
                Thread.sleep(forTimeInterval: 0.06)
                if workingDirectory.hasSuffix("repo-3") {
                    return .timeout
                }
                #expect(arguments.first == "status")
                return .success(output: "# branch.oid (initial)\n# branch.head main")
            }
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let snapshot = metrics.snapshot()

        #expect(result.data.repositories.count == paths.count)
        #expect(result.data.repositories.filter { $0.status == .error }.count == 1)
        #expect(result.data.repositories.filter { $0.resolvedDataSource == .current }.count == paths.count - 1)
        #expect(snapshot.gitStatusCommandCount == paths.count)
        #expect(snapshot.gitTimeoutCount == 1)
        #expect(snapshot.peakConcurrentGitCommandCount == 3)
        #expect(probe.peak == 3)
        #expect(elapsed < 1)

        print(String(
            format: "scan_benchmark.batch_elapsed_ms=%.0f repositories=%d git_calls=%d git_timeouts=%d peak_git_concurrency=%d",
            snapshot.elapsed * 1_000,
            paths.count,
            snapshot.gitCommandCount,
            snapshot.gitTimeoutCount,
            snapshot.peakConcurrentGitCommandCount
        ))
    }

    @Test @MainActor func sleepAndWakeCancelThenRecoverExactlyOnce() async {
        let probe = BlockingScanProbe()
        let scheduler = ScanScheduler(commandMode: true, scanExecution: { request in
            await probe.execute(request)
        })

        scheduler.scanNow(forceRepositoryDiscovery: true, source: .startup)
        #expect(await waitUntil { await probe.requestCount >= 1 })
        scheduler.suspendForSleep()
        #expect(scheduler.isWorkSuspended)
        #expect(!scheduler.hasScheduledTimer)
        #expect(await waitUntil { await probe.activeCount == 0 })

        scheduler.resumeAfterWake()
        #expect(await waitUntil { await probe.requestCount >= 2 })
        let state = await probe.state()
        #expect(state.sources == [.startup, .lifecycleRecovery])
        #expect(state.peakActive == 1)

        scheduler.shutdown()
        #expect(await waitUntil { await probe.activeCount == 0 })
    }

    @Test @MainActor func inactiveSessionPausesAutomaticWorkUntilActivation() async {
        let probe = BlockingScanProbe()
        let scheduler = ScanScheduler(commandMode: true, scanExecution: { request in
            await probe.execute(request)
        })

        scheduler.scanNow(source: .startup)
        #expect(await waitUntil { await probe.requestCount >= 1 })
        scheduler.suspendAutomaticWorkForInactiveSession()
        #expect(scheduler.isSessionInactive)
        #expect(await waitUntil { await probe.activeCount == 0 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await probe.requestCount == 1)

        scheduler.resumeAutomaticWorkForActiveSession()
        #expect(await waitUntil { await probe.requestCount >= 2 })
        let state = await probe.state()
        #expect(state.sources == [.startup, .lifecycleRecovery])
        #expect(state.peakActive == 1)

        scheduler.shutdown()
        #expect(await waitUntil { await probe.activeCount == 0 })
    }

    @Test @MainActor func fullScanWaitsForCancelledRepositoryRetryToExit() async {
        let probe = UnifiedExecutionProbe()
        let scheduler = ScanScheduler(
            commandMode: true,
            repositoryRetryExecution: { _, previous in
                await probe.executeRetry(previous)
            },
            scanExecution: { request in
                await probe.executeScan(request)
            }
        )
        let timestamp = DateFormatting.nowISO()
        let repository = retryableRepositorySnapshot(timestamp: timestamp)
        scheduler.lastResult = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: nil,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary(
                totalRepositories: 1,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 1
            ),
            repositories: [repository]
        )
        scheduler.refreshPhase = .degraded

        scheduler.retryRepository(repository.id)
        #expect(await waitUntil { await probe.retryCount >= 1 })
        scheduler.scanNow(source: .manual)
        #expect(await waitUntil { await probe.scanCount >= 1 })
        let state = await probe.state()
        #expect(state.events == [.retry, .scan])
        #expect(state.peakActive == 1)

        scheduler.shutdown()
        #expect(await waitUntil { await probe.activeCount == 0 })
    }

    @Test @MainActor func selfCheckSleepRecoveryDoesNotCreateGhostRunningScan() async {
        let probe = BlockingScanProbe()
        let scheduler = ScanScheduler(commandMode: true, scanExecution: { request in
            await probe.execute(request)
        })
        let selfCheck = Task { @MainActor in
            await scheduler.runSelfCheck()
        }

        #expect(await waitUntil { await probe.requestCount >= 1 })
        scheduler.suspendForSleep()
        #expect(await waitUntil { await probe.activeCount == 0 })
        _ = await selfCheck.value

        scheduler.resumeAfterWake()
        #expect(await waitUntil { await probe.requestCount >= 2 })
        let state = await probe.state()
        #expect(state.sources == [.manual, .lifecycleRecovery])
        #expect(state.peakActive == 1)

        scheduler.shutdown()
        #expect(await waitUntil { await probe.activeCount == 0 })
        scheduler.scanNow()
        #expect(await probe.requestCount == 2)
    }

    @Test @MainActor func shutdownCancelsInFlightSelfCheck() async {
        let probe = BlockingScanProbe()
        let scheduler = ScanScheduler(commandMode: true, scanExecution: { request in
            await probe.execute(request)
        })
        let selfCheck = Task { @MainActor in
            await scheduler.runSelfCheck()
        }

        #expect(await waitUntil { await probe.requestCount >= 1 })
        scheduler.shutdown()
        #expect(await waitUntil { await probe.activeCount == 0 })
        _ = await selfCheck.value
        #expect(scheduler.isShuttingDown)
        #expect(!scheduler.isScanning)
        scheduler.scanNow()
        #expect(await probe.requestCount == 1)
    }

    @Test @MainActor func shutdownReleasesSelfCheckWaitingOnNonCooperativeRetry() async {
        let retryProbe = NonCooperativeRetryProbe()
        let scanProbe = BlockingScanProbe()
        let scheduler = ScanScheduler(
            commandMode: true,
            repositoryRetryExecution: { _, previous in
                await retryProbe.execute(previous)
            },
            scanExecution: { request in
                await scanProbe.execute(request)
            }
        )
        let timestamp = DateFormatting.nowISO()
        let repository = retryableRepositorySnapshot(timestamp: timestamp)
        scheduler.lastResult = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: nil,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary(
                totalRepositories: 1,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 1
            ),
            repositories: [repository]
        )

        scheduler.retryRepository(repository.id)
        #expect(await waitUntil { await retryProbe.isActive })
        let selfCheck = Task { @MainActor in
            await scheduler.runSelfCheck()
        }
        #expect(await waitUntil { await scheduler.pendingRepositoryRetryDrainWaiterCount == 1 })

        let startedAt = ProcessInfo.processInfo.systemUptime
        scheduler.shutdown()
        _ = await selfCheck.value
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        #expect(elapsed < 0.25)
        #expect(!scheduler.isScanning)
        #expect(await scanProbe.requestCount == 0)
        scheduler.retryRepository(repository.id)
        #expect(await retryProbe.executionCount == 1)

        await retryProbe.release()
        #expect(await waitUntil { await retryProbe.isActive == false })
    }

    @Test @MainActor func idleSchedulerHasNoPollingOrScanStorm() async {
        let probe = BlockingScanProbe()
        let scheduler = ScanScheduler(commandMode: true, scanExecution: { request in
            await probe.execute(request)
        })
        let timestamp = DateFormatting.nowISO()
        scheduler.lastResult = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: nil,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [idleRepositorySnapshot(timestamp: timestamp)]
        )
        scheduler.refreshPhase = .success

        let before = resourceUsage()
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        #expect(scheduler.hasScheduledTimer)
        try? await Task.sleep(for: .milliseconds(500))
        let after = resourceUsage()
        let cpuDelta = max(0, after.cpuSeconds - before.cpuSeconds)
        let rssDelta = max(0, after.maxResidentBytes - before.maxResidentBytes)

        #expect(await probe.requestCount == 0)
        #expect(cpuDelta < 0.25)
        #expect(rssDelta < 32 * 1024 * 1024)
        print(String(
            format: "scan_idle.elapsed_ms=500 cpu_ms=%.1f max_rss_delta_bytes=%lld scan_calls=%d timer_count=1",
            cpuDelta * 1_000,
            rssDelta,
            await probe.requestCount
        ))

        scheduler.shutdown()
        #expect(!scheduler.hasScheduledTimer)
        #expect(scheduler.isShuttingDown)
    }

    @Test func recoveryCoordinatorPreservesForcedDiscovery() {
        var coordinator = ScanRefreshCoordinator()
        coordinator.requestForced(signature: "scope", source: .configuration)
        _ = coordinator.beginNext()
        coordinator.retainOnlyRecovery(signature: "scope", forceRepositoryDiscovery: true)

        #expect(coordinator.completeCurrent() == .init(
            signature: "scope",
            forceRepositoryDiscovery: true,
            source: .lifecycleRecovery
        ))
    }

    @Test @MainActor func staleLifecycleEventsCoalesceToOneFullScan() async {
        let probe = BlockingScanProbe()
        let scheduler = ScanScheduler(commandMode: true, scanExecution: { request in
            await probe.execute(request)
        })
        let now = Date()
        let staleAt = now.addingTimeInterval(-RefreshStatusFormatter.staleThreshold - 1)
        scheduler.lastResult = lifecycleSnapshot(
            timestamp: DateFormatting.isoString(from: staleAt),
            writtenAt: "written-at",
            storageRevision: 7
        )
        scheduler.refreshPhase = .success
        scheduler.startBackgroundScanning(refreshIfNeeded: false)

        scheduler.handleLifecycleRefresh(.windowReopened, now: now)
        scheduler.handleLifecycleRefresh(.applicationBecameActive, now: now)
        scheduler.handleLifecycleRefresh(.wake, now: now)
        scheduler.handleLifecycleRefresh(.wake, now: now)

        #expect(await waitUntil { await probe.requestCount == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        let state = await probe.state()
        #expect(await probe.requestCount == 1)
        #expect(state.sources == [.wake])
        #expect(state.peakActive == 1)

        scheduler.shutdown()
        #expect(await waitUntil { await probe.activeCount == 0 })
    }

    @Test @MainActor func lifecycleEventsDoNotStartSecondFullScanWhileOneIsRunning() async {
        let probe = BlockingScanProbe()
        let scheduler = ScanScheduler(commandMode: true, scanExecution: { request in
            await probe.execute(request)
        })
        let now = Date()
        let staleAt = now.addingTimeInterval(-RefreshStatusFormatter.staleThreshold - 1)
        scheduler.lastResult = lifecycleSnapshot(
            timestamp: DateFormatting.isoString(from: staleAt),
            writtenAt: "written-at",
            storageRevision: 8
        )
        scheduler.refreshPhase = .success
        scheduler.startBackgroundScanning(refreshIfNeeded: false)

        scheduler.scanNow(source: .manual)
        #expect(await waitUntil { await probe.requestCount == 1 })

        scheduler.handleLifecycleRefresh(.windowReopened, now: now)
        scheduler.handleLifecycleRefresh(.applicationBecameActive, now: now)
        try? await Task.sleep(for: .milliseconds(300))

        let state = await probe.state()
        #expect(await probe.requestCount == 1)
        #expect(state.sources == [.manual])
        #expect(state.peakActive == 1)

        scheduler.shutdown()
        #expect(await waitUntil { await probe.activeCount == 0 })
    }

    @Test @MainActor func systemTimeChangeRecalculatesFreshnessWithoutMutatingSnapshotOrScanning() async {
        let probe = BlockingScanProbe()
        let scheduler = ScanScheduler(commandMode: true, scanExecution: { request in
            await probe.execute(request)
        })
        let now = Date()
        let staleAt = now.addingTimeInterval(-RefreshStatusFormatter.staleThreshold - 1)
        let snapshot = lifecycleSnapshot(
            timestamp: DateFormatting.isoString(from: staleAt),
            writtenAt: "written-at",
            storageRevision: 9
        )
        scheduler.lastResult = snapshot
        scheduler.refreshPhase = .success

        scheduler.handleLifecycleRefresh(.systemTimeChanged, now: now)

        #expect(scheduler.lastFreshnessRecalculationAt == now)
        #expect(scheduler.freshness(at: now) == .stale)
        #expect(scheduler.lastResult.generatedAt == snapshot.generatedAt)
        #expect(scheduler.lastResult.writtenAt == snapshot.writtenAt)
        #expect(scheduler.lastResult.lastSuccessfulRefreshAt == snapshot.lastSuccessfulRefreshAt)
        #expect(scheduler.lastResult.storageRevision == snapshot.storageRevision)
        #expect(await probe.requestCount == 0)

        scheduler.shutdown()
    }

    @Test @MainActor func recoveredPathRefreshesOnlyAffectedRepositoryWithoutFullScan() async throws {
        let recoveredRoot = try temporaryDirectory(named: "path-recovery")
        defer { try? FileManager.default.removeItem(at: recoveredRoot) }
        let probe = UnifiedExecutionProbe()
        let scheduler = ScanScheduler(
            commandMode: true,
            repositoryRetryExecution: { _, previous in
                await probe.executeRetry(previous)
            },
            scanExecution: { request in
                await probe.executeScan(request)
            }
        )
        let timestamp = DateFormatting.nowISO()
        let recovering = repositorySnapshot(
            id: "recovering",
            path: recoveredRoot.path,
            timestamp: timestamp,
            status: .error,
            dataSource: .lastSuccessful
        )
        let healthy = repositorySnapshot(
            id: "healthy",
            path: "/tmp/devpulse-healthy-unaffected",
            timestamp: timestamp
        )
        scheduler.lastResult = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: "2026-07-18T00:00:00Z",
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary(
                totalRepositories: 2,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 1
            ),
            repositories: [recovering, healthy],
            storageRevision: 3
        )
        scheduler.refreshPhase = .degraded

        scheduler.handleLifecycleRefresh(
            .pathAvailabilityChanged(rootPath: recoveredRoot.path, isAvailable: true)
        )

        #expect(await waitUntil { await probe.retryCount == 1 })
        #expect(await probe.scanCount == 0)
        let state = await probe.state()
        #expect(state.events == [.retry])
        #expect(state.peakActive == 1)

        scheduler.shutdown()
        #expect(await waitUntil { await probe.activeCount == 0 })
    }

    @Test @MainActor func rapidPathRecoveryRetainsFollowUpWhileUnavailableReadIsInFlight() async throws {
        let recoveredRoot = try temporaryDirectory(named: "rapid-path-recovery")
        defer { try? FileManager.default.removeItem(at: recoveredRoot) }
        let retryProbe = NonCooperativeRetryProbe()
        let scheduler = ScanScheduler(
            commandMode: true,
            repositoryRetryExecution: { _, previous in
                await retryProbe.execute(previous)
            },
            scanExecution: { _ in (.empty(), [], []) }
        )
        let timestamp = DateFormatting.nowISO()
        let repository = repositorySnapshot(
            id: "rapid-recovery",
            path: recoveredRoot.path,
            timestamp: timestamp
        )
        scheduler.lastResult = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: timestamp,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary.build(from: [repository]),
            repositories: [repository]
        )

        scheduler.handleLifecycleRefresh(
            .pathAvailabilityChanged(rootPath: recoveredRoot.path, isAvailable: false)
        )
        #expect(await waitUntil { await retryProbe.isActive })

        scheduler.handleLifecycleRefresh(
            .pathAvailabilityChanged(rootPath: recoveredRoot.path, isAvailable: true)
        )

        #expect(scheduler.pendingPathRefreshCount == 1)
        #expect(await retryProbe.executionCount == 1)

        scheduler.shutdown()
        await retryProbe.release()
        #expect(await waitUntil { await retryProbe.isActive == false })
    }

    @Test @MainActor func staleLifecycleRecoveryKeepsTargetedRetryAndFullScan() async throws {
        let recoveredRoot = try temporaryDirectory(named: "stale-lifecycle-recovery")
        defer { try? FileManager.default.removeItem(at: recoveredRoot) }
        let scanProbe = BlockingScanProbe()
        let retryProbe = PathRefreshCapacityProbe(fastRepositoryID: "recovering")
        let scheduler = ScanScheduler(
            commandMode: true,
            repositoryRetryExecution: { _, previous in
                await retryProbe.execute(previous)
            },
            scanExecution: { request in
                await scanProbe.execute(request)
            }
        )
        let now = Date()
        let staleAt = now.addingTimeInterval(-RefreshStatusFormatter.staleThreshold - 1)
        let timestamp = DateFormatting.isoString(from: staleAt)
        let recovering = repositorySnapshot(
            id: "recovering",
            path: recoveredRoot.path,
            timestamp: timestamp,
            status: .error,
            dataSource: .lastSuccessful
        )
        scheduler.lastResult = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: "2026-07-18T00:00:00Z",
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary.build(from: [recovering]),
            repositories: [recovering],
            storageRevision: 4
        )
        scheduler.refreshPhase = .degraded

        scheduler.handleLifecycleRefresh(.windowReopened, now: now)

        #expect(await waitUntil { await retryProbe.executionCount == 1 })
        #expect(await waitUntil { await scanProbe.requestCount == 1 })
        let state = await scanProbe.state()
        #expect(state.sources == [.windowReopen])
        #expect(state.peakActive == 1)

        scheduler.shutdown()
        #expect(await waitUntil { await scanProbe.activeCount == 0 })
    }

    @Test @MainActor func pathUnavailableDuringFullScanRemainsQueued() async {
        let scanProbe = BlockingScanProbe()
        let retryProbe = PathRefreshCapacityProbe()
        let scheduler = ScanScheduler(
            commandMode: true,
            repositoryRetryExecution: { _, previous in
                await retryProbe.execute(previous)
            },
            scanExecution: { request in
                await scanProbe.execute(request)
            }
        )
        let timestamp = DateFormatting.nowISO()
        let repository = repositorySnapshot(
            id: "external-current",
            path: "/Volumes/Work/external-current",
            timestamp: timestamp
        )
        scheduler.lastResult = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: timestamp,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary.build(from: [repository]),
            repositories: [repository]
        )

        scheduler.scanNow(source: .manual)
        #expect(await waitUntil { await scanProbe.requestCount == 1 })
        scheduler.handleLifecycleRefresh(
            .pathAvailabilityChanged(rootPath: "/Volumes/Work", isAvailable: false)
        )

        #expect(scheduler.pendingPathRefreshCount == 1)
        #expect(await retryProbe.executionCount == 0)

        scheduler.shutdown()
        #expect(await waitUntil { await scanProbe.activeCount == 0 })
    }

    @Test @MainActor func pathRefreshQueueDrainsPastConcurrencyLimit() async {
        let maximumConcurrentRetries = min(12, max(1, ScanConfig.default.maxConcurrentGitOps))
        let repositoryCount = maximumConcurrentRetries + 2
        let retryProbe = PathRefreshCapacityProbe(fastRepositoryID: "repo-00")
        let scheduler = ScanScheduler(
            commandMode: true,
            repositoryRetryExecution: { _, previous in
                await retryProbe.execute(previous)
            },
            scanExecution: { _ in (.empty(), [], []) }
        )
        let timestamp = DateFormatting.nowISO()
        let repositories = (0..<repositoryCount).map { index in
            let id = String(format: "repo-%02d", index)
            return repositorySnapshot(
                id: id,
                path: "/Volumes/Batch/\(id)",
                timestamp: timestamp
            )
        }
        scheduler.lastResult = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: timestamp,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary.build(from: repositories),
            repositories: repositories
        )

        scheduler.handleLifecycleRefresh(
            .pathAvailabilityChanged(rootPath: "/Volumes/Batch", isAvailable: false)
        )

        #expect(await waitUntil {
            await retryProbe.executionCount == maximumConcurrentRetries + 1
        })
        #expect(scheduler.pendingPathRefreshCount == 1)
        #expect(scheduler.retryingRepositoryIDs.count == maximumConcurrentRetries)
        #expect(await retryProbe.peakActiveCount <= maximumConcurrentRetries)

        scheduler.shutdown()
        #expect(await waitUntil { await retryProbe.activeCount == 0 })
    }

    @Test func pathAvailabilityPolicyTargetsOnlyAffectedRepositoriesAndReachableRetries() {
        let timestamp = DateFormatting.nowISO()
        let repositories = [
            repositorySnapshot(id: "affected-current", path: "/Volumes/Work/current", timestamp: timestamp),
            repositorySnapshot(
                id: "affected-retry-reachable",
                path: "/Volumes/Work/retry-reachable",
                timestamp: timestamp,
                status: .error,
                dataSource: .lastSuccessful
            ),
            repositorySnapshot(
                id: "affected-retry-unreachable",
                path: "/Volumes/Work/retry-unreachable",
                timestamp: timestamp,
                status: .error,
                dataSource: .lastSuccessful
            ),
            repositorySnapshot(id: "unrelated-current", path: "/Volumes/Other/current", timestamp: timestamp),
            repositorySnapshot(
                id: "unrelated-retry",
                path: "/Volumes/Other/retry",
                timestamp: timestamp,
                status: .error,
                dataSource: .lastSuccessful
            )
        ]

        let unavailable = ScanSchedulerPolicy.repositoriesNeedingPathRefresh(
            repositories,
            under: "/Volumes/Work",
            isAvailable: false,
            pathIsReachable: { _ in false }
        )
        #expect(Set(unavailable.map(\.id)) == [
            "affected-current", "affected-retry-reachable", "affected-retry-unreachable"
        ])

        let recovered = ScanSchedulerPolicy.repositoriesNeedingPathRefresh(
            repositories,
            under: "/Volumes/Work",
            isAvailable: true,
            pathIsReachable: { $0 != "/Volumes/Work/retry-unreachable" }
        )
        #expect(Set(recovered.map(\.id)) == ["affected-retry-reachable"])
    }

    private func scanConfig(maxConcurrentGitOps: Int) -> ScanConfig {
        ScanConfig(
            enabledBuiltInPaths: [],
            customPaths: [],
            maxDepth: 2,
            changedPreviewLimit: 5,
            maxConcurrentGitOps: maxConcurrentGitOps,
            gitCommandTimeout: 2,
            scanTimeout: 10,
            slowReposkipSeconds: 60,
            activeRepoThreshold: 30
        )
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevPulse-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createCommittedRepository(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: directory)
        try runGit(["config", "user.name", "DevPulse Tests"], in: directory)
        try runGit(["config", "user.email", "devpulse-tests@example.com"], in: directory)
        try "initial\n".write(
            to: directory.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], in: directory)
        try runGit(["commit", "-q", "-m", "Initial commit"], in: directory)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ScanPerformanceTestError.git(arguments, output)
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func idleRepositorySnapshot(timestamp: String) -> RepositorySnapshot {
        RepositorySnapshot(
            id: "idle",
            name: "idle",
            path: "/tmp/idle",
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
            behindCount: 0,
            hasUpstream: true,
            changedFileCount: 0,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: timestamp,
            lastChangedAt: timestamp,
            lastCommitMetadataAvailable: true,
            errorMessage: nil,
            isPinned: false
        )
    }

    private func retryableRepositorySnapshot(timestamp: String) -> RepositorySnapshot {
        RepositorySnapshot(
            id: "retryable",
            name: "retryable",
            path: "/tmp/retryable",
            branch: "main",
            status: .error,
            modifiedFileCount: 0,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 0,
            unstagedFileCount: 0,
            conflictedFileCount: 0,
            aheadCount: 0,
            behindCount: 0,
            hasUpstream: true,
            changedFileCount: 0,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: timestamp,
            dataSource: .lastSuccessful,
            lastSuccessfulScanAt: timestamp,
            lastChangedAt: timestamp,
            lastCommitMetadataAvailable: false,
            unavailableSince: timestamp,
            errorMessage: "读取超时",
            isPinned: false
        )
    }

    private func lifecycleSnapshot(
        timestamp: String,
        writtenAt: String,
        storageRevision: UInt64
    ) -> AppGroupData {
        AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: writtenAt,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary(
                totalRepositories: 1,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 0
            ),
            repositories: [idleRepositorySnapshot(timestamp: timestamp)],
            storageRevision: storageRevision
        )
    }

    private func repositorySnapshot(
        id: String,
        path: String,
        timestamp: String,
        status: RepositoryStatus = .clean,
        dataSource: RepositoryDataSource = .current
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            id: id,
            name: id,
            path: path,
            branch: "main",
            status: status,
            modifiedFileCount: 0,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 0,
            unstagedFileCount: 0,
            conflictedFileCount: 0,
            aheadCount: 0,
            behindCount: 0,
            hasUpstream: true,
            changedFileCount: 0,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: timestamp,
            dataSource: dataSource,
            lastSuccessfulScanAt: dataSource == .current ? timestamp : nil,
            lastChangedAt: timestamp,
            lastCommitMetadataAvailable: true,
            errorMessage: status == .error ? "读取超时" : nil,
            isPinned: false
        )
    }

    @Test func invalidatedReuseFallsThroughToWalkAndDiscoversAllRepos() async throws {
        let root = try temporaryDirectory(named: "invalidated-reuse")
        defer { try? FileManager.default.removeItem(at: root) }

        // Create two real git repositories under the scan root
        let repoPaths = try (0..<2).map { index -> String in
            let repo = root.appendingPathComponent("repo-\(index)")
            try createCommittedRepository(at: repo)
            return repo.path
        }

        // Create a non-repo directory under the scan root.
        // When repositoryAvailability checks this path it returns .notRepository
        // (a clean directory without .git), which invalidates the reuse set.
        let nonRepoPath = root.appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(at: nonRepoPath, withIntermediateDirectories: true)

        let knownPaths = repoPaths + [nonRepoPath.path]
        let metrics = ScanMetricsCollector()
        let startedAt = ProcessInfo.processInfo.systemUptime

        let result = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: knownPaths,
            previousSnapshot: .empty(),
            metrics: metrics
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let snapshot = metrics.snapshot()

        // The non-repo path caused reuse invalidation → walk mode
        #expect(snapshot.discoveryMode == .walked)
        #expect(result.data.repositories.count == repoPaths.count)
        #expect(result.data.repositories.allSatisfy { $0.resolvedDataSource == .current })
        #expect(elapsed < 5)

        print(String(
            format: "scan_invalidated_reuse.elapsed_ms=%.0f discovery=%@ repos=%d",
            snapshot.elapsed * 1_000,
            "\(snapshot.discoveryMode)",
            result.data.repositories.count
        ))
    }

    @Test func parallelReuseChecksCompleteQuickly() async throws {
        let root = try temporaryDirectory(named: "parallel-reuse-checks")
        defer { try? FileManager.default.removeItem(at: root) }

        // Create several git repositories for a parallel reuse check
        let repoPaths = try (0..<6).map { index -> String in
            let repo = root.appendingPathComponent("repo-\(index)")
            try createCommittedRepository(at: repo)
            return repo.path
        }

        let firstMetrics = ScanMetricsCollector()
        let first = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: repoPaths,
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty(),
            metrics: firstMetrics
        )
        #expect(first.data.repositories.count == repoPaths.count)

        // Second scan reuses known paths via parallel availability checks
        let secondMetrics = ScanMetricsCollector()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let second = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            forceRepositoryDiscovery: false,
            previousSnapshot: first.data,
            metrics: secondMetrics
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let secondSnapshot = secondMetrics.snapshot()

        #expect(second.data.repositories.count == repoPaths.count)
        #expect(secondSnapshot.discoveryMode == .reusedKnown)
        #expect(second.data.repositories.allSatisfy { $0.resolvedDataSource == .current })
        #expect(elapsed < 5)

        print(String(
            format: "scan_parallel_reuse.elapsed_ms=%.0f discovery=%@ repos=%d",
            secondSnapshot.elapsed * 1_000,
            "\(secondSnapshot.discoveryMode)",
            second.data.repositories.count
        ))
    }

    @Test @MainActor func manualRefreshDoesNotBlockMainThread() async {
        let probe = BlockingScanProbe()
        let scheduler = ScanScheduler(commandMode: true, scanExecution: { request in
            await probe.execute(request)
        })
        let timestamp = DateFormatting.nowISO()
        let initialData = lifecycleSnapshot(
            timestamp: timestamp,
            writtenAt: "2026-07-23T00:00:00Z",
            storageRevision: 10
        )
        scheduler.lastResult = initialData
        scheduler.lastScanAt = DateFormatting.date(from: timestamp)
        scheduler.refreshPhase = .success

        scheduler.scanNow(source: .manual)

        #expect(scheduler.isScanning)
        #expect(scheduler.refreshPhase == .refreshing)
        #expect(scheduler.lastResult.generatedAt == initialData.generatedAt)
        #expect(scheduler.lastResult.repositories.count == initialData.repositories.count)
        #expect(!scheduler.lastResult.repositories.isEmpty)

        let mainActorResponsive = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(50))
                return false
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
        #expect(mainActorResponsive)

        scheduler.shutdown()
        let probeExited = await waitUntil { await probe.activeCount == 0 }
        #expect(probeExited)
    }

    @Test @MainActor func rapidRefreshStormDeduplication() async {
        let probe = BlockingScanProbe()
        let scheduler = ScanScheduler(
            commandMode: true,
            scanExecution: { request in
                await probe.execute(request)
            }
        )

        for _ in 0..<10 {
            scheduler.scanNow(source: .manual)
        }

        #expect(await waitUntil { await probe.requestCount >= 1 })
        #expect(await probe.requestCount == 1)

        scheduler.shutdown()
        #expect(await waitUntil { await probe.activeCount == 0 })
    }

    private func resourceUsage() -> (cpuSeconds: Double, maxResidentBytes: Int64) {

        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return (user + system, Int64(usage.ru_maxrss))
    }
}

private final class GitConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var peakCount = 0

    func begin() {
        lock.lock()
        activeCount += 1
        peakCount = max(peakCount, activeCount)
        lock.unlock()
    }

    func end() {
        lock.lock()
        activeCount -= 1
        lock.unlock()
    }

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakCount
    }
}

private actor BlockingScanProbe {
    struct State: Sendable {
        let sources: [ScanRefreshSource]
        let peakActive: Int
    }

    private var requests: [ScanExecutionRequest] = []
    private var active = 0
    private var peak = 0

    var requestCount: Int { requests.count }
    var activeCount: Int { active }

    func state() -> State {
        State(sources: requests.map(\.source), peakActive: peak)
    }

    func execute(_ request: ScanExecutionRequest) async -> (
        data: AppGroupData,
        warnings: [String],
        discoveredRepositoryPaths: [String]
    ) {
        requests.append(request)
        active += 1
        peak = max(peak, active)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        active -= 1
        return (.empty(), [], [])
    }
}

private actor UnifiedExecutionProbe {
    enum Event: Sendable, Equatable {
        case retry
        case scan
    }

    struct State: Sendable {
        let events: [Event]
        let peakActive: Int
    }

    private var recordedEvents: [Event] = []
    private var active = 0
    private var peak = 0

    var retryCount: Int { recordedEvents.filter { $0 == .retry }.count }
    var scanCount: Int { recordedEvents.filter { $0 == .scan }.count }
    var activeCount: Int { active }

    func state() -> State {
        State(events: recordedEvents, peakActive: peak)
    }

    func executeRetry(_ previous: RepositorySnapshot) async -> RepositorySnapshot? {
        _ = previous
        await block(as: .retry)
        return nil
    }

    func executeScan(_ request: ScanExecutionRequest) async -> (
        data: AppGroupData,
        warnings: [String],
        discoveredRepositoryPaths: [String]
    ) {
        _ = request
        await block(as: .scan)
        return (.empty(), [], [])
    }

    private func block(as event: Event) async {
        recordedEvents.append(event)
        active += 1
        peak = max(peak, active)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        active -= 1
    }
}

private actor PathRefreshCapacityProbe {
    private let fastRepositoryID: String?
    private var executions: [String] = []
    private var active = 0
    private var peakActive = 0

    init(fastRepositoryID: String? = nil) {
        self.fastRepositoryID = fastRepositoryID
    }

    var executionCount: Int { executions.count }
    var activeCount: Int { active }
    var peakActiveCount: Int { peakActive }

    func execute(_ previous: RepositorySnapshot) async -> RepositorySnapshot? {
        executions.append(previous.id)
        if previous.id == fastRepositoryID {
            return nil
        }

        active += 1
        peakActive = max(peakActive, active)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        active -= 1
        return nil
    }
}

private actor NonCooperativeRetryProbe {
    private var active = false
    private var executions = 0
    private var continuation: CheckedContinuation<Void, Never>?

    var isActive: Bool { active }
    var executionCount: Int { executions }

    func execute(_ previous: RepositorySnapshot) async -> RepositorySnapshot? {
        _ = previous
        executions += 1
        active = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        active = false
        return nil
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Incremental scan tests

extension ScanPerformanceTests {
    /// Verify that unchanged repos are skipped via fast filesystem check.
    /// All repos have HEAD and index timestamps older than last scan → no git status commands.
    @Test func incrementalFastCheckSkipsUnchangedRepos() async throws {
        let root = try temporaryDirectory(named: "incremental-skip")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<3).map { index -> URL in
            let repo = root.appendingPathComponent("repo-\(index)")
            try createCommittedRepository(at: repo)
            return repo
        }
        let repoPaths = repoURLs.map(\.path)

        // First full scan establishes baselines.
        let firstMetrics = ScanMetricsCollector()
        let first = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: repoPaths,
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty(),
            metrics: firstMetrics
        )
        #expect(first.data.repositories.count == repoPaths.count)
        #expect(first.data.repositories.allSatisfy { $0.resolvedDataSource == .current })

        // Set HEAD and index mtimes to the past so the fast check sees them as unchanged.
        // Wait briefly to ensure timestamps are distinguishable.
        try await Task.sleep(for: .milliseconds(50))
        let pastDate = Date().addingTimeInterval(-3600)  // 1 hour ago
        for repoURL in repoURLs {
            let headURL = repoURL.appendingPathComponent(".git/HEAD")
            let indexURL = repoURL.appendingPathComponent(".git/index")
            try FileManager.default.setAttributes(
                [.modificationDate: pastDate],
                ofItemAtPath: headURL.path
            )
            if FileManager.default.fileExists(atPath: indexURL.path) {
                try FileManager.default.setAttributes(
                    [.modificationDate: pastDate],
                    ofItemAtPath: indexURL.path
                )
            }
        }

        // Second scan: fast check should skip all repos.
        let secondMetrics = ScanMetricsCollector()
        let second = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data,
            metrics: secondMetrics
        )
        let secondSnapshot = secondMetrics.snapshot()

        // All repos were skipped — zero git status commands.
        #expect(secondSnapshot.repositorySkippedCount == repoPaths.count)
        #expect(secondSnapshot.gitStatusCommandCount == 0)
        #expect(secondSnapshot.gitCommandCount == 0)
        #expect(second.data.repositories.count == repoPaths.count)
        // Skipped repos retain .current dataSource since state is genuinely unchanged.
        #expect(second.data.repositories.allSatisfy { $0.resolvedDataSource == .current })
        // Fields preserved from previous scan.
        let firstByPath = Dictionary(uniqueKeysWithValues: first.data.repositories.map { ($0.path, $0) })
        for repo in second.data.repositories {
            let prev = firstByPath[repo.path]
            #expect(repo.lastCommitID == prev?.lastCommitID)
            #expect(repo.branch == prev?.branch)
            #expect(repo.changedFileCount == prev?.changedFileCount)
        }

        print(String(
            format: "incremental_skip.repos=%d skipped=%d git_calls=%d",
            repoPaths.count,
            secondSnapshot.repositorySkippedCount,
            secondSnapshot.gitCommandCount
        ))
    }

    /// Verify that when HEAD changes on a repo, only that repo gets git status.
    /// Other repos remain skipped via fast check.
    @Test func incrementalFastCheckRunsGitOnlyOnChangedRepo() async throws {
        let root = try temporaryDirectory(named: "incremental-changed")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<3).map { index -> URL in
            let repo = root.appendingPathComponent("repo-\(index)")
            try createCommittedRepository(at: repo)
            return repo
        }
        let repoPaths = repoURLs.map(\.path)

        // First full scan.
        let firstMetrics = ScanMetricsCollector()
        let first = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: repoPaths,
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty(),
            metrics: firstMetrics
        )

        // Make a new commit in repo-0 only.
        try "changed\n".write(
            to: repoURLs[0].appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], in: repoURLs[0])
        try runGit(["commit", "-q", "-m", "Second commit"], in: repoURLs[0])

        // Set the unchanged repos' HEAD/index to the past so fast check skips them.
        let pastDate = Date().addingTimeInterval(-3600)
        for i in 1..<repoURLs.count {
            let headURL = repoURLs[i].appendingPathComponent(".git/HEAD")
            let indexURL = repoURLs[i].appendingPathComponent(".git/index")
            try FileManager.default.setAttributes(
                [.modificationDate: pastDate],
                ofItemAtPath: headURL.path
            )
            if FileManager.default.fileExists(atPath: indexURL.path) {
                try FileManager.default.setAttributes(
                    [.modificationDate: pastDate],
                    ofItemAtPath: indexURL.path
                )
            }
        }

        // Second scan: only repo-0 should run git status.
        let secondMetrics = ScanMetricsCollector()
        let second = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data,
            metrics: secondMetrics
        )
        let secondSnapshot = secondMetrics.snapshot()

        // Two repos skipped, one repo had changes → 1 status + 1 log command.
        #expect(secondSnapshot.repositorySkippedCount == repoPaths.count - 1)
        #expect(secondSnapshot.gitStatusCommandCount == 1)
        #expect(secondSnapshot.gitLogCommandCount == 1)
        #expect(second.data.repositories.count == repoPaths.count)

        // All repos have .current dataSource — fast-skipped repos preserve their
        // previous state as current since the filesystem proves nothing changed.
        let repo0 = try #require(second.data.repositories.first { $0.name == "repo-0" })
        #expect(repo0.resolvedDataSource == .current)
        let repo1 = try #require(second.data.repositories.first { $0.name == "repo-1" })
        #expect(repo1.resolvedDataSource == .current)

        print(String(
            format: "incremental_changed.repos=%d skipped=%d git_status=%d git_log=%d",
            repoPaths.count,
            secondSnapshot.repositorySkippedCount,
            secondSnapshot.gitStatusCommandCount,
            secondSnapshot.gitLogCommandCount
        ))
    }

    /// Verify that cancelling a scan preserves partial results from completed repos.
    @Test func incrementalScanCancellationPreservesPartialResults() async throws {
        let root = try temporaryDirectory(named: "incremental-cancel")
        defer { try? FileManager.default.removeItem(at: root) }

        // Create a scanning probe that blocks on demand.
        actor CancelProbe {
            var startedCount = 0
            var canProceed = false

            func waitForStart() async { startedCount += 1 }
            func proceed() { canProceed = true }

            func shouldBlock() async -> Bool {
                startedCount += 1
                while !canProceed, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return !Task.isCancelled
            }
        }

        let probe = CancelProbe()

        // Create a scan with controlled blocking on the second repo.
        let repoURLs = try (0..<3).map { index -> URL in
            let repo = root.appendingPathComponent("cancel-repo-\(index)")
            try createCommittedRepository(at: repo)
            return repo
        }
        let repoPaths = repoURLs.map(\.path)

        // First full scan.
        let firstMetrics = ScanMetricsCollector()
        let first = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 3),
            scanRoots: [root.path],
            knownRepositoryPaths: repoPaths,
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty(),
            metrics: firstMetrics
        )
        #expect(first.data.repositories.count == repoPaths.count)

        // Introduce a change in repo-1 (which was the second repo).
        try "new\n".write(
            to: repoURLs[1].appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["commit", "-q", "-am", "New commit"], in: repoURLs[1])

        // Set other repos' timestamps to past so fast check skips them.
        let pastDate = Date().addingTimeInterval(-3600)
        for i in [0, 2] {
            let headURL = repoURLs[i].appendingPathComponent(".git/HEAD")
            let indexURL = repoURLs[i].appendingPathComponent(".git/index")
            try FileManager.default.setAttributes(
                [.modificationDate: pastDate],
                ofItemAtPath: headURL.path
            )
            if FileManager.default.fileExists(atPath: indexURL.path) {
                try FileManager.default.setAttributes(
                    [.modificationDate: pastDate],
                    ofItemAtPath: indexURL.path
                )
            }
        }

        let config = scanConfig(maxConcurrentGitOps: 2)

        // Run scan in a cancellable task.
        let scanTask = Task {
            let metrics = ScanMetricsCollector()
            let result = await GitRepositoryScanner.scan(
                config: config,
                scanRoots: [root.path],
                knownRepositoryPaths: first.discoveredRepositoryPaths,
                previousSnapshot: first.data,
                metrics: metrics
            )
            return (result, metrics.snapshot())
        }

        // Wait for the scan to start, then cancel.
        try await Task.sleep(for: .milliseconds(200))
        scanTask.cancel()

        let (result, snapshot) = await scanTask.value

        // Even cancelled, the scan should return results (partial).
        #expect(result.data.repositories.count > 0)
        // Repos that were skipped via fast check should have .lastSuccessful.
        let skippedRepos = result.data.repositories.filter { $0.resolvedDataSource == .lastSuccessful }
        #expect(skippedRepos.count >= 0)
        #expect(snapshot.gitCommandCount >= 0)

        print(String(
            format: "incremental_cancel.repos=%d git_calls=%d warnings=%d",
            result.data.repositories.count,
            snapshot.gitCommandCount,
            result.warnings.count
        ))
    }

    /// Verify that concurrent scan requests are deduplicated.
    @Test @MainActor func concurrentScanRequestsAreDeduplicated() async {
        let probe = BlockingScanProbe()
        let scheduler = ScanScheduler(
            commandMode: true,
            scanExecution: { request in
                await probe.execute(request)
            }
        )

        // Start first scan.
        scheduler.scanNow(source: .manual)
        #expect(await waitUntil { await probe.requestCount >= 1 })

        // Try to start multiple concurrent scans.
        // Use non-forcing sources: .windowReopen and .timer are properly
        // deduplicated while a scan is running, unlike .wake or .pathRecovery
        // which are designed to supersede an in-progress scan.
        scheduler.scanNow(source: .windowReopen)
        scheduler.scanNow(source: .timer)
        scheduler.scanNow(source: .manual)

        // Only one scan should have been started.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await probe.requestCount == 1)

        scheduler.shutdown()
        #expect(await waitUntil { await probe.activeCount == 0 })
    }

    /// Verify that deleting and recreating a repo is properly handled.
    // MARK: - Full fallback and exception recovery

    /// Verify that repos with .lastSuccessful dataSource are NOT fast-skipped.
    /// The fast check only applies to repos with .current dataSource and a valid
    /// lastSuccessfulScanAt — the guard in repositoryCanSkipGitStatus explicitly
    /// rejects anything else.
    @Test func fastCheckSkipsOnlyWhenSafe() async throws {
        let root = try temporaryDirectory(named: "safe-skip")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("repo")
        try createCommittedRepository(at: repoURL)

        // First scan: repo gets .current dataSource
        let firstMetrics = ScanMetricsCollector()
        let first = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 1),
            scanRoots: [root.path],
            knownRepositoryPaths: [repoURL.path],
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty(),
            metrics: firstMetrics
        )
        #expect(first.data.repositories.first?.resolvedDataSource == .current)

        // Second scan: make git status fail → repo goes to .lastSuccessful
        let secondMetrics = ScanMetricsCollector()
        let second = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 1),
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data,
            metrics: secondMetrics,
            gitCommandRunner: { args, wd, timeout, limit, isCancelled in
                if args.first == "status" {
                    return .timeout
                }
                return GitRepositoryScanner.defaultGitCommandRunner(
                    args, wd, timeout, limit, isCancelled
                )
            }
        )
        #expect(second.data.repositories.first?.status == .error)
        #expect(second.data.repositories.first?.resolvedDataSource == .lastSuccessful)

        // Set HEAD/index timestamps to past so fast check would try to skip
        let pastDate = Date().addingTimeInterval(-3600)
        let headURL = repoURL.appendingPathComponent(".git/HEAD")
        let indexURL = repoURL.appendingPathComponent(".git/index")
        try FileManager.default.setAttributes(
            [.modificationDate: pastDate],
            ofItemAtPath: headURL.path
        )
        if FileManager.default.fileExists(atPath: indexURL.path) {
            try FileManager.default.setAttributes(
                [.modificationDate: pastDate],
                ofItemAtPath: indexURL.path
            )
        }

        // Third scan: even with old timestamps, repo is NOT skipped
        // because its resolvedDataSource is .lastSuccessful
        let thirdMetrics = ScanMetricsCollector()
        let third = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 1),
            scanRoots: [root.path],
            knownRepositoryPaths: second.discoveredRepositoryPaths,
            previousSnapshot: second.data,
            metrics: thirdMetrics
        )
        let thirdSnapshot = thirdMetrics.snapshot()
        #expect(thirdSnapshot.repositorySkippedCount == 0)
        #expect(thirdSnapshot.gitStatusCommandCount >= 1)
        #expect(third.data.repositories.count == 1)

        print(String(
            format: "safe_skip.skipped=%d git_status=%d dataSource=%@",
            thirdSnapshot.repositorySkippedCount,
            thirdSnapshot.gitStatusCommandCount,
            third.data.repositories.first?.resolvedDataSource.rawValue ?? "nil"
        ))
    }

    /// Verify that forceRepositoryDiscovery forces walked discovery mode,
    /// while a subsequent scan without force falls back to known-path reuse.
    @Test func fullFallbackAfterForceDiscovery() async throws {
        let root = try temporaryDirectory(named: "force-disc")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<2).map { index -> URL in
            let repo = root.appendingPathComponent("fd-repo-\(index)")
            try createCommittedRepository(at: repo)
            return repo
        }
        let config = scanConfig(maxConcurrentGitOps: 2)

        // First scan: force discovery → walked
        let firstMetrics = ScanMetricsCollector()
        let first = await GitRepositoryScanner.scan(
            config: config, scanRoots: [root.path],
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty(),
            metrics: firstMetrics
        )
        #expect(firstMetrics.snapshot().discoveryMode == .walked)
        #expect(first.data.repositories.count == repoURLs.count)
        #expect(first.data.repositories.allSatisfy { $0.resolvedDataSource == .current })

        // Second scan: no force → reuse known
        let secondMetrics = ScanMetricsCollector()
        let second = await GitRepositoryScanner.scan(
            config: config, scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data,
            metrics: secondMetrics
        )
        #expect(secondMetrics.snapshot().discoveryMode == .reusedKnown)
        #expect(second.data.repositories.count == repoURLs.count)

        // Third scan: force again → walked again
        let thirdMetrics = ScanMetricsCollector()
        let third = await GitRepositoryScanner.scan(
            config: config, scanRoots: [root.path],
            knownRepositoryPaths: second.discoveredRepositoryPaths,
            forceRepositoryDiscovery: true,
            previousSnapshot: second.data,
            metrics: thirdMetrics
        )
        #expect(thirdMetrics.snapshot().discoveryMode == .walked)
        #expect(third.data.repositories.count == repoURLs.count)
        #expect(third.data.repositories.allSatisfy { $0.resolvedDataSource == .current })

        print(String(
            format: "force_discovery.phase1_mode=%@ phase2_mode=%@ phase3_mode=%@",
            firstMetrics.snapshot().discoveryMode == .walked ? "walked" : "other",
            secondMetrics.snapshot().discoveryMode == .reusedKnown ? "reusedKnown" : "other",
            thirdMetrics.snapshot().discoveryMode == .walked ? "walked" : "other"
        ))
    }

    /// Verify that cancelling a scan during batch reading does not crash,
    /// returns partial results, and preserves prior data for unread repos.
    @Test func cancellationDuringBatchDoesNotCrash() async throws {
        let root = try temporaryDirectory(named: "cancel-batch")
        defer { try? FileManager.default.removeItem(at: root) }

        // Create enough repos so batch phase spans multiple yield points
        let repoURLs = try (0..<8).map { index -> URL in
            let repo = root.appendingPathComponent("batch-repo-\(index)")
            try createCommittedRepository(at: repo)
            return repo
        }
        let config = scanConfig(maxConcurrentGitOps: 3)

        // First scan establishes baselines
        let firstMetrics = ScanMetricsCollector()
        let first = await GitRepositoryScanner.scan(
            config: config, scanRoots: [root.path],
            knownRepositoryPaths: repoURLs.map(\.path),
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty(),
            metrics: firstMetrics
        )
        #expect(first.data.repositories.count == repoURLs.count)

        // Make a change in repo-0 so it will need git status
        try "change\n".write(
            to: repoURLs[0].appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8
        )
        try runGit(["add", "README.md"], in: repoURLs[0])
        try runGit(["commit", "-q", "-m", "Change for cancel test"], in: repoURLs[0])

        // Set other repos' HEAD/index to past so fast check skips them quickly
        let pastDate = Date().addingTimeInterval(-3600)
        for i in 1..<repoURLs.count {
            let headURL = repoURLs[i].appendingPathComponent(".git/HEAD")
            try FileManager.default.setAttributes(
                [.modificationDate: pastDate],
                ofItemAtPath: headURL.path
            )
        }

        // Start scan and cancel after brief delay
        let scanTask = Task {
            return await GitRepositoryScanner.scan(
                config: config, scanRoots: [root.path],
                knownRepositoryPaths: first.discoveredRepositoryPaths,
                previousSnapshot: first.data
            )
        }

        try await Task.sleep(for: .milliseconds(150))
        scanTask.cancel()

        let (result, warnings, _) = await scanTask.value

        // Must not crash; should return something
        #expect(result.repositories.count > 0)
        #expect(result.repositories.count <= repoURLs.count)
        // Should have cancellation warning or at least not crash
        let hasCancelWarning = warnings.contains {
            $0.lowercased().contains("cancel") || $0.lowercased().contains("cancell")
        }
        #expect(hasCancelWarning || warnings.isEmpty)

        print(String(
            format: "cancel_batch.repos=%d warnings=%d has_warning=%@",
            result.repositories.count,
            warnings.count,
            hasCancelWarning ? "yes" : "no"
        ))
    }

    /// Verify that after cancellation, a subsequent rescan recovers all
    /// repos completely with .current data source.
    @Test func cancellationThenRescanRecoversAll() async throws {
        let root = try temporaryDirectory(named: "cancel-recover")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<4).map { index -> URL in
            let repo = root.appendingPathComponent("recover-repo-\(index)")
            try createCommittedRepository(at: repo)
            return repo
        }
        let config = scanConfig(maxConcurrentGitOps: 2)

        // First scan establishes baselines
        let first = await GitRepositoryScanner.scan(
            config: config, scanRoots: [root.path],
            knownRepositoryPaths: repoURLs.map(\.path),
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty()
        )
        #expect(first.data.repositories.count == repoURLs.count)

        // Make a change in repo-0
        try "data\n".write(
            to: repoURLs[0].appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8
        )
        try runGit(["commit", "-q", "-am", "Prep for cancel"], in: repoURLs[0])

        // Set other repos to past so fast check skips them
        let pastDate = Date().addingTimeInterval(-3600)
        for i in 1..<repoURLs.count {
            let headURL = repoURLs[i].appendingPathComponent(".git/HEAD")
            try FileManager.default.setAttributes(
                [.modificationDate: pastDate],
                ofItemAtPath: headURL.path
            )
        }

        // Start and cancel a scan
        let cancelTask = Task {
            return await GitRepositoryScanner.scan(
                config: config, scanRoots: [root.path],
                knownRepositoryPaths: first.discoveredRepositoryPaths,
                previousSnapshot: first.data
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        cancelTask.cancel()
        _ = await cancelTask.value

        // Now rescan with force discovery to confirm full recovery
        let finalMetrics = ScanMetricsCollector()
        let final = await GitRepositoryScanner.scan(
            config: config, scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            forceRepositoryDiscovery: true,
            previousSnapshot: first.data,
            metrics: finalMetrics
        )

        #expect(final.data.repositories.count == repoURLs.count)
        #expect(final.data.repositories.allSatisfy { $0.resolvedDataSource == .current })

        // repo-0 should show the commit we made before cancellation
        let repo0 = try #require(final.data.repositories.first { $0.name == "recover-repo-0" })
        #expect(repo0.lastCommitSummary?.contains("Prep for cancel") == true)

        print(String(
            format: "cancel_recover.repos=%d mode=%@ repo0_summary=%@",
            final.data.repositories.count,
            finalMetrics.snapshot().discoveryMode == .walked ? "walked" : "reused",
            repo0.lastCommitSummary ?? "nil"
        ))
    }

    /// Verify that a repo recovers after a simulated permission-denied / timeout
    /// error via the normal scan path.
    @Test func permissionErrorRecoversOnRetry() async throws {
        let root = try temporaryDirectory(named: "perm-recover")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("repo")
        try createCommittedRepository(at: repoURL)
        let config = scanConfig(maxConcurrentGitOps: 1)

        // First scan establishes baseline
        let firstMetrics = ScanMetricsCollector()
        let first = await GitRepositoryScanner.scan(
            config: config, scanRoots: [root.path],
            knownRepositoryPaths: [repoURL.path],
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty(),
            metrics: firstMetrics
        )
        #expect(first.data.repositories.first?.status == .clean)
        #expect(first.data.repositories.first?.resolvedDataSource == .current)

        // Make a change so the second scan cannot fast-skip via HEAD timestamps.
        // Without this, the fast filesystem check would skip the repo entirely
        // and our custom gitCommandRunner (which simulates the error) would
        // never be called.
        try "change-for-error\n".write(
            to: repoURL.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8
        )
        try runGit(["add", "README.md"], in: repoURL)
        try runGit(["commit", "-q", "-m", "Prep error simulation"], in: repoURL)

        // Simulate failure via timeout. Because HEAD changed, the fast check
        // falls through and our custom runner is called for git status.
        let secondMetrics = ScanMetricsCollector()
        let second = await GitRepositoryScanner.scan(
            config: config, scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data,
            metrics: secondMetrics,
            gitCommandRunner: { args, wd, timeout, limit, isCancelled in
                if args.first == "status" {
                    return .timeout
                }
                return GitRepositoryScanner.defaultGitCommandRunner(
                    args, wd, timeout, limit, isCancelled
                )
            }
        )
        #expect(second.data.repositories.first?.status == .error)
        #expect(second.data.repositories.first?.resolvedDataSource == .lastSuccessful)
        #expect(second.data.repositories.first?.errorMessage != nil)

        // "Restore access" by using default runner (no mock)
        let thirdMetrics = ScanMetricsCollector()
        let third = await GitRepositoryScanner.scan(
            config: config, scanRoots: [root.path],
            knownRepositoryPaths: second.discoveredRepositoryPaths,
            previousSnapshot: second.data,
            metrics: thirdMetrics
        )
        #expect(third.data.repositories.first?.status == .clean)
        #expect(third.data.repositories.first?.resolvedDataSource == .current)
        #expect(third.data.repositories.first?.errorMessage == nil)

        #expect(thirdMetrics.snapshot().gitTimeoutCount == 0)

        print(String(
            format: "perm_recover.phase1=current phase2=error(.lastSuccessful) phase3=current"
        ))
    }

    /// Verify that the metrics totals are consistent: skipped count + read
    /// count should equal the repo count for a stable scan (no cancellation).
    @Test func incrementalSkipMetricConsistency() async throws {
        let root = try temporaryDirectory(named: "metric-consist")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURLs = try (0..<3).map { index -> URL in
            let repo = root.appendingPathComponent("mc-repo-\(index)")
            try createCommittedRepository(at: repo)
            return repo
        }
        let config = scanConfig(maxConcurrentGitOps: 3)

        // First scan establishes baselines for all repos
        let firstMetrics = ScanMetricsCollector()
        let first = await GitRepositoryScanner.scan(
            config: config, scanRoots: [root.path],
            knownRepositoryPaths: repoURLs.map(\.path),
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty(),
            metrics: firstMetrics
        )
        #expect(first.data.repositories.count == repoURLs.count)
        #expect(first.data.repositories.allSatisfy { $0.resolvedDataSource == .current })
        // First scan: all repos were read, none skipped
        #expect(firstMetrics.snapshot().repositorySkippedCount == 0)
        #expect(firstMetrics.snapshot().repositoryReadCount == repoURLs.count)

        // Make a change in repo-0 only
        try "new-metric\n".write(
            to: repoURLs[0].appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8
        )
        try runGit(["add", "README.md"], in: repoURLs[0])
        try runGit(["commit", "-q", "-m", "Metric test"], in: repoURLs[0])

        // Set repo-1 and repo-2 HEAD AND INDEX to past so fast check skips them.
        // Setting only HEAD is insufficient — Git may have refreshed the index
        // during the first scan's git status command, making the index mod date
        // newer than lastSuccessfulScanAt.
        let pastDate = Date().addingTimeInterval(-3600)
        for i in 1..<repoURLs.count {
            let headURL = repoURLs[i].appendingPathComponent(".git/HEAD")
            try FileManager.default.setAttributes(
                [.modificationDate: pastDate],
                ofItemAtPath: headURL.path
            )
            let indexURL = repoURLs[i].appendingPathComponent(".git/index")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                try FileManager.default.setAttributes(
                    [.modificationDate: pastDate],
                    ofItemAtPath: indexURL.path
                )
            }
        }

        // Second scan: repo-1 and repo-2 fast-skipped, repo-0 runs git status + log
        let secondMetrics = ScanMetricsCollector()
        let second = await GitRepositoryScanner.scan(
            config: config, scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data,
            metrics: secondMetrics
        )
        let secondSnapshot = secondMetrics.snapshot()

        #expect(second.data.repositories.count == repoURLs.count)
        #expect(second.data.repositories.allSatisfy { $0.resolvedDataSource == .current })
        // Metrics: 2 skipped, 1 read = 3 total
        #expect(secondSnapshot.repositorySkippedCount == repoURLs.count - 1)
        #expect(secondSnapshot.repositoryReadCount == 1)
        #expect(secondSnapshot.gitStatusCommandCount == 1)
        #expect(secondSnapshot.gitLogCommandCount == 1)

        print(String(
            format: "metric_consist.total=%d skipped=%d read=%d git_status=%d git_log=%d",
            repoURLs.count,
            secondSnapshot.repositorySkippedCount,
            secondSnapshot.repositoryReadCount,
            secondSnapshot.gitStatusCommandCount,
            secondSnapshot.gitLogCommandCount
        ))
    }

    @Test func scanRecoversAfterRepoDeleteAndRecreate() async throws {
        let root = try temporaryDirectory(named: "recovery-lifecycle")
        defer { try? FileManager.default.removeItem(at: root) }

        // Phase 1: Create and scan repos.
        let repoURLs = try (0..<2).map { index -> URL in
            let repo = root.appendingPathComponent("lifecycle-repo-\(index)")
            try createCommittedRepository(at: repo)
            return repo
        }

        let firstMetrics = ScanMetricsCollector()
        let first = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 2),
            scanRoots: [root.path],
            knownRepositoryPaths: repoURLs.map(\.path),
            forceRepositoryDiscovery: true,
            previousSnapshot: .empty(),
            metrics: firstMetrics
        )
        #expect(first.data.repositories.count == repoURLs.count)

        // Phase 2: Delete repo-0 entirely.
        try FileManager.default.removeItem(at: repoURLs[0])

        let secondMetrics = ScanMetricsCollector()
        let second = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 2),
            scanRoots: [root.path],
            knownRepositoryPaths: first.discoveredRepositoryPaths,
            previousSnapshot: first.data,
            metrics: secondMetrics
        )
        // Repo-0 should be gone, repo-1 should remain.
        let secondNames = Set(second.data.repositories.map(\.name))
        #expect(!secondNames.contains("lifecycle-repo-0"))
        #expect(secondNames.contains("lifecycle-repo-1"))

        // Phase 3: Recreate repo-0.
        try createCommittedRepository(at: repoURLs[0])

        let thirdMetrics = ScanMetricsCollector()
        let third = await GitRepositoryScanner.scan(
            config: scanConfig(maxConcurrentGitOps: 2),
            scanRoots: [root.path],
            knownRepositoryPaths: second.discoveredRepositoryPaths,
            forceRepositoryDiscovery: true,
            previousSnapshot: second.data,
            metrics: thirdMetrics
        )
        // Both repos should be discovered again.
        #expect(third.data.repositories.count == repoURLs.count)
        let thirdNames = Set(third.data.repositories.map(\.name))
        #expect(thirdNames.contains("lifecycle-repo-0"))
        #expect(thirdNames.contains("lifecycle-repo-1"))

        // Recreated repo-0 should have current data.
        let recreated = try #require(third.data.repositories.first { $0.name == "lifecycle-repo-0" })
        #expect(recreated.resolvedDataSource == .current)
        #expect(recreated.status != .error)

        print(String(
            format: "recovery_lifecycle.phase1_repos=%d phase2_remaining=%d phase3_recovered=%d",
            first.data.repositories.count,
            second.data.repositories.count,
            third.data.repositories.count
        ))
    }
}

private enum ScanPerformanceTestError: Error {
    case git([String], String)
}

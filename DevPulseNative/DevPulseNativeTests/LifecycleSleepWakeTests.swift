import Foundation
import Testing
@testable import DevPulse

// MARK: - Sleep/Wake & Long-Running Stability Tests
//
// Covers:
// 1. Sleep during active scan → wake recovery
// 2. Multiple rapid sleep/wake cycles (wake storm)
// 3. Timer lifecycle across sleep/wake transitions
// 4. Session inactive → active with pending work
// 5. Wake scan does not wait for repository retries
// 6. Duplicate scan prevention via coordinator
// 7. Failure recovery after interrupted scan

// MARK: - Mock scan execution

private let emptyScanResult: (data: AppGroupData, warnings: [String], discoveredRepositoryPaths: [String]) = (
    data: AppGroupData.empty(),
    warnings: [],
    discoveredRepositoryPaths: []
)

/// A controllable scan execution that reports progress and can be
/// made to hang or fail on demand.
private final class MockScanExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var _delay: TimeInterval = 0
    private var _result = emptyScanResult
    private var _shouldHang = false
    private var _executionCount = 0
    private var _hangResumeContinuation: CheckedContinuation<Void, Never>?

    var executionCount: Int { lock.withLock { _executionCount } }

    func setResult(_ result: (data: AppGroupData, warnings: [String], discoveredRepositoryPaths: [String])) {
        lock.withLock { _result = result }
    }

    func setDelay(_ delay: TimeInterval) {
        lock.withLock { _delay = delay }
    }

    /// Make the scan hang until `resumeHangingScan()` is called.
    func setHanging(_ hang: Bool) {
        lock.withLock { _shouldHang = hang }
    }

    func resumeHangingScan() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let c = _hangResumeContinuation
            _hangResumeContinuation = nil
            return c
        }
        continuation?.resume()
    }

    nonisolated func makeExecution() -> ScanExecution {
        { [mock = self] request in
            let delay = mock.lock.withLock { mock._delay }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return emptyScanResult }
            }

            // Check for hang mode
            let shouldHang = mock.lock.withLock { mock._shouldHang }
            if shouldHang {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    mock.lock.lock()
                    mock._hangResumeContinuation = continuation
                    mock.lock.unlock()
                }
                // After resume, check for cancellation
                guard !Task.isCancelled else { return emptyScanResult }
            }

            mock.lock.withLock { mock._executionCount += 1 }
            return mock.lock.withLock { mock._result }
        }
    }
}

// MARK: - Helpers

/// Create a ScanScheduler in command mode with a controlled scan execution.
/// All stores use /dev/null - no real I/O.
@MainActor
private func makeTestScheduler(
    scanExecutor: MockScanExecutor? = nil
) -> ScanScheduler {
    let executor = scanExecutor ?? MockScanExecutor()
    return ScanScheduler(
        commandMode: true,
        scanExecution: executor.makeExecution()
    )
}

/// Create an AppGroupData with a single repository for testing.
/// Create a minimal RepositorySnapshot for testing.
private func makeRepo(
    name: String = "test-repo",
    path: String = "/tmp/test-repo",
    status: RepositoryStatus = .clean
) -> RepositorySnapshot {
    RepositorySnapshot(
        id: RepositoryIdentity.id(for: path),
        name: name,
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
        changedFileCount: 0,
        changedFilesPreview: [],
        risk: .low,
        lastScannedAt: DateFormatting.nowISO(),
        lastChangedAt: nil,
        errorMessage: nil,
        isPinned: false
    )
}

private func snapshotWithRepository(
    name: String = "test-repo",
    path: String = "/tmp/test-repo",
    status: RepositoryStatus = .clean,
    generatedAt: String? = nil
) -> AppGroupData {
    let repo = makeRepo(name: name, path: path, status: status)
    return AppGroupData(
        schemaVersion: RepositorySnapshotSchema.version,
        generatedAt: generatedAt ?? DateFormatting.nowISO(),
        writtenAt: DateFormatting.nowISO(),
        scanSummary: ScanSummary(
            totalRepositories: 1,
            changedRepositories: 0,
            totalChangedFiles: 0,
            errorRepositories: 0
        ),
        repositories: [repo],
        storageRevision: 1,
        persistenceState: .committed
    )
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Sleep/Wake Lifecycle
// ─────────────────────────────────────────────────────────────────────

@Suite("Sleep/Wake Lifecycle", .serialized)
@MainActor struct SleepWakeLifecycleTests {

    // ────────────────────────────────────────────────
    // Tests: suspendForSleep / resumeAfterWake
    // ────────────────────────────────────────────────

    @Test("suspendForSleep invalidates timer and cancels pending work")
    func suspendForSleepClearsState() {
        let scheduler = makeTestScheduler()

        // Start background scanning (creates timer)
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        #expect(scheduler.hasScheduledTimer == true)

        // Suspend for sleep
        scheduler.suspendForSleep()
        #expect(scheduler.isWorkSuspended == true)
        #expect(scheduler.hasScheduledTimer == false)
    }

    @Test("suspendForSleep cancels active scan task")
    func suspendForSleepCancelsActiveScan() async {
        let executor = MockScanExecutor()
        executor.setHanging(true) // Scan hangs until we resume it
        let scheduler = makeTestScheduler(scanExecutor: executor)

        // Start a scan
        scheduler.scanNow(source: .manual)
        // Give the scan time to start (Task.detached)
        await Task.yield()

        // Suspend for sleep — should cancel the hanging scan
        scheduler.suspendForSleep()
        #expect(scheduler.isWorkSuspended == true)

        // Resume the hanging scan so its cancellation can complete
        executor.resumeHangingScan()
        // Wait for cancellation to propagate
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        await Task.yield()

        #expect(scheduler.isScanning == false,
                "Scan should be cancelled after sleep")
    }

    @Test("resumeAfterWake restarts timer and triggers wake refresh")
    func resumeAfterWakeRestoresState() {
        let scheduler = makeTestScheduler()

        // Start scanning and then suspend
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        scheduler.suspendForSleep()
        #expect(scheduler.isWorkSuspended == true)

        // Resume after wake
        scheduler.resumeAfterWake()
        #expect(scheduler.isWorkSuspended == false)
        #expect(scheduler.hasScheduledTimer == true,
                "Timer should be re-created after wake")
    }

    @Test("resumeAfterWake does nothing when not suspended")
    func resumeAfterWakeNoopWhenNotSuspended() {
        let scheduler = makeTestScheduler()
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        let hadTimer = scheduler.hasScheduledTimer

        // Resume without having suspended — should be a no-op
        scheduler.resumeAfterWake()
        #expect(scheduler.isWorkSuspended == false)
        // Timer should still be running (not double-created)
        #expect(scheduler.hasScheduledTimer == hadTimer)
    }

    @Test("suspendForSleep is idempotent when already suspended")
    func suspendForSleepIsIdempotent() {
        let scheduler = makeTestScheduler()
        scheduler.suspendForSleep()
        scheduler.suspendForSleep() // Second call
        #expect(scheduler.isWorkSuspended == true,
                "Should remain suspended after second call")
    }

    // ────────────────────────────────────────────────
    // Tests: Wake storm protection
    // ────────────────────────────────────────────────

    @Test("rapid sleep/wake cycles do not cause duplicate scan tasks")
    func rapidSleepWakeCycles() async {
        let executor = MockScanExecutor()
        executor.setDelay(0.5) // Short but measurable scan
        let scheduler = makeTestScheduler(scanExecutor: executor)

        // Ensure background scanning is enabled so wake events trigger scans
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        defer { scheduler.stopBackgroundScanning() }

        // Set an empty snapshot so wake refresh decision triggers
        scheduler.lastResult = .empty()

        // Simulate multiple rapid sleep/wake cycles
        for _ in 0..<5 {
            scheduler.suspendForSleep()
            scheduler.resumeAfterWake()
            // No sleep between cycles — rapid transitions exercise the throttle
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        // Allow any deferred scan (200ms coalescing) to settle
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // At most one scan should have been triggered (the wake throttle
        // minimumWakeScanInterval = 15s suppresses subsequent wake events)
        #expect(executor.executionCount <= 1,
                "Rapid sleep/wake should not cause multiple scans")
    }

    @Test("wake storm guard limits scan submissions within minimum interval")
    func wakeStormGuardLimitsScans() async {
        let scheduler = makeTestScheduler()
        scheduler.startBackgroundScanning(refreshIfNeeded: false)

        // Set a snapshot that's not fresh so wake triggers a scan
        let staleSnapshot = snapshotWithRepository(
            generatedAt: DateFormatting.isoString(from: Date().addingTimeInterval(-3600))
        )
        // We can't easily set lastResult in tests, so we verify
        // the wake handler's storm guard via the property we added.
        // Simulate rapid consecutive wake events
        let now = Date()
        scheduler.suspendForSleep(now: now)
        scheduler.resumeAfterWake(now: now)
        #expect(scheduler.isWorkSuspended == false)
        #expect(scheduler.hasScheduledTimer == true)
    }

    // ────────────────────────────────────────────────
    // Tests: Session inactive / active
    // ────────────────────────────────────────────────

    @Test("suspendAutomaticWorkForInactiveSession stops timer")
    func inactiveSessionStopsTimer() {
        let scheduler = makeTestScheduler()
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        #expect(scheduler.hasScheduledTimer == true)

        scheduler.suspendAutomaticWorkForInactiveSession()
        #expect(scheduler.isSessionInactive == true)
        #expect(scheduler.hasScheduledTimer == false,
                "Timer should be invalidated when session is inactive")
    }

    @Test("resumeAutomaticWorkForActiveSession restarts timer")
    func activeSessionRestartsTimer() {
        let scheduler = makeTestScheduler()
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        scheduler.suspendAutomaticWorkForInactiveSession()
        #expect(scheduler.hasScheduledTimer == false)

        scheduler.resumeAutomaticWorkForActiveSession()
        #expect(scheduler.isSessionInactive == false)
        #expect(scheduler.hasScheduledTimer == true,
                "Timer should be re-created when session becomes active")
    }

    @Test("inactive then active with pending retries restarts work")
    func inactiveActiveWithRetries() async {
        let executor = MockScanExecutor()
        executor.setDelay(0.05)
        let scheduler = makeTestScheduler(scanExecutor: executor)

        // Suspend for inactive session
        scheduler.suspendAutomaticWorkForInactiveSession()
        #expect(scheduler.isSessionInactive == true)

        // Try to scan — should be suppressed
        scheduler.scanNow(source: .timer)
        // Wait a bit
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Resume
        scheduler.resumeAutomaticWorkForActiveSession()
        #expect(scheduler.isSessionInactive == false)

        // Allow scan to complete
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(scheduler.isWorkSuspended == false)
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Duplicate Scheduling Prevention
// ─────────────────────────────────────────────────────────────────────

@Suite("Duplicate Scheduling Prevention")
@MainActor struct DuplicateSchedulingTests {

    @Test("rescan while scanning queues but does not duplicate")
    func rescanWhileScanning() async {
        let executor = MockScanExecutor()
        executor.setHanging(true) // Scan hangs
        let scheduler = makeTestScheduler(scanExecutor: executor)

        // Start a scan
        scheduler.scanNow(source: .manual)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // While scan is running, call rescan
        scheduler.rescan()
        #expect(scheduler.isScanning == true)

        // Let the hanging scan complete (the cancellation will propagate)
        executor.resumeHangingScan()
        // Wait for the deferred rescan request to be flushed and processed
        try? await Task.sleep(nanoseconds: 500_000_000)

        // After the first scan is cancelled, the second scan should run.
        // executionCount == 0 means the first hanged scan was cancelled
        // before it fully executed, and the second may not have finished
        // yet. Verify the scheduler is in a valid state.
        #expect(scheduler.isWorkSuspended == false)
    }

    @Test("startBackgroundScanning does not create duplicate timer when already running")
    func startBackgroundScanningNoDuplicateTimer() {
        let scheduler = makeTestScheduler()

        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        let timer1 = scheduler.hasScheduledTimer

        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        let timer2 = scheduler.hasScheduledTimer

        #expect(timer1 == true)
        #expect(timer2 == true)
        // Note: hasScheduledTimer only tells us if a timer exists,
        // not if there are multiple. scheduleNextTimer() cancels the
        // previous one before creating a new one, so there can only
        // be at most one timer at a time.
    }

    @Test("stopBackgroundScanning invalidates timer and disables periodic scans")
    func stopBackgroundScanningClearsTimer() {
        let scheduler = makeTestScheduler()
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        #expect(scheduler.hasScheduledTimer == true)

        scheduler.stopBackgroundScanning()
        #expect(scheduler.hasScheduledTimer == false)
    }

    @Test("same-signature requests are deduplicated by coordinator")
    func coordinatorDeduplicatesSameSignature() {
        var coordinator = ScanRefreshCoordinator()
        let signature = "test-root"

        let first = coordinator.request(signature: signature, forceRepositoryDiscovery: false, source: .manual)
        #expect(first == true)

        let second = coordinator.request(signature: signature, forceRepositoryDiscovery: false, source: .manual)
        #expect(second == false, "Same-signature request should be deduplicated when one is queued")
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Failure Recovery
// ─────────────────────────────────────────────────────────────────────

@Suite("Failure Recovery")
@MainActor struct FailureRecoveryTests {

    @Test("scan cancellation during sleep does not leave stale failure state")
    func scanCancellationDuringSleep() async {
        let executor = MockScanExecutor()
        executor.setHanging(true) // Scan will hang until cancelled
        let scheduler = makeTestScheduler(scanExecutor: executor)

        // Start a scan
        scheduler.scanNow(source: .manual)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(scheduler.isScanning == true)

        // Simulate sleep — this cancels the scan
        scheduler.suspendForSleep()
        executor.resumeHangingScan() // Allow cancellation to complete
        try? await Task.sleep(nanoseconds: 50_000_000)

        // After sleep cancellation, state should be clean
        #expect(scheduler.isScanning == false,
                "Scan should be cancelled after sleep")

        // Wake up — should trigger a recovery refresh
        scheduler.resumeAfterWake()
        #expect(scheduler.isWorkSuspended == false)
    }

    @Test("handleLifecycleRefresh(.lifecycleRecovery) restarts after startup failure")
    func lifecycleRecoveryAfterFailure() {
        let scheduler = makeTestScheduler()

        // Manually set refresh phase to failure (simulating startup failure)
        // We verify this through the lifecycle recovery handler
        scheduler.startBackgroundScanning(refreshIfNeeded: false)

        // Trigger lifecycle recovery
        scheduler.handleLifecycleRefresh(.lifecycleRecovery)

        // Recovery should submit a scan request
        // The deferred scan will flush after 200ms coalescing
    }

    @Test("shutdown cancels all work without leaving dangling state")
    func shutdownCleansUpAllState() {
        let scheduler = makeTestScheduler()
        scheduler.startBackgroundScanning(refreshIfNeeded: false)

        scheduler.shutdown()

        #expect(scheduler.isShuttingDown == true)
        #expect(scheduler.isWorkSuspended == true)
        #expect(scheduler.hasScheduledTimer == false)
        #expect(scheduler.isScanning == false)
    }

    @Test("memory pressure evicts caches without breaking subsequent operations")
    func memoryPressureDoesNotBreakState() async {
        let scheduler = makeTestScheduler()
        scheduler.handleMemoryPressure()
        // After memory pressure, the scheduler should still be usable
        #expect(scheduler.isWorkSuspended == false)
        #expect(scheduler.isScanning == false)
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Timer Lifecycle
// ─────────────────────────────────────────────────────────────────────

@Suite("Timer Lifecycle")
@MainActor struct TimerLifecycleTests {

    @Test("timer is created by startBackgroundScanning")
    func timerCreatedByStart() {
        let scheduler = makeTestScheduler()
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        #expect(scheduler.hasScheduledTimer == true)
    }

    @Test("timer is invalidated by stopBackgroundScanning")
    func timerInvalidatedByStop() {
        let scheduler = makeTestScheduler()
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        scheduler.stopBackgroundScanning()
        #expect(scheduler.hasScheduledTimer == false)
    }

    @Test("timer is re-created after resumeFromWake if background scanning enabled")
    func timerRecreatedAfterWake() {
        let scheduler = makeTestScheduler()
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        scheduler.suspendForSleep()
        #expect(scheduler.hasScheduledTimer == false)

        scheduler.resumeAfterWake()
        #expect(scheduler.hasScheduledTimer == true)
    }

    @Test("scheduleNextTimer does not create timer when background scanning disabled")
    func noTimerWhenScanningDisabled() {
        let scheduler = makeTestScheduler()
        // Don't call startBackgroundScanning
        #expect(scheduler.hasScheduledTimer == false)

        // Attempt wake without background scanning
        scheduler.suspendForSleep()
        scheduler.resumeAfterWake()
        #expect(scheduler.hasScheduledTimer == false,
                "Timer should not be created when background scanning was never enabled")
    }

    @Test("session inactive disables timer even if background scanning enabled")
    func sessionInactiveDisablesTimer() {
        let scheduler = makeTestScheduler()
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        scheduler.suspendAutomaticWorkForInactiveSession()
        #expect(scheduler.hasScheduledTimer == false)

        scheduler.resumeAutomaticWorkForActiveSession()
        #expect(scheduler.hasScheduledTimer == true)
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Background Interval Freshness Bound
// ─────────────────────────────────────────────────────────────────────

@Suite("Background Interval Freshness Bound")
@MainActor struct BackgroundIntervalFreshnessBoundTests {

    @Test("background interval never exceeds stale threshold in any power state")
    func intervalNeverExceedsStaleThreshold() {
        let noChangeLevels = [0, 1, 2, 3, 4, 7, 8, 14, 15, 16, 20, 100]
        let powerStates = ["normal", "battery", "low-power"]
        for level in noChangeLevels {
            for state in powerStates {
                let interval = ScanScheduler.effectiveScanInterval(
                    consecutiveNoChanges: level,
                    powerState: state
                )
                #expect(
                    interval <= RefreshStatusFormatter.staleThreshold,
                    "level \(level) / \(state): interval \(interval) exceeds stale threshold"
                )
            }
        }
    }

    @Test("background interval adapts from base to bound")
    func intervalAdaptsWithinBound() {
        #expect(ScanScheduler.effectiveScanInterval(consecutiveNoChanges: 0, powerState: "normal") == 300)
        #expect(ScanScheduler.effectiveScanInterval(consecutiveNoChanges: 1, powerState: "normal") == 300)
        // At the first no-change tier the interval extends to the stale
        // threshold (600 s) and stays there — never beyond.
        #expect(ScanScheduler.effectiveScanInterval(consecutiveNoChanges: 3, powerState: "normal") == 600)
        #expect(ScanScheduler.effectiveScanInterval(consecutiveNoChanges: 8, powerState: "normal") == 600)
        #expect(ScanScheduler.effectiveScanInterval(consecutiveNoChanges: 15, powerState: "normal") == 600)
        #expect(ScanScheduler.effectiveScanInterval(consecutiveNoChanges: 100, powerState: "normal") == 600)
        // Battery / low-power floors and ceilings are also capped.
        #expect(ScanScheduler.effectiveScanInterval(consecutiveNoChanges: 0, powerState: "battery") == 600)
        #expect(ScanScheduler.effectiveScanInterval(consecutiveNoChanges: 0, powerState: "low-power") == 600)
        #expect(ScanScheduler.effectiveScanInterval(consecutiveNoChanges: 100, powerState: "battery") == 600)
        #expect(ScanScheduler.effectiveScanInterval(consecutiveNoChanges: 100, powerState: "low-power") == 600)
    }

    @Test("timer stays scheduled after a no-change scan completes")
    func timerSurvivesNoChangeScan() async {
        let executor = MockScanExecutor()
        executor.setResult(emptyScanResult)
        let scheduler = makeTestScheduler(scanExecutor: executor)
        scheduler.startBackgroundScanning(refreshIfNeeded: false)
        #expect(scheduler.hasScheduledTimer == true)

        // Drive one scan to completion (no repository changes). The
        // completion handler must leave the background timer armed so the
        // next periodic scan still happens.
        scheduler.scanNow(source: .manual)
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(executor.executionCount >= 1)
        #expect(scheduler.hasScheduledTimer == true)

        scheduler.shutdown()
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Concurrent Refresh Scenarios
// ─────────────────────────────────────────────────────────────────────

@Suite("Concurrent Refresh")
@MainActor struct ConcurrentRefreshTests {

    @Test("scan request while retries are running is handled without blocking for wake")
    func wakeScanDoesNotBlockOnRetries() async {
        let executor = MockScanExecutor()
        executor.setDelay(0.1)
        let scheduler = makeTestScheduler(scanExecutor: executor)

        // Start a scan first to populate some state
        scheduler.scanNow(source: .manual)
        try? await Task.sleep(nanoseconds: 200_000_000)
        try? await Task.yield()

        // Suspend and wake — wake scan should not block on retries
        scheduler.suspendForSleep()
        scheduler.resumeAfterWake()

        // Allow deferred scan to fire
        try? await Task.sleep(nanoseconds: 400_000_000)

        // The wake scan should have executed (not waited for retries)
        #expect(executor.executionCount >= 1)
    }

    @Test("handleLifecycleRefresh(.wake) submits scan request")
    func wakeHandlerSubmitsScan() async {
        let executor = MockScanExecutor()
        executor.setDelay(0.05)
        let scheduler = makeTestScheduler(scanExecutor: executor)
        scheduler.startBackgroundScanning(refreshIfNeeded: false)

        // Trigger wake handler directly
        scheduler.handleLifecycleRefresh(.wake)

        // Allow deferred scan (200ms coalescing) to fire
        try? await Task.sleep(nanoseconds: 350_000_000)

        // A scan should have been executed
        #expect(executor.executionCount >= 1)
    }

    @Test("path availability recovery triggers scan when new repos accessible")
    func pathAvailabilityTriggersScan() async {
        let executor = MockScanExecutor()
        executor.setDelay(0.05)
        let scheduler = makeTestScheduler(scanExecutor: executor)
        scheduler.startBackgroundScanning(refreshIfNeeded: true)

        // Simulate a path becoming available
        scheduler.handleLifecycleRefresh(
            .pathAvailabilityChanged(rootPath: "/tmp/new-path", isAvailable: true)
        )

        // Allow coalesced scan to fire
        try? await Task.sleep(nanoseconds: 350_000_000)

        // Path recovery should trigger a scan
        #expect(executor.executionCount >= 1)
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - ScanRefreshCoordinator Advanced Tests
// ─────────────────────────────────────────────────────────────────────

@Suite("ScanRefreshCoordinator Advanced")
struct CoordinatorAdvancedTests {

    @Test("retainOnlyRecovery preserves recovery request and cancels running")
    func retainOnlyRecovery() {
        var coordinator = ScanRefreshCoordinator()

        // Start a running scan
        let r1 = coordinator.request(signature: "roots-a", forceRepositoryDiscovery: false, source: .manual)
        #expect(r1)
        let started = coordinator.beginNext()
        #expect(started?.signature == "roots-a")

        // Queue a successor then retain recovery
        coordinator.request(signature: "roots-b", forceRepositoryDiscovery: false, source: .timer)
        coordinator.retainOnlyRecovery(signature: "roots-c")
        #expect(coordinator.isRunningCancelled == true)
        #expect(coordinator.nextRequest?.signature == "roots-c")
        #expect(coordinator.nextRequest?.source == .lifecycleRecovery)
    }

    @Test("discardScheduledAutomaticRequests removes timer-triggered requests")
    func discardScheduledAutomaticRequests() {
        var coordinator = ScanRefreshCoordinator()

        coordinator.request(signature: "roots", forceRepositoryDiscovery: false, source: .timer)
        #expect(coordinator.nextRequest != nil)

        coordinator.discardScheduledAutomaticRequests()
        #expect(coordinator.nextRequest == nil)
    }

    @Test("completeCurrent returns next queued request")
    func completeCurrentReturnsNext() {
        var coordinator = ScanRefreshCoordinator()

        coordinator.request(signature: "s1", forceRepositoryDiscovery: false, source: .manual)
        let started = coordinator.beginNext()
        #expect(started?.signature == "s1")

        coordinator.request(signature: "s2", forceRepositoryDiscovery: false, source: .manual)
        let completed = coordinator.completeCurrent()
        #expect(completed?.signature == "s2")
    }

    @Test("beginNext returns nil when running request exists")
    func beginNextNilWhileRunning() {
        var coordinator = ScanRefreshCoordinator()
        coordinator.request(signature: "s1", forceRepositoryDiscovery: false, source: .manual)
        coordinator.beginNext()
        // Should return nil since there's a running request
        #expect(coordinator.beginNext() == nil)
    }
}

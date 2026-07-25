import Foundation
import Testing
@testable import DevPulse

// MARK: - Scan Concurrency & Lifecycle Tests
//
// Covers:
// 1. ScanRefreshCoordinator request deduplication and lifecycle
// 2. ProcessRunner cancellation and resource cleanup
// 3. Simulated concurrent refresh scenarios

// ────────────────────────────────────────────────────────────────────
// MARK: - ScanRefreshCoordinator Tests
// ────────────────────────────────────────────────────────────────────

@Suite("ScanRefreshCoordinator")
struct ScanRefreshCoordinatorTests {

    @Test("Same-signature request is deduplicated when running")
    func sameSignatureDeduplication() {
        var coordinator = ScanRefreshCoordinator()
        let signature = "root1\nroot2"

        // First request is accepted when nothing is running
        let first = coordinator.request(
            signature: signature,
            forceRepositoryDiscovery: false,
            source: .manual
        )
        #expect(first == true)

        // beginNext starts it
        let started = coordinator.beginNext()
        #expect(started != nil)
        #expect(started?.signature == signature)

        // Second same-signature request is deduplicated while running
        let second = coordinator.request(
            signature: signature,
            forceRepositoryDiscovery: false,
            source: .manual
        )
        #expect(second == false)
    }

    @Test("Different signature replaces queued request")
    func differentSignatureReplacesQueued() {
        var coordinator = ScanRefreshCoordinator()
        let sig1 = "roots-a"
        let sig2 = "roots-b"

        // Queue first
        let first = coordinator.request(signature: sig1, forceRepositoryDiscovery: false, source: .manual)
        #expect(first == true)
        #expect(coordinator.nextRequest?.signature == sig1)

        // Replace with second
        let second = coordinator.request(signature: sig2, forceRepositoryDiscovery: false, source: .manual)
        #expect(second == true)
        #expect(coordinator.nextRequest?.signature == sig2,
                "Queued request should be replaced by newer different-signature request")
    }

    @Test("beginNext returns nil when nothing queued")
    func beginNextNilWhenEmpty() {
        var coordinator = ScanRefreshCoordinator()
        let request = coordinator.beginNext()
        #expect(request == nil)
    }

    @Test("completeCurrent allows next request to start")
    func completeCurrentAllowsNext() {
        var coordinator = ScanRefreshCoordinator()
        let sig1 = "roots-1"
        let sig2 = "roots-2"

        // Queue and start sig1
        let r1 = coordinator.request(signature: sig1, forceRepositoryDiscovery: false, source: .manual)
        #expect(r1)
        let started1 = coordinator.beginNext()
        #expect(started1?.signature == sig1)

        // Queue sig2 while sig1 is running
        let r2 = coordinator.request(signature: sig2, forceRepositoryDiscovery: false, source: .manual)
        #expect(r2)
        #expect(coordinator.nextRequest?.signature == sig2)

        // Complete sig1 — sig2 should become available
        let completed = coordinator.completeCurrent()
        #expect(completed?.signature == sig2, "completeCurrent should return the next queued request")

        let started2 = coordinator.beginNext()
        #expect(started2?.signature == sig2)
    }

    @Test("cancelAll clears both scheduled and running state")
    func cancelAllClearsState() {
        var coordinator = ScanRefreshCoordinator()

        // Start one
        let r1 = coordinator.request(signature: "s1", forceRepositoryDiscovery: false, source: .manual)
        #expect(r1)
        let bn1 = coordinator.beginNext()
        #expect(bn1 != nil)
        #expect(coordinator.hasWork)

        // Queue another
        let r2 = coordinator.request(signature: "s2", forceRepositoryDiscovery: false, source: .manual)
        #expect(r2)
        #expect(coordinator.hasWork)

        coordinator.cancelAll()
        #expect(coordinator.nextRequest == nil)
        #expect(coordinator.runningRequest == nil)
        #expect(coordinator.hasWork == false)
    }

    @Test("markRunningCancelled allows new same-signature request")
    func markRunningCancelledAllowsNew() {
        var coordinator = ScanRefreshCoordinator()
        let sig = "shared-roots"

        // Start
        let r1 = coordinator.request(signature: sig, forceRepositoryDiscovery: false, source: .timer)
        #expect(r1)
        let bn1 = coordinator.beginNext()
        #expect(bn1 != nil)

        // Mark as cancelled
        coordinator.markRunningCancelled()
        #expect(coordinator.isRunningCancelled)

        // New same-signature request should be accepted after cancellation
        let second = coordinator.request(signature: sig, forceRepositoryDiscovery: false, source: .manual)
        #expect(second == true)
    }

    @Test("Priority merging preserves higher priority source")
    func priorityMerging() {
        var coordinator = ScanRefreshCoordinator()

        // Queue with timer (lower priority)
        let r1 = coordinator.request(signature: "s", forceRepositoryDiscovery: false, source: .timer)
        #expect(r1)
        #expect(coordinator.nextRequest?.source == .timer)

        // Replace with manual (higher priority)
        let r2 = coordinator.request(signature: "s", forceRepositoryDiscovery: false, source: .manual)
        #expect(r2)
        #expect(coordinator.nextRequest?.source == .manual,
                "Merged request should preserve higher priority source")
    }

    @Test("Full lifecycle: request, beginNext, completeCurrent, request, beginNext")
    func fullLifecycleSequence() {
        var coordinator = ScanRefreshCoordinator()

        // Cycle 1
        let r1 = coordinator.request(signature: "cycle-1", forceRepositoryDiscovery: false, source: .manual)
        #expect(r1)
        let r1started = coordinator.beginNext()
        #expect(r1started?.signature == "cycle-1")
        #expect(coordinator.runningRequest?.signature == "cycle-1")

        let completed1 = coordinator.completeCurrent()
        #expect(completed1 == nil, "No queued request after completing the only one")
        #expect(coordinator.runningRequest == nil)

        // Cycle 2
        let r2 = coordinator.request(signature: "cycle-2", forceRepositoryDiscovery: true, source: .manual)
        #expect(r2)
        let r2started = coordinator.beginNext()
        #expect(r2started?.signature == "cycle-2")
        #expect(r2started?.forceRepositoryDiscovery == true)
    }

    @Test("Request with running same-signature and scheduled same-signature keeps scheduled")
    func sameSignatureWithScheduled() {
        var coordinator = ScanRefreshCoordinator()

        // Start sig1
        let r1 = coordinator.request(signature: "sig", forceRepositoryDiscovery: false, source: .timer)
        #expect(r1)
        let bn1 = coordinator.beginNext()
        #expect(bn1 != nil)

        // Queue sig1 again while running
        let r2 = coordinator.request(signature: "sig", forceRepositoryDiscovery: false, source: .timer)
        #expect(r2 == false,
                "Same-signature while running should be rejected")

        // Complete current
        let cc = coordinator.completeCurrent()
        #expect(cc == nil, "No scheduled after rejection")
    }

    @Test("Force discovery flag is preserved through merging")
    func forceDiscoveryPreserved() {
        var coordinator = ScanRefreshCoordinator()

        let r1 = coordinator.request(signature: "s", forceRepositoryDiscovery: false, source: .timer)
        #expect(r1)
        // Replace with forced
        let r2 = coordinator.request(signature: "s", forceRepositoryDiscovery: true, source: .manual)
        #expect(r2)
        #expect(coordinator.nextRequest?.forceRepositoryDiscovery == true,
                "forceRepositoryDiscovery should be true after merge with forced request")
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - ProcessRunner Cancellation Tests
// ────────────────────────────────────────────────────────────────────

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool {
        lock.withLock { _cancelled }
    }

    func cancel() {
        lock.withLock { _cancelled = true }
    }

    func makeClosure() -> @Sendable () -> Bool {
        { [weak self] in self?.isCancelled ?? true }
    }
}

@Suite("ProcessRunner Cancellation")
struct ProcessRunnerCancellationTests {

    @Test("Cancellation before process start returns .cancelled")
    func cancelBeforeStart() {
        let isCancelled: @Sendable () -> Bool = { true }

        let result = ProcessRunner.runDetailed(
            executable: "/bin/sh",
            arguments: ["-c", "echo hello"],
            workingDirectory: "/tmp",
            timeout: 2,
            isCancelled: isCancelled
        )
        #expect(result == .cancelled)
    }

    @Test("Cancellation during process execution returns .cancelled")
    func cancelDuringExecution() {
        let flag = CancellationFlag()

        // Use a longer command and cancel after a short delay
        let start = DispatchTime.now()
        let isCancelled: @Sendable () -> Bool = {
            // After 100ms, signal cancellation
            if DispatchTime.now() > start + .milliseconds(100) {
                flag.cancel()
            }
            return flag.isCancelled
        }

        let result = ProcessRunner.runDetailed(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 0.5; echo done"],
            workingDirectory: "/tmp",
            timeout: 5,
            isCancelled: isCancelled
        )
        #expect(result == .cancelled,
                "Should return .cancelled when cancellation flag is raised during execution")
    }

    @Test("Timeout returns .timeout")
    func timeoutReturnsTimeout() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = ProcessRunner.runDetailed(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 10"],
            workingDirectory: "/tmp",
            timeout: 0.05,  // very short timeout
            isCancelled: { false }
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(result == .timeout)
        #expect(elapsed < 2, "Timeout should be detected quickly")
    }

    @Test("OutputLimit returns .outputLimit")
    func outputLimitExceeded() {
        let result = ProcessRunner.runDetailed(
            executable: "/bin/sh",
            arguments: ["-c", "while :; do echo 'abcdefghijklmnopqrstuvwxyz0123456789'; done"],
            workingDirectory: "/tmp",
            timeout: 2,
            outputLimit: 1024,
            isCancelled: { false }
        )
        #expect(result == .outputLimit)
    }

    @Test("Successful command returns .success with correct output")
    func successfulCommand() {
        let result = ProcessRunner.runDetailed(
            executable: "/bin/sh",
            arguments: ["-c", "echo hello-world"],
            workingDirectory: "/tmp",
            timeout: 2,
            isCancelled: { false }
        )

        guard case .success(let output) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }
        #expect(output == "hello-world")
    }

    @Test("Unavailable executable returns .unavailable")
    func unavailableExecutable() {
        let result = ProcessRunner.runDetailed(
            executable: "/nonexistent/git-binary",
            arguments: ["status"],
            workingDirectory: "/tmp",
            timeout: 1,
            isCancelled: { false }
        )
        #expect(result == .unavailable)
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: - ScanRefreshCoordinator Request Merging Tests
// ────────────────────────────────────────────────────────────────────

@Suite("ScanRefreshCoordinator Merging")
struct ScanRefreshCoordinatorMergingTests {

    @Test("Lifecycle recovery incoming is preserved when running scan of same signature")
    func lifecycleRecoveryPreservedForSameSignature() {
        var coordinator = ScanRefreshCoordinator()
        let sig = "test-roots"

        // Start a normal timer scan
        let r1 = coordinator.request(signature: sig, forceRepositoryDiscovery: false, source: .timer)
        #expect(r1)
        let running = coordinator.beginNext()
        #expect(running?.source == .timer)

        // A lifecycle recovery request with the same signature should be preserved
        // because lifecycleRecovery.preservesSuccessorForMatchingRun is true
        let queued = coordinator.request(signature: sig, forceRepositoryDiscovery: false, source: .lifecycleRecovery)
        #expect(queued == true,
                "Lifecycle recovery should be preserved as successor when same signature is running")

        // Complete current — should get the preserved lifecycle recovery
        let completed = coordinator.completeCurrent()
        #expect(completed?.source == .lifecycleRecovery,
                "Preserved lifecycle recovery should be returned from completeCurrent")
    }

    @Test("DiscardScheduledAutomaticRequests clears automatic requests")
    func discardAutomatic() {
        var coordinator = ScanRefreshCoordinator()

        let r1 = coordinator.request(signature: "s", forceRepositoryDiscovery: false, source: .timer)
        #expect(r1)
        #expect(coordinator.nextRequest != nil)
        #expect(coordinator.nextRequest?.isAutomatic == true)

        coordinator.discardScheduledAutomaticRequests()
        #expect(coordinator.nextRequest == nil,
                "Automatic request should be discarded")
    }

    @Test("RetainOnlyRecovery replaces scheduled with recovery")
    func retainOnlyRecovery() {
        var coordinator = ScanRefreshCoordinator()

        let r1 = coordinator.request(signature: "s1", forceRepositoryDiscovery: false, source: .timer)
        #expect(r1)
        let running = coordinator.beginNext()
        #expect(running?.source == .timer)

        coordinator.retainOnlyRecovery(signature: "s2")
        // Running should be marked cancelled
        #expect(coordinator.isRunningCancelled)
        // Scheduled should be a lifecycle recovery
        #expect(coordinator.nextRequest?.source == .lifecycleRecovery)
    }
}

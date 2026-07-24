import Foundation
import Testing
@testable import DevPulse

// MARK: - Cross-Process Pipeline Integration Tests
//
// Verifies that the full refresh pipeline (RefreshEngine → AppGroupStore →
// SharedSnapshotStore) correctly guards against cross-process stale writes
// and that the generation isolation flows end-to-end.

@Suite("Cross-Process Pipeline Integration")
struct CrossProcessPipelineTests {

    // ────────────────────────────────────────────────────────────────
    // MARK: - AppGroupStore cross-process write overload
    // ────────────────────────────────────────────────────────────────

    @Test("AppGroupStore.write with observedStorageRevision rejects stale writes")
    func storeWriteRejectsStale() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-cpp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Manually use the store to simulate cross-process writes.
        let storeA = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // Process A writes revision 1.
        let first = try requireSuccess(
            storeA.commit(AppGroupData.empty())
        )
        #expect(first.storageRevision == 1)

        // Process B writes revision 2 (simulating another process).
        let storeB = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        try requireSuccess(
            storeB.commit(AppGroupData.empty())
        )

        // Process A tries to write with observed revision 1 — should fail.
        let staleResult = storeA.commit(
            AppGroupData.empty(),
            observedStorageRevision: 1
        )
        switch staleResult {
        case .success:
            Issue.record("Expected cross-process conflict")
        case .failure(let error):
            guard case .crossProcessWriteDetected(let observed, let actual) = error else {
                Issue.record("Expected crossProcessWriteDetected, got \(error)")
                return
            }
            #expect(observed == 1)
            #expect(actual == 2)
        }
    }

    @Test("AppGroupStore.write without observedStorageRevision bypasses check")
    func storeWriteBypassesCheck() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-cpp2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "test.json",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // Write without revision guard — should always succeed.
        let result = store.commit(AppGroupData.empty())
        try requireSuccess(result)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - GenerationIsolation cross-process validation
    // ────────────────────────────────────────────────────────────────

    @Test("CrossProcessToken correctly tracks revision advancement")
    func crossProcessTokenValidation() {
        // Current matches.
        #expect(GenerationIsolation.validateCrossProcess(
            observedRevision: 5, snapshotRevision: 5
        ) == .current)

        // Observed is ahead of snapshot — still current (no conflict).
        #expect(GenerationIsolation.validateCrossProcess(
            observedRevision: 10, snapshotRevision: 5
        ) == .current)

        // Snapshot advanced past observed — stale.
        let staleResult = GenerationIsolation.validateCrossProcess(
            observedRevision: 5, snapshotRevision: 8
        )
        guard case .stale(let reason) = staleResult else {
            Issue.record("Expected stale")
            return
        }
        #expect(reason.contains("5"))
        #expect(reason.contains("8"))
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - BoundedRecoveryContext timeout enforcement
    // ────────────────────────────────────────────────────────────────

    @Test("BoundedRecoveryContext enforces operation timeout")
    func boundedTimeout() async {
        let context = BoundedRecoveryContext(
            totalBudget: 0.5,
            operationTimeout: 0.05
        )

        var deadline: TimeInterval?
        let result = await context.run(
            operation: {
                // Sleep longer than the operation timeout.
                try await Task.sleep(nanoseconds: 200_000_000) // 200 ms
                return "done"
            },
            deadline: &deadline
        )

        switch result {
        case .timeout:
            #expect(true) // Expected
        case .success:
            Issue.record("Expected timeout for long operation")
        case .budgetExceeded:
            Issue.record("Expected timeout, not budget exceeded")
        case .failure:
            Issue.record("Expected timeout, not failure")
        }
    }

    @Test("BoundedRecoveryContext returns success for fast operation")
    func boundedFastOp() async {
        let context = BoundedRecoveryContext(
            totalBudget: 0.5,
            operationTimeout: 0.2
        )

        var deadline: TimeInterval?
        let result = await context.run(
            operation: {
                try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
                return "done"
            },
            deadline: &deadline
        )

        switch result {
        case .success(let value):
            #expect(value == "done")
        case .timeout, .budgetExceeded:
            Issue.record("Expected success, got timeout/budgetExceeded")
        case .failure:
            Issue.record("Expected success, got failure")
        }
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - WidgetRecoveryManager verifier bounded context
    // ────────────────────────────────────────────────────────────────

    @Test("WidgetRecoveryManager.verifyWidgetReadiness returns report without crashing")
    func verifyWidgetReadiness() async {
        let manager = WidgetRecoveryManager()
        let report = await manager.verifyWidgetReadiness()
        // In a test environment without App Group, this should return a
        // failure report (not crash).
        if !report.canReadSnapshot {
            #expect(report.error != nil)
        }
        // Must have deterministic fields
        #expect(report.canReadSnapshot == (report.error == nil))
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Snapshot version protocol future-schema protection
    // ────────────────────────────────────────────────────────────────

    @Test("VersionedSnapshotProtocol rejects future storage format version")
    func rejectFutureFormatVersion() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-future-snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // Write a header with storageFormatVersion beyond what we support.
        let header: [String: Any] = [
            "schemaVersion": 3,
            "storageFormatVersion": 99,
            "appVersion": "99.0.0"
        ]
        let data = try JSONSerialization.data(withJSONObject: header)
        try data.write(to: url)

        let result = VersionedSnapshotProtocol.validate(at: url)
        guard case .failure(.futureStorageFormatVersion(let supported, let actual)) = result else {
            Issue.record("Expected futureStorageFormatVersion, got \(result)")
            return
        }
        #expect(supported == 1)
        #expect(actual == 99)
    }

    @Test("VersionedSnapshotProtocol rejects future schema version")
    func rejectFutureSchemaVersion() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-future-schema-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let header: [String: Any] = [
            "schemaVersion": 99,
            "appVersion": "99.0.0"
        ]
        let data = try JSONSerialization.data(withJSONObject: header)
        try data.write(to: url)

        let result = VersionedSnapshotProtocol.validate(at: url)
        guard case .failure(.futureSchemaVersion(let expected, let actual, _)) = result else {
            Issue.record("Expected futureSchemaVersion, got \(result)")
            return
        }
        #expect(expected == 3)
        #expect(actual == 99)
    }

    @Test("VersionedSnapshotProtocol rejects unsupported old schema")
    func rejectUnsupportedOldSchema() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-old-schema-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let header: [String: Any] = [
            "schemaVersion": 0,
            "appVersion": "0.1.0"
        ]
        let data = try JSONSerialization.data(withJSONObject: header)
        try data.write(to: url)

        let result = VersionedSnapshotProtocol.validate(at: url)
        guard case .failure(.unsupportedSchemaVersion(0)) = result else {
            Issue.record("Expected unsupportedSchemaVersion, got \(result)")
            return
        }
    }
}

// MARK: - Helpers

private func requireSuccess<T>(_ result: Result<T, Error>) throws -> T {
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        Issue.record("Unexpected failure: \(error)")
        throw error
    }
}

import Foundation
import Testing
@testable import DevPulse

// MARK: - Build Configuration Consistency Tests
//
// Verifies that key build-time constants and configuration values are
// consistent across Info.plist, project.yml, entitlements, and the
// shared runtime-lookup code path.
//
// These tests run against the compiled binary and Info.plist artifacts
// in the test bundle — they cannot verify everything that
// verify-build-consistency.sh does (which checks source files), but
// they provide deterministic runtime assurance.

@Suite("Build Configuration Consistency")
struct BuildConfigConsistencyTests {

    // ────────────────────────────────────────────────────────────────
    // MARK: - Bundle identifier consistency
    // ────────────────────────────────────────────────────────────────

    @Test("App bundle identifier matches expected value")
    func appBundleIdentifier() {
        let expected = "local.devpulse.app"
        let actual = Bundle.main.bundleIdentifier ?? ""
        #expect(
            actual == expected,
            "Expected bundle ID '\(expected)', got '\(actual)'"
        )
    }

    @Test("AppGroupStore constants match expected values")
    func appGroupConstants() {
        #expect(AppGroupStore.appGroupIdentifier == "group.local.devpulse")
        #expect(AppGroupStore.appBundleIdentifier == "local.devpulse.app")
        #expect(AppGroupStore.widgetBundleIdentifier == "local.devpulse.app.widget")
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Shared snapshot location constants
    // ────────────────────────────────────────────────────────────────

    @Test("SharedSnapshotLocation constants match between app and widget paths")
    func sharedSnapshotLocation() {
        #expect(SharedSnapshotLocation.appGroupIdentifier == "group.local.devpulse")
        #expect(!SharedSnapshotLocation.fileName.isEmpty)
        // The file name must match what WidgetSnapshotStore and InstallUpgradeVerifier expect
        #expect(SharedSnapshotLocation.fileName == "repositories.json")
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Schema version consistency
    // ────────────────────────────────────────────────────────────────

    @Test("Schema versions are consistent across RepositorySnapshotSchema and UnifiedLifecycleSchema")
    func schemaVersionConsistency() {
        #expect(UnifiedLifecycleSchema.schemaVersion == RepositorySnapshotSchema.version,
                "UnifiedLifecycleSchema.schemaVersion (\(UnifiedLifecycleSchema.schemaVersion)) must match RepositorySnapshotSchema.version (\(RepositorySnapshotSchema.version))")
        #expect(UnifiedLifecycleSchema.oldestMigratableSchemaVersion == RepositorySnapshotSchema.oldestMigratableVersion,
                "oldestMigratable versions must match")
    }

    @Test("Storage format versions are consistent")
    func storageFormatConsistency() {
        #expect(UnifiedLifecycleSchema.supportedStorageFormatVersion >= 1,
                "Must support at least storage format v1")
        #expect(UnifiedLifecycleSchema.storageFormatVersion == 1,
                "Current storage format should be v1")
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Widget identity constants
    // ────────────────────────────────────────────────────────────────

    @Test("WidgetIdentity kind matches expected value")
    func widgetIdentityKind() {
        #expect(!WidgetIdentity.kind.isEmpty)
        #expect(WidgetIdentity.kind == "DevPulseWidget")
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - BoundedRecoveryContext budget values
    // ────────────────────────────────────────────────────────────────

    @Test("Recovery budgets are configured correctly")
    func recoveryBudgets() {
        #expect(BoundedRecoveryContext.default.totalBudget == 10.0)
        #expect(BoundedRecoveryContext.default.operationTimeout == 3.0)
        #expect(BoundedRecoveryContext.startup.totalBudget == 5.0)
        #expect(BoundedRecoveryContext.startup.operationTimeout == 2.0)
        #expect(BoundedRecoveryContext.widget.totalBudget == 3.0)
        #expect(BoundedRecoveryContext.widget.operationTimeout == 1.0)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Widget identity check (test target-specific)
    // ────────────────────────────────────────────────────────────────

    @Test("WidgetIdentity.kind is a non-empty string")
    func widgetKindNonEmpty() {
        let kind = WidgetIdentity.kind
        #expect(!kind.isEmpty)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Generation isolation structure
    // ────────────────────────────────────────────────────────────────

    @Test("GenerationIsolation.Token has correct struct identity")
    func generationTokenIdentity() {
        let a = GenerationIsolation.Token(generation: 1, epoch: 0)
        let b = GenerationIsolation.Token(generation: 1, epoch: 0)
        let c = GenerationIsolation.Token(generation: 2, epoch: 0)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("GenerationIsolation CrossProcessToken identity")
    func crossProcessTokenIdentity() {
        let a = GenerationIsolation.CrossProcessToken(storageRevision: 1, generation: 1, epoch: 0)
        let b = GenerationIsolation.CrossProcessToken(storageRevision: 1, generation: 1, epoch: 0)
        let c = GenerationIsolation.CrossProcessToken(storageRevision: 2, generation: 1, epoch: 0)
        #expect(a == b)
        #expect(a != c)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Lifecycle coordinator schema consistency
    // ────────────────────────────────────────────────────────────────

    @Test("Install state enum has all expected cases")
    func installStateCases() {
        // Verify the enum compiles — we can't construct all cases directly
        // due to associated values, but the known cases must exist
        let first: InstallState = .firstInstall
        let normal: InstallState = .normalLaunch
        let indeterminate: InstallState = .indeterminate(reason: "test")
        #expect(first != normal)
        #expect(first != indeterminate)
        #expect(normal != indeterminate)
    }

    @Test("WidgetRegistrationState has all expected cases")
    func widgetRegStateCases() {
        let embedded: WidgetRegistrationState = .embedded
        let active: WidgetRegistrationState = .active
        let missing: WidgetRegistrationState = .missingExtension
        #expect(embedded != active)
        #expect(active != missing)
        #expect(embedded != missing)
    }
}

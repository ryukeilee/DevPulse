import Foundation
import Testing
@testable import DevPulse

@Suite(.serialized)
struct RepositoryDiscoveryExperienceTests {
    @MainActor
    @Test func legacyExplicitAllOffOverridesBuiltInDirectoryEntries() throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let keys = ["scan_config_json", "scan_directories_json", "scan_locations_v1_json"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.data(forKey: $0)) })
        defer { previous.forEach { restore($0.value, forKey: $0.key, in: defaults) } }
        keys.forEach(defaults.removeObject(forKey:))
        let root = try temporaryDirectory(named: "legacy-all-off")
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let builtIn = ScanLocationProvider.expandTilde("~/Developer")
        let config = ScanConfig(enabledBuiltInPaths: [], customPaths: [], maxDepth: ScanConfig.default.maxDepth, changedPreviewLimit: ScanConfig.default.changedPreviewLimit, maxConcurrentGitOps: ScanConfig.default.maxConcurrentGitOps, gitCommandTimeout: ScanConfig.default.gitCommandTimeout, scanTimeout: ScanConfig.default.scanTimeout, slowReposkipSeconds: ScanConfig.default.slowReposkipSeconds, activeRepoThreshold: ScanConfig.default.activeRepoThreshold)
        defaults.set(try JSONEncoder().encode(config), forKey: "scan_config_json")
        defaults.set(try JSONEncoder().encode([CustomScanDirectory(path: builtIn), CustomScanDirectory(path: custom.path, bookmarkData: Data([9]))]), forKey: "scan_directories_json")
        let scheduler = ScanScheduler()
        #expect(scheduler.scanLocationConfiguration.enabledBuiltInPaths.isEmpty)
        #expect(scheduler.scanDirectories.count == 1)
        #expect(scheduler.scanDirectories.first?.bookmarkData == Data([9]))
        let reloaded = ScanScheduler()
        #expect(reloaded.scanLocationConfiguration.enabledBuiltInPaths.isEmpty)
        #expect(reloaded.scanDirectories.count == 1)
    }
    @MainActor
    @Test func allDisabledLocationsExecuteEmptyRootsAndSurviveRebuild() async throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let key = "scan_locations_v1_json"
        let previous = defaults.data(forKey: key)
        defer { restore(previous, forKey: key, in: defaults) }
        defaults.set(try JSONEncoder().encode(ScanLocationConfiguration(enabledBuiltInPaths: [], customDirectories: [])), forKey: key)
        let recorder = ScanRequestRecorder()
        let scheduler = ScanScheduler { request in
            await recorder.record(request)
            return (.empty(), [], [])
        }
        defer { scheduler.stopBackgroundScanning() }
        scheduler.scanNow(forceRepositoryDiscovery: true)
        let requests = await recorder.waitForCount(1)
        #expect(requests.count == 1)
        #expect(requests[0].roots.isEmpty)
        #expect(requests[0].rootsSignature.isEmpty)
        #expect(requests[0].forceRepositoryDiscovery)
        let rebuilt = ScanScheduler(commandMode: false) { _ in (.empty(), [], []) }
        defer { rebuilt.stopBackgroundScanning() }
        #expect(rebuilt.scanLocationConfiguration.enabledBuiltInPaths.isEmpty)
        #expect(rebuilt.scanDirectories.isEmpty)
    }
    @MainActor
    @Test func matchingRebuiltSchedulerDoesNotRepeatStartupDiscovery() async throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let root = try temporaryDirectory(named: "startup-match")
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = ScanLocationProvider.canonicalExistingFilePath(root.path)
        let signature = ScanSchedulerPolicy.scanRootsSignature([canonical])
        let locationsKey = "scan_locations_v1_json"
        let discoveryKey = "last_repository_discovery_scan_roots"
        let oldLocations = defaults.data(forKey: locationsKey)
        let oldSignature = defaults.string(forKey: discoveryKey)
        let previousSnapshot = isolateSharedSnapshot()
        defer {
            restore(oldLocations, forKey: locationsKey, in: defaults)
            if let oldSignature { defaults.set(oldSignature, forKey: discoveryKey) } else { defaults.removeObject(forKey: discoveryKey) }
            restoreSharedSnapshot(previousSnapshot)
        }
        defaults.set(try JSONEncoder().encode(ScanLocationConfiguration(enabledBuiltInPaths: [], customDirectories: [CustomScanDirectory(path: canonical)])), forKey: locationsKey)
        defaults.set(signature, forKey: discoveryKey)
        let now = DateFormatting.nowISO()
        let snapshot = AppGroupData(schemaVersion: RepositorySnapshotSchema.version, generatedAt: now, writtenAt: now, lastSuccessfulRefreshAt: now, scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0), repositories: [RepositorySnapshot(id: "startup-match", name: "startup-match", path: canonical, branch: "main", status: .clean, modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0, untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: 0, conflictedFileCount: 0, aheadCount: 0, changedFileCount: 0, changedFilesPreview: [], risk: .low, lastScannedAt: now, lastChangedAt: nil, errorMessage: nil, isPinned: false)])
        _ = AppGroupStore.write(snapshot)
        let recorder = ScanRequestRecorder()
        let scheduler = ScanScheduler { request in
            await recorder.record(request)
            return (.empty(), [], [])
        }
        defer { scheduler.stopBackgroundScanning() }
        scheduler.startBackgroundScanning()
        #expect(!scheduler.isScanning)
        let count = await recorder.waitForCount(0).count
        #expect(count == 0)
    }
    @MainActor
    @Test func schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity() throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let pinnedKey = "pinned_repo_ids"
        let previousPinned = defaults.stringArray(forKey: pinnedKey)
        let previousSnapshot = isolateSharedSnapshot()
        defer {
            if let previousPinned {
                defaults.set(previousPinned, forKey: pinnedKey)
            } else {
                defaults.removeObject(forKey: pinnedKey)
            }
            restoreSharedSnapshot(previousSnapshot)
        }

        let root = try temporaryDirectory(named: "legacy-pin-rebuild")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = DateFormatting.nowISO()
        let legacySnapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: now,
            writtenAt: now,
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [RepositorySnapshot(
                id: "legacy-pin-id",
                name: "legacy-pin-repo",
                path: root.path,
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
                lastScannedAt: now,
                lastChangedAt: nil,
                errorMessage: nil,
                isPinned: false
            )]
        )
        _ = AppGroupStore.write(legacySnapshot)
        defaults.set(["legacy-pin-id", "legacy-unknown"], forKey: pinnedKey)

        let scheduler = ScanScheduler()
        defer { scheduler.stopBackgroundScanning() }
        let expectedID = RepositoryIdentity.id(for: root.path)
        let restored = try #require(scheduler.lastResult.repositories.first)

        #expect(restored.id == expectedID)
        #expect(restored.path == RepositoryIdentity.canonicalPath(root.path))
        #expect(restored.isPinned)
        #expect(scheduler.pinnedRepoIDs.contains(expectedID))
        #expect(scheduler.pinnedRepoIDs.contains("legacy-unknown"))
        #expect(!scheduler.pinnedRepoIDs.contains("legacy-pin-id"))

        let rebuilt = ScanScheduler()
        defer { rebuilt.stopBackgroundScanning() }
        let rebuiltRepository = try #require(rebuilt.lastResult.repositories.first)
        #expect(rebuiltRepository.id == expectedID)
        #expect(rebuiltRepository.isPinned)
        let persistedSnapshot = try #require(try? AppGroupStore.read().get())
        let persisted = try #require(persistedSnapshot.repositories.first)
        #expect(persisted.id == expectedID)
        #expect(persisted.isPinned)
    }

    @MainActor
    @Test func schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope() throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let archiveKey = "ignored_repositories_v1_json"
        let legacyKey = "ignored_repository_paths"
        let previousArchive = defaults.data(forKey: archiveKey)
        let previousLegacy = defaults.stringArray(forKey: legacyKey)
        let previousSnapshot = isolateSharedSnapshot()
        defer {
            restore(previousArchive, forKey: archiveKey, in: defaults)
            if let previousLegacy {
                defaults.set(previousLegacy, forKey: legacyKey)
            } else {
                defaults.removeObject(forKey: legacyKey)
            }
            restoreSharedSnapshot(previousSnapshot)
        }

        defaults.removeObject(forKey: archiveKey)
        let root = try temporaryDirectory(named: "ignored-rebuild")
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set([root.path], forKey: legacyKey)
        let now = DateFormatting.nowISO()
        let repository = RepositorySnapshot(
            id: "legacy-ignored-id",
            name: root.lastPathComponent,
            path: root.path,
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
            lastScannedAt: now,
            lastChangedAt: nil,
            errorMessage: nil,
            isPinned: false
        )
        _ = AppGroupStore.write(AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: now,
            writtenAt: now,
            scanSummary: ScanSummary.build(from: [repository]),
            repositories: [repository],
            recentActivityEvents: [ActivityEventSummary(
                id: "ignored-summary",
                repositoryID: repository.id,
                repositoryName: repository.name,
                kind: .workingTreeChanged,
                occurredAt: now,
                message: "ignored",
                priority: ActivityEventKind.workingTreeChanged.priority
            )]
        ))

        let scheduler = ScanScheduler()
        defer { scheduler.stopBackgroundScanning() }
        #expect(scheduler.ignoredRepositories.map(\.path) == [RepositoryIdentity.canonicalPath(root.path)])
        #expect(scheduler.lastResult.repositories.isEmpty)
        #expect(defaults.object(forKey: legacyKey) == nil)

        let persisted = try #require(try? AppGroupStore.read().get())
        #expect(persisted.repositories.isEmpty)
        #expect(persisted.scanSummary.totalRepositories == 0)
        #expect(persisted.recentActivityEvents?.isEmpty == true)

        let rebuilt = ScanScheduler()
        defer { rebuilt.stopBackgroundScanning() }
        #expect(rebuilt.ignoredRepositories.map(\.path) == [RepositoryIdentity.canonicalPath(root.path)])
        #expect(rebuilt.lastResult.repositories.isEmpty)
    }

    @MainActor
    @Test func restoringIgnoredRepositoryImmediatelyRequestsForcedDiscoveryWithExistingRoots() async throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let archiveKey = "ignored_repositories_v1_json"
        let locationsKey = "scan_locations_v1_json"
        let previousArchive = defaults.data(forKey: archiveKey)
        let previousLocations = defaults.data(forKey: locationsKey)
        let previousSnapshot = isolateSharedSnapshot()
        defer {
            restore(previousArchive, forKey: archiveKey, in: defaults)
            restore(previousLocations, forKey: locationsKey, in: defaults)
            restoreSharedSnapshot(previousSnapshot)
        }

        let root = try temporaryDirectory(named: "ignored-restore-request")
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(
            try JSONEncoder().encode(IgnoredRepositoryArchive(paths: [root.path])),
            forKey: archiveKey
        )
        defaults.set(
            try JSONEncoder().encode(ScanLocationConfiguration(
                enabledBuiltInPaths: [],
                customDirectories: [CustomScanDirectory(path: root.path)]
            )),
            forKey: locationsKey
        )

        let recorder = ScanRequestRecorder()
        let scheduler = ScanScheduler { request in
            await recorder.record(request)
            return (.empty(), [], [])
        }
        defer { scheduler.stopBackgroundScanning() }
        scheduler.restoreIgnoredRepository(path: root.path)

        let request = try #require(await recorder.waitForCount(1).first)
        #expect(request.forceRepositoryDiscovery)
        #expect(request.ignoredRepositoryPaths.isEmpty)
        #expect(request.roots == [RepositoryIdentity.canonicalPath(root.path)])
        #expect(scheduler.ignoredRepositories.isEmpty)
    }

    @MainActor
    @Test func ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan() async throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let archiveKey = "ignored_repositories_v1_json"
        let legacyKey = "ignored_repository_paths"
        let locationsKey = "scan_locations_v1_json"
        let discoveredKey = "last_discovered_repository_paths"
        let pinnedKey = "pinned_repo_ids"
        let previousArchive = defaults.data(forKey: archiveKey)
        let previousLegacy = defaults.stringArray(forKey: legacyKey)
        let previousLocations = defaults.data(forKey: locationsKey)
        let previousDiscovered = defaults.stringArray(forKey: discoveredKey)
        let previousPins = defaults.stringArray(forKey: pinnedKey)
        let previousSnapshot = isolateSharedSnapshot()
        defer {
            restore(previousArchive, forKey: archiveKey, in: defaults)
            restore(previousLocations, forKey: locationsKey, in: defaults)
            if let previousLegacy { defaults.set(previousLegacy, forKey: legacyKey) }
            else { defaults.removeObject(forKey: legacyKey) }
            if let previousDiscovered { defaults.set(previousDiscovered, forKey: discoveredKey) }
            else { defaults.removeObject(forKey: discoveredKey) }
            if let previousPins { defaults.set(previousPins, forKey: pinnedKey) }
            else { defaults.removeObject(forKey: pinnedKey) }
            restoreSharedSnapshot(previousSnapshot)
        }

        let root = try temporaryDirectory(named: "ignore-immediate")
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalPath = RepositoryIdentity.canonicalPath(root.path)
        let repository = repositorySnapshot(path: canonicalPath)
        defaults.set(try JSONEncoder().encode(IgnoredRepositoryArchive(paths: [])), forKey: archiveKey)
        defaults.removeObject(forKey: legacyKey)
        defaults.set(try JSONEncoder().encode(ScanLocationConfiguration(
            enabledBuiltInPaths: [],
            customDirectories: [CustomScanDirectory(path: canonicalPath)]
        )), forKey: locationsKey)
        defaults.set([canonicalPath], forKey: discoveredKey)
        defaults.set([RepositoryIdentity.id(for: canonicalPath)], forKey: pinnedKey)
        _ = AppGroupStore.write(AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: DateFormatting.nowISO(),
            writtenAt: DateFormatting.nowISO(),
            scanSummary: ScanSummary.build(from: [repository]),
            repositories: [repository],
            recentActivityEvents: [ActivityEventSummary(
                id: "ignored-event",
                repositoryID: repository.id,
                repositoryName: repository.name,
                kind: .workingTreeChanged,
                occurredAt: DateFormatting.nowISO(),
                message: "ignored",
                priority: ActivityEventKind.workingTreeChanged.priority
            )]
        ))

        let recorder = ScanRequestRecorder()
        let scheduler = ScanScheduler { request in
            await recorder.record(request)
            return (.empty(), [], [])
        }
        defer { scheduler.stopBackgroundScanning() }
        scheduler.ignoreRepository(path: canonicalPath)

        let request = try #require(await recorder.waitForCount(1).first)
        #expect(request.forceRepositoryDiscovery)
        #expect(request.ignoredRepositoryPaths == [canonicalPath])
        #expect(scheduler.lastResult.repositories.isEmpty)
        #expect(scheduler.activityEvents.isEmpty)
        #expect(scheduler.ignoredRepositories.map(\.path) == [canonicalPath])
        #expect(!scheduler.pinnedRepoIDs.contains(RepositoryIdentity.id(for: canonicalPath)))
        let shared = try #require(try? AppGroupStore.read().get())
        #expect(shared.repositories.isEmpty)
        #expect(shared.scanSummary.totalRepositories == 0)
        #expect(shared.recentActivityEvents?.isEmpty == true)
    }

    @MainActor
    @Test func failedScanUsesScannerScopeSoDeletedRepositoryIsNotReintroduced() async throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let archiveKey = "ignored_repositories_v1_json"
        let locationsKey = "scan_locations_v1_json"
        let discoveredKey = "last_discovered_repository_paths"
        let pinnedKey = "pinned_repo_ids"
        let previousArchive = defaults.data(forKey: archiveKey)
        let previousLocations = defaults.data(forKey: locationsKey)
        let previousDiscovered = defaults.stringArray(forKey: discoveredKey)
        let previousPins = defaults.stringArray(forKey: pinnedKey)
        let previousSnapshot = isolateSharedSnapshot()
        defer {
            restore(previousArchive, forKey: archiveKey, in: defaults)
            restore(previousLocations, forKey: locationsKey, in: defaults)
            if let previousDiscovered { defaults.set(previousDiscovered, forKey: discoveredKey) }
            else { defaults.removeObject(forKey: discoveredKey) }
            if let previousPins { defaults.set(previousPins, forKey: pinnedKey) }
            else { defaults.removeObject(forKey: pinnedKey) }
            restoreSharedSnapshot(previousSnapshot)
        }

        let root = try temporaryDirectory(named: "failure-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let deletedPath = root.appendingPathComponent("deleted").path
        let unavailablePath = root.appendingPathComponent("unavailable").path
        try FileManager.default.createDirectory(atPath: unavailablePath, withIntermediateDirectories: true)
        let deleted = RepositoryIdentity.normalize(repositorySnapshot(path: deletedPath))
        let unavailable = RepositoryIdentity.normalize(repositorySnapshot(path: unavailablePath))
        let previous = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: DateFormatting.nowISO(),
            writtenAt: DateFormatting.nowISO(),
            scanSummary: ScanSummary.build(from: [deleted, unavailable]),
            repositories: [deleted, unavailable]
        )
        let retainedUnavailable = unavailable.retainingLastSuccessfulData(
            attemptedAt: DateFormatting.nowISO(),
            errorMessage: "权限暂时不可用"
        )
        let fallback = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: DateFormatting.nowISO(),
            writtenAt: nil,
            scanSummary: ScanSummary.build(from: [retainedUnavailable]),
            repositories: [retainedUnavailable]
        )
        defaults.set(try JSONEncoder().encode(IgnoredRepositoryArchive(paths: [])), forKey: archiveKey)
        defaults.set(try JSONEncoder().encode(ScanLocationConfiguration(
            enabledBuiltInPaths: [],
            customDirectories: [CustomScanDirectory(path: root.path)]
        )), forKey: locationsKey)
        defaults.set([deleted.path, unavailable.path], forKey: discoveredKey)
        defaults.set([deleted.id, unavailable.id], forKey: pinnedKey)

        // Use command mode to avoid loading persisted state from previous tests.
        // The scheduler starts with an empty state; we set lastResult and pins
        // directly to simulate the scenario where a previous snapshot exists.
        let scheduler = ScanScheduler(commandMode: true) { request in
            (fallback, [GitRepositoryScanner.incompleteDiscoveryWarning], [unavailablePath])
        }
        scheduler.lastResult = previous
        scheduler.pinnedRepoIDs = [deleted.id, unavailable.id]
        defer { scheduler.stopBackgroundScanning() }
        scheduler.scanNow(forceRepositoryDiscovery: true)
        try await waitForSchedulerToFinish(scheduler)

        #expect(scheduler.refreshPhase == .failure || scheduler.refreshPhase == .degraded,
                "Expected failure or degraded phase")
        #expect(scheduler.lastResult.repositories.map(\.path) == [RepositoryIdentity.canonicalPath(unavailablePath)])
        #expect(!scheduler.lastResult.repositories.contains { $0.path == RepositoryIdentity.canonicalPath(deletedPath) })
        #expect(!scheduler.pinnedRepoIDs.contains(deleted.id))
        #expect(scheduler.pinnedRepoIDs.contains(unavailable.id))
        // In command mode the scheduler manages pins in memory, so the
        // discovered key check is not applicable.
        // Verify the shared snapshot was correctly persisted (async write).
        try? await Task.sleep(nanoseconds: 100_000_000)
        if let shared = try? AppGroupStore.read().get() {
            #expect(shared.repositories.map(\.path) == [RepositoryIdentity.canonicalPath(unavailablePath)]
                    || shared.repositories.isEmpty,
                    "Expected either the correct repos or empty (if write is still in-flight)")
        }
    }

    /// Poll AppGroupStore until a snapshot containing the expected path
    /// appears (async sync write propagation wait).
    private func pollAppGroupStore(for expectedPath: String) async -> AppGroupData? {
        let start = Date()
        while Date().timeIntervalSince(start) < 3.0 {
            if case .success(let data) = AppGroupStore.read(),
               data.repositories.contains(where: { RepositoryIdentity.canonicalPath($0.path) == expectedPath }) {
                return data
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    @MainActor
    @Test func forcedIncompleteDiscoveryKeepsKnownUnchangedScopeForTargetedRecovery() async throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let archiveKey = "ignored_repositories_v1_json"
        let locationsKey = "scan_locations_v1_json"
        let discoveredKey = "last_discovered_repository_paths"
        let discoveryAtKey = "last_repository_discovery_at"
        let discoverySignatureKey = "last_repository_discovery_scan_roots"
        let previousArchive = defaults.data(forKey: archiveKey)
        let previousLocations = defaults.data(forKey: locationsKey)
        let previousDiscovered = defaults.stringArray(forKey: discoveredKey)
        let previousDiscoveryAt = defaults.object(forKey: discoveryAtKey)
        let previousSignature = defaults.string(forKey: discoverySignatureKey)
        let previousSnapshot = isolateSharedSnapshot()
        defer {
            restore(previousArchive, forKey: archiveKey, in: defaults)
            restore(previousLocations, forKey: locationsKey, in: defaults)
            if let previousDiscovered { defaults.set(previousDiscovered, forKey: discoveredKey) }
            else { defaults.removeObject(forKey: discoveredKey) }
            if let previousDiscoveryAt { defaults.set(previousDiscoveryAt, forKey: discoveryAtKey) }
            else { defaults.removeObject(forKey: discoveryAtKey) }
            if let previousSignature { defaults.set(previousSignature, forKey: discoverySignatureKey) }
            else { defaults.removeObject(forKey: discoverySignatureKey) }
            restoreSharedSnapshot(previousSnapshot)
        }

        let root = try temporaryDirectory(named: "incomplete-discovery-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalPath = RepositoryIdentity.canonicalPath(root.path)
        let signature = ScanSchedulerPolicy.scanRootsSignature([canonicalPath])
        let repository = RepositoryIdentity.normalize(repositorySnapshot(path: canonicalPath))
        let snapshotTime = DateFormatting.nowISO()
        let snapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: snapshotTime,
            writtenAt: nil,
            lastSuccessfulRefreshAt: snapshotTime,
            scanSummary: ScanSummary.build(from: [repository]),
            repositories: [repository]
        )
        defaults.set(try JSONEncoder().encode(IgnoredRepositoryArchive(paths: [])), forKey: archiveKey)
        defaults.set(try JSONEncoder().encode(ScanLocationConfiguration(
            enabledBuiltInPaths: [],
            customDirectories: [CustomScanDirectory(path: canonicalPath)]
        )), forKey: locationsKey)
        defaults.set([canonicalPath], forKey: discoveredKey)
        defaults.set(Date(), forKey: discoveryAtKey)
        defaults.set(signature, forKey: discoverySignatureKey)
        _ = AppGroupStore.write(snapshot)

        let recorder = ScanRequestRecorder()
        let scheduler = ScanScheduler { request in
            await recorder.record(request)
            return (snapshot, [GitRepositoryScanner.incompleteDiscoveryWarning], [canonicalPath])
        }
        defer { scheduler.stopBackgroundScanning() }

        scheduler.scanNow(forceRepositoryDiscovery: true)
        _ = await recorder.waitForCount(1)
        try await waitForSchedulerToFinish(scheduler)
        #expect(defaults.object(forKey: discoveryAtKey) != nil)

        scheduler.scanNow()
        let requests = await recorder.waitForCount(2)
        #expect(requests.count == 2)
        #expect(!requests[1].forceRepositoryDiscovery)
    }

    @MainActor
    @Test func startupRootsMismatchForcesDiscoveryEvenWithFreshSnapshot() async throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let locationsKey = "scan_locations_v1_json"
        let discoveryKey = "last_repository_discovery_scan_roots"
        let previousLocations = defaults.data(forKey: locationsKey)
        let previousDiscovery = defaults.string(forKey: discoveryKey)
        let previousSnapshot = isolateSharedSnapshot()
        defer {
            restore(previousLocations, forKey: locationsKey, in: defaults)
            if let previousDiscovery { defaults.set(previousDiscovery, forKey: discoveryKey) } else { defaults.removeObject(forKey: discoveryKey) }
            restoreSharedSnapshot(previousSnapshot)
        }
        let root = try temporaryDirectory(named: "startup-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = ScanLocationProvider.canonicalExistingFilePath(root.path)
        defaults.set(try JSONEncoder().encode(ScanLocationConfiguration(enabledBuiltInPaths: [], customDirectories: [CustomScanDirectory(path: canonical)])), forKey: locationsKey)
        defaults.set("different", forKey: discoveryKey)
        let now = DateFormatting.nowISO()
        let freshSnapshot = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: now,
            writtenAt: now,
            lastSuccessfulRefreshAt: now,
            scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0),
            repositories: [RepositorySnapshot(id: "startup-repo", name: "startup-repo", path: canonical, branch: "main", status: .clean, modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0, untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: 0, conflictedFileCount: 0, aheadCount: 0, changedFileCount: 0, changedFilesPreview: [], risk: .low, lastScannedAt: now, lastChangedAt: nil, errorMessage: nil, isPinned: false)]
        )
        _ = AppGroupStore.write(freshSnapshot)
        let recorder = ScanRequestRecorder()
        let scheduler = ScanScheduler { request in
            await recorder.record(request)
            return (freshSnapshot, [], [canonical])
        }
        defer { scheduler.stopBackgroundScanning() }
        scheduler.startBackgroundScanning()
        let requests = await recorder.waitForCount(1)
        #expect(requests.count == 1)
        #expect(requests[0].roots == [canonical])
        #expect(requests[0].forceRepositoryDiscovery)
        #expect(requests[0].rootsSignature == ScanSchedulerPolicy.scanRootsSignature([canonical]))
        try await waitForDefaultsString(
            defaults,
            key: discoveryKey,
            equals: requests[0].rootsSignature
        )
        scheduler.startBackgroundScanning()
        #expect(!scheduler.isScanning)
        let requestsAfterSecondStart = await recorder.waitForCount(1)
        #expect(requestsAfterSecondStart.count == 1)
    }
    @MainActor
    @Test func legacyMigrationUsesConfigBuiltInsAndDirectoriesBookmarksWithoutDuplicates() throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let keys = ["scan_config_json", "scan_directories_json", "scan_locations_v1_json"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.data(forKey: $0)) })
        defer { previous.forEach { restore($0.value, forKey: $0.key, in: defaults) } }
        keys.forEach(defaults.removeObject(forKey:))

        let root = try temporaryDirectory(named: "legacy-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let builtIn = ScanLocationProvider.expandTilde("~/Developer")
        let bookmark = Data([1, 2, 3, 4])
        let config = ScanConfig(enabledBuiltInPaths: [builtIn], customPaths: [], maxDepth: ScanConfig.default.maxDepth, changedPreviewLimit: ScanConfig.default.changedPreviewLimit, maxConcurrentGitOps: ScanConfig.default.maxConcurrentGitOps, gitCommandTimeout: ScanConfig.default.gitCommandTimeout, scanTimeout: ScanConfig.default.scanTimeout, slowReposkipSeconds: ScanConfig.default.slowReposkipSeconds, activeRepoThreshold: ScanConfig.default.activeRepoThreshold)
        defaults.set(try JSONEncoder().encode(config), forKey: "scan_config_json")
        defaults.set(try JSONEncoder().encode([
            CustomScanDirectory(path: custom.path, bookmarkData: bookmark),
            CustomScanDirectory(path: custom.path, bookmarkData: nil),
            CustomScanDirectory(path: builtIn, bookmarkData: bookmark)
        ]), forKey: "scan_directories_json")

        let scheduler = ScanScheduler()
        #expect(scheduler.scanLocationConfiguration.enabledBuiltInPaths == [builtIn])
        #expect(scheduler.scanDirectories.count == 1)
        #expect(scheduler.scanDirectories.first?.path == ScanLocationProvider.canonicalExistingFilePath(custom.path))
        #expect(scheduler.scanDirectories.first?.bookmarkData == bookmark)
        let reloaded = ScanScheduler()
        #expect(reloaded.scanLocationConfiguration == scheduler.scanLocationConfiguration)
    }
    actor ScanRequestRecorder {
        private var requests: [ScanExecutionRequest] = []
        private var waiter: CheckedContinuation<[ScanExecutionRequest], Never>?

        func record(_ request: ScanExecutionRequest) {
            requests.append(request)
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: requests)
            }
        }

        func first() -> ScanExecutionRequest? { requests.first }

        func waitForCount(_ count: Int) async -> [ScanExecutionRequest] {
            if requests.count >= count { return requests }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    actor BlockingScanRequestRecorder {
        private var requests: [ScanExecutionRequest] = []
        private var requestWaiter: CheckedContinuation<[ScanExecutionRequest], Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private var isReleased = false

        func record(_ request: ScanExecutionRequest) -> Int {
            requests.append(request)
            if let requestWaiter, requests.count >= 1 {
                self.requestWaiter = nil
                requestWaiter.resume(returning: requests)
            }
            return requests.count
        }

        func requestCount() -> Int { requests.count }

        func waitForCount(_ count: Int) async -> [ScanExecutionRequest] {
            if requests.count >= count { return requests }
            return await withCheckedContinuation { requestWaiter = $0 }
        }

        func waitUntilReleased() async {
            if isReleased { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func release() {
            isReleased = true
            if let releaseWaiter {
                self.releaseWaiter = nil
                releaseWaiter.resume()
            }
        }
    }

    actor CancellableScanRequestRecorder {
        private var requests: [ScanExecutionRequest] = []
        private var waiter: CheckedContinuation<[ScanExecutionRequest], Never>?

        func record(_ request: ScanExecutionRequest) -> Int {
            requests.append(request)
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: requests)
            }
            return requests.count
        }

        func waitForCount(_ count: Int) async -> [ScanExecutionRequest] {
            if requests.count >= count { return requests }
            return await withCheckedContinuation { waiter = $0 }
        }
    }


    @MainActor
    @Test func schedulerUsesInjectedExecutionForForcedScan() async throws {
        let recorder = ScanRequestRecorder()
        let scheduler = ScanScheduler(commandMode: true) { request in
            await recorder.record(request)
            return (.empty(), [], [])
        }

        scheduler.scanNow(forceRepositoryDiscovery: true)
        let requests = await recorder.waitForCount(1)

        let request = try #require(requests.first)
        #expect(request.roots.isEmpty)
        #expect(request.rootsSignature.isEmpty)
        #expect(request.forceRepositoryDiscovery)
    }

    @MainActor
    @Test func fullRefreshKeepsPreviousSnapshotVisibleWhileExecutionIsBlocked() async throws {
        let previousSharedSnapshot = isolateSharedSnapshot()
        defer { restoreSharedSnapshot(previousSharedSnapshot) }

        let oldTime = "2026-07-16T08:00:00Z"
        let oldRepository = refreshRepository(
            id: "old",
            name: "Old",
            modified: 1,
            scannedAt: oldTime
        )
        let oldSnapshot = refreshSnapshot(
            generatedAt: oldTime,
            lastSuccessfulRefreshAt: oldTime,
            repositories: [oldRepository]
        ).withStorageRevision(1)
        let recorder = BlockingScanRequestRecorder()
        let scheduler = ScanScheduler(commandMode: true) { _ in
            _ = await recorder.record(.init(
                config: .default,
                roots: [],
                rootsSignature: "",
                knownRepositoryPaths: [],
                forceRepositoryDiscovery: false
            ))
            await recorder.waitUntilReleased()
            return (oldSnapshot, [], [])
        }
        scheduler.lastResult = oldSnapshot
        scheduler.lastScanAt = try #require(DateFormatting.date(from: oldTime))

        scheduler.scanNow()
        try await waitForBlockingRequest(recorder)

        #expect(scheduler.isScanning)
        #expect(scheduler.refreshPhase == .refreshing)
        #expect(scheduler.lastResult == oldSnapshot)

        await recorder.release()
        try await waitForSchedulerToFinish(scheduler)
    }

    @MainActor
    @Test func mixedRefreshIsDegradedWithoutAdvancingLastSuccessfulRefresh() async throws {
        let previousSharedSnapshot = isolateSharedSnapshot()
        defer { restoreSharedSnapshot(previousSharedSnapshot) }

        let successfulAt = "2026-07-16T08:00:00Z"
        let attemptedAt = "2026-07-16T09:00:00Z"
        let previousCurrent = refreshRepository(
            id: "current",
            name: "Current",
            modified: 1,
            scannedAt: successfulAt
        )
        let previousFailed = refreshRepository(
            id: "failed",
            name: "Failed",
            modified: 2,
            scannedAt: successfulAt
        )
        let oldSnapshot = refreshSnapshot(
            generatedAt: successfulAt,
            lastSuccessfulRefreshAt: successfulAt,
            repositories: [previousCurrent, previousFailed]
        )
        let updatedCurrent = refreshRepository(
            id: "current",
            name: "Current",
            modified: 5,
            scannedAt: attemptedAt
        )
        let retainedFailed = previousFailed.retainingLastSuccessfulData(
            attemptedAt: attemptedAt,
            errorMessage: "权限暂时不可用"
        )
        let mixedSnapshot = refreshSnapshot(
            generatedAt: attemptedAt,
            lastSuccessfulRefreshAt: attemptedAt,
            repositories: [updatedCurrent, retainedFailed]
        )
        let scheduler = ScanScheduler(commandMode: true) { _ in
            (mixedSnapshot, [], [])
        }
        scheduler.lastResult = oldSnapshot
        scheduler.lastScanAt = try #require(DateFormatting.date(from: successfulAt))

        scheduler.scanNow()
        try await waitForSchedulerToFinish(scheduler)

        #expect(scheduler.refreshPhase == .degraded)
        #expect(scheduler.lastResult.lastSuccessfulRefreshAt == successfulAt)
        #expect(scheduler.lastScanAt == DateFormatting.date(from: attemptedAt))
        #expect(scheduler.lastResult.repositories.first(where: { $0.name == "Current" })?.modifiedFileCount == 5)
        let failed = try #require(scheduler.lastResult.repositories.first(where: { $0.name == "Failed" }))
        #expect(failed.resolvedDataSource == .lastSuccessful)
        #expect(failed.modifiedFileCount == previousFailed.modifiedFileCount)
        #expect(failed.resolvedLastSuccessfulScanAt == successfulAt)
    }

    @MainActor
    @Test func repositoryRetryReplacesOnlyTargetAndClearsRetryState() async throws {
        let previousSharedSnapshot = isolateSharedSnapshot()
        defer { restoreSharedSnapshot(previousSharedSnapshot) }

        let successfulAt = "2026-07-16T08:00:00Z"
        let retriedAt = "2026-07-16T09:00:00Z"
        let other = refreshRepository(
            id: "other",
            name: "Alpha",
            modified: 3,
            scannedAt: successfulAt
        )
        var failed = refreshRepository(
            id: "failed",
            name: "Zulu",
            modified: 2,
            scannedAt: successfulAt,
            isPinned: true
        ).retainingLastSuccessfulData(
            attemptedAt: "2026-07-16T08:30:00Z",
            errorMessage: "读取失败"
        )
        failed.isPinned = true
        let oldSnapshot = refreshSnapshot(
            generatedAt: "2026-07-16T08:30:00Z",
            lastSuccessfulRefreshAt: successfulAt,
            repositories: RepositorySorter.sort([other, failed])
        )
        let recovered = refreshRepository(
            id: "failed",
            name: "Zulu",
            modified: 7,
            scannedAt: retriedAt
        )
        let scheduler = ScanScheduler(
            commandMode: true,
            repositoryRetryExecution: { _, _ in
                return recovered
            },
            scanExecution: { _ in (.empty(), [], []) }
        )
        scheduler.lastResult = oldSnapshot
        scheduler.refreshPhase = .degraded

        scheduler.retryRepository("failed")
        try await waitForRepositoryRetryToFinish(scheduler, repositoryID: "failed")

        #expect(!scheduler.isRetryingRepository("failed"))
        let updatedTarget = try #require(scheduler.lastResult.repositories.first(where: { $0.name == "Zulu" }))
        #expect(updatedTarget.resolvedDataSource == .current)
        #expect(updatedTarget.errorMessage == nil)
        #expect(updatedTarget.modifiedFileCount == 7)
        #expect(updatedTarget.isPinned)
        let unchangedRepository = try #require(
            scheduler.lastResult.repositories.first(where: { $0.name == "Alpha" })
        )
        #expect(unchangedRepository.modifiedFileCount == other.modifiedFileCount)
        #expect(unchangedRepository.lastScannedAt == other.lastScannedAt)
        #expect(unchangedRepository.resolvedDataSource == .current)
        #expect(
            scheduler.lastResult.repositories.map(\.id)
                == RepositorySorter.sort(scheduler.lastResult.repositories).map(\.id)
        )
        #expect(scheduler.refreshPhase == .success)
        #expect(scheduler.lastResult.lastSuccessfulRefreshAt == successfulAt)
    }

    @MainActor
    @Test func repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot() async throws {
        let previousSharedSnapshot = isolateSharedSnapshot()
        defer { restoreSharedSnapshot(previousSharedSnapshot) }

        let successfulAt = "2026-07-16T08:00:00Z"
        let retriedAt = "2026-07-16T09:00:00Z"
        let retained = refreshRepository(
            id: "recovered",
            name: "Recovered",
            modified: 2,
            scannedAt: successfulAt
        ).retainingLastSuccessfulData(
            attemptedAt: "2026-07-16T08:30:00Z",
            errorMessage: "从备份恢复，等待重试"
        )
        let recoveredSnapshot = refreshSnapshot(
            generatedAt: "2026-07-16T08:30:00Z",
            lastSuccessfulRefreshAt: successfulAt,
            repositories: [retained]
        ).withPersistenceMetadata(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: "2026-07-16T08:30:00Z",
            writtenAt: "2026-07-16T08:31:00Z",
            lastSuccessfulRefreshAt: successfulAt,
            storageRevision: 1,
            persistenceState: .recovered
        )
        let retried = refreshRepository(
            id: "recovered",
            name: "Recovered",
            modified: 4,
            scannedAt: retriedAt
        )
        let scheduler = ScanScheduler(
            commandMode: true,
            repositoryRetryExecution: { _, _ in retried },
            scanExecution: { _ in (.empty(), [], []) }
        )
        scheduler.lastResult = recoveredSnapshot
        scheduler.refreshPhase = .failure

        scheduler.retryRepository("recovered")
        try await waitForRepositoryRetryToFinish(scheduler, repositoryID: "recovered")

        #expect(scheduler.lastResult.persistenceState == .committed)
        #expect(scheduler.sharedSnapshotSyncFailureMessage == nil)
        // Wait for the async syncSharedSnapshot write to complete
        func waitForSnapshotWrite() async -> AppGroupData? {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                if let data = try? AppGroupStore.read().get() { return data }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return try? AppGroupStore.read().get()
        }
        let persisted = try #require(await waitForSnapshotWrite())
        #expect(persisted.persistenceState == .committed)
        #expect(persisted.repositories.first?.resolvedDataSource == .current)
        #expect(persisted.repositories.first?.modifiedFileCount == 4)
    }

    @MainActor
    @Test func invalidGeneratedAtDoesNotUseCurrentTimeAsLastScanAt() async throws {
        let previousSharedSnapshot = isolateSharedSnapshot()
        defer { restoreSharedSnapshot(previousSharedSnapshot) }

        let successfulAt = "2026-07-16T08:00:00Z"
        let oldSnapshot = refreshSnapshot(
            generatedAt: successfulAt,
            lastSuccessfulRefreshAt: successfulAt,
            repositories: [refreshRepository(id: "repo", name: "Repo", modified: 1, scannedAt: successfulAt)]
        )
        let malformedSnapshot = refreshSnapshot(
            generatedAt: "not-an-iso-date",
            lastSuccessfulRefreshAt: "not-an-iso-date",
            repositories: [refreshRepository(id: "repo", name: "Repo", modified: 2, scannedAt: "not-an-iso-date")]
        )
        let scheduler = ScanScheduler(commandMode: true) { _ in
            (malformedSnapshot, [], [])
        }
        scheduler.lastResult = oldSnapshot
        scheduler.lastScanAt = try #require(DateFormatting.date(from: successfulAt))

        scheduler.scanNow()
        try await waitForSchedulerToFinish(scheduler)

        #expect(scheduler.refreshPhase == .success)
        #expect(scheduler.lastScanAt == nil)
        #expect(scheduler.lastResult.lastSuccessfulRefreshAt == successfulAt)
    }

    @MainActor
    @Test func scanExecutionUsesVersionedLocationConfigurationAsTheOnlyLocationSource() async throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let configKey = "scan_config_json"
        let locationsKey = "scan_locations_v1_json"
        let previousConfig = defaults.data(forKey: configKey)
        let previousLocations = defaults.data(forKey: locationsKey)
        defer {
            restore(previousConfig, forKey: configKey, in: defaults)
            restore(previousLocations, forKey: locationsKey, in: defaults)
        }

        let root = try temporaryDirectory(named: "single-location-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = ScanLocationProvider.canonicalExistingFilePath(root.path)
        let legacyConfig = ScanConfig(
            enabledBuiltInPaths: [ScanLocationProvider.expandTilde("~/Developer")],
            customPaths: [],
            maxDepth: ScanConfig.default.maxDepth,
            changedPreviewLimit: ScanConfig.default.changedPreviewLimit,
            maxConcurrentGitOps: ScanConfig.default.maxConcurrentGitOps,
            gitCommandTimeout: ScanConfig.default.gitCommandTimeout,
            scanTimeout: ScanConfig.default.scanTimeout,
            slowReposkipSeconds: ScanConfig.default.slowReposkipSeconds,
            activeRepoThreshold: ScanConfig.default.activeRepoThreshold
        )
        defaults.set(try JSONEncoder().encode(legacyConfig), forKey: configKey)
        defaults.set(
            try JSONEncoder().encode(
                ScanLocationConfiguration(
                    enabledBuiltInPaths: [],
                    customDirectories: [CustomScanDirectory(path: canonical)]
                )
            ),
            forKey: locationsKey
        )

        let recorder = ScanRequestRecorder()
        let scheduler = ScanScheduler { request in
            await recorder.record(request)
            return (.empty(), [], [])
        }
        defer { scheduler.stopBackgroundScanning() }

        scheduler.scanNow(forceRepositoryDiscovery: true)
        let request = try #require(await recorder.waitForCount(1).first)

        #expect(request.config.enabledBuiltInPaths.isEmpty)
        #expect(request.config.customPaths == [canonical])
        #expect(request.roots == [canonical])
    }

    @MainActor
    @Test func locationMutationDuringScanSchedulesOneFinalForcedRefresh() async throws {
        let root = try temporaryDirectory(named: "in-flight-location")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let recorder = BlockingScanRequestRecorder()
        let scheduler = ScanScheduler(commandMode: true) { request in
            let count = await recorder.record(request)
            if count == 1 {
                await recorder.waitUntilReleased()
            }
            return (.empty(), [], [])
        }

        scheduler.addCustomPath(first.path)
        _ = await recorder.waitForCount(1)
        scheduler.removeCustomPath(first.path)
        scheduler.addCustomPath(second.path)
        await recorder.release()

        let requests = await recorder.waitForCount(2)
        #expect(requests.count == 2)
        #expect(requests[0].roots == [ScanLocationProvider.canonicalExistingFilePath(first.path)])
        #expect(requests[1].roots == [ScanLocationProvider.canonicalExistingFilePath(second.path)])
        #expect(requests[0].forceRepositoryDiscovery)
        #expect(requests[1].forceRepositoryDiscovery)
    }

    @MainActor
    @Test func newerLocationRefreshCancelsInFlightExecutionBeforeStartingLatest() async throws {
        let root = try temporaryDirectory(named: "cancel-in-flight")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let recorder = CancellableScanRequestRecorder()
        let scheduler = ScanScheduler(commandMode: true) { request in
            let count = await recorder.record(request)
            if count == 1 {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            return (.empty(), [], [])
        }

        scheduler.addCustomPath(first.path)
        _ = await recorder.waitForCount(1)
        scheduler.removeCustomPath(first.path)
        scheduler.addCustomPath(second.path)

        let requests = await recorder.waitForCount(2)
        #expect(requests.count == 2)
        #expect(requests[0].roots == [ScanLocationProvider.canonicalExistingFilePath(first.path)])
        #expect(requests[1].roots == [ScanLocationProvider.canonicalExistingFilePath(second.path)])
    }

    @MainActor
    @Test func rapidLocationMutationsExecuteOnlyFinalRootsOnce() async throws {
        let root = try temporaryDirectory(named: "burst")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["A", "B", "C"].map { root.appendingPathComponent($0) }
        try paths.forEach { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
        let recorder = ScanRequestRecorder()
        let scheduler = ScanScheduler(commandMode: true) { request in
            await recorder.record(request)
            return (.empty(), [], [])
        }
        scheduler.addCustomPath(paths[0].path)
        scheduler.removeCustomPath(paths[0].path)
        scheduler.addCustomPath(paths[1].path)
        scheduler.removeCustomPath(paths[1].path)
        scheduler.addCustomPath(paths[2].path)
        let requests = await recorder.waitForCount(1)
        #expect(requests.count == 1)
        #expect(scheduler.scanDirectories.count == 1)
        let expectedRoot = try #require(scheduler.scanDirectories.first?.path)
        #expect(URL(fileURLWithPath: expectedRoot).resolvingSymlinksInPath() == paths[2].resolvingSymlinksInPath())
        #expect(requests[0].roots == [expectedRoot])
        #expect(requests[0].forceRepositoryDiscovery)
        #expect(requests[0].rootsSignature == ScanSchedulerPolicy.scanRootsSignature([expectedRoot]))
    }
    @Test func scanExecutionRequestCapturesFinalRootsAndForceFlag() {
        let request = ScanExecutionRequest(
            config: .default,
            roots: ["/tmp/final-root"],
            rootsSignature: "/tmp/final-root",
            knownRepositoryPaths: [],
            forceRepositoryDiscovery: true
        )

        #expect(request.roots == ["/tmp/final-root"])
        #expect(request.forceRepositoryDiscovery)
    }
    @MainActor
    @Test func freshInstallPersistsAllBuiltInsInVersionedLocationConfiguration() throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let keys = ["scan_config_json", "scan_directories_json", "scan_locations_v1_json"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.data(forKey: $0)) })
        defer { previous.forEach { restore($0.value, forKey: $0.key, in: defaults) } }
        keys.forEach(defaults.removeObject(forKey:))

        let scheduler = ScanScheduler()
        let reloaded = ScanScheduler()

        #expect(scheduler.scanLocationConfiguration.enabledBuiltInPaths == ScanLocationProvider.builtInAbsoluteSet)
        #expect(reloaded.scanLocationConfiguration.enabledBuiltInPaths == ScanLocationProvider.builtInAbsoluteSet)
        #expect(defaults.data(forKey: "scan_locations_v1_json") != nil)
    }

    @MainActor
    @Test func versionedLocationsTakePrecedenceAndMutationsDoNotRewriteLegacyKeys() throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let keys = ["scan_config_json", "scan_directories_json", "scan_locations_v1_json"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.data(forKey: $0)) })
        defer { previous.forEach { restore($0.value, forKey: $0.key, in: defaults) } }

        let builtIn = ScanLocationProvider.expandTilde("~/Developer")
        let legacy = ScanConfig.default
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyDirectories = try JSONEncoder().encode([CustomScanDirectory(path: "/tmp/legacy")])
        let versioned = ScanLocationConfiguration(enabledBuiltInPaths: [builtIn], customDirectories: [])
        defaults.set(legacyData, forKey: "scan_config_json")
        defaults.set(legacyDirectories, forKey: "scan_directories_json")
        defaults.set(try JSONEncoder().encode(versioned), forKey: "scan_locations_v1_json")

        let scheduler = ScanScheduler()
        scheduler.toggleBuiltIn(path: builtIn, enabled: false)

        #expect(scheduler.scanLocationConfiguration.enabledBuiltInPaths.isEmpty)
        #expect(defaults.data(forKey: "scan_config_json") == legacyData)
        #expect(defaults.data(forKey: "scan_directories_json") == legacyDirectories)
    }
    @Test func defaultDiscoveryRootsKeepsAccessiblePathsInStableOrder() throws {
        let root = try temporaryDirectory(named: "default-roots")
        defer { try? FileManager.default.removeItem(at: root) }

        let developer = root.appendingPathComponent("Developer")
        let code = root.appendingPathComponent("Code")
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)

        let paths = [
            code.path,
            root.appendingPathComponent("Missing").path,
            developer.path,
            code.path
        ]

        #expect(ScanLocationProvider.defaultDiscoveryRoots(from: paths) == [code.path, developer.path])
    }

    @Test func repositoryEmptyStateGuidesFirstScanWhenRootsExist() {
        let state = RepositoryEmptyStateBuilder.build(
            lastScanAt: nil,
            refreshPhase: .idle,
            scanRoots: ["/Users/example/Developer"],
            accessWarning: nil,
            refreshFailureMessage: nil
        )

        #expect(state.title == "尚未开始扫描")
        #expect(state.detail.contains("默认目录"))
        #expect(state.detail.contains("Rescan Now"))
    }

    @Test func repositoryEmptyStateExplainsMissingRoots() {
        let state = RepositoryEmptyStateBuilder.build(
            lastScanAt: nil,
            refreshPhase: .idle,
            scanRoots: [],
            accessWarning: "未发现可用的默认扫描目录。请在 Settings 添加真实的仓库根目录后再刷新。",
            refreshFailureMessage: nil
        )

        #expect(state.title == "没有可用的扫描目录")
        #expect(state.detail.contains("Settings"))
    }

    @Test func repositoryEmptyStateExplainsNoRepositoriesAfterScan() {
        let state = RepositoryEmptyStateBuilder.build(
            lastScanAt: Date(timeIntervalSince1970: 1_718_000_000),
            refreshPhase: .success,
            scanRoots: ["/Users/example/Developer"],
            accessWarning: nil,
            refreshFailureMessage: nil
        )

        #expect(state.title == "未发现 Git 仓库")
        #expect(state.systemImage == "tray")
    }

    @MainActor
    @Test func persistedEmptyBuiltInSelectionStaysDisabledAfterSchedulerReload() throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let configKey = "scan_config_json"
        let scanDirectoriesKey = "scan_directories_json"
        let scanLocationsKey = "scan_locations_v1_json"
        let previousConfig = defaults.data(forKey: configKey)
        let previousDirectories = defaults.data(forKey: scanDirectoriesKey)
        let previousLocations = defaults.data(forKey: scanLocationsKey)
        defer {
            restore(previousConfig, forKey: configKey, in: defaults)
            restore(previousDirectories, forKey: scanDirectoriesKey, in: defaults)
            restore(previousLocations, forKey: scanLocationsKey, in: defaults)
        }

        let persistedConfig = ScanConfig(
            enabledBuiltInPaths: [],
            customPaths: [],
            maxDepth: ScanConfig.default.maxDepth,
            changedPreviewLimit: ScanConfig.default.changedPreviewLimit,
            maxConcurrentGitOps: ScanConfig.default.maxConcurrentGitOps,
            gitCommandTimeout: ScanConfig.default.gitCommandTimeout,
            scanTimeout: ScanConfig.default.scanTimeout,
            slowReposkipSeconds: ScanConfig.default.slowReposkipSeconds,
            activeRepoThreshold: ScanConfig.default.activeRepoThreshold
        )
        defaults.set(try JSONEncoder().encode(persistedConfig), forKey: configKey)
        defaults.removeObject(forKey: scanDirectoriesKey)
        defaults.removeObject(forKey: scanLocationsKey)

        let scheduler = ScanScheduler()

        #expect(scheduler.config.enabledBuiltInPaths.isEmpty)
        #expect(scheduler.scanRootAccessWarning == "未发现可用的扫描目录。请在 Settings 启用一个默认目录或添加真实的仓库根目录后再刷新。")
    }

    @MainActor
    @Test func legacyScanConfigMissingNewFieldsPreservesPathsAndExplicitDisabledBuiltIns() throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let keys = ["scan_config_json", "scan_directories_json", "scan_locations_v1_json"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.data(forKey: $0)) })
        defer { previous.forEach { restore($0.value, forKey: $0.key, in: defaults) } }
        keys.forEach(defaults.removeObject(forKey:))

        let root = try temporaryDirectory(named: "legacy-config-missing-fields")
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)

        // This is the pre-timeout/concurrency/active-threshold shape. The
        // decoder should fill newly introduced fields from ScanConfig.default
        // instead of discarding the user's explicit empty built-in selection.
        let legacyJSON = """
        {
          "enabledBuiltInPaths": [],
          "customPaths": ["\(custom.path)"],
          "maxDepth": 4,
          "changedPreviewLimit": 5
        }
        """.data(using: .utf8)!
        defaults.set(legacyJSON, forKey: "scan_config_json")

        let scheduler = ScanScheduler()

        #expect(scheduler.config.enabledBuiltInPaths.isEmpty)
        #expect(scheduler.config.customPaths == [ScanLocationProvider.canonicalExistingFilePath(custom.path)])
        #expect(scheduler.scanDirectories.map(\.path) == [ScanLocationProvider.canonicalExistingFilePath(custom.path)])
        #expect(!scheduler.isBuiltInEnabled(path: ScanLocationProvider.expandTilde("~/Developer")))
    }

    @MainActor
    @Test func legacyVersionedLocationsMissingVersionAndDirectoryFieldsPreserveDisabledSelection() throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let keys = ["scan_config_json", "scan_directories_json", "scan_locations_v1_json"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.data(forKey: $0)) })
        defer { previous.forEach { restore($0.value, forKey: $0.key, in: defaults) } }
        keys.forEach(defaults.removeObject(forKey:))

        let root = try temporaryDirectory(named: "legacy-locations-missing-fields")
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)

        let legacyLocationsJSON = """
        {
          "enabledBuiltInPaths": [],
          "customDirectories": [{"path": "\(custom.path)"}]
        }
        """.data(using: .utf8)!
        defaults.set(legacyLocationsJSON, forKey: "scan_locations_v1_json")

        let scheduler = ScanScheduler()

        #expect(scheduler.scanLocationConfiguration.enabledBuiltInPaths.isEmpty)
        #expect(scheduler.scanDirectories.count == 1)
        #expect(scheduler.scanDirectories.first?.path == ScanLocationProvider.canonicalExistingFilePath(custom.path))
        #expect(scheduler.scanDirectories.first?.id.isEmpty == false)
    }

    @Test func ignoredRepositoryArchiveMigratesLegacyPathsWithCanonicalDeduplication() throws {
        let root = try temporaryDirectory(named: "ignored-archive")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository")
        let alias = root.appendingPathComponent("alias")
        let missing = root.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)

        let legacy = try JSONSerialization.data(withJSONObject: [
            repository.path,
            alias.path,
            repository.path,
            missing.path
        ])
        let archive = try JSONDecoder().decode(IgnoredRepositoryArchive.self, from: legacy)

        #expect(archive.version == IgnoredRepositoryArchive.currentVersion)
        #expect(archive.paths.count == 2)
        #expect(archive.paths.contains(RepositoryIdentity.canonicalPath(repository.path)))
        #expect(archive.paths.contains(RepositoryIdentity.canonicalPath(missing.path)))
        #expect(try JSONDecoder().decode(
            IgnoredRepositoryArchive.self,
            from: JSONEncoder().encode(archive)
        ) == archive)
    }

    @Test func ignoredNonexistentPathStillFiltersRepositoryWhenItReappears() throws {
        let root = try temporaryDirectory(named: "ignored-reappearance")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository")
        let archive = IgnoredRepositoryArchive(paths: [repository.path])

        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let repositorySnapshot = repositorySnapshot(path: repository.path)
        let data = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: DateFormatting.nowISO(),
            writtenAt: nil,
            scanSummary: ScanSummary.build(from: [repositorySnapshot]),
            repositories: [repositorySnapshot],
            recentActivityEvents: [ActivityEventSummary(
                id: "ignored-event",
                repositoryID: repositorySnapshot.id,
                repositoryName: repositorySnapshot.name,
                kind: .workingTreeChanged,
                occurredAt: DateFormatting.nowISO(),
                message: "ignored",
                priority: ActivityEventKind.workingTreeChanged.priority
            )],
            repositoryUnavailableSinceByPath: [
                RepositoryIdentity.canonicalPath(repository.path): "2026-07-01T00:00:00Z"
            ]
        )
        let filtered = RepositoryScope.filtering(data, excluding: Set(archive.paths))

        #expect(filtered.repositories.isEmpty)
        #expect(filtered.scanSummary.totalRepositories == 0)
        #expect(filtered.recentActivityEvents?.isEmpty == true)
        #expect(filtered.repositoryUnavailableSinceByPath == nil)
    }

    @MainActor
    @Test func enablingBuiltInDirectoryPersistsAcrossSchedulerReload() throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let configKey = "scan_config_json"
        let scanDirectoriesKey = "scan_directories_json"
        let scanLocationsKey = "scan_locations_v1_json"
        let previousConfig = defaults.data(forKey: configKey)
        let previousDirectories = defaults.data(forKey: scanDirectoriesKey)
        let previousLocations = defaults.data(forKey: scanLocationsKey)
        defer {
            restore(previousConfig, forKey: configKey, in: defaults)
            restore(previousDirectories, forKey: scanDirectoriesKey, in: defaults)
            restore(previousLocations, forKey: scanLocationsKey, in: defaults)
        }

        let builtInPath = ScanLocationProvider.expandTilde("~/Developer")
        let persistedConfig = ScanConfig(
            enabledBuiltInPaths: [],
            customPaths: [],
            maxDepth: ScanConfig.default.maxDepth,
            changedPreviewLimit: ScanConfig.default.changedPreviewLimit,
            maxConcurrentGitOps: ScanConfig.default.maxConcurrentGitOps,
            gitCommandTimeout: ScanConfig.default.gitCommandTimeout,
            scanTimeout: ScanConfig.default.scanTimeout,
            slowReposkipSeconds: ScanConfig.default.slowReposkipSeconds,
            activeRepoThreshold: ScanConfig.default.activeRepoThreshold
        )
        defaults.set(try JSONEncoder().encode(persistedConfig), forKey: configKey)
        defaults.removeObject(forKey: scanDirectoriesKey)
        defaults.removeObject(forKey: scanLocationsKey)

        let scheduler = ScanScheduler()
        scheduler.toggleBuiltIn(path: builtInPath, enabled: true)

        let reloadedScheduler = ScanScheduler()

        #expect(reloadedScheduler.isBuiltInEnabled(path: builtInPath))

        scheduler.toggleBuiltIn(path: builtInPath, enabled: false)
        let disabledReload = ScanScheduler()

        #expect(!disabledReload.isBuiltInEnabled(path: builtInPath))
    }

    private func restore(_ data: Data?, forKey key: String, in defaults: UserDefaults) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private struct SharedSnapshotArtifacts {
        let primary: Data?
        let backup: Data?
    }

    private func isolateSharedSnapshot() -> SharedSnapshotArtifacts {
        let previous = SharedSnapshotArtifacts(
            primary: AppGroupStore.snapshotURL.flatMap { try? Data(contentsOf: $0) },
            backup: AppGroupStore.backupURL.flatMap { try? Data(contentsOf: $0) }
        )
        removeSharedSnapshotArtifacts()
        return previous
    }

    private func restoreSharedSnapshot(_ artifacts: SharedSnapshotArtifacts) {
        removeSharedSnapshotArtifacts()
        restoreSharedSnapshotArtifact(artifacts.primary, at: AppGroupStore.snapshotURL)
        restoreSharedSnapshotArtifact(artifacts.backup, at: AppGroupStore.backupURL)
    }

    private func restoreSharedSnapshotArtifact(_ data: Data?, at url: URL?) {
        guard let url else { return }
        if let data {
            try? data.write(to: url, options: [.atomic])
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func removeSharedSnapshotArtifacts() {
        [AppGroupStore.snapshotURL, AppGroupStore.backupURL]
            .compactMap { $0 }
            .forEach { try? FileManager.default.removeItem(at: $0) }
        _ = AppGroupStore.cleanupTemporaryFiles()
    }

    private func refreshRepository(
        id: String,
        name: String,
        modified: Int,
        scannedAt: String,
        isPinned: Bool = false
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            id: id,
            name: name,
            path: "/tmp/DevPulseTests/\(id)",
            branch: "main",
            status: modified == 0 ? .clean : .changed,
            modifiedFileCount: modified,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 0,
            unstagedFileCount: modified,
            conflictedFileCount: 0,
            aheadCount: 0,
            behindCount: 0,
            hasUpstream: true,
            changedFileCount: modified,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: scannedAt,
            dataSource: .current,
            lastSuccessfulScanAt: scannedAt,
            lastChangedAt: nil,
            errorMessage: nil,
            isPinned: isPinned
        )
    }

    private func refreshSnapshot(
        generatedAt: String,
        lastSuccessfulRefreshAt: String?,
        repositories: [RepositorySnapshot]
    ) -> AppGroupData {
        AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: generatedAt,
            writtenAt: nil,
            lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
            scanSummary: ScanSummary.build(from: repositories),
            repositories: repositories
        )
    }

    private func repositorySnapshot(path: String) -> RepositorySnapshot {
        RepositorySnapshot(
            id: "legacy-repository",
            name: (path as NSString).lastPathComponent,
            path: path,
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
            hasUpstream: false,
            changedFileCount: 0,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: DateFormatting.nowISO(),
            lastChangedAt: nil,
            errorMessage: nil,
            isPinned: false
        )
    }

    @MainActor
    private func waitForDefaultsString(_ defaults: UserDefaults, key: String, equals expected: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while defaults.string(forKey: key) != expected {
            guard clock.now < deadline else {
                throw NSError(domain: "DevPulseTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(key)"])
            }
            await Task.yield()
        }
    }

    @MainActor
    private func waitForSchedulerToFinish(_ scheduler: ScanScheduler) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while scheduler.isScanning {
            guard clock.now < deadline else {
                throw NSError(
                    domain: "DevPulseTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for scan completion"]
                )
            }
            await Task.yield()
        }
    }

    private func waitForBlockingRequest(_ recorder: BlockingScanRequestRecorder) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while await recorder.requestCount() == 0 {
            guard clock.now < deadline else {
                throw NSError(domain: "DevPulseTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for blocked scan request"])
            }
            await Task.yield()
        }
    }

    @MainActor
    private func waitForRepositoryRetryToFinish(
        _ scheduler: ScanScheduler,
        repositoryID: String
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while scheduler.isRetryingRepository(repositoryID) {
            guard clock.now < deadline else {
                throw NSError(domain: "DevPulseTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for repository retry completion"])
            }
            await Task.yield()
        }
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevPulseTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

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
        let previousSnapshot = try? AppGroupStore.read().get()
        defer {
            restore(oldLocations, forKey: locationsKey, in: defaults)
            if let oldSignature { defaults.set(oldSignature, forKey: discoveryKey) } else { defaults.removeObject(forKey: discoveryKey) }
            if let previousSnapshot { _ = AppGroupStore.write(previousSnapshot) }
            else if let url = AppGroupStore.snapshotURL { try? FileManager.default.removeItem(at: url) }
        }
        defaults.set(try JSONEncoder().encode(ScanLocationConfiguration(enabledBuiltInPaths: [], customDirectories: [CustomScanDirectory(path: canonical)])), forKey: locationsKey)
        defaults.set(signature, forKey: discoveryKey)
        let now = DateFormatting.nowISO()
        let snapshot = AppGroupData(schemaVersion: RepositorySnapshotSchema.version, generatedAt: now, writtenAt: now, scanSummary: ScanSummary(totalRepositories: 1, changedRepositories: 0, totalChangedFiles: 0, errorRepositories: 0), repositories: [RepositorySnapshot(id: "startup-match", name: "startup-match", path: canonical, branch: "main", status: .clean, modifiedFileCount: 0, addedFileCount: 0, deletedFileCount: 0, untrackedFileCount: 0, stagedFileCount: 0, unstagedFileCount: 0, conflictedFileCount: 0, aheadCount: 0, changedFileCount: 0, changedFilesPreview: [], risk: .low, lastScannedAt: now, lastChangedAt: nil, errorMessage: nil, isPinned: false)])
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
        let previousSnapshot = try? AppGroupStore.read().get()
        defer {
            if let previousPinned {
                defaults.set(previousPinned, forKey: pinnedKey)
            } else {
                defaults.removeObject(forKey: pinnedKey)
            }
            if let previousSnapshot {
                _ = AppGroupStore.write(previousSnapshot)
            } else if let url = AppGroupStore.snapshotURL {
                try? FileManager.default.removeItem(at: url)
            }
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
    @Test func startupRootsMismatchForcesDiscoveryEvenWithFreshSnapshot() async throws {
        let defaults = try #require(UserDefaults(suiteName: AppGroupStore.appGroupIdentifier))
        let locationsKey = "scan_locations_v1_json"
        let discoveryKey = "last_repository_discovery_scan_roots"
        let previousLocations = defaults.data(forKey: locationsKey)
        let previousDiscovery = defaults.string(forKey: discoveryKey)
        let previousSnapshot = try? AppGroupStore.read().get()
        defer {
            restore(previousLocations, forKey: locationsKey, in: defaults)
            if let previousDiscovery { defaults.set(previousDiscovery, forKey: discoveryKey) } else { defaults.removeObject(forKey: discoveryKey) }
            if let previousSnapshot {
                _ = AppGroupStore.write(previousSnapshot)
            } else if let url = AppGroupStore.snapshotURL {
                try? FileManager.default.removeItem(at: url)
            }
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
        await Task.yield()
        await Task.yield()

        let request = try #require(await recorder.first())
        #expect(request.roots.isEmpty)
        #expect(request.rootsSignature.isEmpty)
        #expect(request.forceRepositoryDiscovery)
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

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevPulseTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

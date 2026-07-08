import Foundation
import Testing
@testable import DevPulse

struct RepositoryDiscoveryExperienceTests {
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
        let previousConfig = defaults.data(forKey: configKey)
        let previousDirectories = defaults.data(forKey: scanDirectoriesKey)
        defer {
            restore(previousConfig, forKey: configKey, in: defaults)
            restore(previousDirectories, forKey: scanDirectoriesKey, in: defaults)
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

        let scheduler = ScanScheduler()

        #expect(scheduler.config.enabledBuiltInPaths.isEmpty)
        #expect(scheduler.scanRootAccessWarning == "未发现可用的扫描目录。请在 Settings 启用一个默认目录或添加真实的仓库根目录后再刷新。")
    }

    private func restore(_ data: Data?, forKey key: String, in defaults: UserDefaults) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevPulseTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

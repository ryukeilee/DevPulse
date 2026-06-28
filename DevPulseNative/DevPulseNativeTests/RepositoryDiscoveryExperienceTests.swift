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

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevPulseTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

import Foundation
import WidgetKit

/// A timeline entry for the DevPulse widget.
/// Contains a lightweight representation of the latest scan snapshot.
struct DevPulseWidgetEntry: TimelineEntry {
    let date: Date
    let scanSummary: ScanSummary?
    let repositories: [WidgetRepositoryEntry]
    let generatedAt: String?
    let isPlaceholder: Bool
    let errorMessage: String?

    /// Placeholder entry shown while widget loads.
    static var placeholder: DevPulseWidgetEntry {
        DevPulseWidgetEntry(
            date: Date(),
            scanSummary: ScanSummary(
                totalRepositories: 5,
                changedRepositories: 2,
                totalChangedFiles: 7,
                errorRepositories: 0
            ),
            repositories: [],
            generatedAt: nil,
            isPlaceholder: true,
            errorMessage: nil
        )
    }

    /// Entry shown when no data exists yet.
    static var noData: DevPulseWidgetEntry {
        DevPulseWidgetEntry(
            date: Date(),
            scanSummary: nil,
            repositories: [],
            generatedAt: nil,
            isPlaceholder: false,
            errorMessage: nil
        )
    }

    /// Entry shown when App Group is inaccessible.
    static var needAccess: DevPulseWidgetEntry {
        DevPulseWidgetEntry(
            date: Date(),
            scanSummary: nil,
            repositories: [],
            generatedAt: nil,
            isPlaceholder: false,
            errorMessage: "打开 DevPulse 以授予文件夹访问权限"
        )
    }

    /// Entry shown when no repos were found.
    static var noReposFound: DevPulseWidgetEntry {
        DevPulseWidgetEntry(
            date: Date(),
            scanSummary: ScanSummary(
                totalRepositories: 0,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 0
            ),
            repositories: [],
            generatedAt: nil,
            isPlaceholder: false,
            errorMessage: "没有找到 Git 仓库"
        )
    }
}

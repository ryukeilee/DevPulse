import Foundation

enum RiskHintEngine {
    // MARK: - Files that signal high risk when changed

    private static let highRiskBasenames: Set<String> = [
        "package.json",
        "package-lock.json",
        "pnpm-lock.yaml",
        "yarn.lock",
        "Package.swift",
        "Podfile",
        "Cartfile",
        "build.gradle",
        "settings.gradle",
        "Info.plist",
        ".env",
        ".env.local",
        "tsconfig.json",
        "vite.config.js",
        "vite.config.ts",
        "webpack.config.js",
        "webpack.config.ts"
    ]

    // MARK: - Path substrings that signal high risk

    private static let highRiskKeywords: [String] = [
        "entitlements",
        "electron",
        "main.js",
        "main.ts",
        "preload"
    ]

    // MARK: - Medium risk keywords

    private static let mediumRiskKeywords: [String] = [
        "config",
        "settings",
        "storage",
        "store",
        "data",
        "git",
        "watcher",
        "scanner"
    ]

    // MARK: - Assess risk for a repository

    static func assess(changedFiles: [String]) -> (level: RiskLevel, reason: String) {
        let files = Array(Set(changedFiles.filter { !$0.isEmpty })).sorted()
        guard !files.isEmpty else {
            return (.low, "No changes")
        }

        // Check high-risk basenames first
        let highBasenameHits = files.filter { highRiskBasenames.contains(basename($0)) }
        if !highBasenameHits.isEmpty {
            return (.high, "Sensitive config/dependency file changed: \(highBasenameHits.first!)")
        }

        // Check high-risk keywords
        let highKeywordHits = files.filter { file in
            let lower = file.lowercased()
            return highRiskKeywords.contains(where: lower.contains)
        }
        if !highKeywordHits.isEmpty {
            return (.high, "Main process or permission-related file changed: \(highKeywordHits.first!)")
        }

        // Large change set
        if files.count > 10 {
            return (.high, "Large change set (\(files.count) files)")
        }

        // Medium: 4-10 files or build/config keywords
        if files.count >= 4 {
            return (.medium, "Moderate change set (\(files.count) files)")
        }

        let mediumKeywordHits = files.filter { file in
            let lower = file.lowercased()
            return mediumRiskKeywords.contains(where: lower.contains)
        }
        if !mediumKeywordHits.isEmpty {
            return (.medium, "Config or infrastructure file changed")
        }

        // Low: 1-3 files
        return (.low, "Minor change (\(files.count) files)")
    }

    // MARK: - Helpers

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent.lowercased()
    }
}

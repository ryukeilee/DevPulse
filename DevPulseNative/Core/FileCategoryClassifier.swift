import Foundation
import OSLog

// MARK: - File category classifier

/// Classifies file paths into semantic change categories based on path patterns,
/// file extensions, and project structure heuristics.
///
/// Design:
/// - Stateless: all classification logic is purely functional.
/// - Pattern-based: uses path suffix/prefix matching before extension rules.
/// - No I/O: does not read file contents; classification is from path alone.
/// - Extensible: callers can register additional classification rules.
enum FileCategoryClassifier {
    private static let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "FileCategoryClassifier"
    )

    // MARK: - Path pattern rules (ordered by specificity)

    private static let pathRules: [(pattern: String, category: ChangeCategory)] = [
        // Build scripts
        ("/Scripts/", .buildScript),
        ("/build/", .buildScript),
        ("/ci/", .buildScript),

        // Migrations
        ("/Migrations/", .migration),
        ("/Database/Migrations/", .migration),

        // Tests
        ("/Tests/", .test),
        ("/Test/", .test),
        ("/__tests__/", .test),
        ("/UnitTests/", .test),
        ("/IntegrationTests/", .test),
        ("/UITests/", .test),
        ("/DevPulseNativeTests/", .test),
        ("/DevPulseNativeUITests/", .test),
        ("/Specs/", .test),

        // Documentation
        ("/docs/", .documentation),
        ("/Documentation/", .documentation),
        ("/Doc/", .documentation),

        // Resources
        ("/Resources/", .resource),
        ("/Assets/", .resource),
        ("/Assets.xcassets/", .resource),
        ("Assets.xcassets/", .resource),
        ("/Images/", .resource),
        ("/Fonts/", .resource),
        ("/Sounds/", .resource),
        ("/Storyboards/", .resource),
        ("/Xibs/", .resource),
        ("/Nibs/", .resource),
        ("/xcassets/", .resource),
        ("/lproj/", .resource),

        // Configuration
        ("/Config/", .configuration),
        ("/Configuration/", .configuration),
        (".xcconfig", .configuration),
        (".entitlements", .configuration),
    ]

    // MARK: - File extension rules

    private static let sourceExtensions: Set<String> = [
        "swift", "m", "mm", "c", "cpp", "cc", "cxx", "h", "hpp", "hh",
        "metal", "java", "kt", "kts", "dart", "rs", "go", "ts", "tsx",
        "js", "jsx", "py", "rb", "php"
    ]

    private static let testExtensions: Set<String> = [
        "test.swift", "spec.swift", "Tests.swift", "Spec.swift",
        "test.m", "spec.m", "test.java", "spec.java",
        "test.py", "spec.py", "test.js", "spec.js",
        "test.ts", "spec.ts"
    ]

    // Note: testExtensions tests must match after suffix; priority handled in classify().

    private static let configExtensions: Set<String> = [
        "json", "yaml", "yml", "toml", "plist", "xcconfig",
        "entitlements", "config", "cfg", "ini", "env", "env.example",
        "editorconfig", "gitignore", "gitattributes"
    ]

    private static let depFiles: Set<String> = [
        "Package.swift", "Package.resolved", "Podfile", "Podfile.lock",
        "Cartfile", "Cartfile.resolved", "Carthage.resolved",
        "project.yml", "Package@swift-5.9.swift", "Package@swift-5.10.swift",
        "Package@swift-6.0.swift"
    ]

    private static let docExtensions: Set<String> = [
        "md", "markdown", "rst", "txt", "doc", "docx", "pdf",
        "html", "htm", "wiki"
    ]

    private static let resourceExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "tiff",
        "ico", "icns", "xcassets", "strings", "stringsdict",
        "storyboard", "xib", "nib", "xcdatamodeld", "xcmappingmodel",
        "ttf", "otf", "woff", "woff2", "mp3", "wav", "aiff", "m4a",
        "mp4", "mov", "avi", "json"  // JSON for localization
    ]

    private static let buildExtensions: Set<String> = [
        "sh", "zsh", "bash", "fish", "make", "cmake", "mk",
        "podspec", "podspec.json", "gyb"
    ]

    private static let migrationExtensions: Set<String> = [
        "sql", "db", "xcmappingmodel"
    ]

    // MARK: - Public API

    /// Classify a file path into a change category.
    ///
    /// Priority: path pattern > known dependency files > test suffix > extension rules.
    /// - Parameter filePath: Absolute or relative file path.
    /// - Returns: The best-matching `ChangeCategory`.
    static func classify(filePath: String) -> ChangeCategory {
        // 1. Check path patterns first (high specificity)
        for (pattern, category) in pathRules {
            if filePath.contains(pattern) {
                return category
            }
        }

        let fileName = (filePath as NSString).lastPathComponent
        let fileExtension = (filePath as NSString).pathExtension.lowercased()

        // 2. Known filename patterns (dotfiles, etc.)
        if fileName == ".gitignore" || fileName == ".gitattributes" || fileName == ".editorconfig" {
            return .configuration
        }
        if fileName == ".env" || fileName == ".env.example" || fileName.hasPrefix(".env.") {
            return .configuration
        }

        // 3. Known dependency manifest files
        if depFiles.contains(fileName) {
            return .dependency
        }

        // 4. Test detection by suffix (check before generic extension)
        if fileName.hasSuffix("Tests.swift") || fileName.hasSuffix("Spec.swift")
            || fileName.hasSuffix("Test.swift") || fileName.hasSuffix("Spec.m")
            || fileName.hasSuffix("test.swift") || fileName.hasSuffix("spec.swift")
            || fileName.hasSuffix("test.m") || fileName.hasSuffix("spec.m")
            || fileName.hasSuffix("Test.java") || fileName.hasSuffix("test.java") {
            return .test
        }

        // 4. Check by file extension groups
        if sourceExtensions.contains(fileExtension) {
            return .source
        }

        if configExtensions.contains(fileExtension) {
            return .configuration
        }

        if docExtensions.contains(fileExtension) {
            return .documentation
        }

        if resourceExtensions.contains(fileExtension) {
            return .resource
        }

        if buildExtensions.contains(fileExtension) {
            return .buildScript
        }

        if migrationExtensions.contains(fileExtension) {
            return .migration
        }

        // 5. SwiftPM manifest file (without .swift extension from above)
        if fileName == "Package.swift" {
            return .dependency
        }

        return .unknown
    }

    /// Classify multiple file paths at once, returning a category breakdown.
    static func classifyAll(filePaths: [String]) -> [ChangeCategory: Int] {
        var breakdown: [ChangeCategory: Int] = [:]
        for path in filePaths {
            let category = classify(filePath: path)
            breakdown[category, default: 0] += 1
        }
        return breakdown
    }

    /// Determine the change scope based on category distribution.
    static func determineScope(categoryBreakdown: [ChangeCategory: Int]) -> ChangeScope {
        let total = categoryBreakdown.values.reduce(0, +)
        guard total > 0 else { return .singleFile }

        // Core categories: source, test, config, dep, build, migration
        let coreCategories = categoryBreakdown.filter {
            $0.key != .documentation && $0.key != .resource && $0.key != .unknown
        }
        let coreCount = coreCategories.values.reduce(0, +)

        // Count distinct core category types (test is tied to source so not counted as separate)
        let nonSourceCore = coreCategories.filter { $0.key != .test && $0.key != .source }
        let distinctModules = nonSourceCore.keys.count

        if distinctModules >= 3 { return .crossModule }
        if distinctModules >= 2 && coreCount > 8 { return .crossModule }
        if distinctModules >= 2 { return .multiFile }
        if coreCount > 10 { return .crossModule }
        if coreCount > 5 { return .moduleLocal }
        if total > 3 { return .multiFile }
        return .singleFile
    }
}

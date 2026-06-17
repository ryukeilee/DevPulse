import Foundation

enum ExcludedDirectoryRules {
    /// Directories to skip during recursive scan.
    /// Mirrors the full exclusion list from the spec.
    static let excludedDirNames: Set<String> = [
        "node_modules",
        ".cache",
        ".npm",
        ".pnpm-store",
        ".cargo",
        ".rustup",
        ".Trash",
        "vendor",
        "dist",
        "build",
        ".next",
        ".turbo",
        "target",
        ".venv",
        "venv",
        "__pycache__",
        "Pods",
        "Carthage",
        ".gradle",
        ".idea",
        "DerivedData",
        "Library",
        "Applications",
        "Downloads"
    ]

    /// Check whether a directory name should be excluded.
    static func isExcluded(dirName: String) -> Bool {
        // Always skip hidden directories EXCEPT .git
        if dirName.hasPrefix(".") && dirName != ".git" {
            return true
        }
        return excludedDirNames.contains(dirName)
    }
}

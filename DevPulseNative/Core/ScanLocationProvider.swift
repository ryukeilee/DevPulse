import Foundation

enum ScanLocationProvider {
    /// Built-in (default) scan locations.
    static let builtInLocations: [String] = [
        "~/Developer",
        "~/Projects",
        "~/Code",
        "~/Workspace",
        "~/GitHub",
        "~/Desktop",
        "~/Documents"
    ]

    /// Expand a tilde-prefixed path to an absolute path.
    static func expandTilde(_ path: String) -> String {
        if path == "~" {
            return NSHomeDirectory()
        }
        if path.hasPrefix("~/") {
            return NSString(string: path).expandingTildeInPath
        }
        return path
    }

    /// Return a set of unique absolute paths from mixed raw locations.
    static func expandAll(_ paths: [String]) -> [String] {
        Array(Set(paths.map(expandTilde))).sorted()
    }

    /// Built-in locations expanded to absolute paths.
    static var builtInAbsolute: [String] {
        expandAll(builtInLocations)
    }

    /// Create toggle objects for all built-in locations.
    static func builtInToggles(_ enabledDefaults: Set<String>? = nil) -> [ScanLocationToggle] {
        let enabled = enabledDefaults ?? Set(builtInAbsolute)
        return builtInLocations.map { raw in
            let absolute = expandTilde(raw)
            return ScanLocationToggle(
                id: absolute,
                path: absolute,
                isEnabled: enabled.contains(absolute),
                isBuiltIn: true
            )
        }
    }
}

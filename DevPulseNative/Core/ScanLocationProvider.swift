import Foundation
import Darwin

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

    private static let containerPathFragments = ["/Library/Containers/", "/Library/Group Containers/"]

    /// Expand a tilde-prefixed path to an absolute path.
    static func expandTilde(_ path: String) -> String {
        let home = resolvedUserHomeDirectory()
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst(1))
        }
        return path
    }

    /// Resolve the real user home directory, avoiding the sandbox container home.
    static func resolvedUserHomeDirectory() -> String {
        let candidates: [String?] = [
            FileManager.default.homeDirectoryForCurrentUser.path,
            NSHomeDirectory(),
            passwdHomeDirectory()
        ]

        for candidate in candidates.compactMap({ $0 }) {
            guard !candidate.isEmpty else { continue }
            if !isAppContainerHome(candidate) {
                return candidate
            }
        }

        return passwdHomeDirectory() ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Normalize persisted scan paths from older sandboxed builds.
    static func normalizePersistedPath(_ path: String) -> String {
        let expanded = expandTilde(path)
        let containerHome = NSHomeDirectory()
        let userHome = resolvedUserHomeDirectory()

        guard !containerHome.isEmpty,
              containerHome != userHome,
              expanded.hasPrefix(containerHome) else {
            return expanded
        }

        return userHome + String(expanded.dropFirst(containerHome.count))
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

    private static func isAppContainerHome(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        return containerPathFragments.contains { normalized.contains($0) }
    }

    private static func passwdHomeDirectory() -> String? {
        let uid = getuid()
        guard let entry = getpwuid(uid), let home = entry.pointee.pw_dir else {
            return nil
        }
        return String(cString: home)
    }
}

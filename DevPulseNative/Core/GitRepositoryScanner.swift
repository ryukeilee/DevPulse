import Foundation

// MARK: - Scan configuration

struct ScanConfig: Codable {
    var enabledBuiltInPaths: Set<String>
    var customPaths: [String]
    let maxDepth: Int
    let changedPreviewLimit: Int
    /// Max concurrent git commands (batch size).
    let maxConcurrentGitOps: Int
    /// Per-git-command timeout in seconds.
    let gitCommandTimeout: TimeInterval
    /// Overall scan timeout in seconds.
    let scanTimeout: TimeInterval
    /// Repos flagged slow are skipped for this many seconds.
    let slowReposkipSeconds: TimeInterval
    /// Above this repo count, only scan recently-active repos.
    let activeRepoThreshold: Int

    static let `default` = ScanConfig(
        enabledBuiltInPaths: Set(ScanLocationProvider.builtInAbsolute),
        customPaths: [],
        maxDepth: 4,
        changedPreviewLimit: 5,
        maxConcurrentGitOps: 6,
        gitCommandTimeout: 5.0,
        scanTimeout: 60.0,
        slowReposkipSeconds: 600.0,
        activeRepoThreshold: 30
    )
}

// MARK: - Slow repo tracker (actor for concurrency safety)

private actor SlowRepoTracker {
    private var repos: [String: Date] = [:]
    private let defaultSkipSeconds: TimeInterval

    init(skipSeconds: TimeInterval = 600) {
        self.defaultSkipSeconds = skipSeconds
    }

    func filterActive(_ paths: [String]) -> (active: [String], skipped: [String]) {
        let now = Date()
        // Purge expired
        repos = repos.filter { $0.value > now }

        var active: [String] = []
        var skipped: [String] = []
        for path in paths {
            if let skipUntil = repos[path], skipUntil > now {
                skipped.append(path)
            } else {
                active.append(path)
            }
        }
        return (active, skipped)
    }

    func markSlow(_ path: String, skipSeconds: TimeInterval) {
        repos[path] = Date().addingTimeInterval(skipSeconds)
    }
}

// MARK: - Scanner

enum GitRepositoryScanner {
    private static let slowTracker = SlowRepoTracker()

    // MARK: - Public API

    /// Run a full scan with all low-power safeguards.
    /// Returns the scan result and an array of warning strings.
    static func scan(config: ScanConfig = .default) async -> (data: AppGroupData, warnings: [String]) {
        let startTime = Date()
        var warnings: [String] = []

        // Phase 1: discover all git repositories
        let discoveredPaths = discoverRepositories(config: config, warnings: &warnings)
        var pathsToScan = discoveredPaths

        // Throttle: if >30 repos, only scan changed/active ones
        if pathsToScan.count > config.activeRepoThreshold {
            let previous = AppGroupStore.read()
            let changedPaths = Set(previous.repositories
                .filter { $0.status == .changed || $0.status == .error }
                .map { $0.path })
            let active = pathsToScan.filter { changedPaths.contains($0) }
            if !active.isEmpty {
                warnings.append("Throttling: scanning \(active.count) active repos out of \(pathsToScan.count) total (threshold \(config.activeRepoThreshold))")
                pathsToScan = active
            }
        }

        // Phase 2: read git status in batches
        let snapshots = await readSnapshotsBatched(
            paths: pathsToScan,
            config: config,
            warnings: &warnings,
            overallDeadline: startTime.addingTimeInterval(config.scanTimeout)
        )

        // Phase 3: sort
        let sorted = RepositorySorter.sort(snapshots)

        // Phase 4: build summary
        let changedCount = sorted.filter { $0.status == .changed }.count
        let errorCount = sorted.filter { $0.status == .error }.count
        let totalChangedFiles = sorted.reduce(0) { $0 + $1.changedFileCount }

        let summary = ScanSummary(
            totalRepositories: discoveredPaths.count,
            changedRepositories: changedCount,
            totalChangedFiles: totalChangedFiles,
            errorRepositories: errorCount
        )

        let result = AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: DateFormatting.nowISO(),
            scanSummary: summary,
            repositories: sorted
        )

        // Phase 5: persist to App Group
        AppGroupStore.write(result)

        let elapsed = Date().timeIntervalSince(startTime)
        print("[DevPulse] Scan completed in \(String(format: "%.2f", elapsed))s: "
              + "\(sorted.count) repos, \(changedCount) changed, \(errorCount) errors")
        for warning in warnings {
            print("[DevPulse] ⚠ \(warning)")
        }

        return (result, warnings)
    }

    // MARK: - Repository discovery

    private static func discoverRepositories(config: ScanConfig,
                                             warnings: inout [String]) -> [String] {
        var discovered = Set<String>()

        let allPaths = Array(config.enabledBuiltInPaths) + config.customPaths
        for rawPath in allPaths {
            let root = ScanLocationProvider.expandTilde(rawPath)

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            walkDirectory(root, config: config, discovered: &discovered, warnings: &warnings)
        }

        return Array(discovered).sorted()
    }

    private static func walkDirectory(_ directory: String,
                                      config: ScanConfig,
                                      depth: Int = 0,
                                      discovered: inout Set<String>,
                                      warnings: inout [String]) {
        guard depth <= config.maxDepth else { return }

        if isGitRepository(directory) {
            discovered.insert(directory)
            return
        }

        let dirName = (directory as NSString).lastPathComponent
        if ExcludedDirectoryRules.isExcluded(dirName: dirName) {
            return
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return
        }

        for entry in entries {
            let fullPath = (directory as NSString).appendingPathComponent(entry)
            let entryName = (fullPath as NSString).lastPathComponent

            guard !ExcludedDirectoryRules.isExcluded(dirName: entryName) else { continue }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            walkDirectory(fullPath,
                          config: config,
                          depth: depth + 1,
                          discovered: &discovered,
                          warnings: &warnings)
        }
    }

    // MARK: - Git repository detection

    static func isGitRepository(_ directory: String) -> Bool {
        let gitPath = (directory as NSString).appendingPathComponent(".git")

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) {
            return true
        }

        if let topLevel = ProcessRunner.run(
            arguments: ["rev-parse", "--show-toplevel"],
            workingDirectory: directory
        ) {
            let resolved = ScanLocationProvider.expandTilde(
                (topLevel as NSString).resolvingSymlinksInPath
            )
            let dirResolved = (directory as NSString).resolvingSymlinksInPath
            return resolved == dirResolved
        }

        return false
    }

    // MARK: - Batched snapshot reading

    /// Read git status in batches to limit concurrent git processes.
    private static func readSnapshotsBatched(paths: [String],
                                             config: ScanConfig,
                                             warnings: inout [String],
                                             overallDeadline: Date) async -> [RepositorySnapshot] {
        var results: [RepositorySnapshot] = []
        results.reserveCapacity(paths.count)

        // Filter out slow repos
        let (activePaths, skippedPaths) = await filterSlowRepos(paths)
        let skippedSlow = skippedPaths
        for skipped in skippedSlow {
            let name = (skipped as NSString).lastPathComponent
            results.append(RepositorySnapshot(
                id: stableHash(skipped),
                name: name,
                path: skipped,
                branch: "unknown",
                status: .error,
                changedFileCount: 0,
                changedFilesPreview: [],
                risk: .low,
                lastScannedAt: DateFormatting.nowISO(),
                lastChangedAt: nil,
                errorMessage: "Skipped (previously slow)",
                isPinned: false
            ))
        }

        // Process in batches
        let batchSize = max(1, config.maxConcurrentGitOps)
        for batchStart in stride(from: 0, to: activePaths.count, by: batchSize) {
            // Check overall timeout
            if Date() > overallDeadline {
                warnings.append("Scan timeout reached; \(activePaths.count - batchStart) repos skipped")
                for i in batchStart..<activePaths.count {
                    let path = activePaths[i]
                    let name = (path as NSString).lastPathComponent
                    results.append(RepositorySnapshot(
                        id: stableHash(path),
                        name: name,
                        path: path,
                        branch: "unknown",
                        status: .error,
                        changedFileCount: 0,
                        changedFilesPreview: [],
                        risk: .low,
                        lastScannedAt: DateFormatting.nowISO(),
                        lastChangedAt: nil,
                        errorMessage: "Scan timeout",
                        isPinned: false
                    ))
                }
                break
            }

            let batchEnd = min(batchStart + batchSize, activePaths.count)
            let batch = Array(activePaths[batchStart..<batchEnd])

            // Scan batch concurrently via serial iteration (Process is synchronous)
            // Each git command has its own timeout
            for path in batch {
                let start = Date()
                let snapshot = readSingleSnapshot(repoPath: path, config: config, warnings: &warnings)
                let elapsed = Date().timeIntervalSince(start)

                // Track slow repos (>3s)
                if elapsed > 3.0 {
                    await trackSlowRepo(path, skipSeconds: config.slowReposkipSeconds)
                    warnings.append("Slow repo: \(snapshot.name) (\(String(format: "%.1f", elapsed))s)")
                }

                results.append(snapshot)
            }
        }

        return results
    }

    // MARK: - Slow repo tracking

    private static func filterSlowRepos(_ paths: [String]) async -> (active: [String], skipped: [String]) {
        await slowTracker.filterActive(paths)
    }

    private static func trackSlowRepo(_ path: String, skipSeconds: TimeInterval) async {
        await slowTracker.markSlow(path, skipSeconds: skipSeconds)
    }

    // MARK: - Single snapshot

    private static func readSingleSnapshot(repoPath: String,
                                           config: ScanConfig,
                                           warnings: inout [String]) -> RepositorySnapshot {
        let name = (repoPath as NSString).lastPathComponent
        let id = stableHash(repoPath)

        let branch = ProcessRunner.run(
            arguments: ["branch", "--show-current"],
            workingDirectory: repoPath,
            timeout: config.gitCommandTimeout
        ) ?? "unknown"

        guard let statusOutput = ProcessRunner.run(
            arguments: ["status", "--short"],
            workingDirectory: repoPath,
            timeout: config.gitCommandTimeout
        ) else {
            return RepositorySnapshot(
                id: id,
                name: name,
                path: repoPath,
                branch: branch.isEmpty ? "detached" : branch,
                status: .error,
                changedFileCount: 0,
                changedFilesPreview: [],
                risk: .low,
                lastScannedAt: DateFormatting.nowISO(),
                lastChangedAt: nil,
                errorMessage: "Failed to run git status",
                isPinned: false
            )
        }

        let entries = GitStatusParser.parseStatusEntries(statusOutput)
        let changedFiles = entries.map(\.path)
        let changedCount = changedFiles.count

        let status: RepositoryStatus = changedCount > 0 ? .changed : .clean
        let risk = RiskHintEngine.assess(changedFiles: changedFiles)

        let lastCommitAt = ProcessRunner.run(
            arguments: ["log", "-1", "--pretty=%cI"],
            workingDirectory: repoPath,
            timeout: config.gitCommandTimeout
        )

        // Preview capped at 5
        let preview = Array(changedFiles.prefix(config.changedPreviewLimit))

        return RepositorySnapshot(
            id: id,
            name: name,
            path: repoPath,
            branch: branch.isEmpty ? "detached" : branch,
            status: status,
            changedFileCount: changedCount,
            changedFilesPreview: preview,
            risk: risk.level,
            lastScannedAt: DateFormatting.nowISO(),
            lastChangedAt: status == .changed ? (lastCommitAt ?? DateFormatting.nowISO()) : lastCommitAt,
            errorMessage: nil,
            isPinned: false
        )
    }

    // MARK: - Helpers

    private static func stableHash(_ input: String) -> String {
        var hasher = Hasher()
        hasher.combine(input)
        let hashValue = hasher.finalize()
        return String(format: "%08x", hashValue)
    }
}

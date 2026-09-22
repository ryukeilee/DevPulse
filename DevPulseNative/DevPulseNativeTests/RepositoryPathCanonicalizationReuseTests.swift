import Darwin
import Foundation
import Testing
@testable import DevPulse

/// Coverage for the refresh-scoped reuse of `RepositoryIdentity.canonicalPath`.
///
/// Two things must hold:
///   1. Reuse never changes a result — the canonical path and repository ID for
///      a given input are byte-identical with and without a scope, including
///      symlinks, relative paths, `~`, case differences, trailing slashes and
///      paths that do not exist.
///   2. Reuse is confined to one refresh and removes provably redundant work —
///      measured with deterministic call counters, not wall clock.
@Suite(.serialized)
struct RepositoryPathCanonicalizationReuseTests {

    // MARK: - Fixtures

    private static let scanConfig = ScanConfig(
        enabledBuiltInPaths: [],
        customPaths: [],
        maxDepth: 4,
        changedPreviewLimit: 5,
        maxConcurrentGitOps: 10,
        gitCommandTimeout: 5.0,
        scanTimeout: 60.0,
        slowReposkipSeconds: 600.0,
        activeRepoThreshold: 30
    )

    private enum FixtureError: Error {
        case gitFailed([String], String)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw FixtureError.gitFailed(arguments, output)
        }
        return String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func createGitRepo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: url)
        try runGit(["config", "user.name", "DevPulse Tests"], in: url)
        try runGit(["config", "user.email", "devpulse-tests@example.com"], in: url)
        try "initial\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], in: url)
        try runGit(["commit", "-q", "-m", "Initial commit"], in: url)
    }

    private func scratchRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-canon-\(name)-\(UUID().uuidString)")
    }

    // MARK: - 1. Result equivalence

    /// Inputs that exercise every branch of `canonicalPath`: `~` expansion,
    /// legacy container migration, sandbox migration, symlink resolution,
    /// trailing separators, `..`, case differences and non-existent paths.
    private func equivalenceInputs(scratch: URL) -> [String] {
        let fileManager = FileManager.default
        let target = scratch.appendingPathComponent("target")
        let link = scratch.appendingPathComponent("link")
        let nestedTarget = scratch.appendingPathComponent("nested/inside")
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: nestedTarget, withIntermediateDirectories: true)
        try? fileManager.createSymbolicLink(at: link, withDestinationURL: target)

        let home = ScanLocationProvider.resolvedUserHomeDirectory()
        var inputs: [String] = [
            "",
            "   ",
            "\n\t ",
            scratch.path,
            scratch.path + "/",
            scratch.path + "//",
            scratch.path + "/./",
            scratch.path + "/../" + scratch.lastPathComponent,
            link.path,
            link.path + "/",
            link.path + "/README.md",
            target.path,
            "/tmp",
            "/TMP",
            "/tmp/",
            "/does/not/exist/devpulse-canonicalization",
            "/",
            "~",
            "~/",
            "~/devpulse-canonicalization-missing",
            "relative/path",
            "./relative/path",
            "..",
            home,
            home + "/",
            home + "/Library/Containers/local.devpulse.app/Data",
            home + "/Library/Containers/local.devpulse.app/Data/Repos",
            home + "/Library/Containers/local.devpulse.app/DataX",
            NSHomeDirectory(),
            NSHomeDirectory() + "/devpulse-canonicalization-missing"
        ]
        if NSHomeDirectory() != home {
            inputs.append(NSHomeDirectory() + "/Repos")
            inputs.append(NSHomeDirectory() + "X/Repos")
        }
        return inputs
    }

    @Test func scopedAndUnscopedCanonicalizationAreByteIdentical() async throws {
        let scratch = scratchRoot("equivalence")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let inputs = equivalenceInputs(scratch: scratch)
        var comparisons: [String] = []

        for input in inputs {
            let unscoped = RepositoryIdentity.canonicalPath(input)

            let scope = RepositoryIdentity.CanonicalizationScope()
            let scoped = await RepositoryIdentity.withCanonicalizationScope(scope) {
                // First call computes, second call reuses. Both must agree.
                (RepositoryIdentity.canonicalPath(input),
                 RepositoryIdentity.canonicalPath(input))
            }

            comparisons.append(
                "input=\(input.debugDescription) unscoped=\(unscoped.debugDescription) "
                + "scoped1=\(scoped.0.debugDescription) scoped2=\(scoped.1.debugDescription)"
            )

            #expect(scoped.0 == unscoped, "canonicalPath changed under a scope: \(comparisons.last!)")
            #expect(scoped.1 == unscoped, "reused canonicalPath differs: \(comparisons.last!)")
        }

        // The same set through one scope: results must match the unscoped
        // result for every input, and `id(for:)` must be unchanged as well.
        let sharedScope = RepositoryIdentity.CanonicalizationScope()
        let (repeatedPaths, repeatedIDs) = await RepositoryIdentity.withCanonicalizationScope(sharedScope) {
            (inputs.map { RepositoryIdentity.canonicalPath($0) },
             inputs.map { RepositoryIdentity.id(for: $0) })
        }
        for (index, input) in inputs.enumerated() {
            #expect(repeatedPaths[index] == RepositoryIdentity.canonicalPath(input),
                    "single-scope run differs for input \(input.debugDescription)")
            #expect(repeatedIDs[index] == RepositoryIdentity.id(for: input),
                    "single-scope id differs for input \(input.debugDescription)")
        }
        let metrics = sharedScope.metrics
        // Two lookups per input: `canonicalPath` and the `canonicalPath` inside `id(for:)`.
        #expect(metrics.lookups == inputs.count * 2)
        #expect(metrics.computations == metrics.distinctInputs)
        #expect(metrics.computations + metrics.reuses == metrics.lookups)

        print("canonicalization_equivalence inputs=\(inputs.count) "
              + "lookups=\(metrics.lookups) computations=\(metrics.computations) "
              + "reuses=\(metrics.reuses) distinct=\(metrics.distinctInputs)")
    }

    /// A per-process unique scratch layout. The input forms and table structure
    /// stay stable, while the unique root keeps concurrent test hosts isolated.
    private static let tableScratchPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("devpulse-canon-table-\(UUID().uuidString)")
        .path
    private static let tableInputs = [
        "",
        "   ",
        "\n\t ",
        tableScratchPath,
        tableScratchPath + "/",
        tableScratchPath + "//",
        tableScratchPath + "/./",
        tableScratchPath + "/target",
        tableScratchPath + "/target/",
        tableScratchPath + "/link",
        tableScratchPath + "/link/",
        tableScratchPath + "/link/README.md",
        tableScratchPath + "/target/../link",
        "/tmp",
        "/TMP",
        "/tmp/",
        "/does/not/exist/devpulse-canonicalization",
        "/",
        "~",
        "~/",
        "~/devpulse-canonicalization-missing",
        "nonexistent-sibling",
        "nonexistent-sibling/child"
    ]

    /// Create the deterministic scratch layout used by `tableInputs`.
    private static func prepareTableScratch() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            atPath: tableScratchPath + "/target",
            withIntermediateDirectories: true
        )
        try "table\n".write(
            toFile: tableScratchPath + "/target/README.md",
            atomically: true,
            encoding: .utf8
        )
        try fileManager.createSymbolicLink(
            atPath: tableScratchPath + "/link",
            withDestinationPath: tableScratchPath + "/target"
        )
    }

    /// Print `input -> canonicalPath -> id` for a fixed set of input forms.
    /// The unique scratch root varies per test host. Printed, never asserted:
    /// the assertions live in
    /// `scopedAndUnscopedCanonicalizationAreByteIdentical`.
    @Test func canonicalizationTableIsStable() async throws {
        try Self.prepareTableScratch()
        defer { try? FileManager.default.removeItem(atPath: Self.tableScratchPath) }

        let scope = RepositoryIdentity.CanonicalizationScope()
        let rows = await RepositoryIdentity.withCanonicalizationScope(scope) {
            Self.tableInputs.map { input in
                (input,
                 RepositoryIdentity.canonicalPath(input),
                 RepositoryIdentity.id(for: input))
            }
        }

        print("canonicalization_table_begin\tcwd=\(FileManager.default.currentDirectoryPath.debugDescription)")
        for row in rows {
            print("row\t\(row.0.debugDescription)\t\(row.1.debugDescription)\t\(row.2)")
        }
        print("canonicalization_table_end rows=\(rows.count)")
    }

    @Test func reusedIDMatchesUnscopedID() async throws {
        let scratch = scratchRoot("identity")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: scratch)

        let inputs = [scratch.path, link.path, scratch.path + "/", "~", "/does/not/exist/devpulse"]
        let scope = RepositoryIdentity.CanonicalizationScope()
        let scopedIDs = await RepositoryIdentity.withCanonicalizationScope(scope) {
            inputs.map { RepositoryIdentity.id(for: $0) } + inputs.map { RepositoryIdentity.id(for: $0) }
        }
        let unscopedIDs = inputs.map { RepositoryIdentity.id(for: $0) } + inputs.map { RepositoryIdentity.id(for: $0) }
        #expect(scopedIDs == unscopedIDs)
    }

    // MARK: - 2. Deterministic refresh counts

    private struct RefreshMeasurement {
        let metrics: RepositoryIdentity.CanonicalizationScope.Metrics
        let digest: [String]
        let repositoryCount: Int
        let warnings: [String]
    }

    private func measureIncrementalRefresh(
        root: URL,
        repoPaths: [String],
        previous: AppGroupData,
        reuseEnabled: Bool
    ) async -> RefreshMeasurement {
        let scope = RepositoryIdentity.CanonicalizationScope(reuseEnabled: reuseEnabled)
        let result = await RepositoryIdentity.withCanonicalizationScope(scope) {
            await RefreshEngine().execute(
                config: Self.scanConfig,
                scanRoots: [root.path],
                knownRepositoryPaths: repoPaths,
                forceRepositoryDiscovery: false,
                previousSnapshot: previous,
                source: .timer
            )
        }
        return RefreshMeasurement(
            metrics: scope.metrics,
            digest: result.data.repositories
                .map { "\($0.id)|\($0.path)|\($0.status.rawValue)|\($0.isPinned)" }
                .sorted(),
            repositoryCount: result.data.repositories.count,
            warnings: result.warnings.sorted()
        )
    }

    private func previousSnapshot(for repoPaths: [String], timestamp: String) -> AppGroupData {
        let snapshots: [RepositorySnapshot] = repoPaths.enumerated().map { index, path in
            RepositorySnapshot(
                id: RepositoryIdentity.id(for: path),
                name: (path as NSString).lastPathComponent,
                path: path,
                branch: "main",
                status: .clean,
                modifiedFileCount: 0,
                addedFileCount: 0,
                deletedFileCount: 0,
                untrackedFileCount: 0,
                stagedFileCount: 0,
                unstagedFileCount: 0,
                conflictedFileCount: nil,
                aheadCount: nil,
                behindCount: nil,
                hasUpstream: true,
                changedFileCount: 0,
                changedFilesPreview: [],
                risk: .low,
                lastScannedAt: timestamp,
                lastChangedAt: timestamp,
                errorMessage: nil,
                isPinned: index == 0
            )
        }
        return AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: nil,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary.build(from: snapshots),
            repositories: snapshots,
            storageRevision: 0,
            persistenceState: .committed
        )
    }

    @Test func incrementalRefreshComputesEachDistinctPathOnce() async throws {
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        var report: [String] = []

        for repoCount in [5, 20] {
            let root = scratchRoot("count-\(repoCount)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            var repoPaths: [String] = []
            for index in 0..<repoCount {
                let url = root.appendingPathComponent("repo-\(index)")
                try createGitRepo(at: url)
                repoPaths.append(RepositoryIdentity.canonicalPath(url.path))
            }
            let previous = previousSnapshot(for: repoPaths, timestamp: timestamp)

            let before = await measureIncrementalRefresh(
                root: root, repoPaths: repoPaths, previous: previous, reuseEnabled: false
            )
            let after = await measureIncrementalRefresh(
                root: root, repoPaths: repoPaths, previous: previous, reuseEnabled: true
            )

            let line = "canonicalization repos=\(repoCount) "
                + "before{lookups=\(before.metrics.lookups),computations=\(before.metrics.computations),"
                + "reuses=\(before.metrics.reuses),distinct=\(before.metrics.distinctInputs)} "
                + "after{lookups=\(after.metrics.lookups),computations=\(after.metrics.computations),"
                + "reuses=\(after.metrics.reuses),distinct=\(after.metrics.distinctInputs)}"
            report.append(line)
            print(line)

            // The measured scenario must be a real incremental refresh.
            #expect(before.repositoryCount == repoCount)
            #expect(after.repositoryCount == repoCount)

            // Both runs must observe the same repositories, IDs, paths and warnings.
            #expect(after.digest == before.digest, "reuse changed the refresh result for repos=\(repoCount)")
            #expect(after.warnings == before.warnings)

            // Deterministic reduction: the same number of lookups, no reuse before,
            // and exactly one computation per distinct input after.
            #expect(after.metrics.lookups == before.metrics.lookups)
            #expect(before.metrics.reuses == 0)
            #expect(before.metrics.computations == before.metrics.lookups)
            #expect(after.metrics.computations == after.metrics.distinctInputs)
            #expect(after.metrics.computations + after.metrics.reuses == after.metrics.lookups)
            #expect(after.metrics.computations < before.metrics.computations)
        }

        print("canonicalization_report\n" + report.joined(separator: "\n"))
    }

    // MARK: - 3. Scope lifetime

    /// Reuse must not survive its scope: a path that only starts existing after
    /// one refresh has to be resolved again by the next one — including the
    /// symlink resolution that a missing path skips.
    @Test func reuseDoesNotSurviveTheRefresh() async throws {
        let scratch = scratchRoot("lifetime")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let base = scratch.appendingPathComponent("base")
        let link = scratch.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)

        let throughLink = link.appendingPathComponent("created-later")
        let throughBase = base.appendingPathComponent("created-later")

        let whileMissing = await RepositoryIdentity.withRefreshCanonicalizationScope {
            RepositoryIdentity.canonicalPath(throughLink.path)
        }
        #expect(whileMissing.hasSuffix("/link/created-later"),
                "a missing path must keep the unresolved form, got \(whileMissing)")

        try FileManager.default.createDirectory(at: throughBase, withIntermediateDirectories: true)

        let afterCreation = await RepositoryIdentity.withRefreshCanonicalizationScope {
            RepositoryIdentity.canonicalPath(throughLink.path)
        }
        #expect(afterCreation.hasSuffix("/base/created-later"),
                "the next refresh must resolve the symlink, got \(afterCreation)")
        #expect(afterCreation != whileMissing)
        #expect(afterCreation == RepositoryIdentity.canonicalPath(throughLink.path))
    }

    /// Nested scopes must share exactly one reuse map so the outermost refresh
    /// owns the lifetime.
    @Test func nestedScopesShareOneReuseMap() async throws {
        let outer = RepositoryIdentity.CanonicalizationScope()
        let answer = await RepositoryIdentity.withCanonicalizationScope(outer) {
            await RepositoryIdentity.withRefreshCanonicalizationScope {
                RepositoryIdentity.canonicalPath("/tmp") + "|" + RepositoryIdentity.canonicalPath("/tmp")
            }
        }
        let parts = answer.split(separator: "|").map(String.init)
        #expect(parts.count == 2 && parts[0] == parts[1])
        #expect(outer.metrics.reuses == 1, "nested refresh must inherit the outer scope: \(outer.metrics)")
    }

    // MARK: - 4. Known remainder

    /// Mirrors `ScanScheduler.applyPins()` exactly at its path-processing seam:
    /// filtering, identity migration and sort. Reuse is scoped to that one
    /// synchronous operation and cannot observe later pin/ignore mutations.
    @Test func applyPinsCanonicalizationIsLocalAndEquivalent() async throws {
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let repoCount = 20
        let paths = (0..<repoCount).map { "/devpulse-remainder/repo-\($0)" }
        let data = previousSnapshot(for: paths, timestamp: timestamp)

        func process(reuseEnabled: Bool) -> (RepositoryIdentity.CanonicalizationScope.Metrics, AppGroupData) {
            let scope = RepositoryIdentity.CanonicalizationScope(reuseEnabled: reuseEnabled)
            let result = RepositoryIdentity.withCanonicalizationScopeSync(scope) {
                let scoped = RepositoryScope.filtering(data, excluding: [])
                let migration = RepositoryIdentityMigration.migrate(snapshot: scoped, pinnedIDs: [])
                var repositories = migration.snapshot.repositories
                repositories = RepositorySorter.sort(repositories)
                return AppGroupData(
                    schemaVersion: migration.snapshot.schemaVersion,
                    generatedAt: migration.snapshot.generatedAt,
                    writtenAt: migration.snapshot.writtenAt,
                    lastSuccessfulRefreshAt: migration.snapshot.lastSuccessfulRefreshAt,
                    historySchemaVersion: migration.snapshot.historySchemaVersion,
                    historyRecordingEnabled: migration.snapshot.historyRecordingEnabled,
                    scanSummary: migration.snapshot.scanSummary,
                    repositories: repositories,
                    recentActivityEvents: migration.snapshot.recentActivityEvents,
                    repositoryUnavailableSinceByPath: migration.snapshot.repositoryUnavailableSinceByPath,
                    storageRevision: migration.snapshot.storageRevision,
                    persistenceState: migration.snapshot.persistenceState,
                    pendingItemWidgetSummary: migration.snapshot.pendingItemWidgetSummary,
                    isRefreshing: migration.snapshot.isRefreshing,
                    discoveryWasIncomplete: migration.snapshot.discoveryWasIncomplete,
                    appVersion: migration.snapshot.appVersion,
                    storageFormatVersion: migration.snapshot.storageFormatVersion
                )
            }
            return (scope.metrics, result)
        }

        let before = process(reuseEnabled: false)
        let after = process(reuseEnabled: true)
        print("canonicalization_scheduler_remainder repos=\(repoCount) "
              + "before{lookups=\(before.0.lookups),computations=\(before.0.computations),distinctInputs=\(before.0.distinctInputs)} "
              + "after{lookups=\(after.0.lookups),computations=\(after.0.computations),distinctInputs=\(after.0.distinctInputs)}")

        #expect(after.0.lookups == before.0.lookups)
        #expect(before.0.computations == before.0.lookups)
        #expect(after.0.computations < before.0.computations)
        #expect(after.0.computations == after.0.distinctInputs)
        #expect(after.1 == before.1, "local reuse changed the applyPins processing result")

        // A following invocation gets a new scope and observes changed ignore
        // input rather than reusing any prior filtered result.
        let ignoredPath = RepositoryIdentity.canonicalPath(paths[0])
        let nextScope = RepositoryIdentity.CanonicalizationScope()
        let next = RepositoryIdentity.withCanonicalizationScopeSync(nextScope) {
            RepositoryScope.filtering(data, excluding: [ignoredPath])
        }
        #expect(next.repositories.count == repoCount - 1)
        #expect(!next.repositories.contains { $0.path == paths[0] })
    }

    // MARK: - 5. Cost of one canonicalization

    /// Per-call cost of a single `canonicalPath` computation, printed but never
    /// asserted. It exists so the deterministic counts above can be read as an
    /// order-of-magnitude time figure without relying on end-to-end wall clock,
    /// which on this project is dominated by concurrent builds and the installed
    /// app's App Group activity. Load average is printed so the sample can be
    /// judged.
    @Test func canonicalPathComputationCost() async throws {
        let scratch = scratchRoot("cost")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let base = scratch.appendingPathComponent("base")
        let link = scratch.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)

        let inputs = [base.path, link.path + "/",
                      scratch.appendingPathComponent("missing").path,
                      "~/devpulse-cost-missing", "~"]
        let iterations = 200

        for _ in 0..<20 { for input in inputs { _ = RepositoryIdentity.canonicalPath(input) } }

        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations {
            for input in inputs { _ = RepositoryIdentity.canonicalPath(input) }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let samples = iterations * inputs.count
        let perCallMicroseconds = elapsed / Double(samples) * 1_000_000

        var loads = [Double](repeating: 0, count: 3)
        let loadCount = Int(getloadavg(&loads, 3))
        let loadText = loadCount > 0
            ? loads.prefix(loadCount).map { String(format: "%.2f", $0) }.joined(separator: "/")
            : "n/a"

        print(String(format: "canonicalization_cost per_call_us=%.2f samples=%d total_ms=%.1f loadavg=%@",
                     perCallMicroseconds, samples, elapsed * 1000, loadText))
    }
}

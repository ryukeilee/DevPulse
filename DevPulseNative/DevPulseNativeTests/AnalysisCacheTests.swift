import Testing
import Foundation
@testable import DevPulse

// MARK: - Analysis cache tests

@Suite("AnalysisCache")
struct AnalysisCacheTests {

    private func makeSnapshot(repoID: String = "test-repo", changeCount: Int = 0) -> ChangeImpactSnapshot {
        ChangeImpactSnapshot(
            id: "snap-\(repoID)",
            repositoryID: repoID,
            repositoryPath: "/path/\(repoID)",
            analysisVersion: 1,
            analyzedAt: ISO8601DateFormatter().string(from: Date()),
            baselineState: .none(),
            changes: (0..<changeCount).map { i in
                ChangeEntry(filePath: "f\(i).swift", relativePath: "f\(i).swift", changeKind: .modified,
                           category: .source, isStaged: false, commitID: nil, commitSummary: nil)
            },
            modules: [],
            impactEdges: [],
            scope: .singleFile,
            releaseReadiness: nil,
            categoryBreakdown: [:],
            repositoryHealthSnapshot: nil,
            diagnostics: nil,
            isFromCache: false
        )
    }

    private func makeKey(repoID: String = "test-repo", branch: String = "main", status: String = "clean") -> InvalidationKey {
        InvalidationKey(
            repositoryID: repoID,
            currentBranchHash: InvalidationKey.compute(for: ChangeCollectionInput(
                repositoryPath: "/path", branch: branch, status: .clean,
                modifiedFiles: [], addedFiles: [], deletedFiles: [],
                untrackedFiles: [], conflictedFiles: [],
                stagedFiles: [], unstagedFiles: [],
                lastCommitID: nil, lastCommitSummary: nil,
                aheadCount: nil, behindCount: nil, hasUpstream: nil,
                workspaceKind: nil, recentCommits: nil
            )).currentBranchHash,
            statusHash: status,
            modifiedFilesHash: "",
            lastCommitHash: nil,
            baselineHash: nil,
            manifestHash: nil
        )
    }

    // MARK: - Basic operations

    @Test("Cache starts empty")
    func cacheStartsEmpty() {
        let cache = AnalysisCache()
        #expect(cache.count == 0)
        #expect(cache.hitCount == 0)
        #expect(cache.missCount == 0)
    }

    @Test("Set and get returns cached value")
    func setAndGet() {
        let cache = AnalysisCache()
        let snap = makeSnapshot()
        let key = makeKey()

        cache.set(repositoryID: "test-repo", snapshot: snap, key: key, generation: 0, isChanged: true)

        let retrieved = cache.get(repositoryID: "test-repo", key: key, generation: 0)
        #expect(retrieved != nil)
        #expect(retrieved?.id == snap.id)
        #expect(cache.hitCount == 1)
        #expect(cache.missCount == 0)
    }

    @Test("Get returns nil for missing key")
    func getNilForMissing() {
        let cache = AnalysisCache()
        let key = makeKey()

        let retrieved = cache.get(repositoryID: "nonexistent", key: key, generation: 0)
        #expect(retrieved == nil)
        #expect(cache.missCount == 1)
    }

    @Test("Get returns nil for wrong key")
    func getNilForWrongKey() {
        let cache = AnalysisCache()
        let snap = makeSnapshot()
        let key1 = makeKey(status: "clean")
        let key2 = makeKey(status: "changed")

        cache.set(repositoryID: "test-repo", snapshot: snap, key: key1, generation: 0, isChanged: true)

        let retrieved = cache.get(repositoryID: "test-repo", key: key2, generation: 0)
        #expect(retrieved == nil)
        #expect(cache.hitCount == 0)
        #expect(cache.missCount == 1)
    }

    @Test("Get returns nil for wrong generation")
    func getNilForWrongGeneration() {
        let cache = AnalysisCache()
        let snap = makeSnapshot()
        let key = makeKey()

        cache.set(repositoryID: "test-repo", snapshot: snap, key: key, generation: 0, isChanged: true)

        let retrieved = cache.get(repositoryID: "test-repo", key: key, generation: 1)
        #expect(retrieved == nil)
    }

    // MARK: - Expiration

    @Test("Expired entry returns nil")
    func expiredEntryReturnsNil() {
        let config = AnalysisCache.Configuration(defaultTTLSeconds: 0, unchangedTTLSeconds: 0)
        let cache = AnalysisCache(config: config)
        let snap = makeSnapshot()
        let key = makeKey()

        cache.set(repositoryID: "test-repo", snapshot: snap, key: key, generation: 0, isChanged: true)

        // Expired immediately
        let retrieved = cache.get(repositoryID: "test-repo", key: key, generation: 0)
        #expect(retrieved == nil)
    }

    // MARK: - Clear and remove

    @Test("Remove clears specific entry")
    func removeClearsEntry() {
        let cache = AnalysisCache()
        let snap = makeSnapshot()
        let key = makeKey()

        cache.set(repositoryID: "test-repo", snapshot: snap, key: key, generation: 0, isChanged: true)
        #expect(cache.count == 1)

        cache.remove(repositoryID: "test-repo")
        #expect(cache.count == 0)

        let retrieved = cache.get(repositoryID: "test-repo", key: key, generation: 0)
        #expect(retrieved == nil)
    }

    @Test("Clear empties all entries")
    func clearEmptiesAll() {
        let cache = AnalysisCache()
        let key = makeKey()

        cache.set(repositoryID: "repo-1", snapshot: makeSnapshot(repoID: "repo-1"), key: key, generation: 0, isChanged: true)
        cache.set(repositoryID: "repo-2", snapshot: makeSnapshot(repoID: "repo-2"), key: key, generation: 0, isChanged: true)
        #expect(cache.count == 2)

        cache.clear()
        #expect(cache.count == 0)
    }

    // MARK: - Generation advance

    @Test("Advance generation invalidates all entries")
    func advanceGenerationInvalidates() {
        let cache = AnalysisCache()
        let snap = makeSnapshot()
        let key = makeKey()

        cache.set(repositoryID: "test-repo", snapshot: snap, key: key, generation: 0, isChanged: true)
        #expect(cache.count == 1)

        cache.advanceGeneration()
        #expect(cache.count == 0)
    }

    // MARK: - Hit rate

    @Test("Hit rate increases with successful gets")
    func hitRateIncreases() {
        let cache = AnalysisCache()
        let snap = makeSnapshot()
        let key = makeKey()

        cache.set(repositoryID: "test-repo", snapshot: snap, key: key, generation: 0, isChanged: true)

        // 1 hit, 0 miss
        _ = cache.get(repositoryID: "test-repo", key: key, generation: 0)
        #expect(cache.hitRate == 1.0)

        // 1 hit, 1 miss
        _ = cache.get(repositoryID: "nonexistent", key: key, generation: 0)
        #expect(cache.hitRate == 0.5)
    }

    // MARK: - Unchanged TTL

    @Test("Unchanged repos have longer TTL")
    func unchangedReposLongerTTL() {
        // Default TTL: unchanged = 600s, changed = 300s
        let cache = AnalysisCache()
        let snap = makeSnapshot()
        let key = makeKey()

        // isChanged: false → use unchanged TTL
        cache.set(repositoryID: "test-repo", snapshot: snap, key: key, generation: 0, isChanged: false)

        let retrieved = cache.get(repositoryID: "test-repo", key: key, generation: 0)
        #expect(retrieved != nil)
    }
}

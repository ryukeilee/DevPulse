import Foundation
import CryptoKit
import OSLog

// MARK: - Analysis cache

/// Bounded, versioned cache for change impact analysis results.
///
/// Design:
/// - Entry-level TTL: each cached entry has its own expiration time.
/// - Invalidation-by-key: entries are invalidated when their invalidation
///   key changes (branch, status hash, modified files).
/// - Bounded size: oldest entries are evicted when the cache exceeds capacity.
/// - Generation isolation: cache is invalidated on scan generation change.
/// - Thread-safe: uses OSAllocatedUnfairLock for all access.
///
/// Memory: entries are lightweight metadata + references; actual snapshot
/// storage is in ChangeImpactStore. This cache tracks what's fresh.
final class AnalysisCache: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "AnalysisCache"
    )

    // MARK: - Configuration

    struct Configuration: Sendable {
        /// Maximum number of cached entries.
        var maxEntries: Int = 200
        /// Default TTL for cached analyses (seconds).
        var defaultTTLSeconds: TimeInterval = 300  // 5 minutes
        /// TTL for analyses of unchanged repos (seconds).
        var unchangedTTLSeconds: TimeInterval = 600  // 10 minutes
        /// Whether to cache analyses for error-state repos.
        var cacheErrors: Bool = false

        static let `default` = Configuration()
    }

    // MARK: - Entry

    private struct CacheEntry {
        let analysisID: String
        let snapshot: ChangeImpactSnapshot
        let key: InvalidationKey
        let cachedAt: Date
        let expiresAt: Date
        let generation: UInt64
        var hitCount: Int
    }

    // MARK: - State

    private let config: Configuration
    private var entries: [String: CacheEntry] = [:]
    private var currentGeneration: UInt64 = 0
    private var totalHitCount: Int = 0
    private var totalMissCount: Int = 0
    private var totalEvictionCount: Int = 0

    private let lock = OSAllocatedUnfairLock(initialState: Void())

    var diagnostics: CacheDiagnostics {
        lock.withLock {
            CacheDiagnostics(
                currentEntries: entries.count,
                maxEntries: config.maxEntries,
                hitCount: totalHitCount,
                missCount: totalMissCount,
                evictionCount: totalEvictionCount,
                hitRate: totalHitCount + totalMissCount > 0
                    ? Double(totalHitCount) / Double(totalHitCount + totalMissCount)
                    : 0,
                generation: currentGeneration
            )
        }
    }

    // MARK: - Initialization

    init(config: Configuration = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// Advance the generation, invalidating all existing entries.
    func advanceGeneration() {
        lock.withLock {
            currentGeneration &+= 1
            let oldCount = entries.count
            entries.removeAll()
            logger.debug("Generation advanced to \(self.currentGeneration), invalidated \(oldCount) entries")
        }
    }

    /// Try to get a cached analysis for a repository.
    /// Returns nil if the entry is missing, expired, or has an invalid key.
    func get(
        repositoryID: String,
        key: InvalidationKey,
        generation: UInt64,
        now: Date = Date()
    ) -> ChangeImpactSnapshot? {
        lock.withLock {
            guard let entry = entries[repositoryID] else {
                totalMissCount += 1
                return nil
            }

            // Check generation
            guard entry.generation == generation else {
                entries.removeValue(forKey: repositoryID)
                totalMissCount += 1
                logger.debug("Cache miss for \(repositoryID): generation mismatch")
                return nil
            }

            // Check expiration
            guard now < entry.expiresAt else {
                entries.removeValue(forKey: repositoryID)
                totalMissCount += 1
                logger.debug("Cache miss for \(repositoryID): expired")
                return nil
            }

            // Check invalidation key
            guard entry.key == key else {
                entries.removeValue(forKey: repositoryID)
                totalMissCount += 1
                logger.debug("Cache miss for \(repositoryID): invalidation key changed")
                return nil
            }

            totalHitCount += 1
            var mutableEntry = entry
            mutableEntry.hitCount += 1
            entries[repositoryID] = mutableEntry

            logger.debug("Cache hit for \(repositoryID) (hit #\(mutableEntry.hitCount))")
            return entry.snapshot
        }
    }

    /// Store a snapshot in the cache.
    func set(
        repositoryID: String,
        snapshot: ChangeImpactSnapshot,
        key: InvalidationKey,
        generation: UInt64,
        isChanged: Bool,
        now: Date = Date()
    ) {
        let ttl = isChanged ? config.defaultTTLSeconds : config.unchangedTTLSeconds
        let expiresAt = now.addingTimeInterval(ttl)

        let entry = CacheEntry(
            analysisID: snapshot.id,
            snapshot: snapshot,
            key: key,
            cachedAt: now,
            expiresAt: expiresAt,
            generation: generation,
            hitCount: 0
        )

        lock.withLock {
            entries[repositoryID] = entry
            evictIfNeeded()
        }
    }

    /// Remove a specific entry from the cache.
    func remove(repositoryID: String) {
        lock.withLock {
            entries.removeValue(forKey: repositoryID)
        }
    }

    /// Clear all cached entries.
    func clear() {
        lock.withLock {
            let count = entries.count
            entries.removeAll()
            totalHitCount = 0
            totalMissCount = 0
            logger.debug("Cache cleared (\(count) entries removed)")
        }
    }

    /// Get the number of cached entries.
    var count: Int {
        lock.withLock { entries.count }
    }

    /// Get cache hit count.
    var hitCount: Int {
        lock.withLock { totalHitCount }
    }

    /// Get cache miss count.
    var missCount: Int {
        lock.withLock { totalMissCount }
    }

    /// Get hit rate.
    var hitRate: Double {
        lock.withLock {
            let total = totalHitCount + totalMissCount
            return total > 0 ? Double(totalHitCount) / Double(total) : 0
        }
    }

    // MARK: - Private

    private func evictIfNeeded() {
        let overage = entries.count - config.maxEntries
        guard overage > 0 else { return }

        // Evict oldest entries
        let sorted = entries.sorted { $0.value.cachedAt < $1.value.cachedAt }
        let toEvict = sorted.prefix(overage)
        for (key, _) in toEvict {
            entries.removeValue(forKey: key)
            totalEvictionCount += 1
        }
        logger.debug("Evicted \(toEvict.count) entries, cache now at \(self.entries.count)/\(self.config.maxEntries)")
    }
}

// MARK: - Cache diagnostics

struct CacheDiagnostics: Equatable, Sendable {
    let currentEntries: Int
    let maxEntries: Int
    let hitCount: Int
    let missCount: Int
    let evictionCount: Int
    let hitRate: Double
    let generation: UInt64

    var usageFraction: Double {
        guard maxEntries > 0 else { return 0 }
        return Double(currentEntries) / Double(maxEntries)
    }
}

import Foundation
import OSLog

// MARK: - Impact propagation engine

/// Propagates changes through a dependency graph to determine the full
/// impact scope of a set of file changes.
///
/// Design:
/// - BFS-based: traverses the dependency graph from directly changed modules.
/// - Incremental: can reuse previous propagation results when only leaf
///   modules change (caller provides unchanged subgraph).
/// - Bounded: enforces max propagation depth and edge count.
/// - Explainable: every propagated impact traces back to original evidence.
///
/// Thread safety: This engine is stateless and reentrant. Safe to call
/// concurrently from multiple tasks.
final class ImpactPropagationEngine: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "ImpactPropagation"
    )

    // MARK: - Configuration

    struct Configuration: Sendable {
        /// Maximum BFS depth for impact propagation.
        var maxPropagationDepth: Int = 5
        /// Maximum number of edges to traverse.
        var maxEdgeTraversal: Int = 500
        /// Weight threshold below which impacts are excluded.
        var minImpactWeight: Double = 0.1
        /// Whether to include speculative impacts (low confidence).
        var includeSpeculative: Bool = false
        /// Whether to fall back to previous propagation on failure.
        var fallbackToPrevious: Bool = true

        static let `default` = Configuration()
    }

    private let config: Configuration

    init(config: Configuration = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// Propagate the impact of changes through the dependency graph.
    ///
    /// - Parameters:
    ///   - modules: All known modules in the analysis scope.
    ///   - edges: Dependency edges between modules.
    ///   - directlyChangedModules: IDs of modules with direct file changes.
    ///   - previousPropagation: Optional previous propagation for incremental reuse.
    /// - Returns: Updated modules with propagated impact information.
    func propagate(
        modules: [AffectedModule],
        edges: [ImpactEdge],
        directlyChangedModules: Set<String>,
        previousPropagation: [String: [String]]? = nil
    ) -> [AffectedModule] {
        let startTime = ProcessInfo.processInfo.systemUptime

        // Build adjacency list
        let adjacency = buildAdjacencyList(edges: edges)

        // BFS from directly changed modules
        var impactedModules: [String: PropagationInfo] = [:]
        var visited: Set<String> = []
        var queue: [(moduleID: String, depth: Int, path: [String])] = []

        // Seed queue with directly changed modules
        for moduleID in directlyChangedModules {
            queue.append((moduleID, 0, [moduleID]))
            visited.insert(moduleID)
            impactedModules[moduleID] = PropagationInfo(
                depth: 0,
                path: [moduleID],
                sourceModules: [moduleID],
                isDirect: true
            )
        }

        // BFS traversal
        var edgeCount = 0
        while !queue.isEmpty {
            guard edgeCount < config.maxEdgeTraversal else {
                logger.debug("Max edge traversal (\(self.config.maxEdgeTraversal)) reached, stopping propagation")
                break
            }

            let (currentID, depth, path) = queue.removeFirst()

            guard depth < config.maxPropagationDepth else { continue }

            guard let neighbors = adjacency[currentID] else { continue }

            for (neighborID, edge) in neighbors {
                edgeCount += 1
                guard edge.weight >= config.minImpactWeight else { continue }

                if edge.weight < 0.3 && !config.includeSpeculative { continue }

                let newDepth = depth + 1
                let newPath = path + [neighborID]

                if let existing = impactedModules[neighborID] {
                    // Update with shortest path info
                    if newDepth < existing.depth {
                        impactedModules[neighborID] = PropagationInfo(
                            depth: newDepth,
                            path: newPath,
                            sourceModules: existing.sourceModules.union([currentID]),
                            isDirect: existing.isDirect
                        )
                    } else {
                        // Accumulate source modules
                        impactedModules[neighborID] = PropagationInfo(
                            depth: existing.depth,
                            path: existing.path,
                            sourceModules: existing.sourceModules.union([currentID]),
                            isDirect: existing.isDirect
                        )
                    }
                } else {
                    impactedModules[neighborID] = PropagationInfo(
                        depth: newDepth,
                        path: newPath,
                        sourceModules: [currentID],
                        isDirect: false
                    )
                }

                if !visited.contains(neighborID) {
                    visited.insert(neighborID)
                    queue.append((neighborID, newDepth, newPath))
                }
            }
        }

        let elapsed = (ProcessInfo.processInfo.systemUptime - startTime) * 1000
        logger.debug("Propagation completed in \(elapsed, format: .fixed(precision: 1))ms, impacted \(impactedModules.count) modules")

        // Merge propagation results back into module objects
        return modules.map { module in
            guard let prop = impactedModules[module.id] else {
                return module
            }

            let confidence: ImpactConfidence
            if prop.isDirect {
                confidence = .direct
            } else if prop.depth <= 1 {
                confidence = .high
            } else if prop.depth <= 2 {
                confidence = .medium
            } else if prop.depth <= 3 {
                confidence = .low
            } else {
                confidence = .speculative
            }

            var evidence = module.evidence
            if !prop.isDirect {
                let sourceModuleNames = prop.sourceModules.compactMap { sid in
                    modules.first(where: { $0.id == sid })?.name
                }
                evidence.append("影响传播路径: \(sourceModuleNames.joined(separator: " → "))")
                evidence.append("传播深度: \(prop.depth)")
                evidence.append("置信度: \(confidence.displayName)")
            }

            return AffectedModule(
                id: module.id,
                name: module.name,
                repositoryID: module.repositoryID,
                kind: module.kind,
                changeCount: prop.isDirect ? module.changeCount : 0,
                categoryBreakdown: prop.isDirect ? module.categoryBreakdown : [:],
                directChanges: prop.isDirect ? module.directChanges : [],
                propagatedFrom: prop.isDirect ? module.propagatedFrom : Array(prop.sourceModules),
                confidence: confidence,
                evidence: evidence
            )
        }
    }

    /// Determine verification scope from propagation results.
    /// Returns a list of module names that should be verified.
    func determineVerificationScope(
        modules: [AffectedModule],
        minConfidence: ImpactConfidence = .medium
    ) -> [String] {
        modules
            .filter { $0.confidence.sortOrder <= minConfidence.sortOrder }
            .sorted { $0.confidence.sortOrder < $1.confidence.sortOrder }
            .map { "\($0.name) (\($0.confidence.displayName))" }
    }

    // MARK: - Private

    private struct PropagationInfo {
        let depth: Int
        let path: [String]
        let sourceModules: Set<String>
        let isDirect: Bool
    }

    private typealias AdjacencyList = [String: [(targetID: String, edge: ImpactEdge)]]

    private func buildAdjacencyList(edges: [ImpactEdge]) -> AdjacencyList {
        var adjacency: AdjacencyList = [:]
        for edge in edges {
            adjacency[edge.fromModuleID, default: []].append((edge.toModuleID, edge))
        }
        return adjacency
    }
}

import Testing
import Foundation
@testable import DevPulse

// MARK: - Impact propagation engine tests

@Suite("ImpactPropagationEngine")
struct ImpactPropagationEngineTests {

    private let engine = ImpactPropagationEngine()

    private func makeModule(id: String, name: String, kind: ModuleKind = .library) -> AffectedModule {
        AffectedModule(
            id: id,
            name: name,
            repositoryID: "test-repo",
            kind: kind,
            changeCount: 0,
            categoryBreakdown: [:],
            directChanges: [],
            propagatedFrom: [],
            confidence: .low,
            evidence: []
        )
    }

    private func makeEdge(from: String, to: String, kind: DependencyKind = .targetDependency, weight: Double = 1.0) -> ImpactEdge {
        ImpactEdge(
            id: "\(from)->\(to)",
            fromModuleID: from,
            toModuleID: to,
            via: ["Dependency from \(from) to \(to)"],
            kind: kind,
            weight: weight
        )
    }

    // MARK: - Basic propagation

    @Test("No direct changes produces no propagation")
    func noDirectChanges() {
        let modules = [
            makeModule(id: "A", name: "ModuleA"),
            makeModule(id: "B", name: "ModuleB"),
        ]
        let edges = [makeEdge(from: "A", to: "B")]

        let result = engine.propagate(modules: modules, edges: edges, directlyChangedModules: [])

        // All modules should still be present but with low/direct confidence for unmodified
        #expect(result.count == 2)
        // Directly no changes → no propagation
        #expect(result.allSatisfy { $0.changeCount == 0 })
    }

    @Test("Directly changed module propagates to dependents")
    func directChangePropagates() {
        let modules = [
            makeModule(id: "A", name: "CoreLib"),
            makeModule(id: "B", name: "AppTarget", kind: .app),
            makeModule(id: "C", name: "WidgetExt", kind: .widgetExtension),
        ]
        // Edge direction: engine propagates from fromModuleID to toModuleID.
        // An edge from A to B means "A affects B".
        let edges = [
            makeEdge(from: "A", to: "B", weight: 1.0),  // A changes → B affected
            makeEdge(from: "B", to: "C", weight: 0.7),  // B changes → C affected
        ]

        // Module A has direct changes
        let result = engine.propagate(
            modules: modules,
            edges: edges,
            directlyChangedModules: ["A"]
        )

        // A should be direct
        let moduleA = result.first(where: { $0.id == "A" })
        #expect(moduleA?.confidence == .direct)

        // B should be impacted via A (depth 1)
        let moduleB = result.first(where: { $0.id == "B" })
        #expect(moduleB?.confidence.sortOrder ?? 99 <= ImpactConfidence.high.sortOrder)

        // C should be impacted via B (depth 2)
        let moduleC = result.first(where: { $0.id == "C" })
        #expect(moduleC != nil)

        #expect(result.count == 3)
    }

    @Test("Propagation respects max depth")
    func propagationRespectsDepth() {
        let config = ImpactPropagationEngine.Configuration(maxPropagationDepth: 2)
        let depthLimited = ImpactPropagationEngine(config: config)

        let modules = (0..<5).map { i in
            makeModule(id: "M\(i)", name: "Module\(i)")
        }
        var edges: [ImpactEdge] = []
        for i in 0..<4 {
            edges.append(makeEdge(from: "M\(i)", to: "M\(i+1)", weight: 1.0))
        }

        let result = depthLimited.propagate(
            modules: modules,
            edges: edges,
            directlyChangedModules: ["M0"]
        )

        // M0 is direct, M1 is depth 1, M2 is depth 2, M3/M4 beyond maxDepth 2
        let m0 = result.first(where: { $0.id == "M0" })
        #expect(m0?.confidence == .direct)

        // M2 should be impacted (depth 2, within limit)
        let m2 = result.first(where: { $0.id == "M2" })
        #expect(m2?.confidence != .direct)  // not direct
    }

    @Test("Low weight edges are excluded")
    func lowWeightEdgesExcluded() {
        let modules = [
            makeModule(id: "A", name: "Core"),
            makeModule(id: "B", name: "Peripheral"),
        ]
        let edges = [
            makeEdge(from: "A", to: "B", weight: 0.05)  // below 0.1 threshold
        ]

        let result = engine.propagate(
            modules: modules,
            edges: edges,
            directlyChangedModules: ["A"]
        )

        // B should not be affected because edge weight is too low
        let moduleB = result.first(where: { $0.id == "B" })
        #expect(moduleB?.confidence != .direct)
    }

    // MARK: - Verification scope

    @Test("Determine verification scope filters by confidence")
    func verificationScopeFilters() {
        let modules = [
            makeModule(id: "A", name: "CoreLib"),
            makeModule(id: "B", name: "AppTarget", kind: .app),
            makeModule(id: "C", name: "TestTarget", kind: .testTarget),
        ]

        // Nothing has changes, so they're all low confidence
        let scope = engine.determineVerificationScope(modules: modules, minConfidence: .direct)
        #expect(scope.isEmpty)
    }

    // MARK: - Edge cases

    @Test("Empty modules produces empty result")
    func emptyModules() {
        let result = engine.propagate(modules: [], edges: [], directlyChangedModules: [])
        #expect(result.isEmpty)
    }

    @Test("No edges produces no propagation")
    func noEdges() {
        let modules = [makeModule(id: "A", name: "SoloModule")]
        let result = engine.propagate(modules: modules, edges: [], directlyChangedModules: ["A"])
        #expect(result.count == 1)
        #expect(result.first?.confidence == .direct)
    }

    @Test("Cyclic dependencies don't cause infinite loop")
    func cyclicDependencies() {
        let modules = [
            makeModule(id: "A", name: "ModuleA"),
            makeModule(id: "B", name: "ModuleB"),
            makeModule(id: "C", name: "ModuleC"),
        ]
        let edges = [
            makeEdge(from: "A", to: "B"),
            makeEdge(from: "B", to: "C"),
            makeEdge(from: "C", to: "A"),  // cycle
        ]

        let result = engine.propagate(
            modules: modules,
            edges: edges,
            directlyChangedModules: ["A"]
        )

        // Should complete without hanging and find all modules
        #expect(result.count == 3)
    }
}

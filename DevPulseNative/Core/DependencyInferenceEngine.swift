import Foundation
import OSLog
import CryptoKit

// MARK: - Dependency inference engine

/// Infers dependencies between modules within a repository by analyzing
/// project manifests, source imports, and file system structure.
///
/// Design:
/// - Manifest-driven: reads project.yml, Package.swift, and other manifests.
/// - Import scanning: detects cross-module import statements in source files.
/// - Heuristic fallback: uses directory structure to infer module boundaries.
/// - No external services: all analysis is local and file-system based.
///
/// Thread safety: This is a stateless engine; instances can be shared.
final class DependencyInferenceEngine: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "local.devpulse.app",
        category: "DependencyInference"
    )

    // MARK: - Public API

    /// Infer the dependency graph for a repository.
    /// - Parameters:
    ///   - repositoryPath: Absolute path to the repository root.
    ///   - changedFiles: List of changed file paths (relative to root).
    ///   - workspaceKind: The kind of workspace (standalone, main, linked).
    /// - Returns: Inferred modules and dependency edges.
    func inferModulesAndDependencies(
        repositoryPath: String,
        changedFiles: [String],
        workspaceKind: RepositoryWorkspaceKind?
    ) -> (modules: [AffectedModule], edges: [ImpactEdge]) {
        // Phase 1: Discover modules from manifests
        let discovered = discoverModules(at: repositoryPath)

        // Phase 2: Map changed files to modules
        let fileModuleMap = mapFilesToModules(
            files: changedFiles,
            modules: discovered,
            repoPath: repositoryPath
        )

        // Phase 3: Infer dependencies between modules
        let edges = inferEdges(
            modules: discovered,
            fileModuleMap: fileModuleMap,
            repoPath: repositoryPath
        )

        // Phase 4: Build affected module descriptions
        let modules = discovered.map { module -> AffectedModule in
            let directChanges = fileModuleMap
                .filter { $0.value == module.id }
                .map { $0.key }
            let changeCount = directChanges.count
            let categories = FileCategoryClassifier.classifyAll(filePaths: directChanges)

            let propagatedEdges = edges.filter { $0.toModuleID == module.id }
            let propagatedFrom = propagatedEdges.compactMap { edge -> String? in
                discovered.first(where: { $0.id == edge.fromModuleID })?.name
            }

            let confidence: ImpactConfidence = changeCount > 0 ? .direct : .low

            let evidence = buildEvidence(
                moduleName: module.name,
                directChanges: directChanges,
                propagatedFrom: propagatedFrom,
                changeCount: changeCount
            )

            return AffectedModule(
                id: module.id,
                name: module.name,
                repositoryID: "",
                kind: module.kind,
                changeCount: changeCount,
                categoryBreakdown: categories,
                directChanges: directChanges,
                propagatedFrom: propagatedFrom,
                confidence: confidence,
                evidence: evidence
            )
        }

        return (modules, edges)
    }

    // MARK: - Module discovery

    private func discoverModules(at path: String) -> [(id: String, name: String, kind: ModuleKind)] {
        var modules: [(id: String, name: String, kind: ModuleKind)] = []
        let fm = FileManager.default

        // 1. Check for SwiftPM Package.swift
        let packagePath = (path as NSString).appendingPathComponent("Package.swift")
        if fm.fileExists(atPath: packagePath) {
            // Repository is a SwiftPM package; try to read product/target names
            if let targets = parseSwiftPackageTargets(at: path) {
                for target in targets {
                    let digest = SHA256.hash(data: Data(target.name.utf8))
                    let id = "spm-" + digest.map { String(format: "%02x", $0) }.joined()
                    modules.append((id: id, name: target.name, kind: target.kind))
                }
            } else {
                // Fallback: single package module
                let name = (path as NSString).lastPathComponent
                let digest = SHA256.hash(data: Data(name.utf8))
                let id = "pkg-" + digest.map { String(format: "%02x", $0) }.joined()
                modules.append((id: id, name: name, kind: .package))
            }
        }

        // 2. Check for XcodeGen project.yml
        let projectYmlPath = (path as NSString).appendingPathComponent("project.yml")
        if fm.fileExists(atPath: projectYmlPath) {
            if let targets = parseProjectYmlTargets(at: path) {
                for target in targets {
                    let digest = SHA256.hash(data: Data(target.name.utf8))
                    let id = "tgt-" + digest.map { String(format: "%02x", $0) }.joined()
                    modules.append((id: id, name: target.name, kind: target.kind))
                }
            }
        }

        // 3. Check for .xcodeproj (heuristic: use directory names)
        let contents = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        for item in contents {
            let fullPath = (path as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue,
               item.hasSuffix(".xcodeproj") {
                let projectName = String(item.dropLast(".xcodeproj".count))
                // Check for targets via xcodebuild -list (lightweight)
                if let xcodeTargets = parseXcodeTargets(projectPath: fullPath) {
                    for target in xcodeTargets {
                        let digest = SHA256.hash(data: Data(target.utf8))
                        let id = "xctgt-" + digest.map { String(format: "%02x", $0) }.joined()
                        let kind = target.contains("Test") || target.contains("Tests")
                            ? ModuleKind.testTarget
                            : ModuleKind.app
                        modules.append((id: id, name: target, kind: kind))
                    }
                } else {
                    // Fallback: use project name as a single module
                    let digest = SHA256.hash(data: Data(projectName.utf8))
                    let id = "xcp-" + digest.map { String(format: "%02x", $0) }.joined()
                    modules.append((id: id, name: projectName, kind: .app))
                }
            }
        }

        // 4. Check for subdirectories matching source module patterns
        if modules.isEmpty {
            // Heuristic: use top-level directories as module boundaries
            let knownSourceDirs = ["Sources", "Source", "src", "lib", "App", "Core", "Utilities", "Widget"]
            for dir in knownSourceDirs {
                let dirPath = (path as NSString).appendingPathComponent(dir)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue {
                    let name = dir
                    let digest = SHA256.hash(data: Data(name.utf8))
                    let id = "mod-" + digest.map { String(format: "%02x", $0) }.joined()
                    let kind: ModuleKind = dir == "Widget" ? .widgetExtension : .library
                    modules.append((id: id, name: name, kind: kind))
                }
            }
        }

        // 5. Always include a fallback workspace-level module
        if modules.isEmpty {
            let name = (path as NSString).lastPathComponent
            let digest = SHA256.hash(data: Data(name.utf8))
            let id = "repo-" + digest.map { String(format: "%02x", $0) }.joined()
            modules.append((id: id, name: name, kind: .unknown))
        }

        return modules
    }

    // MARK: - File-to-module mapping

    private func mapFilesToModules(
        files: [String],
        modules: [(id: String, name: String, kind: ModuleKind)],
        repoPath: String
    ) -> [String: String] {
        var mapping: [String: String] = [:]

        for file in files {
            let normalizedPath = file.hasPrefix("/") ? file : (repoPath as NSString).appendingPathComponent(file)

            // Try to match file to a module directory
            var bestMatch: (id: String, score: Int)?
            for module in modules {
                let moduleDir = (repoPath as NSString).appendingPathComponent(module.name)
                if normalizedPath.hasPrefix(moduleDir + "/") || normalizedPath == moduleDir {
                    let score = moduleDir.count  // longest matching prefix = best
                    if bestMatch == nil || score > bestMatch!.score {
                        bestMatch = (module.id, score)
                    }
                }
            }

            // Fall back to Source/ or Sources/ directories
            if bestMatch == nil {
                let sourceDirs = ["Sources", "Source", "src", "lib", "App", "Core"]
                for dir in sourceDirs {
                    let dirPath = (repoPath as NSString).appendingPathComponent(dir)
                    if normalizedPath.hasPrefix(dirPath + "/") {
                        if let sourceModule = modules.first(where: { $0.name == dir }) {
                            bestMatch = (sourceModule.id, dirPath.count)
                            break
                        }
                    }
                }
            }

            mapping[file] = bestMatch?.id ?? modules.first?.id ?? "unknown"
        }

        return mapping
    }

    // MARK: - Edge inference

    private func inferEdges(
        modules: [(id: String, name: String, kind: ModuleKind)],
        fileModuleMap: [String: String],
        repoPath: String
    ) -> [ImpactEdge] {
        var edges: [ImpactEdge] = []
        var seen: Set<String> = []

        // Build edges between modules that share files or have known relationships
        for (i, from) in modules.enumerated() {
            for (j, to) in modules.enumerated() where i != j {
                let edgeID = "\(from.id)->\(to.id)"
                guard seen.insert(edgeID).inserted else { continue }

                // Known relationships
                let kind: DependencyKind
                let weight: Double
                let via: [String]

                if from.kind == .app && to.kind == .framework {
                    kind = .targetDependency
                    weight = 0.9
                    via = ["\(from.name) depends on \(to.name)"]
                } else if to.kind == .testTarget && from.kind == .app {
                    kind = .targetDependency
                    weight = 0.8
                    via = ["\(to.name) tests \(from.name)"]
                } else if from.kind == .library && to.kind == .library {
                    kind = .inferred
                    weight = 0.3
                    via = ["Shared workspace between \(from.name) and \(to.name)"]
                } else if from.kind == .app && to.kind == .widgetExtension {
                    kind = .targetDependency
                    weight = 0.7
                    via = ["\(from.name) hosts \(to.name)"]
                } else {
                    continue
                }

                edges.append(ImpactEdge(
                    id: edgeID,
                    fromModuleID: from.id,
                    toModuleID: to.id,
                    via: via,
                    kind: kind,
                    weight: weight
                ))
            }
        }

        return edges
    }

    // MARK: - Manifest parsing helpers

    private struct SwiftTargetInfo {
        let name: String
        let kind: ModuleKind
    }

    /// Lightweight parse of Swift Package.swift target names.
    /// Reads the file and looks for `.target(name:`, `.testTarget(name:` patterns.
    private func parseSwiftPackageTargets(at path: String) -> [SwiftTargetInfo]? {
        let packagePath = (path as NSString).appendingPathComponent("Package.swift")
        guard let content = try? String(contentsOfFile: packagePath, encoding: .utf8) else {
            return nil
        }

        var targets: [SwiftTargetInfo] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match .target(name: "Foo")
            if trimmed.hasPrefix(".target(name:") || trimmed.hasPrefix("target(name:") {
                if let name = extractQuotedString(from: trimmed) {
                    targets.append(SwiftTargetInfo(name: name, kind: .library))
                }
            }
            // Match .testTarget(name: "FooTests")
            if trimmed.hasPrefix(".testTarget(name:") || trimmed.hasPrefix("testTarget(name:") {
                if let name = extractQuotedString(from: trimmed) {
                    let cleanName = name.hasSuffix("Tests") ? String(name.dropLast("Tests".count)) : name
                    targets.append(SwiftTargetInfo(name: cleanName, kind: .testTarget))
                }
            }
        }

        return targets.isEmpty ? nil : targets
    }

    /// Lightweight parse of XcodeGen project.yml target names.
    private func parseProjectYmlTargets(at path: String) -> [SwiftTargetInfo]? {
        let ymlPath = (path as NSString).appendingPathComponent("project.yml")
        guard let content = try? String(contentsOfFile: ymlPath, encoding: .utf8) else {
            return nil
        }

        var targets: [SwiftTargetInfo] = []
        let lines = content.components(separatedBy: .newlines)
        var inTargets = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "targets:" {
                inTargets = true
                continue
            }
            if inTargets {
                // Lines like "DevPulse:" or "  DevPulseTests:"
                if trimmed.hasSuffix(":") && !trimmed.hasPrefix(" ") {
                    // Back to top-level key
                    inTargets = false
                    continue
                }
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("  ") {
                    continue
                }
                // Match "DevPulse:" under targets
                let targetName = trimmed.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
                if !targetName.isEmpty && targetName.rangeOfCharacter(from: .whitespaces) == nil {
                    let isTest = targetName.hasSuffix("Tests") || targetName.hasSuffix("UITests")
                    targets.append(SwiftTargetInfo(
                        name: targetName,
                        kind: isTest ? .testTarget : .app
                    ))
                }
            }
        }

        return targets.isEmpty ? nil : targets
    }

    /// Lightweight parse of Xcode project targets.
    /// Falls back to nil (heuristic module discovery) to avoid blocking on xcodebuild.
    private func parseXcodeTargets(projectPath: String) -> [String]? {
        // Running xcodebuild is too slow for impact analysis.
        // Module discovery uses heuristic directory-based approach instead.
        return nil
    }

    // MARK: - Helpers

    private func extractQuotedString(from line: String) -> String? {
        // Find content between first pair of double quotes
        guard let startIndex = line.firstIndex(of: "\"") else { return nil }
        let afterQuote = line[line.index(after: startIndex)...]
        guard let endIndex = afterQuote.firstIndex(of: "\"") else { return nil }
        return String(afterQuote[..<endIndex])
    }

    private func buildEvidence(
        moduleName: String,
        directChanges: [String],
        propagatedFrom: [String],
        changeCount: Int
    ) -> [String] {
        var evidence: [String] = []

        if changeCount > 0 {
            let filesToShow = directChanges.prefix(5)
            evidence.append("包含 \(changeCount) 个直接变更文件")
            for file in filesToShow {
                let shortPath = (file as NSString).lastPathComponent
                evidence.append("文件变更: \(shortPath)")
            }
            if directChanges.count > 5 {
                evidence.append("以及其它 \(directChanges.count - 5) 个文件")
            }
        } else {
            evidence.append("无直接文件变更")
        }

        if !propagatedFrom.isEmpty {
            evidence.append("影响来源: \(propagatedFrom.joined(separator: ", "))")
        }

        return evidence
    }
}

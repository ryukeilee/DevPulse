import Testing
import Foundation
@testable import DevPulse

// MARK: - File category classifier tests

@Suite("FileCategoryClassifier")
struct FileCategoryClassifierTests {

    // MARK: - Source files

    @Test("Swift files classified as source")
    func swiftFileIsSource() {
        #expect(FileCategoryClassifier.classify(filePath: "/path/to/View.swift") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "Sources/App/Engine.swift") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "/Users/user/Project/main.swift") == .source)
    }

    @Test("Objective-C files classified as source")
    func objcFilesAreSource() {
        #expect(FileCategoryClassifier.classify(filePath: "source.m") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "source.mm") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "header.h") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "header.hpp") == .source)
    }

    @Test("C/C++ files classified as source")
    func cFilesAreSource() {
        #expect(FileCategoryClassifier.classify(filePath: "impl.c") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "impl.cpp") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "impl.cc") == .source)
    }

    @Test("Other language files classified as source")
    func otherLanguageFilesAreSource() {
        #expect(FileCategoryClassifier.classify(filePath: "Main.java") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "App.kt") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "lib.rs") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "module.go") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "component.tsx") == .source)
        #expect(FileCategoryClassifier.classify(filePath: "util.py") == .source)
    }

    // MARK: - Test files

    @Test("Files in Tests/ directory classified as test")
    func testsDirectoryIsTest() {
        #expect(FileCategoryClassifier.classify(filePath: "/Tests/MyAppTests/ViewTests.swift") == .test)
        #expect(FileCategoryClassifier.classify(filePath: "/Tests/UnitTests/HelperTests.swift") == .test)
        #expect(FileCategoryClassifier.classify(filePath: "/Tests/IntegrationTests/APITests.swift") == .test)
    }

    @Test("Test suffix files classified as test")
    func testSuffixIsTest() {
        #expect(FileCategoryClassifier.classify(filePath: "MyAppTests.swift") == .test)
        #expect(FileCategoryClassifier.classify(filePath: "ViewSpec.swift") == .test)
        #expect(FileCategoryClassifier.classify(filePath: "ModelTest.swift") == .test)
    }

    @Test("DevPulse test target files classified as test")
    func devPulseTestFiles() {
        #expect(FileCategoryClassifier.classify(filePath: "/DevPulseNativeTests/MyTest.swift") == .test)
        #expect(FileCategoryClassifier.classify(filePath: "DevPulseNativeTests/DataTests.swift") == .test)
    }

    // MARK: - Configuration files

    @Test("Configuration files classified as configuration")
    func configFilesAreConfiguration() {
        #expect(FileCategoryClassifier.classify(filePath: "config.json") == .configuration)
        #expect(FileCategoryClassifier.classify(filePath: "settings.yaml") == .configuration)
        #expect(FileCategoryClassifier.classify(filePath: "info.plist") == .configuration)
        #expect(FileCategoryClassifier.classify(filePath: ".gitignore") == .configuration)
        #expect(FileCategoryClassifier.classify(filePath: ".env") == .configuration)
        #expect(FileCategoryClassifier.classify(filePath: "/Config/AppSettings.swift") == .configuration)
    }

    @Test("Entitlements and xcconfig files classified as configuration")
    func entitlementsAndXcconfigAreConfig() {
        #expect(FileCategoryClassifier.classify(filePath: "App.entitlements") == .configuration)
        #expect(FileCategoryClassifier.classify(filePath: "Debug.xcconfig") == .configuration)
    }

    // MARK: - Dependency files

    @Test("Package.swift classified as dependency")
    func packageSwiftIsDependency() {
        #expect(FileCategoryClassifier.classify(filePath: "/project/Package.swift") == .dependency)
        #expect(FileCategoryClassifier.classify(filePath: "Package.swift") == .dependency)
    }

    @Test("Package.resolved classified as dependency")
    func packageResolvedIsDependency() {
        #expect(FileCategoryClassifier.classify(filePath: "Package.resolved") == .dependency)
    }

    @Test("project.yml classified as dependency")
    func projectYmlIsDependency() {
        #expect(FileCategoryClassifier.classify(filePath: "/project/project.yml") == .dependency)
    }

    @Test("Podfile classified as dependency")
    func podfileIsDependency() {
        #expect(FileCategoryClassifier.classify(filePath: "Podfile") == .dependency)
        #expect(FileCategoryClassifier.classify(filePath: "Podfile.lock") == .dependency)
    }

    // MARK: - Documentation files

    @Test("Documentation files classified as documentation")
    func docFilesAreDocumentation() {
        #expect(FileCategoryClassifier.classify(filePath: "README.md") == .documentation)
        #expect(FileCategoryClassifier.classify(filePath: "/docs/guide.md") == .documentation)
        #expect(FileCategoryClassifier.classify(filePath: "Documentation/API.md") == .documentation)
        #expect(FileCategoryClassifier.classify(filePath: "docs/index.html") == .documentation)
    }

    @Test("Doc extensions classified as documentation")
    func docExtensionsAreDocumentation() {
        #expect(FileCategoryClassifier.classify(filePath: "doc.rst") == .documentation)
        #expect(FileCategoryClassifier.classify(filePath: "readme.txt") == .documentation)
        #expect(FileCategoryClassifier.classify(filePath: "manual.pdf") == .documentation)
    }

    // MARK: - Resource files

    @Test("Resource files classified as resource")
    func resourceFilesAreResource() {
        #expect(FileCategoryClassifier.classify(filePath: "image.png") == .resource)
        #expect(FileCategoryClassifier.classify(filePath: "Assets.xcassets/Contents.json") == .resource)
        #expect(FileCategoryClassifier.classify(filePath: "/Resources/Localizable.strings") == .resource)
    }

    @Test("Asset catalog classified as resource")
    func assetCatalogIsResource() {
        #expect(FileCategoryClassifier.classify(filePath: "/App/Assets.xcassets/AppIcon.icns") == .resource)
        #expect(FileCategoryClassifier.classify(filePath: "Assets.xcassets/Image.imageset/Contents.json") == .resource)
    }

    // MARK: - Build script files

    @Test("Build scripts classified as buildScript")
    func buildScriptsAreBuild() {
        #expect(FileCategoryClassifier.classify(filePath: "build.sh") == .buildScript)
        #expect(FileCategoryClassifier.classify(filePath: "/Scripts/ci.sh") == .buildScript)
        #expect(FileCategoryClassifier.classify(filePath: "/ci/deploy.sh") == .buildScript)
    }

    // MARK: - Migration files

    @Test("Migration files classified as migration")
    func migrationFilesAreMigration() {
        #expect(FileCategoryClassifier.classify(filePath: "schema.sql") == .migration)
        #expect(FileCategoryClassifier.classify(filePath: "/Migrations/001_initial.sql") == .migration)
        #expect(FileCategoryClassifier.classify(filePath: "/Database/Migrations/002.sql") == .migration)
    }

    // MARK: - Unknown files

    @Test("Unknown extensions classified as unknown")
    func unknownExtensionsAreUnknown() {
        #expect(FileCategoryClassifier.classify(filePath: "file.xyz") == .unknown)
        #expect(FileCategoryClassifier.classify(filePath: "data.bin") == .unknown)
        #expect(FileCategoryClassifier.classify(filePath: "archive.tar.gz") == .unknown)
    }

    // MARK: - classifyAll

    @Test("classifyAll returns correct breakdown")
    func classifyAllBreakdown() {
        let files = [
            "View.swift",
            "Model.swift",
            "Tests/AppTests.swift",
            "config.json",
            "Package.swift",
            "README.md",
            "image.png",
            "file.unknown"
        ]
        let breakdown = FileCategoryClassifier.classifyAll(filePaths: files)

        #expect(breakdown[.source] == 2)
        #expect(breakdown[.test] == 1)
        #expect(breakdown[.configuration] == 1)
        #expect(breakdown[.dependency] == 1)
        #expect(breakdown[.documentation] == 1)
        #expect(breakdown[.resource] == 1)
        #expect(breakdown[.unknown] == 1)
    }

    // MARK: - determineScope

    @Test("determineScope returns singleFile for one file")
    func scopeSingleFile() {
        let breakdown: [ChangeCategory: Int] = [.source: 1]
        #expect(FileCategoryClassifier.determineScope(categoryBreakdown: breakdown) == .singleFile)
    }

    @Test("determineScope returns multiFile for a few files across categories")
    func scopeMultiFile() {
        let breakdown: [ChangeCategory: Int] = [.source: 2, .test: 2]
        #expect(FileCategoryClassifier.determineScope(categoryBreakdown: breakdown) == .multiFile)
    }

    @Test("determineScope returns crossModule for many categories")
    func scopeCrossModule() {
        let breakdown: [ChangeCategory: Int] = [
            .source: 3, .test: 2, .configuration: 1, .dependency: 1, .buildScript: 1
        ]
        #expect(FileCategoryClassifier.determineScope(categoryBreakdown: breakdown) == .crossModule)
    }

    @Test("determineScope returns moduleLocal for many files in same category")
    func scopeModuleLocal() {
        let breakdown: [ChangeCategory: Int] = [.source: 6, .test: 1]
        #expect(FileCategoryClassifier.determineScope(categoryBreakdown: breakdown) == .moduleLocal)
    }
}

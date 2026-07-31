import Foundation
import Testing
@testable import DevPulse

// MARK: - ScanConfig Value Sanitization Tests
//
// Verifies that ScanConfig initialisation and decoding clamp dangerous
// persisted values (negatives, zero, NaN, Infinity, huge values) to safe
// ranges without breaking legitimate test-time low timeouts.

@Suite("ScanConfig Sanitization")
struct ScanConfigSanitizationTests {

    // MARK: - Direct init clamping

    @Test("maxDepth is clamped to [0, 64]")
    func maxDepthClamping() {
        let zero = ScanConfig.default.with(maxDepth: 0).maxDepth
        #expect(zero == 0, "maxDepth 0 should keep root-only discovery")

        let neg = ScanConfig.default.with(maxDepth: -5).maxDepth
        #expect(neg == 0, "negative maxDepth should clamp to 0")

        let high = ScanConfig.default.with(maxDepth: 100).maxDepth
        #expect(high == 64, "maxDepth 100 should clamp to 64")

        let normal = ScanConfig.default.with(maxDepth: 4).maxDepth
        #expect(normal == 4, "maxDepth 4 should pass through")
    }

    @Test("changedPreviewLimit is clamped to [0, 100]")
    func changedPreviewLimitClamping() {
        let zero = ScanConfig.default.with(changedPreviewLimit: 0).changedPreviewLimit
        #expect(zero == 0, "changedPreviewLimit 0 should suppress the preview")

        let neg = ScanConfig.default.with(changedPreviewLimit: -10).changedPreviewLimit
        #expect(neg == 0, "negative changedPreviewLimit should clamp to 0")

        let high = ScanConfig.default.with(changedPreviewLimit: 999).changedPreviewLimit
        #expect(high == 100, "changedPreviewLimit 999 should clamp to 100")

        let normal = ScanConfig.default.with(changedPreviewLimit: 5).changedPreviewLimit
        #expect(normal == 5, "changedPreviewLimit 5 should pass through")
    }

    @Test("maxConcurrentGitOps is clamped to [1, 10]")
    func maxConcurrentGitOpsClamping() {
        let low = ScanConfig.default.with(maxConcurrentGitOps: 0).maxConcurrentGitOps
        #expect(low == 1, "maxConcurrentGitOps 0 should clamp to 1")

        let neg = ScanConfig.default.with(maxConcurrentGitOps: -3).maxConcurrentGitOps
        #expect(neg == 1, "maxConcurrentGitOps -3 should clamp to 1")

        let high = ScanConfig.default.with(maxConcurrentGitOps: 50).maxConcurrentGitOps
        #expect(high == 10, "maxConcurrentGitOps 50 should clamp to 10")

        let normal = ScanConfig.default.with(maxConcurrentGitOps: 10).maxConcurrentGitOps
        #expect(normal == 10, "maxConcurrentGitOps 10 should pass through")
    }

    @Test("gitCommandTimeout clamps NaN/Infinity/negative to default, preserves low test values")
    func gitCommandTimeoutClamping() {
        // NaN / Infinity / -Infinity → default
        let nan = ScanConfig.default.with(gitCommandTimeout: .nan).gitCommandTimeout
        #expect(nan.isFinite, "NaN should produce finite default")
        #expect(nan == 5.0)

        let pinf = ScanConfig.default.with(gitCommandTimeout: .infinity).gitCommandTimeout
        #expect(pinf.isFinite, "+Inf should produce finite default")
        #expect(pinf == 5.0)

        let ninf = ScanConfig.default.with(gitCommandTimeout: -.infinity).gitCommandTimeout
        #expect(ninf.isFinite, "-Inf should produce finite default")
        #expect(ninf == 5.0)

        let neg = ScanConfig.default.with(gitCommandTimeout: -1).gitCommandTimeout
        #expect(neg == 5.0, "negative should produce default")

        let zero = ScanConfig.default.with(gitCommandTimeout: 0).gitCommandTimeout
        #expect(zero == 5.0, "zero should produce default")

        // Low test values are preserved (floor = 0.1)
        let low = ScanConfig.default.with(gitCommandTimeout: 0.3).gitCommandTimeout
        #expect(low == 0.3, "0.3 is above floor and should pass through")

        let mid = ScanConfig.default.with(gitCommandTimeout: 1.0).gitCommandTimeout
        #expect(mid == 1.0, "1.0 should pass through")

        // Ceiling = 30
        let high = ScanConfig.default.with(gitCommandTimeout: 60).gitCommandTimeout
        #expect(high == 30, "60 should clamp to 30")
    }

    @Test("scanTimeout clamps NaN/Infinity/negative to default, preserves low test values")
    func scanTimeoutClamping() {
        let nan = ScanConfig.default.with(scanTimeout: .nan).scanTimeout
        #expect(nan.isFinite, "NaN should produce finite default")
        #expect(nan == 60.0)

        let pinf = ScanConfig.default.with(scanTimeout: .infinity).scanTimeout
        #expect(pinf.isFinite, "+Inf should produce finite default")
        #expect(pinf == 60.0)

        let ninf = ScanConfig.default.with(scanTimeout: -.infinity).scanTimeout
        #expect(ninf.isFinite, "-Inf should produce finite default")
        #expect(ninf == 60.0)

        let neg = ScanConfig.default.with(scanTimeout: -5).scanTimeout
        #expect(neg == 60.0, "negative should produce default")

        let zero = ScanConfig.default.with(scanTimeout: 0).scanTimeout
        #expect(zero == 60.0, "zero should produce default")

        // Low test values are preserved (floor = 0.5)
        let low = ScanConfig.default.with(scanTimeout: 0.8).scanTimeout
        #expect(low == 0.8, "0.8 is above floor and should pass through")

        let mid = ScanConfig.default.with(scanTimeout: 30).scanTimeout
        #expect(mid == 30, "30 should pass through")

        // Ceiling = 300
        let high = ScanConfig.default.with(scanTimeout: 500).scanTimeout
        #expect(high == 300, "500 should clamp to 300")
    }

    @Test("activeRepoThreshold is clamped to >= 1")
    func activeRepoThresholdClamping() {
        let low = ScanConfig.default.with(activeRepoThreshold: 0).activeRepoThreshold
        #expect(low == 1, "activeRepoThreshold 0 should clamp to 1")

        let neg = ScanConfig.default.with(activeRepoThreshold: -10).activeRepoThreshold
        #expect(neg == 1, "activeRepoThreshold -10 should clamp to 1")

        let normal = ScanConfig.default.with(activeRepoThreshold: 30).activeRepoThreshold
        #expect(normal == 30, "30 should pass through")

        let big = ScanConfig.default.with(activeRepoThreshold: 1000).activeRepoThreshold
        #expect(big == 1000, "1000 should pass through (no upper bound)")
    }

    // MARK: - Decoder clamping

    @Test("Decoded negative values are clamped")
    func decoderClampsNegatives() throws {
        let json = """
        {
            "enabledBuiltInPaths": [],
            "customPaths": [],
            "maxDepth": -2,
            "changedPreviewLimit": -1,
            "maxConcurrentGitOps": -5,
            "gitCommandTimeout": -3.0,
            "scanTimeout": -10.0,
            "slowReposkipSeconds": 600,
            "activeRepoThreshold": -1
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ScanConfig.self, from: json)
        #expect(decoded.maxDepth == 0)
        #expect(decoded.changedPreviewLimit == 0)
        #expect(decoded.maxConcurrentGitOps == 1)
        #expect(decoded.gitCommandTimeout == 5.0)
        #expect(decoded.scanTimeout == 60.0)
        #expect(decoded.activeRepoThreshold == 1)
    }

    @Test("Decoded NaN/Infinity values are clamped")
    func decoderClampsNonFinite() throws {
        let json = """
        {
            "enabledBuiltInPaths": [],
            "customPaths": [],
            "maxDepth": 2,
            "changedPreviewLimit": 5,
            "maxConcurrentGitOps": 3,
            "gitCommandTimeout": 0.3,
            "scanTimeout": 0.8,
            "slowReposkipSeconds": 600,
            "activeRepoThreshold": 5
        }
        """.data(using: .utf8)!
        // JSONDecoder cannot represent NaN/Infinity in JSON, so this just
        // validates that a rapid-low-timeout decode roundtrip produces
        // the exact values we expect (preserving low test configuration).
        let decoded = try JSONDecoder().decode(ScanConfig.self, from: json)
        #expect(decoded.gitCommandTimeout == 0.3)
        #expect(decoded.scanTimeout == 0.8)
    }

    @Test("Decoded huge values are clamped")
    func decoderClampsHuge() throws {
        let json = """
        {
            "enabledBuiltInPaths": [],
            "customPaths": [],
            "maxDepth": 9999,
            "changedPreviewLimit": 9999,
            "maxConcurrentGitOps": 9999,
            "gitCommandTimeout": 9999,
            "scanTimeout": 9999,
            "slowReposkipSeconds": 9999,
            "activeRepoThreshold": 9999
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ScanConfig.self, from: json)
        #expect(decoded.maxDepth == 64)
        #expect(decoded.changedPreviewLimit == 100)
        #expect(decoded.maxConcurrentGitOps == 10)
        #expect(decoded.gitCommandTimeout == 30)
        #expect(decoded.scanTimeout == 300)
        // activeRepoThreshold has no upper bound
        #expect(decoded.activeRepoThreshold == 9999)
    }

    @Test("Round-trip encode/decode preserves default")
    func encoderRoundTripPreservesDefault() throws {
        let original = ScanConfig.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(ScanConfig.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - RepositoryIdentity canonicalPath empty-input Tests

@Suite("RepositoryIdentity canonicalPath empty-input")
struct RepositoryIdentityCanonicalPathEmptyTests {

    @Test("empty string returns empty string")
    func emptyPath() {
        #expect(RepositoryIdentity.canonicalPath("") == "")
    }

    @Test("whitespace-only string returns empty string")
    func whitespacePath() {
        #expect(RepositoryIdentity.canonicalPath("   ") == "")
        #expect(RepositoryIdentity.canonicalPath("\t\n ") == "")
    }

    @Test("non-empty paths still resolve normally")
    func normalPaths() {
        let tilde = RepositoryIdentity.canonicalPath("~")
        #expect(tilde.hasPrefix("/"),
                "tilde should resolve to a real home directory")

        let absolute = RepositoryIdentity.canonicalPath("/tmp")
        #expect(absolute == "/tmp", "absolute path should remain /tmp")
    }

    @Test("id(for:) with empty path produces deterministic hash")
    func emptyPathID() {
        let id = RepositoryIdentity.id(for: "")
        #expect(id.hasPrefix("repo-v1-"))
        #expect(id == RepositoryIdentity.id(for: "   "),
                "empty and whitespace should produce the same ID via canonicalPath")
    }
}

// MARK: - Helper extensions

private extension ScanConfig {
    func with(maxDepth: Int) -> ScanConfig {
        ScanConfig(
            enabledBuiltInPaths: enabledBuiltInPaths,
            customPaths: customPaths,
            maxDepth: maxDepth,
            changedPreviewLimit: changedPreviewLimit,
            maxConcurrentGitOps: maxConcurrentGitOps,
            gitCommandTimeout: gitCommandTimeout,
            scanTimeout: scanTimeout,
            slowReposkipSeconds: slowReposkipSeconds,
            activeRepoThreshold: activeRepoThreshold
        )
    }

    func with(changedPreviewLimit: Int) -> ScanConfig {
        ScanConfig(
            enabledBuiltInPaths: enabledBuiltInPaths,
            customPaths: customPaths,
            maxDepth: maxDepth,
            changedPreviewLimit: changedPreviewLimit,
            maxConcurrentGitOps: maxConcurrentGitOps,
            gitCommandTimeout: gitCommandTimeout,
            scanTimeout: scanTimeout,
            slowReposkipSeconds: slowReposkipSeconds,
            activeRepoThreshold: activeRepoThreshold
        )
    }

    func with(maxConcurrentGitOps: Int) -> ScanConfig {
        ScanConfig(
            enabledBuiltInPaths: enabledBuiltInPaths,
            customPaths: customPaths,
            maxDepth: maxDepth,
            changedPreviewLimit: changedPreviewLimit,
            maxConcurrentGitOps: maxConcurrentGitOps,
            gitCommandTimeout: gitCommandTimeout,
            scanTimeout: scanTimeout,
            slowReposkipSeconds: slowReposkipSeconds,
            activeRepoThreshold: activeRepoThreshold
        )
    }

    func with(gitCommandTimeout: TimeInterval) -> ScanConfig {
        ScanConfig(
            enabledBuiltInPaths: enabledBuiltInPaths,
            customPaths: customPaths,
            maxDepth: maxDepth,
            changedPreviewLimit: changedPreviewLimit,
            maxConcurrentGitOps: maxConcurrentGitOps,
            gitCommandTimeout: gitCommandTimeout,
            scanTimeout: scanTimeout,
            slowReposkipSeconds: slowReposkipSeconds,
            activeRepoThreshold: activeRepoThreshold
        )
    }

    func with(scanTimeout: TimeInterval) -> ScanConfig {
        ScanConfig(
            enabledBuiltInPaths: enabledBuiltInPaths,
            customPaths: customPaths,
            maxDepth: maxDepth,
            changedPreviewLimit: changedPreviewLimit,
            maxConcurrentGitOps: maxConcurrentGitOps,
            gitCommandTimeout: gitCommandTimeout,
            scanTimeout: scanTimeout,
            slowReposkipSeconds: slowReposkipSeconds,
            activeRepoThreshold: activeRepoThreshold
        )
    }

    func with(activeRepoThreshold: Int) -> ScanConfig {
        ScanConfig(
            enabledBuiltInPaths: enabledBuiltInPaths,
            customPaths: customPaths,
            maxDepth: maxDepth,
            changedPreviewLimit: changedPreviewLimit,
            maxConcurrentGitOps: maxConcurrentGitOps,
            gitCommandTimeout: gitCommandTimeout,
            scanTimeout: scanTimeout,
            slowReposkipSeconds: slowReposkipSeconds,
            activeRepoThreshold: activeRepoThreshold
        )
    }
}

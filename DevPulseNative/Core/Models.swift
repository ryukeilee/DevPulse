import Foundation

// MARK: - Schema constants

enum RepositorySnapshotSchema {
    static let version = 1
}

// MARK: - Risk level

enum RiskLevel: String, Codable, Comparable {
    case low = "low"
    case medium = "medium"
    case high = "high"

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        let order: [RiskLevel] = [.low, .medium, .high]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - Repository status

enum RepositoryStatus: String, Codable {
    case clean = "clean"
    case changed = "changed"
    case error = "error"
}

// MARK: - Repository snapshot

struct RepositorySnapshot: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let branch: String
    let status: RepositoryStatus
    let changedFileCount: Int
    let changedFilesPreview: [String]
    let risk: RiskLevel
    let lastScannedAt: String
    let lastChangedAt: String?
    let errorMessage: String?
    var isPinned: Bool

    static func == (lhs: RepositorySnapshot, rhs: RepositorySnapshot) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Scan summary

struct ScanSummary: Codable {
    let totalRepositories: Int
    let changedRepositories: Int
    let totalChangedFiles: Int
    let errorRepositories: Int
}

// MARK: - App Group root data

struct AppGroupData: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let scanSummary: ScanSummary
    let repositories: [RepositorySnapshot]

    static func empty() -> AppGroupData {
        AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            scanSummary: ScanSummary(
                totalRepositories: 0,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 0
            ),
            repositories: []
        )
    }
}

// MARK: - Widget-specific display entry

struct WidgetRepositoryEntry: Codable {
    let id: String
    let name: String
    let branch: String
    let status: RepositoryStatus
    let changedFileCount: Int
    let risk: RiskLevel
    let topChangedFile: String?

    init(from snapshot: RepositorySnapshot) {
        self.id = snapshot.id
        self.name = snapshot.name
        self.branch = snapshot.branch
        self.status = snapshot.status
        self.changedFileCount = snapshot.changedFileCount
        self.risk = snapshot.risk
        self.topChangedFile = snapshot.changedFilesPreview.first
    }
}

// MARK: - Scan-location toggle

struct ScanLocationToggle: Identifiable, Codable {
    let id: String
    let path: String
    var isEnabled: Bool
    let isBuiltIn: Bool
}

// MARK: - Custom scan directory

struct CustomScanDirectory: Identifiable, Codable {
    let id: String
    let path: String
    var isAccessible: Bool

    init(id: String = UUID().uuidString, path: String, isAccessible: Bool = false) {
        self.id = id
        self.path = path
        self.isAccessible = isAccessible
    }
}

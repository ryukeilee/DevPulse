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

struct RepositoryChangeCounts: Codable, Equatable {
    let modified: Int
    let added: Int
    let deleted: Int
    let untracked: Int
    let staged: Int
    let conflicted: Int

    var total: Int {
        modified + added + deleted + untracked
    }
}

struct RepositorySnapshot: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let branch: String
    let status: RepositoryStatus
    let modifiedFileCount: Int
    let addedFileCount: Int
    let deletedFileCount: Int
    let untrackedFileCount: Int
    let stagedFileCount: Int?
    let conflictedFileCount: Int?
    let aheadCount: Int?
    let changedFileCount: Int
    let changedFilesPreview: [String]
    let risk: RiskLevel
    let lastScannedAt: String
    let lastChangedAt: String?
    let errorMessage: String?
    var isPinned: Bool

    static func == (lhs: RepositorySnapshot, rhs: RepositorySnapshot) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.path == rhs.path
            && lhs.branch == rhs.branch
            && lhs.status == rhs.status
            && lhs.modifiedFileCount == rhs.modifiedFileCount
            && lhs.addedFileCount == rhs.addedFileCount
            && lhs.deletedFileCount == rhs.deletedFileCount
            && lhs.untrackedFileCount == rhs.untrackedFileCount
            && lhs.stagedFileCount == rhs.stagedFileCount
            && lhs.conflictedFileCount == rhs.conflictedFileCount
            && lhs.aheadCount == rhs.aheadCount
            && lhs.changedFileCount == rhs.changedFileCount
            && lhs.changedFilesPreview == rhs.changedFilesPreview
            && lhs.risk == rhs.risk
            && lhs.lastScannedAt == rhs.lastScannedAt
            && lhs.lastChangedAt == rhs.lastChangedAt
            && lhs.errorMessage == rhs.errorMessage
            && lhs.isPinned == rhs.isPinned
    }

    var changeCounts: RepositoryChangeCounts {
        RepositoryChangeCounts(
            modified: modifiedFileCount,
            added: addedFileCount,
            deleted: deletedFileCount,
            untracked: untrackedFileCount,
            staged: stagedFileCount ?? 0,
            conflicted: conflictedFileCount ?? 0
        )
    }

    var commitReadiness: CommitReadinessAssessment {
        CommitReadinessEngine.assess(snapshot: self)
    }
}

// MARK: - Activity timeline

enum ActivityTimelineState: String, Codable, Equatable {
    case neverScanned
    case noRepositories
    case allClean
    case active
}

struct ActivityTimelineFeed: Codable, Equatable {
    let state: ActivityTimelineState
    let items: [ActivityTimelineItem]

    var topItem: ActivityTimelineItem? {
        items.first
    }

    var hasItems: Bool {
        !items.isEmpty
    }
}

struct ActivityTimelineItem: Codable, Identifiable, Equatable {
    let id: String
    let repoName: String
    let repoPath: String
    let branch: String
    let status: RepositoryStatus
    let risk: RiskLevel
    let modifiedFileCount: Int
    let addedFileCount: Int
    let deletedFileCount: Int
    let untrackedFileCount: Int
    let stagedFileCount: Int
    let conflictedFileCount: Int
    let aheadCount: Int
    let changedFileCount: Int
    let changedFilesPreview: [String]
    let lastChangedAt: String?
    let lastScannedAt: String

    init(from snapshot: RepositorySnapshot) {
        id = snapshot.id
        repoName = snapshot.name
        repoPath = snapshot.path
        branch = snapshot.branch
        status = snapshot.status
        risk = snapshot.risk
        modifiedFileCount = snapshot.modifiedFileCount
        addedFileCount = snapshot.addedFileCount
        deletedFileCount = snapshot.deletedFileCount
        untrackedFileCount = snapshot.untrackedFileCount
        stagedFileCount = snapshot.stagedFileCount ?? 0
        conflictedFileCount = snapshot.conflictedFileCount ?? 0
        aheadCount = snapshot.aheadCount ?? 0
        changedFileCount = snapshot.changedFileCount
        changedFilesPreview = ActivityTimelineItem.previewBasenames(from: snapshot.changedFilesPreview)
        lastChangedAt = snapshot.lastChangedAt
        lastScannedAt = snapshot.lastScannedAt
    }

    var activityDate: Date? {
        if let lastChangedAt, let date = DateFormatting.date(from: lastChangedAt) {
            return date
        }
        return DateFormatting.date(from: lastScannedAt)
    }

    var commitReadiness: CommitReadinessAssessment {
        CommitReadinessEngine.assess(
            status: status,
            branch: branch,
            risk: risk,
            modifiedFileCount: modifiedFileCount,
            addedFileCount: addedFileCount,
            deletedFileCount: deletedFileCount,
            untrackedFileCount: untrackedFileCount,
            stagedFileCount: stagedFileCount,
            conflictedFileCount: conflictedFileCount,
            aheadCount: aheadCount,
            scanError: status == .error
        )
    }

    private static func previewBasenames(from preview: [String]) -> [String] {
        var seen = Set<String>()
        var basenames: [String] = []

        for path in preview {
            let basename = (path as NSString).lastPathComponent
            guard !basename.isEmpty else { continue }
            if seen.insert(basename).inserted {
                basenames.append(basename)
            }
            if basenames.count == 3 {
                break
            }
        }

        return basenames
    }
}

enum ActivityTimelineBuilder {
    static func build(from repositories: [RepositorySnapshot],
                      lastScanAt: Date?) -> ActivityTimelineFeed {
        let items = repositories
            .map(ActivityTimelineItem.init(from:))
            .sorted(by: sort(_:_:))

        return ActivityTimelineFeed(
            state: classify(repositories: repositories, lastScanAt: lastScanAt),
            items: items
        )
    }

    static func build(from snapshot: AppGroupData, lastScanAt: Date? = nil) -> ActivityTimelineFeed {
        let fallbackLastScanAt = lastScanAt ?? DateFormatting.date(from: snapshot.writtenAt ?? snapshot.generatedAt)
        return build(from: snapshot.repositories, lastScanAt: fallbackLastScanAt)
    }

    private static func classify(repositories: [RepositorySnapshot],
                                 lastScanAt: Date?) -> ActivityTimelineState {
        guard !repositories.isEmpty else {
            return lastScanAt == nil ? .neverScanned : .noRepositories
        }

        let hasChanged = repositories.contains { $0.status == .changed }
        let hasError = repositories.contains { $0.status == .error }

        if !hasChanged && !hasError {
            return .allClean
        }

        return .active
    }

    private static func sort(_ lhs: ActivityTimelineItem,
                             _ rhs: ActivityTimelineItem) -> Bool {
        let lhsPriority = statusPriority(lhs.status)
        let rhsPriority = statusPriority(rhs.status)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        if let lhsDate = lhs.activityDate, let rhsDate = rhs.activityDate, lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        if lhs.activityDate != nil {
            return true
        }

        if rhs.activityDate != nil {
            return false
        }

        if lhs.changedFileCount != rhs.changedFileCount {
            return lhs.changedFileCount > rhs.changedFileCount
        }

        if lhs.risk != rhs.risk {
            return lhs.risk > rhs.risk
        }

        return lhs.repoName.localizedStandardCompare(rhs.repoName) == .orderedAscending
    }

    private static func statusPriority(_ status: RepositoryStatus) -> Int {
        switch status {
        case .changed:
            return 0
        case .clean:
            return 1
        case .error:
            return 2
        }
    }
}

// MARK: - Scan summary

struct ScanSummary: Codable, Equatable {
    let totalRepositories: Int
    let changedRepositories: Int
    let totalChangedFiles: Int
    let errorRepositories: Int
}

// MARK: - App Group root data

struct AppGroupData: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: String
    let writtenAt: String?
    let scanSummary: ScanSummary
    let repositories: [RepositorySnapshot]

    static func empty() -> AppGroupData {
        AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            writtenAt: nil,
            scanSummary: ScanSummary(
                totalRepositories: 0,
                changedRepositories: 0,
                totalChangedFiles: 0,
                errorRepositories: 0
            ),
            repositories: []
        )
    }

    func withWrittenAt(_ writtenAt: String) -> AppGroupData {
        AppGroupData(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            writtenAt: writtenAt,
            scanSummary: scanSummary,
            repositories: repositories
        )
    }
}

// MARK: - Refresh status

enum RefreshPhase: Equatable {
    case idle
    case refreshing
    case success
    case failure
}

enum SnapshotFreshness: Equatable {
    case fresh
    case aging
    case stale
}

enum RefreshStatusFormatter {
    static let agingThreshold: TimeInterval = 5 * 60
    static let staleThreshold: TimeInterval = 15 * 60

    static func freshness(for lastUpdatedAt: Date, now: Date = Date()) -> SnapshotFreshness {
        let age = max(0, now.timeIntervalSince(lastUpdatedAt))

        if age > staleThreshold {
            return .stale
        }

        if age >= agingThreshold {
            return .aging
        }

        return .fresh
    }

    static func updateLabel(for lastUpdatedAt: Date, now: Date = Date()) -> String {
        let age = max(0, now.timeIntervalSince(lastUpdatedAt))

        if age < 60 {
            return "刚刚更新"
        }

        if age < 3600 {
            return "\(Int(age / 60)) 分钟前更新"
        }

        if age < 86400 {
            return "\(Int(age / 3600)) 小时前更新"
        }

        return "\(Int(age / 86400)) 天前更新"
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

// MARK: - Diagnostics

struct DiagnosticEvent: Identifiable, Equatable {
    enum Kind: String, Codable {
        case scanStarted
        case scanSucceeded
        case scanFailed
        case sharedDataWritten
        case sharedDataWriteFailed
        case sharedDataReadFailed
        case widgetReloadRequested
        case validationPassed
        case validationFailed
    }

    let id = UUID()
    let timestamp: String
    let kind: Kind
    let message: String
}

struct DiagnosticsSnapshot {
    var appBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "unknown"
    var widgetBundleIdentifier: String = "local.devpulse.app.widget"
    var appGroupIdentifier: String = "group.local.devpulse"
    var appGroupContainerPath: String?
    var snapshotFilePath: String?
    var appGroupAvailable: Bool = false
    var snapshotExists: Bool = false
    var snapshotReadable: Bool = false
    var snapshotWritable: Bool = false
    var snapshotDecodable: Bool = false
    var lastScanAt: Date?
    var lastGeneratedAt: String?
    var lastWrittenAt: String?
    var lastSharedWriteAt: Date?
    var lastReloadRequestedAt: Date?
    var sharedDataReadAt: Date?
    var widgetSnapshotReadAt: Date?
    var sharedDataReadError: String?
    var sharedDataWriteError: String?
    var widgetSnapshotReadError: String?
    var validationIssues: [String] = []
    var sharedDataSnapshot: AppGroupData?
    var widgetSnapshot: AppGroupData?

    var sharedDataReadSucceeded: Bool {
        sharedDataReadError == nil && sharedDataSnapshot != nil
    }

    var sharedDataWriteSucceeded: Bool {
        sharedDataWriteError == nil && lastSharedWriteAt != nil
    }

    var widgetSnapshotReadSucceeded: Bool {
        widgetSnapshotReadError == nil && widgetSnapshot != nil
    }
}

// MARK: - Shared store errors

enum AppGroupStoreError: LocalizedError, Equatable {
    case appGroupUnavailable
    case snapshotMissing
    case schemaVersionMismatch(expected: Int, actual: Int)
    case readFailed(String)
    case decodeFailed(String)
    case writeFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group container is unavailable."
        case .snapshotMissing:
            return "Shared snapshot file is missing."
        case .schemaVersionMismatch(let expected, let actual):
            return "Shared snapshot schema mismatch. Expected v\(expected), found v\(actual)."
        case .readFailed(let reason):
            return "Failed to read shared snapshot: \(reason)"
        case .decodeFailed(let reason):
            return "Failed to decode shared snapshot: \(reason)"
        case .writeFailed(let reason):
            return "Failed to write shared snapshot: \(reason)"
        case .verificationFailed(let reason):
            return "Shared snapshot verification failed: \(reason)"
        }
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

struct CustomScanDirectory: Identifiable, Codable, Equatable {
    let id: String
    let path: String
    let bookmarkData: Data?

    init(id: String = UUID().uuidString, path: String, bookmarkData: Data? = nil) {
        self.id = id
        self.path = path
        self.bookmarkData = bookmarkData
    }
}

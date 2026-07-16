import CryptoKit
import Foundation

enum ActivityEventKind: String, Codable, CaseIterable, Equatable {
    case newCommit
    case workingTreeChanged
    case stagingChanged
    case branchChanged
    case synchronizationChanged
    case conflictStarted
    case conflictResolved
    case readFailed
    case readRecovered

    var title: String {
        switch self {
        case .newCommit: return "发现新提交"
        case .workingTreeChanged: return "本地改动变化"
        case .stagingChanged: return "暂存状态变化"
        case .branchChanged: return "分支切换"
        case .synchronizationChanged: return "领先/落后变化"
        case .conflictStarted: return "出现冲突"
        case .conflictResolved: return "冲突已解除"
        case .readFailed: return "读取失败"
        case .readRecovered: return "读取已恢复"
        }
    }

    var systemImage: String {
        switch self {
        case .newCommit: return "point.topleft.down.to.point.bottomright.curvepath"
        case .workingTreeChanged: return "doc.badge.ellipsis"
        case .stagingChanged: return "tray.and.arrow.down"
        case .branchChanged: return "arrow.triangle.branch"
        case .synchronizationChanged: return "arrow.up.arrow.down"
        case .conflictStarted: return "exclamationmark.triangle.fill"
        case .conflictResolved: return "checkmark.shield"
        case .readFailed: return "xmark.octagon.fill"
        case .readRecovered: return "arrow.clockwise.circle"
        }
    }

    /// Lower values are more important for Widget selection and stable ties.
    var priority: Int {
        switch self {
        case .conflictStarted: return 0
        case .readFailed: return 1
        case .newCommit: return 2
        case .branchChanged: return 3
        case .synchronizationChanged: return 4
        case .conflictResolved, .readRecovered: return 5
        case .stagingChanged: return 6
        case .workingTreeChanged: return 7
        }
    }
}

struct ActivityEventState: Codable, Equatable {
    let branch: String
    let lastCommitID: String?
    let lastCommitSummary: String?
    let modified: Int
    let added: Int
    let deleted: Int
    let untracked: Int
    let staged: Int
    let unstaged: Int
    let conflicted: Int
    let ahead: Int?
    let behind: Int?
    let hasUpstream: Bool?
    let dataSource: RepositoryDataSource
    let errorMessage: String?

    init(snapshot: RepositorySnapshot) {
        branch = snapshot.branch
        lastCommitID = snapshot.lastCommitID
        lastCommitSummary = snapshot.lastCommitSummary
        modified = snapshot.modifiedFileCount
        added = snapshot.addedFileCount
        deleted = snapshot.deletedFileCount
        untracked = snapshot.untrackedFileCount
        staged = snapshot.stagedFileCount ?? 0
        unstaged = snapshot.unstagedFileCount
            ?? (snapshot.modifiedFileCount + snapshot.addedFileCount + snapshot.deletedFileCount)
        conflicted = snapshot.conflictedFileCount ?? 0
        ahead = snapshot.aheadCount
        behind = snapshot.behindCount
        hasUpstream = snapshot.hasUpstream
        dataSource = snapshot.resolvedDataSource
        errorMessage = snapshot.errorMessage
    }

    func summary(for kind: ActivityEventKind) -> String {
        switch kind {
        case .newCommit:
            let subject = lastCommitSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortID = lastCommitID.map { String($0.prefix(8)) }
            if let subject, !subject.isEmpty { return subject }
            return shortID ?? "无提交"
        case .workingTreeChanged:
            return "改动 \(modified + added + deleted + untracked) · 修 \(modified) / 增 \(added) / 删 \(deleted) / 未跟踪 \(untracked)"
        case .stagingChanged:
            return "已暂存 \(staged) · 未暂存 \(unstaged)"
        case .branchChanged:
            return branch
        case .synchronizationChanged:
            guard hasUpstream != false else { return "未关联上游" }
            guard let ahead, let behind else { return "领先/落后未知" }
            return "领先 \(ahead) · 落后 \(behind)"
        case .conflictStarted, .conflictResolved:
            return "冲突 \(conflicted)"
        case .readFailed, .readRecovered:
            switch dataSource {
            case .current:
                return "Git 元数据可读"
            case .lastSuccessful:
                return errorMessage.map { "读取失败 · \($0)" } ?? "显示上次成功数据"
            case .unknown:
                return errorMessage.map { "读取失败 · \($0)" } ?? "读取状态未知"
            }
        }
    }
}

struct ActivityEvent: Codable, Identifiable, Equatable {
    let id: String
    let repositoryID: String
    let repositoryName: String
    let kind: ActivityEventKind
    let occurredAt: String
    let before: ActivityEventState
    let after: ActivityEventState

    var beforeSummary: String { before.summary(for: kind) }
    var afterSummary: String { after.summary(for: kind) }
    var priority: Int { kind.priority }

    var summary: ActivityEventSummary {
        ActivityEventSummary(
            id: id,
            repositoryID: repositoryID,
            repositoryName: repositoryName,
            kind: kind,
            occurredAt: occurredAt,
            message: "\(beforeSummary) → \(afterSummary)",
            priority: priority
        )
    }
}

/// Compact projection embedded in `repositories.json` for Widget consumption.
/// Full before/after event state remains only in the bounded local event store.
struct ActivityEventSummary: Codable, Identifiable, Equatable {
    let id: String
    let repositoryID: String
    let repositoryName: String
    let kind: ActivityEventKind
    let occurredAt: String
    let message: String
    let priority: Int
}

enum ActivityEventOrdering {
    static func sorted(_ events: [ActivityEvent]) -> [ActivityEvent] {
        events.sorted(by: precedes(_:_:))
    }

    static func sortedSummaries(_ summaries: [ActivityEventSummary]) -> [ActivityEventSummary] {
        summaries.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return timestampPrecedes(
                lhs: lhs.occurredAt,
                rhs: rhs.occurredAt,
                lhsFallback: lhs.id,
                rhsFallback: rhs.id
            )
        }
    }

    private static func precedes(_ lhs: ActivityEvent, _ rhs: ActivityEvent) -> Bool {
        if lhs.occurredAt != rhs.occurredAt {
            return timestampPrecedes(
                lhs: lhs.occurredAt,
                rhs: rhs.occurredAt,
                lhsFallback: lhs.id,
                rhsFallback: rhs.id
            )
        }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        let nameOrder = lhs.repositoryName.localizedStandardCompare(rhs.repositoryName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id < rhs.id
    }

    private static func timestampPrecedes(
        lhs: String,
        rhs: String,
        lhsFallback: String,
        rhsFallback: String
    ) -> Bool {
        let lhsDate = DateFormatting.date(from: lhs)
        let rhsDate = DateFormatting.date(from: rhs)
        if let lhsDate, let rhsDate, lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs != rhs { return lhs > rhs }
        return lhsFallback < rhsFallback
    }
}

enum ActivityEventDiffer {
    static func events(
        previous: AppGroupData,
        current: AppGroupData,
        observedAt: String
    ) -> [ActivityEvent] {
        let previousByID = Dictionary(
            previous.repositories.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var result: [ActivityEvent] = []

        for next in current.repositories {
            guard let prior = previousByID[next.id] else { continue }
            result.append(contentsOf: events(previous: prior, current: next, observedAt: observedAt))
        }

        return ActivityEventOrdering.sorted(result)
    }

    static func events(
        previous: RepositorySnapshot,
        current: RepositorySnapshot,
        observedAt: String
    ) -> [ActivityEvent] {
        let wasReadable = isReadable(previous)
        let isCurrentlyReadable = isReadable(current)
        var kinds: [ActivityEventKind] = []

        if wasReadable, !isCurrentlyReadable {
            kinds.append(.readFailed)
            return kinds.map { makeEvent(kind: $0, previous: previous, current: current, observedAt: observedAt) }
        }

        if !wasReadable, isCurrentlyReadable {
            kinds.append(.readRecovered)
            if previous.resolvedDataSource == .unknown {
                return kinds.map { makeEvent(kind: $0, previous: previous, current: current, observedAt: observedAt) }
            }
        } else if !wasReadable, !isCurrentlyReadable {
            return []
        }

        if commitChanged(previous: previous, current: current) {
            kinds.append(.newCommit)
        }
        if workingTreeChanged(previous: previous, current: current) {
            kinds.append(.workingTreeChanged)
        }
        let previousStaged = previous.stagedFileCount ?? 0
        let currentStaged = current.stagedFileCount ?? 0
        let previousUnstaged = previous.unstagedFileCount
            ?? (previous.modifiedFileCount + previous.addedFileCount + previous.deletedFileCount)
        let currentUnstaged = current.unstagedFileCount
            ?? (current.modifiedFileCount + current.addedFileCount + current.deletedFileCount)
        if previousStaged != currentStaged || previousUnstaged != currentUnstaged {
            kinds.append(.stagingChanged)
        }
        if previous.branch != current.branch {
            kinds.append(.branchChanged)
        }
        if previous.aheadCount != current.aheadCount
            || previous.behindCount != current.behindCount
            || previous.hasUpstream != current.hasUpstream {
            kinds.append(.synchronizationChanged)
        }

        let oldConflicts = previous.conflictedFileCount ?? 0
        let newConflicts = current.conflictedFileCount ?? 0
        if oldConflicts == 0, newConflicts > 0 {
            kinds.append(.conflictStarted)
        } else if oldConflicts > 0, newConflicts == 0 {
            kinds.append(.conflictResolved)
        }

        return ActivityEventOrdering.sorted(kinds.map {
            makeEvent(kind: $0, previous: previous, current: current, observedAt: observedAt)
        })
    }

    private static func isReadable(_ snapshot: RepositorySnapshot) -> Bool {
        snapshot.resolvedDataSource == .current && snapshot.status != .error
    }

    private static func commitChanged(
        previous: RepositorySnapshot,
        current: RepositorySnapshot
    ) -> Bool {
        if let oldID = previous.lastCommitID, let newID = current.lastCommitID {
            return oldID != newID
        }
        return previous.lastChangedAt != current.lastChangedAt
            || previous.lastCommitSummary != current.lastCommitSummary
    }

    private static func workingTreeChanged(
        previous: RepositorySnapshot,
        current: RepositorySnapshot
    ) -> Bool {
        previous.modifiedFileCount != current.modifiedFileCount
            || previous.addedFileCount != current.addedFileCount
            || previous.deletedFileCount != current.deletedFileCount
            || previous.untrackedFileCount != current.untrackedFileCount
            || previous.changedFileCount != current.changedFileCount
    }

    private static func makeEvent(
        kind: ActivityEventKind,
        previous: RepositorySnapshot,
        current: RepositorySnapshot,
        observedAt: String
    ) -> ActivityEvent {
        let before = ActivityEventState(snapshot: previous)
        let after = ActivityEventState(snapshot: current)
        let identity = [
            current.id,
            kind.rawValue,
            observedAt,
            before.summary(for: kind),
            after.summary(for: kind)
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return ActivityEvent(
            id: "activity-v1-\(digest)",
            repositoryID: current.id,
            repositoryName: current.name,
            kind: kind,
            occurredAt: observedAt,
            before: before,
            after: after
        )
    }
}

enum ActivityEventDeduplicator {
    static func newEvents(
        from candidates: [ActivityEvent],
        comparedTo existing: [ActivityEvent]
    ) -> [ActivityEvent] {
        var history = ActivityEventOrdering.sorted(existing)
        var accepted: [ActivityEvent] = []

        for candidate in ActivityEventOrdering.sorted(candidates) {
            let latestMatchingDimension = history.first {
                $0.repositoryID == candidate.repositoryID
                    && family(for: $0.kind) == family(for: candidate.kind)
            }
            if let latestMatchingDimension,
               latestMatchingDimension.kind == candidate.kind,
               latestMatchingDimension.before == candidate.before,
               latestMatchingDimension.after == candidate.after {
                continue
            }
            accepted.append(candidate)
            history = ActivityEventOrdering.sorted(history + [candidate])
        }

        return accepted
    }

    private static func family(for kind: ActivityEventKind) -> String {
        switch kind {
        case .conflictStarted, .conflictResolved:
            return "conflict"
        case .readFailed, .readRecovered:
            return "read"
        default:
            return kind.rawValue
        }
    }
}

enum ActivityEventWidgetSummaryBuilder {
    static let maximumCount = 3
    static let recencyWindow: TimeInterval = 7 * 24 * 60 * 60

    static func build(
        from events: [ActivityEvent],
        now: Date = Date()
    ) -> [ActivityEventSummary] {
        let cutoff = now.addingTimeInterval(-recencyWindow)
        let recent = events.filter { event in
            guard let date = DateFormatting.date(from: event.occurredAt) else { return false }
            return date >= cutoff && date <= now.addingTimeInterval(60)
        }
        return Array(
            ActivityEventOrdering.sortedSummaries(recent.map(\.summary))
                .prefix(maximumCount)
        )
    }

    static func topSummary(from summaries: [ActivityEventSummary]) -> ActivityEventSummary? {
        ActivityEventOrdering.sortedSummaries(summaries).first
    }
}

struct ActivityEventArchive: Codable, Equatable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let events: [ActivityEvent]
}

enum ActivityEventStoreRecovery: Equatable {
    case none
    case migratedLegacy
    case recoveredCorruption
}

struct ActivityEventStoreLoadResult: Equatable {
    let events: [ActivityEvent]
    let recovery: ActivityEventStoreRecovery
}

enum ActivityEventStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "不支持活动记录 schema v\(version)"
        case .readFailed(let reason):
            return "活动记录读取失败：\(reason)"
        case .writeFailed(let reason):
            return "活动记录写入失败：\(reason)"
        }
    }
}

struct ActivityEventStore {
    static let fileName = "activity-events.json"
    static let defaultCapacity = 500

    let fileURL: URL
    let capacity: Int

    init(fileURL: URL, capacity: Int = defaultCapacity) {
        self.fileURL = fileURL
        self.capacity = max(capacity, 1)
    }

    static func live() -> ActivityEventStore? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedSnapshotLocation.appGroupIdentifier
        ) else { return nil }
        return ActivityEventStore(fileURL: container.appendingPathComponent(fileName))
    }

    func load() -> Result<ActivityEventStoreLoadResult, ActivityEventStoreError> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .success(ActivityEventStoreLoadResult(events: [], recovery: .none))
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .failure(.readFailed(error.localizedDescription))
        }

        let decoder = JSONDecoder()
        if let archive = try? decoder.decode(ActivityEventArchive.self, from: data) {
            guard archive.schemaVersion <= ActivityEventArchive.currentSchemaVersion else {
                return .failure(.unsupportedSchema(archive.schemaVersion))
            }
            let events = normalized(archive.events)
            if archive.schemaVersion < ActivityEventArchive.currentSchemaVersion {
                return persistRecovered(events, recovery: .migratedLegacy)
            }
            return .success(ActivityEventStoreLoadResult(events: events, recovery: .none))
        }

        if let events = try? decoder.decode([ActivityEvent].self, from: data) {
            return persistRecovered(normalized(events), recovery: .migratedLegacy)
        }

        // A damaged archive must not make every future scan fail. Replace it
        // atomically with an empty current archive and resume recording.
        return persistRecovered([], recovery: .recoveredCorruption)
    }

    func save(_ events: [ActivityEvent]) -> Result<[ActivityEvent], ActivityEventStoreError> {
        let normalizedEvents = normalized(events)
        let archive = ActivityEventArchive(
            schemaVersion: ActivityEventArchive.currentSchemaVersion,
            events: normalizedEvents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try encoder.encode(archive).write(to: fileURL, options: .atomic)
            return .success(normalizedEvents)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    func merging(
        existing: [ActivityEvent],
        newEvents: [ActivityEvent]
    ) -> [ActivityEvent] {
        var byID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for event in newEvents {
            byID[event.id] = event
        }
        return Array(ActivityEventOrdering.sorted(Array(byID.values)).prefix(capacity))
    }

    private func normalized(_ events: [ActivityEvent]) -> [ActivityEvent] {
        merging(existing: [], newEvents: events)
    }

    private func persistRecovered(
        _ events: [ActivityEvent],
        recovery: ActivityEventStoreRecovery
    ) -> Result<ActivityEventStoreLoadResult, ActivityEventStoreError> {
        switch save(events) {
        case .success(let saved):
            return .success(ActivityEventStoreLoadResult(events: saved, recovery: recovery))
        case .failure(let error):
            return .failure(error)
        }
    }
}

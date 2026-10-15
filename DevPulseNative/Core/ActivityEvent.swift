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

    func remappingRepositoryID(to repositoryID: String) -> ActivityEvent {
        ActivityEvent(
            id: id,
            repositoryID: repositoryID,
            repositoryName: repositoryName,
            kind: kind,
            occurredAt: occurredAt,
            before: before,
            after: after
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

    func remappingRepositoryID(to repositoryID: String) -> ActivityEventSummary {
        ActivityEventSummary(
            id: id,
            repositoryID: repositoryID,
            repositoryName: repositoryName,
            kind: kind,
            occurredAt: occurredAt,
            message: message,
            priority: priority
        )
    }
}

enum ActivityEventOrdering {
    static func sorted(_ events: [ActivityEvent]) -> [ActivityEvent] {
        guard events.count > 1 else { return events }
        // `precedes` parses both timestamps on every comparison, which the sort
        // pays `n log n` times. The canonical shape is checked in one pass
        // below, and for it the timestamp strings already order
        // chronologically, so this path compares them directly. Every other
        // input keeps the general path.
        if hasCanonicalUTCTimestamps(events) {
            return sortedByCanonicalTimestamps(events)
        }
        return events.sorted(by: precedes(_:_:))
    }

    /// Whether `events` is already the exact list `sorted(_:)` returns for it:
    /// strictly ordered by `precedes`, with no duplicate ids. A list of fewer
    /// than two events is trivially both.
    ///
    /// Otherwise this only answers `true` when every timestamp takes the
    /// canonical-UTC path, which is what makes `precedes` a strict total order
    /// and its sorted result unique. Every other input answers `false`, so its
    /// caller re-sorts it instead of trusting the order it holds.
    static func isStrictlyOrdered(_ events: [ActivityEvent]) -> Bool {
        guard events.count > 1 else { return true }
        guard hasCanonicalUTCTimestamps(events) else { return false }
        var seenIDs = Set<String>(minimumCapacity: events.count)
        for index in events.indices {
            guard seenIDs.insert(events[index].id).inserted else { return false }
            guard index > events.startIndex else { continue }
            guard canonicalPrecedes(events[index - 1], events[index]) else { return false }
        }
        return true
    }

    /// `precedes` for the canonical-UTC case, where the fixed-width timestamp
    /// strings compare chronologically.
    private static func canonicalPrecedes(_ lhs: ActivityEvent, _ rhs: ActivityEvent) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        return tieBreakPrecedes(lhs, rhs)
    }

    /// The canonical-UTC sort. Sorts a copy in place: this is the same stable
    /// sort `sorted(by:)` runs, without the second array copy it makes.
    private static func sortedByCanonicalTimestamps(
        _ events: [ActivityEvent]
    ) -> [ActivityEvent] {
        var sorted = events
        sorted.sort { canonicalPrecedes($0, $1) }
        return sorted
    }

    /// Whether every timestamp is `YYYY-MM-DDTHH:MM:SSZ` (20 bytes, UTC), the
    /// shape `DateFormatting.nowISO()` writes. Such strings are fixed width and
    /// zero padded, so their lexicographic order is their chronological order.
    /// The byte count is checked first because `canonicalDate` answers `nil`
    /// for it without a parse, and because any other length is rejected by the
    /// cheaper test alone.
    private static func hasCanonicalUTCTimestamps(_ events: [ActivityEvent]) -> Bool {
        events.allSatisfy {
            $0.occurredAt.utf8.count == 20
                && DateFormatting.canonicalDate($0.occurredAt) != nil
        }
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

    /// Strict "sorts before" relation used by `sorted(_:)`: the result order is
    /// newest timestamp first, then priority, repository name, kind and id.
    /// File-internal so the deduplicator can fold history into one pass with the
    /// exact same comparison the sort uses.
    fileprivate static func precedes(_ lhs: ActivityEvent, _ rhs: ActivityEvent) -> Bool {
        if lhs.occurredAt != rhs.occurredAt {
            return timestampPrecedes(
                lhs: lhs.occurredAt,
                rhs: rhs.occurredAt,
                lhsFallback: lhs.id,
                rhsFallback: rhs.id
            )
        }
        return tieBreakPrecedes(lhs, rhs)
    }

    /// The tail of `precedes` shared by both timestamp paths: what breaks a tie
    /// once the timestamps are known to be equal.
    private static func tieBreakPrecedes(_ lhs: ActivityEvent, _ rhs: ActivityEvent) -> Bool {
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

/// 「最近变化」中需要优先确认的注意力事件口径：冲突开始与读取失败。
/// 只有「未解除」的注意力事件才计入：同仓库同类型的后续解除/恢复事件
/// 会关闭该状态。时间线的提示条与计数共用此定义，避免视图内各自解释。
enum ActivityTimelineAttention {
    /// 未解除的注意力事件：按 (repositoryID, family) 取最新一条，最新状态
    /// 为冲突开始/读取失败才算未解除。返回保持入参顺序。
    static func openAttentionEvents(in events: [ActivityEvent]) -> [ActivityEvent] {
        var latestByFamily: [String: ActivityEvent] = [:]
        // Ordinary development events cannot open or close an attention
        // family. Exclude them before the timestamp-parsing sort, rather than
        // sorting the entire activity archive on every presentation update.
        let attentionEvents = events.filter { attentionFamily(for: $0.kind) != nil }
        for event in attentionEvents.sorted(by: newestFirst) {
            guard let family = attentionFamily(for: event.kind) else { continue }
            let key = "\(event.repositoryID)\u{1F}\(family)"
            if latestByFamily[key] == nil {
                latestByFamily[key] = event
            }
        }
        return events.filter { event in
            guard let family = attentionFamily(for: event.kind) else { return false }
            let key = "\(event.repositoryID)\u{1F}\(family)"
            return (event.kind == .conflictStarted || event.kind == .readFailed)
                && latestByFamily[key]?.id == event.id
        }
    }

    static func count(in events: [ActivityEvent]) -> Int {
        openAttentionEvents(in: events).count
    }

    /// 折叠态提示条口径：displayed 为前 displayedPrefix 条内的未解除注意力
    /// 事件数，additional 为更早记录中的未解除注意力事件数。两数相加恒等于
    /// 全部未解除注意力事件数。
    static func split(
        events: [ActivityEvent],
        displayedPrefix: Int
    ) -> (displayed: Int, additional: Int) {
        let open = openAttentionEvents(in: events)
        let displayedIDs = Set(events.prefix(max(0, displayedPrefix)).map(\.id))
        let displayed = open.filter { displayedIDs.contains($0.id) }.count
        return (displayed, open.count - displayed)
    }

    private static func attentionFamily(for kind: ActivityEventKind) -> String? {
        switch kind {
        case .conflictStarted, .conflictResolved: return "conflict"
        case .readFailed, .readRecovered: return "read"
        default: return nil
        }
    }

    private static func newestFirst(_ lhs: ActivityEvent, _ rhs: ActivityEvent) -> Bool {
        let lhsDate = DateFormatting.date(from: lhs.occurredAt)
        let rhsDate = DateFormatting.date(from: rhs.occurredAt)
        if let lhsDate, let rhsDate, lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        return lhs.id > rhs.id
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
        let digest = DigestHex.encode(SHA256.hash(data: Data(identity.utf8)))
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
    /// Identity of the newest-event index: one entry per repository and event
    /// family, mirroring the `(repositoryID, family(for: kind))` pair the
    /// previous scan matched on.
    private struct FamilyKey: Hashable {
        let repositoryID: String
        let family: String
    }

    static func newEvents(
        from candidates: [ActivityEvent],
        comparedTo existing: [ActivityEvent]
    ) -> [ActivityEvent] {
        // The index below keeps the maximum under `ActivityEventOrdering.precedes`,
        // which equals the old `sorted(...).first { ... }` only while that
        // relation is a strict total order. It is one exactly when every
        // timestamp is a shape `DateFormatting.canonicalDate` accepts: an
        // unparseable value makes `precedes` fall back to a raw string compare
        // that can cycle, and then the `first` of a sorted array is not a
        // maximum, so only the original re-sorting algorithm reproduces it.
        guard hasTotallyOrderedTimestamps(existing),
              hasTotallyOrderedTimestamps(candidates) else {
            return legacyNewEvents(from: candidates, comparedTo: existing)
        }

        // Index the newest history event per (repository, family) in one pass.
        // A candidate can only be a replay of that single newest entry, so the
        // index answers the question the old linear scan asked. The old code
        // re-sorted the whole history after every accepted candidate and then
        // scanned it linearly, making a batch cost
        // O(candidates x history log history); folding the history once keeps
        // the same result at O(history + candidates log candidates).
        var newestByFamily: [FamilyKey: ActivityEvent] = [:]
        newestByFamily.reserveCapacity(existing.count)
        for event in existing {
            keepNewest(event, in: &newestByFamily)
        }

        var accepted: [ActivityEvent] = []
        for candidate in ActivityEventOrdering.sorted(candidates) {
            let key = FamilyKey(
                repositoryID: candidate.repositoryID,
                family: family(for: candidate.kind)
            )
            if let newest = newestByFamily[key],
               newest.kind == candidate.kind,
               newest.before == candidate.before,
               newest.after == candidate.after {
                continue
            }
            accepted.append(candidate)
            keepNewest(candidate, in: &newestByFamily)
        }

        return accepted
    }

    /// Whether every timestamp is a canonical shape, which is what makes
    /// `ActivityEventOrdering.precedes` a strict total order.
    private static func hasTotallyOrderedTimestamps(_ events: [ActivityEvent]) -> Bool {
        events.allSatisfy { DateFormatting.canonicalDate($0.occurredAt) != nil }
    }

    /// The previous implementation, kept for the inputs whose timestamps do not
    /// order totally: it re-sorts the whole history after every accepted
    /// candidate, so it still reproduces whatever `first`-of-sorted result the
    /// old code read for them.
    private static func legacyNewEvents(
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

    /// Retains `event` for its (repository, family) slot when it precedes the
    /// event already indexed there, i.e. when it is newer in the ordering.
    private static func keepNewest(
        _ event: ActivityEvent,
        in index: inout [FamilyKey: ActivityEvent]
    ) {
        let key = FamilyKey(
            repositoryID: event.repositoryID,
            family: family(for: event.kind)
        )
        if let current = index[key], !ActivityEventOrdering.precedes(event, current) {
            return
        }
        index[key] = event
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

    /// Observation-only hook invoked with the byte count of every successful
    /// whole-file write. `nil` (the default) leaves production behaviour and
    /// semantics untouched; tests use it to count writes deterministically.
    let writeObserver: (@Sendable (Int) -> Void)?

    init(
        fileURL: URL,
        capacity: Int = defaultCapacity,
        writeObserver: (@Sendable (Int) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.capacity = max(capacity, 1)
        self.writeObserver = writeObserver
    }

    static func live() -> ActivityEventStore? {
        guard let container = SharedSnapshotLocation.containerURL else { return nil }
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
            let data = try encoder.encode(archive)
            try data.write(to: fileURL, options: .atomic)
            writeObserver?(data.count)
            return .success(normalizedEvents)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    func merging(
        existing: [ActivityEvent],
        newEvents: [ActivityEvent]
    ) -> [ActivityEvent] {
        // Every steady-state caller merges into a list this store produced
        // itself, and most rounds detect nothing new. Re-sorting and
        // re-truncating such a list cannot change it, so the archive is
        // returned as it stands. `isAlreadyNormalized` only answers `true`
        // when that identity is provable; see its documentation.
        if newEvents.isEmpty, isAlreadyNormalized(existing) {
            return existing
        }
        var byID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for event in newEvents {
            byID[event.id] = event
        }
        return Array(ActivityEventOrdering.sorted(Array(byID.values)).prefix(capacity))
    }

    /// Whether `events` is already exactly what `normalized` would return for
    /// it: within `capacity`, with unique ids, and in the strict order
    /// `ActivityEventOrdering.sorted(_:)` produces.
    ///
    /// `isStrictlyOrdered` supplies the order and identity checks, and answers
    /// `true` only for canonical timestamps. There `precedes` is a strict total
    /// order, so an already ordered list is the single order the sort could
    /// produce, and re-sorting cannot reorder it.
    private func isAlreadyNormalized(_ events: [ActivityEvent]) -> Bool {
        events.count <= capacity && ActivityEventOrdering.isStrictlyOrdered(events)
    }

    func pruning(
        _ events: [ActivityEvent],
        keepingRepositoryIDs repositoryIDs: Set<String>
    ) -> [ActivityEvent] {
        normalized(events.filter { repositoryIDs.contains($0.repositoryID) })
    }

    private func normalized(_ events: [ActivityEvent]) -> [ActivityEvent] {
        // The same list folded in as the `existing` side rather than as `new`
        // events: one pair sequence, one de-duplication rule (the later
        // occurrence of an id wins), and it shares `merging`'s identity
        // shortcut instead of re-sorting a list that needs no sort.
        merging(existing: events, newEvents: [])
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

import Foundation
import OSLog

// MARK: - Evaluation result

struct PendingItemEvaluationResult: Sendable {
    let items: [PendingItem]
    let transitions: [PendingItemTransition]
    let notifications: [(item: PendingItem, transition: PendingItemTransition, reason: String)]
    let repositoryIdsExamined: Int
    let workspaceIdsExamined: Int
    let newItemCount: Int
    let resolvedItemCount: Int
    let escalatedCount: Int
    let deescalatedCount: Int
    let durationMs: Double
    let warnings: [String]
}

// MARK: - Context for evaluation

struct PendingItemEvaluationContext: Sendable {
    let repositories: [RepositorySnapshot]
    let workspaceAggregations: [String: WorkspaceAggregation]
    let workspaces: [Workspace]
    let healthAssessments: [String: RepositoryHealthAssessment]
    let previousItems: [PendingItem]
    let now: Date

    init(
        repositories: [RepositorySnapshot],
        workspaceAggregations: [String: WorkspaceAggregation] = [:],
        workspaces: [Workspace] = [],
        healthAssessments: [String: RepositoryHealthAssessment] = [:],
        previousItems: [PendingItem] = [],
        now: Date = Date()
    ) {
        self.repositories = repositories
        self.workspaceAggregations = workspaceAggregations
        self.workspaces = workspaces
        self.healthAssessments = healthAssessments
        self.previousItems = previousItems
        self.now = now
    }
}

// MARK: - Cached assessment helpers

private struct CachedHealth {
    let dirtyDuration: TimeInterval?
    let unpushedDuration: TimeInterval?
    let behindDuration: TimeInterval?
    let staleActivity: Bool
    let creepingChanges: Bool
    let frequentReadFailures: Int
    let recurringConflicts: Int
    let hasRecentRecovery: Bool
    let overallRisk: RiskLevel
}

// MARK: - Rule scope

/// Identifies the single pending item one rule owns for a repository or a
/// workspace.
///
/// This is the initializer's identity without `title`: a rule's title is a
/// human-readable payload it may rewrite, and a rule that stops firing has no
/// candidate to read a title from, so neither the lookup that resolves a
/// disappeared condition nor the lookup that updates a live one can depend on
/// it. The stored item keeps the id it was minted with.
private struct RuleScopeKey: Hashable {
    let source: PendingItemSource
    let repositoryID: String?
    let workspaceID: String?

    init(_ item: PendingItem) {
        self.source = item.source
        self.repositoryID = item.repositoryID
        self.workspaceID = item.workspaceID
    }

    static func repository(_ source: PendingItemSource, _ repositoryID: String) -> RuleScopeKey {
        RuleScopeKey(source: source, repositoryID: repositoryID, workspaceID: nil)
    }

    static func workspace(_ source: PendingItemSource, _ workspaceID: String) -> RuleScopeKey {
        RuleScopeKey(source: source, repositoryID: nil, workspaceID: workspaceID)
    }

    private init(source: PendingItemSource, repositoryID: String?, workspaceID: String?) {
        self.source = source
        self.repositoryID = repositoryID
        self.workspaceID = workspaceID
    }
}

/// Identifies the repository or workspace that owns a previous item. The
/// cross-source carry-forward matches only items from the same owner: a
/// workspace item has a nil repository ID, so keying on the repository alone
/// would let one workspace inherit another workspace's history.
private struct OwnerKey: Hashable {
    let repositoryID: String?
    let workspaceID: String?

    init(_ item: PendingItem) {
        self.repositoryID = item.repositoryID
        self.workspaceID = item.workspaceID
    }
}

/// Canonical visit order for previous items that share an owner: earliest
/// detection first, then stable identity. Never depends on dictionary or
/// archive traversal order.
private func isEarlierPrevious(_ lhs: PendingItem, _ rhs: PendingItem) -> Bool {
    if lhs.firstDetectedAt != rhs.firstDetectedAt {
        if let lhsDate = DateFormatting.date(from: lhs.firstDetectedAt),
           let rhsDate = DateFormatting.date(from: rhs.firstDetectedAt),
           lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        return lhs.firstDetectedAt < rhs.firstDetectedAt
    }
    return lhs.id < rhs.id
}

/// The earlier of two ISO-8601 timestamps, compared by instant so a timezone
/// offset cannot invert the order, then by string when a value is not parseable.
private func earlierTimestamp(_ lhs: String, _ rhs: String) -> String {
    if let lhsDate = DateFormatting.date(from: lhs),
       let rhsDate = DateFormatting.date(from: rhs),
       lhsDate != rhsDate {
        return lhsDate < rhsDate ? lhs : rhs
    }
    return lhs <= rhs ? lhs : rhs
}

/// Whether `lhs` was confirmed more recently than `rhs`, by instant when both
/// parse, otherwise by the raw value.
private func isMoreRecentlyConfirmed(_ lhs: String, _ rhs: String) -> Bool {
    if let lhsDate = DateFormatting.date(from: lhs),
       let rhsDate = DateFormatting.date(from: rhs),
       lhsDate != rhsDate {
        return lhsDate > rhsDate
    }
    return lhs > rhs
}

/// Canonical choice between two previous items that describe the same rule
/// scope or id: a live item outranks a frozen history entry, then the most
/// recently confirmed record wins, then a fixed status/severity order, then the
/// earliest detection. Every comparison is value-derived, so a legacy archive
/// holding several records for one scope resolves to the same item regardless of
/// the order they are stored in.
private func isPreferredPrevious(_ lhs: PendingItem, _ rhs: PendingItem) -> Bool {
    let lhsResolved = lhs.status == .resolved
    let rhsResolved = rhs.status == .resolved
    if lhsResolved != rhsResolved { return !lhsResolved }
    if lhs.lastConfirmedAt != rhs.lastConfirmedAt {
        return isMoreRecentlyConfirmed(lhs.lastConfirmedAt, rhs.lastConfirmedAt)
    }
    if lhs.status != rhs.status { return lhs.status.rawValue < rhs.status.rawValue }
    if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
    if lhs.snoozedUntil != rhs.snoozedUntil {
        return (lhs.snoozedUntil ?? "") < (rhs.snoozedUntil ?? "")
    }
    return isEarlierPrevious(lhs, rhs)
}

/// Canonical choice between the candidates one rule produced for one identity
/// when duplicate repository occurrences disagree: the more severe one wins,
/// then the one with more evidence, then a stable textual order. Keeps the
/// surviving item independent of the order the occurrences were scanned in.
private func isPreferredCandidate(_ lhs: PendingItem, _ rhs: PendingItem) -> Bool {
    if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
    if lhs.evidence.count != rhs.evidence.count { return lhs.evidence.count > rhs.evidence.count }
    if lhs.evidence != rhs.evidence { return lhs.evidence.lexicographicallyPrecedes(rhs.evidence) }
    if lhs.explanation != rhs.explanation { return lhs.explanation < rhs.explanation }
    if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
    return false
}

private extension PendingItemSource {
    /// The evaluator's fixed rule dispatch order. A replaced history item
    /// inherits into the lowest-ranked live source of its owner, so duplicate
    /// repository occurrences cannot change which item inherits.
    var dispatchRank: Int {
        switch self {
        case .dirtyWorkspace: return 0
        case .unpushedCommits: return 1
        case .behindRemote: return 2
        case .mergeConflict: return 3
        case .upstreamMissing: return 4
        case .unavailable: return 5
        case .staleRepository: return 6
        case .scanFailure: return 7
        case .creepingChanges: return 8
        case .staleActivity: return 9
        case .healthTrend: return 10
        case .workspaceDegraded: return 11
        case .workspaceConflicts: return 12
        case .workspaceAggregation: return 13
        }
    }
}

// MARK: - Pending item evaluator

/// Background evaluator that generates pending items from scan results.
///
/// Design principles:
/// - Pure function: same input → same output
/// - Only evaluates conditions, never applies user actions
/// - Uses pre-computed data (no git commands)
/// - Bounded: per-repo and per-workspace rules are independent
enum PendingItemEvaluator {

    static let logger = Logger(subsystem: "local.devpulse.app", category: "PendingEvaluator")

    // MARK: - Main entry

    /// Evaluate all repositories and workspaces for pending items.
    ///
    /// - Parameters:
    ///   - context: Current scan results and previous items
    ///   - previousArchive: The prior full archive (for user-action preservation)
    /// - Returns: Evaluation result with items, transitions, and notifications
    static func evaluate(
        context: PendingItemEvaluationContext,
        previousArchive: PendingItemArchive? = nil
    ) -> PendingItemEvaluationResult {
        let start = Date()
        let warnings: [String] = []

        let previousItems = previousArchive?.items ?? context.previousItems
        // A legacy or hand-edited archive could repeat an id or a rule scope with
        // conflicting state. Keep one canonical item for each: a live item
        // outranks a frozen history entry, then the most recently confirmed
        // record wins, so neither the choice nor the traversal depends on the
        // order the archive happens to store them in.
        var previousByID: [String: PendingItem] = [:]
        previousByID.reserveCapacity(previousItems.count)
        for item in previousItems {
            guard let existing = previousByID[item.id] else {
                previousByID[item.id] = item
                continue
            }
            if isPreferredPrevious(item, existing) {
                previousByID[item.id] = item
            }
        }
        // Resolution and status carry-forward match a rule's own item by scope
        // rather than by the id derived from its title, so a condition that
        // disappeared is still found (and a retitled rule does not orphan its
        // history). A rule owns one item per scope; if a legacy archive holds
        // several, the same canonical choice applies.
        var previousByScope: [RuleScopeKey: PendingItem] = [:]
        previousByScope.reserveCapacity(previousItems.count)
        for item in previousItems {
            let key = RuleScopeKey(item)
            guard let existing = previousByScope[key] else {
                previousByScope[key] = item
                continue
            }
            if isPreferredPrevious(item, existing) {
                previousByScope[key] = item
            }
        }

        // Cache health assessments for fast lookup
        let healthByRepoID = context.healthAssessments

        var state = EvaluationState()

        // Keep explicit dispatch order. All of one repository's candidates are
        // computed before any is dispatched, so a rule whose condition is gone
        // can tell whether another source took the repository over (the
        // cross-rule path replaces the old item) or the repository is simply
        // clean (the rule resolves its own item).
        for repo in context.repositories {
            let health = healthByRepoID[repo.id]
            let cached = extractSignals(from: health)

            let dirtyWorkspace = evaluateDirtyWorkspace(repo, health, cached, context)
            let unpushedCommits = evaluateUnpushedCommits(repo, health, cached, context)
            let behindRemote = evaluateBehindRemote(repo, health, cached, context)
            let mergeConflict = evaluateMergeConflict(repo, health, cached, context)
            let upstreamMissing = evaluateUpstreamMissing(repo, health, cached, context)
            let unavailable = evaluateUnavailable(repo, health, cached, context)
            let staleRepository = evaluateStaleRepository(repo, health, cached, context)
            let scanFailure = evaluateScanFailure(repo, health, cached, context)
            let creepingChanges = evaluateCreepingChanges(repo, health, cached, context)
            let staleActivity = evaluateStaleActivity(repo, health, cached, context)
            let healthTrend = evaluateHealthTrend(repo, health, cached, context)

            var firingCount = 0
            if dirtyWorkspace != nil { firingCount += 1 }
            if unpushedCommits != nil { firingCount += 1 }
            if behindRemote != nil { firingCount += 1 }
            if mergeConflict != nil { firingCount += 1 }
            if upstreamMissing != nil { firingCount += 1 }
            if unavailable != nil { firingCount += 1 }
            if staleRepository != nil { firingCount += 1 }
            if scanFailure != nil { firingCount += 1 }
            if creepingChanges != nil { firingCount += 1 }
            if staleActivity != nil { firingCount += 1 }
            if healthTrend != nil { firingCount += 1 }

            func run(_ source: PendingItemSource, _ candidate: PendingItem?) {
                processRule(candidate: candidate,
                            scope: .repository(source, repo.id),
                            isSuperseded: candidate == nil ? firingCount > 0 : firingCount > 1,
                            isRepositoryRule: true,
                            previousByID: previousByID, previousByScope: previousByScope,
                            context: context, state: &state)
            }

            run(.dirtyWorkspace, dirtyWorkspace)
            run(.unpushedCommits, unpushedCommits)
            run(.behindRemote, behindRemote)
            run(.mergeConflict, mergeConflict)
            run(.upstreamMissing, upstreamMissing)
            run(.unavailable, unavailable)
            run(.staleRepository, staleRepository)
            run(.scanFailure, scanFailure)
            run(.creepingChanges, creepingChanges)
            run(.staleActivity, staleActivity)
            run(.healthTrend, healthTrend)
        }

        for workspace in context.workspaces {
            let aggregation = context.workspaceAggregations[workspace.id]
            let workspaceDegraded = evaluateWorkspaceDegraded(workspace, aggregation, context)
            let workspaceConflicts = evaluateWorkspaceConflicts(workspace, aggregation, context)
            let firingCount = (workspaceDegraded == nil ? 0 : 1) + (workspaceConflicts == nil ? 0 : 1)

            func run(_ source: PendingItemSource, _ candidate: PendingItem?) {
                processRule(candidate: candidate,
                            scope: .workspace(source, workspace.id),
                            isSuperseded: candidate == nil ? firingCount > 0 : firingCount > 1,
                            isRepositoryRule: false,
                            previousByID: previousByID, previousByScope: previousByScope,
                            context: context, state: &state)
            }

            run(.workspaceDegraded, workspaceDegraded)
            run(.workspaceConflicts, workspaceConflicts)
        }

        // Post-processing: carry forward firstDetectedAt from previous items
        // with a different source but the same repository or workspace. This
        // ensures transitions like unavailable → staleRepository preserve the
        // original detection timestamp, and it resolves previous items whose
        // source changed to a different category.
        //
        // One canonical record per rule scope, so duplicate or conflicting scope
        // history is neither double-counted nor reported through a suppressed
        // record. Only these statuses can resolve.
        var resolvablePreviousByOwner: [OwnerKey: [PendingItem]] = [:]
        if !state.items.isEmpty {
            resolvablePreviousByOwner.reserveCapacity(previousByScope.count)
            for item in previousByScope.values {
                switch item.status {
                case .active, .acknowledged, .restored:
                    resolvablePreviousByOwner[OwnerKey(item), default: []].append(item)
                case .snoozed, .muted, .resolved, .permanentlyIgnored:
                    break
                }
            }
        }

        // Consume the replaced history per owner. A previous record goes to the
        // lowest-ranked live source that can replace it, so a duplicate
        // repository occurrence and the input order cannot change which item
        // inherits the timestamp or which transition is reported.
        var liveIndicesByOwner: [OwnerKey: [Int]] = [:]
        var ownerOrder: [OwnerKey] = []
        for index in state.items.indices {
            let item = state.items[index]
            guard item.status != .resolved else { continue }
            let owner = OwnerKey(item)
            guard resolvablePreviousByOwner[owner]?.isEmpty == false else { continue }
            if liveIndicesByOwner[owner] == nil { ownerOrder.append(owner) }
            liveIndicesByOwner[owner, default: []].append(index)
        }

        for owner in ownerOrder {
            guard let liveIndices = liveIndicesByOwner[owner],
                  let matchingPrev = resolvablePreviousByOwner[owner] else { continue }
            let targets = liveIndices.sorted { lhs, rhs in
                let lhsRank = state.items[lhs].source.dispatchRank
                let rhsRank = state.items[rhs].source.dispatchRank
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs < rhs
            }
            // Visit matching previous items in a canonical, value-derived order
            // so the transitions stay stable across input and archive order.
            for prev in matchingPrev.sorted(by: isEarlierPrevious) {
                // Skip a source that still produced a candidate (its rule handled
                // it), one the absent-candidate branch already resolved or kept,
                // and one already replaced by another live source for this owner.
                guard !state.firingScopes.contains(RuleScopeKey(prev)),
                      !state.absentScopes.contains(RuleScopeKey(prev)),
                      !state.supersededScopes.contains(RuleScopeKey(prev)) else { continue }
                guard let targetIndex = targets.first(where: { state.items[$0].source != prev.source }) else {
                    continue
                }
                state.supersededScopes.insert(RuleScopeKey(prev))
                let target = state.items[targetIndex]
                // Record a transition from the old source to the new one. The old
                // item is not added to state.items — the new item replaces it with
                // the preserved firstDetectedAt.
                let transition = PendingItemTransition(
                    from: prev.status,
                    to: .resolved,
                    severityChanged: true,
                    previousSeverity: prev.severity,
                    newSeverity: target.severity,
                    reason: "仓库状态从 \(prev.source.displayName) 转为 \(target.source.displayName)"
                )
                state.transitions.append(transition)
                state.resolvedCount += 1

                // Carry forward the owner's original detection timestamp. The
                // earliest across the replaced sources keeps the result
                // independent of the order those sources are stored in.
                let inherited = earlierTimestamp(target.firstDetectedAt, prev.firstDetectedAt)
                if inherited != target.firstDetectedAt {
                    state.items[targetIndex] = PendingItem(
                        id: target.id,
                        source: target.source,
                        severity: target.severity,
                        repositoryID: target.repositoryID,
                        repositoryName: target.repositoryName,
                        workspaceID: target.workspaceID,
                        workspaceName: target.workspaceName,
                        title: target.title,
                        explanation: target.explanation,
                        evidence: target.evidence,
                        firstDetectedAt: inherited,
                        lastConfirmedAt: target.lastConfirmedAt,
                        status: target.status,
                        snoozedUntil: target.snoozedUntil,
                        duration: target.duration,
                        lastTransition: target.lastTransition
                    )
                }
            }
        }

        // Sort by severity descending, then lastConfirmedAt descending, then id,
        // so items that tie on the business keys keep a stable order.
        state.items.sort {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.lastConfirmedAt != $1.lastConfirmedAt {
                return isMoreRecentlyConfirmed($0.lastConfirmedAt, $1.lastConfirmedAt)
            }
            return $0.id < $1.id
        }

        // Resolutions cancelled later in the evaluation never reach the caller.
        let transitions = state.cancelledTransitionIndices.isEmpty
            ? state.transitions
            : state.transitions.enumerated()
                .filter { !state.cancelledTransitionIndices.contains($0.offset) }
                .map(\.element)

        let duration = Date().timeIntervalSince(start) * 1000

        return PendingItemEvaluationResult(
            items: state.items,
            transitions: transitions,
            notifications: state.notifications,
            repositoryIdsExamined: context.repositories.count,
            workspaceIdsExamined: context.workspaces.count,
            newItemCount: state.newCount,
            resolvedItemCount: state.resolvedCount,
            escalatedCount: state.escalatedCount,
            deescalatedCount: state.deescalatedCount,
            durationMs: duration,
            warnings: warnings
        )
    }

    // MARK: - Rule evaluation helpers

    /// Mutable output shared by rule dispatch and post-processing. The repository
    /// position index intentionally excludes workspace appends, which are not deduplicated.
    private struct EvaluationState {
        var items: [PendingItem] = []
        var firstItemIndexByID: [String: Int] = [:]
        var transitions: [PendingItemTransition] = []
        var notifications: [(PendingItem, PendingItemTransition, String)] = []
        /// Scopes whose rule produced a candidate this evaluation. A stored item
        /// for one of them is a live condition, not a recovered one.
        var firingScopes: Set<RuleScopeKey> = []
        /// Scopes the absent-candidate branch already emitted (a resolution or a
        /// carried-forward resolved item), so duplicate repository occurrences
        /// and the cross-rule pass cannot archive the same scope twice.
        var absentScopes: Set<RuleScopeKey> = []
        /// Scopes the cross-rule pass already resolved, so one replaced source is
        /// reported once even when several new sources appear for the repository.
        var supersededScopes: Set<RuleScopeKey> = []
        /// Every id already emitted, so an absent-candidate resolution can never
        /// append a second copy of an item a repository occurrence created.
        var itemIDs: Set<String> = []
        /// Transition index appended when this evaluation resolved a scope,
        /// keyed by the resolved item's id. A later live occurrence can revive
        /// the item; the stale recovery is then cancelled.
        var resolutionTransitionIndexByID: [String: Int] = [:]
        /// Indices removed from the returned transitions. Kept out-of-band so the
        /// append-only indices stay valid while the evaluation runs.
        var cancelledTransitionIndices: Set<Int> = []
        var newCount = 0
        var resolvedCount = 0
        var escalatedCount = 0
        var deescalatedCount = 0
    }

    // Repository rules also detect explanation changes and deduplicate candidates;
    // workspace rules retain every append and only compare severity/title.
    private static func processRule(
        candidate: PendingItem?,
        scope: RuleScopeKey,
        isSuperseded: Bool,
        isRepositoryRule: Bool,
        previousByID: [String: PendingItem],
        previousByScope: [RuleScopeKey: PendingItem],
        context: PendingItemEvaluationContext,
        state: inout EvaluationState
    ) {
        guard let candidate else {
            // Condition not present for this rule and this repository/workspace.
            guard let previous = previousByScope[scope] else { return }

            // A resolved item stays in the archive: the completed list and the
            // resolved → active reappearance path depend on it, and a later
            // refresh must not report the same recovery again.
            if previous.status == .resolved {
                // One rule instance is handled once per evaluation: a duplicate
                // repository occurrence must not archive a second copy.
                guard state.absentScopes.insert(scope).inserted,
                      state.itemIDs.insert(previous.id).inserted else { return }
                // Register the position too, so a later dirty occurrence for the
                // same repository replaces this entry instead of appending a
                // second item with the same id.
                if isRepositoryRule && state.firstItemIndexByID[previous.id] == nil {
                    state.firstItemIndexByID[previous.id] = state.items.count
                }
                state.items.append(previous)
                return
            }

            // A different source took the repository over: the cross-rule path
            // replaces this item and preserves its firstDetectedAt, so resolving
            // it here would duplicate the recovery.
            guard !isSuperseded else { return }
            guard previous.status == .active || previous.status == .restored || previous.status == .acknowledged else {
                return
            }
            guard state.absentScopes.insert(scope).inserted,
                  state.itemIDs.insert(previous.id).inserted else { return }

            let transition = PendingItemStatusTransition.evaluate(
                current: previous,
                conditionStillActive: false,
                conditionChanged: false,
                newSeverity: nil,
                now: context.now
            )
            if transition.to == .resolved {
                state.resolvedCount += 1
                state.resolutionTransitionIndexByID[previous.id] = state.transitions.count
            }
            state.transitions.append(transition)
            var resolved = previous
            resolved.status = transition.to
            resolved.lastConfirmedAt = DateFormatting.nowISO()
            resolved.lastTransition = transition
            if isRepositoryRule && state.firstItemIndexByID[resolved.id] == nil {
                state.firstItemIndexByID[resolved.id] = state.items.count
            }
            state.items.append(resolved)
            return
        }

        state.firingScopes.insert(scope)

        // Generate or update
        let previous = previousByID[candidate.id]
        let conditionChanged: Bool
        if let prev = previous {
            conditionChanged = prev.severity != candidate.severity
                || prev.title != candidate.title
                || (isRepositoryRule && prev.explanation != candidate.explanation)
        } else {
            conditionChanged = true
        }

        let transition = PendingItemStatusTransition.evaluate(
            current: previous ?? candidate,
            conditionStillActive: true,
            conditionChanged: conditionChanged,
            newSeverity: candidate.severity,
            now: context.now
        )

        state.transitions.append(transition)

        if previous == nil { state.newCount += 1 }
        if transition.severityChanged {
            if let prevSeverity = transition.previousSeverity,
               let newSeverity = transition.newSeverity,
               newSeverity > prevSeverity {
                state.escalatedCount += 1
            } else {
                state.deescalatedCount += 1
            }
        }

        var finalItem = candidate
        if let prev = previous {
            finalItem = PendingItem(
                id: candidate.id,
                source: candidate.source,
                severity: candidate.severity,
                repositoryID: candidate.repositoryID,
                repositoryName: candidate.repositoryName,
                workspaceID: candidate.workspaceID,
                workspaceName: candidate.workspaceName,
                title: candidate.title,
                explanation: candidate.explanation,
                evidence: candidate.evidence,
                firstDetectedAt: prev.firstDetectedAt,
                lastConfirmedAt: DateFormatting.nowISO(),
                status: transition.to,
                snoozedUntil: transition.to == .snoozed ? prev.snoozedUntil : nil,
                duration: candidate.duration,
                lastTransition: transition
            )
        }

        // Deduplicate: if an item with the same ID already exists, keep the one with more evidence
        if !isRepositoryRule {
            state.itemIDs.insert(finalItem.id)
            state.items.append(finalItem)
        } else if let existingIdx = state.firstItemIndexByID[finalItem.id] {
            let existing = state.items[existingIdx]
            // A live candidate supersedes a recovery a clean occurrence already
            // carried forward for the same identity earlier in this evaluation;
            // otherwise keep the canonical candidate so duplicate occurrences of
            // one rule do not make the result depend on scan order.
            if existing.status == .resolved && finalItem.status != .resolved {
                state.items[existingIdx] = finalItem
                // A live occurrence revived an item this evaluation already
                // resolved; drop the stale recovery so the transitions and the
                // resolved count match the item that is actually returned.
                if let index = state.resolutionTransitionIndexByID.removeValue(forKey: finalItem.id) {
                    state.cancelledTransitionIndices.insert(index)
                    state.resolvedCount -= 1
                }
            } else if isPreferredCandidate(finalItem, existing) {
                state.items[existingIdx] = finalItem
            }
        } else {
            state.itemIDs.insert(finalItem.id)
            state.firstItemIndexByID[finalItem.id] = state.items.count
            state.items.append(finalItem)
        }

        // Check notification
        if transition.to.allowsNotification &&
            (previous == nil || transition.from != transition.to || transition.severityChanged) {
            state.notifications.append((finalItem, transition, transition.reason))
        }
    }

    // MARK: - Rule implementations

    private static func evaluateDirtyWorkspace(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        // Condition: changed files > 0 or health signal present
        let hasChanges = repo.resolvedDataSource == .current
            && repo.status == .changed
            && repo.changedFileCount > 0

        guard hasChanges || cached?.dirtyDuration != nil else { return nil }

        let duration = cached?.dirtyDuration ?? 0
        let severity: PendingItemSeverity
        if let health, health.overallRisk == .high {
            severity = .high
        } else if duration >= 24 * 3600 {
            severity = .high
        } else if duration >= 4 * 3600 {
            severity = .medium
        } else {
            severity = .low
        }

        let evidence = health?.signals
            .filter { $0.kind == .dirtyWorkspaceDuration }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .dirtyWorkspace,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "工作区存在长期改动",
            explanation: duration > 0
                ? "仓库 \(repo.name) 有 \(repo.changedFileCount) 个文件尚未提交，已持续 \(formatDuration(duration))。"
                : "仓库 \(repo.name) 有 \(repo.changedFileCount) 个文件尚未提交。",
            evidence: evidence + ["当前改动文件数：\(repo.changedFileCount)"],
            duration: duration
        )
    }

    private static func evaluateUnpushedCommits(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let ahead = repo.aheadCount ?? 0
        let hasAhead = repo.resolvedDataSource == .current && ahead > 0
        let hasHealthSignal = cached?.unpushedDuration != nil

        guard hasAhead || hasHealthSignal else { return nil }

        let duration = cached?.unpushedDuration ?? 0
        let severity: PendingItemSeverity
        if ahead >= 20 || (cached?.overallRisk == .high) {
            severity = .high
        } else if ahead >= 10 || duration >= 72 * 3600 {
            severity = .medium
        } else {
            severity = .low
        }

        let evidence = health?.signals
            .filter { $0.kind == .unpushedCommitsDuration }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .unpushedCommits,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "本地提交未推送",
            explanation: duration > 0
                ? "仓库 \(repo.name) 有 \(ahead) 个本地提交未推送到远端，已持续 \(formatDuration(duration))。"
                : "仓库 \(repo.name) 有 \(ahead) 个本地提交未推送到远端。",
            evidence: evidence + ["未推送提交数：\(ahead)"],
            duration: duration
        )
    }

    private static func evaluateBehindRemote(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let behind = repo.behindCount ?? 0
        let hasBehind = repo.resolvedDataSource == .current && behind > 0
        let hasHealthSignal = cached?.behindDuration != nil

        guard hasBehind || hasHealthSignal else { return nil }

        let duration = cached?.behindDuration ?? 0
        let severity: PendingItemSeverity
        if behind >= 50 || (cached?.overallRisk == .high) {
            severity = .high
        } else if behind >= 20 || duration >= 24 * 3600 {
            severity = .medium
        } else {
            severity = .low
        }

        let evidence = health?.signals
            .filter { $0.kind == .behindRemoteDuration }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .behindRemote,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "仓库落后远端",
            explanation: "仓库 \(repo.name) 落后远端 \(behind) 个提交，持续 \(formatDuration(duration))。",
            evidence: evidence + ["落后提交数：\(behind)"],
            duration: duration
        )
    }

    private static func evaluateMergeConflict(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let conflicted = repo.conflictedFileCount ?? 0
        let hasConflict = repo.resolvedDataSource == .current && conflicted > 0
        let recurringCount = cached?.recurringConflicts ?? 0

        guard hasConflict || recurringCount >= 2 else { return nil }

        let severity: PendingItemSeverity
        if conflicted > 5 || recurringCount >= 5 {
            severity = .critical
        } else if conflicted > 0 || recurringCount >= 3 {
            severity = .high
        } else {
            severity = .medium
        }

        let evidence = health?.signals
            .filter { $0.kind == .recurringConflicts }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .mergeConflict,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "存在合并冲突",
            explanation: conflicted > 0
                ? "仓库 \(repo.name) 当前有 \(conflicted) 个冲突文件需要解决。"
                : "仓库在过去 7 天出现了 \(recurringCount) 次冲突记录。",
            evidence: evidence + ["当前冲突文件数：\(conflicted)", "7天冲突次数：\(recurringCount)"],
            duration: 0
        )
    }

    private static func evaluateUpstreamMissing(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard repo.resolvedDataSource == .current,
              repo.hasUpstream == false,
              (repo.aheadCount ?? 0) > 0 || (repo.behindCount ?? 0) > 0 else {
            return nil
        }

        return PendingItem(
            source: .upstreamMissing,
            severity: .low,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "未关联上游分支",
            explanation: "仓库 \(repo.name) 当前分支未关联远端上游，无法正常推送/拉取。",
            evidence: ["当前分支：\(repo.branch)"],
            duration: 0
        )
    }

    private static func evaluateUnavailable(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let isUnavailable = repo.resolvedDataSource != .current || repo.status == .error
        guard isUnavailable else { return nil }

        let sinceDate: Date
        if let unavailableSince = repo.unavailableSince,
           let d = DateFormatting.date(from: unavailableSince) {
            sinceDate = d
        } else if let d = DateFormatting.date(from: repo.lastScannedAt) {
            sinceDate = d
        } else {
            sinceDate = context.now
        }
        let duration = context.now.timeIntervalSince(sinceDate)

        // Delegate to evaluateStaleRepository when duration exceeds retention window
        let retentionThreshold = RepositoryRetentionPolicy.unavailableRetentionInterval
        guard duration < retentionThreshold else { return nil }

        let severity: PendingItemSeverity
        if duration >= 24 * 3600 {
            severity = .high
        } else {
            severity = .medium
        }

        return PendingItem(
            source: .unavailable,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "仓库无法访问",
            explanation: "仓库 \(repo.name) 从 \(DateFormatting.displayString(from: sinceDate)) 起不可访问，持续 \(formatDuration(duration))。",
            evidence: ["错误信息：\(repo.errorMessage ?? "未知")"],
            duration: max(0, duration)
        )
    }

    private static func evaluateStaleRepository(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let isUnavailable = repo.resolvedDataSource != .current || repo.status == .error
        guard isUnavailable else { return nil }

        let sinceDate: Date
        if let unavailableSince = repo.unavailableSince,
           let d = DateFormatting.date(from: unavailableSince) {
            sinceDate = d
        } else if let d = DateFormatting.date(from: repo.lastScannedAt) {
            sinceDate = d
        } else {
            sinceDate = context.now
        }
        let duration = context.now.timeIntervalSince(sinceDate)

        // Only activate when unavailable duration exceeds the retention threshold
        let retentionThreshold = RepositoryRetentionPolicy.unavailableRetentionInterval
        guard duration >= retentionThreshold else { return nil }

        return PendingItem(
            source: .staleRepository,
            severity: .critical,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "仓库已长期无法访问",
            explanation: "仓库 \(repo.name) 从 \(DateFormatting.displayString(from: sinceDate)) 起已无法访问超过 7 天，持续 \(formatDuration(duration))。请在确认仓库本身已不存在后执行「清理」操作以移除跟踪。",
            evidence: ["错误信息：\(repo.errorMessage ?? "未知")", "持续时间：\(formatDuration(duration))"],
            duration: max(0, duration)
        )
    }

    private static func evaluateScanFailure(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        let failureCount = cached?.frequentReadFailures ?? 0
        guard failureCount >= 2 else { return nil }

        let severity: PendingItemSeverity
        if failureCount >= 5 {
            severity = .high
        } else if failureCount >= 3 {
            severity = .medium
        } else {
            severity = .low
        }

        let evidence = health?.signals
            .filter { $0.kind == .frequentReadFailures }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .scanFailure,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "连续扫描失败",
            explanation: "仓库 \(repo.name) 在过去 24 小时内出现 \(failureCount) 次扫描失败。",
            evidence: evidence + ["24小时失败次数：\(failureCount)"],
            duration: 0
        )
    }

    private static func evaluateCreepingChanges(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard cached?.creepingChanges == true else { return nil }

        let evidence = health?.signals
            .filter { $0.kind == .creepingChanges }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .creepingChanges,
            severity: .medium,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "改动量持续堆积",
            explanation: "仓库 \(repo.name) 的改动文件数在多次扫描中持续增长。",
            evidence: evidence,
            duration: 0
        )
    }

    private static func evaluateStaleActivity(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard cached?.staleActivity == true else { return nil }

        let severity: PendingItemSeverity
        if cached?.overallRisk == .high {
            severity = .high
        } else {
            severity = .low
        }

        let evidence = health?.signals
            .filter { $0.kind == .staleActivity }
            .map { $0.evidence } ?? []

        return PendingItem(
            source: .staleActivity,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "仓库长期不活跃",
            explanation: "仓库 \(repo.name) 超过 7 天没有检测到任何活动。",
            evidence: evidence,
            duration: 0
        )
    }

    private static func evaluateHealthTrend(
        _ repo: RepositorySnapshot,
        _ health: RepositoryHealthAssessment?,
        _ cached: CachedHealth?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard let health, health.hasSufficientHistory, !health.signals.isEmpty else { return nil }

        // Only generate a trend item if there are multiple medium+ signals
        let significantSignals = health.signals.filter { $0.level != .low }
        guard significantSignals.count >= 2 else { return nil }

        let severity: PendingItemSeverity
        switch health.overallRisk {
        case .high: severity = .high
        case .medium: severity = .medium
        case .low: severity = .low
        }

        let signalTitles = significantSignals.prefix(3).map(\.title)

        return PendingItem(
            source: .healthTrend,
            severity: severity,
            repositoryID: repo.id,
            repositoryName: repo.name,
            title: "综合健康趋势异常",
            explanation: health.primaryExplanation,
            evidence: signalTitles + ["评估时间：\(health.assessedAt)"],
            duration: 0
        )
    }

    // MARK: - Workspace rules

    private static func evaluateWorkspaceDegraded(
        _ workspace: Workspace,
        _ aggregation: WorkspaceAggregation?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard let aggregation, aggregation.totalRepositories > 0 else { return nil }
        guard aggregation.overallHealth == .critical || aggregation.overallHealth == .warning else {
            return nil
        }

        let severity: PendingItemSeverity
        switch aggregation.overallHealth {
        case .critical: severity = .high
        case .warning: severity = .medium
        case .healthy, .unknown: return nil
        }

        let detail: String
        if aggregation.errorCount > 0 {
            detail = "\(aggregation.errorCount) 个仓库有错误，\(aggregation.warningCount) 个需要关注"
        } else {
            detail = "\(aggregation.warningCount) 个仓库需要关注"
        }

        return PendingItem(
            source: .workspaceDegraded,
            severity: severity,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            title: "工作空间状态异常",
            explanation: "工作空间「\(workspace.name)」当前状态：\(detail)。",
            evidence: [
                "健康仓库：\(aggregation.healthyCount)",
                "警告仓库：\(aggregation.warningCount)",
                "错误仓库：\(aggregation.errorCount)",
                "不可用仓库：\(aggregation.unavailableRepositoryCount)"
            ],
            duration: 0
        )
    }

    private static func evaluateWorkspaceConflicts(
        _ workspace: Workspace,
        _ aggregation: WorkspaceAggregation?,
        _ context: PendingItemEvaluationContext
    ) -> PendingItem? {
        guard let aggregation, aggregation.conflictCount > 0 else { return nil }

        let severity: PendingItemSeverity = aggregation.conflictCount > 3 ? .high : .medium

        return PendingItem(
            source: .workspaceConflicts,
            severity: severity,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            title: "工作空间存在合并冲突",
            explanation: "工作空间「\(workspace.name)」中有 \(aggregation.conflictCount) 个仓库存在冲突。",
            evidence: ["冲突仓库：\(aggregation.conflictRepositoryNames.joined(separator: "、"))"],
            duration: 0
        )
    }

    // MARK: - Helpers

    private static func extractSignals(from health: RepositoryHealthAssessment?) -> CachedHealth? {
        guard let health else { return nil }
        let signals = health.signals

        return CachedHealth(
            dirtyDuration: signals.first(where: { $0.kind == .dirtyWorkspaceDuration }).flatMap { $0.duration },
            unpushedDuration: signals.first(where: { $0.kind == .unpushedCommitsDuration }).flatMap { $0.duration },
            behindDuration: signals.first(where: { $0.kind == .behindRemoteDuration }).flatMap { $0.duration },
            staleActivity: signals.contains(where: { $0.kind == .staleActivity }),
            creepingChanges: signals.contains(where: { $0.kind == .creepingChanges }),
            frequentReadFailures: signals.first(where: { $0.kind == .frequentReadFailures }).flatMap { failure in
                Int(failure.currentValue.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
            } ?? 0,
            recurringConflicts: signals.first(where: { $0.kind == .recurringConflicts }).flatMap { conflict in
                Int(conflict.currentValue.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
            } ?? 0,
            hasRecentRecovery: signals.contains(where: { $0.kind == .recentRecovery }),
            overallRisk: health.overallRisk
        )
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60

        if days > 0 {
            return "\(days) 天 \(hours) 小时"
        } else if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        } else if minutes > 0 {
            return "\(minutes) 分"
        }
        return "< 1 分"
    }
}

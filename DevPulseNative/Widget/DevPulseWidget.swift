import Foundation
import SwiftUI
import WidgetKit

private enum WidgetSnapshotSchema {
    static let version = RepositorySnapshotSchema.version
}

private enum WidgetSnapshotStore {
    static let appGroupIdentifier = SharedSnapshotLocation.appGroupIdentifier
    private static let snapshotFileName = SharedSnapshotLocation.fileName

    static func load() -> Result<AppGroupData, WidgetSnapshotLoadError> {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return .failure(.appGroupUnavailable)
        }

        let snapshotURL = containerURL.appendingPathComponent(snapshotFileName)
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            return .failure(.snapshotMissing(path: snapshotURL.path))
        }

        do {
            let data = try Data(contentsOf: snapshotURL)
            do {
                let snapshot = try JSONDecoder().decode(AppGroupData.self, from: data)
                guard snapshot.schemaVersion == WidgetSnapshotSchema.version else {
                    return .failure(.schemaMismatch(
                        expected: WidgetSnapshotSchema.version,
                        actual: snapshot.schemaVersion
                    ))
                }
                return .success(snapshot)
            } catch {
                return .failure(.decodeFailed(path: snapshotURL.path, reason: error.localizedDescription))
            }
        } catch {
            return .failure(.readFailed(path: snapshotURL.path, reason: error.localizedDescription))
        }
    }
}

enum WidgetSnapshotLoadError: LocalizedError, Equatable {
    case appGroupUnavailable
    case snapshotMissing(path: String)
    case readFailed(path: String, reason: String)
    case decodeFailed(path: String, reason: String)
    case schemaMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group container is unavailable."
        case .snapshotMissing(let path):
            return "Shared snapshot file is missing at \(path)."
        case .readFailed(let path, let reason):
            return "Shared snapshot read failed at \(path): \(reason)"
        case .decodeFailed(let path, let reason):
            return "Shared snapshot decode failed at \(path): \(reason)"
        case .schemaMismatch(let expected, let actual):
            return "Shared snapshot schema mismatch. Expected v\(expected), found v\(actual)."
        }
    }
}

enum WidgetLoadState: Equatable {
    case placeholder
    case noSnapshot
    case loadFailed
    case ready
}

struct WidgetLoadFailurePresentation: Equatable {
    let title: String
    let detail: String
    let icon: String
    let footerText: String
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (WidgetEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(loadEntry())
        }
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let entry = loadEntry()
        let nextRefreshInterval: TimeInterval
        switch entry.loadState {
        case .placeholder, .noSnapshot, .loadFailed:
            nextRefreshInterval = 300
        case .ready:
            nextRefreshInterval = 900
        }
        let nextRefresh = Date().addingTimeInterval(nextRefreshInterval)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadEntry() -> WidgetEntry {
        switch WidgetSnapshotStore.load() {
        case .success(let snapshot):
            return .content(
                snapshot: snapshot,
                feed: ActivityTimelineBuilder.build(from: snapshot)
            )
        case .failure(let error):
            switch error {
            case .snapshotMissing:
                return .noSnapshot()
            case .appGroupUnavailable, .readFailed, .decodeFailed, .schemaMismatch:
                return .loadFailed(error)
            }
        }
    }
}

struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AppGroupData?
    let feed: ActivityTimelineFeed
    let loadState: WidgetLoadState
    let loadFailure: WidgetLoadFailurePresentation?
    let trustAssessment: SnapshotTrustAssessment?

    static var placeholder: WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .placeholder,
            loadFailure: nil,
            trustAssessment: nil
        )
    }

    static func content(snapshot: AppGroupData,
                        feed: ActivityTimelineFeed) -> WidgetEntry {
        let trustAssessment = RefreshStatusFormatter.snapshotAssessment(
            generatedAt: snapshot.generatedAt,
            writtenAt: snapshot.writtenAt,
            missingReason: "共享快照缺少 generatedAt / writtenAt，无法确认 Widget 数据是否最新。"
        )

        return WidgetEntry(
            date: Date(),
            snapshot: snapshot,
            feed: feed,
            loadState: .ready,
            loadFailure: nil,
            trustAssessment: trustAssessment
        )
    }

    static func noSnapshot() -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .noSnapshot,
            loadFailure: nil,
            trustAssessment: nil
        )
    }

    static func loadFailed(_ error: WidgetSnapshotLoadError) -> WidgetEntry {
        WidgetEntry(
            date: Date(),
            snapshot: nil,
            feed: ActivityTimelineFeed(state: .neverScanned, items: []),
            loadState: .loadFailed,
            loadFailure: WidgetLoadFailurePresentation(
                title: error.widgetTitle,
                detail: error.widgetDetail,
                icon: error.widgetIcon,
                footerText: error.footerText
            ),
            trustAssessment: nil
        )
    }
}

struct DevPulseWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: WidgetEntry

    var body: some View {
        Group {
            switch widgetFamily {
            case .systemSmall:
                SmallGlanceWidgetView(entry: entry)
            case .systemMedium:
                MediumGlanceWidgetView(entry: entry)
            case .systemLarge:
                LargeGlanceWidgetView(entry: entry)
            default:
                SmallGlanceWidgetView(entry: entry)
            }
        }
        .containerBackground(for: .widget) {
            WidgetPanelBackground()
        }
    }
}

private enum WidgetPalette {
    static let base = Color(red: 0.08, green: 0.07, blue: 0.08)
    static let card = Color(red: 0.17, green: 0.12, blue: 0.13)
    static let cardStrong = Color(red: 0.22, green: 0.14, blue: 0.15)
    static let stroke = Color.white.opacity(0.07)
    static let subtleStroke = Color.white.opacity(0.035)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.70)
    static let textMuted = Color.white.opacity(0.54)
    static let accent = Color(red: 0.94, green: 0.33, blue: 0.20)
    static let accentSoft = Color(red: 0.79, green: 0.23, blue: 0.18)
    static let clean = Color(red: 0.51, green: 0.86, blue: 0.60)
    static let changed = Color(red: 0.98, green: 0.60, blue: 0.15)
    static let error = Color(red: 0.94, green: 0.34, blue: 0.28)
}

private struct WidgetPanelBackground: View {
    var body: some View {
        ContainerRelativeShape()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.26, green: 0.09, blue: 0.08),
                        Color(red: 0.15, green: 0.08, blue: 0.09),
                        WidgetPalette.base
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                ContainerRelativeShape()
                    .stroke(WidgetPalette.stroke, lineWidth: 0.6)
            )
    }
}

private struct WidgetCardBackground: View {
    var emphasis: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        WidgetPalette.cardStrong.opacity(0.96 + emphasis * 0.02),
                        WidgetPalette.card.opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                WidgetPalette.accent.opacity(0.18 + emphasis * 0.08),
                                Color.white.opacity(0.055),
                                Color.black.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.55
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.04 + emphasis * 0.015),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
    }
}

private struct WidgetFooterBar: View {
    let text: String
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Image(systemName: "clock")
                .font(.system(size: compact ? 7 : 8, weight: .semibold, design: .rounded))
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .font(.system(size: compact ? 8 : 9, weight: .medium, design: .rounded))
        .foregroundStyle(WidgetPalette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, compact ? 3 : 4)
        .background(WidgetCardBackground(emphasis: 0.04))
    }
}

private struct WidgetStateBlock: View {
    let title: String
    let detail: String?
    let icon: String
    var prominent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 6 : 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: prominent ? 13 : 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.accent.opacity(0.92))

                Text(title)
                    .font(.system(size: prominent ? 15 : 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if let detail {
                Text(detail)
                    .font(.system(size: prominent ? 11 : 10, weight: .medium, design: .rounded))
                    .foregroundStyle(WidgetPalette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, prominent ? 9 : 8)
        .padding(.vertical, prominent ? 8 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WidgetCardBackground())
    }
}

private struct WidgetChromeHeader: View {
    let trailingText: String?
    var compactTitle: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(WidgetPalette.accent.opacity(0.96))
            Text(compactTitle ? "DP" : "DevPulse")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(WidgetPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(compactTitle ? 1 : 0.8)
            Spacer(minLength: 0)
            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.textPrimary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(WidgetPalette.cardStrong.opacity(0.96))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(WidgetPalette.accent.opacity(0.18), lineWidth: 0.55)
                            )
                    )
            }
        }
    }
}

private struct WidgetSummaryStrip: View {
    let summary: ScanSummary
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            WidgetMetricCell(label: "仓库", value: "\(summary.totalRepositories)", compact: compact)
            WidgetMetricCell(label: "活跃", value: "\(summary.changedRepositories + summary.errorRepositories)", compact: compact)
            WidgetMetricCell(label: "改动", value: "\(summary.totalChangedFiles)", compact: compact)
            if summary.errorRepositories > 0 {
                WidgetMetricCell(label: "异常", value: "\(summary.errorRepositories)", tone: .warning, compact: compact)
            }
        }
    }
}

private struct WidgetMetricCell: View {
    enum Tone {
        case normal
        case warning
    }

    let label: String
    let value: String
    var tone: Tone = .normal
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: compact ? 7 : 8, weight: .semibold, design: .rounded))
                .foregroundStyle(WidgetPalette.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(value)
                .font(.system(size: compact ? 12 : 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, compact ? 3 : 5)
        .background(WidgetCardBackground())
    }

    private var valueColor: Color {
        switch tone {
        case .normal:
            return WidgetPalette.textPrimary
        case .warning:
            return WidgetPalette.error
        }
    }
}

private struct WidgetRepositoryBoard: View {
    enum Density {
        case panel
        case compact
        case regular
    }

    let items: [ActivityTimelineItem]
    let limit: Int
    var prominentFirst: Bool = false
    var showHintOnFirst: Bool = false
    var hideSecondaryBadgeOnFirst: Bool = false
    var density: Density = .regular

    var body: some View {
        let visibleItems = Array(items.prefix(limit))

        VStack(alignment: .leading, spacing: boardSpacing) {
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                WidgetRepositoryRow(
                    item: item,
                    prominent: prominentFirst && index == 0,
                    showHint: showHintOnFirst && index == 0,
                    hideSecondaryBadge: hideSecondaryBadgeOnFirst && index == 0,
                    density: density
                )
            }
        }
    }

    private var boardSpacing: CGFloat {
        switch density {
        case .panel:
            return 3
        case .compact:
            return 4
        case .regular:
            return 5
        }
    }
}

private struct WidgetRepositoryRow: View {
    let item: ActivityTimelineItem
    var prominent: Bool = false
    var showHint: Bool = false
    var hideSecondaryBadge: Bool = false
    var density: WidgetRepositoryBoard.Density = .regular

    private var readiness: CommitReadinessAssessment {
        item.commitReadiness
    }

    var body: some View {
        if density == .panel {
            panelBody
        } else {
            cardBody
        }
    }

    private var panelBody: some View {
        HStack(alignment: .center, spacing: 7) {
            WidgetStatusDot(status: item.status)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.repoName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .layoutPriority(2)

                Text(branchLabel)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(WidgetPalette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.78)
                    .layoutPriority(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(item.widgetChangeCountLabel)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(changeCountColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(item.activityLabel)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(WidgetPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(WidgetCardBackground(emphasis: 0.03))
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack(alignment: .top, spacing: 8) {
                WidgetStatusDot(status: item.status)

                VStack(alignment: .leading, spacing: density == .compact ? 2 : 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.repoName)
                            .font(.system(size: titleFontSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(WidgetPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .layoutPriority(2)

                        Spacer(minLength: 6)

                        Text(item.widgetChangeCountLabel)
                            .font(.system(size: prominent ? 10 : 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(changeCountColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    HStack(alignment: .center, spacing: 6) {
                        Text(branchLabel)
                            .font(.system(size: metadataFontSize, weight: .medium, design: .monospaced))
                            .foregroundStyle(WidgetPalette.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .minimumScaleFactor(0.78)
                            .layoutPriority(1)

                        Spacer(minLength: 4)

                        Text(item.activityLabel)
                            .font(.system(size: metadataFontSize, weight: .medium, design: .rounded))
                            .foregroundStyle(WidgetPalette.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            HStack(spacing: 5) {
                WidgetRepositoryStatusBadge(status: item.status)

                if !hideSecondaryBadge {
                    WidgetReadinessBadge(level: readiness.level, size: prominent ? .large : .compact)
                }

                Spacer(minLength: 0)
            }

            if showHint {
                Text(readiness.widgetShortHint)
                    .font(.system(size: density == .compact ? 9 : 10, weight: .medium, design: .rounded))
                    .foregroundStyle(WidgetPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
        }
        .padding(.horizontal, prominent ? 9 : 8)
        .padding(.vertical, verticalPadding)
        .background(WidgetCardBackground(emphasis: prominent ? 0.08 : 0))
    }

    private var titleFontSize: CGFloat {
        if prominent {
            return density == .compact ? 14 : 15
        }
        return density == .compact ? 12 : 13
    }

    private var metadataFontSize: CGFloat {
        if prominent {
            return density == .compact ? 9 : 10
        }
        return 9
    }

    private var rowSpacing: CGFloat {
        if prominent {
            return density == .compact ? 5 : 6
        }
        return density == .compact ? 4 : 5
    }

    private var verticalPadding: CGFloat {
        if prominent {
            return density == .compact ? 7 : 8
        }
        return density == .compact ? 6 : 7
    }

    private var branchLabel: String {
        item.branch.isEmpty ? "detached" : item.branch
    }

    private var changeCountColor: Color {
        switch item.status {
        case .clean:
            return WidgetPalette.textMuted
        case .changed:
            return WidgetPalette.changed
        case .error:
            return WidgetPalette.error
        }
    }
}

private struct WidgetSmallRepositoryFocus: View {
    let item: ActivityTimelineItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 7) {
                WidgetStatusDot(status: item.status)

                Text(item.repoName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .multilineTextAlignment(.leading)
                    .layoutPriority(2)
            }

            HStack(spacing: 5) {
                WidgetRepositoryStatusBadge(status: item.status, compact: true)

                if item.changedFileCount > 0 {
                    Text(smallChangeLabel)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .foregroundStyle(changeCountColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(changeCountColor.opacity(0.12))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(changeCountColor.opacity(0.12), lineWidth: 0.5)
                                )
                        )
                }
            }

            Text(shortReadinessLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(WidgetPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WidgetCardBackground(emphasis: 0.08))
    }

    private var smallChangeLabel: String {
        if item.changedFileCount > 99 {
            return "99+改"
        }
        return "\(item.changedFileCount)改"
    }

    private var shortReadinessLabel: String {
        item.commitReadiness.level.shortLabel
    }

    private var changeCountColor: Color {
        switch item.status {
        case .clean:
            return WidgetPalette.textMuted
        case .changed:
            return WidgetPalette.changed
        case .error:
            return WidgetPalette.error
        }
    }
}

private struct WidgetStatusDot: View {
    let status: RepositoryStatus

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: 13, height: 13)

            Circle()
                .fill(tint.opacity(0.92))
                .frame(width: 5, height: 5)
                .shadow(color: tint.opacity(0.55), radius: 5)
        }
        .overlay(
            Circle()
                .stroke(tint.opacity(0.14), lineWidth: 0.55)
        )
    }

    private var tint: Color {
        switch status {
        case .clean:
            return WidgetPalette.clean
        case .changed:
            return WidgetPalette.changed
        case .error:
            return WidgetPalette.error
        }
    }
}

private struct WidgetRepositoryStatusBadge: View {
    let status: RepositoryStatus
    var compact: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: compact ? 8 : 9, weight: .bold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(backgroundOpacity))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.12), lineWidth: 0.5)
                    )
            )
            .foregroundStyle(tint)
    }

    private var label: String {
        switch status {
        case .clean:
            return "Clean"
        case .changed:
            return "Dirty"
        case .error:
            return "Error"
        }
    }

    private var tint: Color {
        switch status {
        case .clean:
            return WidgetPalette.textMuted
        case .changed:
            return WidgetPalette.changed
        case .error:
            return WidgetPalette.error
        }
    }

    private var backgroundOpacity: Double {
        switch status {
        case .clean:
            return 0.1
        case .changed:
            return 0.14
        case .error:
            return 0.16
        }
    }
}

private struct SmallGlanceWidgetView: View {
    let entry: WidgetEntry

    private var prioritizedItems: [ActivityTimelineItem] {
        WidgetRepositoryPriorityBuilder.build(from: entry.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetChromeHeader(trailingText: nil, compactTitle: true)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
        .padding(.horizontal, 9)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch entry.loadState {
        case .placeholder:
            placeholderContent
        case .noSnapshot:
            shortState(
                title: WidgetRefreshCopy.waitingFirstRefreshTitle,
                detail: WidgetRefreshCopy.waitingFirstRefreshDetail,
                icon: "arrow.triangle.2.circlepath"
            )
        case .loadFailed:
            shortState(
                title: entry.loadFailure?.title ?? "共享快照读取失败",
                detail: entry.loadFailure?.detail,
                icon: entry.loadFailure?.icon ?? "exclamationmark.triangle.fill"
            )
        case .ready:
            guardedReadyContent
        }
    }

    @ViewBuilder
    private var guardedReadyContent: some View {
        switch entry.trustAssessment?.state {
        case .fresh:
            readyContent
        case .stale, .expired:
            shortState(
                title: WidgetRefreshCopy.waitingRefreshTitle,
                detail: WidgetRefreshCopy.waitingRefreshDetail(from: entry.trustAssessment),
                icon: "clock.badge.exclamationmark"
            )
        case .unknown, .failed:
            shortState(
                title: WidgetRefreshCopy.pendingConfirmationTitle,
                detail: WidgetRefreshCopy.pendingConfirmationDetail,
                icon: "questionmark.circle"
            )
        case .none:
            shortState(
                title: WidgetRefreshCopy.pendingConfirmationTitle,
                detail: WidgetRefreshCopy.pendingConfirmationDetail,
                icon: "questionmark.circle"
            )
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if prioritizedItems.isEmpty {
            shortState(
                title: "没有找到仓库",
                detail: "检查扫描目录后重新刷新",
                icon: "folder"
            )
        } else {
            WidgetSmallRepositoryFocus(item: prioritizedItems[0])
        }
    }

    @ViewBuilder
    private var placeholderContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.16))
                .frame(width: 84, height: 10)
            RoundedRectangle(cornerRadius: 8)
                .fill(WidgetPalette.accent.opacity(0.20))
                .frame(width: 104, height: 20)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.12))
                .frame(width: 132, height: 14)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.10))
                .frame(height: 10)
        }
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private func shortState(title: String, detail: String?, icon: String) -> some View {
        WidgetStateBlock(title: title, detail: detail, icon: icon, prominent: true)
    }
}

private struct MediumGlanceWidgetView: View {
    let entry: WidgetEntry

    private var prioritizedItems: [ActivityTimelineItem] {
        WidgetRepositoryPriorityBuilder.build(from: entry.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            WidgetChromeHeader(trailingText: headerTrailingText)

            content

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 7)
        .padding(.horizontal, 9)
        .padding(.bottom, 7)
    }

    private var headerTrailingText: String? {
        if case .ready = entry.loadState,
           let trustAssessment = entry.trustAssessment,
           trustAssessment.state != .fresh {
            switch trustAssessment.state {
            case .stale, .expired:
                return WidgetRefreshCopy.waitingRefreshTitle
            case .unknown, .failed:
                return WidgetRefreshCopy.pendingConfirmationTitle
            case .fresh:
                break
            }
        }

        guard
            case .ready = entry.loadState,
            entry.trustAssessment?.state == .fresh,
            let summary = entry.snapshot?.scanSummary
        else {
            return nil
        }

        if summary.totalRepositories == 0 {
            return "没有仓库"
        }

        let activeRepos = summary.changedRepositories + summary.errorRepositories
        if activeRepos == 0 {
            return "全部干净"
        }

        if summary.totalChangedFiles > 0 {
            return "\(activeRepos) 个活跃仓库 · \(summary.totalChangedFiles) 个文件"
        }

        return "\(activeRepos) 个活跃仓库"
    }

    @ViewBuilder
    private var content: some View {
        switch entry.loadState {
        case .placeholder:
            placeholderRows
        case .noSnapshot:
            shortState(
                title: WidgetRefreshCopy.waitingFirstRefreshTitle,
                detail: WidgetRefreshCopy.waitingFirstRefreshDetail,
                icon: "arrow.triangle.2.circlepath"
            )
        case .loadFailed:
            shortState(
                title: entry.loadFailure?.title ?? "共享快照读取失败",
                detail: entry.loadFailure?.detail,
                icon: entry.loadFailure?.icon ?? "exclamationmark.triangle.fill"
            )
        case .ready:
            guardedReadyContent
        }
    }

    @ViewBuilder
    private var guardedReadyContent: some View {
        switch entry.trustAssessment?.state {
        case .fresh:
            readyContent
        case .stale, .expired:
            shortState(
                title: WidgetRefreshCopy.waitingRefreshTitle,
                detail: WidgetRefreshCopy.waitingRefreshDetail(from: entry.trustAssessment),
                icon: "clock.badge.exclamationmark"
            )
        case .unknown, .failed:
            shortState(
                title: WidgetRefreshCopy.pendingConfirmationTitle,
                detail: WidgetRefreshCopy.pendingConfirmationDetail,
                icon: "questionmark.circle"
            )
        case .none:
            shortState(
                title: WidgetRefreshCopy.pendingConfirmationTitle,
                detail: WidgetRefreshCopy.pendingConfirmationDetail,
                icon: "questionmark.circle"
            )
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if prioritizedItems.isEmpty {
            shortState(
                title: "没有找到仓库",
                detail: "检查扫描目录后重新刷新",
                icon: "folder"
            )
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let summary = entry.snapshot?.scanSummary {
                    WidgetSummaryStrip(summary: summary, compact: true)
                }
                WidgetRepositoryBoard(items: prioritizedItems, limit: 2, density: .panel)
            }
        }
    }

    @ViewBuilder
    private var placeholderRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(WidgetPalette.accent.opacity(0.20))
                .frame(width: 70, height: 20)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.16))
                .frame(width: 140, height: 12)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.12))
                .frame(width: 190, height: 10)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.10))
                .frame(width: 88, height: 9)
        }
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private func shortState(title: String, detail: String?, icon: String) -> some View {
        WidgetStateBlock(title: title, detail: detail, icon: icon, prominent: false)
    }

    @ViewBuilder
    private var footer: some View {
        WidgetFooterBar(text: entry.footerText, compact: true)
    }
}

private struct LargeGlanceWidgetView: View {
    let entry: WidgetEntry

    private var prioritizedItems: [ActivityTimelineItem] {
        WidgetRepositoryPriorityBuilder.build(from: entry.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WidgetChromeHeader(trailingText: headerTrailingText)

            content

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var headerTrailingText: String? {
        if case .ready = entry.loadState,
           let trustAssessment = entry.trustAssessment,
           trustAssessment.state != .fresh {
            switch trustAssessment.state {
            case .stale, .expired:
                return WidgetRefreshCopy.waitingRefreshTitle
            case .unknown, .failed:
                return WidgetRefreshCopy.pendingConfirmationTitle
            case .fresh:
                break
            }
        }

        guard
            case .ready = entry.loadState,
            entry.trustAssessment?.state == .fresh,
            let summary = entry.snapshot?.scanSummary
        else {
            return nil
        }

        if summary.totalRepositories == 0 {
            return "没有仓库"
        }

        let activeRepos = summary.changedRepositories + summary.errorRepositories
        if activeRepos == 0 {
            return "全部干净"
        }

        return "\(activeRepos) 个待看仓库"
    }

    @ViewBuilder
    private var content: some View {
        switch entry.loadState {
        case .placeholder:
            placeholderRows
        case .noSnapshot:
            shortState(
                title: WidgetRefreshCopy.waitingFirstRefreshTitle,
                detail: WidgetRefreshCopy.waitingFirstRefreshDetail,
                icon: "arrow.triangle.2.circlepath"
            )
        case .loadFailed:
            shortState(
                title: entry.loadFailure?.title ?? "共享快照读取失败",
                detail: entry.loadFailure?.detail,
                icon: entry.loadFailure?.icon ?? "exclamationmark.triangle.fill"
            )
        case .ready:
            guardedReadyContent
        }
    }

    @ViewBuilder
    private var guardedReadyContent: some View {
        switch entry.trustAssessment?.state {
        case .fresh:
            readyContent
        case .stale, .expired:
            shortState(
                title: WidgetRefreshCopy.waitingRefreshTitle,
                detail: WidgetRefreshCopy.waitingRefreshDetail(from: entry.trustAssessment),
                icon: "clock.badge.exclamationmark"
            )
        case .unknown, .failed:
            shortState(
                title: WidgetRefreshCopy.pendingConfirmationTitle,
                detail: WidgetRefreshCopy.pendingConfirmationDetail,
                icon: "questionmark.circle"
            )
        case .none:
            shortState(
                title: WidgetRefreshCopy.pendingConfirmationTitle,
                detail: WidgetRefreshCopy.pendingConfirmationDetail,
                icon: "questionmark.circle"
            )
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if prioritizedItems.isEmpty {
            shortState(
                title: "没有找到仓库",
                detail: "检查扫描目录后重新刷新",
                icon: "folder"
            )
        } else {
            VStack(alignment: .leading, spacing: 5) {
                if let summary = entry.snapshot?.scanSummary {
                    WidgetSummaryStrip(summary: summary, compact: true)
                }
                WidgetRepositoryBoard(items: prioritizedItems, limit: 3, density: .compact)
            }
        }
    }

    @ViewBuilder
    private var placeholderRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 170, height: 12)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 10)
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private func shortState(title: String, detail: String?, icon: String) -> some View {
        WidgetStateBlock(title: title, detail: detail, icon: icon, prominent: true)
    }

    @ViewBuilder
    private var footer: some View {
        WidgetFooterBar(text: entry.footerText)
    }
}

private struct WidgetReadinessBadge: View {
    enum Size {
        case compact
        case large
    }

    let level: CommitReadinessLevel
    var size: Size = .compact

    var body: some View {
        HStack(spacing: size == .large ? 5 : 4) {
            Image(systemName: symbolName)
                .font(size == .large ? .caption.weight(.semibold) : .system(size: 9, weight: .bold, design: .rounded))
            Text(level.shortLabel)
                .font(badgeFont)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.14))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(0.12), lineWidth: 0.5)
                )
        )
        .foregroundStyle(tint)
    }

    private var badgeFont: Font {
        switch size {
        case .compact:
            return .system(size: 9, weight: .bold, design: .rounded)
        case .large:
            return .system(size: 12, weight: .bold, design: .rounded)
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .compact:
            return 6
        case .large:
            return 7
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .compact:
            return 2
        case .large:
            return 3
        }
    }

    private var tint: Color {
        switch level {
        case .idle:
            return WidgetPalette.textMuted
        case .review:
            return WidgetPalette.changed
        case .ready:
            return WidgetPalette.clean
        case .dirty:
            return WidgetPalette.error
        case .unknown:
            return WidgetPalette.error
        }
    }

    private var symbolName: String {
        switch level {
        case .idle:
            return "checkmark.circle.fill"
        case .review:
            return "questionmark.circle.fill"
        case .ready:
            return "arrow.up.circle.fill"
        case .dirty:
            return "exclamationmark.triangle.fill"
        case .unknown:
            return "exclamationmark.triangle.fill"
        }
    }
}

private struct SimpleWidgetChromeHeader: View {
    let trailingText: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption2.weight(.semibold))
            Text("DevPulse")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            if let trailingText {
                Text(trailingText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct SimpleWidgetStateBlock: View {
    let title: String
    let detail: String?
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SimpleWidgetRepositoryRow: View {
    let item: ActivityTimelineItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.repoName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(item.widgetChangeCountLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Text(statusLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(statusTint.opacity(0.14)))
                    .foregroundStyle(statusTint)

                Text(item.branch.isEmpty ? "detached" : item.branch)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Text(item.activityLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var statusLabel: String {
        switch item.status {
        case .clean:
            return "Clean"
        case .changed:
            return "Dirty"
        case .error:
            return "Error"
        }
    }

    private var statusTint: Color {
        switch item.status {
        case .clean:
            return .green
        case .changed:
            return .orange
        case .error:
            return .red
        }
    }
}

private struct SimpleSmallGlanceWidgetView: View {
    let entry: WidgetEntry

    private var prioritizedItems: [ActivityTimelineItem] {
        WidgetRepositoryPriorityBuilder.build(from: entry.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SimpleWidgetChromeHeader(trailingText: nil)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let state = fallbackState {
            SimpleWidgetStateBlock(title: state.title, detail: state.detail, icon: state.icon)
        } else if let item = prioritizedItems.first {
            SimpleWidgetRepositoryRow(item: item)
        } else {
            SimpleWidgetStateBlock(title: "没有找到仓库", detail: "检查扫描目录后重新刷新", icon: "folder")
        }
    }

    private var fallbackState: (title: String, detail: String?, icon: String)? {
        switch entry.loadState {
        case .placeholder:
            return ("正在读取共享快照", nil, "clock")
        case .noSnapshot:
            return (WidgetRefreshCopy.waitingFirstRefreshTitle, WidgetRefreshCopy.waitingFirstRefreshDetail, "arrow.triangle.2.circlepath")
        case .loadFailed:
            return (entry.loadFailure?.title ?? "共享快照读取失败", entry.loadFailure?.detail, entry.loadFailure?.icon ?? "exclamationmark.triangle.fill")
        case .ready:
            switch entry.trustAssessment?.state {
            case .stale, .expired:
                return (WidgetRefreshCopy.waitingRefreshTitle, WidgetRefreshCopy.waitingRefreshDetail(from: entry.trustAssessment), "clock.badge.exclamationmark")
            case .unknown, .failed, .none:
                return (WidgetRefreshCopy.pendingConfirmationTitle, WidgetRefreshCopy.pendingConfirmationDetail, "questionmark.circle")
            case .fresh:
                return nil
            }
        }
    }
}

private struct SimpleMediumGlanceWidgetView: View {
    let entry: WidgetEntry

    private var prioritizedItems: [ActivityTimelineItem] {
        WidgetRepositoryPriorityBuilder.build(from: entry.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SimpleWidgetChromeHeader(trailingText: mediumTrailingText)

            content

            Text(entry.footerText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let state = fallbackState {
            SimpleWidgetStateBlock(title: state.title, detail: state.detail, icon: state.icon)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(prioritizedItems.prefix(2).enumerated()), id: \.element.id) { index, item in
                    SimpleWidgetRepositoryRow(item: item)
                    if index == 0 && prioritizedItems.count > 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private var mediumTrailingText: String? {
        guard case .ready = entry.loadState else { return nil }
        guard let state = entry.trustAssessment?.state, state != .fresh else { return nil }
        switch state {
        case .stale, .expired:
            return WidgetRefreshCopy.waitingRefreshTitle
        case .unknown, .failed:
            return WidgetRefreshCopy.pendingConfirmationTitle
        case .fresh:
            return nil
        }
    }

    private var fallbackState: (title: String, detail: String?, icon: String)? {
        switch entry.loadState {
        case .placeholder:
            return ("正在读取共享快照", nil, "clock")
        case .noSnapshot:
            return (WidgetRefreshCopy.waitingFirstRefreshTitle, WidgetRefreshCopy.waitingFirstRefreshDetail, "arrow.triangle.2.circlepath")
        case .loadFailed:
            return (entry.loadFailure?.title ?? "共享快照读取失败", entry.loadFailure?.detail, entry.loadFailure?.icon ?? "exclamationmark.triangle.fill")
        case .ready:
            switch entry.trustAssessment?.state {
            case .stale, .expired:
                return (WidgetRefreshCopy.waitingRefreshTitle, WidgetRefreshCopy.waitingRefreshDetail(from: entry.trustAssessment), "clock.badge.exclamationmark")
            case .unknown, .failed, .none:
                return (WidgetRefreshCopy.pendingConfirmationTitle, WidgetRefreshCopy.pendingConfirmationDetail, "questionmark.circle")
            case .fresh:
                return prioritizedItems.isEmpty ? ("没有找到仓库", "检查扫描目录后重新刷新", "folder") : nil
            }
        }
    }
}

private struct SimpleLargeGlanceWidgetView: View {
    let entry: WidgetEntry

    private var prioritizedItems: [ActivityTimelineItem] {
        WidgetRepositoryPriorityBuilder.build(from: entry.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SimpleWidgetChromeHeader(trailingText: largeTrailingText)

            content

            Spacer(minLength: 0)

            Text(entry.footerText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if let state = fallbackState {
            SimpleWidgetStateBlock(title: state.title, detail: state.detail, icon: state.icon)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(prioritizedItems.prefix(3).enumerated()), id: \.element.id) { index, item in
                    SimpleWidgetRepositoryRow(item: item)
                    if index < min(prioritizedItems.count, 3) - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private var largeTrailingText: String? {
        guard case .ready = entry.loadState else { return nil }
        guard let state = entry.trustAssessment?.state, state != .fresh else { return nil }
        switch state {
        case .stale, .expired:
            return WidgetRefreshCopy.waitingRefreshTitle
        case .unknown, .failed:
            return WidgetRefreshCopy.pendingConfirmationTitle
        case .fresh:
            return nil
        }
    }

    private var fallbackState: (title: String, detail: String?, icon: String)? {
        switch entry.loadState {
        case .placeholder:
            return ("正在读取共享快照", nil, "clock")
        case .noSnapshot:
            return (WidgetRefreshCopy.waitingFirstRefreshTitle, WidgetRefreshCopy.waitingFirstRefreshDetail, "arrow.triangle.2.circlepath")
        case .loadFailed:
            return (entry.loadFailure?.title ?? "共享快照读取失败", entry.loadFailure?.detail, entry.loadFailure?.icon ?? "exclamationmark.triangle.fill")
        case .ready:
            switch entry.trustAssessment?.state {
            case .stale, .expired:
                return (WidgetRefreshCopy.waitingRefreshTitle, WidgetRefreshCopy.waitingRefreshDetail(from: entry.trustAssessment), "clock.badge.exclamationmark")
            case .unknown, .failed, .none:
                return (WidgetRefreshCopy.pendingConfirmationTitle, WidgetRefreshCopy.pendingConfirmationDetail, "questionmark.circle")
            case .fresh:
                return prioritizedItems.isEmpty ? ("没有找到仓库", "检查扫描目录后重新刷新", "folder") : nil
            }
        }
    }
}

private extension WidgetEntry {
    var footerText: String {
        switch loadState {
        case .placeholder:
            return "正在读取共享快照"
        case .noSnapshot:
            return "最近刷新: \(WidgetRefreshCopy.waitingFirstRefreshTitle)"
        case .loadFailed:
            return loadFailure?.footerText ?? "最近刷新: snapshot 读取失败"
        case .ready:
            if let trustAssessment, trustAssessment.state != .fresh {
                switch trustAssessment.state {
                case .stale, .expired:
                    return "\(WidgetRefreshCopy.waitingRefreshTitle) · \(trustAssessment.detail)"
                case .unknown, .failed:
                    return "最近刷新: \(WidgetRefreshCopy.pendingConfirmationTitle)"
                case .fresh:
                    break
                }
            }

            guard let snapshot else {
                return "最近刷新: 未知"
            }

            var timestamps: [(timestamp: String, date: Date)] = []
            if let writtenAt = snapshot.writtenAt, let writtenDate = DateFormatting.date(from: writtenAt) {
                timestamps.append((timestamp: writtenAt, date: writtenDate))
            }

            if let generatedDate = DateFormatting.date(from: snapshot.generatedAt) {
                timestamps.append((timestamp: snapshot.generatedAt, date: generatedDate))
            }

            guard let latest = timestamps.max(by: { $0.date < $1.date }) else {
                return "最近刷新: 未知"
            }

            return "最近刷新 \(DateFormatting.relativeTime(from: latest.timestamp, relativeTo: date))"
        }
    }
}

private extension WidgetSnapshotLoadError {
    var widgetTitle: String {
        switch self {
        case .appGroupUnavailable:
            return "共享容器不可用"
        case .snapshotMissing:
            return WidgetRefreshCopy.waitingFirstRefreshTitle
        case .readFailed:
            return "共享快照读取失败"
        case .decodeFailed:
            return "共享快照损坏"
        case .schemaMismatch:
            return "快照版本不匹配"
        }
    }

    var widgetDetail: String {
        switch self {
        case .appGroupUnavailable:
            return "检查 App 与 Widget 是否使用同一 Team / App Group，然后打开 Diagnostics"
        case .snapshotMissing:
            return WidgetRefreshCopy.waitingFirstRefreshDetail
        case .readFailed:
            return "打开 Diagnostics 检查 snapshot 路径、权限和共享容器状态"
        case .decodeFailed:
            return "在 DevPulse 执行 Refresh Data，重写共享 snapshot"
        case .schemaMismatch:
            return "重新构建 App 与 Widget 后，再执行 Refresh Data"
        }
    }

    var widgetIcon: String {
        switch self {
        case .appGroupUnavailable:
            return "externaldrive.badge.exclamationmark"
        case .snapshotMissing:
            return "arrow.triangle.2.circlepath"
        case .readFailed:
            return "exclamationmark.triangle.fill"
        case .decodeFailed:
            return "doc.badge.gearshape"
        case .schemaMismatch:
            return "arrow.triangle.2.circlepath.circle"
        }
    }

    var footerText: String {
        switch self {
        case .appGroupUnavailable:
            return "最近刷新: 共享容器不可用"
        case .snapshotMissing:
            return "最近刷新: \(WidgetRefreshCopy.waitingFirstRefreshTitle)"
        case .readFailed:
            return "最近刷新: snapshot 读取失败"
        case .decodeFailed:
            return "最近刷新: snapshot 解码失败"
        case .schemaMismatch:
            return "最近刷新: snapshot 版本不匹配"
        }
    }
}

private extension ActivityTimelineItem {
    var widgetChangeCountLabel: String {
        changedFileCount == 1 ? "1 处改动" : "\(changedFileCount) 处改动"
    }

    var activityLabel: String {
        if let lastChangedAt {
            return DateFormatting.relativeTime(from: lastChangedAt)
        }

        return DateFormatting.relativeTime(from: lastScannedAt)
    }
}

@main
struct DevPulseWidget: Widget {
    let kind = WidgetIdentity.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            DevPulseWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("DevPulse")
        .description("一眼查看本地 Git 仓库状态。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

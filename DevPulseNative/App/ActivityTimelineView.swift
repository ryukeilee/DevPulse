import SwiftUI

struct ActivityTimelineView: View {
    let events: [ActivityEvent]
    let repositories: [RepositorySnapshot]
    let lastScanAt: Date?
    let isScanning: Bool
    let onRescan: () -> Void
    @State private var showsAllEvents = false

    private var decisionsByRepositoryID: [String: RepositoryDecision] {
        ActivityTimelineDecisionContextBuilder.build(from: repositories)
    }

    /// Overview 只先展示最近一小段，避免历史记录把今日状态推到很下面；
    /// 展开仍沿用同一份本地活动记录，最多保留原有的 100 条上限。
    private static let initialDisplayedEventCount = 8
    private static let maxDisplayedEvents = 100

    private var orderedEvents: [ActivityEvent] {
        ActivityEventOrdering.sorted(events)
    }

    var body: some View {
        // 一次 body 求值只构建一次排序/展示列表与决策上下文，避免
        // 计算属性在 header / 计数 / 每行渲染处被重复执行。
        let orderedEvents = self.orderedEvents
        let displayedEvents = Array(
            orderedEvents.prefix(showsAllEvents ? Self.maxDisplayedEvents : Self.initialDisplayedEventCount)
        )
        let decisions = decisionsByRepositoryID
        // 提示口径覆盖全部冲突/读取异常：折叠态下较早记录中的注意力事件
        // 同样计入，避免"列表有冲突"因超出前 8 条而漏报。
        let attentionCount = ActivityTimelineAttention.count(in: displayedEvents)
        let additionalAttentionCount = max(
            0,
            ActivityTimelineAttention.count(in: orderedEvents) - attentionCount
        )
        return VStack(alignment: .leading, spacing: 12) {
            header(displayedEvents: displayedEvents)

            if events.isEmpty {
                emptyState
            } else {
                attentionNotice(
                    displayedCount: attentionCount,
                    additionalCount: additionalAttentionCount
                )

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayedEvents) { event in
                        ActivityEventRow(
                            event: event,
                            decision: decisions[event.repositoryID]
                        )

                        if event.id != displayedEvents.last?.id {
                            Divider().overlay(DevPulseVisualStyle.separator)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DevPulseVisualStyle.sectionCornerRadius, style: .continuous)
                .fill(DevPulseVisualStyle.surface)
        )
    }

    private func header(displayedEvents: [ActivityEvent]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("最近变化")
                    .font(.headline)
                Text("按扫描发现时间排列；开发变化与读取状态变化来自同一份活动记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !events.isEmpty {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("最近 \(displayedEvents.count) 条 · 共 \(events.count) 条")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if events.count > Self.initialDisplayedEventCount {
                        Button(showsAllEvents ? "收起" : "显示全部") {
                            withAnimation(.easeOut(duration: 0.16)) {
                                showsAllEvents.toggle()
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption2.weight(.medium))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func attentionNotice(displayedCount: Int, additionalCount: Int) -> some View {
        if displayedCount > 0 && additionalCount > 0 {
            Label(
                "列表中有 \(displayedCount) 条冲突或读取异常（另有 \(additionalCount) 条在较早记录中），建议优先确认",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
        } else if displayedCount > 0 {
            Label(
                "列表中有 \(displayedCount) 条冲突或读取异常，建议优先确认",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
        } else if additionalCount > 0 {
            Label(
                "较早记录中有 \(additionalCount) 条冲突或读取异常，展开后建议优先确认",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isScanning {
                Label("正在扫描最近变化", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))

                Text("本轮扫描完成后，新的提交、改动、分支或读取状态变化会出现在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    lastScanAt == nil ? "尚未建立活动基线" : "暂无增量变化",
                    systemImage: lastScanAt == nil ? "clock.badge.questionmark" : "checkmark.circle"
                )
                .font(.subheadline.weight(.semibold))

                Text(
                    lastScanAt == nil
                        ? "执行一次扫描建立仓库状态基线；后续只有提交、改动、分支、同步、冲突或读取状态变化才会生成记录。"
                        : "最近扫描没有发现新的变化。跨日记录会继续保留，直到达到本地容量上限。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("重新扫描", action: onRescan)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isScanning)
            }
        }
    }
}

struct ActivityEventRow: View {
    let event: ActivityEvent
    let decision: RepositoryDecision?

    init(event: ActivityEvent, decision: RepositoryDecision? = nil) {
        self.event = event
        self.decision = decision
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: event.kind.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(event.repositoryName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(event.kind.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tint)

                    Spacer(minLength: 8)

                    Text(timeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(absoluteTimeLabel)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.beforeSummary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(event.afterSummary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

                if let decision, decision.primaryAction.kind != .noActionNeeded {
                    Label("当前建议 · \(decision.primaryAction.title)", systemImage: "arrow.right.circle")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .help(decision.explanation)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var timeLabel: String {
        DateFormatting.relativeTimeChinese(from: event.occurredAt) ?? absoluteTimeLabel
    }

    private var absoluteTimeLabel: String {
        guard let date = DateFormatting.date(from: event.occurredAt) else {
            return event.occurredAt
        }
        return DateFormatting.displayString(from: date)
    }

    private var tint: Color {
        switch event.kind {
        case .conflictStarted, .readFailed:
            return .red
        case .newCommit, .branchChanged, .synchronizationChanged:
            return .blue
        case .conflictResolved, .readRecovered:
            return .green
        case .stagingChanged, .workingTreeChanged:
            return .orange
        }
    }
}

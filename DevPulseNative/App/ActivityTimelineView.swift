import SwiftUI

struct ActivityTimelineView: View {
    let events: [ActivityEvent]
    let repositories: [RepositorySnapshot]
    let lastScanAt: Date?
    let isScanning: Bool
    let onRescan: () -> Void

    private var decisionsByRepositoryID: [String: RepositoryDecision] {
        ActivityTimelineDecisionContextBuilder.build(from: repositories)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if events.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events.prefix(100))) { event in
                        ActivityEventRow(
                            event: event,
                            decision: decisionsByRepositoryID[event.repositoryID]
                        )

                        if event.id != events.prefix(100).last?.id {
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity Timeline")
                    .font(.headline)
                Text("只记录扫描发现的增量变化；相同状态不会重复记账。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !events.isEmpty {
                Text("保留 \(events.count) 条")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                lastScanAt == nil ? "尚未建立活动基线" : "暂无增量活动",
                systemImage: lastScanAt == nil ? "clock.badge.questionmark" : "checkmark.circle"
            )
            .font(.subheadline.weight(.semibold))

            Text(
                lastScanAt == nil
                    ? "执行一次扫描建立仓库状态基线；后续只有提交、改动、分支、同步、冲突或读取状态变化才会生成事件。"
                    : "最近扫描没有发现有意义变化。跨日记录会继续保留，直到达到本地容量上限。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Rescan Now", action: onRescan)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isScanning)
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

                if let decision {
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

import Foundation
import SwiftUI

struct TodayDevelopmentSummaryView: View {
    private enum TrendUnit: Equatable {
        case count
        case minutes
    }

    let events: [ActivityEvent]
    let lastScanAt: Date?
    let isScanning: Bool

    init(
        events: [ActivityEvent],
        lastScanAt: Date? = nil,
        isScanning: Bool = false
    ) {
        self.events = events
        self.lastScanAt = lastScanAt
        self.isScanning = isScanning
    }

    private var summary: DailyDevelopmentSummary {
        DailyDevelopmentSummaryBuilder.build(events: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metrics
            stateMessage
            mostActiveProject

            Text(comparisonDescription)
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                Text("今日开发摘要")
                    .font(.headline)
                Text("基于扫描发现的变化记录，不会触发额外扫描。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("近期趋势")
        }
    }

    private var metrics: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            alignment: .leading,
            spacing: 10
        ) {
            metric(
                title: "发现新提交",
                value: "\(summary.commitCount)",
                systemImage: "checkmark.circle",
                trend: summary.commitTrend,
                trendUnit: .count
            )
            metric(
                title: "活跃项目",
                value: "\(summary.activeProjectCount)",
                systemImage: "folder",
                trend: summary.activeProjectTrend,
                trendUnit: .count
            )
            metric(
                title: "专注时间（估算）",
                value: focusTimeLabel(summary.focusMinutes),
                systemImage: "timer",
                trend: summary.focusTimeTrend,
                trendUnit: .minutes
            )
            metric(
                title: "活动记录",
                value: "\(summary.activityCount)",
                systemImage: "waveform.path.ecg",
                trend: nil
            )
        }
    }

    @ViewBuilder
    private var stateMessage: some View {
        if summary.hasDataWarning {
            Label(
                "包含读取异常",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .help("今天有 \(summary.unavailableProjectCount) 个项目曾读取失败；摘要仅统计可读取的变化。")
        }

        if !summary.hasActivity {
            Label(
                emptyStateTitle,
                systemImage: emptyStateSymbol
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Text(emptyStateDetail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if isScanning {
            Label("正在扫描，摘要将在本轮完成后更新", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var hasSuccessfulScanToday: Bool {
        guard let lastScanAt else { return false }
        return Calendar.current.isDate(lastScanAt, inSameDayAs: Date())
    }

    private var emptyStateTitle: String {
        guard lastScanAt != nil else { return "等待首次成功扫描" }
        return hasSuccessfulScanToday ? "今天暂无开发变化" : "今天尚未完成成功扫描"
    }

    private var emptyStateSymbol: String {
        lastScanAt == nil || !hasSuccessfulScanToday
            ? "clock.badge.questionmark"
            : "checkmark.circle"
    }

    private var emptyStateDetail: String {
        guard lastScanAt != nil else {
            return "完成首次成功扫描后，这里会显示检测到的提交和项目变化。"
        }
        guard hasSuccessfulScanToday else {
            return "摘要等待今天的成功扫描；上次扫描不代表今天没有开发变化。"
        }
        return "摘要只记录扫描发现的变化；没有变化不代表扫描失败。"
    }

    @ViewBuilder
    private var mostActiveProject: some View {
        if let project = summary.mostActiveProject {
            HStack(spacing: 10) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.orange.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("最活跃项目")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(project.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(project.activityCount) 次活动")
                        .font(.subheadline.weight(.semibold))
                    Text(trendLabel(project.trend, unit: .count))
                        .font(.caption2)
                        .foregroundStyle(trendColor(project.trend))
                }
            }
            .padding(.vertical, 2)
        } else {
            Label("最活跃项目 · 暂无可展示项目", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(
        title: String,
        value: String,
        systemImage: String,
        trend: DailyDevelopmentSummary.Trend?,
        trendUnit: TrendUnit = .count
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let trend {
                Text(trendLabel(trend, unit: trendUnit))
                    .font(.caption2)
                    .foregroundStyle(trendColor(trend))
                    .lineLimit(1)
            } else {
                Text("扫描变化记录")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DevPulseVisualStyle.strongerSurface)
        )
    }

    private func focusTimeLabel(_ minutes: Int) -> String {
        guard minutes > 0 else { return "0 分钟" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 { return "\(remainingMinutes) 分钟" }
        if remainingMinutes == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(remainingMinutes) 分钟"
    }

    private func trendLabel(
        _ trend: DailyDevelopmentSummary.Trend,
        unit: TrendUnit
    ) -> String {
        switch trend.direction {
        case .increased:
            return "↑ 较近 7 天有活动日均 +\(formattedDelta(trend.delta, unit: unit))"
        case .decreased:
            return "↓ 较近 7 天有活动日均 \(formattedDelta(trend.delta, unit: unit))"
        case .unchanged:
            return "→ 与近 7 天有活动日均持平"
        case .unavailable:
            return "近期无可比较活动"
        }
    }

    private var comparisonDescription: String {
        let history = summary.comparisonActivityDayCount == 0
            ? "近 7 天暂无可比较活动"
            : "趋势按近 7 天内 \(summary.comparisonActivityDayCount) 个有活动日均比较"
        return "\(history)；专注时间按扫描发现的活动间隔估算。"
    }

    private func formattedDelta(_ delta: Double?, unit: TrendUnit) -> String {
        guard let delta else { return "—" }
        let value: String
        if abs(delta.rounded() - delta) < 0.01 {
            value = String(Int(delta.rounded()))
        } else {
            value = String(format: "%.1f", delta)
        }
        return unit == .minutes ? "\(value) 分钟" : value
    }

    private func trendColor(_ trend: DailyDevelopmentSummary.Trend) -> Color {
        switch trend.direction {
        case .increased:
            return .green
        case .decreased:
            return .orange
        case .unchanged, .unavailable:
            return .secondary
        }
    }
}

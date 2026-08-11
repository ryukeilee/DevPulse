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
    let now: Date

    init(
        events: [ActivityEvent],
        lastScanAt: Date? = nil,
        isScanning: Bool = false,
        now: Date = Date()
    ) {
        self.events = events
        self.lastScanAt = lastScanAt
        self.isScanning = isScanning
        self.now = now
    }

    private var summary: DailyDevelopmentSummary {
        DailyDevelopmentSummaryBuilder.build(events: events, now: now)
    }

    var body: some View {
        // 一次 body 求值只构建一次摘要派生；各子视图复用同一份结果，
        // 避免计算属性在 12+ 处被重复执行（每次都会重新遍历全部事件）。
        let summary = self.summary
        return VStack(alignment: .leading, spacing: 12) {
            header(summary: summary)
            metrics(summary: summary)
            trendContent(summary: summary)
            stateMessage(summary: summary)
            mostActiveProject(summary: summary)

            Text("专注时间按扫描发现的活动间隔估算；趋势只与近 7 天内有活动的日期比较。")
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

    private func header(summary: DailyDevelopmentSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("今日开发摘要")
                    .font(.headline)
                Text(headerDescription(summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("开发趋势")
        }
    }

    private func headerDescription(_ summary: DailyDevelopmentSummary) -> String {
        guard summary.activityCount > 0 else {
            return "仅统计扫描发现的开发变化，不会触发额外扫描。"
        }
        return "今天检测到 \(summary.activityCount) 条开发变化；读取异常不计入统计。"
    }

    private func metrics(summary: DailyDevelopmentSummary) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            alignment: .leading,
            spacing: 10
        ) {
            metric(
                title: "发现新提交",
                value: "\(summary.commitCount)",
                systemImage: "checkmark.circle",
                detail: "扫描变化"
            )
            metric(
                title: "活跃项目",
                value: "\(summary.activeProjectCount)",
                systemImage: "folder",
                detail: "有开发变化"
            )
            metric(
                title: "专注时间（估算）",
                value: focusTimeLabel(summary.focusMinutes),
                systemImage: "timer",
                detail: "活动间隔估算"
            )
        }
    }

    @ViewBuilder
    private func trendContent(summary: DailyDevelopmentSummary) -> some View {
        if summary.hasActivity || summary.comparisonActivityDayCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("开发趋势")
                        .font(.subheadline.weight(.semibold))
                    Text("今日相对近 7 天有活动日均")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    trendMetric(
                        title: "提交",
                        trend: summary.commitTrend,
                        unit: .count
                    )
                    trendMetric(
                        title: "项目",
                        trend: summary.activeProjectTrend,
                        unit: .count
                    )
                    trendMetric(
                        title: "专注",
                        trend: summary.focusTimeTrend,
                        unit: .minutes
                    )
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DevPulseVisualStyle.strongerSurface)
            )
        } else {
            Label(
                "暂无历史变化，趋势会在扫描记录积累后显示",
                systemImage: "chart.line.uptrend.xyaxis"
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func stateMessage(summary: DailyDevelopmentSummary) -> some View {
        if summary.hasDataWarning {
            Label(
                "当前有 \(summary.unavailableProjectCount) 个项目读取异常，统计可能不完整",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .help("读取失败的项目不会计入今日开发变化和趋势。")
        }

        if isScanning {
            Label("正在扫描，今日摘要将在本轮完成后更新", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if !summary.hasActivity {
            Label(
                emptyStateTitle(summary),
                systemImage: emptyStateSymbol(summary)
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Text(emptyStateDetail(summary))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasSuccessfulScanToday: Bool {
        guard let lastScanAt else { return false }
        return Calendar.current.isDate(lastScanAt, inSameDayAs: now)
    }

    private func emptyStateTitle(_ summary: DailyDevelopmentSummary) -> String {
        guard lastScanAt != nil else { return "等待首次成功扫描" }
        if summary.hasDataWarning { return "今天暂无可确认的开发变化" }
        return hasSuccessfulScanToday ? "今天暂无开发变化" : "今天尚未完成成功扫描"
    }

    private func emptyStateSymbol(_ summary: DailyDevelopmentSummary) -> String {
        if summary.hasDataWarning { return "exclamationmark.circle" }
        return lastScanAt == nil || !hasSuccessfulScanToday
            ? "clock.badge.questionmark"
            : "checkmark.circle"
    }

    private func emptyStateDetail(_ summary: DailyDevelopmentSummary) -> String {
        guard lastScanAt != nil else {
            return "完成首次成功扫描后，这里会显示检测到的提交和项目变化。"
        }
        if summary.hasDataWarning {
            return "部分项目读取失败，当前的“暂无变化”不能代表所有项目都没有变化。"
        }
        guard hasSuccessfulScanToday else {
            return "摘要等待今天的成功扫描；上次扫描不代表今天没有开发变化。"
        }
        return "摘要只记录扫描发现的变化；没有变化不代表扫描失败。"
    }

    @ViewBuilder
    private func mostActiveProject(summary: DailyDevelopmentSummary) -> some View {
        if let project = summary.mostActiveProject {
            HStack(spacing: 10) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.orange.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("今日最活跃项目")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(project.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(project.activityCount) 次变化")
                        .font(.subheadline.weight(.semibold))
                    Text(trendValueLabel(project.trend, unit: .count))
                        .font(.caption2)
                        .foregroundStyle(trendColor(project.trend))
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func metric(
        title: String,
        value: String,
        systemImage: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DevPulseVisualStyle.strongerSurface)
        )
    }

    private func trendMetric(
        title: String,
        trend: DailyDevelopmentSummary.Trend,
        unit: TrendUnit
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(trendValueLabel(trend, unit: unit))
                .font(.callout.weight(.semibold))
                .foregroundStyle(trendColor(trend))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(trendComparisonLabel(trend))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func focusTimeLabel(_ minutes: Int) -> String {
        guard minutes > 0 else { return "0 分钟" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 { return "\(remainingMinutes) 分钟" }
        if remainingMinutes == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(remainingMinutes) 分钟"
    }

    private func trendValueLabel(
        _ trend: DailyDevelopmentSummary.Trend,
        unit: TrendUnit
    ) -> String {
        switch trend.direction {
        case .increased:
            return "↑ +\(formattedDelta(trend.delta, unit: unit))"
        case .decreased:
            return "↓ \(formattedDelta(trend.delta, unit: unit))"
        case .unchanged:
            return "→ 持平"
        case .unavailable:
            return "— 暂无可比"
        }
    }

    private func trendComparisonLabel(_ trend: DailyDevelopmentSummary.Trend) -> String {
        guard trend.comparisonDayCount > 0 else { return "暂无历史活动" }
        return "较 \(trend.comparisonDayCount) 个有活动日"
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

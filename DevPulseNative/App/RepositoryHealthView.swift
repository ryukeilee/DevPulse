import SwiftUI

// MARK: - Health signal row

struct HealthSignalRow: View {
    let signal: RepositoryHealthSignal

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: signal.systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(signal.title)
                        .font(.callout.weight(.semibold))
                    riskBadge
                }

                Text(signal.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("证据：\(signal.evidence)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 12) {
                        Label(signal.currentValue, systemImage: "tag")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if let threshold = signal.threshold {
                            Label("阈值：\(threshold)", systemImage: "line.diagonal")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DevPulseVisualStyle.surface)
        )
    }

    private var riskBadge: some View {
        Text(riskLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private var riskLabel: String {
        switch signal.level {
        case .high: return "高风险"
        case .medium: return "中风险"
        case .low: return "低风险"
        }
    }

    private var tint: Color {
        switch signal.level {
        case .high: return .red
        case .medium: return .orange
        case .low: return .secondary
        }
    }
}

// MARK: - Health assessment summary card

struct HealthAssessmentCard: View {
    let assessment: RepositoryHealthAssessment
    let onRefresh: (() -> Void)?

    init(assessment: RepositoryHealthAssessment,
         onRefresh: (() -> Void)? = nil) {
        self.assessment = assessment
        self.onRefresh = onRefresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: overallIcon)
                    .font(.title2)
                    .foregroundStyle(overallTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("健康趋势")
                        .font(.headline)
                    Text(assessment.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if !assessment.hasSufficientHistory {
                    Text("数据不足")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                } else {
                    riskLevelBadge
                }

                if let onRefresh {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("重新评估健康趋势")
                }
            }

            if !assessment.hasSufficientHistory {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(assessment.primaryExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(DevPulseVisualStyle.strongerSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if assessment.signals.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                    Text("近期无风险预警")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                // Signal list
                VStack(spacing: 6) {
                    ForEach(assessment.signals) { signal in
                        HealthSignalRow(signal: signal)
                    }
                }

                // Primary explanation
                Text(assessment.primaryExplanation)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(overallTint)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(overallTint.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DevPulseVisualStyle.surface)
        )
    }

    private var overallIcon: String {
        switch assessment.overallRisk {
        case .high: return "exclamationmark.triangle.fill"
        case .medium: return "exclamationmark.circle"
        case .low: return "checkmark.circle"
        }
    }

    private var overallTint: Color {
        switch assessment.overallRisk {
        case .high: return .red
        case .medium: return .orange
        case .low: return .green
        }
    }

    private var riskLevelBadge: some View {
        Text(riskLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(overallTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(overallTint.opacity(0.12))
            .clipShape(Capsule())
    }

    private var riskLabel: String {
        switch assessment.overallRisk {
        case .high: return "高风险"
        case .medium: return "需关注"
        case .low: return "正常"
        }
    }
}

// MARK: - Trend mini indicator for list rows

struct TrendMiniIndicator: View {
    let risk: RiskLevel
    let signalCount: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            if signalCount > 1 {
                Text("\(signalCount)")
                    .font(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.1))
        .clipShape(Capsule())
        .help(helpText)
    }

    private var icon: String {
        switch risk {
        case .high: return "exclamationmark.triangle.fill"
        case .medium: return "exclamationmark.circle"
        case .low: return "checkmark.circle"
        }
    }

    private var tint: Color {
        switch risk {
        case .high: return .red
        case .medium: return .orange
        case .low: return .green
        }
    }

    private var helpText: String {
        switch risk {
        case .high: return "\(signalCount) 个风险信号"
        case .medium: return "需关注"
        case .low: return "趋势正常"
        }
    }
}

// MARK: - Health rating bar

struct HealthRatingBar: View {
    let overallRisk: RiskLevel
    let signalCount: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(fillColor(for: index))
                    .frame(width: 6, height: 12)
            }

            if signalCount > 0 {
                Text("\(signalCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("健康趋势：\(riskLabel)")
        .help("\(riskLabel) · \(signalCount) 个信号")
    }

    private func fillColor(for index: Int) -> Color {
        let activeLevel: Int
        switch overallRisk {
        case .low: activeLevel = 0
        case .medium: activeLevel = 1
        case .high: activeLevel = 2
        }
        let isFilled = index <= activeLevel
        return isFilled ? barTint(for: index) : Color.gray.opacity(0.15)
    }

    private func barTint(for index: Int) -> Color {
        switch index {
        case 0: return .green
        case 1: return .orange
        case 2: return .red
        default: return .gray
        }
    }

    private var riskLabel: String {
        switch overallRisk {
        case .low: return "正常"
        case .medium: return "需关注"
        case .high: return "高风险"
        }
    }
}

// MARK: - Trend sheet view (for detail window)

struct RepositoryTrendSheet: View {
    let repositoryID: String
    let repositoryName: String
    let historyStore: RepositoryHistoryStore
    @State private var assessment: RepositoryHealthAssessment?
    @State private var isLoading = true
    @State private var historyCount = 0
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("健康趋势")
                    .font(.title3.weight(.semibold))
                Spacer()
                if historyCount > 0 {
                    Text("\(historyCount) 条记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !isLoading {
                    Button("刷新") {
                        loadAssessment()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在评估趋势…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if let assessment {
                HealthAssessmentCard(assessment: assessment) {
                    loadAssessment()
                }
            }
        }
        .padding(16)
        .frame(width: 420, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: loadAssessment)
    }

    private func loadAssessment() {
        isLoading = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) {
            let loadResult = historyStore.load(for: repositoryID)
            switch loadResult {
            case .success(let entries):
                let assessedAt = DateFormatting.nowISO()
                let assessment = RepositoryHealthEngine.assess(
                    repositoryID: repositoryID,
                    repositoryName: repositoryName,
                    entries: entries,
                    assessedAt: assessedAt
                )
                await MainActor.run {
                    self.assessment = assessment
                    self.historyCount = entries.count
                    self.isLoading = false
                }
            case .failure(let error):
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

import SwiftUI

struct ScanStatusView: View {
    @EnvironmentObject var scheduler: ScanScheduler

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Summary stats
                HStack(spacing: 24) {
                    StatBadge(
                        label: "仓库",
                        value: "\(scheduler.lastResult.scanSummary.totalRepositories)",
                        systemImage: "folder"
                    )
                    StatBadge(
                        label: "有改动",
                        value: "\(scheduler.lastResult.scanSummary.changedRepositories)",
                        systemImage: "doc.badge.ellipsis"
                    )
                    StatBadge(
                        label: "文件",
                        value: "\(scheduler.lastResult.scanSummary.totalChangedFiles)",
                        systemImage: "text.document"
                    )
                    if scheduler.lastResult.scanSummary.errorRepositories > 0 {
                        StatBadge(
                            label: "异常",
                            value: "\(scheduler.lastResult.scanSummary.errorRepositories)",
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                }

                Spacer()

                // Right side: last scan time + rescan button
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 12) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(scheduler.refreshStatusText)
                                .font(.caption)
                                .foregroundColor(statusTint)

                            if let detail = scheduler.refreshDetailText {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button(action: { scheduler.rescan() }) {
                            HStack(spacing: 4) {
                                if scheduler.isScanning {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text(scheduler.isScanning ? "Scanning..." : "Rescan Now")
                            }
                        }
                        .disabled(scheduler.isScanning)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityLabel("重新扫描全部仓库")
                        .accessibilityHint(
                            scheduler.refreshPhase == .failure
                                ? "重新尝试读取全部仓库状态"
                                : "重新发现并读取全部仓库"
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if scheduler.isScanning, let progress = scheduler.currentProgress {
                RefreshStageProgressBar(progress: progress)
                    .animation(.easeOut(duration: 0.2), value: scheduler.currentProgress)
            }
        }
    }

    private var statusTint: Color {
        let freshness = DataFreshnessBuilder.build(
            refreshPhase: scheduler.refreshPhase,
            trustAssessment: scheduler.refreshTrustAssessment,
            persistenceState: scheduler.lastResult.persistenceState,
            repositories: scheduler.lastResult.repositories,
            isRefreshing: scheduler.isScanning
        )
        switch freshness {
        case .normal:
            return .secondary
        case .refreshing:
            return .secondary
        case .stale:
            return .orange
        case .degraded:
            return .orange
        case .failed:
            return .red
        }
    }
}

// MARK: - Stat badge

// MARK: - Stage progress bar

struct RefreshStageProgressBar: View {
    let progress: RefreshProgress

    var body: some View {
        HStack(spacing: 12) {
            if let currentStage = progress.currentStage,
               let stageProgress = progress.phases[currentStage] {
                ProgressView(value: stageProgress.fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 120)
                    .scaleEffect(x: 1, y: 0.5, anchor: .center)

                Text(currentStage.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("\(stageProgress.completedItems)/\(stageProgress.totalItems)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Stat badge

struct StatBadge: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.headline)
                    .fontWeight(.semibold)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

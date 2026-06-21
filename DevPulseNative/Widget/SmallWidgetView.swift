import SwiftUI
import WidgetKit

/// Small widget: summary view showing total counts.
struct SmallWidgetView: View {
    let entry: DevPulseWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                Text("DevPulse")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
            }
            .foregroundColor(.secondary)

            Spacer(minLength: 0)

            // Content
            if entry.isPlaceholder {
                placeholderContent
            } else if let error = entry.errorMessage {
                errorContent(error)
            } else if let summary = entry.scanSummary {
                summaryContent(summary)
            } else {
                Text("—")
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

            // Footer: last updated
            if let generatedAt = entry.generatedAt {
                Text("更新于 \(DateFormatting.relativeTime(from: generatedAt, relativeTo: entry.date))")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - Placeholder

    private var placeholderContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("3 个仓库有改动")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("12 处改动")
                .font(.body)
                .fontWeight(.bold)
                .redacted(reason: .placeholder)
        }
    }

    // MARK: - Error / No data

    private func errorContent(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
    }

    // MARK: - Summary

    private func summaryContent(_ summary: ScanSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if summary.changedRepositories > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(summary.changedRepositories)")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("仓库\n有改动")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text("\(summary.totalChangedFiles) 处改动")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if summary.totalRepositories > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(summary.totalRepositories)")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("仓库")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Text("全部干净")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }
}

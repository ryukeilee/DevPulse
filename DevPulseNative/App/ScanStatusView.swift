import SwiftUI

struct ScanStatusView: View {
    @EnvironmentObject var scheduler: ScanScheduler

    var body: some View {
        HStack(spacing: 16) {
            // Summary stats
            HStack(spacing: 24) {
                StatBadge(
                    label: "Repos",
                    value: "\(scheduler.lastResult.scanSummary.totalRepositories)",
                    systemImage: "folder"
                )
                StatBadge(
                    label: "Changed",
                    value: "\(scheduler.lastResult.scanSummary.changedRepositories)",
                    systemImage: "doc.badge.ellipsis"
                )
                StatBadge(
                    label: "Files",
                    value: "\(scheduler.lastResult.scanSummary.totalChangedFiles)",
                    systemImage: "text.document"
                )
                if scheduler.lastResult.scanSummary.errorRepositories > 0 {
                    StatBadge(
                        label: "Errors",
                        value: "\(scheduler.lastResult.scanSummary.errorRepositories)",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }

            Spacer()

            // Right side: last scan time + rescan button
            HStack(spacing: 12) {
                if let lastScan = scheduler.lastScanAt {
                    Text("Updated \(relativeTime(from: lastScan))")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "<1m ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
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

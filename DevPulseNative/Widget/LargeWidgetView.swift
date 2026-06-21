import SwiftUI
import WidgetKit

/// Large widget: shows up to 6 repository rows with risk and top changed file.
struct LargeWidgetView: View {
    let entry: DevPulseWidgetEntry

    private let maxRepos = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            headerView

            // Content
            if entry.isPlaceholder {
                placeholderRows
            } else if let error = entry.errorMessage {
                errorContent(error)
            } else if entry.repositories.isEmpty {
                emptyContent
            } else {
                repoRows
            }

            Spacer(minLength: 0)

            // Footer
            footerView
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .semibold))
            Text("DevPulse")
                .font(.caption)
                .fontWeight(.semibold)

            Spacer()

            if let summary = entry.scanSummary {
                HStack(spacing: 8) {
                    Text("\(summary.totalRepositories) 个仓库")
                        .font(.system(size: 9))
                    if summary.changedRepositories > 0 {
                        Text("\(summary.changedRepositories) 个有改动")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                    Text("\(summary.totalChangedFiles) 处改动")
                        .font(.system(size: 9))
                }
                .foregroundColor(.secondary)
            }
        }
        .foregroundColor(.secondary)
    }

    // MARK: - Error / Empty

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

    private var emptyContent: some View {
        Text("没有找到 Git 仓库。\n打开 DevPulse 后扫描你的开发目录。")
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Rows

    private var repoRows: some View {
        VStack(spacing: 3) {
            ForEach(entry.repositories.prefix(maxRepos), id: \.id) { repo in
                LargeRepoRow(repo: repo)
                if repo.id != entry.repositories.prefix(maxRepos).last?.id {
                    Divider().opacity(0.3)
                }
            }
        }
    }

    private var placeholderRows: some View {
        VStack(spacing: 3) {
            ForEach(0..<6) { _ in
                LargeRepoRow(repo: nil)
                    .redacted(reason: .placeholder)
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Spacer()
            if let generatedAt = entry.generatedAt {
                Text("更新于 \(DateFormatting.relativeTime(from: generatedAt, relativeTo: entry.date))")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Large row

struct LargeRepoRow: View {
    let repo: WidgetRepositoryEntry?

    var body: some View {
        HStack(spacing: 8) {
            if let repo {
                // Status dot
                Circle()
                    .fill(repo.status == .changed ? Color.orange :
                            repo.status == .error ? Color.red : Color.green)
                    .frame(width: 6, height: 6)

                // Repo name
                Text(repo.name)
                    .font(.system(size: 11))
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                // Changed file count or status
                if repo.changedFileCount > 0 {
                    Text("\(repo.changedFileCount) 处改动")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                } else {
                    Text("干净")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                }

                // Branch
                Text(repo.branch)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 48, alignment: .trailing)

                // Risk badge
                RiskWidgetBadge(level: repo.risk)

                // Top changed file (optional)
                if let topFile = repo.topChangedFile {
                    Text(topFile)
                        .font(.system(size: 7))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 64, alignment: .leading)
                }
            } else {
                // Placeholder skeleton
                Circle().fill(.secondary).frame(width: 6, height: 6)
                Text("项目").font(.system(size: 11))
                Spacer()
                Text("5 处改动").font(.system(size: 9))
                Text("main").font(.system(size: 8))
            }
        }
    }
}

// MARK: - Risk widget badge

struct RiskWidgetBadge: View {
    let level: RiskLevel

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help("风险：\(level.rawValue)")
    }

    private var color: Color {
        switch level {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}

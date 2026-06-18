import SwiftUI
import WidgetKit

/// Medium widget: shows up to 3 repository rows.
struct MediumWidgetView: View {
    let entry: DevPulseWidgetEntry

    private let maxRepos = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            headerView

            Spacer(minLength: 0)

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
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .semibold))
            Text("DevPulse")
                .font(.caption2)
                .fontWeight(.semibold)
            Spacer()
            if let summary = entry.scanSummary, summary.changedRepositories > 0 {
                Text("\(summary.changedRepositories) changed")
                    .font(.system(size: 8))
                    .foregroundColor(.orange)
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
        Text("No repositories found")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    // MARK: - Rows

    private var repoRows: some View {
        VStack(spacing: 4) {
            ForEach(entry.repositories.prefix(maxRepos), id: \.id) { repo in
                MediumRepoRow(repo: repo)
            }
        }
    }

    private var placeholderRows: some View {
        VStack(spacing: 4) {
            ForEach(0..<3) { _ in
                MediumRepoRow(repo: nil)
                    .redacted(reason: .placeholder)
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Spacer()
            if let generatedAt = entry.generatedAt {
                Text("Updated \(DateFormatting.relativeTime(from: generatedAt, relativeTo: entry.date))")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Medium row

struct MediumRepoRow: View {
    let repo: WidgetRepositoryEntry?

    var body: some View {
        HStack(spacing: 6) {
            if let repo {
                // Status dot
                Circle()
                    .fill(repo.status == .changed ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)

                Text(repo.name)
                    .font(.system(size: 11))
                    .fontWeight(.medium)
                    .lineLimit(1)

                if repo.changedFileCount > 0 {
                    Text("\(repo.changedFileCount) files")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                } else {
                    Text("clean")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                }

                Spacer()

                // Branch
                Text(repo.branch)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.12))
                    )
            } else {
                // Placeholder skeleton
                Circle().fill(.secondary).frame(width: 6, height: 6)
                Text("Repo Name").font(.system(size: 11))
                Text("4 files").font(.system(size: 9))
                Spacer()
                Text("main").font(.system(size: 8))
            }
        }
    }
}

import SwiftUI

struct RepositoryListView: View {
    @EnvironmentObject var scheduler: ScanScheduler

    var body: some View {
        VStack(spacing: 0) {
            if scheduler.lastResult.repositories.isEmpty {
                emptyView
            } else {
                List {
                    ForEach(scheduler.lastResult.repositories) { repo in
                        RepositoryRow(repo: repo)
                            .contextMenu {
                                Button(repo.isPinned ? "Unpin" : "Pin") {
                                    scheduler.togglePin(repoID: repo.id)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No repositories found in configured scan roots")
                .font(.body)
                .foregroundColor(.secondary)
            Text("Press Rescan Now in the Overview tab to start scanning.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Repository row

struct RepositoryRow: View {
    let repo: RepositorySnapshot

    var body: some View {
        HStack(spacing: 12) {
            // Pin indicator
            if repo.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }

            // Status icon
            statusIcon
                .frame(width: 20)

            // Repo info
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.body)
                    .fontWeight(.medium)
                HStack(spacing: 6) {
                    branchLabel
                    if repo.changedFileCount > 0 {
                        Text("modified \(repo.modifiedFileCount) · added \(repo.addedFileCount) · deleted \(repo.deletedFileCount) · untracked \(repo.untrackedFileCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Risk badge
            if repo.status != .error {
                RiskBadge(level: repo.risk)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch repo.status {
        case .changed:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundColor(.orange)
        case .clean:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var branchLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
            Text(repo.branch)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.1))
        )
    }
}

// MARK: - Risk badge

struct RiskBadge: View {
    let level: RiskLevel

    var body: some View {
        Text(level.rawValue.capitalized)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
            )
            .foregroundColor(textColor)
    }

    private var backgroundColor: Color {
        switch level {
        case .low: return .green.opacity(0.15)
        case .medium: return .orange.opacity(0.15)
        case .high: return .red.opacity(0.15)
        }
    }

    private var textColor: Color {
        switch level {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}

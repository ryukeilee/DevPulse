import SwiftUI

struct PendingItemDetailView: View {
    let item: PendingItem
    @EnvironmentObject var scheduler: ScanScheduler
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider().overlay(DevPulseVisualStyle.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    severitySection
                    overviewSection
                    evidenceSection
                    statusSection
                    actionsSection
                }
                .padding(20)
            }
            Divider().overlay(DevPulseVisualStyle.separator)
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 460, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var detailHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: item.source.systemImage).font(.title3).foregroundStyle(severityColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.title3.weight(.semibold))
                Text(item.source.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            severityBadge
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var severitySection: some View {
        card(title: "Severity") {
            HStack(spacing: 8) {
                Image(systemName: item.severity.systemImage).foregroundStyle(severityColor)
                Text(item.severity.displayName).font(.headline)
                if item.duration > 0 {
                    Text("duration " + formatDuration(item.duration)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var overviewSection: some View {
        card(title: "Description") {
            Text(item.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let repoName = item.repositoryName {
                Label(repoName, systemImage: "shippingbox").font(.caption).foregroundStyle(.tertiary)
            }
            if let wsName = item.workspaceName {
                Label(wsName, systemImage: "rectangle.3.group").font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.caption2)
                Text("First: " + relativeTime(item.firstDetectedAt)).font(.caption)
                Text("Last: " + relativeTime(item.lastConfirmedAt)).font(.caption)
            }.foregroundStyle(.tertiary)
        }
    }

    private var evidenceSection: some View {
        card(title: "Evidence") {
            if item.evidence.isEmpty {
                Text("No evidence available").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(item.evidence, id: \.self) { ev in
                    Label(ev, systemImage: "doc.text").font(.caption).lineLimit(3)
                }
            }
        }
    }

    private var statusSection: some View {
        card(title: "Status") {
            HStack(spacing: 8) {
                Image(systemName: statusIcon).foregroundStyle(statusColor)
                Text(item.status.displayName).font(.headline)
                if let transition = item.lastTransition {
                    Text(transition.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionsSection: some View {
        card(title: "Actions") {
            HStack(spacing: 8) {
                if item.status == .active || item.status == .restored {
                    Button("Acknowledge") { scheduler.applyUserAction(to: item.id, action: .acknowledge); dismiss() }.buttonStyle(.bordered)
                }
                if item.status != .permanentlyIgnored {
                    Button("Ignore", role: .destructive) { scheduler.applyUserAction(to: item.id, action: .permanentlyIgnore); dismiss() }.buttonStyle(.bordered)
                }
                if item.status == .snoozed || item.status == .acknowledged || item.status == .muted {
                    Button("Restore") { scheduler.applyUserAction(to: item.id, action: .unmute); dismiss() }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var severityColor: Color {
        switch item.severity {
        case .tip: return .secondary
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        case .critical: return Color(red: 0.5, green: 0.0, blue: 0.0)
        }
    }

    private var severityBadge: some View {
        Text(item.severity.displayName)
            .font(.caption.weight(.medium))
            .foregroundStyle(severityColor)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(severityColor.opacity(0.11)))
    }

    private var statusIcon: String {
        switch item.status {
        case .active: return "questionmark.circle.fill"
        case .acknowledged: return "hand.raised.fill"
        case .snoozed: return "bell.slash.fill"
        case .muted: return "speaker.slash.fill"
        case .restored: return "bell.badge.fill"
        case .resolved: return "checkmark.circle.fill"
        case .permanentlyIgnored: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .active: return .orange
        case .acknowledged: return .secondary
        case .snoozed: return .blue
        case .muted: return .secondary
        case .restored: return .orange
        case .resolved: return .green
        case .permanentlyIgnored: return .gray
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DevPulseVisualStyle.surface))
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let s = Int(interval); let d = s / 86400; let h = (s % 86400) / 3600
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \((s % 3600) / 60)m" }
        return "\((s % 3600) / 60)m"
    }

    private func relativeTime(_ ts: String) -> String {
        guard let date = DateFormatting.date(from: ts) else { return "unknown" }
        let i = -date.timeIntervalSinceNow
        if i < 60 { return "now" }
        if i < 3600 { return "\(Int(i/60))m" }
        if i < 86400 { return "\(Int(i/3600))h" }
        return "\(Int(i/86400))d"
    }
}

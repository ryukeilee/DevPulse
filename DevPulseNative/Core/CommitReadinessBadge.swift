import SwiftUI

struct CommitReadinessBadge: View {
    let level: CommitReadinessLevel
    var compact: Bool = false

    var body: some View {
        Text(level.shortLabel)
            .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, compact ? 8 : 10)
            .frame(height: compact ? 20 : 22)
            .background(
                Capsule().fill(backgroundColor.opacity(backgroundOpacity))
            )
            .foregroundStyle(backgroundColor)
    }

    private var backgroundColor: Color {
        switch level {
        case .clean:
            return .secondary
        case .inProgress:
            return .orange
        case .commitReady:
            return .blue
        case .needsReview:
            return .orange
        case .pushSuggested:
            return .green
        case .attention:
            return .red
        }
    }

    private var backgroundOpacity: Double {
        switch level {
        case .attention:
            return 0.16
        case .clean:
            return 0.08
        default:
            return 0.12
        }
    }
}

struct RiskBadge: View {
    let level: RiskLevel

    var body: some View {
        Text(level.rawValue.capitalized)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                Capsule().fill(tint.opacity(0.1))
            )
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch level {
        case .low:
            return .secondary
        case .medium:
            return .orange
        case .high:
            return .red
        }
    }
}

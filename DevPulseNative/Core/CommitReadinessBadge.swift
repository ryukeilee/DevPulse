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
        case .idle:
            return .secondary
        case .review:
            return .orange
        case .ready:
            return .green
        case .dirty:
            return .red
        case .unknown:
            return .red
        }
    }

    private var backgroundOpacity: Double {
        switch level {
        case .unknown:
            return 0.16
        case .dirty:
            return 0.14
        case .idle:
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

import SwiftUI

struct CommitReadinessBadge: View {
    let level: CommitReadinessLevel
    var compact: Bool = false

    var body: some View {
        Text(level.shortLabel)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                Capsule().fill(backgroundColor.opacity(0.12))
            )
            .foregroundStyle(backgroundColor)
    }

    private var backgroundColor: Color {
        switch level {
        case .clean:
            return .green
        case .ready:
            return .blue
        case .review:
            return .orange
        case .notReady:
            return .red
        }
    }
}

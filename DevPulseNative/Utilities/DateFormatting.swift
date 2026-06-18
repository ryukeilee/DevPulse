import Foundation

enum DateFormatting {
    /// Format a relative time string like "2m ago", "1h ago", etc.
    static func relativeTime(from iso8601String: String, relativeTo now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso8601String)
                ?? ISO8601DateFormatter().date(from: iso8601String) else {
            return "unknown"
        }

        let interval = now.timeIntervalSince(date)
        if interval < 60 {
            return "<1m ago"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h ago"
        } else {
            return "\(Int(interval / 86400))d ago"
        }
    }

    /// Current time as ISO-8601 string.
    static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// Parse an ISO-8601 string into a Date when possible.
    static func date(from iso8601String: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso8601String)
            ?? ISO8601DateFormatter().date(from: iso8601String)
    }
}

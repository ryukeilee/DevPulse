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

    /// Concise Chinese relative time for action-oriented repository surfaces.
    /// Invalid or implausibly future timestamps return nil so callers can show
    /// an explicit unavailable-state fallback instead of a misleading value.
    static func relativeTimeChinese(from iso8601String: String,
                                    relativeTo now: Date = Date()) -> String? {
        guard let date = date(from: iso8601String) else { return nil }

        let interval = now.timeIntervalSince(date)
        guard interval >= -60 else { return nil }

        if interval < 60 {
            return "刚刚"
        } else if interval < 3_600 {
            return "\(Int(interval / 60)) 分钟前"
        } else if interval < 86_400 {
            return "\(Int(interval / 3_600)) 小时前"
        } else {
            return "\(Int(interval / 86_400)) 天前"
        }
    }

    /// Current time as ISO-8601 string.
    static func nowISO() -> String {
        isoString(from: Date())
    }

    static func isoString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Parse an ISO-8601 string into a Date when possible.
    static func date(from iso8601String: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso8601String)
            ?? ISO8601DateFormatter().date(from: iso8601String)
    }

    static func displayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

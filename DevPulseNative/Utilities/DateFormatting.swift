import Foundation

enum DateFormatting {
    /// A parser for one synchronous operation.
    ///
    /// Kept as the batch-reuse entry point for callers that parse many
    /// timestamps in one pass (repository history, snapshot validation, list
    /// ordering). Canonical timestamps are parsed arithmetically, so sharing a
    /// parser and building one per call observe identical behavior and
    /// identical cost.
    struct TimestampParser {
        func date(from iso8601String: String) -> Date? {
            DateFormatting.date(from: iso8601String)
        }
    }

    /// Format a relative time string like "2m ago", "1h ago", etc.
    static func relativeTime(from iso8601String: String, relativeTo now: Date = Date()) -> String {
        guard let date = date(from: iso8601String) else { return "unknown" }

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
        SharedFormatters.shared.isoString(from: date)
    }

    /// Parse an ISO-8601 string into a Date when possible.
    ///
    /// Canonical timestamps — the shapes this app writes and reads — are parsed
    /// by `canonicalDate` without touching a formatter. Everything else keeps
    /// the previous `fractional ?? standard` formatter lookup, so accepted
    /// formats and rejected inputs are unchanged.
    static func date(from iso8601String: String) -> Date? {
        if let date = canonicalDate(iso8601String) { return date }
        return SharedFormatters.shared.date(from: iso8601String)
    }

    static func displayString(from date: Date) -> String {
        SharedFormatters.shared.displayString(from: date)
    }

    // MARK: - Canonical ISO-8601 fast path

    private static let dash: UInt8 = 0x2D          // -
    private static let colon: UInt8 = 0x3A         // :
    private static let upperT: UInt8 = 0x54        // T
    private static let upperZ: UInt8 = 0x5A        // Z
    private static let plus: UInt8 = 0x2B          // +

    /// Parses the canonical shapes this app writes and reads —
    /// `YYYY-MM-DDTHH:MM:SSZ` and `YYYY-MM-DDTHH:MM:SS±HH:MM`.
    ///
    /// Returns `nil` for every other string. That includes the shapes where
    /// `ISO8601DateFormatter` and `Date.ISO8601FormatStyle` disagree, so those
    /// keep taking the formatter path and keep their current result: clock
    /// fields at or past their maximum (`hh >= 24`, `mm >= 60`, `ss >= 60`),
    /// UTC offsets outside `±14:00` or with `mm > 59`, and calendar days that
    /// only exist after normalization such as `2025-02-29`.
    ///
    /// Restricting the fast path to valid calendar dates is what makes the
    /// arithmetic below exact: no normalization is involved, and integral
    /// epoch seconds convert to the same `Date` the formatter returns.
    private static func canonicalDate(_ string: String) -> Date? {
        string.utf8.withContiguousStorageIfAvailable { buffer in
            parseCanonical(buffer)
        } ?? nil
    }

    private static func parseCanonical(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        let count = bytes.count
        guard count == 20 || count == 25 else { return nil }
        guard bytes[4] == dash, bytes[7] == dash, bytes[10] == upperT,
              bytes[13] == colon, bytes[16] == colon else { return nil }

        guard let year = digits(bytes, 0, digits: 4),
              let month = digits(bytes, 5),
              let day = digits(bytes, 8),
              let hour = digits(bytes, 11),
              let minute = digits(bytes, 14),
              let second = digits(bytes, 17) else { return nil }

        guard hour < 24, minute < 60, second < 60,
              month >= 1, month <= 12,
              day >= 1, day <= daysInMonth(month, year: year) else { return nil }

        // `ISO8601DateFormatter` follows the hybrid Julian/Gregorian calendar:
        // it reads dates before the 1582-10-15 cutover as Julian, where the
        // proleptic-Gregorian arithmetic below disagrees with it by the number
        // of days the two calendars had drifted apart (up to 10). Those dates
        // take the formatter path so their current value is preserved.
        guard (year, month, day) >= (1582, 10, 15) else { return nil }

        var offset = 0
        if count == 20 {
            guard bytes[19] == upperZ else { return nil }
        } else {
            guard bytes[22] == colon,
                  let offsetHour = digits(bytes, 20),
                  let offsetMinute = digits(bytes, 23),
                  offsetHour <= 14, offsetMinute <= 59 else { return nil }
            let magnitude = offsetHour * 3_600 + offsetMinute * 60
            switch bytes[19] {
            case plus: offset = magnitude
            case dash: offset = -magnitude
            default: return nil
            }
        }

        let days = daysSinceEpoch(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds))
    }

    /// ASCII digits starting at `offset`, or nil when any is not a digit.
    @inline(__always)
    private static func digits(_ bytes: UnsafeBufferPointer<UInt8>,
                               _ offset: Int,
                               digits count: Int = 2) -> Int? {
        var value = 0
        for index in offset..<(offset + count) {
            let digit = Int(bytes[index]) &- 48
            guard digit >= 0, digit <= 9 else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    @inline(__always)
    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let isLeapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            return isLeapYear ? 29 : 28
        }
    }

    /// Days from 1970-01-01 for a validated proleptic-Gregorian date
    /// (Howard Hinnant's `days_from_civil`).
    @inline(__always)
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

/// Shared, lazily built formatters.
///
/// `ISO8601DateFormatter` and `DateFormatter` are mutable classes and are not
/// `Sendable`, so the instances live behind a lock instead of a bare `static
/// let`. Building one and configuring it measured ~190us in an optimized build,
/// against the ~57us parse or ~1.2us format that follows, which is why the
/// derived-model and list-row paths were dominated by construction. The lock
/// costs ~20ns against that, so the instances are shared rather than rebuilt.
private final class SharedFormatters: @unchecked Sendable {
    static let shared = SharedFormatters()

    private let lock = NSLock()
    private let iso8601 = ISO8601DateFormatter()
    private let fractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let display: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    func isoString(from date: Date) -> String {
        lock.withLock { iso8601.string(from: date) }
    }

    func date(from string: String) -> Date? {
        lock.withLock {
            fractionalSeconds.date(from: string) ?? iso8601.date(from: string)
        }
    }

    func displayString(from date: Date) -> String {
        lock.withLock {
            // `TimeZone.current` is user-settable, so refresh it rather than
            // pinning whatever zone was current when the formatter was built.
            // Re-assigning an unchanged zone measured ~0.23us.
            display.timeZone = TimeZone.current
            return display.string(from: date)
        }
    }
}

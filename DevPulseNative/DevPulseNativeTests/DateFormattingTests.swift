import Foundation
import Testing
@testable import DevPulse

/// `DateFormatting` 的时间戳解析走一条不建 formatter 的快速路径，其余输入仍交给
/// 与改动前完全相同的 `ISO8601DateFormatter` 组合。这些测试锁定两者之间的边界：
/// 凡是快速路径接受的输入都必须与 formatter 组合给出逐位相同的 `Date`，凡是两者
/// 存在分歧的形状都必须继续走 formatter。
struct DateFormattingTests {

    /// 改动前的实现，用作行为基准。
    private static func referenceDate(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func referenceISOString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func epoch(_ date: Date?) -> String {
        guard let date else { return "nil" }
        // 逐位比较：解析结果必须是同一个 Date，而不是"相差极小"的 Date。
        return String(format: "%.9f", date.timeIntervalSince1970)
    }

    private static func expectMatchesReference(_ string: String,
                                               sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(epoch(DateFormatting.date(from: string)) == epoch(referenceDate(from: string)),
                "\(string) 的解析结果与 formatter 基准不一致",
                sourceLocation: sourceLocation)
    }

    // MARK: - 基准等价的规范形状

    @Test func canonicalTimestampsMatchTheFormatterBaseline() {
        var inputs: [String] = []
        for year in ["1582", "1583", "1900", "1970", "2024", "2026", "9999"] {
            for month in ["01", "02", "04", "06", "12"] {
                for day in ["01", "15", "28", "29", "30", "31"] {
                    for time in ["00:00:00", "12:34:56", "23:59:59"] {
                        for offset in ["Z", "+00:00", "-00:00", "+14:00", "-14:00",
                                       "+05:30", "-08:00", "+13:45"] {
                            inputs.append("\(year)-\(month)-\(day)T\(time)\(offset)")
                        }
                    }
                }
            }
        }
        // 1582-10-15 是快速路径允许的最早日期，单独覆盖它和它的前一天。
        inputs.append(contentsOf: [
            "1582-10-15T00:00:00Z",
            "1582-10-14T00:00:00Z",
            "1582-10-04T00:00:00Z",
            "1582-12-31T23:59:59+14:00",
        ])

        for input in inputs {
            Self.expectMatchesReference(input)
        }
    }

    /// 快速路径必须真的命中：规范时间戳不应依赖 `ISO8601DateFormatter`。
    /// 通过一次解析的规模证明——formatter 组合需要约 10^2 微秒数量级，
    /// 纯算术路径需要约 10^0 微秒数量级。
    @Test func canonicalParsingDoesNotShowFormatterCostScaling() {
        let timestamps = (0..<2000).map { index in
            Self.referenceISOString(from: Date(timeIntervalSince1970: 1_770_000_000 + Double(index) * 137))
        }

        func elapsed(_ body: () -> Int) -> TimeInterval {
            var sink = 0
            for _ in 0..<3 { sink &+= body() }
            var best = TimeInterval.greatestFiniteMagnitude
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                sink &+= body()
                best = min(best, ProcessInfo.processInfo.systemUptime - start)
            }
            #expect(sink > 0)
            return best
        }

        let fast = elapsed { timestamps.reduce(0) { $0 + (DateFormatting.date(from: $1) == nil ? 0 : 1) } }
        let baseline = elapsed { timestamps.reduce(0) { $0 + (Self.referenceDate(from: $1) == nil ? 0 : 1) } }
        #expect(fast * 4 < baseline,
                "规范时间戳解析未体现快速路径：fast=\(fast) baseline=\(baseline)")
    }

    // MARK: - 分歧形状继续走 formatter

    @Test func nonCanonicalInputsKeepFormatterSemantics() {
        let inputs = [
            // 分数秒：formatter 截断到毫秒，`Date.ISO8601FormatStyle` 不舍入。
            "2026-02-02T02:40:00.0Z",
            "2026-02-02T02:40:00.123Z",
            "2026-02-02T02:40:00.123456Z",
            "2026-02-02T02:40:00.500+08:00",
            // 越界时钟字段：formatter 拒绝，`Date.ISO8601FormatStyle` 接受。
            "2026-01-15T24:00:00Z",
            "2026-01-15T25:00:00Z",
            "2026-01-15T99:00:00Z",
            "2026-01-15T00:60:00Z",
            "2026-01-15T00:99:00Z",
            "2026-01-15T00:00:60Z",
            "2026-01-15T00:00:61Z",
            // 越界 UTC 偏移：formatter 接受，`Date.ISO8601FormatStyle` 拒绝。
            "2026-01-15T00:00:00+23:59",
            "2026-01-15T00:00:00+99:99",
            "2026-01-15T00:00:00+15:00",
            "2026-01-15T00:00:00-15:00",
            // 需要归一化的日历日。
            "2025-02-29T00:00:00Z",
            "2026-04-31T00:00:00Z",
            "2026-06-31T00:00:00Z",
            "2026-13-45T99:99:99Z",
            "2026-00-15T00:00:00Z",
            "2026-01-00T00:00:00Z",
            // 形状不匹配。
            "2026-02-02T02:40:00",
            "2026-02-02",
            "2026-1-15T00:00:00Z",
            "26-01-15T00:00:00Z",
            "2026-01-15t00:00:00z",
            "2026-01-15 00:00:00Z",
            "2026-01-15T00:00:00+0800",
            " 2026-01-15T00:00:00Z",
            "2026-01-15T00:00:00Z ",
            "2026-01-15T00:00:00Z\n",
            "2026-01-15T00:00:00ZZ",
            "x2026-01-15T00:00:00Z",
            "２０２６-01-15T00:00:00Z",
            "",
            "nope",
        ]

        for input in inputs {
            Self.expectMatchesReference(input)
        }
    }

    /// 1582-10-15 之前 `ISO8601DateFormatter` 按儒略历解释，快速路径的格里高利历
    /// 算术在那里不成立，因此这些日期必须继续由 formatter 决定取值。
    @Test func preGregorianCutoverDatesKeepFormatterSemantics() {
        let inputs = [
            "0000-01-01T00:00:00Z",
            "0000-02-29T00:00:00Z",
            "0001-01-01T00:00:00Z",
            "0100-06-15T12:00:00Z",
            "1000-06-15T12:00:00Z",
            "1500-06-15T12:00:00Z",
            "1582-10-14T23:59:59Z",
            "1582-10-14T00:00:00+14:00",
        ]

        for input in inputs {
            Self.expectMatchesReference(input)
        }
        // 切分点本身必须与 formatter 一致，且确实是切分点。
        Self.expectMatchesReference("1582-10-15T00:00:00Z")
        #expect(DateFormatting.date(from: "1582-10-15T00:00:00Z")
                != DateFormatting.date(from: "1582-10-14T00:00:00Z"))
    }

    // MARK: - 变异模糊测试

    /// 在规范字符串上做多字节变异，覆盖"恰好长得像规范形状"的相邻输入。
    @Test func mutatedCanonicalStringsAlwaysMatchTheFormatterBaseline() {
        let digits = Array("0123456789".utf8)
        let substitutes: [UInt8] = [
            UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: ":"),
            UInt8(ascii: "T"), UInt8(ascii: "Z"), UInt8(ascii: "z"),
            UInt8(ascii: "9"), UInt8(ascii: " "), UInt8(ascii: "W"),
        ]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33) % bound
        }

        for _ in 0..<6_000 {
            var bytes = Array("2026-01-15T00:00:00Z".utf8)
            for _ in 0..<(1 + next(4)) {
                let position = next(bytes.count)
                bytes[position] = next(2) == 0 ? digits[next(10)] : substitutes[next(substitutes.count)]
            }
            Self.expectMatchesReference(String(decoding: bytes, as: UTF8.self))
        }
    }

    // MARK: - 输出与派生

    @Test func isoStringMatchesTheFormatterBaseline() {
        var instant = -62_135_769_600.0   // 0001-01-01
        while instant < 253_402_300_800.0 {  // 9999-12-31
            for fraction in [0.0, 0.4, 0.5, 0.999] {
                let date = Date(timeIntervalSince1970: instant + fraction)
                #expect(DateFormatting.isoString(from: date) == Self.referenceISOString(from: date),
                        "isoString 在 \(instant + fraction) 处与 formatter 基准不一致")
            }
            instant += 43_200.0 * 1_201
        }
    }

    @Test func isoStringRoundTripsThroughTheParser() {
        for instant in [-1.0, 0.0, 1_770_000_000.0, 253_402_300_799.0] {
            let date = Date(timeIntervalSince1970: instant)
            #expect(DateFormatting.date(from: DateFormatting.isoString(from: date)) == date)
        }
    }

    @Test func relativeTimeLabelsAreUnchanged() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        func stamp(_ offset: TimeInterval) -> String {
            DateFormatting.isoString(from: now.addingTimeInterval(-offset))
        }

        #expect(DateFormatting.relativeTime(from: stamp(0), relativeTo: now) == "<1m ago")
        #expect(DateFormatting.relativeTime(from: stamp(59), relativeTo: now) == "<1m ago")
        #expect(DateFormatting.relativeTime(from: stamp(120), relativeTo: now) == "2m ago")
        #expect(DateFormatting.relativeTime(from: stamp(7_200), relativeTo: now) == "2h ago")
        #expect(DateFormatting.relativeTime(from: stamp(172_800), relativeTo: now) == "2d ago")
        #expect(DateFormatting.relativeTime(from: "not a date", relativeTo: now) == "unknown")

        #expect(DateFormatting.relativeTimeChinese(from: stamp(0), relativeTo: now) == "刚刚")
        #expect(DateFormatting.relativeTimeChinese(from: stamp(120), relativeTo: now) == "2 分钟前")
        #expect(DateFormatting.relativeTimeChinese(from: stamp(7_200), relativeTo: now) == "2 小时前")
        #expect(DateFormatting.relativeTimeChinese(from: stamp(172_800), relativeTo: now) == "2 天前")
        #expect(DateFormatting.relativeTimeChinese(from: "not a date", relativeTo: now) == nil)
        // 未来超过容差的时刻必须继续返回 nil。
        #expect(DateFormatting.relativeTimeChinese(from: stamp(-600), relativeTo: now) == nil)
        #expect(DateFormatting.relativeTimeChinese(from: stamp(-30), relativeTo: now) == "刚刚")
    }

    @Test func timestampParserMatchesTheSharedHelper() {
        let parser = DateFormatting.TimestampParser()
        let inputs = [
            "2026-01-15T00:00:00Z",
            "2026-01-15T00:00:00.123Z",
            "2026-01-15T00:00:00+05:30",
            "2025-02-29T00:00:00Z",
            "2026-01-15T00:00:00",
            "nope",
        ]
        for input in inputs {
            #expect(Self.epoch(parser.date(from: input)) == Self.epoch(DateFormatting.date(from: input)))
            #expect(Self.epoch(parser.date(from: input)) == Self.epoch(Self.referenceDate(from: input)))
        }
    }

    @Test func displayStringKeepsTheConfiguredFormat() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let reference = DateFormatter()
        reference.locale = Locale(identifier: "en_US_POSIX")
        reference.timeZone = TimeZone.current
        reference.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        #expect(DateFormatting.displayString(from: date) == reference.string(from: date))
    }
}

import Foundation

/// The subset of RFC 5545 recurrence rules that Apple Calendar can represent.
/// Anything else fails to parse, so the event goes to review instead of repeating wrongly.
public struct Recurrence: Equatable, Sendable {
    public enum Frequency: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }

    public struct WeekdayRule: Equatable, Sendable {
        /// 1 is Sunday and 7 is Saturday.
        public let weekday: Int
        /// 1 for the first in the month, -1 for the last, nil for every.
        public let ordinal: Int?
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unsupported(String)
        public var description: String {
            switch self { case .unsupported(let detail): return detail }
        }
    }

    public var frequency: Frequency
    public var interval = 1
    public var until: Day?
    public var count: Int?
    public var byDay: [WeekdayRule] = []
    public var byMonthDay: [Int] = []
    public var byMonth: [Int] = []

    private static let weekdayCodes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    public init(rrule: String) throws {
        var text = rrule.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased().hasPrefix("RRULE:") { text = String(text.dropFirst(6)) }

        var frequency: Frequency?
        var setPosition: Int?
        for part in text.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { throw ParseError.unsupported("can't read \"\(part)\"") }
            let (key, value) = (pair[0].uppercased(), pair[1].uppercased())
            switch key {
            case "FREQ":
                guard let parsed = Frequency(rawValue: value) else { throw ParseError.unsupported("frequency \(value)") }
                frequency = parsed
            case "INTERVAL":
                guard let parsed = Int(value), parsed > 0 else { throw ParseError.unsupported("interval \(value)") }
                interval = parsed
            case "UNTIL":
                guard let parsed = Day(compact: value) else { throw ParseError.unsupported("end date \(value)") }
                until = parsed
            case "COUNT":
                guard let parsed = Int(value), parsed > 0 else { throw ParseError.unsupported("count \(value)") }
                count = parsed
            case "BYDAY":
                byDay = try value.split(separator: ",").map { try Recurrence.parseWeekday(String($0)) }
            case "BYMONTHDAY":
                byMonthDay = try value.split(separator: ",").map {
                    guard let parsed = Int($0), parsed != 0, abs(parsed) <= 31 else {
                        throw ParseError.unsupported("day of month \($0)")
                    }
                    return parsed
                }
            case "BYMONTH":
                byMonth = try value.split(separator: ",").map {
                    guard let parsed = Int($0), (1...12).contains(parsed) else { throw ParseError.unsupported("month \($0)") }
                    return parsed
                }
            case "BYSETPOS":
                guard let parsed = Int(value), parsed != 0 else { throw ParseError.unsupported("position \(value)") }
                setPosition = parsed
            case "WKST":
                continue
            default:
                throw ParseError.unsupported("\(key) isn't supported")
            }
        }
        guard let frequency else { throw ParseError.unsupported("missing FREQ") }
        self.frequency = frequency
        if until != nil && count != nil { throw ParseError.unsupported("both UNTIL and COUNT") }

        // BYDAY=TU;BYSETPOS=1 is another way of writing BYDAY=1TU.
        if let setPosition {
            guard byDay.count == 1, byDay[0].ordinal == nil else {
                throw ParseError.unsupported("BYSETPOS with several days")
            }
            byDay = [WeekdayRule(weekday: byDay[0].weekday, ordinal: setPosition)]
        }
        if frequency == .weekly, byDay.contains(where: { $0.ordinal != nil }) {
            throw ParseError.unsupported("a weekly rule with a numbered day")
        }
        if frequency == .daily, !(byDay.isEmpty && byMonthDay.isEmpty && byMonth.isEmpty) {
            throw ParseError.unsupported("a daily rule with BY parts")
        }
    }

    private static func parseWeekday(_ text: String) throws -> WeekdayRule {
        guard text.count >= 2, let weekday = weekdayCodes[String(text.suffix(2))] else {
            throw ParseError.unsupported("day \(text)")
        }
        let prefix = text.dropLast(2)
        if prefix.isEmpty { return WeekdayRule(weekday: weekday, ordinal: nil) }
        guard let ordinal = Int(prefix), ordinal != 0, abs(ordinal) <= 5 else {
            throw ParseError.unsupported("day \(text)")
        }
        return WeekdayRule(weekday: weekday, ordinal: ordinal)
    }

    /// Whether the pattern lands on `candidate`, ignoring UNTIL and COUNT.
    func patternMatches(_ candidate: Day, start: Day) -> Bool {
        guard candidate >= start else { return false }
        switch frequency {
        case .daily:
            return (candidate.number - start.number) % interval == 0
        case .weekly:
            // RFC 5545 weeks start on Monday by default. Day 4 of the epoch was a Monday.
            let weekIndex = { (day: Day) in Int(floor(Double(day.number - 4) / 7)) }
            guard (weekIndex(candidate) - weekIndex(start)) % interval == 0 else { return false }
            let days = byDay.isEmpty ? [start.weekday] : byDay.map(\.weekday)
            return days.contains(candidate.weekday)
        case .monthly:
            let months = (candidate.year - start.year) * 12 + candidate.month - start.month
            guard months % interval == 0 else { return false }
            return dayOfMonthMatches(candidate, start: start)
        case .yearly:
            guard (candidate.year - start.year) % interval == 0 else { return false }
            guard (byMonth.isEmpty ? [start.month] : byMonth).contains(candidate.month) else { return false }
            return dayOfMonthMatches(candidate, start: start)
        }
    }

    private func dayOfMonthMatches(_ candidate: Day, start: Day) -> Bool {
        if !byDay.isEmpty {
            return byDay.contains { rule in
                guard rule.weekday == candidate.weekday else { return false }
                guard let ordinal = rule.ordinal else { return true }
                if ordinal > 0 { return (candidate.day - 1) / 7 + 1 == ordinal }
                return (candidate.daysInMonth - candidate.day) / 7 + 1 == -ordinal
            }
        }
        if !byMonthDay.isEmpty {
            return byMonthDay.contains { $0 > 0 ? $0 == candidate.day : candidate.daysInMonth + $0 + 1 == candidate.day }
        }
        return candidate.day == start.day
    }

    /// The first occurrence on or after `earliest`, within about three years of it.
    public func nextOccurrence(start: Day, onOrAfter earliest: Day) -> Day? {
        var candidate = start
        var seen = 0
        let horizon = max(start, earliest).adding(days: 1100)
        while candidate <= horizon {
            if let until, candidate > until { return nil }
            if patternMatches(candidate, start: start) {
                seen += 1
                if let count, seen > count { return nil }
                if candidate >= earliest { return candidate }
            }
            candidate = candidate.adding(days: 1)
        }
        return nil
    }

    /// False if this rule repeats with no end.
    public var hasEnd: Bool { until != nil || count != nil }
}

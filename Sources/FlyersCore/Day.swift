import Foundation

/// A calendar date with no time or time zone, so date maths can't shift across daylight saving.
public struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public init?(year: Int, month: Int, day: Int) {
        let parts = DateComponents(year: year, month: month, day: day)
        guard parts.isValidDate(in: Day.utc) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD`.
    public init?(iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            return nil
        }
        self.init(year: y, month: m, day: d)
    }

    /// Parses `YYYYMMDD`, ignoring anything after it, such as the time in an RRULE's UNTIL.
    public init?(compact: String) {
        guard compact.count >= 8 else { return nil }
        let digits = compact.prefix(8)
        guard let y = Int(digits.prefix(4)),
              let m = Int(digits.dropFirst(4).prefix(2)),
              let d = Int(digits.dropFirst(6)) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)!
    }

    public static var today: Day { Day(date: Date()) }

    private var utcDate: Date {
        Day.utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// Days since the Unix epoch.
    public var number: Int { Int(utcDate.timeIntervalSince1970 / 86_400) }

    /// 1 is Sunday and 7 is Saturday, matching Calendar and EKWeekday.
    public var weekday: Int { Day.utc.component(.weekday, from: utcDate) }

    public var daysInMonth: Int { Day.utc.range(of: .day, in: .month, for: utcDate)!.count }

    public func adding(days: Int) -> Day {
        Day(date: Day.utc.date(byAdding: .day, value: days, to: utcDate)!, calendar: Day.utc)
    }

    /// Midnight at the start of this day in the given calendar's time zone.
    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    public static func < (lhs: Day, rhs: Day) -> Bool { lhs.number < rhs.number }

    public static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    public var weekdayName: String { Day.weekdayNames[weekday - 1] }
}

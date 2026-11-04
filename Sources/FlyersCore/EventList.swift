import Foundation

/// How the main list is grouped. It lives here, not in the views, so it can be tested.
public enum EventList {
    public enum Row: Identifiable, Equatable {
        case event(FlyerEvent, next: Day?)
        /// Optional repeating events from one schedule flyer, shown as one expandable row.
        case series(flyerID: UUID, events: [FlyerEvent], next: Day)

        public var id: UUID {
            switch self {
            case .event(let event, _): return event.id
            case .series(let flyerID, _, _): return flyerID
            }
        }

        var sortDay: Day? {
            switch self {
            case .event(_, let next): return next
            case .series(_, _, let next): return next
            }
        }
    }

    public struct Section: Identifiable, Equatable {
        public let title: String
        public var rows: [Row]
        public var id: String { title }
    }

    public static func upcoming(_ events: [FlyerEvent], today: Day) -> [Section] {
        let live = events.filter { !$0.isHidden && $0.state != .needsReview && !$0.isOver(today: today) }
        var rows: [Row] = []
        var seriesByFlyer: [UUID: [FlyerEvent]] = [:]
        for event in live {
            if event.state == .available && event.rrule != nil {
                seriesByFlyer[event.flyerID, default: []].append(event)
            } else {
                rows.append(.event(event, next: event.nextDay(onOrAfter: today)))
            }
        }
        for (flyerID, group) in seriesByFlyer {
            let sorted = group.sorted { ($0.nextDay(onOrAfter: today) ?? today) < ($1.nextDay(onOrAfter: today) ?? today) }
            if let next = sorted.first?.nextDay(onOrAfter: today) {
                rows.append(.series(flyerID: flyerID, events: sorted, next: next))
            }
        }
        rows.sort(by: { sortKey($0) < sortKey($1) })

        var sections: [Section] = []
        for row in rows {
            let title = row.sortDay.map { bucket($0, today: today) } ?? "No date"
            if sections.last?.title == title {
                sections[sections.count - 1].rows.append(row)
            } else {
                sections.append(Section(title: title, rows: [row]))
            }
        }
        return sections
    }

    public static func needingReview(_ events: [FlyerEvent]) -> [FlyerEvent] {
        events.filter { $0.state == .needsReview }.sorted {
            ($0.startDay ?? Day(year: 9999, month: 1, day: 1)!) < ($1.startDay ?? Day(year: 9999, month: 1, day: 1)!)
        }
    }

    public static func past(_ events: [FlyerEvent], today: Day) -> [FlyerEvent] {
        events.filter { !$0.isHidden && $0.state != .needsReview && $0.isOver(today: today) }
            .sorted { ($0.startDay ?? today) > ($1.startDay ?? today) }
    }

    /// The next few things to show in the menu bar. Only what's on the calendar.
    public static func next(_ events: [FlyerEvent], today: Day, limit: Int) -> [(event: FlyerEvent, day: Day)] {
        events.filter { $0.state == .onCalendar }
            .compactMap { event in event.nextDay(onOrAfter: today).map { (event: event, day: $0) } }
            .sorted { $0.day < $1.day }
            .prefix(limit)
            .map { $0 }
    }

    private static func sortKey(_ row: Row) -> Int { row.sortDay?.number ?? Int.max }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    static func bucket(_ day: Day, today: Day) -> String {
        if day == today { return "Today" }
        if day == today.adding(days: 1) { return "Tomorrow" }
        if day.number - today.number < 7 { return "This week" }
        if day.year == today.year && day.month == today.month { return "Later this month" }
        return monthFormatter.string(from: day.date())
    }
}

public enum EventFormat {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()

    private static let fullDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMMM d yyyy")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    public static func shortDay(_ day: Day) -> String { dayFormatter.string(from: day.date()) }

    public static func time(_ text: String) -> String {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(
            bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()
        ) else { return text }
        return timeFormatter.string(from: date)
    }

    public static func timeRange(_ event: FlyerEvent) -> String? {
        guard let start = event.startTime else { return nil }
        guard let end = event.endTime else { return time(start) }
        return "\(time(start)) to \(time(end))"
    }

    /// One line for a list row. Pass the next occurrence so a repeating event shows its next date.
    public static func summary(_ event: FlyerEvent, day: Day?) -> String {
        guard let day = day ?? event.startDay else { return "No date" }
        var when = shortDay(day)
        if let end = event.endDay, event.rrule == nil { when += " to \(shortDay(end))" }
        if let range = timeRange(event) { when += ", \(range)" }
        return when
    }

    /// The full date and time for the detail pane.
    public static func full(_ event: FlyerEvent) -> String {
        guard let start = event.startDay else { return "No date on the flyer" }
        var when = fullDayFormatter.string(from: start.date())
        if let end = event.endDay { when += " to \(fullDayFormatter.string(from: end.date()))" }
        if let range = timeRange(event) { when += ", \(range)" }
        return when
    }

    /// A rule in plain language, such as "Every Friday until Apr 30".
    public static func repeats(_ rule: Recurrence) -> String {
        let weekdays = rule.byDay.filter { $0.ordinal == nil }.map { Day.weekdayNames[$0.weekday - 1] }
        var text: String
        switch rule.frequency {
        case .daily:
            text = rule.interval == 1 ? "Every day" : "Every \(rule.interval) days"
        case .weekly:
            let days = weekdays.isEmpty ? "week" : weekdays.joined(separator: ", ")
            text = rule.interval == 1 ? "Every \(days)" : "Every \(rule.interval) weeks\(weekdays.isEmpty ? "" : " on \(days)")"
        case .monthly:
            if let numbered = rule.byDay.first(where: { $0.ordinal != nil }), let ordinal = numbered.ordinal {
                let names = [1: "First", 2: "Second", 3: "Third", 4: "Fourth", 5: "Fifth", -1: "Last", -2: "Second to last"]
                text = "\(names[ordinal] ?? "\(ordinal)th") \(Day.weekdayNames[numbered.weekday - 1]) of "
                text += rule.interval == 1 ? "each month" : "every \(rule.interval) months"
            } else {
                text = rule.interval == 1 ? "Every month" : "Every \(rule.interval) months"
            }
        case .yearly:
            text = rule.interval == 1 ? "Every year" : "Every \(rule.interval) years"
        }
        if let until = rule.until { text += " until \(shortDay(until))" }
        if let count = rule.count { text += ", \(count) times" }
        return text
    }
}

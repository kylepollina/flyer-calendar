import EventKit
import Foundation

public struct CalendarSnapshot: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var isAllDay: Bool
    public var location: String?

    public init(title: String, start: Date, isAllDay: Bool, location: String?) {
        self.title = title
        self.start = start
        self.isAllDay = isAllDay
        self.location = location
    }
}

/// Links from a Calendar event back to the event in Flyers. A link only selects an event,
/// so one that arrives from anywhere else can't change anything.
public enum AppLink {
    public static let scheme = "flyers"

    public static func url(for id: UUID) -> URL {
        URL(string: "\(scheme)://event/\(id.uuidString)")!
    }

    public static func eventID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == "event" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1 else { return nil }
        return UUID(uuidString: parts[0])
    }
}

public protocol CalendarSyncing: AnyObject {
    /// True once there's access and a chosen calendar that still exists.
    var isReady: Bool { get }
    func add(_ event: FlyerEvent, alertMinutesBefore: Int) throws -> String
    func update(_ event: FlyerEvent, itemID: String) throws
    /// Adds the Open in Flyers link to an existing event, keeping everything you've edited.
    func addAppLink(_ event: FlyerEvent, itemID: String) throws
    func remove(itemID: String) throws
    func snapshot(itemID: String) -> CalendarSnapshot?
}

public struct CalendarChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
}

public enum CalendarError: Error, CustomStringConvertible {
    case notReady
    case noDate
    case noSource

    public var description: String {
        switch self {
        case .notReady: return "Choose a calendar in Settings first"
        case .noDate: return "The event has no date"
        case .noSource: return "Couldn't find an account to create the calendar in"
        }
    }
}

public final class CalendarService: CalendarSyncing {
    public static let defaultCalendarName = "Flyers"
    public let store = EKEventStore()
    public var calendarID: String?

    public init(calendarID: String?) {
        self.calendarID = calendarID
    }

    public static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public var isReady: Bool { CalendarService.hasAccess && calendar != nil }

    private var calendar: EKCalendar? {
        calendarID.flatMap { store.calendar(withIdentifier: $0) }
    }

    public func writableCalendars() -> [CalendarChoice] {
        store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func createFlyersCalendar() throws -> String {
        let new = EKCalendar(for: .event, eventStore: store)
        new.title = CalendarService.defaultCalendarName
        guard let source = store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw CalendarError.noSource
        }
        new.source = source
        try store.saveCalendar(new, commit: true)
        return new.calendarIdentifier
    }

    public func add(_ event: FlyerEvent, alertMinutesBefore: Int) throws -> String {
        guard let calendar else { throw CalendarError.notReady }
        let item = EKEvent(eventStore: store)
        item.calendar = calendar
        try fill(item, from: event)
        if let recurrence = event.recurrence {
            item.recurrenceRules = [CalendarService.makeRule(recurrence)]
        }
        if alertMinutesBefore > 0 {
            var offset = TimeInterval(-alertMinutesBefore * 60)
            // An all-day event starts at midnight, so aim its alert at 9 AM rather than overnight.
            if item.isAllDay { offset += 9 * 3600 }
            item.addAlarm(EKAlarm(relativeOffset: offset))
        }
        try store.save(item, span: .futureEvents, commit: true)
        return item.calendarItemIdentifier
    }

    public func update(_ event: FlyerEvent, itemID: String) throws {
        guard let item = store.calendarItem(withIdentifier: itemID) as? EKEvent else { return }
        try fill(item, from: event)
        try store.save(item, span: .futureEvents, commit: true)
    }

    public func addAppLink(_ event: FlyerEvent, itemID: String) throws {
        guard let item = store.calendarItem(withIdentifier: itemID) as? EKEvent else { return }
        item.url = AppLink.url(for: event.id)
        // The URL field held the flyer's own link, so keep that in the notes.
        if let link = event.url, !(item.notes ?? "").contains(link) {
            item.notes = [item.notes, "Link: \(link)"].compactMap { $0 }.joined(separator: "\n\n")
        }
        try store.save(item, span: .futureEvents, commit: true)
    }

    public func remove(itemID: String) throws {
        guard let item = store.calendarItem(withIdentifier: itemID) as? EKEvent else { return }
        try store.remove(item, span: .futureEvents, commit: true)
    }

    public func snapshot(itemID: String) -> CalendarSnapshot? {
        guard let item = store.calendarItem(withIdentifier: itemID) as? EKEvent else { return nil }
        return CalendarSnapshot(title: item.title ?? "", start: item.startDate, isAllDay: item.isAllDay, location: item.location)
    }

    private func fill(_ item: EKEvent, from event: FlyerEvent) throws {
        guard let times = CalendarService.times(for: event) else { throw CalendarError.noDate }
        item.title = event.name
        item.startDate = times.start
        item.endDate = times.end
        item.isAllDay = times.isAllDay
        item.location = event.location
        item.url = AppLink.url(for: event.id)
        var notes: [String] = []
        if let details = event.details { notes.append(details) }
        if let link = event.url { notes.append("Link: \(link)") }
        if let printed = event.datePrinted { notes.append("As printed: \(printed)") }
        if event.locationInferred { notes.append("The location is a best guess.") }
        notes.append("Added by Flyers.")
        item.notes = notes.joined(separator: "\n\n")
    }

    /// An event with no printed end time gets a nominal hour, so it shows up on the calendar.
    public static func times(
        for event: FlyerEvent, calendar: Calendar = .current
    ) -> (start: Date, end: Date, isAllDay: Bool)? {
        guard let startDay = event.startDay else { return nil }
        guard let startTime = event.startTime, let start = at(startDay, time: startTime, calendar: calendar) else {
            return (startDay.date(calendar: calendar), (event.endDay ?? startDay).date(calendar: calendar), true)
        }
        guard let endTime = event.endTime, var end = at(event.endDay ?? startDay, time: endTime, calendar: calendar) else {
            return (start, start.addingTimeInterval(3600), false)
        }
        // "9 PM to 1 AM" ends the next day.
        if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end)! }
        return (start, end, false)
    }

    private static func at(_ day: Day, time: String, calendar: Calendar) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: parts[0], minute: parts[1]))
    }

    public static func makeRule(_ recurrence: Recurrence, calendar: Calendar = .current) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch recurrence.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        var end: EKRecurrenceEnd?
        if let until = recurrence.until {
            // Include the whole of the last day.
            end = EKRecurrenceEnd(end: until.adding(days: 1).date(calendar: calendar).addingTimeInterval(-1))
        } else if let count = recurrence.count {
            end = EKRecurrenceEnd(occurrenceCount: count)
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: recurrence.interval,
            daysOfTheWeek: recurrence.byDay.isEmpty ? nil : recurrence.byDay.map { rule in
                EKRecurrenceDayOfWeek(EKWeekday(rawValue: rule.weekday)!, weekNumber: rule.ordinal ?? 0)
            },
            daysOfTheMonth: recurrence.byMonthDay.isEmpty ? nil : recurrence.byMonthDay.map { NSNumber(value: $0) },
            monthsOfTheYear: recurrence.byMonth.isEmpty ? nil : recurrence.byMonth.map { NSNumber(value: $0) },
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }
}

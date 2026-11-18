import Foundation
import Testing
@testable import FlyersCore

private func makeEvent(
    _ name: String, start: String?, rrule: String? = nil, state: EventState = .onCalendar, flyer: UUID = UUID()
) -> FlyerEvent {
    FlyerEvent(
        id: UUID(), flyerID: flyer, name: name, datePrinted: nil, startDay: start.flatMap(Day.init(iso:)),
        startTime: nil, endDay: nil, endTime: nil, rrule: rrule, yearInferred: false, startUncertain: false,
        location: nil, locationInferred: false, url: nil, details: nil, state: state, stateBeforeDelete: nil,
        calendarItemID: nil, fingerprint: name, problems: []
    )
}

@Suite struct EventListTests {
    @Test func searchFindsEventsByAnyOfTheirWordsSoonestFirst() {
        var climbing = makeEvent("Bouldering Night", start: "2026-11-20")
        climbing.location = "Movement Lincoln Park"
        let chess = makeEvent("Chess Club", start: "2026-11-05")
        var cafe = makeEvent("Open Mic", start: "2026-10-01")
        cafe.details = "At the Understudy café"
        let deleted = makeEvent("Chess Swap", start: "2026-11-06", state: .deleted)
        let all = [climbing, chess, cafe, deleted]

        #expect(EventList.search("lincoln park", in: all, today: today).upcoming.map(\.event.name) == ["Bouldering Night"])
        // Accents and case don't matter, and past events come back too.
        #expect(EventList.search("CAFE", in: all, today: today).past.map(\.name) == ["Open Mic"])
        // Every word has to match, and deleted events aren't searched.
        #expect(EventList.search("chess club", in: all, today: today).upcoming.map(\.event.name) == ["Chess Club"])
        #expect(EventList.search("chess", in: all, today: today).upcoming.count == 1)
        #expect(EventList.search("  ", in: all, today: today).isEmpty)
    }

    private let today = Day(iso: "2026-11-03")!

    @Test func upcomingIsChronologicalWithBuckets() {
        let sections = EventList.upcoming([
            makeEvent("January", start: "2027-01-05"),
            makeEvent("Later", start: "2026-11-25"),
            makeEvent("Now", start: "2026-11-03"),
            makeEvent("Soon", start: "2026-11-06"),
        ], today: today)
        #expect(sections.map(\.title).prefix(3) == ["Today", "This week", "Later this month"])
        #expect(sections.count == 4)
        #expect(sections.last?.rows.count == 1)
    }

    @Test func hiddenEventsArentUpcomingButHeldOnesAre() {
        let sections = EventList.upcoming([
            makeEvent("Deleted", start: "2026-11-05", state: .deleted),
            makeEvent("Removed", start: "2026-11-05", state: .removedInCalendar),
            makeEvent("Check", start: "2026-11-05", state: .needsReview),
        ], today: today)
        #expect(sections.flatMap(\.rows).map(\.event.name) == ["Check"])
    }

    @Test func everyEventFromOnePhotoIsListedSoonestFirst() {
        let flyer = UUID()
        let events = [
            makeEvent("B", start: "2026-11-09", rrule: "FREQ=WEEKLY;BYDAY=MO", flyer: flyer),
            makeEvent("A", start: "2026-11-04", state: .available, flyer: flyer),
            makeEvent("Gone", start: "2026-11-04", state: .deleted, flyer: flyer),
            makeEvent("Elsewhere", start: "2026-11-04"),
        ]
        #expect(EventList.fromFlyer(flyer, in: events, today: today).map(\.name) == ["A", "B"])
    }

    @Test func aRepeatingEventOnTheCalendarIsItsOwnRowAtItsNextDate() {
        let sections = EventList.upcoming([
            makeEvent("Weekly", start: "2026-10-05", rrule: "FREQ=WEEKLY;BYDAY=MO"),
        ], today: today)
        #expect(sections.first?.rows.first?.next == Day(iso: "2026-11-09"))
    }

    @Test func aFinishedRepeatMovesToPast() {
        let events = [makeEvent("April", start: "2026-04-24", rrule: "FREQ=WEEKLY;BYDAY=FR;UNTIL=20260430")]
        #expect(EventList.upcoming(events, today: today).isEmpty)
        #expect(EventList.past(events, today: today).count == 1)
    }

    @Test func aMultiDayEventIsLiveUntilItEnds() {
        var festival = makeEvent("Fest", start: "2026-11-01")
        festival.endDay = Day(iso: "2026-11-03")
        #expect(!festival.isOver(today: today))
        #expect(festival.isOver(today: today.adding(days: 1)))
    }

    @Test func undatedEventsAreNotPast() {
        #expect(EventList.past([makeEvent("Undated", start: nil, state: .available)], today: today).isEmpty)
    }

    @Test func theMenuOnlyShowsWhatsOnTheCalendar() {
        let next = EventList.next([
            makeEvent("Later", start: "2026-11-20"),
            makeEvent("Sooner", start: "2026-11-04"),
            makeEvent("Optional", start: "2026-11-04", state: .available),
        ], today: today, limit: 5)
        #expect(next.map(\.event.name) == ["Sooner", "Later"])
    }

    @Test func rulesReadInPlainLanguage() throws {
        #expect(EventFormat.repeats(try Recurrence(rrule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=SU")) == "Every 2 weeks on Sunday")
        #expect(EventFormat.repeats(try Recurrence(rrule: "FREQ=MONTHLY;BYDAY=1TU")) == "First Tuesday of each month")
        #expect(EventFormat.repeats(try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=FR")) == "Every Friday")
    }
}

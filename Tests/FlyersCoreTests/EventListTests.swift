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

    @Test func hiddenAndReviewEventsArentUpcoming() {
        let sections = EventList.upcoming([
            makeEvent("Deleted", start: "2026-11-05", state: .deleted),
            makeEvent("Removed", start: "2026-11-05", state: .removedInCalendar),
            makeEvent("Check", start: "2026-11-05", state: .needsReview),
        ], today: today)
        #expect(sections.isEmpty)
    }

    @Test func optionalRepeatingEventsCollapseIntoOneRowPerFlyer() {
        let flyer = UUID()
        let sections = EventList.upcoming([
            makeEvent("A", start: "2026-11-09", rrule: "FREQ=WEEKLY;BYDAY=MO", state: .available, flyer: flyer),
            makeEvent("B", start: "2026-11-04", rrule: "FREQ=WEEKLY;BYDAY=WE", state: .available, flyer: flyer),
        ], today: today)
        #expect(sections.count == 1)
        guard case .series(let id, let events, let next)? = sections.first?.rows.first else {
            Issue.record("expected a series")
            return
        }
        #expect(id == flyer)
        #expect(events.map(\.name) == ["B", "A"])
        #expect(next == Day(iso: "2026-11-04"))
    }

    @Test func aRepeatingEventOnTheCalendarIsItsOwnRowAtItsNextDate() {
        let sections = EventList.upcoming([
            makeEvent("Weekly", start: "2026-10-05", rrule: "FREQ=WEEKLY;BYDAY=MO"),
        ], today: today)
        guard case .event(_, let next)? = sections.first?.rows.first else {
            Issue.record("expected an event")
            return
        }
        #expect(next == Day(iso: "2026-11-09"))
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

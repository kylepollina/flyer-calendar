import Foundation
import Testing
@testable import FlyersCore

private func day(_ iso: String) -> Day { Day(iso: iso)! }

@Suite struct RecurrenceTests {
    @Test func weeklyWithEndStopsAfterUntil() throws {
        let rule = try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=FR;UNTIL=20260430")
        let start = day("2026-04-24")
        #expect(rule.nextOccurrence(start: start, onOrAfter: start) == start)
        #expect(rule.nextOccurrence(start: start, onOrAfter: day("2026-04-25")) == nil)
    }

    @Test func untilWithTimeIsAccepted() throws {
        #expect(try Recurrence(rrule: "RRULE:FREQ=WEEKLY;UNTIL=20260430T235959Z").until == day("2026-04-30"))
    }

    @Test func everyOtherWeekSkipsAWeek() throws {
        let rule = try Recurrence(rrule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=SU")
        let start = day("2026-04-19")
        #expect(rule.nextOccurrence(start: start, onOrAfter: day("2026-04-20")) == day("2026-05-03"))
    }

    @Test func firstTuesdayOfTheMonth() throws {
        let rule = try Recurrence(rrule: "FREQ=MONTHLY;BYDAY=1TU")
        let start = day("2026-11-03")
        #expect(rule.nextOccurrence(start: start, onOrAfter: start) == start)
        #expect(rule.nextOccurrence(start: start, onOrAfter: day("2026-11-04")) == day("2026-12-01"))
    }

    @Test func lastFridayOfTheMonth() throws {
        let rule = try Recurrence(rrule: "FREQ=MONTHLY;BYDAY=-1FR")
        let start = day("2026-11-27")
        #expect(rule.nextOccurrence(start: start, onOrAfter: day("2026-11-28")) == day("2026-12-25"))
    }

    @Test func setPositionBecomesAnOrdinal() throws {
        #expect(try Recurrence(rrule: "FREQ=MONTHLY;BYDAY=TU;BYSETPOS=1") == Recurrence(rrule: "FREQ=MONTHLY;BYDAY=1TU"))
    }

    @Test func countLimitsOccurrences() throws {
        let rule = try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=MO;COUNT=2")
        let start = day("2026-11-02")
        #expect(rule.nextOccurrence(start: start, onOrAfter: day("2026-11-09")) == day("2026-11-09"))
        #expect(rule.nextOccurrence(start: start, onOrAfter: day("2026-11-10")) == nil)
    }

    @Test(arguments: ["FREQ=HOURLY", "BYDAY=MO", "FREQ=WEEKLY;BYHOUR=9", "FREQ=WEEKLY;BYDAY=1MO", "nonsense",
                      "FREQ=WEEKLY;COUNT=2;UNTIL=20260101", "FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=1"])
    func unsupportedRulesAreRejected(rule: String) {
        #expect(throws: Recurrence.ParseError.self) { try Recurrence(rrule: rule) }
    }
}

@Suite struct IngestTests {
    private let taken = day("2026-04-18")

    private func run(
        _ events: [ExtractedEvent], confidence: Confidence = .high, mode: AddMode = .automatic,
        today: Day? = nil, existing: Set<String> = []
    ) -> [FlyerEvent] {
        var settings = AppSettings()
        settings.addMode = mode
        return Ingest.events(
            from: ExtractionResult(isEventFlyer: true, confidence: confidence, events: events),
            flyerID: UUID(), takenOn: taken, today: today ?? taken, settings: settings, existingFingerprints: existing
        )
    }

    @Test func oneOffGoesToTheCalendar() {
        let events = run([ExtractedEvent(name: "Chess", dateAsPrinted: "Sun 4.26", startDate: "2026-04-26")])
        #expect(events.first?.state == .queued)
    }

    @Test func reviewModeHoldsEvents() {
        let events = run([ExtractedEvent(name: "Chess", startDate: "2026-04-26")], mode: .review)
        #expect(events.first?.state == .needsReview)
    }

    @Test func lowConfidenceGoesToReview() {
        let events = run([ExtractedEvent(name: "Chess", startDate: "2026-04-26")], confidence: .low)
        #expect(events.first?.state == .needsReview)
    }

    @Test func wrongPrintedWeekdayGoesToReview() {
        let events = run([ExtractedEvent(name: "Chess", dateAsPrinted: "Sat Apr 26", startDate: "2026-04-26")])
        #expect(events.first?.state == .needsReview)
        #expect(events.first?.problems.first?.contains("Saturday") == true)
    }

    @Test func missingDateGoesToReview() {
        #expect(run([ExtractedEvent(name: "Chess")]).first?.state == .needsReview)
    }

    @Test func eventsBeforeThePhotoAreDropped() {
        #expect(run([ExtractedEvent(name: "Old", startDate: "2026-04-11")]).isEmpty)
    }

    @Test func eventsAlreadyOverStayOffTheCalendar() {
        let events = run([ExtractedEvent(name: "Chess", startDate: "2026-04-26")], today: day("2026-05-01"))
        #expect(events.first?.state == .available)
    }

    @Test func aSingleRepeatingEventGoesToTheCalendar() {
        let events = run([ExtractedEvent(name: "Chess", startDate: "2026-04-21", rrule: "FREQ=WEEKLY;BYDAY=TU")])
        #expect(events.first?.state == .queued)
    }

    @Test func scheduleFlyersOnlyQueueTheirDatedEvents() {
        let events = run([
            ExtractedEvent(name: "A", startDate: "2026-04-20", rrule: "FREQ=WEEKLY;BYDAY=MO"),
            ExtractedEvent(name: "B", startDate: "2026-04-21", rrule: "FREQ=WEEKLY;BYDAY=TU"),
            ExtractedEvent(name: "C", startDate: "2026-04-22", rrule: "FREQ=WEEKLY;BYDAY=WE"),
            ExtractedEvent(name: "Skate", startDate: "2026-04-21"),
        ])
        #expect(events.map(\.state) == [.available, .available, .available, .queued])
    }

    @Test func aRuleThatMissesTheStartGoesToReview() {
        let events = run([ExtractedEvent(name: "Chess", startDate: "2026-04-22", rrule: "FREQ=WEEKLY;BYDAY=TU")])
        #expect(events.first?.state == .needsReview)
    }

    @Test func anUnsupportedRuleGoesToReview() {
        let events = run([ExtractedEvent(name: "Chess", startDate: "2026-04-22", rrule: "FREQ=WEEKLY;BYHOUR=9")])
        #expect(events.first?.state == .needsReview)
    }

    @Test func uncertainStartGoesToReview() {
        let events = run([ExtractedEvent(
            name: "Run", startDate: "2026-04-19", rrule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=SU", startUncertain: true
        )])
        #expect(events.first?.state == .needsReview)
    }

    @Test func duplicatesAreSkippedHoweverTheyreWritten() {
        let existing = FlyerEvent.makeFingerprint(name: "Chess Club!", startDay: day("2026-04-26"))
        #expect(run([ExtractedEvent(name: "chess club", startDate: "2026-04-26")], existing: [existing]).isEmpty)
    }

    @Test func aFlyerListingAnEventTwiceKeepsOne() {
        let chess = ExtractedEvent(name: "Chess", startDate: "2026-04-26")
        #expect(run([chess, chess]).count == 1)
    }

    @Test func nonFlyersProduceNothing() {
        let events = Ingest.events(
            from: ExtractionResult(isEventFlyer: false, events: [ExtractedEvent(name: "x", startDate: "2026-04-26")]),
            flyerID: UUID(), takenOn: taken, today: taken, settings: AppSettings(), existingFingerprints: []
        )
        #expect(events.isEmpty)
    }

    @Test func linksAreNormalizedAndUnsafeSchemesDropped() {
        #expect(Ingest.normalizedURL("www.seafolklore.org") == "https://www.seafolklore.org")
        #expect(Ingest.normalizedURL("http://a.example/x") == "http://a.example/x")
        #expect(Ingest.normalizedURL("javascript:alert(1)") == nil)
        #expect(Ingest.normalizedURL("file:///etc/passwd") == nil)
        #expect(Ingest.normalizedURL("not a link") == nil)
    }

    @Test func printedWeekdayNeedsExactlyOneDay() {
        #expect(Ingest.printedWeekday("Sat | 4.11") == 7)
        #expect(Ingest.printedWeekday("THURS 7-9 pm") == 5)
        #expect(Ingest.printedWeekday("FRIDAY SATURDAY SUNDAY OCT 9-11") == nil)
        #expect(Ingest.printedWeekday("Saturn Bar, Sunset") == nil)
        #expect(Ingest.printedWeekday("Sundays 4-6pm") == 1)
        #expect(Ingest.printedWeekday("Tuesdays and Thursdays") == nil)
    }
}

@Suite struct LocalFilterTests {
    @Test func flyerTextPasses() {
        #expect(LocalFilter.shouldSend(text: "Chess Club\nSat Nov 14 6pm", codeCount: 0))
        #expect(LocalFilter.shouldSend(text: "Self Defense at Bender Martial Arts 4.11", codeCount: 0))
    }

    @Test func aQRCodeWithSomeTextPasses() {
        #expect(LocalFilter.shouldSend(text: "Crescent Moon Fundraiser", codeCount: 1))
    }

    @Test func littleOrNoTextIsSkipped() {
        #expect(!LocalFilter.shouldSend(text: "", codeCount: 0))
        #expect(!LocalFilter.shouldSend(text: "STOP", codeCount: 1))
    }

    @Test func textWithNoDateCuesIsSkipped() {
        #expect(!LocalFilter.shouldSend(text: "Fresh coffee and pastries baked here", codeCount: 0))
    }
}

@Suite struct ClientParsingTests {
    private func reply(stop: String = "end_turn", text: String) -> Data {
        let body: [String: Any] = [
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]],
            "stop_reason": stop,
            "usage": ["input_tokens": 1000, "output_tokens": 200],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private let answer = #"{"is_event_flyer":true,"confidence":"high","reason":"r","flyer_title":"T","events":[{"name":"Chess","date_as_printed":null,"start_date":"2026-04-26","start_time":null,"end_date":null,"end_time":null,"year_inferred":false,"rrule":null,"start_uncertain":false,"location":null,"location_inferred":false,"url":null,"description":null}]}"#

    @Test func readsTheAnswerPastThinkingBlocks() throws {
        let (result, usage) = try AnthropicClient.parse(data: reply(text: answer), status: 200)
        #expect(result.events.first?.name == "Chess")
        #expect(result.flyerTitle == "T")
        #expect(usage.input == 1000)
    }

    @Test func aRefusalIsPermanent() {
        #expect(throws: ExtractionError.self) { try AnthropicClient.parse(data: reply(stop: "refusal", text: answer), status: 200) }
    }

    @Test func statusCodesMapToErrors() {
        let body = Data(#"{"error":{"message":"nope"}}"#.utf8)
        #expect(throws: ExtractionError.keyRejected) { try AnthropicClient.parse(data: body, status: 401) }
        #expect(throws: ExtractionError.temporary("nope")) { try AnthropicClient.parse(data: body, status: 529) }
        #expect(throws: ExtractionError.permanent("nope")) { try AnthropicClient.parse(data: body, status: 400) }
        let credit = Data(#"{"error":{"message":"Your credit balance is too low"}}"#.utf8)
        #expect(throws: ExtractionError.outOfCredit("Your credit balance is too low")) { try AnthropicClient.parse(data: credit, status: 400) }
    }

    @Test func theRequestCarriesTheSchemaAndNoPhotoMetadata() throws {
        let context = PhotoContext(takenOn: Day(iso: "2026-04-18")!, coordinates: (41.9, -87.6), codes: [
            DetectedCode(value: "https://a.example", xPercent: 10, yPercent: 20),
        ])
        let request = try AnthropicClient.makeRequest(jpeg: Data([1, 2, 3]), context: context, apiKey: "k")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "claude-haiku-5-5")
        let config = body["output_config"] as! [String: Any]
        #expect((config["format"] as! [String: Any])["type"] as? String == "json_schema")
        #expect(context.promptText.contains("x 10%, y 20%"))
        #expect(context.promptText.contains("41.900, -87.600"))
    }
}

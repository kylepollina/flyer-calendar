import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FlyersCore

private final class FakeCalendar: CalendarSyncing {
    var isReady = true
    var items: [String: FlyerEvent] = [:]
    var snapshots: [String: CalendarSnapshot] = [:]
    var failAdds = false
    var next = 0

    func add(_ event: FlyerEvent, alertMinutesBefore: Int) throws -> String {
        if failAdds { throw CalendarError.notReady }
        next += 1
        let id = "item\(next)"
        items[id] = event
        snapshots[id] = CalendarSnapshot(
            title: event.name, start: CalendarService.times(for: event)!.start,
            isAllDay: event.startTime == nil, location: event.location
        )
        return id
    }

    func update(_ event: FlyerEvent, itemID: String) throws { items[itemID] = event }

    var linkedItems: [String] = []
    var failLinks = false

    func addAppLink(_ event: FlyerEvent, itemID: String) throws {
        if failLinks { throw CalendarError.notReady }
        linkedItems.append(itemID)
    }

    func remove(itemID: String) throws {
        items[itemID] = nil
        snapshots[itemID] = nil
    }

    func snapshot(itemID: String) -> CalendarSnapshot? { snapshots[itemID] }
}

private struct FakePhotos: PhotoSource {
    var list: [PhotoCandidate]
    var data: Data

    func candidates(since: Date, includeScreenshots: Bool) async -> [PhotoCandidate] { list }
    func imageData(id: String) async throws -> Data { data }
}

private final class FakeExtractor: EventExtracting, @unchecked Sendable {
    var outcome: () throws -> ExtractionResult
    var calls = 0
    /// Runs during a request, to act while a scan is in progress.
    var onCall: (@MainActor @Sendable () -> Void)?

    init(_ outcome: @escaping () throws -> ExtractionResult) { self.outcome = outcome }

    func extract(jpeg: Data, context: PhotoContext, apiKey: String) async throws -> (ExtractionResult, TokenUsage) {
        calls += 1
        if let onCall { await onCall() }
        return (try outcome(), TokenUsage(input: 3000, output: 400))
    }
}

/// A QR-free image that Vision reads as flyer text.
private func textImage() -> Data {
    let context = CGContext(
        data: nil, width: 1000, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1000, height: 400))
    let line = NSAttributedStringMaker.make("Chess Club Sat Nov 14 at 6pm")
    let ctLine = CTLineCreateWithAttributedString(line)
    context.textPosition = CGPoint(x: 40, y: 180)
    CTLineDraw(ctLine, context)
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

import CoreText

private enum NSAttributedStringMaker {
    static func make(_ text: String) -> CFAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        return CFAttributedStringCreate(nil, text as CFString, [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ] as CFDictionary)!
    }
}

@MainActor
private func makeEngine(
    photos: [String] = ["p1"], calendar: FakeCalendar = FakeCalendar(), extractor: FakeExtractor,
    key: String? = "k", setup: (inout AppSettings) -> Void = { _ in }
) -> (FlyersEngine, DocumentStore) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flyers-\(UUID())", isDirectory: true)
    let store = DocumentStore(directory: directory)
    var document = AppDocument()
    setup(&document.settings)
    let candidates = photos.map { PhotoCandidate(id: $0, takenAt: Date()) }
    let engine = FlyersEngine(
        store: store, photos: FakePhotos(list: candidates, data: textImage()), extractor: extractor,
        calendar: calendar, apiKey: { key }, document: document
    )
    return (engine, store)
}

private let future = Day.today.adding(days: 10)

private func flyer(_ name: String = "Chess") -> ExtractionResult {
    ExtractionResult(isEventFlyer: true, flyerTitle: "Club", events: [ExtractedEvent(name: name, startDate: future.iso, startTime: "18:00")])
}

@MainActor @Suite struct EngineTests {
    @Test func aFlyerEndsUpOnTheCalendarAndCostsMoney() async {
        let calendar = FakeCalendar()
        let (engine, _) = makeEngine(calendar: calendar, extractor: FakeExtractor { flyer() })
        await engine.scan()
        #expect(engine.document.events.first?.state == .onCalendar)
        #expect(calendar.items.count == 1)
        #expect(engine.spendThisMonth > 0)
        #expect(engine.document.photos["p1"]?.status == .extracted)
        #expect(engine.document.lastScanSummary == "1 new event")
    }

    @Test func noKeyMeansNoScanAndAClearMessage() async {
        let extractor = FakeExtractor { flyer() }
        let (engine, _) = makeEngine(extractor: extractor, key: nil)
        await engine.scan()
        #expect(extractor.calls == 0)
        #expect(engine.alertMessage?.contains("API key") == true)
    }

    @Test func processedPhotosAreNeverPaidForTwice() async {
        let extractor = FakeExtractor { flyer() }
        let (engine, _) = makeEngine(extractor: extractor)
        await engine.scan()
        await engine.scan()
        #expect(extractor.calls == 1)
    }

    @Test func aRejectedKeyStopsTheScanAndRetriesLater() async {
        let extractor = FakeExtractor { throw ExtractionError.keyRejected }
        let (engine, _) = makeEngine(photos: ["p1", "p2"], extractor: extractor)
        await engine.scan()
        #expect(extractor.calls == 1)
        #expect(engine.document.photos.isEmpty)
        #expect(engine.alertMessage?.contains("rejected") == true)
    }

    @Test func temporaryFailuresRetryOnlyThreeTimes() async {
        let extractor = FakeExtractor { throw ExtractionError.temporary("busy") }
        let (engine, _) = makeEngine(extractor: extractor)
        for _ in 0..<5 { await engine.scan() }
        #expect(extractor.calls == 3)
        #expect(engine.document.photos["p1"]?.status == .failed)
    }

    @Test func permanentFailuresDontRetry() async {
        let extractor = FakeExtractor { throw ExtractionError.permanent("refused") }
        let (engine, _) = makeEngine(extractor: extractor)
        await engine.scan()
        await engine.scan()
        #expect(extractor.calls == 1)
    }

    @Test func theSpendLimitStopsAPICalls() async {
        let extractor = FakeExtractor { flyer() }
        let (engine, _) = makeEngine(extractor: extractor) { $0.monthlySpendLimit = 0 }
        await engine.scan()
        #expect(extractor.calls == 0)
        #expect(engine.alertMessage?.contains("spending limit") == true)
        #expect(engine.document.photos.isEmpty)
    }

    @Test func existingEventsGetAnAppLinkOnlyOnce() async {
        let calendar = FakeCalendar()
        let (engine, _) = makeEngine(calendar: calendar, extractor: FakeExtractor { flyer() })
        await engine.scan()
        engine.addAppLinksIfNeeded()
        engine.addAppLinksIfNeeded()
        #expect(calendar.linkedItems.count == 1)
        #expect(engine.document.appLinksAdded == true)
    }

    @Test func aFailedAppLinkIsRetriedLater() async {
        let calendar = FakeCalendar()
        let (engine, _) = makeEngine(calendar: calendar, extractor: FakeExtractor { flyer() })
        await engine.scan()
        calendar.failLinks = true
        engine.addAppLinksIfNeeded()
        #expect(engine.document.appLinksAdded == nil)
        calendar.failLinks = false
        engine.addAppLinksIfNeeded()
        #expect(calendar.linkedItems.count == 1)
    }

    @Test func linksFindLiveEventsButNotDeletedOnes() async {
        let (engine, _) = makeEngine(extractor: FakeExtractor { flyer() })
        await engine.scan()
        let id = engine.document.events[0].id
        #expect(engine.eventForLink(AppLink.url(for: id))?.id == id)
        engine.delete([id])
        #expect(engine.eventForLink(AppLink.url(for: id)) == nil)
    }

    @Test func stoppingEndsTheScanAfterTheCurrentPhoto() async {
        let extractor = FakeExtractor { flyer() }
        let (engine, _) = makeEngine(photos: ["p1", "p2", "p3"], extractor: extractor)
        extractor.onCall = { engine.stopScan() }
        await engine.scan()
        #expect(extractor.calls == 1)
        #expect(engine.document.photos["p1"]?.status == .extracted)
        #expect(engine.document.photos["p2"] == nil)
        #expect(!engine.isScanning)
        #expect(!engine.isStopping)
        #expect(engine.isPaused)
    }

    @Test func automaticScansRespectAPauseAndManualOnesClearIt() async {
        let extractor = FakeExtractor { flyer() }
        let (engine, store) = makeEngine(photos: ["p1", "p2", "p3"], extractor: extractor)
        extractor.onCall = { engine.stopScan() }
        await engine.scan()
        extractor.onCall = nil

        await engine.scan(manual: false)
        #expect(extractor.calls == 1)
        #expect(store.load().scanPaused == true)

        await engine.scan()
        #expect(extractor.calls == 3)
        #expect(!engine.isPaused)
    }

    @Test func stoppingWhenNotScanningDoesNothing() {
        let (engine, _) = makeEngine(extractor: FakeExtractor { flyer() })
        engine.stopScan()
        #expect(!engine.isPaused)
        #expect(!engine.isStopping)
    }

    @Test func changingTheStartDateMidScanSkipsTheRest() async {
        let extractor = FakeExtractor { flyer() }
        let (engine, _) = makeEngine(photos: ["p1", "p2", "p3"], extractor: extractor)
        extractor.onCall = { engine.updateSettings { $0.scanStartDate = Date().addingTimeInterval(3600) } }
        await engine.scan()
        #expect(extractor.calls == 1)
        // Skipped, not recorded, so moving the date back would still find them.
        #expect(engine.document.photos["p2"] == nil)
    }

    @Test func aLibrarySavedBeforePausingExistedStillLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flyers-\(UUID())", isDirectory: true)
        let store = DocumentStore(directory: directory)
        var document = AppDocument()
        document.lastScanSummary = "kept"
        try store.save(document)
        let url = directory.appendingPathComponent("library.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["scanPaused"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(store.load().lastScanSummary == "kept")
        #expect(store.load().scanPaused == nil)
    }

    @Test func aDeletedEventStaysDeletedAfterTheSameFlyerIsSeenAgain() async {
        let calendar = FakeCalendar()
        let (engine, _) = makeEngine(photos: ["p1"], calendar: calendar, extractor: FakeExtractor { flyer() })
        await engine.scan()
        let id = engine.document.events[0].id
        engine.delete([id])
        #expect(calendar.items.isEmpty)
        #expect(engine.event(id: id)?.state == .deleted)
        #expect(engine.visibleEvents.isEmpty)

        // A second photo of the same flyer.
        let photos = FakePhotos(list: [PhotoCandidate(id: "p2", takenAt: Date())], data: textImage())
        let second = FlyersEngine(
            store: engine.store, photos: photos, extractor: FakeExtractor { flyer() }, calendar: calendar,
            apiKey: { "k" }, document: engine.document
        )
        await second.scan()
        #expect(second.visibleEvents.isEmpty)
        #expect(calendar.items.isEmpty)
    }

    @Test func undoPutsTheEventBack() async {
        let calendar = FakeCalendar()
        let (engine, _) = makeEngine(calendar: calendar, extractor: FakeExtractor { flyer() })
        await engine.scan()
        let id = engine.document.events[0].id
        engine.delete([id])
        engine.undoDelete()
        #expect(engine.event(id: id)?.state == .onCalendar)
        #expect(calendar.items.count == 1)
        #expect(engine.lastDeletedIDs.isEmpty)
    }

    @Test func eventsWaitWhenNoCalendarIsChosen() async {
        let calendar = FakeCalendar()
        calendar.isReady = false
        let (engine, _) = makeEngine(calendar: calendar, extractor: FakeExtractor { flyer() })
        await engine.scan()
        #expect(engine.document.events.first?.state == .queued)
        calendar.isReady = true
        engine.flushQueue()
        #expect(engine.document.events.first?.state == .onCalendar)
    }

    @Test func aFailedAddGoesToReviewWithTheReason() async {
        let calendar = FakeCalendar()
        calendar.failAdds = true
        let (engine, _) = makeEngine(calendar: calendar, extractor: FakeExtractor { flyer() })
        await engine.scan()
        #expect(engine.document.events.first?.state == .needsReview)
        #expect(engine.document.events.first?.problems.first?.contains("Couldn't add") == true)
    }

    @Test func deletingInCalendarIsRespected() async {
        let calendar = FakeCalendar()
        let (engine, _) = makeEngine(calendar: calendar, extractor: FakeExtractor { flyer() })
        await engine.scan()
        calendar.snapshots.removeAll()
        engine.reconcileWithCalendar()
        #expect(engine.document.events.first?.state == .removedInCalendar)
    }

    @Test func editsInCalendarWin() async {
        let calendar = FakeCalendar()
        let (engine, _) = makeEngine(calendar: calendar, extractor: FakeExtractor { flyer() })
        await engine.scan()
        let itemID = engine.document.events[0].calendarItemID!
        let moved = future.adding(days: 1)
        calendar.snapshots[itemID] = CalendarSnapshot(
            title: "Renamed", start: moved.date().addingTimeInterval(19 * 3600), isAllDay: false, location: "Library"
        )
        engine.reconcileWithCalendar()
        let event = engine.document.events[0]
        #expect(event.name == "Renamed")
        #expect(event.location == "Library")
        #expect(event.startDay == moved)
        #expect(event.startTime == "19:00")
    }

    @Test func editsInTheAppReachCalendarAndKeepTheFingerprint() async {
        let calendar = FakeCalendar()
        let (engine, _) = makeEngine(calendar: calendar, extractor: FakeExtractor { flyer() })
        await engine.scan()
        let id = engine.document.events[0].id
        let original = engine.document.events[0].fingerprint
        engine.edit(id) { $0.name = "Better name" }
        #expect(calendar.items.values.first?.name == "Better name")
        #expect(engine.event(id: id)?.fingerprint == original)
    }

    @Test func approvingFromReviewAddsToTheCalendar() async {
        let calendar = FakeCalendar()
        let (engine, _) = makeEngine(calendar: calendar, extractor: FakeExtractor { flyer() }) { $0.addMode = .review }
        await engine.scan()
        let id = engine.document.events[0].id
        #expect(calendar.items.isEmpty)
        engine.addToCalendar(id)
        #expect(calendar.items.count == 1)
        #expect(engine.event(id: id)?.state == .onCalendar)
    }

    @Test func theLibrarySurvivesARestart() async {
        let (engine, store) = makeEngine(extractor: FakeExtractor { flyer() })
        await engine.scan()
        let reloaded = store.load()
        #expect(reloaded.events == engine.document.events)
        #expect(reloaded.spend == engine.document.spend)
        #expect(reloaded.photos["p1"]?.status == .extracted)
    }

    @Test func anUnreadableLibraryIsSetAsideNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flyers-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("library.json"))
        let store = DocumentStore(directory: directory)
        #expect(store.load().events.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("library.unreadable") })
    }
}

@Suite struct AppLinkTests {
    @Test func aLinkRoundTrips() {
        let id = UUID()
        #expect(AppLink.eventID(from: AppLink.url(for: id)) == id)
    }

    @Test(arguments: [
        "https://event/00000000-0000-0000-0000-000000000001",
        "flyers://delete/00000000-0000-0000-0000-000000000001",
        "flyers://event/not-a-uuid",
        "flyers://event/00000000-0000-0000-0000-000000000001/extra",
        "flyers://event",
    ])
    func otherLinksAreIgnored(text: String) {
        #expect(AppLink.eventID(from: URL(string: text)!) == nil)
    }
}

@Suite struct CalendarMappingTests {
    private func event(
        start: String = "2026-04-26", time: String? = "18:00", endDay: String? = nil, endTime: String? = nil
    ) -> FlyerEvent {
        FlyerEvent(
            id: UUID(), flyerID: UUID(), name: "E", datePrinted: nil, startDay: Day(iso: start), startTime: time,
            endDay: endDay.flatMap(Day.init(iso:)), endTime: endTime, rrule: nil, yearInferred: false,
            startUncertain: false, location: nil, locationInferred: false, url: nil, details: nil, state: .queued,
            stateBeforeDelete: nil, calendarItemID: nil, fingerprint: "f", problems: []
        )
    }

    @Test func noTimeMeansAllDayAcrossTheWholeSpan() {
        let times = CalendarService.times(for: event(start: "2026-10-09", time: nil, endDay: "2026-10-11"))!
        #expect(times.isAllDay)
        #expect(Day(date: times.end) == Day(iso: "2026-10-11"))
    }

    @Test func noEndTimeGetsANominalHour() {
        let times = CalendarService.times(for: event())!
        #expect(times.end.timeIntervalSince(times.start) == 3600)
    }

    @Test func anEndBeforeTheStartMeansTheNextDay() {
        let times = CalendarService.times(for: event(time: "21:00", endTime: "01:00"))!
        #expect(times.end.timeIntervalSince(times.start) == 4 * 3600)
    }

    @Test func rulesMapToEventKit() throws {
        let rule = CalendarService.makeRule(try Recurrence(rrule: "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;UNTIL=20261231"))
        #expect(rule.frequency == .monthly)
        #expect(rule.interval == 2)
        #expect(rule.daysOfTheWeek?.first?.dayOfTheWeek == .friday)
        #expect(rule.daysOfTheWeek?.first?.weekNumber == -1)
        #expect(rule.recurrenceEnd?.endDate != nil)
    }

    @Test func countsMapToEventKit() throws {
        let rule = CalendarService.makeRule(try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4"))
        #expect(rule.daysOfTheWeek?.count == 2)
        #expect(rule.recurrenceEnd?.occurrenceCount == 4)
    }
}

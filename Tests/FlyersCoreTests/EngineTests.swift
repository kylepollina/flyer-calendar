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

private final class FakePhotos: PhotoSource, @unchecked Sendable {
    var list: [PhotoCandidate]
    var data: Data
    var deleted: [[String]] = []
    /// What Photos' confirmation answers.
    var allowDelete = true

    init(list: [PhotoCandidate], data: Data) {
        self.list = list
        self.data = data
    }

    func candidates(since: Date, includeScreenshots: Bool) async -> [PhotoCandidate] { list }
    func imageData(id: String) async throws -> Data { data }
    func delete(ids: [String]) async throws -> Bool {
        guard allowDelete else { return false }
        deleted.append(ids)
        return true
    }
}

private final class FakeExtractor: EventExtracting, @unchecked Sendable {
    var outcome: () throws -> ExtractionResult
    var calls = 0
    /// How many photos each request carried.
    var photoCounts: [Int] = []
    /// Runs during a request, to act while a scan is in progress.
    var onCall: (@MainActor @Sendable () -> Void)?

    init(_ outcome: @escaping () throws -> ExtractionResult) { self.outcome = outcome }

    func extract(jpegs: [Data], context: PhotoContext, apiKey: String) async throws -> (ExtractionResult, TokenUsage) {
        calls += 1
        photoCounts.append(jpegs.count)
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
    photos: [String] = ["p1"], secondsApart: TimeInterval = 600, calendar: FakeCalendar = FakeCalendar(),
    extractor: FakeExtractor, key: String? = "k", photoSource: ((FakePhotos) -> Void)? = nil,
    setup: (inout AppSettings) -> Void = { _ in }
) -> (FlyersEngine, DocumentStore) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flyers-\(UUID())", isDirectory: true)
    let store = DocumentStore(directory: directory)
    var document = AppDocument()
    setup(&document.settings)
    // Ten minutes apart by default, so each photo is read on its own.
    let start = Date()
    let candidates = photos.enumerated().map { index, id in
        PhotoCandidate(id: id, takenAt: start.addingTimeInterval(Double(index) * secondsApart))
    }
    let fake = FakePhotos(list: candidates, data: textImage())
    photoSource?(fake)
    let engine = FlyersEngine(
        store: store, photos: fake, extractor: extractor,
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

    @Test func photosTakenMomentsApartAreReadInOneRequest() async {
        let extractor = FakeExtractor { flyer() }
        let (engine, _) = makeEngine(photos: ["p1", "p2", "p3"], secondsApart: 30, extractor: extractor)
        await engine.scan()
        #expect(extractor.photoCounts == [3])
        #expect(engine.document.photos.values.allSatisfy { $0.status == .extracted })
        #expect(engine.document.flyers.first?.assetID == "p1")
        #expect(engine.document.flyers.first?.assetIDs == ["p1", "p2", "p3"])
        #expect(engine.document.lastScanSummary == "1 new event")
    }

    @Test func aFailedGroupRecordsEveryPhoto() async {
        let extractor = FakeExtractor { throw ExtractionError.permanent("refused") }
        let (engine, _) = makeEngine(photos: ["p1", "p2"], secondsApart: 30, extractor: extractor)
        await engine.scan()
        #expect(engine.document.lastScanSummary == "0 new events, 2 couldn't be read")
        await engine.scan()
        #expect(extractor.calls == 1)
        #expect(engine.document.photos["p2"]?.status == .failed)
    }

    @Test func scheduledScansWaitForABurstToFinish() async {
        let extractor = FakeExtractor { flyer() }
        // Taken just now, so another screenshot may still be coming.
        let (engine, _) = makeEngine(photos: ["p1", "p2"], secondsApart: 30, extractor: extractor)
        await engine.scan(manual: false)
        #expect(extractor.calls == 0)
        #expect(engine.document.photos.isEmpty)
        await engine.scan()
        #expect(extractor.photoCounts == [2])
    }

    @Test func thePhotoIsOfferedOnlyWithItsLastEvent() async {
        let extractor = FakeExtractor {
            ExtractionResult(isEventFlyer: true, events: [
                ExtractedEvent(name: "Chess", startDate: future.iso), ExtractedEvent(name: "Go", startDate: future.iso),
            ])
        }
        let (engine, _) = makeEngine(photos: ["p1", "p2"], secondsApart: 30, extractor: extractor)
        await engine.scan()
        let ids = engine.document.events.map(\.id)
        #expect(engine.flyersOnlyUsedBy([ids[0]]).isEmpty)
        #expect(engine.flyersOnlyUsedBy(ids).map(\.allAssetIDs) == [["p1", "p2"]])
        engine.delete([ids[0]])
        #expect(engine.flyersOnlyUsedBy([ids[1]]).count == 1)
    }

    @Test func aFlyersPhotoIsSavedHereThenRemovedFromPhotos() async throws {
        var fake: FakePhotos!
        let (engine, store) = makeEngine(extractor: FakeExtractor { flyer() }, photoSource: { fake = $0 })
        await engine.scan()
        let saved = try #require(engine.document.flyers.first)
        #expect(saved.photoFiles?.count == 1)
        #expect(FileManager.default.fileExists(atPath: store.photoURL(saved.photoFiles![0]).path))
        #expect(fake.deleted == [["p1"]])
        #expect(saved.photosInLibrary == false)
    }

    @Test func photosThatArentFlyersStayInPhotos() async {
        var fake: FakePhotos!
        let (engine, _) = makeEngine(extractor: FakeExtractor { ExtractionResult(isEventFlyer: false) }, photoSource: { fake = $0 })
        await engine.scan()
        #expect(fake.deleted.isEmpty)
        #expect(engine.savedPhotoNames.isEmpty)
    }

    @Test func onlyThePhotosShowingTheFlyerAreSavedAndRemoved() async {
        var fake: FakePhotos!
        let extractor = FakeExtractor {
            var result = flyer()
            result.photosUsed = [1, 3]
            return result
        }
        let (engine, _) = makeEngine(photos: ["p1", "p2", "p3"], secondsApart: 30, extractor: extractor, photoSource: { fake = $0 })
        await engine.scan()
        #expect(engine.document.flyers.first?.allAssetIDs == ["p1", "p3"])
        #expect(engine.document.flyers.first?.photoFiles?.count == 2)
        #expect(fake.deleted == [["p1", "p3"]])
    }

    @Test func decliningInPhotosKeepsTheOriginalThere() async {
        let (engine, _) = makeEngine(extractor: FakeExtractor { flyer() }, photoSource: { $0.allowDelete = false })
        await engine.scan()
        #expect(engine.document.flyers.first?.photoFiles?.count == 1)
        #expect(engine.document.flyers.first?.mayBeInLibrary == true)
        #expect(engine.alertMessage == nil)
        #expect(engine.flyersOnlyInLibrary.isEmpty)
    }

    @Test func withTheSettingOffPhotosStayInPhotos() async {
        var fake: FakePhotos!
        let (engine, _) = makeEngine(extractor: FakeExtractor { flyer() }, photoSource: { fake = $0 }) {
            $0.removesPhotosFromLibrary = false
        }
        await engine.scan()
        #expect(fake.deleted.isEmpty)
        #expect(engine.document.flyers.first?.photoFiles?.count == 1)
    }

    @Test func olderFlyersCanBeMovedIntoFlyers() async {
        var fake: FakePhotos!
        let (engine, _) = makeEngine(extractor: FakeExtractor { flyer() }, photoSource: { fake = $0 }) {
            $0.removesPhotosFromLibrary = false
        }
        await engine.scan()
        engine.deleteSavedPhotos(of: engine.document.flyers.map(\.id))
        #expect(engine.flyersOnlyInLibrary.count == 1)
        #expect(await engine.moveOlderPhotosIntoFlyers() == 1)
        #expect(engine.flyersOnlyInLibrary.isEmpty)
        #expect(engine.document.flyers.first?.photoFiles?.count == 1)
        #expect(fake.deleted == [["p1"]])
    }

    @Test func savedPhotosOfPastEventsCanBeCleared() async throws {
        let (engine, store) = makeEngine(extractor: FakeExtractor { flyer() })
        await engine.scan()
        #expect(engine.flyersWithOnlyPastEvents().isEmpty)
        let later = future.adding(days: 1)
        let past = engine.flyersWithOnlyPastEvents(today: later)
        #expect(past.count == 1)
        let name = try #require(past.first?.photoFiles?.first)
        engine.deleteSavedPhotos(of: past.map(\.id))
        #expect(engine.savedPhotoNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.photoURL(name).path))
    }

    @Test func theFlyerKeepsWhereThePhotoWasTaken() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flyers-\(UUID())", isDirectory: true)
        let photos = FakePhotos(list: [PhotoCandidate(id: "p1", takenAt: Date(), latitude: 41.9, longitude: -87.6)], data: textImage())
        let engine = FlyersEngine(
            store: DocumentStore(directory: directory), photos: photos, extractor: FakeExtractor { flyer() },
            calendar: FakeCalendar(), apiKey: { "k" }
        )
        await engine.scan()
        #expect(engine.document.flyers.first?.latitude == 41.9)
        #expect(engine.document.flyers.first?.longitude == -87.6)
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

@Suite struct PhotoGroupingTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func photos(_ offsets: [TimeInterval]) -> [PhotoCandidate] {
        offsets.enumerated().map { PhotoCandidate(id: "p\($0.offset)", takenAt: start.addingTimeInterval($0.element)) }
    }

    @Test func aChainOfCloseShotsIsOneGroupEvenPastTwoMinutesInAll() {
        // Each is within two minutes of the one before, as when scrolling slowly through a post.
        let groups = PhotoGrouping.groups(photos([0, 90, 180, 270]))
        #expect(groups.map(\.count) == [4])
    }

    @Test func aLongerGapStartsANewGroup() {
        let groups = PhotoGrouping.groups(photos([0, 60, 600, 650, 2000]))
        #expect(groups.map { $0.map(\.id) } == [["p0", "p1"], ["p2", "p3"], ["p4"]])
    }

    @Test func groupsAreSortedByTimeTaken() {
        let groups = PhotoGrouping.groups(photos([60, 0]))
        #expect(groups.first?.map(\.id) == ["p1", "p0"])
    }

    @Test func aLongBurstIsSplitToKeepRequestsSmall() {
        let groups = PhotoGrouping.groups(photos((0..<11).map { Double($0) * 5 }))
        #expect(groups.map(\.count) == [PhotoGrouping.maxPhotos, 11 - PhotoGrouping.maxPhotos])
    }

    @Test func aRecentBurstMayStillGrow() {
        let group = photos([0, 30])
        #expect(PhotoGrouping.mayStillGrow(group, now: start.addingTimeInterval(60)))
        #expect(!PhotoGrouping.mayStillGrow(group, now: start.addingTimeInterval(200)))
    }

    @Test func severalPhotosAreLabeledInThePrompt() {
        let code = DetectedCode(value: "https://example.com", xPercent: 50, yPercent: 80)
        let context = PhotoContext(takenOn: Day(iso: "2026-11-12")!, coordinates: nil, codesByPhoto: [[], [code]])
        #expect(context.promptText.contains("These 2 photos"))
        #expect(context.promptText.contains("Photo 1: no QR codes"))
        #expect(context.promptText.contains("Photo 2: QR codes"))
    }
}

@Suite struct LinkAndSponsorTests {
    @Test func linksAreCleanedAndTheFirstIsTheMainOne() {
        let extracted = ExtractedEvent(name: "Tap", links: [
            EventLink(label: "Tickets", url: "tickets.example.org"),
            EventLink(label: " ", url: "https://example.org"),
            EventLink(label: "Dupe", url: "https://tickets.example.org"),
            EventLink(label: "Bad", url: "javascript:alert(1)"),
        ], sponsors: ["Herald", "  ", "Tap All-Stars"])
        let result = ExtractionResult(isEventFlyer: true, events: [extracted])
        let event = Ingest.events(
            from: result, flyerID: UUID(), takenOn: .today, today: .today, settings: AppSettings(), existingFingerprints: []
        )[0]
        #expect(event.url == "https://tickets.example.org")
        #expect(event.links == [
            EventLink(label: "Tickets", url: "https://tickets.example.org"),
            EventLink(label: "Link", url: "https://example.org"),
        ])
        #expect(event.sponsors == ["Herald", "Tap All-Stars"])
    }

    @Test func eventsSavedBeforeMultipleLinksStillShowTheirLink() {
        var event = makeEvent()
        event.url = "https://old.example"
        #expect(event.allLinks == [EventLink(label: "Link", url: "https://old.example")])
    }

    @Test func editingTheMainLinkReplacesItAndKeepsTheRest() {
        var event = makeEvent()
        event.url = "https://a.example"
        event.links = [EventLink(label: "Tickets", url: "https://a.example"), EventLink(label: "Site", url: "https://b.example")]
        event.setMainLink("https://c.example")
        #expect(event.allLinks.map(\.url) == ["https://c.example", "https://b.example"])
        #expect(event.allLinks.first?.label == "Tickets")
        event.setMainLink(nil)
        #expect(event.allLinks.map(\.url) == ["https://b.example"])
    }

    private func makeEvent() -> FlyerEvent {
        FlyerEvent(
            id: UUID(), flyerID: UUID(), name: "E", datePrinted: nil, startDay: nil, startTime: nil, endDay: nil,
            endTime: nil, rrule: nil, yearInferred: false, startUncertain: false, location: nil, locationInferred: false,
            url: nil, details: nil, state: .queued, stateBeforeDelete: nil, calendarItemID: nil, fingerprint: "f", problems: []
        )
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

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FlyersCore

// Two devices, each with its own library folder, photo IDs and Calendar item IDs, syncing through
// an in-memory cloud and sharing one iCloud calendar, as a Mac and an iPhone would.

/// iCloud Calendar: one set of events every device sees, each under its own item IDs.
private final class SharedCalendar {
    var events: [String: FlyerEvent] = [:]
    var adds = 0
}

private final class DeviceCalendar: CalendarSyncing {
    let shared: SharedCalendar
    let device: String
    init(_ shared: SharedCalendar, device: String) {
        self.shared = shared
        self.device = device
    }

    var isReady = true
    private func external(_ itemID: String) -> String { String(itemID.dropFirst(device.count + 1)) }

    func add(_ event: FlyerEvent, alertMinutesBefore: Int) throws -> String {
        shared.adds += 1
        let externalID = "ext-\(shared.adds)"
        shared.events[externalID] = event
        return "\(device)-\(externalID)"
    }

    func update(_ event: FlyerEvent, itemID: String) throws { shared.events[external(itemID)] = event }
    func addAppLink(_ event: FlyerEvent, itemID: String) throws {}
    func remove(itemID: String) throws { shared.events[external(itemID)] = nil }

    func snapshot(itemID: String) -> CalendarSnapshot? {
        guard let event = shared.events[external(itemID)], let times = CalendarService.times(for: event) else { return nil }
        return CalendarSnapshot(title: event.name, start: times.start, isAllDay: times.isAllDay, location: event.location)
    }

    func externalID(itemID: String) -> String? { shared.events[external(itemID)] == nil ? nil : external(itemID) }
    func itemID(externalID: String) -> String? { shared.events[externalID] == nil ? nil : "\(device)-\(externalID)" }
}

/// One device's view of iCloud Photos: the same photos under its own local IDs.
private final class DevicePhotos: PhotoSource, @unchecked Sendable {
    let device: String
    var cloudIDs: [String]
    var takenAt: [String: Date] = [:]
    var deleted: [[String]] = []
    let data: Data

    init(device: String, cloudIDs: [String], data: Data) {
        self.device = device
        self.cloudIDs = cloudIDs
        self.data = data
    }

    func local(_ cloud: String) -> String { "\(device)-\(cloud)" }

    func candidates(since: Date, includeScreenshots: Bool) async -> [PhotoCandidate] {
        cloudIDs.map { PhotoCandidate(id: local($0), takenAt: takenAt[$0] ?? Date()) }
    }

    func imageData(id: String) async throws -> Data { data }

    func delete(ids: [String]) async throws -> Bool {
        deleted.append(ids)
        return true
    }

    func cloudIDs(forLocal ids: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.filter { $0.hasPrefix("\(device)-") }.map { ($0, String($0.dropFirst(device.count + 1))) })
    }

    func localIDs(forCloud ids: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.filter(cloudIDs.contains).map { ($0, local($0)) })
    }
}

private final class SyncExtractor: EventExtracting, @unchecked Sendable {
    var calls = 0
    var outcome: () -> ExtractionResult
    /// Runs during a request, to act while a scan is reading a photo.
    var during: (@MainActor () async -> Void)?

    init(_ outcome: @escaping () -> ExtractionResult) { self.outcome = outcome }

    func extract(jpegs: [Data], context: PhotoContext, apiKey: String) async throws -> (ExtractionResult, TokenUsage) {
        calls += 1
        if let during { await during() }
        return (outcome(), TokenUsage(input: 3000, output: 400))
    }
}

/// The cloud: the latest version of each record.
private final class MemoryCloud {
    var records: [String: SyncRecord] = [:]
}

/// Moves records between one device and the cloud. A conflict keeps the later change.
@MainActor
private final class MemorySync: SyncConnection {
    let cloud: MemoryCloud
    weak var engine: FlyersEngine?
    var ledger = SyncLedger()
    var uploadsWork = true

    init(_ cloud: MemoryCloud) { self.cloud = cloud }

    func changed() {}

    func pushNow() async {
        guard let engine, uploadsWork else { return }
        for record in engine.outgoingSyncChanges(ledger: &ledger) {
            if let existing = cloud.records[record.name], existing.modifiedAt > record.modifiedAt { continue }
            cloud.records[record.name] = record
            ledger.settle(record)
        }
    }

    func fetchNow() async {
        guard let engine else { return }
        let incoming = cloud.records.values
            .filter { ledger.hashes[$0.name] != $0.payloadHash }
            .sorted { $0.name < $1.name }
        engine.applySyncRecords(incoming, ledger: &ledger)
    }

    func isUploaded(flyerID: UUID) -> Bool {
        let name = FlyersEngine.recordName(flyer: flyerID)
        return uploadsWork && cloud.records[name] != nil
    }
}

private func flyerImage() -> Data {
    let context = CGContext(
        data: nil, width: 1000, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1000, height: 400))
    let text = CFAttributedStringCreate(nil, "Chess Club Sat Nov 14 at 6pm" as CFString, [
        kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 64, nil),
        kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
    ] as CFDictionary)!
    context.textPosition = CGPoint(x: 40, y: 180)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

private let soon = Day.today.adding(days: 10)

private func chessFlyer() -> ExtractionResult {
    ExtractionResult(isEventFlyer: true, flyerTitle: "Club", events: [ExtractedEvent(name: "Chess", startDate: soon.iso, startTime: "18:00")])
}

@MainActor
private struct Device {
    let engine: FlyersEngine
    let sync: MemorySync
    let photos: DevicePhotos
    let extractor: SyncExtractor
}

@MainActor
private func device(
    _ name: String, cloud: MemoryCloud, calendar: SharedCalendar, photos cloudIDs: [String] = ["c1"],
    extractor: SyncExtractor = SyncExtractor(chessFlyer), image: Data
) -> Device {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flyers-sync-\(UUID())", isDirectory: true)
    let photos = DevicePhotos(device: name, cloudIDs: cloudIDs, data: image)
    let engine = FlyersEngine(
        store: DocumentStore(directory: directory), photos: photos, extractor: extractor,
        calendar: DeviceCalendar(calendar, device: name), apiKey: { "k" }, document: AppDocument(), deviceID: name
    )
    let sync = MemorySync(cloud)
    sync.engine = engine
    engine.sync = sync
    return Device(engine: engine, sync: sync, photos: photos, extractor: extractor)
}

@MainActor @Suite struct SyncTests {
    private let image = flyerImage()

    @Test func aFlyerFoundOnOneDeviceShowsUpOnTheOtherOnceOnTheCalendar() async throws {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let mac = device("mac", cloud: cloud, calendar: calendar, image: image)
        let phone = device("phone", cloud: cloud, calendar: calendar, photos: [], image: image)

        await mac.engine.scan()
        await mac.sync.pushNow()
        await phone.sync.fetchNow()

        let event = try #require(phone.engine.document.events.first)
        #expect(event.name == "Chess")
        #expect(event.state == .onCalendar)
        #expect(event.ownerDevice == "mac")
        // The phone has the flyer and its photo, saved under the same file names.
        let flyer = try #require(phone.engine.flyer(id: event.flyerID))
        let file = try #require(flyer.photoFiles?.first)
        #expect(FileManager.default.fileExists(atPath: phone.engine.store.photoURL(file).path))
        // Only the device that found it added it to Calendar.
        phone.engine.flushQueue()
        #expect(calendar.adds == 1)
    }

    @Test func onlyTheDeviceThatFoundAnEventAddsItToTheCalendar() async throws {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let mac = device("mac", cloud: cloud, calendar: calendar, image: image)
        let phone = device("phone", cloud: cloud, calendar: calendar, photos: [], image: image)
        // The Mac has no calendar chosen yet, so its event waits.
        (mac.engine.calendar as! DeviceCalendar).isReady = false
        await mac.engine.scan()
        await mac.sync.pushNow()
        await phone.sync.fetchNow()
        #expect(phone.engine.document.events.first?.state == .queued)
        phone.engine.flushQueue()
        #expect(calendar.adds == 0)

        (mac.engine.calendar as! DeviceCalendar).isReady = true
        mac.engine.flushQueue()
        #expect(calendar.adds == 1)
        await mac.sync.pushNow()
        await phone.sync.fetchNow()
        #expect(phone.engine.document.events.first?.state == .onCalendar)
    }

    @Test func addingOnTheOtherDeviceMakesItTheOwner() async throws {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let mac = device("mac", cloud: cloud, calendar: calendar, image: image)
        let phone = device("phone", cloud: cloud, calendar: calendar, photos: [], image: image)
        await mac.engine.scan()
        await mac.sync.pushNow()
        await phone.sync.fetchNow()
        let id = try #require(phone.engine.document.events.first?.id)
        phone.engine.removeFromCalendar(id)
        #expect(calendar.events.isEmpty)

        phone.engine.addToCalendar(id)
        #expect(calendar.events.count == 1)
        #expect(phone.engine.event(id: id)?.ownerDevice == "phone")
        await phone.sync.pushNow()
        await mac.sync.fetchNow()
        mac.engine.flushQueue()
        #expect(calendar.adds == 2)
    }

    @Test func aPhotoReadOnOneDeviceIsNeverPaidForOnTheOther() async {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let mac = device("mac", cloud: cloud, calendar: calendar, image: image)
        let phone = device("phone", cloud: cloud, calendar: calendar, image: image)

        await mac.engine.scan()
        await mac.sync.pushNow()
        await phone.engine.scan()

        #expect(mac.extractor.calls == 1)
        #expect(phone.extractor.calls == 0)
        #expect(phone.engine.document.photos["phone-c1"]?.status == .extracted)
        #expect(phone.engine.visibleEvents.count == 1)
    }

    @Test func aPhotoBeingReadElsewhereIsLeftAloneUntilItsClaimRunsOut() async {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let phone = device("phone", cloud: cloud, calendar: calendar, image: image)
        let mac = device("mac", cloud: cloud, calendar: calendar, image: image)
        // While the Mac is reading the photo, the phone opens and scans.
        mac.extractor.during = { await phone.engine.scan() }

        await mac.engine.scan()
        #expect(phone.extractor.calls == 0)
        #expect(mac.extractor.calls == 1)
    }

    @Test func anAbandonedClaimIsPickedUp() async {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let mac = device("mac", cloud: cloud, calendar: calendar, image: image)
        let phone = device("phone", cloud: cloud, calendar: calendar, image: image)
        // The Mac claimed the photo long ago and never finished, as if it quit mid-scan.
        let stale = PhotoRecord(
            status: .claimed, attempts: 0, processedAt: Date().addingTimeInterval(-FlyersEngine.claimTimeout - 60),
            cloudID: "c1", claimedBy: "mac"
        )
        let payload = try! SyncCoding.encoder.encode(stale)
        cloud.records["photo-c1"] = SyncRecord(name: "photo-c1", kind: .photo, modifiedAt: Date().addingTimeInterval(-700), payload: payload)
        _ = mac

        await phone.engine.scan()
        #expect(phone.extractor.calls == 1)
    }

    @Test func deletingOnTheOtherDeviceTakesItOffTheCalendarToo() async throws {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let mac = device("mac", cloud: cloud, calendar: calendar, image: image)
        let phone = device("phone", cloud: cloud, calendar: calendar, photos: [], image: image)
        await mac.engine.scan()
        await mac.sync.pushNow()
        await phone.sync.fetchNow()
        let id = try #require(phone.engine.document.events.first?.id)

        phone.engine.delete([id])
        #expect(calendar.events.isEmpty)
        await phone.sync.pushNow()
        await mac.sync.fetchNow()
        #expect(mac.engine.event(id: id)?.state == .deleted)
        #expect(mac.engine.visibleEvents.isEmpty)
    }

    @Test func anEditOnTheOtherDeviceSticks() async throws {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let mac = device("mac", cloud: cloud, calendar: calendar, image: image)
        let phone = device("phone", cloud: cloud, calendar: calendar, photos: [], image: image)
        await mac.engine.scan()
        await mac.sync.pushNow()
        await phone.sync.fetchNow()
        let id = try #require(phone.engine.document.events.first?.id)

        phone.engine.edit(id) { $0.name = "Chess night" }
        #expect(calendar.events.values.first?.name == "Chess night")
        await phone.sync.pushNow()
        await mac.sync.fetchNow()
        // The Mac owns the event, and reading Calendar back agrees with the edit.
        mac.engine.reconcileWithCalendar()
        #expect(mac.engine.event(id: id)?.name == "Chess night")
        await mac.sync.pushNow()
        await phone.sync.fetchNow()
        #expect(phone.engine.event(id: id)?.name == "Chess night")
    }

    @Test func theLaterChangeWins() async throws {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let mac = device("mac", cloud: cloud, calendar: calendar, image: image)
        let phone = device("phone", cloud: cloud, calendar: calendar, photos: [], image: image)
        await mac.engine.scan()
        await mac.sync.pushNow()
        await phone.sync.fetchNow()
        let id = try #require(phone.engine.document.events.first?.id)

        mac.engine.edit(id) { $0.details = "From the Mac" }
        var macChanges = mac.engine.outgoingSyncChanges(ledger: &mac.sync.ledger, now: Date())
        phone.engine.edit(id) { $0.details = "From the phone" }
        await phone.sync.pushNow()
        // The Mac's older change arrives after the phone's newer one, and loses.
        for index in macChanges.indices { macChanges[index].modifiedAt = Date().addingTimeInterval(-60) }
        for record in macChanges where (cloud.records[record.name]?.modifiedAt ?? .distantPast) <= record.modifiedAt {
            cloud.records[record.name] = record
        }
        await mac.sync.fetchNow()
        #expect(mac.engine.event(id: id)?.details == "From the phone")
    }

    @Test func settingsSyncButTheChosenCalendarStaysOnEachDevice() async {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let mac = device("mac", cloud: cloud, calendar: calendar, photos: [], image: image)
        let phone = device("phone", cloud: cloud, calendar: calendar, photos: [], image: image)
        phone.engine.updateSettings { $0.calendarID = "phone-calendar" }
        await phone.sync.pushNow()

        mac.engine.updateSettings {
            $0.addMode = .review
            $0.alertMinutesBefore = 60
            $0.calendarID = "mac-calendar"
        }
        await mac.sync.pushNow()
        await phone.sync.fetchNow()
        #expect(phone.engine.document.settings.addMode == .review)
        #expect(phone.engine.document.settings.alertMinutesBefore == 60)
        #expect(phone.engine.document.settings.calendarID == "phone-calendar")
    }

    @Test func photosStayInPhotosUntilTheirCopyIsInICloud() async {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let mac = device("mac", cloud: cloud, calendar: calendar, image: image)
        mac.sync.uploadsWork = false
        await mac.engine.scan()
        #expect(mac.photos.deleted.isEmpty)

        let other = device("mac2", cloud: MemoryCloud(), calendar: SharedCalendar(), image: image)
        await other.engine.scan()
        #expect(other.photos.deleted == [["mac2-c1"]])
    }

    @Test func unchangedRecordsDontTravelAgain() async {
        let cloud = MemoryCloud(), calendar = SharedCalendar()
        let mac = device("mac", cloud: cloud, calendar: calendar, image: image)
        let phone = device("phone", cloud: cloud, calendar: calendar, photos: [], image: image)
        await mac.engine.scan()
        await mac.sync.pushNow()
        await phone.sync.fetchNow()
        #expect(mac.engine.outgoingSyncChanges(ledger: &mac.sync.ledger).isEmpty)
        #expect(phone.engine.outgoingSyncChanges(ledger: &phone.sync.ledger).isEmpty)
    }
}

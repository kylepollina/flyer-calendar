import FlyersCore
import SwiftUI
import UIKit

@main
struct FlyersPhoneApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            EventListView(model: model, engine: model.engine)
                .task { await model.opened() }
                .onChange(of: scenePhase) {
                    if scenePhase == .active { Task { await model.opened() } }
                }
        }
    }
}

/// Connects the engine to the phone: permissions, the API key and scanning when the app opens.
@MainActor
final class PhoneModel: ObservableObject {
    let engine: FlyersEngine
    let calendarService: CalendarService
    /// Sync with your other devices, in builds signed for iCloud.
    let cloudSync: CloudSync?
    let isDemo: Bool
    @Published var hasAPIKey: Bool
    @Published var hasPhotoAccess: Bool
    @Published var hasCalendarAccess: Bool
    /// Flyers left with no events after a delete, waiting for you to choose whether to delete their photos.
    @Published var orphanedFlyers: [Flyer] = []
    /// Shows first-run setup. You can close it and come back from Settings.
    @Published var isShowingSetup = false
    /// Off until this iPhone and your Mac share what they've scanned. With both scanning the same
    /// iCloud library on their own, each photo would be paid for and added to Calendar twice.
    @Published var scansHere: Bool {
        didSet { UserDefaults.standard.set(scansHere, forKey: PhoneModel.scansHereKey) }
    }

    private static let scansHereKey = "scansOnThisDevice"

    init() {
        let demo = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--demo-setup")
        isDemo = demo
        scansHere = UserDefaults.standard.bool(forKey: PhoneModel.scansHereKey)
        if demo {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flyers-demo-\(UUID())", isDirectory: true)
            let store = DocumentStore(directory: directory)
            calendarService = CalendarService(calendarID: nil)
            cloudSync = nil
            engine = FlyersEngine(
                store: store, photos: PhotoLibrary(), extractor: AnthropicClient(), calendar: DemoCalendar(),
                apiKey: { nil }, document: PhoneDemo.document(store: store)
            )
            // --demo-setup shows first-run setup over the demo, as if nothing were allowed yet.
            let previewSetup = CommandLine.arguments.contains("--demo-setup")
            hasAPIKey = !previewSetup
            hasPhotoAccess = !previewSetup
            hasCalendarAccess = !previewSetup
            isShowingSetup = previewSetup
            return
        }
        let store = DocumentStore(directory: DocumentStore.defaultDirectory)
        let document = store.load()
        let service = CalendarService(calendarID: document.settings.calendarID)
        calendarService = service
        let engine = FlyersEngine(
            store: store, photos: PhotoLibrary(), extractor: AnthropicClient(), calendar: service,
            apiKey: { APIKeyStore.read() }, document: document
        )
        self.engine = engine
        cloudSync = CloudSync.containerIDFromInfo.map { CloudSync(engine: engine, containerID: $0) }
        // CloudKit tells the sync engine about changes from your other devices with a silent push.
        if cloudSync != nil { UIApplication.shared.registerForRemoteNotifications() }
        hasAPIKey = APIKeyStore.read() != nil
        hasPhotoAccess = PhotoLibrary.isAuthorized
        hasCalendarAccess = CalendarService.hasAccess
        // Saves the scan start date, so photos taken before the first launch stay out of it.
        engine.updateSettings { _ in }
        isShowingSetup = !isSetUp
    }

    /// Everything Flyers needs before it can put flyers on your calendar.
    var isSetUp: Bool {
        hasAPIKey && hasPhotoAccess && hasCalendarAccess && (isDemo || engine.document.settings.calendarID != nil)
    }

    /// Deletes events, then offers to delete photos they were the last events from.
    func delete(_ ids: [UUID]) {
        let flyers = engine.flyersOnlyUsedBy(ids)
        engine.delete(ids)
        orphanedFlyers = flyers.filter { $0.assetID != "demo" }
    }

    func createFlyersCalendar() {
        if let id = try? calendarService.createFlyersCalendar() { chooseCalendar(id) }
    }

    /// Where each of a flyer's photos can be loaded from, in order: the copy saved in Flyers,
    /// or, for older flyers, your Photos library.
    func photoSources(_ flyer: Flyer?) -> [PhoneImageSource] {
        guard let flyer else { return [] }
        return flyer.allAssetIDs.enumerated().map { index, assetID in
            if let files = flyer.photoFiles, files.indices.contains(index) {
                return .file(engine.store.photoURL(files[index]))
            }
            return .library(assetID)
        }
    }

    var canScan: Bool { !isDemo && scansHere && hasAPIKey && hasPhotoAccess }

    /// Runs each time the app comes to the front, which is when an iPhone app gets to work.
    func opened() async {
        guard !isDemo else { return }
        hasPhotoAccess = PhotoLibrary.isAuthorized
        hasCalendarAccess = CalendarService.hasAccess
        engine.reconcileWithCalendar()
        if canScan {
            await engine.scan(manual: false)
        } else {
            await cloudSync?.fetchNow()
        }
    }

    func scanNow() async {
        if canScan { await engine.scan() }
    }

    func thumbnail(_ flyer: Flyer?) -> UIImage? {
        guard let name = flyer?.thumbnailFile else { return nil }
        if let cached = thumbnails[name] { return cached }
        let image = UIImage(contentsOfFile: engine.store.thumbnailsDirectory.appendingPathComponent(name).path)
        thumbnails[name] = image
        return image
    }

    /// Rows and backdrops ask for the same small images many times while scrolling.
    private var thumbnails: [String: UIImage] = [:]


    func requestPhotoAccess() async {
        hasPhotoAccess = await PhotoLibrary.requestAccess()
    }

    func requestCalendarAccess() async {
        hasCalendarAccess = await calendarService.requestAccess()
    }

    func chooseCalendar(_ id: String?) {
        calendarService.calendarID = id
        engine.updateSettings { $0.calendarID = id }
        engine.flushQueue()
    }

    /// Returns an error message, or nil if the key works and is saved.
    func saveAPIKey(_ key: String) async -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a key" }
        if let error = await AnthropicClient().testKey(trimmed) { return error.description }
        guard APIKeyStore.save(trimmed) else { return "Couldn't save the key in your Keychain" }
        hasAPIKey = true
        engine.clearAlert()
        return nil
    }

    func removeAPIKey() {
        APIKeyStore.delete()
        hasAPIKey = false
    }
}

/// Where a flyer photo can be loaded from.
enum PhoneImageSource: Hashable, Sendable {
    case file(URL)
    case library(String)

    /// Decodes off the main thread at a size that still holds detail when zoomed in.
    func load() async -> UIImage? {
        let data: Data?
        switch self {
        case .file(let url):
            data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        case .library(let id):
            data = try? await PhotoLibrary().imageData(id: id)
        }
        guard let data else { return nil }
        let image = await Task.detached(priority: .userInitiated) { ImageTools.decode(data, maxEdge: 3000) }.value
        return image.map { UIImage(cgImage: $0) }
    }
}

/// A calendar that does nothing, for demo mode.
final class DemoCalendar: CalendarSyncing {
    var isReady: Bool { true }
    private var next = 0

    func add(_ event: FlyerEvent, alertMinutesBefore: Int) throws -> String {
        next += 1
        return "demo-\(next)"
    }

    func update(_ event: FlyerEvent, itemID: String) throws {}
    func addAppLink(_ event: FlyerEvent, itemID: String) throws {}
    func remove(itemID: String) throws {}
    func snapshot(itemID: String) -> CalendarSnapshot? { nil }
}

/// Sample flyers, so the app can be tried and screenshotted without permissions or a key.
enum PhoneDemo {
    @MainActor
    static func document(store: DocumentStore) -> AppDocument {
        var document = AppDocument()
        let today = Day.today

        func makeFlyer(_ title: String, _ top: UIColor, _ bottom: UIColor, latitude: Double? = nil, longitude: Double? = nil) -> Flyer {
            let id = UUID()
            let size = CGSize(width: 450, height: 600)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                let colors = [top.cgColor, bottom.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
                    context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                }
                (title as NSString).draw(in: CGRect(x: 32, y: 40, width: 386, height: 300), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 52, weight: .heavy), .foregroundColor: UIColor.white,
                ])
            }
            if let data = image.jpegData(compressionQuality: 0.85) {
                try? store.saveThumbnail(data, name: "\(id.uuidString).jpg")
            }
            return Flyer(
                id: id, assetID: "demo", takenAt: Date(), title: title, reason: "Demo flyer", confidence: .high,
                thumbnailFile: "\(id.uuidString).jpg", latitude: latitude, longitude: longitude
            )
        }
        let jazz = makeFlyer("Fellowship Wednesdays", .systemIndigo, .systemTeal, latitude: 47.614, longitude: -122.317)
        let market = makeFlyer("Winter craft market", .systemRed, .systemOrange)
        let schedule = makeFlyer("Community schedule", .systemGreen, .systemMint)
        document.flyers = [jazz, market, schedule]

        func event(
            _ name: String, flyer: Flyer, offset: Int, time: String? = "19:30", rrule: String? = nil,
            state: EventState = .onCalendar, location: String? = nil, problems: [String] = []
        ) -> FlyerEvent {
            FlyerEvent(
                id: UUID(), flyerID: flyer.id, name: name, datePrinted: nil, startDay: today.adding(days: offset),
                startTime: time, endDay: nil, endTime: nil, rrule: rrule, yearInferred: false, startUncertain: false,
                location: location, locationInferred: false, url: nil, details: "Live jazz and fellowship.",
                state: state, stateBeforeDelete: nil, calendarItemID: nil, fingerprint: name, problems: problems
            )
        }
        var featured = event("Dick Oatts and Jim Rotondi", flyer: jazz, offset: 2, location: "Vermillion, 1508 11th Ave")
        featured.url = "https://www.seattlejazzfellowship.org"
        featured.links = [
            EventLink(label: "Tickets", url: "https://www.seattlejazzfellowship.org"),
            EventLink(label: "Venue", url: "https://www.vermillionseattle.com"),
        ]
        featured.sponsors = ["Seattle Jazz Fellowship", "Vermillion Art Gallery & Bar"]
        featured.details = "An evening of straight-ahead jazz with saxophonist Dick Oatts and trumpeter Jim Rotondi, "
            + "followed by an open jam session. Tickets are $15 to $25, with discounts for students."
        document.events = [
            featured,
            event("Darelle Holden", flyer: jazz, offset: 9, location: "Vermillion, 1508 11th Ave"),
            event("Winter craft market", flyer: market, offset: 16, time: nil, location: "Park pavilion"),
            event("Group fitness", flyer: schedule, offset: 3, rrule: "FREQ=WEEKLY;BYDAY=MO"),
            event("Trivia night", flyer: schedule, offset: 4, rrule: "FREQ=WEEKLY;BYDAY=TU"),
            event("Run club", flyer: schedule, offset: 5, rrule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=SU", state: .needsReview,
                  problems: ["The flyer doesn't say which date comes first"]),
            event("Old show", flyer: jazz, offset: -30, state: .available, location: "Vermillion, 1508 11th Ave"),
        ]
        return document
    }
}

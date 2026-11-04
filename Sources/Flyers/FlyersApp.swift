import AppKit
import Combine
import EventKit
import FlyersCore
import ServiceManagement
import SwiftUI

@main
struct FlyersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Flyers", id: AppModel.mainWindowID) {
            MainView(model: model, engine: model.engine)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 980, height: 660)

        Settings {
            SettingsView(model: model, engine: model.engine)
        }

        MenuBarExtra("Flyers", systemImage: "calendar.badge.plus") {
            MenuBarView(model: model, engine: model.engine)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var launchedAtLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        AppDelegate.launchedAtLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Closing the window leaves the app scanning from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// A calendar that does nothing, for demo mode.
private final class DemoCalendar: CalendarSyncing {
    var isReady: Bool { true }
    func add(_ event: FlyerEvent, alertMinutesBefore: Int) throws -> String { UUID().uuidString }
    func update(_ event: FlyerEvent, itemID: String) throws {}
    func addAppLink(_ event: FlyerEvent, itemID: String) throws {}
    func remove(itemID: String) throws {}
    func snapshot(itemID: String) -> CalendarSnapshot? { nil }
}

/// Connects the engine to the system: permissions, the background schedule and login items.
@MainActor
final class AppModel: ObservableObject {
    static let mainWindowID = "main"

    let engine: FlyersEngine
    let calendarService: CalendarService
    let isDemo: Bool
    @Published var hasAPIKey: Bool
    @Published var hasPhotoAccess: Bool
    @Published var hasCalendarAccess: Bool
    @Published var launchAtLoginError: String?

    private var scheduler: NSBackgroundActivityScheduler?
    private var calendarObserver: NSObjectProtocol?

    init() {
        let demo = CommandLine.arguments.contains("--demo")
        isDemo = demo
        if demo {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flyers-demo-\(UUID())", isDirectory: true)
            let store = DocumentStore(directory: directory)
            calendarService = CalendarService(calendarID: nil)
            engine = FlyersEngine(
                store: store, photos: PhotoLibrary(), extractor: AnthropicClient(), calendar: DemoCalendar(),
                apiKey: { nil }, document: DemoData.document(store: store)
            )
            hasAPIKey = true
            hasPhotoAccess = true
            hasCalendarAccess = true
            return
        }
        let store = DocumentStore(directory: DocumentStore.defaultDirectory)
        let document = store.load()
        let service = CalendarService(calendarID: document.settings.calendarID)
        calendarService = service
        engine = FlyersEngine(
            store: store, photos: PhotoLibrary(), extractor: AnthropicClient(), calendar: service,
            apiKey: { APIKeyStore.read() }, document: document
        )
        hasAPIKey = APIKeyStore.read() != nil
        hasPhotoAccess = PhotoLibrary.isAuthorized
        hasCalendarAccess = CalendarService.hasAccess
        // Saves the scan start date, so photos taken before the first launch stay out of it.
        engine.updateSettings { _ in }
        startBackgroundWork()
    }

    var isSetUp: Bool {
        hasAPIKey && hasPhotoAccess && hasCalendarAccess && engine.document.settings.calendarID != nil
    }

    func scanIfReady() {
        guard !isDemo, hasAPIKey, hasPhotoAccess else { return }
        Task { await engine.scan(manual: false) }
    }

    private func startBackgroundWork() {
        calendarObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: calendarService.store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.engine.reconcileWithCalendar() }
        }
        engine.reconcileWithCalendar()
        engine.addAppLinksIfNeeded()
        scheduleScans()
        scanIfReady()
    }

    /// macOS picks the moment within the interval, which avoids waking the Mac just for this.
    func scheduleScans() {
        guard !isDemo else { return }
        scheduler?.invalidate()
        let activity = NSBackgroundActivityScheduler(identifier: "app.flyers.scan")
        activity.repeats = true
        activity.interval = TimeInterval(engine.document.settings.scanIntervalMinutes * 60)
        activity.tolerance = activity.interval / 4
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                self?.refreshAccess()
                if let self, self.hasAPIKey, self.hasPhotoAccess { await self.engine.scan(manual: false) }
                completion(.finished)
            }
        }
        scheduler = activity
    }

    func refreshAccess() {
        guard !isDemo else { return }
        hasPhotoAccess = PhotoLibrary.isAuthorized
        hasCalendarAccess = CalendarService.hasAccess
    }

    func requestPhotoAccess() async {
        hasPhotoAccess = await PhotoLibrary.requestAccess()
        scanIfReady()
    }

    func requestCalendarAccess() async {
        hasCalendarAccess = await calendarService.requestAccess()
    }

    func chooseCalendar(_ id: String?) {
        calendarService.calendarID = id
        engine.updateSettings { $0.calendarID = id }
        engine.flushQueue()
    }

    func createCalendar() throws {
        chooseCalendar(try calendarService.createFlyersCalendar())
    }

    /// Returns an error message, or nil if the key works and is saved.
    func saveAPIKey(_ key: String) async -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a key" }
        if let error = await AnthropicClient().testKey(trimmed) { return error.description }
        guard APIKeyStore.save(trimmed) else { return "Couldn't save the key in your Keychain" }
        hasAPIKey = true
        engine.clearAlert()
        scanIfReady()
        return nil
    }

    func removeAPIKey() {
        APIKeyStore.delete()
        hasAPIKey = false
    }

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "macOS wouldn't change this: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }
}

enum DemoData {
    @MainActor
    static func document(store: DocumentStore) -> AppDocument {
        var document = AppDocument()
        let today = Day.today
        let makeFlyer = { (title: String, gray: CGFloat) -> Flyer in
            let id = UUID()
            let context = CGContext(
                data: nil, width: 450, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            context.setFillColor(CGColor(red: gray, green: 0.45, blue: 1 - gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 450, height: 600))
            if let image = context.makeImage(), let data = ImageTools.jpeg(image, maxEdge: 600) {
                try? store.saveThumbnail(data, name: "\(id.uuidString).jpg")
            }
            return Flyer(
                id: id, assetID: "demo", takenAt: Date(), title: title, reason: "Demo flyer",
                confidence: .high, thumbnailFile: "\(id.uuidString).jpg"
            )
        }
        let jazz = makeFlyer("Fellowship Wednesdays", 0.2)
        let market = makeFlyer("Winter craft market", 0.8)
        let schedule = makeFlyer("Community schedule", 0.5)
        document.flyers = [jazz, market, schedule]

        func event(
            _ name: String, flyer: Flyer, offset: Int, time: String? = "19:30", rrule: String? = nil,
            state: EventState = .onCalendar, location: String? = nil, url: String? = nil, problems: [String] = []
        ) -> FlyerEvent {
            FlyerEvent(
                id: UUID(), flyerID: flyer.id, name: name, datePrinted: nil, startDay: today.adding(days: offset),
                startTime: time, endDay: nil, endTime: nil, rrule: rrule, yearInferred: false, startUncertain: false,
                location: location, locationInferred: false, url: url, details: "Live jazz and fellowship.",
                state: state, stateBeforeDelete: nil, calendarItemID: nil, fingerprint: name, problems: problems
            )
        }
        var linkable = event("Darelle Holden", flyer: jazz, offset: 9, location: "Vermillion, 1508 11th Ave")
        // A fixed ID, so links can be tried in demo mode.
        linkable.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        document.events = [
            event("Dick Oatts and Jim Rotondi", flyer: jazz, offset: 2, location: "Vermillion, 1508 11th Ave", url: "https://www.seattlejazzfellowship.org"),
            linkable,
            event("Winter craft market", flyer: market, offset: 16, time: nil, location: "Park pavilion"),
            event("Group fitness", flyer: schedule, offset: 3, rrule: "FREQ=WEEKLY;BYDAY=MO", state: .available),
            event("Trivia night", flyer: schedule, offset: 4, rrule: "FREQ=WEEKLY;BYDAY=TU", state: .available),
            event("Run club", flyer: schedule, offset: 5, rrule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=SU", state: .needsReview, problems: ["The flyer doesn't say which date comes first"]),
            event("Old show", flyer: jazz, offset: -30, state: .available),
        ]
        document.spend[FlyersEngine.monthKey(today)] = 0.0127
        document.lastScanAt = Date()
        document.lastScanSummary = "2 new events"
        return document
    }
}

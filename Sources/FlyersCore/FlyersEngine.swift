import Combine
import CoreGraphics
import Foundation

/// The app's state and every action on it. Photos, the API and Calendar are all behind protocols,
/// so these rules run in tests with no permissions.
@MainActor
public final class FlyersEngine: ObservableObject {
    @Published public private(set) var document: AppDocument
    @Published public private(set) var isScanning = false
    @Published public private(set) var scanProgress: String?
    @Published public private(set) var isStopping = false
    /// A problem that needs you, such as a rejected key.
    @Published public private(set) var alertMessage: String?
    /// The events the last delete removed, for Undo.
    @Published public private(set) var lastDeletedIDs: [UUID] = []

    public let store: DocumentStore
    public let calendar: CalendarSyncing
    private let photos: PhotoSource
    private let extractor: EventExtracting
    private let apiKey: () -> String?
    private let maxAttempts = 3

    public init(
        store: DocumentStore, photos: PhotoSource, extractor: EventExtracting,
        calendar: CalendarSyncing, apiKey: @escaping () -> String?, document: AppDocument? = nil
    ) {
        self.store = store
        self.photos = photos
        self.extractor = extractor
        self.calendar = calendar
        self.apiKey = apiKey
        self.document = document ?? store.load()
    }

    // MARK: Lookups

    public var visibleEvents: [FlyerEvent] { document.events.filter { !$0.isHidden } }
    public func flyer(id: UUID) -> Flyer? { document.flyers.first { $0.id == id } }
    public func event(id: UUID) -> FlyerEvent? { document.events.first { $0.id == id } }

    public var spendThisMonth: Double { document.spend[FlyersEngine.monthKey(.today)] ?? 0 }

    public static func monthKey(_ day: Day) -> String { String(day.iso.prefix(7)) }

    public func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&document.settings)
        persist()
    }

    public func clearAlert() { alertMessage = nil }

    // MARK: Scanning

    /// Looks for new photos and processes each one. Progress is saved after every photo,
    /// so a crash or quit never pays for the same photo twice.
    ///
    /// Scans you start yourself clear a pause. Automatic ones respect it.
    public func scan(manual: Bool = true) async {
        guard !isScanning else { return }
        if !manual && isPaused { return }
        guard let key = apiKey(), !key.isEmpty else {
            alertMessage = "Add your API key in Settings to start scanning."
            return
        }
        isScanning = true
        alertMessage = nil
        if manual { document.scanPaused = nil }
        defer {
            isScanning = false
            isStopping = false
            scanProgress = nil
        }
        flushQueue()

        let settings = document.settings
        let found = await photos.candidates(since: settings.scanStartDate, includeScreenshots: settings.includeScreenshots)
        let pending = found.filter { candidate in
            guard let record = document.photos[candidate.id] else { return true }
            return record.status == .failed && record.attempts < maxAttempts
        }

        var added = 0
        var failed = 0
        var stopReason: String?
        for (index, candidate) in pending.enumerated() {
            if isStopping { break }
            // A start date changed during the scan applies right away.
            if candidate.takenAt < document.settings.scanStartDate { continue }
            scanProgress = "Checking photo \(index + 1) of \(pending.count)"
            do {
                added += try await process(candidate, apiKey: key)
            } catch let error as ExtractionError {
                switch error {
                case .keyRejected, .outOfCredit:
                    stopReason = error.description
                case .temporary(let detail):
                    failed += 1
                    record(candidate.id, status: .failed, error: detail)
                case .permanent(let detail):
                    failed += 1
                    record(candidate.id, status: .failed, error: detail, attempts: maxAttempts)
                }
            } catch is SpendLimitReached {
                stopReason = "This month's spending limit is reached. Raise it in Settings to keep scanning."
            } catch {
                failed += 1
                record(candidate.id, status: .failed, error: String(describing: error))
            }
            if stopReason != nil { break }
        }

        alertMessage = stopReason
        document.lastScanAt = Date()
        var summary = added == 1 ? "1 new event" : "\(added) new events"
        if failed > 0 { summary += ", \(failed) couldn't be read" }
        document.lastScanSummary = summary
        persist()
    }

    public var isPaused: Bool { document.scanPaused == true }

    /// Stops after the current photo, whose request may already be paid for. Stays paused
    /// until you start a scan yourself, so the next scheduled scan can't pick it back up.
    public func stopScan() {
        guard isScanning else { return }
        isStopping = true
        scanProgress = "Stopping after this photo"
        document.scanPaused = true
        persist()
    }

    private struct SpendLimitReached: Error {}

    private func process(_ candidate: PhotoCandidate, apiKey: String) async throws -> Int {
        let data = try await photos.imageData(id: candidate.id)
        let (jpeg, thumbnail, codes, worthSending) = try await ImageWorker.run { () -> (Data, Data?, [DetectedCode], Bool) in
            guard let image = ImageTools.decode(data), let jpeg = ImageTools.jpeg(image, maxEdge: 1568) else {
                throw ExtractionError.permanent("The image couldn't be decoded")
            }
            let codes = try ImageTools.detectCodes(image)
            let text = try ImageTools.recognizeText(image)
            return (jpeg, ImageTools.jpeg(image, maxEdge: 900), codes, LocalFilter.shouldSend(text: text, codeCount: codes.count))
        }
        guard worthSending else {
            record(candidate.id, status: .skippedByFilter)
            return 0
        }

        guard spendThisMonth < document.settings.monthlySpendLimit else { throw SpendLimitReached() }
        let takenOn = Day(date: candidate.takenAt)
        var coordinates: (latitude: Double, longitude: Double)?
        if let latitude = candidate.latitude, let longitude = candidate.longitude {
            coordinates = (latitude, longitude)
        }
        let context = PhotoContext(takenOn: takenOn, coordinates: coordinates, codes: codes)
        let (result, usage) = try await extractor.extract(jpeg: jpeg, context: context, apiKey: apiKey)
        document.spend[FlyersEngine.monthKey(.today), default: 0] += usage.cost

        guard result.isEventFlyer else {
            record(candidate.id, status: .notAFlyer)
            return 0
        }
        let flyerID = UUID()
        var thumbnailName: String?
        if let thumbnail {
            let name = "\(flyerID.uuidString).jpg"
            try? store.saveThumbnail(thumbnail, name: name)
            thumbnailName = name
        }
        let new = Ingest.events(
            from: result, flyerID: flyerID, takenOn: takenOn, today: .today, settings: document.settings,
            existingFingerprints: Set(document.events.map(\.fingerprint))
        )
        if !new.isEmpty {
            document.flyers.append(Flyer(
                id: flyerID, assetID: candidate.id, takenAt: candidate.takenAt, title: result.flyerTitle,
                reason: result.reason, confidence: result.confidence, thumbnailFile: thumbnailName
            ))
            document.events.append(contentsOf: new)
        }
        record(candidate.id, status: .extracted)
        flushQueue()
        return new.count
    }

    private func record(_ id: String, status: PhotoStatus, error: String? = nil, attempts: Int? = nil) {
        let previous = document.photos[id]?.attempts ?? 0
        document.photos[id] = PhotoRecord(
            status: status, attempts: attempts ?? previous + 1, lastError: error, processedAt: Date()
        )
        persist()
    }

    // MARK: Calendar

    /// Adds anything waiting. Without a calendar yet, events simply wait for one.
    public func flushQueue() {
        guard calendar.isReady else { return }
        for index in document.events.indices where document.events[index].state == .queued {
            do {
                document.events[index].calendarItemID = try calendar.add(
                    document.events[index], alertMinutesBefore: document.settings.alertMinutesBefore
                )
                document.events[index].state = .onCalendar
            } catch {
                document.events[index].state = .needsReview
                document.events[index].problems.append("Couldn't add this to Calendar: \(error)")
            }
        }
        persist()
    }

    /// Puts a reviewed or optional event on the calendar.
    public func addToCalendar(_ id: UUID) {
        change(id) {
            $0.state = .queued
            $0.problems.removeAll()
        }
        flushQueue()
    }

    /// Removes an event from the calendar but keeps it in the app.
    public func removeFromCalendar(_ id: UUID) {
        guard let event = event(id: id), let itemID = event.calendarItemID else { return }
        try? calendar.remove(itemID: itemID)
        change(id) {
            $0.calendarItemID = nil
            $0.state = .available
        }
        persist()
    }

    /// Deleting keeps a hidden record, so a rescan of the same flyer can't bring the event back.
    public func delete(_ ids: [UUID]) {
        var removed: [UUID] = []
        for id in ids {
            guard let event = event(id: id), !event.isHidden else { continue }
            if let itemID = event.calendarItemID { try? calendar.remove(itemID: itemID) }
            change(id) {
                $0.stateBeforeDelete = $0.state
                $0.state = .deleted
                $0.calendarItemID = nil
            }
            removed.append(id)
        }
        lastDeletedIDs = removed
        persist()
    }

    public func undoDelete() {
        for id in lastDeletedIDs {
            change(id) {
                let previous = $0.stateBeforeDelete ?? .available
                $0.state = previous == .onCalendar ? .queued : previous
                $0.stateBeforeDelete = nil
            }
        }
        lastDeletedIDs = []
        flushQueue()
        persist()
    }

    public func dismissUndo() { lastDeletedIDs = [] }

    /// Applies your edits here and in Calendar. Your edit counts as checking the event.
    public func edit(_ id: UUID, _ apply: (inout FlyerEvent) -> Void) {
        change(id) {
            apply(&$0)
            $0.problems.removeAll()
            $0.locationInferred = false
            $0.startUncertain = false
        }
        if let event = event(id: id), let itemID = event.calendarItemID {
            do {
                try calendar.update(event, itemID: itemID)
            } catch {
                alertMessage = "Couldn't update Calendar: \(error)"
            }
        }
        persist()
    }

    /// Picks up changes you made in Calendar. Your changes there win.
    public func reconcileWithCalendar() {
        guard calendar.isReady else { return }
        var changed = false
        for index in document.events.indices {
            let event = document.events[index]
            guard event.state == .onCalendar, let itemID = event.calendarItemID else { continue }
            guard let snapshot = calendar.snapshot(itemID: itemID) else {
                document.events[index].state = .removedInCalendar
                document.events[index].calendarItemID = nil
                changed = true
                continue
            }
            if snapshot.title != event.name {
                document.events[index].name = snapshot.title
                changed = true
            }
            if snapshot.location != event.location {
                document.events[index].location = snapshot.location
                changed = true
            }
            let startDay = Day(date: snapshot.start)
            // A repeating event's snapshot is its first occurrence, so only one-offs take a new date.
            if event.rrule == nil, startDay != event.startDay {
                document.events[index].startDay = startDay
                changed = true
            }
            if !snapshot.isAllDay {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: snapshot.start)
                let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
                if time != event.startTime {
                    document.events[index].startTime = time
                    changed = true
                }
            }
        }
        if changed { persist() }
    }

    /// Gives events added before Open in Flyers links existed a link, once.
    /// It waits for a calendar, and tries again next launch if any event fails.
    public func addAppLinksIfNeeded() {
        guard document.appLinksAdded != true, calendar.isReady else { return }
        var allSucceeded = true
        for event in document.events where event.state == .onCalendar {
            guard let itemID = event.calendarItemID else { continue }
            do {
                try calendar.addAppLink(event, itemID: itemID)
            } catch {
                allSucceeded = false
            }
        }
        if allSucceeded {
            document.appLinksAdded = true
            persist()
        }
    }

    /// Where a link should land. Nil if the event no longer exists here.
    public func eventForLink(_ url: URL) -> FlyerEvent? {
        guard let id = AppLink.eventID(from: url), let found = event(id: id), !found.isHidden else { return nil }
        return found
    }

    // MARK: Plumbing

    private func change(_ id: UUID, _ apply: (inout FlyerEvent) -> Void) {
        guard let index = document.events.firstIndex(where: { $0.id == id }) else { return }
        apply(&document.events[index])
    }

    private func persist() {
        do {
            try store.save(document)
        } catch {
            alertMessage = "Couldn't save your library: \(error.localizedDescription)"
        }
    }
}

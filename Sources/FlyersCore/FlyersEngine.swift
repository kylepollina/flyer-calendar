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

    /// Looks for new photos and processes them, with photos taken within a couple of minutes of
    /// each other read together. Progress is saved after every request, so a crash or quit never
    /// pays for the same photo twice.
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
        var checked = 0
        var savedInFlyers: [String] = []
        for group in PhotoGrouping.groups(pending) {
            if isStopping { break }
            let first = checked + 1
            checked += group.count
            // A scheduled scan leaves a burst you may still be adding to, so it's read whole later.
            if !manual && PhotoGrouping.mayStillGrow(group, now: Date()) { continue }
            // A start date changed during the scan applies right away.
            let group = group.filter { $0.takenAt >= document.settings.scanStartDate }
            if group.isEmpty { continue }
            scanProgress = group.count == 1
                ? "Checking photo \(first) of \(pending.count)"
                : "Checking photos \(first)–\(checked) of \(pending.count)"
            do {
                let outcome = try await process(group, apiKey: key)
                added += outcome.added
                failed += outcome.failed
                savedInFlyers += outcome.saved
            } catch let stop as StopScan {
                stopReason = stop.reason
                break
            } catch {
                failed += group.count
                for candidate in group { record(candidate.id, status: .failed, error: String(describing: error)) }
            }
        }

        // Once at the end, so Photos asks you to confirm once per scan rather than once per flyer.
        if document.settings.removesPhotosFromLibrary && !savedInFlyers.isEmpty {
            scanProgress = "Moving flyer photos out of Photos"
            await removeFromLibrary(savedInFlyers)
        }

        if let stopReason { alertMessage = stopReason }
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

    /// Ends the whole scan, such as a rejected key or the spending limit.
    private struct StopScan: Error { let reason: String }

    private struct PreparedPhoto: Sendable {
        var candidate: PhotoCandidate
        /// The photo as stored in your library, kept so Flyers can save its own copy.
        var original: Data
        var jpeg: Data
        var thumbnail: Data?
        var codes: [DetectedCode]
        var hasText: Bool
        var worthSending: Bool
    }

    private func prepare(_ candidate: PhotoCandidate) async throws -> PreparedPhoto {
        let data = try await photos.imageData(id: candidate.id)
        return try await ImageWorker.run {
            guard let image = ImageTools.decode(data), let jpeg = ImageTools.jpeg(image, maxEdge: 1568) else {
                throw ExtractionError.permanent("The image couldn't be decoded")
            }
            let codes = try ImageTools.detectCodes(image)
            let text = try ImageTools.recognizeText(image)
            return PreparedPhoto(
                candidate: candidate, original: data, jpeg: jpeg, thumbnail: ImageTools.jpeg(image, maxEdge: 900), codes: codes,
                hasText: LocalFilter.hasText(text), worthSending: LocalFilter.shouldSend(text: text, codeCount: codes.count)
            )
        }
    }

    /// Reads a group of photos taken moments apart in one request, so details on one photo,
    /// like a post's title, reach the events on the others.
    /// `saved` lists the photos whose copies are now kept in Flyers.
    private func process(_ group: [PhotoCandidate], apiKey: String) async throws -> (added: Int, failed: Int, saved: [String]) {
        var failed = 0
        var prepared: [PreparedPhoto] = []
        for candidate in group {
            do {
                prepared.append(try await prepare(candidate))
            } catch let error as ExtractionError {
                failed += 1
                record(candidate.id, status: .failed, error: error.description, attempts: maxAttempts)
            } catch {
                failed += 1
                record(candidate.id, status: .failed, error: String(describing: error))
            }
        }
        // The group is sent when any photo looks like an event. Others with text go along for
        // context, and ones with almost no text, like a selfie, never leave this Mac.
        let worthSending = prepared.contains(where: \.worthSending)
        for photo in prepared where !worthSending || !photo.hasText {
            record(photo.candidate.id, status: .skippedByFilter)
        }
        let sending = worthSending ? prepared.filter(\.hasText) : []
        guard let lead = sending.first else { return (0, failed, []) }
        let ids = sending.map(\.candidate.id)

        guard spendThisMonth < document.settings.monthlySpendLimit else {
            throw StopScan(reason: "This month's spending limit is reached. Raise it in Settings to keep scanning.")
        }
        let takenOn = Day(date: lead.candidate.takenAt)
        let coordinates = sending.lazy.compactMap { photo -> (latitude: Double, longitude: Double)? in
            guard let latitude = photo.candidate.latitude, let longitude = photo.candidate.longitude else { return nil }
            return (latitude, longitude)
        }.first
        let context = PhotoContext(takenOn: takenOn, coordinates: coordinates, codesByPhoto: sending.map(\.codes))
        let result: ExtractionResult
        do {
            let (answer, usage) = try await extractor.extract(jpegs: sending.map(\.jpeg), context: context, apiKey: apiKey)
            document.spend[FlyersEngine.monthKey(.today), default: 0] += usage.cost
            result = answer
        } catch let error as ExtractionError {
            switch error {
            case .keyRejected, .outOfCredit:
                throw StopScan(reason: error.description)
            case .temporary(let detail):
                for id in ids { record(id, status: .failed, error: detail) }
            case .permanent(let detail):
                for id in ids { record(id, status: .failed, error: detail, attempts: maxAttempts) }
            }
            return (0, failed + ids.count, [])
        }

        guard result.isEventFlyer else {
            for id in ids { record(id, status: .notAFlyer) }
            return (0, failed, [])
        }
        // Only the photos that show the flyer belong to it. Others taken nearby are left alone.
        let numbers = Set((result.photosUsed ?? []).filter { (1...sending.count).contains($0) })
        let used = numbers.isEmpty ? sending : sending.enumerated().filter { numbers.contains($0.offset + 1) }.map(\.element)
        let main = used[0]
        let flyerID = UUID()
        var thumbnailName: String?
        if let thumbnail = main.thumbnail {
            let name = "\(flyerID.uuidString).jpg"
            try? store.saveThumbnail(thumbnail, name: name)
            thumbnailName = name
        }
        let new = Ingest.events(
            from: result, flyerID: flyerID, takenOn: takenOn, today: .today, settings: document.settings,
            existingFingerprints: Set(document.events.map(\.fingerprint))
        )
        var saved: [String] = []
        if !new.isEmpty {
            let usedIDs = used.map(\.candidate.id)
            let files = savePhotos(used.map(\.original), flyerID: flyerID)
            if files != nil { saved = usedIDs }
            document.flyers.append(Flyer(
                id: flyerID, assetID: main.candidate.id, takenAt: main.candidate.takenAt, title: result.flyerTitle,
                reason: result.reason, confidence: result.confidence, thumbnailFile: thumbnailName,
                assetIDs: usedIDs.count > 1 ? usedIDs : nil,
                latitude: coordinates?.latitude, longitude: coordinates?.longitude,
                photoFiles: files
            ))
            document.events.append(contentsOf: new)
        }
        for id in ids { record(id, status: .extracted) }
        flushQueue()
        return (new.count, failed, saved)
    }

    // MARK: Saved photos

    /// Saves full-size copies, all or nothing, so a photo only leaves your library once its copy is safe.
    private func savePhotos(_ originals: [Data], flyerID: UUID) -> [String]? {
        var names: [String] = []
        for (index, data) in originals.enumerated() {
            let name = "\(flyerID.uuidString)-\(index + 1)"
            do {
                try store.savePhoto(data, name: name)
                names.append(name)
            } catch {
                names.forEach(store.deletePhoto)
                return nil
            }
        }
        return names
    }

    /// Deletes photos from your library once their copies are saved here. Says nothing if you
    /// decline Photos' confirmation, since that's a choice, and tries again next time you ask.
    private func removeFromLibrary(_ assetIDs: [String]) async {
        do {
            guard try await photos.delete(ids: assetIDs) else { return }
            let removed = Set(assetIDs)
            for index in document.flyers.indices where document.flyers[index].allAssetIDs.contains(where: removed.contains) {
                document.flyers[index].photosInLibrary = false
            }
            persist()
        } catch {
            alertMessage = "Couldn't remove flyer photos from Photos: \(error.localizedDescription)"
        }
    }

    /// Flyers whose photos are still only in your library, from before Flyers kept its own copies.
    public var flyersOnlyInLibrary: [Flyer] {
        document.flyers.filter { $0.photoFiles == nil && $0.mayBeInLibrary && $0.assetID != "demo" }
    }

    public var savedPhotoNames: [String] { document.flyers.flatMap { $0.photoFiles ?? [] } }

    /// Copies older flyers' photos into Flyers, then removes them from your library.
    /// Returns how many flyers' photos were moved.
    @discardableResult
    public func moveOlderPhotosIntoFlyers() async -> Int {
        var moved: [String] = []
        var count = 0
        for flyer in flyersOnlyInLibrary {
            var originals: [Data] = []
            for id in flyer.allAssetIDs {
                guard let data = try? await photos.imageData(id: id) else { break }
                originals.append(data)
            }
            guard let index = document.flyers.firstIndex(where: { $0.id == flyer.id }) else { continue }
            guard originals.count == flyer.allAssetIDs.count else {
                // Already gone from your library, so there's nothing left to copy.
                if originals.isEmpty { document.flyers[index].photosInLibrary = false }
                continue
            }
            guard let files = savePhotos(originals, flyerID: flyer.id) else { continue }
            document.flyers[index].photoFiles = files
            moved += flyer.allAssetIDs
            count += 1
        }
        persist()
        if !moved.isEmpty { await removeFromLibrary(moved) }
        return count
    }

    /// Flyers with no event still coming up, whose saved photos you're unlikely to need.
    public func flyersWithOnlyPastEvents(today: Day = .today) -> [Flyer] {
        document.flyers.filter { flyer in
            flyer.photoFiles != nil && !document.events.contains {
                $0.flyerID == flyer.id && !$0.isHidden && !$0.isOver(today: today)
            }
        }
    }

    /// Deletes the copies saved in Flyers. The small preview stays.
    public func deleteSavedPhotos(of flyerIDs: [UUID]) {
        let ids = Set(flyerIDs)
        for index in document.flyers.indices where ids.contains(document.flyers[index].id) {
            document.flyers[index].photoFiles?.forEach(store.deletePhoto)
            document.flyers[index].photoFiles = nil
        }
        persist()
    }

    /// Deletes flyers' photos everywhere: the copies here and, if still there, the originals in Photos.
    public func deletePhotos(of flyerIDs: [UUID]) async {
        let ids = Set(flyerIDs)
        let inLibrary = document.flyers.filter { ids.contains($0.id) && $0.mayBeInLibrary }.flatMap(\.allAssetIDs)
        if !inLibrary.isEmpty {
            do {
                // Declining in Photos keeps everything, including the copy here.
                guard try await photos.delete(ids: inLibrary) else { return }
            } catch {
                alertMessage = "Couldn't delete the photo from Photos: \(error.localizedDescription)"
                return
            }
        }
        for index in document.flyers.indices where ids.contains(document.flyers[index].id) {
            document.flyers[index].photosInLibrary = false
        }
        deleteSavedPhotos(of: flyerIDs)
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

    /// The flyers that deleting `ids` would leave with no events in the app, so you can be offered
    /// to delete their photos too. A flyer with other events still showing keeps its photos.
    public func flyersOnlyUsedBy(_ ids: [UUID]) -> [Flyer] {
        let deleting = Set(ids)
        let flyerIDs = Set(document.events.filter { deleting.contains($0.id) && !$0.isHidden }.map(\.flyerID))
        return document.flyers
            .filter { flyerIDs.contains($0.id) }
            .filter { flyer in
                !document.events.contains { $0.flyerID == flyer.id && !$0.isHidden && !deleting.contains($0.id) }
            }
            // Only flyers that still have a photo somewhere are worth asking about.
            .filter { $0.photoFiles != nil || $0.mayBeInLibrary }
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

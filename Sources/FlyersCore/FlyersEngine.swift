import Combine
import CoreGraphics
import Foundation

/// The app's state and every action on it. Photos, the API and Calendar are all behind protocols,
/// so these rules run in tests with no permissions.
@MainActor
public final class FlyersEngine: ObservableObject {
    /// Changed only through the engine, including the sync code in Sync.swift.
    @Published public internal(set) var document: AppDocument
    @Published public private(set) var isScanning = false
    @Published public private(set) var scanProgress: String?
    @Published public private(set) var isStopping = false
    /// A problem that needs you, such as a rejected key.
    @Published public private(set) var alertMessage: String?
    /// What the last drop found, until you dismiss it.
    @Published public private(set) var dropSummary: String?
    /// The events the last delete removed, for Undo.
    @Published public private(set) var lastDeletedIDs: [UUID] = []

    public let store: DocumentStore
    public let calendar: CalendarSyncing
    /// This copy of the app, so syncing devices know which one found each event.
    public let deviceID: String
    /// Connects to iCloud when sync is on. Nil keeps everything on this device.
    public weak var sync: SyncConnection?
    /// True while records from other devices are applied. The connection is busy with its ledger
    /// then, so saves don't tell it about changes. It asks for them once the apply is done.
    var isApplyingSync = false
    private let photos: PhotoSource
    private let extractor: EventExtracting
    private let apiKey: () -> String?
    private let maxAttempts = 3

    public init(
        store: DocumentStore, photos: PhotoSource, extractor: EventExtracting,
        calendar: CalendarSyncing, apiKey: @escaping () -> String?, document: AppDocument? = nil,
        deviceID: String? = nil
    ) {
        self.store = store
        self.deviceID = deviceID ?? store.deviceID()
        self.photos = photos
        self.extractor = extractor
        self.calendar = calendar
        self.apiKey = apiKey
        self.document = document ?? store.load()
        // Events deleted before deletion dates were kept start their 30 days now.
        for index in self.document.events.indices where self.document.events[index].isHidden && self.document.events[index].deletedAt == nil {
            self.document.events[index].deletedAt = Date()
        }
    }

    /// How long deleted events stay in the Past list to be restored.
    public static let deletedKeptFor: TimeInterval = 30 * 24 * 60 * 60

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

    /// Looks for new photos and processes them, with screenshots taken within a couple of minutes
    /// of each other read together. Progress is saved after every request, so a crash or quit never
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
        // What other devices have read and claimed since last time.
        if let sync { await sync.fetchNow() }
        flushQueue()

        let settings = document.settings
        let found = await photos.candidates(since: settings.scanStartDate, includeScreenshots: settings.includeScreenshots)
        cloudIDs = photos.cloudIDs(forLocal: found.map(\.id))
        let pending = found.filter { isPending($0.id) }

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
            // Tells other devices these are taken before paying to read them.
            if let sync {
                for candidate in group {
                    record(candidate.id, status: .claimed, attempts: document.photos[candidate.id]?.attempts ?? 0, claimedBy: deviceID)
                }
                await sync.pushNow()
                // Another device may have claimed or finished some of them in the meantime.
                await sync.fetchNow()
            }
            let mine = group.filter { isPending($0.id) }
            if mine.isEmpty { continue }
            do {
                let outcome = try await process(mine, apiKey: key)
                added += outcome.added
                failed += outcome.failed
                savedInFlyers += outcome.saved
            } catch let stop as StopScan {
                stopReason = stop.reason
                break
            } catch {
                failed += mine.count
                for candidate in mine { record(candidate.id, status: .failed, error: String(describing: error)) }
            }
        }

        // Older flyers get a saved copy too, so deleting one from Photos by hand never loses it.
        if !flyersOnlyInLibrary.isEmpty {
            scanProgress = "Saving flyer photos"
            await cacheLibraryPhotos()
        }

        // Once at the end, so Photos asks you to confirm once per scan rather than once per flyer.
        if document.settings.removesPhotosFromLibrary && !savedInFlyers.isEmpty {
            scanProgress = "Moving flyer photos out of Photos"
            // Deleting from iCloud Photos deletes everywhere, so with sync on, the copy in iCloud
            // has to be uploaded first.
            if let sync {
                await sync.pushNow()
                let uploaded = Set(document.flyers.filter { sync.isUploaded(flyerID: $0.id) }.flatMap(\.allAssetIDs))
                savedInFlyers.removeAll { !uploaded.contains($0) }
            }
            if !savedInFlyers.isEmpty { await removeFromLibrary(savedInFlyers) }
        }

        if let stopReason { alertMessage = stopReason }
        document.lastScanAt = Date()
        var summary = added == 1 ? "1 new event" : "\(added) new events"
        if failed > 0 { summary += ", \(failed) couldn't be read" }
        document.lastScanSummary = summary
        persist()
    }

    public var isPaused: Bool { document.scanPaused == true }

    /// iCloud Photos' cross-device IDs for the photos in the current scan, by local ID.
    private var cloudIDs: [String: String] = [:]

    /// How long another device's claim on a photo holds before it counts as abandoned.
    public static let claimTimeout: TimeInterval = 600

    /// What this or another device already did with a photo, found by either ID.
    private func photoRecord(_ id: String) -> PhotoRecord? {
        document.photos[id] ?? cloudIDs[id].flatMap { document.photos[FlyersEngine.cloudKey($0)] }
    }

    /// Photos synced from a device whose library this one can't match yet wait under their cloud ID.
    static func cloudKey(_ cloudID: String) -> String { "cloud:" + cloudID }

    /// Whether a photo still needs reading here.
    private func isPending(_ id: String, now: Date = Date()) -> Bool {
        guard let record = photoRecord(id) else { return true }
        switch record.status {
        case .failed:
            return record.attempts < maxAttempts
        case .claimed:
            // Someone else's fresh claim is respected. An old one, or our own left by a crash, isn't.
            return record.claimedBy == deviceID || now.timeIntervalSince(record.processedAt) >= FlyersEngine.claimTimeout
        default:
            return false
        }
    }

    public func clearDropSummary() { dropSummary = nil }

    /// Scans images you drop on the window. They skip the on-device text check, since you chose
    /// them, and screenshots taken within a couple of minutes of each other are read together.
    /// Returns the new events, so the window can show them.
    @discardableResult
    public func scanDropped(_ dropped: [DroppedPhoto]) async -> [UUID] {
        guard !dropped.isEmpty else { return [] }
        guard !isScanning else {
            alertMessage = "A scan is running. Drop the photos again when it's done."
            return []
        }
        guard let key = apiKey(), !key.isEmpty else {
            alertMessage = "Add your API key in Settings to start scanning."
            return []
        }
        isScanning = true
        alertMessage = nil
        dropSummary = nil
        defer {
            isScanning = false
            isStopping = false
            scanProgress = nil
        }

        var originals: [String: Data] = [:]
        var dated: [PhotoCandidate] = []
        var undated: [PhotoCandidate] = []
        var alreadyScanned = 0
        for photo in dropped {
            let id = photo.id
            guard originals[id] == nil else { continue }
            if let record = document.photos[id], record.status != .failed {
                alreadyScanned += 1
                continue
            }
            originals[id] = photo.data
            let candidate = PhotoCandidate(
                id: id, takenAt: photo.takenAt ?? Date(), latitude: photo.latitude, longitude: photo.longitude,
                isScreenshot: photo.isScreenshot
            )
            if photo.takenAt == nil { undated.append(candidate) } else { dated.append(candidate) }
        }
        // Without a date there's no telling which photos go together, so each is read alone.
        let groups = PhotoGrouping.groups(dated) + undated.map { [$0] }
        let before = Set(document.events.map(\.id))
        let total = originals.count
        var added = 0
        var failed = 0
        var checked = 0
        for group in groups {
            if isStopping { break }
            let first = checked + 1
            checked += group.count
            scanProgress = group.count == 1
                ? "Checking dropped photo \(first) of \(total)"
                : "Checking dropped photos \(first)–\(checked) of \(total)"
            do {
                let outcome = try await process(group, apiKey: key, originals: originals)
                added += outcome.added
                failed += outcome.failed
            } catch let stop as StopScan {
                alertMessage = stop.reason
                break
            } catch {
                failed += group.count
                for candidate in group { record(candidate.id, status: .failed, error: String(describing: error)) }
            }
        }

        var parts = [added == 1 ? "1 new event" : "\(added) new events"]
        if alreadyScanned > 0 { parts.append("\(alreadyScanned) already scanned") }
        if failed > 0 { parts.append("\(failed) couldn't be read") }
        dropSummary = "From your drop: " + parts.joined(separator: ", ")
        persist()
        return document.events.map(\.id).filter { !before.contains($0) }
    }

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

    private func prepare(_ candidate: PhotoCandidate, original: Data?) async throws -> PreparedPhoto {
        let data: Data
        if let original { data = original } else { data = try await photos.imageData(id: candidate.id) }
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
    /// `originals` holds dropped images, which aren't in your library. Those skip the on-device
    /// text check and are never removed from Photos.
    private func process(
        _ group: [PhotoCandidate], apiKey: String, originals: [String: Data] = [:]
    ) async throws -> (added: Int, failed: Int, saved: [String]) {
        let isDrop = !originals.isEmpty
        var failed = 0
        var prepared: [PreparedPhoto] = []
        for candidate in group {
            do {
                prepared.append(try await prepare(candidate, original: originals[candidate.id]))
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
        let worthSending = isDrop || prepared.contains(where: \.worthSending)
        for photo in prepared where !isDrop && (!worthSending || !photo.hasText) {
            record(photo.candidate.id, status: .skippedByFilter)
        }
        let sending = isDrop ? prepared : worthSending ? prepared.filter(\.hasText) : []
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
        // Photos read together can show separate flyers. Each becomes its own flyer, with only
        // the photos that show it, so every event has the right picture.
        var added = 0
        var saved: [String] = []
        // Photos some flyer couldn't save a copy of, which must stay in your library.
        var unsaved: Set<String> = []
        var fingerprints = Set(document.events.map(\.fingerprint))
        for extracted in result.flyers {
            let numbers = Set(extracted.photosUsed.filter { (1...sending.count).contains($0) })
            // Without photo numbers, a lone flyer had them all. With several, the first is the best guess.
            let used = numbers.isEmpty
                ? (result.flyers.count == 1 ? sending : [sending[0]])
                : sending.enumerated().filter { numbers.contains($0.offset + 1) }.map(\.element)
            let main = used[0]
            let flyerID = UUID()
            var new = Ingest.events(
                from: result.only(extracted), flyerID: flyerID, takenOn: takenOn, today: .today,
                settings: document.settings, existingFingerprints: fingerprints
            )
            for index in new.indices { new[index].ownerDevice = deviceID }
            guard !new.isEmpty else { continue }
            fingerprints.formUnion(new.map(\.fingerprint))
            var thumbnailName: String?
            if let thumbnail = main.thumbnail {
                let name = "\(flyerID.uuidString).jpg"
                try? store.saveThumbnail(thumbnail, name: name)
                thumbnailName = name
            }
            let usedIDs = used.map(\.candidate.id)
            let files = savePhotos(used.map(\.original), flyerID: flyerID)
            if files == nil {
                unsaved.formUnion(usedIDs)
            } else if !isDrop {
                saved += usedIDs.filter { !saved.contains($0) }
            }
            document.flyers.append(Flyer(
                id: flyerID, assetID: main.candidate.id, takenAt: main.candidate.takenAt, title: extracted.flyerTitle,
                reason: result.reason, confidence: result.confidence, thumbnailFile: thumbnailName,
                assetIDs: usedIDs.count > 1 ? usedIDs : nil,
                latitude: coordinates?.latitude, longitude: coordinates?.longitude,
                photoFiles: files,
                photosInLibrary: isDrop ? false : nil
            ))
            document.events.append(contentsOf: new)
            added += new.count
        }
        // A photo only leaves your library once every flyer that shows it has its own copy.
        saved.removeAll(where: unsaved.contains)
        for id in ids { record(id, status: .extracted) }
        flushQueue()
        return (added, failed, saved)
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

    /// Flyers whose originals may still be in your Photos library.
    public var flyersStillInLibrary: [Flyer] {
        document.flyers.filter { $0.mayBeInLibrary && $0.assetID != "demo" && !$0.assetID.hasPrefix("dropped:") }
    }

    /// Copies photos only in your library into Flyers, without touching the library, so deleting
    /// them from Photos later never loses them. Returns how many flyers it saved photos for.
    @discardableResult
    public func cacheLibraryPhotos() async -> Int {
        var count = 0
        for flyer in flyersOnlyInLibrary where await copyIntoFlyers(flyer) {
            count += 1
        }
        persist()
        return count
    }

    /// Saves a flyer's photos here if they aren't already. False if they couldn't be read.
    private func copyIntoFlyers(_ flyer: Flyer) async -> Bool {
        guard flyer.photoFiles == nil else { return true }
        var found: [(id: String, data: Data)] = []
        for id in flyer.allAssetIDs {
            if let data = try? await photos.imageData(id: id) { found.append((id, data)) }
        }
        guard let index = document.flyers.firstIndex(where: { $0.id == flyer.id }) else { return false }
        guard !found.isEmpty else {
            // Already gone from your library, so there's nothing left to copy.
            document.flyers[index].photosInLibrary = false
            return false
        }
        guard let files = savePhotos(found.map(\.data), flyerID: flyer.id) else { return false }
        // Photos already deleted from your library are dropped, keeping what's left.
        if found.count < flyer.allAssetIDs.count {
            let ids = found.map(\.id)
            document.flyers[index].assetID = ids[0]
            document.flyers[index].assetIDs = ids.count > 1 ? ids : nil
        }
        document.flyers[index].photoFiles = files
        return true
    }

    /// Removes one flyer's photos from your Photos library, keeping a copy here and all its events.
    public func removeFromLibrary(flyerID: UUID) async {
        guard let flyer = flyer(id: flyerID), flyer.mayBeInLibrary else { return }
        guard await copyIntoFlyers(flyer) else {
            persist()
            alertMessage = "Couldn't save a copy of the photo, so it was left in Photos."
            return
        }
        persist()
        await removeFromLibrary(flyer.allAssetIDs)
    }

    public var savedPhotoNames: [String] { document.flyers.flatMap { $0.photoFiles ?? [] } }

    /// Copies older flyers' photos into Flyers, then removes them from your library.
    /// Returns how many flyers' photos were moved.
    @discardableResult
    public func moveOlderPhotosIntoFlyers() async -> Int {
        var moved: [String] = []
        var count = 0
        for flyer in flyersStillInLibrary where await copyIntoFlyers(flyer) {
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

    private func record(
        _ id: String, status: PhotoStatus, error: String? = nil, attempts: Int? = nil, claimedBy: String? = nil
    ) {
        let previous = document.photos[id]?.attempts ?? 0
        document.photos[id] = PhotoRecord(
            status: status, attempts: attempts ?? previous + 1, lastError: error, processedAt: Date(),
            cloudID: cloudIDs[id] ?? document.photos[id]?.cloudID, claimedBy: claimedBy
        )
        persist()
    }

    // MARK: Calendar

    /// Adds anything waiting. Without a calendar yet, events simply wait for one.
    public func flushQueue() {
        guard calendar.isReady else { return }
        // Another device's queued events are its to add, so they never land on Calendar twice.
        for index in document.events.indices where document.events[index].state == .queued && isOwnedHere(document.events[index]) {
            do {
                let itemID = try calendar.add(
                    document.events[index], alertMinutesBefore: document.settings.alertMinutesBefore
                )
                document.events[index].calendarItemID = itemID
                document.events[index].calendarExternalID = calendar.externalID(itemID: itemID)
                document.events[index].missingFromCalendarSince = nil
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
            $0.ownerDevice = deviceID
        }
        flushQueue()
    }

    /// Removes an event from the calendar but keeps it in the app.
    public func removeFromCalendar(_ id: UUID) {
        guard let event = event(id: id), let itemID = calendarItemID(for: event) else { return }
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
            if let itemID = calendarItemID(for: event) { try? calendar.remove(itemID: itemID) }
            change(id) {
                $0.stateBeforeDelete = $0.state
                $0.state = .deleted
                $0.deletedAt = Date()
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
                $0.deletedAt = nil
                if $0.state == .queued { $0.ownerDevice = deviceID }
            }
        }
        lastDeletedIDs = []
        flushQueue()
        persist()
    }

    public func dismissUndo() { lastDeletedIDs = [] }

    /// Events you deleted here or that left Calendar in the last 30 days, most recently deleted
    /// first, so they can be brought back.
    public var hiddenEvents: [FlyerEvent] { recentlyDeleted() }

    /// Older ones drop off the list. Their records stay, so a rescan or another device can't bring
    /// them back.
    public func recentlyDeleted(now: Date = Date()) -> [FlyerEvent] {
        document.events
            .filter { $0.isHidden && now.timeIntervalSince($0.deletedAt ?? now) < FlyersEngine.deletedKeptFor }
            .sorted { ($0.deletedAt ?? now) > ($1.deletedAt ?? now) }
    }

    /// Brings hidden events back. One deleted here goes back where it was. One that left Calendar
    /// stays off it, since it may still be there under a new ID; Add to Calendar puts it back.
    public func restore(_ ids: [UUID]) {
        for id in ids {
            change(id) {
                switch $0.state {
                case .deleted:
                    let previous = $0.stateBeforeDelete ?? .available
                    $0.state = previous == .onCalendar ? .queued : previous
                    if $0.state == .queued { $0.ownerDevice = deviceID }
                case .removedInCalendar:
                    $0.state = .available
                default:
                    return
                }
                $0.stateBeforeDelete = nil
                $0.missingFromCalendarSince = nil
                $0.deletedAt = nil
            }
        }
        flushQueue()
        persist()
    }

    /// Applies your edits here and in Calendar. Your edit counts as checking the event.
    public func edit(_ id: UUID, _ apply: (inout FlyerEvent) -> Void) {
        change(id) {
            apply(&$0)
            $0.problems.removeAll()
            $0.locationInferred = false
            $0.startUncertain = false
        }
        if let event = event(id: id), let itemID = calendarItemID(for: event) {
            do {
                try calendar.update(event, itemID: itemID)
            } catch {
                alertMessage = "Couldn't update Calendar: \(error)"
            }
        }
        persist()
    }

    /// Picks up changes you made in Calendar. Your changes there win.
    /// How long an event has to stay missing from Calendar before Flyers treats it as removed.
    /// Calendar can briefly lose track of events while iCloud syncs.
    public static let missingGracePeriod: TimeInterval = 3600

    public func reconcileWithCalendar(now: Date = Date()) {
        guard calendar.isReady else { return }
        var changed = false
        for index in document.events.indices {
            var event = document.events[index]
            // Only the owner reads Calendar's changes back, so a sync that arrives before Calendar's
            // own can't make another device undo an edit.
            guard event.state == .onCalendar, isOwnedHere(event), var itemID = event.calendarItemID else { continue }
            var snapshot = calendar.snapshot(itemID: itemID)
            // A sync can give the event a new ID. Its cross-device ID still finds it.
            if snapshot == nil, let externalID = event.calendarExternalID, let found = calendar.itemID(externalID: externalID) {
                itemID = found
                snapshot = calendar.snapshot(itemID: found)
                document.events[index].calendarItemID = found
                changed = true
            }
            guard let snapshot else {
                if let since = event.missingFromCalendarSince {
                    if now.timeIntervalSince(since) >= FlyersEngine.missingGracePeriod {
                        document.events[index].state = .removedInCalendar
                        document.events[index].deletedAt = now
                        document.events[index].calendarItemID = nil
                        document.events[index].missingFromCalendarSince = nil
                        changed = true
                    }
                } else {
                    document.events[index].missingFromCalendarSince = now
                    changed = true
                }
                continue
            }
            if event.missingFromCalendarSince != nil {
                document.events[index].missingFromCalendarSince = nil
                changed = true
            }
            // Events added before cross-device IDs were saved get theirs now.
            if event.calendarExternalID == nil, let externalID = calendar.externalID(itemID: itemID) {
                document.events[index].calendarExternalID = externalID
                event.calendarExternalID = externalID
                changed = true
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

    /// Flyers used to hold back repeating events on a flyer with three or more of them, for you to
    /// add by hand. Those now go to the calendar like everything else, once.
    public func addHeldScheduleEventsIfNeeded(today: Day = .today) {
        guard document.heldEventsAdded != true else { return }
        let held = document.events.filter { $0.state == .available && $0.rrule != nil && $0.calendarItemID == nil }
        let counts = Dictionary(grouping: held, by: \.flyerID).mapValues(\.count)
        for event in held where (counts[event.flyerID] ?? 0) >= 3 && !event.isOver(today: today) {
            change(event.id) { $0.state = .queued }
        }
        document.heldEventsAdded = true
        flushQueue()
    }

    /// Where a link should land. Nil if the event no longer exists here.
    public func eventForLink(_ url: URL) -> FlyerEvent? {
        guard let id = AppLink.eventID(from: url), let found = event(id: id), !found.isHidden else { return nil }
        return found
    }

    // MARK: Plumbing

    /// Saves what a sync brought in, then adds anything now waiting for this device's calendar.
    func saveFromSync() {
        persist()
        flushQueue()
    }

    /// Changes settings without counting it as a change to send back.
    func updateSettingsFromSync(_ change: (inout AppSettings) -> Void) {
        change(&document.settings)
    }

    func photosCloudIDs(for localIDs: [String]) -> [String: String] {
        photos.cloudIDs(forLocal: localIDs.filter { !$0.hasPrefix("cloud:") && $0 != "demo" && !$0.hasPrefix("dropped:") })
    }

    func photosLocalIDs(for cloudIDs: [String]) -> [String: String] {
        photos.localIDs(forCloud: Array(Set(cloudIDs)))
    }

    /// Events from before sync have no owner, which every device would read as its own. The
    /// device that already has them, when it starts syncing, makes them its own before sending.
    public func claimUnownedEvents() {
        guard document.events.contains(where: { $0.ownerDevice == nil }) else { return }
        for index in document.events.indices where document.events[index].ownerDevice == nil {
            document.events[index].ownerDevice = deviceID
        }
        persist()
    }

    /// Photos read before sync were recorded without their iCloud Photos ID, which is how other
    /// devices know not to read them again. Fills it in for the ones still in Photos.
    public func fillPhotoCloudIDs() {
        let missing = document.photos.filter { $0.value.cloudID == nil && !$0.key.hasPrefix("cloud:") }.map(\.key)
        guard !missing.isEmpty else { return }
        let found = photosCloudIDs(for: missing)
        guard !found.isEmpty else { return }
        for (id, cloudID) in found { document.photos[id]?.cloudID = cloudID }
        persist()
    }

    /// Whether this device adds the event to Calendar and watches Calendar for it.
    public func isOwnedHere(_ event: FlyerEvent) -> Bool {
        event.ownerDevice == nil || event.ownerDevice == deviceID
    }

    /// The event's Calendar entry on this device. One another device added is found by its
    /// cross-device ID, since Calendar gives it a different item ID here.
    private func calendarItemID(for event: FlyerEvent) -> String? {
        event.calendarItemID ?? event.calendarExternalID.flatMap { calendar.itemID(externalID: $0) }
    }

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
        if !isApplyingSync { sync?.changed() }
    }
}

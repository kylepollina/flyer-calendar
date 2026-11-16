import CryptoKit
import Foundation

// Sync between your devices, kept separate from how records travel, so the merge rules run in
// tests with a fake cloud. `CloudSync` carries them through iCloud.
//
// The rules:
// - Each flyer, event and read photo is its own record, so a change on one device and a scan on the
//   other don't overwrite each other. The later change to a record wins.
// - Photos are matched across devices by iCloud Photos' cloud ID, so a photo read on one device is
//   never paid for again on the other. A device claims photos before reading them.
// - Only an event's owner, the device that found it, adds it to Calendar. Calendar syncs itself
//   through iCloud, so the other devices find it there by its cross-device ID.
// - Things that only make sense on one device stay there: Calendar item IDs, the chosen calendar,
//   the scan start date and spending.

/// How the engine reaches the cloud. The engine tells it when something changed, and asks it to
/// send or fetch at points where order matters, such as claiming photos before reading them.
@MainActor
public protocol SyncConnection: AnyObject {
    /// Something changed. Send it soon.
    func changed()
    /// Sends everything waiting, and returns once it's done or has failed.
    func pushNow() async
    /// Fetches what other devices changed, and returns once it's applied.
    func fetchNow() async
    /// Whether a flyer and its photos have reached iCloud, so its originals can safely leave Photos.
    func isUploaded(flyerID: UUID) -> Bool
}

public enum SyncKind: String, Codable, Sendable {
    case event, flyer, photo, settings
}

/// One synced thing, as it travels.
public struct SyncRecord: Equatable, Sendable {
    /// Unique across kinds, such as "event-<id>".
    public var name: String
    public var kind: SyncKind
    /// When it last changed on the device that sent it. The later change wins.
    public var modifiedAt: Date
    public var payload: Data
    /// Files a flyer carries, its saved photos and preview, by file name.
    public var files: [String: URL]

    public init(name: String, kind: SyncKind, modifiedAt: Date, payload: Data, files: [String: URL] = [:]) {
        self.name = name
        self.kind = kind
        self.modifiedAt = modifiedAt
        self.payload = payload
        self.files = files
    }

    public var payloadHash: String { SyncLedger.hash(payload) }
}

/// What this device last sent or received for each record, so only real changes travel.
public struct SyncLedger: Codable, Equatable, Sendable {
    /// Each record's payload as last sent or received, hashed.
    public var hashes: [String: String] = [:]
    public var modifiedAt: [String: Date] = [:]
    /// CloudKit's metadata for each record, to save a change over the version it last saw.
    public var systemFields: [String: Data] = [:]
    /// CloudKit's own sync state.
    public var engineState: Data?

    public init() {}

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Records a record as matching the cloud, whether sent from here or received.
    public mutating func settle(_ record: SyncRecord) {
        hashes[record.name] = record.payloadHash
        modifiedAt[record.name] = record.modifiedAt
    }
}

/// The settings that make sense on every device. The chosen calendar, the scan start date and
/// launch at login stay on each device.
struct SyncedSettings: Codable, Equatable {
    var addMode: AddMode
    var alertMinutesBefore: Int
    var monthlySpendLimit: Double
    var includeScreenshots: Bool
    var removePhotosFromLibrary: Bool?

    init(_ settings: AppSettings) {
        addMode = settings.addMode
        alertMinutesBefore = settings.alertMinutesBefore
        monthlySpendLimit = settings.monthlySpendLimit
        includeScreenshots = settings.includeScreenshots
        removePhotosFromLibrary = settings.removePhotosFromLibrary
    }

    func apply(to settings: inout AppSettings) {
        settings.addMode = addMode
        settings.alertMinutesBefore = alertMinutesBefore
        settings.monthlySpendLimit = monthlySpendLimit
        settings.includeScreenshots = includeScreenshots
        settings.removePhotosFromLibrary = removePhotosFromLibrary
    }
}

enum SyncCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // The same data always encodes the same, so its hash shows whether it changed.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension FlyersEngine {
    public static let settingsRecordName = "settings"

    public static func recordName(event id: UUID) -> String { "event-\(id.uuidString)" }
    public static func recordName(flyer id: UUID) -> String { "flyer-\(id.uuidString)" }
    public static func recordName(photo cloudID: String) -> String { "photo-\(cloudID)" }

    /// Everything that syncs, as it is now.
    func currentSyncRecords(now: Date, ledger: SyncLedger) -> [SyncRecord] {
        func make(_ name: String, _ kind: SyncKind, _ value: some Encodable, files: [String: URL] = [:]) -> SyncRecord? {
            guard let payload = try? SyncCoding.encoder.encode(value) else { return nil }
            return SyncRecord(name: name, kind: kind, modifiedAt: ledger.modifiedAt[name] ?? now, payload: payload, files: files)
        }
        var output: [SyncRecord] = []
        for event in document.events {
            var shared = event
            // Item IDs and the missing-from-Calendar clock are only meaningful on this device.
            shared.calendarItemID = nil
            shared.missingFromCalendarSince = nil
            if let record = make(FlyersEngine.recordName(event: event.id), .event, shared) { output.append(record) }
        }
        let cloud = photosCloudIDs(for: document.flyers.flatMap(\.allAssetIDs))
        for flyer in document.flyers {
            var shared = flyer
            // Photos' local IDs differ on each device, so the cloud ID travels instead.
            shared.assetID = cloud[flyer.assetID].map(FlyersEngine.cloudKey) ?? flyer.assetID
            shared.assetIDs = flyer.assetIDs?.map { id in cloud[id].map(FlyersEngine.cloudKey) ?? id }
            var files: [String: URL] = [:]
            for name in flyer.photoFiles ?? [] { files[name] = store.photoURL(name) }
            if let name = flyer.thumbnailFile { files[name] = store.thumbnailsDirectory.appendingPathComponent(name) }
            if let record = make(FlyersEngine.recordName(flyer: flyer.id), .flyer, shared, files: files) { output.append(record) }
        }
        // One record per photo, however many devices read it. Ones only another device could see
        // wait under their cloud ID and travel as they arrived.
        var photos: [String: PhotoRecord] = [:]
        for (key, record) in document.photos {
            guard let cloudID = record.cloudID else { continue }
            let name = FlyersEngine.recordName(photo: cloudID)
            if photos[name] == nil || !key.hasPrefix("cloud:") { photos[name] = record }
        }
        for (name, record) in photos.sorted(by: { $0.key < $1.key }) {
            if let made = make(name, .photo, record) { output.append(made) }
        }
        if let record = make(FlyersEngine.settingsRecordName, .settings, SyncedSettings(document.settings)) {
            output.append(record)
        }
        return output
    }

    /// What changed here since it last matched the cloud. Each gets this moment as its change time.
    public func outgoingSyncChanges(ledger: inout SyncLedger, now: Date = Date()) -> [SyncRecord] {
        var changes: [SyncRecord] = []
        for var record in currentSyncRecords(now: now, ledger: ledger) where ledger.hashes[record.name] != record.payloadHash {
            record.modifiedAt = now
            ledger.modifiedAt[record.name] = now
            changes.append(record)
        }
        return changes
    }

    /// Applies what other devices changed. A record changed here more recently, and not yet sent,
    /// keeps this device's version, which goes out next.
    ///
    /// Saving here doesn't call the connection's `changed()`, since the connection is in the middle
    /// of lending its ledger. It calls `changed()` itself afterwards, to send anything this changed,
    /// such as an event added to Calendar.
    public func applySyncRecords(_ records: [SyncRecord], ledger: inout SyncLedger) {
        guard !records.isEmpty else { return }
        isApplyingSync = true
        defer { isApplyingSync = false }
        let current = Dictionary(currentSyncRecords(now: Date(), ledger: ledger).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let cloudToLocal = photosLocalIDs(for: records.flatMap(cloudIDs(in:)))
        var applied = false
        for record in records {
            let unsentHere = current[record.name].map { ledger.hashes[record.name] != $0.payloadHash } ?? false
            if unsentHere, let mine = ledger.modifiedAt[record.name], mine > record.modifiedAt { continue }
            if apply(record, cloudToLocal: cloudToLocal) { applied = true }
            ledger.settle(record)
        }
        if applied { saveFromSync() }
    }

    private func cloudIDs(in record: SyncRecord) -> [String] {
        switch record.kind {
        case .photo:
            return [String(record.name.dropFirst("photo-".count))]
        case .flyer:
            guard let flyer = try? SyncCoding.decoder.decode(Flyer.self, from: record.payload) else { return [] }
            return flyer.allAssetIDs.filter { $0.hasPrefix("cloud:") }.map { String($0.dropFirst("cloud:".count)) }
        default:
            return []
        }
    }

    /// Applies one record. False if it couldn't be read.
    private func apply(_ record: SyncRecord, cloudToLocal: [String: String]) -> Bool {
        let decoder = SyncCoding.decoder
        switch record.kind {
        case .event:
            guard var event = try? decoder.decode(FlyerEvent.self, from: record.payload) else { return false }
            if let index = document.events.firstIndex(where: { $0.id == event.id }) {
                // This device's link to the Calendar entry stays.
                event.calendarItemID = document.events[index].calendarItemID
                event.missingFromCalendarSince = document.events[index].missingFromCalendarSince
                document.events[index] = event
            } else {
                document.events.append(event)
            }
            return true
        case .flyer:
            guard var flyer = try? decoder.decode(Flyer.self, from: record.payload) else { return false }
            let local = { (id: String) -> String in
                guard id.hasPrefix("cloud:") else { return id }
                return cloudToLocal[String(id.dropFirst("cloud:".count))] ?? id
            }
            flyer.assetID = local(flyer.assetID)
            flyer.assetIDs = flyer.assetIDs?.map(local)
            for (name, url) in record.files {
                let destination = name == flyer.thumbnailFile
                    ? store.thumbnailsDirectory.appendingPathComponent(name)
                    : store.photoURL(name)
                guard url != destination, !FileManager.default.fileExists(atPath: destination.path) else { continue }
                try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: url, to: destination)
            }
            // Files that didn't arrive aren't listed, so the viewer falls back to the preview.
            flyer.photoFiles = flyer.photoFiles?.filter { FileManager.default.fileExists(atPath: store.photoURL($0).path) }
            if flyer.photoFiles?.isEmpty == true { flyer.photoFiles = nil }
            if let index = document.flyers.firstIndex(where: { $0.id == flyer.id }) {
                document.flyers[index] = flyer
            } else {
                document.flyers.append(flyer)
            }
            return true
        case .photo:
            guard var photo = try? decoder.decode(PhotoRecord.self, from: record.payload) else { return false }
            let cloudID = String(record.name.dropFirst("photo-".count))
            photo.cloudID = cloudID
            let key = cloudToLocal[cloudID] ?? FlyersEngine.cloudKey(cloudID)
            document.photos[key] = photo
            // Once the photo is matched here, its stand-in under the cloud ID isn't needed.
            if key != FlyersEngine.cloudKey(cloudID) { document.photos[FlyersEngine.cloudKey(cloudID)] = nil }
            return true
        case .settings:
            guard let settings = try? decoder.decode(SyncedSettings.self, from: record.payload) else { return false }
            updateSettingsFromSync { settings.apply(to: &$0) }
            return true
        }
    }
}

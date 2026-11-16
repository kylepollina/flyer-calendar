import CloudKit
import Combine
import Foundation

/// Carries sync records through iCloud, in a zone of your private CloudKit database, with
/// `CKSyncEngine` doing the scheduling, retries and change tracking.
///
/// Needs the app to have the iCloud (CloudKit) entitlement for `containerID`. Without it, CloudKit
/// stops the app, so this is only created once the app is signed for iCloud.
@MainActor
public final class CloudSync: ObservableObject, SyncConnection {
    public static let zoneName = "Flyers"

    /// The last problem, such as being signed out of iCloud, for Settings to show.
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastSyncAt: Date?

    private weak var engine: FlyersEngine?
    private var syncEngine: CKSyncEngine?
    /// Kept here, since CloudKit doesn't keep its delegate alive.
    private var delegate: Delegate?
    private var ledger: SyncLedger
    private let ledgerURL: URL
    private let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName)
    /// Records waiting to be sent, by name.
    private var pending: [String: SyncRecord] = [:]

    public init(engine: FlyersEngine, containerID: String) {
        self.engine = engine
        ledgerURL = engine.store.directory.appendingPathComponent("sync.json")
        ledger = (try? Data(contentsOf: ledgerURL)).flatMap { try? JSONDecoder().decode(SyncLedger.self, from: $0) } ?? SyncLedger()

        let saved = ledger.engineState.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let delegate = Delegate(self)
        self.delegate = delegate
        let configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: containerID).privateCloudDatabase,
            stateSerialization: saved,
            delegate: delegate
        )
        let syncEngine = CKSyncEngine(configuration)
        self.syncEngine = syncEngine
        if saved == nil {
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        engine.claimUnownedEvents()
        engine.fillPhotoCloudIDs()
        engine.sync = self
        changed()
        Task { await checkAccount(containerID) }
    }

    /// Reads the container's ID from Info.plist, where only builds signed for iCloud list it.
    /// Without the entitlement, CloudKit would stop the app.
    public static var containerIDFromInfo: String? {
        Bundle.main.object(forInfoDictionaryKey: "FlyersCloudContainer") as? String
    }

    private func checkAccount(_ containerID: String) async {
        switch try? await CKContainer(identifier: containerID).accountStatus() {
        case .available: break
        case .noAccount: lastError = "Sign in to iCloud to sync with your other devices."
        case .restricted: lastError = "iCloud is restricted on this device."
        case .temporarilyUnavailable: lastError = "iCloud is unavailable right now."
        default: lastError = "Couldn't check your iCloud account."
        }
    }

    // MARK: SyncConnection

    public func changed() {
        guard let engine, let syncEngine else { return }
        let changes = engine.outgoingSyncChanges(ledger: &ledger)
        guard !changes.isEmpty else { return }
        for record in changes { pending[record.name] = record }
        syncEngine.state.add(pendingRecordZoneChanges: changes.map { .saveRecord(recordID($0.name)) })
        saveLedger()
    }

    public func pushNow() async {
        changed()
        do {
            try await syncEngine?.sendChanges()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func fetchNow() async {
        do {
            try await syncEngine?.fetchChanges()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func isUploaded(flyerID: UUID) -> Bool {
        let name = FlyersEngine.recordName(flyer: flyerID)
        return pending[name] == nil && ledger.hashes[name] != nil
    }

    // MARK: Events

    fileprivate func handle(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let update):
            ledger.engineState = try? JSONEncoder().encode(update.stateSerialization)
            saveLedger()

        case .accountChange(let change):
            if case .signOut = change.changeType {
                lastError = "Signed out of iCloud. Flyers keeps everything on this device until you sign back in."
            }

        case .fetchedRecordZoneChanges(let fetched):
            let records = fetched.modifications.map(\.record)
            for record in records { ledger.systemFields[record.recordID.recordName] = systemFields(of: record) }
            let incoming = records.compactMap(syncRecord(from:))
            engine?.applySyncRecords(incoming, ledger: &ledger)
            lastSyncAt = Date()
            lastError = nil
            saveLedger()

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                let name = record.recordID.recordName
                ledger.systemFields[name] = systemFields(of: record)
                if let sentRecord = pending.removeValue(forKey: name) { ledger.settle(sentRecord) }
            }
            for failure in sent.failedRecordSaves {
                resolve(failure.record, error: failure.error)
            }
            lastSyncAt = Date()
            saveLedger()

        default:
            break
        }
    }

    /// The cloud had a newer version, or something went wrong. The later change wins.
    private func resolve(_ record: CKRecord, error: CKError) {
        let name = record.recordID.recordName
        switch error.code {
        case .serverRecordChanged:
            guard let server = error.serverRecord else { return }
            ledger.systemFields[name] = systemFields(of: server)
            let theirs = server["modifiedAt"] as? Date ?? .distantPast
            if let mine = pending[name], mine.modifiedAt > theirs {
                // Ours is newer, so send it again over their version.
                syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            } else {
                pending[name] = nil
                if let incoming = syncRecord(from: server) { engine?.applySyncRecords([incoming], ledger: &ledger) }
            }
        case .zoneNotFound:
            syncEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        case .unknownItem:
            // Deleted in the cloud, so save it fresh.
            ledger.systemFields[name] = nil
            syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        default:
            lastError = error.localizedDescription
        }
    }

    // MARK: Records

    fileprivate func ckRecord(for id: CKRecord.ID) -> CKRecord? {
        guard let record = pending[id.recordName] else {
            // Sent already, or replaced by a newer change that's queued under the same name.
            syncEngine?.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            return nil
        }
        let ckRecord = ledger.systemFields[record.name].flatMap(Self.record(fromSystemFields:))
            ?? CKRecord(recordType: record.kind.rawValue, recordID: id)
        ckRecord["kind"] = record.kind.rawValue
        ckRecord["modifiedAt"] = record.modifiedAt
        ckRecord["payload"] = record.payload
        let files = record.files.filter { FileManager.default.fileExists(atPath: $0.value.path) }.sorted { $0.key < $1.key }
        ckRecord["fileNames"] = files.isEmpty ? nil : files.map(\.key)
        ckRecord["files"] = files.isEmpty ? nil : files.map { CKAsset(fileURL: $0.value) }
        return ckRecord
    }

    private func syncRecord(from record: CKRecord) -> SyncRecord? {
        guard let kindName = record["kind"] as? String, let kind = SyncKind(rawValue: kindName),
              let payload = record["payload"] as? Data else { return nil }
        var files: [String: URL] = [:]
        if let names = record["fileNames"] as? [String], let assets = record["files"] as? [CKAsset] {
            for (name, asset) in zip(names, assets) {
                if let url = asset.fileURL { files[name] = url }
            }
        }
        return SyncRecord(
            name: record.recordID.recordName, kind: kind,
            modifiedAt: record["modifiedAt"] as? Date ?? .distantPast, payload: payload, files: files
        )
    }

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    private func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    private func saveLedger() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: ledgerURL, options: .atomic)
    }

    /// Receives CloudKit's callbacks, which come off the main thread, and hands them to `CloudSync`.
    private final class Delegate: CKSyncEngineDelegate, @unchecked Sendable {
        weak var owner: CloudSync?
        init(_ owner: CloudSync) { self.owner = owner }

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
            await MainActor.run { owner?.handle(event) }
        }

        func nextRecordZoneChangeBatch(
            _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
        ) async -> CKSyncEngine.RecordZoneChangeBatch? {
            let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
            guard !changes.isEmpty else { return nil }
            let owner = owner
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
                await MainActor.run { owner?.ckRecord(for: id) }
            }
        }
    }
}

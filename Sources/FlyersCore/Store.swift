import Foundation
import Security

/// Keeps everything in one JSON file. A personal library is small, so this stays simple,
/// and an atomic write means a crash can't leave a half-written file.
public struct DocumentStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flyers", isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("library.json") }
    public var thumbnailsDirectory: URL { directory.appendingPathComponent("Thumbnails", isDirectory: true) }

    public func load() -> AppDocument {
        guard let data = try? Data(contentsOf: fileURL) else { return AppDocument() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let document = try? decoder.decode(AppDocument.self, from: data) { return document }
        // Keep an unreadable library rather than overwriting its deleted-event records.
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.moveItem(at: fileURL, to: directory.appendingPathComponent("library.unreadable-\(stamp).json"))
        return AppDocument()
    }

    public func save(_ document: AppDocument) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }

    /// A random ID for this copy of the app, made once. Syncing devices use it to tell each other apart.
    public func deviceID() -> String {
        let url = directory.appendingPathComponent("device-id")
        if let saved = try? String(contentsOf: url, encoding: .utf8), !saved.isEmpty { return saved }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    public func saveThumbnail(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        try data.write(to: thumbnailsDirectory.appendingPathComponent(name), options: .atomic)
    }

    /// Full-size copies of flyer photos, kept here so they can leave your Photos library.
    public var photosDirectory: URL { directory.appendingPathComponent("Photos", isDirectory: true) }

    public func photoURL(_ name: String) -> URL { photosDirectory.appendingPathComponent(name) }

    public func savePhoto(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        try data.write(to: photoURL(name), options: .atomic)
    }

    public func deletePhoto(name: String) {
        try? FileManager.default.removeItem(at: photoURL(name))
    }

    /// Bytes used by saved photos.
    public func photosSize(_ names: [String]) -> Int64 {
        names.reduce(0) { total, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: photoURL(name).path)[.size] as? NSNumber)?.int64Value
            return total + (size ?? 0)
        }
    }
}

/// The Anthropic API key, in iCloud Keychain so you enter it once for all your devices.
///
/// Keys saved before it synced are in this device's own keychain. They're still read, and moved to
/// iCloud Keychain by `moveToICloud()`. Builds that can't reach iCloud Keychain, such as the Mac app
/// built by `build-app.sh`, which has no app identifier, keep using this device's keychain.
public enum APIKeyStore {
    private static let service = "app.flyers.anthropic-api-key"
    private static let account = "default"

    private static func query(synced: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if synced {
            query[kSecAttrSynchronizable as String] = true
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    public static func read() -> String? {
        read(synced: true) ?? read(synced: false)
    }

    private static func read(synced: Bool) -> String? {
        var search = query(synced: synced)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ key: String) -> Bool {
        if save(key, synced: true) {
            // The synced copy is the one read from now on.
            SecItemDelete(query(synced: false) as CFDictionary)
            return true
        }
        return save(key, synced: false)
    }

    private static func save(_ key: String, synced: Bool) -> Bool {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(synced: synced) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(synced: synced)
        add[kSecValueData as String] = data
        if synced { add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Moves a key saved before it synced into iCloud Keychain.
    public static func moveToICloud() {
        guard read(synced: true) == nil, let key = read(synced: false) else { return }
        _ = save(key)
    }

    /// Removes the key from every device.
    public static func delete() {
        SecItemDelete(query(synced: true) as CFDictionary)
        SecItemDelete(query(synced: false) as CFDictionary)
    }
}

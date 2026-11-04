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

    public func saveThumbnail(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        try data.write(to: thumbnailsDirectory.appendingPathComponent(name), options: .atomic)
    }
}

/// Stores the API key in your login Keychain.
public enum APIKeyStore {
    private static let service = "app.flyers.anthropic-api-key"
    private static let account = "default"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func read() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

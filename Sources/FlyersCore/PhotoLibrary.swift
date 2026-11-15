import Foundation
import Photos

public struct PhotoCandidate: Equatable, Sendable {
    public var id: String
    public var takenAt: Date
    public var latitude: Double?
    public var longitude: Double?
    /// Only screenshots are read together with ones taken moments before.
    public var isScreenshot: Bool

    public init(id: String, takenAt: Date, latitude: Double? = nil, longitude: Double? = nil, isScreenshot: Bool = false) {
        self.id = id
        self.isScreenshot = isScreenshot
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
    }
}

public protocol PhotoSource: Sendable {
    func candidates(since: Date, includeScreenshots: Bool) async -> [PhotoCandidate]
    func imageData(id: String) async throws -> Data
    /// Moves photos to Recently Deleted. Photos asks you to confirm, and this returns false
    /// if you decline.
    func delete(ids: [String]) async throws -> Bool
    /// iCloud Photos' cross-device IDs for photos in this library, by local ID.
    func cloudIDs(forLocal ids: [String]) -> [String: String]
    /// This library's local IDs for photos synced from another device, by cloud ID.
    func localIDs(forCloud ids: [String]) -> [String: String]
}

extension PhotoSource {
    public func cloudIDs(forLocal ids: [String]) -> [String: String] { [:] }
    public func localIDs(forCloud ids: [String]) -> [String: String] { [:] }
}

public struct PhotoLibrary: PhotoSource {
    public struct LoadError: Error, CustomStringConvertible {
        public let description: String
    }

    public init() {}

    public static var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    public static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    public func candidates(since: Date, includeScreenshots: Bool) async -> [PhotoCandidate] {
        guard PhotoLibrary.isAuthorized else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", since as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var output: [PhotoCandidate] = []
        assets.enumerateObjects { asset, _, _ in
            let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
            // Screenshots often hold private things like messages, so they're opt-in.
            if !includeScreenshots && isScreenshot { return }
            output.append(PhotoCandidate(
                id: asset.localIdentifier,
                takenAt: asset.creationDate ?? Date(),
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                isScreenshot: isScreenshot
            ))
        }
        return output
    }

    /// Moves photos to Recently Deleted. Photos asks you to confirm first.
    public func delete(ids: [String]) async throws -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        // Already gone, perhaps deleted by hand, which counts as done.
        guard assets.count > 0 else { return true }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return true
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return false
        }
    }

    public func cloudIDs(forLocal ids: [String]) -> [String: String] {
        guard !ids.isEmpty, PhotoLibrary.isAuthorized else { return [:] }
        var output: [String: String] = [:]
        for (local, result) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: ids) {
            if case .success(let cloud) = result { output[local] = cloud.stringValue }
        }
        return output
    }

    public func localIDs(forCloud ids: [String]) -> [String: String] {
        guard !ids.isEmpty, PhotoLibrary.isAuthorized else { return [:] }
        var output: [String: String] = [:]
        let cloud = ids.map(PHCloudIdentifier.init(stringValue:))
        for (identifier, result) in PHPhotoLibrary.shared().localIdentifierMappings(for: cloud) {
            if case .success(let local) = result { output[identifier.stringValue] = local }
        }
        return output
    }

    public func imageData(id: String) async throws -> Data {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw LoadError(description: "The photo is no longer in your library")
        }
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        // With Optimize Mac Storage on, the original may only be in iCloud.
        options.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    let detail = (info?[PHImageErrorKey] as? Error)?.localizedDescription ?? "The image couldn't be loaded"
                    continuation.resume(throwing: LoadError(description: detail))
                }
            }
        }
    }
}

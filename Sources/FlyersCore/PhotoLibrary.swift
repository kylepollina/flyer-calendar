import Foundation
import Photos

public struct PhotoCandidate: Equatable, Sendable {
    public var id: String
    public var takenAt: Date
    public var latitude: Double?
    public var longitude: Double?

    public init(id: String, takenAt: Date, latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
    }
}

public protocol PhotoSource: Sendable {
    func candidates(since: Date, includeScreenshots: Bool) async -> [PhotoCandidate]
    func imageData(id: String) async throws -> Data
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
            // Screenshots often hold private things like messages, so they're opt-in.
            if !includeScreenshots && asset.mediaSubtypes.contains(.photoScreenshot) { return }
            output.append(PhotoCandidate(
                id: asset.localIdentifier,
                takenAt: asset.creationDate ?? Date(),
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude
            ))
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

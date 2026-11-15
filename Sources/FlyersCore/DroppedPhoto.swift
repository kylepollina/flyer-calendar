import CryptoKit
import Foundation
import ImageIO

/// An image dropped on the window, from Finder, Photos or a browser.
public struct DroppedPhoto: Sendable {
    public var data: Data
    public var takenAt: Date?
    public var latitude: Double?
    public var longitude: Double?

    /// Screenshots from a Mac or iPhone are PNGs, while cameras save JPEG or HEIC. A file has
    /// nothing better to go on, and only screenshots are read together.
    public var isScreenshot: Bool { data.starts(with: [0x89, 0x50, 0x4E, 0x47]) }

    /// Reads when and where the photo was taken from its metadata. `fileDate`, such as a
    /// screenshot file's creation date, is the fallback when the photo doesn't say.
    public init(data: Data, fileDate: Date? = nil) {
        self.data = data
        takenAt = fileDate
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            takenAt = formatter.date(from: text) ?? takenAt
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            self.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -latitude : latitude
            self.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -longitude : longitude
        }
    }

    public init(data: Data, takenAt: Date?, latitude: Double? = nil, longitude: Double? = nil) {
        self.data = data
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The same image dropped twice gets the same ID, so it's never paid for twice.
    public var id: String {
        "dropped:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

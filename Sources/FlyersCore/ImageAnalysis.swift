import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public struct DetectedCode: Equatable, Sendable {
    public var value: String
    public var xPercent: Int
    public var yPercent: Int

    public init(value: String, xPercent: Int, yPercent: Int) {
        self.value = value
        self.xPercent = xPercent
        self.yPercent = yPercent
    }
}

/// Runs image work one job at a time on its own thread.
/// Vision blocks while it works, and blocking Swift's shared thread pool can deadlock it.
public enum ImageWorker {
    private static let queue = DispatchQueue(label: "app.flyers.image-worker", qos: .utility)

    public static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

public enum ImageTools {
    /// Decodes an image, upright and at most `maxEdge` pixels on its long side.
    public static func decode(_ data: Data, maxEdge: Int = 4096) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ] as CFDictionary)
    }

    /// Encodes a resized JPEG. It's built from pixels alone, so it carries no metadata.
    public static func jpeg(_ image: CGImage, maxEdge: Int, quality: Double = 0.85) -> Data? {
        let longest = max(image.width, image.height)
        let scale = min(1, Double(maxEdge) / Double(longest))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    public static func recognizeText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Decodes QR codes on this Mac. Positions let the model tell which flyer a code is on.
    public static func detectCodes(_ image: CGImage) throws -> [DetectedCode] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap { observation in
            guard let value = observation.payloadStringValue, seen.insert(value).inserted else { return nil }
            let box = observation.boundingBox
            // Vision measures from the bottom-left.
            return DetectedCode(
                value: value,
                xPercent: Int(((box.midX) * 100).rounded()),
                yPercent: Int(((1 - box.midY) * 100).rounded())
            )
        }
    }
}

/// Decides on this Mac which photos are worth sending to the API.
/// It only has to avoid missing flyers. The model rejects whatever else gets through.
public enum LocalFilter {
    public static let minimumLetters = 12

    private static let cuePatterns = [
        // Months and weekdays, including abbreviations.
        #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b"#,
        #"\b(mon|tue|tues|wed|weds|thu|thur|thurs|fri|sat|sun)(day|sday|nesday|rsday|urday)?s?\b"#,
        // 7pm, 7:30 pm, 19:30.
        #"\b\d{1,2}(:\d{2})?\s*(am|pm|a\.m|p\.m)\b"#,
        #"\b\d{1,2}:\d{2}\b"#,
        // 4.11, 4/11.
        #"\b\d{1,2}[./]\d{1,2}\b"#,
        #"\b(today|tonight|tomorrow|weekly|every|doors|tickets|rsvp|register)\b"#,
    ]

    public static func shouldSend(text: String, codeCount: Int) -> Bool {
        let letters = text.unicodeScalars.filter(CharacterSet.letters.contains).count
        guard letters >= minimumLetters else { return false }
        if codeCount > 0 { return true }
        let lowered = text.lowercased()
        return cuePatterns.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }
}

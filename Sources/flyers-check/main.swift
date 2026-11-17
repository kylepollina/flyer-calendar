// Runs the app's on-device filter and extraction over a folder of images, so changes can be
// checked against real flyers without the app or any Photos and Calendar access.
//
//   swift run flyers-check samples            on-device filter and QR only, nothing is sent
//   swift run flyers-check samples --api      also calls the API, using ANTHROPIC_API_KEY
//   swift run flyers-check samples --apple    reads them with Apple Intelligence instead
//   swift run flyers-check burst --api --together
//                                             sends every photo in the folder in one request, as the
//                                             app does with photos taken moments apart
import Foundation
import FlyersCore
import ImageIO

let arguments = CommandLine.arguments.dropFirst()
guard let folder = arguments.first(where: { !$0.hasPrefix("--") }) else {
    print("usage: flyers-check <folder> [--api] [--together]")
    exit(2)
}
let useApple = arguments.contains("--apple") || arguments.contains("--apple-device")
let useAPI = arguments.contains("--api") || useApple
let key = useApple ? "" : ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
if useApple, case .unavailable(let reason) = AppleIntelligenceReader.status {
    print("Apple Intelligence isn't available: \(reason)")
    exit(2)
}
if useAPI && !useApple && (key ?? "").isEmpty {
    print("--api needs ANTHROPIC_API_KEY")
    exit(2)
}

func metadata(_ url: URL) -> (Day, (latitude: Double, longitude: Double)?) {
    let fallback = Day.today
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return (fallback, nil)
    }
    var day = fallback
    if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
       let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
        day = Day(compact: text.replacingOccurrences(of: ":", with: "")) ?? fallback
    }
    var coordinates: (latitude: Double, longitude: Double)?
    if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
       let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
       let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
        coordinates = (
            (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -latitude : latitude,
            (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -longitude : longitude
        )
    }
    return (day, coordinates)
}

let root = URL(fileURLWithPath: folder)
let imageSuffixes: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
    .filter { imageSuffixes.contains($0.pathExtension.lowercased()) }
    .sorted { $0.path < $1.path }

let client: EventExtracting = useApple
    ? AppleIntelligenceReader(model: arguments.contains("--apple-device") ? .onDevice : .automatic)
    : AnthropicClient()

/// Prints what each flyer in an answer became.
func report(_ result: ExtractionResult, takenOn: Day) -> Int {
    print("  flyer=\(result.isEventFlyer) confidence=\(result.confidence.rawValue) reason=\(result.reason)")
    var count = 0
    for flyer in result.flyers {
        print("  FLYER \"\(flyer.flyerTitle ?? "-")\" from photos \(flyer.photosUsed)")
        let events = Ingest.events(
            from: result.only(flyer), flyerID: UUID(), takenOn: takenOn, today: takenOn, settings: AppSettings(), existingFingerprints: []
        )
        count += events.count
        for event in events {
            let when = [event.startDay?.iso, event.startTime, event.endDay?.iso, event.endTime].compactMap { $0 }.joined(separator: " ")
            print("    [\(event.state.rawValue)] \(event.name) | \(when) | rrule=\(event.rrule ?? "-") | \(event.location ?? "no location")\(event.locationInferred ? " (guess)" : "")")
            for link in event.allLinks { print("        \(link.label): \(link.url)") }
            for problem in event.problems { print("        check: \(problem)") }
        }
    }
    return count
}

if arguments.contains("--together") {
    guard useAPI, let key else {
        print("--together needs --api")
        exit(2)
    }
    var jpegs: [Data] = []
    var codesByPhoto: [[DetectedCode]] = []
    for (index, url) in files.enumerated() {
        guard let data = try? Data(contentsOf: url), let image = ImageTools.decode(data), let jpeg = ImageTools.jpeg(image, maxEdge: 1568) else {
            print("\(url.lastPathComponent): couldn't read")
            exit(1)
        }
        jpegs.append(jpeg)
        codesByPhoto.append(try ImageTools.detectCodes(image))
        print("Photo \(index + 1): \(url.lastPathComponent)")
    }
    guard let first = files.first else { exit(0) }
    let (takenOn, coordinates) = metadata(first)
    let context = PhotoContext(takenOn: takenOn, coordinates: coordinates, codesByPhoto: codesByPhoto)
    do {
        let (result, usage) = try await client.extract(jpegs: jpegs, context: context, apiKey: key)
        let count = report(result, takenOn: takenOn)
        print("\n\(files.count) photos in one request, \(result.flyers.count) flyers, \(count) events, $\(String(format: "%.4f", usage.cost))")
    } catch {
        print("failed: \(error)")
    }
    exit(0)
}
var totals = (sent: 0, flyers: 0, missedFlyers: 0, wronglyAccepted: 0, events: 0, cost: 0.0)

for url in files {
    let expectFlyer = !url.path.contains("not-flyers")
    guard let data = try? Data(contentsOf: url), let image = ImageTools.decode(data), let jpeg = ImageTools.jpeg(image, maxEdge: 1568) else {
        print("\(url.lastPathComponent): couldn't read")
        continue
    }
    let codes = try ImageTools.detectCodes(image)
    let text = try ImageTools.recognizeText(image)
    let send = LocalFilter.shouldSend(text: text, codeCount: codes.count)
    print("\n\(url.lastPathComponent) expected=\(expectFlyer ? "flyer" : "other") filter=\(send ? "send" : "skip") qr=\(codes.map(\.value))")
    if expectFlyer {
        totals.flyers += 1
        if !send { totals.missedFlyers += 1 }
    }
    guard send else { continue }
    totals.sent += 1
    guard useAPI, let key else { continue }

    let (takenOn, coordinates) = metadata(url)
    let context = PhotoContext(takenOn: takenOn, coordinates: coordinates, codes: codes)
    do {
        let (result, usage) = try await client.extract(jpeg: jpeg, context: context, apiKey: key)
        totals.cost += usage.cost
        if result.isEventFlyer != expectFlyer {
            if expectFlyer { totals.missedFlyers += 1 } else { totals.wronglyAccepted += 1 }
        }
        totals.events += report(result, takenOn: takenOn)
    } catch {
        print("  failed: \(error)")
    }
}

print("\n\(files.count) photos, \(totals.sent) passed the filter, \(totals.missedFlyers) of \(totals.flyers) flyers missed, \(totals.wronglyAccepted) wrongly accepted, \(totals.events) events, $\(String(format: "%.4f", totals.cost))")

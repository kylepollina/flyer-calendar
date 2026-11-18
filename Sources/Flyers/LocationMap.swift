import FlyersCore
import MapKit
import SwiftUI

/// A flyer's location, found on the map.
struct FoundPlace: Codable, Hashable, Sendable {
    var name: String?
    var address: String?
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }

    /// Opens the place, or directions to it, in Google Maps.
    /// Apple's own maps link, which the system opens in whichever maps app it uses for places.
    var appleMapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")!
        let query = [name, address].compactMap { $0 }.joined(separator: ", ")
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: query.isEmpty ? "\(latitude),\(longitude)" : query),
        ]
        return components.url
    }

    func googleMapsURL(directions: Bool) -> URL? {
        // The name and address find the actual place listing. Coordinates are the fallback.
        let query = [name, address].compactMap { $0 }.joined(separator: ", ")
        var components = URLComponents(string: directions ? "https://www.google.com/maps/dir/" : "https://www.google.com/maps/search/")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: directions ? "destination" : "query", value: query.isEmpty ? "\(latitude),\(longitude)" : query),
        ]
        return components.url
    }
}

/// Finds a flyer's location on the map, searching near where the photo was taken, or near where
/// you are for a photo with no location, like a screenshot. Results are saved, so the map of every
/// event doesn't search again each launch. Editing an event's location searches for the new text.
@MainActor
enum PlaceFinder {
    /// A saved miss is tried again after a while, since it may have been a network failure.
    private struct Entry: Codable {
        var place: FoundPlace?
        var searchedAt: Date
    }

    private static var entries: [String: Entry] = load()
    private static let fileURL = DocumentStore.defaultDirectory.appendingPathComponent("places.json")

    private static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func key(_ query: String, _ center: CLLocationCoordinate2D?) -> String {
        "\(query)|\(center.map { String(format: "%.2f,%.2f", $0.latitude, $0.longitude) } ?? "-")"
    }

    /// The saved answer, without searching.
    static func cached(for query: String, near center: CLLocationCoordinate2D?) -> FoundPlace? {
        entries[key(query, center)]?.place
    }

    static func place(for query: String, near center: CLLocationCoordinate2D?) async -> FoundPlace? {
        let key = key(query, center)
        if let entry = entries[key], entry.place != nil || entry.searchedAt.timeIntervalSinceNow > -7 * 86400 {
            return entry.place
        }
        // A screenshot has no photo location, so search near you instead: flyers you see are
        // usually for places nearby. Without either, a vague place like "Park pavilion" would match
        // somewhere random, so only a street address, which has a number, is specific enough.
        let center = center ?? CLLocationManager().location?.coordinate
        guard center != nil || query.contains(where: \.isNumber) else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        }
        guard let response = try? await MKLocalSearch(request: request).start() else {
            // Not saved, so a failed search is tried again next time.
            return nil
        }
        var place: FoundPlace?
        if let item = response.mapItems.first {
            let found = item.placemark.coordinate
            // A place far from the photo is more likely a different place with the same name.
            let isNear = center.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: CLLocation(latitude: found.latitude, longitude: found.longitude)) < 150_000
            } ?? true
            if isNear {
                place = FoundPlace(name: item.name, address: item.placemark.title, latitude: found.latitude, longitude: found.longitude)
            }
        }
        entries[key] = Entry(place: place, searchedAt: Date())
        if let data = try? JSONEncoder().encode(entries) {
            try? FileManager.default.createDirectory(at: DocumentStore.defaultDirectory, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
        return place
    }
}

/// A pin on the map of every event. A plain button, so a click or tap always selects it.
struct PinBadge: View {
    let count: Int
    let isUpcoming: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if count == 1 {
                    Image(systemName: "calendar")
                } else {
                    Text("\(count)").monospacedDigit()
                }
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(isUpcoming ? Color.accentColor : Color.gray, in: Circle())
            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .scaleEffect(isSelected ? 1.3 : 1)
            .animation(.snappy, value: isSelected)
            // A bigger target than the circle itself.
            .padding(8)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 1 ? "1 event here" : "\(count) events here")
    }
}

extension MKCoordinateRegion {
    /// A region showing every coordinate with some margin, and never closer than a neighborhood,
    /// so a map with one place doesn't zoom in to a single building.
    static func fitting(_ coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var minLatitude = first.latitude, maxLatitude = first.latitude
        var minLongitude = first.longitude, maxLongitude = first.longitude
        for coordinate in coordinates {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.4, 0.03),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.4, 0.03)
            )
        )
    }
}

extension Flyer {
    /// Where the photo was taken.
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Which app a tap on an event's map opens. Chosen in Settings, and kept on each device, since one
/// may have Google Maps and another not.
enum MapsApp: String, CaseIterable, Identifiable {
    case system, apple, google
    static let key = "mapsApp"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Device Default"
        case .apple: return "Apple Maps"
        case .google: return "Google Maps"
        }
    }
}

/// A still map of the event's place. Tapping it opens the place in the maps app chosen in
/// Settings, where you can get directions. Shows nothing when the place can't be found, so the
/// printed location stands alone.
struct LocationMap: View {
    let location: String
    let near: CLLocationCoordinate2D?
    @State private var place: FoundPlace?
    @State private var searched = false
    @AppStorage(MapsApp.key) private var mapsApp = MapsApp.system
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let place {
                VStack(alignment: .leading, spacing: 10) {
                    Button { open(place) } label: {
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: place.coordinate, latitudinalMeters: 900, longitudinalMeters: 900
                        )), interactionModes: []) {
                            Marker(place.name ?? location, coordinate: place.coordinate)
                        }
                        // The button takes every tap, so the map never pans or zooms.
                        .allowsHitTesting(false)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            Label(mapsApp == .google ? "Open in Google Maps" : "Open in Maps", systemImage: "arrow.up.forward.app")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.regularMaterial, in: Capsule())
                                .padding(8)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(place.name ?? location) in Maps")
                    if let address = place.address, address != location {
                        Text(address)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } else if !searched {
                // Holds the card's shape while searching, so the page doesn't jump much.
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 40)
            }
        }
        .task(id: location) {
            place = await PlaceFinder.place(for: location, near: near)
            searched = true
        }
    }

    private func open(_ place: FoundPlace) {
        switch mapsApp {
        case .system: if let url = place.appleMapsURL { openURL(url) }
        case .apple: place.mapItem.openInMaps()
        case .google: if let url = place.googleMapsURL(directions: false) { openURL(url) }
        }
    }
}

/// The Settings row choosing which maps app opens places.
struct MapsAppPicker: View {
    @AppStorage(MapsApp.key) private var mapsApp = MapsApp.system

    var body: some View {
        Picker("Open places in", selection: $mapsApp) {
            ForEach(MapsApp.allCases) { Text($0.title).tag($0) }
        }
    }
}

/// You on the map: a blue dot with a white ring and a soft glow, like Maps and Find My. Shared by
/// the Mac and iPhone maps, which pin it to the map like the events.
struct YouAreHere: View {
    /// Where you are now, once, or nil if Location is off or unavailable.
    static func currentLocation() async -> CLLocation? {
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if let location = update.location { return location }
                if update.authorizationDenied || update.authorizationDeniedGlobally { return nil }
            }
        } catch {}
        return nil
    }

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.blue.opacity(0.25))
                .frame(width: 44, height: 44)
                .scaleEffect(isPulsing ? 1 : 0.5)
                .opacity(isPulsing ? 0 : 1)
            Circle()
                .fill(.blue)
                .frame(width: 18, height: 18)
                .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { isPulsing = true }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("My location")
    }
}

/// A pin made of the flyer's photo, cropped square, with a point under it marking the spot and
/// the name under that. The name hangs below without changing the pin's size, so the point stays
/// on the place. A pin holding several events shows just their number in a circle instead.
/// Shared by the Mac and iPhone maps.
struct EventPin: View {
    let title: String
    let image: PlatformImage?
    let count: Int
    /// Every event in the pin comes from the same photo, so the photo says more than a number.
    var isOnePhoto = false
    let isSelected: Bool
    let action: () -> Void

    private let size: CGFloat = 58

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                if count > 1 && !isOnePhoto {
                    // Events from different photos: just how many, big. Zoom in and they split into photos.
                    Text("\(count)")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.accentColor, in: Circle())
                        .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                } else {
                    photo
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white, lineWidth: 3) }
                        // Several events from this one photo: a small count in the corner.
                        .overlay(alignment: .topTrailing) {
                            if count > 1 {
                                Text("\(count)")
                                    .font(.caption2.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .frame(minWidth: 20, minHeight: 20)
                                    .background(Color.accentColor, in: Circle())
                                    .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                                    .offset(x: 7, y: -7)
                            }
                        }
                }
                Image(systemName: "triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(180))
                    .offset(y: -3)
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .overlay(alignment: .bottom) {
                name.alignmentGuide(.bottom) { $0[.top] - 2 }
            }
            .scaleEffect(isSelected ? 1.2 : 1, anchor: .bottom)
            .animation(.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 1 ? title : "\(title), \(count) events")
    }

    @ViewBuilder private var photo: some View {
        if let image {
            Image(platformImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "calendar")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.accentColor)
        }
    }

    /// Plain text, like the map's own labels: a soft outline in the map's background color keeps
    /// it readable over streets and parks without a box behind it.
    private var name: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: 130)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: Color.appBackground, radius: 1)
            .shadow(color: Color.appBackground, radius: 1)
            .shadow(color: Color.appBackground, radius: 2)
    }
}

/// Saves the map's view as text, for `@AppStorage`. Shared by the Mac and iPhone maps.
enum MapLook {
    static func encode(_ region: MKCoordinateRegion) -> String {
        [region.center.latitude, region.center.longitude, region.span.latitudeDelta, region.span.longitudeDelta]
            .map { String($0) }.joined(separator: ",")
    }

    static func decode(_ text: String) -> MKCoordinateRegion? {
        let numbers = text.split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: numbers[0], longitude: numbers[1]),
            span: MKCoordinateSpan(latitudeDelta: numbers[2], longitudeDelta: numbers[3])
        )
    }
}

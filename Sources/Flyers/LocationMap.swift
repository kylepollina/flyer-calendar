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

/// Finds a flyer's location on the map, searching near where the photo was taken.
/// Results are saved, so the map of every event doesn't search again each launch.
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
        // With no photo location, as with screenshots, a vague place like "Park pavilion" matches
        // somewhere random. Only a street address, which has a number, is specific enough.
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

/// A map of the event's place, with buttons for directions in Apple Maps or Google Maps.
/// Shows nothing when the place can't be found, so the printed location stands alone.
struct LocationMap: View {
    let location: String
    let near: CLLocationCoordinate2D?
    @State private var place: FoundPlace?
    @State private var searched = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let place {
                VStack(alignment: .leading, spacing: 10) {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: place.coordinate, latitudinalMeters: 900, longitudinalMeters: 900
                    ))) {
                        Marker(place.name ?? location, coordinate: place.coordinate)
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if let address = place.address, address != location {
                        Text(address)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Menu {
                            Button("In Apple Maps") { openInAppleMaps(directions: true) }
                            Button("In Google Maps") { openInGoogleMaps(directions: true) }
                        } label: {
                            Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
                        }
                        .fixedSize()
                        Button("Apple Maps") { openInAppleMaps(directions: false) }
                        Button("Google Maps") { openInGoogleMaps(directions: false) }
                    }
                    .controlSize(.regular)
                    // Keeps three buttons on one line on a narrow iPhone.
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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

    private func openInAppleMaps(directions: Bool) {
        place?.mapItem.openInMaps(launchOptions: directions ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault] : nil)
    }

    private func openInGoogleMaps(directions: Bool) {
        if let url = place?.googleMapsURL(directions: directions) { openURL(url) }
    }
}

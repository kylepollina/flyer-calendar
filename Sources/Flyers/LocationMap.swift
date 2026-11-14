import AppKit
import FlyersCore
import MapKit
import SwiftUI

/// Finds a flyer's location on the map, searching near where the photo was taken.
/// Results are kept for the session, so moving between events doesn't search again.
@MainActor
enum PlaceFinder {
    private static var found: [String: MKMapItem?] = [:]

    static func place(for query: String, near center: CLLocationCoordinate2D?) async -> MKMapItem? {
        let key = "\(query)|\(center.map { "\($0.latitude),\($0.longitude)" } ?? "-")"
        if let cached = found[key] { return cached }
        // With no photo location, as with screenshots, a vague place like "Park pavilion" matches
        // somewhere random. Only a street address, which has a number, is specific enough.
        guard center != nil || query.contains(where: \.isNumber) else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        }
        let item = try? await MKLocalSearch(request: request).start().mapItems.first
        // A place far from the photo is more likely a different place with the same name.
        let result: MKMapItem? = {
            guard let item else { return nil }
            guard let center else { return item }
            let distance = CLLocation(latitude: center.latitude, longitude: center.longitude)
                .distance(from: CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude))
            return distance < 150_000 ? item : nil
        }()
        found[key] = result
        return result
    }
}

/// A map of the event's place, with buttons for directions in Apple Maps or Google Maps.
/// Shows nothing when the place can't be found, so the printed location stands alone.
struct LocationMap: View {
    let location: String
    let near: CLLocationCoordinate2D?
    @State private var place: MKMapItem?
    @State private var searched = false

    var body: some View {
        Group {
            if let place {
                VStack(alignment: .leading, spacing: 10) {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: place.placemark.coordinate, latitudinalMeters: 900, longitudinalMeters: 900
                    ))) {
                        Marker(place.name ?? location, coordinate: place.placemark.coordinate)
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if let address = address(of: place), address != location {
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

    private func address(of item: MKMapItem) -> String? {
        item.placemark.title
    }

    private func openInAppleMaps(directions: Bool) {
        guard let place else { return }
        place.openInMaps(launchOptions: directions ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault] : nil)
    }

    private func openInGoogleMaps(directions: Bool) {
        guard let place else { return }
        let coordinate = place.placemark.coordinate
        // The name and address find the actual place listing. Coordinates are the fallback.
        let query = [place.name, address(of: place)].compactMap { $0 }.joined(separator: ", ")
        var components = URLComponents(string: directions ? "https://www.google.com/maps/dir/" : "https://www.google.com/maps/search/")!
        components.queryItems = [URLQueryItem(name: "api", value: "1")]
        let target = query.isEmpty ? "\(coordinate.latitude),\(coordinate.longitude)" : query
        components.queryItems?.append(URLQueryItem(name: directions ? "destination" : "query", value: target))
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

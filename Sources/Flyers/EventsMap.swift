import AppKit
import CoreLocation
import FlyersCore
import MapKit
import SwiftUI

/// Every upcoming event that has a findable place, on one map, as on the iPhone.
/// Events at the same place share a pin, and selecting it lists them.
struct EventsMap: View {
    @ObservedObject var engine: FlyersEngine
    let thumbnail: (FlyerEvent) -> NSImage?
    let onOpen: (UUID) -> Void

    struct Pin: Identifiable, Hashable {
        var place: FoundPlace
        var events: [FlyerEvent]
        var hasUpcoming: Bool
        var id: String { String(format: "%.5f,%.5f", place.latitude, place.longitude) }

        static func == (a: Pin, b: Pin) -> Bool { a.id == b.id && a.events.map(\.id) == b.events.map(\.id) }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @State private var places: [UUID: FoundPlace] = [:]
    @State private var selectedPin: String?
    @State private var isSearching = false
    @State private var position = MapCameraPosition.automatic
    /// Asks once to show where you are. Kept here so the request isn't dropped.
    @State private var locationManager = CLLocationManager()
    @State private var userLocation: CLLocation?
    /// Counts camera moves, so the dot drawn over the map redraws as it pans.
    @State private var cameraMoves = 0
    private let today = Day.today

    private var located: [FlyerEvent] {
        engine.visibleEvents.filter { $0.location != nil && !$0.isOver(today: today) }
    }

    private var pins: [Pin] {
        var byPlace: [String: Pin] = [:]
        for event in located {
            guard let place = places[event.id] else { continue }
            var pin = byPlace[Pin(place: place, events: [], hasUpcoming: false).id] ?? Pin(place: place, events: [], hasUpcoming: false)
            pin.events.append(event)
            pin.hasUpcoming = true
            byPlace[pin.id] = pin
        }
        return byPlace.values.sorted { $0.id < $1.id }
    }

    var body: some View {
        let pins = pins
        MapReader { proxy in
        Map(position: $position) {
            // How sure the Mac is of where you are, as a soft blue circle under everything.
            if let userLocation, userLocation.horizontalAccuracy > 0 {
                MapCircle(center: userLocation.coordinate, radius: userLocation.horizontalAccuracy)
                    .foregroundStyle(.blue.opacity(0.12))
                    .stroke(.blue.opacity(0.3), lineWidth: 1)
            }
            ForEach(pins) { pin in
                Annotation(
                    pin.events.count == 1 ? pin.events[0].name : (pin.place.name ?? "\(pin.events.count) events"),
                    coordinate: pin.place.coordinate
                ) {
                    PinBadge(count: pin.events.count, isUpcoming: pin.hasUpcoming, isSelected: selectedPin == pin.id) {
                        selectedPin = selectedPin == pin.id ? nil : pin.id
                    }
                }
            }
        }
        .onMapCameraChange(frequency: .continuous) { cameraMoves += 1 }
        // You, drawn over the map rather than in it, so you're never under a pin.
        .overlay {
            if let userLocation, let spot = proxy.convert(userLocation.coordinate, to: .local) {
                let _ = cameraMoves
                YouAreHere().position(spot)
            }
        }
        }
        .onAppear {
            if locationManager.authorizationStatus == .notDetermined { locationManager.requestWhenInUseAuthorization() }
        }
        .task {
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let location = update.location { userLocation = location }
                }
            } catch {}
        }
        .overlay(alignment: .top) {
            if isSearching {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Finding places").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassSurface(in: Capsule())
                .padding(12)
            }
        }
        .overlay(alignment: .bottom) {
            if let pin = pins.first(where: { $0.id == selectedPin }) {
                pinCard(pin).padding(16).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selectedPin)
        // Reframes when the set of places changes, not on every redraw, so it never fights your panning.
        .onChange(of: pins.map(\.id), initial: true) {
            if let region = MKCoordinateRegion.fitting(pins.map(\.place.coordinate)) { position = .region(region) }
        }
        .task(id: located.map(\.id)) { await findPlaces() }
    }

    private func pinCard(_ pin: Pin) -> some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if let name = pin.place.name {
                    Text(name).font(.headline)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(pin.events.sorted { ($0.startDay?.number ?? 0) > ($1.startDay?.number ?? 0) }) { event in
                            Button { onOpen(event.id) } label: {
                                RowLabel(
                                    title: event.name,
                                    subtitle: EventFormat.summary(event, day: event.nextDay(onOrAfter: today)),
                                    detail: event.isOver(today: today) ? "Past" : nil,
                                    thumbnail: thumbnail(event),
                                    repeats: event.rrule != nil,
                                    status: nil
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 420)
    }

    /// Looks places up one at a time, which stays well inside MapKit's search limits.
    /// Saved answers fill in first, so the map appears at once after the first visit.
    private func findPlaces() async {
        var missing: [FlyerEvent] = []
        for event in located {
            guard let location = event.location else { continue }
            let near = engine.flyer(id: event.flyerID)?.coordinate
            if let place = PlaceFinder.cached(for: location, near: near) {
                places[event.id] = place
            } else {
                missing.append(event)
            }
        }
        guard !missing.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        for event in missing {
            if Task.isCancelled { return }
            guard let location = event.location else { continue }
            let near = engine.flyer(id: event.flyerID)?.coordinate
            if let place = await PlaceFinder.place(for: location, near: near) { places[event.id] = place }
        }
    }
}

import CoreLocation
import FlyersCore
import MapKit
import SwiftUI

/// Upcoming events with a findable place, on a map with you on it. Each pin is the flyer's photo
/// with the event's name under it. Events at the same place share a pin, and tapping it lists them.
struct PhoneMapView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    /// Events opened from the map, which open within the map's tab.
    @State private var path: [UUID] = []

    struct Pin: Identifiable {
        var place: FoundPlace
        /// Soonest first.
        var events: [FlyerEvent]
        var id: String { String(format: "%.5f,%.5f", place.latitude, place.longitude) }
    }

    @State private var places: [UUID: FoundPlace] = [:]
    @State private var selectedPin: String?
    @State private var isSearching = false
    @State private var position = MapCameraPosition.automatic
    /// Asks once to show where you are. Kept here so the request isn't dropped.
    @State private var locationManager = CLLocationManager()
    private let today = Day.today

    private var located: [FlyerEvent] {
        engine.visibleEvents.filter { $0.location != nil && !$0.isOver(today: today) }
    }

    private var pins: [Pin] {
        var byPlace: [String: Pin] = [:]
        for event in located {
            guard let place = places[event.id] else { continue }
            let empty = Pin(place: place, events: [])
            var pin = byPlace[empty.id] ?? empty
            pin.events.append(event)
            byPlace[pin.id] = pin
        }
        return byPlace.values.map { pin in
            var pin = pin
            pin.events.sort { ($0.nextDay(onOrAfter: today) ?? today) < ($1.nextDay(onOrAfter: today) ?? today) }
            return pin
        }
        .sorted { $0.id < $1.id }
    }

    var body: some View {
        let pins = pins
        NavigationStack(path: $path) {
            Map(position: $position) {
                UserAnnotation()
                ForEach(pins) { pin in
                    Annotation(
                        pin.events.count == 1 ? pin.events[0].name : (pin.place.name ?? "\(pin.events.count) events"),
                        coordinate: pin.place.coordinate,
                        anchor: .bottom
                    ) {
                        PhotoPin(
                            image: model.thumbnail(engine.flyer(id: pin.events[0].flyerID)),
                            count: pin.events.count,
                            isSelected: selectedPin == pin.id
                        ) {
                            selectedPin = selectedPin == pin.id ? nil : pin.id
                        }
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .overlay(alignment: .top) {
                if isSearching {
                    ProgressView()
                        .padding(10)
                        .glassSurface(in: Circle())
                        .padding(.top, 8)
                }
            }
            .onAppear {
                if locationManager.authorizationStatus == .notDetermined {
                    locationManager.requestWhenInUseAuthorization()
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let pin = pins.first(where: { $0.id == selectedPin }) { pinCard(pin) }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                EventDetailView(model: model, engine: engine, eventID: id)
            }
            // Reframes when the set of places changes, not on every redraw, so it never fights your panning.
            .onChange(of: pins.map(\.id), initial: true) {
                if let region = MKCoordinateRegion.fitting(pins.map(\.place.coordinate)) { position = .region(region) }
            }
            .task(id: located.map(\.id)) { await findPlaces() }
        }
    }

    private func pinCard(_ pin: Pin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = pin.place.name { Text(name).font(.headline) }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pin.events) { event in
                        Button { path.append(event.id) } label: {
                            EventRow(
                                event: event, day: event.nextDay(onOrAfter: today),
                                thumbnail: model.thumbnail(engine.flyer(id: event.flyerID))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 190)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Looks places up one at a time, which stays well inside MapKit's search limits.
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

/// A map pin made of the flyer's photo, cropped square, so you can tell events apart at a glance.
/// A number in the corner counts events at the same place.
private struct PhotoPin: View {
    let image: UIImage?
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "calendar")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.accentColor)
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white, lineWidth: 3)
                }
                .overlay(alignment: .topTrailing) {
                    if count > 1 {
                        Text("\(count)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(Color.accentColor, in: Circle())
                            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                            .offset(x: 8, y: -8)
                    }
                }
                // A small point under the photo, so it reads as marking a spot.
                Image(systemName: "triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(180))
                    .offset(y: -2)
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .scaleEffect(isSelected ? 1.2 : 1, anchor: .bottom)
            .animation(.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 1 ? "1 event here" : "\(count) events here")
    }
}

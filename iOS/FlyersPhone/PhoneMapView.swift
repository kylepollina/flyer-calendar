import CoreLocation
import FlyersCore
import MapKit
import SwiftUI

/// Upcoming events with a findable place, on a map with you on it. Each pin is the flyer's photo
/// with the event's name under it. Pins that would overlap at the current zoom share one, which
/// splits apart as you zoom in. Tapping a pin lists its events.
struct PhoneMapView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    /// Events opened from the map, which open within the map's tab.
    @State private var path: [PhoneRoute] = []

    /// One place, with every event there.
    struct Place: Identifiable {
        var place: FoundPlace
        var events: [FlyerEvent]
        var id: String { String(format: "%.5f,%.5f", place.latitude, place.longitude) }
    }

    /// What's drawn: one place, or several close enough to overlap at this zoom.
    struct Pin: Identifiable {
        var places: [Place]
        /// Soonest first.
        var events: [FlyerEvent]
        var id: String { places.map(\.id).joined(separator: "|") }
        var coordinate: CLLocationCoordinate2D { places[0].place.coordinate }
    }

    /// Pins closer on screen than this share one, so a pin never hides another.
    private static let groupingDistance: Double = 64

    @State private var places: [UUID: FoundPlace] = [:]
    /// The open pin, by the events in it, so it stays open while grouping changes.
    @State private var selectedEvents: Set<UUID> = []
    /// When a pin was last tapped, so the same tap reaching the map doesn't close it again.
    @State private var lastPinTap = Date.distantPast
    @State private var isSearching = false
    @State private var position = MapCameraPosition.automatic
    @State private var viewport: MapGrouping.Viewport?
    @State private var mapSize = CGSize.zero
    /// Asks once to show where you are. Kept here so the request isn't dropped.
    @State private var locationManager = CLLocationManager()
    /// Where you are, kept current while the map is open.
    @State private var userLocation: CLLocation?
    /// Where you were looking, kept across opening an event, switching tabs and relaunching.
    @AppStorage("map.region") private var savedRegion = ""
    private let today = Day.today

    private var located: [FlyerEvent] {
        engine.visibleEvents.filter { $0.location != nil && !$0.isOver(today: today) }
    }

    private var placesWithEvents: [Place] {
        var byPlace: [String: Place] = [:]
        for event in located {
            guard let found = places[event.id] else { continue }
            let empty = Place(place: found, events: [])
            var place = byPlace[empty.id] ?? empty
            place.events.append(event)
            byPlace[place.id] = place
        }
        return byPlace.values.sorted { $0.id < $1.id }
    }

    private var pins: [Pin] {
        let all = placesWithEvents
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let points = all.map { MapGrouping.Point(id: $0.id, latitude: $0.place.latitude, longitude: $0.place.longitude) }
        return MapGrouping.group(points, in: viewport, distance: Self.groupingDistance).map { ids in
            let grouped = ids.compactMap { byID[$0] }
            let events = grouped.flatMap(\.events).sorted {
                ($0.nextDay(onOrAfter: today) ?? today) < ($1.nextDay(onOrAfter: today) ?? today)
            }
            return Pin(places: grouped, events: events)
        }
    }

    var body: some View {
        let pins = pins
        NavigationStack(path: $path) {
            Map(position: $position) {
                // How sure the phone is of where you are, as a soft blue circle under everything.
                if let userLocation, userLocation.horizontalAccuracy > 0 {
                    MapCircle(center: userLocation.coordinate, radius: userLocation.horizontalAccuracy)
                        .foregroundStyle(.blue.opacity(0.12))
                        .stroke(.blue.opacity(0.3), lineWidth: 1)
                }
                ForEach(pins) { pin in
                    Annotation(title(of: pin), coordinate: pin.coordinate, anchor: .bottom) {
                        EventPin(
                            title: title(of: pin),
                            image: model.thumbnail(engine.flyer(id: (engine.eventWithOldestPhoto(pin.events) ?? pin.events[0]).flyerID)),
                            count: pin.events.count,
                            isSelected: isSelected(pin)
                        ) {
                            lastPinTap = Date()
                            selectedEvents = isSelected(pin) ? [] : Set(pin.events.map(\.id))
                        }
                    }
                    // The pin draws its own name, under its point.
                    .annotationTitles(.hidden)
                }
                // Anchored to the map like the events, so it moves with it exactly.
                if let userLocation {
                    Annotation("My Location", coordinate: userLocation.coordinate) { YouAreHere() }
                        .annotationTitles(.hidden)
                }
            }
            // No built-in controls: pinch to zoom, and the location button stands alone.
            .mapControls {}
            // Tapping anywhere else on the map closes an open pin's card. A tap on a pin can reach
            // the map too, so this waits a moment and leaves it be if a pin just took it.
            .onTapGesture {
                guard !selectedEvents.isEmpty else { return }
                DispatchQueue.main.async {
                    if Date().timeIntervalSince(lastPinTap) > 0.3 {
                        withAnimation(.snappy) { selectedEvents = [] }
                    }
                }
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { mapSize = $0 }
            .onMapCameraChange(frequency: .onEnd) { context in
                savedRegion = MapLook.encode(context.region)
                viewport = MapGrouping.Viewport(
                    centerLatitude: context.region.center.latitude, centerLongitude: context.region.center.longitude,
                    latitudeSpan: context.region.span.latitudeDelta, longitudeSpan: context.region.span.longitudeDelta,
                    width: mapSize.width, height: mapSize.height
                )
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
                // Back from an event, or another tab, the map is where you left it.
                if let region = MapLook.decode(savedRegion) { position = .region(region) }
            }
            // Where you are when the map opens, and again every 10 minutes while it's open.
            .task {
                while !Task.isCancelled {
                    if let location = await YouAreHere.currentLocation() { userLocation = location }
                    try? await Task.sleep(for: .seconds(600))
                }
            }
            // The location button sits at the right edge just above the Map button in the tab bar,
            // where your thumb already is, with an open pin's card under it.
            // Over the map rather than an inset, so the map's own bottom edge, and the Apple Maps
            // logo MapKit pins to it, stay down by the tab bar instead of floating above these.
            .overlay(alignment: .bottom) {
                VStack(alignment: .trailing, spacing: 10) {
                    // Centered over the tab bar's round Camera button: it's about 61 points across
                    // with 22 points to the screen's edge, so its center is 52 points in. A 52-point
                    // button 26 points in shares that center line.
                    Button(action: centerOnYou) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 52, height: 52)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassSurface(in: Circle())
                    .accessibilityLabel("Show My Location")
                    .padding(.trailing, 26)
                    .padding(.bottom, 14)
                    if let pin = pins.first(where: isSelected) { pinCard(pin) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .phoneRoutes(model: model, engine: engine)
            // Fits every pin the first time, before you've looked anywhere yourself.
            .onChange(of: placesWithEvents.map(\.id), initial: true) {
                guard savedRegion.isEmpty,
                      let region = MKCoordinateRegion.fitting(placesWithEvents.map(\.place.coordinate)) else { return }
                position = .region(region)
            }
            // Searches again when an event's location is edited, not only when events come and go.
            .task(id: located.map { "\($0.id)|\($0.location ?? "")" }) { await findPlaces() }
        }
    }

    /// Moves the map to you, keeping the zoom, without following you around afterwards.
    private func centerOnYou() {
        guard let userLocation else {
            if locationManager.authorizationStatus == .notDetermined { locationManager.requestWhenInUseAuthorization() }
            return
        }
        let span = viewport.map { MKCoordinateSpan(latitudeDelta: $0.latitudeSpan, longitudeDelta: $0.longitudeSpan) }
            ?? MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        withAnimation(.snappy) {
            position = .region(MKCoordinateRegion(center: userLocation.coordinate, span: span))
        }
    }

    /// A pin is open when it holds the events last tapped, even if zooming regrouped them.
    private func isSelected(_ pin: Pin) -> Bool {
        !selectedEvents.isEmpty && !selectedEvents.isDisjoint(with: pin.events.map(\.id))
    }

    private func title(of pin: Pin) -> String {
        if pin.events.count == 1 { return pin.events[0].name }
        if pin.places.count == 1, let name = pin.places[0].place.name { return name }
        return "\(pin.events.count) events"
    }

    private func pinCard(_ pin: Pin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pin.places.count == 1 ? (pin.places[0].place.name ?? title(of: pin)) : "\(pin.events.count) events nearby")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pin.events) { event in
                        Button { path.append(.event(event.id)) } label: {
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
                // Its old place, from before an edit, shouldn't linger while the new one is found.
                places[event.id] = nil
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


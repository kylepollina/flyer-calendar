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
    @State private var path: [UUID] = []

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
    /// Counts camera moves, so the dot drawn over the map redraws as it pans.
    @State private var cameraMoves = 0
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
            MapReader { proxy in
            Map(position: $position) {
                // How sure the phone is of where you are, as a soft blue circle under everything.
                if let userLocation, userLocation.horizontalAccuracy > 0 {
                    MapCircle(center: userLocation.coordinate, radius: userLocation.horizontalAccuracy)
                        .foregroundStyle(.blue.opacity(0.12))
                        .stroke(.blue.opacity(0.3), lineWidth: 1)
                }
                ForEach(pins) { pin in
                    Annotation(title(of: pin), coordinate: pin.coordinate, anchor: .bottom) {
                        PhotoPin(
                            title: title(of: pin),
                            image: model.thumbnail(engine.flyer(id: pin.events[0].flyerID)),
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
            }
            // Keeps your dot in step with the map while it moves.
            .onMapCameraChange(frequency: .continuous) { cameraMoves += 1 }
            // You, drawn over the map rather than in it, since MapKit stacks its own pins however it
            // likes. This way the dot is always on top of the events.
            .overlay {
                if let userLocation, let spot = proxy.convert(userLocation.coordinate, to: .local) {
                    let _ = cameraMoves
                    YouAreHere().position(spot)
                }
            }
            }
            .mapControls { MapCompass() }
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
            .task {
                // Follows you while the map is open, and stops when you leave it.
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { userLocation = location }
                    }
                } catch {}
            }
            // The location button sits at the right edge just above the Map button in the tab bar,
            // where your thumb already is, with an open pin's card under it.
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .trailing, spacing: 10) {
                    Button(action: centerOnYou) {
                        Label("Show My Location", systemImage: "location.fill").labelStyle(.iconOnly)
                    }
                    .glassButton()
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .padding(.trailing, 16)
                    if let pin = pins.first(where: isSelected) { pinCard(pin) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                EventDetailView(model: model, engine: engine, eventID: id)
            }
            // Fits every pin the first time, before you've looked anywhere yourself.
            .onChange(of: placesWithEvents.map(\.id), initial: true) {
                guard savedRegion.isEmpty,
                      let region = MKCoordinateRegion.fitting(placesWithEvents.map(\.place.coordinate)) else { return }
                position = .region(region)
            }
            .task(id: located.map(\.id)) { await findPlaces() }
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

/// Saves the map's view as text, for `@AppStorage`.
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

/// A pin made of the flyer's photo, cropped square, with a point under it marking the spot and
/// the name under that. The name hangs below without changing the pin's size, so the point stays
/// on the place. A pin holding several events shows just their number in a circle instead.
private struct PhotoPin: View {
    let title: String
    let image: UIImage?
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    private let size: CGFloat = 58

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                if count > 1 {
                    // Several events: just how many, big. Zoom in and they split into photos.
                    Text("\(count)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: size, height: size)
                        .background(Color.accentColor, in: Circle())
                        .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                } else {
                    photo
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white, lineWidth: 3) }
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
            Image(uiImage: image).resizable().scaledToFill()
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
            .shadow(color: Color(uiColor: .systemBackground), radius: 1)
            .shadow(color: Color(uiColor: .systemBackground), radius: 1)
            .shadow(color: Color(uiColor: .systemBackground), radius: 2)
    }
}

/// You on the map: a blue dot with a white ring and a soft glow, like Maps and Find My.
private struct YouAreHere: View {
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

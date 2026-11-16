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
    @Namespace private var mapScope
    /// Where you were looking, kept across opening an event, switching tabs and relaunching.
    @AppStorage("map.region") private var savedRegion = ""
    @AppStorage(MapLook.pinStyleKey) private var pinStyle = MapLook.PinStyle.photo
    @AppStorage(MapLook.labelKey) private var labelPosition = MapLook.LabelPosition.below
    @AppStorage(MapLook.sizeKey) private var pinSize = MapLook.PinSize.medium
    @AppStorage(MapLook.baseKey) private var base = MapLook.Base.standard
    @AppStorage(MapLook.placesKey) private var showsPlaces = true
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
            Map(position: $position, scope: mapScope) {
                UserAnnotation()
                if base == .off {
                    // Covers the map's own drawing, leaving only your events and you.
                    MapPolygon(coordinates: MapLook.wholeWorld).foregroundStyle(Color(uiColor: .systemBackground))
                }
                ForEach(pins) { pin in
                    Annotation(title(of: pin), coordinate: pin.place.coordinate, anchor: .bottom) {
                        MapPin(
                            style: pinStyle, label: labelPosition, size: pinSize.points,
                            title: title(of: pin),
                            image: model.thumbnail(engine.flyer(id: pin.events[0].flyerID)),
                            count: pin.events.count,
                            isSelected: selectedPin == pin.id
                        ) {
                            selectedPin = selectedPin == pin.id ? nil : pin.id
                        }
                    }
                    // Pins draw their own names, so they can go above or below.
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(base.style(showsPlaces: showsPlaces))
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .onEnd) { context in
                savedRegion = MapLook.encode(context.region)
            }
            .overlay(alignment: .topTrailing) {
                MapLookMenu(
                    pinStyle: $pinStyle, labelPosition: $labelPosition, pinSize: $pinSize,
                    base: $base, showsPlaces: $showsPlaces
                )
                .padding(.trailing, 12)
                .padding(.top, 8)
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
            // The location button sits just above the Map button in the tab bar, where your thumb
            // already is, with an open pin's card under it.
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .trailing, spacing: 10) {
                    MapUserLocationButton(scope: mapScope)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .tint(.primary)
                        .padding(.trailing, 16)
                    if let pin = pins.first(where: { $0.id == selectedPin }) { pinCard(pin) }
                }
            }
            .mapScope(mapScope)
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                EventDetailView(model: model, engine: engine, eventID: id)
            }
            // Fits every pin the first time, before you've looked anywhere yourself.
            .onChange(of: pins.map(\.id), initial: true) {
                guard savedRegion.isEmpty, let region = MKCoordinateRegion.fitting(pins.map(\.place.coordinate)) else { return }
                position = .region(region)
            }
            .task(id: located.map(\.id)) { await findPlaces() }
        }
    }

    private func title(of pin: Pin) -> String {
        pin.events.count == 1 ? pin.events[0].name : (pin.place.name ?? "\(pin.events.count) events")
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

/// Ways to draw the map and its pins, to try out from the map's debug menu. Saved on this iPhone.
enum MapLook {
    static let pinStyleKey = "map.pinStyle"
    static let labelKey = "map.label"
    static let sizeKey = "map.pinSize"
    static let baseKey = "map.base"
    static let placesKey = "map.places"

    enum PinStyle: String, CaseIterable, Identifiable {
        case photo, round, card, dot
        var id: String { rawValue }
        var name: String {
            switch self {
            case .photo: return "Square photo"
            case .round: return "Round photo"
            case .card: return "Photo card"
            case .dot: return "Dot"
            }
        }
    }

    enum LabelPosition: String, CaseIterable, Identifiable {
        case above, below, hidden
        var id: String { rawValue }
        var name: String { rawValue.capitalized }
    }

    enum PinSize: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var name: String { rawValue.capitalized }
        var points: CGFloat {
            switch self {
            case .small: return 42
            case .medium: return 58
            case .large: return 80
            }
        }
    }

    enum Base: String, CaseIterable, Identifiable {
        case standard, muted, satellite, hybrid, off
        var id: String { rawValue }
        var name: String { self == .off ? "Off" : rawValue.capitalized }

        func style(showsPlaces: Bool) -> MapStyle {
            let places: PointOfInterestCategories = showsPlaces ? .all : .excludingAll
            switch self {
            case .standard, .off: return .standard(pointsOfInterest: places)
            case .muted: return .standard(emphasis: .muted, pointsOfInterest: places)
            case .satellite: return .imagery
            case .hybrid: return .hybrid(pointsOfInterest: places)
            }
        }
    }

    /// Nearly the whole globe, for hiding the map under the pins.
    static let wholeWorld = [
        CLLocationCoordinate2D(latitude: -85, longitude: -179.9),
        CLLocationCoordinate2D(latitude: 85, longitude: -179.9),
        CLLocationCoordinate2D(latitude: 85, longitude: 179.9),
        CLLocationCoordinate2D(latitude: -85, longitude: 179.9),
    ]

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

/// The ladybug in the map's corner: try different pins, names and maps.
private struct MapLookMenu: View {
    @Binding var pinStyle: MapLook.PinStyle
    @Binding var labelPosition: MapLook.LabelPosition
    @Binding var pinSize: MapLook.PinSize
    @Binding var base: MapLook.Base
    @Binding var showsPlaces: Bool

    var body: some View {
        Menu {
            Picker("Pins", selection: $pinStyle) {
                ForEach(MapLook.PinStyle.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Names", selection: $labelPosition) {
                ForEach(MapLook.LabelPosition.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Size", selection: $pinSize) {
                ForEach(MapLook.PinSize.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Map", selection: $base) {
                ForEach(MapLook.Base.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            Toggle("Places on the Map", isOn: $showsPlaces)
            Divider()
            Button("Reset", systemImage: "arrow.counterclockwise") {
                pinStyle = .photo
                labelPosition = .below
                pinSize = .medium
                base = .standard
                showsPlaces = true
            }
        } label: {
            Label("Map Options", systemImage: "ladybug").labelStyle(.iconOnly)
        }
        .glassButton()
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }
}

/// One pin on the map, drawn the way the debug menu says. Names hang above or below without
/// changing the pin's size, so the point under it stays on the place.
private struct MapPin: View {
    let style: MapLook.PinStyle
    let label: MapLook.LabelPosition
    let size: CGFloat
    let title: String
    let image: UIImage?
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            pin
                .overlay(alignment: .bottom) {
                    if label == .below && style != .card { name.alignmentGuide(.bottom) { $0[.top] - 4 } }
                }
                .overlay(alignment: .top) {
                    if label == .above && style != .card { name.alignmentGuide(.top) { $0[.bottom] + 4 } }
                }
                .scaleEffect(isSelected ? 1.2 : 1, anchor: .bottom)
                .animation(.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 1 ? title : "\(title), \(count) events")
    }

    @ViewBuilder private var pin: some View {
        switch style {
        case .photo:
            VStack(spacing: 0) {
                photo
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: size / 4, style: .continuous).strokeBorder(.white, lineWidth: 3) }
                    .overlay(alignment: .topTrailing) { countBadge }
                pointer
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        case .round:
            VStack(spacing: 0) {
                photo
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                    .overlay(alignment: .topTrailing) { countBadge }
                pointer
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        case .card:
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    photo.frame(width: size * 1.6, height: size * 1.1).clipped()
                    if label != .hidden {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: size * 1.6 - 8)
                            .padding(.vertical, 4)
                    }
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white, lineWidth: 2) }
                .overlay(alignment: .topTrailing) { countBadge }
                pointer
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        case .dot:
            PinBadge(count: count, isUpcoming: true, isSelected: false, action: action)
                .scaleEffect(size / 46)
        }
    }

    @ViewBuilder private var photo: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "calendar")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.accentColor)
        }
    }

    /// A small point under the pin, so it reads as marking a spot.
    private var pointer: some View {
        Image(systemName: "triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(180))
            .offset(y: -2)
    }

    @ViewBuilder private var countBadge: some View {
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

    private var name: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 120)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

import FlyersCore
import MapKit
import SwiftUI

/// Every event that has a findable place, past and upcoming, on one map.
/// Events at the same place share a pin, and tapping it lists them.
struct PhoneMapView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    /// Events opened from the map, which open within the map's tab.
    @State private var path: [UUID] = []

    enum Show: String, CaseIterable, Identifiable {
        case all = "All", upcoming = "Upcoming", past = "Past"
        var id: String { rawValue }
    }

    struct Pin: Identifiable {
        var place: FoundPlace
        var events: [FlyerEvent]
        var hasUpcoming: Bool
        var id: String { String(format: "%.5f,%.5f", place.latitude, place.longitude) }
    }

    @State private var places: [UUID: FoundPlace] = [:]
    @State private var show = Show.all
    @State private var selectedPin: String?
    @State private var isSearching = false
    @State private var position = MapCameraPosition.automatic
    private let today = Day.today

    private var located: [FlyerEvent] {
        engine.visibleEvents.filter { $0.location != nil && $0.state != .needsReview }
    }

    private var pins: [Pin] {
        var byPlace: [String: Pin] = [:]
        for event in located {
            let isOver = event.isOver(today: today)
            if show == .upcoming && isOver || show == .past && !isOver { continue }
            guard let place = places[event.id] else { continue }
            let empty = Pin(place: place, events: [], hasUpcoming: false)
            var pin = byPlace[empty.id] ?? empty
            pin.events.append(event)
            pin.hasUpcoming = pin.hasUpcoming || !isOver
            byPlace[pin.id] = pin
        }
        return byPlace.values.sorted { $0.id < $1.id }
    }

    var body: some View {
        let pins = pins
        NavigationStack(path: $path) {
            Map(position: $position) {
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
            .safeAreaInset(edge: .top) {
                HStack {
                    Picker("Show", selection: $show) {
                        ForEach(Show.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if isSearching { ProgressView() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .glassSurface(in: Capsule())
                .padding(.horizontal)
                .padding(.top, 4)
            }
            .safeAreaInset(edge: .bottom) {
                if let pin = pins.first(where: { $0.id == selectedPin }) { pinCard(pin) }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                EventDetailView(model: model, engine: engine, eventID: id)
            }
            .onChange(of: show) { selectedPin = nil }
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
                    ForEach(pin.events.sorted { ($0.startDay?.number ?? 0) > ($1.startDay?.number ?? 0) }) { event in
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

import AppKit
import FlyersCore
import MapKit
import SwiftUI

/// Every event that has a findable place, past and upcoming, on one map.
/// Events at the same place share a pin, and selecting it lists them.
struct EventsMap: View {
    @ObservedObject var engine: FlyersEngine
    let thumbnail: (FlyerEvent) -> NSImage?
    let onOpen: (UUID) -> Void

    enum Show: String, CaseIterable, Identifiable {
        case all = "All", upcoming = "Upcoming", past = "Past"
        var id: String { rawValue }
    }

    struct Pin: Identifiable, Hashable {
        var place: FoundPlace
        var events: [FlyerEvent]
        var hasUpcoming: Bool
        var id: String { String(format: "%.5f,%.5f", place.latitude, place.longitude) }

        static func == (a: Pin, b: Pin) -> Bool { a.id == b.id && a.events.map(\.id) == b.events.map(\.id) }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
            var pin = byPlace[Pin(place: place, events: [], hasUpcoming: false).id] ?? Pin(place: place, events: [], hasUpcoming: false)
            pin.events.append(event)
            pin.hasUpcoming = pin.hasUpcoming || !isOver
            byPlace[pin.id] = pin
        }
        return byPlace.values.sorted { $0.id < $1.id }
    }

    var body: some View {
        let pins = pins
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
        .overlay(alignment: .top) {
            HStack(spacing: 12) {
                Picker("Show", selection: $show) {
                    ForEach(Show.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if isSearching {
                    ProgressView().controlSize(.small)
                    Text("Finding places").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(summary(pins)).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassSurface(in: Capsule())
            .padding(12)
        }
        .overlay(alignment: .bottom) {
            if let pin = pins.first(where: { $0.id == selectedPin }) {
                pinCard(pin).padding(16).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selectedPin)
        .onChange(of: show) { selectedPin = nil }
        // Reframes when the set of places changes, not on every redraw, so it never fights your panning.
        .onChange(of: pins.map(\.id), initial: true) {
            if let region = MKCoordinateRegion.fitting(pins.map(\.place.coordinate)) { position = .region(region) }
        }
        .task(id: located.map(\.id)) { await findPlaces() }
    }

    private func summary(_ pins: [Pin]) -> String {
        let shown = pins.reduce(0) { $0 + $1.events.count }
        let missing = located.count - places.count
        var text = shown == 1 ? "1 event" : "\(shown) events"
        if missing > 0 { text += " · \(missing) without a findable place" }
        return text
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

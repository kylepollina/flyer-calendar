import FlyersCore
import SwiftUI
import UIKit

enum PhoneTab: String, CaseIterable, Identifiable {
    case upcoming = "Upcoming"
    case review = "Review"
    case past = "Past"
    var id: String { rawValue }
}

struct EventListView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    @State private var tab = PhoneTab.upcoming
    @State private var path: [UUID] = []
    @State private var isShowingSettings = false
    @State private var isShowingMap = false

    private var today: Day { .today }
    private var reviewCount: Int { EventList.needingReview(engine.document.events).count }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle("Flyers")
                .navigationDestination(for: UUID.self) { id in
                    EventDetailView(model: model, engine: engine, eventID: id)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    Picker("View", selection: $tab) {
                        Text("Upcoming").tag(PhoneTab.upcoming)
                        Text(reviewCount > 0 ? "Review \(reviewCount)" : "Review").tag(PhoneTab.review)
                        Text("Past").tag(PhoneTab.past)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { status }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isShowingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { isShowingMap = true } label: { Label("Map", systemImage: "map") }
                    }
                }
                .refreshable { await model.scanNow() }
                .sheet(isPresented: $isShowingSettings) { PhoneSettingsView(model: model, engine: engine) }
                .sheet(isPresented: $isShowingMap) {
                    PhoneMapView(model: model, engine: engine) { id in
                        isShowingMap = false
                        path = [id]
                    }
                }
        }
    }

    @ViewBuilder private var list: some View {
        switch tab {
        case .upcoming:
            let sections = EventList.upcoming(engine.document.events, today: today)
            if sections.isEmpty {
                ContentUnavailableView("No upcoming events", systemImage: "calendar", description: Text(emptyMessage))
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row(for: $0.event, day: $0.next) }
                                .onDelete { offsets in engine.delete(offsets.map { section.rows[$0].id }) }
                        }
                    }
                }
            }
        case .review:
            flatList(
                EventList.needingReview(engine.document.events),
                empty: ContentUnavailableView(
                    "Nothing to check", systemImage: "checkmark.circle",
                    description: Text("Events that need a second look wait here before reaching your calendar.")
                )
            )
        case .past:
            flatList(
                EventList.past(engine.document.events, today: today),
                empty: ContentUnavailableView(
                    "No past events", systemImage: "clock", description: Text("Events move here once they've finished.")
                )
            )
        }
    }

    private var emptyMessage: String {
        model.scansHere
            ? "Photograph a flyer and it'll show up here the next time you open Flyers."
            : "Scanning on this iPhone is off. Turn it on in Settings, or wait for syncing with your Mac."
    }

    @ViewBuilder private func flatList(_ events: [FlyerEvent], empty: some View) -> some View {
        if events.isEmpty {
            empty
        } else {
            List {
                ForEach(events) { row(for: $0, day: $0.startDay) }
                    .onDelete { offsets in engine.delete(offsets.map { events[$0].id }) }
            }
        }
    }

    private func row(for event: FlyerEvent, day: Day?) -> some View {
        NavigationLink(value: event.id) {
            EventRow(event: event, day: day, thumbnail: model.thumbnail(engine.flyer(id: event.flyerID)))
        }
    }

    /// What the app is doing, or what the last delete can undo.
    @ViewBuilder private var status: some View {
        let message = engine.scanProgress ?? engine.alertMessage
        if message != nil || !engine.lastDeletedIDs.isEmpty {
            HStack(spacing: 10) {
                if engine.scanProgress != nil { ProgressView() }
                if let message {
                    Text(message).font(.callout).lineLimit(2)
                    Spacer(minLength: 8)
                    if engine.scanProgress != nil {
                        Button("Stop") { engine.stopScan() }.disabled(engine.isStopping)
                    } else {
                        Button("Dismiss") { engine.clearAlert() }
                    }
                } else {
                    let count = engine.lastDeletedIDs.count
                    Text(count == 1 ? "Event deleted" : "\(count) events deleted").font(.callout)
                    Spacer(minLength: 8)
                    Button("Undo") { engine.undoDelete() }
                    Button("Dismiss") { engine.dismissUndo() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

struct EventRow: View {
    let event: FlyerEvent
    let day: Day?
    let thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 44, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name).fontWeight(.semibold).lineLimit(2)
                HStack(spacing: 4) {
                    if event.rrule != nil {
                        Image(systemName: "repeat").imageScale(.small).accessibilityLabel("Repeats")
                    }
                    Text(EventFormat.summary(event, day: day)).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let location = event.location {
                    Text(location).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if event.state == .needsReview {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("Needs review")
            } else if event.state == .queued {
                Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Waiting for a calendar")
            }
        }
        .padding(.vertical, 2)
    }
}

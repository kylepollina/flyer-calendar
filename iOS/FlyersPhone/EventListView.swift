import FlyersCore
import SwiftUI
import UIKit

enum PhoneTab: String, Hashable {
    case upcoming = "Upcoming"
    case past = "Past"
    case map = "Map"
}

struct EventListView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    @State private var tab = PhoneTab.upcoming
    /// Each tab keeps its own place, as tab bars do.
    @State private var paths: [PhoneTab: [UUID]] = [:]
    @State private var isShowingSettings = false

    private var today: Day { .today }

    /// Tabs along the bottom, where your thumb is. The map sits apart at the bottom right, the
    /// place iOS gives a tab that isn't one of the lists.
    var body: some View {
        TabView(selection: $tab) {
            Tab(PhoneTab.upcoming.rawValue, systemImage: "calendar", value: PhoneTab.upcoming) { stack(.upcoming) }
            Tab(PhoneTab.past.rawValue, systemImage: "clock", value: PhoneTab.past) { stack(.past) }
            Tab(PhoneTab.map.rawValue, systemImage: "map", value: PhoneTab.map, role: .search) {
                PhoneMapView(model: model, engine: engine)
            }
        }
        .sheet(isPresented: $isShowingSettings) { PhoneSettingsView(model: model, engine: engine) }
        .fullScreenCover(isPresented: $model.isShowingSetup, onDismiss: model.setupClosed) { PhoneSetupView(model: model, engine: engine) }
        .photoDeletePrompt(model: model, engine: engine)
        .sensoryFeedback(.success, trigger: engine.lastDeletedIDs) { _, new in !new.isEmpty }
    }

    private func stack(_ tab: PhoneTab) -> some View {
        NavigationStack(path: Binding(get: { paths[tab] ?? [] }, set: { paths[tab] = $0 })) {
            list(tab)
                .navigationTitle(tab.rawValue)
                .navigationDestination(for: UUID.self) { id in
                    EventDetailView(model: model, engine: engine, eventID: id)
                }
                .overlay(alignment: .bottom) { notices }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isShowingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    }
                    if model.canScan {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { Task { await model.scanNow() } } label: {
                                Label("Scan now", systemImage: "arrow.clockwise")
                            }
                            .disabled(engine.isScanning)
                        }
                    }
                }
                .refreshable { await model.scanNow() }
                .animation(.snappy, value: noticeKey)
        }
    }

    @ViewBuilder private func list(_ tab: PhoneTab) -> some View {
        switch tab {
        case .upcoming:
            let sections = EventList.upcoming(engine.document.events, today: today)
            if sections.isEmpty {
                ContentUnavailableView("No upcoming events", systemImage: "calendar", description: Text(emptyMessage))
                    .background { SetupBackdrop() }
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row(for: $0.event, day: $0.next) }
                        }
                    }
                    bottomSpace
                }
            }
        case .past:
            let events = EventList.past(engine.document.events, today: today)
            let hidden = engine.hiddenEvents
            if events.isEmpty && hidden.isEmpty {
                ContentUnavailableView(
                    "No past events", systemImage: "clock", description: Text("Events move here once they've finished.")
                )
            } else {
                List {
                    if !events.isEmpty {
                        Section { ForEach(events) { row(for: $0, day: $0.startDay) } }
                    }
                    if !hidden.isEmpty {
                        Section {
                            ForEach(hidden) { hiddenRow($0) }
                        } header: {
                            HStack {
                                Text("Deleted")
                                Spacer()
                                Button("Restore All") { engine.restore(hidden.map(\.id)) }
                                    .font(.subheadline)
                                    .textCase(nil)
                            }
                        } footer: {
                            Text("Deleted events stay here, so a rescan can't bring them back. Swipe one to restore it.")
                        }
                    }
                    bottomSpace
                }
            }
        case .map:
            EmptyView()
        }
    }

    /// Room to scroll past a floating notice.
    private var bottomSpace: some View {
        Color.clear.frame(height: 40).listRowBackground(Color.clear)
    }

    private var emptyMessage: String {
        model.scansHere
            ? "Photograph a flyer and it'll show up here the next time you open Flyers."
            : model.cloudSync != nil
                ? "Flyers your Mac finds show up here through iCloud. To read photos on this iPhone too, turn on scanning in Settings."
                : "Scanning on this iPhone is off. Turn it on in Settings."
    }

    private func row(for event: FlyerEvent, day: Day?) -> some View {
        NavigationLink(value: event.id) {
            EventRow(event: event, day: day, thumbnail: model.thumbnail(engine.flyer(id: event.flyerID)))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { model.delete([event.id]) } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            if event.state == .needsReview || event.state == .available {
                Button { engine.addToCalendar(event.id) } label: { Label("Add", systemImage: "calendar.badge.plus") }
                    .tint(.green)
            }
        }
        .contextMenu {
            if event.state == .needsReview || event.state == .available {
                Button("Add to Calendar", systemImage: "calendar.badge.plus") { engine.addToCalendar(event.id) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { model.delete([event.id]) }
        }
    }

    private func hiddenRow(_ event: FlyerEvent) -> some View {
        EventRow(
            event: event, day: event.startDay, thumbnail: model.thumbnail(engine.flyer(id: event.flyerID)),
            note: event.state == .removedInCalendar ? "Removed in Calendar" : "Deleted in Flyers"
        )
        .opacity(0.6)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { engine.restore([event.id]) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                .tint(.blue)
        }
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") { engine.restore([event.id]) }
        }
    }

    // MARK: Notices

    /// Changes whenever a notice appears or goes away, which drives the animation.
    private var noticeKey: String {
        [engine.scanProgress, engine.alertMessage, engine.lastDeletedIDs.isEmpty ? nil : "undo"]
            .map { $0 == nil ? "-" : "+" }.joined()
    }

    private var notices: some View {
        GlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                if let message = engine.alertMessage {
                    PhoneNotice(systemImage: "exclamationmark.triangle.fill", text: message, tint: .orange) {
                        Button("Dismiss") { engine.clearAlert() }
                    }
                }
                if let progress = engine.scanProgress {
                    PhoneNotice(text: progress, tint: .secondary) {
                        Button("Stop") { engine.stopScan() }.disabled(engine.isStopping)
                    }
                }
                if !engine.lastDeletedIDs.isEmpty {
                    let count = engine.lastDeletedIDs.count
                    PhoneNotice(systemImage: "trash", text: count == 1 ? "Event deleted" : "\(count) events deleted", tint: .secondary) {
                        Button("Undo") { engine.undoDelete() }
                        Button("Dismiss", systemImage: "xmark") { engine.dismissUndo() }
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// A floating glass message with its actions. With no symbol it shows a spinner.
struct PhoneNotice<Actions: View>: View {
    var systemImage: String?
    let text: String
    let tint: Color
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(tint)
            } else {
                ProgressView()
            }
            Text(text).font(.callout).lineLimit(2)
            Spacer(minLength: 8)
            actions()
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .glassSurface(in: Capsule())
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct EventRow: View {
    let event: FlyerEvent
    let day: Day?
    let thumbnail: UIImage?
    var note: String?

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(image: thumbnail)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.name).font(.headline).lineLimit(2)
                HStack(spacing: 4) {
                    if event.rrule != nil {
                        Image(systemName: "repeat").imageScale(.small).accessibilityLabel("Repeats")
                    }
                    Text(EventFormat.summary(event, day: day)).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let detail = note ?? event.location {
                    Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if event.state == .needsReview {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("Needs review")
            } else if event.state == .queued {
                Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Waiting for a calendar")
            }
        }
        .padding(.vertical, 3)
    }
}

/// A flyer's small preview, like a print with a thin edge.
struct Thumbnail: View {
    let image: UIImage?
    var width: CGFloat = 48
    var height: CGFloat = 64

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.12)) }
        .accessibilityHidden(true)
    }
}

extension View {
    /// After deleting a photo's last event, offers to delete the photo too.
    func photoDeletePrompt(model: PhoneModel, engine: FlyersEngine) -> some View {
        modifier(PhotoDeletePrompt(model: model, engine: engine))
    }
}

private struct PhotoDeletePrompt: ViewModifier {
    @ObservedObject var model: PhoneModel
    let engine: FlyersEngine

    private var count: Int { model.orphanedFlyers.reduce(0) { $0 + $1.allAssetIDs.count } }

    private var message: String {
        let it = count == 1 ? "it" : "them"
        let start = "No other events in Flyers come from \(it)."
        if model.orphanedFlyers.contains(where: \.mayBeInLibrary) {
            return start + " Photos keeps deleted photos in Recently Deleted for 30 days."
        }
        return start + " Flyers has the only copy, so \(it) can't be recovered."
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            count == 1 ? "Delete the photo too?" : "Delete the \(count) photos too?",
            isPresented: Binding(get: { !model.orphanedFlyers.isEmpty }, set: { if !$0 { model.orphanedFlyers = [] } }),
            titleVisibility: .visible
        ) {
            Button(count == 1 ? "Delete Photo" : "Delete Photos", role: .destructive) {
                let ids = model.orphanedFlyers.map(\.id)
                Task { await engine.deletePhotos(of: ids) }
            }
            Button(count == 1 ? "Keep Photo" : "Keep Photos", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

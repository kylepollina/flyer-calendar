import FlyersCore
import SwiftUI
import UIKit

/// Every page a navigation stack can push. All of them go through the stack's path, so stepping
/// from one to another always lands where you tapped. Mixing pushed views with path values made
/// an event opened from "From This Photo" fall back to that page.
enum PhoneRoute: Hashable {
    case event(UUID)
    /// Every event from one photo, opened from one of them.
    case photoEvents(flyerID: UUID, from: UUID)
}

extension View {
    /// The pages for `PhoneRoute`, for each navigation stack.
    func phoneRoutes(model: PhoneModel, engine: FlyersEngine) -> some View {
        navigationDestination(for: PhoneRoute.self) { route in
            switch route {
            case .event(let id):
                EventDetailView(model: model, engine: engine, eventID: id)
            case .photoEvents(let flyerID, let from):
                PhotoEventsView(model: model, engine: engine, flyerID: flyerID, currentID: from)
            }
        }
    }
}

enum PhoneTab: String, Hashable {
    case upcoming = "Upcoming"
    case past = "Past"
    /// Not a page: tapping it opens the camera.
    case camera = "Camera"
    case map = "Map"
}

struct EventListView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    @State private var tab = PhoneTab.upcoming
    /// Each tab keeps its own place, as tab bars do.
    @State private var paths: [PhoneTab: [PhoneRoute]] = [:]
    @State private var isShowingSettings = false
    @State private var isShowingCamera = false

    private var today: Day { .today }

    /// Tabs along the bottom, where your thumb is. The map sits apart at the bottom right, the
    /// place iOS gives a tab that isn't one of the lists.
    var body: some View {
        // Tapping Map while on the map goes back to Upcoming, so the map button works as a toggle.
        // Camera never becomes the page: it opens the camera over whatever you're looking at.
        TabView(selection: Binding(get: { tab }, set: { new in
            if new == .camera {
                isShowingCamera = true
                return
            }
            tab = new == .map && tab == .map ? .upcoming : new
        })) {
            Tab(PhoneTab.upcoming.rawValue, systemImage: "calendar", value: PhoneTab.upcoming) { stack(.upcoming) }
            Tab(PhoneTab.past.rawValue, systemImage: "clock", value: PhoneTab.past) { stack(.past) }
            // Last of the tabs, so it sits right beside Map.
            Tab(PhoneTab.camera.rawValue, systemImage: "camera", value: PhoneTab.camera) { Color.clear }
            Tab(PhoneTab.map.rawValue, systemImage: "map", value: PhoneTab.map, role: .search) {
                PhoneMapView(model: model, engine: engine)
            }
        }
        .sheet(isPresented: $isShowingSettings) { PhoneSettingsView(model: model, engine: engine) }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraCapture { photo in
                Task { await scanCameraPhoto(photo) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $model.isShowingSetup, onDismiss: model.setupClosed) { PhoneSetupView(model: model, engine: engine) }
        .confirmingDelete($model.pendingDelete, engine: engine, perform: model.delete)
        .photoDeletePrompt(model: model, engine: engine)
        .sensoryFeedback(.success, trigger: engine.lastDeletedIDs) { _, new in !new.isEmpty }
    }

    /// Reads a photo you just took, like a dropped photo on the Mac, then opens what it found.
    private func scanCameraPhoto(_ photo: DroppedPhoto) async {
        let found = await engine.scanDropped([photo])
        guard let first = found.first, let event = engine.event(id: first) else { return }
        let target: PhoneTab = event.isOver(today: today) ? .past : .upcoming
        tab = target
        paths[target] = [.event(first)]
    }

    private func stack(_ tab: PhoneTab) -> some View {
        NavigationStack(path: Binding(get: { paths[tab] ?? [] }, set: { paths[tab] = $0 })) {
            list(tab)
                .navigationTitle(tab.rawValue)
                .phoneRoutes(model: model, engine: engine)
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
                // Both sections stay in place, even when empty, so a restored event slides from
                // one to the other instead of a whole section popping in or out under your finger.
                List {
                    Section { ForEach(events) { row(for: $0, day: $0.startDay) } }
                    Section {
                        ForEach(hidden) { hiddenRow($0) }
                    } header: {
                        if !hidden.isEmpty { Text("Recently Deleted") }
                    } footer: {
                        if !hidden.isEmpty {
                            Text("Swipe one to restore it, or open it. Deleted events leave this list after 30 days.")
                        }
                    }
                    bottomSpace
                }
                .animation(.snappy, value: hidden.map(\.id))
            }
        case .map, .camera:
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
        NavigationLink(value: PhoneRoute.event(event.id)) {
            EventRow(event: event, day: day, thumbnail: model.thumbnail(engine.flyer(id: event.flyerID)))
        }
        // A soft green wash on events you haven't opened yet, like unread messages.
        .listRowBackground(event.isUnseen ? Color.green.opacity(0.14) : nil)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { model.requestDelete([event.id]) } label: { Label("Delete", systemImage: "trash") }
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
            Button("Delete", systemImage: "trash", role: .destructive) { model.requestDelete([event.id]) }
        }
    }

    /// Tap to open its page, which has Restore, or swipe left to restore it here.
    private func hiddenRow(_ event: FlyerEvent) -> some View {
        NavigationLink(value: PhoneRoute.event(event.id)) {
            EventRow(
                event: event, day: event.startDay, thumbnail: model.thumbnail(engine.flyer(id: event.flyerID)),
                note: event.state == .removedInCalendar ? "Removed in Calendar" : "Deleted in Flyers"
            )
            .opacity(0.6)
        }
        // Swiping left shows Restore on the right, where Delete sits on other rows.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { engine.restoreAfterSwipe(event.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
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

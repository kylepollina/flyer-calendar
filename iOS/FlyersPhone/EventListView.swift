import FlyersCore
import SwiftUI
import UIKit

enum PhoneTab: String, CaseIterable, Identifiable {
    case upcoming = "Upcoming"
    case review = "Review"
    case past = "Past"
    case deleted = "Deleted"
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
                .safeAreaInset(edge: .top, spacing: 0) { tabs }
                .overlay(alignment: .bottom) { notices }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isShowingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { isShowingMap = true } label: { Label("Map", systemImage: "map") }
                        if model.canScan {
                            Button { Task { await model.scanNow() } } label: {
                                Label("Scan now", systemImage: "arrow.clockwise")
                            }
                            .disabled(engine.isScanning)
                        }
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
                .fullScreenCover(isPresented: $model.isShowingSetup, onDismiss: model.setupClosed) { PhoneSetupView(model: model, engine: engine) }
                .photoDeletePrompt(model: model, engine: engine)
                .sensoryFeedback(.success, trigger: engine.lastDeletedIDs) { _, new in !new.isEmpty }
                .animation(.snappy, value: noticeKey)
        }
    }

    /// Floats over the list, so it reads as part of the glass toolbar rather than a bar of its own.
    private var tabs: some View {
        Picker("View", selection: $tab) {
            Text("Upcoming").tag(PhoneTab.upcoming)
            Text(reviewCount > 0 ? "Review \(reviewCount)" : "Review").tag(PhoneTab.review)
            Text("Past").tag(PhoneTab.past)
            Text("Deleted").tag(PhoneTab.deleted)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var list: some View {
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
        case .review:
            let events = EventList.needingReview(engine.document.events)
            if events.isEmpty {
                ContentUnavailableView(
                    "Nothing to check", systemImage: "checkmark.circle",
                    description: Text("Events that need a second look wait here before reaching your calendar.")
                )
            } else {
                List {
                    ForEach(events) { row(for: $0, day: $0.startDay) }
                    bottomSpace
                }
            }
        case .past:
            let events = EventList.past(engine.document.events, today: today)
            if events.isEmpty {
                ContentUnavailableView(
                    "No past events", systemImage: "clock", description: Text("Events move here once they've finished.")
                )
            } else {
                List {
                    Section { ForEach(events) { row(for: $0, day: $0.startDay) } }
                    bottomSpace
                }
            }
        case .deleted:
            let hidden = engine.hiddenEvents
            if hidden.isEmpty {
                ContentUnavailableView(
                    "Nothing deleted", systemImage: "trash",
                    description: Text("Events you delete, here or in Calendar, wait here in case you want them back.")
                )
            } else {
                List {
                    Section {
                        ForEach(hidden) { hiddenRow($0) }
                    } header: {
                        HStack {
                            Text("\(hidden.count) deleted")
                            Spacer()
                            Button("Restore All") { engine.restore(hidden.map(\.id)) }
                                .font(.subheadline)
                                .textCase(nil)
                        }
                    } footer: {
                        Text("Deleted events stay here, so a rescan can't bring them back. Swipe one to restore it.")
                    }
                    bottomSpace
                }
            }
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

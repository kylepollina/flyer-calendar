import AppKit
import CoreLocation
import FlyersCore
import SwiftUI

enum ListTab: String, CaseIterable, Identifiable {
    case upcoming = "Upcoming"
    case past = "Past"
    var id: String { rawValue }
}

/// Switches lists with a row of glass buttons, like the tab bar on iPhone. The chosen one sits
/// in a lighter pill that slides between them.
struct GlassTabs: View {
    let items: [(tab: ListTab, symbol: String)]
    @Binding var selection: ListTab
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.tab) { item in
                let isSelected = item.tab == selection
                Button { selection = item.tab } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.symbol).font(.system(size: 15, weight: .medium))
                        Text(item.tab.rawValue).font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(.primary.opacity(0.1))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .glassSurface(in: Capsule())
        .animation(.snappy, value: selection)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: FlyersEngine
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var tab = ListTab.upcoming
    @State private var selection: UUID?
    /// What to select once a link's tab switch has happened.
    @State private var linkedSelection: UUID?
    @State private var linkMessage: String?
    @State private var isShowingMap = false
    /// Shows every event from one photo in the detail pane, opened from an event's page.
    @State private var photoEventsFlyerID: UUID?
    @State private var photoViewer: PhotoViewerItem?
    @State private var isDropTargeted = false
    /// Flyers left with no events after a delete, waiting for you to choose whether to delete their photos.
    @State private var orphanedFlyers: [Flyer] = []
    /// Events waiting for you to confirm deleting them.
    @State private var pendingDelete: [UUID] = []

    private var today: Day { .today }

    var body: some View {
        Group {
            if model.showsSetup {
                SetupView(model: model, engine: engine)
            } else {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 460)
                        // In the window's toolbar over the sidebar, Settings and Scan now share one
                        // piece of glass.
                        .toolbar {
                            ToolbarItemGroup(placement: .automatic) {
                                Toggle(isOn: Binding(
                                    get: { model.isShowingSettings },
                                    set: { showing in
                                        if showing { model.isShowingSettings = true } else { showList(tab) }
                                    }
                                )) {
                                    Label("Settings", systemImage: "gearshape")
                                        .labelStyle(.titleAndIcon)
                                        // Room between the words and the glass edge.
                                        .padding(.horizontal, 6)
                                }
                                .help("Settings (⌘,)")
                                Button {
                                    Task { await engine.scan() }
                                } label: {
                                    Label("Scan now", systemImage: "arrow.clockwise")
                                }
                                .disabled(engine.isScanning)
                                .keyboardShortcut("r")
                                .help("Check your library for new flyers (⌘R)")
                            }
                        }
                } detail: {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) { notices }
                }
                .background { tabShortcuts }
                .onDrop(of: DropLoader.types, isTargeted: $isDropTargeted, perform: scanDrop)
                .overlay {
                    if isDropTargeted {
                        DropTargetOverlay().transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: isDropTargeted)
                .overlay {
                    if let item = photoViewer {
                        PhotoViewer(item: item) { photoViewer = nil }
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: photoViewer?.id)
            }
        }
        .confirmationDialog(
            photoCount == 1 ? "Delete the photo too?" : "Delete the \(photoCount) photos too?",
            isPresented: Binding(get: { !orphanedFlyers.isEmpty }, set: { if !$0 { orphanedFlyers = [] } })
        ) {
            Button(photoCount == 1 ? "Delete Photo" : "Delete Photos", role: .destructive) {
                let ids = orphanedFlyers.map(\.id)
                Task { await engine.deletePhotos(of: ids) }
            }
            Button(photoCount == 1 ? "Keep Photo" : "Keep Photos", role: .cancel) {}
        } message: {
            Text(photoDeleteMessage)
        }
        .onAppear {
            // Started at login, the app stays in the menu bar unless it still needs setting up.
            if AppDelegate.launchedAtLogin && model.isSetUp {
                AppDelegate.launchedAtLogin = false
                dismissWindow(id: AppModel.mainWindowID)
                return
            }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            model.refreshAccess()
            if let id = model.eventToReveal {
                model.eventToReveal = nil
                reveal(id)
            } else if selection == nil && !model.isShowingSettings {
                selection = firstRowID(in: tab)
            }
            model.showTourIfNew()
        }
        .onChange(of: model.showsSetup) {
            // Setup just finished, so this is the first look at the main window.
            if !model.showsSetup { model.showTourIfNew() }
        }
        .sheet(isPresented: Binding(get: { model.isShowingTour }, set: { if !$0 { model.tourClosed() } })) {
            TourView { model.tourClosed() }
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .onChange(of: tab) {
            selection = linkedSelection ?? firstRowID(in: tab)
            linkedSelection = nil
        }
        .onChange(of: selection) {
            if selection != nil {
                photoEventsFlyerID = nil
                model.isShowingSettings = false
                isShowingMap = false
            }
        }
        .onChange(of: isShowingMap) {
            if isShowingMap {
                model.isShowingSettings = false
                selection = nil
            } else if selection == nil && !model.isShowingSettings {
                selection = firstRowID(in: tab)
            }
        }
        .onChange(of: model.isShowingSettings) {
            // Clears the row, so clicking it again leaves the settings page.
            if model.isShowingSettings {
                selection = nil
                isShowingMap = false
            }
        }
        .onChange(of: model.eventToReveal) {
            guard let id = model.eventToReveal else { return }
            model.eventToReveal = nil
            reveal(id)
        }
        .onOpenURL(perform: openLink)
        .confirmingDelete($pendingDelete, engine: engine, perform: performDelete)
    }

    /// ⌘1, ⌘2 and ⌘3 switch lists. A segmented picker can't hold shortcuts itself.
    private var tabShortcuts: some View {
        ForEach(Array(ListTab.allCases.enumerated()), id: \.element) { index, item in
            Button(item.rawValue) { showList(item) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// Goes to a list, leaving the settings page even if that list is already the current one.
    private func showList(_ item: ListTab) {
        model.isShowingSettings = false
        isShowingMap = false
        if item == tab {
            if selection == nil { selection = firstRowID(in: tab) }
        } else {
            tab = item
        }
    }

    private func openLink(_ url: URL) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        guard let event = engine.eventForLink(url) else {
            linkMessage = "That event isn't in Flyers anymore."
            return
        }
        linkMessage = nil
        reveal(event.id)
    }

    /// Switches to the list that holds the event and selects it.
    private func reveal(_ id: UUID) {
        guard let event = engine.event(id: id) else { return }
        isShowingMap = false
        let target: ListTab = event.isOver(today: today) ? .past : .upcoming
        if target == tab {
            selection = event.id
        } else {
            linkedSelection = event.id
            tab = target
        }
    }

    // MARK: Notices

    /// Changes whenever a notice appears or goes away, which drives the animation.
    private var noticeKey: String {
        [
            linkMessage, engine.dropSummary, engine.alertMessage, engine.scanProgress,
            engine.isPaused && !engine.isScanning ? "paused" : nil,
            engine.lastDeletedIDs.isEmpty ? nil : "\(engine.lastDeletedIDs.count)",
        ]
        .map { $0 == nil ? "-" : "+" }
        .joined()
    }

    /// Notices float over the content, so nothing jumps when one comes or goes.
    private var notices: some View {
        GlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                if let linkMessage {
                    Notice(systemImage: "link", text: linkMessage, tint: .secondary) {
                        Button("Dismiss") { self.linkMessage = nil }
                    }
                }
                if let summary = engine.dropSummary {
                    Notice(systemImage: "photo.badge.checkmark", text: summary, tint: .secondary) {
                        Button("Dismiss") { engine.clearDropSummary() }
                    }
                }
                if let message = engine.alertMessage {
                    Notice(systemImage: "exclamationmark.triangle.fill", text: message, tint: .orange) {
                        Button("Dismiss") { engine.clearAlert() }
                    }
                }
                if let progress = engine.scanProgress {
                    Notice(text: progress, tint: .secondary) {
                        Button("Stop") { engine.stopScan() }.disabled(engine.isStopping)
                    }
                }
                if engine.isPaused && !engine.isScanning {
                    Notice(systemImage: "pause.circle.fill", text: "Scanning is paused", tint: .secondary) {
                        Button("Resume") { Task { await engine.scan() } }
                    }
                }
                if !engine.lastDeletedIDs.isEmpty {
                    let count = engine.lastDeletedIDs.count
                    Notice(systemImage: "trash", text: count == 1 ? "Event deleted" : "\(count) events deleted", tint: .secondary) {
                        Button("Undo") { engine.undoDelete() }
                        Button("Dismiss") { engine.dismissUndo() }
                    }
                }
            }
        }
        .frame(maxWidth: 480)
        .padding(16)
        .animation(.snappy, value: noticeKey)
    }

    // MARK: Sidebar

    /// Like the iPhone: the list switch floats at the bottom, where it's easy to reach. Settings is
    /// in the toolbar above, and the last scan sits at the top of the list.
    private var sidebar: some View {
        list
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 10) {
                    if let scanStatus {
                        Text(scanStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(scanStatus)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 10) {
                    GlassTabs(
                        items: [(ListTab.upcoming, "calendar"), (ListTab.past, "clock")],
                        selection: Binding(get: { tab }, set: showList)
                    )
                    mapButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
    }

    /// Beside the list switch, like the Map button beside the tab bar on iPhone. Shows every event
    /// on a map in place of the event, and lit up while it does.
    private var mapButton: some View {
        Button { isShowingMap.toggle() } label: {
            Image(systemName: isShowingMap ? "map.fill" : "map")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isShowingMap ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle())
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .help("Show every event on a map (⇧⌘M)")
        .accessibilityLabel("Map")
        .accessibilityAddTraits(isShowingMap ? .isSelected : [])
    }

    private var scanStatus: String? {
        guard let date = engine.document.lastScanAt else { return nil }
        let when = "Scanned \(date.formatted(.relative(presentation: .named)))"
        guard let summary = engine.document.lastScanSummary else { return when }
        return "\(when) · \(summary)"
    }

    @ViewBuilder private var list: some View {
        switch tab {
        case .upcoming:
            let sections = EventList.upcoming(engine.document.events, today: today)
            if sections.isEmpty {
                EmptyList(symbol: "calendar", title: "No upcoming events", message: "Photograph a flyer and it'll show up here after the next scan.")
            } else {
                List(selection: $selection) {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in eventRow(row.event, day: row.next) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand(perform: deleteSelection)
            }
        case .past:
            let events = EventList.past(engine.document.events, today: today)
            let hidden = engine.hiddenEvents
            if events.isEmpty && hidden.isEmpty {
                EmptyList(symbol: "clock", title: "No past events", message: "Events move here once they've finished.")
            } else {
                List(selection: $selection) {
                    ForEach(events) { eventRow($0, day: $0.startDay) }
                    if !hidden.isEmpty {
                        // Deleted events stay in the library, so a rescan can't bring them back.
                        // Here you can bring them back yourself.
                        Section("Recently Deleted") {
                            ForEach(hidden) { hiddenRow($0) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand(perform: deleteSelection)
            }
        }
    }

    private func firstRowID(in tab: ListTab) -> UUID? {
        switch tab {
        case .upcoming:
            return EventList.upcoming(engine.document.events, today: today).first?.rows.first?.id
        case .past:
            return EventList.past(engine.document.events, today: today).first?.id
        }
    }

    private func hiddenRow(_ event: FlyerEvent) -> some View {
        HStack(spacing: 8) {
            RowLabel(
                title: event.name,
                subtitle: EventFormat.summary(event, day: event.startDay),
                detail: event.state == .removedInCalendar ? "Removed in Calendar" : "Deleted in Flyers",
                thumbnail: thumbnail(engine.flyer(id: event.flyerID)),
                repeats: event.rrule != nil,
                status: nil
            )
            .opacity(0.6)
        }
        // Click to open its page, which has Restore. Or swipe left, or Control-click.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { engine.restore([event.id]) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                .tint(.blue)
        }
        .contextMenu {
            Button("Restore") { engine.restore([event.id]) }
        }
    }

    private func eventRow(_ event: FlyerEvent, day: Day?, showsThumbnail: Bool = true) -> some View {
        RowLabel(
            title: event.name,
            subtitle: EventFormat.summary(event, day: day),
            detail: event.location,
            thumbnail: thumbnail(engine.flyer(id: event.flyerID)),
            repeats: event.rrule != nil,
            status: RowStatus(event.state),
            showsThumbnail: showsThumbnail
        )
        .tag(event.id)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { delete([event.id]) } label: { Label("Delete", systemImage: "trash") }
        }
        .contextMenu {
            if event.state == .available || event.state == .needsReview {
                Button("Add to Calendar") { engine.addToCalendar(event.id) }
            }
            Button("Delete", role: .destructive) { delete([event.id]) }
        }
    }

    private func thumbnail(_ flyer: Flyer?) -> NSImage? {
        guard let name = flyer?.thumbnailFile else { return nil }
        return NSImage(contentsOf: engine.store.thumbnailsDirectory.appendingPathComponent(name))
    }

    /// Every delete asks first.
    private func delete(_ ids: [UUID]) {
        pendingDelete = ids
    }

    /// When this removes the last event from a photo, offers to delete the photo too.
    private func performDelete(_ ids: [UUID]) {
        if let selection, ids.contains(selection) { self.selection = nil }
        let flyers = engine.flyersOnlyUsedBy(ids)
        engine.delete(ids)
        orphanedFlyers = flyers
    }

    private var photoCount: Int { orphanedFlyers.reduce(0) { $0 + $1.allAssetIDs.count } }

    private var photoDeleteMessage: String {
        let it = photoCount == 1 ? "it" : "them"
        let start = "No other events in Flyers come from \(it)."
        if orphanedFlyers.contains(where: \.mayBeInLibrary) {
            return start + " Photos keeps deleted photos in Recently Deleted for 30 days."
        }
        return start + " Flyers has the only copy, so \(it) can't be recovered."
    }

    /// Scans dropped images, then shows the first new event.
    private func scanDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            let photos = await DropLoader.load(providers)
            guard !photos.isEmpty else {
                linkMessage = "Only images can be scanned."
                return
            }
            let new = await engine.scanDropped(photos)
            if let first = new.first {
                model.isShowingSettings = false
                reveal(first)
            }
        }
        return true
    }

    private func viewPhoto(of flyer: Flyer?) {
        guard let flyer else { return }
        photoViewer = PhotoViewerItem(assetIDs: PhotoRef.all(for: flyer, store: engine.store), thumbnail: thumbnail(flyer))
    }

    private func deleteSelection() {
        guard let selection, let event = engine.event(id: selection), !event.isHidden else { return }
        delete([selection])
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if model.isShowingSettings {
            SettingsView(model: model, engine: engine)
        } else if isShowingMap {
            EventsMap(engine: engine, thumbnail: { thumbnail(engine.flyer(id: $0.flyerID)) }) { reveal($0) }
        } else if let flyerID = photoEventsFlyerID {
            PhotoEventsPage(
                engine: engine, flyerID: flyerID, currentID: selection,
                thumbnail: thumbnail(engine.flyer(id: flyerID)),
                onViewPhoto: { viewPhoto(of: engine.flyer(id: flyerID)) },
                onSelect: { id in
                    photoEventsFlyerID = nil
                    self.selection = id
                },
                onBack: { photoEventsFlyerID = nil },
                onDelete: delete
            )
        } else if let selection, let event = engine.event(id: selection) {
            EventDetail(
                engine: engine, event: event, thumbnail: thumbnail(engine.flyer(id: event.flyerID)),
                onViewPhoto: { viewPhoto(of: engine.flyer(id: event.flyerID)) },
                onShowPhotoEvents: { photoEventsFlyerID = event.flyerID },
                onDelete: delete
            )
            .id(event.id)
        } else if firstRowID(in: tab) != nil {
            ContentUnavailableView("Select an event", systemImage: "photo.on.rectangle.angled")
        } else {
            // The sidebar already explains why its list is empty.
            Color.clear
        }
    }
}

// MARK: - Pieces

/// Rows only mark what needs attention. Most events are on the calendar, so a mark
/// on each one would just be noise.
enum RowStatus {
    case review
    case waiting

    init?(_ state: EventState) {
        switch state {
        case .needsReview: self = .review
        case .queued: self = .waiting
        default: return nil
        }
    }
}

struct RowLabel: View {
    let title: String
    let subtitle: String
    let detail: String?
    let thumbnail: NSImage?
    let repeats: Bool
    let status: RowStatus?
    var showsThumbnail = true

    var body: some View {
        HStack(spacing: 12) {
            if showsThumbnail {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 42, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.12))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold).lineLimit(1)
                HStack(spacing: 4) {
                    if repeats {
                        Image(systemName: "repeat").imageScale(.small).accessibilityLabel("Repeats")
                    }
                    Text(subtitle).lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            switch status {
            case .review:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help("Needs a second look")
                    .accessibilityLabel("Needs review")
            case .waiting:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .help("Waiting for a calendar")
                    .accessibilityLabel("Waiting for a calendar")
            case nil:
                EmptyView()
            }
        }
        .padding(.vertical, 3)
    }
}

/// A floating message with its actions. With no symbol it shows a spinner.
struct Notice<Actions: View>: View {
    var systemImage: String?
    let text: String
    let tint: Color
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(tint)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.callout).lineLimit(2)
            Spacer(minLength: 8)
            actions()
                .buttonStyle(.borderless)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct EmptyList: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The scrolling page behind an event or a schedule, tinted by its flyer.
struct DetailPage<Content: View>: View {
    let thumbnail: NSImage?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16, content: content)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                // Leaves room to scroll past a floating notice.
                .padding(.bottom, 72)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background { FlyerBackdrop(image: thumbnail) }
    }
}

/// The flyer itself, like a print on the page.
struct FlyerPoster: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 190, maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18))
            }
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }
}

/// One labeled line in an event's card.
struct FactRow<Value: View>: View {
    let symbol: String
    let label: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                value()
            }
            Spacer(minLength: 0)
        }
    }
}

struct EventDetail: View {
    @ObservedObject var engine: FlyersEngine
    let event: FlyerEvent
    let thumbnail: NSImage?
    let onViewPhoto: () -> Void
    let onShowPhotoEvents: () -> Void
    let onDelete: ([UUID]) -> Void
    @State private var isEditing = false

    /// Every event that came from the same photo, this one included.
    private var fromSamePhoto: [FlyerEvent] {
        EventList.fromFlyer(event.flyerID, in: engine.document.events, today: .today)
    }
    @State private var pendingLink: URL?

    private var flyer: Flyer? { engine.flyer(id: event.flyerID) }

    var body: some View {
        DetailPage(thumbnail: thumbnail) {
            header
            if !event.problems.isEmpty {
                GlassCard(tint: .orange.opacity(0.25)) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(event.problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                }
            }
            actions
            facts
            if let details = event.details {
                GlassCard {
                    Text(details).textSelection(.enabled)
                }
            }
            if fromSamePhoto.count > 1 { samePhotoCard }
        }
        .sheet(isPresented: $isEditing) { EditEventSheet(engine: engine, event: event) }
        // Starts loading the original now, so it's ready when you open the photo.
        .task(id: event.flyerID) {
            if let flyer, let first = PhotoRef.all(for: flyer, store: engine.store).first {
                PhotoCache.shared.prefetch([first])
            }
        }
        // Flyers can link anywhere, so show the whole address before opening it.
        .confirmationDialog(
            "Open this link?",
            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            presenting: pendingLink
        ) { url in
            Button("Open in browser") { NSWorkspace.shared.open(url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text(url.absoluteString)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            if let thumbnail {
                Button(action: onViewPhoto) { FlyerPoster(image: thumbnail) }
                    .buttonStyle(.plain)
                    .help("View the full photo")
                    .accessibilityLabel("View the full photo")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(event.name)
                    .font(.system(.title, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(EventFormat.full(event))
                    .font(.title3)
                    .foregroundStyle(.primary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Label(statusText, systemImage: statusSymbol)
                    .font(.callout)
                    .foregroundStyle(event.state == .onCalendar ? AnyShapeStyle(.green) : AnyShapeStyle(.primary.opacity(0.8)))
                    .padding(.top, 2)
            }
            .padding(.top, 4)
        }
    }

    private var actions: some View {
        GlassGroup {
            HStack(spacing: 8) {
                if event.isHidden {
                    // A deleted event's page only offers to bring it back.
                    Button { engine.restore([event.id]) } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .glassButton(prominent: true)
                    .help(event.state == .removedInCalendar
                        ? "Bring it back to Flyers. Use Add to Calendar if it's no longer on your calendar."
                        : "Bring it back, and onto your calendar if it was there")
                    Button(action: onViewPhoto) {
                        Label("View photo", systemImage: "photo").labelStyle(.iconOnly)
                    }
                    .glassButton()
                    .help("View the full photo")
                } else {
                    liveActions
                }
            }
            .controlSize(.large)
        }
    }

    /// Everything you can do with an event that isn't deleted.
    @ViewBuilder private var liveActions: some View {
                if event.state == .needsReview || event.state == .available {
                    Button { engine.addToCalendar(event.id) } label: {
                        Label("Add to Calendar", systemImage: "calendar.badge.plus")
                    }
                    .glassButton(prominent: true)
                }
                if event.state == .onCalendar {
                    Button { engine.removeFromCalendar(event.id) } label: {
                        Label("Remove from Calendar", systemImage: "calendar.badge.minus")
                    }
                    .glassButton()
                }
                Button { isEditing = true } label: {
                    Label("Edit", systemImage: "pencil").labelStyle(.iconOnly)
                }
                .glassButton()
                .keyboardShortcut("e")
                .help("Edit (⌘E)")
                Button(action: onViewPhoto) {
                    Label("View photo", systemImage: "photo").labelStyle(.iconOnly)
                }
                .glassButton()
                .help("View the full photo")
                if let flyer, flyer.mayBeInLibrary, flyer.assetID != "demo" {
                    Button { Task { await engine.removeFromLibrary(flyerID: flyer.id) } } label: {
                        Label("Remove Photo from Photos", systemImage: "photo.badge.arrow.down").labelStyle(.iconOnly)
                    }
                    .glassButton()
                    .help("Remove the photo from your Photos library. Flyers keeps a copy, and every event stays.")
                }
                Spacer(minLength: 0)
                Button(role: .destructive) { onDelete([event.id]) } label: {
                    Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                }
                .glassButton()
                .help("Delete")
    }

    @ViewBuilder private var facts: some View {
        let links = event.allLinks.compactMap { link in URL(string: link.url).map { (label: link.label, url: $0) } }
        let sponsors = event.sponsors ?? []
        if event.recurrence != nil || event.location != nil || !links.isEmpty || !sponsors.isEmpty || event.datePrinted != nil {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    if let recurrence = event.recurrence {
                        FactRow(symbol: "repeat", label: "Repeats") {
                            Text(EventFormat.repeats(recurrence))
                        }
                    }
                    if let location = event.location {
                        FactRow(symbol: "mappin.and.ellipse", label: event.locationInferred ? "Where (best guess)" : "Where") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(location).textSelection(.enabled)
                                LocationMap(location: location, near: photoCoordinate)
                            }
                        }
                    }
                    if !links.isEmpty {
                        FactRow(symbol: "link", label: links.count == 1 ? "Link" : "Links") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(links, id: \.url) { link in
                                    let host = link.url.host() ?? link.url.absoluteString
                                    let title = links.count == 1 || link.label == "Link" ? host : "\(link.label) · \(host)"
                                    Button(title) { pendingLink = link.url }
                                        .buttonStyle(.link)
                                        .help(link.url.absoluteString)
                                }
                            }
                        }
                    }
                    if !sponsors.isEmpty {
                        FactRow(symbol: "star", label: sponsors.count == 1 ? "Sponsor" : "Sponsors") {
                            Text(sponsors.joined(separator: ", "))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    if let printed = event.datePrinted {
                        FactRow(symbol: "text.quote", label: "As printed") {
                            Text(printed).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    /// The other events read from this photo, on a page of their own where you can manage them.
    private var samePhotoCard: some View {
        Button(action: onShowPhotoEvents) {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "photo.stack").foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(fromSamePhoto.count) events from this photo").font(.headline)
                        Text(fromSamePhoto.filter { $0.id != event.id }.map(\.name).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    private var photoCoordinate: CLLocationCoordinate2D? { flyer?.coordinate }

    private var statusSymbol: String {
        switch event.state {
        case .onCalendar: return "checkmark.circle.fill"
        case .queued: return "clock"
        case .needsReview: return "exclamationmark.circle"
        case .deleted, .removedInCalendar: return "trash"
        default: return "calendar"
        }
    }

    private var statusText: String {
        switch event.state {
        case .onCalendar: return "On your calendar"
        case .queued: return "Waiting for a calendar"
        case .needsReview: return "Waiting for you to check it"
        case .deleted: return "Deleted. Restore it to bring it back."
        case .removedInCalendar: return "Removed in Calendar. Restore it to bring it back."
        default: return "Not on your calendar"
        }
    }
}

struct EditEventSheet: View {
    @ObservedObject var engine: FlyersEngine
    let event: FlyerEvent
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start = Date()
    @State private var hasTime = false
    @State private var hasEndTime = false
    @State private var end = Date()
    @State private var location = ""
    @State private var link = ""
    @State private var details = ""
    @State private var linkError: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Location", text: $location)
            }
            Section {
                DatePicker("Date", selection: $start, displayedComponents: .date)
                Toggle("Has a start time", isOn: $hasTime)
                if hasTime {
                    DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                    Toggle("Has an end time", isOn: $hasEndTime)
                    if hasEndTime {
                        DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                    }
                }
            }
            Section {
                TextField("Main link", text: $link)
                if let linkError {
                    Text(linkError).font(.caption).foregroundStyle(.red)
                }
                TextField("Details", text: $details, axis: .vertical).lineLimit(2...5)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        name = event.name
        location = event.location ?? ""
        link = event.url ?? ""
        details = event.details ?? ""
        hasTime = event.startTime != nil
        hasEndTime = event.endTime != nil
        start = CalendarService.times(for: event)?.start ?? Date()
        end = CalendarService.times(for: event)?.end ?? start
    }

    private func save() {
        let trimmedLink = link.trimmingCharacters(in: .whitespaces)
        let url = Ingest.normalizedURL(trimmedLink)
        if !trimmedLink.isEmpty && url == nil {
            linkError = "Enter a web address, such as example.org"
            return
        }
        let format = { (date: Date) -> String in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        engine.edit(event.id) {
            $0.name = name.isEmpty ? event.name : name
            $0.startDay = Day(date: start)
            $0.startTime = hasTime ? format(start) : nil
            $0.endTime = hasTime && hasEndTime ? format(end) : nil
            $0.location = location.isEmpty ? nil : location
            $0.setMainLink(url)
            $0.details = details.isEmpty ? nil : details
        }
        dismiss()
    }
}

/// Shown while images are dragged over the window.
struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.35))
            VStack(spacing: 10) {
                Image(systemName: "photo.badge.plus").font(.system(size: 44))
                Text("Drop photos to scan").font(.title2.weight(.semibold))
                Text("Screenshots taken within a couple of minutes of each other are read together.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(8)
        }
        .allowsHitTesting(false)
    }
}

/// Every event read from one photo, under the photo itself. Opened from an event's page, and shown in
/// its place in the detail pane. Swipe an event, or Control-click it, to delete it.
struct PhotoEventsPage: View {
    @ObservedObject var engine: FlyersEngine
    let flyerID: UUID
    /// The event the page was opened from, if it's still there.
    let currentID: UUID?
    let thumbnail: NSImage?
    let onViewPhoto: () -> Void
    let onSelect: (UUID) -> Void
    let onBack: () -> Void
    let onDelete: ([UUID]) -> Void

    var body: some View {
        let events = EventList.fromFlyer(flyerID, in: engine.document.events, today: .today)
        List {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("[", modifiers: .command)
                HStack(alignment: .top, spacing: 20) {
                    if let thumbnail {
                        Button(action: onViewPhoto) { FlyerPoster(image: thumbnail) }
                            .buttonStyle(.plain)
                            .help("View the full photo")
                            .accessibilityLabel("View the full photo")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("From This Photo").font(.system(.title, weight: .bold))
                        Text(events.isEmpty ? "Every event from this photo was deleted." : events.count == 1 ? "1 event" : "\(events.count) events")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if !events.isEmpty {
                Section {
                    ForEach(events) { event in
                        Button { onSelect(event.id) } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.name).fontWeight(event.id == currentID ? .semibold : .regular)
                                    Text(event.recurrence.map(EventFormat.repeats) ?? EventFormat.summary(event, day: nil))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", systemImage: "trash", role: .destructive) { onDelete([event.id]) }
                        }
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { onDelete([event.id]) }
                        }
                    }
                } footer: {
                    Text("Swipe left on an event, or Control-click it, to delete it. Deleted events wait under Past, where you can restore them.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .background { FlyerBackdrop(image: thumbnail) }
    }
}

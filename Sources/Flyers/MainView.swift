import AppKit
import CoreLocation
import FlyersCore
import SwiftUI

enum ListTab: String, CaseIterable, Identifiable {
    case upcoming = "Upcoming"
    case review = "Needs review"
    case past = "Past"
    var id: String { rawValue }
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
    /// Schedules showing their events in the list, by flyer.
    @State private var expandedSeries: Set<UUID> = []
    @State private var photoViewer: PhotoViewerItem?
    /// Flyers left with no events after a delete, waiting for you to choose whether to delete their photos.
    @State private var orphanedFlyers: [Flyer] = []

    private var today: Day { .today }
    private var reviewCount: Int { EventList.needingReview(engine.document.events).count }

    var body: some View {
        Group {
            if model.showsSetup {
                SetupView(model: model, engine: engine)
            } else {
                NavigationSplitView {
                    sidebar.navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 460)
                } detail: {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) { notices }
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
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
                }
                .background { tabShortcuts }
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
        .onChange(of: reviewCount) { old, new in
            // Clearing the review list moves on to the next event, like working through an inbox.
            if tab == .review && new < old && !model.isShowingSettings { selection = firstRowID(in: .review) }
        }
        .onChange(of: selection) {
            if selection != nil { model.isShowingSettings = false }
        }
        .onChange(of: model.isShowingSettings) {
            // Clears the row, so clicking it again leaves the settings page.
            if model.isShowingSettings { selection = nil }
        }
        .onChange(of: model.eventToReveal) {
            guard let id = model.eventToReveal else { return }
            model.eventToReveal = nil
            reveal(id)
        }
        .onOpenURL(perform: openLink)
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
        // The event may be inside a schedule, which has to be open for its row to show.
        expandedSeries.insert(event.flyerID)
        let target: ListTab = event.state == .needsReview ? .review : event.isOver(today: today) ? .past : .upcoming
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
            linkMessage, engine.alertMessage, engine.scanProgress,
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

    private var sidebar: some View {
        list
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("View", selection: Binding(get: { tab }, set: showList)) {
                    Text("Upcoming").tag(ListTab.upcoming)
                    Text(reviewCount > 0 ? "Needs review \(reviewCount)" : "Needs review").tag(ListTab.review)
                    Text("Past").tag(ListTab.past)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    settingsRow
                    if let scanStatus {
                        Text(scanStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
    }

    /// Pinned below the list, and highlighted like a selected row while its page is showing.
    private var settingsRow: some View {
        Button {
            if model.isShowingSettings {
                showList(tab)
            } else {
                model.isShowingSettings = true
            }
        } label: {
            Label("Settings", systemImage: "gearshape")
                .fontWeight(.medium)
                .foregroundStyle(model.isShowingSettings ? .white : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    model.isShowingSettings ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Settings (⌘,)")
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
                            ForEach(section.rows) { row in rowView(row) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand(perform: deleteSelection)
            }
        case .review:
            let events = EventList.needingReview(engine.document.events)
            if events.isEmpty {
                EmptyList(symbol: "checkmark.circle", title: "Nothing to check", message: "Events that need a second look wait here before reaching your calendar.")
            } else {
                List(selection: $selection) {
                    ForEach(events) { eventRow($0, day: $0.startDay) }
                }
                .listStyle(.sidebar)
                .onDeleteCommand(perform: deleteSelection)
            }
        case .past:
            let events = EventList.past(engine.document.events, today: today)
            if events.isEmpty {
                EmptyList(symbol: "clock", title: "No past events", message: "Events move here once they've finished.")
            } else {
                List(selection: $selection) {
                    ForEach(events) { eventRow($0, day: $0.startDay) }
                }
                .listStyle(.sidebar)
                .onDeleteCommand(perform: deleteSelection)
            }
        }
    }

    private func firstRowID(in tab: ListTab) -> UUID? {
        switch tab {
        case .upcoming:
            switch EventList.upcoming(engine.document.events, today: today).first?.rows.first {
            case .event(let event, _): return event.id
            case .series(let flyerID, _, _): return flyerID
            case nil: return nil
            }
        case .review:
            return EventList.needingReview(engine.document.events).first?.id
        case .past:
            return EventList.past(engine.document.events, today: today).first?.id
        }
    }

    @ViewBuilder private func rowView(_ row: EventList.Row) -> some View {
        switch row {
        case .event(let event, let next):
            eventRow(event, day: next)
        case .series(let flyerID, let events, let next):
            let flyer = engine.flyer(id: flyerID)
            let isExpanded = expandedSeries.contains(flyerID)
            // Not a DisclosureGroup, whose leading chevron would push this thumbnail out of line
            // with the rows around it. Selecting the row opens the schedule, and the chevron
            // only shows or hides its events.
            HStack(spacing: 8) {
                RowLabel(
                    title: flyer?.title ?? "Weekly schedule",
                    subtitle: "\(events.count) repeating events",
                    detail: "Next \(EventFormat.shortDay(next))",
                    thumbnail: thumbnail(flyer),
                    repeats: true,
                    status: nil
                )
                Button {
                    withAnimation(.snappy) {
                        if isExpanded { expandedSeries.remove(flyerID) } else { expandedSeries.insert(flyerID) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .fontWeight(.semibold)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isExpanded ? "Hide these events" : "Show these events")
            }
            .tag(flyerID)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { delete(events.map(\.id)) } label: { Label("Delete", systemImage: "trash") }
            }
            .contextMenu {
                Button("Delete all \(events.count)", role: .destructive) { delete(events.map(\.id)) }
            }
            if isExpanded {
                // They share the schedule's flyer, which the row above already shows.
                ForEach(events) {
                    eventRow($0, day: $0.nextDay(onOrAfter: today), showsThumbnail: false)
                        .padding(.leading, 54)
                }
            }
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

    /// When this removes the last event from a photo, offers to delete the photo too.
    private func delete(_ ids: [UUID]) {
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

    private func viewPhoto(of flyer: Flyer?) {
        guard let flyer else { return }
        photoViewer = PhotoViewerItem(assetIDs: PhotoRef.all(for: flyer, store: engine.store), thumbnail: thumbnail(flyer))
    }

    private func deleteSelection() {
        guard let selection else { return }
        if engine.event(id: selection) != nil {
            delete([selection])
        } else {
            // A selected series is one row for all its optional events.
            delete(engine.visibleEvents.filter { $0.flyerID == selection && $0.state == .available && $0.rrule != nil }.map(\.id))
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if model.isShowingSettings {
            SettingsView(model: model, engine: engine)
        } else if let selection, let event = engine.event(id: selection), !event.isHidden {
            EventDetail(
                engine: engine, event: event, thumbnail: thumbnail(engine.flyer(id: event.flyerID)),
                onViewPhoto: { viewPhoto(of: engine.flyer(id: event.flyerID)) }
            ) {
                delete([event.id])
            }
            .id(event.id)
        } else if let selection, let flyer = engine.flyer(id: selection) {
            SeriesDetail(
                engine: engine, flyer: flyer, thumbnail: thumbnail(flyer),
                events: engine.visibleEvents.filter { $0.flyerID == selection && $0.state == .available && $0.rrule != nil }
            )
            .id(flyer.id)
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
    let onDelete: () -> Void
    @State private var isEditing = false
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
                Spacer(minLength: 0)
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                }
                .glassButton()
                .help("Delete")
            }
            .controlSize(.large)
        }
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

    private var photoCoordinate: CLLocationCoordinate2D? {
        guard let latitude = flyer?.latitude, let longitude = flyer?.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var statusSymbol: String {
        switch event.state {
        case .onCalendar: return "checkmark.circle.fill"
        case .queued: return "clock"
        case .needsReview: return "exclamationmark.circle"
        default: return "calendar"
        }
    }

    private var statusText: String {
        switch event.state {
        case .onCalendar: return "On your calendar"
        case .queued: return "Waiting for a calendar"
        case .needsReview: return "Waiting for you to check it"
        default: return "Not on your calendar"
        }
    }
}

struct SeriesDetail: View {
    @ObservedObject var engine: FlyersEngine
    let flyer: Flyer
    let thumbnail: NSImage?
    let events: [FlyerEvent]

    var body: some View {
        DetailPage(thumbnail: thumbnail) {
            HStack(alignment: .top, spacing: 20) {
                if let thumbnail { FlyerPoster(image: thumbnail) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(flyer.title ?? "Weekly schedule")
                        .font(.system(.title, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("These repeat, so they stay here until you choose the ones you want on your calendar.")
                        .foregroundStyle(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(events) { event in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.name).fontWeight(.semibold)
                                Text(event.recurrence.map(EventFormat.repeats) ?? "")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { engine.addToCalendar(event.id) } label: {
                                Label("Add", systemImage: "calendar.badge.plus")
                            }
                            .glassButton()
                        }
                    }
                }
            }
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

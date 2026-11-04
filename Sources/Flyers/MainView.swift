import AppKit
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

    private var today: Day { .today }
    private var reviewCount: Int { EventList.needingReview(engine.document.events).count }

    var body: some View {
        VStack(spacing: 0) {
            if !model.isSetUp && !model.isDemo {
                SetupView(model: model, engine: engine)
            } else {
                banners
                HSplitView {
                    list.frame(minWidth: 300, idealWidth: 400)
                    detail.frame(minWidth: 340, maxWidth: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    Text("Upcoming").tag(ListTab.upcoming)
                    Text(reviewCount > 0 ? "Needs review \(reviewCount)" : "Needs review").tag(ListTab.review)
                    Text("Past").tag(ListTab.past)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await engine.scan() }
                } label: {
                    Label("Scan now", systemImage: "arrow.clockwise")
                }
                .disabled(engine.isScanning)
                .help("Check your library for new flyers")
            }
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
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .onChange(of: tab) {
            selection = linkedSelection
            linkedSelection = nil
        }
        .onOpenURL(perform: openLink)
    }

    private func openLink(_ url: URL) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        guard let event = engine.eventForLink(url) else {
            linkMessage = "That event isn't in Flyers anymore."
            return
        }
        linkMessage = nil
        let target: ListTab = event.state == .needsReview ? .review : event.isOver(today: today) ? .past : .upcoming
        if target == tab {
            selection = event.id
        } else {
            linkedSelection = event.id
            tab = target
        }
    }

    @ViewBuilder private var banners: some View {
        if let linkMessage {
            Banner(systemImage: "link", text: linkMessage, tint: .secondary) {
                Button("Dismiss") { self.linkMessage = nil }
            }
        }
        if let message = engine.alertMessage {
            Banner(systemImage: "exclamationmark.triangle", text: message, tint: .orange) {
                Button("Dismiss") { engine.clearAlert() }
            }
        }
        if let progress = engine.scanProgress {
            Banner(systemImage: "photo.on.rectangle", text: progress, tint: .secondary) {
                ProgressView().controlSize(.small)
                Button("Stop") { engine.stopScan() }.disabled(engine.isStopping)
            }
        }
        if engine.isPaused && !engine.isScanning {
            Banner(systemImage: "pause.circle", text: "Scanning is paused", tint: .secondary) {
                Button("Resume") { Task { await engine.scan() } }
            }
        }
        if !engine.lastDeletedIDs.isEmpty {
            let count = engine.lastDeletedIDs.count
            Banner(systemImage: "trash", text: count == 1 ? "Event deleted" : "\(count) events deleted", tint: .secondary) {
                Button("Undo") { engine.undoDelete() }
                Button("Dismiss") { engine.dismissUndo() }
            }
        }
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        switch tab {
        case .upcoming:
            let sections = EventList.upcoming(engine.document.events, today: today)
            if sections.isEmpty {
                EmptyList(title: "No upcoming events", message: "Photograph a flyer and it'll show up here after the next scan.")
            } else {
                List(selection: $selection) {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in rowView(row) }
                        }
                    }
                }
                .onDeleteCommand(perform: deleteSelection)
            }
        case .review:
            let events = EventList.needingReview(engine.document.events)
            if events.isEmpty {
                EmptyList(title: "Nothing to check", message: "Events that need a second look wait here before reaching your calendar.")
            } else {
                List(selection: $selection) {
                    ForEach(events) { eventRow($0, day: $0.startDay) }
                }
                .onDeleteCommand(perform: deleteSelection)
            }
        case .past:
            let events = EventList.past(engine.document.events, today: today)
            if events.isEmpty {
                EmptyList(title: "No past events", message: "Events move here once they've finished.")
            } else {
                List(selection: $selection) {
                    ForEach(events) { eventRow($0, day: $0.startDay) }
                }
                .onDeleteCommand(perform: deleteSelection)
            }
        }
    }

    @ViewBuilder private func rowView(_ row: EventList.Row) -> some View {
        switch row {
        case .event(let event, let next):
            eventRow(event, day: next)
        case .series(let flyerID, let events, let next):
            let flyer = engine.flyer(id: flyerID)
            DisclosureGroup {
                ForEach(events) { eventRow($0, day: $0.nextDay(onOrAfter: today)) }
            } label: {
                RowLabel(
                    title: flyer?.title ?? "Weekly schedule",
                    subtitle: "\(events.count) repeating events, next \(EventFormat.shortDay(next))",
                    thumbnail: thumbnail(flyer),
                    badge: "Optional"
                )
            }
            .tag(flyerID)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { delete(events.map(\.id)) } label: { Label("Delete", systemImage: "trash") }
            }
            .contextMenu {
                Button("Delete all \(events.count)", role: .destructive) { delete(events.map(\.id)) }
            }
        }
    }

    private func eventRow(_ event: FlyerEvent, day: Day?) -> some View {
        RowLabel(
            title: event.name,
            subtitle: [EventFormat.summary(event, day: day), event.location].compactMap { $0 }.joined(separator: " · "),
            thumbnail: thumbnail(engine.flyer(id: event.flyerID)),
            badge: event.rrule != nil ? "Repeats" : nil
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

    private func delete(_ ids: [UUID]) {
        if let selection, ids.contains(selection) { self.selection = nil }
        engine.delete(ids)
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
        if let selection, let event = engine.event(id: selection), !event.isHidden {
            EventDetail(engine: engine, event: event, thumbnail: thumbnail(engine.flyer(id: event.flyerID))) {
                delete([event.id])
            }
            .id(event.id)
        } else if let selection, let flyer = engine.flyer(id: selection) {
            SeriesDetail(
                engine: engine, flyer: flyer, thumbnail: thumbnail(flyer),
                events: engine.visibleEvents.filter { $0.flyerID == selection && $0.state == .available && $0.rrule != nil }
            )
            .id(flyer.id)
        } else {
            VStack(spacing: 6) {
                Text("Select an event").foregroundStyle(.secondary)
                if let summary = engine.document.lastScanSummary, let date = engine.document.lastScanAt {
                    Text("Last scan \(date.formatted(.relative(presentation: .named))): \(summary)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Pieces

struct RowLabel: View {
    let title: String
    let subtitle: String
    let thumbnail: NSImage?
    let badge: String?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 36, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct Banner<Actions: View>: View {
    let systemImage: String
    let text: String
    let tint: Color
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer()
            actions().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct EmptyList: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EventDetail: View {
    @ObservedObject var engine: FlyersEngine
    let event: FlyerEvent
    let thumbnail: NSImage?
    let onDelete: () -> Void
    @State private var isEditing = false
    @State private var isViewingPhoto = false
    @State private var pendingLink: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let thumbnail {
                    Button { isViewingPhoto = true } label: {
                        Image(nsImage: thumbnail)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 340)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("View the full photo")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.name).font(.title2).fontWeight(.semibold).textSelection(.enabled)
                    Text(EventFormat.full(event)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(event.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let recurrence = event.recurrence {
                        Label(EventFormat.repeats(recurrence), systemImage: "repeat")
                    }
                    if let location = event.location {
                        Label(event.locationInferred ? "\(location) (best guess)" : location, systemImage: "mappin.and.ellipse")
                            .textSelection(.enabled)
                    }
                    if let text = event.url, let url = URL(string: text) {
                        Button { pendingLink = url } label: {
                            Label(url.host() ?? text, systemImage: "link")
                        }
                        .buttonStyle(.link)
                    }
                    Label(statusText, systemImage: event.state == .onCalendar ? "calendar.badge.checkmark" : "calendar")
                        .foregroundStyle(event.state == .onCalendar ? .green : .secondary)
                }
                if let details = event.details {
                    Text(details).font(.callout).textSelection(.enabled)
                }
                if let printed = event.datePrinted {
                    Text("As printed: \(printed)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if event.state == .needsReview || event.state == .available {
                    Button("Add to Calendar") { engine.addToCalendar(event.id) }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
                if event.state == .onCalendar {
                    Button("Remove from Calendar") { engine.removeFromCalendar(event.id) }
                        .padding(.top, 4)
                }
                HStack {
                    Button("Edit") { isEditing = true }
                    Button("View photo") { isViewingPhoto = true }
                    Spacer()
                    Button("Delete", role: .destructive, action: onDelete)
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $isEditing) { EditEventSheet(engine: engine, event: event) }
        .sheet(isPresented: $isViewingPhoto) {
            FullPhotoSheet(assetID: engine.flyer(id: event.flyerID)?.assetID)
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

    private var statusText: String {
        switch event.state {
        case .onCalendar: return "On your calendar"
        case .queued: return "Waiting for a calendar"
        case .needsReview: return "Waiting for you to check it"
        default: return "Not on your calendar"
        }
    }
}

/// Loads the original from your library, since the app only keeps a smaller copy.
struct FullPhotoSheet: View {
    let assetID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 760, height: 820)
        .task(load)
    }

    @Sendable private func load() async {
        guard let assetID else {
            failure = "The original photo couldn't be found."
            return
        }
        do {
            let data = try await PhotoLibrary().imageData(id: assetID)
            if let loaded = NSImage(data: data) {
                image = loaded
            } else {
                failure = "The photo couldn't be opened."
            }
        } catch {
            failure = "The photo couldn't be loaded. It may no longer be in your library."
        }
    }
}

struct SeriesDetail: View {
    @ObservedObject var engine: FlyersEngine
    let flyer: Flyer
    let thumbnail: NSImage?
    let events: [FlyerEvent]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text(flyer.title ?? "Weekly schedule").font(.title2).fontWeight(.semibold)
                Text("These repeat, so they stay here until you choose the ones you want on your calendar.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(events) { event in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.name).fontWeight(.medium)
                            Text(event.recurrence.map(EventFormat.repeats) ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") { engine.addToCalendar(event.id) }
                    }
                    Divider()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            TextField("Name", text: $name)
            DatePicker("Date", selection: $start, displayedComponents: .date)
            Toggle("Has a start time", isOn: $hasTime)
            if hasTime {
                DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                Toggle("Has an end time", isOn: $hasEndTime)
                if hasEndTime {
                    DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                }
            }
            TextField("Location", text: $location)
            TextField("Link", text: $link)
            if let linkError {
                Text(linkError).font(.caption).foregroundStyle(.red)
            }
            TextField("Details", text: $details, axis: .vertical).lineLimit(2...5)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
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
            $0.url = url
            $0.details = details.isEmpty ? nil : details
        }
        dismiss()
    }
}

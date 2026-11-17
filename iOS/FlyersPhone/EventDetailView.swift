import FlyersCore
import SwiftUI
import UIKit

struct EventDetailView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    let eventID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isViewingPhoto = false
    @State private var isEditing = false
    @State private var pendingLink: URL?

    var body: some View {
        if let event = engine.event(id: eventID) {
            content(event)
                // Deleting the event you're looking at closes its page. A deleted event opened
                // from Past stays open, to restore it.
                .onChange(of: event.isHidden) { wasHidden, isHidden in
                    if isHidden && !wasHidden { dismiss() }
                }
        } else {
            ContentUnavailableView("Event deleted", systemImage: "trash")
        }
    }

    private func content(_ event: FlyerEvent) -> some View {
        let flyer = engine.flyer(id: event.flyerID)
        let thumbnail = model.thumbnail(flyer)
        let fromSamePhoto = EventList.fromFlyer(event.flyerID, in: engine.document.events, today: .today)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(event, thumbnail: thumbnail)
                if !event.problems.isEmpty {
                    GlassCard(tint: .orange.opacity(0.25)) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(event.problems, id: \.self) { problem in
                                Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                            }
                        }
                    }
                }
                actions(event)
                facts(event, flyer: flyer)
                if let details = event.details {
                    GlassCard { Text(details).textSelection(.enabled) }
                }
                if fromSamePhoto.count > 1 { samePhoto(fromSamePhoto, current: event) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background { FlyerBackdrop(image: thumbnail) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { moreMenu(event, flyer: flyer) }
        }
        .sheet(isPresented: $isEditing) { PhoneEditEventView(engine: engine, event: event) }
        .fullScreenCover(isPresented: $isViewingPhoto) {
            PhotoPager(sources: model.photoSources(flyer), placeholder: thumbnail) { isViewingPhoto = false }
        }
        // Flyers can link anywhere, so show the whole address before opening it.
        .confirmationDialog(
            "Open this link?",
            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            titleVisibility: .visible,
            presenting: pendingLink
        ) { url in
            Button("Open in Safari") { openURL(url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text(url.absoluteString)
        }
    }

    /// Asks first. Once the event is gone, this page closes itself.
    private func delete(_ ids: [UUID]) {
        model.requestDelete(ids)
    }

    // MARK: Pieces

    private func header(_ event: FlyerEvent, thumbnail: UIImage?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let thumbnail {
                Button { isViewingPhoto = true } label: {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 270)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.2))
                        }
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("View the full photo")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(event.name)
                    .font(.system(.title, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(EventFormat.full(event))
                    .font(.title3)
                    .foregroundStyle(.primary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                // The symbol carries the color, so the words stay readable over any backdrop.
                Label {
                    Text(statusText(event)).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: statusSymbol(event))
                        .foregroundStyle(event.state == .onCalendar ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
                .font(.callout.weight(.medium))
                .padding(.top, 2)
            }
        }
    }

    private func actions(_ event: FlyerEvent) -> some View {
        GlassGroup {
            HStack(spacing: 10) {
                if event.isHidden {
                    Button { engine.restore([event.id]) } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                } else if event.state == .needsReview || event.state == .available {
                    Button { engine.addToCalendar(event.id) } label: {
                        Label("Add to Calendar", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                } else if event.state == .onCalendar {
                    Button { engine.removeFromCalendar(event.id) } label: {
                        Label("Remove from Calendar", systemImage: "calendar.badge.minus").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                } else {
                    Spacer()
                }
                if !event.isHidden {
                    Button { isEditing = true } label: {
                        Text("Edit")
                    }
                    .glassButton()
                    Button(role: .destructive) { delete([event.id]) } label: {
                        Label("Delete", systemImage: "trash").labelStyle(.iconOnly).foregroundStyle(.red)
                    }
                    .glassButton()
                }
            }
            .controlSize(.large)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .sensoryFeedback(.success, trigger: event.state)
        }
    }

    private func moreMenu(_ event: FlyerEvent, flyer: Flyer?) -> some View {
        Menu {
            Button("View Photo", systemImage: "photo") { isViewingPhoto = true }
            if let flyer, flyer.mayBeInLibrary, flyer.assetID != "demo" {
                Button("Remove Photo from Photos", systemImage: "photo.badge.arrow.down") {
                    Task { await engine.removeFromLibrary(flyerID: flyer.id) }
                }
            }
            if event.isHidden {
                Button("Restore", systemImage: "arrow.uturn.backward") { engine.restore([event.id]) }
            } else {
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { delete([event.id]) }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    @ViewBuilder private func facts(_ event: FlyerEvent, flyer: Flyer?) -> some View {
        let links = event.allLinks.compactMap { link in URL(string: link.url).map { (label: link.label, url: $0) } }
        let sponsors = event.sponsors ?? []
        if event.recurrence != nil || event.location != nil || !links.isEmpty || !sponsors.isEmpty || event.datePrinted != nil {
            GlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    if let recurrence = event.recurrence {
                        Fact(symbol: "repeat", label: "Repeats") { Text(EventFormat.repeats(recurrence)) }
                    }
                    if let location = event.location {
                        Fact(symbol: "mappin.and.ellipse", label: event.locationInferred ? "Where (best guess)" : "Where") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(location).textSelection(.enabled)
                                LocationMap(location: location, near: flyer?.coordinate)
                            }
                        }
                    }
                    if !links.isEmpty {
                        Fact(symbol: "link", label: links.count == 1 ? "Link" : "Links") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(links, id: \.url) { link in
                                    let host = link.url.host() ?? link.url.absoluteString
                                    Button(links.count == 1 || link.label == "Link" ? host : "\(link.label) · \(host)") {
                                        pendingLink = link.url
                                    }
                                    .multilineTextAlignment(.leading)
                                }
                            }
                        }
                    }
                    if !sponsors.isEmpty {
                        Fact(symbol: "star", label: sponsors.count == 1 ? "Sponsor" : "Sponsors") {
                            Text(sponsors.joined(separator: ", ")).textSelection(.enabled)
                        }
                    }
                    if let printed = event.datePrinted {
                        Fact(symbol: "text.quote", label: "As printed") { Text(printed).textSelection(.enabled) }
                    }
                }
            }
        }
    }

    /// The other events read from this photo, on a page of their own where you can manage them.
    private func samePhoto(_ events: [FlyerEvent], current: FlyerEvent) -> some View {
        NavigationLink(value: PhoneRoute.photoEvents(flyerID: current.flyerID, from: current.id)) {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "photo.stack").foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(events.count) events from this photo").font(.headline)
                        Text(events.filter { $0.id != current.id }.map(\.name).joined(separator: ", "))
                            .font(.subheadline)
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

    private func statusSymbol(_ event: FlyerEvent) -> String {
        switch event.state {
        case .onCalendar: return "checkmark.circle.fill"
        case .queued: return "clock"
        case .needsReview: return "exclamationmark.circle"
        case .deleted, .removedInCalendar: return "trash"
        default: return "calendar"
        }
    }

    private func statusText(_ event: FlyerEvent) -> String {
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

/// One labeled line in an event's card.
struct Fact<Value: View>: View {
    let symbol: String
    let label: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                value()
            }
            Spacer(minLength: 0)
        }
    }
}

/// A flyer's photos full screen, swiping between them when there are several.
/// Pinch to zoom, drag to move, double-tap to zoom in or back out.
struct PhotoPager: View {
    let sources: [PhoneImageSource]
    /// The small preview, shown at once while the first photo loads.
    let placeholder: UIImage?
    let onClose: () -> Void
    @State private var page = 0
    /// How far a photo has been pulled down to close. The black fades as it goes.
    @State private var dismissDrag: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(dismissDrag / 400, 0.7)).ignoresSafeArea()
            if sources.isEmpty {
                ZoomablePhoto(source: nil, placeholder: placeholder, dismissDrag: $dismissDrag, onClose: onClose)
            } else {
                TabView(selection: $page) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                        ZoomablePhoto(
                            source: source, placeholder: index == 0 ? placeholder : nil,
                            dismissDrag: $dismissDrag, onClose: onClose
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: sources.count > 1 ? .always : .never))
            }
        }
        .presentationBackground(.clear)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Label("Close", systemImage: "xmark").labelStyle(.iconOnly).font(.title3.weight(.semibold))
            }
            .glassButton()
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .padding()
        }
        .statusBarHidden()
    }
}

private struct ZoomablePhoto: View {
    let source: PhoneImageSource?
    let placeholder: UIImage?
    @Binding var dismissDrag: CGFloat
    let onClose: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var baseOffset = CGSize.zero

    var body: some View {
        Group {
            if let shown = image ?? placeholder {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .offset(y: dismissDrag)
                    .gesture(zoom)
                    .simultaneousGesture(scale == 1 ? pullToClose : nil)
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            if scale > 1 { reset() } else { scale = 3; baseScale = 3 }
                        }
                    }
            } else if failed {
                ContentUnavailableView(
                    "No photo", systemImage: "photo",
                    description: Text("The photo couldn't be loaded. It may no longer be in your library.")
                )
                .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard image == nil, let source else { return }
            image = await source.load()
            failed = image == nil
        }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { scale = min(max(baseScale * $0.magnification, 1), 8) }
            .onEnded { _ in
                baseScale = scale
                if scale == 1 { reset() }
            }
            .simultaneously(with: DragGesture(minimumDistance: scale > 1 ? 0 : 10_000)
                .onChanged { value in
                    offset = CGSize(width: baseOffset.width + value.translation.width, height: baseOffset.height + value.translation.height)
                }
                .onEnded { _ in baseOffset = offset })
    }

    /// Pulling an unzoomed photo down closes the viewer, as in Photos. Sideways swipes still turn pages.
    private var pullToClose: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard value.translation.height > 0, value.translation.height > abs(value.translation.width) else { return }
                dismissDrag = value.translation.height
            }
            .onEnded { value in
                if dismissDrag > 120 || value.predictedEndTranslation.height > 400 && dismissDrag > 0 {
                    onClose()
                } else {
                    withAnimation(.snappy) { dismissDrag = 0 }
                }
            }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}

/// Changes an event here and in Calendar. Your edit counts as checking it.
struct PhoneEditEventView: View {
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
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Location", text: $location)
                }
                Section {
                    DatePicker("Date", selection: $start, displayedComponents: .date)
                    Toggle("Has a start time", isOn: $hasTime.animation())
                    if hasTime {
                        DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                        Toggle("Has an end time", isOn: $hasEndTime.animation())
                        if hasEndTime {
                            DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                        }
                    }
                }
                Section {
                    TextField("Main link", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let linkError {
                        Text(linkError).font(.caption).foregroundStyle(.red)
                    }
                    TextField("Details", text: $details, axis: .vertical).lineLimit(3...8)
                }
            }
            .navigationTitle("Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).fontWeight(.semibold) }
            }
            .onAppear(perform: load)
        }
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

/// Every event read from one photo, under the photo itself. Swipe one to delete it.
struct PhotoEventsView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    let flyerID: UUID
    /// The event you came from.
    let currentID: UUID
    @State private var isViewingPhoto = false

    var body: some View {
        let events = EventList.fromFlyer(flyerID, in: engine.document.events, today: .today)
        let flyer = engine.flyer(id: flyerID)
        let thumbnail = model.thumbnail(flyer)
        List {
            if let thumbnail {
                Button { isViewingPhoto = true } label: {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 270)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.2))
                        }
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View the full photo")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(events) { event in
                    NavigationLink(value: PhoneRoute.event(event.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.name).fontWeight(event.id == currentID ? .semibold : .regular)
                            Text(event.recurrence.map(EventFormat.repeats) ?? EventFormat.summary(event, day: nil))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete", systemImage: "trash", role: .destructive) { model.requestDelete([event.id]) }
                    }
                }
            } footer: {
                if !events.isEmpty {
                    Text("Swipe an event to delete it. Deleted events wait under Past, where you can restore them.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { FlyerBackdrop(image: thumbnail) }
        .navigationTitle("From This Photo")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if events.isEmpty {
                ContentUnavailableView("No events left", systemImage: "photo", description: Text("Every event from this photo was deleted."))
            }
        }
        .fullScreenCover(isPresented: $isViewingPhoto) {
            PhotoPager(sources: model.photoSources(flyer), placeholder: thumbnail) { isViewingPhoto = false }
        }
    }
}

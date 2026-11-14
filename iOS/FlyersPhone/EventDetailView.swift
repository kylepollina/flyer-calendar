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
    @State private var isConfirmingDeleteAll = false
    @State private var pendingLink: URL?

    var body: some View {
        if let event = engine.event(id: eventID), !event.isHidden {
            content(event)
        } else {
            ContentUnavailableView("Event deleted", systemImage: "trash")
        }
    }

    private func content(_ event: FlyerEvent) -> some View {
        let flyer = engine.flyer(id: event.flyerID)
        let fromSamePhoto = EventList.fromFlyer(event.flyerID, in: engine.document.events, today: .today)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(event, flyer: flyer)
                if !event.problems.isEmpty {
                    Card {
                        ForEach(event.problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                        }
                    }
                }
                actions(event)
                facts(event, flyer: flyer)
                if let details = event.details {
                    Card { Text(details).textSelection(.enabled) }
                }
                if fromSamePhoto.count > 1 { samePhoto(fromSamePhoto, current: event) }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isViewingPhoto) {
            PhotoScreen(image: model.photo(flyer)) { isViewingPhoto = false }
        }
        // Flyers can link anywhere, so show the whole address before opening it.
        .confirmationDialog(
            "Open this link?",
            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            titleVisibility: .visible,
            presenting: pendingLink
        ) { url in
            Button("Open in browser") { openURL(url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text(url.absoluteString)
        }
        .confirmationDialog(
            "Delete all \(fromSamePhoto.count) events from this photo?",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete \(fromSamePhoto.count) Events", role: .destructive) {
                engine.delete(fromSamePhoto.map(\.id))
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They also come off your calendar. You can undo this right after.")
        }
    }

    private func header(_ event: FlyerEvent, flyer: Flyer?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if let thumbnail = model.thumbnail(flyer) {
                Button { isViewingPhoto = true } label: {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 120, maxHeight: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View the full photo")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(event.name).font(.title2.bold()).textSelection(.enabled)
                Text(EventFormat.full(event)).foregroundStyle(.secondary)
                Label(statusText(event), systemImage: event.state == .onCalendar ? "checkmark.circle.fill" : "calendar")
                    .font(.callout)
                    .foregroundStyle(event.state == .onCalendar ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .padding(.top, 2)
            }
        }
    }

    private func actions(_ event: FlyerEvent) -> some View {
        HStack(spacing: 10) {
            if event.state == .needsReview || event.state == .available {
                Button { engine.addToCalendar(event.id) } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
            if event.state == .onCalendar {
                Button { engine.removeFromCalendar(event.id) } label: {
                    Label("Remove from Calendar", systemImage: "calendar.badge.minus")
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                engine.delete([event.id])
                dismiss()
            } label: {
                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private func facts(_ event: FlyerEvent, flyer: Flyer?) -> some View {
        let links = event.allLinks.compactMap { link in URL(string: link.url).map { (label: link.label, url: $0) } }
        let sponsors = event.sponsors ?? []
        if event.recurrence != nil || event.location != nil || !links.isEmpty || !sponsors.isEmpty || event.datePrinted != nil {
            Card {
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

    /// The other events read from this photo, so a flyer that added too much is quick to clear out.
    private func samePhoto(_ events: [FlyerEvent], current: FlyerEvent) -> some View {
        Card {
            HStack {
                Text("\(events.count) events from this photo").font(.headline)
                Spacer()
                Button("Delete All…", role: .destructive) { isConfirmingDeleteAll = true }
            }
            ForEach(events) { other in
                NavigationLink(value: other.id) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(other.name).fontWeight(other.id == current.id ? .semibold : .regular)
                            Text(other.recurrence.map(EventFormat.repeats) ?? EventFormat.summary(other, day: nil))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if other.id == current.id {
                            Text("This event").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .disabled(other.id == current.id)
            }
        }
    }

    private func statusText(_ event: FlyerEvent) -> String {
        switch event.state {
        case .onCalendar: return "On your calendar"
        case .queued: return "Waiting for a calendar"
        case .needsReview: return "Waiting for you to check it"
        default: return "Not on your calendar"
        }
    }
}

/// A rounded panel for one group of details.
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

/// The flyer's photo, full screen. Pinch to zoom, drag to move, double-tap to reset.
struct PhotoScreen: View {
    let image: UIImage?
    let onClose: () -> Void
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var baseOffset = CGSize.zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().onTapGesture(perform: onClose)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { scale = min(max(baseScale * $0.magnification, 1), 8) }
                            .onEnded { _ in
                                baseScale = scale
                                if scale == 1 { reset() }
                            }
                            .simultaneously(with: DragGesture()
                                .onChanged { value in
                                    guard scale > 1 else { return }
                                    offset = CGSize(
                                        width: baseOffset.width + value.translation.width,
                                        height: baseOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in baseOffset = offset })
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            if scale > 1 { reset() } else { scale = 3; baseScale = 3 }
                        }
                    }
            } else {
                ContentUnavailableView("No photo", systemImage: "photo").foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.hierarchical).foregroundStyle(.white)
            }
            .accessibilityLabel("Close")
            .padding()
        }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}

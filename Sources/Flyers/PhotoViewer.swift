import AppKit
import FlyersCore
import SwiftUI

/// Where a flyer's photo lives: the copy saved in Flyers, or, for older flyers, your Photos library.
enum PhotoRef: Hashable, Sendable {
    case file(URL)
    case library(String)

    /// Saved copies first, since they open instantly and survive the photo leaving your library.
    static func all(for flyer: Flyer, store: DocumentStore) -> [PhotoRef] {
        flyer.allAssetIDs.enumerated().map { index, assetID in
            if let files = flyer.photoFiles, files.indices.contains(index) {
                return .file(store.photoURL(files[index]))
            }
            return .library(assetID)
        }
    }

    fileprivate func data() async -> Data? {
        switch self {
        case .file(let url):
            return await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        case .library(let id):
            return try? await PhotoLibrary().imageData(id: id)
        }
    }
}

/// Keeps a few full-size photos in memory. Loading an original from Photos, sometimes from iCloud,
/// takes seconds, so an event's photo starts loading as soon as the event is shown.
@MainActor
final class PhotoCache {
    static let shared = PhotoCache()
    private let limit = 12
    private var images: [PhotoRef: NSImage] = [:]
    private var order: [PhotoRef] = []
    private var loading: [PhotoRef: Task<NSImage?, Never>] = [:]

    func cached(_ id: PhotoRef) -> NSImage? { images[id] }

    /// Starts loading without waiting for it.
    func prefetch(_ ids: [PhotoRef]) {
        for id in ids where images[id] == nil && loading[id] == nil {
            Task { _ = await load(id) }
        }
    }

    func load(_ id: PhotoRef) async -> NSImage? {
        if let image = images[id] { return image }
        if let task = loading[id] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let data = await id.data() else { return nil }
            // Decoded off the main thread, at a size that still holds detail when zoomed in.
            let decoded = await Task.detached(priority: .userInitiated) { ImageTools.decode(data, maxEdge: 3200) }.value
            return decoded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
        loading[id] = task
        let image = await task.value
        loading[id] = nil
        if let image {
            images[id] = image
            order.removeAll { $0 == id }
            order.append(id)
            if order.count > limit { images[order.removeFirst()] = nil }
        }
        return image
    }
}

struct PhotoViewerItem: Identifiable {
    let id = UUID()
    let assetIDs: [PhotoRef]
    /// The app's small copy of the first photo, shown while the original loads.
    let thumbnail: NSImage?
}

/// The flyer's photos over the window. Click outside the photo or press Esc to close,
/// pinch, double-click or use ⌘+ and ⌘− to zoom, and arrow keys to page through a group.
struct PhotoViewer: View {
    let item: PhotoViewerItem
    let onClose: () -> Void
    @State private var index = 0
    @State private var loaded: [PhotoRef: NSImage] = [:]
    @State private var failed: Set<PhotoRef> = []
    @StateObject private var zoom = ZoomController()

    private var assetID: PhotoRef? { item.assetIDs.indices.contains(index) ? item.assetIDs[index] : nil }

    private var image: NSImage? {
        guard let assetID else { return item.thumbnail }
        return loaded[assetID] ?? PhotoCache.shared.cached(assetID) ?? (index == 0 ? item.thumbnail : nil)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityLabel("Close photo")
                    .accessibilityAddTraits(.isButton)

                if let image {
                    let size = fitted(image.size, in: geometry.size)
                    ZoomableImage(image: image, controller: zoom)
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
                        .id(index)
                } else if let assetID, failed.contains(assetID) {
                    ContentUnavailableView(
                        "No photo", systemImage: "photo",
                        description: Text("The photo couldn't be loaded. It may no longer be in your library.")
                    )
                    .foregroundStyle(.white)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .overlay(alignment: .bottom) { controls.padding(20) }
        }
        .background { shortcuts }
        .task(id: index) { await loadCurrent() }
        .onChange(of: index) { zoom.reset() }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if item.assetIDs.count > 1 {
                Button { index -= 1 } label: { Label("Previous photo", systemImage: "chevron.left") }
                    .disabled(index == 0)
                Text("\(index + 1) of \(item.assetIDs.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button { index += 1 } label: { Label("Next photo", systemImage: "chevron.right") }
                    .disabled(index >= item.assetIDs.count - 1)
                Divider().frame(height: 16)
            }
            Button { zoom.zoom(by: 1 / 1.5) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
                .help("Zoom out (⌘−)")
            Button { zoom.zoom(by: 1.5) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                .help("Zoom in (⌘+)")
            Divider().frame(height: 16)
            Button(action: onClose) { Label("Close", systemImage: "xmark") }
                .help("Close (Esc)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassSurface(in: Capsule())
    }

    /// Keyboard shortcuts need a button to live on.
    private var shortcuts: some View {
        Group {
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            Button("Previous") { if index > 0 { index -= 1 } }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next") { if index < item.assetIDs.count - 1 { index += 1 } }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Zoom in") { zoom.zoom(by: 1.5) }.keyboardShortcut("=")
            Button("Zoom out") { zoom.zoom(by: 1 / 1.5) }.keyboardShortcut("-")
            Button("Actual size") { zoom.reset() }.keyboardShortcut("0")
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func loadCurrent() async {
        guard let assetID else { return }
        // The next photo in a group starts loading too, so paging is instant.
        if index + 1 < item.assetIDs.count { PhotoCache.shared.prefetch([item.assetIDs[index + 1]]) }
        if loaded[assetID] != nil { return }
        if let image = await PhotoCache.shared.load(assetID) {
            loaded[assetID] = image
        } else {
            failed.insert(assetID)
        }
    }

    /// The photo's size scaled to fit the window, leaving a margin to click outside it.
    private func fitted(_ size: NSSize, in bounds: CGSize) -> CGSize {
        let available = CGSize(width: max(bounds.width - 80, 100), height: max(bounds.height - 140, 100))
        guard size.width > 0, size.height > 0 else { return available }
        let scale = min(available.width / size.width, available.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Lets SwiftUI buttons drive the scroll view's zoom.
@MainActor
final class ZoomController: ObservableObject {
    weak var scrollView: NSScrollView?

    func zoom(by factor: CGFloat) {
        guard let scrollView else { return }
        let target = min(max(scrollView.magnification * factor, scrollView.minMagnification), scrollView.maxMagnification)
        let center = scrollView.contentView.bounds.center
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            scrollView.animator().setMagnification(target, centeredAt: center)
        }
    }

    func reset() {
        guard let scrollView else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            scrollView.animator().magnification = 1
        }
    }
}

/// An image you can pinch to zoom and drag around, using AppKit's own scroll view zoom.
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    let controller: ZoomController

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 8
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        scrollView.documentView = imageView

        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleClick.numberOfClicksRequired = 2
        scrollView.addGestureRecognizer(doubleClick)
        context.coordinator.scrollView = scrollView
        controller.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // The small copy is swapped for the original once it loads, keeping the zoom.
        if let imageView = scrollView.documentView as? NSImageView, imageView.image !== image {
            imageView.image = image
        }
        if scrollView.magnification == 1, let documentView = scrollView.documentView {
            documentView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        }
        controller.scrollView = scrollView
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?

        @MainActor @objc func toggleZoom(_ recognizer: NSClickGestureRecognizer) {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let point = recognizer.location(in: documentView)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                if scrollView.magnification > 1.01 {
                    scrollView.animator().magnification = 1
                } else {
                    scrollView.animator().setMagnification(3, centeredAt: point)
                }
            }
        }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

import SwiftUI

// Shared by the Mac and iPhone apps. Liquid Glass needs macOS 26 or iOS 26, and the apps still run
// on macOS 15 and iOS 18, where these fall back to materials and the standard button styles.

#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage

extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}

extension Color {
    /// The plain background behind the app's pages.
    static var appBackground: Color { Color(nsColor: .windowBackgroundColor) }
}
#else
import UIKit
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}

extension Color {
    /// The plain background behind the app's pages.
    static var appBackground: Color { Color(uiColor: .systemBackground) }
}
#endif

extension View {
    /// A glass surface behind this view.
    @ViewBuilder func glassSurface<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Lets neighboring glass shapes blend into each other.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

/// A rounded glass card for a group of related content.
struct GlassCard<Content: View>: View {
    var tint: Color?
    var padding: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: tint)
    }
}

/// The flyer's own colors, blurred behind the detail pane, so each event has its own look
/// and the glass on top has something to refract.
struct FlyerBackdrop: View {
    let image: PlatformImage?

    var body: some View {
        ZStack {
            Color.appBackground
            if let image {
                Color.clear
                    .overlay {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 70)
                            .saturation(1.5)
                            .opacity(0.6)
                    }
                    .clipped()
                LinearGradient(
                    colors: [.clear, Color.appBackground.opacity(0.75)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A soft wash of color behind first-run setup.
struct SetupBackdrop: View {
    var body: some View {
        ZStack {
            Color.appBackground
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.6, 0.4], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    .orange, .pink, .purple,
                    .pink, .purple, .blue,
                    .purple, .blue, .teal,
                ]
            )
            .opacity(0.25)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

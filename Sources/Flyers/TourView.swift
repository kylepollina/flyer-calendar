import AppKit
import SwiftUI

/// The welcome tour: four short pages on what Flyers does and how to steer it.
/// Opens by itself once setup is done, until it has been closed once, and again from
/// Settings or Help ▸ Welcome Tour.
struct TourView: View {
    /// `UserDefaults` key set when the tour is closed, so quitting midway shows it again next launch.
    static let seenKey = "tourSeen"
    static let size = CGSize(width: 560, height: 480)

    var onDone: () -> Void

    @State private var page = 0
    @State private var movingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pageCount = 4
    private var isLast: Bool { page == pageCount - 1 }

    var body: some View {
        VStack(spacing: 0) {
            pageContent
                .id(page)
                .transition(pageTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // A wash of color, so the glass panels have something to show through them.
        .background { SetupBackdrop() }
        .background(arrowKeys)
    }

    // MARK: - Pages

    @ViewBuilder private var pageContent: some View {
        switch page {
        case 0: welcomePage
        case 1: howPage
        case 2: reviewPage
        default: shortcutsPage
        }
    }

    private var welcomePage: some View {
        PageLayout(title: "Welcome to Flyers",
                   subtitle: "Take a photo of a flyer, and the event lands on your calendar. That's the whole idea.") {
            HStack(spacing: 18) {
                MiniFlyer(title: "Jazz in the Park", lines: ["Sat · Nov 14", "7:30 PM"], colors: [.indigo, .teal])
                    .rotationEffect(.degrees(-6))
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .glassSurface(in: Circle())
                MiniEvent(title: "Jazz in the Park", when: "Sat, Nov 14 · 7:30 PM", place: "Volunteer Park", color: .indigo)
            }
            .frame(height: 230)
            .accessibilityHidden(true)
        }
    }

    private var howPage: some View {
        PageLayout(title: "It works in the background",
                   subtitle: "Flyers keeps checking your photo library from the menu bar, even with this window closed.") {
            HStack(spacing: 10) {
                StepIcon(symbol: "iphone")
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                StepIcon(symbol: "macbook")
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                StepIcon(symbol: "calendar")
            }
            .font(.system(size: 13, weight: .bold))
            .padding(.vertical, 6)
            .accessibilityHidden(true)
        } details: {
            FeatureRow(symbol: "camera", title: "Photograph a flyer on your iPhone or Mac")
            FeatureRow(symbol: "lock", title: "New photos are checked on this Mac first")
            FeatureRow(symbol: "text.viewfinder", title: "Likely flyers are read by the Anthropic API")
            FeatureRow(symbol: "calendar.badge.plus", title: "Their events go on your calendar")
        }
    }

    private var reviewPage: some View {
        PageLayout(title: "You stay in charge",
                   subtitle: "When a flyer is unclear, Flyers asks instead of guessing.") {
            MiniReview()
                .padding(.bottom, 4)
                .accessibilityHidden(true)
        } details: {
            FeatureRow(symbol: "exclamationmark.circle", title: "Unclear events wait in Needs review", keys: ["⌘2"])
            FeatureRow(symbol: "repeat", title: "Weekly schedules let you pick what to add")
            FeatureRow(symbol: "pencil", title: "Fix anything the flyer got wrong", keys: ["⌘E"])
        }
    }

    private var shortcutsPage: some View {
        PageLayout(title: "A few shortcuts",
                   subtitle: "Everything is also a button, so there's nothing to memorize.") {
            EmptyView()
        } details: {
            FeatureRow(symbol: "arrow.clockwise", title: "Scan for new photos now", keys: ["⌘R"])
            FeatureRow(symbol: "list.bullet", title: "Upcoming, Needs review, Past", keys: ["⌘1–3"])
            FeatureRow(symbol: "pencil", title: "Edit an event", keys: ["⌘E"])
            FeatureRow(symbol: "trash", title: "Delete an event, with Undo", keys: ["⌫"])
            FeatureRow(symbol: "menubar.rectangle", title: "Next events, from the menu bar")
            FeatureRow(symbol: "gearshape", title: "Settings, and this tour", keys: ["⌘,"])
        }
    }

    // MARK: - Footer

    /// The buttons hold their positions from page to page, so Next never moves under the pointer.
    private var footer: some View {
        ZStack {
            PageDots(count: pageCount, current: page)
            HStack(spacing: 8) {
                if !isLast {
                    Button("Skip", action: onDone)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Close the tour")
                }
                Spacer()
                if page > 0 {
                    Button("Back") { go(to: page - 1) }
                        .glassButton()
                        .controlSize(.large)
                }
                Button(isLast ? "Get Started" : page == 0 ? "Take the Tour" : "Next") {
                    if isLast { onDone() } else { go(to: page + 1) }
                }
                .glassButton(prominent: true)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
        .padding(.top, 8)
    }

    /// ← and → flip pages, and Esc closes the tour from any page.
    private var arrowKeys: some View {
        Group {
            Button("", action: onDone)
                .keyboardShortcut(.cancelAction)
            Button("") { if page > 0 { go(to: page - 1) } }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { if !isLast { go(to: page + 1) } }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func go(to index: Int) {
        movingForward = index > page
        if reduceMotion {
            page = index
        } else {
            withAnimation(.smooth(duration: 0.28)) { page = index }
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let insertion: Edge = movingForward ? .trailing : .leading
        let removal: Edge = movingForward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: insertion).combined(with: .opacity),
                           removal: .move(edge: removal).combined(with: .opacity))
    }
}

// MARK: - Layout

/// Title and subtitle on top, then the picture, then a glass panel of feature rows.
private struct PageLayout<Hero: View, Details: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var details: () -> Details

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            hero()
            if Details.self != EmptyView.self {
                VStack(spacing: 0) { details() }
                    .padding(.vertical, 6)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 32)
            }
        }
        .padding(.top, 36)
    }
}

private extension PageLayout where Details == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder hero: @escaping () -> Hero) {
        self.init(title: title, subtitle: subtitle, hero: hero, details: { EmptyView() })
    }
}

/// One feature: its icon, what it does, and its shortcut if it has one.
private struct FeatureRow: View {
    let symbol: String
    let title: String
    var keys: [String] = []

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { KeyCap(text: $0) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? Color.primary.opacity(0.75) : Color.primary.opacity(0.18))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

// MARK: - Illustrations

/// A small printed flyer.
private struct MiniFlyer: View {
    let title: String
    let lines: [String]
    let colors: [Color]
    var width: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: 34, height: 34)
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 19, weight: .black))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(size: 11, weight: .semibold)).opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: width, height: width * 1.36, alignment: .leading)
        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 7)
    }
}

/// An event as Calendar shows it, with a colored bar down its side.
private struct MiniEvent: View {
    let title: String
    let when: String
    let place: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(when).font(.system(size: 12)).foregroundStyle(.secondary)
                Label(place, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 210, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous), tint: color.opacity(0.18))
    }
}

/// A glass circle holding one step's symbol.
private struct StepIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .regular))
            .frame(width: 58, height: 58)
            .glassSurface(in: Circle())
    }
}

/// An event waiting in Needs review, with the note that explains why.
private struct MiniReview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [.green, .mint], startPoint: .top, endPoint: .bottom))
                    .frame(width: 30, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Run club").font(.system(size: 13, weight: .semibold))
                    Text("Every 2 weeks on Sunday").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            Label("The flyer doesn't say which date comes first", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 300)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

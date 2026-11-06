import AppKit
import FlyersCore
import SwiftUI

/// The API key field. Used in first-run setup and in Settings. It never shows a saved key.
struct APIKeyField: View {
    @ObservedObject var model: AppModel
    @State private var key = ""
    @State private var error: String?
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("API key", text: $key, prompt: Text(model.hasAPIKey ? "Enter a new key to replace it" : "sk-ant-…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    isChecking = true
                    Task {
                        error = await model.saveAPIKey(key)
                        if error == nil { key = "" }
                        isChecking = false
                    }
                }
                .disabled(isChecking)
                if isChecking { ProgressView().controlSize(.small) }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

struct CalendarPicker: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: FlyersEngine
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Add events to", selection: Binding(
                get: { engine.document.settings.calendarID },
                set: { model.chooseCalendar($0) }
            )) {
                Text("Choose a calendar").tag(String?.none)
                ForEach(model.calendarService.writableCalendars()) { choice in
                    Text(choice.title).tag(String?.some(choice.id))
                }
            }
            Button("Create a Flyers calendar") {
                do {
                    try model.createCalendar()
                    error = nil
                } catch {
                    self.error = "Couldn't create it: \(error)"
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: FlyersEngine

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 84, height: 84)
                        .accessibilityHidden(true)
                    Text("Welcome to Flyers").font(.system(.largeTitle, weight: .bold))
                    Text("Take a photo of a flyer, and the event lands on your calendar.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                GlassGroup(spacing: 10) {
                    VStack(spacing: 10) {
                        SetupStep(symbol: "key.fill", title: "Anthropic API key", done: model.hasAPIKey) {
                            Text("Reads your flyers. It's stored in your Keychain.")
                                .foregroundStyle(.primary.opacity(0.75))
                            APIKeyField(model: model)
                            Link("Create a key in the Anthropic Console", destination: URL(string: "https://console.anthropic.com/")!)
                                .font(.callout)
                        }
                        SetupStep(symbol: "photo.fill", title: "Photos", done: model.hasPhotoAccess) {
                            Text("Only photos taken from today onward are checked. You can change this in Settings.")
                                .foregroundStyle(.primary.opacity(0.75))
                            Button("Allow access to Photos") { Task { await model.requestPhotoAccess() } }
                                .glassButton(prominent: true)
                        }
                        SetupStep(symbol: "calendar", title: "Calendar", done: model.hasCalendarAccess && engine.document.settings.calendarID != nil) {
                            if model.hasCalendarAccess {
                                CalendarPicker(model: model, engine: engine)
                            } else {
                                Text("Lets Flyers add events and notice when you change them.")
                                    .foregroundStyle(.primary.opacity(0.75))
                                Button("Allow access to Calendar") { Task { await model.requestCalendarAccess() } }
                                    .glassButton(prominent: true)
                            }
                        }
                        SetupStep(symbol: "menubar.arrow.up.rectangle", title: "Run in the background", done: model.launchesAtLogin) {
                            Text("Starts Flyers when you log in, so it keeps checking from the menu bar.")
                                .foregroundStyle(.primary.opacity(0.75))
                            Button("Start at login") { model.setLaunchAtLogin(true) }
                                .glassButton()
                            if let error = model.launchAtLoginError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                Label(
                    "Photos are checked on this Mac first. Only ones that seem to show an event go to the Anthropic API.",
                    systemImage: "lock.fill"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background { SetupBackdrop() }
    }
}

/// A card for one setup step. A finished step shrinks to its title, which leaves the next one in focus.
private struct SetupStep<Content: View>: View {
    let symbol: String
    let title: String
    let done: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(title).font(.headline)
                        Spacer()
                        if done {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Done")
                        }
                    }
                    if !done { content() }
                }
            }
        }
        .animation(.snappy, value: done)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: FlyersEngine
    @State private var pageWidth: CGFloat = 0

    private var settings: AppSettings { engine.document.settings }

    private func binding<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { engine.document.settings[keyPath: path] },
            set: { value in engine.updateSettings { $0[keyPath: path] = value } }
        )
    }

    var body: some View {
        Form {
            Section("API key") {
                LabeledContent("Status", value: model.hasAPIKey ? "Saved in your Keychain" : "Not set")
                APIKeyField(model: model)
                if model.hasAPIKey {
                    Button("Remove key", role: .destructive) { model.removeAPIKey() }
                }
            }
            Section("Calendar") {
                if model.hasCalendarAccess {
                    CalendarPicker(model: model, engine: engine)
                } else {
                    Button("Allow access to Calendar") { Task { await model.requestCalendarAccess() } }
                }
                Picker("New events", selection: binding(\.addMode)) {
                    Text("Add automatically").tag(AddMode.automatic)
                    Text("Wait for my review").tag(AddMode.review)
                }
                Picker("Alert", selection: binding(\.alertMinutesBefore)) {
                    Text("None").tag(0)
                    Text("1 hour before").tag(60)
                    Text("3 hours before").tag(180)
                    Text("1 day before").tag(1440)
                    Text("2 days before").tag(2880)
                }
            }
            Section {
                Picker("Check for new photos", selection: Binding(
                    get: { settings.scanIntervalMinutes },
                    set: { value in
                        engine.updateSettings { $0.scanIntervalMinutes = value }
                        model.scheduleScans()
                    }
                )) {
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                    Text("Every 3 hours").tag(180)
                    Text("Every 6 hours").tag(360)
                    Text("Once a day").tag(1440)
                }
                DatePicker("Check photos taken since", selection: binding(\.scanStartDate), displayedComponents: .date)
                Toggle("Include screenshots", isOn: binding(\.includeScreenshots))
                if !model.hasPhotoAccess {
                    Button("Allow access to Photos") { Task { await model.requestPhotoAccess() } }
                }
            } header: {
                Text("Scanning")
            } footer: {
                if settings.includeScreenshots {
                    Text("Screenshots that mention dates are sent to the Anthropic API, and they can include private things like messages.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section {
                LabeledContent("This month", value: engine.spendThisMonth.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
                Picker("Monthly limit", selection: binding(\.monthlySpendLimit)) {
                    Text("$0.50").tag(0.5)
                    Text("$1").tag(1.0)
                    Text("$5").tag(5.0)
                    Text("$20").tag(20.0)
                }
            } header: {
                Text("Spending")
            } footer: {
                Text("Scanning pauses when the limit is reached. This is the app's own estimate, so check the Anthropic Console for exact billing.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("General") {
                Toggle("Start at login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Help") {
                LabeledContent("Welcome tour") {
                    Button("Show Tour…") { model.isShowingTour = true }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Margins rather than a narrower frame, so the scroll view still reaches the window's
        // edges and the toolbar's blur runs all the way across.
        .contentMargins(.horizontal, max(0, (pageWidth - 640) / 2), for: .scrollContent)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { pageWidth = $0 }
        .background { SetupBackdrop() }
        .navigationTitle("Settings")
        .onAppear { model.refreshAccess() }
    }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: FlyersEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let next = EventList.next(engine.document.events, today: .today, limit: 5)
        let reviewCount = EventList.needingReview(engine.document.events).count
        VStack(alignment: .leading, spacing: 12) {
            if next.isEmpty {
                Text("Nothing coming up")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(next, id: \.event.id) { item in
                        Button { open(item.event.id) } label: {
                            MenuBarRow(event: item.event, day: item.day)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if reviewCount > 0 {
                Button { openReview() } label: {
                    Label(reviewCount == 1 ? "1 event to check" : "\(reviewCount) events to check", systemImage: "exclamationmark.circle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                }
                .buttonStyle(.plain)
            }
            if let message = engine.alertMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            Group {
                if let progress = engine.scanProgress {
                    Text(progress)
                } else if engine.isPaused {
                    Text("Scanning is paused")
                } else if let date = engine.document.lastScanAt {
                    Text("Last scan \(date.formatted(.relative(presentation: .named)))")
                } else {
                    Text("No scans yet")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            GlassGroup {
                HStack(spacing: 6) {
                    Button("Open Flyers") { openMainWindow() }
                        .glassButton(prominent: true)
                    if engine.isScanning {
                        Button("Stop") { engine.stopScan() }
                            .glassButton()
                            .disabled(engine.isStopping)
                    } else {
                        Button(engine.isPaused ? "Resume" : "Scan now") { Task { await engine.scan() } }
                            .glassButton()
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.isShowingSettings = true
                        openMainWindow()
                    } label: {
                        Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
                    }
                    .glassButton()
                    .help("Settings")
                    Button { NSApp.terminate(nil) } label: {
                        Label("Quit Flyers", systemImage: "power").labelStyle(.iconOnly)
                    }
                    .glassButton()
                    .help("Quit Flyers")
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func openMainWindow() {
        openWindow(id: AppModel.mainWindowID)
        NSApp.activate()
    }

    private func open(_ id: UUID) {
        model.eventToReveal = id
        openMainWindow()
    }

    private func openReview() {
        if let first = EventList.needingReview(engine.document.events).first { open(first.id) }
    }
}

/// An upcoming event with a small calendar page showing its date.
private struct MenuBarRow: View {
    let event: FlyerEvent
    let day: Day

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                Text(Self.monthFormatter.string(from: day.date()).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.red)
                Text(Self.dayFormatter.string(from: day.date()))
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 36, height: 38)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.name).fontWeight(.medium).lineLimit(1)
                Text(EventFormat.summary(event, day: day))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

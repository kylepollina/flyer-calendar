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
                SecureField(model.hasAPIKey ? "Enter a new key to replace it" : "sk-ant-…", text: $key)
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
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up Flyers").font(.title).fontWeight(.semibold)
                    Text("Flyers checks your new photos on this Mac. Photos that look like they might show an event go to the Anthropic API to be read, and the events go on your calendar.")
                        .foregroundStyle(.secondary)
                }
                SetupStep(title: "Anthropic API key", done: model.hasAPIKey) {
                    Text("It's stored in your Keychain. Create one in the Anthropic Console.")
                        .font(.callout).foregroundStyle(.secondary)
                    if !model.hasAPIKey { APIKeyField(model: model) }
                }
                SetupStep(title: "Photos", done: model.hasPhotoAccess) {
                    Text("Only photos taken from today onward are checked. You can change this in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                    if !model.hasPhotoAccess {
                        Button("Allow access to Photos") { Task { await model.requestPhotoAccess() } }
                    }
                }
                SetupStep(title: "Calendar", done: model.hasCalendarAccess && engine.document.settings.calendarID != nil) {
                    if model.hasCalendarAccess {
                        CalendarPicker(model: model, engine: engine)
                    } else {
                        Text("Lets Flyers add events and notice when you change them.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Allow access to Calendar") { Task { await model.requestCalendarAccess() } }
                    }
                }
                SetupStep(title: "Run in the background", done: model.launchesAtLogin) {
                    Text("Starts Flyers when you log in, so it keeps checking from the menu bar.")
                        .font(.callout).foregroundStyle(.secondary)
                    if !model.launchesAtLogin {
                        Button("Start at login") { model.setLaunchAtLogin(true) }
                    }
                    if let error = model.launchAtLoginError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct SetupStep<Content: View>: View {
    let title: String
    let done: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: FlyersEngine

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
            Section("Scanning") {
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
                if settings.includeScreenshots {
                    Text("Screenshots that mention dates are sent to the Anthropic API, and they can include private things like messages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.hasPhotoAccess {
                    Button("Allow access to Photos") { Task { await model.requestPhotoAccess() } }
                }
            }
            Section("Spending") {
                LabeledContent("This month", value: engine.spendThisMonth.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
                Picker("Monthly limit", selection: binding(\.monthlySpendLimit)) {
                    Text("$0.50").tag(0.5)
                    Text("$1").tag(1.0)
                    Text("$5").tag(5.0)
                    Text("$20").tag(20.0)
                }
                Text("Scanning pauses when the limit is reached. This is the app's own estimate, so check the Anthropic Console for exact billing.")
                    .font(.caption).foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
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
        VStack(alignment: .leading, spacing: 10) {
            if next.isEmpty {
                Text("Nothing coming up").foregroundStyle(.secondary)
            } else {
                ForEach(next, id: \.event.id) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.event.name).fontWeight(.medium).lineLimit(1)
                        Text(EventFormat.summary(item.event, day: item.day)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            if reviewCount > 0 {
                Label(reviewCount == 1 ? "1 event to check" : "\(reviewCount) events to check", systemImage: "exclamationmark.circle")
                    .font(.callout)
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
            HStack {
                if engine.isScanning {
                    Button("Stop") { engine.stopScan() }.disabled(engine.isStopping)
                } else {
                    Button(engine.isPaused ? "Resume" : "Scan now") { Task { await engine.scan() } }
                }
                Button("Open Flyers") {
                    openWindow(id: AppModel.mainWindowID)
                    NSApp.activate()
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Flyers")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }
}

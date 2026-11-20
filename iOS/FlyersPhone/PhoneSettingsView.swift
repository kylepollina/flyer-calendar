import FlyersCore
import SwiftUI

struct PhoneSettingsView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    /// Slides the page back out. Settings is a page that slides in from the left, not a sheet.
    var onClose: () -> Void = {}
    @State private var isMovingPhotos = false
    @State private var isConfirmingClear = false

    private func binding<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { engine.document.settings[keyPath: path] }, set: { value in engine.updateSettings { $0[keyPath: path] = value } })
    }

    /// A short list of categories, each with its current value, opening a page of its own, like
    /// iOS Settings. Setup comes back as a row at the top only while something still needs doing.
    var body: some View {
        NavigationStack {
            Form {
                if !model.isSetUp {
                    Section {
                        Button {
                            onClose()
                            model.isShowingSetup = true
                        } label: {
                            Label("Finish Setting Up", systemImage: "exclamationmark.circle.fill")
                                .symbolRenderingMode(.multicolor)
                                .fontWeight(.semibold)
                        }
                    } footer: {
                        Text("Flyers needs a little more before it can put events on your calendar.")
                    }
                }
                Section {
                    page("Calendar", symbol: "calendar", color: .red, value: calendarName) { calendarSection }
                    page("Scanning", symbol: "viewfinder", color: .blue, value: model.scansHere ? "On" : "Off") { scanningSection }
                    page("Reading Flyers", symbol: "text.viewfinder", color: .purple, value: model.hasAPIKey ? "Claude" : "Needs a key") {
                        keySection
                        spendingSection
                    }
                }
                Section {
                    page("Photos", symbol: "photo.on.rectangle", color: .orange, value: savedPhotosValue) { photosSection }
                    page("Maps", symbol: "map", color: .green, value: mapsApp.title) { mapsSection }
                    page("iCloud Sync", symbol: "icloud", color: .cyan, value: model.cloudSync == nil ? "Off" : "On") {
                        SyncSection(cloudSync: model.cloudSync)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onClose() }.fontWeight(.semibold) }
            }
        }
    }

    @AppStorage(MapsApp.key) private var mapsApp = MapsApp.system

    /// A row with a colored icon and its current value, opening a page of settings.
    private func page<Content: View>(
        _ title: String, symbol: String, color: Color, value: String, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        NavigationLink {
            Form { content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent {
                Text(value)
            } label: {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private var calendarName: String {
        guard model.hasCalendarAccess else { return "No access" }
        let id = engine.document.settings.calendarID
        return model.calendarService.writableCalendars().first { $0.id == id }?.title ?? "Not chosen"
    }

    private var savedPhotosValue: String {
        let count = engine.savedPhotoNames.count
        return count == 0 ? "None saved" : "\(count) saved"
    }

    private var mapsSection: some View {
        Section {
            MapsAppPicker()
        } footer: {
            Text("Where an event's place opens when you tap its map. Device Default uses the maps app your iPhone opens map links in.")
        }
    }

    private var spendingSection: some View {
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
            Text("Scanning pauses when the limit is reached. This is Flyers' own estimate, so check the Anthropic Console for exact billing.")
        }
    }

    private var calendarSection: some View {
        Section("Calendar") {
            if model.hasCalendarAccess {
                CalendarChooser(model: model, engine: engine)
            } else {
                Button("Allow Access to Calendar") { Task { await model.requestCalendarAccess() } }
            }
            Picker("Alert", selection: binding(\.alertMinutesBefore)) {
                Text("None").tag(0)
                Text("1 hour before").tag(60)
                Text("3 hours before").tag(180)
                Text("1 day before").tag(1440)
                Text("2 days before").tag(2880)
            }
        }
    }

    private var scanningSection: some View {
        Section {
            Toggle("Scan photos on this iPhone", isOn: $model.scansHere)
            if model.scansHere {
                DatePicker("Photos taken since", selection: binding(\.scanStartDate), displayedComponents: .date)
                Toggle("Include screenshots", isOn: binding(\.includeScreenshots))
                Button("Scan Now") { Task { await model.scanNow() } }
                    .disabled(!model.canScan || engine.isScanning)
            }
            if model.scansHere && !model.hasPhotoAccess {
                Button("Allow Access to Photos") { Task { await model.requestPhotoAccess() } }
            }
            if model.scansHere && !model.hasAPIKey {
                Text("Add your Anthropic API key below to start. A key saved on your Mac shows up here through iCloud Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Scanning")
        } footer: {
            Text(model.cloudSync == nil
                ? "Leave this off while Flyers on your Mac is scanning. Until the two sync, each would read the same photos and add the same events to your calendar."
                : "With sync on, your iPhone and Mac share what they've read, so each photo is read once, by whichever device gets to it first.")
        }
    }

    private var photosSection: some View {
        let saved = engine.savedPhotoNames
        let inLibrary = engine.flyersStillInLibrary
        let past = engine.flyersWithOnlyPastEvents()
        return Section {
            Toggle("Move flyer photos out of Photos", isOn: binding(\.removesPhotosFromLibrary))
            LabeledContent("Saved in Flyers") {
                Text(saved.isEmpty
                    ? "None"
                    : "\(saved.count) \(saved.count == 1 ? "photo" : "photos"), \(ByteCountFormatter.string(fromByteCount: engine.store.photosSize(saved), countStyle: .file))")
            }
            .confirmationDialog(
                "Delete the saved photos of \(past.count) past \(past.count == 1 ? "flyer" : "flyers")?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Delete Photos", role: .destructive) { engine.deleteSavedPhotos(of: past.map(\.id)) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The events and small previews stay. Photos moved out of your library can't be recovered.")
            }
            if !inLibrary.isEmpty && model.hasPhotoAccess {
                Button(isMovingPhotos ? "Removing…" : "Remove \(inLibrary.count) \(inLibrary.count == 1 ? "Flyer" : "Flyers") from Photos") {
                    isMovingPhotos = true
                    Task {
                        await engine.moveOlderPhotosIntoFlyers()
                        isMovingPhotos = false
                    }
                }
                .disabled(isMovingPhotos || engine.isScanning)
            }
            if !past.isEmpty {
                Button("Delete Photos of \(past.count) Past \(past.count == 1 ? "Flyer" : "Flyers")…", role: .destructive) {
                    isConfirmingClear = true
                }
            }
        } header: {
            Text("Photos")
        } footer: {
            Text("Flyers keeps its own copy of every flyer photo, so deleting one from Photos never touches its events.")
        }
    }

    private var keySection: some View {
        Section {
            if model.hasAPIKey {
                LabeledContent("Key", value: "Saved in your Keychain")
                Button("Remove Key", role: .destructive) { model.removeAPIKey() }
            } else {
                APIKeyField(model: model)
            }
        } header: {
            Text("Anthropic API key")
        } footer: {
            Text("Flyers sends photos that look like flyers to Anthropic's API to read them, using your own key. It syncs to your other devices through iCloud Keychain.")
        }
    }
}

/// Picks the calendar new events go on, or makes one called Flyers.
struct CalendarChooser: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine

    var body: some View {
        let calendars = model.calendarService.writableCalendars()
        Picker("Add events to", selection: Binding(
            get: { engine.document.settings.calendarID },
            set: { model.chooseCalendar($0) }
        )) {
            Text("Choose…").tag(String?.none)
            ForEach(calendars) { choice in
                Text(choice.title).tag(String?.some(choice.id))
            }
        }
        if !calendars.contains(where: { $0.title == CalendarService.defaultCalendarName }) {
            Button("Make a “\(CalendarService.defaultCalendarName)” Calendar") { model.createFlyersCalendar() }
        }
    }
}

/// Checks a key with Anthropic before saving it in the Keychain.
struct APIKeyField: View {
    @ObservedObject var model: PhoneModel
    @State private var key = ""
    @State private var error: String?
    @State private var isChecking = false

    var body: some View {
        SecureField("sk-ant-…", text: $key)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(save)
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
        Button(isChecking ? "Checking…" : "Save Key", action: save)
            .disabled(key.isEmpty || isChecking)
    }

    private func save() {
        isChecking = true
        Task {
            error = await model.saveAPIKey(key)
            if error == nil { key = "" }
            isChecking = false
        }
    }
}

/// First run: a welcome with a card per step, over a soft wash of color, like the Mac app.
struct PhoneSetupView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.tint)
                        Text("Welcome to Flyers").font(.largeTitle.bold())
                        Text("Photograph a flyer, and its events land on your calendar.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 8)

                    if model.cloudSync != nil {
                        SetupStepCard(symbol: "icloud.fill", title: "Synced with your Mac", done: true,
                                      detail: "Flyers your Mac finds show up here through iCloud. Turn on scanning in Settings to read photos on this iPhone too.") {
                            EmptyView()
                        }
                    }
                    if model.needsScanningSetup {
                        SetupStepCard(symbol: "key.fill", title: "Anthropic API key", done: model.hasAPIKey,
                                      detail: "Flyers reads flyers with Claude, using your own key. It syncs through iCloud Keychain.") {
                            VStack(alignment: .leading, spacing: 8) { APIKeyField(model: model) }
                                .textFieldStyle(.roundedBorder)
                        }
                        SetupStepCard(symbol: "photo.on.rectangle", title: "Photos", done: model.hasPhotoAccess,
                                      detail: "To look through your new photos for flyers.") {
                            Button("Allow Access") { Task { await model.requestPhotoAccess() } }.glassButton(prominent: true)
                        }
                    }
                    SetupStepCard(symbol: "calendar", title: "Calendar",
                                  done: model.hasCalendarAccess && engine.document.settings.calendarID != nil,
                                  detail: model.cloudSync != nil
                                      ? "To change or delete events in your calendar from this iPhone."
                                      : "To add the events Flyers finds.") {
                        if model.hasCalendarAccess {
                            VStack(alignment: .leading, spacing: 8) { CalendarChooser(model: model, engine: engine) }
                                .pickerStyle(.menu)
                        } else {
                            Button("Allow Access") { Task { await model.requestCalendarAccess() } }.glassButton(prominent: true)
                        }
                    }
                }
                .padding(24)
            }
            .background { SetupBackdrop() }
            .safeAreaInset(edge: .bottom) {
                Button { dismiss() } label: {
                    Text(model.isSetUp ? "Get Started" : "Not Now").font(.headline).frame(maxWidth: .infinity)
                }
                .glassButton(prominent: model.isSetUp)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
    }
}

private struct SetupStepCard<Action: View>: View {
    let symbol: String
    let title: String
    let done: Bool
    let detail: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: done ? "checkmark.circle.fill" : symbol)
                        .font(.title2)
                        .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                        .frame(width: 32)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if !done { action() }
            }
        }
        .animation(.snappy, value: done)
    }
}

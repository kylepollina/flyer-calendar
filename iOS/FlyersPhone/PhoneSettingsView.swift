import FlyersCore
import SwiftUI

struct PhoneSettingsView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    @Environment(\.dismiss) private var dismiss
    @State private var isMovingPhotos = false
    @State private var isConfirmingClear = false

    private func binding<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { engine.document.settings[keyPath: path] }, set: { value in engine.updateSettings { $0[keyPath: path] = value } })
    }

    var body: some View {
        NavigationStack {
            Form {
                calendarSection
                scanningSection
                photosSection
                keySection
                Section("Spending") {
                    LabeledContent("This month", value: engine.spendThisMonth.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
                    Picker("Monthly limit", selection: binding(\.monthlySpendLimit)) {
                        Text("$0.50").tag(0.5)
                        Text("$1").tag(1.0)
                        Text("$5").tag(5.0)
                        Text("$20").tag(20.0)
                    }
                }
                Section {
                    Button("Show Setup") {
                        dismiss()
                        model.isShowingSetup = true
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
        }
    }

    private var calendarSection: some View {
        Section("Calendar") {
            if model.hasCalendarAccess {
                CalendarChooser(model: model, engine: engine)
            } else {
                Button("Allow Access to Calendar") { Task { await model.requestCalendarAccess() } }
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
            if !model.hasPhotoAccess {
                Button("Allow Access to Photos") { Task { await model.requestPhotoAccess() } }
            }
        } header: {
            Text("Scanning")
        } footer: {
            Text("Leave this off while Flyers on your Mac is scanning. Until the two sync, each would read the same photos and add the same events to your calendar.")
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
            Text("Flyers sends photos that look like flyers to Anthropic's API to read them, using your own key.")
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

                    SetupStepCard(symbol: "key.fill", title: "Anthropic API key", done: model.hasAPIKey,
                                  detail: "Flyers reads flyers with Claude, using your own key.") {
                        VStack(alignment: .leading, spacing: 8) { APIKeyField(model: model) }
                            .textFieldStyle(.roundedBorder)
                    }
                    SetupStepCard(symbol: "photo.on.rectangle", title: "Photos", done: model.hasPhotoAccess,
                                  detail: "To look through your new photos for flyers.") {
                        Button("Allow Access") { Task { await model.requestPhotoAccess() } }.glassButton(prominent: true)
                    }
                    SetupStepCard(symbol: "calendar", title: "Calendar",
                                  done: model.hasCalendarAccess && engine.document.settings.calendarID != nil,
                                  detail: "To add the events Flyers finds.") {
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

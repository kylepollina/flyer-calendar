import FlyersCore
import SwiftUI

struct PhoneSettingsView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var engine: FlyersEngine
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var keyError: String?
    @State private var isCheckingKey = false

    private func binding<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { engine.document.settings[keyPath: path] }, set: { value in engine.updateSettings { $0[keyPath: path] = value } })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Scan photos on this iPhone", isOn: $model.scansHere)
                    if model.scansHere {
                        DatePicker("Photos taken since", selection: binding(\.scanStartDate), displayedComponents: .date)
                        Toggle("Include screenshots", isOn: binding(\.includeScreenshots))
                        Toggle("Move flyer photos out of Photos", isOn: binding(\.removesPhotosFromLibrary))
                        Button("Scan Now") { Task { await model.scanNow() } }
                            .disabled(!model.canScan || engine.isScanning)
                    }
                } header: {
                    Text("Scanning")
                } footer: {
                    Text("Leave this off while Flyers on your Mac is scanning. Until the two sync, each would read the same photos and add the same events to your calendar.")
                }

                Section("Anthropic API key") {
                    if model.hasAPIKey {
                        LabeledContent("Key", value: "Saved in your Keychain")
                        Button("Remove Key", role: .destructive) { model.removeAPIKey() }
                    } else {
                        SecureField("sk-ant-…", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if let keyError { Text(keyError).font(.caption).foregroundStyle(.red) }
                        Button(isCheckingKey ? "Checking…" : "Save Key") {
                            isCheckingKey = true
                            Task {
                                keyError = await model.saveAPIKey(key)
                                if keyError == nil { key = "" }
                                isCheckingKey = false
                            }
                        }
                        .disabled(key.isEmpty || isCheckingKey)
                    }
                }

                Section("Access") {
                    if model.hasPhotoAccess {
                        LabeledContent("Photos", value: "Allowed")
                    } else {
                        Button("Allow access to Photos") { Task { await model.requestPhotoAccess() } }
                    }
                    if model.hasCalendarAccess {
                        Picker("Calendar", selection: Binding(
                            get: { engine.document.settings.calendarID },
                            set: { model.chooseCalendar($0) }
                        )) {
                            Text("None").tag(String?.none)
                            ForEach(model.calendarService.writableCalendars()) { choice in
                                Text(choice.title).tag(String?.some(choice.id))
                            }
                        }
                    } else {
                        Button("Allow access to Calendar") { Task { await model.requestCalendarAccess() } }
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
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

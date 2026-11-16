import FlyersCore
import SwiftUI

/// iCloud sync in Settings: whether it's on, when it last synced, and what went wrong.
/// Shared by the Mac and iPhone apps.
struct SyncSection: View {
    let cloudSync: CloudSync?

    var body: some View {
        Section {
            if let cloudSync {
                SyncStatusRows(cloudSync: cloudSync)
            } else {
                LabeledContent("iCloud", value: "Off in this build")
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Flyers, events and saved photos sync through your iCloud account. Only the device that found an event adds it to your calendar, and Calendar's own sync brings it to the rest.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SyncStatusRows: View {
    @ObservedObject var cloudSync: CloudSync
    @State private var isSyncing = false

    var body: some View {
        LabeledContent("iCloud") {
            if let error = cloudSync.lastError {
                Text(error).foregroundStyle(.red)
            } else if let last = cloudSync.lastSyncAt {
                Text("Synced \(last.formatted(.relative(presentation: .named)))")
            } else {
                Text("Waiting to sync")
            }
        }
        Button(isSyncing ? "Syncing…" : "Sync Now") {
            isSyncing = true
            Task {
                await cloudSync.fetchNow()
                await cloudSync.pushNow()
                isSyncing = false
            }
        }
        .disabled(isSyncing)
    }
}

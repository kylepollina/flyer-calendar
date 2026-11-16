import FlyersCore
import SwiftUI

extension View {
    /// Asks before deleting events. Set `ids` to ask; it clears when you answer.
    /// Shared by the Mac and iPhone apps.
    func confirmingDelete(_ ids: Binding<[UUID]>, engine: FlyersEngine, perform: @escaping ([UUID]) -> Void) -> some View {
        let names = ids.wrappedValue.compactMap { engine.event(id: $0)?.name }
        let title = names.count == 1 ? "Delete “\(names[0])”?" : "Delete \(ids.wrappedValue.count) events?"
        return confirmationDialog(
            title,
            isPresented: Binding(get: { !ids.wrappedValue.isEmpty }, set: { if !$0 { ids.wrappedValue = [] } }),
            titleVisibility: .visible,
            presenting: ids.wrappedValue
        ) { pending in
            Button(pending.count == 1 ? "Delete Event" : "Delete \(pending.count) Events", role: .destructive) { perform(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.count == 1
                 ? "It comes off your calendar too. You can restore it from Past."
                 : "They come off your calendar too. You can restore them from Past.")
        }
    }
}

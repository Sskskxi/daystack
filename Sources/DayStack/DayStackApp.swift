import SwiftUI

@main
struct DayStackApp: App {
    @StateObject private var store: TodoStore
    @StateObject private var sync: SyncService
    @StateObject private var reminders: ReminderSync

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = TodoStore()
        _store = StateObject(wrappedValue: store)
        _sync = StateObject(wrappedValue: SyncService(store: store))
        _reminders = StateObject(wrappedValue: ReminderSync(store: store))
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(store)
                .environmentObject(sync)
                .environmentObject(reminders)
        } label: {
            MenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuLabel: View {
    @ObservedObject var store: TodoStore

    var body: some View {
        let open = store.openCount(on: Date())
        HStack(spacing: 3) {
            Image(systemName: "calendar")
            if open > 0 { Text("\(open)") }
        }
    }
}

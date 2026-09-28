import SwiftUI

@main
struct DayStackApp: App {
    @StateObject private var store: TodoStore
    @StateObject private var sync: SyncService
    @StateObject private var reminders: ReminderSync
    @StateObject private var settings: AppSettings

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        // Created first: it sets the calendar's first weekday that everything else uses.
        _settings = StateObject(wrappedValue: AppSettings())
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
                .environmentObject(settings)
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

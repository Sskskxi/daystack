import SwiftUI
import UserNotifications

@main
struct DayStackApp: App {
    @StateObject private var store: TodoStore
    @StateObject private var sync: SyncService
    @StateObject private var reminders: ReminderSync
    @StateObject private var settings: AppSettings
    @StateObject private var widget: WidgetExport

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        // Created first: it sets the calendar's first weekday that everything else uses.
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        let store = TodoStore()
        let reminders = ReminderSync(store: store)
        _widget = StateObject(wrappedValue: WidgetExport(store: store, settings: settings))
        // Alerts now come only from Reminders; drop anything 1.6.x scheduled itself.
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        _store = StateObject(wrappedValue: store)
        _sync = StateObject(wrappedValue: SyncService(store: store))
        _reminders = StateObject(wrappedValue: reminders)
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(store)
                .environmentObject(sync)
                .environmentObject(reminders)
                .environmentObject(settings)
                .environmentObject(widget)
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

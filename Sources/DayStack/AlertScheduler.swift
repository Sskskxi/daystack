import Combine
import DayStackCore
import Foundation
import UserNotifications

/// Keeps macOS notifications in step with the to-do list: one per timed to-do, plus the optional
/// morning summary and evening nudge. Everything is rescheduled from scratch on each change,
/// which keeps the summaries' text current without tracking individual edits.
@MainActor
final class AlertScheduler: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var denied = false

    private let store: TodoStore
    private let settings: AppSettings
    private let reminders: ReminderSync
    private let center = UNUserNotificationCenter.current()
    private var bag = Set<AnyCancellable>()

    private static let prefix = "daystack."
    private static let daysAhead = 7
    /// macOS keeps at most 64 pending notifications per app; leave room for the summaries.
    private static let maxTodoAlerts = 40

    init(store: TodoStore, settings: AppSettings, reminders: ReminderSync) {
        self.store = store
        self.settings = settings
        self.reminders = reminders
        super.init()
        center.delegate = self

        Publishers.Merge4(
            store.$todos.map { _ in () },
            settings.objectWillChange.map { _ in () },
            reminders.$enabled.map { _ in () },
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged).map { _ in () }
        )
        .debounce(for: .seconds(1), scheduler: RunLoop.main)
        .sink { [weak self] in self?.reschedule() }
        .store(in: &bag)

        reschedule()
    }

    private var anyEnabled: Bool { settings.todoAlerts || settings.morningOn || settings.eveningOn }

    func reschedule() {
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            guard anyEnabled else { return }

            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            denied = !granted
            guard granted else { return }

            for request in buildRequests() {
                try? await center.add(request)
            }
        }
    }

    private func buildRequests() -> [UNNotificationRequest] {
        let now = Date()
        let cal = Calendar.current
        var requests: [UNNotificationRequest] = []

        if settings.todoAlerts {
            let horizon = cal.date(byAdding: .day, value: Self.daysAhead, to: now)!
            // A to-do already linked to a reminder rings through that reminder's alarm (Mac and iPhone),
            // so skip ours to avoid a duplicate. Unlinked ones (sync off, pending or failing) still get ours.
            let remindersHandle = reminders.enabled
            let timed = store.todos
                .compactMap { t -> (Todo, Date)? in
                    guard !t.done, let at = t.alertDate, at > now, at < horizon else { return nil }
                    if remindersHandle && t.reminderId != nil { return nil }
                    return (t, at)
                }
                .sorted { $0.1 < $1.1 }
                .prefix(Self.maxTodoAlerts)
            for (todo, at) in timed {
                requests.append(request("todo.\(todo.id.uuidString)", at: at,
                                        title: todo.title, body: L("DayStack to-do at %@", at.fmt(.dateTime.hour().minute()))))
            }
        }

        for offset in 0..<Self.daysAhead {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) else { continue }
            let items = store.items(on: day)
            let open = items.filter { !$0.done }

            if settings.morningOn, !items.isEmpty,
               let at = cal.date(byAdding: .minute, value: settings.morningMinutes, to: day), at > now {
                let names = open.prefix(3).map(\.title).joined(separator: ", ")
                let more = open.count > 3 ? L(" and %d more", open.count - 3) : ""
                let body = open.isEmpty ? L("All done already. Nice!") : names + more
                requests.append(request("morning.\(Day.key(day))", at: at, title: L("%d to-dos today", items.count), body: body))
            }

            if settings.eveningOn, !open.isEmpty,
               let at = cal.date(byAdding: .minute, value: settings.eveningMinutes, to: day), at > now {
                let title = open.count == 1 ? L("1 to-do still open today") : L("%d to-dos still open today", open.count)
                requests.append(request("evening.\(Day.key(day))", at: at, title: title,
                                        body: open.prefix(3).map(\.title).joined(separator: ", ")))
            }
        }
        return requests
    }

    private func request(_ id: String, at date: Date, title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNNotificationRequest(identifier: Self.prefix + id, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
    }

    // Show banners even though a menu bar app counts as "active".
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

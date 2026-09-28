import Combine
import DayStackCore
import EventKit
import Foundation

/// Two-way sync between DayStack to-dos and a "DayStack" list in Apple Reminders.
/// Links live in Todo.reminderId; `known` remembers which links existed at the last sync
/// so a missing item can be told apart as "deleted on the other side" vs "not created yet".
@MainActor
final class ReminderSync: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "remindersSync")
            if enabled && !oldValue { start() }
        }
    }
    @Published private(set) var message: String?

    private let ek = EKEventStore()
    private let store: TodoStore
    private var bag = Set<AnyCancellable>()
    private var syncing = false
    private var pending = false

    private static let listTitle = "DayStack"

    private var known: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "remindersKnownIds") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "remindersKnownIds") }
    }

    init(store: TodoStore) {
        self.store = store
        enabled = UserDefaults.standard.bool(forKey: "remindersSync")

        store.$todos
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: ek)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &bag)

        if enabled { start() }
    }

    private var authorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    private func start() {
        Task {
            do {
                let granted: Bool
                if #available(macOS 14.0, *) {
                    granted = try await ek.requestFullAccessToReminders()
                } else {
                    granted = try await ek.requestAccess(to: .reminder)
                }
                if granted {
                    message = nil
                    sync()
                } else {
                    message = L("Allow DayStack in System Settings → Privacy & Security → Reminders, then turn sync on again.")
                    enabled = false
                }
            } catch {
                message = L("Couldn't access Reminders: %@", error.localizedDescription)
                enabled = false
            }
        }
    }

    func sync() {
        guard enabled, authorized else { return }
        if syncing {
            pending = true
            return
        }
        syncing = true
        Task {
            do {
                let list = try reminderList()
                let reminders = await fetch(list)
                try reconcile(reminders, list: list)
                message = nil
            } catch {
                message = L("Reminders sync failed: %@", error.localizedDescription)
            }
            syncing = false
            if pending {
                pending = false
                sync()
            }
        }
    }

    private func reminderList() throws -> EKCalendar {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "remindersListId"), let cal = ek.calendar(withIdentifier: id) {
            return cal
        }
        if let cal = ek.calendars(for: .reminder).first(where: { $0.title == Self.listTitle }) {
            defaults.set(cal.calendarIdentifier, forKey: "remindersListId")
            return cal
        }
        let cal = EKCalendar(for: .reminder, eventStore: ek)
        cal.title = Self.listTitle
        guard let source = ek.defaultCalendarForNewReminders()?.source ?? ek.sources.first(where: { $0.sourceType == .calDAV }) else {
            throw NSError(domain: "DayStack", code: 2, userInfo: [NSLocalizedDescriptionKey: L("No Reminders account found.")])
        }
        cal.source = source
        try ek.saveCalendar(cal, commit: true)
        defaults.set(cal.calendarIdentifier, forKey: "remindersListId")
        return cal
    }

    private func fetch(_ list: EKCalendar) async -> [EKReminder] {
        await withCheckedContinuation { cont in
            ek.fetchReminders(matching: ek.predicateForReminders(in: [list])) { cont.resume(returning: $0 ?? []) }
        }
    }

    private func reconcile(_ reminders: [EKReminder], list: EKCalendar) throws {
        let byId = Dictionary(reminders.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let known = self.known
        let todos = store.todos
        let linkedByTodos = Set(todos.compactMap(\.reminderId))

        var updates: [UUID: (inout Todo) -> Void] = [:]
        var deletes = Set<UUID>()
        var created: [(UUID, EKReminder)] = []
        var imported: [Todo] = []
        var linked = Set<String>()

        for todo in todos {
            if let rid = todo.reminderId, let r = byId[rid] {
                linked.insert(rid)
                let theirs = values(of: r)
                guard theirs.title != todo.title || theirs.done != todo.done || theirs.day != todo.day || theirs.time != todo.time else { continue }
                let theirTime = r.lastModifiedDate ?? .distantPast
                if theirTime > todo.lastModified {
                    updates[todo.id] = { t in
                        t.title = theirs.title
                        t.done = theirs.done
                        t.day = theirs.day
                        t.time = theirs.time
                        t.modifiedAt = theirTime
                    }
                } else {
                    write(todo, to: r)
                    try ek.save(r, commit: false)
                }
            } else if let rid = todo.reminderId, known.contains(rid) {
                deletes.insert(todo.id)
            } else {
                let r = EKReminder(eventStore: ek)
                r.calendar = list
                write(todo, to: r)
                try ek.save(r, commit: false)
                created.append((todo.id, r))
            }
        }

        for r in reminders where !linkedByTodos.contains(r.calendarItemIdentifier) {
            if known.contains(r.calendarItemIdentifier) {
                try ek.remove(r, commit: false)
            } else {
                let v = values(of: r)
                imported.append(Todo(title: v.title, day: v.day, done: v.done,
                                     createdAt: r.creationDate ?? Date(),
                                     modifiedAt: r.lastModifiedDate ?? Date(),
                                     reminderId: r.calendarItemIdentifier,
                                     time: v.time))
                linked.insert(r.calendarItemIdentifier)
            }
        }

        try ek.commit()

        for (todoId, r) in created {
            let rid = r.calendarItemIdentifier
            linked.insert(rid)
            updates[todoId] = { $0.reminderId = rid }
        }

        if !updates.isEmpty || !deletes.isEmpty || !imported.isEmpty {
            store.apply { all in
                all.removeAll { deletes.contains($0.id) }
                for i in all.indices {
                    updates[all[i].id]?(&all[i])
                }
                let existing = Set(all.compactMap(\.reminderId))
                all += imported.filter { !existing.contains($0.reminderId ?? "") }
            }
        }
        self.known = linked
    }

    private func values(of r: EKReminder) -> (title: String, done: Bool, day: String, time: String?) {
        var day = Day.key(r.creationDate ?? Date())
        var time: String?
        if let c = r.dueDateComponents, let y = c.year, let m = c.month, let d = c.day {
            day = String(format: "%04d-%02d-%02d", y, m, d)
            if let h = c.hour { time = TimeText.format(h, c.minute ?? 0) }
        }
        return (r.title ?? "", r.isCompleted, day, time)
    }

    private func write(_ todo: Todo, to r: EKReminder) {
        r.title = todo.title
        r.isCompleted = todo.done
        guard let date = Day.date(todo.day) else { return }
        let ymd = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        var comps = r.dueDateComponents ?? DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.year = ymd.year
        comps.month = ymd.month
        comps.day = ymd.day
        // A timed to-do becomes a timed reminder with an alarm, so the iPhone rings too.
        if let time = todo.time, let (h, m) = TimeText.components(time) {
            comps.hour = h
            comps.minute = m
            r.dueDateComponents = comps
            if let at = todo.alertDate { r.alarms = [EKAlarm(absoluteDate: at)] }
        } else {
            comps.hour = nil
            comps.minute = nil
            r.dueDateComponents = comps
            r.alarms = nil
        }
    }
}

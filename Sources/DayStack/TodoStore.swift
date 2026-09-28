import Foundation

struct Todo: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var day: String
    var done = false
    var createdAt = Date()
}

enum Day {
    static let cal: Calendar = {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date) -> String { formatter.string(from: date) }

    static func date(_ key: String) -> Date? { formatter.date(from: key) }

    static var mondayFirstSymbols: [String] {
        let s = cal.veryShortWeekdaySymbols
        return Array(s[1...]) + [s[0]]
    }
}

extension Array where Element == Todo {
    func on(_ date: Date) -> [Todo] {
        let k = Day.key(date)
        return filter { $0.day == k }
    }

    var doneByDay: [String: Int] {
        reduce(into: [:]) { acc, t in if t.done { acc[t.day, default: 0] += 1 } }
    }

    var daysWithItems: Set<String> { Set(map(\.day)) }
}

final class TodoStore: ObservableObject {
    @Published private(set) var todos: [Todo] = []
    private let url: URL
    private var dayObserver: NSObjectProtocol?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DayStack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("todos.json")

        // "Today" is computed at render time, so redraw the menu bar count and calendar when the date rolls over.
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }

        guard let data = try? Data(contentsOf: url) else { return }
        do {
            todos = try JSONDecoder().decode([Todo].self, from: data)
        } catch {
            // Keep the unreadable file instead of overwriting it on the next save.
            let backup = dir.appendingPathComponent("todos.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("DayStack: could not read todos.json, moved to \(backup.lastPathComponent): \(error)")
        }
    }

    func items(on date: Date) -> [Todo] {
        let k = Day.key(date)
        return todos.filter { $0.day == k }
    }

    func openCount(on date: Date) -> Int {
        let k = Day.key(date)
        return todos.filter { $0.day == k && !$0.done }.count
    }

    var doneByDay: [String: Int] { todos.doneByDay }

    var daysWithItems: Set<String> { todos.daysWithItems }

    func add(_ title: String, on date: Date) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        todos.append(Todo(title: t, day: Day.key(date)))
        save()
    }

    func toggle(_ id: UUID) {
        guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[i].done.toggle()
        save()
    }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[i].title = t
        save()
    }

    func delete(_ id: UUID) {
        todos.removeAll { $0.id == id }
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(todos)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("DayStack: save failed: \(error)")
        }
    }
}

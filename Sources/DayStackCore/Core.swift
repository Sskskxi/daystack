import Foundation

public struct Todo: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var day: String
    public var done: Bool
    public var createdAt: Date
    public var modifiedAt: Date?
    public var reminderId: String?

    public init(id: UUID = UUID(), title: String, day: String, done: Bool = false,
                createdAt: Date = Date(), modifiedAt: Date? = Date(), reminderId: String? = nil) {
        self.id = id
        self.title = title
        self.day = day
        self.done = done
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.reminderId = reminderId
    }

    public var lastModified: Date { modifiedAt ?? createdAt }
}

public enum Day {
    /// 1 = Sunday, 2 = Monday.
    public static var firstWeekday = 2 {
        didSet { cal = makeCalendar(firstWeekday) }
    }

    public private(set) static var cal = makeCalendar(2)

    private static func makeCalendar(_ firstWeekday: Int) -> Calendar {
        var c = Calendar.current
        c.firstWeekday = firstWeekday
        return c
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func key(_ date: Date) -> String { formatter.string(from: date) }

    public static func date(_ key: String) -> Date? { formatter.date(from: key) }

    public static func isValidKey(_ key: String) -> Bool {
        guard let d = date(key) else { return false }
        return self.key(d) == key
    }

    /// Very short weekday symbols ordered from `firstWeekday`.
    public static var weekdaySymbols: [String] {
        let s = cal.veryShortWeekdaySymbols
        let start = cal.firstWeekday - 1
        return Array(s[start...] + s[..<start])
    }
}

public extension Array where Element == Todo {
    func on(_ date: Date) -> [Todo] {
        let k = Day.key(date)
        return filter { $0.day == k }
    }

    var doneByDay: [String: Int] {
        reduce(into: [:]) { acc, t in if t.done { acc[t.day, default: 0] += 1 } }
    }

    var daysWithItems: Set<String> { Set(map(\.day)) }

    var countByDay: [String: Int] {
        reduce(into: [:]) { acc, t in acc[t.day, default: 0] += 1 }
    }
}

/// The on-disk to-do list, shared by the app and the MCP server. Every write is a locked read-modify-write
/// so two processes editing at once can't drop each other's changes.
public enum TodoFile {
    public static let directory: URL = {
        if let custom = ProcessInfo.processInfo.environment["DAYSTACK_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DayStack", isDirectory: true)
    }()

    public static var url: URL { directory.appendingPathComponent("todos.json") }
    private static var lockURL: URL { directory.appendingPathComponent(".todos.lock") }

    public static func load() throws -> [Todo] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Todo].self, from: Data(contentsOf: url))
    }

    @discardableResult
    public static func mutate(_ change: (inout [Todo]) throws -> Void) throws -> [Todo] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        var todos = try load()
        try change(&todos)
        try JSONEncoder().encode(todos).write(to: url, options: .atomic)
        return todos
    }
}

import Foundation

public struct Todo: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var day: String
    public var done: Bool
    public var createdAt: Date
    public var modifiedAt: Date?
    public var reminderId: String?
    /// Alert time as "HH:mm" (24h), or nil for an all-day to-do.
    public var time: String?

    public init(id: UUID = UUID(), title: String, day: String, done: Bool = false,
                createdAt: Date = Date(), modifiedAt: Date? = Date(), reminderId: String? = nil, time: String? = nil) {
        self.id = id
        self.title = title
        self.day = day
        self.done = done
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.reminderId = reminderId
        self.time = time
    }

    /// The moment this to-do's alert should fire, if it has a time.
    public var alertDate: Date? {
        guard let time, let d = Day.date(day), let (h, m) = TimeText.components(time) else { return nil }
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: d)
    }

    public var lastModified: Date { modifiedAt ?? createdAt }
}

public enum Day {
    /// 1 = Sunday, 2 = Monday.
    public static var firstWeekday = 2 {
        didSet { cal = makeCalendar() }
    }

    /// Language used for weekday symbols.
    public static var locale = Locale.current {
        didSet { cal = makeCalendar() }
    }

    public private(set) static var cal = makeCalendar()

    private static func makeCalendar() -> Calendar {
        var c = Calendar.current
        c.firstWeekday = firstWeekday
        c.locale = locale
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

/// Finds a time of day written in a to-do title: "3pm", "3:30 pm", "15:00", "오후 3시", "9시 반".
public enum TimeText {
    public static func components(_ hhmm: String) -> (Int, Int)? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    public static func format(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d", h, m) }

    public static func isValid(_ s: String) -> Bool { components(s) != nil && s.count == 5 }

    private static let korean = try! NSRegularExpression(pattern: #"(오전|오후|아침|저녁|밤)?\s*(\d{1,2})\s*시(?:\s*(\d{1,2})\s*분|\s*(반))?"#)
    private static let english = try! NSRegularExpression(pattern: #"\b(\d{1,2})(?::([0-5]\d))?\s*(am|pm|a\.m\.|p\.m\.)(?![a-z])"#, options: .caseInsensitive)
    private static let clock = try! NSRegularExpression(pattern: #"\b([01]?\d|2[0-3]):([0-5]\d)\b"#)

    public static func parse(_ text: String) -> String? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }

        if let m = korean.firstMatch(in: text, range: range), var h = Int(group(m, 2) ?? "") {
            let marker = group(m, 1)
            let minute = group(m, 4) != nil ? 30 : Int(group(m, 3) ?? "0") ?? 0
            if ["오후", "저녁", "밤"].contains(marker ?? ""), h < 12 { h += 12 }
            if ["오전", "아침"].contains(marker ?? ""), h == 12 { h = 0 }
            if (0...23).contains(h), (0...59).contains(minute) { return format(h, minute) }
        }
        if let m = english.firstMatch(in: text, range: range), var h = Int(group(m, 1) ?? ""), (1...12).contains(h) {
            let minute = Int(group(m, 2) ?? "0") ?? 0
            let pm = (group(m, 3) ?? "").lowercased().hasPrefix("p")
            if pm, h < 12 { h += 12 }
            if !pm, h == 12 { h = 0 }
            return format(h, minute)
        }
        if let m = clock.firstMatch(in: text, range: range), let h = Int(group(m, 1) ?? ""), let minute = Int(group(m, 2) ?? "") {
            return format(h, minute)
        }
        return nil
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

import DayStackCore
import Foundation

final class TodoStore: ObservableObject {
    @Published private(set) var todos: [Todo] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var dayObserver: NSObjectProtocol?

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: TodoFile.directory, withIntermediateDirectories: true)
        do {
            todos = try TodoFile.load()
        } catch {
            // Keep the unreadable file instead of overwriting it on the next save.
            let backup = TodoFile.directory.appendingPathComponent("todos.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: TodoFile.url, to: backup)
            NSLog("DayStack: could not read todos.json, moved to \(backup.lastPathComponent): \(error)")
        }

        // "Today" is computed at render time, so redraw the menu bar count and calendar when the date rolls over.
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
        watchForExternalChanges()
    }

    /// Picks up edits made by the MCP server (e.g. Claude adding a to-do) while the app is running.
    private func watchForExternalChanges() {
        let fd = open(TodoFile.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.reloadFromDisk() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func reloadFromDisk() {
        guard let latest = try? TodoFile.load(), latest != todos else { return }
        todos = latest
    }

    func items(on date: Date) -> [Todo] { todos.on(date) }

    func openCount(on date: Date) -> Int { todos.on(date).filter { !$0.done }.count }

    var doneByDay: [String: Int] { todos.doneByDay }

    var countByDay: [String: Int] { todos.countByDay }

    func add(_ title: String, on date: Date) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        apply { $0.append(Todo(title: t, day: Day.key(date), time: TimeText.parse(t))) }
    }

    func setTime(_ id: UUID, _ time: String?) {
        apply { todos in
            guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
            todos[i].time = time
            todos[i].modifiedAt = Date()
        }
    }

    func toggle(_ id: UUID) {
        apply { todos in
            guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
            todos[i].done.toggle()
            todos[i].modifiedAt = Date()
        }
    }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        apply { todos in
            guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
            todos[i].title = t
            if let time = TimeText.parse(t) { todos[i].time = time }
            todos[i].modifiedAt = Date()
        }
    }

    func delete(_ id: UUID) {
        apply { $0.removeAll { $0.id == id } }
    }

    func apply(_ change: (inout [Todo]) -> Void) {
        do {
            todos = try TodoFile.mutate(change)
        } catch {
            NSLog("DayStack: save failed: \(error)")
        }
    }
}

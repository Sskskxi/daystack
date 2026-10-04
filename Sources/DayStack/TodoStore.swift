import AppKit
import DayStackCore
import Foundation

final class TodoStore: ObservableObject {
    @Published private(set) var todos: [Todo] = []
    @Published private(set) var categories: [TodoCategory] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var undoStack: [[Todo]] = []
    private var redoStack: [[Todo]] = []
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

        if let saved = CategoryFile.load() {
            categories = saved
        } else {
            // First launch: start with the usual split so the feature is visible; editable in Settings.
            setCategories([
                TodoCategory(name: L("Work"), color: TodoCategory.palette[0]),
                TodoCategory(name: L("Study"), color: TodoCategory.palette[1]),
                TodoCategory(name: L("Personal"), color: TodoCategory.palette[2]),
            ])
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
        if let latest = try? TodoFile.load(), latest != todos { todos = latest }
        if let latest = CategoryFile.load(), latest != categories { categories = latest }
    }

    // MARK: - Categories

    func category(_ id: String?) -> TodoCategory? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    func setCategories(_ list: [TodoCategory]) {
        categories = list
        do { try CategoryFile.save(list) } catch { NSLog("DayStack: saving categories failed: \(error)") }
    }

    func addCategory() {
        let used = Set(categories.map(\.color))
        let color = TodoCategory.palette.first { !used.contains($0) } ?? TodoCategory.palette[categories.count % TodoCategory.palette.count]
        setCategories(categories + [TodoCategory(name: L("New category"), color: color)])
    }

    func updateCategory(_ c: TodoCategory) {
        let name = c.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = categories.firstIndex(where: { $0.id == c.id }) else { return }
        var list = categories
        list[i] = TodoCategory(id: c.id, name: String(name.prefix(30)), color: c.color)
        setCategories(list)
    }

    /// To-dos keep the dead id and simply show as uncategorized.
    func deleteCategory(_ id: String) {
        setCategories(categories.filter { $0.id != id })
    }

    func items(on date: Date) -> [Todo] { todos.on(date) }

    func openCount(on date: Date) -> Int { todos.on(date).filter { !$0.done }.count }

    var doneByDay: [String: Int] { todos.doneByDay }

    var countByDay: [String: Int] { todos.countByDay }

    /// `time` ("HH:mm") wins over a time written in the title; `detectTime: false` ignores the title.
    /// A "#category" in the title wins over `category`.
    func add(_ title: String, on date: Date, time: String? = nil, detectTime: Bool = true, category: String? = nil) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let q = QuickAdd.parse(t, categories: categories)
        let resolved = time ?? (detectTime ? TimeText.parse(q.title) : nil)
        apply(undoable: true) { $0.append(Todo(title: q.title, day: Day.key(date), time: resolved,
                               category: q.category ?? category, important: q.important)) }
    }

    func setTime(_ id: UUID, _ time: String?) { edit(id) { $0.time = time } }

    func toggle(_ id: UUID) {
        apply(undoable: true) { todos in
            guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
            todos.setDone(at: i, !todos[i].done)
        }
    }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let q = QuickAdd.parse(t, categories: categories)
        edit(id) { todo in
            todo.title = q.title
            if let time = TimeText.parse(q.title) { todo.time = time }
            if let c = q.category { todo.category = c }
            if q.important { todo.isImportant = true }
        }
    }

    /// Moves to-dos to another day, e.g. postponing what didn't get done.
    func move(_ ids: [UUID], to date: Date) {
        let key = Day.key(date)
        let set = Set(ids)
        apply(undoable: true) { todos in
            for i in todos.indices where set.contains(todos[i].id) && todos[i].day != key {
                todos[i].day = key
                todos[i].modifiedAt = Date()
            }
        }
    }

    func setCategory(_ id: UUID, _ category: String?) { edit(id) { $0.category = category } }

    func toggleImportant(_ id: UUID) { edit(id) { $0.isImportant.toggle() } }

    func setRepeat(_ id: UUID, _ rule: Repeat?) { edit(id) { $0.repeats = rule } }

    private func edit(_ id: UUID, _ change: (inout Todo) -> Void) {
        apply(undoable: true) { todos in
            guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
            change(&todos[i])
            todos[i].modifiedAt = Date()
        }
    }

    func delete(_ id: UUID) {
        apply(undoable: true) { $0.removeAll { $0.id == id } }
    }

    /// `undoable` is for the user's own edits; sync changes shouldn't land on the undo stack.
    func apply(undoable: Bool = false, _ change: (inout [Todo]) -> Void) {
        let before = todos
        do {
            todos = try TodoFile.mutate(change)
        } catch {
            NSLog("DayStack: save failed: \(error)")
            return
        }
        if undoable, todos != before {
            undoStack = Array((undoStack + [before]).suffix(50))
            redoStack = []
        }
    }

    func undo() { restore(from: &undoStack, saveTo: &redoStack) }

    func redo() { restore(from: &redoStack, saveTo: &undoStack) }

    private func restore(from stack: inout [[Todo]], saveTo other: inout [[Todo]]) {
        guard let snapshot = stack.popLast() else { NSSound.beep(); return }
        other.append(todos)
        let current = Set(todos.map(\.id))
        // A to-do coming back from deletion gets a new reminder; its old one was removed by sync.
        let restored = snapshot.map { t -> Todo in
            var t = t
            if !current.contains(t.id) { t.reminderId = nil }
            t.modifiedAt = Date()
            return t
        }
        apply { $0 = restored }
    }
}

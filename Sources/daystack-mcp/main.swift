import DayStackCore
import Foundation

// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0) exposing DayStack to-dos as tools.

let serverVersion = "1.9.0"
// Limits so a runaway or prompt-injected AI session can't flood the user's list.
let maxTitleLength = 300
let maxBatch = 50

func log(_ s: String) {
    FileHandle.standardError.write(Data("daystack-mcp: \(s)\n".utf8))
}

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

struct ToolError: Error { let message: String }

// MARK: - Dates

func todayKey() -> String { Day.key(Date()) }

func weekday(_ key: String) -> String {
    guard let d = Day.date(key) else { return "" }
    return d.formatted(.dateTime.weekday(.abbreviated))
}

func parseDate(_ raw: Any?, default def: String) throws -> String {
    guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return def }
    let offsets = ["today": 0, "tomorrow": 1, "yesterday": -1]
    if let off = offsets[s] {
        return Day.key(Day.cal.date(byAdding: .day, value: off, to: Date())!)
    }
    guard Day.isValidKey(s) else { throw ToolError(message: "Invalid date '\(s)'. Use YYYY-MM-DD, 'today', 'tomorrow' or 'yesterday'.") }
    return s
}

func shortId(_ t: Todo) -> String { String(t.id.uuidString.prefix(8)).lowercased() }

func findIndex(_ todos: [Todo], _ raw: Any?) throws -> Int {
    guard let id = (raw as? String)?.lowercased(), !id.isEmpty else { throw ToolError(message: "Missing 'id'.") }
    let matches = todos.indices.filter { todos[$0].id.uuidString.lowercased().hasPrefix(id) }
    guard matches.count == 1 else {
        throw ToolError(message: matches.isEmpty ? "No to-do with id '\(id)'. Call list_todos to see ids." : "Id '\(id)' is ambiguous; use more characters.")
    }
    return matches[0]
}

/// "!" for important, "#Work" for its category, "↻ daily" when it repeats.
func tags(_ t: Todo, _ categories: [TodoCategory]) -> String {
    var out: [String] = []
    if t.isImportant { out.append("!") }
    if let c = categories.first(where: { $0.id == t.category }) { out.append("#\(c.name)") }
    if let r = t.repeats { out.append("repeats \(r.rawValue)") }
    return out.isEmpty ? "" : " [" + out.joined(separator: ", ") + "]"
}

func describe(_ t: Todo) -> String {
    "[\(t.done ? "x" : " ")] \(t.title)\(tags(t, CategoryFile.load() ?? []))  (id: \(shortId(t)), \(t.day)\(t.time.map { " \($0)" } ?? ""))"
}

/// Looks a category up by name; "" or "none" clears it.
func parseCategory(_ raw: Any?) throws -> String?? {
    guard let name = (raw as? String)?.trimmingCharacters(in: .whitespaces) else { return .none }
    let clean = name.hasPrefix("#") ? String(name.dropFirst()) : name
    if clean.isEmpty || clean.lowercased() == "none" { return .some(nil) }
    let all = CategoryFile.load() ?? []
    guard let c = all.first(where: { $0.name.compare(clean, options: .caseInsensitive) == .orderedSame }) else {
        throw ToolError(message: "No category '\(clean)'. Categories: \(all.map(\.name).joined(separator: ", ")).")
    }
    return .some(c.id)
}

func parseRepeat(_ raw: Any?) throws -> Repeat?? {
    guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return .none }
    if s.isEmpty || s == "never" || s == "none" { return .some(nil) }
    guard let r = Repeat(rawValue: s) else { throw ToolError(message: "Invalid repeat '\(s)'. Use daily, weekdays, weekly, monthly or never.") }
    return .some(r)
}

/// Builds a new to-do from tool arguments, honoring "#Category" and "!" written in the title.
func newTodo(_ args: [String: Any]) throws -> Todo {
    let q = QuickAdd.parse(try cleanTitle(args["title"]), categories: CategoryFile.load() ?? [])
    return Todo(title: q.title, day: try parseDate(args["date"], default: todayKey()),
                time: try parseTime(args["time"], title: q.title),
                category: try parseCategory(args["category"]) ?? q.category,
                important: (args["important"] as? Bool) ?? q.important,
                repeats: try parseRepeat(args["repeat"]) ?? nil)
}

// MARK: - Tools

let dateProp: [String: Any] = ["type": "string", "description": "YYYY-MM-DD in the user's local time, or 'today' / 'tomorrow' / 'yesterday'."]
let timeProp: [String: Any] = ["type": "string", "description": "Alert time HH:mm (24h, local). The user gets a notification then. Omit for an all-day to-do."]
let categoryProp: [String: Any] = ["type": "string", "description": "Category name, e.g. Work or Study (see list_todos for the user's categories). Empty string for none."]
let importantProp: [String: Any] = ["type": "boolean", "description": "Mark as important (flagged, shown first)."]
let repeatProp: [String: Any] = ["type": "string", "enum": ["never", "daily", "weekdays", "weekly", "monthly"], "description": "Repeat rule. When checked off, the next occurrence is added."]

func parseTime(_ raw: Any?, title: String) throws -> String? {
    guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return TimeText.parse(title) }
    guard TimeText.isValid(s) else { throw ToolError(message: "Invalid time '\(s)'. Use HH:mm, e.g. 15:30.") }
    return s
}

func toolDefinitions() -> [[String: Any]] {
    let today = todayKey()
    return [
        [
            "name": "list_todos",
            "description": "List the user's DayStack to-dos for a date range (default: today), with their categories. Today is \(today) (\(weekday(today))). Returns ids needed by update_todo and delete_todo.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "start_date": dateProp,
                    "end_date": dateProp,
                    "include_done": ["type": "boolean", "description": "Include completed to-dos (default true)."],
                ],
            ],
        ],
        [
            "name": "add_todo",
            "description": "Add one to-do / plan to the user's DayStack calendar. Today is \(today) (\(weekday(today))). Put any time of day in the title, e.g. '3pm Dentist'.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "What to do."],
                    "date": dateProp,
                    "time": timeProp,
                    "category": categoryProp,
                    "important": importantProp,
                    "repeat": repeatProp,
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "add_todos",
            "description": "Add several to-dos at once, e.g. a plan for the week. Today is \(today) (\(weekday(today))).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": ["title": ["type": "string"], "date": dateProp, "time": timeProp,
                                           "category": categoryProp, "important": importantProp, "repeat": repeatProp],
                            "required": ["title"],
                        ],
                    ],
                ],
                "required": ["items"],
            ],
        ],
        [
            "name": "update_todo",
            "description": "Change a to-do's title, move it to another date (e.g. postpone what didn't get done), change its category, importance or repeat, or mark it done / not done.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Id (or its first 8 characters) from list_todos."],
                    "title": ["type": "string"],
                    "date": dateProp,
                    "time": ["type": "string", "description": "Alert time HH:mm, or empty string to remove the alert."],
                    "done": ["type": "boolean"],
                    "category": categoryProp,
                    "important": importantProp,
                    "repeat": repeatProp,
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "delete_todo",
            "description": "Delete a to-do permanently.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "Id (or its first 8 characters) from list_todos."]],
                "required": ["id"],
            ],
        ],
    ]
}

func cleanTitle(_ raw: Any?) throws -> String {
    let t = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !t.isEmpty else { throw ToolError(message: "Title can't be empty.") }
    guard t.count <= maxTitleLength else { throw ToolError(message: "Title is too long (max \(maxTitleLength) characters).") }
    return t
}

func callTool(_ name: String, _ args: [String: Any]) throws -> String {
    switch name {
    case "list_todos":
        let today = todayKey()
        let start = try parseDate(args["start_date"], default: today)
        let end = try parseDate(args["end_date"], default: start)
        let includeDone = args["include_done"] as? Bool ?? true
        let todos = try TodoFile.load()
            .filter { $0.day >= start && $0.day <= end && (includeDone || !$0.done) }
            .sorted { ($0.day, $0.createdAt) < ($1.day, $1.createdAt) }
        let categories = CategoryFile.load() ?? []
        var out = "Today is \(today) (\(weekday(today))). Categories: \(categories.isEmpty ? "none" : categories.map(\.name).joined(separator: ", ")).\n"
        if todos.isEmpty { return out + "No to-dos from \(start) to \(end)." }
        for (day, items) in Dictionary(grouping: todos, by: \.day).sorted(by: { $0.key < $1.key }) {
            out += "\n\(day) (\(weekday(day))) — \(items.filter(\.done).count)/\(items.count) done\n"
            for t in items { out += "  [\(t.done ? "x" : " ")] \(t.time.map { "\($0) " } ?? "")\(t.title)\(tags(t, categories))  (id: \(shortId(t)))\n" }
        }
        return out

    case "add_todo":
        let todo = try newTodo(args)
        try TodoFile.mutate { $0.append(todo) }
        return "Added: \(describe(todo))"

    case "add_todos":
        guard let items = args["items"] as? [[String: Any]], !items.isEmpty else { throw ToolError(message: "'items' must be a non-empty array.") }
        guard items.count <= maxBatch else { throw ToolError(message: "Too many items (max \(maxBatch) per call).") }
        let new = try items.map(newTodo)
        try TodoFile.mutate { $0 += new }
        return "Added \(new.count) to-dos:\n" + new.map { "  " + describe($0) }.joined(separator: "\n")

    case "update_todo":
        let newTitle = try args["title"].map { try cleanTitle($0) }
        let newDay = try args["date"].map { try parseDate($0, default: "") }
        let newDone = args["done"] as? Bool
        let timeArg = args["time"] as? String
        if let t = timeArg, !t.isEmpty, !TimeText.isValid(t) { throw ToolError(message: "Invalid time '\(t)'. Use HH:mm.") }
        let newCategory = try parseCategory(args["category"])
        let newRepeat = try parseRepeat(args["repeat"])
        let newImportant = args["important"] as? Bool
        var result: Todo?
        try TodoFile.mutate { todos in
            let i = try findIndex(todos, args["id"])
            if let newTitle { todos[i].title = newTitle }
            if let newDay { todos[i].day = newDay }
            if let timeArg { todos[i].time = timeArg.isEmpty ? nil : timeArg }
            if let newCategory { todos[i].category = newCategory }
            if let newRepeat { todos[i].repeats = newRepeat }
            if let newImportant { todos[i].isImportant = newImportant }
            todos[i].modifiedAt = Date()
            // Last, so a repeating to-do's next occurrence copies the edits above.
            if let newDone { todos.setDone(at: i, newDone) }
            result = todos[i]
        }
        return "Updated: \(describe(result!))"

    case "delete_todo":
        var removed: Todo?
        try TodoFile.mutate { todos in
            let i = try findIndex(todos, args["id"])
            removed = todos.remove(at: i)
        }
        return "Deleted: \(removed!.title) (\(removed!.day))"

    default:
        throw ToolError(message: "Unknown tool '\(name)'.")
    }
}

// MARK: - JSON-RPC loop

func handle(_ msg: [String: Any]) {
    guard let id = msg["id"], let method = msg["method"] as? String else { return } // notifications need no reply
    let params = msg["params"] as? [String: Any] ?? [:]

    func reply(_ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

    switch method {
    case "initialize":
        reply([
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "daystack", "version": serverVersion],
            "instructions": "DayStack is the user's menu bar calendar and to-do list. Use these tools when the user asks to add, plan, check, complete, move or remove to-dos. Dates are in the user's local time.",
        ])
    case "ping":
        reply([:])
    case "tools/list":
        reply(["tools": toolDefinitions()])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            reply(["content": [["type": "text", "text": try callTool(name, args)]], "isError": false])
        } catch let e as ToolError {
            reply(["content": [["type": "text", "text": e.message]], "isError": true])
        } catch {
            reply(["content": [["type": "text", "text": "DayStack error: \(error.localizedDescription)"]], "isError": true])
        }
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
    }
}

log("started, data at \(TodoFile.url.path)")
while let line = readLine(strippingNewline: true) {
    guard line.utf8.count <= 1_000_000, let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
    handle(msg)
}

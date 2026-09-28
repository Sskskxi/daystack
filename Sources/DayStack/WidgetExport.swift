import Combine
import DayStackCore
import Foundation

/// Feeds the iPhone home screen widget. The widget is a Scriptable script (Scriptable reads its
/// scripts and files from its own iCloud Drive folder), so we write both the script and a small
/// data file there whenever to-dos or settings change.
@MainActor
final class WidgetExport: ObservableObject {
    @Published private(set) var available = false

    private let store: TodoStore
    private let settings: AppSettings
    private var bag = Set<AnyCancellable>()
    private let fm = FileManager.default

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents", isDirectory: true)
    }

    init(store: TodoStore, settings: AppSettings) {
        self.store = store
        self.settings = settings

        Publishers.Merge3(
            store.$todos.map { _ in () },
            settings.objectWillChange.map { _ in () },
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged).map { _ in () }
        )
        .debounce(for: .seconds(2), scheduler: RunLoop.main)
        .sink { [weak self] in self?.write() }
        .store(in: &bag)

        // Scriptable's folder appears once the app is installed on an iPhone with iCloud on.
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.write() }
            .store(in: &bag)

        write()
    }

    func write() {
        let container = Self.folder.deletingLastPathComponent()
        available = fm.fileExists(atPath: container.path)
        guard available else { return }

        do {
            try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try writeIfChanged(Data(Self.script.utf8), to: Self.folder.appendingPathComponent("DayStack.js"))
            try writeIfChanged(exportData(), to: Self.folder.appendingPathComponent("DayStack.json"))
        } catch {
            NSLog("DayStack: widget export failed: \(error)")
        }
    }

    private func exportData() throws -> Data {
        let cal = Day.cal
        let today = cal.startOfDay(for: Date())
        let cutoff = Day.key(cal.date(byAdding: .day, value: -140, to: today)!)
        let done = store.todos.doneByDay.filter { $0.key >= cutoff }

        var todos: [String: [[String: Any]]] = [:]
        for offset in -1...7 {
            let day = cal.date(byAdding: .day, value: offset, to: today)!
            let items = store.todos.on(day)
            if !items.isEmpty {
                todos[Day.key(day)] = items.map { ["t": $0.title, "d": $0.done] }
            }
        }

        let json: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: Date()),
            "weekStart": settings.weekStart,
            "lang": L10n.isKorean ? "ko" : "en",
            "tint": settings.tintHex ?? NSNull(),
            "done": done,
            "todos": todos,
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    /// Skips identical writes so iCloud doesn't re-upload (and the widget doesn't churn) for nothing.
    private func writeIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), stripUpdated(existing) == stripUpdated(data) { return }
        try data.write(to: url, options: .atomic)
    }

    private func stripUpdated(_ data: Data) -> Data {
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        obj.removeValue(forKey: "updated")
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? data
    }

    static let script = #"""
    // Variables used by Scriptable.
    // These must be at the very top of the file. Do not edit.
    // icon-color: deep-gray; icon-glyph: calendar-alt;

    // DayStack widget: heatmap + today's to-dos. Data is written by DayStack on your Mac.
    const fm = FileManager.iCloud()
    const path = fm.joinPath(fm.documentsDirectory(), "DayStack.json")

    const fg = Color.dynamic(new Color("#1C1C1E"), new Color("#F2F2F7"))
    const dim = Color.dynamic(new Color("#8E8E93"), new Color("#8E8E93"))
    const bg = Color.dynamic(new Color("#FFFFFF"), new Color("#1C1C1E"))

    function key(d) {
      return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0")
    }
    function level(n) { return n === 0 ? 0 : n === 1 ? 1 : n <= 3 ? 2 : 3 }

    function cellColor(data, lv) {
      if (lv === 0) return Color.dynamic(new Color("#E5E5EA"), new Color("#2C2C2E"))
      if (data.tint) return new Color(data.tint, [0, 0.3, 0.6, 0.95][lv])
      const light = ["", "#BDBDC2", "#7C7C82", "#2C2C2E"]
      const dark = ["", "#5A5A5E", "#9A9A9E", "#E5E5EA"]
      return Color.dynamic(new Color(light[lv]), new Color(dark[lv]))
    }

    function heatmap(parent, data, weeks, size, gap) {
      const now = new Date()
      const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
      const first = (data.weekStart || 2) - 1
      const offset = (today.getDay() - first + 7) % 7
      const start = new Date(today.getFullYear(), today.getMonth(), today.getDate() - offset - (weeks - 1) * 7)
      const grid = parent.addStack()
      grid.layoutHorizontally()
      grid.spacing = gap
      for (let w = 0; w < weeks; w++) {
        const col = grid.addStack()
        col.layoutVertically()
        col.spacing = gap
        for (let r = 0; r < 7; r++) {
          const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + w * 7 + r)
          const cell = col.addStack()
          cell.size = new Size(size, size)
          cell.cornerRadius = size * 0.22
          if (d > today) {
            cell.backgroundColor = Color.clear()
            continue
          }
          cell.backgroundColor = cellColor(data, level(data.done[key(d)] || 0))
          if (key(d) === key(today)) {
            cell.borderWidth = 1.5
            cell.borderColor = fg
          }
        }
      }
    }

    function todayItems(data) { return (data.todos || {})[key(new Date())] || [] }

    function todoList(parent, data, max, fontSize) {
      const items = todayItems(data)
      const box = parent.addStack()
      box.layoutVertically()
      box.spacing = 3
      const head = box.addStack()
      const title = head.addText(tr("Today", "오늘"))
      title.font = Font.semiboldSystemFont(fontSize)
      title.textColor = fg
      head.addSpacer()
      const count = head.addText(items.filter(i => i.d).length + "/" + items.length)
      count.font = Font.mediumMonospacedSystemFont(fontSize - 1)
      count.textColor = dim
      if (items.length === 0) {
        const t = box.addText(tr("Nothing planned", "계획 없음"))
        t.font = Font.systemFont(fontSize - 1)
        t.textColor = dim
      }
      for (const item of items.slice(0, max)) {
        const t = box.addText((item.d ? "☑︎ " : "☐ ") + item.t)
        t.font = Font.systemFont(fontSize - 1)
        t.textColor = item.d ? dim : fg
        t.lineLimit = 1
      }
      if (items.length > max) {
        const more = box.addText(tr("+" + (items.length - max) + " more", "+" + (items.length - max) + "개 더"))
        more.font = Font.systemFont(fontSize - 2)
        more.textColor = dim
      }
    }

    async function load() {
      if (!fm.fileExists(path)) return null
      if (!fm.isFileDownloaded(path)) await fm.downloadFileFromiCloud(path)
      return JSON.parse(fm.readString(path))
    }

    const data = await load()
    const KO = data ? data.lang === "ko" : Device.language().startsWith("ko")
    function tr(en, ko) { return KO ? ko : en }
    const family = config.widgetFamily || "medium"
    const w = new ListWidget()
    w.backgroundColor = bg
    w.setPadding(14, 14, 14, 14)
    w.refreshAfterDate = new Date(Date.now() + 15 * 60 * 1000)

    if (!data) {
      const t = w.addText(tr("Open DayStack on your Mac to set up this widget.", "Mac에서 DayStack을 열어 위젯을 설정하세요."))
      t.font = Font.systemFont(12)
      t.textColor = dim
    } else if (family === "small") {
      heatmap(w, data, 8, 12, 3)
      w.addSpacer()
      const items = todayItems(data)
      const done = items.filter(i => i.d).length + "/" + items.length
      const t = w.addText(tr(done + " today", "오늘 " + done))
      t.font = Font.semiboldSystemFont(12)
      t.textColor = fg
    } else if (family === "large") {
      const head = w.addText("DayStack")
      head.font = Font.boldSystemFont(15)
      head.textColor = fg
      w.addSpacer(8)
      heatmap(w, data, 18, 14, 3)
      w.addSpacer(12)
      todoList(w, data, 8, 14)
      w.addSpacer()
    } else {
      const row = w.addStack()
      row.layoutHorizontally()
      heatmap(row, data, 9, 12, 3)
      row.addSpacer(14)
      todoList(row, data, 5, 13)
    }

    Script.setWidget(w)
    if (!config.runsInWidget) {
      if (family === "small") await w.presentSmall()
      else if (family === "large") await w.presentLarge()
      else await w.presentMedium()
    }
    Script.complete()
    """#
}

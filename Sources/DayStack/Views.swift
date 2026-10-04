import DayStackCore
import ServiceManagement
import SwiftUI

enum Shade {
    static func level(_ n: Int) -> Int { n == 0 ? 0 : n == 1 ? 1 : n <= 3 ? 2 : 3 }
    static func fill(_ level: Int, tint: Color) -> Color {
        level == 0 ? Color.primary.opacity(0.07) : tint.opacity([0, 0.3, 0.6, 0.95][level])
    }
}

private struct HeatTintKey: EnvironmentKey {
    static let defaultValue = Color.primary
}

private struct HeatStrongTextKey: EnvironmentKey {
    static let defaultValue = Color(nsColor: .windowBackgroundColor)
}

extension EnvironmentValues {
    var heatTint: Color {
        get { self[HeatTintKey.self] }
        set { self[HeatTintKey.self] = newValue }
    }

    /// Text color on the two darkest heatmap levels.
    var heatStrongText: Color {
        get { self[HeatStrongTextKey.self] }
        set { self[HeatStrongTextKey.self] = newValue }
    }
}

enum Screen: Equatable {
    case calendar
    case day(Date)
    case friends
    case friend(String)
    case friendDay(String, Date)
    case settings
}

struct RootView: View {
    @EnvironmentObject var sync: SyncService
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: TodoStore
    @StateObject private var keys = KeyRouter()
    @State private var screen = Screen.calendar
    @State private var month = Date()
    @State private var showWeeks = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch screen {
                case .calendar:
                    CalendarPane(month: $month, showWeeks: $showWeeks,
                                 onPick: { screen = .day($0) },
                                 onFriends: { screen = .friends },
                                 onSettings: { screen = .settings })
                case .settings:
                    SettingsView { screen = .calendar }
                case .day(let day):
                    // A new view per day, so the draft, selection and key handler belong to that day.
                    DayView(day: day, onBack: { screen = .calendar }, onGo: { screen = .day($0) })
                        .id(Day.key(day))
                case .friends:
                    FriendsView(onBack: { screen = .calendar }, onOpen: { screen = .friend($0) })
                case .friend(let id):
                    if let m = sync.friends.first(where: { $0.id == id }) {
                        FriendView(member: m, onBack: { screen = .friends }, onPick: { screen = .friendDay(id, $0) })
                    } else {
                        FriendsView(onBack: { screen = .calendar }, onOpen: { screen = .friend($0) })
                    }
                case .friendDay(let id, let day):
                    if let m = sync.friends.first(where: { $0.id == id }) {
                        FriendDayView(member: m, day: day) { screen = .friend(id) }
                    } else {
                        FriendsView(onBack: { screen = .calendar }, onOpen: { screen = .friend($0) })
                    }
                }
            }
            .padding(14)
            // One fixed height for every screen; MenuBarExtra windows don't reliably shrink when content gets shorter.
            .frame(height: 500, alignment: .top)
            NoticeBar { screen = .settings }
        }
        // Rebuild everything when the week start or language changes: dates and text are computed at render time.
        .id("\(settings.weekStart)-\(settings.language.rawValue)")
        .frame(width: 320)
        .environment(\.locale, L10n.locale)
        .environment(\.heatTint, settings.tint)
        .environment(\.heatStrongText, settings.strongText)
        .environmentObject(keys)
        .onAppear { keys.install(global: handleKey) }
    }

    /// Shortcuts that work on every screen; screens handle theirs first.
    private func handleKey(_ k: Key) -> Bool {
        switch true {
        case k.is("n", .cmd):
            screen = .day(Date())
        case k.is(",", .cmd):
            screen = .settings
        case k.is("z", .cmd) && !k.editingText:
            store.undo()
        case k.is("z", [.cmd, .shift]) && !k.editingText:
            store.redo()
        case k.is("w", .cmd):
            NSApp.keyWindow?.close()
        case k.is("q", .cmd):
            NSApp.terminate(nil)
        default:
            return false
        }
        return true
    }
}

// MARK: - Calendar

struct CalendarPane: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var sync: SyncService
    @Environment(\.heatTint) private var tint
    @Binding var month: Date
    @Binding var showWeeks: Bool
    let onPick: (Date) -> Void
    let onFriends: () -> Void
    let onSettings: () -> Void
    @EnvironmentObject var keys: KeyRouter
    @State private var keyOwner = UUID()

    var body: some View {
        let done = store.doneByDay
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 1) {
                Text(showWeeks ? L("Last %d weeks", StackHeatmap.weeks) : month.fmt(.dateTime.year().month(.wide)))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if !showWeeks {
                    IconButton("chevron.left") { shift(-1) }
                    Button(L("Today")) { month = Date() }
                        .buttonStyle(.plain).font(.caption.weight(.medium))
                    IconButton("chevron.right") { shift(1) }
                }
                IconButton("person.2") { onFriends() }
                    .help(L("Friends"))
                IconButton(showWeeks ? "calendar" : "square.grid.3x3.fill") { showWeeks.toggle() }
                    .help(showWeeks ? L("Month view") : L("Stacked weeks view"))
                IconButton("gearshape", action: onSettings)
                    .help(L("Settings"))
                    .overlay(alignment: .topTrailing) {
                        if sync.updateAvailable {
                            Circle().fill(Color.red).frame(width: 6, height: 6).offset(x: -2, y: 3)
                        }
                    }
            }

            if showWeeks {
                StackHeatmap(done: done, onPick: onPick)
            } else {
                MonthGrid(month: month, done: done, itemCounts: store.countByDay, onPick: onPick)
            }

            HStack(spacing: 3) {
                Text(L("%d done", doneCount(done))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(L("Less")).font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<4, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 2).fill(Shade.fill(l, tint: tint)).frame(width: 9, height: 9)
                }
                Text(L("More")).font(.caption2).foregroundStyle(.secondary)
            }

            TodoPreview(onOpen: onPick)
        }
        .onAppear { keys.set(keyOwner, handleKey) }
        .onDisappear { keys.clear(keyOwner) }
    }

    private func handleKey(_ k: Key) -> Bool {
        guard !showWeeks, !k.editingText else { return false }
        switch true {
        case k.is(Key.left, .cmd), k.is(Key.left): shift(-1)
        case k.is(Key.right, .cmd), k.is(Key.right): shift(1)
        case k.is("t", .cmd): month = Date()
        case k.is(Key.returnKey): onPick(Date())
        default: return false
        }
        return true
    }

    private func shift(_ months: Int) {
        month = Day.cal.date(byAdding: .month, value: months, to: month) ?? month
    }

    private func doneCount(_ done: [String: Int]) -> Int {
        let cal = Day.cal
        if showWeeks {
            let today = cal.startOfDay(for: Date())
            return (0..<(StackHeatmap.weeks * 7)).reduce(0) { sum, i in
                let d = cal.date(byAdding: .day, value: -i, to: today)!
                return sum + (done[Day.key(d)] ?? 0)
            }
        }
        let prefix = String(Day.key(month).prefix(7))
        return done.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
    }
}

struct TodoPreview: View {
    @EnvironmentObject var store: TodoStore
    let onOpen: (Date) -> Void

    var body: some View {
        let today = Date()
        let todayKey = Day.key(today)
        let todays = store.items(on: today)
        let earlier = store.todos
            .filter { !$0.done && $0.day < todayKey }
            .sorted { $0.day > $1.day }

        VStack(alignment: .leading, spacing: 6) {
            Divider()
            SectionHeader(title: L("Today"), detail: "\(todays.filter(\.done).count)/\(todays.count)") { onOpen(today) }
            if todays.isEmpty {
                Text(L("Nothing planned today."))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(TodoGroup.ordered(todays)) { t in
                        TodoRow(todo: t, compact: true)
                    }
                    if !earlier.isEmpty {
                        SectionHeader(title: L("Unfinished earlier"), detail: "\(earlier.count)", action: nil,
                                      button: (L("Move all to today"), { store.move(earlier.map(\.id), to: today) }))
                            .padding(.top, 8).padding(.bottom, 2)
                        ForEach(earlier) { t in
                            let date = Day.date(t.day) ?? today
                            TodoRow(todo: t, compact: true,
                                    dateLabel: date.fmt(.dateTime.month(.abbreviated).day()),
                                    onOpenDay: { onOpen(date) })
                        }
                    }
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let detail: String
    let action: (() -> Void)?
    var button: (String, () -> Void)? = nil

    var body: some View {
        HStack {
            Text(title).font(.caption.weight(.semibold))
            Spacer()
            if let button {
                Button(button.0, action: button.1)
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let action {
                IconButton("chevron.right", action: action).help(L("Open day"))
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: 18)
    }
}

struct MonthGrid: View {
    let month: Date
    let done: [String: Int]
    let itemCounts: [String: Int]
    let onPick: (Date) -> Void

    private var days: [Date] {
        let cal = Day.cal
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let offset = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        return (0..<42).map { cal.date(byAdding: .day, value: $0 - offset, to: first)! }
    }

    var body: some View {
        let cal = Day.cal
        let symbols = Day.weekdaySymbols
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                Text(symbols[i]).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(days, id: \.self) { d in
                let key = Day.key(d)
                DayCell(
                    number: cal.component(.day, from: d),
                    inMonth: cal.isDate(d, equalTo: month, toGranularity: .month),
                    level: Shade.level(done[key] ?? 0),
                    items: itemCounts[key] ?? 0,
                    isToday: cal.isDateInToday(d)
                ) { onPick(d) }
            }
        }
    }
}

struct DayCell: View {
    let number: Int
    let inMonth: Bool
    let level: Int
    let items: Int
    let isToday: Bool
    let action: () -> Void
    @Environment(\.heatTint) private var tint
    @Environment(\.heatStrongText) private var strongText

    private static let maxDots = 5

    var body: some View {
        let ink = level >= 2 ? strongText : Color.primary
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Shade.fill(level, tint: tint))
                if isToday {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary, lineWidth: 1.5)
                }
                Text("\(number)")
                    .font(.system(size: 11, weight: isToday ? .bold : .regular))
                    .foregroundStyle(ink)
                    .offset(y: items > 0 ? -3 : 0)
            }
            .overlay(alignment: .bottom) {
                if items > 0 {
                    HStack(spacing: 2) {
                        ForEach(0..<min(items, Self.maxDots), id: \.self) { _ in
                            Circle().fill(ink.opacity(0.6)).frame(width: 3, height: 3)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .help(items == 0 ? "" : items == 1 ? L("1 to-do") : L("%d to-dos", items))
            .frame(height: 30)
            .contentShape(Rectangle())
            .opacity(inMonth ? 1 : 0.35)
        }
        .buttonStyle(.plain)
    }
}

struct StackHeatmap: View {
    static let weeks = 18
    let done: [String: Int]
    let onPick: (Date) -> Void
    @Environment(\.heatTint) private var tint

    private let size: CGFloat = 11
    private let gap: CGFloat = 3

    var body: some View {
        let cal = Day.cal
        let today = cal.startOfDay(for: Date())
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let start = cal.date(byAdding: .weekOfYear, value: -(Self.weeks - 1), to: thisWeek)!
        let symbols = Day.weekdaySymbols

        HStack(alignment: .top, spacing: gap) {
            VStack(spacing: gap) {
                ForEach(0..<7, id: \.self) { r in
                    Text(r % 2 == 0 ? symbols[r] : "")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                        .frame(width: 10, height: size)
                }
            }
            ForEach(0..<Self.weeks, id: \.self) { w in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { r in
                        let d = cal.date(byAdding: .day, value: w * 7 + r, to: start)!
                        let n = done[Day.key(d)] ?? 0
                        if d > today {
                            Color.clear.frame(width: size, height: size)
                        } else {
                            Button { onPick(d) } label: {
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(Shade.fill(Shade.level(n), tint: tint))
                                    .overlay {
                                        if cal.isDateInToday(d) {
                                            RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.primary, lineWidth: 1)
                                        }
                                    }
                                    .frame(width: size, height: size)
                            }
                            .buttonStyle(.plain)
                            .help(L("%@: %d done", d.fmt(.dateTime.month(.abbreviated).day()), n))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: - Day

struct DayView: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var keys: KeyRouter
    let day: Date
    let onBack: () -> Void
    let onGo: (Date) -> Void

    @State private var draft = ""
    @State private var draftTime: String?
    /// The user removed the time, so don't fall back to one written in the text.
    @State private var timeCleared = false
    @State private var pickingTime = false
    /// Stays picked between adds, so a run of work to-dos needs one click.
    @State private var draftCategory: String?
    @State private var pickingCategory = false
    @State private var pickingMoveDate = false
    /// Row chosen with the arrow keys; keyboard commands act on it.
    @State private var selected: UUID?
    @State private var request: RowRequest?
    @State private var keyOwner = UUID()
    @FocusState private var addFocused: Bool

    var body: some View {
        let items = store.items(on: day)
        let shownTime = timeCleared ? nil : (draftTime ?? TimeText.parse(draft))
        let doneCount = items.filter(\.done).count
        let unfinished = items.filter { !$0.done }.map(\.id)
        let pickedCategory = store.category(draftCategory)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                IconButton("chevron.left", action: onBack)
                Text(day.fmt(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.headline)
                if Day.cal.isDateInToday(day) {
                    Text(L("Today")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !unfinished.isEmpty {
                    Menu {
                        if !Day.cal.isDateInToday(day) {
                            Button(L("Move %d unfinished to today", unfinished.count)) { store.move(unfinished, to: Date()) }
                        }
                        Button(L("Postpone %d unfinished a day", unfinished.count)) {
                            store.move(unfinished, to: Postpone.nextDay(after: Day.key(day)))
                        }
                        Button(L("Move %d unfinished to…", unfinished.count)) { pickingMoveDate = true }
                    } label: {
                        Image(systemName: "arrow.turn.up.right").font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("Move unfinished"))
                    .popover(isPresented: $pickingMoveDate, arrowEdge: .bottom) {
                        MoveDatePopover(initial: Postpone.nextDay(after: Day.key(day))) { store.move(unfinished, to: $0) } dismiss: {
                            pickingMoveDate = false
                        }
                    }
                }
                Text("\(doneCount) / \(items.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                TextField(L("Add a to-do…"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($addFocused)
                    .onSubmit(addDraft)
                    .help(L("Tip: \"#Work\" files it under a category, a lone \"!\" marks it important, \"3pm\" sets an alert."))
                Button(action: addDraft) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isDraftEmpty ? 0.08 : 0.85)))
                        .foregroundStyle(isDraftEmpty ? Color.secondary : Color(nsColor: .windowBackgroundColor))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDraftEmpty)
                .help(L("Add"))
                Button { pickingCategory = true } label: {
                    HStack(spacing: 4) {
                        if let pickedCategory {
                            Circle().fill(Color(hex: pickedCategory.color)).frame(width: 8, height: 8)
                            Text(pickedCategory.name).lineLimit(1).frame(maxWidth: 52)
                        } else {
                            Image(systemName: "tag")
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, pickedCategory == nil ? 0 : 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(pickedCategory == nil ? 0.08 : 0.15)))
                    .foregroundStyle(pickedCategory == nil ? Color.secondary : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Category"))
                .popover(isPresented: $pickingCategory, arrowEdge: .bottom) {
                    CategoryPopover(selected: draftCategory, onPick: { draftCategory = $0 }) {
                        pickingCategory = false
                        addFocused = true
                    }
                }
                Button { pickingTime = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: shownTime == nil ? "clock" : "bell.fill")
                        if let shownTime { Text(TimeText.display(shownTime)).monospacedDigit() }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, shownTime == nil ? 0 : 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(shownTime == nil ? 0.08 : 0.15)))
                    .foregroundStyle(shownTime == nil ? Color.secondary : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Alert time"))
                .popover(isPresented: $pickingTime, arrowEdge: .bottom) {
                    TimePopover(initial: shownTime,
                                onSet: { draftTime = $0; timeCleared = false },
                                onRemove: { draftTime = nil; timeCleared = true }) {
                        pickingTime = false
                        addFocused = true
                    }
                }
            }

            if items.isEmpty {
                Text(L("Nothing yet. Type above and press ⏎."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                let groups = TodoGroup.make(items, categories: store.categories)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(groups) { g in
                                if groups.count > 1 || g.category != nil {
                                    CategoryHeader(category: g.category, items: g.items)
                                        .padding(.top, g.id == groups.first?.id ? 0 : 6)
                                }
                                ForEach(g.items) { t in
                                    TodoRow(todo: t, selected: selected == t.id, request: request).id(t.id)
                                }
                            }
                        }
                    }
                    .onChange(of: selected) { id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async { addFocused = true }
            keys.set(keyOwner, handleKey)
        }
        .onDisappear { keys.clear(keyOwner) }
        .onChange(of: addFocused) { f in if f { selected = nil } }
        .onExitCommand(perform: onBack)
    }

    private var isDraftEmpty: Bool { draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private func addDraft() {
        guard !isDraftEmpty else { return }
        store.add(draft, on: day, time: draftTime, detectTime: !timeCleared, category: draftCategory)
        draft = ""
        draftTime = nil
        timeCleared = false
        addFocused = true
    }

    /// See the shortcut list in Settings.
    private func handleKey(_ k: Key) -> Bool {
        let list = TodoGroup.make(store.items(on: day), categories: store.categories).flatMap(\.items)
        let index = selected.flatMap { s in list.firstIndex { $0.id == s } }

        if k.is("n", .cmd) {
            selected = nil
            addFocused = true
            return true
        }
        if k.editingText {
            // ↓ leaves the add field for the list.
            if k.code == Key.down, addFocused, let first = list.first {
                addFocused = false
                selected = first.id
                return true
            }
            return false
        }
        if k.is(Key.left, .cmd) || k.is(Key.right, .cmd) {
            onGo(Day.cal.date(byAdding: .day, value: k.code == Key.left ? -1 : 1, to: day) ?? day)
            return true
        }
        if k.is("t", .cmd) {
            onGo(Date())
            return true
        }
        guard let i = index else {
            if (k.code == Key.down || k.code == Key.up) && k.plain, let t = k.code == Key.down ? list.first : list.last {
                selected = t.id
                return true
            }
            return false
        }
        let t = list[i]
        let neighbor = i + 1 < list.count ? list[i + 1].id : (i > 0 ? list[i - 1].id : nil)

        switch true {
        case k.is(Key.down):
            selected = list[min(i + 1, list.count - 1)].id
        case k.is(Key.up):
            if i == 0 { addFocused = true } else { selected = list[i - 1].id }
        case k.is(Key.escape):
            selected = nil
        case k.is(Key.space), k.is("d", .cmd):
            store.toggle(t.id)
        case k.is(Key.returnKey), k.is("e", .cmd):
            request = RowRequest(id: t.id, action: .edit)
        case k.code == Key.delete || k.code == Key.forwardDelete:
            store.delete(t.id)
            selected = neighbor
        case k.is("]", .cmd):
            store.move([t.id], to: Postpone.nextDay(after: t.day))
            selected = neighbor
        case k.is("t", [.cmd, .shift]):
            if !Day.cal.isDateInToday(day) {
                store.move([t.id], to: Date())
                selected = neighbor
            }
        case k.is("d", [.cmd, .shift]):
            request = RowRequest(id: t.id, action: .date)
        case k.is("a", [.cmd, .shift]):
            request = RowRequest(id: t.id, action: .time)
        case k.is("i", .cmd):
            store.toggleImportant(t.id)
        case k.cmd && !k.shift && !k.option && Int(k.chars).map({ (0...9).contains($0) }) == true:
            let n = Int(k.chars)!
            if n == 0 { store.setCategory(t.id, nil) } else if n <= store.categories.count { store.setCategory(t.id, store.categories[n - 1].id) }
        default:
            return false
        }
        return true
    }
}

/// Asks a row to open its editor or a popover, from a keyboard shortcut.
struct RowRequest: Equatable {
    enum Action { case edit, date, time }
    let id: UUID
    let action: Action
    /// Makes repeating the same request still count as a change.
    var nonce = UUID()
}

/// A day's to-dos split by category, in the order categories are listed in Settings; uncategorized last.
struct TodoGroup: Identifiable {
    let id: String
    let category: TodoCategory?
    let items: [Todo]

    static func make(_ todos: [Todo], categories: [TodoCategory]) -> [TodoGroup] {
        let known = Set(categories.map(\.id))
        var groups = categories.compactMap { c -> TodoGroup? in
            let items = todos.filter { $0.category == c.id }
            return items.isEmpty ? nil : TodoGroup(id: c.id, category: c, items: ordered(items))
        }
        let rest = todos.filter { !known.contains($0.category ?? "") }
        if !rest.isEmpty { groups.append(TodoGroup(id: "", category: nil, items: ordered(rest))) }
        return groups
    }

    /// Important first, otherwise the order they were added in.
    static func ordered(_ todos: [Todo]) -> [Todo] {
        todos.enumerated()
            .sorted { ($0.element.isImportant ? 0 : 1, $0.offset) < ($1.element.isImportant ? 0 : 1, $1.offset) }
            .map(\.element)
    }
}

struct CategoryHeader: View {
    let category: TodoCategory?
    let items: [Todo]

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(category.map { Color(hex: $0.color) } ?? Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(category?.name ?? L("Other")).font(.caption.weight(.semibold))
            Spacer()
            Text("\(items.filter(\.done).count)/\(items.count)").font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(height: 18)
    }
}

/// Picks the category for new to-dos.
struct CategoryPopover: View {
    @EnvironmentObject var store: TodoStore
    let selected: String?
    let onPick: (String?) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(nil)
            ForEach(store.categories) { row($0) }
            Text(L("Type #name in a to-do to file it."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6).padding(.top, 4)
        }
        .padding(8)
        .frame(width: 180)
    }

    private func row(_ c: TodoCategory?) -> some View {
        Button {
            onPick(c?.id)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Circle().fill(c.map { Color(hex: $0.color) } ?? Color.clear)
                    .overlay(Circle().strokeBorder(Color.secondary, lineWidth: c == nil ? 1 : 0))
                    .frame(width: 9, height: 9)
                Text(c?.name ?? L("No category")).font(.system(size: 12))
                Spacer()
                if selected == c?.id { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum Postpone {
    /// The day after the to-do's day, or tomorrow if it's already overdue.
    static func nextDay(after key: String) -> Date {
        let today = Day.cal.startOfDay(for: Date())
        let base = Swift.max(Day.date(key) ?? today, today)
        return Day.cal.date(byAdding: .day, value: 1, to: base) ?? base
    }
}

/// Small popover with a calendar for moving to-dos to another day.
struct MoveDatePopover: View {
    let initial: Date
    let onPick: (Date) -> Void
    let dismiss: () -> Void

    @State private var picked = Date()

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            DatePicker("", selection: $picked, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
                .environment(\.locale, L10n.locale)
                .environment(\.calendar, Day.cal)
            Button(L("Move")) {
                onPick(picked)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.small)
        }
        .padding(10)
        .onAppear { picked = initial }
    }
}

/// Small popover for choosing an alert time ("HH:mm") or removing it.
struct TimePopover: View {
    let initial: String?
    let onSet: (String) -> Void
    let onRemove: () -> Void
    let dismiss: () -> Void

    @State private var picked = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Alert time")).font(.headline)
            DatePicker("", selection: $picked, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.field)
                .environment(\.locale, L10n.locale)
            HStack {
                if initial != nil {
                    Button(L("Remove")) {
                        onRemove()
                        dismiss()
                    }
                }
                Spacer()
                Button(L("Set")) {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: picked)
                    onSet(TimeText.format(c.hour ?? 9, c.minute ?? 0))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 180)
        .onAppear {
            let (h, m) = initial.flatMap(TimeText.components) ?? (9, 0)
            picked = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        }
    }
}

extension TimeText {
    /// "15:00" shown in the user's locale, e.g. "3:00 PM" or "오후 3:00".
    static func display(_ hhmm: String) -> String {
        guard let (h, m) = components(hhmm),
              let d = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) else { return hhmm }
        return d.fmt(.dateTime.hour().minute())
    }
}

struct TodoRow: View {
    @EnvironmentObject var store: TodoStore
    let todo: Todo
    var compact = false
    var dateLabel: String? = nil
    var onOpenDay: (() -> Void)? = nil
    var selected = false
    var request: RowRequest? = nil

    @State private var editing = false
    @State private var text = ""
    @State private var hover = false
    @State private var pickingTime = false
    @State private var pickingDate = false
    @FocusState private var focused: Bool

    var body: some View {
        let category = store.category(todo.category)
        HStack(spacing: 8) {
            Button { store.toggle(todo.id) } label: {
                Image(systemName: todo.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: compact ? 12 : 14))
                    .foregroundStyle(category.map { Color(hex: $0.color) } ?? Color.primary)
            }
            .buttonStyle(.plain)
            .help(category?.name ?? "")

            if todo.isImportant && !editing {
                Image(systemName: "flag.fill")
                    .font(.system(size: compact ? 9 : 10))
                    .foregroundStyle(.orange)
                    .help(L("Important"))
            }

            if let time = todo.time, !editing {
                Label(TimeText.display(time), systemImage: "bell")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: compact ? 10 : 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if editing {
                TextField("", text: $text)
                    .font(.system(size: compact ? 12 : 13))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { f in if !f && editing { commit() } }
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(todo.title)
                    .font(.system(size: compact ? 12 : 13))
                    .lineLimit(compact ? 1 : nil)
                    .strikethrough(todo.done)
                    .foregroundStyle(todo.done ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginEdit)
            }

            if let rule = todo.repeats, !editing, !(hover && compact) {
                Image(systemName: "repeat")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help(L(rule.label))
            }

            // Stay visible while a popover is open, or it would lose its anchor and close.
            if (hover || pickingTime || pickingDate) && !editing {
                if !todo.done {
                    IconButton("arrow.turn.up.right") { store.move([todo.id], to: Postpone.nextDay(after: todo.day)) }
                        .help(L("Postpone a day"))
                }
                optionsMenu
            }
            if let dateLabel, !editing {
                Button { onOpenDay?() } label: {
                    Text(dateLabel).font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Open this day"))
            }
        }
        .frame(minHeight: 22)
        .padding(.horizontal, 6)
        .padding(.vertical, compact ? 1 : 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hover ? 0.06 : 0)))
        .onHover { hover = $0 }
        .onChange(of: request) { r in
            guard let r, r.id == todo.id else { return }
            switch r.action {
            case .edit: beginEdit()
            case .date: pickingDate = true
            case .time: pickingTime = true
            }
        }
        .popover(isPresented: $pickingTime, arrowEdge: .bottom) {
            TimePopover(initial: todo.time,
                        onSet: { store.setTime(todo.id, $0) },
                        onRemove: { store.setTime(todo.id, nil) }) { pickingTime = false }
        }
        .popover(isPresented: $pickingDate, arrowEdge: .bottom) {
            MoveDatePopover(initial: Postpone.nextDay(after: todo.day)) { store.move([todo.id], to: $0) } dismiss: {
                pickingDate = false
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            if todo.day != Day.key(Date()) {
                Button(L("Move to today")) { store.move([todo.id], to: Date()) }
            }
            Button(L("Postpone a day")) { store.move([todo.id], to: Postpone.nextDay(after: todo.day)) }
            Button(L("Choose date…")) { pickingDate = true }
            Divider()
            Button(todo.isImportant ? L("Remove importance") : L("Mark important")) { store.toggleImportant(todo.id) }
            Menu(L("Category")) {
                checkItem(L("No category"), on: store.category(todo.category) == nil) { store.setCategory(todo.id, nil) }
                ForEach(store.categories) { c in
                    checkItem(c.name, on: todo.category == c.id) { store.setCategory(todo.id, c.id) }
                }
            }
            Menu(L("Repeat")) {
                checkItem(L("Never"), on: todo.repeats == nil) { store.setRepeat(todo.id, nil) }
                ForEach(Repeat.allCases, id: \.self) { r in
                    checkItem(L(r.label), on: todo.repeats == r) { store.setRepeat(todo.id, r) }
                }
            }
            Button(L("Alert time…")) { pickingTime = true }
            Divider()
            Button(L("Edit"), action: beginEdit)
            Button(L("Delete"), role: .destructive) { store.delete(todo.id) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 22)
        .help(L("Options"))
    }

    @ViewBuilder
    private func checkItem(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        if on {
            Button(action: action) { Label(title, systemImage: "checkmark") }
        } else {
            Button(title, action: action)
        }
    }

    private func beginEdit() {
        text = todo.title
        editing = true
    }

    private func commit() {
        store.rename(todo.id, to: text)
        editing = false
    }
}

extension Repeat {
    /// English key for L().
    var label: String {
        switch self {
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

extension Color {
    /// "#RRGGBB"
    init(hex: String) {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Shared

struct IconButton: View {
    let name: String
    let action: () -> Void

    init(_ name: String, action: @escaping () -> Void) {
        self.name = name
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Only shown when something needs attention: an available update or a sync/update message.
struct NoticeBar: View {
    @EnvironmentObject var sync: SyncService
    @EnvironmentObject var reminders: ReminderSync
    let onSettings: () -> Void

    var body: some View {
        let messages = [sync.updateMessage, reminders.message].compactMap { $0 }
        if sync.updateAvailable || !messages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                ForEach(messages, id: \.self) { msg in
                    Text(msg).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture(perform: onSettings)
                }
                if sync.updateAvailable, let v = sync.latestVersion {
                    HStack {
                        Text(L("DayStack %@ is available", v)).font(.caption)
                        Spacer()
                        Button(L("Update")) { sync.installUpdate() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(sync.installing)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }
}

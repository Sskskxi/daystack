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
                    DayView(day: day) { screen = .calendar }
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
                    ForEach(todays) { t in
                        TodoRow(todo: t, compact: true)
                    }
                    if !earlier.isEmpty {
                        SectionHeader(title: L("Unfinished earlier"), detail: "\(earlier.count)", action: nil)
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

    var body: some View {
        HStack {
            Text(title).font(.caption.weight(.semibold))
            Spacer()
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
    let day: Date
    let onBack: () -> Void

    @State private var draft = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        let items = store.items(on: day)
        let doneCount = items.filter(\.done).count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                IconButton("chevron.left", action: onBack)
                Text(day.fmt(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.headline)
                if Day.cal.isDateInToday(day) {
                    Text(L("Today")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(doneCount) / \(items.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                TextField(L("Add a to-do…"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($addFocused)
                    .onSubmit(addDraft)
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
            }

            if items.isEmpty {
                Text(L("Nothing yet. Type above and press ⏎."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { TodoRow(todo: $0) }
                    }
                }
            }
        }
        .onAppear { DispatchQueue.main.async { addFocused = true } }
        .onExitCommand(perform: onBack)
    }

    private var isDraftEmpty: Bool { draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private func addDraft() {
        store.add(draft, on: day)
        draft = ""
        addFocused = true
    }
}

struct TodoRow: View {
    @EnvironmentObject var store: TodoStore
    let todo: Todo
    var compact = false
    var dateLabel: String? = nil
    var onOpenDay: (() -> Void)? = nil

    @State private var editing = false
    @State private var text = ""
    @State private var hover = false
    @State private var pickingTime = false
    @State private var pickedTime = Date()
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { store.toggle(todo.id) } label: {
                Image(systemName: todo.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: compact ? 12 : 14))
            }
            .buttonStyle(.plain)

            if let at = todo.alertDate, !editing {
                Label(at.fmt(.dateTime.hour().minute()), systemImage: "bell")
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

            // Stay visible while the popover is open, or it would lose its anchor and close.
            if (hover || pickingTime) && !editing {
                IconButton("clock", action: openTimePicker)
                    .help(L("Alert time"))
                    .popover(isPresented: $pickingTime, arrowEdge: .bottom) { timePopover }
                IconButton("pencil", action: beginEdit).help(L("Edit"))
                IconButton("trash") { store.delete(todo.id) }.help(L("Delete"))
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
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .onHover { hover = $0 }
    }

    private var timePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Alert time")).font(.headline)
            DatePicker("", selection: $pickedTime, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.field)
                .environment(\.locale, L10n.locale)
            HStack {
                if todo.time != nil {
                    Button(L("Remove")) {
                        store.setTime(todo.id, nil)
                        pickingTime = false
                    }
                }
                Spacer()
                Button(L("Set")) {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: pickedTime)
                    store.setTime(todo.id, TimeText.format(c.hour ?? 9, c.minute ?? 0))
                    pickingTime = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 180)
    }

    private func openTimePicker() {
        pickedTime = todo.alertDate ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        pickingTime = true
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

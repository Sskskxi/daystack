import SwiftUI

struct FriendsView: View {
    @EnvironmentObject var sync: SyncService
    let onBack: () -> Void
    let onOpen: (String) -> Void

    @State private var joinCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                IconButton("chevron.left", action: onBack)
                Text("Friends").font(.headline)
                Spacer()
                if sync.groupURL != nil {
                    IconButton("arrow.clockwise") { sync.refresh() }.help("Refresh")
                }
            }

            HStack {
                Text("Your name").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $sync.name).textFieldStyle(.roundedBorder)
            }

            if sync.groupURL == nil { setup } else { group }

            if let status = sync.status {
                Text(status)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { sync.refresh() }
        .onExitCommand(perform: onBack)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share your to-dos with friends through a shared iCloud Drive folder.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Create a group") { sync.createGroup() }
            Divider().padding(.vertical, 2)
            HStack {
                TextField("Invite code", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(join)
                Button("Join", action: join).disabled(joinCode.isEmpty || sync.busy)
            }
            Text("To join, first accept your friend's iCloud folder invite, then enter their code.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var group: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Invite code").font(.caption).foregroundStyle(.secondary)
                Text(sync.code ?? "……")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                IconButton("doc.on.doc") { sync.copyCode() }.help("Copy code")
                Spacer()
                Button("Share folder…") { sync.revealInFinder() }.font(.caption)
            }
            Text("To invite: in Finder, right-click the DayStack folder → Share → invite your friend. Then send them the code.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            if sync.friends.isEmpty {
                Text("No friends have joined yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sync.friends) { m in
                            FriendRow(member: m) { onOpen(m.id) }
                        }
                    }
                }
            }

            Button("Leave group") { sync.leave() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func join() {
        sync.join(code: joinCode)
    }
}

struct FriendRow: View {
    let member: Member
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let cal = Day.cal
        let today = cal.startOfDay(for: Date())
        let done = member.todos.doneByDay
        let todays = member.todos.on(today)

        Button(action: action) {
            HStack(spacing: 10) {
                Text(String(member.name.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.8)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(member.name).font(.system(size: 13, weight: .medium))
                    Text("Today \(todays.filter(\.done).count)/\(todays.count) · \(member.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { i in
                        let d = cal.date(byAdding: .day, value: i - 6, to: today)!
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Shade.fill(Shade.level(done[Day.key(d)] ?? 0)))
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct FriendView: View {
    let member: Member
    let onBack: () -> Void
    let onPick: (Date) -> Void

    @State private var month = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                IconButton("chevron.left", action: onBack)
                Text(member.name).font(.headline)
                Spacer()
                Text(month.formatted(.dateTime.year().month(.abbreviated)))
                    .font(.caption).foregroundStyle(.secondary)
                IconButton("chevron.left") { shift(-1) }
                IconButton("chevron.right") { shift(1) }
            }
            MonthGrid(month: month, done: member.todos.doneByDay, hasItems: member.todos.daysWithItems, onPick: onPick)
        }
        .onExitCommand(perform: onBack)
    }

    private func shift(_ months: Int) {
        month = Day.cal.date(byAdding: .month, value: months, to: month) ?? month
    }
}

struct FriendDayView: View {
    let member: Member
    let day: Date
    let onBack: () -> Void

    var body: some View {
        let items = member.todos.on(day)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                IconButton("chevron.left", action: onBack)
                Text("\(member.name) · \(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                    .font(.headline).lineLimit(1)
                Spacer()
                Text("\(items.filter(\.done).count) / \(items.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text("No to-dos this day.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { t in
                            HStack(spacing: 8) {
                                Image(systemName: t.done ? "checkmark.square.fill" : "square").font(.system(size: 14))
                                Text(t.title)
                                    .strikethrough(t.done)
                                    .foregroundStyle(t.done ? .secondary : .primary)
                                Spacer()
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .onExitCommand(perform: onBack)
    }
}

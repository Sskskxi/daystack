import DayStackCore
import ServiceManagement
import SwiftUI

// MARK: - Settings model

final class AppSettings: ObservableObject {
    struct HeatColor: Identifiable {
        let id: String
        let name: String
        /// nil for grey, which follows light/dark mode instead of a fixed color.
        let hex: String?

        var color: Color {
            guard let hex, let v = Int(hex.dropFirst(), radix: 16) else { return .primary }
            return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }
    }

    static let heatColors: [HeatColor] = [
        HeatColor(id: "grey", name: "Grey", hex: nil),
        HeatColor(id: "green", name: "Green", hex: "#21994D"),
        HeatColor(id: "blue", name: "Blue", hex: "#3373F2"),
        HeatColor(id: "purple", name: "Purple", hex: "#8C59E6"),
        HeatColor(id: "pink", name: "Pink", hex: "#ED4D8C"),
        HeatColor(id: "orange", name: "Orange", hex: "#F2801A"),
    ]

    @Published var heatColor: String {
        didSet { UserDefaults.standard.set(heatColor, forKey: "heatColor") }
    }

    /// 1 = Sunday, 2 = Monday.
    @Published var weekStart: Int {
        didSet {
            UserDefaults.standard.set(weekStart, forKey: "weekStart")
            Day.firstWeekday = weekStart
        }
    }

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            Self.applyLanguage(language)
        }
    }

    init() {
        let d = UserDefaults.standard
        heatColor = d.string(forKey: "heatColor") ?? "grey"
        weekStart = d.integer(forKey: "weekStart") == 1 ? 1 : 2
        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .auto
        Day.firstWeekday = weekStart
        Self.applyLanguage(language)
    }

    private static func applyLanguage(_ language: AppLanguage) {
        L10n.language = language
        Day.locale = L10n.locale
    }

    var tint: Color { Self.heatColors.first { $0.id == heatColor }?.color ?? .primary }

    var tintHex: String? { Self.heatColors.first { $0.id == heatColor }?.hex }

    /// Grey cells flip with light/dark mode, so their text must too; colored cells always read best in white.
    var strongText: Color { heatColor == "grey" ? Color(nsColor: .windowBackgroundColor) : .white }
}

// MARK: - Claude integration

enum ClaudeIntegration {
    enum Status: Equatable {
        case notInstalled, disconnected, connected, outdated
    }

    static var serverPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/daystack-mcp").path
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    // Claude Code

    private static var claudeCLI: String? {
        ["\(home.path)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home.path)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func codeStatus() -> Status {
        guard claudeCLI != nil else { return .notInstalled }
        let url = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = (json["mcpServers"] as? [String: Any])?["daystack"] as? [String: Any]
        else { return .disconnected }
        return entry["command"] as? String == serverPath ? .connected : .outdated
    }

    static func connectCode() throws {
        guard let cli = claudeCLI else { throw message(L("Claude Code isn't installed.")) }
        if codeStatus() != .disconnected {
            _ = try? run(cli, ["mcp", "remove", "--scope", "user", "daystack"])
        }
        try run(cli, ["mcp", "add", "--scope", "user", "daystack", "--", serverPath])
    }

    static func disconnectCode() throws {
        guard let cli = claudeCLI else { return }
        try run(cli, ["mcp", "remove", "--scope", "user", "daystack"])
    }

    // Claude Desktop

    private static var desktopConfig: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    private static var desktopInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: desktopConfig.deletingLastPathComponent().path)
    }

    private static func readDesktopConfig() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: desktopConfig.path) else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: desktopConfig)) as? [String: Any] else {
            throw message(L("Claude Desktop's config file isn't valid JSON, so it was left untouched."))
        }
        return json
    }

    private static func writeDesktopConfig(_ json: [String: Any]) throws {
        let backup = desktopConfig.appendingPathExtension("bak-daystack")
        if FileManager.default.fileExists(atPath: desktopConfig.path), !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: desktopConfig, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: desktopConfig, options: .atomic)
    }

    static func desktopStatus() -> Status {
        guard desktopInstalled else { return .notInstalled }
        guard let json = try? readDesktopConfig(),
              let entry = (json["mcpServers"] as? [String: Any])?["daystack"] as? [String: Any]
        else { return .disconnected }
        return entry["command"] as? String == serverPath ? .connected : .outdated
    }

    static func connectDesktop() throws {
        var json = try readDesktopConfig()
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        servers["daystack"] = ["command": serverPath, "args": [String]()]
        json["mcpServers"] = servers
        try writeDesktopConfig(json)
    }

    static func disconnectDesktop() throws {
        var json = try readDesktopConfig()
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: "daystack")
        json["mcpServers"] = servers
        try writeDesktopConfig(json)
    }

    // Helpers

    private static func message(_ text: String) -> NSError {
        NSError(domain: "DayStack", code: 3, userInfo: [NSLocalizedDescriptionKey: text])
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw message(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "claude exited with status \(p.terminationStatus)" : text)
        }
        return text
    }
}

// MARK: - Settings screen

struct SettingsView: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sync: SyncService
    @EnvironmentObject var reminders: ReminderSync
    @EnvironmentObject var widget: WidgetExport
    let onBack: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var codeStatus = ClaudeIntegration.Status.disconnected
    @State private var desktopStatus = ClaudeIntegration.Status.disconnected
    @State private var claudeMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                IconButton("chevron.left", action: onBack)
                Text(L("Settings")).font(.headline)
                Spacer()
            }

            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            section(L("Calendar")) {
                row(L("Heatmap color")) {
                    HStack(spacing: 6) {
                        ForEach(AppSettings.heatColors) { c in
                            Button { settings.heatColor = c.id } label: {
                                Circle()
                                    .fill(c.color)
                                    .frame(width: 16, height: 16)
                                    .padding(2)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(settings.heatColor == c.id ? 0.9 : 0), lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .help(L(c.name))
                        }
                    }
                }
                row(L("Week starts on")) {
                    Picker("", selection: $settings.weekStart) {
                        Text(L("Monday")).tag(2)
                        Text(L("Sunday")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
                row(L("Language")) {
                    Picker("", selection: $settings.language) {
                        Text(L("Auto")).tag(AppLanguage.auto)
                        Text("English").tag(AppLanguage.en)
                        Text("한국어").tag(AppLanguage.ko)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                }
            }

            section(L("Categories")) {
                ForEach(store.categories) { c in
                    CategoryEditRow(category: c)
                }
                Button {
                    store.addCategory()
                } label: {
                    Label(L("Add category"), systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                note(L("Click the dot to change its color. Type #name in a to-do to file it. Deleting a category keeps its to-dos."))
            }

            section(L("Alerts")) {
                row(L("Sync with Reminders")) {
                    Toggle("", isOn: Binding(get: { reminders.enabled }, set: { reminders.setEnabledByUser($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                note(L("Give a to-do a time (\"3pm\", \"15:00\", \"오후 3시\") or use the clock button. It becomes a reminder in a \"DayStack\" list that rings on your Mac and iPhone. Setting a time turns this on automatically."))
                if !reminders.enabled {
                    note(L("Off: to-do times are shown but nothing rings."))
                }
            }

            section(L("General")) {
                row(L("Open at login")) {
                    Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .onChange(of: launchAtLogin) { on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                NSLog("DayStack: launch-at-login change failed: \(error)")
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
                row(L("iPhone widget")) {
                    if widget.available {
                        Label(L("Ready"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L("Needs Scriptable")).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                note(widget.available
                     ? L("On your iPhone: add a Scriptable widget, long-press it → Edit Widget → Script: DayStack.")
                     : L("Install the free Scriptable app on your iPhone (iCloud on), then come back here."))
            }

            section(L("Keyboard shortcuts")) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(ShortcutList.items, id: \.keys) { item in
                        HStack {
                            Text(L(item.what)).font(.system(size: 11))
                            Spacer()
                            Text(item.keys).font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            section("Claude") {
                claudeRow("Claude Code", status: codeStatus,
                          connect: ClaudeIntegration.connectCode, disconnect: ClaudeIntegration.disconnectCode)
                claudeRow("Claude Desktop", status: desktopStatus,
                          connect: ClaudeIntegration.connectDesktop, disconnect: ClaudeIntegration.disconnectDesktop)
                note(claudeMessage ?? L("Lets Claude add and edit your to-dos, e.g. \"add a plan: gym tomorrow 7pm\"."))
            }
            }
            .padding(.trailing, 4)
            }

            Divider()
            HStack {
                Text("DayStack v\(SyncService.currentVersion)").font(.caption).foregroundStyle(.secondary)
                if sync.updateAvailable, let v = sync.latestVersion {
                    Button(L("Update to %@", v)) { sync.installUpdate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(sync.installing)
                } else {
                    Button(sync.checking ? L("Checking…") : L("Check for updates")) { sync.checkForUpdates() }
                        .controlSize(.small)
                        .disabled(sync.checking)
                }
                Spacer()
                Button(L("Quit DayStack")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .controlSize(.small)
            }
        }
        .onAppear(perform: refreshClaude)
        .onExitCommand(perform: onBack)
    }

    private func refreshClaude() {
        codeStatus = ClaudeIntegration.codeStatus()
        desktopStatus = ClaudeIntegration.desktopStatus()
    }

    @ViewBuilder
    private func claudeRow(_ name: String, status: ClaudeIntegration.Status,
                           connect: @escaping () throws -> Void, disconnect: @escaping () throws -> Void) -> some View {
        row(name) {
            HStack(spacing: 6) {
                switch status {
                case .notInstalled:
                    Text(L("Not installed")).font(.caption).foregroundStyle(.tertiary)
                case .connected:
                    Label(L("Connected"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Button(L("Disconnect")) { perform(disconnect, done: nil) }.controlSize(.small)
                case .outdated:
                    Button(L("Reconnect")) { perform(connect, done: name == "Claude Desktop" ? L("Restart Claude Desktop to apply.") : nil) }
                        .controlSize(.small)
                        .help(L("DayStack moved since it was connected"))
                case .disconnected:
                    Button(L("Connect")) { perform(connect, done: name == "Claude Desktop" ? L("Connected. Restart Claude Desktop to apply.") : L("Connected. Start a new Claude Code session to use it.")) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void, done: String?) {
        do {
            try action()
            claudeMessage = done
        } catch {
            claudeMessage = L("Couldn't update Claude: %@", error.localizedDescription)
        }
        refreshClaude()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            content()
        }
        .frame(minHeight: 22)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Name, color and delete for one category in Settings.
struct CategoryEditRow: View {
    @EnvironmentObject var store: TodoStore
    let category: TodoCategory
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            Button {
                let p = TodoCategory.palette
                let next = p[((p.firstIndex(of: category.color) ?? -1) + 1) % p.count]
                store.updateCategory(TodoCategory(id: category.id, name: category.name, color: next))
            } label: {
                Circle().fill(Color(hex: category.color)).frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            TextField("", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(save)
                .onChange(of: name) { _ in save() }
            IconButton("trash") { store.deleteCategory(category.id) }
                .foregroundStyle(.secondary)
                .help(L("Delete"))
        }
        .frame(minHeight: 22)
        .onAppear { name = category.name }
    }

    private func save() {
        guard name.trimmingCharacters(in: .whitespaces) != category.name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.updateCategory(TodoCategory(id: category.id, name: name, color: category.color))
    }
}

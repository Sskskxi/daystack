import DayStackCore
import ServiceManagement
import SwiftUI

// MARK: - Settings model

final class AppSettings: ObservableObject {
    struct HeatColor: Identifiable {
        let id: String
        let name: String
        let color: Color
    }

    static let heatColors: [HeatColor] = [
        HeatColor(id: "grey", name: "Grey", color: .primary),
        HeatColor(id: "green", name: "Green", color: Color(red: 0.13, green: 0.6, blue: 0.3)),
        HeatColor(id: "blue", name: "Blue", color: Color(red: 0.2, green: 0.45, blue: 0.95)),
        HeatColor(id: "purple", name: "Purple", color: Color(red: 0.55, green: 0.35, blue: 0.9)),
        HeatColor(id: "pink", name: "Pink", color: Color(red: 0.93, green: 0.3, blue: 0.55)),
        HeatColor(id: "orange", name: "Orange", color: Color(red: 0.95, green: 0.5, blue: 0.1)),
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

    init() {
        let d = UserDefaults.standard
        heatColor = d.string(forKey: "heatColor") ?? "grey"
        weekStart = d.integer(forKey: "weekStart") == 1 ? 1 : 2
        Day.firstWeekday = weekStart
    }

    var tint: Color { Self.heatColors.first { $0.id == heatColor }?.color ?? .primary }

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
        guard let cli = claudeCLI else { throw message("Claude Code isn't installed.") }
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
            throw message("Claude Desktop's config file isn't valid JSON, so it was left untouched.")
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
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sync: SyncService
    @EnvironmentObject var reminders: ReminderSync
    let onBack: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var codeStatus = ClaudeIntegration.Status.disconnected
    @State private var desktopStatus = ClaudeIntegration.Status.disconnected
    @State private var claudeMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                IconButton("chevron.left", action: onBack)
                Text("Settings").font(.headline)
                Spacer()
            }

            section("Calendar") {
                row("Heatmap color") {
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
                            .help(c.name)
                        }
                    }
                }
                row("Week starts on") {
                    Picker("", selection: $settings.weekStart) {
                        Text("Monday").tag(2)
                        Text("Sunday").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            section("General") {
                row("Open at login") {
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
                row("Sync with Reminders") {
                    Toggle("", isOn: $reminders.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                note("Two-way sync with a \"DayStack\" list in Apple Reminders, on your iPhone too.")
            }

            section("Claude") {
                claudeRow("Claude Code", status: codeStatus,
                          connect: ClaudeIntegration.connectCode, disconnect: ClaudeIntegration.disconnectCode)
                claudeRow("Claude Desktop", status: desktopStatus,
                          connect: ClaudeIntegration.connectDesktop, disconnect: ClaudeIntegration.disconnectDesktop)
                note(claudeMessage ?? "Lets Claude add and edit your to-dos, e.g. \"add a plan: gym tomorrow 7pm\".")
            }

            Spacer(minLength: 0)
            Divider()
            HStack {
                Text("DayStack v\(SyncService.currentVersion)").font(.caption).foregroundStyle(.secondary)
                if sync.updateAvailable, let v = sync.latestVersion {
                    Button("Update to \(v)") { sync.installUpdate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(sync.installing)
                }
                Spacer()
                Button("Quit DayStack") { NSApp.terminate(nil) }
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
                    Text("Not installed").font(.caption).foregroundStyle(.tertiary)
                case .connected:
                    Label("Connected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Button("Disconnect") { perform(disconnect, done: nil) }.controlSize(.small)
                case .outdated:
                    Button("Reconnect") { perform(connect, done: name == "Claude Desktop" ? "Restart Claude Desktop to apply." : nil) }
                        .controlSize(.small)
                        .help("DayStack moved since it was connected")
                case .disconnected:
                    Button("Connect") { perform(connect, done: name == "Claude Desktop" ? "Connected. Restart Claude Desktop to apply." : "Connected. Start a new Claude Code session to use it.") }
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
            claudeMessage = "Couldn't update Claude: \(error.localizedDescription)"
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

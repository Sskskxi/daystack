import AppKit
import Combine
import Foundation

struct Member: Codable, Identifiable {
    var id: String
    var name: String
    var updatedAt: Date
    var todos: [Todo]
}

struct GroupInfo: Codable {
    var code: String
    var createdAt: Date
}

// Each member writes only their own members/<id>.json, so iCloud never has to merge conflicting edits.
@MainActor
final class SyncService: ObservableObject {
    @Published private(set) var groupURL: URL?
    @Published private(set) var code: String?
    @Published private(set) var friends: [Member] = []
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var updateMessage: String?
    @Published private(set) var installing = false
    @Published var name: String {
        didSet { UserDefaults.standard.set(name, forKey: "displayName") }
    }

    let memberId: String
    private let store: TodoStore
    private var bag = Set<AnyCancellable>()
    private let fm = FileManager.default

    static var iCloudRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    init(store: TodoStore) {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "memberId") {
            memberId = id
        } else {
            memberId = UUID().uuidString
            defaults.set(memberId, forKey: "memberId")
        }
        name = defaults.string(forKey: "displayName") ?? NSFullUserName()
        self.store = store

        if let path = defaults.string(forKey: "groupPath"), fm.fileExists(atPath: path) {
            groupURL = URL(fileURLWithPath: path, isDirectory: true)
        }

        store.$todos
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &bag)

        $name
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &bag)

        Timer.publish(every: 20, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)

        publish()
        refresh()
    }

    private var membersDir: URL? { groupURL?.appendingPathComponent("members", isDirectory: true) }

    func createGroup() {
        guard ensureICloud() else { return }
        let code = Self.makeCode()
        let dir = Self.iCloudRoot.appendingPathComponent("DayStack-\(code)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir.appendingPathComponent("members"), withIntermediateDirectories: true)
            try JSONEncoder().encode(GroupInfo(code: code, createdAt: Date()))
                .write(to: dir.appendingPathComponent("group.json"), options: .atomic)
            status = nil
            connect(dir, code: code)
        } catch {
            status = "Couldn't create the group folder: \(error.localizedDescription)"
        }
    }

    func join(code raw: String) {
        let code = raw.uppercased().filter { !$0.isWhitespace }
        guard !busy, !code.isEmpty, ensureICloud() else { return }
        busy = true
        status = "Looking for the shared folder…"
        Task {
            // Freshly accepted shares may still be placeholders, so give iCloud a few seconds to download group.json.
            for _ in 0..<8 {
                if let dir = findGroup(code) {
                    busy = false
                    status = nil
                    connect(dir, code: code)
                    return
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            busy = false
            status = "No shared folder with code \(code) found. Accept your friend's iCloud folder invite first, then try again."
        }
    }

    func leave() {
        if let dir = membersDir {
            try? fm.removeItem(at: dir.appendingPathComponent("\(memberId).json"))
        }
        groupURL = nil
        code = nil
        friends = []
        status = nil
        UserDefaults.standard.removeObject(forKey: "groupPath")
    }

    func publish() {
        guard let group = groupURL, let dir = membersDir else { return }
        guard fm.fileExists(atPath: group.path) else {
            status = "The shared group folder is gone (deleted or no longer shared). Leave the group and join again."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let me = Member(id: memberId, name: trimmed.isEmpty ? "Me" : trimmed, updatedAt: Date(), todos: store.todos)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(me).write(to: dir.appendingPathComponent("\(memberId).json"), options: .atomic)
        } catch {
            status = "Couldn't save to the shared folder: \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard let group = groupURL, let dir = membersDir else { return }
        if code == nil { code = readGroup(group)?.code }

        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var found: [Member] = []
        for file in files {
            if file.hasPrefix("."), file.hasSuffix(".icloud") {
                let real = String(file.dropFirst().dropLast(".icloud".count))
                try? fm.startDownloadingUbiquitousItem(at: dir.appendingPathComponent(real))
                continue
            }
            guard file.hasSuffix(".json"), file != "\(memberId).json",
                  let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let member = try? JSONDecoder().decode(Member.self, from: data)
            else { continue }
            found.append(member)
        }
        friends = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        checkForUpdate(group)
    }

    // MARK: - Updates

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    var updateAvailable: Bool {
        guard let latestVersion else { return false }
        return latestVersion.compare(Self.currentVersion, options: .numeric) == .orderedDescending
    }

    private struct VersionInfo: Codable { var version: String }

    private func checkForUpdate(_ group: URL) {
        let updates = group.appendingPathComponent("updates", isDirectory: true)
        let file = updates.appendingPathComponent("version.json")
        if !fm.fileExists(atPath: file.path) {
            try? fm.startDownloadingUbiquitousItem(at: file)
            return
        }
        guard let data = try? Data(contentsOf: file),
              let info = try? JSONDecoder().decode(VersionInfo.self, from: data) else { return }
        latestVersion = info.version
        if updateAvailable {
            try? fm.startDownloadingUbiquitousItem(at: updates.appendingPathComponent("DayStack.zip"))
        }
    }

    func installUpdate() {
        guard let group = groupURL, !installing else { return }
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else {
            updateMessage = "Updates only work when running DayStack.app."
            return
        }
        let zip = group.appendingPathComponent("updates/DayStack.zip")
        guard fm.fileExists(atPath: zip.path) else {
            try? fm.startDownloadingUbiquitousItem(at: zip)
            updateMessage = "Downloading the update from iCloud… try again in a moment."
            return
        }

        installing = true
        updateMessage = "Installing update…"
        do {
            let tmp = fm.temporaryDirectory.appendingPathComponent("DayStack-update-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path])
            let newApp = tmp.appendingPathComponent("DayStack.app")
            guard fm.fileExists(atPath: newApp.path) else {
                throw NSError(domain: "DayStack", code: 1, userInfo: [NSLocalizedDescriptionKey: "The update package is incomplete."])
            }
            try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            _ = try fm.replaceItemAt(current, withItemAt: newApp)

            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", current.path]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            installing = false
            updateMessage = "Update failed: \(error.localizedDescription)"
        }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "DayStack", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) exited with status \(p.terminationStatus)"])
        }
    }

    func revealInFinder() {
        guard let g = groupURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([g])
    }

    func copyCode() {
        guard let code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func connect(_ dir: URL, code: String) {
        groupURL = dir
        self.code = code
        UserDefaults.standard.set(dir.path, forKey: "groupPath")
        publish()
        refresh()
    }

    private func findGroup(_ code: String) -> URL? {
        var candidates: [URL] = []
        for top in subdirectories(of: Self.iCloudRoot) {
            candidates.append(top)
            candidates += subdirectories(of: top)
        }
        return candidates.first { readGroup($0)?.code == code }
    }

    private func subdirectories(of url: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func readGroup(_ dir: URL) -> GroupInfo? {
        let file = dir.appendingPathComponent("group.json")
        if !fm.fileExists(atPath: file.path) {
            if fm.fileExists(atPath: dir.appendingPathComponent(".group.json.icloud").path) {
                try? fm.startDownloadingUbiquitousItem(at: file)
            }
            return nil
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(GroupInfo.self, from: data)
    }

    private func ensureICloud() -> Bool {
        if fm.fileExists(atPath: Self.iCloudRoot.path) { return true }
        status = "iCloud Drive is off. Turn it on in System Settings → Apple Account → iCloud → iCloud Drive."
        return false
    }

    private static func makeCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}

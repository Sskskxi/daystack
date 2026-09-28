import AppKit
import Combine
import CryptoKit
import DayStackCore
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
    @Published private(set) var lastRefresh: Date?
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
            status = L("Couldn't create the group folder: %@", error.localizedDescription)
        }
    }

    func join(code raw: String) {
        let code = raw.uppercased().filter { !$0.isWhitespace }
        guard !busy, !code.isEmpty, ensureICloud() else { return }
        busy = true
        status = L("Looking for the shared folder…")
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
            status = L("No shared folder with code %@ found. Accept your friend's iCloud folder invite first, then try again.", code)
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
            status = L("The shared group folder is gone (deleted or no longer shared). Leave the group and join again.")
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let me = Member(id: memberId, name: trimmed.isEmpty ? "Me" : trimmed, updatedAt: Date(), todos: store.todos)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(me).write(to: dir.appendingPathComponent("\(memberId).json"), options: .atomic)
        } catch {
            status = L("Couldn't save to the shared folder: %@", error.localizedDescription)
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
            guard file.hasSuffix(".json"), file != "\(memberId).json" else { continue }
            let url = dir.appendingPathComponent(file)
            try? fm.startDownloadingUbiquitousItem(at: url)
            guard let data = readSmallFile(url),
                  let member = try? JSONDecoder().decode(Member.self, from: data),
                  "\(member.id).json" == file
            else { continue }
            found.append(Self.sanitized(member))
        }
        friends = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastRefresh = Date()
        checkForUpdate(group)
    }

    // MARK: - Friends' data (untrusted)

    /// Anyone in the group can write to the shared folder, so cap what we read from it.
    private func readSmallFile(_ url: URL, limit: Int = 2_000_000) -> Data? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func sanitized(_ m: Member) -> Member {
        var m = m
        m.name = String(m.name.prefix(40))
        m.todos = m.todos.prefix(5000).map { t in
            var t = t
            t.title = String(t.title.prefix(300))
            return t
        }
        return m
    }

    // MARK: - Updates

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// Only updates signed with the publisher's private key (see scripts/sign-update.swift) are installed.
    private static let updatePublicKey: Curve25519.Signing.PublicKey? = {
        guard let b64 = Bundle.main.object(forInfoDictionaryKey: "DSUpdatePublicKey") as? String,
              let raw = Data(base64Encoded: b64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }()

    var updateAvailable: Bool {
        guard let latestVersion else { return false }
        return Self.isNewer(latestVersion)
    }

    private static func isNewer(_ version: String) -> Bool {
        version.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    private struct VersionInfo: Codable {
        var version: String
        var signature: String?
    }

    private func readVersionInfo(_ updates: URL) -> VersionInfo? {
        guard let data = readSmallFile(updates.appendingPathComponent("version.json"), limit: 10_000) else { return nil }
        return try? JSONDecoder().decode(VersionInfo.self, from: data)
    }

    private func checkForUpdate(_ group: URL) {
        let updates = group.appendingPathComponent("updates", isDirectory: true)
        let file = updates.appendingPathComponent("version.json")
        if !fm.fileExists(atPath: file.path) {
            try? fm.startDownloadingUbiquitousItem(at: file)
            return
        }
        // Unsigned announcements are ignored outright, so nobody can make the button appear with a fake file.
        guard Self.updatePublicKey != nil, let info = readVersionInfo(updates), info.signature != nil else {
            latestVersion = nil
            return
        }
        latestVersion = info.version
        if updateAvailable {
            try? fm.startDownloadingUbiquitousItem(at: updates.appendingPathComponent("DayStack.zip"))
        }
    }

    func installUpdate() {
        guard let group = groupURL, !installing else { return }
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else {
            updateMessage = L("Updates only work when running DayStack.app.")
            return
        }
        let updates = group.appendingPathComponent("updates", isDirectory: true)
        let zip = updates.appendingPathComponent("DayStack.zip")
        guard fm.fileExists(atPath: zip.path) else {
            try? fm.startDownloadingUbiquitousItem(at: zip)
            updateMessage = L("Downloading the update from iCloud… try again in a moment.")
            return
        }

        installing = true
        updateMessage = L("Installing update…")
        do {
            // Verify the exact bytes we then unpack, so the file can't be swapped between check and use.
            guard let key = Self.updatePublicKey,
                  let info = readVersionInfo(updates),
                  let sig = info.signature.flatMap({ Data(base64Encoded: $0) }),
                  let zipData = readSmallFile(zip, limit: 200_000_000),
                  key.isValidSignature(sig, for: zipData)
            else {
                throw Self.error(L("This update isn't signed by the DayStack publisher, so it wasn't installed. If it was just published, it may still be syncing; try again in a minute."))
            }

            let tmp = fm.temporaryDirectory.appendingPathComponent("DayStack-update-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let verifiedZip = tmp.appendingPathComponent("update.zip")
            try zipData.write(to: verifiedZip)
            let unpacked = tmp.appendingPathComponent("unpacked", isDirectory: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", verifiedZip.path, unpacked.path])

            let newApp = unpacked.appendingPathComponent("DayStack.app")
            let isLink = (try? newApp.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? true
            guard fm.fileExists(atPath: newApp.path), !isLink,
                  let plist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
                  plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  let newVersion = plist["CFBundleShortVersionString"] as? String
            else {
                throw Self.error(L("The update package is incomplete."))
            }
            // Refuse downgrades: an old (validly signed) build could reintroduce fixed bugs.
            guard Self.isNewer(newVersion) else {
                throw Self.error(L("This update is not newer than the installed version."))
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
            updateMessage = L("Update failed: %@", error.localizedDescription)
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "DayStack", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
        guard let data = readSmallFile(file, limit: 10_000) else { return nil }
        return try? JSONDecoder().decode(GroupInfo.self, from: data)
    }

    private func ensureICloud() -> Bool {
        if fm.fileExists(atPath: Self.iCloudRoot.path) { return true }
        status = L("iCloud Drive is off. Turn it on in System Settings → Apple Account → iCloud → iCloud Drive.")
        return false
    }

    private static func makeCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}

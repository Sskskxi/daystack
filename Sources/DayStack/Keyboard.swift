import AppKit
import SwiftUI

/// A key press in the DayStack window.
struct Key {
    static let returnKey: UInt16 = 36
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let forwardDelete: UInt16 = 117
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126

    struct Mods: OptionSet {
        let rawValue: Int
        static let cmd = Mods(rawValue: 1)
        static let shift = Mods(rawValue: 2)
        static let option = Mods(rawValue: 4)
    }

    let code: UInt16
    /// Lowercased, ignoring modifiers.
    let chars: String
    let mods: Mods
    /// A text field has focus, so plain keys belong to it.
    let editingText: Bool

    var cmd: Bool { mods.contains(.cmd) }
    var shift: Bool { mods.contains(.shift) }
    var option: Bool { mods.contains(.option) }
    var plain: Bool { mods.isEmpty }

    /// Exactly these modifiers and this character.
    func `is`(_ char: String, _ mods: Mods = []) -> Bool { chars == char && self.mods == mods }

    func `is`(_ code: UInt16, _ mods: Mods = []) -> Bool { self.code == code && self.mods == mods }
}

/// One key monitor for the whole window: app-wide shortcuts first, then whichever screen is showing.
final class KeyRouter: ObservableObject {
    private var monitor: Any?
    private var owner: UUID?
    private var screen: ((Key) -> Bool)?

    func install(global: @escaping (Key) -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Popovers (time and date pickers) handle their own keys.
            guard let self, let window = event.window, !String(describing: type(of: window)).contains("Popover") else { return event }
            var mods: Key.Mods = []
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) { mods.insert(.cmd) }
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.option) { mods.insert(.option) }
            if flags.contains(.control) { return event }
            let key = Key(code: event.keyCode,
                          chars: (event.charactersIgnoringModifiers ?? "").lowercased(),
                          mods: mods,
                          editingText: window.firstResponder is NSText)
            if self.screen?(key) == true || global(key) { return nil }
            return event
        }
    }

    /// Screens appear before the previous one disappears, so each removes only its own handler.
    func set(_ owner: UUID, _ handler: @escaping (Key) -> Bool) {
        self.owner = owner
        screen = handler
    }

    func clear(_ owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        screen = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// Shown in Settings. English keys for L().
enum ShortcutList {
    static let items: [(keys: String, what: String)] = [
        ("⌘N", "New to-do"),
        ("⌘T", "Go to today"),
        ("⌘← ⌘→", "Previous / next day or month"),
        ("↑ ↓", "Select a to-do"),
        ("Space  ⌘D", "Check / uncheck"),
        ("⏎  ⌘E", "Edit"),
        ("⌘⌫", "Delete"),
        ("⌘]", "Postpone a day"),
        ("⇧⌘T", "Move to today"),
        ("⇧⌘D", "Choose date…"),
        ("⇧⌘A", "Alert time…"),
        ("⌘I", "Mark important"),
        ("⌘1–9  ⌘0", "Set category / none"),
        ("⌘Z  ⇧⌘Z", "Undo / redo"),
        ("⌘,", "Settings"),
        ("Esc", "Back"),
        ("⌘W  ⌘Q", "Close / quit"),
    ]
}

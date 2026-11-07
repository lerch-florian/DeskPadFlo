import Carbon
import Cocoa
import ReSwift

// A global keyboard shortcut: a virtual key code plus Carbon modifier flags (the form
// RegisterEventHotKey takes).
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    // "⌃⌥⇧⌘H", in the order macOS shows modifiers.
    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (Shortcut.specialKeyNames[keyCode] ?? Shortcut.printableKey(for: keyCode)?.uppercased() ?? "Key \(keyCode)")
    }

    // The character for a menu item's key equivalent, if the key has one.
    var menuKeyEquivalent: String? {
        Shortcut.specialKeyNames[keyCode] == nil ? Shortcut.printableKey(for: keyCode)?.lowercased() : nil
    }

    var isFunctionKey: Bool { Shortcut.functionKeyCodes.contains(keyCode) }

    // Keys with a fixed name, regardless of keyboard layout.
    private static let specialKeyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        for (number, code) in functionKeyCodes.enumerated() {
            names[code] = "F\(number + 1)"
        }
        return names
    }()

    // F1...F20, in order.
    private static let functionKeyCodes: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    // What the key types on the current keyboard layout.
    private static func printableKey(for keyCode: UInt32) -> String? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

// The shortcuts the user can change.
enum ShortcutKind: String, CaseIterable {
    case emergencyReset
    case dragEntry

    var title: String {
        switch self {
        case .emergencyReset: return "Move cursor to main screen"
        case .dragEntry: return "Send dragged window into the screen"
        }
    }

    var detail: String {
        switch self {
        case .emergencyReset: return "Works anywhere, e.g. if the cursor is ever stuck on the virtual screen."
        case .dragEntry: return "Click to Enter mode: press while dragging a window over the preview."
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .emergencyReset: return Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | optionKey | shiftKey))
        case .dragEntry: return Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | shiftKey))
        }
    }
}

enum ShortcutsAction: Action {
    case set(ShortcutKind, Shortcut)
    case reset(ShortcutKind)
}

struct ShortcutsState: Equatable {
    var emergencyReset: Shortcut
    var dragEntry: Shortcut

    subscript(kind: ShortcutKind) -> Shortcut {
        get {
            switch kind {
            case .emergencyReset: return emergencyReset
            case .dragEntry: return dragEntry
            }
        }
        set {
            switch kind {
            case .emergencyReset: emergencyReset = newValue
            case .dragEntry: dragEntry = newValue
            }
        }
    }

    // Remembered between launches (UserDefaults); the defaults apply until one is changed.
    static var initialState: ShortcutsState {
        var state = ShortcutsState(emergencyReset: ShortcutKind.emergencyReset.defaultShortcut, dragEntry: ShortcutKind.dragEntry.defaultShortcut)
        for kind in ShortcutKind.allCases {
            if let stored = UserDefaults.standard.array(forKey: defaultsKey(kind)) as? [Int], stored.count == 2 {
                state[kind] = Shortcut(keyCode: UInt32(stored[0]), modifiers: UInt32(stored[1]))
            }
        }
        return state
    }

    func save() {
        for kind in ShortcutKind.allCases {
            let shortcut = self[kind]
            if shortcut == kind.defaultShortcut {
                UserDefaults.standard.removeObject(forKey: ShortcutsState.defaultsKey(kind))
            } else {
                UserDefaults.standard.set([Int(shortcut.keyCode), Int(shortcut.modifiers)], forKey: ShortcutsState.defaultsKey(kind))
            }
        }
    }

    private static func defaultsKey(_ kind: ShortcutKind) -> String { "shortcut.\(kind.rawValue)" }

    enum Validation: Equatable {
        case valid
        case rejected(String)
    }

    // Global shortcuts need care: one without a modifier would swallow ordinary typing system-wide,
    // and a few belong to macOS itself.
    func validate(_ shortcut: Shortcut, for kind: ShortcutKind) -> Validation {
        let usableModifiers = UInt32(cmdKey | controlKey | optionKey)
        if shortcut.modifiers & usableModifiers == 0, shortcut.isFunctionKey == false {
            return .rejected("Include ⌘, ⌃ or ⌥ (or use a function key), otherwise it would catch normal typing.")
        }
        let reserved: [(UInt32, Int)] = [
            (UInt32(cmdKey), kVK_ANSI_Q), (UInt32(cmdKey), kVK_ANSI_W), (UInt32(cmdKey), kVK_ANSI_H),
            (UInt32(cmdKey), kVK_ANSI_M), (UInt32(cmdKey), kVK_Tab), (UInt32(cmdKey), kVK_Space),
            (UInt32(cmdKey), kVK_ANSI_Grave), (UInt32(cmdKey | optionKey), kVK_Escape),
        ]
        if reserved.contains(where: { $0.0 == shortcut.modifiers && UInt32($0.1) == shortcut.keyCode }) {
            return .rejected("\(shortcut.displayString) is reserved by macOS.")
        }
        for other in ShortcutKind.allCases where other != kind && self[other] == shortcut {
            return .rejected("\(shortcut.displayString) is already used for “\(other.title)”.")
        }
        return .valid
    }
}

func shortcutsReducer(action: Action, state: ShortcutsState) -> ShortcutsState {
    var state = state
    switch action {
    case let ShortcutsAction.set(kind, shortcut):
        state[kind] = shortcut

    case let ShortcutsAction.reset(kind):
        state[kind] = kind.defaultShortcut

    default:
        break
    }
    return state
}

// Saves the shortcuts and re-registers the global one whenever a shortcut changes. (The
// drag shortcut is registered only during a drag, with whatever is current at that moment.)
func shortcutsSideEffect() -> SideEffect {
    return { action, _, getState in
        guard action is ShortcutsAction, let shortcuts = getState()?.shortcutsState else { return }
        shortcuts.save()
        updateEmergencyHotKey(shortcuts.emergencyReset)
    }
}

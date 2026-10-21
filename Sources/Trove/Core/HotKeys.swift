import AppKit
import Combine
import Carbon.HIToolbox

struct KeyCombo: Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, shiftKey, optionKey, controlKey).
    var modifiers: UInt32

    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    var displayString: String {
        var out = ""
        if modifiers & KeyCombo.control != 0 { out += "⌃" }
        if modifiers & KeyCombo.option != 0 { out += "⌥" }
        if modifiers & KeyCombo.shift != 0 { out += "⇧" }
        if modifiers & KeyCombo.command != 0 { out += "⌘" }
        out += KeyCodeNames.name(for: keyCode)
        return out
    }

    var encoded: String { "\(keyCode):\(modifiers)" }

    static func decode(_ string: String) -> KeyCombo? {
        guard !string.isEmpty else { return nil }
        let parts = string.split(separator: ":")
        guard parts.count == 2,
              let keyCode = UInt32(parts[0]),
              let modifiers = UInt32(parts[1]) else { return nil }
        return KeyCombo(keyCode: keyCode, modifiers: modifiers)
    }
}

enum KeyCodeNames {
    private static let map: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "Esc", 36: "↩", 76: "⌤",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4",
        119: "End", 120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→",
        125: "↓", 126: "↑",
    ]

    static func name(for keyCode: UInt32) -> String {
        map[keyCode] ?? "Key \(keyCode)"
    }
}

/// Registers system-wide hot keys through Carbon.
@MainActor
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    enum Action: UInt32, CaseIterable {
        case activate = 1
        case quickPaste = 2
        case pasteStack = 3
        case plainText = 4
        case nextPinboard = 5
        case previousPinboard = 6
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private(set) var registrations: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x54525645 // 'TRVE'
    @Published private(set) var conflicts: [String] = []

    func install() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return noErr }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                HotKeyCenter.shared.fire(id)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &eventHandler)
    }

    private func fire(_ id: UInt32) {
        handlers[id]?()
    }

    func setHandler(for action: Action, _ handler: @escaping () -> Void) {
        handlers[action.rawValue] = handler
    }

    @discardableResult
    func register(_ action: Action, combo: KeyCombo?) -> Bool {
        unregister(action)
        guard let combo else { return false }
        install()
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr, let hotKeyRef {
            registrations[action.rawValue] = hotKeyRef
            return true
        }
        return false
    }

    func unregister(_ action: Action) {
        if let ref = registrations.removeValue(forKey: action.rawValue) {
            UnregisterEventHotKey(ref)
        }
    }

    /// Registers every configured shortcut and reports the outcome, so a
    /// silently rejected combination (already owned by another app) is visible.
    @discardableResult
    func applyAndReport(from prefs: Preferences) -> [(Action, String, Bool)] {
        var report: [(Action, String, Bool)] = []
        let plans: [(Action, String)] = [
            (.activate, prefs.activateShortcut),
            (.quickPaste, prefs.quickPasteShortcut),
            (.pasteStack, prefs.pasteStackShortcut),
            (.plainText, prefs.plainTextShortcut),
            (.nextPinboard, prefs.nextPinboardShortcut),
            (.previousPinboard, prefs.previousPinboardShortcut),
        ]
        for (action, encoded) in plans {
            guard let combo = KeyCombo.decode(encoded) else {
                register(action, combo: nil)
                report.append((action, "disabled", true))
                continue
            }
            let ok = register(action, combo: combo)
            report.append((action, combo.displayString, ok))
        }
        return report
    }

    func unregisterAll() {
        for action in Action.allCases { unregister(action) }
    }

    func apply(from prefs: Preferences) {
        conflicts = applyAndReport(from: prefs).compactMap { _, combo, accepted in accepted ? nil : combo }
    }
}

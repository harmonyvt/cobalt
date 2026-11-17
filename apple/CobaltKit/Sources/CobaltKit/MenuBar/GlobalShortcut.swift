import Foundation

/// A key combination the Mac app listens for in every app ("paste from anywhere", settings). The key is kept as
/// its hardware code, which is what the system registers, plus the name it was recorded under for the row.
public struct GlobalShortcut: Codable, Equatable, Sendable {
    public struct Modifiers: OptionSet, Codable, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers
    /// What the key is called in the row: "V", "F5", "space".
    public var key: String

    public init(keyCode: UInt16, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// "⌃⌥⌘V", the modifiers in the order the system's menus draw them.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }

    /// A plain key, or shift and a key, would take that key away from typing in every app. A function key is the
    /// one key that can stand alone.
    public var isUsable: Bool {
        if !modifiers.isDisjoint(with: [.command, .control, .option]) { return true }
        return Self.functionKeys[keyCode] != nil
    }

    /// The same modifiers as Carbon's `cmdKey`, `shiftKey`, `optionKey` and `controlKey`, for `RegisterEventHotKey`.
    public var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= 0x0100 }
        if modifiers.contains(.shift) { flags |= 0x0200 }
        if modifiers.contains(.option) { flags |= 0x0800 }
        if modifiers.contains(.control) { flags |= 0x1000 }
        return flags
    }

    /// The row's name for a key: the keys with no character by their code, the rest by the character the key
    /// types with no modifier held. Nil when the key has no name to show (a dead key, a bare modifier).
    public static func keyName(keyCode: UInt16, characters: String?) -> String? {
        if let named = namedKeys[keyCode] ?? functionKeys[keyCode] { return named }
        guard let characters else { return nil }
        let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let scalar = trimmed.unicodeScalars.first,
              !(0xF700...0xF8FF).contains(scalar.value),          // AppKit's function-key range (arrows, home, end)
              !CharacterSet.controlCharacters.contains(scalar)
        else { return nil }
        return trimmed.uppercased()
    }

    private static let namedKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "space", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

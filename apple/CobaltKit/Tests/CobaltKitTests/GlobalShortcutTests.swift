import Foundation
import Testing
@testable import CobaltKit

struct GlobalShortcutTests {
    @Test func theRowDrawsModifiersInMenuOrder() {
        let shortcut = GlobalShortcut(keyCode: 9, modifiers: [.command, .shift, .option, .control], key: "V")
        #expect(shortcut.display == "⌃⌥⇧⌘V")
        #expect(GlobalShortcut(keyCode: 9, modifiers: [.command, .shift], key: "V").display == "⇧⌘V")
    }

    @Test func aPlainOrShiftedKeyIsRefusedAndAFunctionKeyStandsAlone() {
        #expect(!GlobalShortcut(keyCode: 9, modifiers: [], key: "V").isUsable)
        #expect(!GlobalShortcut(keyCode: 9, modifiers: [.shift], key: "V").isUsable)
        #expect(GlobalShortcut(keyCode: 9, modifiers: [.control], key: "V").isUsable)
        #expect(GlobalShortcut(keyCode: 96, modifiers: [], key: "F5").isUsable)
    }

    @Test func carbonModifiersMatchTheSystemConstants() {
        // cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000
        #expect(GlobalShortcut(keyCode: 9, modifiers: [.command, .shift], key: "V").carbonModifiers == 0x0300)
        #expect(GlobalShortcut(keyCode: 9, modifiers: [.control, .option], key: "V").carbonModifiers == 0x1800)
    }

    @Test func keysAreNamedByCodeFirstThenByCharacter() {
        #expect(GlobalShortcut.keyName(keyCode: 49, characters: " ") == "space")
        #expect(GlobalShortcut.keyName(keyCode: 96, characters: "\u{F708}") == "F5")
        #expect(GlobalShortcut.keyName(keyCode: 9, characters: "v") == "V")
        #expect(GlobalShortcut.keyName(keyCode: 200, characters: "\u{F72B}") == nil)
        #expect(GlobalShortcut.keyName(keyCode: 200, characters: nil) == nil)
    }

    @MainActor @Test func settingsKeepTheShortcutAndClearIt() {
        let defaults = UserDefaults(suiteName: "GlobalShortcutTests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults, keychain: .memory())
        #expect(settings.pasteShortcut == nil)
        let shortcut = GlobalShortcut(keyCode: 9, modifiers: [.control, .option, .command], key: "V")
        settings.pasteShortcut = shortcut
        #expect(Settings(defaults: defaults, keychain: .memory()).pasteShortcut == shortcut)
        settings.pasteShortcut = nil
        #expect(Settings(defaults: defaults, keychain: .memory()).pasteShortcut == nil)
    }
}

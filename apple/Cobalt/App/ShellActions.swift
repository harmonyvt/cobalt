import CobaltKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// What the screens can ask the shell to do: the file pickers and the paste all live at the shell,
/// so the library header and the home circles share them.
struct ShellActions {
    var paste: @MainActor () -> Void = {}
    var chooseFile: @MainActor () -> Void = {}
    /// The system photo picker (a photo or a video from the library).
    var choosePhotos: @MainActor () -> Void = {}
    var trimNewWebp: @MainActor (LibraryPost) -> Void = { _ in }
    /// "make another webp" / "make a webp" from a media's detail: the home focus with the trim open, the
    /// run's webp joining that media (CONTRACT-MEDIA 1.11).
    var makeWebp: @MainActor (MediaItem) -> Void = { _ in }
    /// A short line on the screen underneath once a detail has popped ("deleted."); the shell draws it.
    var showStatus: @MainActor (String) -> Void = { _ in }
    var openSettings: @MainActor () -> Void = {}
    /// Re-reads the server (settings changed the server or the key).
    var recheckServer: @MainActor () -> Void = {}
}

/// "trim a new webp" (a post's detail, a library card, ⌘T, a media's "another webp") means the owner wants the trim: when the run it
/// starts lands in focus, the trim strip is already open under the planet (a clip over 10 s; a shorter one
/// has nothing to trim). Asked once, answered once, and stale after two minutes.
@MainActor
enum TrimIntent {
    private static var requestedAt: Date?

    static func request() { requestedAt = Date() }

    /// True once if a request is pending and recent.
    static func consume() -> Bool {
        defer { requestedAt = nil }
        guard let at = requestedAt else { return false }
        return Date().timeIntervalSince(at) < 120
    }
}

private struct ShellActionsKey: EnvironmentKey {
    static let defaultValue = ShellActions()
}

extension EnvironmentValues {
    var shell: ShellActions {
        get { self[ShellActionsKey.self] }
        set { self[ShellActionsKey.self] = newValue }
    }
}

/// The pasteboard, read only when the owner taps paste. Previews and the simulator evidence run
/// override it so no "allow paste" prompt gets in the way.
@MainActor
enum Pasteboard {
    static var override: String?

    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static func string() -> String? {
        if let override { return override }
        #if canImport(UIKit)
        return UIPasteboard.general.string
        #else
        return NSPasteboard.general.string(forType: .string)
        #endif
    }
}

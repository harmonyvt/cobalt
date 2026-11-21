import CobaltKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A paste the menu bar will not finish itself. The window's shell takes it and runs the same path
/// ⌘V uses, so the review sheet and the name-it sheet are the ones the window already has.
/// A job that later needs the owner (a multi-item post, a file still unnamed) is `focus`: the shell
/// brings that job forward instead of pasting again.
@MainActor @Observable
final class MenuBarHandoff {
    static let shared = MenuBarHandoff()

    private(set) var token = 0
    private var items: [PastedContent] = []
    private var focus: Job.ID?
    /// Opens the main window. The menu bar label sets it; nil while the menu bar icon has not appeared (`MacWindows.reveal`
    /// then does it from the window's own stored action).
    var reveal: (() -> Void)?

    func stage(items: [PastedContent]) {
        self.items = items
        focus = nil
        token += 1
    }

    func stage(focus id: Job.ID) {
        items = []
        focus = id
        token += 1
    }

    /// The pending paste, once. A second read is nil, so appear and change can both call it.
    func take() -> (items: [PastedContent], focus: Job.ID?)? {
        guard focus != nil || !items.isEmpty else { return nil }
        defer { items = []; focus = nil }
        return (items, focus)
    }
}

#if os(macOS)
/// The menu bar icon is on, so closing the last window must not quit: the icon is the app.
@MainActor
final class MenuBarPresence {
    static let shared = MenuBarPresence()
    var staysRunning = true
}
#endif

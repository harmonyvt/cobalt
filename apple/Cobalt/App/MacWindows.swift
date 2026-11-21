#if os(macOS)
import AppKit
import SwiftUI

/// The Mac app's windows, found by identifier and never by title. The main window's title is the app's name and the
/// editor's is the open project's, so a title is neither stable nor ours to rely on.
///
/// SwiftUI gives the `NSWindow` of a `Window(id:)` scene an identifier built from the scene id (the id itself, or the id
/// followed by `-AppWindow-<n>` style suffixes, depending on the system). That format is SwiftUI's, not ours, so
/// `matches` accepts the id or anything that starts with the id and a dash, and the window's own root view also reports
/// its `NSWindow` (`registersMainWindow`) so the lookup does not depend on the format at all while the window exists.
enum MacWindowID {
    static let main = "main"
    static let editor = "editor"
}

@MainActor
enum MacWindows {
    /// The main window, held weakly by its own root view. Nil once SwiftUI let the window go (closed).
    private static weak var mainWindow: NSWindow?
    /// Opens a scene by id. Set by the main window's root view and by the menu bar's views; a closed scene's action still
    /// opens it again, which is what the Dock needs when no menu bar icon is up.
    private static var openMain: (@MainActor () -> Void)?

    /// Whether an `NSWindow.identifier` belongs to the scene `id`.
    static func matches(_ identifier: NSUserInterfaceItemIdentifier?, id: String) -> Bool {
        guard let raw = identifier?.rawValue else { return false }
        return raw == id || raw.hasPrefix(id + "-")
    }

    static func window(id: String) -> NSWindow? {
        if id == MacWindowID.main, let held = mainWindow { return held }
        return NSApp.windows.first { matches($0.identifier, id: id) }
    }

    /// The main window is on screen and not minimized. The studio wallpaper's windows are not this: they are ours, have
    /// no identifier, and sit at the desktop level, which is why `hasVisibleWindows` cannot answer this.
    static var isMainVisible: Bool {
        guard let window = window(id: MacWindowID.main) else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    static func rememberOpenAction(_ open: OpenWindowAction) {
        openMain = { open(id: MacWindowID.main) }
    }

    /// Brings the main window to the front: restores a minimized one, orders a retained closed one front, and opens the
    /// scene when no window exists. With no `OpenWindowAction` of its own it uses the last one a view handed over.
    static func reveal(_ open: OpenWindowAction? = nil) {
        if let open { rememberOpenAction(open) }
        NSApp.activate()
        if NSApp.isHidden { NSApp.unhide(nil) }
        if let window = window(id: MacWindowID.main) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openMain {
            openMain()
        }
    }

    fileprivate static func adopt(_ window: NSWindow) {
        mainWindow = window
    }
}

extension View {
    /// On the main window's root: remembers its `NSWindow` and the action that opens it again.
    func registersMainWindow() -> some View { modifier(RegistersMainWindow()) }
}

private struct RegistersMainWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .background(MainWindowAnchor())
            .onAppear { MacWindows.rememberOpenAction(openWindow) }
    }
}

private struct MainWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}

    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated { MacWindows.adopt(window) }
        }
    }
}
#endif

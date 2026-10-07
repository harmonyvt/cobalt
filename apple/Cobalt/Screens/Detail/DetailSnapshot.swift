#if DEBUG
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Evidence without the screen (debug builds only): `-detailSnapshot /path/prefix` writes every window of the app itself
/// (a sheet is one) as `prefix-t<seconds>-<n>.png` at each time in `-detailSnapshotAt 3,8` (default 4), by drawing the
/// windows' own view hierarchies (`CombineSnapshot.write`: no screen recording, nothing else on the desktop is read).
/// Armed by the first hero that appears (the detail's, the focus planet's), once.
///
/// On the Mac, `-detailKeyAt 5` presses Escape in the topmost sheet at that second (delivered in the process through
/// `NSWindow.sendEvent`; nothing on the desktop is pressed or clicked): the full-screen player's close.
@MainActor
enum DetailSnapshot {
    private static var started = false

    static func runIfRequested() {
        let defaults = UserDefaults.standard
        guard !started else { return }
        started = true
        #if os(macOS)
        MacInput.runIfRequested()
        #endif
        guard let prefix = defaults.string(forKey: "detailSnapshot") else { return }
        let times = (defaults.string(forKey: "detailSnapshotAt") ?? "4").split(separator: ",").compactMap { Double($0) }
        Task { @MainActor in
            var last = 0.0
            for time in times {
                try? await Task.sleep(for: .seconds(max(0, time - last)))
                last = time
                CombineSnapshot.write(prefix: "\(prefix)-t\(Int(time))")
                #if os(macOS)
                dumpViews(to: "\(prefix)-t\(Int(time))-views.txt")
                #endif
            }
        }
    }

    #if os(macOS)
    /// The sheet's AppKit view tree with frames, to find the view that is wider than its window.
    private static func dumpViews(to path: String) {
        var out = ""
        func walk(_ view: NSView, _ depth: Int) {
            out += String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame)\n"
            for sub in view.subviews { walk(sub, depth + 1) }
        }
        for window in NSApp.windows.flatMap({ [$0] + $0.sheets }) {
            out += "== \(type(of: window)) \(window.frame)\n"
            if let root = window.contentView?.superview { walk(root, 0) }
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
    #endif
}

#if os(macOS)
@MainActor
private enum MacInput {
    static func runIfRequested() {
        let d = UserDefaults.standard
        if d.object(forKey: "detailKeyAt") != nil {
            schedule(d.double(forKey: "detailKeyAt")) { window in
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                        isARepeat: false, keyCode: 53) else { continue }
                    window.sendEvent(event)
                }
            }
        }
    }

    /// The window on top: the innermost sheet, else the app's main window.
    private static func topWindow() -> NSWindow? {
        var window = NSApp.windows.first(where: { !$0.isSheet && $0.isVisible })
        while let sheet = window?.attachedSheet { window = sheet }
        return window
    }

    private static func schedule(_ seconds: Double, _ action: @escaping @MainActor (NSWindow) -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if let window = topWindow() { action(window) }
        }
    }
}
#endif
#endif

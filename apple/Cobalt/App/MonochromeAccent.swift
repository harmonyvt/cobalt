#if os(macOS)
import AppKit
import SwiftUI

/// The Mac's accent is the system's: sidebar selection, focus rings and the default button follow
/// whatever the owner picked in System Settings (orange, in this case), and an asset-catalog
/// `AccentColor` only wins while that setting is "multicolor". cobalt is monochrome, so the app
/// asks AppKit for the graphite accent in its own defaults domain, before the first window exists
/// (the same keys `defaults write com.capybaraharmony.cobalt AppleAccentColor -int -1` would write,
/// scoped to this app: the system setting is not touched). `.tint(...)` on the SwiftUI side covers
/// controls; this covers the AppKit-drawn selection.
enum MonochromeAccent {
    /// -1 is graphite in `AppleAccentColor`; the highlight is its neutral grey.
    static func apply() {
        let defaults = UserDefaults.standard
        defaults.set(-1, forKey: "AppleAccentColor")
        defaults.set("0.847059 0.847059 0.862745 Graphite", forKey: "AppleHighlightColor")
    }

    #if DEBUG
    /// `-accentProbe 1`: writes to `accent-probe.txt` in the app's temporary directory the colours AppKit resolves for the accent and for a selected
    /// row, so the evidence does not depend on a window being the key window.
    @MainActor
    static func probeIfRequested() {
        guard UserDefaults.standard.string(forKey: "accentProbe") != nil else { return }
        // The app is sandboxed: its own temporary directory is the one place it can write.
        let path = NSTemporaryDirectory() + "accent-probe.txt"
        func hex(_ color: NSColor) -> String {
            guard let c = color.usingColorSpace(.sRGB) else { return "?" }
            return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        let lines = [
            "controlAccentColor \(hex(NSColor.controlAccentColor))",
            "selectedContentBackgroundColor \(hex(NSColor.selectedContentBackgroundColor))",
            "keyboardFocusIndicatorColor \(hex(NSColor.keyboardFocusIndicatorColor))",
            "selectedTextBackgroundColor \(hex(NSColor.selectedTextBackgroundColor))",
        ]
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
    #endif
}
#endif

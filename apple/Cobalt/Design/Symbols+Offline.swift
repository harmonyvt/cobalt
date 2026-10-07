import SwiftUI

/// SF Symbols for offline media (CONTRACT-OFFLINE section 4). All exist since SF Symbols 1 to 3 (iOS 13 to 15),
/// so they resolve on iOS 26 and macOS 26 (checked with `NSImage(systemSymbolName:)` on the build host). An
/// extension of `Symbol` in its own file so no lane edits `Symbols.swift`; compiled into the share extension and
/// the widgets too (`Cobalt/Design` is shared). `Symbol.removeOffline` (`xmark.bin`) and `Symbol.offlineOn`
/// (`internaldrive`, the cache) already exist in `Symbols+Live.swift`.
extension Symbol {
    /// A media whose every file is kept: the badge, filled.
    static let offlineAll = "arrow.down.circle.fill"
    /// Some of its files are kept: the same circle, outline.
    static let offlineSome = "arrow.down.circle"
    /// A download that failed.
    static let offlineFailed = "exclamationmark.circle"
    /// "keep offline", the menu item and the detail's toggle.
    static let keepOffline = "arrow.down.circle"
    static let stopDownloading = "stop.circle"
    /// "show in files" and "open in files".
    static let showInFiles = "folder"
    /// "show in finder" (the Mac's twin of `showInFiles`).
    static let showInFinder = "folder"
    /// The cache row.
    static let cache = "internaldrive"
    /// A download that waits for the network.
    static let offlineWaiting = "clock"
}

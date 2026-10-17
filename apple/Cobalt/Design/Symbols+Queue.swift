import SwiftUI

/// SF Symbols for the queue tab (apple/CONTRACT.md section 12). All exist since SF Symbols 1 to 4, so they resolve on
/// iOS 26 and macOS 26. An extension of `Symbol` in its own file, compiled into the extensions too (`Cobalt/Design`).
extension Symbol {
    /// The tab and the sidebar row: a stack of work.
    static let queue = "list.bullet.rectangle"
    /// The empty state.
    static let queueEmpty = "checkmark.circle"
    /// The search index's row.
    static let indexing = "text.magnifyingglass"
    /// Posters still to make.
    static let posters = "photo.stack"
    /// The server's own work (another device's save, the share sheet's).
    static let serverWork = "server.rack"
    /// A finished save.
    static let finished = "checkmark.circle"
    /// The photos album row.
    static let photosAlbum = "photo.on.rectangle.angled"
}

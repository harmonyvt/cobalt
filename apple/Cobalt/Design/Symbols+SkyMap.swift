import Foundation

/// SF Symbols for the library's sky map. Both exist on iOS 26 and macOS 26. Compiled into the extensions too
/// (`Cobalt/Design` is shared).
extension Symbol {
    enum SkyMap {
        /// The library toolbar's button: the map is a night sky.
        static let button = "sparkles"
        static let close = "xmark"
        /// "reset view" while zoomed or panned.
        static let reset = "arrow.up.left.and.down.right.magnifyingglass"
        static let open = "arrow.up.right"
        static let failed = "exclamationmark.triangle"
        static let retry = "arrow.clockwise"
        static let empty = "sparkles"
    }
}

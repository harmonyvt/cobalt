import Foundation

/// SF Symbols for search names (APP-API-CONTRACT 48.6). All exist on iOS 18 and macOS 15. Compiled into the extensions too
/// (`Cobalt/Design` is shared).
extension Symbol {
    enum Names {
        /// "names" in the library's menu, and a name's row without pictures.
        static let menu = "character.book.closed"
        static let add = "plus"
        static let delete = "trash"
        static let retry = "arrow.clockwise"
        /// An example ("this is…").
        static let example = "checkmark.circle.fill"
        /// A not post.
        static let notIt = "xmark.circle.fill"
        static let unmark = "circle.dashed"
        /// "this is…" in a post's menu.
        static let thisIs = "tag"
        static let newName = "plus.circle"
        static let search = "magnifyingglass"
        static let open = "chevron.right"
        static let notEmbedded = "hourglass"
    }
}

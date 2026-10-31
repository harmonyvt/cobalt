import SwiftUI

/// SF Symbols for a gallery link's screen and editing its files (APP-API-CONTRACT section 41), compiled into the
/// extensions too (`Cobalt/Design`).
extension Symbol {
    enum LinkEdit {
        /// The toolbar's `edit`.
        static let edit = "pencil"
        /// Take a file out (the minus on a row).
        static let remove = "minus.circle.fill"
        /// "add files".
        static let add = "plus.circle"
        /// A file that no longer shows in the link.
        static let notShown = "eye.slash"
        /// A pick in the add-files picker, and a file already in the link.
        static let ticked = "checkmark.circle.fill"
        /// The drag hint (Mac: the row moves by drag anywhere).
        static let drag = "line.3.horizontal"
        /// The discord preview's heading.
        static let discord = "bubble.left"
        /// The library's "add to link".
        static let addToLink = "link.badge.plus"
        /// Open a post from a file row.
        static let openPost = "chevron.right"
        static let search = "magnifyingglass"
    }
}

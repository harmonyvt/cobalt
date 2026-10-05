import SwiftUI

/// SF Symbols for the library's mosaic and table (CONTRACT-LIBRARY2 section 7; all exist on macOS 26). A nested
/// namespace in its own file so the lanes that build the screens never edit `Symbols.swift`. Compiled into the
/// share extension and the widgets too (`Cobalt/Design` is shared).
extension Symbol {
    enum Library {
        static let mosaic = "square.grid.2x2"
        static let table = "list.bullet"
        /// The sort and show menu.
        static let sortMenu = "arrow.up.arrow.down"
        static let descending = "chevron.down"
        static let ascending = "chevron.up"
        static let open = "arrow.up.left.and.arrow.down.right"
        static let copyLink = "doc.on.doc"
        static let copied = "checkmark"
        static let share = "square.and.arrow.up"
        static let savePhotos = "photo.badge.arrow.down"
        static let rename = "pencil"
        /// Destructive role, last in the menu.
        static let deleteEverything = "trash"
        /// A tile whose picture did not load.
        static let pictureFailed = "photo.badge.exclamationmark"
        /// A tile's and a row's badge, and the table's `public` column: the video's switch (CONTRACT-VISIBILITY 6.2).
        static let isPublic = "globe"
        static let isPrivate = "lock.fill"
        /// "make public" and "make private…" in the context menu.
        static let makePublic = "globe"
        static let makePrivate = "lock.fill"
        /// The inspector toggle (iPad, Mac).
        static let inspector = "sidebar.trailing"
        static let refresh = "arrow.clockwise"
        /// The face type dots of a narrow tile.
        static let typeVideo = "film"
        static let typeWebp = "sparkles"
        static let typePhoto = "photo"
    }
}

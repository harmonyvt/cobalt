import SwiftUI

/// SF Symbols for one media with many renditions (CONTRACT-MEDIA.md section 7; all exist on macOS
/// 26). A nested namespace in its own file so the lanes that build the screens never edit
/// `Symbols.swift`; the names that already exist there are repeated so a screen reads them all from
/// one place. Compiled into the share extension and the widgets too (`Cobalt/Design` is shared).
extension Symbol {
    enum Media {
        /// The video tab chip and the compact face dot.
        static let video = "film"
        /// The webp chip, the face dot, "another webp" and "make a webp".
        static let webp = "sparkles"
        static let makeWebp = "sparkles"
        /// Hosted (the chip's glyph, the planet's dot).
        static let hosted = "link"
        /// A private copy only (the chip's glyph).
        static let privateCopy = "lock"
        /// The public/private switch's glyph (CONTRACT-VISIBILITY 6.2): a public link, and a file only the owner sees.
        static let isPublic = "globe"
        static let isPrivate = "lock.fill"
        /// The detail's `more` menu.
        static let more = "ellipsis.circle"
        static let deleteWebp = "trash"
        /// Destructive role, last in the menu.
        static let deleteEverything = "trash"
        /// "remove from this iphone".
        static let removeFromDevice = "xmark.bin"
        /// "try again" after a partial delete.
        static let retry = "arrow.clockwise"
        static let copyLink = "doc.on.doc"
        /// What the copy button turns into for a moment.
        static let copied = "checkmark"
        static let share = "square.and.arrow.up"
        static let savePhotos = "photo.badge.arrow.down"
        static let publicShare = "link.badge.plus"
        /// The crop badge in a webp's meta line.
        static let crop = "crop"
        static let openInLibrary = "photo.on.rectangle.angled"
    }
}

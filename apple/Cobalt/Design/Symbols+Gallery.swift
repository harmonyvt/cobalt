import SwiftUI

/// SF Symbols for photos, galleries and what is made from them (apple/CONTRACT-GALLERY.md; all exist on iOS 26 and macOS
/// 26). A nested namespace in its own file so the lanes that build the screens never edit `Symbols.swift`. Compiled into
/// the share extension and the widgets too (`Cobalt/Design` is shared).
extension Symbol {
    enum Gallery {
        /// A single photo: the library's kind chip, the planet's dot, the photos tab.
        static let photo = "photo"
        /// A gallery: the stack behind a planet, the count badge, the `galleries` chip.
        static let gallery = "photo.stack"
        static let galleries = "rectangle.stack"
        /// A video or gif item of a gallery.
        static let video = "film"
        /// The three makes (the paste hero's row, the combine sheet's segments, the detail's tabs).
        static let slideshowWebp = "play.square.stack"
        static let slideshowMp4 = "play.rectangle"
        static let galleryImage = "square.grid.3x3"
        /// `make from it` / `make from this post…`.
        static let make = "wand.and.stars"
        /// The four layouts' glyphs (the share sheet's inline buttons, the combine sheet's picker).
        static let layoutStrip = "rectangle.split.1x2"
        static let layoutGrid2 = "square.grid.2x2"
        static let layoutGrid3 = "square.grid.3x3"
        static let layoutRow = "rectangle.split.2x1"
        /// Reorder (drag) and the keyboard's `move earlier` / `move later`.
        static let reorder = "line.3.horizontal"
        static let moveEarlier = "arrow.left"
        static let moveLater = "arrow.right"
        /// Ticked / unticked in the combine strip and in `select photos`.
        static let ticked = "checkmark.circle.fill"
        static let unticked = "circle"
        /// An item that could not be fetched (red, with `!`).
        static let missing = "exclamationmark.triangle.fill"
        static let retry = "arrow.clockwise"
        /// `crossfade` toggle and `sound` row.
        static let crossfade = "square.on.square"
        static let sound = "speaker.wave.2"
        /// Where a kept gallery lives (the "saved to cobalt · Files › …" line).
        static let folder = "folder"
        /// `copy text` (Live Text) and `save to photos`.
        static let copyText = "text.viewfinder"
        static let saveToPhotos = "photo.badge.arrow.down"
        static let copyLinks = "link"
        static let selectPhotos = "checkmark.circle"
        /// Repost tools (wave A7).
        static let crop = "crop"
        static let repostFrame = "rectangle.portrait.on.rectangle.portrait"
    }
}

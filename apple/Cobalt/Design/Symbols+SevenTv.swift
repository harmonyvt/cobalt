import SwiftUI

/// SF Symbols for the studio tab's 7TV card, set screen and sheets (APP-API-CONTRACT 57.7). Its own file, compiled into the
/// extensions too (`Cobalt/Design`). Every name exists since SF Symbols 4.
extension Symbol {
    enum SevenTv {
        /// "link 7tv", "link again", "link".
        static let link = "link.badge.plus"
        /// "unlink" (it asks first).
        static let unlink = "xmark.circle"
        /// The amber "7tv signed you out" line.
        static let warn = "exclamationmark.triangle"
        /// A set's "open".
        static let open = "chevron.right"
        /// "make live".
        static let makeLive = "dot.radiowaves.left.and.right"
        /// "new set".
        static let newSet = "plus.rectangle.on.rectangle"
        /// A search tile's "+" and "✓".
        static let add = "plus"
        static let inSet = "checkmark"
        /// "add with another name…" and "rename".
        static let rename = "pencil"
        /// "copy to set…".
        static let copyToSet = "square.on.square"
        /// "remove".
        static let remove = "trash"
        /// "copy the bookmark".
        static let bookmark = "bookmark"
        /// "open 7tv.app".
        static let website = "safari"
        /// The filter field.
        static let filter = "line.3.horizontal.decrease"
        static let retry = "arrow.clockwise"
        /// A channel or account without a picture.
        static let person = "person.crop.circle"
        /// "upload to 7tv" (57.9) and the sheet's "upload".
        static let upload = "arrow.up.circle"
        /// The 7tv tab (APP-API-CONTRACT 57.7).
        static let tab = "face.smiling"
        /// The account's "⋯" menu.
        static let more = "ellipsis"
        /// "search 7tv" (the Mac's middle column) and the search segment.
        static let search = "magnifyingglass"
        /// "upload from library".
        static let library = "photo.on.rectangle.angled"
        /// The "on 7tv" mark of a library picture.
        static let onSevenTv = "checkmark.seal.fill"
        /// "select" and a picked tile.
        static let select = "checkmark.circle"
        static let picked = "checkmark.circle.fill"
        /// "reset to <7tv name>".
        static let reset = "arrow.uturn.backward"
        /// The clash sheet's choices.
        static let choiceOn = "largecircle.fill.circle"
        static let choiceOff = "circle"
        /// The studio's "7tv →" row.
        static let shortcut = "chevron.right"
        /// The upload sheet's "crop…" and "use this crop" (57.10).
        static let crop = "crop"
        /// The crop line's "clear".
        static let clearCrop = "xmark"
    }
}

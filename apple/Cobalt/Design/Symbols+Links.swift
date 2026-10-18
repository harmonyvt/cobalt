import SwiftUI

/// SF Symbols for gallery share links (APP-API-CONTRACT section 24): the tab, a revoke, a video's play glyph. An
/// extension of `Symbol` in its own file, compiled into the extensions too (`Cobalt/Design`).
extension Symbol {
    /// The links tab and its sidebar row.
    static let links = "link.circle"
    /// The empty state.
    static let linksEmpty = "link.badge.plus"
    /// Revoke a link: it stops working.
    static let revokeLink = "minus.circle"
    /// A file in a link that is private now.
    static let linkFilePrivate = "lock.fill"
    /// A video in a link's strip.
    static let linkFilePlay = "play.fill"

    // MARK: collections (APP-API-CONTRACT section 26)

    /// A collection: its row and its screen.
    static let collection = "folder"
    /// "new collection" (the row, the menu item).
    static let collectionNew = "folder.badge.plus"
    /// "add to collection" in a link's menu.
    static let collectionAdd = "folder.badge.plus"
    /// "remove from collection".
    static let collectionRemove = "folder.badge.minus"
    /// Rename a collection.
    static let collectionRename = "pencil"
    static let collectionCopyAll = "doc.on.doc"
    /// Reroll all of a collection's links: new addresses, old ones revoked.
    static let collectionReroll = "arrow.triangle.2.circlepath"
    /// Delete a collection.
    static let collectionDelete = "trash"
    /// A collection screen's menu.
    static let collectionMenu = "ellipsis.circle"
    /// A picked link in the new-collection sheet.
    static let linkPicked = "checkmark.circle.fill"
    /// A link not picked.
    static let linkNotPicked = "circle"
}

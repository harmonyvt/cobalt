import CobaltKit
import Foundation

/// Copy for share link collections (APP-API-CONTRACT section 26; all new, lowercase): the collections section of the
/// links tab, a collection's screen, the new / rename sheet and the row menus. Plain values only (counts, CobaltKit
/// types), since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum Collections {
        // MARK: the section and its rows

        static let section = "collections"
        static let linksHeader = "links"
        static let new = "new collection"
        /// The menu item that opens the sheet from a link's row.
        static let newEllipsis = "new collection…"
        static func linkCount(_ count: Int) -> String { "\(count) \(count == 1 ? "link" : "links")" }
        static func rowA11y(name: String, links: Int) -> String { "\(name), \(linkCount(links))" }
        static let folderA11y = "collection"

        // MARK: a collection's screen

        static let emptyTitle = "no links here yet"
        static let emptyBody = "add links from their menu"
        static let menu = "collection"
        static let rename = "rename"
        static let copyAll = "copy all links"
        static let delete = "delete"
        static let deleteTitle = "delete this collection?"
        static let deleteMessage = "its links keep working."
        static let keep = "keep"
        static let reroll = "reroll all links"
        static let rerollTitle = "reroll all links?"
        static let rerollMessage = "every link gets a new address and a new title. the old links stop working."
        static let rerollConfirm = "reroll"

        // MARK: a link's menu

        static let addTo = "add to collection"
        static let removeFrom = "remove from collection"

        // MARK: the sheet

        static let newTitle = "new collection"
        static let renameTitle = "rename collection"
        static let nameField = "name"
        static let namePlaceholder = "collection name"
        static let includeHeader = "links to include"
        static let noLinksToInclude = "no links yet · you can add them later"
        static let save = "save"
        static let cancel = "cancel"
        static func picked(_ count: Int) -> String { "\(count) picked" }
        static func nameCount(_ count: Int) -> String { "\(count) of \(ShareCollectionRule.nameLimit)" }

        // MARK: statuses

        static let made = "collection made"
        static let renamed = "collection renamed"
        static let deleted = "collection deleted"
        static let added = "added to collection"
        static let removed = "removed from collection"
        static let linkGone = "that link is gone"
        static let tooMany = "100 collections at most"
        static let full = "this collection is full"
        static let rerolling = "rerolling…"
        static let rerolled = "links rerolled"
        static let nothingToReroll = "nothing to reroll"
        static let collectionGone = "that collection is gone"

        /// The status line for a refused or failed collection call: the three the server names, else the usual.
        static func message(for error: Error) -> String {
            switch error {
            case ShareCollectionError.linkNotFound: return linkGone
            case ShareCollectionError.tooMany: return tooMany
            case ShareCollectionError.full: return full
            case ShareCollectionError.empty: return nothingToReroll
            case ShareCollectionError.notFound: return collectionGone
            default: return Copy.actionFailed
            }
        }
    }
}

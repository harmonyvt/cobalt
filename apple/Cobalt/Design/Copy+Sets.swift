import CobaltKit
import Foundation

// Copy for sets (APP-API-CONTRACT section 28): a set is a named group of collections. In the code it is a
// `CollectionGroup`, because a `ShareSet` is already a link; the owner only ever reads "set".
extension Copy {
    enum Sets {
        static let all = "all"                                                // the chip that shows every collection
        static let new = "new set"
        static let newTitle = "new set"
        static let renameTitle = "rename set"
        static let namePlaceholder = "set name"
        static let create = "create", save = "save"
        static let rename = "rename"
        static let delete = "delete set"
        static let copyAll = "copy all links"
        static let sets = "sets"                                              // a collection's menu: which sets hold it
        static func newWith(_ collection: String) -> String { "new set with \(collection)" }
        static func deleteTitle(_ name: String) -> String { "delete \(name)?" }
        static let deleteMessage = "its collections and links stay."
        static func chip(_ name: String, count: Int) -> String { "\(name) \(count)" }
        static func collectionCount(_ n: Int) -> String { n == 1 ? "1 collection" : "\(n) collections" }
        static let emptySet = "no collections in this set yet. long press a collection to add it."
        static let created = "set made", renamed = "set renamed", deleted = "set deleted"
        static let added = "added to set", removed = "removed from set"
        static let tooMany = "100 sets at most"
        static let full = "this set is full"
        static let gone = "that set is gone"
        static let collectionGone = "that collection is gone"

        /// The status line for a refused or failed set call.
        static func message(for error: Error) -> String {
            switch error {
            case CollectionGroupError.tooMany: return tooMany
            case CollectionGroupError.full: return full
            case CollectionGroupError.notFound: return gone
            case CollectionGroupError.collectionNotFound: return collectionGone
            default: return Copy.actionFailed
            }
        }
    }
}

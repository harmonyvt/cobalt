import Foundation

/// How a library post is already shared: how many live gallery links hold one of its files, and how many collections
/// hold one of those links. What the library's tiles badge, so the owner can see what went out before picking again.
public struct ShareStatus: Sendable, Equatable {
    public var links: Int
    public var collections: Int

    public init(links: Int = 0, collections: Int = 0) {
        self.links = links
        self.collections = collections
    }

    public static let none = ShareStatus()

    public var isShared: Bool { links > 0 }
}

/// The links and collections the owner has (`ShareSetStore`), turned around so a post can be looked up by its files.
/// Built once per draw of the library from the store's two lists; a post's lookup costs one pass over its renditions.
public struct ShareSetIndex: Sendable, Equatable {
    /// Library file id → the ids of the sets that hold it.
    private var setsByFile: [String: Set<String>] = [:]
    /// Set id → the ids of the collections that hold it.
    private var collectionsBySet: [String: Set<String>] = [:]

    public init(sets: [ShareSet], collections: [ShareCollection]) {
        for set in sets {
            for item in set.items { setsByFile[item.id, default: []].insert(set.id) }
        }
        let live = Set(sets.map(\.id))
        for collection in collections {
            for setID in collection.setIDs where live.contains(setID) {
                collectionsBySet[setID, default: []].insert(collection.id)
            }
        }
    }

    public static let empty = ShareSetIndex(sets: [], collections: [])

    public var isEmpty: Bool { setsByFile.isEmpty }

    /// Every library file of the post a set could hold: each rendition's own file and its hosted link.
    public static func fileIDs(of item: MediaItem) -> Set<String> {
        var ids = Set<String>()
        for rendition in item.renditions {
            if let id = rendition.file?.id { ids.insert(id) }
            if let id = rendition.hosted?.id { ids.insert(id) }
        }
        return ids
    }

    /// The links holding any file of the post (one link holding two of its files counts once) and the collections
    /// holding any of those links.
    public func status(for item: MediaItem) -> ShareStatus {
        let sets = setIDs(for: item)
        guard !sets.isEmpty else { return .none }
        return ShareStatus(links: sets.count, collections: collectionIDs(forSets: sets).count)
    }

    /// The ids of the live links that hold any file of the post.
    public func setIDs(for item: MediaItem) -> Set<String> {
        guard !setsByFile.isEmpty else { return [] }
        var sets = Set<String>()
        for id in Self.fileIDs(of: item) {
            if let found = setsByFile[id] { sets.formUnion(found) }
        }
        return sets
    }

    /// The ids of the collections holding a link that holds any file of the post (the library's collection filter).
    public func collectionIDs(for item: MediaItem) -> Set<String> {
        collectionIDs(forSets: setIDs(for: item))
    }

    private func collectionIDs(forSets sets: Set<String>) -> Set<String> {
        var collections = Set<String>()
        for id in sets {
            if let found = collectionsBySet[id] { collections.formUnion(found) }
        }
        return collections
    }
}

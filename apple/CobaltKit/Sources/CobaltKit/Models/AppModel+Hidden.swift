import Foundation

// Offline copies of a hidden post (APP-API-CONTRACT 37.7): "stay on the device but are listed only in the hidden album".
// The store keeps the files; these say which of them belong to a hidden post, so the lists that show the device's media
// leave them out and the album lists them.

extension AppModel {
    /// What the device remembers of the hidden posts (`HiddenIndex`): persisted, so it is there at launch, offline and
    /// before the library tab was ever opened. `LibraryModel.syncHiddenIndex` keeps it true to the server.
    var hiddenIndex: HiddenIndex { settings.hiddenIndex }

    /// The library file ids of every hidden post the device knows of.
    public var hiddenFileIDs: Set<String> {
        hiddenIndex.fileIDs.union(library.hiddenPosts.flatMap { $0.files.map(\.id) })
    }

    /// The media is (or joins) a hidden post: nothing is made from it, asked about, or shared by link.
    public func isHiddenPost(_ item: MediaItem) -> Bool {
        if let post = item.post, post.hidden || hiddenIndex.contains(post: post.id) { return true }
        return item.local.map { isHidden($0) } ?? false
    }

    /// The device's copy is of a hidden post (it joins one the device knows is hidden, `MediaItem.joins`).
    public func isHidden(_ media: StoredMedia) -> Bool {
        hiddenIndex.matches(media) || library.hiddenPosts.contains { MediaItem.joins(media, $0) }
    }

    /// What the device holds, without the hidden posts' copies: the lists of "on this device" read this and not `store.media`.
    public var visibleStoredMedia: [StoredMedia] {
        guard !hiddenIndex.isEmpty || !library.hiddenPosts.isEmpty else { return store.media }
        return store.media.filter { !isHidden($0) }
    }

    /// The device's copies of hidden posts: listed in the hidden album only.
    public var hiddenStoredMedia: [StoredMedia] {
        guard !hiddenIndex.isEmpty || !library.hiddenPosts.isEmpty else { return [] }
        return store.media.filter { isHidden($0) }
    }
}

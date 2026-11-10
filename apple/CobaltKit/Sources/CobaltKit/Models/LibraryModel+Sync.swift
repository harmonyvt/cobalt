import Foundation

extension LibraryModel {
    func storedPost(_ id: String) -> LibraryPost? {
        posts.first { $0.id == id } ?? hiddenPosts.first { $0.id == id }
    }

    func postOwning(file id: String) -> LibraryPost? {
        posts.first { $0.files.contains { $0.id == id } } ?? hiddenPosts.first { $0.files.contains { $0.id == id } }
    }

    /// Replaces both lists from the on-device copy. `hasMore` stays false: the pages are the sync
    /// cursor's, not the library's, so a filter does not ask `GET /library` for the rest.
    func replaceFromSync(_ snapshot: SyncLibrarySnapshot, source: String) {
        let wasEmpty = posts.isEmpty
        posts = snapshot.visible.filter { !$0.hidden }
        var seen = Set<String>()
        let album = snapshot.hidden + snapshot.visible.filter(\.hidden)
        hiddenPosts = album.filter { seen.insert($0.id).inserted }
        postCount = posts.count
        fileCount = posts.reduce(0) { $0 + $1.files.count }
        hiddenCount = hiddenPosts.count
        hasMore = false
        hiddenHasMore = false
        cursor = nil
        hiddenCursor = nil
        failure = nil
        hiddenFailure = nil
        replaceHiddenIndex(with: hiddenPosts)
        didApply(page: LibraryPage(
            posts: posts + hiddenPosts, postCount: postCount, fileCount: fileCount,
            publicBytes: 0, privateBytes: 0, next: nil, hiddenCount: hiddenCount))
        if wasEmpty, !posts.isEmpty { LaunchTiming.noteFirstContent(source: source) }
    }

    /// The screen moves before the outbox sends. Returns the post as it now is, or nil when a delete
    /// would be the honest result (status changes never delete).
    @discardableResult
    func stageLocalStatus(_ status: PostStatus, post: LibraryPost) -> LibraryPost? {
        var updated = storedPost(post.id) ?? post
        let wasHidden = updated.hidden || hiddenPosts.contains { $0.id == updated.id }
        SyncMerge.apply(status, to: &updated)
        posts.removeAll { $0.id == updated.id }
        hiddenPosts.removeAll { $0.id == updated.id }
        if updated.hidden {
            hiddenPosts.insert(updated, at: 0)
            recentlyHidden.insert(updated.id)
            recentlyUnhidden.remove(updated.id)
            if !wasHidden { hiddenCount += 1 }
            rememberHidden([updated])
            if expandedPostID == updated.id { expandedPostID = nil }
        } else {
            posts.insert(updated, at: 0)
            recentlyUnhidden.insert(updated.id)
            recentlyHidden.remove(updated.id)
            if wasHidden { hiddenCount = max(0, hiddenCount - 1) }
            forgetHidden(posts: [updated.id])
        }
        postCount = posts.count
        hiddenEpoch += 1
        return updated
    }
}

import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
public final class LibraryModel {
    public internal(set) var posts: [LibraryPost] = []
    public internal(set) var postCount: Int = 0
    public internal(set) var fileCount: Int = 0
    public internal(set) var isLoading: Bool = false
    public internal(set) var failure: PipelineFailure?
    public internal(set) var hasMore: Bool = false
    public var expandedPostID: String?                    // one card open at a time
    /// Evicted items being fetched again (`redownload(_:)`), by `StoredVideo.id`, with the bytes so
    /// far. An entry exists exactly while its download runs, so a card can show a ring from it.
    public internal(set) var redownloads: [String: TransferProgress] = [:]
    /// Library file ids whose public/private switch is on its way to the server (`AppModel.setVisibility`): an
    /// entry exists exactly while the request runs, so the detail can disable the switch and say "making the link…".
    public internal(set) var visibilityInFlight: Set<String> = []

    // MARK: - Hidden posts (APP-API-CONTRACT 37; `LibraryModel+Hidden.swift`)

    /// The hidden chip is on: the library shows the hidden album (`hiddenPosts`) instead of `posts`. Not persisted: the
    /// album is locked each time it opens, so it starts closed.
    public var showingHidden: Bool = false
    /// The hidden album's loaded pages, most recently hidden first. Hidden posts are in no other list.
    public internal(set) var hiddenPosts: [LibraryPost] = []
    /// How many posts are hidden on the server (`counts.hidden` of every page, kept honest by `setStatus`).
    public internal(set) var hiddenCount: Int = 0
    public internal(set) var hiddenLoading: Bool = false
    public internal(set) var hiddenFailure: PipelineFailure?
    /// Bumped whenever the device's memory of what is hidden changed (a post hidden or unhidden, a sync): the screens close
    /// a detail that holds a post that just became hidden.
    public internal(set) var hiddenVersion: Int = 0
    public internal(set) var hiddenHasMore: Bool = false
    /// A `setStatus` request is on its way: the status menu can disable itself and say "working…".
    public internal(set) var statusInFlight: Bool = false

    // MARK: - View state (CONTRACT-LIBRARY2 decisions 10, 14; persisted per device except `query`)

    /// `mosaic` or `table`; remembered ("library.view"), `mosaic` by default.
    public var viewMode: LibraryViewMode {
        didSet { if viewMode != oldValue { defaults.set(viewMode.rawValue, forKey: LibraryDefaults.view) } }
    }
    /// The sort ("library.sort", `date.desc` by default).
    public var sort: LibrarySort {
        didSet { if sort != oldValue { defaults.set(sort.stored, forKey: LibraryDefaults.sort) } }
    }
    /// The visibility filter ("library.show", `everything` by default).
    public var show: LibraryShow {
        didSet { if show != oldValue { defaults.set(show.rawValue, forKey: LibraryDefaults.show) } }
    }
    /// The kind chip ("library.kind", `all` by default; apple/CONTRACT-GALLERY.md 1.21).
    public var kindFilter: LibraryKindFilter {
        didSet { if kindFilter != oldValue { defaults.set(kindFilter.rawValue, forKey: LibraryDefaults.kind) } }
    }
    /// The search text; not persisted. With `features.search` a change also starts the server search
    /// (`LibraryModel+Search.swift`).
    public var query: String = "" {
        didSet { if query != oldValue { queryDidChange() } }
    }
    /// The server's answer for the current query, posts best first (APP-API-CONTRACT 21); nil while there is none (no
    /// query, under two letters, no `features.search`, still waiting, or the search failed): the local name filter then
    /// answers alone.
    public internal(set) var searchResults: [LibraryPost]?
    /// Each result's `score`, by post id.
    public internal(set) var searchScores: [String: Double] = [:]
    /// Where the server search is, for the line under the search field.
    public internal(set) var searchState: LibrarySearchState = .idle
    /// Posts a search returned, by id, kept after the query is cleared, so a detail opened from a result that is not
    /// in `posts` (past the loaded pages) keeps its post. Emptied by `reset()`.
    public internal(set) var searchKnown: [String: LibraryPost] = [:]
    /// While `loadAll` runs: pages in so far and the server's total (the quiet line above the results).
    public private(set) var loadingAll: (loaded: Int, total: Int)?

    /// Titles the owner gave on this device, by local media id (CONTRACT-LIBRARY2 decision 8). Memory only
    /// in K1: wave K2 writes them to `StoredVideo.title` and `MediaItem.localTitle` reads them from there.
    public internal(set) var localTitles: [String: String] = [:]

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var cursor: String?
    @ObservationIgnored var redownloadTasks: [String: Task<StoredVideo, Error>] = [:]
    /// The debounce, request and waking retry of the current query; cancelled by the next keystroke.
    @ObservationIgnored var searchTask: Task<Void, Never>?
    /// The server answered `error.search.off`: no more server searches until `reset()` (a server or key change).
    @ObservationIgnored var searchOffByServer = false
    /// The hidden album's next page.
    @ObservationIgnored var hiddenCursor: String?
    /// `hiddenCount` when the album's first page was last read (nil: never): a different count means it moved.
    @ObservationIgnored var hiddenSyncedCount: Int?
    /// Posts this device just hid. A page that was already on its way when they were hidden still lists them: it must not
    /// put them back. Emptied by the first page that was asked for after the last status change.
    @ObservationIgnored var recentlyHidden: Set<String> = []
    /// Posts this device just unhid: a hidden page that was already on its way still lists them and must not put them back.
    @ObservationIgnored var recentlyUnhidden: Set<String> = []
    /// Bumped when a status change starts and ends, so a page can tell it began before one.
    @ObservationIgnored var statusEpoch = 0
    /// Bumped by every change to the set of hidden posts this device makes itself (a status change, a delete from the
    /// album): a whole-album read that began before one is stale and is dropped (`syncHiddenIndex`).
    @ObservationIgnored var hiddenEpoch = 0
    /// When the whole album was last read (nil: not since launch or the last server change).
    @ObservationIgnored var hiddenSyncedAt: Date?
    /// Tests: runs after the pages of a whole-album read came in, before the answer is kept.
    @ObservationIgnored var afterHiddenRead: (@MainActor () async -> Void)?
    /// The whole-album read the last refresh started.
    @ObservationIgnored var hiddenSyncTask: Task<Void, Never>?
    /// A whole-album read (`syncHiddenIndex`) is running.
    @ObservationIgnored var hiddenSyncing = false

    static let pageSize = 20
    static let wholePageSize = 50
    /// The most hidden posts one whole-album read collects; past it the device's memory only grows.
    static let syncCap = 2000

    /// `defaults`: where the view state is remembered. The app's settings defaults unless injected (tests
    /// pass a fresh suite).
    init(context: PipelineContext, seed: LibraryPage? = nil, defaults: UserDefaults? = nil) {
        self.ctx = context
        let defaults = defaults ?? context.settings.defaults
        self.defaults = defaults
        self.viewMode = defaults.string(forKey: LibraryDefaults.view).flatMap(LibraryViewMode.init(rawValue:)) ?? .mosaic
        self.sort = defaults.string(forKey: LibraryDefaults.sort).flatMap(LibrarySort.init(stored:)) ?? .newest
        self.show = defaults.string(forKey: LibraryDefaults.show).flatMap(LibraryShow.init(rawValue:)) ?? .everything
        self.kindFilter = defaults.string(forKey: LibraryDefaults.kind).flatMap(LibraryKindFilter.init(rawValue:)) ?? .all
        if let seed { apply(seed, replacing: true) }
    }

    func reset() {
        posts = []; postCount = 0; fileCount = 0; failure = nil; hasMore = false; cursor = nil
        expandedPostID = nil; loadingAll = nil; localTitles = [:]
        searchTask?.cancel(); searchTask = nil; searchOffByServer = false
        searchResults = nil; searchScores = [:]; searchState = .idle; searchKnown = [:]
        showingHidden = false; hiddenPosts = []; hiddenCount = 0; hiddenLoading = false; hiddenFailure = nil
        hiddenHasMore = false; hiddenCursor = nil; hiddenSyncedCount = nil; hiddenSyncedAt = nil; recentlyHidden = []
        recentlyUnhidden = []; statusInFlight = false; hiddenEpoch += 1; hiddenVersion += 1
        ctx.settings.hiddenIndex = HiddenIndex()             // another server: nothing is known about what it hides
    }

    func apply(_ page: LibraryPage, replacing: Bool) {
        // A post the server calls hidden (or this device just hid) is in no list but the hidden album, whatever page it
        // came on (APP-API-CONTRACT 37.2).
        let listed = page.posts.filter { !$0.hidden && !recentlyHidden.contains($0.id) }
        if replacing {
            posts = listed
        } else {
            let known = Set(posts.map(\.id))
            posts += listed.filter { !known.contains($0.id) }
        }
        postCount = page.postCount
        fileCount = page.fileCount
        if !statusInFlight { hiddenCount = page.hiddenCount }
        cursor = page.next
        hasMore = page.next != nil
        didApply(page: page)
    }

    /// Called after every page (refresh, `loadMore`, `loadAll`, `locate`, the seed) has joined `posts`:
    /// the title sync-down. A post that joins a local media and has a `custom_title` different from the
    /// local one writes it to the store (CONTRACT-LIBRARY2 decision 8), unless a newer title of this device
    /// is still waiting to reach the server (`TitleQueue`). A post without a `custom_title` changes nothing:
    /// a title typed offline must not be erased by a server that has not heard it yet.
    func didApply(page: LibraryPage) {
        let store = ctx.store
        var pending: Set<String>?
        for post in page.posts {
            guard let title = post.customTitle.flatMap(MediaTitle.clean),
                  let media = store.media(joining: post),
                  media.customTitle != title else { continue }
            let queued = pending ?? Set(ctx.titles.all().map(\.itemID))
            pending = queued
            if post.files.contains(where: { queued.contains($0.id) }) { continue }
            if store.writeTitle(title, media: media.id) { localTitles[media.id] = nil }
        }
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = ctx.client
            if ctx.capabilities.titles { await ctx.titles.flush(client: client) }       // titles that failed to send, before the page reads them
            let epoch = statusEpoch
            let page = try await ctx.libraryPage(cursor: nil, limit: Self.pageSize)
            apply(page, replacing: true)
            if epoch == statusEpoch, !statusInFlight { recentlyHidden = []; recentlyUnhidden = [] }       // asked after the last change: it is the truth
            failure = nil
            // quiet, and not waited for: the refresh is done when the library page is
            hiddenSyncTask = Task { [weak self] in await self?.syncHiddenIndex() }
        } catch {
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
        }
    }

    public func loadMore() async {
        guard !isLoading, hasMore, let cursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await ctx.libraryPage(cursor: cursor, limit: Self.pageSize)
            apply(page, replacing: false)
            failure = nil
        } catch {
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
        }
    }

    // MARK: - The whole library (search, filter, sort, "open in library")

    /// Everything on device: pages of 50 until the server has no more or `cap` posts are in. A quiet
    /// `loadingAll` reports the count while it runs. A failure stops it and lands in `failure`.
    public func loadAll(cap: Int = 1000) async {
        if showingHidden { return await loadAllHidden(cap: cap) }       // the album's own pages
        await settle()
        guard !isLoading else { return }
        guard posts.isEmpty || hasMore else { return }
        isLoading = true
        defer { isLoading = false; loadingAll = nil }
        await pages(cap: cap, progress: true) { _ in false }
    }

    /// Loads pages until the post is in `posts` (or the server has no more, or the cap of 1000 posts):
    /// true when it is loaded.
    public func locate(postID: String) async -> Bool {
        if posts.contains(where: { $0.id == postID }) { return true }
        await settle()
        if posts.contains(where: { $0.id == postID }) { return true }
        guard !isLoading, posts.isEmpty || hasMore else { return false }
        isLoading = true
        defer { isLoading = false }
        await pages(cap: 1000, progress: false) { [postID] loaded in loaded.contains { $0.id == postID } }
        return posts.contains { $0.id == postID }
    }

    /// Waits out a load that is already running, so a search typed during the first page still sees it.
    private func settle() async {
        while isLoading, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// The paging loop of `loadAll` and `locate`. `isLoading` is held by the caller.
    private func pages(cap: Int, progress: Bool, found: ([LibraryPost]) -> Bool) async {
        do {
            var next = posts.isEmpty ? nil : cursor
            while posts.count < cap {
                let limit = min(Self.wholePageSize, cap - posts.count)
                let page = try await ctx.libraryPage(cursor: next, limit: limit)
                apply(page, replacing: next == nil && posts.isEmpty)
                failure = nil
                if progress { loadingAll = (loaded: posts.count, total: max(postCount, posts.count)) }
                next = page.next
                if next == nil || page.posts.isEmpty || found(page.posts) { break }
            }
        } catch {
            if let f = pipelineFailure(from: error, during: .saving) { failure = f }
        }
    }

    // MARK: - Titles

    /// Optimistic edit of a post's custom title (nil clears); `AppModel.rename` calls it, and reverts the
    /// same way. The next library page replaces it with the server's value.
    public func setCustomTitle(_ title: String?, post id: String) {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        posts[index].customTitle = title
    }

    /// This device's own copy of a media's title (nil clears), by local media id.
    func setLocalTitle(_ title: String?, media id: String) {
        if let title { localTitles[id] = title } else { localTitles[id] = nil }
    }

    // MARK: - Visibility

    /// The library's current copy of a file (a value a view holds may be older).
    func file(id: String) -> LibraryFile? {
        for post in posts { if let file = post.files.first(where: { $0.id == id }) { return file } }
        for post in hiddenPosts { if let file = post.files.first(where: { $0.id == id }) { return file } }
        return nil
    }

    /// Puts `file` in place of the one with its id, and keeps its post's `visibility` honest (the original's,
    /// else public when any file is; only when the post carried one). A file the library does not list is ignored.
    func replace(file: LibraryFile) {
        for index in posts.indices {
            guard let at = posts[index].files.firstIndex(where: { $0.id == file.id }) else { continue }
            posts[index].files[at] = file
            if posts[index].visibility != nil {
                let files = posts[index].files
                posts[index].visibility = files.first { $0.role == .privateCopy }?.visibility
                    ?? (files.contains { $0.isPublic } ? .public : .private)
            }
            return
        }
        for index in hiddenPosts.indices {
            guard let at = hiddenPosts[index].files.firstIndex(where: { $0.id == file.id }) else { continue }
            hiddenPosts[index].files[at] = file
            return
        }
    }

    public func copyLink(_ file: LibraryFile) {
        guard let url = file.url else { return }
        ctx.clipboard.copy(ctx.capabilities.shareLink(for: url).absoluteString)
    }

    /// To Photos. On macOS the caller uses `fileExporter` with `localCopy` instead.
    public func save(_ file: LibraryFile) async throws {
        let (url, isTemp) = try await copy(file)
        do {
            try await ctx.photos.save(fileURL: url, isImage: file.contentType?.hasPrefix("image/") ?? false)
        } catch {
            if isTemp { try? FileManager.default.removeItem(at: url) }
            throw pipelineFailure(from: error, during: .saving) ?? error
        }
        if isTemp { try? FileManager.default.removeItem(at: url) }
    }

    /// A file on disk with this item's bytes: the stored original when the device has it, else a
    /// download (keyed for a private copy, open for a public file).
    public func localCopy(_ file: LibraryFile) async throws -> URL {
        try await copy(file).0
    }

    /// Private copy → public link (copied to the clipboard).
    public func host(_ file: LibraryFile) async throws -> URL {
        do {
            let hosted = try await ctx.client.publish(item: file.id)
            ctx.clipboard.copy(ctx.capabilities.shareLink(for: hosted.url).absoluteString)
            await refresh()
            return hosted.url
        } catch {
            throw pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
        }
    }

    /// `GET /emotes?q=`. Nothing is stored.
    public func searchEmotes(query: String) async throws -> [EmoteHit] {
        try await ctx.client.searchEmotes(query: query)
    }

    /// `GET /emotes?sort=&page=`: top, trending, new or the global set, with or without a name. Nothing is stored.
    public func browseEmotes(query: String, sort: EmoteSort, page: Int) async throws -> EmotePage {
        try await ctx.client.browseEmotes(query: query, sort: sort, page: page)
    }

    /// `POST /emotes`, then the library is read again so the new file is in `posts`.
    public func saveEmote(id: String) async throws -> SavedEmote {
        let saved = try await ctx.client.saveEmote(id: id)
        await refresh()
        return saved
    }

    /// Deletes our copy only (`DELETE /library/items/<id>/post`). 7TV is not called.
    public func removeEmote(fileID: String) async throws {
        _ = try await ctx.client.deletePost(anchor: fileID)
        drop(files: [fileID])
    }

    /// Only when `file.deletable`; removes it from `posts`.
    public func delete(_ file: LibraryFile) async throws {
        guard file.deletable, let name = file.mediaName else { throw PipelineFailure.unsupported }
        do {
            try await ctx.client.deleteMedia(name: name)
        } catch {
            throw pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
        }
        forgetSearched(files: [file.id])
        dropHidden(files: [file.id])
        guard let index = posts.firstIndex(where: { $0.files.contains { $0.id == file.id } }) else { return }
        posts[index].files.removeAll { $0.id == file.id }
        fileCount = max(0, fileCount - 1)
        if posts[index].files.isEmpty {
            if expandedPostID == posts[index].id { expandedPostID = nil }
            posts.remove(at: index)
            postCount = max(0, postCount - 1)
        }
    }

    /// The server confirmed these files gone (a partial or a whole-post delete): they leave `posts`,
    /// and a post left with no file goes with them.
    func drop(files ids: Set<String>) {
        guard !ids.isEmpty else { return }
        forgetSearched(files: ids)
        dropHidden(files: ids)
        for index in posts.indices.reversed() {
            let before = posts[index].files.count
            posts[index].files.removeAll { ids.contains($0.id) }
            let removed = before - posts[index].files.count
            guard removed > 0 else { continue }
            fileCount = max(0, fileCount - removed)
            if posts[index].files.isEmpty {
                if expandedPostID == posts[index].id { expandedPostID = nil }
                posts.remove(at: index)
                postCount = max(0, postCount - 1)
            }
        }
    }

    /// A whole post is gone on the server.
    func drop(post id: String) {
        forgetSearched(posts: [id])
        dropHidden(post: id)
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        fileCount = max(0, fileCount - posts[index].files.count)
        postCount = max(0, postCount - 1)
        if expandedPostID == id { expandedPostID = nil }
        posts.remove(at: index)
    }

    // MARK: -

    func copy(_ file: LibraryFile) async throws -> (URL, Bool) {
        let fm = FileManager.default
        let post = posts.first { $0.files.contains { $0.id == file.id } }
        // The device's own entry for this item, kept or evicted (CONTRACT-LIVE.md 4.2): the stored
        // original of a private copy, or the stored webp of a public file.
        let stored: StoredVideo?
        if file.role == .privateCopy {
            stored = ctx.store.videos.first {
                $0.kind == .original && (($0.sessionID != nil && $0.sessionID == post?.session?.id)
                    || ($0.link != nil && $0.link == post?.link))
            }
        } else if let url = file.url {
            stored = ctx.store.videos.first { $0.kind == .webp && $0.remoteURL == url }
        } else {
            stored = nil
        }
        if let url = stored?.fileURL, fm.fileExists(atPath: url.path) { return (url, false) }

        let remote: RemoteFile
        if file.role == .privateCopy {
            remote = .libraryItem(id: file.id)
        } else if let url = file.url {
            remote = .open(url)
        } else if file.canToggleVisibility {
            remote = .libraryItem(id: file.id)         // a webp switched private: only the key reaches its private copy
        } else {
            throw PipelineFailure.unsupported
        }
        var name = file.name
        if (name as NSString).pathExtension.isEmpty,
           let type = file.contentType, let ext = UTType(mimeType: type)?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        let downloaded: URL
        do {
            downloaded = try await ctx.client.download(remote, to: ctx.store.inboxURL(for: name), progress: { _ in })
        } catch {
            throw pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
        }
        // An evicted entry takes the download back (and becomes the newest for eviction) instead of
        // leaving a second copy behind; with "keep videos on this iphone" off it stays a temp file.
        if let stored, ctx.settings.keepVideosOnDevice,
           let refilled = try? await ctx.store.attach(file: downloaded, to: stored.id, move: true, keep: true),
           let url = refilled.fileURL {
            return (url, false)
        }
        return (downloaded, true)
    }
}

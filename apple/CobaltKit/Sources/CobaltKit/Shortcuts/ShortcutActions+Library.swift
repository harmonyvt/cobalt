import Foundation

// "Get latest saves" and the `CobaltSave` entity's lookups (CONTRACT-PARALLEL.md 15.4): what the library and the
// server's sessions say, as `ShortcutSave`s.

extension ShortcutSave {
    /// A saved post of `GET /library` (v3 on a server with galleries): always `saved` (a post exists once its original is
    /// stored). A gallery's photos are its `item` rows; what was made from it (slideshows, gallery images, crops) is told
    /// apart by `role`, so a slideshow mp4 never makes a photo gallery "a video" and a slideshow webp is a made file, not
    /// one of the post's webps.
    init(post: LibraryPost) {
        let title = MediaTitle.text(
            MediaTitle.resolve(custom: post.customTitle, service: post.service, ref: post.ref, fileName: post.title))
        let parts = Parts(post)
        // The original's public link: a public original (`visibility`, or a legacy hosted copy) that has a url; a
        // gallery has none of its own, its lead item stands in.
        let publicLink = parts.originals.first { $0.isPublic && $0.url != nil }?.url
            ?? parts.items.first { $0.isPublic && $0.url != nil }?.url
        let webps = parts.plain.filter { $0.role == .webp && $0.url != nil }.sorted { $0.createdAt > $1.createdAt }
        let service = post.service.flatMap { $0 == "upload" || $0.isEmpty ? nil : $0 }
        let kind = parts.kind
        let itemLinks: [URL]
        if parts.items.isEmpty {
            // one video or one photo: its own link is its one item's
            itemLinks = parts.originals.first { $0.isPublic && $0.url != nil }.flatMap(\.url).map { [$0] } ?? []
        } else {
            itemLinks = parts.items.filter(\.isPublic).compactMap(\.url)
        }
        let count: Int
        switch kind {
        case .gallery: count = max(post.itemCount ?? 0, parts.items.count)
        case .photo, .video: count = 1
        }
        self.init(
            id: post.id, title: title, link: post.link, service: service, state: .saved, publicLink: publicLink,
            webpLinks: webps.compactMap(\.url), duration: post.duration, created: post.createdAt, hasVideo: parts.hasVideo,
            kind: kind, itemCount: count, itemLinks: itemLinks,
            madeLinks: parts.made.filter(\.isPublic).compactMap(\.url), itemsFailed: kind == .gallery ? post.itemsFailed.count : 0)
    }

    /// A save the server holds as a session (a link save in progress or finished, no library post yet).
    init(session s: StudioSession) {
        let link = s.link.flatMap(URL.init(string:)).flatMap { LinkInfo($0) != nil ? $0 : nil }
        let ref = link.flatMap { LinkInfo($0)?.ref }
        let title = MediaTitle.text(MediaTitle.resolve(custom: nil, service: s.service, ref: ref, fileName: s.title))
        let state: ShortcutSaveState
        switch s.status {
        case .ready: state = .saved
        case .error: state = .failed
        case .saving: state = s.step == .queued ? .queued : .saving
        }
        let service = s.service.flatMap { $0 == "upload" || $0.isEmpty ? nil : $0 }
        // A session says what it is once it is ready: `item_count` of a gallery, and each item's type.
        var kind: ShortcutMediaKind?
        var count: Int?
        var hasVideo = true
        if s.status == .ready, let n = s.itemCount {
            count = n
            if n >= 2 {
                kind = .gallery
                if !s.items.isEmpty { hasVideo = s.items.contains { $0.type == .video } }
            } else if n == 1, s.items.count == 1, let type = s.items.first?.type {
                kind = type == .photo ? .photo : .video
                hasVideo = type != .photo
            }
        }
        self.init(
            id: s.id, title: title, link: link, service: service, state: state, publicLink: nil,
            webpLinks: s.renders.sorted { $0.createdAt > $1.createdAt }.map(\.url), duration: s.duration,
            created: s.createdAt, hasVideo: hasVideo, kind: kind, itemCount: count)
    }

    /// A post's files told apart: its gallery items, what was made from it, and the plain originals and webps.
    struct Parts {
        /// A gallery's originals (`role item`), in the post's order.
        var items: [LibraryFile]
        /// Slideshows, gallery images and crops, newest first.
        var made: [LibraryFile]
        /// Files that are none of the above: a single post's original(s) and its webps.
        var plain: [LibraryFile]
        /// A single post's originals (not webps).
        var originals: [LibraryFile]
        var kind: ShortcutMediaKind
        var hasVideo: Bool

        init(_ post: LibraryPost) {
            items = post.files.filter { $0.galleryRole == .item }.sorted { ($0.itemIndex ?? 0) < ($1.itemIndex ?? 0) }
            made = post.files.filter { $0.galleryRole == .slideshow || $0.galleryRole == .export || $0.galleryRole == .crop }
                .sorted { $0.createdAt > $1.createdAt }
            plain = post.files.filter { $0.galleryRole == nil }
            originals = plain.filter { $0.role != .webp }
            func isVideo(_ file: LibraryFile) -> Bool { file.contentType?.lowercased().hasPrefix("video/") == true }
            func isImage(_ file: LibraryFile) -> Bool { file.contentType?.lowercased().hasPrefix("image/") == true }
            // What "Make webp" needs: a video original, or a video item (the server renders a gallery's first video).
            hasVideo = originals.contains(where: isVideo) || items.contains(where: isVideo)
            if let said = post.kind {
                switch said {
                case .gallery: kind = .gallery
                case .photo: kind = .photo
                case .video, .webp: kind = .video
                }
            } else if items.count >= 2 {
                kind = .gallery
            } else if hasVideo {
                kind = .video
            } else if let only = (items.first ?? originals.first), isImage(only), only.contentType?.lowercased() != "image/gif" {
                kind = .photo
            } else {
                kind = .video
            }
        }
    }
}

extension ShortcutActions {
    /// Pages of 20, newest first, until `enough` says stop or the library ends (or `maxPages`).
    func libraryPosts(maxPages: Int = 5, until enough: ([LibraryPost]) -> Bool) async throws -> [LibraryPost] {
        var posts: [LibraryPost] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page: LibraryPage
            do { page = try await ctx.libraryPage(cursor: cursor, limit: 20) }
            catch { throw Self.shortcutError(error, during: .saving, caps: ctx.capabilities) }
            posts += page.posts
            if enough(posts) { break }
            guard let next = page.next else { break }
            cursor = next
        }
        return posts.sorted { $0.createdAt > $1.createdAt }
    }

    /// "Get latest saves" (15.4): the newest `count` (1 to 20) of the kind asked for. Needs the library.
    public func latestSaves(count: Int = 1, kind: ShortcutSaveKind = .anything) async throws -> [ShortcutSave] {
        let began = ctx.clock.now()
        _ = try await prepare()
        let n = min(max(count, 1), 20)
        guard ctx.capabilities.library else { throw ShortcutError.failed(.unsupported) }
        let posts = try await libraryPosts { Self.matches($0, kind).count >= n }
        let saves = Self.matches(posts, kind).prefix(n).map { ShortcutSave(post: $0) }
        logRun(action: "latest", inputs: n, accepted: saves.count, failed: 0, began: began, outcome: "ok")
        return Array(saves)
    }

    static func matches(_ posts: [LibraryPost], _ kind: ShortcutSaveKind) -> [LibraryPost] {
        let sorted = posts.sorted { $0.createdAt > $1.createdAt }
        switch kind {
        case .anything: return sorted
        case .videos: return sorted.filter { let p = ShortcutSave.Parts($0); return p.kind == .video && p.hasVideo }
        case .photos: return sorted.filter { ShortcutSave.Parts($0).kind == .photo }
        case .galleries: return sorted.filter { ShortcutSave.Parts($0).kind == .gallery }
        case .webps:
            // a webp made of a video, or a slideshow webp (a made file of a gallery)
            return sorted.filter { $0.files.contains { $0.role == .webp || $0.madeKind == .slideshow(.webp) } }
        }
    }

    // MARK: - The CobaltSave entity's lookups (15.4)

    /// `entities(for:)`: the loaded library model first, then `GET /studio/<id>` (a link save), then the first library
    /// page. Ids nobody knows are dropped; the order of `ids` is kept.
    public func saves(for ids: [String]) async -> [ShortcutSave] {
        guard !ids.isEmpty else { return [] }
        var found: [String: ShortcutSave] = [:]
        let loaded = Dictionary(model.library.posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids { if let post = loaded[id] { found[id] = ShortcutSave(post: post) } }
        let client = ctx.client
        for id in ids where found[id] == nil {
            if let session = try? await client.session(id, wait: 0) { found[id] = ShortcutSave(session: session) }
        }
        if ids.contains(where: { found[$0] == nil }), ctx.capabilities.library,
           let page = try? await ctx.libraryPage(cursor: nil, limit: 20) {
            for post in page.posts where found[post.id] == nil && ids.contains(post.id) { found[post.id] = ShortcutSave(post: post) }
        }
        return ids.compactMap { found[$0] }
    }

    /// `suggestedEntities()`: the first library page (20).
    public func suggestedSaves() async -> [ShortcutSave] {
        guard ctx.capabilities.library || !model.library.posts.isEmpty else { return [] }
        if let page = try? await ctx.libraryPage(cursor: nil, limit: 20) {
            return page.posts.sorted { $0.createdAt > $1.createdAt }.map { ShortcutSave(post: $0) }
        }
        return model.library.posts.prefix(20).map { ShortcutSave(post: $0) }
    }

    // MARK: - Errors

    /// Anything a client call threw, as the action reports it (cancellation stays a cancellation).
    nonisolated static func shortcutError(_ error: Error, during phase: ErrorPhase, caps: Capabilities) -> Error {
        if let e = error as? ShortcutError { return e }
        guard let failure = pipelineFailure(from: error, during: phase, limits: caps.limits) else { return CancellationError() }
        return ShortcutError.from(failure, lineMax: caps.limits.lineMax)
    }
}

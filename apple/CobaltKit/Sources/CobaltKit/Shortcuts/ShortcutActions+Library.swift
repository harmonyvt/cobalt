import Foundation

// "Get latest saves" and the `CobaltSave` entity's lookups (CONTRACT-PARALLEL.md 15.4): what the library and the
// server's sessions say, as `ShortcutSave`s.

extension ShortcutSave {
    /// A saved post of `GET /library`: always `saved` (a post exists once its original is stored).
    init(post: LibraryPost) {
        let title = MediaTitle.text(
            MediaTitle.resolve(custom: post.customTitle, service: post.service, ref: post.ref, fileName: post.title))
        let originals = post.files.filter { $0.role != .webp }
        // The original's public link: a public original (`visibility`, or a legacy hosted copy) that has a url.
        let publicLink = originals.first { $0.isPublic && $0.url != nil }?.url
        let webps = post.files.filter { $0.role == .webp && $0.url != nil }.sorted { $0.createdAt > $1.createdAt }
        let service = post.service.flatMap { $0 == "upload" || $0.isEmpty ? nil : $0 }
        self.init(
            id: post.id, title: title, link: post.link, service: service, state: .saved, publicLink: publicLink,
            webpLinks: webps.compactMap(\.url), duration: post.duration, created: post.createdAt,
            hasVideo: originals.contains { $0.contentType?.lowercased().hasPrefix("video/") == true })
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
        self.init(
            id: s.id, title: title, link: link, service: service, state: state, publicLink: nil,
            webpLinks: s.renders.sorted { $0.createdAt > $1.createdAt }.map(\.url), duration: s.duration,
            created: s.createdAt, hasVideo: true)
    }
}

extension ShortcutActions {
    /// Pages of 20, newest first, until `enough` says stop or the library ends (or `maxPages`).
    func libraryPosts(maxPages: Int = 5, until enough: ([LibraryPost]) -> Bool) async throws -> [LibraryPost] {
        let client = ctx.client
        let v2 = ctx.capabilities.visibility
        var posts: [LibraryPost] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page: LibraryPage
            do { page = try await client.library(cursor: cursor, limit: 20, v2: v2) }
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
        case .videos: return sorted.filter { ShortcutSave(post: $0).hasVideo }
        case .webps: return sorted.filter { $0.files.contains { $0.role == .webp } }
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
           let page = try? await client.library(cursor: nil, limit: 20, v2: ctx.capabilities.visibility) {
            for post in page.posts where found[post.id] == nil && ids.contains(post.id) { found[post.id] = ShortcutSave(post: post) }
        }
        return ids.compactMap { found[$0] }
    }

    /// `suggestedEntities()`: the first library page (20).
    public func suggestedSaves() async -> [ShortcutSave] {
        guard ctx.capabilities.library || !model.library.posts.isEmpty else { return [] }
        if let page = try? await ctx.client.library(cursor: nil, limit: 20, v2: ctx.capabilities.visibility) {
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

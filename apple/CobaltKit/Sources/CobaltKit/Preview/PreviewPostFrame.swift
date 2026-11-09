import Foundation
import Synchronization

// Post frames on the preview server (APP-API-CONTRACT 52): believable details for each style (invented posts, after the
// mockup's), Harmony's edits of them, and framed copies queued on the preview editor's clock.

/// What the preview server holds of post details: Harmony's edits, by item id, and every call.
final class PreviewPostFrameState: Sendable {
    private struct State {
        var edited: [String: PostDetails] = [:]
        var calls: [String] = []
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }
    func record(_ call: String) { state.withLock { $0.calls.append(call) } }
    func edited(_ id: String) -> PostDetails? { state.withLock { $0.edited[id] } }
    func store(_ details: PostDetails, for id: String) { state.withLock { $0.edited[id] = details } }
}

extension PreviewData {
    /// The details the preview server "looked up" for a link: one invented post per style. The second Instagram reel of the
    /// library (`Dd7P496wolG`) is a post that is gone (`found` false), so the sheet's "couldn't find the post" shows too.
    static func postDetails(link: URL?, now: Date) -> PostDetails {
        let raw = link?.absoluteString ?? "https://x.com/mochibytes/status/1987000000000000000"
        let hour = 3_600.0, day = 86_400.0
        switch PostFrameStyle(link: link ?? URL(string: raw)) {
        case .x:
            return PostDetails(
                link: raw, site: .x, found: true, name: "mochi", handle: "@mochibytes",
                text: "the cat learned to open the fridge and now we live in fear", postedAt: now.addingTimeInterval(-4 * hour),
                counts: PostCounts(likes: 18_000, reposts: 2_100, replies: 312, views: 402_000), verified: true)
        case .instagram:
            if raw.contains("Dd7P496wolG") {
                return PostDetails(link: raw, site: .instagram, found: false)
            }
            return PostDetails(
                link: raw, site: .instagram, found: true, name: "tofu.the.shiba", handle: "@tofu.the.shiba",
                text: "he heard the word walk from three rooms away", postedAt: now.addingTimeInterval(-2 * day),
                counts: PostCounts(likes: 24_118, comments: 381))
        case .twitch:
            return PostDetails(
                link: raw, site: .twitch, found: true, name: "nightowl_44", title: "he did NOT see that coming",
                channel: "pixelmaru", game: "Just Chatting", postedAt: now.addingTimeInterval(-3 * day),
                counts: PostCounts(views: 58_204))
        case .youtube:
            return PostDetails(
                link: raw, site: .youtube, found: true, handle: "@littlebuilds",
                text: "The full build, from cardboard to working tram line. Parts list below.",
                title: "I built a tiny city for my hamster (it took 6 months)", channel: "Little Builds",
                postedAt: now.addingTimeInterval(-365 * day),
                counts: PostCounts(likes: 84_000, views: 2_300_000, subscribers: 1_200_000))
        case .generic:
            return PostDetails(
                link: raw, site: .generic, found: true, name: "Aurora Field Notes", text: "No speed-up, no edits. Shot on a phone.",
                title: "Northern lights over the lake, real time", siteName: "vimeo", postedAt: now.addingTimeInterval(-60 * day))
        }
    }
}

extension PreviewClient {
    /// The library post that holds a file, and the file (the fixture page, then what the editor rendered).
    private func postFramePost(_ id: String) -> (post: LibraryPost?, file: LibraryFile?) {
        let now = clock.now()
        var posts = PreviewData.libraryPage(now: now).posts
        if scenario.hasEditor { posts += editorState.libraryPosts(now: now, timeScale: timeScale, scenario: scenario) }
        for post in posts {
            if let file = post.files.first(where: { $0.id == id }) { return (post, file) }
        }
        return (nil, nil)
    }

    /// `GET /library/items/<id>/post-details`: the post of the item's link; a file of the editor's preview projects (no post in
    /// the fixture page) reads as the X post. A render (`link` nil, made by the editor) is `noLink`.
    public func postDetails(item id: String, refresh: Bool) async throws -> PostDetails {
        postFrameState.record("DETAILS \(id)\(refresh ? " refresh" : "")")
        try await clock.sleep(seconds: (refresh ? 1.2 : 0.5) * timeScale)
        guard scenario.hasEditor else { throw PipelineFailure.unsupported }
        if let edited = postFrameState.edited(id) { return edited }
        let found = postFramePost(id)
        if let post = found.post, post.link == nil { throw PostFrameError.noLink }
        if found.post == nil, PreviewData.editorSources()[id] == nil { throw PostFrameError.notFound }
        return PreviewData.postDetails(link: found.post?.link, now: clock.now())
    }

    /// `PATCH /library/items/<id>/post-details`: the edit is kept for the rest of the run.
    public func setPostDetails(item id: String, _ patch: PostDetailsPatch) async throws -> PostDetails {
        postFrameState.record("PATCH \(id)")
        var details = try await postDetails(item: id, refresh: false)
        func apply(_ change: PostDetailsPatch.Change<String>, _ field: inout String?) {
            switch change {
            case .keep: break
            case .clear: field = nil
            case .set(let v): field = v
            }
        }
        apply(patch.name, &details.name)
        apply(patch.handle, &details.handle)
        apply(patch.text, &details.text)
        apply(patch.title, &details.title)
        apply(patch.channel, &details.channel)
        apply(patch.game, &details.game)
        switch patch.postedAt {
        case .keep: break
        case .clear: details.postedAt = nil
        case .set(let d): details.postedAt = d
        }
        details.edited = true
        postFrameState.store(details, for: id)
        return details
    }

    /// The preview posts have no stored avatars: the cards draw letter avatars.
    public func postAvatar(item id: String) async throws -> Data { throw PostFrameError.notFound }

    /// `POST /library/items/<id>/post-frame`: a framed copy on the preview editor's clock (the source's length, or the trim's).
    public func postFrame(item id: String, options: PostFrameOptions) async throws -> EditRender {
        postFrameState.record("FRAME \(id) \(options.style?.rawValue ?? "auto") \(options.theme.rawValue) \(options.canvas.rawValue)")
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasEditor else { throw PipelineFailure.unsupported }
        let found = postFramePost(id)
        let source = PreviewData.editorSources()[id]
        guard found.file != nil || source != nil else { throw PostFrameError.notFound }
        if let type = found.file?.contentType?.lowercased(), !type.hasPrefix("video/") { throw PostFrameError.notVideo }
        if let post = found.post, post.link == nil { throw PostFrameError.noLink }
        let length = found.file?.duration ?? source?.duration ?? 12
        let start = max(0, options.from ?? 0)
        let end = min(length, options.to ?? length)
        let seconds = min(PostFrameOptions.maxSeconds, max(0.5, end - start))
        let title = found.post?.customTitle ?? found.post?.title ?? source?.shortName ?? "video"
        let style = options.style ?? PostFrameStyle(link: found.post?.link)
        return try editorState.startPostRender(
            itemID: id, title: title, style: style, secondsTotal: seconds, now: clock.now(), timeScale: timeScale, scenario: scenario)
    }
}

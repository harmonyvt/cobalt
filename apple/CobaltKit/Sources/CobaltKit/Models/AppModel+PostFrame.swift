import Foundation

// Post frames (APP-API-CONTRACT 52): a saved video re-rendered inside a drawn card that reads like the post it came from. The
// item page's "post frame" sheet, the editor's "post" tool and the switch on save all end in `makePostFrame`; the framed copy
// is an editor render of kind `post`, watched here until its library post exists.

extension AppModel {
    /// The server makes framed copies (`features.post_frame`).
    public var canMakePostFrames: Bool { capabilities.postFrame }

    /// The library item a framed copy of this media frames: the video's own file on the server. Nil for a photo, a gallery,
    /// a webp-only post, or a media the server does not hold.
    public func postFrameSource(_ item: MediaItem) -> String? {
        guard item.kind == .video, let file = item.video?.file else { return nil }
        if let type = file.contentType?.lowercased(), !type.hasPrefix("video/") { return nil }
        return file.id
    }

    /// The item page shows "post frame": the server makes them, the media is a video on the server, and it was saved from
    /// a web page (uploads, renders and emotes have no post).
    public func canPostFrame(_ item: MediaItem) -> Bool {
        guard capabilities.postFrame, postFrameSource(item) != nil, let link = item.link,
              let scheme = link.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// The style the server would pick for this media (52.4).
    public func postFrameStyle(_ item: MediaItem) -> PostFrameStyle { PostFrameStyle(link: item.link) }

    /// "make framed copy" (52.2): queues the render. It joins the editor's renders at once (so the queue and the item page show
    /// it before the next poll) and is watched until it ends; once done, the library is read again so the copy appears.
    /// Throws `PostFrameError`, `EditError` (`.queueFull`, `.off`) or the transport's error; nothing is queued then.
    @discardableResult
    public func makePostFrame(itemID: String, options: PostFrameOptions) async throws -> EditRender {
        guard capabilities.postFrame else { throw PostFrameError.off }
        let render = try await ctx.client.postFrame(item: itemID, options: options)
        editor.mergeRenders([render])
        watchPostFrame(render)
        Task { await self.unifiedQueue.refresh() }
        return render
    }

    /// The framed copies of an item this device knows about that are still on their way, newest first.
    public func postFrameRenders(of itemID: String) -> [EditRender] {
        editor.renders.filter { $0.postItemID == itemID && ($0.isActive || $0.status == .error) }
    }

    /// The loaded library posts that are framed copies of an item (their file's `made_from` names it), newest first.
    public func framedCopies(of itemID: String) -> [LibraryPost] {
        library.posts.filter { post in
            post.files.contains { file in
                file.madeFrom.contains(itemID) && (file.madeSpec.map(\.isPostFrame) ?? (file.galleryRole == nil))
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// The style a framed copy was made in (its `made_spec`), when the server said.
    public func framedCopyStyle(_ post: LibraryPost) -> PostFrameStyle? {
        for file in post.files {
            if let style = file.madeSpec?.postFrame?.style { return style }
        }
        return nil
    }

    /// "open in editor for more" (52.6): a new project on this video, opened with its "post" tool up.
    public func openPostFrameInEditor(_ item: MediaItem) async throws {
        postFrames.postToolRequested = true
        do {
            _ = try await editor.create(from: [item])
        } catch {
            postFrames.postToolRequested = false
            throw error
        }
    }

    // MARK: watching

    /// Polls a framed copy's render (`GET /edits/renders/<rid>`) every 2 s, then 5 s after a minute, until it ends. Nothing
    /// to do for one that already ended, or one already watched.
    func watchPostFrame(_ render: EditRender) {
        let rid = render.id
        guard render.isActive, postFrames.watchers[rid] == nil else { return }
        guard let client = ctx.client as? any EditorClient else { return }
        let clock = ctx.clock
        postFrames.watchers[rid] = Task { @MainActor [weak self] in
            var polls = 0
            var last = render
            while !Task.isCancelled, last.isActive {
                try? await clock.sleep(seconds: polls < 30 ? 2 : 5)
                guard !Task.isCancelled else { break }
                polls += 1
                guard let fresh = try? await client.editRender(id: rid) else {
                    if polls > 400 { break }            // ~30 min of failures: the queue's own poll takes over
                    continue
                }
                last = fresh
                self?.editor.mergeRenders([fresh])
            }
            guard let self else { return }
            self.postFrames.watchers[rid] = nil
            if last.status == .done { await self.library.refresh() }
        }
    }

    // MARK: on save

    /// A video save finished (`Pipeline`, `PipelineContext.postFrameAfterSave`): with "post frame" on for the link's site, asks
    /// for a framed copy in that site's look (`fit`). Once per item; a refusal is logged, never shown (the plain video is
    /// always kept).
    func postFrameAfterSave(itemID: String, link: URL) {
        guard capabilities.postFrame else { return }
        let choice = settings.postFrameSaveChoice(for: PostFrameStyle(link: link))
        guard choice.on, !settings.postFrameAsked(itemID) else { return }
        settings.notePostFrameAsked(itemID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.makePostFrame(itemID: itemID, options: PostFrameOptions(theme: choice.theme, canvas: .fit))
            } catch {
                Telemetry.log(.error, .pipeline, "post frame on save failed", data: Telemetry.errorData(error))
            }
        }
    }
}

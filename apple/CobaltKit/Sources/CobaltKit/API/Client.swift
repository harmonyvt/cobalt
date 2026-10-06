import Foundation

public struct TransferProgress: Sendable, Equatable {
    public var bytes: Int64
    public var total: Int64?
}

public enum RemoteFile: Sendable, Equatable {
    case open(URL)                 // tunnel, redirect, picker item, public media: never sent the key
    case studioSource(session: String)
    case libraryItem(id: String)   // keyed
}

public protocol CobaltClient: Sendable {
    var baseURL: URL { get }
    func capabilities() async -> Capabilities
    func resolve(_ link: URL) async throws -> CobaltResult                         // POST /
    func createStudio(link: URL) async throws -> StudioCreated                    // POST /studio
    func upload(file: URL, name: String, contentType: String,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult  // PUT /studio/upload
    func session(_ id: String, wait: Int) async throws -> StudioSession          // GET /studio/<id>?wait=
    func sourceURL(session id: String) -> URL                                     // GET /studio/<id>/source (no key)
    func render(session id: String, _ request: RenderRequest) async throws -> String   // job id
    func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus
    func publish(session id: String) async throws -> HostedFile                  // POST /studio/<id>/publish
    func publish(item id: String) async throws -> HostedFile                     // POST /library/items/<id>/publish
    func openStudio(item id: String) async throws -> StudioCreated               // POST /library/items/<id>/studio
    func library(cursor: String?, limit: Int) async throws -> LibraryPage        // GET /library
    // One file per rendition, public or private (CONTRACT-VISIBILITY.md 6.1; APP-API-CONTRACT 16). The defaults
    // below forward to the calls above (or say the server cannot), so a client that predates them still compiles.
    /// `POST /studio` with `public` next to `url` (only when the server has `public_default`); nil omits the field.
    func createStudio(link: URL, public makePublic: Bool?) async throws -> StudioCreated
    /// `PUT /studio/upload` with `?public=1` when `makePublic` is true.
    func upload(file: URL, name: String, contentType: String, public makePublic: Bool?,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult
    /// `GET /library` with `v=2` when `v2` (only when the server has `features.visibility`): one entry per file.
    func library(cursor: String?, limit: Int, v2: Bool) async throws -> LibraryPage
    /// `PATCH /library/items/<id>/visibility {"public"}` (keyed): the file as it is now, and whether the edge cache
    /// was cleared. Idempotent. Throws `.unsupported` on a client or server that cannot.
    func setVisibility(item id: String, public makePublic: Bool) async throws -> VisibilityChange
    // The server's line (APP-API-CONTRACT section 17; `features.line`). Defaults forward to the calls above (queue
    // ignored) or say the server cannot, so a client that predates the line still compiles.
    /// `POST /studio` with `queue: true` (the answer says `queued` and `queue_ahead` instead of `429 error.studio.busy`)
    /// and the post's custom `title` (17.3; nil omits both).
    func createStudio(link: URL, public makePublic: Bool?, queue: Bool, title: String?) async throws -> StudioCreated
    /// `POST /library/items/<id>/studio` with `?queue=1` when `queue`.
    func openStudio(item id: String, queue: Bool) async throws -> StudioCreated
    /// `PUT /studio/upload` with `?queue=1` and `?title=` (17.3); an adopted session that had to wait is `queued`.
    func upload(file: URL, name: String, contentType: String, public makePublic: Bool?, queue: Bool, title: String?,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult
    /// `DELETE /studio/<id>/line`: cancels a save that has not started. `409 error.studio.started` is `.started`.
    func cancelQueued(session id: String) async throws -> QueueCancel
    /// `DELETE /studio/<id>/render/<job>`: cancels a render that has not started.
    func cancelQueued(session id: String, job: String) async throws -> QueueCancel
    /// `GET /studio/line` (keyed).
    func line() async throws -> ServerLineSnapshot
    /// `PUT /studio/line/notify`: one Hark message when everything this key has in flight is done (17.8). Returns how
    /// many jobs the server watches (0 = nothing in flight, or no notify bridge).
    func setLineNotify() async throws -> Int
    /// `DELETE /studio/line/notify` (idempotent).
    func cancelLineNotify() async throws
    func deleteMedia(name: String) async throws                                   // DELETE /media/<name>
    /// `DELETE /library/items/<id>/post` (CONTRACT-MEDIA 6.1), only when `features.delete_post`: deletes
    /// the whole post the file `itemID` belongs to. A partial result is returned, not thrown.
    func deletePost(anchor itemID: String) async throws -> PostDeleteResult
    /// `PATCH /library/items/<id>/post` (CONTRACT-LIBRARY2 4.2), only when `features.titles`: sets (or, with
    /// nil, clears) the custom title of the post the file `itemID` belongs to. The caller sends a title
    /// that `MediaTitle.clean` already accepted.
    func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult
    // Live Activities (APP-API-CONTRACT section 8; keyed; the server never wakes its container for these)
    func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws   // PUT /live/start-token
    func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply                // PUT /live/runs/<run>
    func relayLiveState(run: UUID, _ state: LiveContentState) async throws                     // POST /live/runs/<run>/state
    func endLiveRun(_ run: UUID) async throws                                                  // DELETE /live/runs/<run>
    func liveSelftest() async throws -> LiveSelftest                                           // GET /live/selftest
    // Notify bridge (APP-API-CONTRACT section 9; keyed; for a build with no APNs). Defaults do nothing
    // so a client that predates the bridge keeps compiling.
    func setNotify(session id: String, _ optIn: NotifyOptIn) async throws                     // PUT /studio/<id>/notify
    func cancelNotify(session id: String) async throws                                          // DELETE /studio/<id>/notify
    func download(_ file: RemoteFile, to destination: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL
    // Photos and galleries (APP-API-CONTRACT 18.2, 18.4, 18.5, 18.10-18.13; `features.gallery`, `features.gallery_make`).
    // Defaults forward to the calls above or say the server cannot, so a client that predates galleries still compiles.
    /// `POST /studio` with everything `options` carries: `items`, `item_count`, the share sheet's chained `slideshow`
    /// or `gallery_image` (18.12), `origin`, `notify`. Without gallery fields it is the plain create.
    func createStudio(url: URL, options: StudioCreateOptions) async throws -> StudioCreated
    /// `POST /studio/<sid>/slideshow` (keyed): a slideshow webp or mp4 of the post's items. `items` are the post's items
    /// as known (their types make the wire's `seconds`: a number for a photo, `null` for a video or gif). `focused`
    /// puts it ahead of every waiting save (`priority: "focused"`, only with the server's line).
    func makeSlideshow(session: String, plan: SlideshowPlan, items: [GalleryItem], focused: Bool, notify: Bool) async throws -> RenderAccepted
    /// `POST /studio/<sid>/gallery-image` (keyed): the borderless gallery image. `plan.items` must be photos.
    func makeGalleryImage(session: String, plan: GalleryImagePlan, focused: Bool, notify: Bool) async throws -> RenderAccepted
    /// `GET /studio/<sid>/render/<job>` of a slideshow or gallery-image make: the phase, then the made file's row.
    func makeStatus(session: String, job: String, wait: Int) async throws -> MakeStatus
    /// `POST /studio/<sid>/items/retry` (keyed): fetch only these indices again (a save job in the line).
    func retryItems(session: String, items: [Int]) async throws -> StudioCreated
    /// `DELETE /library/items/<id>` (keyed): one item, slideshow, crop or export. The last item of a post is
    /// `409 error.library.last_item` (use `deletePost`).
    func deleteItem(_ itemID: String) async throws
    /// `PUT /library/items/<id>/made` (keyed, 18.6): a file made on the device from the item `itemID` (a crop: `role .crop`,
    /// an `image/jpeg` body, `spec` the JSON of `made_spec`, at most 512 bytes). The row joins the post and follows its
    /// public/private switch. Nothing changes on the server when it throws.
    func uploadMade(
        item itemID: String, role: GalleryRole, file: URL, contentType: String, name: String, spec: Data,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> MadeUpload
    /// `PATCH /library/items/<id>/visibility {"public", "scope": "post"}` (keyed): the whole post's files at once.
    func setPostVisibility(anchor itemID: String, public makePublic: Bool) async throws -> VisibilityResult
    /// `GET /library` with `v=3` when `v3` (only when the server has `features.gallery`): `v=2` plus gallery items,
    /// made files and each post's `kind`.
    func library(cursor: String?, limit: Int, v3: Bool) async throws -> LibraryPage
}

extension CobaltClient {
    public func createStudio(link: URL, public makePublic: Bool?) async throws -> StudioCreated {
        try await createStudio(link: link)
    }
    public func upload(
        file: URL, name: String, contentType: String, public makePublic: Bool?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        try await upload(file: file, name: name, contentType: contentType, progress: progress)
    }
    public func library(cursor: String?, limit: Int, v2: Bool) async throws -> LibraryPage {
        try await library(cursor: cursor, limit: limit)
    }
    public func setVisibility(item id: String, public makePublic: Bool) async throws -> VisibilityChange {
        throw PipelineFailure.unsupported
    }
    public func createStudio(link: URL, public makePublic: Bool?, queue: Bool, title: String?) async throws -> StudioCreated {
        try await createStudio(link: link, public: makePublic)
    }
    public func openStudio(item id: String, queue: Bool) async throws -> StudioCreated {
        try await openStudio(item: id)
    }
    public func upload(
        file: URL, name: String, contentType: String, public makePublic: Bool?, queue: Bool, title: String?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        try await upload(file: file, name: name, contentType: contentType, public: makePublic, progress: progress)
    }
    public func cancelQueued(session id: String) async throws -> QueueCancel { throw PipelineFailure.unsupported }
    public func cancelQueued(session id: String, job: String) async throws -> QueueCancel { throw PipelineFailure.unsupported }
    public func line() async throws -> ServerLineSnapshot { throw PipelineFailure.unsupported }
    public func setLineNotify() async throws -> Int { 0 }
    public func cancelLineNotify() async throws {}
    public func setNotify(session id: String, _ optIn: NotifyOptIn) async throws {}
    public func cancelNotify(session id: String) async throws {}
    public func createStudio(url: URL, options: StudioCreateOptions) async throws -> StudioCreated {
        guard options.isPlain else { throw PipelineFailure.unsupported }
        return try await createStudio(link: url, public: options.makePublic, queue: options.queue, title: options.title)
    }
    public func makeSlideshow(session: String, plan: SlideshowPlan, items: [GalleryItem], focused: Bool, notify: Bool) async throws -> RenderAccepted {
        throw PipelineFailure.unsupported
    }
    public func makeGalleryImage(session: String, plan: GalleryImagePlan, focused: Bool, notify: Bool) async throws -> RenderAccepted {
        throw PipelineFailure.unsupported
    }
    public func makeStatus(session: String, job: String, wait: Int) async throws -> MakeStatus { throw PipelineFailure.unsupported }
    public func retryItems(session: String, items: [Int]) async throws -> StudioCreated { throw PipelineFailure.unsupported }
    public func deleteItem(_ itemID: String) async throws { throw PipelineFailure.unsupported }
    public func uploadMade(
        item itemID: String, role: GalleryRole, file: URL, contentType: String, name: String, spec: Data,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> MadeUpload {
        throw PipelineFailure.unsupported
    }
    public func setPostVisibility(anchor itemID: String, public makePublic: Bool) async throws -> VisibilityResult {
        throw PipelineFailure.unsupported
    }
    public func library(cursor: String?, limit: Int, v3: Bool) async throws -> LibraryPage {
        try await library(cursor: cursor, limit: limit, v2: v3)
    }
    /// A client that predates the route says the server cannot do it.
    public func deletePost(anchor itemID: String) async throws -> PostDeleteResult { throw PipelineFailure.unsupported }
    /// Likewise: a client that predates titles says the server cannot do it.
    public func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult { throw PipelineFailure.unsupported }
}

extension CobaltClient {
    /// `makeSlideshow` without a Hark opt-in.
    public func makeSlideshow(session: String, plan: SlideshowPlan, items: [GalleryItem], focused: Bool) async throws -> RenderAccepted {
        try await makeSlideshow(session: session, plan: plan, items: items, focused: focused, notify: false)
    }
    /// `makeGalleryImage` without a Hark opt-in.
    public func makeGalleryImage(session: String, plan: GalleryImagePlan, focused: Bool) async throws -> RenderAccepted {
        try await makeGalleryImage(session: session, plan: plan, focused: focused, notify: false)
    }
}

/// What `PATCH /library/items/<id>/post` answers: `{"status":"success","post":"<post key>","title":"…"|null}`.
public struct PostTitleResult: Sendable, Equatable, Decodable {
    public var post: String
    public var title: String?          // nil = the custom title is cleared

    public init(post: String, title: String?) {
        self.post = post
        self.title = title
    }
}

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
    /// A client that predates the route says the server cannot do it.
    public func deletePost(anchor itemID: String) async throws -> PostDeleteResult { throw PipelineFailure.unsupported }
    /// Likewise: a client that predates titles says the server cannot do it.
    public func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult { throw PipelineFailure.unsupported }
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

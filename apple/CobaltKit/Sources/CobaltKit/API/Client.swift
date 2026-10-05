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

import Foundation
import Observation

/// Why the details of a post could not be read.
public enum PostDetailsProblem: Sendable, Equatable {
    /// The item has no link (an upload, a render): nothing to frame it in.
    case noLink
    /// The item is gone.
    case notFound
    /// The server has no post frames.
    case off
    /// No network, or the server did not answer.
    case offline
    /// Anything else.
    case failed

    init(_ error: Error) {
        switch error {
        case PostFrameError.noLink, PostFrameError.notVideo: self = .noLink
        case PostFrameError.notFound: self = .notFound
        case PostFrameError.off, PipelineFailure.unsupported: self = .off
        case CobaltError.network: self = .offline
        default: self = .failed
        }
    }
}

/// What the app knows of one item's post (APP-API-CONTRACT 52.2), by library item id.
public enum PostDetailsState: Sendable, Equatable {
    case loading
    case loaded(PostDetails)
    case failed(PostDetailsProblem)

    public var details: PostDetails? {
        if case .loaded(let d) = self { return d }
        return nil
    }
}

/// Post frames (APP-API-CONTRACT 52): the details of the posts the screens asked about, their avatars, and the framed copies
/// this device is watching. `AppModel.postFrames`; the calls that make a framed copy are on `AppModel` (`AppModel+PostFrame`).
@MainActor @Observable
public final class PostFrameStore {
    /// By library item id.
    public private(set) var details: [String: PostDetailsState] = [:]
    /// Avatar bytes, by library item id (the picture is keyed: `GET …/post-details/avatar`).
    public private(set) var avatars: [String: Data] = [:]
    /// "open in editor for more" made a project: the editor opens its "post" tool once it is up, and clears this.
    public var postToolRequested = false

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var avatarLoads: Set<String> = []
    /// Framed copies being polled, by render id.
    @ObservationIgnored var watchers: [String: Task<Void, Never>] = [:]

    init(context: PipelineContext) {
        self.ctx = context
    }

    public func state(for itemID: String) -> PostDetailsState? { details[itemID] }

    /// `GET /library/items/<id>/post-details` (a lookup when the server has none yet). Loaded details stay shown while a
    /// refresh runs; a failed refresh keeps them. Fetches the avatar when there is one.
    public func load(itemID: String, refresh: Bool = false) async {
        let started = generation
        let had = details[itemID]?.details
        if had == nil { details[itemID] = .loading }
        do {
            let fresh = try await ctx.client.postDetails(item: itemID, refresh: refresh)
            guard started == generation else { return }
            details[itemID] = .loaded(fresh)
            await loadAvatar(itemID: itemID, details: fresh)
        } catch {
            guard started == generation else { return }
            if had == nil { details[itemID] = .failed(PostDetailsProblem(error)) }
        }
    }

    /// Loads the details unless they are here (or on their way).
    public func loadIfNeeded(itemID: String) async {
        switch details[itemID] {
        case .loaded?, .loading?: return
        case .failed?, nil: await load(itemID: itemID)
        }
    }

    /// `PATCH /library/items/<id>/post-details`: the fields saved for good. Nothing is sent for an empty patch.
    @discardableResult
    public func save(itemID: String, _ patch: PostDetailsPatch) async throws -> PostDetails? {
        guard !patch.isEmpty else { return details[itemID]?.details }
        let fresh = try await ctx.client.setPostDetails(item: itemID, patch)
        details[itemID] = .loaded(fresh)
        return fresh
    }

    /// The avatar's bytes, once per item and session (a failure leaves the letter avatar).
    private func loadAvatar(itemID: String, details: PostDetails) async {
        guard details.avatarURL != nil, avatars[itemID] == nil, !avatarLoads.contains(itemID) else { return }
        avatarLoads.insert(itemID)
        let started = generation
        guard let data = try? await ctx.client.postAvatar(item: itemID), started == generation else { return }
        avatars[itemID] = data
    }

    /// The server or key changed: forget everything of the old one.
    func reset() {
        generation += 1
        details = [:]
        avatars = [:]
        avatarLoads = []
        postToolRequested = false
        for task in watchers.values { task.cancel() }
        watchers = [:]
    }
}

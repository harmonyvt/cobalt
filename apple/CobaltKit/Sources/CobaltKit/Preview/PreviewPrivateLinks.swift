import Foundation
import Synchronization

// Private share links in previews (APP-API-CONTRACT 36): the share-link server (`hasShareLinks`) also has
// `features.private_links`. It starts with no private link and `new_links` public (so the share-link fixtures read as
// before); a preview turns one on (`PreviewData.privateSampleSetID`). Rotating gives a new key and the old one is gone;
// making a file public (the section 16 switch) revokes its key, as the server does.

extension PreviewData {
    /// The gallery link the previews make private (the untitled two-webp one).
    static let privateSampleSetID = "9000000000000000002"
}

/// What the preview "server" holds for `/share/private`, and every call made (`"PUT set <id>"`, `"ROTATE item <id>"`).
final class PreviewPrivateState: Sendable {
    private struct State {
        var links: [String: PrivateLink] = [:]
        var newLinks: NewLinks = .public
        var counter = 0
        var calls: [String] = []
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }

    func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    /// 22 base62 characters, different for every key the preview makes.
    static func key(_ n: Int) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var x = UInt64(truncatingIfNeeded: n &* 2_654_435_761 &+ 0x9E37_79B9)
        var out = ""
        for _ in 0..<22 {
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            out.append(alphabet[Int((x >> 33) % 62)])
        }
        return out
    }

    static func url(_ key: String) -> URL { PreviewData.shareBase.appendingPathComponent("p").appendingPathComponent(key) }

    private func make(_ s: inout State, _ kind: PrivateLink.Kind, _ id: String, now: Date) -> PrivateLink {
        s.counter += 1
        let link = PrivateLink(kind: kind, targetID: id, url: Self.url(Self.key(s.counter)), createdAt: now)
        s.links[link.id] = link
        return link
    }

    func list(now: Date) -> PrivateLinkList {
        state.withLock { s in
            return PrivateLinkList(links: s.links.values.sorted { $0.createdAt > $1.createdAt }, newLinks: s.newLinks)
        }
    }

    func link(_ kind: PrivateLink.Kind, _ id: String, now: Date) -> PrivateLink? {
        state.withLock { s in
            return s.links[PrivateLink.id(kind, id)]
        }
    }

    /// On: the live link, unchanged, or a new one.
    func enable(_ kind: PrivateLink.Kind, _ id: String, now: Date) -> PrivateLink {
        state.withLock { s in
            if let live = s.links[PrivateLink.id(kind, id)] { return live }
            return make(&s, kind, id, now: now)
        }
    }

    func revoke(_ kind: PrivateLink.Kind, _ id: String) {
        state.withLock { s in s.links[PrivateLink.id(kind, id)] = nil }
    }

    /// A new key; nil when none is live.
    func rotate(_ kind: PrivateLink.Kind, _ id: String, now: Date) -> PrivateLink? {
        state.withLock { s in
            guard s.links[PrivateLink.id(kind, id)] != nil else { return nil }
            return make(&s, kind, id, now: now)
        }
    }

    func rotateAll(now: Date) -> PrivateLinkRotation {
        state.withLock { s in
            let live = s.links.values.sorted { $0.createdAt > $1.createdAt }
            var fresh: [PrivateLink] = []
            for old in live { fresh.append(make(&s, old.kind, old.targetID, now: now)) }
            return PrivateLinkRotation(links: fresh, rotated: fresh.count)
        }
    }

    var newLinks: NewLinks {
        get { state.withLock { $0.newLinks } }
        set { state.withLock { $0.newLinks = newValue } }
    }

    /// `file` as the "server" lists it: with a live key it is not public and carries `private_url`.
    func applying(to file: LibraryFile, now: Date) -> LibraryFile {
        guard let link = link(.item, file.id, now: now) else { return file }
        var out = file
        out.privateURL = link.url
        out.wireVisibility = .private
        out.url = nil
        return out
    }

    /// `set` as the "server" lists it: `private`, `public_url`, `link`, and `url` the live one.
    func applying(to set: ShareSet, now: Date) -> ShareSet {
        var out = set
        let pub = PreviewData.shareURL(id: set.id)
        out.publicURL = pub
        if let link = link(.set, set.id, now: now) {
            out.isPrivate = true
            out.link = link
            out.url = link.url
        } else {
            out.isPrivate = false
            out.link = nil
            out.url = pub
        }
        return out
    }
}

extension PreviewClient {
    /// `GET /share/private`.
    public func privateLinks() async throws -> PrivateLinkList {
        privateState.record("GET")
        try await clock.sleep(seconds: 0.2 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        return privateState.list(now: clock.now())
    }

    /// `PUT /share/private/items|sets/<id>`: a file must be listed and take the switch (a public one goes off first); a
    /// gallery link must be live.
    public func enablePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws -> PrivateLink {
        privateState.record("PUT \(kind.rawValue) \(id)")
        try await clock.sleep(seconds: 0.4 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        switch kind {
        case .item:
            let files = try await library(cursor: nil, limit: 100, v2: visibility != .off).posts.flatMap(\.files)
            guard let file = files.first(where: { $0.id == id }) else { throw PrivateLinkError.notFound }
            guard file.canToggleVisibility else { throw PrivateLinkError.notToggleable }
            if file.isPublic, visibility != .off { _ = visibilityState.set(file, public: false) }
        case .set:
            guard shareState.sets.contains(where: { $0.id == id }) else { throw PrivateLinkError.notFound }
        }
        return privateState.enable(kind, id, now: clock.now())
    }

    /// `DELETE /share/private/items|sets/<id>`: none live is still fine.
    public func revokePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws {
        privateState.record("DELETE \(kind.rawValue) \(id)")
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        privateState.revoke(kind, id)
    }

    /// `POST /share/private/items|sets/<id>/rotate`: `.notFound` when none is live.
    public func rotatePrivateLink(_ kind: PrivateLink.Kind, id: String) async throws -> PrivateLink {
        privateState.record("ROTATE \(kind.rawValue) \(id)")
        try await clock.sleep(seconds: 0.3 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard let link = privateState.rotate(kind, id, now: clock.now()) else { throw PrivateLinkError.notFound }
        return link
    }

    /// `POST /share/private/rotate-all`.
    public func rotateAllPrivateLinks() async throws -> PrivateLinkRotation {
        privateState.record("ROTATE all")
        try await clock.sleep(seconds: 0.5 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        return privateState.rotateAll(now: clock.now())
    }

    /// `PATCH /share/private/settings`.
    public func setNewLinks(_ value: NewLinks) async throws -> NewLinks {
        privateState.record("PATCH \(value.rawValue)")
        try await clock.sleep(seconds: 0.2 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        privateState.newLinks = value
        return value
    }

    /// `POST /share/collections/<id>/privacy`: every live link of the collection; answers their private links after.
    public func setCollectionPrivacy(id: String, _ change: CollectionPrivacy) async throws -> [PrivateLink] {
        privateState.record("PRIVACY \(id)")
        try await clock.sleep(seconds: 0.5 * timeScale)
        guard scenario.hasShareLinks else { throw PipelineFailure.unsupported }
        guard let collection = shareState.collections.first(where: { $0.id == id }) else { throw ShareCollectionError.notFound }
        let now = clock.now()
        let live = collection.setIDs.filter { sid in shareState.sets.contains { $0.id == sid } }
        var links: [PrivateLink] = []
        for sid in live {
            switch change {
            case .makePrivate: links.append(privateState.enable(.set, sid, now: now))
            case .makePublic: privateState.revoke(.set, sid)
            case .rotate:
                if let link = privateState.rotate(.set, sid, now: now) { links.append(link) }
            }
        }
        return links
    }
}

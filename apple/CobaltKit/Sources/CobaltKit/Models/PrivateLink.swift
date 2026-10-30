import Foundation

// Private share links (APP-API-CONTRACT 36): a post's file or a gallery link can have a link with a key inside it,
// `<share_base_url>p/<key>`. While it is live the public address of the same thing is a 404 and the private link is the
// only way in; rotating makes a new key and the old one is a 404 at once. The wire shapes of `/share/private`, the
// three states the app calls a file's link, and the refusals. Not the MCP's private link (35.5, `McpSettings`).

/// One live private link (`<link>` in 36.3).
public struct PrivateLink: Sendable, Equatable, Identifiable, Decodable {
    /// `item`: a library file (`media_items`); `set`: a gallery link (`share_sets`).
    public enum Kind: String, Sendable, Equatable, Decodable {
        case item, set
    }

    public var kind: Kind
    /// The library file id or the gallery link id.
    public var targetID: String
    /// `<share_base_url>p/<key>`: what the owner copies.
    public var url: URL
    /// When this key was made (a rotate makes a new one).
    public var createdAt: Date
    /// Page opens (GETs of the page, not file fetches).
    public var opened: Int
    public var lastOpenedAt: Date?

    /// `item:<id>` / `set:<id>`: one live link per thing.
    public var id: String { Self.id(kind, targetID) }

    public static func id(_ kind: Kind, _ targetID: String) -> String { "\(kind.rawValue):\(targetID)" }

    public init(kind: Kind, targetID: String, url: URL, createdAt: Date, opened: Int = 0, lastOpenedAt: Date? = nil) {
        self.kind = kind
        self.targetID = targetID
        self.url = url
        self.createdAt = createdAt
        self.opened = opened
        self.lastOpenedAt = lastOpenedAt
    }

    enum CodingKeys: String, CodingKey {
        case kind, url, createdAt, opened, lastOpenedAt
        case targetID = "targetId"           // `target_id` after convertFromSnakeCase
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        targetID = try c.decode(String.self, forKey: .targetID)
        url = try c.decode(URL.self, forKey: .url)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        opened = (try? c.decodeIfPresent(Int.self, forKey: .opened)) ?? 0
        lastOpenedAt = (try? c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)) ?? nil
    }

    static func decode(_ data: Data) throws -> PrivateLink {
        try CobaltJSON.decoder().decode(PrivateLink.self, from: data)
    }
}

/// `share_settings.new_links`: what a new gallery link starts as when the request does not say.
public enum NewLinks: String, Sendable, Equatable, CaseIterable, Decodable {
    case `public`, `private`

    /// A word this build does not know reads as `public` (the server's own default).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NewLinks(rawValue: raw) ?? .public
    }
}

/// `GET /share/private`: every live link, newest first, and what new gallery links start as.
public struct PrivateLinkList: Sendable, Equatable, Decodable {
    public var links: [PrivateLink]
    public var newLinks: NewLinks

    public init(links: [PrivateLink] = [], newLinks: NewLinks = .public) {
        self.links = links
        self.newLinks = newLinks
    }

    enum CodingKeys: String, CodingKey { case links, newLinks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        links = ((try? c.decodeIfPresent([Lossy<PrivateLink>].self, forKey: .links)) ?? nil)?.compactMap(\.value) ?? []
        newLinks = ((try? c.decodeIfPresent(NewLinks.self, forKey: .newLinks)) ?? nil) ?? .public
    }

    static func decode(_ data: Data) throws -> PrivateLinkList {
        try CobaltJSON.decoder().decode(PrivateLinkList.self, from: data)
    }
}

/// `POST /share/private/rotate-all`: every live link with its new key, and how many were rotated.
public struct PrivateLinkRotation: Sendable, Equatable, Decodable {
    public var links: [PrivateLink]
    public var rotated: Int

    public init(links: [PrivateLink], rotated: Int) {
        self.links = links
        self.rotated = rotated
    }

    enum CodingKeys: String, CodingKey { case links, rotated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        links = ((try? c.decodeIfPresent([Lossy<PrivateLink>].self, forKey: .links)) ?? nil)?.compactMap(\.value) ?? []
        rotated = ((try? c.decodeIfPresent(Int.self, forKey: .rotated)) ?? nil) ?? links.count
    }
}

/// What `POST /share/collections/<id>/privacy` does to every live gallery link of a collection.
public enum CollectionPrivacy: Sendable, Equatable {
    /// `{"private": true}`: turns on the ones that are not.
    case makePrivate
    /// `{"private": false}`: revokes them; each is public again at `share…/g/<id>`.
    case makePublic
    /// `{"rotate": true}`: a new key for each live one.
    case rotate

    var body: [String: Any] {
        switch self {
        case .makePrivate: return ["private": true]
        case .makePublic: return ["private": false]
        case .rotate: return ["rotate": true]
        }
    }
}

/// A file's link, as the app names its three states (36.2): `off` (not public, no private link), `public` (the share
/// page and the media URL work), `private` (only the private link works; the file is not public).
public enum FileLink: String, Sendable, Equatable, CaseIterable {
    case off, `public`, `private`
}

/// What the private-link routes answer when they refuse (mapped from the wire in `HTTPCobaltClient+PrivateLinks`).
public enum PrivateLinkError: Error, Sendable, Equatable {
    /// `404 error.private.not_found`: no such live file or gallery link, or (rotate) no live private link.
    case notFound
    /// `409 error.private.not_toggleable`: the section 16 switch does not take this file.
    case notToggleable
    /// `400 error.private.bad_request`.
    case badRequest
    /// `503 error.api.generic`: migration 0024 is not applied, or the server cannot take it right now.
    case unavailable
}

extension LibraryFile {
    /// The file's link: private while it has a live private link, else public or off.
    public var linkState: FileLink {
        if privateURL != nil { return .private }
        return isPublic ? .public : .off
    }
}

extension Rendition {
    /// The live private link of this rendition's file (the original's for a video), nil when it has none.
    public var privateURL: URL? { file?.privateURL ?? hosted?.privateURL }

    /// The rendition's link: private, public or off.
    public var fileLink: FileLink {
        if privateURL != nil { return .private }
        return isPublic ? .public : .off
    }
}

extension Capabilities {
    /// The link to hand out for a rendition (36.6: copy, share sheet, keyboard, Shortcuts): its private link when it has
    /// one, else its public share link, else nil.
    public func liveLink(for rendition: Rendition) -> URL? {
        if let key = rendition.privateURL { return key }
        return rendition.publicURL.map(shareLink(for:))
    }
}

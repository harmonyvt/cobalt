import Foundation

// Gallery share links (APP-API-CONTRACT section 24): 2..4 public library files under one link,
// `<share_base_url>g/<id>`. The wire shapes, the one rule the library's select bar and the server share, and the
// errors the three routes answer.

/// One link: its files in the order shown (`GET /share/sets`, `POST /share/sets`).
public struct ShareSet: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    /// `<share_base_url>g/<id>`: what the owner copies.
    public var url: URL
    /// The title the owner gave (1..80 characters); nil when none.
    public var title: String?
    public var createdAt: Date
    public var items: [ShareSetItem]
    /// `private` (APP-API-CONTRACT 36.3): the link has a live private link, so `url` is that one and the public address
    /// `share…/g/<id>` is a 404. False from a server without private links.
    public var isPrivate: Bool
    /// `public_url`: `<share_base_url>g/<id>`, the address while the link is public. Nil from an older server.
    public var publicURL: URL?
    /// `link`: the live private link while private (its opens, when its key was made); nil while public.
    public var link: PrivateLink?

    public init(
        id: String, url: URL, title: String? = nil, createdAt: Date, items: [ShareSetItem],
        isPrivate: Bool = false, publicURL: URL? = nil, link: PrivateLink? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
        self.items = items
        self.isPrivate = isPrivate
        self.publicURL = publicURL
        self.link = link
    }

    /// The title, else "N files".
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "\(items.count) files"
    }

    /// How many of the files are still public (a set whose files all went private stays listed until revoked).
    public var publicItemCount: Int { items.filter(\.isPublic).count }

    enum CodingKeys: String, CodingKey {
        case id, url, title, createdAt, items, link
        case isPrivate = "private"
        case publicURL = "publicUrl"           // `public_url` after convertFromSnakeCase
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        items = (try c.decodeIfPresent([Lossy<ShareSetItem>].self, forKey: .items) ?? []).compactMap(\.value)
        // 36.3, all lenient: a server without private links sends none of these
        link = (try? c.decodeIfPresent(PrivateLink.self, forKey: .link)) ?? nil
        isPrivate = ((try? c.decodeIfPresent(Bool.self, forKey: .isPrivate)) ?? nil) ?? (link != nil)
        publicURL = (try? c.decodeIfPresent(URL.self, forKey: .publicURL)) ?? nil
    }

    /// The link as it is once its private link is on: `url` is the private one.
    func makingPrivate(_ link: PrivateLink) -> ShareSet {
        var s = self
        if s.publicURL == nil, !s.isPrivate { s.publicURL = s.url }
        s.isPrivate = true
        s.link = link
        s.url = link.url
        return s
    }

    /// The link as it is once its private link is revoked: public again at `share…/g/<id>` (`fallback` when the server
    /// never said its public address).
    func makingPublic(fallback: URL?) -> ShareSet {
        var s = self
        s.isPrivate = false
        s.link = nil
        if let pub = s.publicURL ?? fallback { s.url = pub }
        return s
    }
}

/// One file of a set. `url` is nil once the file is no longer public (or was deleted).
public struct ShareSetItem: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    public var url: URL?
    public var contentType: String?
    public var posterURL: URL?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    /// `hidden` (APP-API-CONTRACT 37.2): the file's post is hidden, so the link leaves it out (`url` is null too).
    /// False when absent.
    public var hidden: Bool

    public init(
        id: String, url: URL? = nil, contentType: String? = nil, posterURL: URL? = nil,
        width: Int? = nil, height: Int? = nil, duration: Double? = nil, hidden: Bool = false
    ) {
        self.id = id
        self.url = url
        self.contentType = contentType
        self.posterURL = posterURL
        self.width = width
        self.height = height
        self.duration = duration
        self.hidden = hidden
    }

    /// The still to draw: the poster, else the file itself when it is an image (a photo or a webp); nil for a video
    /// with no poster or a file that is no longer public.
    public var thumbnailURL: URL? {
        if let posterURL { return posterURL }
        if contentType?.lowercased().hasPrefix("image/") == true { return url }
        return nil
    }

    /// The file is still public (the server sends `url: null` otherwise).
    public var isPublic: Bool { url != nil }

    /// The file is a video (by its content type).
    public var isVideo: Bool { contentType?.lowercased().hasPrefix("video/") == true }

    enum CodingKeys: String, CodingKey {
        case id, url, contentType, width, height, duration, hidden
        case posterURL = "posterUrl"           // `poster_url` after convertFromSnakeCase
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = (try? c.decodeIfPresent(URL.self, forKey: .url)) ?? nil
        contentType = (try? c.decodeIfPresent(String.self, forKey: .contentType)) ?? nil
        posterURL = (try? c.decodeIfPresent(URL.self, forKey: .posterURL)) ?? nil
        width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? nil
        height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? nil
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? nil
        hidden = ((try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? nil) ?? false
    }
}

/// What the three share routes answer when they refuse (mapped from the wire in `HTTPCobaltClient`).
public enum ShareSetError: Error, Sendable, Equatable {
    /// `409 error.share.not_public`: these library file ids are missing or private now.
    case notPublic([String])
    /// `400 error.share.bad_request`: not 2..4 distinct ids, a bad shape or a title over 80 characters.
    case badRequest
    /// `404 error.share.not_found`: the set is not (or no longer) there.
    case notFound
    /// `503 error.api.generic`: the server cannot take it right now.
    case unavailable
    /// `409 error.share.changed` (APP-API-CONTRACT 41.1): the link's files are not the ones the client last saw
    /// (`expect`), so nothing was written. Carries the link as it is now.
    case changed(ShareSet)
    /// `409 error.hidden` (APP-API-CONTRACT 37.2): these library file ids belong to hidden posts and never go in a link.
    case hidden([String])
}

/// What `PATCH /share/sets/<id>` does with a link's title (APP-API-CONTRACT 41.1).
public enum ShareSetTitleChange: Sendable, Equatable {
    /// The field is left out: the title stays.
    case keep
    /// A new title (trimmed, 1..80 characters).
    case set(String)
    /// `null`: no title, so the roast caption shows again.
    case clear
}

/// What the select bar says about a pick.
public enum ShareSetVerdict: Sendable, Equatable {
    /// 2..max files, all public: the button works.
    case ready
    /// Fewer than 2 files picked.
    case tooFew
    /// More than `max` files picked.
    case tooMany(max: Int)
    /// This many of the picked files are private.
    case notPublic(count: Int)
}

/// The one rule of a share set, shared by the library's select bar and the tests (the server enforces the same).
public enum ShareSetRule {
    /// A set holds at least this many files.
    public static let minimum = 2
    /// `limits.share_set_max` when the server does not say.
    public static let defaultMaximum = 4
    /// The title the server takes: 1..80 characters.
    public static let titleLimit = 80

    /// `publicFlags`: one Bool per picked file, true when that file is public now. Order of checks: too many, too
    /// few, then private files (so five picks with one private file say "too many", not "private").
    public static func verdict(publicFlags: [Bool], max: Int) -> ShareSetVerdict {
        let cap = Swift.max(minimum, max)
        if publicFlags.count > cap { return .tooMany(max: cap) }
        if publicFlags.count < minimum { return .tooFew }
        let privateCount = publicFlags.filter { !$0 }.count
        if privateCount > 0 { return .notPublic(count: privateCount) }
        return .ready
    }

    /// The library file id that stands for a whole post in a set, or nil when the post has no public file (or is a
    /// gallery, which the library cannot tick).
    ///
    /// The choice, in order: the post's `face` (what the library draws it as: the newest animated webp, else the
    /// slideshow, else the original) when that rendition has a public file; otherwise the post's original (the
    /// `.video` rendition: the video, or a single photo); otherwise the newest of the other renditions that has a
    /// public file (a webp, a slideshow, a made file). A rendition's public file is its `file` when that is public,
    /// else its `hosted` link when that is public. A file is public when its `visibility` says so
    /// (`LibraryFile.isPublic`) and it has a link.
    public static func fileID(for item: MediaItem) -> String? {
        if item.kind == .gallery { return nil }
        if let id = publicFile(of: item.face)?.id { return id }
        if let video = item.video, let id = publicFile(of: video)?.id { return id }
        let others = item.renditions
            .filter { !$0.isItem }
            .sorted { $0.createdAt > $1.createdAt }
        for rendition in others {
            if let id = publicFile(of: rendition)?.id { return id }
        }
        return nil
    }

    /// The library file id that stands for a post in a PRIVATE link (APP-API-CONTRACT 36.3: any live file, public or
    /// not): `fileID(for:)` when the post has a public file, else the same order over every file the post has (the
    /// face's, the original's, then the newest other rendition's). Nil for a gallery and a post with no library file.
    public static func privateFileID(for item: MediaItem) -> String? {
        if item.kind == .gallery { return nil }
        if let id = fileID(for: item) { return id }
        if let id = anyFile(of: item.face)?.id { return id }
        if let video = item.video, let id = anyFile(of: video)?.id { return id }
        let others = item.renditions
            .filter { !$0.isItem }
            .sorted { $0.createdAt > $1.createdAt }
        for rendition in others {
            if let id = anyFile(of: rendition)?.id { return id }
        }
        return nil
    }

    /// The library file of `rendition`, public or not.
    static func anyFile(of rendition: Rendition) -> LibraryFile? {
        rendition.file ?? rendition.hosted
    }

    /// The library file that makes `rendition` public now, if any.
    public static func publicFile(of rendition: Rendition) -> LibraryFile? {
        if let file = rendition.file, file.isPublic, file.url != nil { return file }
        if let hosted = rendition.hosted, hosted.isPublic, hosted.url != nil { return hosted }
        return nil
    }
}

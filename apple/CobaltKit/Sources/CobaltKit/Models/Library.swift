import Foundation

/// Whether a file has a public link (CONTRACT-VISIBILITY.md): the toggle's state. A video or a webp is one file
/// on the server and is public or private; `kind` only says where its bytes live.
public enum Visibility: String, Sendable, Codable, Equatable { case `public`, `private` }

/// What `PATCH /library/items/<id>/visibility` answered: the file as it is now, and for a switch to private
/// whether the server could clear its public link from the edge cache (`cache_cleared`: nil when nothing needed
/// clearing or the server does not say, false when it tried and could not).
public struct VisibilityChange: Sendable, Equatable {
    public let file: LibraryFile
    public let cacheCleared: Bool?

    public init(file: LibraryFile, cacheCleared: Bool?) {
        self.file = file
        self.cacheCleared = cacheCleared
    }
}

public struct LibraryFile: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case `public`, `private` }
    /// `made`: a crop (or an export) made on the device and uploaded with `PUT /library/items/<id>/made` (18.6). Before this
    /// word a `made` row failed to decode, and the library page dropped it.
    public enum Source: String, Sendable, Codable { case webp, studio, host, upload, saved, made }
    public enum Role: Sendable, Equatable { case webp, hostedLink, privateCopy }

    public var id: String
    public var kind: Kind
    public var source: Source
    public var name: String
    public var url: URL?
    public var contentType: String?
    public var bytes: Int64?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var createdAt: Date
    public var mediaName: String?
    public var deletable: Bool
    /// `poster_url` (CONTRACT-LIBRARY2 decision 19): the server's still of a video file, a
    /// `https://media.capybaraharmony.com/<10 base62>.jpg`; nil when the server sends none (a webp never has one).
    public var posterURL: URL?
    /// `visibility`, as the server sent it; nil from a server that does not (read `visibility`).
    public var wireVisibility: Visibility?
    /// `visibility_toggle`: `PATCH …/visibility` takes this file (an original, or a webp). False when absent.
    public var canToggleVisibility: Bool = false
    // GET /library?v=3 (APP-API-CONTRACT 18.3): what the file is within its post. All nil/empty from an older server
    // and for every file that is not part of a gallery or made from one.
    /// `role`: `item` (an original of a gallery), `slideshow`, `export` (a gallery image), `crop`; nil for a file that
    /// is none of these (a single file, a webp of a video).
    public var galleryRole: GalleryRole?
    /// `item_index`: the item's place in its post (0-based); nil for a file that is not an item.
    public var itemIndex: Int?
    /// `made_from`: the library file ids a made file was made from.
    public var madeFrom: [String] = []
    /// `made_spec`: the spec a made file was made with.
    public var madeSpec: MadeSpec?

    /// What a made file is (the key a remake replaces); nil for anything else.
    public var madeKind: MadeKind? { MadeKind(role: galleryRole, spec: madeSpec) }

    /// The file's visibility: the server's word, else derived from `kind` (a legacy server: a `public` file is a
    /// public link, a `private` one has none). On `GET /library?v=2` an original that is public has `kind
    /// private` (where its bytes live) and `visibility public`.
    public var visibility: Visibility { wireVisibility ?? (kind == .public ? .public : .private) }
    public var isPublic: Bool { visibility == .public }

    /// An original (private or public: `kind private` says where its bytes live); public image/webp → webp;
    /// other public → hostedLink (only a legacy server lists a separate hosted copy).
    public var role: Role {
        if kind == .private { return .privateCopy }
        if contentType?.lowercased() == "image/webp" { return .webp }
        return .hostedLink
    }
}

extension LibraryFile {
    enum CodingKeys: String, CodingKey {
        case id, kind, source, name, url, contentType, bytes, width, height, duration
        case createdAt, mediaName, deletable
        case posterURL = "posterUrl"           // `poster_url` after convertFromSnakeCase
        case visibility
        case canToggleVisibility = "visibilityToggle"   // `visibility_toggle`
        case galleryRole = "role"
        case itemIndex, madeFrom, madeSpec               // `item_index`, `made_from`, `made_spec`
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        source = try c.decode(Source.self, forKey: .source)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        // The upload response's `item` has neither of these; the library listing always does.
        mediaName = try c.decodeIfPresent(String.self, forKey: .mediaName)
        deletable = try c.decodeIfPresent(Bool.self, forKey: .deletable) ?? false
        posterURL = try? c.decodeIfPresent(URL.self, forKey: .posterURL)      // a bad poster never loses the file
        wireVisibility = (try? c.decodeIfPresent(Visibility.self, forKey: .visibility)) ?? nil   // a word we do not know reads as unsaid
        canToggleVisibility = (try? c.decodeIfPresent(Bool.self, forKey: .canToggleVisibility)) ?? false
        // v=3 fields: a word this build does not know reads as unsaid, and never loses the file
        galleryRole = (try? c.decodeIfPresent(GalleryRole.self, forKey: .galleryRole)) ?? nil
        itemIndex = (try? c.decodeIfPresent(Int.self, forKey: .itemIndex)) ?? nil
        madeFrom = ((try? c.decodeIfPresent([String].self, forKey: .madeFrom)) ?? nil) ?? []
        madeSpec = ((try? c.decodeIfPresent(JSONValue.self, forKey: .madeSpec)) ?? nil)?.object.flatMap(MadeSpec.init(object:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(source, forKey: .source)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(contentType, forKey: .contentType)
        try c.encodeIfPresent(bytes, forKey: .bytes)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(mediaName, forKey: .mediaName)
        try c.encode(deletable, forKey: .deletable)
        try c.encodeIfPresent(posterURL, forKey: .posterURL)
        try c.encodeIfPresent(wireVisibility, forKey: .visibility)
        try c.encode(canToggleVisibility, forKey: .canToggleVisibility)
        try c.encodeIfPresent(galleryRole, forKey: .galleryRole)
        try c.encodeIfPresent(itemIndex, forKey: .itemIndex)
        if !madeFrom.isEmpty { try c.encode(madeFrom, forKey: .madeFrom) }
        if let data = madeSpec?.data, let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            try c.encode(value, forKey: .madeSpec)
        }
    }
}

/// Any JSON value, for the one field the wire leaves open (`made_spec`).
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), dictionary([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .dictionary(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .dictionary(let v): try c.encode(v)
        }
    }

    /// The Foundation value (for `JSONSerialization`).
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.any)
        case .dictionary(let v): return v.mapValues(\.any)
        }
    }

    var object: [String: Any]? {
        if case .dictionary(let v) = self { return v.mapValues(\.any) }
        return nil
    }
}

public struct LibrarySession: Sendable, Codable, Equatable {
    public var id: String
    public var status: SessionStatus
    public var expiresAt: Date
    public var sourceURL: URL

    enum CodingKeys: String, CodingKey {
        case id, status, expiresAt
        case sourceURL = "sourceUrl"          // `source_url` after convertFromSnakeCase
    }
}

public enum LibraryPill: Sendable, Equatable, CaseIterable { case webp, mp4Link, privateCopy }

public struct LibraryPost: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var service: String?
    public var link: URL?
    public var title: String?
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var createdAt: Date
    public var session: LibrarySession?
    public var files: [LibraryFile]
    /// `custom_title` (CONTRACT-LIBRARY2 decision 1): the owner's title for this post; nil when none is set.
    public var customTitle: String?
    /// `poster_url` on the post: the original's poster, else any file's; nil when the server sends none.
    public var posterURL: URL?
    /// `visibility` on the post (`GET /library?v=2`): its original's, else public when any file is; nil from a
    /// server that does not say.
    public var visibility: Visibility?
    /// `kind` (`GET /library?v=3`, 18.3): what the post is; nil from an older server.
    public var kind: MediaKind?
    /// `item_count` (v=3): the live items of a gallery.
    public var itemCount: Int?
    /// `items_failed` (v=3): indices of the items the save could not fetch.
    public var itemsFailed: [Int] = []

    /// `LinkInfo(link).ref`
    public var ref: String? { link.flatMap { LinkInfo($0)?.ref } }

    /// Unique roles present, order webp, mp4Link, privateCopy.
    public var pills: [LibraryPill] {
        let roles = Set(files.map(\.role))
        var out: [LibraryPill] = []
        if roles.contains(.webp) { out.append(.webp) }
        if roles.contains(.hostedLink) { out.append(.mp4Link) }
        if roles.contains(.privateCopy) { out.append(.privateCopy) }
        return out
    }
}

extension LibraryPost {
    enum CodingKeys: String, CodingKey {
        case id, service, link, title, duration, width, height, createdAt, session, files
        case customTitle, visibility
        case kind, itemCount, itemsFailed      // `kind`, `item_count`, `items_failed`
        case posterURL = "posterUrl"           // `poster_url` after convertFromSnakeCase
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        service = try c.decodeIfPresent(String.self, forKey: .service)
        link = try c.decodeIfPresent(URL.self, forKey: .link)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        session = try c.decodeIfPresent(LibrarySession.self, forKey: .session)
        files = (try c.decodeIfPresent([Lossy<LibraryFile>].self, forKey: .files) ?? []).compactMap(\.value)
        customTitle = try? c.decodeIfPresent(String.self, forKey: .customTitle)
        posterURL = try? c.decodeIfPresent(URL.self, forKey: .posterURL)
        visibility = (try? c.decodeIfPresent(Visibility.self, forKey: .visibility)) ?? nil
        kind = (try? c.decodeIfPresent(MediaKind.self, forKey: .kind)) ?? nil
        itemCount = (try? c.decodeIfPresent(Int.self, forKey: .itemCount)) ?? nil
        itemsFailed = ((try? c.decodeIfPresent([Int].self, forKey: .itemsFailed)) ?? nil) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(service, forKey: .service)
        try c.encodeIfPresent(link, forKey: .link)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(session, forKey: .session)
        try c.encode(files, forKey: .files)
        try c.encodeIfPresent(customTitle, forKey: .customTitle)
        try c.encodeIfPresent(posterURL, forKey: .posterURL)
        try c.encodeIfPresent(visibility, forKey: .visibility)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(itemCount, forKey: .itemCount)
        if !itemsFailed.isEmpty { try c.encode(itemsFailed, forKey: .itemsFailed) }
    }
}

public struct LibraryPage: Sendable, Equatable {
    public var posts: [LibraryPost]
    public var postCount: Int
    public var fileCount: Int
    public var publicBytes: Int64
    public var privateBytes: Int64
    public var next: String?
}

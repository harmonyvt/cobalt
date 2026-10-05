import Foundation

public struct LibraryFile: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case `public`, `private` }
    public enum Source: String, Sendable, Codable { case webp, studio, host, upload, saved }
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

    /// private → privateCopy; public image/webp → webp; other public → hostedLink.
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

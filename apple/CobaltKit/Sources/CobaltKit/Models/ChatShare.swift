import Foundation

// A chat shared as a web page (APP-API-CONTRACT 46): share.capybaraharmony.com/c/<key> shows the chat up to the message it
// was shared at, with its tool cards and its videos and pictures playable. Chats stay private until shared.

/// The live shared page of a chat, as `GET|PUT /chat/threads/<id>/share` and `POST .../share/rotate` answer it.
public struct ChatShare: Sendable, Equatable, Decodable {
    /// share.../c/<key>: the only way in while it is live.
    public var url: URL
    public var threadID: String
    /// The last message on the page.
    public var uptoID: String
    public var uptoAt: Date?
    /// Messages on the page, and messages written after it (an update brings them in).
    public var messages: Int
    public var behind: Int
    /// Videos and pictures the link streams.
    public var files: Int
    /// The chat's videos and pictures play on the page.
    public var media: Bool
    /// The model's code is on the page, folded.
    public var code: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Page opens.
    public var opened: Int
    public var lastOpenedAt: Date?

    public init(
        url: URL, threadID: String, uptoID: String, uptoAt: Date?, messages: Int, behind: Int, files: Int, media: Bool,
        code: Bool, createdAt: Date, updatedAt: Date, opened: Int = 0, lastOpenedAt: Date? = nil
    ) {
        self.url = url
        self.threadID = threadID
        self.uptoID = uptoID
        self.uptoAt = uptoAt
        self.messages = messages
        self.behind = behind
        self.files = files
        self.media = media
        self.code = code
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.opened = opened
        self.lastOpenedAt = lastOpenedAt
    }

    enum CodingKeys: String, CodingKey {
        case url, threadId, uptoId, uptoAt, messages, behind, files, media, code, createdAt, updatedAt, opened, lastOpenedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        threadID = try c.decode(String.self, forKey: .threadId)
        uptoID = try c.decode(String.self, forKey: .uptoId)
        uptoAt = try c.decodeIfPresent(Date.self, forKey: .uptoAt)
        messages = try c.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        behind = try c.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0
        media = try c.decodeIfPresent(Bool.self, forKey: .media) ?? true
        code = try c.decodeIfPresent(Bool.self, forKey: .code) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        opened = try c.decodeIfPresent(Int.self, forKey: .opened) ?? 0
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
    }
}

/// What `PUT /chat/threads/<id>/share` changes: nil leaves a setting as it is (a new share starts with media on, code off).
public struct ChatShareChange: Sendable, Equatable {
    public var media: Bool?
    public var code: Bool?
    /// Move the page up to the chat's latest message.
    public var toLatest: Bool

    public init(media: Bool? = nil, code: Bool? = nil, toLatest: Bool = false) {
        self.media = media
        self.code = code
        self.toLatest = toLatest
    }

    var body: [String: Any] {
        var b: [String: Any] = [:]
        if let media { b["media"] = media }
        if let code { b["code"] = code }
        if toLatest { b["upto"] = "latest" }
        return b
    }
}

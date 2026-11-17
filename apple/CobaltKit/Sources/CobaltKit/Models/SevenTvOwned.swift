import Foundation

// "your emotes on 7tv" (APP-API-CONTRACT 57.14): every emote the linked account owns, `GET /7tv/owned`, newest first, at most 500.
// Wider than `GET /7tv/uploads` (57.11), which only knows what capystore uploaded: an emote made on 7tv.app shows here too,
// with `file_id` null.

/// One emote of the account: its pictures (null while 7TV is still processing it), its marks, and the library file it came
/// from when capystore uploaded it.
public struct SevenTvOwnedEmote: Sendable, Equatable, Identifiable, Decodable {
    public var id: String { emoteID }
    public var emoteID: String
    public var name: String
    public var animated: Bool
    public var isPrivate: Bool
    public var zeroWidth: Bool
    /// 7TV is still making its sizes (a pending emote has no picture yet, but can be put in a set at once, 57.9).
    public var pending: Bool
    public var previewURL: URL?
    public var fileURL: URL?
    public var pageURL: URL
    /// The library file id when capystore uploaded it (`seventv_uploads`); nil for one made on 7tv.app.
    public var fileID: String?
    /// The time in the emote id (ms on the wire).
    public var createdAt: Date?

    public init(
        emoteID: String, name: String, animated: Bool = false, isPrivate: Bool = false, zeroWidth: Bool = false, pending: Bool = false,
        previewURL: URL? = nil, fileURL: URL? = nil, pageURL: URL? = nil, fileID: String? = nil, createdAt: Date? = nil
    ) {
        self.emoteID = emoteID
        self.name = name
        self.animated = animated
        self.isPrivate = isPrivate
        self.zeroWidth = zeroWidth
        self.pending = pending
        self.previewURL = previewURL
        self.fileURL = fileURL
        self.pageURL = pageURL ?? SevenTvEmoteRule.pageURL(emoteID)
        self.fileID = fileID
        self.createdAt = createdAt
    }

    /// Capystore uploaded it from a library file.
    public var fromLibrary: Bool { fileID?.isEmpty == false }

    enum CodingKeys: String, CodingKey {
        case name, animated, pending
        case emoteID = "emoteId"
        case isPrivate = "private"
        case zeroWidth
        case previewURL = "previewUrl"
        case fileURL = "fileUrl"
        case pageURL = "pageUrl"
        case fileID = "fileId"
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoteID = try c.decode(String.self, forKey: .emoteID)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        animated = (try? c.decodeIfPresent(Bool.self, forKey: .animated)) ?? false
        isPrivate = (try? c.decodeIfPresent(Bool.self, forKey: .isPrivate)) ?? false
        zeroWidth = (try? c.decodeIfPresent(Bool.self, forKey: .zeroWidth)) ?? false
        pending = (try? c.decodeIfPresent(Bool.self, forKey: .pending)) ?? false
        previewURL = SevenTvWire.url(try? c.decodeIfPresent(String.self, forKey: .previewURL))
        fileURL = SevenTvWire.url(try? c.decodeIfPresent(String.self, forKey: .fileURL))
        pageURL = SevenTvWire.url(try? c.decodeIfPresent(String.self, forKey: .pageURL)) ?? SevenTvEmoteRule.pageURL(emoteID)
        fileID = SevenTvWire.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .fileID))
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    /// The emote as a search hit (its own 7TV name), for adding it to a set. A pending emote has no pictures yet: 7TV's CDN
    /// names where they will be.
    public var asHit: EmoteHit {
        EmoteHit(
            id: emoteID, name: name, animated: animated,
            previewURL: previewURL ?? SevenTvEmoteRule.cdnURL(emoteID, size: "2x"),
            fileURL: fileURL ?? SevenTvEmoteRule.cdnURL(emoteID, size: "4x"))
    }
}

/// `GET /7tv/owned`: `{status, owner_id, total, emotes: [...]}`. A row without an emote id is dropped, not the answer; `total`
/// is what the account owns (more than `emotes.count` once past the 500 the server lists).
public struct SevenTvOwnedList: Sendable, Equatable, Decodable {
    public var ownerID: String?
    public var total: Int
    public var emotes: [SevenTvOwnedEmote]

    public init(ownerID: String? = nil, total: Int? = nil, emotes: [SevenTvOwnedEmote]) {
        self.ownerID = ownerID
        self.total = max(total ?? emotes.count, emotes.count)
        self.emotes = emotes
    }

    enum CodingKeys: String, CodingKey {
        case total, emotes
        case ownerID = "ownerId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerID = SevenTvWire.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .ownerID))
        let rows = (try? c.decodeIfPresent([Lossy<SevenTvOwnedEmote>].self, forKey: .emotes)) ?? []
        emotes = rows.compactMap(\.value)
        let said = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? 0
        total = max(said, emotes.count)
    }
}

import Foundation

/// One 7TV emote from `GET /emotes` (APP-API-CONTRACT section 20).
public struct EmoteHit: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var animated: Bool
    /// The grid picture (often 2x).
    public var previewURL: URL
    /// The largest webp. A copy downloads this when we have not saved it yet.
    public var fileURL: URL
    /// Our library file id, once saved.
    public var libraryID: String?
    /// That file's public URL. Hold inserts this, and only after a save.
    public var libraryURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, animated
        case previewURL = "previewUrl"
        case fileURL = "fileUrl"
        case libraryID = "libraryId"
        case libraryURL = "libraryUrl"
    }
}

/// How `GET /emotes?sort=` orders 7TV (APP-API-CONTRACT section 20.1). `global` is 7TV's global set.
public enum EmoteSort: String, Sendable, CaseIterable, Codable, Identifiable {
    case trendingDaily = "trending_daily"
    case trendingWeekly = "trending_weekly"
    case trendingMonthly = "trending_monthly"
    case topDaily = "top_daily"
    case topWeekly = "top_weekly"
    case topMonthly = "top_monthly"
    case top
    case new
    case global

    public var id: String { rawValue }
}

/// One page of `GET /emotes?sort=&page=` (24 a page).
public struct EmotePage: Sendable, Equatable {
    public var items: [EmoteHit]
    public var page: Int
    public var hasMore: Bool

    public init(items: [EmoteHit], page: Int, hasMore: Bool) {
        self.items = items
        self.page = page
        self.hasMore = hasMore
    }
}

/// What `POST /emotes` keeps: the library file id, its public URL, and the 7TV id.
public struct SavedEmote: Sendable, Equatable, Decodable {
    public var id: String
    public var name: String
    public var url: URL?
    public var emoteID: String

    enum CodingKeys: String, CodingKey {
        case id, name, url
        case emoteID = "emoteId"
    }
}

/// Variants of an emote (APP-API-CONTRACT 20.2): every 7TV emote whose own name (never a set's alias) is the same, case
/// aside. The server filters with `exact=1`; the app filters again so a server without it still answers right.
public enum EmoteVariants {
    /// `catJAM` and `CATJAM` are the same name; `catJAM2` is not.
    public static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The hits named `name`, in their order.
    public static func keep(_ items: [EmoteHit], name: String) -> [EmoteHit] {
        items.filter { sameName($0.name, name) }
    }
}

import Foundation

// The booru tab (APP-API-CONTRACT 72): Danbooru search through the server, under this device's own content level and
// filters. Questionable and explicit do not exist in capystore (owner, 2026-11-22): the levels are general and sensitive
// only, and the server drops anything else before it reaches the app.

/// A content level: Danbooru's rating, general or sensitive only.
public enum BooruLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case general = "g"
    case sensitive = "s"

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    /// An older server can still answer "q" (the removed questionable level): read it as sensitive, the highest there is.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "g" ? .general : .sensitive
    }
}

/// What happens to the posts a theme matches.
public enum BooruThemeMode: String, Sendable, Codable, CaseIterable {
    case show, blur, hide
}

public enum BooruOrder: String, Sendable, Codable, CaseIterable {
    case new, popular, score, favs, random

    /// Danbooru's `order:` metatag; newest is its default.
    var danbooruTag: String? {
        switch self {
        case .new: return nil
        case .popular: return "order:rank"
        case .score: return "order:score"
        case .favs: return "order:favcount"
        case .random: return "order:random"
        }
    }
}

public enum BooruMedia: String, Sendable, Codable, CaseIterable {
    case image, animated, video
}

public enum BooruShape: String, Sendable, Codable, CaseIterable {
    case tall, square, wide
}

/// One theme inside the levels (72.3), as the server describes it.
public struct BooruTheme: Sendable, Equatable, Decodable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String
    public var `default`: BooruThemeMode
    /// The lowest level at which it can match anything (a theme for content above general matters from sensitive up).
    public var minLevel: BooruLevel
    public var tags: [String]

    public init(id: String, label: String, detail: String, default: BooruThemeMode, minLevel: BooruLevel, tags: [String]) {
        self.id = id
        self.label = label
        self.detail = detail
        self.default = `default`
        self.minLevel = minLevel
        self.tags = tags
    }
}

/// `GET|PUT /booru/settings`: this key's (this device's) level, theme modes and blacklist.
public struct BooruSettings: Sendable, Equatable, Decodable {
    public var level: BooruLevel
    public var themes: [String: BooruThemeMode]
    public var themeList: [BooruTheme]
    public var blacklist: String
    public var updatedAt: Int?

    public init(level: BooruLevel, themes: [String: BooruThemeMode], themeList: [BooruTheme], blacklist: String, updatedAt: Int? = nil) {
        self.level = level
        self.themes = themes
        self.themeList = themeList
        self.blacklist = blacklist
        self.updatedAt = updatedAt
    }

    public func mode(_ theme: BooruTheme) -> BooruThemeMode { themes[theme.id] ?? theme.default }
}

/// A change to the settings; nil fields stay as they are.
public struct BooruSettingsPatch: Sendable, Equatable {
    public var level: BooruLevel?
    public var themes: [String: BooruThemeMode]?
    public var blacklist: String?

    public init(level: BooruLevel? = nil, themes: [String: BooruThemeMode]? = nil, blacklist: String? = nil) {
        self.level = level
        self.themes = themes
        self.blacklist = blacklist
    }

    var json: [String: Any] {
        var o: [String: Any] = [:]
        if let level { o["level"] = level.rawValue }
        if let themes { o["themes"] = themes.mapValues(\.rawValue) }
        if let blacklist { o["blacklist"] = blacklist }
        return o
    }
}

public struct BooruTags: Sendable, Equatable, Decodable {
    public var artist: [String]
    public var character: [String]
    public var copyright: [String]
    public var general: [String]
    public var meta: [String]

    public init(artist: [String] = [], character: [String] = [], copyright: [String] = [], general: [String] = [], meta: [String] = []) {
        self.artist = artist
        self.character = character
        self.copyright = copyright
        self.general = general
        self.meta = meta
    }
}

extension BooruLevel {
    /// A post rated `rating` may be shown while the level asked for is `level`: no higher than it. A nil level (settings
    /// the device could not read, nothing to compare with) lets everything the server sent stand.
    public static func shows(_ rating: BooruLevel, at level: BooruLevel?) -> Bool {
        guard let level else { return true }
        return rating <= level
    }
}

public struct BooruPost: Sendable, Equatable, Decodable, Identifiable {
    public var id: Int
    public var rating: BooruLevel
    /// A theme set to blur matched: the grid shows a cover until tapped.
    public var blur: Bool
    public var media: BooruMedia
    public var ext: String
    public var width: Int
    public var height: Int
    public var size: Int
    public var score: Int
    public var favs: Int
    public var createdAt: String?
    public var source: String?
    public var pageUrl: URL
    public var thumbUrl: URL
    public var sampleUrl: URL
    public var fileUrl: URL
    public var tags: BooruTags

    public init(
        id: Int, rating: BooruLevel, blur: Bool = false, media: BooruMedia = .image, ext: String = "png", width: Int = 1000,
        height: Int = 1400, size: Int = 0, score: Int = 0, favs: Int = 0, createdAt: String? = nil, source: String? = nil,
        pageUrl: URL, thumbUrl: URL, sampleUrl: URL, fileUrl: URL, tags: BooruTags = BooruTags()
    ) {
        self.id = id
        self.rating = rating
        self.blur = blur
        self.media = media
        self.ext = ext
        self.width = width
        self.height = height
        self.size = size
        self.score = score
        self.favs = favs
        self.createdAt = createdAt
        self.source = source
        self.pageUrl = pageUrl
        self.thumbUrl = thumbUrl
        self.sampleUrl = sampleUrl
        self.fileUrl = fileUrl
        self.tags = tags
    }

    public var aspect: Double { height > 0 ? Double(width) / Double(height) : 1 }
}

/// What the server left out of a page, by reason.
public struct BooruHidden: Sendable, Equatable, Decodable {
    public var level: Int
    public var theme: Int
    public var blacklist: Int
    public var refine: Int
    public var blocked: Int

    public init(level: Int = 0, theme: Int = 0, blacklist: Int = 0, refine: Int = 0, blocked: Int = 0) {
        self.level = level
        self.theme = theme
        self.blacklist = blacklist
        self.refine = refine
        self.blocked = blocked
    }

    /// Hidden by the owner's own choices (themes, blacklist, refine): what the footer counts.
    public var byFilters: Int { theme + blacklist + refine }

    static func + (a: Self, b: Self) -> Self {
        Self(level: a.level + b.level, theme: a.theme + b.theme, blacklist: a.blacklist + b.blacklist, refine: a.refine + b.refine,
             blocked: a.blocked + b.blocked)
    }
}

public struct BooruPage: Sendable, Equatable, Decodable {
    public var level: BooruLevel
    public var posts: [BooruPost]
    public var hidden: BooruHidden
    public var nextPage: Int?
    /// Extras Danbooru's 2-tag limit did not take ("order", "rating"); the server filtered anyway.
    public var dropped: [String]

    public init(level: BooruLevel, posts: [BooruPost], hidden: BooruHidden = BooruHidden(), nextPage: Int? = nil, dropped: [String] = []) {
        self.level = level
        self.posts = posts
        self.hidden = hidden
        self.nextPage = nextPage
        self.dropped = dropped
    }
}

public struct BooruSuggestion: Sendable, Equatable, Decodable, Identifiable {
    public enum Kind: String, Sendable, Decodable { case general, artist, copyright, character, meta }
    public var id: String { name }
    public var name: String
    public var kind: Kind
    public var count: Int

    public init(name: String, kind: Kind, count: Int) {
        self.name = name
        self.kind = kind
        self.count = count
    }

    /// Tags never suggested (the server's hard block, APP-API-CONTRACT 72.1); posts carrying them never come back from the
    /// server's filter either.
    static let blocked = ["loli", "shota", "toddlercon", "lolicon", "shotacon", "child_on_child"]
    static func isBlocked(_ name: String) -> Bool { blocked.contains { name == $0 || name.hasPrefix($0 + "_") } }
}

/// One search: the owner's tags (at most 2), the order and the refinements.
public struct BooruQuery: Sendable, Equatable {
    public static let maxTags = 2

    public var tags: String
    public var order: BooruOrder
    public var minScore: Int?
    public var media: BooruMedia?
    public var shape: BooruShape?

    public init(tags: String = "", order: BooruOrder = .new, minScore: Int? = nil, media: BooruMedia? = nil, shape: BooruShape? = nil) {
        self.tags = tags
        self.order = order
        self.minScore = minScore
        self.media = media
        self.shape = shape
    }

    /// The typed words that count as tags (metatags the server sets itself are not counted).
    public var tagList: [String] {
        tags.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { t in
            let body = t.drop { $0 == "-" || $0 == "~" }
            return !body.isEmpty && !["rating:", "status:", "order:", "limit:", "is:"].contains { body.hasPrefix($0) }
        }
    }

    public var tooManyTags: Bool { tagList.count > Self.maxTags }

    /// How many refinements are on (the filter button's badge).
    public var refinements: Int { [minScore != nil, media != nil, shape != nil].filter { $0 }.count }

    func items(page: Int, level: BooruLevel?) -> [(String, String)] {
        var q: [(String, String)] = [("tags", tagList.joined(separator: " ")), ("page", String(page)), ("order", order.rawValue)]
        if let level { q.append(("level", level.rawValue)) }
        if let minScore { q.append(("min_score", String(minScore))) }
        if let media { q.append(("media", media.rawValue)) }
        if let shape { q.append(("shape", shape.rawValue)) }
        return q
    }
}

/// The routes, kept apart from `CobaltClient` like `TwitchSessionClient`, so no existing fake has to change.
/// `HTTPCobaltClient` conforms; any other client has no booru tab.
public protocol BooruClient: Sendable {
    func booruPosts(_ query: BooruQuery, page: Int, level: BooruLevel?) async throws -> BooruPage
    func booruAutocomplete(_ q: String) async throws -> [BooruSuggestion]
    func booruSettings() async throws -> BooruSettings
    func updateBooruSettings(_ patch: BooruSettingsPatch) async throws -> BooruSettings
}

extension HTTPCobaltClient: BooruClient {
    // Danbooru answers the apps but refuses requests from the Worker (live, 2026-11-21: every GET /booru/posts was 502). So
    // the app fetches posts.json itself and the server filters the page under this device's settings (POST /booru/filter,
    // APP-API-CONTRACT 72.7): the level, the hard block, the themes and the blacklist are still the server's to apply.
    static let danbooru = URL(string: "https://danbooru.donmai.us")!
    static let danbooruPageLimit = 100
    /// The post fields the server's filter reads; the rest of Danbooru's answer stays on the device.
    static let danbooruKeys: Set<String> = [
        "id", "rating", "tag_string", "tag_string_artist", "tag_string_character", "tag_string_copyright", "tag_string_general",
        "tag_string_meta", "score", "fav_count", "file_ext", "file_size", "image_width", "image_height", "created_at", "source",
        "file_url", "large_file_url", "preview_file_url", "is_deleted", "is_banned", "is_pending", "media_asset",
    ]
    private static let danbooruSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": "capystore/1.0 (private booru tab)", "Accept": "application/json"]
        return URLSession(configuration: c)
    }()

    private static func danbooruGet(_ path: String, _ items: [URLQueryItem]) async throws -> (Any?, Int) {
        var c = URLComponents(url: danbooru.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = items
        do {
            let (data, response) = try await danbooruSession.data(from: c.url!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (try? JSONSerialization.jsonObject(with: data), status)
        } catch let e as URLError {
            throw CobaltError.network(e.code)
        }
    }

    public func booruPosts(_ query: BooruQuery, page: Int, level: BooruLevel?) async throws -> BooruPage {
        // the owner's tags first; the order and the rating clause are extras, given up in that order when Danbooru refuses
        // the tag count (anonymous searches take 2 tags). The server filters the page again either way.
        let clause = level ?? .sensitive
        let ratings = BooruLevel.allCases.filter { $0 <= clause }.map(\.rawValue).joined(separator: ",")
        var extras: [(String, String)] = []
        if let order = query.order.danbooruTag { extras.append(("order", order)) }
        extras.append(("rating", "rating:\(ratings)"))
        var dropped: [String] = []
        var raw: [Any] = []
        while true {
            let tags = (query.tagList + extras.map(\.1)).joined(separator: " ")
            let (body, status) = try await Self.danbooruGet("posts.json", [
                URLQueryItem(name: "limit", value: String(Self.danbooruPageLimit)),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "tags", value: tags),
            ])
            if status == 422, !extras.isEmpty {
                dropped.append(extras.removeFirst().0)
                continue
            }
            if status == 429 { throw CobaltError.api(code: "error.booru.busy", httpStatus: 429) }
            guard (200..<300).contains(status), let list = body as? [Any] else {
                throw CobaltError.api(code: "error.booru.upstream", httpStatus: status == 0 ? 502 : status)
            }
            raw = list
            break
        }
        let trimmed: [Any] = raw.compactMap { item in
            (item as? [String: Any]).map { $0.filter { Self.danbooruKeys.contains($0.key) } }
        }
        var json: [String: Any] = ["posts": trimmed]
        if let level { json["level"] = level.rawValue }
        if let s = query.minScore { json["min_score"] = s }
        if let m = query.media { json["media"] = m.rawValue }
        if let s = query.shape { json["shape"] = s.rawValue }
        struct Wire: Decodable { var level: BooruLevel; var posts: [BooruPost]; var hidden: BooruHidden }
        let req = try makeRequest("POST", "/booru/filter", keyed: true, timeout: 25)
        let w = try await decodeBooru(Wire.self, req, body: try JSONSerialization.data(withJSONObject: json))
        let next = raw.count >= Self.danbooruPageLimit && page < 1000 ? page + 1 : nil
        return BooruPage(level: w.level, posts: w.posts, hidden: w.hidden, nextPage: next, dropped: dropped)
    }

    public func booruAutocomplete(_ q: String) async throws -> [BooruSuggestion] {
        let term = q.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-~"))
        guard !term.isEmpty, !term.contains(":") else { return [] }
        let (body, status) = try await Self.danbooruGet("autocomplete.json", [
            URLQueryItem(name: "search[query]", value: term),
            URLQueryItem(name: "search[type]", value: "tag_query"),
            URLQueryItem(name: "limit", value: "10"),
        ])
        guard (200..<300).contains(status), let list = body as? [[String: Any]] else {
            throw CobaltError.api(code: "error.booru.upstream", httpStatus: status == 0 ? 502 : status)
        }
        let kinds: [Int: BooruSuggestion.Kind] = [0: .general, 1: .artist, 3: .copyright, 4: .character, 5: .meta]
        return list.compactMap { s in
            guard let name = s["value"] as? String, !name.isEmpty, !name.contains(":"), !BooruSuggestion.isBlocked(name) else { return nil }
            return BooruSuggestion(name: name, kind: kinds[s["category"] as? Int ?? 0] ?? .general, count: s["post_count"] as? Int ?? 0)
        }
    }

    public func booruSettings() async throws -> BooruSettings {
        try await decodeBooru(BooruSettings.self, try makeRequest("GET", "/booru/settings", keyed: true, timeout: 15))
    }

    public func updateBooruSettings(_ patch: BooruSettingsPatch) async throws -> BooruSettings {
        let req = try makeRequest("PUT", "/booru/settings", keyed: true, timeout: 15)
        return try await decodeBooru(BooruSettings.self, req, body: Self.jsonBody(patch.json))
    }

    private func decodeBooru<T: Decodable>(_ type: T.Type, _ req: URLRequest, body: Data? = nil) async throws -> T {
        let (data, http) = try await send(req, body: body)
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        guard let value = try? CobaltJSON.decoder().decode(T.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return value
    }
}

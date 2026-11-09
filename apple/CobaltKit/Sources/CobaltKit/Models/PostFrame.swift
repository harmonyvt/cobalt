import Foundation

// Post frames (APP-API-CONTRACT 52): a saved video re-rendered inside a drawn card that reads like the post it came from. The
// details of the post (`PostDetails`, 52.1), what a framed copy asks for (`PostFrameOptions`, 52.2) and the refusals. The
// framed copy itself is an editor render of kind `post` (`EditRender`).

/// The card's look (52.4): one per site, `generic` for every other one. Any style can be asked for.
public enum PostFrameStyle: String, Sendable, CaseIterable, Hashable, Codable {
    case x, instagram, twitch, youtube, generic

    /// The style the server picks for a link (52.4): `generic` for a host no style knows, and for no link at all.
    public init(link: URL?) {
        self = link.flatMap { $0.host(percentEncoded: false) }.map(Self.style(host:)) ?? .generic
    }

    /// The style for a link as the library stores it (a string; `7tv:<id>` and `upload:<id>` are `generic`).
    public init(linkString: String?) {
        self.init(link: linkString.flatMap(URL.init(string:)))
    }

    /// 52.4's host table, case and a leading `www.` ignored.
    static func style(host raw: String) -> PostFrameStyle {
        var host = raw.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        switch host {
        case "x.com", "twitter.com", "mobile.twitter.com", "fxtwitter.com", "vxtwitter.com": return .x
        case "instagram.com": return .instagram
        case "twitch.tv", "clips.twitch.tv", "m.twitch.tv": return .twitch
        case "youtube.com", "m.youtube.com", "youtu.be", "music.youtube.com": return .youtube
        default: return .generic
        }
    }

    /// Decodes a word this build does not know as `generic`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PostFrameStyle(rawValue: raw) ?? .generic
    }
}

/// `theme`: the card drawn light or dark (the server's default is dark).
public enum PostFrameTheme: String, Sendable, CaseIterable, Hashable, Codable {
    case light, dark
}

/// `canvas`: `fit` (the file is the card's own size), `portrait` (1080×1920) or `square` (1080×1080), the card centred on a
/// blurred, darkened copy of the video.
public enum PostFrameCanvas: String, Sendable, CaseIterable, Hashable, Codable {
    case fit, portrait, square
}

/// `show`: which parts of the card are drawn. Every part is on by default (a key the server does not get is true).
public struct PostFrameShow: Sendable, Hashable, Codable {
    public var avatar: Bool
    public var text: Bool
    /// Likes, views and the other counts.
    public var counts: Bool
    public var time: Bool

    public init(avatar: Bool = true, text: Bool = true, counts: Bool = true, time: Bool = true) {
        self.avatar = avatar
        self.text = text
        self.counts = counts
        self.time = time
    }

    public static let all = PostFrameShow()

    var wire: [String: Any] { ["avatar": avatar, "text": text, "counts": counts, "time": time] }
}

/// `counts` of `PostDetails`: a snapshot from the lookup; any of them may be missing.
public struct PostCounts: Sendable, Hashable, Codable {
    public var likes: Int?
    public var reposts: Int?
    public var replies: Int?
    public var views: Int?
    public var comments: Int?
    public var subscribers: Int?

    public init(
        likes: Int? = nil, reposts: Int? = nil, replies: Int? = nil, views: Int? = nil, comments: Int? = nil, subscribers: Int? = nil
    ) {
        self.likes = likes
        self.reposts = reposts
        self.replies = replies
        self.views = views
        self.comments = comments
        self.subscribers = subscribers
    }

    /// No count at all.
    public var isEmpty: Bool { [likes, reposts, replies, views, comments, subscribers].allSatisfy { $0 == nil } }

    private enum CodingKeys: String, CodingKey { case likes, reposts, replies, views, comments, subscribers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // a count sent as a float, a string or junk never loses the details: it reads as missing
        func count(_ key: CodingKeys) -> Int? {
            if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return n >= 0 ? n : nil }
            if let d = try? c.decodeIfPresent(Double.self, forKey: key), d.isFinite, d >= 0, d < 1e15 { return Int(d) }
            return nil
        }
        likes = count(.likes)
        reposts = count(.reposts)
        replies = count(.replies)
        views = count(.views)
        comments = count(.comments)
        subscribers = count(.subscribers)
    }

    /// `18000` -> `18K`, `402000` -> `402K`, `2300000` -> `2.3M`, `1250` -> `1.2K`, `999` -> `999` (how the sites shorten counts).
    public static func compact(_ n: Int) -> String {
        let value = max(0, n)
        // whole-number arithmetic, rounded down like the sites (1,999 is 1.9K, never 2K)
        func short(_ unit: Int, _ suffix: String) -> String {
            let tenths = value / (unit / 10)
            if tenths >= 1_000 || tenths % 10 == 0 { return "\(tenths / 10)\(suffix)" }
            return "\(tenths / 10).\(tenths % 10)\(suffix)"
        }
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return short(1_000, "K")
        case ..<1_000_000_000: return short(1_000_000, "M")
        default: return short(1_000_000_000, "B")
        }
    }
}

/// `PostDetails` of 52.2: what the server knows of the post a file was saved from (one row per source link).
public struct PostDetails: Sendable, Equatable {
    /// The item's `link` as stored.
    public var link: String
    public var site: PostFrameStyle
    /// A lookup gave anything. False: the post is gone or the site refused; the card shows a letter avatar and what was typed.
    public var found: Bool
    public var name: String?
    /// Keeps its `@`.
    public var handle: String?
    public var text: String?
    public var title: String?
    public var channel: String?
    public var game: String?
    /// The site's own name (the generic card's label), when the lookup gave one.
    public var siteName: String?
    public var postedAt: Date?
    public var counts: PostCounts
    public var verified: Bool
    /// `GET /library/items/<id>/post-details/avatar` (keyed): read it with `CobaltClient.postAvatar(item:)`. Nil without one.
    public var avatarURL: URL?
    /// Harmony edited a field (`PATCH`).
    public var edited: Bool

    public init(
        link: String, site: PostFrameStyle, found: Bool, name: String? = nil, handle: String? = nil, text: String? = nil,
        title: String? = nil, channel: String? = nil, game: String? = nil, siteName: String? = nil, postedAt: Date? = nil,
        counts: PostCounts = PostCounts(), verified: Bool = false, avatarURL: URL? = nil, edited: Bool = false
    ) {
        self.link = link
        self.site = site
        self.found = found
        self.name = name
        self.handle = handle
        self.text = text
        self.title = title
        self.channel = channel
        self.game = game
        self.siteName = siteName
        self.postedAt = postedAt
        self.counts = counts
        self.verified = verified
        self.avatarURL = avatarURL
        self.edited = edited
    }

    /// The host of the link, without `www.` (the generic card names the site by `siteName`, else this).
    public var host: String? {
        guard var host = URL(string: link)?.host(percentEncoded: false)?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// Who posted it, as the card's first line says: the name, else the channel, else the handle without its `@`.
    public var displayName: String? {
        for candidate in [name, channel, handle.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }] {
            if let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        }
        return nil
    }

    /// The details with this render's overrides drawn instead (52.2 `details`): empty overrides change nothing.
    public func applying(_ fields: PostDetailsFields) -> PostDetails {
        var out = self
        if let v = fields.name { out.name = v }
        if let v = fields.handle { out.handle = v }
        if let v = fields.text { out.text = v }
        if let v = fields.title { out.title = v }
        if let v = fields.channel { out.channel = v }
        if let v = fields.game { out.game = v }
        return out
    }
}

extension PostDetails: Decodable {
    private enum CodingKeys: String, CodingKey {
        case link, site, found, name, handle, text, title, channel, game, siteName, postedAt, counts, verified, edited
        case avatarURL = "avatarUrl"            // `avatar_url`
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        link = (try? c.decodeIfPresent(String.self, forKey: .link)) ?? ""
        let rawSite = try? c.decodeIfPresent(String.self, forKey: .site)
        // a site this build does not know (a new style) is drawn as generic; a missing one comes from the link
        site = rawSite.map { PostFrameStyle(rawValue: $0) ?? .generic } ?? PostFrameStyle(linkString: link)
        found = Self.flag(c, .found) ?? true
        func text(_ key: CodingKeys) -> String? {
            guard let s = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        }
        name = text(.name)
        handle = text(.handle)
        self.text = text(.text)
        title = text(.title)
        channel = text(.channel)
        game = text(.game)
        siteName = text(.siteName)
        postedAt = try? c.decodeIfPresent(Date.self, forKey: .postedAt)
        counts = (try? c.decodeIfPresent(PostCounts.self, forKey: .counts)) ?? PostCounts()
        verified = Self.flag(c, .verified) ?? false
        avatarURL = try? c.decodeIfPresent(URL.self, forKey: .avatarURL)
        edited = Self.flag(c, .edited) ?? false
    }

    /// A flag sent as a bool or as the table's 0/1.
    private static func flag(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b }
        if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return n != 0 }
        return nil
    }
}

/// The text fields of the details (52.3): a render's one-off overrides (`details` on the frame route). A nil field is not
/// sent (the stored one is drawn).
public struct PostDetailsFields: Sendable, Hashable {
    public var name: String?
    public var handle: String?
    public var text: String?
    public var title: String?
    public var channel: String?
    public var game: String?

    public init(
        name: String? = nil, handle: String? = nil, text: String? = nil, title: String? = nil, channel: String? = nil,
        game: String? = nil
    ) {
        self.name = name
        self.handle = handle
        self.text = text
        self.title = title
        self.channel = channel
        self.game = game
    }

    public var isEmpty: Bool { [name, handle, text, title, channel, game].allSatisfy { $0 == nil } }

    /// The fields that are set, held to the server's lengths (2000 characters, `text` 4000).
    var wire: [String: Any] {
        var out: [String: Any] = [:]
        if let name { out["name"] = PostDetailsPatch.clip(name, PostDetailsPatch.maxField) }
        if let handle { out["handle"] = PostDetailsPatch.clip(handle, PostDetailsPatch.maxField) }
        if let text { out["text"] = PostDetailsPatch.clip(text, PostDetailsPatch.maxText) }
        if let title { out["title"] = PostDetailsPatch.clip(title, PostDetailsPatch.maxField) }
        if let channel { out["channel"] = PostDetailsPatch.clip(channel, PostDetailsPatch.maxField) }
        if let game { out["game"] = PostDetailsPatch.clip(game, PostDetailsPatch.maxField) }
        return out
    }
}

/// `PATCH /library/items/<id>/post-details` (52.2): each field is left alone (`.keep`), cleared (`.clear`, null on the wire)
/// or set. Saved for good; the row's `edited_at` is set.
public struct PostDetailsPatch: Sendable, Hashable {
    public enum Change<Value: Sendable & Hashable>: Sendable, Hashable {
        case keep
        case clear
        case set(Value)
    }

    public var name: Change<String> = .keep
    public var handle: Change<String> = .keep
    public var text: Change<String> = .keep
    public var title: Change<String> = .keep
    public var channel: Change<String> = .keep
    public var game: Change<String> = .keep
    public var postedAt: Change<Date> = .keep

    public init() {}

    /// The patch that turns `old`'s text fields into `new`'s: a blank field is a clear, an unchanged one is left out.
    public init(from old: PostDetails, to new: PostDetailsFields) {
        func change(_ was: String?, _ now: String?) -> Change<String> {
            guard let now else { return .keep }
            let clean = now.trimmingCharacters(in: .whitespacesAndNewlines)
            let before = was?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if clean == before { return .keep }
            return clean.isEmpty ? .clear : .set(clean)
        }
        name = change(old.name, new.name)
        handle = change(old.handle, new.handle)
        text = change(old.text, new.text)
        title = change(old.title, new.title)
        channel = change(old.channel, new.channel)
        game = change(old.game, new.game)
    }

    /// Nothing to send.
    public var isEmpty: Bool { wire.isEmpty }

    static let maxField = 2000
    static let maxText = 4000

    static func clip(_ s: String, _ limit: Int) -> String { s.count > limit ? String(s.prefix(limit)) : s }

    /// The body: only the fields that change; a clear is JSON null; `posted_at` in ms.
    var wire: [String: Any] {
        var out: [String: Any] = [:]
        func put(_ key: String, _ change: Change<String>, _ limit: Int) {
            switch change {
            case .keep: break
            case .clear: out[key] = NSNull()
            case .set(let v): out[key] = Self.clip(v, limit)
            }
        }
        put("name", name, Self.maxField)
        put("handle", handle, Self.maxField)
        put("text", text, Self.maxText)
        put("title", title, Self.maxField)
        put("channel", channel, Self.maxField)
        put("game", game, Self.maxField)
        switch postedAt {
        case .keep: break
        case .clear: out["posted_at"] = NSNull()
        case .set(let date): out["posted_at"] = Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        return out
    }
}

/// What `POST /library/items/<id>/post-frame` asks for (52.2). The defaults are the server's, except that theme, canvas and
/// show are always sent.
public struct PostFrameOptions: Sendable, Hashable {
    /// Nil: the server picks from the link.
    public var style: PostFrameStyle?
    public var theme: PostFrameTheme
    public var canvas: PostFrameCanvas
    public var show: PostFrameShow
    /// Seconds of the source to frame (the editor's trim); nil: from the start / to the end.
    public var from: Double?
    public var to: Double?
    /// This render's one-off overrides; not saved.
    public var details: PostDetailsFields
    /// One Hark message when it ends.
    public var notify: Bool

    public init(
        style: PostFrameStyle? = nil, theme: PostFrameTheme = .dark, canvas: PostFrameCanvas = .fit, show: PostFrameShow = .all,
        from: Double? = nil, to: Double? = nil, details: PostDetailsFields = PostDetailsFields(), notify: Bool = false
    ) {
        self.style = style
        self.theme = theme
        self.canvas = canvas
        self.show = show
        self.from = from
        self.to = to
        self.details = details
        self.notify = notify
    }

    /// At most this many seconds are framed (52.2).
    public static let maxSeconds = 600.0

    /// The body: `style` when chosen; `theme`, `canvas`, `show` always; `from`/`to` when they make a range (rounded to ms,
    /// never negative, `to` after `from`); `details` when any is set; `notify` only when true.
    var wire: [String: Any] {
        var out: [String: Any] = ["theme": theme.rawValue, "canvas": canvas.rawValue, "show": show.wire]
        if let style { out["style"] = style.rawValue }
        func ms(_ s: Double) -> Double { (s * 1000).rounded() / 1000 }
        let start = from.flatMap { $0.isFinite ? max(0, ms($0)) : nil }
        let end = to.flatMap { $0.isFinite ? ms($0) : nil }
        if let start, start > 0 { out["from"] = start }
        if let end, end > (start ?? 0) { out["to"] = end }
        let fields = details.wire
        if !fields.isEmpty { out["details"] = fields }
        if notify { out["notify"] = true }
        return out
    }
}

/// The post-frame routes' own refusals (52.2). The render queue's refusals are `EditError` (`.queueFull`, `.off`).
public enum PostFrameError: Error, Sendable, Equatable {
    /// `404 error.library.not_found`: the item is not (or no longer) there.
    case notFound
    /// `409 error.post.no_link`: an upload or a render: there is no post to frame it in.
    case noLink
    /// `409 error.post.not_video`: only videos are framed.
    case notVideo
    /// `400`: a field the server would not take.
    case badRequest
    /// The server has no post frames (`features.post_frame` false).
    case off

    public init?(code: String) {
        switch code {
        case "error.library.not_found": self = .notFound
        case "error.post.no_link": self = .noLink
        case "error.post.not_video": self = .notVideo
        case "error.post.bad_request", "error.post.invalid": self = .badRequest
        case "error.post.off": self = .off
        default: return nil
        }
    }
}

/// The look the post-frame sheet opens with: the last one used (52.6 "the sheet opens with the last look and size you used").
public struct PostFrameLook: Sendable, Hashable, Codable {
    public var theme: PostFrameTheme
    public var canvas: PostFrameCanvas
    public var show: PostFrameShow

    public init(theme: PostFrameTheme = .dark, canvas: PostFrameCanvas = .fit, show: PostFrameShow = .all) {
        self.theme = theme
        self.canvas = canvas
        self.show = show
    }
}

/// "post frame" on save, for one site (52.6): off by default; when on, each saved video gets a framed copy (`fit`) in `theme`.
public struct PostFrameSaveChoice: Sendable, Hashable, Codable {
    public var on: Bool
    public var theme: PostFrameTheme

    public init(on: Bool = false, theme: PostFrameTheme = .dark) {
        self.on = on
        self.theme = theme
    }
}

extension MadeSpec {
    /// A framed copy's spec (`{"kind":"post","item","style","render"}`, 52.2).
    public var isPostFrame: Bool { kind == "post" }

    /// The item a framed copy was made from, and its style, read from the spec as the server sent it.
    public var postFrame: (item: String?, style: PostFrameStyle?)? {
        guard isPostFrame else { return nil }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let style = (object?["style"] as? String).map { PostFrameStyle(rawValue: $0) ?? .generic }
        return (object?["item"] as? String, style)
    }
}

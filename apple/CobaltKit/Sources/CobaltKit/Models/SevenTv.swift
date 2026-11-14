import Foundation

// 7TV accounts (APP-API-CONTRACT 57): the owner links one 7TV account, then reads and edits the emote sets of its own
// channel and of every channel that made it an editor. The apps only call the `/7tv` routes; the Worker talks to 7TV.
// Every shape decodes leniently (an odd field never drops the answer), like the stage's.

// MARK: - the account

/// `GET /7tv` (57.4, 57.5): not linked, or the account and the channels it can edit.
public struct SevenTvStatus: Sendable, Equatable, Decodable {
    public var linked: Bool
    public var account: SevenTvUser?
    /// The account's own channel first (`you`), then the channels it edits, by name. Empty while `relink`.
    public var channels: [SevenTvChannelInfo]

    public init(linked: Bool, account: SevenTvUser? = nil, channels: [SevenTvChannelInfo] = []) {
        self.linked = linked
        self.account = account
        self.channels = channels
    }

    public static let notLinked = SevenTvStatus(linked: false)

    /// Linked, but 7TV signed the token out: the card says "link again".
    public var needsRelink: Bool { linked && account?.status == .relink }

    enum CodingKeys: String, CodingKey { case linked, account, channels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try? c.decodeIfPresent(SevenTvUser.self, forKey: .account)
        linked = (try? c.decodeIfPresent(Bool.self, forKey: .linked)) ?? (account != nil)
        let rows = (try? c.decodeIfPresent([Lossy<SevenTvChannelInfo>].self, forKey: .channels)) ?? []
        channels = rows.compactMap(\.value)
    }
}

/// `account` (57.5).
public struct SevenTvUser: Sendable, Equatable, Decodable {
    public enum Status: String, Sendable, Equatable {
        case ok
        /// 7TV answered 401 (logged out on 7tv.app, or the 30 days ran out), or the token can no longer be read.
        case relink
    }

    public var id: String
    public var name: String
    public var avatarURL: URL?
    public var linkedAt: Date?
    /// When 7TV's session ends (the JWT's `exp`, else link time + 30 days).
    public var expiresAt: Date?
    public var status: Status

    public init(
        id: String, name: String, avatarURL: URL? = nil, linkedAt: Date? = nil, expiresAt: Date? = nil, status: Status = .ok
    ) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.linkedAt = linkedAt
        self.expiresAt = expiresAt
        self.status = status
    }

    /// Whole days left until `expiresAt` (0 on the last day); nil without an expiry or once it has passed.
    public func daysLeft(now: Date) -> Int? {
        guard let expiresAt, expiresAt > now else { return nil }
        return Int(expiresAt.timeIntervalSince(now) / 86_400)
    }

    /// "expires in N days" shows when fewer than 7 days are left (57.7).
    public func expiresSoon(now: Date) -> Bool {
        guard let days = daysLeft(now: now) else { return false }
        return days < 7
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case avatarURL = "avatarUrl"
        case linkedAt, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        avatarURL = SevenTvWire.url(try? c.decodeIfPresent(String.self, forKey: .avatarURL))
        linkedAt = try? c.decodeIfPresent(Date.self, forKey: .linkedAt)
        expiresAt = try? c.decodeIfPresent(Date.self, forKey: .expiresAt)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .ok
    }
}

/// What the linked account may do on a channel (57.5). 7TV still decides; these only hide buttons that would fail.
public struct SevenTvRights: Sendable, Equatable, Decodable {
    public var manageSets: Bool
    public var createSets: Bool
    public var makeLive: Bool

    public init(manageSets: Bool, createSets: Bool, makeLive: Bool) {
        self.manageSets = manageSets
        self.createSets = createSets
        self.makeLive = makeLive
    }

    public static let all = SevenTvRights(manageSets: true, createSets: true, makeLive: true)
    public static let none = SevenTvRights(manageSets: false, createSets: false, makeLive: false)

    enum CodingKeys: String, CodingKey { case manageSets, createSets, makeLive }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manageSets = (try? c.decodeIfPresent(Bool.self, forKey: .manageSets)) ?? false
        createSets = (try? c.decodeIfPresent(Bool.self, forKey: .createSets)) ?? false
        makeLive = (try? c.decodeIfPresent(Bool.self, forKey: .makeLive)) ?? false
    }
}

/// One channel the account can edit: its own (`you`) or one that made it an editor (57.5).
public struct SevenTvChannelInfo: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var avatarURL: URL?
    public var you: Bool
    public var activeSetID: String?
    public var can: SevenTvRights

    public init(
        id: String, name: String, avatarURL: URL? = nil, you: Bool = false, activeSetID: String? = nil,
        can: SevenTvRights = .all
    ) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.you = you
        self.activeSetID = activeSetID
        self.can = can
    }

    enum CodingKeys: String, CodingKey {
        case id, name, you, can
        case avatarURL = "avatarUrl"
        case activeSetID = "activeSetId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        avatarURL = SevenTvWire.url(try? c.decodeIfPresent(String.self, forKey: .avatarURL))
        you = (try? c.decodeIfPresent(Bool.self, forKey: .you)) ?? false
        activeSetID = SevenTvWire.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .activeSetID))
        // the owner's own channel can do everything (57.5), whatever the row says
        let rights = (try? c.decodeIfPresent(SevenTvRights.self, forKey: .can)) ?? .none
        can = you ? .all : rights
    }
}

// MARK: - sets

/// One set in a channel's list (`GET /7tv/channels/:id/sets`).
public struct SevenTvSetRow: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    public var name: String
    /// How many emotes the set holds at most; nil when 7TV did not say.
    public var capacity: Int?
    public var count: Int
    public var live: Bool

    public init(id: String, name: String, capacity: Int?, count: Int, live: Bool) {
        self.id = id
        self.name = name
        self.capacity = capacity
        self.count = count
        self.live = live
    }

    /// 0...1 of the capacity (0 without one).
    public var fill: Double {
        guard let capacity, capacity > 0 else { return 0 }
        return min(1, max(0, Double(count) / Double(capacity)))
    }

    enum CodingKeys: String, CodingKey { case id, name, capacity, count, live }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        capacity = try? c.decodeIfPresent(Int.self, forKey: .capacity)
        count = max(0, (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0)
        live = (try? c.decodeIfPresent(Bool.self, forKey: .live)) ?? false
    }
}

/// `GET /7tv/channels/:id/sets`: live first, then by name.
public struct SevenTvChannelSets: Sendable, Equatable, Decodable {
    public var channelID: String
    public var activeSetID: String?
    public var sets: [SevenTvSetRow]

    public init(channelID: String, activeSetID: String?, sets: [SevenTvSetRow]) {
        self.channelID = channelID
        self.activeSetID = activeSetID
        self.sets = sets
    }

    enum CodingKeys: String, CodingKey {
        case sets
        case channelID = "channelId"
        case activeSetID = "activeSetId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelID = (try? c.decodeIfPresent(String.self, forKey: .channelID)) ?? ""
        activeSetID = SevenTvWire.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .activeSetID))
        let rows = (try? c.decodeIfPresent([Lossy<SevenTvSetRow>].self, forKey: .sets)) ?? []
        sets = rows.compactMap(\.value)
    }

    /// The list as the server orders it: the live set first, then by name.
    public static func ordered(_ sets: [SevenTvSetRow]) -> [SevenTvSetRow] {
        sets.sorted { a, b in
            if a.live != b.live { return a.live }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

/// `set` in a set's page and in the answers of `POST /7tv/sets` and `PATCH /7tv/sets/:id`.
public struct SevenTvSetInfo: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var capacity: Int?
    public var count: Int
    public var ownerID: String?
    public var live: Bool

    public init(id: String, name: String, capacity: Int?, count: Int, ownerID: String?, live: Bool) {
        self.id = id
        self.name = name
        self.capacity = capacity
        self.count = count
        self.ownerID = ownerID
        self.live = live
    }

    public var summary: SevenTvSetRow {
        SevenTvSetRow(id: id, name: name, capacity: capacity, count: count, live: live)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, capacity, count, live
        case ownerID = "ownerId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        capacity = try? c.decodeIfPresent(Int.self, forKey: .capacity)
        count = max(0, (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0)
        ownerID = SevenTvWire.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .ownerID))
        live = (try? c.decodeIfPresent(Bool.self, forKey: .live)) ?? false
    }
}

/// `<set emote>` (57.4): an emote as it sits in one set. The same emote can be in a set twice under two aliases, so the
/// identity is the emote and its alias.
public struct SevenTvSetItem: Sendable, Equatable, Identifiable, Decodable {
    public var emoteID: String
    /// The name it has in this set.
    public var alias: String
    /// The emote's own 7TV name.
    public var name: String
    /// `alias != name`.
    public var renamed: Bool
    public var animated: Bool
    public var previewURL: URL?
    public var fileURL: URL?
    public var addedAt: Date?

    public var id: String { emoteID + "/" + alias }

    public init(
        emoteID: String, alias: String, name: String, animated: Bool, previewURL: URL?, fileURL: URL?, addedAt: Date? = nil
    ) {
        self.emoteID = emoteID
        self.alias = alias
        self.name = name
        self.renamed = alias != name
        self.animated = animated
        self.previewURL = previewURL
        self.fileURL = fileURL
        self.addedAt = addedAt
    }

    enum CodingKeys: String, CodingKey {
        case alias, name, renamed, animated
        case emoteID = "emoteId"
        case previewURL = "previewUrl"
        case fileURL = "fileUrl"
        case addedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoteID = try c.decode(String.self, forKey: .emoteID)
        let own = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        let alias = SevenTvWire.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .alias)) ?? own
        self.alias = alias
        name = own.isEmpty ? alias : own
        renamed = (try? c.decodeIfPresent(Bool.self, forKey: .renamed)) ?? (alias != name)
        animated = (try? c.decodeIfPresent(Bool.self, forKey: .animated)) ?? false
        previewURL = SevenTvWire.url(try? c.decodeIfPresent(String.self, forKey: .previewURL))
        fileURL = SevenTvWire.url(try? c.decodeIfPresent(String.self, forKey: .fileURL))
        addedAt = try? c.decodeIfPresent(Date.self, forKey: .addedAt)
    }
}

/// `GET /7tv/sets/:id?q=&page=`: 60 a page.
public struct SevenTvSetPage: Sendable, Equatable, Decodable {
    public var set: SevenTvSetInfo
    public var page: Int
    public var hasMore: Bool
    public var emotes: [SevenTvSetItem]

    public init(set: SevenTvSetInfo, page: Int, hasMore: Bool, emotes: [SevenTvSetItem]) {
        self.set = set
        self.page = page
        self.hasMore = hasMore
        self.emotes = emotes
    }

    enum CodingKeys: String, CodingKey { case set, page, hasMore, emotes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        set = try c.decode(SevenTvSetInfo.self, forKey: .set)
        page = max(1, (try? c.decodeIfPresent(Int.self, forKey: .page)) ?? 1)
        hasMore = (try? c.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
        let rows = (try? c.decodeIfPresent([Lossy<SevenTvSetItem>].self, forKey: .emotes)) ?? []
        emotes = rows.compactMap(\.value)
    }
}

/// What the emote writes answer: `{set_id, emote_id, alias}` (add, rename) or `{set_id, emote_id, removed}` (remove).
public struct SevenTvEmoteChange: Sendable, Equatable, Decodable {
    public var setID: String
    public var emoteID: String
    public var alias: String?
    public var removed: Bool

    public init(setID: String, emoteID: String, alias: String?, removed: Bool = false) {
        self.setID = setID
        self.emoteID = emoteID
        self.alias = alias
        self.removed = removed
    }

    enum CodingKeys: String, CodingKey {
        case alias, removed
        case setID = "setId"
        case emoteID = "emoteId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setID = (try? c.decodeIfPresent(String.self, forKey: .setID)) ?? ""
        emoteID = (try? c.decodeIfPresent(String.self, forKey: .emoteID)) ?? ""
        alias = SevenTvWire.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .alias))
        removed = (try? c.decodeIfPresent(Bool.self, forKey: .removed)) ?? false
    }
}

/// `POST /7tv/channels/:id/live`: `{channel_id, active_set_id}` (nil once cleared).
public struct SevenTvLiveChange: Sendable, Equatable, Decodable {
    public var channelID: String
    public var activeSetID: String?

    public init(channelID: String, activeSetID: String?) {
        self.channelID = channelID
        self.activeSetID = activeSetID
    }

    enum CodingKeys: String, CodingKey {
        case channelID = "channelId"
        case activeSetID = "activeSetId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelID = (try? c.decodeIfPresent(String.self, forKey: .channelID)) ?? ""
        activeSetID = SevenTvWire.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .activeSetID))
    }
}

// MARK: - names

/// The names the routes take (57.4): a set name is 1...100 characters, an alias 1...100 with no spaces. 7TV checks again.
public enum SevenTvRule {
    public static let nameMax = 100
    /// `GET /7tv/sets/:id` answers 60 emotes a page.
    public static let pageSize = 60

    /// A set name, trimmed; nil when empty or too long.
    public static func cleanSetName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= nameMax else { return nil }
        return name
    }

    /// An alias, trimmed; nil when empty, too long, or with a space inside.
    public static func cleanAlias(_ raw: String) -> String? {
        let alias = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, alias.count <= nameMax else { return nil }
        guard !alias.contains(where: { $0.isWhitespace }) else { return nil }
        return alias
    }

    /// The `q` of a set's page: trimmed and cut to 100 characters; nil when empty.
    public static func cleanFilter(_ raw: String) -> String? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return String(q.prefix(nameMax))
    }

    /// The emote of `emotes` already under `alias`, exactly (7TV compares names case-sensitively): the clash an add would hit.
    public static func clash(alias: String, in emotes: [SevenTvSetItem]) -> SevenTvSetItem? {
        emotes.first { $0.alias == alias }
    }

    /// The next name in a run: a number at the end goes up by one, else 2 goes on (`catJam` → `catJam2`, `catJam2` →
    /// `catJam3`). Kept to 100 characters by cutting the name, never the number.
    public static func nextAlias(after alias: String) -> String {
        let digits = String(alias.reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
        var stem = String(alias.dropLast(digits.count))
        var number = 2
        if !digits.isEmpty, digits.count <= 9, let n = Int(digits), !stem.isEmpty {
            number = n + 1
        } else {
            stem = alias
        }
        let suffix = String(number)
        if stem.count + suffix.count > nameMax { stem = String(stem.prefix(max(0, nameMax - suffix.count))) }
        return stem + suffix
    }

    /// A free name for an emote whose name `alias` is taken: the next in its run (`nextAlias`) that `taken` does not hold.
    public static func suggestAlias(for alias: String, taken: Set<String>) -> String {
        var candidate = nextAlias(after: alias)
        var tries = 0
        while taken.contains(candidate), tries < 1_000 {
            candidate = nextAlias(after: candidate)
            tries += 1
        }
        return candidate
    }

    /// `base` when it is free, else the next free one in its run.
    public static func freeAlias(_ base: String, taken: Set<String>) -> String {
        taken.contains(base) ? suggestAlias(for: base, taken: taken) : base
    }

    /// 7TV ids in paths (`[0-9A-Za-z]{20,32}`); anything else would be a 404 anyway.
    public static func isID(_ raw: String) -> Bool {
        (20...32).contains(raw.count) && raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

// MARK: - linking

/// The link the bookmarklet opens, `cobalt-apple://7tv-link?token=<token>` (57.1), and the token checks. The token is a full
/// 7TV login: it never goes into a log (`redacted`) and never into chat.
public enum SevenTvLink {
    public static let host = "7tv-link"

    /// The bookmarklet to copy. On 7tv.app while logged in it opens the link above with the session token.
    public static let bookmarklet =
        #"javascript:(()=>{const t=localStorage.getItem('7tv-token');if(!t){alert('log in to 7tv.app first');return;}location.href='cobalt-apple://7tv-link?token='+encodeURIComponent(t.replace(/^"|"$/g,''));})()"#

    /// 7TV's website.
    public static let website = URL(string: "https://7tv.app/")!

    // MARK: the login sheet (57.12)

    /// 7TV's own login page, which the app's sign-in sheet shows (Twitch, Discord or Kick).
    public static let loginURL = URL(string: "https://7tv.app/login")!

    /// The `localStorage` key 7tv.app keeps its session token under, on its own origin.
    public static let storageKey = "7tv-token"

    /// The sheet's own website data store (capystore's 7TV session, apart from Safari and from every other web view of the app).
    /// A fixed id, so the session survives launches; the apps pass it to `WKWebsiteDataStore(forIdentifier:)`.
    public static let loginDataStoreID = UUID(uuidString: "6F3A5C1E-7B24-4D8E-9A10-5E7C2B9D4F36")!

    /// The pages the sheet keeps inside its web view: 7TV and the three sign-ins it offers, with their subdomains. Anything
    /// else opens in the system browser.
    public static let loginHosts = [
        "7tv.app", "7tv.io", "id.twitch.tv", "twitch.tv", "passport.twitch.tv", "discord.com", "kick.com",
    ]

    /// True when `host` is `base` or a subdomain of it ("7tv.app", "api.7tv.app"; not "evil7tv.app").
    public static func host(_ host: String?, isOrIsUnder base: String) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return host == base || host.hasSuffix("." + base)
    }

    /// True while the sheet's page is 7tv.app itself (or a subdomain): the only origin whose `localStorage` is read.
    public static func isSevenTvHost(_ host: String?) -> Bool { Self.host(host, isOrIsUnder: "7tv.app") }

    /// True when a page on `host` may load inside the sheet's web view.
    public static func loginAllows(host: String?) -> Bool {
        loginHosts.contains { Self.host(host, isOrIsUnder: $0) }
    }

    /// What `localStorage.getItem('7tv-token')` answered (a string, `NSNull` or nothing): the token without the JSON quotes
    /// 7tv.app may keep around it, or nil while there is none yet. Not checked further: the link says what is wrong with it.
    public static func token(fromStorage value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let token = clean(raw)
        return token.isEmpty ? nil : token
    }

    /// True for any `cobalt-apple://7tv-link` link, with or without a token.
    public static func isLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "cobalt-apple" && url.host(percentEncoded: false)?.lowercased() == host
    }

    /// The token a `7tv-link` carries, cleaned (`clean`); nil for any other link or an empty token.
    public static func token(from url: URL) -> String? {
        guard isLink(url),
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value
        else { return nil }
        let token = clean(raw)
        return token.isEmpty ? nil : token
    }

    /// A pasted token: spaces and new lines gone, and the quotes `localStorage` keeps around it.
    public static func clean(_ raw: String) -> String {
        var token = raw.filter { !$0.isWhitespace }
        while token.hasPrefix("\"") || token.hasPrefix("'") { token.removeFirst() }
        while token.hasSuffix("\"") || token.hasSuffix("'") { token.removeLast() }
        return token
    }

    /// What the server accepts before asking 7TV (57.4): three base64url parts, at most 4096 characters.
    public static func looksLikeToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 4096 else { return false }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return parts.allSatisfy { part in
            part.allSatisfy { ch in ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "=") }
        }
    }

    /// A link as it may be logged: a `7tv-link` loses its query (the token); anything else is unchanged.
    public static func redacted(_ url: URL) -> String {
        guard isLink(url) else { return url.absoluteString }
        return "cobalt-apple://\(host)?token=<redacted>"
    }
}

// MARK: - refusals

/// The `/7tv` routes' refusals (57.4), with 7TV's own message where it gave one.
public enum SevenTvError: Error, Sendable, Equatable {
    /// `409 error.seventv.not_linked`: no account is linked.
    case notLinked
    /// `409 error.seventv.relink`: 7TV signed the token out; link again.
    case relink
    /// `400 error.seventv.token_invalid`: 7TV refused the token, or it does not look like one.
    case tokenInvalid
    /// `403 error.seventv.forbidden`: the channel did not give the account that right.
    case forbidden(String?)
    /// `404 error.seventv.not_found`.
    case notFound
    /// `429 error.seventv.rate_limited`.
    case rateLimited
    /// `400 error.seventv.rejected`: set full, bad alias; 7TV's message.
    case rejected(String?)
    /// `409 error.seventv.name_taken`: the set already has an emote under that name (`POST /7tv/sets/:id/emotes` without
    /// `override_conflicts`). `conflictEmoteID` and `alias` name the emote holding it, when the server knew (`conflict`).
    case nameTaken(conflictEmoteID: String?, alias: String?)
    /// `502 error.seventv.unavailable`: 7TV did not answer.
    case unavailable
    /// `503 error.seventv.not_ready`: the server's migration has not run yet.
    case notReady
    /// `404 error.seventv.file_not_found` (57.9): the library file to upload is not there.
    case fileNotFound
    /// `415 error.seventv.file_type` (57.9): only webp, gif, png, avif and jpeg go to 7TV.
    case fileType
    /// `413 error.seventv.too_big` (57.9, 57.10): over 7 MiB less 64 KiB, even after the fit (or an avif).
    case tooBig
    /// `400 error.seventv.too_large` (57.10): a shape outside width:height 1:32..3:1 (pass a crop box), or an avif over
    /// 1000 px a side.
    case tooLarge
    /// `422/502 error.seventv.fit_failed` (57.10): the picture would not decode or the fit ran out of time; the helper's reason.
    case fitFailed(String?)
    /// `429 error.seventv.busy` (57.10): the server is fitting another picture.
    case busy
    /// The server has no `/7tv` routes (an older server, or a client without them).
    case off
    /// The server could not be reached.
    case offline
    /// Anything else.
    case other

    /// The error a wire code names (with the server's `message`); nil for any other code.
    public init?(code: String, message: String? = nil) {
        let message = message.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch code {
        case "error.seventv.not_linked": self = .notLinked
        case "error.seventv.relink": self = .relink
        case "error.seventv.token_invalid": self = .tokenInvalid
        case "error.seventv.forbidden": self = .forbidden(message)
        case "error.seventv.not_found": self = .notFound
        case "error.seventv.rate_limited": self = .rateLimited
        case "error.seventv.rejected": self = .rejected(message)
        case "error.seventv.name_taken": self = .nameTaken(conflictEmoteID: nil, alias: nil)
        case "error.seventv.unavailable": self = .unavailable
        case "error.seventv.not_ready": self = .notReady
        case "error.seventv.file_not_found": self = .fileNotFound
        case "error.seventv.file_type": self = .fileType
        case "error.seventv.too_big": self = .tooBig
        case "error.seventv.too_large": self = .tooLarge
        case "error.seventv.fit_failed": self = .fitFailed(message)
        case "error.seventv.busy": self = .busy
        default: return nil
        }
    }

    /// Any error a 7TV call can throw, as a `SevenTvError` (a client or server without the routes is `.off`).
    public static func from(_ error: Error) -> SevenTvError {
        switch error {
        case let e as SevenTvError:
            return e
        case PipelineFailure.unsupported:
            return .off
        case let e as CobaltError:
            switch e {
            case .network: return .offline
            case .api(let code, let status):
                if let known = SevenTvError(code: code) { return known }
                if status == 404 { return .off }
                return .other
            case .invalidResponse(let status):
                return status == 404 ? .off : .other
            default: return .other
            }
        case let e as URLError:
            return e.code == .cancelled ? .other : .offline
        default:
            return .other
        }
    }

    /// 7TV's own words, for `forbidden` and `rejected`; the fit's reason for `fitFailed`.
    public var message: String? {
        switch self {
        case .forbidden(let m), .rejected(let m), .fitFailed(let m): return m
        default: return nil
        }
    }

    /// The account has to be linked (again) before anything else works.
    public var needsLink: Bool { self == .notLinked || self == .relink }

    /// The set already has an emote under that name.
    public var isNameTaken: Bool {
        if case .nameTaken = self { return true }
        return false
    }
}

// MARK: - wire helpers

enum SevenTvWire {
    /// A URL from a string that may be missing, empty or not a URL.
    static func url(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else { return nil }
        return url
    }

    static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : raw
    }
}

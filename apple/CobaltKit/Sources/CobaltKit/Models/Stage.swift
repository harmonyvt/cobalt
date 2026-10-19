import Foundation

// Stage (APP-API-CONTRACT section 29; `features.stage`): the stream canvas OBS loads, the viewer store and Twitch channel
// points, driven from the studio tab. The wire shapes of the owner routes (29.10), the patch the app sends, the errors the
// routes answer, and the rules the app and the server share (ranges, clamps, the masked link). "stage" is the code's word
// (`/studio` already means the save session); only the app's copy says "studio". The store that drives these is `StageStore`.

// MARK: - rules

public enum StageRule {
    /// "how crazy": tiles on screen at once.
    public static let densityRange = 5...100
    /// "tile life": seconds a tile stays.
    public static let tileSecondsRange = 3...30
    public static let tileScaleRange: ClosedRange<Double> = 0.5...1.6
    public static let spotlightSecondsRange = 10...120
    /// Tiles that may play video at once.
    public static let videoMaxRange = 0...24
    /// A reward's cost in channel points, and its global cooldown in seconds.
    public static let costRange = 1...1_000_000
    public static let cooldownRange = 0...604_800
    /// The search pool's words: the field is capped at this many code points (cut, never refused).
    public static let searchLimit = 120

    /// A slider settles this long before it is sent (last write wins).
    public static let debounce = 0.3
    /// The redemptions feed is read this often while the studio screen is visible.
    public static let pollInterval = 4.0
    /// Redemptions read per poll, and files per page of the pool sheet.
    public static let redemptionsLimit = 30
    public static let poolPageSize = 60

    public static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The search pool's words: control characters removed, trimmed, cut to `searchLimit` code points; nil when empty.
    public static func cleanSearch(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            switch s.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: continue
            default: scalars.append(s)
            }
        }
        var cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.unicodeScalars.count > searchLimit {
            var cut = String.UnicodeScalarView()
            cut.append(contentsOf: cleaned.unicodeScalars.prefix(searchLimit))
            cleaned = String(cut).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The OBS link as the screen shows it: only its last 4 characters are readable ("studio…/live/••••k7Q2").
    public static func masked(live url: URL) -> String {
        let token = url.lastPathComponent
        let tail = String(token.suffix(4))
        let host = url.host(percentEncoded: false) ?? ""
        let first = host.split(separator: ".").first.map(String.init) ?? host
        return "\(first)…/live/••••\(tail)"
    }

    /// A link without its scheme and trailing slash ("studio.capybaraharmony.com/store").
    public static func display(_ url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        var path = url.path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }
}

// MARK: - an item

/// One pool item (29.3): a public file of the library. The canvas shape carries `url` and `duration`; a store item leaves
/// them out and carries `thumbURL`.
public struct StageItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case image, video
    }

    public var id: String
    /// The 3-4 character code a viewer pastes into "summon" (upper case); nil when the server has not given one yet.
    public var code: String?
    public var title: String
    public var kind: Kind
    public var url: URL?
    public var posterURL: URL?
    public var thumbURL: URL?
    public var width: Int?
    public var height: Int?
    public var duration: Double?

    public init(
        id: String, code: String? = nil, title: String, kind: Kind = .image, url: URL? = nil, posterURL: URL? = nil,
        thumbURL: URL? = nil, width: Int? = nil, height: Int? = nil, duration: Double? = nil
    ) {
        self.id = id
        self.code = code
        self.title = title
        self.kind = kind
        self.url = url
        self.posterURL = posterURL
        self.thumbURL = thumbURL
        self.width = width
        self.height = height
        self.duration = duration
    }

    /// What a small tile draws: the store thumbnail, else the poster, else the file itself when it is a picture.
    public var thumbnail: URL? { thumbURL ?? posterURL ?? (kind == .image ? url : nil) }
}

extension StageItem: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, code, title, kind, url, width, height, duration
        case posterURL = "posterUrl"          // `poster_url` after convertFromSnakeCase
        case thumbURL = "thumbUrl"            // `thumb_url`
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        code = (try? c.decodeIfPresent(String.self, forKey: .code)).flatMap { $0.isEmpty ? nil : $0 }
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .image
        url = try? c.decodeIfPresent(URL.self, forKey: .url)
        posterURL = try? c.decodeIfPresent(URL.self, forKey: .posterURL)
        thumbURL = try? c.decodeIfPresent(URL.self, forKey: .thumbURL)
        width = try? c.decodeIfPresent(Int.self, forKey: .width)
        height = try? c.decodeIfPresent(Int.self, forKey: .height)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
    }
}

// MARK: - the spotlight

/// The one big tile on the canvas (29.3): the last summon or owner pick, while newer than `spotlight_seconds` or pinned.
public struct StageSpotlight: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case summon, owner
    }

    public var item: StageItem
    /// The viewer's display name; nil for a pick of the owner's.
    public var by: String?
    public var action: Source
    /// While pinned: when the pin ends.
    public var pinnedUntil: Date?
    /// When it was put up.
    public var at: Date

    public init(item: StageItem, by: String? = nil, action: Source = .owner, pinnedUntil: Date? = nil, at: Date = Date()) {
        self.item = item
        self.by = by
        self.action = action
        self.pinnedUntil = pinnedUntil
        self.at = at
    }

    /// Pinned at `now` (the pin has not run out).
    public func isPinned(now: Date) -> Bool { pinnedUntil.map { $0 > now } ?? false }
}

extension StageSpotlight: Decodable {
    enum CodingKeys: String, CodingKey { case item, by, action, pinnedUntil, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(StageItem.self, forKey: .item)
        by = (try? c.decodeIfPresent(String.self, forKey: .by)).flatMap { $0.isEmpty ? nil : $0 }
        action = (try? c.decodeIfPresent(String.self, forKey: .action)).flatMap(Source.init(rawValue:)) ?? .owner
        pinnedUntil = try? c.decodeIfPresent(Date.self, forKey: .pinnedUntil)
        at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? .distantPast
    }
}

// MARK: - the pool

/// What the canvas and the store draw from (29.3), as the owner routes report it.
public struct StagePool: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case library, collection, group, search
    }

    public var kind: Kind
    /// A collection or group id, or the search words; nil for the library.
    public var ref: String?
    /// The collection or set's name, the words, or "whole library".
    public var name: String?
    /// Files in the resolved pool.
    public var count: Int
    /// The collection or set was deleted: the pool is then empty.
    public var missing: Bool

    public init(kind: Kind = .library, ref: String? = nil, name: String? = nil, count: Int = 0, missing: Bool = false) {
        self.kind = kind
        self.ref = ref
        self.name = name
        self.count = count
        self.missing = missing
    }
}

extension StagePool: Decodable {
    enum CodingKeys: String, CodingKey { case kind, ref, name, count, missing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .library
        ref = try? c.decodeIfPresent(String.self, forKey: .ref)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        count = max(0, (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0)
        missing = (try? c.decodeIfPresent(Bool.self, forKey: .missing)) ?? false
    }
}

/// A pool the owner picks (`PATCH /stage` `pool`).
public enum StagePoolChoice: Sendable, Equatable {
    case library
    case collection(id: String)
    /// A set: a group of collections (APP-API-CONTRACT 28).
    case group(id: String)
    case search(words: String)

    public var kind: StagePool.Kind {
        switch self {
        case .library: return .library
        case .collection: return .collection
        case .group: return .group
        case .search: return .search
        }
    }

    /// The id or words; nil for the library.
    public var ref: String? {
        switch self {
        case .library: return nil
        case .collection(let id), .group(let id): return id
        case .search(let words): return words
        }
    }

    /// Whether the stage's pool is this choice.
    public func matches(_ pool: StagePool) -> Bool {
        pool.kind == kind && pool.ref == ref
    }
}

/// One page of the pool (`GET /stage/pool`, the "pick for the spotlight" sheet).
public struct StagePoolPage: Sendable, Equatable, Decodable {
    public var total: Int
    public var offset: Int
    /// The offset to ask for next; nil on the last page.
    public var next: Int?
    public var items: [StageItem]

    public init(total: Int = 0, offset: Int = 0, next: Int? = nil, items: [StageItem] = []) {
        self.total = total
        self.offset = offset
        self.next = next
        self.items = items
    }

    enum CodingKeys: String, CodingKey { case total, offset, next, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let listed = (try? c.decodeIfPresent([Lossy<StageItem>].self, forKey: .items)) ?? []
        items = listed.compactMap(\.value)
        total = max(items.count, (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? 0)
        offset = (try? c.decodeIfPresent(Int.self, forKey: .offset)) ?? 0
        next = try? c.decodeIfPresent(Int.self, forKey: .next)
    }
}

// MARK: - Twitch

/// The Twitch connection (29.8) as the stage reports it; nil on the stage while nothing is connected.
public struct StageTwitch: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// Rewards and the redemptions webhook are in place.
        case ok
        /// The token could not be refreshed: connect again.
        case reconnect
        /// Channel points need an Affiliate or Partner channel (Twitch refused to make the rewards).
        case notAffiliate = "not_affiliate"
        /// Connected; the rewards and the webhook are still being made (the next `GET /stage` retries).
        case settingUp = "setting_up"
    }

    public var login: String
    public var displayName: String
    public var connectedAt: Date?
    public var status: Status
    /// When Twitch last sent a redemption.
    public var lastEventAt: Date?

    public init(login: String, displayName: String? = nil, connectedAt: Date? = nil, status: Status = .ok, lastEventAt: Date? = nil) {
        self.login = login
        self.displayName = displayName ?? login
        self.connectedAt = connectedAt
        self.status = status
        self.lastEventAt = lastEventAt
    }
}

extension StageTwitch: Decodable {
    enum CodingKeys: String, CodingKey { case login, displayName, connectedAt, status, lastEventAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        login = try c.decode(String.self, forKey: .login)
        let shown = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        displayName = (shown?.isEmpty ?? true) ? login : (shown ?? login)
        connectedAt = try? c.decodeIfPresent(Date.self, forKey: .connectedAt)
        // an unknown status is not claimed to be healthy
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .settingUp
        lastEventAt = try? c.decodeIfPresent(Date.self, forKey: .lastEventAt)
    }
}

/// The four rewards viewers spend channel points on (29.2). Also the `action` of a reward.
public enum StageRewardKind: String, Sendable, Equatable, CaseIterable, Identifiable {
    case summon, chaos, shuffle, pin

    public var id: String { rawValue }
}

/// One reward (`<reward>` in 29.10).
public struct StageReward: Sendable, Equatable, Identifiable {
    public var action: StageRewardKind
    /// The title on Twitch (a bare word, or "capystore " + the word when Twitch had it taken).
    public var title: String
    public var cost: Int
    public var cooldownSeconds: Int
    public var enabled: Bool
    /// Twitch has the current values. False after a refused update; the next `GET /stage` retries.
    public var synced: Bool

    public var id: String { action.rawValue }

    public init(action: StageRewardKind, title: String? = nil, cost: Int, cooldownSeconds: Int, enabled: Bool, synced: Bool = true) {
        self.action = action
        self.title = title ?? action.rawValue
        self.cost = cost
        self.cooldownSeconds = cooldownSeconds
        self.enabled = enabled
        self.synced = synced
    }
}

extension StageReward: Decodable {
    enum CodingKeys: String, CodingKey { case action, title, cost, cooldownSeconds, enabled, synced }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .action)
        guard let kind = StageRewardKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "unknown reward \(raw)")
        }
        action = kind
        let named = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        title = (named?.isEmpty ?? true) ? kind.rawValue : (named ?? kind.rawValue)
        cost = (try? c.decodeIfPresent(Int.self, forKey: .cost)) ?? 0
        cooldownSeconds = (try? c.decodeIfPresent(Int.self, forKey: .cooldownSeconds)) ?? 0
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        synced = (try? c.decodeIfPresent(Bool.self, forKey: .synced)) ?? true
    }
}

/// One line of the redemptions feed (`<redemption>` in 29.10): a viewer's summon, chaos, shuffle or pin, or the owner's own
/// action (id `owner:…`, name "you").
public struct StageRedemption: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable {
        case done, refunded, failed
    }

    public enum Reason: String, Sendable, Equatable {
        case offAir = "off_air"
        case noMatch = "no_match"
        case disabled
        case error
        /// chaos or shuffle with an empty pool, or pin with nothing in the spotlight (29.9).
        case noEffect = "no_effect"
    }

    public var id: String
    /// `summon`, `chaos`, `shuffle`, `pin`, and for the owner's own also `skip`, `unpin`, `spotlight`.
    public var action: String
    public var userName: String
    /// What the viewer typed (summon), if anything.
    public var input: String?
    /// The item a summon resolved to.
    public var item: StageItem?
    public var status: Status
    public var reason: Reason?
    public var createdAt: Date

    public init(
        id: String, action: String, userName: String, input: String? = nil, item: StageItem? = nil,
        status: Status = .done, reason: Reason? = nil, createdAt: Date
    ) {
        self.id = id
        self.action = action
        self.userName = userName
        self.input = input
        self.item = item
        self.status = status
        self.reason = reason
        self.createdAt = createdAt
    }

    /// The owner's own action, not a viewer's.
    public var isOwner: Bool { id.hasPrefix("owner:") }

    /// The reward this is, when it is one of the four.
    public var kind: StageRewardKind? { StageRewardKind(rawValue: action) }
}

extension StageRedemption: Decodable {
    enum CodingKeys: String, CodingKey { case id, action, userName, input, item, status, reason, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        action = (try? c.decodeIfPresent(String.self, forKey: .action)) ?? ""
        userName = (try? c.decodeIfPresent(String.self, forKey: .userName)) ?? ""
        let typed = (try? c.decodeIfPresent(String.self, forKey: .input)) ?? nil
        input = (typed?.isEmpty ?? true) ? nil : typed
        item = try? c.decodeIfPresent(StageItem.self, forKey: .item)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .failed
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)).flatMap(Reason.init(rawValue:))
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

// MARK: - the stage

/// The stage (`<stage>` in 29.10): the settings, the pool, the OBS and store links, Twitch and the spotlight.
public struct StageSettings: Sendable, Equatable {
    public var onAir: Bool
    public var pool: StagePool
    /// "how crazy": tiles on screen, 5...100.
    public var density: Int
    /// "tile life": seconds, 3...30.
    public var tileSeconds: Int
    public var tileScale: Double
    public var spotlightAuto: Bool
    public var spotlightSeconds: Int
    /// The spotlight tile plays its sound on stream.
    public var sound: Bool
    public var videoMax: Int
    /// The store is open to viewers. Off (locked) by default: the store and its sign-in are gone until the owner opens it.
    public var storeOpen: Bool
    public var storeHint: Bool
    /// The canvas page OBS loads (secret token in the path).
    public var liveURL: URL
    public var storeURL: URL
    public var twitch: StageTwitch?
    public var spotlight: StageSpotlight?
    public var updatedAt: Date?

    public init(
        onAir: Bool = false, pool: StagePool = StagePool(), density: Int = 30, tileSeconds: Int = 10, tileScale: Double = 1,
        spotlightAuto: Bool = true, spotlightSeconds: Int = 20, sound: Bool = true, videoMax: Int = 12, storeOpen: Bool = false,
        storeHint: Bool = true, liveURL: URL, storeURL: URL, twitch: StageTwitch? = nil, spotlight: StageSpotlight? = nil,
        updatedAt: Date? = nil
    ) {
        self.onAir = onAir
        self.pool = pool
        self.density = density
        self.tileSeconds = tileSeconds
        self.tileScale = tileScale
        self.spotlightAuto = spotlightAuto
        self.spotlightSeconds = spotlightSeconds
        self.sound = sound
        self.videoMax = videoMax
        self.storeOpen = storeOpen
        self.storeHint = storeHint
        self.liveURL = liveURL
        self.storeURL = storeURL
        self.twitch = twitch
        self.spotlight = spotlight
        self.updatedAt = updatedAt
    }

    /// The canvas inside the app: the page with `?preview=1` (always muted, no store hint).
    public var previewURL: URL {
        guard var parts = URLComponents(url: liveURL, resolvingAgainstBaseURL: false) else { return liveURL }
        var items = parts.queryItems ?? []
        items.removeAll { $0.name == "preview" }
        items.append(URLQueryItem(name: "preview", value: "1"))
        parts.queryItems = items
        return parts.url ?? liveURL
    }

    /// The OBS link, masked to its last 4 characters.
    public var maskedLiveLink: String { StageRule.masked(live: liveURL) }

    /// The store link without its scheme.
    public var storeLinkText: String { StageRule.display(storeURL) }

    /// This stage with the patch's plain fields applied (clamped): what a slider shows before the server answers. The pool
    /// is not applied (its name and count are the server's).
    public func applying(_ patch: StagePatch) -> StageSettings {
        var out = self
        let p = patch.clamped()
        if let v = p.onAir { out.onAir = v }
        if let v = p.density { out.density = v }
        if let v = p.tileSeconds { out.tileSeconds = v }
        if let v = p.tileScale { out.tileScale = v }
        if let v = p.spotlightAuto { out.spotlightAuto = v }
        if let v = p.spotlightSeconds { out.spotlightSeconds = v }
        if let v = p.sound { out.sound = v }
        if let v = p.videoMax { out.videoMax = v }
        if let v = p.storeOpen { out.storeOpen = v }
        if let v = p.storeHint { out.storeHint = v }
        return out
    }
}

extension StageSettings: Decodable {
    enum CodingKeys: String, CodingKey {
        case onAir, pool, density, tileSeconds, tileScale, spotlightAuto, spotlightSeconds, sound, videoMax
        case storeOpen, storeHint, twitch, spotlight, updatedAt
        case liveURL = "liveUrl"              // `live_url` after convertFromSnakeCase
        case storeURL = "storeUrl"            // `store_url`
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onAir = (try? c.decodeIfPresent(Bool.self, forKey: .onAir)) ?? false
        pool = (try? c.decodeIfPresent(StagePool.self, forKey: .pool)) ?? StagePool()
        density = StageRule.clamp((try? c.decodeIfPresent(Int.self, forKey: .density)) ?? 30, to: StageRule.densityRange)
        tileSeconds = StageRule.clamp((try? c.decodeIfPresent(Int.self, forKey: .tileSeconds)) ?? 10, to: StageRule.tileSecondsRange)
        tileScale = StageRule.clamp((try? c.decodeIfPresent(Double.self, forKey: .tileScale)) ?? 1, to: StageRule.tileScaleRange)
        spotlightAuto = (try? c.decodeIfPresent(Bool.self, forKey: .spotlightAuto)) ?? true
        spotlightSeconds = StageRule.clamp(
            (try? c.decodeIfPresent(Int.self, forKey: .spotlightSeconds)) ?? 20, to: StageRule.spotlightSecondsRange)
        sound = (try? c.decodeIfPresent(Bool.self, forKey: .sound)) ?? true
        videoMax = StageRule.clamp((try? c.decodeIfPresent(Int.self, forKey: .videoMax)) ?? 12, to: StageRule.videoMaxRange)
        storeOpen = (try? c.decodeIfPresent(Bool.self, forKey: .storeOpen)) ?? false      // locked unless the server says open
        storeHint = (try? c.decodeIfPresent(Bool.self, forKey: .storeHint)) ?? true
        liveURL = try c.decode(URL.self, forKey: .liveURL)
        storeURL = try c.decode(URL.self, forKey: .storeURL)
        twitch = try? c.decodeIfPresent(StageTwitch.self, forKey: .twitch)
        spotlight = try? c.decodeIfPresent(StageSpotlight.self, forKey: .spotlight)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

/// `GET /stage`: the stage and its four rewards.
public struct StageSnapshot: Sendable, Equatable, Decodable {
    public var stage: StageSettings
    public var rewards: [StageReward]

    public init(stage: StageSettings, rewards: [StageReward] = []) {
        self.stage = stage
        self.rewards = rewards
    }

    enum CodingKeys: String, CodingKey { case stage, rewards }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decode(StageSettings.self, forKey: .stage)
        rewards = ((try? c.decodeIfPresent([Lossy<StageReward>].self, forKey: .rewards)) ?? []).compactMap(\.value)
    }
}

// MARK: - what the app sends

/// `PATCH /stage`: any of the fields. Out-of-range numbers are clamped by the server and by `clamped()` here.
public struct StagePatch: Sendable, Equatable {
    public var onAir: Bool?
    public var pool: StagePoolChoice?
    public var density: Int?
    public var tileSeconds: Int?
    public var tileScale: Double?
    public var spotlightAuto: Bool?
    public var spotlightSeconds: Int?
    public var sound: Bool?
    public var videoMax: Int?
    public var storeOpen: Bool?
    public var storeHint: Bool?

    public init(
        onAir: Bool? = nil, pool: StagePoolChoice? = nil, density: Int? = nil, tileSeconds: Int? = nil, tileScale: Double? = nil,
        spotlightAuto: Bool? = nil, spotlightSeconds: Int? = nil, sound: Bool? = nil, videoMax: Int? = nil,
        storeOpen: Bool? = nil, storeHint: Bool? = nil
    ) {
        self.onAir = onAir
        self.pool = pool
        self.density = density
        self.tileSeconds = tileSeconds
        self.tileScale = tileScale
        self.spotlightAuto = spotlightAuto
        self.spotlightSeconds = spotlightSeconds
        self.sound = sound
        self.videoMax = videoMax
        self.storeOpen = storeOpen
        self.storeHint = storeHint
    }

    public var isEmpty: Bool { self == StagePatch() }

    /// Every number inside its range.
    public func clamped() -> StagePatch {
        var out = self
        out.density = density.map { StageRule.clamp($0, to: StageRule.densityRange) }
        out.tileSeconds = tileSeconds.map { StageRule.clamp($0, to: StageRule.tileSecondsRange) }
        out.tileScale = tileScale.map { StageRule.clamp($0, to: StageRule.tileScaleRange) }
        out.spotlightSeconds = spotlightSeconds.map { StageRule.clamp($0, to: StageRule.spotlightSecondsRange) }
        out.videoMax = videoMax.map { StageRule.clamp($0, to: StageRule.videoMaxRange) }
        return out
    }

    /// A patch of the same fields this one sets, holding the values `settings` has now (what to put back when a write
    /// fails). The pool is not part of it (the server's name and count are not guessed).
    public func values(in settings: StageSettings) -> StagePatch {
        var out = StagePatch()
        if onAir != nil { out.onAir = settings.onAir }
        if density != nil { out.density = settings.density }
        if tileSeconds != nil { out.tileSeconds = settings.tileSeconds }
        if tileScale != nil { out.tileScale = settings.tileScale }
        if spotlightAuto != nil { out.spotlightAuto = settings.spotlightAuto }
        if spotlightSeconds != nil { out.spotlightSeconds = settings.spotlightSeconds }
        if sound != nil { out.sound = settings.sound }
        if videoMax != nil { out.videoMax = settings.videoMax }
        if storeOpen != nil { out.storeOpen = settings.storeOpen }
        if storeHint != nil { out.storeHint = settings.storeHint }
        return out
    }

    /// This patch with `later`'s fields on top (the last write wins).
    public func merging(_ later: StagePatch) -> StagePatch {
        var out = self
        if let v = later.onAir { out.onAir = v }
        if let v = later.pool { out.pool = v }
        if let v = later.density { out.density = v }
        if let v = later.tileSeconds { out.tileSeconds = v }
        if let v = later.tileScale { out.tileScale = v }
        if let v = later.spotlightAuto { out.spotlightAuto = v }
        if let v = later.spotlightSeconds { out.spotlightSeconds = v }
        if let v = later.sound { out.sound = v }
        if let v = later.videoMax { out.videoMax = v }
        if let v = later.storeOpen { out.storeOpen = v }
        if let v = later.storeHint { out.storeHint = v }
        return out
    }

    /// The JSON object the route takes: only the fields that are set, numbers clamped.
    func body() -> [String: Any] {
        let p = clamped()
        var out: [String: Any] = [:]
        if let v = p.onAir { out["on_air"] = v }
        if let pool = p.pool {
            var object: [String: Any] = ["kind": pool.kind.rawValue]
            if let ref = pool.ref { object["ref"] = ref }
            out["pool"] = object
        }
        if let v = p.density { out["density"] = v }
        if let v = p.tileSeconds { out["tile_seconds"] = v }
        if let v = p.tileScale { out["tile_scale"] = v }
        if let v = p.spotlightAuto { out["spotlight_auto"] = v }
        if let v = p.spotlightSeconds { out["spotlight_seconds"] = v }
        if let v = p.sound { out["sound"] = v }
        if let v = p.videoMax { out["video_max"] = v }
        if let v = p.storeOpen { out["store_open"] = v }
        if let v = p.storeHint { out["store_hint"] = v }
        return out
    }
}

/// What the owner does to the canvas (`POST /stage/action`). Each is also a row in the feed ("you").
public enum StageAction: Sendable, Equatable {
    /// Drop the spotlight now and pick again.
    case skip
    /// Keep the spotlight up (2 more minutes).
    case pin
    case unpin
    /// Wipe the canvas and refill it.
    case shuffle
    /// 100 tiles on screen for 30 seconds.
    case chaos
    /// Put this pool item in the spotlight (the owner's own pick).
    case spotlight(itemID: String)

    var type: String {
        switch self {
        case .skip: return "skip"
        case .pin: return "pin"
        case .unpin: return "unpin"
        case .shuffle: return "shuffle"
        case .chaos: return "chaos"
        case .spotlight: return "spotlight"
        }
    }

    var itemID: String? {
        if case .spotlight(let id) = self { return id }
        return nil
    }
}

/// Where the Twitch sign-in came back to: `cobalt-apple://stage?twitch=connected` or `?twitch=failed&reason=<code>` (29.4).
/// The authentication session hands the app this URL; the same link also reaches the app if the session was closed.
public enum StageTwitchReturn: Sendable, Equatable {
    case connected
    case failed(reason: String?)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "cobalt-apple", url.host(percentEncoded: false)?.lowercased() == "stage",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let result = items.first(where: { $0.name == "twitch" })?.value
        else { return nil }
        switch result {
        case "connected":
            self = .connected
        case "failed":
            self = .failed(reason: items.first(where: { $0.name == "reason" })?.value)
        default:
            return nil
        }
    }
}

// MARK: - refusals

/// What the stage routes answer when they refuse (mapped from the wire in `HTTPCobaltClient`), and two classes of failure
/// that never reached the server's answer. `from(_:)` classifies anything a call can throw.
public enum StageError: Error, Sendable, Equatable {
    /// `400 error.stage.bad_request`: a bad kind, an unknown collection or set, empty words, bad JSON.
    case badRequest
    /// `404 error.stage.off`: the server has no stage host (or the route is not there).
    case off
    /// `404 error.stage.not_found`: that pool item (or reward) is not there.
    case notFound
    /// `404 error.stage.twitch_off`: the server has no Twitch secrets.
    case twitchOff
    /// `409 error.stage.off_air`: an action needs the stage on air.
    case offAir
    /// `503 error.stage.search_unavailable`: the meaning search is off or asleep; nothing changed.
    case searchUnavailable
    /// `503 error.api.generic`: the server cannot take it right now.
    case unavailable
    /// The server could not be reached.
    case offline
    /// Anything else.
    case other

    /// The error a wire code names; nil for any other code.
    public init?(code: String) {
        switch code {
        case "error.stage.bad_request": self = .badRequest
        case "error.stage.off": self = .off
        case "error.stage.not_found": self = .notFound
        case "error.stage.twitch_off": self = .twitchOff
        case "error.stage.off_air": self = .offAir
        case "error.stage.search_unavailable": self = .searchUnavailable
        default: return nil
        }
    }

    /// Any error a stage call can throw, as a `StageError` (a client that predates the routes is `.off`).
    public static func from(_ error: Error) -> StageError {
        switch error {
        case let e as StageError:
            return e
        case PipelineFailure.unsupported:
            return .off
        case let e as CobaltError:
            switch e {
            case .network: return .offline
            case .api(let code, let status):
                if let known = StageError(code: code) { return known }
                return status == 503 ? .unavailable : .other
            default: return .other
            }
        case let e as URLError:
            return e.code == .cancelled ? .other : .offline
        default:
            return .other
        }
    }
}

import Foundation

// The values the twitch tab draws (APP-API-CONTRACT 70). Built off main by `TwitchChatEngine`; immutable, Sendable,
// Equatable (apple/ARCHITECTURE.md rule 2). Nothing here is stored: chat lives only while the tab is open.

/// An emote as chat draws it: a Twitch emote from the message's own `emotes` tag, or a 7TV emote matched by name.
public struct ChatEmote: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable { case twitch, sevenTv, sevenTvGlobal, kick, youtube }

    /// Twitch's or 7TV's emote id.
    public var id: String
    public var name: String {
        didSet { lowercasedName = name.lowercased() }
    }
    /// Precomputed lowercased name for allocation-free picker filtering and composer autocomplete.
    public private(set) var lowercasedName: String
    /// The 2x picture.
    public var url: URL
    public var animated: Bool
    /// A 7TV zero-width emote: drawn on top of the emote before it (a hat, a rain).
    public var zeroWidth: Bool
    /// Width over height (wide emotes are wider than tall).
    public var aspect: Double
    public var source: Source

    public init(id: String, name: String, url: URL, animated: Bool, zeroWidth: Bool = false, aspect: Double = 1, source: Source) {
        self.id = id
        self.name = name
        self.lowercasedName = name.lowercased()
        self.url = url
        self.animated = animated
        self.zeroWidth = zeroWidth
        self.aspect = aspect
        self.source = source
    }

    /// Twitch's CDN, the dark theme at 2x. `emotesv2_` ids are the newer emotes, which may be animated (the `default` format
    /// answers the GIF when there is one).
    public static func twitch(id: String, name: String, animated: Bool? = nil) -> ChatEmote {
        let url = URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0")!
        return ChatEmote(id: id, name: name, url: url, animated: animated ?? id.hasPrefix("emotesv2_"), source: .twitch)
    }
}

/// A badge in front of a name: Twitch's (broadcaster, moderator, vip, subscriber…) or a 7TV cosmetic badge.
public struct ChatBadge: Sendable, Hashable {
    public var id: String
    public var title: String
    public var url: URL
    public var animated: Bool

    public init(id: String, title: String, url: URL, animated: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.animated = animated
    }
}

/// A 7TV paint: the gradient, image texture, multi-layer composite, or plain colour (plus drop shadows) a supporter's
/// name is drawn in.
public struct SevenTvPaint: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case linear, radial, plain, image }

    /// Radial gradient geometry (`circle` vs `ellipse`), matching CSS `radial-gradient(<shape>, ...)`.
    public enum RadialShape: String, Sendable, Hashable {
        case circle
        case ellipse

        public init(wireValue: String?) {
            switch (wireValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "circle": self = .circle
            default: self = .ellipse
            }
        }
    }

    public struct Stop: Sendable, Hashable {
        /// 0...1 along the gradient.
        public var at: Double
        /// 0xRRGGBBAA.
        public var rgba: UInt32

        public init(at: Double, rgba: UInt32) {
            self.at = at
            self.rgba = rgba
        }
    }

    public struct Shadow: Sendable, Hashable {
        public var xOffset: Double
        public var yOffset: Double
        public var radius: Double
        /// 0xRRGGBBAA.
        public var rgba: UInt32

        public init(xOffset: Double, yOffset: Double, radius: Double, rgba: UInt32) {
            self.xOffset = xOffset
            self.yOffset = yOffset
            self.radius = radius
            self.rgba = rgba
        }
    }

    /// One composited layer inside a 7TV paint (ordered bottom-to-top).
    public struct Layer: Sendable, Hashable {
        public var kind: Kind
        /// Degrees, CSS style (0 points up, 90 right).
        public var angle: Double
        public var shape: RadialShape
        public var repeats: Bool
        public var stops: [Stop]
        /// Solid colour or fallback colour (0xRRGGBBAA).
        public var color: UInt32?
        /// Texture URL when `kind == .image`.
        public var imageURL: URL?
        /// Layer opacity in `0...1`.
        public var opacity: Double
        /// True when an `.image` layer is expected to animate (WebP/AVIF/GIF).
        public var animatedImage: Bool

        public init(
            kind: Kind,
            angle: Double = 90,
            shape: RadialShape = .ellipse,
            repeats: Bool = false,
            stops: [Stop] = [],
            color: UInt32? = nil,
            imageURL: URL? = nil,
            opacity: Double = 1,
            animatedImage: Bool = true
        ) {
            self.kind = kind
            self.angle = angle
            self.shape = shape
            self.repeats = repeats
            self.stops = stops
            self.color = color
            self.imageURL = imageURL
            self.opacity = max(0, min(1, opacity))
            self.animatedImage = animatedImage
        }

        /// True when this image URL looks like a static asset (e.g. `1x_static.webp`, `.png`, `.jpg`).
        public static func inferAnimatedImage(url: URL?) -> Bool {
            guard let url else { return false }
            let path = url.path.lowercased()
            if path.contains("_static.") || path.hasSuffix(".png") || path.hasSuffix(".jpg") || path.hasSuffix(".jpeg") {
                return false
            }
            return true
        }
    }

    /// GPU shader animation parameters for gradient / sheen / iridescent effects.
    public struct Animation: Sendable, Hashable {
        public enum Mode: String, Sendable, Hashable {
            /// Static paint (no shader clock).
            case none
            /// Smooth continuous drift along the gradient axis or radial rings.
            case drift
            /// Periodic diagonal specular sheen sweep across the text.
            case shimmer
            /// Smooth iridescent hue-wave prism sheen.
            case iridescent
        }

        public var mode: Mode
        /// Cycles per second.
        public var speed: Double
        /// Effect strength in `0...1`.
        public var intensity: Double

        public static let none = Animation(mode: .none, speed: 0, intensity: 0)

        public var isAnimated: Bool { mode != .none && speed > 0 && intensity > 0 }

        public init(mode: Mode, speed: Double = 0.18, intensity: Double = 0.5) {
            self.mode = mode
            self.speed = max(0, speed)
            self.intensity = max(0, min(1, intensity))
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Degrees, CSS style (0 points up, 90 right).
    public var angle: Double
    /// Radial gradient geometry (`circle` vs `ellipse`).
    public var shape: RadialShape
    public var repeats: Bool
    public var stops: [Stop]
    /// A plain paint's colour (0xRRGGBBAA), or a fallback colour while an image paint loads.
    public var color: UInt32?
    /// An image (`URL`) paint's texture URL.
    public var imageURL: URL?
    public var shadows: [Shadow]
    /// Explicit multi-layer stack (bottom-to-top). Empty for single-layer v3 paints (`resolvedLayers` synthesises one).
    public var layers: [Layer]
    /// GPU shader animation specification.
    public var animation: Animation

    public init(
        id: String,
        name: String,
        kind: Kind,
        angle: Double = 90,
        shape: RadialShape = .ellipse,
        repeats: Bool = false,
        stops: [Stop] = [],
        color: UInt32? = nil,
        imageURL: URL? = nil,
        shadows: [Shadow] = [],
        layers: [Layer] = [],
        animation: Animation? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.angle = angle
        self.shape = shape
        self.repeats = repeats
        self.stops = stops
        self.color = color
        self.imageURL = imageURL
        self.shadows = shadows
        self.layers = layers
        self.animation = animation ?? Self.defaultAnimation(kind: kind, repeats: repeats, stops: stops, layers: layers)
    }

    /// Layers in bottom-to-top compositing order. Single-layer v3 paints yield one synthesised layer.
    public var resolvedLayers: [Layer] {
        if !layers.isEmpty { return layers }
        return [Layer(
            kind: kind,
            angle: angle,
            shape: shape,
            repeats: repeats,
            stops: stops,
            color: color,
            imageURL: imageURL,
            opacity: 1,
            animatedImage: Layer.inferAnimatedImage(url: imageURL)
        )]
    }

    /// True when any layer renders a remote image/texture URL.
    public var hasImageLayer: Bool {
        resolvedLayers.contains { $0.kind == .image && $0.imageURL != nil }
    }

    /// True when this paint needs the lightweight GPU shader clock (`TimelineView`).
    public var hasAnimatedShader: Bool {
        animation.isAnimated
    }

    /// Default subtle GPU animation inferred from a paint's geometry when none is specified explicitly:
    /// repeating gradients smoothly drift along their cycle; rich 3+ stop gradients get a refined metallic shimmer;
    /// plain colours and simple 2-stop gradients stay static (zero clock overhead).
    public static func defaultAnimation(
        kind: Kind,
        repeats: Bool,
        stops: [Stop],
        layers: [Layer] = []
    ) -> Animation {
        let active: [Layer] = layers.isEmpty
            ? [Layer(kind: kind, repeats: repeats, stops: stops)]
            : layers
        if active.contains(where: { ($0.kind == .linear || $0.kind == .radial) && $0.repeats && $0.stops.count >= 2 }) {
            return Animation(mode: .drift, speed: 0.16, intensity: 0.85)
        }
        if active.contains(where: { ($0.kind == .linear || $0.kind == .radial) && $0.stops.count >= 3 }) {
            return Animation(mode: .shimmer, speed: 0.22, intensity: 0.30)
        }
        return .none
    }

    /// Gradient stops sorted by position; repeating gradients are tiled across `0...1` (both backward below the first
    /// stop and forward past the last stop) so non-shader fallback paths also honour CSS repeating gradients.
    public var resolvedStops: [Stop] {
        Self.resolveStops(stops, repeats: repeats)
    }

    public static func resolveStops(_ stops: [Stop], repeats: Bool) -> [Stop] {
        let sorted = stops.sorted { $0.at < $1.at }
        guard repeats, sorted.count >= 2, let first = sorted.first?.at, let last = sorted.last?.at else {
            return sorted
        }
        let period = last - first
        guard period > 0.005, (first > 0.001 || last < 0.999) else { return sorted }

        let startCycle = first > 0.001 ? -Int(ceil(first / period)) : 0
        let maxCycles = 24
        var out: [Stop] = []
        var prevSample: (pos: Double, rgba: UInt32)?

        for cycleOffset in 0..<maxCycles {
            let cycle = startCycle + cycleOffset
            let offset = Double(cycle) * period
            if first + offset >= 1.0 { break }
            var hitEnd = false
            for s in sorted {
                let pos = s.at + offset
                if pos < 0.0 {
                    prevSample = (pos, s.rgba)
                    continue
                }
                if out.isEmpty, pos > 0.0, let prev = prevSample {
                    let span = pos - prev.pos
                    let t = span > 0 ? (0.0 - prev.pos) / span : 1.0
                    out.append(Stop(at: 0.0, rgba: Self.lerpRGBA(prev.rgba, s.rgba, t: t)))
                }
                if pos > 1.0 {
                    if let prev = out.last, prev.at < 1.0 {
                        let span = pos - prev.at
                        let t = span > 0 ? (1.0 - prev.at) / span : 1.0
                        out.append(Stop(at: 1.0, rgba: Self.lerpRGBA(prev.rgba, s.rgba, t: t)))
                    }
                    hitEnd = true
                    break
                }
                out.append(Stop(at: pos, rgba: s.rgba))
                prevSample = (pos, s.rgba)
            }
            if hitEnd { break }
        }
        return out.isEmpty ? sorted : out
    }

    private static func lerpRGBA(_ a: UInt32, _ b: UInt32, t: Double) -> UInt32 {
        let k = max(0, min(1, t))
        func mix(_ shift: UInt32) -> UInt32 {
            let ca = Double((a >> shift) & 0xFF)
            let cb = Double((b >> shift) & 0xFF)
            return UInt32((ca + (cb - ca) * k).rounded()) & 0xFF
        }
        return (mix(24) << 24) | (mix(16) << 16) | (mix(8) << 8) | mix(0)
    }
}

/// One part of a message.
public enum ChatFragment: Sendable, Hashable {
    case text(String)
    case emote(ChatEmote)
    /// An emote with zero-width emotes stacked on it.
    case stack(ChatEmote, [ChatEmote])
    /// `@name`.
    case mention(String)
    case link(URL)
}

/// One wrap-able visual piece of a chat message, pre-tokenized once when the line is built off-main.
public enum ChatRenderPiece: Sendable, Hashable {
    case word(String)
    case emote(ChatEmote, [ChatEmote])
    case mention(String)
    case link(URL)
}

public struct TwitchChatLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case message
        /// `/me`: the whole message in the name's colour.
        case action
        /// A USERNOTICE (a sub, a raid, a gift): Twitch's own words, then the user's message when there is one.
        case notice(String)
        /// Something the app says (connected, slow mode on, a send refused).
        case system
    }

    /// Twitch's message id (`id` tag), or a channel-namespaced local/system id (`"\(channel):local-N"` / `"\(channel):sys-N"`).
    public var id: String
    /// Lowercased channel login this message belongs to (empty only for legacy/synthetic fixtures that omit it).
    public var channel: String
    public var kind: Kind
    public var login: String
    public var displayName: String
    /// 0xRRGGBB, nil when the user never picked one (the view picks a steady colour from the name).
    public var color: UInt32?
    public var badges: [ChatBadge]
    public var fragments: [ChatFragment] {
        didSet { renderPieces = Self.tokenize(fragments) }
    }
    /// Pre-tokenized words/emotes/mentions/links so `TwitchChatRow.body` never calls `String.split` per evaluation.
    public private(set) var renderPieces: [ChatRenderPiece]
    public var timestamp: Date
    /// The message @-mentions the signed-in user.
    public var mentionsMe: Bool
    /// Sent from this device.
    public var mine: Bool
    /// `reply-parent-*`: who and what this answers.
    public var replyTo: Reply?
    /// Removed by a moderator (CLEARMSG / CLEARCHAT): drawn struck through.
    public var deleted: Bool = false

    public struct Reply: Sendable, Hashable {
        public var login: String
        public var displayName: String
        public var text: String

        public init(login: String, displayName: String, text: String) {
            self.login = login
            self.displayName = displayName
            self.text = text
        }
    }

    public init(
        id: String,
        channel: String = "",
        kind: Kind,
        login: String,
        displayName: String,
        color: UInt32?,
        badges: [ChatBadge],
        fragments: [ChatFragment],
        timestamp: Date,
        mentionsMe: Bool,
        mine: Bool,
        replyTo: Reply?,
        deleted: Bool = false
    ) {
        self.id = id
        self.channel = channel.isEmpty ? "" : StreamAddress.canonicalKey(for: channel)
        self.kind = kind
        self.login = login
        self.displayName = displayName
        self.color = color
        self.badges = badges
        self.fragments = fragments
        self.renderPieces = Self.tokenize(fragments)
        self.timestamp = timestamp
        self.mentionsMe = mentionsMe
        self.mine = mine
        self.replyTo = replyTo
        self.deleted = deleted
    }

    /// Splits `.text` fragments into word tokens once when constructing or updating a line.
    public static func tokenize(_ fragments: [ChatFragment]) -> [ChatRenderPiece] {
        var out: [ChatRenderPiece] = []
        out.reserveCapacity(fragments.count * 2)
        for f in fragments {
            switch f {
            case .text(let s):
                for w in s.split(separator: " ", omittingEmptySubsequences: true) {
                    out.append(.word(String(w)))
                }
            case .emote(let e):
                out.append(.emote(e, []))
            case .stack(let e, let more):
                out.append(.emote(e, more))
            case .mention(let m):
                out.append(.mention(m))
            case .link(let u):
                out.append(.link(u))
            }
        }
        return out
    }

    /// True when `id` was minted locally (`local-*`, `sys-*`, or channel-namespaced `ch:local-*` / `ch:sys-*`),
    /// so it must never be sent to Twitch as `reply-parent-msg-id`.
    public static func isSyntheticID(_ id: String) -> Bool {
        id.hasPrefix("local-") || id.hasPrefix("sys-") || id.contains(":local-") || id.contains(":sys-")
    }

    public var isSyntheticID: Bool { Self.isSyntheticID(id) }

    /// The plain text again (for copying and replying).
    public var plainText: String {
        fragments.map { f -> String in
            switch f {
            case .text(let s): return s
            case .emote(let e): return e.name
            case .stack(let e, let more): return ([e] + more).map(\.name).joined(separator: " ")
            case .mention(let m): return "@\(m)"
            case .link(let u): return u.absoluteString
            }
        }.joined(separator: " ")
    }
}

/// The room's modes (ROOMSTATE).
public struct TwitchRoomState: Sendable, Hashable {
    public var slowSeconds = 0
    public var emoteOnly = false
    public var subsOnly = false
    /// Minutes; -1 off, 0 any follower.
    public var followersOnlyMinutes = -1
    public init() {}
}

public enum TwitchChatStatus: Sendable, Hashable {
    case idle
    case connecting
    /// Joined. `canSend` false: read-only (anonymous, or a token without the chat scopes).
    case joined(canSend: Bool)
    /// Lost; retrying after `retryIn` seconds.
    case reconnecting(retryIn: Int)
    case failed(String)
}

/// What the chat view draws, published by the engine at most ~8 times a second.
public struct TwitchChatSnapshot: Sendable, Equatable {
    public var channel: String
    public var status: TwitchChatStatus
    public var room: TwitchRoomState
    /// Oldest first, at most `TwitchChatEngine.lineLimit`.
    public var lines: [TwitchChatLine]
    /// 7TV paints by login (lowercased), applied when a line is drawn: they arrive after the lines often.
    public var paints: [String: SevenTvPaint]
    /// 7TV badges by login.
    public var sevenTvBadges: [String: ChatBadge]
    /// Bumped when the emote list changes (the composer re-reads `emotes`).
    public var emotesVersion: Int

    public init(channel: String) {
        self.channel = channel
        self.status = .idle
        self.room = TwitchRoomState()
        self.lines = []
        self.paints = [:]
        self.sevenTvBadges = [:]
        self.emotesVersion = 0
    }

    public var canSend: Bool {
        if case .joined(let can) = status { return can }
        return false
    }
}

/// The emotes the composer offers, best first: the channel's 7TV, the user's Twitch emotes, then 7TV global. `sections`
/// is the same set grouped for the emote picker (70.6), plus the channel's Twitch emotes the user can't send yet.
public struct TwitchEmoteList: Sendable, Equatable {
    public var emotes: [ChatEmote]
    public var sections: [TwitchEmoteSection]
    public init(emotes: [ChatEmote] = [], sections: [TwitchEmoteSection] = []) {
        self.emotes = emotes
        self.sections = sections
    }

    /// The picker's sections with only the emotes whose name contains `query` (case-insensitive; names starting with it
    /// first), empty sections dropped. A blank query answers every section as it is.
    public func sections(matching query: String) -> [TwitchEmoteSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sections.filter { !$0.emotes.isEmpty } }
        return sections.compactMap { section in
            var starts: [ChatEmote] = []
            var contains: [ChatEmote] = []
            for e in section.emotes {
                let n = e.lowercasedName
                if n.hasPrefix(q) { starts.append(e) } else if n.contains(q) { contains.append(e) }
            }
            guard !starts.isEmpty || !contains.isEmpty else { return nil }
            var out = section
            out.emotes = starts + contains
            return out
        }
    }

    /// Groups the emotes for the picker: this channel's 7TV set, this channel's Twitch emotes (locked when the user can't
    /// send them), the user's other Twitch emotes, Twitch global, 7TV global (minus names the channel's set took).
    public static func pickerSections(
        sevenTvChannel: [ChatEmote], channelTwitch: [ChatEmote], user: [TwitchUserEmote], roomID: String?,
        sevenTvGlobal: [ChatEmote]
    ) -> [TwitchEmoteSection] {
        let byName: ([ChatEmote]) -> [ChatEmote] = { $0.sorted { $0.lowercasedName < $1.lowercasedName } }
        let usable = Set(user.map(\.emote.id))

        var channel: [ChatEmote] = []
        var channelIDs = Set<String>()
        for e in channelTwitch where channelIDs.insert(e.id).inserted { channel.append(e) }
        if let roomID {
            for u in user where u.ownerID == roomID && channelIDs.insert(u.emote.id).inserted { channel.append(u.emote) }
        }
        // the ones the user can send come first, Twitch's own order (by tier) kept inside each half
        channel = channel.filter { usable.contains($0.id) } + channel.filter { !usable.contains($0.id) }
        let locked = Set(channel.map(\.id).filter { !usable.contains($0) })

        var global: [ChatEmote] = []
        var mine: [ChatEmote] = []
        var seen = channelIDs
        for u in user where seen.insert(u.emote.id).inserted {
            if u.isGlobal { global.append(u.emote) } else { mine.append(u.emote) }
        }

        let channelNames = Set(sevenTvChannel.map(\.name))
        return [
            TwitchEmoteSection(kind: .channelSevenTv, emotes: byName(sevenTvChannel)),
            TwitchEmoteSection(kind: .channelTwitch, emotes: channel, locked: locked),
            TwitchEmoteSection(kind: .yourTwitch, emotes: byName(mine)),
            TwitchEmoteSection(kind: .twitchGlobal, emotes: global),
            TwitchEmoteSection(kind: .sevenTvGlobal, emotes: byName(sevenTvGlobal.filter { !channelNames.contains($0.name) })),
        ]
    }

    /// Up to `limit` emotes whose name starts with `prefix` (case-insensitive), exact matches first, then names holding it.
    public func completions(for prefix: String, limit: Int = 8) -> [ChatEmote] {
        guard prefix.count >= 2 else { return [] }
        let p = prefix.lowercased()
        var exact: [ChatEmote] = []
        var starts: [ChatEmote] = []
        var seen = Set<String>()
        for e in emotes {
            let n = e.lowercasedName
            guard n.hasPrefix(p), seen.insert(e.name).inserted else { continue }
            if n == p { exact.append(e) } else { starts.append(e) }
            if exact.count + starts.count >= limit * 3 { break }
        }
        // then names with the letters anywhere ("cat" finds "catJAM" first, then "PETTHECAT")
        var inside: [ChatEmote] = []
        if exact.count + starts.count < limit {
            for e in emotes where inside.count < limit && !seen.contains(e.name) && e.lowercasedName.contains(p) {
                seen.insert(e.name)
                inside.append(e)
            }
        }
        return Array((exact + starts + inside).prefix(limit))
    }
}

/// One group in the emote picker (70.6).
public struct TwitchEmoteSection: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// The channel's 7TV set.
        case channelSevenTv
        /// The channel's own Twitch emotes (subscriber, follower, bits).
        case channelTwitch
        /// Twitch emotes from the user's other subscriptions.
        case yourTwitch
        case twitchGlobal
        case sevenTvGlobal
    }

    public var kind: Kind
    public var emotes: [ChatEmote]
    /// Ids the user can't send here (the channel's sub emotes without the sub): drawn dimmed with a lock.
    public var locked: Set<String>
    public var id: String { kind.rawValue }

    public init(kind: Kind, emotes: [ChatEmote], locked: Set<String> = []) {
        self.kind = kind
        self.emotes = emotes
        self.locked = locked
    }
}

/// A Twitch emote the signed-in user can send (Helix `chat/emotes/user`), with what Twitch says about it.
public struct TwitchUserEmote: Sendable, Hashable {
    public var emote: ChatEmote
    /// `globals`, `smilies`, `subscriptions`, `follower`, `bitstier`, …
    public var type: String?
    /// The broadcaster the emote belongs to ("0" or empty for Twitch's own).
    public var ownerID: String?

    public init(emote: ChatEmote, type: String?, ownerID: String?) {
        self.emote = emote
        self.type = type
        self.ownerID = ownerID
    }

    var isGlobal: Bool {
        type == "globals" || type == "smilies" || ownerID == "0" || ownerID == "twitch" || (ownerID ?? "").isEmpty
    }
}

// MARK: - splitting a message

public enum ChatFragmenter {
    /// Splits `text` into fragments: Twitch emotes at their ranges first, then each other word looked up in `named`
    /// (7TV, channel over global), `@mentions` and links. Zero-width emotes are stacked onto the emote before them.
    public static func fragments(
        text: String, ranges: [TwitchEmoteRange], named: [String: ChatEmote]
    ) -> [ChatFragment] {
        let scalars = Array(text.unicodeScalars)
        var out: [ChatFragment] = []
        var cursor = 0
        func push(_ emote: ChatEmote) {
            if emote.zeroWidth, let last = out.last {
                switch last {
                case .emote(let base):
                    out[out.count - 1] = .stack(base, [emote])
                    return
                case .stack(let base, let more):
                    out[out.count - 1] = .stack(base, more + [emote])
                    return
                default: break
                }
            }
            out.append(.emote(emote))
        }
        func append(word: String) {
            if let emote = named[word] {
                push(emote)
            } else if word.hasPrefix("@"), word.count > 1 {
                let name = word.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: ",.!?:;"))
                out.append(.mention(name))
            } else if word.lowercased().hasPrefix("http://") || word.lowercased().hasPrefix("https://"), let url = URL(string: word) {
                out.append(.link(url))
            } else if case .text(let prior)? = out.last {
                out[out.count - 1] = .text(prior + " " + word)
            } else {
                out.append(.text(word))
            }
        }
        func words(_ from: Int, _ to: Int) {
            guard from < to else { return }
            var s = String.UnicodeScalarView()
            s.append(contentsOf: scalars[from..<to])
            for word in String(s).split(separator: " ", omittingEmptySubsequences: true) {
                append(word: String(word))
            }
        }
        for r in ranges where r.start >= cursor && r.end < scalars.count {
            words(cursor, r.start)
            var s = String.UnicodeScalarView()
            s.append(contentsOf: scalars[r.start...r.end])
            push(.twitch(id: r.id, name: String(s)))
            cursor = r.end + 1
        }
        words(cursor, scalars.count)
        return out
    }

    /// True when `text` names `login` as a word (`@login` or `login`), case-insensitive.
    public static func mentions(_ text: String, login: String) -> Bool {
        guard !login.isEmpty else { return false }
        let me = login.lowercased()
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) where word == me {
            return true
        }
        return false
    }
}

extension ChatEmote {
    /// A 7TV emote from chat as the 7tv tab's emote (for "add to a 7tv set…"); nil for Twitch/Kick/YouTube native emotes.
    public var asHit: EmoteHit? {
        guard source == .sevenTv || source == .sevenTvGlobal else { return nil }
        let big = URL(string: url.absoluteString.replacingOccurrences(of: "/2x.", with: "/4x.")) ?? url
        return EmoteHit(id: id, name: name, animated: animated, previewURL: url, fileURL: big, libraryID: nil, libraryURL: nil)
    }
}

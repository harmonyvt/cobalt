import Foundation

// The values the twitch tab draws (APP-API-CONTRACT 70). Built off main by `TwitchChatEngine`; immutable, Sendable,
// Equatable (apple/ARCHITECTURE.md rule 2). Nothing here is stored: chat lives only while the tab is open.

/// An emote as chat draws it: a Twitch emote from the message's own `emotes` tag, or a 7TV emote matched by name.
public struct ChatEmote: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable { case twitch, sevenTv, sevenTvGlobal }

    /// Twitch's or 7TV's emote id.
    public var id: String
    public var name: String
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

    public init(id: String, title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// A 7TV paint: the gradient (or plain colour) a supporter's name is drawn in.
public struct SevenTvPaint: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case linear, radial, plain }

    public struct Stop: Sendable, Hashable {
        /// 0...1 along the gradient.
        public var at: Double
        /// 0xRRGGBBAA.
        public var rgba: UInt32
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Degrees, CSS style (0 points up, 90 right).
    public var angle: Double
    public var stops: [Stop]
    /// A plain paint's colour (0xRRGGBBAA), or the first stop's.
    public var color: UInt32?
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

    /// Twitch's message id (`id` tag), or a local one.
    public var id: String
    public var kind: Kind
    public var login: String
    public var displayName: String
    /// 0xRRGGBB, nil when the user never picked one (the view picks a steady colour from the name).
    public var color: UInt32?
    public var badges: [ChatBadge]
    public var fragments: [ChatFragment]
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
    }

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
                let n = e.name.lowercased()
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
        let byName: ([ChatEmote]) -> [ChatEmote] = { $0.sorted { $0.name.lowercased() < $1.name.lowercased() } }
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

    /// Up to `limit` emotes whose name starts with `prefix` (case-insensitive), exact matches first.
    public func completions(for prefix: String, limit: Int = 8) -> [ChatEmote] {
        guard prefix.count >= 2 else { return [] }
        let p = prefix.lowercased()
        var exact: [ChatEmote] = []
        var starts: [ChatEmote] = []
        var seen = Set<String>()
        for e in emotes {
            let n = e.name.lowercased()
            guard n.hasPrefix(p), seen.insert(e.name).inserted else { continue }
            if n == p { exact.append(e) } else { starts.append(e) }
            if exact.count + starts.count >= limit * 3 { break }
        }
        return Array((exact + starts).prefix(limit))
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
    /// A 7TV emote from chat as the 7tv tab's emote (for "add to a 7tv set…"); nil for a Twitch emote.
    public var asHit: EmoteHit? {
        guard source != .twitch else { return nil }
        let big = URL(string: url.absoluteString.replacingOccurrences(of: "/2x.", with: "/4x.")) ?? url
        return EmoteHit(id: id, name: name, animated: animated, previewURL: url, fileURL: big, libraryID: nil, libraryURL: nil)
    }
}

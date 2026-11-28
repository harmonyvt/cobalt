import Foundation

// The screen pane (apple/CONTRACT-PANE.md section 2): one panel per window, on the leading side, that shows one item
// beside whatever tab is open. These are its pure, platform-free pieces; the views live in `apple/Cobalt/Pane/`.

/// What the pane is doing.
public enum PaneState: String, Codable, Sendable, CaseIterable {
    /// Not on screen (the tab has the whole window).
    case hidden
    /// Beside the tab: the left screen of a Duo, a column on an iPad or a Mac, a sheet on one narrow screen.
    case screen
    /// The whole window: media on one screen and details on the other (a cover on one narrow screen).
    case span
    /// A running item closed to a bar over the tab (above the tab bar).
    case bar
}

/// A Twitch channel login (lowercased).
public typealias TwitchChannel = String

/// What the pane shows. One at a time per window.
public enum PaneItem: Hashable, Codable, Sendable {
    /// A media item id (library, home, a link's file, a chat result).
    case post(String)
    /// The library's hold-to-peek: the post's page, opened for as long as the finger is down (`PaneMachine.endPeek`).
    case peek(String)
    /// The library's select actions page (the picks live in the library's controller).
    case selection
    /// A save run (a job id) while it runs, then its result.
    case save(String)
    /// A share link (`ShareSet`) id.
    case link(String)
    /// A collection id.
    case collection(String)
    /// A 7TV emote id.
    case emote(String)
    /// The 7TV add-to-set flow for an emote id.
    case emoteAddToSet(String)
    /// A studio channel-point reward id.
    case reward(String)
    /// A studio pool video id.
    case poolVideo(String)
    /// Maximum simultaneous Twitch streams supported in a single pane.
    public static let maxSimultaneousStreams = 4

    /// A Twitch channel login.
    case stream(TwitchChannel)
    /// Two simultaneous Twitch streams (primary + secondary channel logins).
    case dualStream(primary: TwitchChannel, secondary: TwitchChannel)
    /// Three or four simultaneous Twitch streams (ordered, distinct channel logins).
    case multiStream(channels: [TwitchChannel])
    /// A booru post id.
    case booruPost(Int)
    /// The booru filters page.
    case booruFilters
    /// A swarm id (and its board).
    case swarm(String)
    /// A search name id.
    case name(String)
    /// A queue job id.
    case job(String)

    /// The kinds that can still be running when the pane closes (a stream playing, a save or a job in flight, a swarm
    /// at work, the studio on air), so closing them leaves a bar instead of hiding them. Whether one *is* running is
    /// runtime state its page reports (`Pane.setRunning`); this only says the kind can.
    public var keepsRunning: Bool {
        switch self {
        case .stream, .dualStream, .multiStream, .save, .swarm, .job, .reward, .poolVideo: true
        default: false
        }
    }

    /// Who keeps the one bar when two running items want it (`PaneMachine`): a stream stops without its page, so it
    /// outranks the rest (a job, a save, a swarm or the studio keep running wherever they run; only their bar goes).
    public var barRank: Int {
        switch self {
        case .stream, .dualStream, .multiStream: 1
        default: 0
        }
    }

    /// The item's kind, a stable short word: the saved route's key, analytics (never ids), placeholders.
    public var kind: String {
        switch self {
        case .post: "post"
        case .peek: "peek"
        case .selection: "selection"
        case .save: "save"
        case .link: "link"
        case .collection: "collection"
        case .emote: "emote"
        case .emoteAddToSet: "emoteAddToSet"
        case .reward: "reward"
        case .poolVideo: "poolVideo"
        case .stream: "stream"
        case .dualStream: "dualStream"
        case .multiStream: "multiStream"
        case .booruPost: "booruPost"
        case .booruFilters: "booruFilters"
        case .swarm: "swarm"
        case .name: "name"
        case .job: "job"
        }
    }

    /// True for the transient hold-to-peek item.
    public var isPeek: Bool { if case .peek = self { true } else { false } }

    /// True for single, dual, or multi Twitch stream items.
    public var isStream: Bool {
        switch self {
        case .stream, .dualStream, .multiStream: true
        default: false
        }
    }

    /// Ordered active Twitch channel logins held by this pane item (empty for non-stream items).
    public var streamChannels: [TwitchChannel] {
        switch self {
        case .stream(let login): [login]
        case .dualStream(let primary, let secondary): [primary, secondary]
        case .multiStream(let channels): channels
        default: []
        }
    }

    /// Builds the canonical stream `PaneItem` for 1...4 distinct channels:
    /// 1 -> `.stream`, 2 -> `.dualStream`, 3...4 -> `.multiStream`.
    public static func streams(_ rawChannels: [TwitchChannel]) -> PaneItem? {
        var normalized: [TwitchChannel] = []
        for raw in rawChannels {
            let clean = StreamAddress.canonicalKey(for: raw)
            guard !clean.isEmpty, !normalized.contains(clean) else { continue }
            normalized.append(clean)
            if normalized.count == maxSimultaneousStreams { break }
        }
        switch normalized.count {
        case 0: return nil
        case 1: return .stream(normalized[0])
        case 2: return .dualStream(primary: normalized[0], secondary: normalized[1])
        default: return .multiStream(channels: normalized)
        }
    }

    /// Promotes a single `.stream` item into `.dualStream` (or replaces secondary if already dual).
    /// Returns `nil` when `self` is not a stream or `secondary` matches the primary channel.
    public func promotedToDual(secondary rawSecondary: TwitchChannel) -> PaneItem? {
        let sec = StreamAddress.canonicalKey(for: rawSecondary)
        guard !sec.isEmpty else { return nil }
        switch self {
        case .stream(let primary):
            let pri = StreamAddress.canonicalKey(for: primary)
            guard pri != sec else { return nil }
            return .dualStream(primary: pri, secondary: sec)
        case .dualStream(let primary, _):
            let pri = StreamAddress.canonicalKey(for: primary)
            guard pri != sec else { return nil }
            return .dualStream(primary: pri, secondary: sec)
        default:
            return nil
        }
    }

    /// Appends a unique stream up to `maxSimultaneousStreams` (1 -> 2 -> 3 -> 4).
    /// Returns `nil` when `self` is not a stream, `rawChannel` is empty/already active, or already at the 4-stream cap.
    public func addingStream(_ rawChannel: TwitchChannel) -> PaneItem? {
        guard isStream else { return nil }
        let clean = StreamAddress.canonicalKey(for: rawChannel)
        guard !clean.isEmpty else { return nil }
        let current = streamChannels.map(StreamAddress.canonicalKey(for:))
        guard current.count < Self.maxSimultaneousStreams, !current.contains(clean) else { return nil }
        return Self.streams(current + [clean])
    }

    /// Removes a stream from a dual/multi-stream item, demoting 4 -> 3 -> 2 -> 1 (or `nil` if not found / last stream).
    public func removingStream(_ rawChannel: TwitchChannel) -> PaneItem? {
        guard isStream else { return nil }
        let clean = StreamAddress.canonicalKey(for: rawChannel)
        let current = streamChannels.map(StreamAddress.canonicalKey(for:))
        guard current.contains(clean) else { return nil }
        let remaining = current.filter { $0 != clean }
        return Self.streams(remaining)
    }

    /// Replaces the channel at `index` with a distinct `rawChannel`, preserving slot order.
    public func replacingStream(at index: Int, with rawChannel: TwitchChannel) -> PaneItem? {
        guard isStream else { return nil }
        let clean = StreamAddress.canonicalKey(for: rawChannel)
        guard !clean.isEmpty else { return nil }
        var current = streamChannels.map(StreamAddress.canonicalKey(for:))
        guard current.indices.contains(index) else { return nil }
        if current[index] == clean { return nil }
        guard !current.contains(clean) else { return nil }
        current[index] = clean
        return Self.streams(current)
    }

    /// Demotes a `.dualStream` or `.multiStream` item down to a single `.stream(keeping)`.
    public func demotedToSingle(keeping rawChannel: TwitchChannel) -> PaneItem? {
        let current = streamChannels.map(StreamAddress.canonicalKey(for:))
        guard current.count >= 2 else { return nil }
        let keep = StreamAddress.canonicalKey(for: rawChannel)
        guard current.contains(keep) else { return nil }
        return .stream(keep)
    }

    // MARK: coding

    // `{"kind":"post","id":"abc"}`, `{"kind":"dualStream","id":"a","secondary":"b"}`,
    // `{"kind":"multiStream","channels":["a","b","c"]}`, `{"kind":"booruPost","n":7}`, `{"kind":"selection"}`:
    // flat and readable, so a saved route from an older build decodes or fails cleanly (an unknown kind throws;
    // `PaneRoute` then drops it).
    private enum CodingKeys: String, CodingKey { case kind, id, secondary, channels, n }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        func id() throws -> String { try c.decode(String.self, forKey: .id) }
        switch kind {
        case "post": self = .post(try id())
        case "peek": self = .peek(try id())
        case "selection": self = .selection
        case "save": self = .save(try id())
        case "link": self = .link(try id())
        case "collection": self = .collection(try id())
        case "emote": self = .emote(try id())
        case "emoteAddToSet": self = .emoteAddToSet(try id())
        case "reward": self = .reward(try id())
        case "poolVideo": self = .poolVideo(try id())
        case "stream": self = .stream(try id())
        case "dualStream":
            let primary = try id()
            let secondary = try c.decode(String.self, forKey: .secondary)
            guard !primary.isEmpty, !secondary.isEmpty, primary.lowercased() != secondary.lowercased() else {
                throw DecodingError.dataCorruptedError(forKey: .secondary, in: c, debugDescription: "invalid dualStream pair")
            }
            self = .dualStream(primary: primary, secondary: secondary)
        case "multiStream":
            let raw = try c.decode([String].self, forKey: .channels)
            let cleaned = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let uniqueCount = Set(cleaned.filter { !$0.isEmpty }).count
            guard cleaned.count >= 2,
                  cleaned.count <= Self.maxSimultaneousStreams,
                  uniqueCount == cleaned.count
            else {
                throw DecodingError.dataCorruptedError(forKey: .channels, in: c, debugDescription: "invalid multiStream channels")
            }
            if cleaned.count == 2 {
                self = .dualStream(primary: cleaned[0], secondary: cleaned[1])
            } else {
                self = .multiStream(channels: cleaned)
            }
        case "booruPost": self = .booruPost(try c.decode(Int.self, forKey: .n))
        case "booruFilters": self = .booruFilters
        case "swarm": self = .swarm(try id())
        case "name": self = .name(try id())
        case "job": self = .job(try id())
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown pane item kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .post(let s), .peek(let s), .save(let s), .link(let s), .collection(let s), .emote(let s),
             .emoteAddToSet(let s), .reward(let s), .poolVideo(let s), .stream(let s), .swarm(let s), .name(let s),
             .job(let s):
            try c.encode(s, forKey: .id)
        case .dualStream(let primary, let secondary):
            try c.encode(primary, forKey: .id)
            try c.encode(secondary, forKey: .secondary)
        case .multiStream(let channels):
            try c.encode(channels, forKey: .channels)
        case .booruPost(let n):
            try c.encode(n, forKey: .n)
        case .selection, .booruFilters:
            break
        }
    }
}

/// What is saved per scene (`@SceneStorage("pane")`) and restored on relaunch.
public struct PaneRoute: Codable, Equatable, Sendable {
    /// The item shown, or the last one shown while `hidden` (a drag held on the leading edge reopens it).
    public var item: PaneItem?
    public var state: PaneState
    /// The shelf card on show (0 = the first).
    public var shelf: Int

    public init(item: PaneItem? = nil, state: PaneState = .hidden, shelf: Int = 0) {
        self.item = item
        self.state = state
        self.shelf = max(0, shelf)
    }

    /// Nothing open.
    public static let hidden = PaneRoute()

    /// True while the pane takes room on screen or in a sheet (`screen` or `span`).
    public var isVisible: Bool { item != nil && (state == .screen || state == .span) }

    /// The route as it may be restored: a peek is never restored (it only lasts while a finger is down), and a state
    /// with no item is `hidden`.
    public var restorable: PaneRoute {
        guard let item, !item.isPeek else { return PaneRoute(item: nil, state: .hidden, shelf: 0) }
        return PaneRoute(item: item, state: state, shelf: shelf)
    }

    private enum CodingKeys: String, CodingKey { case item, state, shelf }

    // Forgiving: an item or a state this build does not know decodes as nothing open rather than failing the scene.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let item = try? c.decodeIfPresent(PaneItem.self, forKey: .item)
        let state = (try? c.decodeIfPresent(PaneState.self, forKey: .state)) ?? .hidden
        let shelf = (try? c.decodeIfPresent(Int.self, forKey: .shelf)) ?? 0
        self = PaneRoute(item: item, state: item == nil ? .hidden : state, shelf: shelf)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(item, forKey: .item)
        try c.encode(state, forKey: .state)
        try c.encode(shelf, forKey: .shelf)
    }

    /// The saved form (JSON), for `@SceneStorage`.
    public func encoded() -> Data? { try? JSONEncoder().encode(restorable) }

    /// A saved route, or nil when there is none or it does not decode.
    public static func decoded(_ data: Data?) -> PaneRoute? {
        guard let data, let route = try? JSONDecoder().decode(PaneRoute.self, from: data) else { return nil }
        return route.restorable
    }
}

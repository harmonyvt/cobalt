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
    /// A Twitch channel login.
    case stream(String)
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
        case .stream, .save, .swarm, .job, .reward, .poolVideo: true
        default: false
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
        case .booruPost: "booruPost"
        case .booruFilters: "booruFilters"
        case .swarm: "swarm"
        case .name: "name"
        case .job: "job"
        }
    }

    /// True for the transient hold-to-peek item.
    public var isPeek: Bool { if case .peek = self { true } else { false } }

    // MARK: coding

    // `{"kind":"post","id":"abc"}`, `{"kind":"booruPost","n":7}`, `{"kind":"selection"}`: flat and readable, so a
    // saved route from an older build decodes or fails cleanly (an unknown kind throws; `PaneRoute` then drops it).
    private enum CodingKeys: String, CodingKey { case kind, id, n }

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

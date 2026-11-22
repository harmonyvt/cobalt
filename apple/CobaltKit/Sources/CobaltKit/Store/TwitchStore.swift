import Foundation
import Observation

/// The twitch tab (APP-API-CONTRACT 70): who chat signs in as, the followed channels that are live, and the one channel
/// being watched, with its live chat. The engines (`TwitchChatEngine`, `TwitchDirectory`) do the network and JSON off
/// main; this model only assigns what changed (apple/ARCHITECTURE.md rules 1 and 2). Nothing of chat is kept: closing a
/// channel drops it. The last few channels opened are remembered by name only.
@MainActor @Observable
public final class TwitchStore {
    public enum ClipState: Equatable, Sendable {
        case idle
        case making
        /// The clip is saving to the library (its link went to the queue).
        case saved
        case failed
    }

    public private(set) var session: TwitchSession?
    /// `GET /stage/twitch/session` has answered (or failed) once.
    public private(set) var sessionLoaded = false
    public private(set) var following: [TwitchStreamInfo] = []
    public private(set) var followingLoaded = false
    /// The channel open now (lowercased login), nil on the list.
    public private(set) var channel: String?
    public private(set) var channelInfo: TwitchChannelInfo?
    /// Its stream while it is live.
    public private(set) var stream: TwitchStreamInfo?
    public private(set) var chat: TwitchChatSnapshot?
    public private(set) var emotes = TwitchEmoteList()
    /// Emotes picked in the emote picker (70.6), newest first. Memory only, like the rest of chat.
    public private(set) var recentEmotes: [ChatEmote] = []
    static let recentEmotesMax = 24
    /// The message the composer answers (a long press › reply).
    public var replyTo: TwitchChatLine?
    public private(set) var clipState: ClipState = .idle
    /// Channels opened before, newest first (names only).
    public private(set) var recents: [String] = []

    /// Chat can send: signed in with the chat scopes and joined.
    public var canSend: Bool { chat?.canSend == true }
    /// Signed in, but the studio's connection predates the chat scopes: connect twitch again in studio.
    public var needsChatScopes: Bool { session?.connected == true && session?.reconnect != true && session?.canChat != true }
    public var needsReconnect: Bool { session?.reconnect == true }
    public var canClip: Bool { session?.canClip == true && stream != nil }

    @ObservationIgnored private let ctx: PipelineContext
    @ObservationIgnored private var engine: TwitchChatEngine?
    @ObservationIgnored private var listen: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var emotesVersion = -1
    /// When `GET /stage/twitch/session` was last asked, so a session that cannot chat yet is asked again (after a
    /// reconnect in studio) without asking on every appearance.
    @ObservationIgnored var sessionFetchedAt: Date?  // internal: tests age it past `recheckAfter`
    /// The open channel's chat signed in with chat scopes (false: read-only or anonymous).
    @ObservationIgnored private var engineCanChat = false
    static let recheckAfter: TimeInterval = 15

    static let recentsKey = "twitchRecentChannels"
    static let recentsMax = 8

    init(context: PipelineContext) {
        self.ctx = context
        self.recents = context.settings.defaults.stringArray(forKey: Self.recentsKey) ?? []
    }

    /// Reads the session (when it is missing, near its end, or cannot chat yet) and the followed live channels. A
    /// session that gained chat (Twitch reconnected in studio) rejoins the open channel's chat signed in. `force`
    /// asks the server even when the last answer is recent (pull to refresh).
    public func load(force: Bool = false) async {
        await refreshSessionIfNeeded(force: force)
        await loadFollowing()
        rejoinIfChatGained()
    }

    public func loadFollowing() async {
        guard let creds = session?.credentials else {
            followingLoaded = true
            return
        }
        let gen = generation
        let live = await TwitchDirectory(credentials: creds).followedLive()
        guard gen == generation else { return }
        if live != following { following = live }
        followingLoaded = true
    }

    private func refreshSessionIfNeeded(force: Bool = false) async {
        if !force {
            // a session that can chat is kept until near its end; anything else (read-only, not connected, needs a
            // reconnect) is asked again once the last answer is a few seconds old, so a reconnect shows up
            if let s = session, s.connected, s.canChat == true, s.reconnect != true, let end = s.expiresAt,
               end.timeIntervalSinceNow > 10 * 60 { return }
            if let at = sessionFetchedAt, Date().timeIntervalSince(at) < Self.recheckAfter { return }
        }
        sessionFetchedAt = Date()
        let gen = generation
        let fresh: TwitchSession?
        if let client = ctx.client as? any TwitchSessionClient {
            fresh = try? await client.twitchSession()
        } else {
            fresh = nil
        }
        guard gen == generation else { return }
        if fresh != session { session = fresh }
        sessionLoaded = true
    }

    /// The open channel's chat was joined without chat scopes and the session has them now: join again, signed in.
    private func rejoinIfChatGained() {
        guard let login = channel, engine != nil, !engineCanChat, session?.credentials?.canChat == true else { return }
        close()
        open(login)
    }

    /// Opens `name` (a login, or a twitch.tv link): its stream and its chat.
    public func open(_ name: String) {
        guard let login = Self.login(from: name) else { return }
        if channel == login, engine != nil, engineCanChat || session?.credentials?.canChat != true { return }
        close()
        channel = login
        remember(login)
        let gen = generation
        Task {
            await refreshSessionIfNeeded()
            guard gen == generation, channel == login else { return }
            let creds = session?.credentials
            let engine = TwitchChatEngine(channel: login, credentials: creds)
            self.engine = engine
            engineCanChat = creds?.canChat == true
            listen = Task { [weak self] in
                for await snap in engine.snapshots {
                    guard let self, gen == self.generation else { return }
                    if snap != self.chat { self.chat = snap }
                    if snap.emotesVersion != self.emotesVersion {
                        self.emotesVersion = snap.emotesVersion
                        let list = await engine.emotes()
                        if list != self.emotes { self.emotes = list }
                    }
                }
            }
            await engine.start()
            if let creds {
                let dir = TwitchDirectory(credentials: creds)
                async let info = dir.channel(login: login)
                async let live = dir.stream(login: login)
                let (i, l) = await (info, live)
                guard gen == generation else { return }
                channelInfo = i
                stream = l
            }
        }
    }

    /// Back to the list: the chat connection closes and its lines are gone.
    public func close() {
        generation += 1
        listen?.cancel()
        listen = nil
        if let engine { Task { await engine.stop() } }
        engine = nil
        engineCanChat = false
        channel = nil
        channelInfo = nil
        stream = nil
        chat = nil
        emotes = TwitchEmoteList()
        emotesVersion = -1
        replyTo = nil
        clipState = .idle
    }

    /// The picker put `emote` in the composer: it moves to the front of `recentEmotes`.
    public func noteEmotePicked(_ emote: ChatEmote) {
        var list = recentEmotes.filter { $0.id != emote.id }
        list.insert(emote, at: 0)
        if list.count > Self.recentEmotesMax { list.removeLast(list.count - Self.recentEmotesMax) }
        recentEmotes = list
    }

    /// `recentEmotes` that this channel still offers and the user can send here.
    public var recentEmotesHere: [ChatEmote] {
        guard !recentEmotes.isEmpty else { return [] }
        var usable = Set<String>()
        for section in emotes.sections {
            for e in section.emotes where !section.locked.contains(e.id) { usable.insert(e.id) }
        }
        return recentEmotes.filter { usable.contains($0.id) }
    }

    /// Sends a message (answering `replyTo` when set). False when chat is read-only or the send failed.
    @discardableResult
    public func send(_ text: String) async -> Bool {
        guard let engine else { return false }
        let ok = await engine.send(text, replyTo: replyTo?.id.hasPrefix("local-") == true ? nil : replyTo?.id)
        if ok { replyTo = nil }
        return ok
    }

    /// Clips the last seconds of the live stream and hands the clip's link to `save` (the queue).
    public func clip(save: @MainActor (URL) -> Void) async {
        guard let creds = session?.credentials, let id = stream?.userID ?? channelInfo?.id, clipState != .making else { return }
        clipState = .making
        let gen = generation
        let url = await TwitchDirectory(credentials: creds).makeClip(broadcasterID: id)
        guard gen == generation else { return }
        if let url {
            save(url)
            clipState = .saved
        } else {
            clipState = .failed
        }
    }

    public func acknowledgeClip() { clipState = .idle }

    func reset() {
        close()
        session = nil
        sessionLoaded = false
        following = []
        followingLoaded = false
    }

    private func remember(_ login: String) {
        var list = recents.filter { $0 != login }
        list.insert(login, at: 0)
        if list.count > Self.recentsMax { list.removeLast(list.count - Self.recentsMax) }
        recents = list
        ctx.settings.defaults.set(list, forKey: Self.recentsKey)
    }

    /// `name`, `@name`, `twitch.tv/name` or a full link → `name`; nil when it is not a Twitch login.
    public nonisolated static func login(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: s.hasPrefix("http") ? s : "https://\(s)"), let host = url.host, host.hasSuffix("twitch.tv") {
            s = url.pathComponents.dropFirst().first ?? ""
        }
        if s.hasPrefix("@") { s.removeFirst() }
        guard (3...25).contains(s.count), s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return s
    }
}

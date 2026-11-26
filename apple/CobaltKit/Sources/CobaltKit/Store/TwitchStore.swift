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
    /// The primary channel open now (lowercased login), nil on the list.
    public private(set) var channel: String?
    public private(set) var channelInfo: TwitchChannelInfo?
    /// Its stream while it is live.
    public private(set) var stream: TwitchStreamInfo?
    /// The secondary channel open in dual-stream mode (lowercased login), nil in single-stream mode.
    public private(set) var secondaryChannel: String?
    public private(set) var secondaryChannelInfo: TwitchChannelInfo?
    /// The secondary stream while it is live.
    public private(set) var secondaryStream: TwitchStreamInfo?
    /// True when two distinct streams are open side-by-side.
    public var isDualStream: Bool { channel != nil && secondaryChannel != nil }
    /// Ordered open channel logins (1 in single mode, 2 in dual mode).
    public var activeChannels: [String] { [channel, secondaryChannel].compactMap { $0 } }
    /// Dual-stream combined chat coordinator (manages both chat sockets, accents, filters, and foolproof composer locking).
    public let combinedChat = TwitchCombinedChatModel()
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
    public var canSend: Bool { isDualStream ? combinedChat.canSendAny : (chat?.canSend == true) }
    /// Signed in, but the studio's connection predates the chat scopes: connect twitch again in studio.
    public var needsChatScopes: Bool { session?.connected == true && session?.reconnect != true && session?.canChat != true }
    public var needsReconnect: Bool { session?.reconnect == true }
    public var canClip: Bool { session?.canClip == true && (stream != nil || secondaryStream != nil) }

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
        guard !engineCanChat, session?.credentials?.canChat == true else { return }
        if let primary = channel, let secondary = secondaryChannel {
            let focused = combinedChat.focusedChannel
            combinedChat.stop()
            openDual(primary: primary, secondary: secondary, focusedChannel: focused)
            return
        }
        guard let login = channel, engine != nil else { return }
        close()
        open(login)
    }

    /// Opens `name` (a login, or a twitch.tv link): its stream and its chat.
    public func open(_ name: String) {
        guard let login = Self.login(from: name) else { return }
        if channel == login, secondaryChannel == nil, engine != nil, engineCanChat || session?.credentials?.canChat != true { return }
        // Preserve already-fetched metadata if demoting from dual-stream to one of the active channels.
        let preservedInfo: TwitchChannelInfo? = (channel == login) ? channelInfo : ((secondaryChannel == login) ? secondaryChannelInfo : nil)
        let preservedStream: TwitchStreamInfo? = (channel == login) ? stream : ((secondaryChannel == login) ? secondaryStream : nil)
        close()
        channel = login
        channelInfo = preservedInfo
        stream = preservedStream
        remember(login)
        let gen = generation
        Task {
            await refreshSessionIfNeeded()
            guard gen == generation, channel == login, secondaryChannel == nil else { return }
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

    /// Opens two simultaneous Twitch streams and wires `combinedChat` for both channels.
    /// Keeps any already-fetched channel/stream metadata intact on 1 -> 2 promotion to avoid flicker.
    public func openDual(primary rawPrimary: String, secondary rawSecondary: String, focusedChannel rawFocused: String? = nil) {
        guard let primary = Self.login(from: rawPrimary), let secondary = Self.login(from: rawSecondary) else { return }
        if primary == secondary {
            open(primary)
            return
        }
        let alreadyMatching = (channel == primary && secondaryChannel == secondary && combinedChat.channels == [primary, secondary])
        if alreadyMatching, engineCanChat || session?.credentials?.canChat != true {
            if let rawFocused { combinedChat.setFocusedChannel(rawFocused) }
            return
        }

        // Preserve any known metadata across 1 -> 2 promotion or slot reordering.
        let knownInfo: [String: TwitchChannelInfo] = [
            channel: channelInfo,
            secondaryChannel: secondaryChannelInfo,
        ].reduce(into: [:]) { acc, pair in
            if let k = pair.key, let v = pair.value { acc[k] = v }
        }
        let knownStream: [String: TwitchStreamInfo] = [
            channel: stream,
            secondaryChannel: secondaryStream,
        ].reduce(into: [:]) { acc, pair in
            if let k = pair.key, let v = pair.value { acc[k] = v }
        }

        // Tear down standalone single-stream chat engine so we never run 3 chat sockets.
        generation += 1
        listen?.cancel()
        listen = nil
        if let singleEngine = engine { Task { await singleEngine.stop() } }
        engine = nil
        chat = nil
        emotes = TwitchEmoteList()
        emotesVersion = -1
        replyTo = nil
        clipState = .idle

        channel = primary
        secondaryChannel = secondary
        channelInfo = knownInfo[primary]
        stream = knownStream[primary] ?? following.first(where: { $0.login.lowercased() == primary })
        secondaryChannelInfo = knownInfo[secondary]
        secondaryStream = knownStream[secondary] ?? following.first(where: { $0.login.lowercased() == secondary })

        remember(secondary)
        remember(primary)

        let gen = generation
        let focused = rawFocused?.lowercased() ?? primary
        let initialNames = displayNamesMap(for: [primary, secondary])
        if session != nil {
            let creds = session?.credentials
            engineCanChat = creds?.canChat == true
            combinedChat.configure(
                channels: [primary, secondary],
                displayNames: initialNames,
                credentials: creds,
                focusedChannel: focused)
        } else {
            combinedChat.configureChannelsWithoutEngines(
                [primary, secondary],
                displayNames: initialNames,
                focusedChannel: focused)
        }

        Task {
            await refreshSessionIfNeeded()
            guard gen == generation, channel == primary, secondaryChannel == secondary else { return }
            let creds = session?.credentials
            engineCanChat = creds?.canChat == true
            combinedChat.configure(
                channels: [primary, secondary],
                displayNames: self.displayNamesMap(for: [primary, secondary]),
                credentials: creds,
                focusedChannel: self.combinedChat.focusedChannel ?? focused)
            if let creds {
                let dir = TwitchDirectory(credentials: creds)
                async let pInfo = dir.channel(login: primary)
                async let pLive = dir.stream(login: primary)
                async let sInfo = dir.channel(login: secondary)
                async let sLive = dir.stream(login: secondary)
                let (pi, pl, si, sl) = await (pInfo, pLive, sInfo, sLive)
                guard gen == generation, channel == primary, secondaryChannel == secondary else { return }
                channelInfo = pi ?? channelInfo
                stream = pl
                secondaryChannelInfo = si ?? secondaryChannelInfo
                secondaryStream = sl
                combinedChat.updateDisplayNames(self.displayNamesMap(for: [primary, secondary]))
            }
        }
    }

    /// Syncs visual/audio focus into `combinedChat` without disturbing any locked composer target.
    public func updateCombinedChatFocus(_ login: String?) {
        guard isDualStream else { return }
        combinedChat.setFocusedChannel(login)
    }

    /// Live stream info for `login` (checks primary, secondary, and followed live directory).
    public func streamInfo(for login: String) -> TwitchStreamInfo? {
        let lower = login.lowercased()
        if channel == lower, let stream { return stream }
        if secondaryChannel == lower, let secondaryStream { return secondaryStream }
        return following.first { $0.login.lowercased() == lower }
    }

    /// Channel profile info for `login`.
    public func channelInfo(for login: String) -> TwitchChannelInfo? {
        let lower = login.lowercased()
        if channel == lower { return channelInfo }
        if secondaryChannel == lower { return secondaryChannelInfo }
        return nil
    }

    /// Best display name for `login` (falling back to the login itself).
    public func displayName(for login: String) -> String {
        let lower = login.lowercased()
        if let name = streamInfo(for: lower)?.displayName, !name.isEmpty { return name }
        if let name = channelInfo(for: lower)?.displayName, !name.isEmpty { return name }
        return lower
    }

    private func displayNamesMap(for logins: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for login in logins {
            let lower = login.lowercased()
            map[lower] = displayName(for: lower)
        }
        return map
    }

    /// Back to the list: the chat connection closes and its lines are gone.
    public func close() {
        generation += 1
        listen?.cancel()
        listen = nil
        if let engine { Task { await engine.stop() } }
        engine = nil
        engineCanChat = false
        combinedChat.stop()
        channel = nil
        channelInfo = nil
        stream = nil
        secondaryChannel = nil
        secondaryChannelInfo = nil
        secondaryStream = nil
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

    /// Clips the last seconds of the live stream (or a specific channel in dual-stream mode) and hands the clip's link to `save`.
    public func clip(channel targetLogin: String? = nil, save: @MainActor (URL) -> Void) async {
        let login = targetLogin?.lowercased() ?? channel
        let broadcasterID: String?
        if let login {
            broadcasterID = streamInfo(for: login)?.userID ?? channelInfo(for: login)?.id
        } else {
            broadcasterID = stream?.userID ?? channelInfo?.id
        }
        guard let creds = session?.credentials, let id = broadcasterID, clipState != .making else { return }
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

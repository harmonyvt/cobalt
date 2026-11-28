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
    /// Ordered open channel logins (1 in single mode, 2...4 in dual/multi mode).
    public private(set) var activeChannels: [String] = []
    /// Channel profile metadata keyed by lowercased login for all active streams.
    public private(set) var channelInfos: [String: TwitchChannelInfo] = [:]
    /// Live stream metadata keyed by lowercased login for all active streams.
    public private(set) var streamInfos: [String: TwitchStreamInfo] = [:]

    /// The primary channel open now (lowercased login), nil on the list.
    public var channel: String? { activeChannels.first }
    public var channelInfo: TwitchChannelInfo? { channel.flatMap { channelInfos[$0] } }
    /// Its stream while it is live.
    public var stream: TwitchStreamInfo? { channel.flatMap { streamInfos[$0] } }
    /// The secondary channel open in dual/multi-stream mode (lowercased login), nil in single-stream mode.
    public var secondaryChannel: String? { activeChannels.count >= 2 ? activeChannels[1] : nil }
    public var secondaryChannelInfo: TwitchChannelInfo? { secondaryChannel.flatMap { channelInfos[$0] } }
    /// The secondary stream while it is live.
    public var secondaryStream: TwitchStreamInfo? { secondaryChannel.flatMap { streamInfos[$0] } }
    /// True when 2 or more distinct streams are open together.
    public var isDualStream: Bool { activeChannels.count >= 2 }
    /// Alias for `isDualStream` when 2...4 simultaneous streams are open.
    public var isMultiStream: Bool { activeChannels.count >= 2 }
    /// Number of currently open streams (`0...4`).
    public var streamCount: Int { activeChannels.count }
    /// Multi-stream combined chat coordinator (manages up to 4 chat sockets, accents, filters, and foolproof composer locking).
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

    /// Chat can send: signed in with the chat scopes and joined on a platform that supports sending.
    public var canSend: Bool { isDualStream ? combinedChat.canSendAny : (chat?.canSend == true) }
    /// Signed in, but the studio's connection predates the chat scopes: connect twitch again in studio.
    public var needsChatScopes: Bool { session?.connected == true && session?.reconnect != true && session?.canChat != true }
    public var needsReconnect: Bool { session?.reconnect == true }
    public var canClip: Bool {
        session?.canClip == true && activeChannels.contains(where: {
            StreamAddress.platform(for: $0).supportsServerClip && streamInfos[$0] != nil
        })
    }

    @ObservationIgnored private let ctx: PipelineContext
    @ObservationIgnored private var engine: (any LiveChatEngine)?
    @ObservationIgnored private var listen: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var emotesVersion = -1
    @ObservationIgnored private var lowPowerMode = false
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
        let conserve = AppLifecycle.shared.snapshot.shouldConservePower
        self.lowPowerMode = conserve
        self.combinedChat.setLowPowerMode(conserve)
        AppLifecycle.shared.register(self, order: .media)
    }

    /// Propagates power-conservation / Low Power Mode to active single or combined chat engines.
    public func setLowPowerMode(_ enabled: Bool) {
        guard lowPowerMode != enabled else { return }
        lowPowerMode = enabled
        combinedChat.setLowPowerMode(enabled)
        if let active = engine {
            Task { await active.setLowPowerMode(enabled) }
        }
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
        guard activeChannels.contains(where: { StreamAddress.platform(for: $0) == .twitch }) else { return }
        if activeChannels.count >= 2 {
            let channelsToReopen = activeChannels
            let focused = combinedChat.focusedChannel
            combinedChat.stop()
            openMulti(channels: channelsToReopen, focusedChannel: focused)
            return
        }
        guard let login = channel, engine != nil else { return }
        close()
        open(login)
    }

    /// Opens `name` (a Twitch login/URL, Kick slug/URL, or YouTube Live URL/handle): its stream and live chat.
    public func open(_ name: String) {
        guard let login = Self.login(from: name) else { return }
        let platform = StreamAddress.platform(for: login)
        let needsSessionUpgrade = platform == .twitch && !engineCanChat && session?.credentials?.canChat == true
        if activeChannels == [login], engine != nil, !needsSessionUpgrade { return }
        // Preserve already-fetched metadata if demoting from dual/multi-stream to one of the active channels.
        let preservedInfo = channelInfos[login]
        let preservedStream = streamInfos[login]
        close()
        activeChannels = [login]
        syncActiveStreamPresence()
        if let preservedInfo { channelInfos[login] = preservedInfo }
        if let preservedStream { streamInfos[login] = preservedStream }
        remember(login)
        let gen = generation
        let lpm = lowPowerMode
        Task {
            if platform == .twitch {
                await refreshSessionIfNeeded()
                guard gen == generation, activeChannels == [login] else { return }
            }
            let creds = platform == .twitch ? session?.credentials : nil
            let engine = LiveChatEngineFactory.make(channel: login, credentials: creds)
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
            if lpm { await engine.setLowPowerMode(true) }
            await engine.start()
            if platform == .twitch {
                if let creds {
                    let dir = TwitchDirectory(credentials: creds)
                    async let info = dir.channel(login: login)
                    async let live = dir.stream(login: login)
                    let (i, l) = await (info, live)
                    guard gen == generation, activeChannels == [login] else { return }
                    if let i { channelInfos[login] = i } else { channelInfos.removeValue(forKey: login) }
                    if let l { streamInfos[login] = l } else { streamInfos.removeValue(forKey: login) }
                }
            } else {
                if let meta = await ExternalLiveDirectory.fetchMetadata(for: login) {
                    guard gen == generation, activeChannels == [login] else { return }
                    channelInfos[login] = meta.asChannelInfo
                    if let live = meta.asStreamInfo {
                        streamInfos[login] = live
                    } else {
                        streamInfos.removeValue(forKey: login)
                    }
                }
            }
        }
    }

    /// Opens two simultaneous live streams (Twitch, Kick, or YouTube) and wires `combinedChat` for both channels.
    /// Keeps any already-fetched channel/stream metadata intact on 1 -> 2 promotion to avoid flicker.
    public func openDual(primary rawPrimary: String, secondary rawSecondary: String, focusedChannel rawFocused: String? = nil) {
        guard let primary = Self.login(from: rawPrimary), let secondary = Self.login(from: rawSecondary) else { return }
        openMulti(channels: [primary, secondary], focusedChannel: rawFocused)
    }

    /// Opens 1...4 simultaneous live streams (Twitch, Kick, or YouTube) and wires `combinedChat` for all active channels.
    /// Preserves already-fetched metadata and running chat sockets for channels that remain open across 1↔2↔3↔4 transitions.
    public func openMulti(channels rawChannels: [String], focusedChannel rawFocused: String? = nil) {
        var normalized: [String] = []
        for raw in rawChannels {
            guard let login = Self.login(from: raw), !normalized.contains(login) else { continue }
            normalized.append(login)
            if normalized.count == PaneItem.maxSimultaneousStreams { break }
        }
        guard !normalized.isEmpty else { return }
        if normalized.count == 1 {
            open(normalized[0])
            return
        }

        let hasTwitchChannel = normalized.contains { StreamAddress.platform(for: $0) == .twitch }
        let alreadyMatching = (activeChannels == normalized && combinedChat.channels == normalized)
        if alreadyMatching, (!hasTwitchChannel || engineCanChat || session?.credentials?.canChat != true) {
            if let rawFocused { combinedChat.setFocusedChannel(rawFocused) }
            return
        }

        // Preserve any known metadata across 1 -> 2 -> 3 -> 4 transitions or slot reordering.
        let knownInfo = channelInfos
        let knownStream = streamInfos

        // Tear down standalone single-stream chat engine so we never run duplicate chat sockets.
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

        activeChannels = normalized
        syncActiveStreamPresence()
        var nextChannelInfos: [String: TwitchChannelInfo] = [:]
        var nextStreamInfos: [String: TwitchStreamInfo] = [:]
        for login in normalized {
            if let info = knownInfo[login] { nextChannelInfos[login] = info }
            if let live = knownStream[login] ?? following.first(where: { StreamAddress.canonicalKey(for: $0.login) == login }) {
                nextStreamInfos[login] = live
            }
        }
        channelInfos = nextChannelInfos
        streamInfos = nextStreamInfos

        for login in normalized.reversed() {
            remember(login)
        }

        let gen = generation
        let focused = rawFocused.map(StreamAddress.canonicalKey(for:)) ?? normalized[0]
        let initialNames = displayNamesMap(for: normalized)
        combinedChat.setLowPowerMode(lowPowerMode)
        if session != nil || !hasTwitchChannel {
            let creds = session?.credentials
            engineCanChat = creds?.canChat == true
            combinedChat.configure(
                channels: normalized,
                displayNames: initialNames,
                credentials: creds,
                focusedChannel: focused)
        } else {
            combinedChat.configureChannelsWithoutEngines(
                normalized,
                displayNames: initialNames,
                focusedChannel: focused)
        }

        Task {
            if hasTwitchChannel {
                await refreshSessionIfNeeded()
                guard gen == generation, activeChannels == normalized else { return }
            }
            let creds = session?.credentials
            engineCanChat = creds?.canChat == true
            combinedChat.configure(
                channels: normalized,
                displayNames: self.displayNamesMap(for: normalized),
                credentials: creds,
                focusedChannel: self.combinedChat.focusedChannel ?? focused)

            let results = await withTaskGroup(
                of: (String, TwitchChannelInfo?, TwitchStreamInfo?).self,
                returning: [(String, TwitchChannelInfo?, TwitchStreamInfo?)].self
            ) { group in
                let dir = creds.map { TwitchDirectory(credentials: $0) }
                for login in normalized {
                    let platform = StreamAddress.platform(for: login)
                    group.addTask {
                        if platform == .twitch {
                            guard let dir else { return (login, nil, nil) }
                            async let info = dir.channel(login: login)
                            async let live = dir.stream(login: login)
                            return (login, await info, await live)
                        } else {
                            let meta = await ExternalLiveDirectory.fetchMetadata(for: login)
                            return (login, meta?.asChannelInfo, meta?.asStreamInfo)
                        }
                    }
                }
                var collected: [(String, TwitchChannelInfo?, TwitchStreamInfo?)] = []
                for await item in group {
                    collected.append(item)
                }
                return collected
            }
            guard gen == generation, activeChannels == normalized else { return }
            for (login, info, live) in results {
                if let info { channelInfos[login] = info }
                if let live { streamInfos[login] = live } else if StreamAddress.platform(for: login) == .twitch || info != nil {
                    streamInfos.removeValue(forKey: login)
                }
            }
            combinedChat.updateDisplayNames(self.displayNamesMap(for: normalized))
        }
    }

    /// Syncs visual/audio focus into `combinedChat` without disturbing any locked composer target.
    public func updateCombinedChatFocus(_ login: String?) {
        guard isDualStream else { return }
        combinedChat.setFocusedChannel(login)
    }

    /// Live stream info for `login` (checks active streams and followed live directory).
    public func streamInfo(for login: String) -> TwitchStreamInfo? {
        let key = StreamAddress.canonicalKey(for: login)
        if let live = streamInfos[key] { return live }
        return following.first { StreamAddress.canonicalKey(for: $0.login) == key }
    }

    /// Channel profile info for `login`.
    public func channelInfo(for login: String) -> TwitchChannelInfo? {
        channelInfos[StreamAddress.canonicalKey(for: login)]
    }

    /// Best display name for `login` (falling back to the platform-free display label).
    public func displayName(for login: String) -> String {
        let key = StreamAddress.canonicalKey(for: login)
        if let name = streamInfo(for: key)?.displayName, !name.isEmpty { return name }
        if let name = channelInfo(for: key)?.displayName, !name.isEmpty { return name }
        return StreamAddress.displayLabel(for: key)
    }

    private func displayNamesMap(for logins: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for login in logins {
            let key = StreamAddress.canonicalKey(for: login)
            map[key] = displayName(for: key)
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
        activeChannels = []
        syncActiveStreamPresence()
        channelInfos = [:]
        streamInfos = [:]
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

    /// Clips the last seconds of a live Twitch stream (or a specific channel in dual-stream mode) and hands the clip's link to `save`.
    public func clip(channel targetLogin: String? = nil, save: @MainActor (URL) -> Void) async {
        let login = targetLogin.map(StreamAddress.canonicalKey(for:)) ?? channel
        if let login, !StreamAddress.platform(for: login).supportsServerClip { return }
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

    private func syncActiveStreamPresence() {
        ActiveStreamPresence.update(
            channels: activeChannels,
            defaults: ctx.settings.defaults,
            now: ctx.clock.now())
    }

    private func remember(_ login: String) {
        var list = recents.filter { $0 != login }
        list.insert(login, at: 0)
        if list.count > Self.recentsMax { list.removeLast(list.count - Self.recentsMax) }
        recents = list
        ctx.settings.defaults.set(list, forKey: Self.recentsKey)
    }

    /// Parses a Twitch login/URL (`name`, `@name`, `twitch.tv/name`), Kick slug/URL (`kick:name`, `kick.com/name`),
    /// or YouTube Live URL/handle (`youtube.com/watch?v=...`, `youtube.com/@handle`, `youtu.be/...`, `yt:@handle`, `yt:<id>`)
    /// into its canonical key; returns `nil` if invalid.
    public nonisolated static func login(from input: String) -> String? {
        StreamAddress.parse(input)?.canonicalKey
    }
}

extension TwitchStore: LifecycleAware {
    public func lifecycle(_ event: LifecycleEvent, snapshot: LifecycleSnapshot) {
        switch event {
        case .lowPowerModeChanged, .thermalChanged:
            setLowPowerMode(snapshot.shouldConservePower)
        case .becameActive:
            if !activeChannels.isEmpty {
                syncActiveStreamPresence()
            }
        case .willTerminate:
            ActiveStreamPresence.clear(defaults: ctx.settings.defaults)
        default:
            break
        }
    }
}

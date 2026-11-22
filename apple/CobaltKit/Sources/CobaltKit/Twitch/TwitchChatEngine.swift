import Foundation

/// Who chat connects as: the studio's Twitch account (`GET /stage/twitch/session`, APP-API-CONTRACT 70), or nobody (read
/// only, as Twitch's anonymous `justinfan`).
public struct TwitchCredentials: Sendable, Equatable {
    public var login: String
    public var userID: String
    public var clientID: String
    public var token: String
    /// The token has `chat:read` and `chat:edit`.
    public var canChat: Bool

    public init(login: String, userID: String, clientID: String, token: String, canChat: Bool) {
        self.login = login
        self.userID = userID
        self.clientID = clientID
        self.token = token
        self.canChat = canChat
    }
}

/// One channel's live chat (APP-API-CONTRACT 70): the IRC socket, 7TV's emotes and EventAPI (paints, badges, set changes)
/// and Twitch's badges, folded into `TwitchChatSnapshot`s published at most every 120 ms. All parsing and JSON happen
/// here, off main (apple/ARCHITECTURE.md rule 1). Nothing is written anywhere: closing it forgets everything.
public actor TwitchChatEngine {
    public static let lineLimit = 300
    static let ircURL = URL(string: "wss://irc-ws.chat.twitch.tv:443")!
    static let publishGap: Duration = .milliseconds(120)

    public nonisolated let snapshots: AsyncStream<TwitchChatSnapshot>
    private let continuation: AsyncStream<TwitchChatSnapshot>.Continuation

    private let channel: String
    private let credentials: TwitchCredentials?
    private let session: URLSession

    private var snapshot: TwitchChatSnapshot
    private var dirty = false
    private var publishing = false
    private var stopped = false

    private var irc: URLSessionWebSocketTask?
    private var ircLoop: Task<Void, Never>?
    private var attempts = 0
    /// The account's IRC login failed: read-only from here (a token without chat scopes, or an expired one).
    private var authRefused = false

    private var events: URLSessionWebSocketTask?
    private var eventsLoop: Task<Void, Never>?
    private var eventsAttempts = 0

    private var roomID: String?
    private var sevenTvSetID: String?
    private var twitchBadges: [String: ChatBadge] = [:]
    private var channelBadges: [String: ChatBadge] = [:]
    private var globalEmotes: [String: ChatEmote] = [:]
    private var channelEmotes: [String: ChatEmote] = [:]
    private var userEmotes: [String: ChatEmote] = [:]
    /// The same, with Twitch's type and owner (for the picker's sections), in Twitch's order.
    private var userEmoteRows: [TwitchUserEmote] = []
    /// Every Twitch emote the channel has (`chat/emotes`), sendable or not: the picker shows the rest locked.
    private var channelTwitchEmotes: [ChatEmote] = []
    /// `userEmoteRows` came from the pass asked for this channel (it holds the follower emotes too).
    private var userEmotesHaveChannel = false
    private var named: [String: ChatEmote] = [:]
    private var emoteList = TwitchEmoteList()
    /// The text and Twitch emote ranges of each line still shown, so lines can be split again when 7TV's emotes arrive.
    private var raw: [String: (String, [TwitchEmoteRange])] = [:]
    /// 7TV cosmetics by id, and which cosmetic each login wears.
    private var paintsByID: [String: SevenTvPaint] = [:]
    private var badgesByID: [String: ChatBadge] = [:]
    private var wornPaint: [String: String] = [:]
    private var wornBadge: [String: String] = [:]
    /// What USERSTATE says about the signed-in user here (for the lines this device sends).
    private var myColor: UInt32?
    private var myBadges: [TwitchBadgeRef] = []
    private var myDisplayName: String?
    private var localCounter = 0

    public init(channel: String, credentials: TwitchCredentials?, session: URLSession = .shared) {
        self.channel = channel.lowercased()
        self.credentials = credentials
        self.session = session
        self.snapshot = TwitchChatSnapshot(channel: channel.lowercased())
        (snapshots, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - lifecycle

    public func start() {
        guard !stopped, irc == nil else { return }
        set(status: .connecting)
        connectIRC()
        Task { await self.loadGlobals() }
    }

    public func stop() {
        stopped = true
        ircLoop?.cancel()
        eventsLoop?.cancel()
        irc?.cancel(with: .goingAway, reason: nil)
        events?.cancel(with: .goingAway, reason: nil)
        irc = nil
        events = nil
        continuation.finish()
    }

    /// The emotes the composer completes, best first.
    public func emotes() -> TwitchEmoteList { emoteList }

    // MARK: - sending

    /// Sends `text` (a reply when `replyTo` is a message id). False when chat is read-only or not joined.
    @discardableResult
    public func send(_ text: String, replyTo: String? = nil) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, snapshot.canSend, let irc, let credentials else { return false }
        do {
            try await irc.send(.string(TwitchIRC.privmsg(channel: channel, text: trimmed, replyTo: replyTo)))
        } catch {
            return false
        }
        // Twitch never echoes our own message back over IRC: it is drawn here with what USERSTATE said about us
        localCounter += 1
        let id = "local-\(localCounter)"
        var reply: TwitchChatLine.Reply?
        if let replyTo, let parent = snapshot.lines.last(where: { $0.id == replyTo }) {
            reply = .init(login: parent.login, displayName: parent.displayName, text: parent.plainText)
        }
        var line = TwitchChatLine(
            id: id, kind: .message, login: credentials.login, displayName: myDisplayName ?? credentials.login,
            color: myColor, badges: resolve(myBadges), fragments: [], timestamp: Date(), mentionsMe: false, mine: true,
            replyTo: reply)
        if trimmed.hasPrefix("/me ") {
            line.kind = .action
            line.fragments = ChatFragmenter.fragments(text: String(trimmed.dropFirst(4)), ranges: [], named: named)
        } else {
            line.fragments = ChatFragmenter.fragments(text: trimmed, ranges: [], named: named)
        }
        raw[id] = (trimmed.hasPrefix("/me ") ? String(trimmed.dropFirst(4)) : trimmed, [])
        append(line)
        return true
    }

    // MARK: - IRC

    private func connectIRC() {
        guard !stopped else { return }
        let task = session.webSocketTask(with: Self.ircURL)
        irc = task
        task.resume()
        let login = authRefused ? nil : credentials
        ircLoop = Task { [weak self] in
            guard let self else { return }
            await self.ircSession(task, login: login)
        }
    }

    private func ircSession(_ task: URLSessionWebSocketTask, login: TwitchCredentials?) async {
        do {
            try await task.send(.string(TwitchIRC.capabilities()))
            if let login {
                try await task.send(.string(TwitchIRC.pass(login.token)))
                try await task.send(.string(TwitchIRC.nick(login.login)))
            } else {
                try await task.send(.string(TwitchIRC.nick(TwitchIRC.anonymousNick())))
            }
            try await task.send(.string(TwitchIRC.join(channel)))
            while !Task.isCancelled {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                for line in text.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" }) {
                    guard let parsed = TwitchIRC.parse(String(line)) else { continue }
                    await handle(parsed, on: task, login: login)
                }
            }
        } catch {
            // closed, or the network went away
        }
        guard !stopped, irc === task else { return }
        irc = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        attempts += 1
        let wait = min(30, 1 << min(attempts - 1, 5))
        set(status: .reconnecting(retryIn: wait))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            await self?.reconnectNow()
        }
    }

    private func reconnectNow() {
        guard !stopped, irc == nil else { return }
        set(status: .connecting)
        connectIRC()
    }

    private func handle(_ m: IRCMessage, on task: URLSessionWebSocketTask, login: TwitchCredentials?) async {
        switch m.command {
        case "PING":
            try? await task.send(.string("PONG :\(m.trailing ?? "tmi.twitch.tv")"))
        case "RECONNECT":
            task.cancel(with: .goingAway, reason: nil)
        case "ROOMSTATE":
            applyRoomState(m.tags)
            if roomID == nil, let id = m.tags["room-id"], !id.isEmpty {
                roomID = id
                Task { await self.loadChannel(id) }
            }
        case "JOIN":
            // only our own JOIN arrives (no membership capability): we are in
            attempts = 0
            set(status: .joined(canSend: login?.canChat == true && !authRefused))
        case "USERSTATE", "GLOBALUSERSTATE":
            if let c = TwitchIRC.color(m.tags["color"]) { myColor = c }
            if m.command == "USERSTATE" { myBadges = TwitchIRC.badges(m.tags["badges"]) }
            if let name = m.tags["display-name"], !name.isEmpty { myDisplayName = name }
        case "PRIVMSG":
            privmsg(m, login: login)
        case "USERNOTICE":
            usernotice(m, login: login)
        case "CLEARMSG":
            if let target = m.tags["target-msg-id"] { markDeleted { $0.id == target } }
        case "CLEARCHAT":
            if let who = m.trailing?.lowercased(), !who.isEmpty {
                markDeleted { $0.login == who }
            } else {
                system("chat was cleared by a moderator")
            }
        case "NOTICE":
            let text = m.trailing ?? ""
            if text.lowercased().contains("login authentication failed") || text.lowercased().contains("improperly formatted auth") {
                // the token is no good for chat: carry on read-only
                authRefused = true
                task.cancel(with: .goingAway, reason: nil)
                system("can't sign in to twitch chat, reading only")
            } else if !text.isEmpty {
                system(text.lowercased())
            }
        default:
            break
        }
    }

    private func applyRoomState(_ tags: [String: String]) {
        var room = snapshot.room
        if let v = tags["slow"], let n = Int(v) { room.slowSeconds = n }
        if let v = tags["emote-only"] { room.emoteOnly = v == "1" }
        if let v = tags["subs-only"] { room.subsOnly = v == "1" }
        if let v = tags["followers-only"], let n = Int(v) { room.followersOnlyMinutes = n }
        if room != snapshot.room {
            snapshot.room = room
            markDirty()
        }
    }

    private func privmsg(_ m: IRCMessage, login: TwitchCredentials?) {
        guard var text = m.trailing, let nick = m.nick?.lowercased() else { return }
        var kind = TwitchChatLine.Kind.message
        // `\u{1}ACTION …\u{1}` is /me
        if text.hasPrefix("\u{1}ACTION "), text.hasSuffix("\u{1}") {
            text = String(text.dropFirst(8).dropLast())
            kind = .action
        }
        let ranges = kind == .action ? [] : TwitchIRC.emoteRanges(m.tags["emotes"])
        let id = m.tags["id"] ?? UUID().uuidString
        var reply: TwitchChatLine.Reply?
        if let parent = m.tags["reply-parent-user-login"], !parent.isEmpty {
            reply = .init(
                login: parent, displayName: m.tags["reply-parent-display-name"] ?? parent,
                text: m.tags["reply-parent-msg-body"] ?? "")
            // Twitch puts "@parent " in front of a reply: the banner above says it already
            let lead = "@\(m.tags["reply-parent-display-name"] ?? parent) "
            if text.lowercased().hasPrefix(lead.lowercased()) {
                text = String(text.dropFirst(lead.count))
            }
        }
        let shifted = reply == nil ? ranges : shift(ranges, original: m.trailing ?? "", now: text)
        let line = TwitchChatLine(
            id: id, kind: kind, login: nick, displayName: m.tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? nick,
            color: TwitchIRC.color(m.tags["color"]), badges: resolve(TwitchIRC.badges(m.tags["badges"])),
            fragments: ChatFragmenter.fragments(text: text, ranges: shifted, named: named),
            timestamp: m.tags["tmi-sent-ts"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
            mentionsMe: login.map { ChatFragmenter.mentions(text, login: $0.login) } ?? false,
            mine: login.map { $0.login.lowercased() == nick } ?? false,
            replyTo: reply)
        raw[id] = (text, shifted)
        append(line)
    }

    /// Emote ranges count from the start of the original text; dropping the reply's "@name " moves them left.
    private func shift(_ ranges: [TwitchEmoteRange], original: String, now: String) -> [TwitchEmoteRange] {
        let cut = original.unicodeScalars.count - now.unicodeScalars.count
        guard cut > 0 else { return ranges }
        return ranges.compactMap { r in
            guard r.start >= cut else { return nil }
            return TwitchEmoteRange(id: r.id, start: r.start - cut, end: r.end - cut)
        }
    }

    private func usernotice(_ m: IRCMessage, login: TwitchCredentials?) {
        let said = m.tags["system-msg"] ?? ""
        let text = m.trailing ?? ""
        let nick = (m.tags["login"] ?? m.nick ?? "").lowercased()
        let id = m.tags["id"] ?? UUID().uuidString
        let ranges = TwitchIRC.emoteRanges(m.tags["emotes"])
        let line = TwitchChatLine(
            id: id, kind: .notice(said), login: nick, displayName: m.tags["display-name"] ?? nick,
            color: TwitchIRC.color(m.tags["color"]), badges: resolve(TwitchIRC.badges(m.tags["badges"])),
            fragments: text.isEmpty ? [] : ChatFragmenter.fragments(text: text, ranges: ranges, named: named),
            timestamp: Date(), mentionsMe: false, mine: false, replyTo: nil)
        if !text.isEmpty { raw[id] = (text, ranges) }
        append(line)
    }

    private func system(_ text: String) {
        localCounter += 1
        append(TwitchChatLine(
            id: "sys-\(localCounter)", kind: .system, login: "", displayName: "", color: nil, badges: [],
            fragments: [.text(text)], timestamp: Date(), mentionsMe: false, mine: false, replyTo: nil))
    }

    private func markDeleted(_ match: (TwitchChatLine) -> Bool) {
        var changed = false
        for i in snapshot.lines.indices where !snapshot.lines[i].deleted && match(snapshot.lines[i]) {
            snapshot.lines[i].deleted = true
            changed = true
        }
        if changed { markDirty() }
    }

    private func append(_ line: TwitchChatLine) {
        snapshot.lines.append(line)
        if snapshot.lines.count > Self.lineLimit {
            let drop = snapshot.lines.count - Self.lineLimit
            for gone in snapshot.lines.prefix(drop) { raw[gone.id] = nil }
            snapshot.lines.removeFirst(drop)
        }
        markDirty()
    }

    private func resolve(_ refs: [TwitchBadgeRef]) -> [ChatBadge] {
        refs.compactMap { channelBadges["\($0.set)/\($0.version)"] ?? twitchBadges["\($0.set)/\($0.version)"] }
    }

    // MARK: - publishing

    private func set(status: TwitchChatStatus) {
        guard snapshot.status != status else { return }
        snapshot.status = status
        markDirty()
    }

    private func markDirty() {
        dirty = true
        guard !publishing else { return }
        publishing = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.publishGap)
            await self?.publish()
        }
    }

    private func publish() {
        publishing = false
        guard dirty, !stopped else { return }
        dirty = false
        continuation.yield(snapshot)
    }

    // MARK: - emotes and badges

    private func loadGlobals() async {
        async let seven: Void = loadSevenTvGlobal()
        async let badges: Void = loadTwitchBadges(path: "chat/badges/global", channel: false)
        async let mine: Void = loadUserEmotes(broadcasterID: nil)
        _ = await (seven, badges, mine)
    }

    private func loadChannel(_ id: String) async {
        async let seven: Void = loadSevenTvChannel(id)
        async let badges: Void = loadTwitchBadges(path: "chat/badges", query: [("broadcaster_id", id)], channel: true)
        // again with the channel, so its follower emotes come too (Helix lists those only when asked for a broadcaster)
        async let mine: Void = loadUserEmotes(broadcasterID: id)
        async let theirs: Void = loadChannelTwitchEmotes(id)
        _ = await (seven, badges, mine, theirs)
        connectEvents()
    }

    private func loadSevenTvGlobal() async {
        guard let data = await get(SevenTvChatWire.globalURL),
              let set = try? SevenTvChatWire.decoder().decode(SevenTvChatWire.EmoteSet.self, from: data)
        else { return }
        var map: [String: ChatEmote] = [:]
        for e in set.emotes ?? [] { if let emote = e.emote(global: true) { map[emote.name] = emote } }
        globalEmotes = map
        rebuildEmotes()
    }

    private func loadSevenTvChannel(_ twitchID: String) async {
        guard let data = await get(SevenTvChatWire.userURL(twitchID: twitchID)),
              let user = try? SevenTvChatWire.decoder().decode(SevenTvChatWire.User.self, from: data)
        else { return }
        var map: [String: ChatEmote] = [:]
        for e in user.emoteSet?.emotes ?? [] { if let emote = e.emote(global: false) { map[emote.name] = emote } }
        channelEmotes = map
        sevenTvSetID = user.emoteSet?.id
        rebuildEmotes()
    }

    private func loadTwitchBadges(path: String, query: [(String, String)] = [], channel: Bool) async {
        guard let page: HelixWire.Page<HelixWire.BadgeSet> = await helix(path, query: query) else { return }
        var map: [String: ChatBadge] = [:]
        for set in page.data ?? [] {
            for v in set.versions {
                guard let s = v.imageUrl2x, let url = URL(string: s) else { continue }
                map["\(set.setId)/\(v.id)"] = ChatBadge(id: "\(set.setId)/\(v.id)", title: v.title ?? set.setId, url: url)
            }
        }
        if channel { channelBadges = map } else { twitchBadges = map }
        // lines that came before the badges get theirs now
        guard !snapshot.lines.isEmpty else { return }
        markDirty()
    }

    private func loadUserEmotes(broadcasterID: String?) async {
        guard let credentials else { return }
        var map: [String: ChatEmote] = [:]
        var rows: [TwitchUserEmote] = []
        var cursor: String?
        var complete = false
        for _ in 0..<8 {
            var query = [("user_id", credentials.userID)]
            if let broadcasterID { query.append(("broadcaster_id", broadcasterID)) }
            if let cursor { query.append(("after", cursor)) }
            guard let page: HelixWire.CursorPage<HelixWire.UserEmote> = await helix("chat/emotes/user", query: query) else { break }
            for e in page.data ?? [] {
                let emote = ChatEmote.twitch(id: e.id, name: e.name, animated: e.format.map { $0.contains("animated") })
                map[e.name] = emote
                rows.append(TwitchUserEmote(emote: emote, type: e.emoteType, ownerID: e.ownerId))
            }
            cursor = page.pagination?.cursor
            if cursor == nil || cursor == "" { complete = true; break }
        }
        // a failed channel pass never wipes what the first pass found
        guard !map.isEmpty || complete else { return }
        // the first pass (no channel) may finish after the channel's: it never replaces that fuller list
        if broadcasterID == nil, userEmotesHaveChannel { return }
        if broadcasterID != nil { userEmotesHaveChannel = true }
        userEmotes = map
        userEmoteRows = rows
        rebuildEmotes()
    }

    private func loadChannelTwitchEmotes(_ id: String) async {
        guard let page: HelixWire.Page<HelixWire.ChannelEmote> = await helix("chat/emotes", query: [("broadcaster_id", id)])
        else { return }
        channelTwitchEmotes = (page.data ?? []).map {
            ChatEmote.twitch(id: $0.id, name: $0.name, animated: $0.format.map { $0.contains("animated") })
        }
        rebuildEmotes()
    }

    private func rebuildEmotes() {
        // the channel's 7TV names win over the user's Twitch emotes, which win over 7TV global
        var all = globalEmotes
        for (k, v) in userEmotes { all[k] = v }
        for (k, v) in channelEmotes { all[k] = v }
        named = all
        let sorted: ([ChatEmote]) -> [ChatEmote] = { $0.sorted { $0.name.lowercased() < $1.name.lowercased() } }
        emoteList = TwitchEmoteList(
            emotes: sorted(Array(channelEmotes.values)) + sorted(Array(userEmotes.values)) + sorted(Array(globalEmotes.values)),
            sections: TwitchEmoteList.pickerSections(
                sevenTvChannel: Array(channelEmotes.values), channelTwitch: channelTwitchEmotes, user: userEmoteRows,
                roomID: roomID, sevenTvGlobal: Array(globalEmotes.values)))
        snapshot.emotesVersion += 1
        // split the lines on screen again, so 7TV words become emotes
        for i in snapshot.lines.indices {
            let id = snapshot.lines[i].id
            guard let (text, ranges) = raw[id] else { continue }
            let next = ChatFragmenter.fragments(text: text, ranges: ranges, named: named)
            if next != snapshot.lines[i].fragments { snapshot.lines[i].fragments = next }
        }
        markDirty()
    }

    // MARK: - 7TV EventAPI (paints, badges, live set changes)

    private func connectEvents() {
        guard !stopped, events == nil, roomID != nil else { return }
        let task = session.webSocketTask(with: SevenTvChatWire.events)
        events = task
        task.resume()
        eventsLoop = Task { [weak self] in
            guard let self else { return }
            await self.eventsSession(task)
        }
    }

    private func eventsSession(_ task: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
                guard let env = try? SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: data) else { continue }
                await handleEvent(env, on: task)
            }
        } catch {}
        guard !stopped, events === task else { return }
        events = nil
        eventsAttempts += 1
        let wait = min(60, 2 << min(eventsAttempts, 5))
        try? await Task.sleep(for: .seconds(wait))
        connectEvents()
    }

    private func handleEvent(_ env: SevenTvChatWire.Envelope, on task: URLSessionWebSocketTask) async {
        switch env.op {
        case 1:
            // hello: ask for this channel's cosmetics and its set's changes
            eventsAttempts = 0
            guard let room = roomID else { return }
            let channelCondition = ["ctx": "channel", "platform": "TWITCH", "id": room]
            var subs = [
                SevenTvChatWire.subscribe(type: "cosmetic.*", condition: channelCondition),
                SevenTvChatWire.subscribe(type: "entitlement.*", condition: channelCondition),
            ]
            if let set = sevenTvSetID { subs.append(SevenTvChatWire.subscribe(type: "emote_set.update", condition: ["object_id": set])) }
            for s in subs { try? await task.send(.string(s)) }
        case 0:
            guard let type = env.d?.type, let body = env.d?.body else { return }
            dispatch(type: type, body: body)
        case 4, 7:
            // reconnect / end of stream: start over
            task.cancel(with: .goingAway, reason: nil)
        default:
            break
        }
    }

    private func dispatch(type: String, body: SevenTvChatWire.Body) {
        switch type {
        case "cosmetic.create":
            guard let obj = body.object, let id = obj.id ?? obj.data?.id, let data = obj.data else { return }
            switch (obj.kind ?? "").uppercased() {
            case "PAINT": if let p = SevenTvChatWire.paint(data, id: id) { paintsByID[id] = p }
            case "BADGE": if let b = SevenTvChatWire.badge(data, id: id) { badgesByID[id] = b }
            default: return
            }
            applyCosmetics()
        case "entitlement.create", "entitlement.delete":
            guard let obj = body.object, let ref = obj.refId, let login = obj.user?.twitchLogin else { return }
            let removing = type == "entitlement.delete"
            switch (obj.kind ?? "").uppercased() {
            case "PAINT":
                if removing { if wornPaint[login] == ref { wornPaint[login] = nil } } else { wornPaint[login] = ref }
            case "BADGE":
                if removing { if wornBadge[login] == ref { wornBadge[login] = nil } } else { wornBadge[login] = ref }
            default: return
            }
            applyCosmetics()
        case "emote_set.update":
            var changed = false
            for c in body.pushed ?? [] where c.key == "emotes" {
                if let e = c.value?.emote(global: false) { channelEmotes[e.name] = e; changed = true }
            }
            for c in body.pulled ?? [] where c.key == "emotes" {
                if let name = c.oldValue?.name { channelEmotes[name] = nil; changed = true }
            }
            for c in body.updated ?? [] where c.key == "emotes" {
                if let old = c.oldValue?.name { channelEmotes[old] = nil }
                if let e = c.value?.emote(global: false) { channelEmotes[e.name] = e }
                changed = true
            }
            if changed { rebuildEmotes() }
        default:
            break
        }
    }

    private func applyCosmetics() {
        var paints: [String: SevenTvPaint] = [:]
        for (login, id) in wornPaint { if let p = paintsByID[id] { paints[login] = p } }
        var badges: [String: ChatBadge] = [:]
        for (login, id) in wornBadge { if let b = badgesByID[id] { badges[login] = b } }
        if paints != snapshot.paints { snapshot.paints = paints; markDirty() }
        if badges != snapshot.sevenTvBadges { snapshot.sevenTvBadges = badges; markDirty() }
    }

    // MARK: - HTTP

    private func get(_ url: URL, headers: [String: String] = [:]) async -> Data? {
        MainThreadGuard.assertOffMain()
        var req = URLRequest(url: url, timeoutInterval: 20)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    private func helix<T: Decodable>(_ path: String, query: [(String, String)] = []) async -> T? {
        guard let credentials else { return nil }
        guard var comps = URLComponents(url: HelixWire.base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = comps.url,
              let data = await get(url, headers: ["Client-Id": credentials.clientID, "Authorization": "Bearer \(credentials.token)"])
        else { return nil }
        return try? HelixWire.decoder().decode(T.self, from: data)
    }
}

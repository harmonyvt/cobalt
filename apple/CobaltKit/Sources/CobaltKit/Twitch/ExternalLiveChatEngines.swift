import Foundation

// Account-free live chat engines for Kick (Pusher WebSocket) and YouTube Live (InnerTube `get_live_chat`),
// sharing `LiveChatEngine` and `TwitchChatSnapshot` so single-stream and mixed multi-stream combined chat
// render Twitch, Kick, and YouTube messages identically without any external accounts.

/// Unified live chat engine interface implemented by `TwitchChatEngine`, `KickChatEngine`, and `YouTubeLiveChatEngine`.
public protocol LiveChatEngine: Actor {
    nonisolated var snapshots: AsyncStream<TwitchChatSnapshot> { get }
    nonisolated var channelName: String { get }
    func start()
    func stop()
    func emotes() -> TwitchEmoteList
    func send(_ text: String, replyTo: String?) async -> Bool
    func setLowPowerMode(_ enabled: Bool)
}

extension TwitchChatEngine: LiveChatEngine {}

/// Creates the right `LiveChatEngine` for a Twitch, Kick, or YouTube Live canonical channel key.
public enum LiveChatEngineFactory {
    public static func make(
        channel: String,
        credentials: TwitchCredentials?,
        session: URLSession = .shared,
        assetCache: TwitchChatAssetCache? = nil,
        sendLimiter: TwitchChatSendLimiter? = nil
    ) -> any LiveChatEngine {
        let address = StreamAddress.parse(channel)
        switch address?.platform ?? .twitch {
        case .twitch:
            return TwitchChatEngine(
                channel: address?.canonicalKey ?? channel,
                credentials: credentials,
                session: session,
                assetCache: assetCache,
                sendLimiter: sendLimiter
            )
        case .kick:
            return KickChatEngine(address: address!, session: session)
        case .youtube:
            return YouTubeLiveChatEngine(address: address!, session: session)
        }
    }
}

// MARK: - Kick Chat Parser (pure, unit-testable)

public enum KickChatParser {
    public enum Event: Sendable, Equatable {
        case subscribed
        case ping
        case message(TwitchChatLine)
        case deleted(messageID: String)
        case ignored
    }

    public struct PusherCredentials: Sendable, Equatable {
        public let appKey: String
        public let cluster: String

        public init(appKey: String, cluster: String) {
            self.appKey = appKey
            self.cluster = cluster
        }
    }

    /// Fallback public Pusher key/cluster used by Kick's web client if the realtime bootstrap endpoint omits one.
    public static let fallbackCredentials = PusherCredentials(appKey: "34bf7a0ff419a2a775b9", cluster: "us2")

    /// Parses `POST https://web.kick.com/api/v1/realtime/channels/<id>/chat/connection` JSON.
    public static func parseConnectionCredentials(_ data: Data) -> PusherCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let connections = dataObj["connections"] as? [[String: Any]]
        else { return nil }
        for conn in connections {
            if let creds = conn["credentials"] as? [String: Any],
               let key = creds["app_key"] as? String, !key.isEmpty {
                let cluster = (creds["cluster"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "us2"
                return PusherCredentials(appKey: key, cluster: cluster)
            }
        }
        return nil
    }

    /// Parses one Pusher WebSocket JSON frame into a normalized `Event`.
    public static func parseFrame(
        _ text: String,
        channelKey: String,
        namedEmotes: [String: ChatEmote] = [:]
    ) -> Event {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventName = frame["event"] as? String
        else { return .ignored }

        if eventName == "pusher:ping" { return .ping }
        if eventName == "pusher_internal:subscription_succeeded" { return .subscribed }

        let payloadDict: [String: Any]?
        if let rawStr = frame["data"] as? String, let rawData = rawStr.data(using: .utf8) {
            payloadDict = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
        } else {
            payloadDict = frame["data"] as? [String: Any]
        }
        guard let payload = payloadDict else { return .ignored }

        if eventName.hasSuffix("MessageDeletedEvent") {
            if let msg = payload["message"] as? [String: Any], let id = msg["id"] as? String, !id.isEmpty {
                return .deleted(messageID: id)
            }
            if let id = payload["id"] as? String, !id.isEmpty {
                return .deleted(messageID: id)
            }
            return .ignored
        }

        if eventName.hasSuffix("ChatMessageEvent") {
            guard let id = payload["id"] as? String, !id.isEmpty,
                  let content = payload["content"] as? String
            else { return .ignored }

            let sender = payload["sender"] as? [String: Any]
            let displayName = (sender?["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "chatter"
            let slug = (sender?["slug"] as? String)?.lowercased() ?? displayName.lowercased()
            let identity = sender?["identity"] as? [String: Any]
            let color = parseHexColor(identity?["color"] as? String)

            var reply: TwitchChatLine.Reply?
            if let meta = payload["metadata"] as? [String: Any],
               let origMsg = meta["original_message"] as? [String: Any],
               let origSender = meta["original_sender"] as? [String: Any],
               let origContent = origMsg["content"] as? String,
               let origUser = origSender["username"] as? String {
                reply = TwitchChatLine.Reply(
                    login: origUser.lowercased(),
                    displayName: origUser,
                    text: stripEmoteMarkup(origContent)
                )
            }

            let timestamp: Date
            if let createdStr = payload["created_at"] as? String,
               let parsed = TwitchHLSParser.parseISO8601(createdStr) {
                timestamp = parsed
            } else {
                timestamp = Date()
            }

            let fragments = parseContentFragments(content, namedEmotes: namedEmotes)
            let line = TwitchChatLine(
                id: id,
                channel: channelKey,
                kind: .message,
                login: slug,
                displayName: displayName,
                color: color,
                badges: [],
                fragments: fragments,
                timestamp: timestamp,
                mentionsMe: false,
                mine: false,
                replyTo: reply
            )
            return .message(line)
        }

        return .ignored
    }

    /// Parses Kick message text containing `[emote:<id>:<name>]` tokens alongside 7TV named emotes, `@mentions`, and links.
    public static func parseContentFragments(_ content: String, namedEmotes: [String: ChatEmote] = [:]) -> [ChatFragment] {
        guard content.contains("[emote:") else {
            return ChatFragmenter.fragments(text: content, ranges: [], named: namedEmotes)
        }
        guard let regex = try? NSRegularExpression(pattern: #"\[emote:(\d+):([^\]]+)\]"#) else {
            return ChatFragmenter.fragments(text: content, ranges: [], named: namedEmotes)
        }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return ChatFragmenter.fragments(text: content, ranges: [], named: namedEmotes)
        }

        var out: [ChatFragment] = []
        var cursor = 0
        for match in matches {
            let full = match.range
            if full.location > cursor {
                let slice = ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
                out.append(contentsOf: ChatFragmenter.fragments(text: slice, ranges: [], named: namedEmotes))
            }
            let emoteID = ns.substring(with: match.range(at: 1))
            let emoteName = ns.substring(with: match.range(at: 2))
            if let url = URL(string: "https://files.kick.com/emotes/\(emoteID)/fullsize") {
                out.append(.emote(ChatEmote(
                    id: "kick-\(emoteID)",
                    name: emoteName,
                    url: url,
                    animated: true,
                    zeroWidth: false,
                    aspect: 1,
                    source: .kick
                )))
            } else {
                out.append(.text(emoteName))
            }
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            let tail = ns.substring(from: cursor)
            out.append(contentsOf: ChatFragmenter.fragments(text: tail, ranges: [], named: namedEmotes))
        }
        return out
    }

    /// Parses 7TV v3 emote set JSON (either `/v3/users/kick/<userID>` or `/v3/emote-sets/global`).
    public static func parseSevenTvEmotes(_ data: Data, source: ChatEmote.Source) -> [String: ChatEmote] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let rawEmotes: [[String: Any]]
        if let emoteSet = root["emote_set"] as? [String: Any],
           let list = emoteSet["emotes"] as? [[String: Any]] {
            rawEmotes = list
        } else if let list = root["emotes"] as? [[String: Any]] {
            rawEmotes = list
        } else {
            return [:]
        }
        var out: [String: ChatEmote] = [:]
        out.reserveCapacity(rawEmotes.count)
        for item in rawEmotes {
            guard let id = item["id"] as? String, !id.isEmpty,
                  let name = item["name"] as? String, !name.isEmpty
            else { continue }
            let d = item["data"] as? [String: Any]
            let animated = (d?["animated"] as? Bool) ?? false
            let flags = (item["flags"] as? Int) ?? (d?["flags"] as? Int) ?? 0
            let zeroWidth = (flags & 1) != 0 || (flags & 256) != 0
            let host = d?["host"] as? [String: Any]
            let rawHostURL = (host?["url"] as? String) ?? "//cdn.7tv.app/emote/\(id)"
            let base = rawHostURL.hasPrefix("//") ? "https:\(rawHostURL)" : rawHostURL
            var aspect: Double = 1
            var pickedFile = animated ? "2x.webp" : "2x.webp"
            if let files = host?["files"] as? [[String: Any]] {
                if let f2 = files.first(where: { ($0["name"] as? String) == "2x.webp" })
                    ?? files.first(where: { ($0["name"] as? String) == "2x.avif" })
                    ?? files.first(where: { ($0["name"] as? String)?.hasPrefix("2x.") == true })
                    ?? files.first {
                    if let fn = f2["name"] as? String { pickedFile = fn }
                    if let w = f2["width"] as? Double, let h = f2["height"] as? Double, h > 0 {
                        aspect = max(0.5, min(4.0, w / h))
                    } else if let w = f2["width"] as? Int, let h = f2["height"] as? Int, h > 0 {
                        aspect = max(0.5, min(4.0, Double(w) / Double(h)))
                    }
                }
            }
            guard let url = URL(string: "\(base)/\(pickedFile)") else { continue }
            out[name] = ChatEmote(
                id: id,
                name: name,
                url: url,
                animated: animated,
                zeroWidth: zeroWidth,
                aspect: aspect,
                source: source
            )
        }
        return out
    }

    private static func stripEmoteMarkup(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[emote:\d+:([^\]]+)\]"#) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "$1")
    }

    static func parseHexColor(_ raw: String?) -> UInt32? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let val = UInt32(s, radix: 16) else { return nil }
        return val
    }
}

// MARK: - Kick Chat Engine

public actor KickChatEngine: LiveChatEngine {
    static let publishGap: Duration = .milliseconds(150)
    static let lowPowerPublishGap: Duration = .milliseconds(400)

    public nonisolated let snapshots: AsyncStream<TwitchChatSnapshot>
    public nonisolated let channelName: String
    private let continuation: AsyncStream<TwitchChatSnapshot>.Continuation

    private let address: StreamAddress
    private let session: URLSession
    private var snapshot: TwitchChatSnapshot
    private var namedEmotes: [String: ChatEmote] = [:]

    private var stopped = false
    private var lowPowerMode = false
    private var dirty = false
    private var publishing = false
    private var socket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    public init(address: StreamAddress, session: URLSession = .shared) {
        self.address = address
        self.session = session
        self.channelName = address.canonicalKey
        self.snapshot = TwitchChatSnapshot(channel: address.canonicalKey)
        (snapshots, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        guard !stopped, runTask == nil else { return }
        set(status: .connecting)
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        stopped = true
        runTask?.cancel()
        runTask = nil
        pingTask?.cancel()
        pingTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        continuation.finish()
    }

    public func emotes() -> TwitchEmoteList { TwitchEmoteList() }

    public func send(_ text: String, replyTo: String? = nil) async -> Bool { false }

    public func setLowPowerMode(_ enabled: Bool) {
        lowPowerMode = enabled
    }

    private func runLoop() async {
        let resolver = KickStreamResolver(session: session)
        var attempts = 0

        while !stopped, !Task.isCancelled {
            do {
                let payload = try await resolver.fetchChannel(slug: address.identifier)
                guard !stopped, !Task.isCancelled else { return }
                guard let chatroomID = payload.metadata.kickChatroomID else {
                    set(status: .failed("no chatroom"))
                    return
                }

                // Best-effort 7TV Kick + global emotes (non-blocking for chat startup)
                if namedEmotes.isEmpty {
                    let uid = payload.metadata.kickUserID
                    Task { [weak self] in
                        await self?.loadSevenTvEmotes(kickUserID: uid)
                    }
                }

                let creds: KickChatParser.PusherCredentials
                if let cid = payload.metadata.kickChannelID,
                   let fetched = await fetchPusherCredentials(channelID: cid) {
                    creds = fetched
                } else {
                    creds = KickChatParser.fallbackCredentials
                }

                guard let wsURL = URL(string: "wss://ws-\(creds.cluster).pusher.com/app/\(creds.appKey)?protocol=7&client=js&version=8.4.0-rc2&flash=false") else {
                    set(status: .failed("invalid chat socket"))
                    return
                }

                let task = session.webSocketTask(with: wsURL)
                socket = task
                task.resume()

                let subObj: [String: Any] = [
                    "event": "pusher:subscribe",
                    "data": [
                        "auth": "",
                        "channel": "chatrooms.\(chatroomID).v2",
                    ],
                ]
                if let subData = try? JSONSerialization.data(withJSONObject: subObj),
                   let subText = String(data: subData, encoding: .utf8) {
                    try await task.send(.string(subText))
                }

                startPingLoop(for: task)
                attempts = 0

                while !stopped, !Task.isCancelled {
                    let message = try await task.receive()
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: continue
                    }
                    await handleFrame(text, socket: task)
                }
            } catch {
                pingTask?.cancel()
                pingTask = nil
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil
                guard !stopped, !Task.isCancelled else { return }
                attempts += 1
                let delay = min(15, 1 << min(4, attempts))
                set(status: .reconnecting(retryIn: delay))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func handleFrame(_ text: String, socket: URLSessionWebSocketTask) async {
        let event = KickChatParser.parseFrame(text, channelKey: channelName, namedEmotes: namedEmotes)
        switch event {
        case .subscribed:
            set(status: .joined(canSend: false))
        case .ping:
            let pong = #"{"event":"pusher:pong","data":{}}"#
            try? await socket.send(.string(pong))
        case .message(let line):
            if snapshot.status == .connecting {
                snapshot.status = .joined(canSend: false)
            }
            snapshot.lines.append(line)
            if snapshot.lines.count > TwitchChatEngine.lineLimit {
                snapshot.lines.removeFirst(snapshot.lines.count - TwitchChatEngine.lineLimit)
            }
            markDirty()
        case .deleted(let messageID):
            if let idx = snapshot.lines.firstIndex(where: { $0.id == messageID }), !snapshot.lines[idx].deleted {
                snapshot.lines[idx].deleted = true
                markDirty()
            }
        case .ignored:
            break
        }
    }

    private func startPingLoop(for task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                let ping = #"{"event":"pusher:ping","data":{}}"#
                try? await task.send(.string(ping))
                _ = self
            }
        }
    }

    private func fetchPusherCredentials(channelID: Int) async -> KickChatParser.PusherCredentials? {
        guard let url = URL(string: "https://web.kick.com/api/v1/realtime/channels/\(channelID)/chat/connection") else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(KickStreamResolver.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "client": ["id": UUID().uuidString.lowercased(), "type": "web"],
            "capabilities": ["accepted_providers": [["provider": "pusher"]]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return KickChatParser.parseConnectionCredentials(data)
    }

    private func loadSevenTvEmotes(kickUserID: Int?) async {
        MainThreadGuard.assertOffMain()
        var merged: [String: ChatEmote] = [:]
        if let globalURL = URL(string: "https://7tv.io/v3/emote-sets/global"),
           let (data, resp) = try? await session.data(from: globalURL),
           let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            merged = KickChatParser.parseSevenTvEmotes(data, source: .sevenTvGlobal)
        }
        if let kickUserID,
           let userURL = URL(string: "https://7tv.io/v3/users/kick/\(kickUserID)"),
           let (data, resp) = try? await session.data(from: userURL),
           let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            let channelMap = KickChatParser.parseSevenTvEmotes(data, source: .sevenTv)
            for (k, v) in channelMap { merged[k] = v }
        }
        if !merged.isEmpty {
            namedEmotes = merged
        }
    }

    private func set(status: TwitchChatStatus) {
        guard snapshot.status != status else { return }
        snapshot.status = status
        continuation.yield(snapshot)
    }

    private func markDirty() {
        dirty = true
        guard !publishing else { return }
        publishing = true
        let gap = lowPowerMode ? Self.lowPowerPublishGap : Self.publishGap
        Task { [weak self] in
            try? await Task.sleep(for: gap)
            await self?.flushPublish()
        }
    }

    private func flushPublish() {
        publishing = false
        guard dirty, !stopped else { return }
        dirty = false
        continuation.yield(snapshot)
    }
}

// MARK: - YouTube Live Chat Parser (pure, unit-testable)

public enum YouTubeLiveChatParser {
    public struct PollResult: Sendable, Equatable {
        public let lines: [TwitchChatLine]
        public let nextContinuation: String?
        public let timeoutMs: Int

        public init(lines: [TwitchChatLine], nextContinuation: String?, timeoutMs: Int) {
            self.lines = lines
            self.nextContinuation = nextContinuation
            self.timeoutMs = timeoutMs
        }
    }

    /// Parses `POST https://www.youtube.com/youtubei/v1/live_chat/get_live_chat` JSON response.
    public static func parsePollResponse(_ data: Data, channelKey: String) -> PollResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cc = root["continuationContents"] as? [String: Any],
              let liveChat = cc["liveChatContinuation"] as? [String: Any]
        else {
            return PollResult(lines: [], nextContinuation: nil, timeoutMs: 3000)
        }

        var nextContinuation: String?
        var timeoutMs = 2500
        if let continuations = liveChat["continuations"] as? [[String: Any]] {
            for c in continuations {
                if let inv = c["invalidationContinuationData"] as? [String: Any],
                   let token = inv["continuation"] as? String, !token.isEmpty {
                    nextContinuation = token
                    if let t = inv["timeoutMs"] as? Int { timeoutMs = t }
                    break
                }
                if let timed = c["timedContinuationData"] as? [String: Any],
                   let token = timed["continuation"] as? String, !token.isEmpty {
                    nextContinuation = token
                    if let t = timed["timeoutMs"] as? Int { timeoutMs = t }
                    break
                }
                if let reload = c["reloadContinuationData"] as? [String: Any],
                   let token = reload["continuation"] as? String, !token.isEmpty {
                    nextContinuation = token
                    break
                }
            }
        }

        var lines: [TwitchChatLine] = []
        if let actions = liveChat["actions"] as? [[String: Any]] {
            for action in actions {
                guard let addItem = action["addChatItemAction"] as? [String: Any],
                      let item = addItem["item"] as? [String: Any]
                else { continue }

                if let textMsg = item["liveChatTextMessageRenderer"] as? [String: Any],
                   let line = parseMessageRenderer(textMsg, channelKey: channelKey, noticePrefix: nil) {
                    lines.append(line)
                } else if let paidMsg = item["liveChatPaidMessageRenderer"] as? [String: Any] {
                    let amount = simpleText(paidMsg["purchaseAmountText"]) ?? "Super Chat"
                    if let line = parseMessageRenderer(paidMsg, channelKey: channelKey, noticePrefix: "Super Chat · \(amount)") {
                        lines.append(line)
                    }
                } else if let memberMsg = item["liveChatMembershipItemRenderer"] as? [String: Any] {
                    let header = runsPlainText(memberMsg["headerSubtext"]) ?? simpleText(memberMsg["headerSubtext"]) ?? "New member"
                    if let line = parseMessageRenderer(memberMsg, channelKey: channelKey, noticePrefix: header) {
                        lines.append(line)
                    }
                }
            }
        }

        return PollResult(lines: lines, nextContinuation: nextContinuation, timeoutMs: timeoutMs)
    }

    private static func parseMessageRenderer(
        _ renderer: [String: Any],
        channelKey: String,
        noticePrefix: String?
    ) -> TwitchChatLine? {
        guard let id = renderer["id"] as? String, !id.isEmpty else { return nil }
        let authorName = simpleText(renderer["authorName"]) ?? "viewer"
        let authorID = (renderer["authorExternalChannelId"] as? String) ?? authorName
        let login = authorName.lowercased()

        let timestamp: Date
        if let usecStr = renderer["timestampUsec"] as? String, let usec = Double(usecStr) {
            timestamp = Date(timeIntervalSince1970: usec / 1_000_000)
        } else {
            timestamp = Date()
        }

        var badges: [ChatBadge] = []
        var authorColor: UInt32?
        if let rawBadges = renderer["authorBadges"] as? [[String: Any]] {
            for entry in rawBadges {
                guard let b = entry["liveChatAuthorBadgeRenderer"] as? [String: Any] else { continue }
                let tooltip = (b["tooltip"] as? String) ?? ""
                if let custom = b["customThumbnail"] as? [String: Any],
                   let thumbs = custom["thumbnails"] as? [[String: Any]],
                   let urlStr = thumbs.last?["url"] as? String,
                   let url = URL(string: urlStr.hasPrefix("//") ? "https:\(urlStr)" : urlStr) {
                    badges.append(ChatBadge(id: "yt-badge-\(badges.count)", title: tooltip, url: url))
                } else if let icon = b["icon"] as? [String: Any], let iconType = icon["iconType"] as? String {
                    switch iconType {
                    case "OWNER": authorColor = 0xFFD600
                    case "MODERATOR": authorColor = 0x5E84F1
                    default: break
                    }
                }
            }
        }

        let fragments = parseRuns((renderer["message"] as? [String: Any])?["runs"] as? [[String: Any]])
        if fragments.isEmpty && noticePrefix == nil { return nil }

        let kind: TwitchChatLine.Kind = noticePrefix.map { .notice($0) } ?? .message
        return TwitchChatLine(
            id: id,
            channel: channelKey,
            kind: kind,
            login: login.isEmpty ? authorID : login,
            displayName: authorName,
            color: authorColor,
            badges: badges,
            fragments: fragments,
            timestamp: timestamp,
            mentionsMe: false,
            mine: false,
            replyTo: nil
        )
    }

    private static func parseRuns(_ runs: [[String: Any]]?) -> [ChatFragment] {
        guard let runs else { return [] }
        var out: [ChatFragment] = []
        for run in runs {
            if let text = run["text"] as? String, !text.isEmpty {
                out.append(contentsOf: ChatFragmenter.fragments(text: text, ranges: [], named: [:]))
            } else if let emoji = run["emoji"] as? [String: Any] {
                let emojiID = (emoji["emojiId"] as? String) ?? UUID().uuidString
                let shortcuts = emoji["shortcuts"] as? [String]
                let name = shortcuts?.first ?? emojiID
                if let image = emoji["image"] as? [String: Any],
                   let thumbs = image["thumbnails"] as? [[String: Any]],
                   let rawURL = thumbs.last?["url"] as? String,
                   let url = URL(string: rawURL.hasPrefix("//") ? "https:\(rawURL)" : rawURL) {
                    out.append(.emote(ChatEmote(
                        id: "yt-\(emojiID)",
                        name: name,
                        url: url,
                        animated: false,
                        zeroWidth: false,
                        aspect: 1,
                        source: .youtube
                    )))
                } else {
                    out.append(.text(name))
                }
            }
        }
        return out
    }

    private static func simpleText(_ raw: Any?) -> String? {
        if let dict = raw as? [String: Any], let s = dict["simpleText"] as? String, !s.isEmpty {
            return s
        }
        return nil
    }

    private static func runsPlainText(_ raw: Any?) -> String? {
        guard let dict = raw as? [String: Any], let runs = dict["runs"] as? [[String: Any]] else { return nil }
        let joined = runs.compactMap { $0["text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }
}

// MARK: - YouTube Live Chat Engine

public actor YouTubeLiveChatEngine: LiveChatEngine {
    static let publishGap: Duration = .milliseconds(150)
    static let lowPowerPublishGap: Duration = .milliseconds(400)

    public nonisolated let snapshots: AsyncStream<TwitchChatSnapshot>
    public nonisolated let channelName: String
    private let continuation: AsyncStream<TwitchChatSnapshot>.Continuation

    private let address: StreamAddress
    private let session: URLSession
    private var snapshot: TwitchChatSnapshot
    private var seenIDs: Set<String> = []
    private var seenOrder: [String] = []

    private var stopped = false
    private var lowPowerMode = false
    private var dirty = false
    private var publishing = false
    private var runTask: Task<Void, Never>?

    public init(address: StreamAddress, session: URLSession = .shared) {
        self.address = address
        self.session = session
        self.channelName = address.canonicalKey
        self.snapshot = TwitchChatSnapshot(channel: address.canonicalKey)
        (snapshots, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        guard !stopped, runTask == nil else { return }
        set(status: .connecting)
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        stopped = true
        runTask?.cancel()
        runTask = nil
        continuation.finish()
    }

    public func emotes() -> TwitchEmoteList { TwitchEmoteList() }

    public func send(_ text: String, replyTo: String? = nil) async -> Bool { false }

    public func setLowPowerMode(_ enabled: Bool) {
        lowPowerMode = enabled
    }

    private func runLoop() async {
        let resolver = YouTubeLiveResolver(session: session)
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/live_chat/get_live_chat?prettyPrint=false")!
        var nextToken: String?
        var attempts = 0

        while !stopped, !Task.isCancelled {
            if nextToken == nil {
                do {
                    let watch = try await resolver.fetchWatchPage(address: address)
                    guard !stopped, !Task.isCancelled else { return }
                    if let token = watch.chatContinuation, !token.isEmpty {
                        nextToken = token
                        set(status: .joined(canSend: false))
                        attempts = 0
                    } else {
                        // Stream might have live chat disabled or not yet initialized.
                        attempts += 1
                        let delay = min(15, 2 * attempts)
                        set(status: attempts > 2 ? .failed("live chat unavailable") : .reconnecting(retryIn: delay))
                        try? await Task.sleep(for: .seconds(delay))
                        continue
                    }
                } catch {
                    guard !stopped, !Task.isCancelled else { return }
                    attempts += 1
                    let delay = min(15, 1 << min(4, attempts))
                    set(status: .reconnecting(retryIn: delay))
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
            }

            guard let token = nextToken else { continue }
            do {
                var req = URLRequest(url: endpoint, timeoutInterval: 10)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(YouTubeLiveResolver.webUserAgent, forHTTPHeaderField: "User-Agent")
                let body: [String: Any] = [
                    "continuation": token,
                    "context": [
                        "client": [
                            "clientName": "WEB",
                            "clientVersion": YouTubeLiveResolver.webClientVersion,
                            "hl": "en",
                            "gl": "US",
                        ]
                    ],
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                MainThreadGuard.assertOffMain()
                let (data, response) = try await session.data(for: req)
                guard !stopped, !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw TwitchHLSError.playlistFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
                }

                let parsed = YouTubeLiveChatParser.parsePollResponse(data, channelKey: channelName)
                if snapshot.status != .joined(canSend: false) {
                    set(status: .joined(canSend: false))
                }
                attempts = 0

                if !parsed.lines.isEmpty {
                    var appended = false
                    for line in parsed.lines {
                        guard seenIDs.insert(line.id).inserted else { continue }
                        seenOrder.append(line.id)
                        snapshot.lines.append(line)
                        appended = true
                    }
                    if snapshot.lines.count > TwitchChatEngine.lineLimit {
                        snapshot.lines.removeFirst(snapshot.lines.count - TwitchChatEngine.lineLimit)
                    }
                    if seenOrder.count > TwitchChatEngine.lineLimit * 2 {
                        let drop = seenOrder.count - TwitchChatEngine.lineLimit * 2
                        for old in seenOrder.prefix(drop) { seenIDs.remove(old) }
                        seenOrder.removeFirst(drop)
                    }
                    if appended { markDirty() }
                }

                nextToken = parsed.nextContinuation
                let baseMs = max(1200, min(10_000, parsed.timeoutMs))
                let waitMs = lowPowerMode ? max(2500, min(12_000, baseMs * 2)) : baseMs
                try? await Task.sleep(for: .milliseconds(waitMs))
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                attempts += 1
                if attempts >= 3 { nextToken = nil }
                let delay = min(15, 1 << min(4, attempts))
                set(status: .reconnecting(retryIn: delay))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func set(status: TwitchChatStatus) {
        guard snapshot.status != status else { return }
        snapshot.status = status
        continuation.yield(snapshot)
    }

    private func markDirty() {
        dirty = true
        guard !publishing else { return }
        publishing = true
        let gap = lowPowerMode ? Self.lowPowerPublishGap : Self.publishGap
        Task { [weak self] in
            try? await Task.sleep(for: gap)
            await self?.flushPublish()
        }
    }

    private func flushPublish() {
        publishing = false
        guard dirty, !stopped else { return }
        dirty = false
        continuation.yield(snapshot)
    }
}

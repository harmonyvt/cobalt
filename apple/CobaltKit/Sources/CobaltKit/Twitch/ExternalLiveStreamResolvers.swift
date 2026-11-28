import Foundation

// Account-free Kick and YouTube Live HLS & metadata resolvers (off-main, Swift 6 strict concurrency).
//
// - Kick:
//   1. `GET https://kick.com/api/v2/channels/<slug>` -> `playback_url` (AWS IVS master `.m3u8`), `id`, `user_id`,
//      `chatroom.id`, `livestream` metadata.
//   2. `GET <playback_url>` -> standard HLS master playlist parsed via `TwitchHLSParser.parseMaster`.
//
// - YouTube Live:
//   1. `GET https://www.youtube.com/watch?v=<id>` or `/@<handle>/live` or `/channel/<UC...>/live`
//      -> resolves live `videoId`, channel display name, title, avatar, viewer count, and initial live chat continuation.
//   2. `POST https://www.youtube.com/youtubei/v1/player?prettyPrint=false` (ANDROID client)
//      -> `streamingData.hlsManifestUrl` (standard MPEG-TS HLS master playlist).
//   3. `GET <hlsManifestUrl>` with Android `User-Agent` -> parsed via `TwitchHLSParser.parseMaster`,
//      forwarding `requiredHeaders` so media playlists and segment fetches stay authorized.

public struct KickChannelPayload: Sendable, Equatable {
    public let metadata: ExternalLiveStreamMetadata
    public let playbackURL: URL?

    public init(metadata: ExternalLiveStreamMetadata, playbackURL: URL?) {
        self.metadata = metadata
        self.playbackURL = playbackURL
    }
}

public struct YouTubeWatchPageInfo: Sendable, Equatable {
    public let videoID: String?
    public let channelID: String?
    public let displayName: String
    public let title: String
    public let avatarURL: URL?
    public let thumbnailURL: URL?
    public let viewerCount: Int
    public let isLive: Bool
    public let chatContinuation: String?

    public init(
        videoID: String?,
        channelID: String?,
        displayName: String,
        title: String,
        avatarURL: URL?,
        thumbnailURL: URL?,
        viewerCount: Int,
        isLive: Bool,
        chatContinuation: String?
    ) {
        self.videoID = videoID
        self.channelID = channelID
        self.displayName = displayName
        self.title = title
        self.avatarURL = avatarURL
        self.thumbnailURL = thumbnailURL
        self.viewerCount = viewerCount
        self.isLive = isLive
        self.chatContinuation = chatContinuation
    }
}

public struct YouTubePlayerResponseInfo: Sendable, Equatable {
    public let status: String
    public let hlsManifestURL: URL?
    public let isLive: Bool
    public let title: String?
    public let author: String?
    public let channelID: String?
    public let viewerCount: Int?
    public let thumbnailURL: URL?

    public init(
        status: String,
        hlsManifestURL: URL?,
        isLive: Bool,
        title: String? = nil,
        author: String? = nil,
        channelID: String? = nil,
        viewerCount: Int? = nil,
        thumbnailURL: URL? = nil
    ) {
        self.status = status
        self.hlsManifestURL = hlsManifestURL
        self.isLive = isLive
        self.title = title
        self.author = author
        self.channelID = channelID
        self.viewerCount = viewerCount
        self.thumbnailURL = thumbnailURL
    }
}

// MARK: - Kick Resolver

public struct KickStreamResolver: Sendable {
    public typealias Fetch = TwitchStreamResolver.Fetch

    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private let fetch: Fetch

    public init(session: URLSession = .shared) {
        self.fetch = { request in
            MainThreadGuard.assertOffMain()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TwitchHLSError.playlistFailed(0)
            }
            return (data, http)
        }
    }

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// Fetches Kick channel profile, live status, chatroom ID, and `playback_url`.
    public func fetchChannel(slug: String) async throws -> KickChannelPayload {
        let cleanSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard StreamAddress.isValidKickSlug(cleanSlug),
              let url = URL(string: "https://kick.com/api/v2/channels/\(cleanSlug)")
        else {
            throw TwitchHLSError.invalidChannel
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, http) = try await fetch(req)
        if http.statusCode == 404 { throw TwitchHLSError.offline }
        guard (200..<300).contains(http.statusCode) else {
            throw TwitchHLSError.playlistFailed(http.statusCode)
        }
        return try Self.parseChannelJSON(data, canonicalKey: "kick:\(cleanSlug)")
    }

    /// Resolves a Kick channel address to its AWS IVS HLS master playlist and variants.
    public func resolveStream(address: StreamAddress) async throws -> TwitchResolvedStream {
        guard address.platform == .kick else { throw TwitchHLSError.invalidChannel }
        let payload = try await fetchChannel(slug: address.identifier)
        guard payload.metadata.isLive, let masterURL = payload.playbackURL else {
            throw TwitchHLSError.offline
        }
        var req = URLRequest(url: masterURL, timeoutInterval: 10)
        req.setValue("application/vnd.apple.mpegurl, */*", forHTTPHeaderField: "Accept")
        req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, http) = try await fetch(req)
        if http.statusCode == 404 { throw TwitchHLSError.offline }
        guard (200..<300).contains(http.statusCode), let text = String(data: data, encoding: .utf8) else {
            throw TwitchHLSError.playlistFailed(http.statusCode)
        }
        let parsed = TwitchHLSParser.parseMaster(text, baseURL: masterURL)
        let ordered = Self.orderVariants(parsed)
        guard !ordered.isEmpty else { throw TwitchHLSError.noPlayableVariant }
        return TwitchResolvedStream(
            masterURL: masterURL,
            variants: ordered,
            requiredHeaders: [:],
            metadata: payload.metadata
        )
    }

    /// Pure JSON parser for `GET https://kick.com/api/v2/channels/<slug>`.
    public static func parseChannelJSON(_ data: Data, canonicalKey: String) throws -> KickChannelPayload {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TwitchHLSError.playlistFailed(0)
        }
        let channelID = intValue(obj["id"])
        let userID = intValue(obj["user_id"])
        let slug = (obj["slug"] as? String)?.lowercased()
            ?? StreamAddress.parse(canonicalKey)?.identifier
            ?? canonicalKey

        let user = obj["user"] as? [String: Any]
        let username = (user?["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let avatarStr = user?["profile_pic"] as? String
        let avatarURL = avatarStr.flatMap(URL.init(string:))

        let chatroom = obj["chatroom"] as? [String: Any]
        let chatroomID = intValue(chatroom?["id"])

        let livestream = obj["livestream"] as? [String: Any]
        let isLive: Bool
        if let livestream {
            isLive = (livestream["is_live"] as? Bool) ?? true
        } else {
            isLive = false
        }

        let title = (livestream?["session_title"] as? String) ?? ""
        let viewers = intValue(livestream?["viewer_count"]) ?? 0

        var category = ""
        if let categories = livestream?["categories"] as? [[String: Any]],
           let firstName = categories.first?["name"] as? String {
            category = firstName
        }

        var thumbnailURL: URL?
        if let thumb = livestream?["thumbnail"] as? [String: Any],
           let urlStr = thumb["url"] as? String {
            thumbnailURL = URL(string: urlStr)
        }

        let playbackStr = (obj["playback_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let playbackURL = (playbackStr?.isEmpty == false) ? URL(string: playbackStr!) : nil

        let displayName = (username?.isEmpty == false) ? username! : slug
        let metadata = ExternalLiveStreamMetadata(
            platform: .kick,
            canonicalKey: "kick:\(slug)",
            displayName: displayName,
            title: title,
            category: category,
            avatarURL: avatarURL,
            thumbnailURL: thumbnailURL,
            viewerCount: viewers,
            isLive: isLive,
            kickChannelID: channelID,
            kickUserID: userID,
            kickChatroomID: chatroomID,
            kickSlug: slug
        )
        return KickChannelPayload(metadata: metadata, playbackURL: playbackURL)
    }

    static func orderVariants(_ variants: [TwitchVariant]) -> [TwitchVariant] {
        variants.sorted { lhs, rhs in
            if lhs.isAudioOnly != rhs.isAudioOnly { return !lhs.isAudioOnly }
            let lh = lhs.height ?? 0
            let rh = rhs.height ?? 0
            if lh != rh { return lh > rh }
            let lf = lhs.frameRate ?? 0
            let rf = rhs.frameRate ?? 0
            if lf != rf { return lf > rf }
            return lhs.bandwidth > rhs.bandwidth
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }
}

// MARK: - YouTube Live Resolver

public struct YouTubeLiveResolver: Sendable {
    public typealias Fetch = TwitchStreamResolver.Fetch

    public static let androidClientVersion = "20.10.38"
    public static let androidUserAgent = "com.google.android.youtube/\(androidClientVersion) (Linux; U; Android 14) gzip"
    public static let webClientVersion = "2.20250301.00.00"
    static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private let fetch: Fetch

    public init(session: URLSession = .shared) {
        self.fetch = { request in
            MainThreadGuard.assertOffMain()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TwitchHLSError.playlistFailed(0)
            }
            return (data, http)
        }
    }

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// Fetches watch page HTML to resolve `@handle` / `channel/UC...` / `videoId` to live video ID, metadata, and chat continuation.
    public func fetchWatchPage(address: StreamAddress) async throws -> YouTubeWatchPageInfo {
        guard address.platform == .youtube, let url = address.webURL else {
            throw TwitchHLSError.invalidChannel
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("CONSENT=YES+cb.20210328-17-p0.en+FX+999; SOCS=CAI", forHTTPHeaderField: "Cookie")
        let (data, http) = try await fetch(req)
        if http.statusCode == 404 { throw TwitchHLSError.offline }
        guard (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            throw TwitchHLSError.playlistFailed(http.statusCode)
        }
        return Self.parseWatchPageHTML(html, canonicalKey: address.canonicalKey)
    }

    /// Requests the InnerTube ANDROID player response to obtain `streamingData.hlsManifestUrl`.
    public func fetchPlayerResponse(videoID: String) async throws -> YouTubePlayerResponseInfo {
        guard StreamAddress.isValidYouTubeVideoID(videoID) else {
            throw TwitchHLSError.invalidChannel
        }
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("3", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(Self.androidClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue(Self.androidUserAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": Self.androidClientVersion,
                    "androidSdkVersion": 34,
                    "hl": "en",
                    "gl": "US",
                ]
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await fetch(req)
        guard (200..<300).contains(http.statusCode) else {
            throw TwitchHLSError.playlistFailed(http.statusCode)
        }
        return try Self.parsePlayerResponseJSON(data)
    }

    /// Resolves a YouTube Live address to its HLS master playlist, variants, required Android User-Agent header, and metadata.
    public func resolveStream(address: StreamAddress) async throws -> TwitchResolvedStream {
        guard address.platform == .youtube else { throw TwitchHLSError.invalidChannel }

        let watchInfo: YouTubeWatchPageInfo?
        let videoID: String
        switch address.youtubeTarget {
        case .videoID(let vid):
            videoID = vid
            watchInfo = try? await fetchWatchPage(address: address)
        case .handle, .channelID:
            let page = try await fetchWatchPage(address: address)
            guard let resolvedID = page.videoID, page.isLive else {
                throw TwitchHLSError.offline
            }
            videoID = resolvedID
            watchInfo = page
        case nil:
            throw TwitchHLSError.invalidChannel
        }

        let player = try await fetchPlayerResponse(videoID: videoID)
        if player.status.uppercased() == "LIVE_STREAM_OFFLINE" || player.status.uppercased() == "ERROR" {
            throw TwitchHLSError.offline
        }
        guard let masterURL = player.hlsManifestURL else {
            if !player.isLive { throw TwitchHLSError.offline }
            throw TwitchHLSError.noPlayableVariant
        }

        let headers = ["User-Agent": Self.androidUserAgent]
        var req = URLRequest(url: masterURL, timeoutInterval: 10)
        req.setValue("application/vnd.apple.mpegurl, */*", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, http) = try await fetch(req)
        if http.statusCode == 404 { throw TwitchHLSError.offline }
        guard (200..<300).contains(http.statusCode), let text = String(data: data, encoding: .utf8) else {
            throw TwitchHLSError.playlistFailed(http.statusCode)
        }

        let parsed = TwitchHLSParser.parseMaster(text, baseURL: masterURL)
        let ordered = KickStreamResolver.orderVariants(parsed)
        guard !ordered.isEmpty else { throw TwitchHLSError.noPlayableVariant }

        let displayName: String = {
            if let a = player.author, !a.isEmpty { return a }
            if let d = watchInfo?.displayName, !d.isEmpty { return d }
            return address.displayLabel
        }()
        let title: String = {
            if let t = player.title, !t.isEmpty { return t }
            return watchInfo?.title ?? ""
        }()
        let metadata = ExternalLiveStreamMetadata(
            platform: .youtube,
            canonicalKey: address.canonicalKey,
            displayName: displayName,
            title: title,
            category: "YouTube Live",
            avatarURL: watchInfo?.avatarURL,
            thumbnailURL: watchInfo?.thumbnailURL ?? player.thumbnailURL,
            viewerCount: watchInfo?.viewerCount ?? player.viewerCount ?? 0,
            isLive: player.isLive || (watchInfo?.isLive ?? true),
            youtubeVideoID: videoID,
            youtubeChannelID: player.channelID ?? watchInfo?.channelID,
            youtubeChatContinuation: watchInfo?.chatContinuation
        )

        return TwitchResolvedStream(
            masterURL: masterURL,
            variants: ordered,
            requiredHeaders: headers,
            metadata: metadata
        )
    }

    // MARK: - Pure HTML & JSON Parsers (unit-testable)

    /// Parses YouTube watch or `/@handle/live` HTML into live video ID, display name, title, viewers, and chat continuation.
    public static func parseWatchPageHTML(_ html: String, canonicalKey: String) -> YouTubeWatchPageInfo {
        var videoID: String?
        var channelID: String?
        var displayName = StreamAddress.displayLabel(for: canonicalKey)
        var title = ""
        var avatarURL: URL?
        var thumbnailURL: URL?
        var viewerCount = 0
        var isLive = false
        var chatContinuation: String?

        // 1. Parse `ytInitialPlayerResponse` JSON if embedded
        if let playerJSON = extractJSONObject(in: html, after: "ytInitialPlayerResponse = "),
           let data = playerJSON.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let details = root["videoDetails"] as? [String: Any] {
                if let vid = details["videoId"] as? String, StreamAddress.isValidYouTubeVideoID(vid) {
                    videoID = vid
                }
                if let cid = details["channelId"] as? String, !cid.isEmpty { channelID = cid }
                if let author = details["author"] as? String, !author.isEmpty { displayName = author }
                if let t = details["title"] as? String, !t.isEmpty { title = t }
                if let liveFlag = details["isLive"] as? Bool { isLive = liveFlag }
                if !isLive, let liveContent = details["isLiveContent"] as? Bool,
                   let status = (root["playabilityStatus"] as? [String: Any])?["status"] as? String,
                   status.uppercased() == "OK" {
                    isLive = liveContent
                }
                if let thumbObj = details["thumbnail"] as? [String: Any],
                   let thumbs = thumbObj["thumbnails"] as? [[String: Any]],
                   let lastURL = thumbs.last?["url"] as? String {
                    thumbnailURL = URL(string: lastURL)
                }
            }
            if let micro = (root["microformat"] as? [String: Any])?["playerMicroformatRenderer"] as? [String: Any],
               let liveDetails = micro["liveBroadcastDetails"] as? [String: Any],
               let liveNow = liveDetails["isLiveNow"] as? Bool {
                isLive = liveNow
            }
        }

        // 2. Parse `ytInitialData` for live chat continuation, avatar, and concurrent viewer count
        if let initialDataJSON = extractJSONObject(in: html, after: "ytInitialData = "),
           let data = initialDataJSON.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            chatContinuation = findLiveChatContinuation(in: root)
            if avatarURL == nil {
                avatarURL = findAvatarURL(in: root)
            }
            if viewerCount == 0 {
                viewerCount = findConcurrentViewers(in: initialDataJSON)
            }
        }

        // 3. Fallback regex extraction for canonical watch link and live chat continuation
        if videoID == nil {
            videoID = firstCapture(in: html, pattern: #"rel="canonical"\s+href="https://www\.youtube\.com/watch\?v=([A-Za-z0-9_-]{11})""#)
                ?? firstCapture(in: html, pattern: #""videoId"\s*:\s*"([A-Za-z0-9_-]{11})""#)
        }
        if chatContinuation == nil, let range = html.range(of: "liveChatRenderer") {
            let tail = String(html[range.lowerBound...].prefix(4_000))
            chatContinuation = firstCapture(in: tail, pattern: #""continuation"\s*:\s*"([^"]{20,})""#)
        }
        if viewerCount == 0 {
            viewerCount = findConcurrentViewers(in: html)
        }

        return YouTubeWatchPageInfo(
            videoID: videoID,
            channelID: channelID,
            displayName: displayName,
            title: title,
            avatarURL: avatarURL,
            thumbnailURL: thumbnailURL,
            viewerCount: viewerCount,
            isLive: isLive,
            chatContinuation: chatContinuation
        )
    }

    /// Pure JSON parser for `POST /youtubei/v1/player`.
    public static func parsePlayerResponseJSON(_ data: Data) throws -> YouTubePlayerResponseInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TwitchHLSError.playlistFailed(0)
        }
        let playability = root["playabilityStatus"] as? [String: Any]
        let status = (playability?["status"] as? String) ?? "UNKNOWN"

        let streaming = root["streamingData"] as? [String: Any]
        let hlsStr = streaming?["hlsManifestUrl"] as? String
        let hlsURL = hlsStr.flatMap(URL.init(string:))

        let details = root["videoDetails"] as? [String: Any]
        let title = details?["title"] as? String
        let author = details?["author"] as? String
        let channelID = details?["channelId"] as? String
        let isLive = (details?["isLive"] as? Bool) ?? (details?["isLiveContent"] as? Bool) ?? (hlsURL != nil)
        let viewerCount = (details?["viewCount"] as? String).flatMap(Int.init)

        var thumbnailURL: URL?
        if let thumbObj = details?["thumbnail"] as? [String: Any],
           let thumbs = thumbObj["thumbnails"] as? [[String: Any]],
           let lastURL = thumbs.last?["url"] as? String {
            thumbnailURL = URL(string: lastURL)
        }

        return YouTubePlayerResponseInfo(
            status: status,
            hlsManifestURL: hlsURL,
            isLive: isLive,
            title: title,
            author: author,
            channelID: channelID,
            viewerCount: viewerCount,
            thumbnailURL: thumbnailURL
        )
    }

    /// Extracts a balanced JSON `{ ... }` object starting immediately after `marker`.
    public static func extractJSONObject(in text: String, after marker: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        var idx = markerRange.upperBound
        while idx < text.endIndex, text[idx].isWhitespace {
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex, text[idx] == "{" else { return nil }

        let bytes = text[idx...].utf8
        var depth = 0
        var inString = false
        var escaped = false
        var endOffset: Int?
        var offset = 0

        for b in bytes {
            if inString {
                if escaped {
                    escaped = false
                } else if b == 0x5C { // '\'
                    escaped = true
                } else if b == 0x22 { // '"'
                    inString = false
                }
            } else {
                if b == 0x22 {
                    inString = true
                } else if b == 0x7B { // '{'
                    depth += 1
                } else if b == 0x7D { // '}'
                    depth -= 1
                    if depth == 0 {
                        endOffset = offset + 1
                        break
                    }
                }
            }
            offset += 1
            // Safety cap at 4 MB
            if offset > 4_000_000 { return nil }
        }

        guard let endOffset else { return nil }
        let startUTF8 = idx.samePosition(in: text.utf8) ?? text.utf8.startIndex
        let endUTF8 = text.utf8.index(startUTF8, offsetBy: endOffset)
        return String(text.utf8[startUTF8..<endUTF8])
    }

    private static func findLiveChatContinuation(in node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let chat = dict["liveChatRenderer"] as? [String: Any] {
                if let continuations = chat["continuations"] as? [[String: Any]] {
                    for c in continuations {
                        if let reload = c["reloadContinuationData"] as? [String: Any],
                           let token = reload["continuation"] as? String, !token.isEmpty {
                            return token
                        }
                        if let inv = c["invalidationContinuationData"] as? [String: Any],
                           let token = inv["continuation"] as? String, !token.isEmpty {
                            return token
                        }
                        if let timed = c["timedContinuationData"] as? [String: Any],
                           let token = timed["continuation"] as? String, !token.isEmpty {
                            return token
                        }
                    }
                }
            }
            for (_, v) in dict {
                if let found = findLiveChatContinuation(in: v) { return found }
            }
        } else if let arr = node as? [Any] {
            for item in arr {
                if let found = findLiveChatContinuation(in: item) { return found }
            }
        }
        return nil
    }

    private static func findAvatarURL(in node: Any) -> URL? {
        if let dict = node as? [String: Any] {
            if let owner = dict["videoOwnerRenderer"] as? [String: Any],
               let thumb = owner["thumbnail"] as? [String: Any],
               let thumbs = thumb["thumbnails"] as? [[String: Any]],
               let raw = thumbs.last?["url"] as? String {
                let normalized = raw.hasPrefix("//") ? "https:\(raw)" : raw
                return URL(string: normalized)
            }
            for (_, v) in dict {
                if let found = findAvatarURL(in: v) { return found }
            }
        } else if let arr = node as? [Any] {
            for item in arr {
                if let found = findAvatarURL(in: item) { return found }
            }
        }
        return nil
    }

    private static func findConcurrentViewers(in text: String) -> Int {
        // Matches `"12,345 watching now"` or `"viewCount":{"videoViewCountRenderer":{"viewCount":{"runs":[{"text":"12,345"},{"text":" watching now"}]}}}`
        if let raw = firstCapture(in: text, pattern: #"([0-9][0-9,]{0,9})\s+watching now"#) {
            let digits = raw.filter(\.isNumber)
            if let n = Int(digits) { return n }
        }
        if let raw = firstCapture(in: text, pattern: #""text"\s*:\s*"([0-9][0-9,]{0,9})"\s*\}\s*,\s*\{\s*"text"\s*:\s*"\s*watching now"#) {
            let digits = raw.filter(\.isNumber)
            if let n = Int(digits) { return n }
        }
        return 0
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        let cap = match.range(at: 1)
        guard cap.location != NSNotFound else { return nil }
        return ns.substring(with: cap)
    }
}

// MARK: - Unified External Metadata Helper

/// Account-free live metadata fetcher for Kick and YouTube streams (used by `TwitchStore` when no Twitch Helix call applies).
public enum ExternalLiveDirectory {
    public static func fetchMetadata(for canonicalKey: String, session: URLSession = .shared) async -> ExternalLiveStreamMetadata? {
        guard let address = StreamAddress.parse(canonicalKey) else { return nil }
        switch address.platform {
        case .twitch:
            return nil
        case .kick:
            return try? await KickStreamResolver(session: session).fetchChannel(slug: address.identifier).metadata
        case .youtube:
            let resolver = YouTubeLiveResolver(session: session)
            let watch = try? await resolver.fetchWatchPage(address: address)
            let vid: String?
            switch address.youtubeTarget {
            case .videoID(let v): vid = v
            case .handle, .channelID: vid = watch?.videoID
            case nil: vid = nil
            }
            let player: YouTubePlayerResponseInfo?
            if let vid {
                player = try? await resolver.fetchPlayerResponse(videoID: vid)
            } else {
                player = nil
            }
            guard watch != nil || player != nil else { return nil }
            let displayName = player?.author ?? watch?.displayName ?? address.displayLabel
            let title = player?.title ?? watch?.title ?? ""
            let isLive = player?.isLive ?? watch?.isLive ?? false
            return ExternalLiveStreamMetadata(
                platform: .youtube,
                canonicalKey: address.canonicalKey,
                displayName: displayName,
                title: title,
                category: "YouTube Live",
                avatarURL: watch?.avatarURL,
                thumbnailURL: watch?.thumbnailURL ?? player?.thumbnailURL,
                viewerCount: watch?.viewerCount ?? player?.viewerCount ?? 0,
                isLive: isLive,
                youtubeVideoID: vid,
                youtubeChannelID: player?.channelID ?? watch?.channelID,
                youtubeChatContinuation: watch?.chatContinuation
            )
        }
    }
}

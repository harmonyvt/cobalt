import Foundation

/// Live streaming platforms supported by the native HLS player and live chat stack.
public enum StreamPlatform: String, Sendable, Codable, Hashable, CaseIterable {
    case twitch
    case kick
    case youtube

    public var displayName: String {
        switch self {
        case .twitch: "Twitch"
        case .kick: "Kick"
        case .youtube: "YouTube"
        }
    }

    public var lowercaseName: String {
        switch self {
        case .twitch: "twitch"
        case .kick: "kick"
        case .youtube: "youtube"
        }
    }

    /// Compact badge mark for pills and channel chips.
    public var badgeMark: String {
        switch self {
        case .twitch: "TW"
        case .kick: "K"
        case .youtube: "YT"
        }
    }

    /// Brand accent color as 0xRRGGBB.
    public var brandRGB: UInt32 {
        switch self {
        case .twitch: 0x9146FF
        case .kick: 0x53FC18
        case .youtube: 0xFF0033
        }
    }

    /// Only Twitch supports authenticated chat sending through the studio session.
    public var supportsSendingChat: Bool {
        self == .twitch
    }

    /// Only Twitch has a WebView embed fallback when native HLS fails.
    public var supportsEmbedFallback: Bool {
        self == .twitch
    }

    /// Only Twitch supports server-side Helix clip creation.
    public var supportsServerClip: Bool {
        self == .twitch
    }
}

/// Target identifier within a YouTube Live address.
public enum YouTubeLiveTarget: Sendable, Hashable, Codable {
    /// A specific 11-character YouTube video ID (case-sensitive).
    case videoID(String)
    /// A channel handle without leading `@` (lowercased).
    case handle(String)
    /// A `UC...` channel ID (case-sensitive).
    case channelID(String)
}

/// Classification of a shared or pasted URL for live-stream handling vs normal media saving.
public enum SharedStreamKind: Sendable, Hashable {
    /// Unambiguous live stream URL (Twitch channel, Kick channel, YouTube `/live/...`, `/@handle/live`, `/channel/UC.../live`).
    case live(StreamAddress)
    /// YouTube URL that could be either a live stream or a regular video to save
    /// (`youtube.com/watch?v=...`, `youtu.be/...`, `youtube.com/@handle`, `youtube.com/channel/UC...`).
    case ambiguousYouTube(StreamAddress)

    public var address: StreamAddress {
        switch self {
        case .live(let address), .ambiguousYouTube(let address):
            return address
        }
    }

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}

/// Canonical, platform-aware live stream address parsed from user input, URLs, or stored keys.
///
/// Canonical key format:
/// - Twitch: plain lowercase login (`"xqc"`) — 100% backward compatible with existing recents/routes.
/// - Kick: `"kick:<lowercased-slug>"` (e.g. `"kick:xqc"`).
/// - YouTube: `"yt:<11-char-videoID>"` (preserves exact case), `"yt:@<lowercased-handle>"`,
///   or `"yt:channel/<UC...>"` (preserves exact case).
public struct StreamAddress: Sendable, Hashable {
    public let platform: StreamPlatform
    /// Platform-native identifier (Twitch login, Kick slug, or YouTube videoId / `@handle` / `channel/UC...`).
    public let identifier: String
    /// Parsed YouTube target when `platform == .youtube`.
    public let youtubeTarget: YouTubeLiveTarget?

    public init(platform: StreamPlatform, identifier: String, youtubeTarget: YouTubeLiveTarget? = nil) {
        self.platform = platform
        self.identifier = identifier
        self.youtubeTarget = youtubeTarget
    }

    /// Stable key stored in `PaneItem`, `TwitchStore.activeChannels`, recents, and dictionaries.
    public var canonicalKey: String {
        switch platform {
        case .twitch:
            return identifier
        case .kick:
            return "kick:\(identifier)"
        case .youtube:
            return "yt:\(identifier)"
        }
    }

    /// Human-readable short label without internal prefixes (`kick:` / `yt:`).
    public var displayLabel: String {
        switch platform {
        case .twitch:
            return identifier
        case .kick:
            return identifier
        case .youtube:
            switch youtubeTarget {
            case .handle(let h): return "@\(h)"
            case .videoID(let v): return v
            case .channelID(let c): return c
            case nil: return identifier
            }
        }
    }

    /// Public watch URL for opening in Safari / sharing.
    public var webURL: URL? {
        switch platform {
        case .twitch:
            return URL(string: "https://www.twitch.tv/\(identifier)")
        case .kick:
            return URL(string: "https://kick.com/\(identifier)")
        case .youtube:
            switch youtubeTarget {
            case .videoID(let v):
                return URL(string: "https://www.youtube.com/watch?v=\(v)")
            case .handle(let h):
                return URL(string: "https://www.youtube.com/@\(h)/live")
            case .channelID(let c):
                return URL(string: "https://www.youtube.com/channel/\(c)/live")
            case nil:
                return URL(string: "https://www.youtube.com/")
            }
        }
    }

    // MARK: - Parsing & Canonicalization

    /// Parses a Twitch login/URL, Kick slug/URL (`kick:<slug>`, `kick.com/<slug>`),
    /// or YouTube Live URL/shorthand (`youtube.com/watch?v=...`, `youtube.com/live/...`, `youtu.be/...`,
    /// `youtube.com/@handle`, `yt:<videoId>`, `yt:@<handle>`, `yt:channel/<UC...>`).
    public static func parse(_ rawInput: String) -> StreamAddress? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let lower = trimmed.lowercased()

        // 1. Explicit prefixes (`kick:`, `yt:`, `youtube:`, `twitch:`)
        if lower.hasPrefix("kick:") {
            let slug = String(lower.dropFirst("kick:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/@"))
            guard isValidKickSlug(slug) else { return nil }
            return StreamAddress(platform: .kick, identifier: slug)
        }
        if lower.hasPrefix("yt:") || lower.hasPrefix("youtube:") {
            let dropCount = lower.hasPrefix("yt:") ? 3 : 8
            let body = String(trimmed.dropFirst(dropCount))
            return parseYouTubeShorthand(body)
        }
        if lower.hasPrefix("twitch:") {
            let login = String(lower.dropFirst("twitch:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/@"))
            guard isValidTwitchLogin(login) else { return nil }
            return StreamAddress(platform: .twitch, identifier: login)
        }

        // 2. URL forms (with or without scheme)
        if let urlAddress = parseURL(trimmed) {
            return urlAddress
        }

        // 3. Bare Twitch login (`name` or `@name`)
        var candidate = lower
        if candidate.hasPrefix("@") { candidate.removeFirst() }
        guard isValidTwitchLogin(candidate) else { return nil }
        return StreamAddress(platform: .twitch, identifier: candidate)
    }

    /// Classifies an HTTP/HTTPS URL as an unambiguous live stream, an ambiguous YouTube URL
    /// (which may be a live stream or a regular video), or `nil` (non-stream URL, clip, VOD, Short, playlist).
    public static func classifySharedURL(_ url: URL) -> SharedStreamKind? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return classifyURLComponents(comps)
    }

    /// Extracts the first shareable HTTP/HTTPS URL from text, including promotional share copy from
    /// official mobile apps (e.g. `"Watch Gigguk with me on Twitch! https://www.twitch.tv/gigguk"`)
    /// or scheme-less stream links (e.g. `"twitch.tv/gigguk"`).
    public static func extractSharedURL(from text: String) -> URL? {
        if let explicit = LinkInfo.firstLink(in: text) {
            return explicit
        }
        return firstBareStreamURL(in: text)
    }

    /// Extracts and classifies a live-stream URL from freeform shared text (such as mobile app share sheets).
    /// Returns `nil` when the text contains no stream URL or only VOD/clip/Short links.
    public static func classifySharedText(_ text: String) -> (url: URL, kind: SharedStreamKind)? {
        let links = LinkInfo.allLinks(in: text, limit: 10)
        if !links.isEmpty {
            for url in links {
                if let kind = classifySharedURL(url) {
                    return (url, kind)
                }
            }
            return nil
        }
        if let bare = firstBareStreamURL(in: text), let kind = classifySharedURL(bare) {
            return (bare, kind)
        }
        return nil
    }

    /// Canonicalizes an arbitrary channel key string, preserving case for YouTube video/channel IDs
    /// while lowercasing Twitch logins, Kick slugs, and YouTube `@handle` keys.
    public static func canonicalKey(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let parsed = parse(trimmed) {
            return parsed.canonicalKey
        }
        return trimmed.lowercased()
    }

    /// Detects the platform for a canonical key or raw input (defaults to `.twitch`).
    public static func platform(for raw: String) -> StreamPlatform {
        parse(raw)?.platform ?? .twitch
    }

    /// Display label without internal prefixes (`kick:` / `yt:`) for a canonical key.
    public static func displayLabel(for raw: String) -> String {
        parse(raw)?.displayLabel ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Web URL for a canonical key or raw input.
    public static func webURL(for raw: String) -> URL? {
        parse(raw)?.webURL
    }

    // MARK: - Private helpers

    private static let twitchLiveHosts: Set<String> = ["twitch.tv", "www.twitch.tv", "m.twitch.tv", "go.twitch.tv"]
    private static let kickLiveHosts: Set<String> = ["kick.com", "www.kick.com", "m.kick.com"]
    private static let youtubeShortHosts: Set<String> = ["youtu.be", "www.youtu.be"]
    private static let youtubeLiveHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com",
    ]

    private static let twitchReservedPaths: Set<String> = [
        "directory", "videos", "video", "downloads", "settings", "subscriptions",
        "inventory", "wallet", "search", "popout", "collections", "clip", "clips",
        "p", "u", "moderator", "jobs", "turbo", "prime", "drops", "friends",
        "messages", "activity", "store", "login", "signup", "following", "team",
        "teams", "squad", "stories", "embed",
    ]

    private static let kickReservedPaths: Set<String> = [
        "browse", "categories", "following", "search", "video", "videos", "clip",
        "clips", "popout", "dashboard", "transactions", "settings", "terms",
        "privacy", "community-guidelines", "dmca", "auth", "login", "register",
        "subcategories",
    ]

    private static let bareStreamLinkExpression: NSRegularExpression = {
        // Matches scheme-less Twitch, Kick, or YouTube URLs not preceded by another domain label.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "(?<![A-Za-z0-9.-])(?:(?:www|m|go)\\.)?(?:twitch\\.tv|kick\\.com|youtube\\.com|youtu\\.be)/[^\\s<>\"'`]+",
            options: [.caseInsensitive]
        )
    }()

    private static func firstBareStreamURL(in text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let limit = min(text.count, 16_384)
        let prefix = String(text.prefix(limit))
        let range = NSRange(prefix.startIndex..., in: prefix)
        guard let match = bareStreamLinkExpression.firstMatch(in: prefix, options: [], range: range),
              let swiftRange = Range(match.range, in: prefix)
        else { return nil }
        var found = String(prefix[swiftRange])
        while let last = found.last, "),.;:!?]}".contains(last) { found.removeLast() }
        guard let url = URL(string: "https://\(found)"), LinkInfo(url) != nil else { return nil }
        return url
    }

    private static func parseURL(_ raw: String) -> StreamAddress? {
        // Avoid interpreting bare logins with dots or invalid hosts as URLs unless a known host matches.
        let lower = raw.lowercased()
        let candidateString: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            candidateString = raw
        } else if raw.contains("/") || lower.contains(".tv") || lower.contains(".com") || lower.contains(".be") {
            candidateString = "https://\(raw)"
        } else {
            return nil
        }

        guard let comps = URLComponents(string: candidateString) else { return nil }
        return classifyURLComponents(comps)?.address
    }

    private static func classifyURLComponents(_ comps: URLComponents) -> SharedStreamKind? {
        guard let host = comps.host?.lowercased(), !host.isEmpty else { return nil }
        let pathParts = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        // Twitch URLs (excludes clips.twitch.tv, VODs /videos/..., /<user>/clip/..., /<user>/videos, etc.)
        if twitchLiveHosts.contains(host) {
            guard let first = pathParts.first?.lowercased() else { return nil }
            if first == "popout" {
                guard pathParts.count >= 2 else { return nil }
                let ch = pathParts[1].lowercased()
                guard isValidTwitchLogin(ch) else { return nil }
                return .live(StreamAddress(platform: .twitch, identifier: ch))
            }
            guard !twitchReservedPaths.contains(first), isValidTwitchLogin(first) else { return nil }
            // Only bare `/<channel>` or `/<channel>/home` are live channel pages; subpaths like
            // `/<channel>/clip/...`, `/<channel>/videos`, `/<channel>/video/...`, `/<channel>/v/...`
            // are VODs/clips/tabs that should not hijack normal media saving.
            if pathParts.count > 1 {
                guard pathParts.count == 2, pathParts[1].lowercased() == "home" else { return nil }
            }
            return .live(StreamAddress(platform: .twitch, identifier: first))
        }

        // Kick URLs (excludes clips.kick.com, `?clip=...`, /video/..., /videos/..., /<slug>/clips/...)
        if kickLiveHosts.contains(host) {
            if let clipParam = comps.queryItems?.first(where: { $0.name.lowercased() == "clip" })?.value,
               !clipParam.isEmpty {
                return nil
            }
            guard let first = pathParts.first?.lowercased() else { return nil }
            if first == "popout" {
                guard pathParts.count >= 2 else { return nil }
                let slug = pathParts[1].lowercased()
                guard isValidKickSlug(slug) else { return nil }
                return .live(StreamAddress(platform: .kick, identifier: slug))
            }
            guard !kickReservedPaths.contains(first), isValidKickSlug(first) else { return nil }
            guard pathParts.count == 1 else { return nil }
            return .live(StreamAddress(platform: .kick, identifier: first))
        }

        // YouTube short URLs (`youtu.be/<videoId>`) — could be a live stream or a regular video
        if youtubeShortHosts.contains(host) {
            guard pathParts.count == 1, let vid = pathParts.first, isValidYouTubeVideoID(vid) else { return nil }
            return .ambiguousYouTube(StreamAddress(platform: .youtube, identifier: vid, youtubeTarget: .videoID(vid)))
        }

        // YouTube standard/mobile URLs
        if youtubeLiveHosts.contains(host) {
            let first = pathParts.first
            let firstLower = first?.lowercased()

            // Explicitly exclude Shorts, playlists, clips, community posts, search, feeds
            if let firstLower, ["shorts", "playlist", "clip", "post", "results", "feed", "redirect"].contains(firstLower) {
                return nil
            }

            // /watch?v=<videoId> — ambiguous (could be a live stream or a normal video)
            if firstLower == nil || firstLower == "watch" {
                if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, isValidYouTubeVideoID(v) {
                    return .ambiguousYouTube(StreamAddress(platform: .youtube, identifier: v, youtubeTarget: .videoID(v)))
                }
                return nil
            }

            guard let first, let firstLower else { return nil }

            // /live/<videoId> — unambiguous live stream
            if firstLower == "live", pathParts.count >= 2, isValidYouTubeVideoID(pathParts[1]) {
                let vid = pathParts[1]
                return .live(StreamAddress(platform: .youtube, identifier: vid, youtubeTarget: .videoID(vid)))
            }

            // /embed/<videoId> — ambiguous
            if firstLower == "embed", pathParts.count >= 2, isValidYouTubeVideoID(pathParts[1]) {
                let vid = pathParts[1]
                return .ambiguousYouTube(StreamAddress(platform: .youtube, identifier: vid, youtubeTarget: .videoID(vid)))
            }

            // /@handle/live (unambiguous live) or /@handle (ambiguous channel link)
            if first.hasPrefix("@") {
                let handle = String(first.dropFirst()).lowercased()
                guard isValidYouTubeHandle(handle) else { return nil }
                let address = StreamAddress(platform: .youtube, identifier: "@\(handle)", youtubeTarget: .handle(handle))
                if pathParts.count == 2, pathParts[1].lowercased() == "live" {
                    return .live(address)
                }
                if pathParts.count == 1 {
                    return .ambiguousYouTube(address)
                }
                return nil
            }

            // /channel/UC.../live (unambiguous live) or /channel/UC... (ambiguous channel link)
            if firstLower == "channel", pathParts.count >= 2, isValidYouTubeChannelID(pathParts[1]) {
                let cid = pathParts[1]
                let address = StreamAddress(platform: .youtube, identifier: "channel/\(cid)", youtubeTarget: .channelID(cid))
                if pathParts.count == 3, pathParts[2].lowercased() == "live" {
                    return .live(address)
                }
                if pathParts.count == 2 {
                    return .ambiguousYouTube(address)
                }
                return nil
            }
        }

        return nil
    }

    private static func parseYouTubeShorthand(_ rawBody: String) -> StreamAddress? {
        let body = rawBody.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !body.isEmpty else { return nil }

        // Handle explicit `yt:@handle`
        if body.hasPrefix("@") {
            let handle = String(body.dropFirst()).lowercased()
            guard isValidYouTubeHandle(handle) else { return nil }
            return StreamAddress(platform: .youtube, identifier: "@\(handle)", youtubeTarget: .handle(handle))
        }

        // Handle `yt:channel/UC...`
        if body.lowercased().hasPrefix("channel/") {
            let cid = String(body.dropFirst("channel/".count))
            guard isValidYouTubeChannelID(cid) else { return nil }
            return StreamAddress(platform: .youtube, identifier: "channel/\(cid)", youtubeTarget: .channelID(cid))
        }

        // Direct `UC...` channel ID
        if isValidYouTubeChannelID(body) {
            return StreamAddress(platform: .youtube, identifier: "channel/\(body)", youtubeTarget: .channelID(body))
        }

        // Exact 11-char video ID (case-sensitive!)
        if isValidYouTubeVideoID(body) {
            return StreamAddress(platform: .youtube, identifier: body, youtubeTarget: .videoID(body))
        }

        // Otherwise treat `yt:<handle>` as a handle shorthand
        let handle = body.lowercased()
        guard isValidYouTubeHandle(handle) else { return nil }
        return StreamAddress(platform: .youtube, identifier: "@\(handle)", youtubeTarget: .handle(handle))
    }

    public static func isValidTwitchLogin(_ s: String) -> Bool {
        (3...25).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    public static func isValidKickSlug(_ s: String) -> Bool {
        (2...32).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    public static func isValidYouTubeVideoID(_ s: String) -> Bool {
        s.count == 11 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    public static func isValidYouTubeHandle(_ s: String) -> Bool {
        (2...30).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }
    }

    public static func isValidYouTubeChannelID(_ s: String) -> Bool {
        s.hasPrefix("UC") && (20...32).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

/// Normalized metadata returned by Kick / YouTube live resolvers (no account required).
public struct ExternalLiveStreamMetadata: Sendable, Equatable {
    public let platform: StreamPlatform
    public let canonicalKey: String
    public let displayName: String
    public let title: String
    public let category: String
    public let avatarURL: URL?
    public let thumbnailURL: URL?
    public let viewerCount: Int
    public let isLive: Bool
    public let kickChannelID: Int?
    public let kickUserID: Int?
    public let kickChatroomID: Int?
    public let kickSlug: String?
    public let youtubeVideoID: String?
    public let youtubeChannelID: String?
    public let youtubeChatContinuation: String?

    public init(
        platform: StreamPlatform,
        canonicalKey: String,
        displayName: String,
        title: String = "",
        category: String = "",
        avatarURL: URL? = nil,
        thumbnailURL: URL? = nil,
        viewerCount: Int = 0,
        isLive: Bool = true,
        kickChannelID: Int? = nil,
        kickUserID: Int? = nil,
        kickChatroomID: Int? = nil,
        kickSlug: String? = nil,
        youtubeVideoID: String? = nil,
        youtubeChannelID: String? = nil,
        youtubeChatContinuation: String? = nil
    ) {
        self.platform = platform
        self.canonicalKey = canonicalKey
        self.displayName = displayName
        self.title = title
        self.category = category
        self.avatarURL = avatarURL
        self.thumbnailURL = thumbnailURL
        self.viewerCount = viewerCount
        self.isLive = isLive
        self.kickChannelID = kickChannelID
        self.kickUserID = kickUserID
        self.kickChatroomID = kickChatroomID
        self.kickSlug = kickSlug
        self.youtubeVideoID = youtubeVideoID
        self.youtubeChannelID = youtubeChannelID
        self.youtubeChatContinuation = youtubeChatContinuation
    }

    /// Converts external live metadata into the shared `TwitchChannelInfo` model for uniform UI rendering.
    public var asChannelInfo: TwitchChannelInfo {
        TwitchChannelInfo(
            id: kickChannelID.map(String.init) ?? youtubeChannelID ?? canonicalKey,
            login: canonicalKey,
            displayName: displayName.isEmpty ? StreamAddress.displayLabel(for: canonicalKey) : displayName,
            avatar: avatarURL
        )
    }

    /// Converts external live metadata into `TwitchStreamInfo` when live.
    public var asStreamInfo: TwitchStreamInfo? {
        guard isLive else { return nil }
        return TwitchStreamInfo(
            userID: kickUserID.map(String.init) ?? youtubeChannelID ?? canonicalKey,
            login: canonicalKey,
            displayName: displayName.isEmpty ? StreamAddress.displayLabel(for: canonicalKey) : displayName,
            title: title,
            game: category.isEmpty ? platform.displayName : category,
            viewers: viewerCount,
            startedAt: nil,
            thumbnail: thumbnailURL
        )
    }
}

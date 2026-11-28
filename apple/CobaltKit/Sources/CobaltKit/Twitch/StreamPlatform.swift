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

    private static func parseURL(_ raw: String) -> StreamAddress? {
        // Avoid interpreting bare logins with dots or invalid hosts as URLs unless a known host matches.
        let candidateString: String
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            candidateString = raw
        } else if raw.contains("/") || raw.lowercased().contains(".tv") || raw.lowercased().contains(".com") || raw.lowercased().contains(".be") {
            candidateString = "https://\(raw)"
        } else {
            return nil
        }

        guard let comps = URLComponents(string: candidateString),
              let host = comps.host?.lowercased(),
              !host.isEmpty
        else { return nil }

        let pathParts = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        // Twitch URLs
        if host == "twitch.tv" || host.hasSuffix(".twitch.tv") {
            guard let first = pathParts.first?.lowercased(), isValidTwitchLogin(first) else { return nil }
            // Ignore non-channel top-level paths
            let reserved: Set<String> = ["directory", "videos", "downloads", "settings", "subscriptions", "inventory", "wallet", "search", "popout"]
            if reserved.contains(first) {
                if first == "popout", pathParts.count >= 2 {
                    let ch = pathParts[1].lowercased()
                    return isValidTwitchLogin(ch) ? StreamAddress(platform: .twitch, identifier: ch) : nil
                }
                return nil
            }
            return StreamAddress(platform: .twitch, identifier: first)
        }

        // Kick URLs
        if host == "kick.com" || host.hasSuffix(".kick.com") {
            guard let first = pathParts.first?.lowercased() else { return nil }
            let reserved: Set<String> = ["browse", "categories", "following", "search", "video", "clips", "popout"]
            if reserved.contains(first) {
                if first == "popout", pathParts.count >= 2 {
                    let slug = pathParts[1].lowercased()
                    return isValidKickSlug(slug) ? StreamAddress(platform: .kick, identifier: slug) : nil
                }
                return nil
            }
            guard isValidKickSlug(first) else { return nil }
            return StreamAddress(platform: .kick, identifier: first)
        }

        // YouTube short URLs (`youtu.be/<videoId>`)
        if host == "youtu.be" || host == "www.youtu.be" {
            guard let vid = pathParts.first, isValidYouTubeVideoID(vid) else { return nil }
            return StreamAddress(platform: .youtube, identifier: vid, youtubeTarget: .videoID(vid))
        }

        // YouTube standard/mobile/studio URLs
        if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") {
            // /watch?v=<videoId>
            if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, isValidYouTubeVideoID(v) {
                return StreamAddress(platform: .youtube, identifier: v, youtubeTarget: .videoID(v))
            }
            guard let first = pathParts.first else { return nil }
            let firstLower = first.lowercased()

            // /live/<videoId> or /embed/<videoId> or /shorts/<videoId>
            if (firstLower == "live" || firstLower == "embed" || firstLower == "shorts"),
               pathParts.count >= 2,
               isValidYouTubeVideoID(pathParts[1]) {
                let vid = pathParts[1]
                return StreamAddress(platform: .youtube, identifier: vid, youtubeTarget: .videoID(vid))
            }

            // /@handle or /@handle/live
            if first.hasPrefix("@") {
                let handle = String(first.dropFirst()).lowercased()
                guard isValidYouTubeHandle(handle) else { return nil }
                return StreamAddress(platform: .youtube, identifier: "@\(handle)", youtubeTarget: .handle(handle))
            }

            // /channel/UC... or /channel/UC.../live
            if firstLower == "channel", pathParts.count >= 2, isValidYouTubeChannelID(pathParts[1]) {
                let cid = pathParts[1]
                return StreamAddress(platform: .youtube, identifier: "channel/\(cid)", youtubeTarget: .channelID(cid))
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

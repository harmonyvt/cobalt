import Foundation

// Low-latency Twitch HLS resolution and M3U8 parsing (off-main, Swift 6 strict concurrency).
//
// Pipeline:
//   1. `POST https://gql.twitch.tv/gql` (`PlaybackAccessToken`, raw GraphQL query so persisted-hash rotations don't break it)
//      with optional `Authorization: OAuth <auth-token>` cookie from WebKit's shared store (falls back to anonymous).
//   2. `GET https://usher.ttvnw.net/api/channel/hls/<channel>.m3u8?fast_bread=true&supported_codecs=avc1...`
//      returns the master playlist with variants (`chunked`/source, 720p60, ..., `audio_only`).
//   3. Media playlists carry `#EXT-X-TWITCH-PREFETCH:<url>` lines for segments still being encoded on the edge,
//      plus `#EXT-X-DATERANGE` (`X-SERVER-TIME`) and `#EXT-X-PROGRAM-DATE-TIME` for live broadcaster delay.

public struct TwitchPlaybackToken: Sendable, Equatable {
    public let value: String
    public let signature: String

    public init(value: String, signature: String) {
        self.value = value
        self.signature = signature
    }
}

public struct TwitchVariant: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let bandwidth: Int
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?
    public let codecs: String
    public let url: URL

    public init(
        id: String, name: String, bandwidth: Int, width: Int?, height: Int?,
        frameRate: Double?, codecs: String, url: URL
    ) {
        self.id = id
        self.name = name
        self.bandwidth = bandwidth
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codecs = codecs
        self.url = url
    }

    public var isSource: Bool {
        id.lowercased() == "chunked" || name.localizedCaseInsensitiveContains("source")
    }

    public var isAudioOnly: Bool {
        let lower = id.lowercased()
        if lower == "audio_only" || name.lowercased() == "audio_only" { return true }
        return width == nil && height == nil && codecs.lowercased().hasPrefix("mp4a")
    }

    /// True when the native MPEG-TS H.264/AAC demuxer can decode this variant.
    public var isNativeCompatible: Bool {
        if isAudioOnly { return true }
        let lower = codecs.lowercased()
        if lower.isEmpty { return true }
        return lower.contains("avc1")
    }

    /// Compact label for menus and badges (`1080p60`, `720p60`, `audio`).
    public var shortLabel: String {
        if isAudioOnly { return "audio only" }
        if let h = height {
            if let fps = frameRate, fps >= 45 {
                let suffix = "\(h)p\(Int(fps.rounded()))"
                return isSource ? "\(suffix) · source" : suffix
            }
            return isSource ? "\(h)p · source" : "\(h)p"
        }
        return name.isEmpty ? id : name
    }
}

public struct TwitchSegment: Sendable, Equatable {
    public let sequence: Int
    public let url: URL
    public let duration: Double
    public let programDateTime: Date?
    public let isPrefetch: Bool
    public let isDiscontinuity: Bool
    public let isAd: Bool

    public init(
        sequence: Int, url: URL, duration: Double, programDateTime: Date?,
        isPrefetch: Bool, isDiscontinuity: Bool, isAd: Bool
    ) {
        self.sequence = sequence
        self.url = url
        self.duration = duration
        self.programDateTime = programDateTime
        self.isPrefetch = isPrefetch
        self.isDiscontinuity = isDiscontinuity
        self.isAd = isAd
    }

    /// Query-stripped path key so a segment re-signed with a different `?dna=...` still deduplicates cleanly.
    public var dedupKey: String {
        "\(url.host() ?? "")\(url.path())"
    }
}

public struct TwitchMediaPlaylist: Sendable, Equatable {
    public let targetDuration: Double
    public let mediaSequence: Int
    public let liveSequence: Int?
    public let serverTime: Date?
    public let isLowLatency: Bool
    public let isEndList: Bool
    public let segments: [TwitchSegment]
    public let prefetchSegments: [TwitchSegment]

    public init(
        targetDuration: Double, mediaSequence: Int, liveSequence: Int?, serverTime: Date?,
        isLowLatency: Bool, isEndList: Bool, segments: [TwitchSegment], prefetchSegments: [TwitchSegment]
    ) {
        self.targetDuration = targetDuration
        self.mediaSequence = mediaSequence
        self.liveSequence = liveSequence
        self.serverTime = serverTime
        self.isLowLatency = isLowLatency
        self.isEndList = isEndList
        self.segments = segments
        self.prefetchSegments = prefetchSegments
    }

    public var allSegments: [TwitchSegment] { segments + prefetchSegments }

    /// Average completed segment duration (seconds), falling back to 2.0 s.
    public var averageDuration: Double {
        let valid = segments.map(\.duration).filter { $0 > 0.1 && $0 < 15 }
        guard !valid.isEmpty else { return 2.0 }
        return valid.reduce(0, +) / Double(valid.count)
    }
}

public enum TwitchHLSError: Error, Sendable, Equatable {
    case invalidChannel
    case offline
    case integrityRequired
    case tokenFailed(String)
    case playlistFailed(Int)
    case noPlayableVariant
    case unsupportedCodec(String)
}

// MARK: - M3U8 parser

public enum TwitchHLSParser {
    /// Parses a Twitch Usher master playlist into ordered variants.
    public static func parseMaster(_ text: String, baseURL: URL? = nil) -> [TwitchVariant] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var mediaNames: [String: String] = [:]
        var pendingInf: [String: String]?
        var out: [TwitchVariant] = []
        var seenIDs: Set<String> = []

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                if let groupID = attrs["GROUP-ID"], let name = attrs["NAME"] {
                    mediaNames[groupID] = name
                }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingInf = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#") {
                continue
            } else if let attrs = pendingInf {
                pendingInf = nil
                guard let url = resolveURL(line, relativeTo: baseURL) else { continue }
                let bandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0
                let codecs = attrs["CODECS"] ?? ""
                let frameRate = Double(attrs["FRAME-RATE"] ?? "")
                let (w, h) = parseResolution(attrs["RESOLUTION"])
                let groupID = attrs["VIDEO"] ?? attrs["AUDIO"] ?? ""
                var id = groupID.isEmpty ? (h.map { "\($0)p" } ?? "stream_\(out.count)") : groupID
                if seenIDs.contains(id) { id = "\(id)_\(out.count)" }
                seenIDs.insert(id)
                let name = mediaNames[groupID] ?? id
                out.append(TwitchVariant(
                    id: id, name: name, bandwidth: bandwidth, width: w, height: h,
                    frameRate: frameRate, codecs: codecs, url: url
                ))
            }
        }
        return out
    }

    /// Parses a Twitch media playlist, including `#EXT-X-TWITCH-PREFETCH`, `X-SERVER-TIME`, ads and discontinuities.
    public static func parseMedia(_ text: String, baseURL: URL? = nil) -> TwitchMediaPlaylist {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var targetDuration: Double = 2.0
        var mediaSequence = 0
        var liveSequence: Int?
        var serverTime: Date?
        var hasFutureFlag = false
        var isEndList = false

        var segments: [TwitchSegment] = []
        var prefetchURLs: [URL] = []

        var pendingDuration: Double?
        var pendingTitle: String?
        var pendingPDT: Date?
        var pendingDiscontinuity = false
        var insideAdDateRange = false

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                if let v = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) { targetDuration = v }
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                if let v = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) { mediaSequence = v }
            } else if line.hasPrefix("#EXT-X-TWITCH-LIVE-SEQUENCE:") {
                liveSequence = Int(line.dropFirst("#EXT-X-TWITCH-LIVE-SEQUENCE:".count))
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                isEndList = true
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                pendingDiscontinuity = true
                insideAdDateRange = false
            } else if line.hasPrefix("#EXT-X-TWITCH-INFO:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-TWITCH-INFO:".count)))
                if let raw = attrs["SERVER-TIME"], let st = parseServerTime(raw) {
                    serverTime = st
                }
                if attrs["FUTURE"]?.lowercased() == "true" {
                    hasFutureFlag = true
                }
            } else if line.hasPrefix("#EXT-X-DATERANGE:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-DATERANGE:".count)))
                let cls = (attrs["CLASS"] ?? "").lowercased()
                if let raw = attrs["X-SERVER-TIME"], let st = parseServerTime(raw) {
                    serverTime = st
                } else if cls == "timestamp", let sd = attrs["START-DATE"].flatMap(parseISO8601) {
                    serverTime = sd
                }
                if cls.contains("stitched-ad") || cls.contains("maf-ad") || cls.contains("ad-quartz") {
                    insideAdDateRange = true
                } else if cls == "twitch-stream-source" {
                    let src = (attrs["X-TV-TWITCH-STREAM-SOURCE"] ?? "").lowercased()
                    if src == "live" { insideAdDateRange = false }
                }
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                pendingPDT = parseISO8601(String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count)))
            } else if line.hasPrefix("#EXTINF:") {
                let rest = line.dropFirst("#EXTINF:".count)
                if let comma = rest.firstIndex(of: ",") {
                    pendingDuration = Double(rest[..<comma].trimmingCharacters(in: .whitespaces))
                    pendingTitle = String(rest[rest.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    pendingDuration = Double(rest.trimmingCharacters(in: .whitespaces))
                    pendingTitle = nil
                }
            } else if line.hasPrefix("#EXT-X-TWITCH-PREFETCH:") {
                let raw = String(line.dropFirst("#EXT-X-TWITCH-PREFETCH:".count)).trimmingCharacters(in: .whitespaces)
                if let url = resolveURL(raw, relativeTo: baseURL) {
                    prefetchURLs.append(url)
                }
            } else if line.hasPrefix("#") {
                continue
            } else if let dur = pendingDuration {
                let title = pendingTitle ?? ""
                let seq = mediaSequence + segments.count
                let isAd = insideAdDateRange || isAdTitle(title)
                if let url = resolveURL(line, relativeTo: baseURL) {
                    segments.append(TwitchSegment(
                        sequence: seq,
                        url: url,
                        duration: dur,
                        programDateTime: pendingPDT,
                        isPrefetch: false,
                        isDiscontinuity: pendingDiscontinuity,
                        isAd: isAd
                    ))
                }
                pendingDuration = nil
                pendingTitle = nil
                pendingPDT = nil
                pendingDiscontinuity = false
            }
        }

        // Estimate duration and programDateTime for prefetch segments by continuing from the last completed segment.
        let validDurs = segments.map(\.duration).filter { $0 > 0.1 && $0 < 15 }
        let estDuration = validDurs.isEmpty ? 2.0 : (validDurs.reduce(0, +) / Double(validDurs.count))
        var nextPDT: Date? = segments.last.flatMap { seg in
            seg.programDateTime.map { $0.addingTimeInterval(seg.duration) }
        }
        var prefetchSegments: [TwitchSegment] = []
        let prefetchBaseSeq = mediaSequence + segments.count
        for (i, url) in prefetchURLs.enumerated() {
            prefetchSegments.append(TwitchSegment(
                sequence: prefetchBaseSeq + i,
                url: url,
                duration: estDuration,
                programDateTime: nextPDT,
                isPrefetch: true,
                isDiscontinuity: false,
                isAd: false
            ))
            nextPDT = nextPDT?.addingTimeInterval(estDuration)
        }

        let isLowLatency = !prefetchSegments.isEmpty || hasFutureFlag || liveSequence != nil
        return TwitchMediaPlaylist(
            targetDuration: targetDuration,
            mediaSequence: mediaSequence,
            liveSequence: liveSequence,
            serverTime: serverTime,
            isLowLatency: isLowLatency,
            isEndList: isEndList,
            segments: segments,
            prefetchSegments: prefetchSegments
        )
    }

    /// Splits an HLS attribute list (`KEY=VALUE,KEY2="A,B"`) without breaking inside quoted values.
    public static func parseAttributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var i = raw.startIndex
        while i < raw.endIndex {
            while i < raw.endIndex && (raw[i] == "," || raw[i] == " ") { i = raw.index(after: i) }
            let keyStart = i
            while i < raw.endIndex && raw[i] != "=" && raw[i] != "," { i = raw.index(after: i) }
            guard i < raw.endIndex && raw[i] == "=" else { break }
            let key = String(raw[keyStart..<i]).trimmingCharacters(in: .whitespaces)
            i = raw.index(after: i) // skip '='
            let value: String
            if i < raw.endIndex && raw[i] == "\"" {
                i = raw.index(after: i)
                let valStart = i
                while i < raw.endIndex && raw[i] != "\"" { i = raw.index(after: i) }
                value = String(raw[valStart..<i])
                if i < raw.endIndex { i = raw.index(after: i) } // skip closing '"'
                while i < raw.endIndex && raw[i] != "," { i = raw.index(after: i) }
            } else {
                let valStart = i
                while i < raw.endIndex && raw[i] != "," { i = raw.index(after: i) }
                value = String(raw[valStart..<i]).trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    public static func parseISO8601(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(s) { return d }
        return nil
    }

    private static func parseServerTime(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let epoch = Double(s), epoch > 1_000_000_000 {
            return Date(timeIntervalSince1970: epoch)
        }
        return parseISO8601(s)
    }

    private static func parseResolution(_ raw: String?) -> (Int?, Int?) {
        guard let raw, let x = raw.lowercased().firstIndex(of: "x") else { return (nil, nil) }
        return (Int(raw[..<x]), Int(raw[raw.index(after: x)...]))
    }

    private static func resolveURL(_ raw: String, relativeTo base: URL?) -> URL? {
        if let abs = URL(string: raw), abs.scheme != nil { return abs }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }

    private static func isAdTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        guard !lower.isEmpty, lower != "live" else { return false }
        return lower.contains("amazon") || lower.contains("stitched") || lower.contains("preroll") || lower.contains("midroll")
    }
}

// MARK: - GQL + Usher resolver

public actor TwitchStreamResolver {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Twitch's public web Client-ID (Helix developer IDs are rejected by gql.twitch.tv).
    public static let webClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private static let gqlURL = URL(string: "https://gql.twitch.tv/gql")!
    private static let tokenQuery = """
    query PlaybackAccessToken($login: String!, $playerType: String!, $platform: String!) { \
    streamPlaybackAccessToken(channelName: $login, params: {platform: $platform, playerBackend: "mediaplayer", playerType: $playerType}) { \
    value signature } }
    """

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

    /// Requests a live playback access token for `channel`. If an authenticated attempt with `authToken` fails
    /// (for example an expired cookie), retries anonymously so playback still works.
    public func fetchPlaybackToken(channel: String, authToken: String? = nil) async throws -> TwitchPlaybackToken {
        let clean = Self.sanitize(channel)
        guard !clean.isEmpty else { throw TwitchHLSError.invalidChannel }
        if let auth = authToken?.trimmingCharacters(in: .whitespacesAndNewlines), !auth.isEmpty {
            do {
                return try await requestToken(channel: clean, authToken: auth)
            } catch TwitchHLSError.offline {
                throw TwitchHLSError.offline
            } catch {
                // Retry anonymously if the signed-in cookie was rejected or expired.
            }
        }
        return try await requestToken(channel: clean, authToken: nil)
    }

    /// Fetches and parses the Usher master playlist with `fast_bread=true` (Twitch low-latency HLS).
    public func fetchMasterPlaylist(channel: String, token: TwitchPlaybackToken) async throws -> [TwitchVariant] {
        let clean = Self.sanitize(channel)
        guard !clean.isEmpty else { throw TwitchHLSError.invalidChannel }
        var comps = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(clean).m3u8")!
        let nonce = Int.random(in: 100_000...9_999_999)
        comps.queryItems = [
            URLQueryItem(name: "allow_source", value: "true"),
            URLQueryItem(name: "allow_audio_only", value: "true"),
            URLQueryItem(name: "fast_bread", value: "true"),
            URLQueryItem(name: "p", value: "\(nonce)"),
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "player_backend", value: "mediaplayer"),
            URLQueryItem(name: "playlist_include_framerate", value: "true"),
            URLQueryItem(name: "reassignments_supported", value: "true"),
            URLQueryItem(name: "sig", value: token.signature),
            URLQueryItem(name: "supported_codecs", value: "avc1"),
            URLQueryItem(name: "token", value: token.value),
        ]
        guard let url = comps.url else { throw TwitchHLSError.invalidChannel }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("application/vnd.apple.mpegurl, */*", forHTTPHeaderField: "Accept")
        let (data, http) = try await fetch(req)
        if http.statusCode == 404 { throw TwitchHLSError.offline }
        guard (200..<300).contains(http.statusCode), let text = String(data: data, encoding: .utf8) else {
            throw TwitchHLSError.playlistFailed(http.statusCode)
        }
        let variants = TwitchHLSParser.parseMaster(text, baseURL: url)
        guard !variants.isEmpty else { throw TwitchHLSError.noPlayableVariant }
        return variants
    }

    /// Fetches and parses a live variant media playlist.
    public func fetchMediaPlaylist(url: URL) async throws -> TwitchMediaPlaylist {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, http) = try await fetch(req)
        if http.statusCode == 404 { throw TwitchHLSError.offline }
        guard (200..<300).contains(http.statusCode), let text = String(data: data, encoding: .utf8) else {
            throw TwitchHLSError.playlistFailed(http.statusCode)
        }
        return TwitchHLSParser.parseMedia(text, baseURL: url)
    }

    /// Resolves `channel` to Usher variants (token + master playlist).
    public func resolve(channel: String, authToken: String? = nil) async throws -> [TwitchVariant] {
        let token = try await fetchPlaybackToken(channel: channel, authToken: authToken)
        return try await fetchMasterPlaylist(channel: channel, token: token)
    }

    public static func sanitize(_ channel: String) -> String {
        channel.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private func requestToken(channel: String, authToken: String?) async throws -> TwitchPlaybackToken {
        let payload = GQLRequest(
            operationName: "PlaybackAccessToken",
            query: Self.tokenQuery,
            variables: .init(login: channel, playerType: "embed", platform: "web")
        )
        var req = URLRequest(url: Self.gqlURL, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.webClientID, forHTTPHeaderField: "Client-ID")
        if let authToken {
            req.setValue("OAuth \(authToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, http) = try await fetch(req)
        guard (200..<300).contains(http.statusCode) else {
            throw TwitchHLSError.tokenFailed("http \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(GQLResponse.self, from: data)
        if let errors = decoded.errors, !errors.isEmpty {
            let msg = errors.compactMap(\.message).joined(separator: "; ")
            if msg.localizedCaseInsensitiveContains("integrity") {
                throw TwitchHLSError.integrityRequired
            }
            if decoded.data?.streamPlaybackAccessToken == nil {
                throw TwitchHLSError.tokenFailed(msg)
            }
        }
        guard let tok = decoded.data?.streamPlaybackAccessToken, !tok.value.isEmpty, !tok.signature.isEmpty else {
            throw TwitchHLSError.offline
        }
        return TwitchPlaybackToken(value: tok.value, signature: tok.signature)
    }

    private struct GQLRequest: Encodable {
        let operationName: String
        let query: String
        let variables: Variables
        struct Variables: Encodable {
            let login: String
            let playerType: String
            let platform: String
        }
    }

    private struct GQLResponse: Decodable {
        let data: Payload?
        let errors: [GQLError]?
        struct Payload: Decodable {
            let streamPlaybackAccessToken: RawToken?
        }
        struct RawToken: Decodable {
            let value: String
            let signature: String
        }
        struct GQLError: Decodable {
            let message: String?
        }
    }
}

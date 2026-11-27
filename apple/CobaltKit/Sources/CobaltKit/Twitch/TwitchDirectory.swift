import Foundation

/// `GET /stage/twitch/session` (APP-API-CONTRACT 70): the studio's Twitch connection, with a fresh token, for the twitch
/// tab. `connected` false: the studio has no Twitch account; `reconnect`: it must be connected again in studio.
public struct TwitchSession: Sendable, Equatable, Decodable {
    public var connected: Bool
    public var clientId: String?
    public var userId: String?
    public var login: String?
    public var displayName: String?
    public var accessToken: String?
    public var expiresAt: Date?
    public var scopes: [String]?
    public var canChat: Bool?
    public var reconnect: Bool?

    public init(
        connected: Bool, clientId: String? = nil, userId: String? = nil, login: String? = nil, displayName: String? = nil,
        accessToken: String? = nil, expiresAt: Date? = nil, scopes: [String]? = nil, canChat: Bool? = nil, reconnect: Bool? = nil
    ) {
        self.connected = connected
        self.clientId = clientId
        self.userId = userId
        self.login = login
        self.displayName = displayName
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.canChat = canChat
        self.reconnect = reconnect
    }

    /// Chat and Helix credentials, when the answer has a usable token.
    public var credentials: TwitchCredentials? {
        guard connected, reconnect != true, let clientId, let userId, let login, let accessToken, !accessToken.isEmpty else { return nil }
        return TwitchCredentials(login: login, userID: userId, clientID: clientId, token: accessToken, canChat: canChat == true)
    }

    /// The token can make clips.
    public var canClip: Bool { scopes?.contains("clips:edit") == true }
}

/// The route, kept apart from `CobaltClient` like `SevenTvClient`, so no existing fake has to change. `HTTPCobaltClient`
/// conforms; any other client reads as "no session" (anonymous, read-only chat).
public protocol TwitchSessionClient: Sendable {
    func twitchSession() async throws -> TwitchSession
}

extension HTTPCobaltClient: TwitchSessionClient {
    public func twitchSession() async throws -> TwitchSession {
        let req = try makeRequest("GET", "/stage/twitch/session", keyed: true, timeout: 20)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw apiError(data, status: http.statusCode) }
        guard let session = try? CobaltJSON.decoder().decode(TwitchSession.self, from: data) else {
            throw CobaltError.invalidResponse(httpStatus: http.statusCode)
        }
        return session
    }
}

/// A live stream (Helix `streams`).
public struct TwitchStreamInfo: Sendable, Equatable, Identifiable {
    public var id: String { login }
    public var userID: String
    public var login: String
    public var displayName: String
    public var title: String
    public var game: String
    public var viewers: Int
    public var startedAt: Date?
    /// A 440x248 still of the stream.
    public var thumbnail: URL?
}

/// A channel (Helix `users`).
public struct TwitchChannelInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var login: String
    public var displayName: String
    public var avatar: URL?
}

/// Helix calls as the signed-in user (APP-API-CONTRACT 70): the followed channels that are live, a channel's profile and
/// live state, and making a clip. JSON is decoded here, off main.
public actor TwitchDirectory {
    private let credentials: TwitchCredentials
    private let session: URLSession

    public init(credentials: TwitchCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    /// The channels the user follows that are live now, most viewers first (`user:read:follows`).
    public func followedLive() async -> [TwitchStreamInfo] {
        let page: HelixWire.Page<HelixWire.Stream>? = await helix("streams/followed", query: [("user_id", credentials.userID), ("first", "100")])
        return (page?.data ?? []).map(Self.stream).sorted { $0.viewers > $1.viewers }
    }

    /// The channel's live stream, nil when it is offline.
    public func stream(login: String) async -> TwitchStreamInfo? {
        let page: HelixWire.Page<HelixWire.Stream>? = await helix("streams", query: [("user_login", login.lowercased())])
        return page?.data?.first.map(Self.stream)
    }

    public func channel(login: String) async -> TwitchChannelInfo? {
        let page: HelixWire.Page<HelixWire.User>? = await helix("users", query: [("login", login.lowercased())])
        guard let u = page?.data?.first else { return nil }
        return TwitchChannelInfo(
            id: u.id, login: u.login, displayName: u.displayName ?? u.login, avatar: u.profileImageUrl.flatMap(URL.init(string:)))
    }

    /// Makes a clip of the last seconds of `broadcasterID`'s stream (`clips:edit`) and waits until Twitch has it (up to
    /// about 20 s). The clip's page, ready to save; nil when Twitch refused or it never appeared.
    public func makeClip(broadcasterID: String) async -> URL? {
        MainThreadGuard.assertOffMain()
        guard var comps = URLComponents(url: HelixWire.base.appendingPathComponent("clips"), resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = [URLQueryItem(name: "broadcaster_id", value: broadcasterID)]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        authorize(&req)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 202 || http.statusCode == 200,
              let page = try? HelixWire.decoder().decode(HelixWire.Page<HelixWire.Clip>.self, from: data),
              let clip = page.data?.first
        else { return nil }
        // Twitch takes a few seconds to cut it: GET /clips answers it once it exists
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(2))
            let found: HelixWire.Page<HelixWire.Clip>? = await helix("clips", query: [("id", clip.id)])
            if found?.data?.isEmpty == false { return URL(string: "https://clips.twitch.tv/\(clip.id)") }
        }
        return nil
    }

    private static func stream(_ s: HelixWire.Stream) -> TwitchStreamInfo {
        let thumb = s.thumbnailUrl?
            .replacingOccurrences(of: "{width}", with: "440")
            .replacingOccurrences(of: "{height}", with: "248")
        return TwitchStreamInfo(
            userID: s.userId, login: s.userLogin, displayName: s.userName ?? s.userLogin, title: s.title ?? "",
            game: s.gameName ?? "", viewers: s.viewerCount ?? 0,
            startedAt: s.startedAt.flatMap {
                (try? Date($0, strategy: .iso8601))
                    ?? (try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            },
            thumbnail: thumb.flatMap(URL.init(string:)))
    }

    private func authorize(_ req: inout URLRequest) {
        req.setValue(credentials.clientID, forHTTPHeaderField: "Client-Id")
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
    }

    private func helix<T: Decodable>(_ path: String, query: [(String, String)]) async -> T? {
        MainThreadGuard.assertOffMain()
        guard var comps = URLComponents(url: HelixWire.base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        authorize(&req)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? HelixWire.decoder().decode(T.self, from: data)
    }
}

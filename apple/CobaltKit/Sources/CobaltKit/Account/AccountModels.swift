import Foundation

// Accounts (APP-API-CONTRACT 42): the owner signs in through Cloudflare Access and each device keeps its own session, a
// token with the exact shape of a client key. These are the shapes of the 42.5 routes (`/auth/*` on the API host).

/// One signed-in device (`<session>` in 42.5).
public struct AccountSession: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    /// "harmony's iphone", "safari on mac".
    public var device: String
    /// `ios`, `ipados`, `mac` or `web` (anything else reads as `web`).
    public var platform: String
    public var createdAt: Date
    public var lastUsedAt: Date?
    /// Slides to 90 days after the last use.
    public var expiresAt: Date?
    /// `cf.country` of the last use ("AU"), when known.
    public var country: String?
    /// This is the session the request was made with.
    public var current: Bool

    public init(
        id: String, device: String, platform: String, createdAt: Date, lastUsedAt: Date? = nil, expiresAt: Date? = nil,
        country: String? = nil, current: Bool = false
    ) {
        self.id = id
        self.device = device
        self.platform = platform
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
        self.country = country
        self.current = current
    }

    public var kind: AccountPlatform { AccountPlatform(rawValue: platform) ?? .web }

    private enum CodingKeys: String, CodingKey {
        case id, device, platform, createdAt, lastUsedAt, expiresAt, country, current
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? AccountPlatform.web.rawValue
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        current = try c.decodeIfPresent(Bool.self, forKey: .current) ?? false
    }
}

/// Where a session was signed in.
public enum AccountPlatform: String, Sendable, Equatable, CaseIterable {
    case ios, ipados, mac, web
}

/// One key for tools (`<key>` in 42.5): the client keys made on the web, and the keys pasted into apps before accounts.
public struct AccountKey: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    public var name: String
    /// The token's first 8 characters.
    public var prefix: String
    public var createdAt: Date
    public var lastUsedAt: Date?
    /// A key that was pasted into an app which has since signed in (`replaced_by` set): safe to revoke.
    public var oldPaste: Bool

    public init(id: String, name: String, prefix: String, createdAt: Date, lastUsedAt: Date? = nil, oldPaste: Bool = false) {
        self.id = id
        self.name = name
        self.prefix = prefix
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.oldPaste = oldPaste
    }

    private enum CodingKeys: String, CodingKey { case id, name, prefix, createdAt, lastUsedAt, oldPaste }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        oldPaste = try c.decodeIfPresent(Bool.self, forKey: .oldPaste) ?? false
    }
}

/// `POST /auth/keys` (APP-API-CONTRACT 50): the new key, in this answer only, and its row.
public struct AccountKeyCreated: Sendable, Equatable {
    /// The whole key: shown once, never stored by the app or the server.
    public var key: String
    public var item: AccountKey

    public init(key: String, item: AccountKey) {
        self.key = key
        self.item = item
    }

    static func decode(_ data: Data) throws -> AccountKeyCreated {
        struct Wire: Decodable { var key: String; var item: AccountKey }
        let w = try CobaltJSON.decoder().decode(Wire.self, from: data)
        return AccountKeyCreated(key: w.key, item: w.item)
    }
}

/// `GET /auth/me`: who made the request, and how many sessions and keys are live.
public struct AccountMe: Sendable, Equatable, Decodable {
    public struct Caller: Sendable, Equatable, Decodable {
        public enum Kind: String, Sendable, Equatable, Decodable { case key, session }
        public var kind: Kind
        public var id: String
        public var device: String?
        public var platform: String?
        /// The Access email that signed this session in (sessions only).
        public var email: String?
        public var expiresAt: Date?

        public init(kind: Kind, id: String, device: String? = nil, platform: String? = nil, email: String? = nil, expiresAt: Date? = nil) {
            self.kind = kind
            self.id = id
            self.device = device
            self.platform = platform
            self.email = email
            self.expiresAt = expiresAt
        }
    }

    public var caller: Caller
    public var sessions: Int
    public var keys: Int

    public init(caller: Caller, sessions: Int, keys: Int) {
        self.caller = caller
        self.sessions = sessions
        self.keys = keys
    }

    private enum CodingKeys: String, CodingKey { case caller, sessions, keys }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caller = try c.decode(Caller.self, forKey: .caller)
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        keys = try c.decodeIfPresent(Int.self, forKey: .keys) ?? 0
    }
}

/// `POST /auth/exchange` (42.3): the device's new token and its session.
public struct AuthExchange: Sendable, Equatable, Decodable {
    public var key: String
    public var session: AccountSession?

    public init(key: String, session: AccountSession?) {
        self.key = key
        self.session = session
    }
}

/// Why signing in, or an account change, did not happen. Copy maps each to its line.
public enum AccountError: Error, Sendable, Equatable {
    /// The owner closed the Access sheet.
    case cancelled
    /// The sheet came back without a usable `cobalt-apple://signed-in?code=…`.
    case badCallback
    /// `400 error.api.auth.code.invalid`: the one-time code was used, ran out (2 minutes) or does not match.
    case codeInvalid
    /// The token came back but this device would not keep it (keychain refused).
    case couldNotSave
    /// `404`: the session or key is already gone.
    case notFound
    /// `409 error.api.auth.key.too_many`: 50 keys for tools are live already.
    case tooManyKeys
    /// `400 error.api.auth.key.name_invalid`: empty, longer than 40 characters, or more than one line.
    case badName
    /// `403 error.api.auth.session_required`: only a signed-in device makes or renames keys, not one on a pasted key.
    case needsSession
    /// No network.
    case offline
    /// Anything else (a 5xx, an answer that did not decode).
    case failed

    /// What a client error means here (an `AccountError` stays itself).
    public static func from(_ error: Error) -> AccountError {
        if let own = error as? AccountError { return own }
        switch error as? CobaltError {
        case .api(let code, _)? where code == "error.api.auth.code.invalid": return .codeInvalid
        case .api(let code, _)? where code == "error.api.auth.session.not_found": return .notFound
        case .api(let code, _)? where code == "error.api.auth.key.too_many": return .tooManyKeys
        case .api(let code, _)? where code == "error.api.auth.key.name_invalid": return .badName
        case .api(let code, _)? where code == "error.api.auth.session_required": return .needsSession
        case .network?: return .offline
        case .cancelled?: return .cancelled
        default: return .failed
        }
    }
}

extension AccountSession {
    static func decodeList(_ data: Data) throws -> [AccountSession] {
        struct Wire: Decodable { var sessions: [Lossy<AccountSession>]? }
        return (try CobaltJSON.decoder().decode(Wire.self, from: data).sessions ?? []).compactMap(\.value)
    }
}

extension AccountKey {
    /// `{ "item": <key> }` (`PATCH /auth/keys/<id>`).
    static func decodeItem(_ data: Data) throws -> AccountKey {
        struct Wire: Decodable { var item: AccountKey }
        return try CobaltJSON.decoder().decode(Wire.self, from: data).item
    }

    static func decodeList(_ data: Data) throws -> [AccountKey] {
        struct Wire: Decodable { var keys: [Lossy<AccountKey>]? }
        return (try CobaltJSON.decoder().decode(Wire.self, from: data).keys ?? []).compactMap(\.value)
    }
}

extension AccountMe {
    static func decode(_ data: Data) throws -> AccountMe { try CobaltJSON.decoder().decode(AccountMe.self, from: data) }
}

extension AuthExchange {
    static func decode(_ data: Data) throws -> AuthExchange { try CobaltJSON.decoder().decode(AuthExchange.self, from: data) }
}

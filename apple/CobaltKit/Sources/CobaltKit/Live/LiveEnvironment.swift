import Foundation

/// Which APNs host this build's Live Activity tokens belong to (CONTRACT-LIVE.md 2.2, decision 6).
public enum LiveEnvironment: String, Sendable, Codable {
    case sandbox, production

    /// From the embedded provisioning profile's `Entitlements.aps-environment` ("development" →
    /// sandbox, "production" → production); a device build with no profile (TestFlight, App Store)
    /// → production; the simulator, an unsigned build or the Mac → nil (no push).
    public static var current: LiveEnvironment? { detected }

    private static let detected: LiveEnvironment? = {
        #if os(iOS) && !targetEnvironment(simulator)
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return .production
        }
        return environment(fromProvisioning: try? Data(contentsOf: url))
        #else
        return nil
        #endif
    }()

    /// `embedded.mobileprovision` is a CMS envelope around an XML property list: find the plist
    /// inside the bytes and read `Entitlements.aps-environment`. Nil when the profile cannot be
    /// read or grants no push.
    static func environment(fromProvisioning data: Data?) -> LiveEnvironment? {
        guard let data,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String
        else { return nil }
        switch value {
        case "development": return .sandbox
        case "production": return .production
        default: return nil
        }
    }
}

/// For the Settings row.
public enum LiveStatus: Sendable, Equatable {
    case pushed        // the server keeps the island current while the app is closed
    case localOnly     // updates only while cobalt is open (no push from this server or build)
    case off           // turned off in ios settings (ActivityAuthorizationInfo)
    case unavailable   // macOS, or a device without Live Activities
}

/// The client's side of one run, as `PUT /live/runs/<run>` takes it (APP-API-CONTRACT.md 8.2).
public struct LiveRunRegistration: Sendable, Equatable {
    public var run: UUID
    public var environment: LiveEnvironment
    public var updateToken: String?      // lowercase hex
    public var session: String?
    public var start: Bool               // true: the server push-starts the activity (share sheet)
    public var attributes: LiveRunAttributes
    public var state: LiveContentState

    public init(
        run: UUID, environment: LiveEnvironment, updateToken: String?, session: String?, start: Bool,
        attributes: LiveRunAttributes, state: LiveContentState
    ) {
        self.run = run
        self.environment = environment
        self.updateToken = updateToken
        self.session = session
        self.start = start
        self.attributes = attributes
        self.state = state
    }
}

public struct LiveRunReply: Sendable, Equatable {
    public var pushing: Bool
    public var started: Bool
    /// Why a start did not happen, when the server says: `no_start_token`, `not_configured`,
    /// `start_unconfirmed` (never ask again), `start_rate_limited` (ask again later). Additive.
    public var reason: String?

    public init(pushing: Bool, started: Bool, reason: String? = nil) {
        self.pushing = pushing
        self.started = started
        self.reason = reason
    }
}

/// `GET /live/selftest`: the owner's live check that the server can reach APNs (APP-API-CONTRACT.md
/// 8.6). `BadDeviceToken` is the healthy answer: HTTP/2, the JWT and the topic all worked.
public struct LiveSelftest: Sendable, Equatable {
    public var configured: Bool
    public var transport: String?
    public var host: String?
    public var jwt: String?
    public var apnsStatus: Int?
    public var apnsReason: String?

    public var isHealthy: Bool { configured && apnsReason == "BadDeviceToken" }

    public init(
        configured: Bool, transport: String? = nil, host: String? = nil, jwt: String? = nil,
        apnsStatus: Int? = nil, apnsReason: String? = nil
    ) {
        self.configured = configured
        self.transport = transport
        self.host = host
        self.jwt = jwt
        self.apnsStatus = apnsStatus
        self.apnsReason = apnsReason
    }
}

extension LiveRunRegistration {
    /// The `PUT /live/runs/<run>` body: snake_case outside; `attributes` and `state` keep the Swift
    /// property names because the server forwards them to APNs verbatim. `update_token` and
    /// `session` are written as explicit nulls when unknown.
    func requestBody() throws -> Data {
        struct Body: Encodable {
            var environment: String
            var updateToken: String?
            var session: String?
            var start: Bool
            var attributes: LiveRunAttributes
            var state: LiveContentState

            enum CodingKeys: String, CodingKey {
                case environment, session, start, attributes, state
                case updateToken = "update_token"
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(environment, forKey: .environment)
                try c.encode(updateToken, forKey: .updateToken)
                try c.encode(session, forKey: .session)
                try c.encode(start, forKey: .start)
                try c.encode(attributes, forKey: .attributes)
                try c.encode(state, forKey: .state)
            }
        }
        return try JSONEncoder().encode(Body(
            environment: environment.rawValue, updateToken: updateToken, session: session, start: start,
            attributes: attributes, state: state))
    }
}

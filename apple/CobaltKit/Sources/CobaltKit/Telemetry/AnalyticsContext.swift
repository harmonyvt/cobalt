import Foundation
import Synchronization

/// What the app's own API requests say about who sent them (APP-API-CONTRACT 58), so the server's PostHog events land
/// inside the app's session replay:
///  - `x-capy-client`: `ios` or `macos`, always (the server tells the app's calls from a tool's).
///  - `x-capy-install` and `x-capy-session`: only while the app's PostHog SDK runs (the app sets `sessionID`); the install
///    id is telemetry's own (`TelemetryInstall`), the session id the SDK's current one.
/// CobaltKit never imports PostHog: the app target owns the SDK and hands in the session id here.
public enum AnalyticsContext {
    public static let clientHeader = "x-capy-client"
    public static let installHeader = "x-capy-install"
    public static let sessionHeader = "x-capy-session"

    private static let provider = Mutex<(@Sendable () -> String?)?>(nil)

    /// Set by the app when its SDK starts (and to nil when it stops). Called on every request: keep it cheap.
    public static func setSessionProvider(_ f: (@Sendable () -> String?)?) {
        provider.withLock { $0 = f }
    }

    public static var client: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }

    /// The headers for one request to the app's own server.
    public static func headers(install: () -> String = { TelemetryInstall.id() }) -> [(String, String)] {
        var out = [(clientHeader, client)]
        guard let f = provider.withLock({ $0 }) else { return out }
        out.append((installHeader, install()))
        if let session = f(), UUID(uuidString: session) != nil { out.append((sessionHeader, session.lowercased())) }
        return out
    }
}

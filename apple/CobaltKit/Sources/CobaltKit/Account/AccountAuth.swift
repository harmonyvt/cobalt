import CryptoKit
import Foundation
import Security
import Synchronization
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import SystemConfiguration
#endif

// Signing an app in (APP-API-CONTRACT 42.3): a PKCE pair, Cloudflare Access in a web sheet, a one-time code back on
// `cobalt-apple://signed-in?code=…`, then `POST /auth/exchange` for the device's token.

/// The pieces of 42.3 that are pure: the verifier and its challenge, the page the sheet opens, the code it returns.
public enum AccountAuth {
    /// The web app behind Cloudflare Access; its Worker mints the one-time code.
    public static let webBase = URL(string: "https://cobalt.capybaraharmony.com")!
    /// The sheet ends on this scheme (the app's own; the server's redirect is fixed to it).
    public static let callbackScheme = "cobalt-apple"
    static let callbackHost = "signed-in"

    /// 32 random bytes, base64url without padding (43 characters).
    public static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()               // arc4random: also a CSPRNG on Apple platforms
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
        }
        return base64url(Data(bytes))
    }

    /// PKCE S256: base64url(SHA-256(verifier)), no padding.
    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `https://cobalt.capybaraharmony.com/api/auth/app?platform=…&device=…&challenge=…`, every value percent-encoded
    /// (a `+` in a device name too, so the server never reads it as a space).
    public static func startURL(base: URL = webBase, platform: String, device: String, challenge: String) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let path = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.percentEncodedPath = path + "/api/auth/app"
        comps.percentEncodedQuery = [("platform", platform), ("device", device), ("challenge", challenge)]
            .map { "\($0.0)=\(encode($0.1))" }
            .joined(separator: "&")
        return comps.url
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?/'")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// The one-time code from `cobalt-apple://signed-in?code=<base64url>`; nil for any other URL.
    public static func code(from url: URL) -> String? {
        guard url.scheme?.lowercased() == callbackScheme,
              url.host(percentEncoded: false)?.lowercased() == callbackHost,
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value,
              (16...128).contains(code.count),
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return code
    }

    /// Whether a link that reached the app is the sign-in's return (the sheet normally keeps it; never navigate on it).
    public static func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == callbackScheme && url.host(percentEncoded: false)?.lowercased() == callbackHost
    }
}

/// What the server is told about this device: `platform` from the contract's list and a name the owner recognises.
public struct AccountDevice: Sendable, Equatable {
    /// `ios`, `ipados` or `mac`.
    public var platform: String
    /// The device's own name when the system shares it ("harmony's mac studio"), else "iphone" / "ipad" / "mac";
    /// lowercase, printable, at most 40 UTF-16 units (the server's limit).
    public var name: String

    public init(platform: String, name: String) {
        self.platform = platform
        self.name = name
    }

    @MainActor public static var current: AccountDevice {
        #if os(macOS)
        let raw = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return AccountDevice(platform: AccountPlatform.mac.rawValue, name: clean(raw, fallback: "mac"))
        #elseif canImport(UIKit)
        let device = UIDevice.current
        let pad = device.userInterfaceIdiom == .pad
        let fallback = pad ? "ipad" : "iphone"
        // since iOS 16 `name` is the model ("iPhone") unless the app has the user-assigned-name entitlement
        let named = device.name.caseInsensitiveCompare(device.model) == .orderedSame ? nil : device.name
        return AccountDevice(platform: (pad ? AccountPlatform.ipados : .ios).rawValue, name: clean(named, fallback: fallback))
        #else
        return AccountDevice(platform: AccountPlatform.ios.rawValue, name: "iphone")
        #endif
    }

    /// Lowercased, control characters and surrounding spaces dropped, cut to 40 UTF-16 units; `fallback` when nothing is left.
    static func clean(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        let scalars = raw.lowercased().unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        while text.utf16.count > 40 { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }
}

/// The web sheet that runs Cloudflare Access: opens `url` and answers the URL it ended on (`callbackScheme`). The app
/// passes one wrapping SwiftUI's `WebAuthenticationSession` (not ephemeral, so Access's cookie is reused next time);
/// previews and tests pass `PreviewWebSignIn`. Closing the sheet throws `AccountError.cancelled`.
@MainActor
public protocol WebSignIn {
    func open(_ url: URL, callbackScheme: String) async throws -> URL
}

/// A sheet that "signs in" after a moment without any network: previews and tests.
@MainActor
public struct PreviewWebSignIn: WebSignIn {
    public enum Outcome: Sendable, Equatable {
        case signedIn
        /// The owner closes the sheet.
        case cancelled
        /// The sheet returns a link with no code.
        case broken
    }

    public var outcome: Outcome
    public var seconds: Double

    public init(outcome: Outcome = .signedIn, seconds: Double = 1.2) {
        self.outcome = outcome
        self.seconds = seconds
    }

    public func open(_ url: URL, callbackScheme: String) async throws -> URL {
        PreviewWebSignIn.log.withLock { $0.append(url) }
        if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
        switch outcome {
        case .signedIn: return URL(string: "\(callbackScheme)://signed-in?code=PrEvIeW-c0de_0123456789abcdefghijklmnopqr")!
        case .cancelled: throw AccountError.cancelled
        case .broken: return URL(string: "\(callbackScheme)://signed-in")!
        }
    }

    /// The URLs every preview sheet opened in this process (tests read the last one).
    nonisolated static let log = Mutex<[URL]>([])
}

/// A keyed request answered `401 error.api.auth.key.invalid` (an ended session, a revoked key). The real client raises it
/// from any route; the app listens (`AppModel.live`) and re-reads `/capabilities`, which puts it in the signed-out state.
/// Nothing listens in the extensions, previews or tests.
enum AuthSignal {
    private static let handler = Mutex<(@Sendable () -> Void)?>(nil)

    static func install(_ handler: (@Sendable () -> Void)?) {
        self.handler.withLock { $0 = handler }
    }

    static func keyRejected() {
        let current = handler.withLock { $0 }
        current?()
    }
}

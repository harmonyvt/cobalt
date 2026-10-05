import Foundation
import Observation

/// App group plumbing with the fallbacks section 4.6 pins: no container → this process's
/// Application Support; no suite → `.standard`. macOS has no extension, so it never touches the
/// group container (which would trigger the "access data from other apps" prompt).
enum AppGroup {
    static let id = "group.com.capybaraharmony.cobalt"

    static func containerURL() -> URL? {
        #if os(macOS)
        return nil
        #else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
        #endif
    }

    static func defaults() -> UserDefaults {
        #if os(macOS)
        return .standard
        #else
        return UserDefaults(suiteName: id) ?? .standard
        #endif
    }

    /// `<app group container>/<name>`, else `Application Support/<name>`; created on demand.
    static func directory(_ name: String) -> URL {
        let fm = FileManager.default
        let base = containerURL()
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

public enum KeyInputError: Error, Sendable {
    case notAKey         // not a lowercase UUID after trimming
    case couldNotSave    // a valid key this device would not store (keychain refused): never "not a key"
}
public enum ServerInputError: Error, Sendable { case notAURL }

@MainActor @Observable
public final class Settings {
    nonisolated public static let defaultServer = URL(string: "https://api.capybaraharmony.com")!

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let keychain: Keychain
    nonisolated static let keyAccount = "api-key"
    /// The server the stored key was pasted for ("host" or "host:port"). A key with no record here
    /// (saved by an earlier build) belongs to `defaultServer`: that is the only server it was ever
    /// minted for.
    nonisolated static let keyHostAccount = "api-key-host"

    public private(set) var serverURL: URL
    /// A key is stored AND it belongs to the current server. After pasting another cobalt's address
    /// this is false: the owner's key is never sent there (it stays stored, and counts again when
    /// the original server is set back; `clearAPIKey()` forgets it).
    public private(set) var hasAPIKey: Bool

    public init(defaults: UserDefaults, keychain: Keychain) {
        self.defaults = defaults
        self.keychain = keychain
        let server = defaults.string(forKey: "serverURL").flatMap(URL.init(string:)) ?? Settings.defaultServer
        self.serverURL = server
        self.hasAPIKey = Settings.apiKey(in: keychain, forServer: server) != nil
    }

    private static var sharedInstance: Settings?

    /// App-group defaults and the shared keychain.
    public static func shared() -> Settings {
        if let s = sharedInstance { return s }
        let s = Settings(defaults: AppGroup.defaults(), keychain: .shared)
        sharedInstance = s
        return s
    }

    // MARK: stored preferences (UserDefaults-backed, observable)

    public var webpQuality: WebpQuality {
        get {
            access(keyPath: \.webpQuality)
            return defaults.string(forKey: "webpQuality").flatMap(WebpQuality.init(rawValue:)) ?? .med
        }
        set { withMutation(keyPath: \.webpQuality) { defaults.set(newValue.rawValue, forKey: "webpQuality") } }
    }

    public var webpWidth: Int {
        get {
            access(keyPath: \.webpWidth)
            let w = defaults.integer(forKey: "webpWidth")
            return w > 0 ? w : 480
        }
        set { withMutation(keyPath: \.webpWidth) { defaults.set(newValue, forKey: "webpWidth") } }
    }

    public var keepVideosOnDevice: Bool {
        get {
            access(keyPath: \.keepVideosOnDevice)
            return defaults.object(forKey: "keepVideosOnDevice") as? Bool ?? true
        }
        set { withMutation(keyPath: \.keepVideosOnDevice) { defaults.set(newValue, forKey: "keepVideosOnDevice") } }
    }

    /// How much the device keeps offline; .gb5 by default. Stored in the app-group defaults, where
    /// `OfflineStore` re-reads it inside every enforcement (so the share extension obeys it too).
    public var storageLimit: StorageLimit {
        get {
            access(keyPath: \.storageLimit)
            return LimitDefaults.choice(defaults)
        }
        set {
            withMutation(keyPath: \.storageLimit) {
                defaults.set(newValue.rawValue, forKey: LimitDefaults.key)
                defaults.removeObject(forKey: LimitDefaults.bytesKey)
            }
        }
    }

    public var haptics: Bool {
        get {
            access(keyPath: \.haptics)
            return defaults.object(forKey: "haptics") as? Bool ?? true
        }
        set { withMutation(keyPath: \.haptics) { defaults.set(newValue, forKey: "haptics") } }
    }

    // MARK: share sheet and photos album (CONTRACT-SYNC.md section 4)

    /// "continue in background automatically": a link shared into the sheet closes it by itself after
    /// `autoContinueSeconds`. App-group defaults, so the extension reads them. On by default.
    public var autoContinue: Bool {
        get {
            access(keyPath: \.autoContinue)
            return defaults.object(forKey: "autoContinue") as? Bool ?? true
        }
        set { withMutation(keyPath: \.autoContinue) { defaults.set(newValue, forKey: "autoContinue") } }
    }

    /// The wait before the sheet closes: one of `autoContinueChoices`; anything else reads as 5.
    public var autoContinueSeconds: Int {
        get {
            access(keyPath: \.autoContinueSeconds)
            let s = defaults.integer(forKey: "autoContinueSeconds")
            return Settings.autoContinueChoices.contains(s) ? s : 5
        }
        set { withMutation(keyPath: \.autoContinueSeconds) { defaults.set(newValue, forKey: "autoContinueSeconds") } }
    }

    nonisolated public static let autoContinueChoices: [Int] = [3, 5, 10]

    /// "save to a photos album": off until the owner turns it on (`PhotosSync.enable()` asks for access
    /// first and only then sets it).
    public var photosAlbumSync: Bool {
        get {
            access(keyPath: \.photosAlbumSync)
            return defaults.object(forKey: "photosAlbumSync") as? Bool ?? false
        }
        set { withMutation(keyPath: \.photosAlbumSync) { defaults.set(newValue, forKey: "photosAlbumSync") } }
    }

    /// "include webps": off by default; applies to webps kept from the moment it is turned on.
    public var photosSyncWebps: Bool {
        get {
            access(keyPath: \.photosSyncWebps)
            return defaults.object(forKey: "photosSyncWebps") as? Bool ?? false
        }
        set { withMutation(keyPath: \.photosSyncWebps) { defaults.set(newValue, forKey: "photosSyncWebps") } }
    }

    // MARK: diagnostics

    /// "send crash reports and logs to your server": on by default (it is the owner's own server). Off
    /// keeps the log on the device and sends nothing. App-group defaults.
    public var sendTelemetry: Bool {
        get {
            access(keyPath: \.sendTelemetry)
            return defaults.object(forKey: "sendTelemetry") as? Bool ?? true
        }
        set { withMutation(keyPath: \.sendTelemetry) { defaults.set(newValue, forKey: "sendTelemetry") } }
    }

    // MARK: key and server

    /// The stored key, only while it belongs to the current server (see `hasAPIKey`).
    public func apiKey() -> String? { Settings.apiKey(in: keychain, forServer: serverURL) }

    /// The key stored in `keychain`, when it was pasted for `server`'s host (and port). Every live
    /// client reads through this, so a key never reaches a server it was not pasted for.
    nonisolated public static func apiKey(in keychain: Keychain, forServer server: URL) -> String? {
        guard let key = keychain.string(for: keyAccount) else { return nil }
        let owner = keychain.string(for: keyHostAccount) ?? keyScope(of: defaultServer)
        return owner == keyScope(of: server) ? key : nil
    }

    /// "host" or "host:port", lowercased: what a key is bound to.
    nonisolated static func keyScope(of url: URL) -> String {
        let host = (url.host(percentEncoded: false) ?? url.absoluteString).lowercased()
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Binds the key to the server that is set right now.
    public func setAPIKey(pasted text: String) throws(KeyInputError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 36, UUID(uuidString: trimmed) != nil else { throw .notAKey }
        let previousKey = keychain.string(for: Settings.keyAccount)
        let previousHost = keychain.string(for: Settings.keyHostAccount)
        do {
            try keychain.set(trimmed, for: Settings.keyAccount)
            try keychain.set(Settings.keyScope(of: serverURL), for: Settings.keyHostAccount)
        } catch {
            // the key is fine, the device would not keep it: put back what was there, say so
            try? keychain.set(previousKey, for: Settings.keyAccount)
            try? keychain.set(previousHost, for: Settings.keyHostAccount)
            throw .couldNotSave
        }
        hasAPIKey = true
    }

    public func clearAPIKey() {
        try? keychain.set(nil, for: Settings.keyAccount)
        try? keychain.set(nil, for: Settings.keyHostAccount)
        hasAPIKey = false
    }

    /// First http(s) URL in the text, path dropped.
    public func setServer(pasted text: String) throws(ServerInputError) {
        guard let found = LinkInfo.firstLink(in: text),
              var comps = URLComponents(url: found, resolvingAgainstBaseURL: false),
              let host = comps.host, !host.isEmpty
        else { throw .notAURL }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        guard let url = comps.url else { throw .notAURL }
        defaults.set(url.absoluteString, forKey: "serverURL")
        serverURL = url
        hasAPIKey = Settings.apiKey(in: keychain, forServer: url) != nil
    }

    public func resetServer() {
        defaults.removeObject(forKey: "serverURL")
        serverURL = Settings.defaultServer
        hasAPIKey = Settings.apiKey(in: keychain, forServer: serverURL) != nil
    }
}

import Foundation
import Observation
import Synchronization

/// App group plumbing with the fallbacks section 4.6 pins: no container → this process's
/// Application Support; no suite → `.standard`. macOS has no extension, so it never touches the
/// group container (which would trigger the "access data from other apps" prompt).
///
/// Where everything lives is decided ONCE per process (`location`) and every folder (`Videos`, `Sync`,
/// `Jobs`, `Telemetry`) hangs off that one answer, so reads and writes can never disagree. A sideloaded
/// build re-signed with another certificate (Feather, Sideloadly, AltStore) loses or renames the
/// app-group entitlement: `containerURL` then answers nil, or a folder the process cannot write. Both
/// fall back to the app's own Application Support, which is always there. The share extension then has
/// its own folder and cannot hand files to the app (the app downloads from the server instead).
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

    /// Which folder holds everything this process stores.
    enum RootKind: String, Sendable {
        /// `<app group container>`: shared with the extension.
        case appGroup
        /// This process's Application Support: the group container is missing or unwritable.
        case fallback
        /// Not even Application Support could be written; the temporary directory stands in (nothing
        /// survives a relaunch there).
        case none
    }

    /// The answer of `resolve`: the base folder, which kind it is, and why the group was not used.
    struct Location: Sendable, Equatable {
        var kind: RootKind
        var base: URL
        /// Whether `base` accepted a probe write.
        var writable: Bool
        /// The group container was not used because: `macos`, `no-container` (entitlement missing or
        /// renamed), or `unwritable`. Nil when the group is used.
        var groupSkipped: String?
        /// A folder moved from the fallback into the group when the group became available.
        var migrated: [String] = []

        /// One-line telemetry payload.
        var telemetry: [String: TelemetryValue] {
            var data: [String: TelemetryValue] = ["kind": .string(kind.rawValue), "writable": .bool(writable)]
            if let groupSkipped { data["groupSkipped"] = .string(groupSkipped) }
            if !migrated.isEmpty { data["migrated"] = .string(migrated.joined(separator: ",")) }
            return data
        }
    }

    private static let resolved = Mutex<Location?>(nil)

    /// Decided once per process.
    static var location: Location {
        resolved.withLock { slot in
            if let slot { return slot }
            let made = resolve(container: containerURL(), applicationSupport: applicationSupportURL())
            slot = made
            return made
        }
    }

    private static func applicationSupportURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// The Mac has no extension and never opens the group container (that triggers the "access data
    /// from other apps" prompt).
    static var usesGroup: Bool {
        #if os(macOS)
        return false
        #else
        return true
        #endif
    }

    /// The decision itself, with its inputs passed in (tests give it a missing, an unwritable and a good container).
    static func resolve(container: URL?, applicationSupport: URL?, usesGroup: Bool = AppGroup.usesGroup) -> Location {
        let fm = FileManager.default
        var skipped: String?
        if !usesGroup {
            skipped = "macos"
        } else if let container {
            if writable(container) {
                var location = Location(kind: .appGroup, base: container, writable: true, groupSkipped: nil)
                if let support = applicationSupport { location.migrated = migrateFallback(from: support, into: container) }
                return location
            }
            skipped = "unwritable"
        } else {
            skipped = "no-container"
        }
        if let support = applicationSupport, writable(support) {
            return Location(kind: .fallback, base: support, writable: true, groupSkipped: skipped)
        }
        return Location(kind: .none, base: fm.temporaryDirectory, writable: writable(fm.temporaryDirectory), groupSkipped: skipped)
    }

    /// Creates the folder when needed and proves it takes a file (a container can exist and still refuse writes).
    static func writable(_ dir: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let probe = dir.appendingPathComponent(".cobalt-probe-\(UUID().uuidString.prefix(8))")
            try Data("x".utf8).write(to: probe)
            try? fm.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// The folders a build that ran without the group left in Application Support move into the group
    /// once it is there (a properly signed build replaces the sideloaded one): only when the group
    /// has no such folder yet, so nothing is ever merged or overwritten. Returns the names moved.
    private static func migrateFallback(from support: URL, into container: URL) -> [String] {
        let fm = FileManager.default
        var moved: [String] = []
        for name in ["Videos", "Sync", "Jobs"] {
            let old = support.appendingPathComponent(name, isDirectory: true)
            let new = container.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            if (try? fm.moveItem(at: old, to: new)) != nil { moved.append(name) }
        }
        return moved
    }

    /// `<root>/<name>`; created on demand. The root is the group container, else Application Support.
    static func directory(_ name: String) -> URL {
        let dir = location.base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    /// "keep new saves offline" (CONTRACT-OFFLINE.md decision 5; the key keeps its old name so the owner's answer
    /// carries over). ON by default. On: every original and webp this device saves lands kept (in Files on
    /// iOS). Off: originals are not downloaded, and webps and plain-cobalt saves land in the cache.
    /// Turning it off deletes nothing.
    public var keepVideosOnDevice: Bool {
        get {
            access(keyPath: \.keepVideosOnDevice)
            return defaults.object(forKey: "keepVideosOnDevice") as? Bool ?? true
        }
        set { withMutation(keyPath: \.keepVideosOnDevice) { defaults.set(newValue, forKey: "keepVideosOnDevice") } }
    }

    /// The CACHE limit (CONTRACT-OFFLINE.md decision 4); .gb5 by default. It bounds only files nobody asked
    /// to keep: kept files are never evicted and do not count against it. Stored in the app-group defaults,
    /// where `OfflineStore` re-reads it inside every enforcement (so the share extension obeys it too).
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

    // MARK: sharing (CONTRACT-VISIBILITY.md decision 3)

    /// "make new saves public": a link save, an upload and the share sheet ask the server for a public link
    /// right away (`public: true`); off, they stay private until the owner switches one on. ON by default
    /// (the owner's call, 2026-10-05). App-group defaults, key `save.newSavesPublic`, so the extension reads
    /// what the app's settings wrote. Only the saves made after the switch are affected.
    public var newSavesPublic: Bool {
        get {
            access(keyPath: \.newSavesPublic)
            return defaults.object(forKey: Settings.newSavesPublicKey) as? Bool ?? true
        }
        set { withMutation(keyPath: \.newSavesPublic) { defaults.set(newValue, forKey: Settings.newSavesPublicKey) } }
    }

    nonisolated static let newSavesPublicKey = "save.newSavesPublic"

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

    /// "save to a photos album": OFF until the owner turns it on (CONTRACT-OFFLINE.md decision 13, owner's
    /// call 2026-10-06: kept videos live in Files, so new saves no longer go to Photos by themselves; the
    /// manual "save to photos" stays, and nothing already in the album is touched). Before 2026-10-06 an
    /// install with no stored value read ON. That needs no migration: only `PhotosSync.enable()` and
    /// `disable()` (the owner's own taps) ever wrote this key, so a stored `true` is always an explicit
    /// "on" (it stays on) and a stored `false` an explicit "off", while an install that never touched the
    /// toggle has no value and now reads off. The system's permission prompt appears when the owner turns
    /// it on, not at launch. Kept as a key so it can be switched back on.
    public var photosAlbumSync: Bool {
        get {
            access(keyPath: \.photosAlbumSync)
            return defaults.object(forKey: "photosAlbumSync") as? Bool ?? false
        }
        set { withMutation(keyPath: \.photosAlbumSync) { defaults.set(newValue, forKey: "photosAlbumSync") } }
    }

    /// "include webps": on by default (PhotoKit keeps them as stills; the settings footnote says so). Turned
    /// on later, it applies to webps kept from then on.
    public var photosSyncWebps: Bool {
        get {
            access(keyPath: \.photosSyncWebps)
            return defaults.object(forKey: "photosSyncWebps") as? Bool ?? true
        }
        set { withMutation(keyPath: \.photosSyncWebps) { defaults.set(newValue, forKey: "photosSyncWebps") } }
    }

    // MARK: save to a folder (the Mac; Folder/FolderSync.swift)

    /// "save to a folder" (macOS): every video and webp that lands in the offline store is copied into the
    /// owner's folder once. ON until the owner turns it off; an install that never touched it has no stored
    /// value and reads on. Which folder, and what was copied, live in the folder ledger, not here.
    public var folderSync: Bool {
        get {
            access(keyPath: \.folderSync)
            return defaults.object(forKey: "folderSync") as? Bool ?? true
        }
        set { withMutation(keyPath: \.folderSync) { defaults.set(newValue, forKey: "folderSync") } }
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

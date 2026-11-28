import Foundation

/// How a live stream watch deep link should open in Capystore's stream pane.
public enum WatchDeepLinkMode: String, Sendable, Hashable, Codable {
    /// Replaces the stream pane with a single stream (default).
    case open
    /// Appends the channel alongside currently playing streams (up to `PaneItem.maxSimultaneousStreams`).
    case add
}

/// Deep link payload for `cobalt-apple://watch`:
/// - `cobalt-apple://watch?channel=<canonicalKey>&mode=open|add`
/// - `cobalt-apple://watch?url=<percent-encoded-https-url>&mode=open|add`
/// - `cobalt-apple://watch/<canonicalKey>` (optional `?mode=open|add`)
public struct WatchDeepLink: Sendable, Hashable {
    public let address: StreamAddress
    public let mode: WatchDeepLinkMode

    public init(address: StreamAddress, mode: WatchDeepLinkMode = .open) {
        self.address = address
        self.mode = mode
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "cobalt-apple",
              url.host(percentEncoded: false)?.lowercased() == "watch",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let items = comps.queryItems ?? []
        let rawMode = items.first(where: { $0.name.lowercased() == "mode" })?.value?.lowercased()
        let mode: WatchDeepLinkMode = rawMode == WatchDeepLinkMode.add.rawValue ? .add : .open

        if let rawChannel = items.first(where: { $0.name.lowercased() == "channel" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawChannel.isEmpty {
            guard let parsed = StreamAddress.parse(rawChannel) else { return nil }
            self.address = parsed
            self.mode = mode
            return
        }

        if let rawURL = items.first(where: { $0.name.lowercased() == "url" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawURL.isEmpty {
            let webURL = URL(string: rawURL) ?? StreamAddress.extractSharedURL(from: rawURL)
            guard let webURL, let kind = StreamAddress.classifySharedURL(webURL) else { return nil }
            self.address = kind.address
            self.mode = mode
            return
        }

        let pathKey = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathKey.isEmpty, let parsed = StreamAddress.parse(pathKey) {
            self.address = parsed
            self.mode = mode
            return
        }

        return nil
    }

    /// Canonical `cobalt-apple://watch?channel=<canonicalKey>&mode=<open|add>` URL.
    public var url: URL {
        Self.url(for: address, mode: mode)
    }

    public static func url(for address: StreamAddress, mode: WatchDeepLinkMode = .open) -> URL {
        var comps = URLComponents()
        comps.scheme = "cobalt-apple"
        comps.host = "watch"
        comps.queryItems = [
            URLQueryItem(name: "channel", value: address.canonicalKey),
            URLQueryItem(name: "mode", value: mode.rawValue),
        ]
        return comps.url ?? URL(string: "cobalt-apple://watch")!
    }

    public static func url(forWebURL webURL: URL, mode: WatchDeepLinkMode = .open) -> URL {
        var comps = URLComponents()
        comps.scheme = "cobalt-apple"
        comps.host = "watch"
        comps.queryItems = [
            URLQueryItem(name: "url", value: webURL.absoluteString),
            URLQueryItem(name: "mode", value: mode.rawValue),
        ]
        return comps.url ?? URL(string: "cobalt-apple://watch")!
    }

    /// Resolves this watch deep link into the `PaneItem` the window should open,
    /// appending to `currentStreamItem` when `mode == .add` and a stream is already open.
    public func resolvedPaneItem(currentStreamItem: PaneItem?) -> PaneItem {
        let key = address.canonicalKey
        guard mode == .add, let current = currentStreamItem, current.isStream else {
            return .stream(key)
        }
        if let added = current.addingStream(key) {
            return added
        }
        // Already open in the current multi-stream layout or already at the 4-stream cap:
        // preserve the active stream layout instead of tearing it down.
        return current
    }
}

/// Shared App Group presence of currently playing streams so the iOS Share Extension can offer
/// "Add to Stream" only when 1...3 streams are actively open in Capystore.
public enum ActiveStreamPresence {
    static let channelsKey = "cobalt.activeStreamChannels"
    static let updatedAtKey = "cobalt.activeStreamUpdatedAt"

    /// Presence expires automatically after 6 hours in case the host app was terminated abruptly.
    public static let defaultMaxAge: TimeInterval = 6 * 3600

    public static func update(
        channels: [String],
        defaults: UserDefaults? = nil,
        now: Date = Date()
    ) {
        let store = defaults ?? AppGroup.defaults()
        let normalized = normalize(channels)
        guard !normalized.isEmpty else {
            clear(defaults: store)
            return
        }
        store.set(normalized, forKey: channelsKey)
        store.set(now.timeIntervalSince1970, forKey: updatedAtKey)
    }

    public static func clear(defaults: UserDefaults? = nil) {
        let store = defaults ?? AppGroup.defaults()
        store.removeObject(forKey: channelsKey)
        store.removeObject(forKey: updatedAtKey)
    }

    public static func current(
        defaults: UserDefaults? = nil,
        now: Date = Date(),
        maxAge: TimeInterval = defaultMaxAge
    ) -> [String] {
        let store = defaults ?? AppGroup.defaults()
        let updatedAt = store.double(forKey: updatedAtKey)
        guard updatedAt > 0 else { return [] }
        let age = now.timeIntervalSince1970 - updatedAt
        guard age >= 0, age <= maxAge else { return [] }
        guard let raw = store.stringArray(forKey: channelsKey) else { return [] }
        return normalize(raw)
    }

    /// True when 1...(maxSimultaneousStreams - 1) other streams are actively playing and do not already include `address`.
    public static func canAddToStream(
        _ address: StreamAddress,
        defaults: UserDefaults? = nil,
        now: Date = Date(),
        maxAge: TimeInterval = defaultMaxAge
    ) -> Bool {
        let active = current(defaults: defaults, now: now, maxAge: maxAge)
        return !active.isEmpty
            && active.count < PaneItem.maxSimultaneousStreams
            && !active.contains(address.canonicalKey)
    }

    private static func normalize(_ channels: [String]) -> [String] {
        var result: [String] = []
        for raw in channels {
            let key = StreamAddress.canonicalKey(for: raw)
            guard !key.isEmpty, !result.contains(key) else { continue }
            result.append(key)
            if result.count == PaneItem.maxSimultaneousStreams { break }
        }
        return result
    }
}

/// Pending live-stream watch request queued on `AppModel` for `AppShell`'s `Pane` to consume.
/// `serial` distinguishes repeated requests for the same channel (e.g. reopening after closing).
public struct WatchRequest: Equatable, Sendable {
    public let link: WatchDeepLink
    public let serial: Int

    public init(link: WatchDeepLink, serial: Int) {
        self.link = link
        self.serial = serial
    }
}

extension AppModel {
    /// Routes `cobalt-apple://watch?...` URLs to the stream pane. Returns `true` if handled.
    @discardableResult
    public func openWatchLink(_ url: URL) -> Bool {
        guard let link = WatchDeepLink(url: url) else { return false }
        requestWatch(link)
        return true
    }

    /// Opens a live stream address directly in the stream pane (replacing or adding alongside active streams).
    public func openStream(_ address: StreamAddress, mode: WatchDeepLinkMode = .open) {
        requestWatch(WatchDeepLink(address: address, mode: mode))
    }

    /// Queues a `WatchDeepLink` for the active window's `Pane` to open on both warm and cold launches.
    public func requestWatch(_ link: WatchDeepLink) {
        queueShown = false
        if capabilities.stage || capabilities.kind == .unreachable {
            selectedTab = .twitch
        }
        watchRequest = WatchRequest(link: link, serial: (watchRequest?.serial ?? 0) + 1)
    }

    /// Consumes the pending watch request and returns the resolved `PaneItem` to open.
    @discardableResult
    public func takeWatchRequest(currentPaneItem: PaneItem? = nil) -> PaneItem? {
        guard let request = watchRequest else { return nil }
        watchRequest = nil
        let activeStream: PaneItem?
        if let currentPaneItem, currentPaneItem.isStream {
            activeStream = currentPaneItem
        } else {
            activeStream = PaneItem.streams(twitch.activeChannels)
        }
        return request.link.resolvedPaneItem(currentStreamItem: activeStream)
    }
}

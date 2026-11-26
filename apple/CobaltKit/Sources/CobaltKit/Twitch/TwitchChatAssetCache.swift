import Foundation

// Shared off-main caches and per-account IRC rate limiter for Twitch chat (Phase 4: Combined Chat).
// When two `TwitchChatEngine` actors run concurrently, they share all four account/global asset caches
// (7TV global emotes, Twitch global badges, Helix userEmotes, 7TV user cosmetics) and one per-account
// IRC send limiter so "Both" sends stagger cleanly (~150 ms) without tripping Twitch's global limits.

/// Cached 7TV cosmetic resolution for one Twitch user ID (nil fields record a negative hit so both engines
/// don't repeatedly query users without cosmetics).
public struct TwitchCachedCosmetics: Sendable, Equatable {
    public var paint: SevenTvPaint?
    public var badge: ChatBadge?

    public init(paint: SevenTvPaint? = nil, badge: ChatBadge? = nil) {
        self.paint = paint
        self.badge = badge
    }
}

/// Cached Helix `chat/emotes/user` response (both name map for fragmentation and full rows for picker sections).
public struct TwitchUserEmoteBundle: Sendable, Equatable {
    public var map: [String: ChatEmote]
    public var rows: [TwitchUserEmote]

    public init(map: [String: ChatEmote] = [:], rows: [TwitchUserEmote] = []) {
        self.map = map
        self.rows = rows
    }
}

/// Shared actor cache reused across `TwitchChatEngine` instances for all four account/global chat caches:
/// 1. 7TV global emotes
/// 2. Twitch global badges
/// 3. Authenticated Helix `userEmotes`
/// 4. 7TV user cosmetics (by Twitch user ID)
///
/// Uses single-flight deduplication so two engines starting simultaneously share a single network fetch.
public actor TwitchChatAssetCache {
    public static let shared = TwitchChatAssetCache()

    private struct Timed<Value: Sendable>: Sendable {
        var value: Value
        var storedAt: ContinuousClock.Instant
    }

    private struct UserEmoteKey: Hashable, Sendable {
        var userID: String
        var broadcasterID: String
    }

    private let globalEmotesTTL: Duration
    private let globalBadgesTTL: Duration
    private let userEmotesTTL: Duration
    private let cosmeticsTTL: Duration
    private let cosmeticsLimit: Int
    private let now: @Sendable () -> ContinuousClock.Instant

    // 1. 7TV global emotes
    private var sevenTvGlobal: Timed<[String: ChatEmote]>?
    private var sevenTvGlobalInFlight: Task<[String: ChatEmote], Never>?

    // 2. Twitch global badges
    private var twitchGlobalBadges: Timed<[String: ChatBadge]>?
    private var twitchGlobalBadgesInFlight: Task<[String: ChatBadge], Never>?

    // 3. Helix userEmotes
    private var userEmotes: [UserEmoteKey: Timed<TwitchUserEmoteBundle>] = [:]
    private var userEmotesInFlight: [UserEmoteKey: Task<TwitchUserEmoteBundle?, Never>] = [:]

    // 4. 7TV user cosmetics (keyed by Twitch user ID)
    private var cosmetics: [String: Timed<TwitchCachedCosmetics>] = [:]
    private var cosmeticsOrder: [String] = []

    public init(
        globalEmotesTTL: Duration = .seconds(15 * 60),
        globalBadgesTTL: Duration = .seconds(30 * 60),
        userEmotesTTL: Duration = .seconds(10 * 60),
        cosmeticsTTL: Duration = .seconds(10 * 60),
        cosmeticsLimit: Int = 1_000
    ) {
        self.globalEmotesTTL = globalEmotesTTL
        self.globalBadgesTTL = globalBadgesTTL
        self.userEmotesTTL = userEmotesTTL
        self.cosmeticsTTL = cosmeticsTTL
        self.cosmeticsLimit = max(16, cosmeticsLimit)
        self.now = { ContinuousClock.now }
    }

    init(
        globalEmotesTTL: Duration = .seconds(15 * 60),
        globalBadgesTTL: Duration = .seconds(30 * 60),
        userEmotesTTL: Duration = .seconds(10 * 60),
        cosmeticsTTL: Duration = .seconds(10 * 60),
        cosmeticsLimit: Int = 1_000,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.globalEmotesTTL = globalEmotesTTL
        self.globalBadgesTTL = globalBadgesTTL
        self.userEmotesTTL = userEmotesTTL
        self.cosmeticsTTL = cosmeticsTTL
        self.cosmeticsLimit = max(16, cosmeticsLimit)
        self.now = now
    }

    private func isFresh<T>(_ entry: Timed<T>?, ttl: Duration) -> Bool {
        guard let entry else { return false }
        return entry.storedAt.duration(to: now()) < ttl
    }

    // MARK: 1. 7TV global emotes

    public func sevenTvGlobalEmotes(
        fetch: @escaping @Sendable () async -> [String: ChatEmote]
    ) async -> [String: ChatEmote] {
        MainThreadGuard.assertOffMain()
        if isFresh(sevenTvGlobal, ttl: globalEmotesTTL), let cached = sevenTvGlobal?.value, !cached.isEmpty {
            return cached
        }
        if let task = sevenTvGlobalInFlight {
            return await task.value
        }
        let task = Task { await fetch() }
        sevenTvGlobalInFlight = task
        let result = await task.value
        sevenTvGlobalInFlight = nil
        if !result.isEmpty {
            sevenTvGlobal = Timed(value: result, storedAt: now())
        }
        return result
    }

    // MARK: 2. Twitch global badges

    public func globalTwitchBadges(
        fetch: @escaping @Sendable () async -> [String: ChatBadge]
    ) async -> [String: ChatBadge] {
        MainThreadGuard.assertOffMain()
        if isFresh(twitchGlobalBadges, ttl: globalBadgesTTL), let cached = twitchGlobalBadges?.value, !cached.isEmpty {
            return cached
        }
        if let task = twitchGlobalBadgesInFlight {
            return await task.value
        }
        let task = Task { await fetch() }
        twitchGlobalBadgesInFlight = task
        let result = await task.value
        twitchGlobalBadgesInFlight = nil
        if !result.isEmpty {
            twitchGlobalBadges = Timed(value: result, storedAt: now())
        }
        return result
    }

    // MARK: 3. Helix userEmotes

    public func userEmotes(
        userID: String,
        broadcasterID: String?,
        fetch: @escaping @Sendable () async -> TwitchUserEmoteBundle?
    ) async -> TwitchUserEmoteBundle? {
        MainThreadGuard.assertOffMain()
        let key = UserEmoteKey(userID: userID, broadcasterID: broadcasterID ?? "")
        if isFresh(userEmotes[key], ttl: userEmotesTTL), let cached = userEmotes[key]?.value {
            return cached
        }
        if let task = userEmotesInFlight[key] {
            return await task.value
        }
        let task = Task { await fetch() }
        userEmotesInFlight[key] = task
        let result = await task.value
        userEmotesInFlight[key] = nil
        if let result {
            userEmotes[key] = Timed(value: result, storedAt: now())
        }
        return result
    }

    // MARK: 4. 7TV user cosmetics

    /// Splits `userIDs` into fresh cached hits and missing IDs that still need a 7TV GraphQL lookup.
    public func cachedCosmetics(for userIDs: [String]) -> (hits: [String: TwitchCachedCosmetics], missing: [String]) {
        MainThreadGuard.assertOffMain()
        var hits: [String: TwitchCachedCosmetics] = [:]
        var missing: [String] = []
        let current = now()
        for id in userIDs {
            if let entry = cosmetics[id], entry.storedAt.duration(to: current) < cosmeticsTTL {
                hits[id] = entry.value
            } else {
                missing.append(id)
            }
        }
        return (hits, missing)
    }

    /// Stores resolved 7TV cosmetics (including negative hits) keyed by Twitch user ID, bounded to `cosmeticsLimit`.
    public func storeCosmetics(_ entries: [String: TwitchCachedCosmetics]) {
        MainThreadGuard.assertOffMain()
        let current = now()
        for (id, value) in entries {
            let isNew = cosmetics[id] == nil
            cosmetics[id] = Timed(value: value, storedAt: current)
            if isNew {
                cosmeticsOrder.append(id)
            }
        }
        if cosmeticsOrder.count > cosmeticsLimit {
            let drop = cosmeticsOrder.count - cosmeticsLimit
            for oldID in cosmeticsOrder.prefix(drop) {
                cosmetics[oldID] = nil
            }
            cosmeticsOrder.removeFirst(drop)
        }
    }

    // MARK: lifecycle / memory

    public func purge(_ level: PurgeLevel) {
        switch level {
        case .background:
            cosmetics.removeAll()
            cosmeticsOrder.removeAll()
        case .memoryWarning:
            purgeAll()
        }
    }

    public func purgeAll() {
        sevenTvGlobal = nil
        sevenTvGlobalInFlight?.cancel()
        sevenTvGlobalInFlight = nil
        twitchGlobalBadges = nil
        twitchGlobalBadgesInFlight?.cancel()
        twitchGlobalBadgesInFlight = nil
        userEmotes.removeAll()
        for task in userEmotesInFlight.values { task.cancel() }
        userEmotesInFlight.removeAll()
        cosmetics.removeAll()
        cosmeticsOrder.removeAll()
    }
}

/// Shared per-account Twitch IRC send rate limiter across all joined channels.
///
/// Twitch enforces global per-account limits (`20 msgs / 30 s` for regular users, `100 / 30 s` for mods/VIPs)
/// across all channels combined. Reserving slots synchronously before sleeping guarantees that sending to
/// `"Both"` channels staggers consecutive `PRIVMSG` frames by at least `minimumGap` (~150 ms) even under
/// concurrent actor reentrancy, and never trips global IRC drops.
public actor TwitchChatSendLimiter {
    public static let shared = TwitchChatSendLimiter()

    public static let defaultWindow: Duration = .seconds(30)
    public static let defaultStandardLimit = 20
    public static let defaultElevatedLimit = 100
    public static let defaultMinimumGap: Duration = .milliseconds(150)

    private let window: Duration
    private let standardLimit: Int
    private let elevatedLimit: Int
    private let minimumGap: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async -> Void

    /// Reserved send instants per lowercased account key (always sorted ascending).
    private var history: [String: [ContinuousClock.Instant]] = [:]

    public init(
        window: Duration = defaultWindow,
        standardLimit: Int = defaultStandardLimit,
        elevatedLimit: Int = defaultElevatedLimit,
        minimumGap: Duration = defaultMinimumGap
    ) {
        self.window = window
        self.standardLimit = max(1, standardLimit)
        self.elevatedLimit = max(standardLimit, elevatedLimit)
        self.minimumGap = minimumGap
        self.now = { ContinuousClock.now }
        self.sleep = { duration in try? await Task.sleep(for: duration) }
    }

    init(
        window: Duration = defaultWindow,
        standardLimit: Int = defaultStandardLimit,
        elevatedLimit: Int = defaultElevatedLimit,
        minimumGap: Duration = defaultMinimumGap,
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        sleep: @escaping @Sendable (Duration) async -> Void
    ) {
        self.window = window
        self.standardLimit = max(1, standardLimit)
        self.elevatedLimit = max(standardLimit, elevatedLimit)
        self.minimumGap = minimumGap
        self.now = now
        self.sleep = sleep
    }

    /// Acquires a send slot for `accountKey`, waiting for stagger gap or sliding-window capacity if needed.
    /// Returns the delay duration waited before this send was permitted.
    @discardableResult
    public func acquire(accountKey: String, elevated: Bool = false) async -> Duration {
        let key = accountKey.lowercased()
        let current = now()
        var stamps = pruned(history[key] ?? [], at: current)
        let candidate = nextSlot(for: stamps, at: current, elevated: elevated)
        stamps.append(candidate)
        history[key] = stamps

        let wait = candidate > current ? current.duration(to: candidate) : .zero
        if wait > .zero {
            await sleep(wait)
        }
        return wait
    }

    /// Inspects the delay that a send for `accountKey` would currently wait without consuming a slot.
    public func nextDelay(accountKey: String, elevated: Bool = false) -> Duration {
        let key = accountKey.lowercased()
        let current = now()
        let stamps = pruned(history[key] ?? [], at: current)
        let candidate = nextSlot(for: stamps, at: current, elevated: elevated)
        return candidate > current ? current.duration(to: candidate) : .zero
    }

    public func recentSendCount(accountKey: String) -> Int {
        let key = accountKey.lowercased()
        return pruned(history[key] ?? [], at: now()).count
    }

    public func reset(accountKey: String? = nil) {
        if let accountKey {
            history[accountKey.lowercased()] = nil
        } else {
            history.removeAll()
        }
    }

    private func pruned(_ stamps: [ContinuousClock.Instant], at current: ContinuousClock.Instant) -> [ContinuousClock.Instant] {
        stamps.filter { $0.duration(to: current) < window }
    }

    private func nextSlot(
        for stamps: [ContinuousClock.Instant],
        at current: ContinuousClock.Instant,
        elevated: Bool
    ) -> ContinuousClock.Instant {
        var candidate = current
        if let last = stamps.last {
            let afterGap = last.advanced(by: minimumGap)
            if afterGap > candidate { candidate = afterGap }
        }
        let limit = elevated ? elevatedLimit : standardLimit
        if stamps.count >= limit {
            let blocking = stamps[stamps.count - limit]
            let afterWindow = blocking.advanced(by: window)
            if afterWindow > candidate { candidate = afterWindow }
        }
        return candidate
    }
}

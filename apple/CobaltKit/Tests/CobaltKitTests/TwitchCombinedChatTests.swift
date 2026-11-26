import Foundation
import Testing
@testable import CobaltKit

// Phase 4 Combined Twitch Chat & Opus Dual-Target Composer unit tests:
// - Channel-namespaced local/system IDs (zero cross-channel SwiftUI ForEach collisions)
// - Shared TwitchChatAssetCache deduplication across all 4 caches
// - Monotonic live arrival merge order, in-place updates, eviction stability & channel filtering
// - Opus composer target lock precedence (reply > filter > focus), filter-peek immunity & Both staggering
// - Deterministic channel accents & username hue-collision shifting

private final class CombinedChatStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data?) -> (Int, Data))?

    static func setHandler(_ block: (@Sendable (URLRequest, Data?) -> (Int, Data))?) {
        lock.lock()
        handler = block
        lock.unlock()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CombinedChatStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let block = Self.handler
        Self.lock.unlock()

        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        let (status, data) = block?(request, body) ?? (404, Data())
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

private final class LockedRecorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ value: T) {
        lock.lock()
        items.append(value)
        lock.unlock()
    }

    func snapshot() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ContinuousClock.Instant

    init(_ start: ContinuousClock.Instant = ContinuousClock.now) {
        self.current = start
    }

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        lock.unlock()
    }
}

// MARK: - 1. Namespaced IDs & Channel Attribution

struct TwitchChatNamespacedIDTests {
    @Test func localAndSystemIDsAreChannelNamespacedAndCollisionFree() async throws {
        let creds = TwitchCredentials(login: "harmony", userID: "42", clientID: "cid", token: "tok", canChat: true)
        let limiter = TwitchChatSendLimiter(minimumGap: .zero)
        let alpha = TwitchChatEngine(
            channel: "Alpha", credentials: creds,
            session: CombinedChatStubURLProtocol.makeSession(),
            assetCache: TwitchChatAssetCache(), sendLimiter: limiter)
        let beta = TwitchChatEngine(
            channel: "Beta", credentials: creds,
            session: CombinedChatStubURLProtocol.makeSession(),
            assetCache: TwitchChatAssetCache(), sendLimiter: limiter)
        defer {
            Task {
                await alpha.stop()
                await beta.stop()
            }
        }

        let sentFrames = LockedRecorder<String>()
        await alpha.setStatusForTesting(.joined(canSend: true))
        await beta.setStatusForTesting(.joined(canSend: true))
        await alpha.setSendOverrideForTesting { raw in sentFrames.append(raw); return true }
        await beta.setSendOverrideForTesting { raw in sentFrames.append(raw); return true }

        #expect(await alpha.send("hello alpha"))
        #expect(await beta.send("hello beta"))
        await alpha.emitSystemForTesting("joined alpha")
        await beta.emitSystemForTesting("joined beta")
        await alpha.ingestIRCForTesting(
            "@display-name=Capy;id=srv-1 :capy!capy@capy.tmi.twitch.tv PRIVMSG #alpha :yo")
        await beta.ingestIRCForTesting(
            "@system-msg=Resubbed;id=un-1 :tmi.twitch.tv USERNOTICE #beta :hi")

        let aLines = await alpha.currentSnapshot().lines
        let bLines = await beta.currentSnapshot().lines
        #expect(aLines.map(\.id) == ["alpha:local-1", "alpha:sys-2", "srv-1"])
        #expect(bLines.map(\.id) == ["beta:local-1", "beta:sys-2", "un-1"])
        #expect(aLines.allSatisfy { $0.channel == "alpha" })
        #expect(bLines.allSatisfy { $0.channel == "beta" })

        let allIDs = aLines.map(\.id) + bLines.map(\.id)
        #expect(Set(allIDs).count == allIDs.count)

        // Synthetic IDs never go out as @reply-parent-msg-id on the IRC wire
        #expect(TwitchChatLine.isSyntheticID("alpha:local-1"))
        #expect(TwitchChatLine.isSyntheticID("beta:sys-1"))
        #expect(TwitchChatLine.isSyntheticID("local-1"))
        #expect(TwitchChatLine.isSyntheticID("sys-2"))
        #expect(!TwitchChatLine.isSyntheticID("srv-1"))

        #expect(await alpha.send("reply to local", replyTo: "alpha:local-1"))
        #expect(await alpha.send("reply to real", replyTo: "srv-1"))
        let frames = sentFrames.snapshot()
        #expect(frames.contains("PRIVMSG #alpha :reply to local"))
        #expect(!frames.contains(where: { $0.contains("alpha:local-1") }))
        #expect(frames.contains("@reply-parent-msg-id=srv-1 PRIVMSG #alpha :reply to real"))
    }
}

// MARK: - 2. Shared TwitchChatAssetCache (All 4 Caches)

@Suite(.serialized)
struct TwitchChatAssetCacheTests {
    @Test func twoEnginesDeduplicateAllFourCachesThroughSharedAssetCache() async throws {
        defer { CombinedChatStubURLProtocol.setHandler(nil) }
        let requestedPaths = LockedRecorder<String>()

        CombinedChatStubURLProtocol.setHandler { req, body in
            guard let url = req.url else { return (404, Data()) }
            let host = url.host() ?? ""
            let path = url.path()
            requestedPaths.append("\(host)\(path)")

            if host == "7tv.io", path == "/v3/emote-sets/global" {
                return (200, Data("""
                {"id":"global","name":"Global","emotes":[
                  {"id":"g1","name":"KEKW","flags":0,"data":{"id":"g1","flags":0,"animated":false,
                    "host":{"url":"//cdn.7tv.app/emote/g1","files":[{"name":"2x.webp","width":64,"height":64,"format":"WEBP"}]}}}
                ]}
                """.utf8))
            }
            if host == "api.twitch.tv", path == "/helix/chat/badges/global" {
                return (200, Data("""
                {"data":[
                  {"set_id":"vip","versions":[{"id":"1","image_url_2x":"https://static-cdn.jtvnw.net/badges/v1/vip/2","title":"VIP"}]}
                ]}
                """.utf8))
            }
            if host == "api.twitch.tv", path == "/helix/chat/emotes/user" {
                return (200, Data("""
                {"data":[
                  {"id":"u1","name":"myEmote","format":["static"],"emote_type":"subscriptions","owner_id":"900"}
                ],"pagination":{}}
                """.utf8))
            }
            if host == "7tv.io", path == "/v3/gql" {
                let text = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let has101 = text.contains("101")
                let json = has101
                    ? """
                    {"data":{"u0":{"style":{
                      "paint":{"id":"p101","name":"Neon","function":"LINEAR_GRADIENT","angle":90,"repeat":false,"color":null,
                        "stops":[{"at":0,"color":-16711681},{"at":1,"color":-65281}],"shadows":[]},
                      "badge":null
                    }}}}
                    """
                    : """
                    {"data":{"u0":null}}
                    """
                return (200, Data(json.utf8))
            }
            return (404, Data())
        }

        let sharedCache = TwitchChatAssetCache()
        let creds = TwitchCredentials(login: "me", userID: "77", clientID: "cid", token: "tok", canChat: true)
        let session = CombinedChatStubURLProtocol.makeSession()
        let engineA = TwitchChatEngine(channel: "alpha", credentials: creds, session: session, assetCache: sharedCache)
        let engineB = TwitchChatEngine(channel: "beta", credentials: creds, session: session, assetCache: sharedCache)
        defer {
            Task {
                await engineA.stop()
                await engineB.stop()
            }
        }

        // 1, 2, 3: 7TV global emotes, Twitch global badges, Helix userEmotes — concurrently from both engines
        async let loadA: Void = engineA.loadGlobalsForTesting()
        async let loadB: Void = engineB.loadGlobalsForTesting()
        _ = await (loadA, loadB)

        let emotesA = await engineA.emotes().emotes.map(\.name)
        let emotesB = await engineB.emotes().emotes.map(\.name)
        #expect(emotesA.contains("KEKW"))
        #expect(emotesB.contains("KEKW"))
        #expect(emotesA.contains("myEmote"))
        #expect(emotesB.contains("myEmote"))

        // 4: 7TV user cosmetics — engineA fetches user 101, then engineB reuses cached entry with 0 extra GQL hits
        await engineA.ingestIRCForTesting(
            "@user-id=101;badges=vip/1;display-name=Alice;id=a1 :alice!alice@alice.tmi.twitch.tv PRIVMSG #alpha :KEKW")
        await engineA.flushCosmeticsForTesting()
        await engineB.ingestIRCForTesting(
            "@user-id=101;badges=vip/1;display-name=Alice;id=b1 :alice!alice@alice.tmi.twitch.tv PRIVMSG #beta :myEmote")
        await engineB.flushCosmeticsForTesting()

        let snapA = await engineA.currentSnapshot()
        let snapB = await engineB.currentSnapshot()
        #expect(snapA.paints["alice"]?.id == "p101")
        #expect(snapB.paints["alice"]?.id == "p101")
        #expect(snapA.lines.first?.badges.map(\.id) == ["vip/1"])
        #expect(snapB.lines.first?.badges.map(\.id) == ["vip/1"])

        let paths = requestedPaths.snapshot()
        #expect(paths.filter { $0 == "7tv.io/v3/emote-sets/global" }.count == 1)
        #expect(paths.filter { $0 == "api.twitch.tv/helix/chat/badges/global" }.count == 1)
        #expect(paths.filter { $0 == "api.twitch.tv/helix/chat/emotes/user" }.count == 1)
        #expect(paths.filter { $0 == "7tv.io/v3/gql" }.count == 1)

        // Background purge drops cosmetics only; memoryWarning drops all four caches
        await sharedCache.purge(.background)
        let afterBg = await sharedCache.cachedCosmetics(for: ["101"])
        #expect(afterBg.hits.isEmpty && afterBg.missing == ["101"])
    }
}

// MARK: - 3. Monotonic Arrival Merge Order, Filtering & Eviction Stability

@MainActor
struct TwitchCombinedChatMergeAndFilterTests {
    private func line(
        id: String,
        channel: String,
        login: String = "viewer",
        text: String = "hi",
        sentAt: Date = Date(timeIntervalSince1970: 1_000),
        deleted: Bool = false
    ) -> TwitchChatLine {
        TwitchChatLine(
            id: id,
            channel: channel,
            kind: .message,
            login: login,
            displayName: login.capitalized,
            color: nil,
            badges: [],
            fragments: [.text(text)],
            timestamp: sentAt,
            mentionsMe: false,
            mine: false,
            replyTo: nil,
            deleted: deleted)
    }

    private func snapshot(channel: String, status: TwitchChatStatus, lines: [TwitchChatLine]) -> TwitchChatSnapshot {
        var snap = TwitchChatSnapshot(channel: channel)
        snap.status = status
        snap.lines = lines
        return snap
    }

    @Test func monotonicArrivalOrderIgnoresOutOfOrderServerTimestampsAndPreservesUpdatesInPlace() {
        let model = TwitchCombinedChatModel(
            assetCache: TwitchChatAssetCache(),
            sendLimiter: TwitchChatSendLimiter(minimumGap: .zero))
        model.configureChannelsWithoutEngines(["alpha", "beta"], focusedChannel: "alpha")

        // Stream A arrives first with t=2000; Stream B arrives second with an OLDER t=1500 (e.g. delay offset).
        // Combined feed MUST keep arrival order (a1, b1, a2) — never scroll-back jitter by re-sorting on sentAt.
        let a1 = line(id: "a1", channel: "alpha", text: "first", sentAt: Date(timeIntervalSince1970: 2_000))
        model.ingest(snapshot(channel: "alpha", status: .joined(canSend: true), lines: [a1]))

        let b1 = line(id: "b1", channel: "beta", text: "second", sentAt: Date(timeIntervalSince1970: 1_500))
        model.ingest(snapshot(channel: "beta", status: .joined(canSend: true), lines: [b1]))

        let a2 = line(id: "a2", channel: "alpha", text: "third", sentAt: Date(timeIntervalSince1970: 1_900))
        model.ingest(snapshot(channel: "alpha", status: .joined(canSend: true), lines: [a1, a2]))

        #expect(model.allLines.map(\.id) == ["a1", "b1", "a2"])

        // In-place update (moderation delete on a1) updates without shifting position
        let a1Deleted = line(id: "a1", channel: "alpha", text: "first", sentAt: Date(timeIntervalSince1970: 2_000), deleted: true)
        model.ingest(snapshot(channel: "alpha", status: .joined(canSend: true), lines: [a1Deleted, a2]))
        #expect(model.allLines.map(\.id) == ["a1", "b1", "a2"])
        #expect(model.allLines[0].deleted)

        // Filtering: All vs Stream A vs Stream B
        model.setFilter(.all)
        #expect(model.visibleLines.map(\.id) == ["a1", "b1", "a2"])

        model.setFilter(.channel("alpha"))
        #expect(model.visibleLines.map(\.id) == ["a1", "a2"])

        model.setFilter(.channel("beta"))
        #expect(model.visibleLines.map(\.id) == ["b1"])
    }

    @Test func evictedSlowerChannelLinesAreNeverReAppended() {
        let model = TwitchCombinedChatModel(
            assetCache: TwitchChatAssetCache(),
            sendLimiter: TwitchChatSendLimiter(minimumGap: .zero))
        model.configureChannelsWithoutEngines(["slow", "fast"], focusedChannel: "slow")

        let slowOld = line(id: "slow-1", channel: "slow")
        model.ingest(snapshot(channel: "slow", status: .joined(canSend: false), lines: [slowOld]))

        // Flood fast channel past combinedLineLimit (400) so slow-1 is evicted from allLines
        let fastBatch = (1...405).map { line(id: "fast-\($0)", channel: "fast") }
        model.ingest(snapshot(channel: "fast", status: .joined(canSend: false), lines: fastBatch))
        #expect(model.allLines.count == TwitchCombinedChatModel.combinedLineLimit)
        #expect(!model.allLines.contains(where: { $0.id == "slow-1" }))

        // Slow channel emits a new line alongside slow-1 in its own snapshot: slow-1 MUST NOT re-append!
        let slowNew = line(id: "slow-2", channel: "slow")
        model.ingest(snapshot(channel: "slow", status: .joined(canSend: false), lines: [slowOld, slowNew]))
        #expect(!model.allLines.contains(where: { $0.id == "slow-1" }))
        #expect(model.allLines.last?.id == "slow-2")
    }
}

// MARK: - 4. Opus Foolproof Composer Target Locking & Send Limiter Staggering

@MainActor
struct TwitchDualComposerTargetAndLimiterTests {
    private func line(id: String, channel: String) -> TwitchChatLine {
        TwitchChatLine(
            id: id,
            channel: channel,
            kind: .message,
            login: "alice",
            displayName: "Alice",
            color: nil,
            badges: [],
            fragments: [.text("hello")],
            timestamp: Date(timeIntervalSince1970: 1_000),
            mentionsMe: false,
            mine: false,
            replyTo: nil)
    }

    @Test func targetLockPrecedenceIsReplyOverFilterOverFocusAndFilterPeekingNeverCorruptsTarget() {
        let model = TwitchCombinedChatModel(
            assetCache: TwitchChatAssetCache(),
            sendLimiter: TwitchChatSendLimiter(minimumGap: .zero))
        model.configureChannelsWithoutEngines(["alpha", "beta"], focusedChannel: "alpha")

        // Base case: All filter + focus on alpha -> resolves to alpha (never .both)
        #expect(model.resolvedInitialTarget() == .channel("alpha"))
        #expect(!model.isTargetOutOfFocus)

        // Focus changes to beta while composer is closed -> resolves to beta
        model.setFocusedChannel("beta")
        #expect(model.resolvedInitialTarget() == .channel("beta"))

        // Filter overrides focus: filter on alpha beats focus on beta
        model.setFilter(.channel("alpha"))
        #expect(model.resolvedInitialTarget() == .channel("alpha"))

        // Reply overrides filter & focus: replying to a beta line locks target to beta even while filtered to alpha
        model.beginReply(to: line(id: "srv-b1", channel: "beta"))
        #expect(model.composerTarget == .channel("beta"))
        #expect(model.composerTargetLocked)
        #expect(model.resolvedInitialTarget() == .channel("beta"))

        // Peeking another filter or swapping focus while reply is active NEVER changes target
        model.setFilter(.channel("alpha"))
        model.setFocusedChannel("alpha")
        #expect(model.composerTarget == .channel("beta"))
        #expect(model.replyTo?.id == "srv-b1")
        #expect(model.isTargetOutOfFocus)

        // Cancel reply while composer closed -> unlocks and falls back to active filter (alpha)
        model.cancelReply(composerOpen: false, hasDraft: false)
        #expect(!model.composerTargetLocked)
        #expect(model.composerTarget == .channel("alpha"))

        // Open keyboard -> target initializes ONCE and locks against filter peeks & focus changes
        model.composerDidOpen()
        #expect(model.composerTarget == .channel("alpha"))
        #expect(model.composerTargetLocked)

        model.setFilter(.channel("beta"))
        model.setFocusedChannel("beta")
        #expect(model.composerTarget == .channel("alpha"))
        #expect(model.isTargetOutOfFocus)

        // Closing keyboard WITH a draft preserves lock; closing WITHOUT a draft unlocks
        model.composerDidClose(hasDraft: true)
        #expect(model.composerTargetLocked)
        #expect(model.composerTarget == .channel("alpha"))

        model.composerDidClose(hasDraft: false)
        #expect(!model.composerTargetLocked)
        #expect(model.composerTarget == .channel("beta"))

        // `.both` is ONLY reachable via explicit menu selection, clears replyTo, and isTargetOutOfFocus is false
        model.beginReply(to: line(id: "srv-a1", channel: "alpha"))
        model.selectSendTarget(.both)
        #expect(model.composerTarget == .both)
        #expect(model.replyTo == nil)
        #expect(!model.isTargetOutOfFocus)
    }

    @Test func sendingToBothStaggersViaSharedLimiterAndRespectsWindowLimits() async {
        let clock = LockedClock()
        let recordedWaits = LockedRecorder<Duration>()
        let limiter = TwitchChatSendLimiter(
            window: .seconds(30),
            standardLimit: 3,
            elevatedLimit: 5,
            minimumGap: .milliseconds(150),
            now: { clock.now() },
            sleep: { wait in
                recordedWaits.append(wait)
                clock.advance(by: wait)
            })

        let creds = TwitchCredentials(login: "me", userID: "1", clientID: "cid", token: "tok", canChat: true)
        let engineA = TwitchChatEngine(
            channel: "alpha", credentials: creds,
            session: CombinedChatStubURLProtocol.makeSession(),
            assetCache: TwitchChatAssetCache(), sendLimiter: limiter)
        let engineB = TwitchChatEngine(
            channel: "beta", credentials: creds,
            session: CombinedChatStubURLProtocol.makeSession(),
            assetCache: TwitchChatAssetCache(), sendLimiter: limiter)
        defer {
            Task {
                await engineA.stop()
                await engineB.stop()
            }
        }

        let sentOrder = LockedRecorder<String>()
        await engineA.setStatusForTesting(.joined(canSend: true))
        await engineB.setStatusForTesting(.joined(canSend: true))
        await engineA.setSendOverrideForTesting { raw in sentOrder.append(raw); return true }
        await engineB.setSendOverrideForTesting { raw in sentOrder.append(raw); return true }

        let model = TwitchCombinedChatModel(assetCache: TwitchChatAssetCache(), sendLimiter: limiter)
        model.attachEngines([engineA, engineB], focusedChannel: "alpha", autoStart: false)
        model.selectSendTarget(.both)

        let ok = await model.send("gg both")
        #expect(ok)
        #expect(sentOrder.snapshot() == ["PRIVMSG #alpha :gg both", "PRIVMSG #beta :gg both"])
        // First send is immediate (0ms), second send waits exactly the 150ms stagger gap
        #expect(recordedWaits.snapshot() == [.milliseconds(150)])

        // 3rd send fits within standardLimit=3 after another 150ms stagger (engine keys limiter by credentials.userID = "1")
        let wait3 = await limiter.acquire(accountKey: "1", elevated: false)
        #expect(wait3 == .milliseconds(150))

        // 4th send hits the 30s sliding window for standardLimit=3 (1st send was at t=0, now at t=300ms -> waits 29.7s)
        let wait4 = await limiter.acquire(accountKey: "1", elevated: false)
        #expect(wait4 >= .seconds(29) && wait4 <= .seconds(30))

        // Concurrent reentrancy check: 3 simultaneous acquires reserve 0ms, 150ms, 300ms
        await limiter.reset()
        let concurrentClock = LockedClock()
        let concurrentLimiter = TwitchChatSendLimiter(
            window: .seconds(30),
            standardLimit: 20,
            elevatedLimit: 100,
            minimumGap: .milliseconds(150),
            now: { concurrentClock.now() },
            sleep: { _ in })
        let d1 = await concurrentLimiter.acquire(accountKey: "acc")
        let d2 = await concurrentLimiter.acquire(accountKey: "acc")
        let d3 = await concurrentLimiter.acquire(accountKey: "acc")
        #expect(d1 == .zero)
        #expect(d2 == .milliseconds(150))
        #expect(d3 == .milliseconds(300))
    }
}

// MARK: - 5. Channel Accents & Username Hue-Collision Shifting

struct TwitchUsernameColorShifterTests {
    @Test func deterministicAccentsAndHueCollisionShifting() {
        let accentA = TwitchChannelAccent(slot: .primary, channel: "shroud", displayName: "shroud")
        let accentB = TwitchChannelAccent(slot: .secondary, channel: "tarik", displayName: "Tarik")
        #expect(accentA.darkRGB == TwitchChannelAccent.primaryDarkRGB)
        #expect(accentA.lightRGB == TwitchChannelAccent.primaryLightRGB)
        #expect(accentA.mark == "S")
        #expect(accentB.darkRGB == TwitchChannelAccent.secondaryDarkRGB)
        #expect(accentB.lightRGB == TwitchChannelAccent.secondaryLightRGB)
        #expect(accentB.mark == "T")

        let symbolOnly = TwitchChannelAccent(slot: .secondary, channel: "___", displayName: "___")
        #expect(symbolOnly.mark == "B")

        let accentHues = [accentA.hueDegrees, accentB.hueDegrees]

        // Colliding sky-blue & rose (including 0°/360° wrap-around pure red) get shifted clear of both accents
        let collidingSamples: [UInt32] = [
            TwitchChannelAccent.primaryDarkRGB, // exact Stream A sky blue (~199°)
            0x1E90FF,                           // DodgerBlue (~210°, within 24° of 199°)
            TwitchChannelAccent.secondaryDarkRGB, // exact Stream B rose (~351°)
            0xFF0000,                           // Pure red (0°, 9° from 351° across wrap-around!)
            0xFF3366,                           // Vivid rose-pink (~345°)
        ]
        for rgb in collidingSamples {
            let shifted = TwitchUsernameColorShifter.shiftedIfColliding(rgb, avoiding: accentHues)
            #expect(shifted != rgb)
            let shiftedHSL = TwitchUsernameColorShifter.rgbToHSL(shifted)
            for accentHue in accentHues {
                let dist = TwitchUsernameColorShifter.circularHueDistance(shiftedHSL.h, accentHue)
                #expect(dist >= 24)
            }
        }

        // Non-colliding hues stay completely unchanged
        let safeSamples: [UInt32] = [
            0x00FF7F, // SpringGreen (~150°)
            0xDAA520, // GoldenRod (~43°)
            0x8A2BE2, // BlueViolet (~271°)
        ]
        for rgb in safeSamples {
            #expect(TwitchUsernameColorShifter.shiftedIfColliding(rgb, avoiding: accentHues) == rgb)
        }

        // Low-saturation grays stay unchanged
        #expect(TwitchUsernameColorShifter.shiftedIfColliding(0xCCCCCC, avoiding: accentHues) == 0xCCCCCC)
        #expect(TwitchUsernameColorShifter.shiftedIfColliding(0x808080, avoiding: accentHues) == 0x808080)

        // Single-stream mode (empty accentHues) never alters username color
        #expect(TwitchUsernameColorShifter.shiftedIfColliding(0x38BDF8, avoiding: []) == 0x38BDF8)
    }
}

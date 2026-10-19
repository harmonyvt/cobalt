import Foundation
import Synchronization

// Stage in previews (APP-API-CONTRACT 30): a server with `features.stage` and `stage_twitch`, a connected stage on air with
// a spotlight, four rewards and a few redemptions, and 72 public files in the pool. Writes behave like the real routes:
// numbers are clamped, a pool must name a collection or set the preview links server has (or words), `409 off_air` while off
// air, an item must be in the pool, and a reward patch updates the reward. `PreviewScenario.stageNotConnected` is the stage
// before Twitch is connected (off air, whole library, no spotlight, no redemptions); "connect" works and the next read finds
// it connected. `.stageFail` cannot load the stage (`503`). `.happy` and `.renditions` are the connected stage.

extension PreviewScenario {
    /// The preview server has `features.stage`.
    var hasStage: Bool {
        switch self {
        case .happy, .renditions, .stageNotConnected, .stageFail: return true
        default: return false
        }
    }
}

extension PreviewData {
    static let stageHost = URL(string: "https://studio.capybaraharmony.com/")!

    /// The OBS link: 32 characters of token, the last four are `tail`.
    static func stageLiveURL(tail: String = "k7Q2") -> URL {
        stageHost.appendingPathComponent("live").appendingPathComponent("PrEvIeWstageToken00000000000" + tail)
    }

    static let stageStoreURL = stageHost.appendingPathComponent("store")

    /// Codes are 3 characters from this alphabet (30.2).
    private static let stageCodeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// The 72 public files of the preview pool: 12 titles over and over, the first twelve with the codes the boards use.
    static func stageItems(count: Int = 72) -> [StageItem] {
        let codes = ["K7Q", "M3T", "CAT", "FD9", "B2R", "CF7", "KT5", "CTY", "BK3", "GT8", "SK4", "HF6"]
        let templates: [(String, StageItem.Kind, Int, Int, Double?)] = [
            ("the dog at the harbour", .video, 720, 1280, 37.43),
            ("the timer one", .image, 480, 568, 5.4),
            ("cat supervising the shower again", .image, 1080, 1350, nil),
            ("crunchy chili something", .image, 1080, 1080, nil),
            ("cockatoo on the train", .video, 1280, 720, 12.2),
            ("coffee art, third try", .image, 480, 480, 10.1),
            ("kitchen timer, again", .image, 480, 568, 5.4),
            ("city at night", .image, 480, 270, 5.0),
            ("bike lane", .video, 1080, 1920, 8.8),
            ("guitar riff", .video, 1920, 1080, 21.0),
            ("skate fail", .image, 720, 720, 3.2),
            ("harbour fog", .image, 1920, 1080, nil),
        ]
        let alphabet = stageCodeAlphabet
        return (0..<count).map { i in
            let t = templates[i % templates.count]
            let name = String(format: "PrEvIeWs%03d", i)
            let code: String
            if i < codes.count {
                code = codes[i]
            } else {
                code = String([alphabet[(i / 32) % 32], alphabet[i % 32], alphabet[7]])
            }
            let title = i < templates.count ? t.0 : "\(t.0) \(i / templates.count + 1)"
            let ext = t.1 == .video ? "mp4" : (t.4 != nil ? "webp" : "jpg")
            return StageItem(
                id: String(format: "PrEvIeWstage%05d", i), code: code, title: title, kind: t.1,
                url: mediaBase.appendingPathComponent("\(name).\(ext)"),
                posterURL: t.1 == .video ? mediaBase.appendingPathComponent("\(name).jpg") : nil,
                width: t.2, height: t.3, duration: t.4)
        }
    }

    /// The four rewards (30.2): summon 500 / 30 s on, chaos 2,000 / 300 s on, shuffle 1,000 / 120 s on, pin 300 / 60 s off.
    static func stageRewards(synced: Bool) -> [StageReward] {
        [
            StageReward(action: .summon, cost: 500, cooldownSeconds: 30, enabled: true, synced: synced),
            StageReward(action: .chaos, cost: 2_000, cooldownSeconds: 300, enabled: true, synced: synced),
            StageReward(action: .shuffle, cost: 1_000, cooldownSeconds: 120, enabled: true, synced: synced),
            StageReward(action: .pin, cost: 300, cooldownSeconds: 60, enabled: false, synced: synced),
        ]
    }

    /// The stage of a stage scenario (`now` is when the preview server started).
    static func stageSettings(for scenario: PreviewScenario, items: [StageItem], now: Date) -> StageSettings {
        let connected = scenario != .stageNotConnected
        let cat = items[2]
        return StageSettings(
            onAir: connected,
            pool: connected
                ? StagePool(kind: .collection, ref: "PrEvIeWcoll00001", name: "memes", count: 24)
                : StagePool(kind: .library, ref: nil, name: "whole library", count: items.count),
            density: 30, tileSeconds: 10, tileScale: 1, spotlightAuto: true, spotlightSeconds: 20, sound: true, videoMax: 12,
            storeOpen: false, storeHint: true, liveURL: stageLiveURL(), storeURL: stageStoreURL,
            twitch: connected
                ? StageTwitch(
                    login: "capybaraharmony", displayName: "capybaraharmony", connectedAt: now.addingTimeInterval(-3 * 86_400),
                    status: .ok, lastEventAt: now.addingTimeInterval(-20))
                : nil,
            spotlight: connected ? StageSpotlight(item: cat, by: "mochi", action: .summon, at: now.addingTimeInterval(-20)) : nil,
            updatedAt: now.addingTimeInterval(-20))
    }

    /// The feed, newest first.
    static func stageRedemptions(for scenario: PreviewScenario, items: [StageItem], now: Date) -> [StageRedemption] {
        guard scenario != .stageNotConnected else { return [] }
        func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }
        return [
            StageRedemption(id: "PrEvIeWredeem0001", action: "summon", userName: "mochi", input: "cat", item: items[2], createdAt: ago(20)),
            StageRedemption(id: "PrEvIeWredeem0002", action: "chaos", userName: "zeph", createdAt: ago(60)),
            StageRedemption(
                id: "PrEvIeWredeem0003", action: "summon", userName: "pebble", input: "cursed food", item: items[3], createdAt: ago(180)),
            StageRedemption(id: "PrEvIeWredeem0004", action: "shuffle", userName: "kiri", createdAt: ago(360)),
            StageRedemption(
                id: "PrEvIeWredeem0005", action: "summon", userName: "juno", input: "bird", item: items[4], createdAt: ago(540)),
            StageRedemption(
                id: "PrEvIeWredeem0006", action: "summon", userName: "wren", input: "dragon", status: .refunded, reason: .noMatch,
                createdAt: ago(720)),
            StageRedemption(
                id: "owner:PrEvIeWseed00001", action: "spotlight", userName: "you", item: items[0], createdAt: ago(840)),
        ]
    }
}

/// What the preview "server" holds for `/stage`: the stage, its rewards, the feed, the pool, every call made, and the patches
/// that reached it (so a test sees one request for a burst of slider moves).
final class PreviewStageState: Sendable {
    private struct State {
        var stage = StageSettings(liveURL: PreviewData.stageLiveURL(), storeURL: PreviewData.stageStoreURL)
        var rewards: [StageReward] = []
        var redemptions: [StageRedemption] = []
        var items: [StageItem] = []
        var calls: [String] = []
        var patches: [StagePatch] = []
        var loadFails = false
        var searchUnavailable = false
        /// `connect` was asked: the next read finds Twitch connected (the callback the web session would have made).
        var connecting = false
        var counter = 0
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }
    var patches: [StagePatch] { state.withLock { $0.patches } }
    var stage: StageSettings { state.withLock { $0.stage } }
    var redemptions: [StageRedemption] { state.withLock { $0.redemptions } }
    var items: [StageItem] { state.withLock { $0.items } }

    func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func seed(_ scenario: PreviewScenario, now: Date) {
        let items = PreviewData.stageItems()
        state.withLock { s in
            s.items = items
            s.stage = PreviewData.stageSettings(for: scenario, items: items, now: now)
            s.rewards = PreviewData.stageRewards(synced: scenario != .stageNotConnected)
            s.redemptions = PreviewData.stageRedemptions(for: scenario, items: items, now: now)
            s.loadFails = scenario == .stageFail
        }
    }

    /// Tests: `GET /stage` answers 503 while this is true.
    var loadFails: Bool {
        get { state.withLock { $0.loadFails } }
        set { state.withLock { $0.loadFails = newValue } }
    }

    /// Tests: a search pool answers `503 error.stage.search_unavailable` while this is true.
    var searchUnavailable: Bool {
        get { state.withLock { $0.searchUnavailable } }
        set { state.withLock { $0.searchUnavailable = newValue } }
    }

    /// Tests: puts the stage on or off air without a call.
    func setOnAir(_ on: Bool) { state.withLock { $0.stage.onAir = on } }

    func read(at now: Date) throws -> StageSnapshot {
        try state.withLock { s in
            if s.loadFails { throw StageError.unavailable }
            if s.connecting {
                s.connecting = false
                s.stage.twitch = StageTwitch(login: "capybaraharmony", displayName: "capybaraharmony", connectedAt: now, status: .ok)
                s.rewards = s.rewards.map { r in var r = r; r.synced = true; return r }
            }
            return StageSnapshot(stage: s.stage, rewards: s.rewards)
        }
    }

    func patch(_ p: StagePatch, collections: [ShareCollection], groups: [CollectionGroup], now: Date) throws -> StageSettings {
        try state.withLock { s in
            s.patches.append(p)
            if let pool = p.pool {
                switch pool {
                case .library:
                    s.stage.pool = StagePool(kind: .library, ref: nil, name: "whole library", count: s.items.count)
                case .collection(let id):
                    guard let collection = collections.first(where: { $0.id == id }) else { throw StageError.badRequest }
                    s.stage.pool = StagePool(kind: .collection, ref: id, name: collection.name, count: 24)
                case .group(let id):
                    guard let group = groups.first(where: { $0.id == id }) else { throw StageError.badRequest }
                    s.stage.pool = StagePool(kind: .group, ref: id, name: group.name, count: 48)
                case .search(let words):
                    guard let clean = StageRule.cleanSearch(words) else { throw StageError.badRequest }
                    if s.searchUnavailable { throw StageError.searchUnavailable }
                    s.stage.pool = StagePool(kind: .search, ref: clean, name: clean, count: 9)
                }
            }
            s.stage = s.stage.applying(p)
            s.stage.updatedAt = now
            return s.stage
        }
    }

    func rotate(at now: Date) -> StageSettings {
        state.withLock { s in
            s.counter += 1
            s.stage.liveURL = PreviewData.stageLiveURL(tail: String(format: "r%03d", s.counter))
            s.stage.updatedAt = now
            return s.stage
        }
    }

    /// An owner action: needs the stage on air; a pick must be in the pool; each is a "you" line in the feed.
    func act(_ action: StageAction, at now: Date) throws -> StageSettings {
        try state.withLock { s in
            guard s.stage.onAir else { throw StageError.offAir }
            let pool = Array(s.items.prefix(s.stage.pool.missing ? 0 : s.stage.pool.count))
            var shown: StageItem?
            switch action {
            case .skip:
                let current = s.stage.spotlight?.item.id
                shown = pool.first { $0.id != current }
                if let item = shown { s.stage.spotlight = StageSpotlight(item: item, by: nil, action: .owner, at: now) }
            case .pin:
                s.stage.spotlight?.pinnedUntil = now.addingTimeInterval(120)
            case .unpin:
                s.stage.spotlight?.pinnedUntil = nil
            case .shuffle, .chaos:
                break
            case .spotlight(let id):
                guard let item = pool.first(where: { $0.id == id }) else { throw StageError.notFound }
                shown = item
                s.stage.spotlight = StageSpotlight(item: item, by: nil, action: .owner, at: now)
            }
            s.counter += 1
            s.redemptions.insert(
                StageRedemption(
                    id: "owner:PrEvIeWown\(String(format: "%05d", s.counter))", action: action.type, userName: "you", item: shown,
                    createdAt: now),
                at: 0)
            return s.stage
        }
    }

    func page(offset: Int, limit: Int) -> StagePoolPage {
        state.withLock { s in
            let pool = Array(s.items.prefix(s.stage.pool.missing ? 0 : s.stage.pool.count))
            let start = min(max(0, offset), pool.count)
            let end = min(pool.count, start + limit)
            return StagePoolPage(total: pool.count, offset: start, next: end < pool.count ? end : nil, items: Array(pool[start..<end]))
        }
    }

    func feed(limit: Int, before: Date?) -> [StageRedemption] {
        state.withLock { s in
            Array(s.redemptions.filter { before == nil || $0.createdAt < (before ?? .distantFuture) }.prefix(limit))
        }
    }

    func updateReward(_ kind: StageRewardKind, cost: Int?, cooldownSeconds: Int?, enabled: Bool?) throws -> StageReward {
        try state.withLock { s in
            guard let i = s.rewards.firstIndex(where: { $0.action == kind }) else { throw StageError.notFound }
            if let cost { s.rewards[i].cost = StageRule.clamp(cost, to: StageRule.costRange) }
            if let cooldownSeconds { s.rewards[i].cooldownSeconds = StageRule.clamp(cooldownSeconds, to: StageRule.cooldownRange) }
            if let enabled { s.rewards[i].enabled = enabled }
            s.rewards[i].synced = s.stage.twitch != nil
            return s.rewards[i]
        }
    }

    func connect() {
        state.withLock { $0.connecting = true }
    }

    func disconnect(at now: Date) -> StageSettings {
        state.withLock { s in
            s.connecting = false
            s.stage.twitch = nil
            s.rewards = s.rewards.map { r in var r = r; r.synced = false; return r }
            s.stage.updatedAt = now
            return s.stage
        }
    }
}

extension PreviewClient {
    private func stageLatency() async throws {
        try await clock.sleep(seconds: 0.2 * timeScale)
    }

    /// `GET /stage`; `.stageFail` answers `503`. After `connectStageTwitch` the next read finds Twitch connected.
    public func stage() async throws -> StageSnapshot {
        stageState.record("GET")
        try await stageLatency()
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
        return try stageState.read(at: clock.now())
    }

    /// `PATCH /stage`: numbers clamped; a pool must be a collection or set the preview links server holds, or words
    /// (`badRequest` otherwise; `searchUnavailable` while the test switch says so).
    public func updateStage(_ patch: StagePatch) async throws -> StageSettings {
        stageState.record("PATCH")
        try await stageLatency()
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
        return try stageState.patch(patch, collections: shareState.collections, groups: shareState.groups, now: clock.now())
    }

    /// `POST /stage/rotate`: a new token, so the last four characters of the link change.
    public func rotateStage() async throws -> StageSettings {
        stageState.record("POST rotate")
        try await stageLatency()
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
        return stageState.rotate(at: clock.now())
    }

    /// `POST /stage/action`: `offAir` while off air, `notFound` for an item outside the pool.
    public func stageAction(_ action: StageAction) async throws -> StageSettings {
        stageState.record("POST action \(action.type)" + (action.itemID.map { " \($0)" } ?? ""))
        try await stageLatency()
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
        return try stageState.act(action, at: clock.now())
    }

    /// `GET /stage/pool`: the resolved pool, `badRequest` for a limit outside 1...100 or an offset below 0.
    public func stagePool(offset: Int, limit: Int) async throws -> StagePoolPage {
        stageState.record("GET pool \(offset) \(limit)")
        try await stageLatency()
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
        guard offset >= 0, (1...100).contains(limit) else { throw StageError.badRequest }
        return stageState.page(offset: offset, limit: limit)
    }

    /// `GET /stage/redemptions`: newest first.
    public func stageRedemptions(limit: Int, before: Date?) async throws -> [StageRedemption] {
        stageState.record("GET redemptions")
        try await clock.sleep(seconds: 0.1 * timeScale)
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
        guard (1...100).contains(limit) else { throw StageError.badRequest }
        if stageState.loadFails { throw StageError.unavailable }
        return stageState.feed(limit: limit, before: before)
    }

    /// `PATCH /stage/rewards/<action>`: clamped; `synced` while Twitch is connected.
    public func updateStageReward(_ kind: StageRewardKind, cost: Int?, cooldownSeconds: Int?, enabled: Bool?) async throws -> StageReward {
        stageState.record("PATCH reward \(kind.rawValue)")
        try await stageLatency()
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
        return try stageState.updateReward(kind, cost: cost, cooldownSeconds: cooldownSeconds, enabled: enabled)
    }

    /// `POST /stage/twitch/connect`: the authorize URL; the next `GET /stage` finds Twitch connected.
    public func connectStageTwitch() async throws -> URL {
        stageState.record("POST connect")
        try await stageLatency()
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
        stageState.connect()
        return URL(string: "https://id.twitch.tv/oauth2/authorize?response_type=code&client_id=PrEvIeW&redirect_uri=https%3A%2F%2Fstudio.capybaraharmony.com%2Ftwitch%2Fcallback&scope=channel%3Amanage%3Aredemptions&state=PrEvIeWstate&force_verify=true")!
    }

    /// `DELETE /stage/twitch`.
    public func disconnectStageTwitch() async throws -> StageSettings {
        stageState.record("DELETE twitch")
        try await stageLatency()
        guard scenario.hasStage else { throw PipelineFailure.unsupported }
        return stageState.disconnect(at: clock.now())
    }
}

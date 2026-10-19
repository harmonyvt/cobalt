import Foundation
import Testing
@testable import CobaltKit

// Stage, the studio tab (APP-API-CONTRACT 30): the capability, the wire shapes of the owner routes (30.10), the patch and its
// clamps, the nine routes and their refusals, the preview server, and the store: load, switches, the debounced sliders (last
// write wins), rewards, rotate, Twitch connect and disconnect, and the feed polled every 4 s only while it is asked to.

private let stageKey = "2d6b9e10-5c3a-4f7e-8a21-9b0c4d7e1f35"

private let wireItem = """
{"id":"PrEvIeWstage00002","code":"CAT","title":"cat supervising the shower again","kind":"image","url":"https://media.capybaraharmony.com/PrEvIeWs002.jpg","poster_url":null,"width":1080,"height":1350,"duration":null}
"""

private let wireVideoItem = """
{"id":"PrEvIeWstage00000","code":"K7Q","title":"the dog at the harbour","kind":"video","url":"https://media.capybaraharmony.com/PrEvIeWs000.mp4","poster_url":"https://media.capybaraharmony.com/PrEvIeWs000.jpg","width":720,"height":1280,"duration":37.43}
"""

private let wireSpotlight = """
{"item":\(wireItem),"by":"mochi","action":"summon","pinned_until":null,"at":1790000800000}
"""

private let wireTwitch = """
{"login":"capybaraharmony","display_name":"CapybaraHarmony","connected_at":1790000000000,"status":"ok","last_event_at":1790000900000}
"""

private let wireStage = """
{"on_air":true,"pool":{"kind":"collection","ref":"PrEvIeWcoll00001","name":"memes","count":24,"missing":false},
 "density":30,"tile_seconds":10,"tile_scale":1.0,"spotlight_auto":true,"spotlight_seconds":20,"sound":true,"video_max":12,
 "store_open":false,"store_hint":true,
 "live_url":"https://studio.capybaraharmony.com/live/Zk7Q2abcdefghijklmnopqrstuvwxk7Q2",
 "store_url":"https://studio.capybaraharmony.com/store",
 "twitch":\(wireTwitch),"spotlight":\(wireSpotlight),"updated_at":1790000950000}
"""

private let wireRewards = """
[{"action":"summon","title":"summon","cost":500,"cooldown_seconds":30,"enabled":true,"synced":true},
 {"action":"chaos","title":"chaos","cost":2000,"cooldown_seconds":300,"enabled":true,"synced":true},
 {"action":"shuffle","title":"capystore shuffle","cost":1000,"cooldown_seconds":120,"enabled":true,"synced":false},
 {"action":"pin","title":"pin","cost":300,"cooldown_seconds":60,"enabled":false,"synced":true}]
"""

private let wireSnapshot = """
{"status":"success","stage":\(wireStage),"rewards":\(wireRewards)}
"""

private let wireRedemptions = """
{"status":"success","redemptions":[
 {"id":"2f1d3c9a-0000-4000-8000-000000000001","action":"summon","user_name":"mochi","input":"cat","item":\(wireItem),"status":"done","reason":null,"created_at":1790000800000},
 {"id":"2f1d3c9a-0000-4000-8000-000000000002","action":"summon","user_name":"wren","input":"dragon","item":null,"status":"refunded","reason":"no_match","created_at":1790000700000},
 {"id":"owner:AbCdEfGhIjKlMnOp","action":"skip","user_name":"you","input":null,"item":null,"status":"done","reason":null,"created_at":1790000600000}]}
"""

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try CobaltJSON.decoder().decode(T.self, from: Data(json.utf8))
}

// MARK: - capability

struct StageCapabilityTests {
    private func caps(features: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":\#(features),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func theFlagsAreOnWhenTheServerSaysSo() throws {
        let on = try caps(features: #"{"stage":true,"stage_twitch":true}"#)
        #expect(on.stage && on.stageTwitch)
        let canvasOnly = try caps(features: #"{"stage":true,"stage_twitch":false}"#)
        #expect(canvasOnly.stage && !canvasOnly.stageTwitch)
    }

    @Test func twitchIsForcedOffWithoutTheStage() throws {
        let c = try caps(features: #"{"stage":false,"stage_twitch":true}"#)
        #expect(!c.stage && !c.stageTwitch)
        #expect(try !caps(features: #"{"stage_twitch":true}"#).stageTwitch)
    }

    @Test func theFlagsAreOffWhenAbsent() throws {
        let c = try caps(features: #"{"library":true,"chat":true}"#)
        #expect(!c.stage && !c.stageTwitch)
        #expect(!Capabilities.unknown.stage && !Capabilities.unknown.stageTwitch)
    }

    @Test func thePreviewServersWithAStage() {
        for scenario in [PreviewScenario.happy, .renditions, .stageNotConnected, .stageFail] {
            let c = PreviewData.capabilities(for: scenario)
            #expect(c.stage && c.stageTwitch, "\(scenario)")
        }
        #expect(!PreviewData.capabilities(for: .plainCobalt).stage)
        #expect(!PreviewData.capabilities(for: .chatEmpty).stage)
    }

    @Test func theTabIsAfterChatAndShowsOnlyWithTheFlag() {
        var c = Capabilities.unknown
        #expect(!AppTab.stage.isAvailable(with: c))
        c.stage = true
        #expect(AppTab.stage.isAvailable(with: c))
        let all = AppTab.allCases
        #expect(all.firstIndex(of: .stage) == all.firstIndex(of: .chat).map { $0 + 1 })
    }
}

// MARK: - models

struct StageModelTests {
    @Test func theStageDecodesFromTheWire() throws {
        let s = try decode(StageSettings.self, wireStage)
        #expect(s.onAir && s.density == 30 && s.tileSeconds == 10 && s.tileScale == 1.0)
        #expect(s.spotlightAuto && s.spotlightSeconds == 20 && s.sound && s.videoMax == 12)
        #expect(!s.storeOpen && s.storeHint)
        #expect(s.pool == StagePool(kind: .collection, ref: "PrEvIeWcoll00001", name: "memes", count: 24, missing: false))
        #expect(s.liveURL.absoluteString == "https://studio.capybaraharmony.com/live/Zk7Q2abcdefghijklmnopqrstuvwxk7Q2")
        #expect(s.storeURL.absoluteString == "https://studio.capybaraharmony.com/store")
        #expect(s.updatedAt == Date(timeIntervalSince1970: 1_790_000_950))
        let twitch = try #require(s.twitch)
        #expect(twitch.login == "capybaraharmony" && twitch.displayName == "CapybaraHarmony" && twitch.status == .ok)
        #expect(twitch.connectedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(twitch.lastEventAt == Date(timeIntervalSince1970: 1_790_000_900))
        let spotlight = try #require(s.spotlight)
        #expect(spotlight.by == "mochi" && spotlight.action == .summon && spotlight.pinnedUntil == nil)
        #expect(spotlight.at == Date(timeIntervalSince1970: 1_790_000_800))
        #expect(spotlight.item.id == "PrEvIeWstage00002" && spotlight.item.code == "CAT")
    }

    @Test func aStageWithoutTwitchOrSpotlightDecodes() throws {
        let json = """
        {"on_air":false,"pool":{"kind":"library","ref":null,"name":"whole library","count":300,"missing":false},
         "density":5,"tile_seconds":3,"tile_scale":0.5,"spotlight_auto":false,"spotlight_seconds":120,"sound":false,"video_max":0,
         "store_open":true,"store_hint":false,"live_url":"https://studio.capybaraharmony.com/live/abcd","store_url":"https://studio.capybaraharmony.com/store",
         "twitch":null,"spotlight":null,"updated_at":1790000950000}
        """
        let s = try decode(StageSettings.self, json)
        #expect(!s.onAir && s.twitch == nil && s.spotlight == nil)
        #expect(s.pool.kind == .library && s.pool.ref == nil && s.pool.name == "whole library")
        #expect(s.storeOpen && !s.storeHint && !s.sound && s.videoMax == 0)
    }

    @Test func numbersOutsideTheirRangeAreClampedOnTheWayIn() throws {
        let json = wireStage
            .replacingOccurrences(of: "\"density\":30", with: "\"density\":900")
            .replacingOccurrences(of: "\"tile_seconds\":10", with: "\"tile_seconds\":1")
            .replacingOccurrences(of: "\"tile_scale\":1.0", with: "\"tile_scale\":4.0")
        let s = try decode(StageSettings.self, json)
        #expect(s.density == 100 && s.tileSeconds == 3 && s.tileScale == 1.6)
    }

    @Test func aMissingStoreFlagMeansLocked() throws {
        let json = wireStage.replacingOccurrences(of: "\"store_open\":false,", with: "")
        #expect(try !decode(StageSettings.self, json).storeOpen)
    }

    @Test func theLinksAreMaskedAndTheStoreLinkIsPlain() throws {
        let s = try decode(StageSettings.self, wireStage)
        #expect(s.maskedLiveLink == "studio…/live/••••k7Q2")
        #expect(!s.maskedLiveLink.contains("abcdefgh"))
        #expect(s.storeLinkText == "studio.capybaraharmony.com/store")
    }

    @Test func thePreviewLinkAddsPreviewOnce() throws {
        let s = try decode(StageSettings.self, wireStage)
        let preview = s.previewURL.absoluteString
        #expect(preview.hasPrefix("https://studio.capybaraharmony.com/live/Zk7Q2") && preview.hasSuffix("?preview=1"))
        var again = s
        again.liveURL = s.previewURL
        #expect(again.previewURL == s.previewURL)
    }

    @Test func itemsDecodeForTheCanvasAndForTheStore() throws {
        let video = try decode(StageItem.self, wireVideoItem)
        #expect(video.kind == .video && video.duration == 37.43 && video.width == 720 && video.height == 1280)
        #expect(video.thumbnail?.lastPathComponent == "PrEvIeWs000.jpg")
        let image = try decode(StageItem.self, wireItem)
        #expect(image.kind == .image && image.posterURL == nil && image.thumbnail?.lastPathComponent == "PrEvIeWs002.jpg")
        let store = try decode(
            StageItem.self,
            #"{"id":"x","code":"AAA","title":"t","kind":"video","thumb_url":"https://media.capybaraharmony.com/t.jpg","width":null,"height":null}"#)
        #expect(store.url == nil && store.duration == nil && store.thumbnail?.lastPathComponent == "t.jpg")
    }

    @Test func anItemWithOddFieldsStillDecodes() throws {
        let item = try decode(StageItem.self, #"{"id":"x","title":null,"kind":"hologram","url":"not a url at all %%","width":"wide"}"#)
        #expect(item.id == "x" && item.title == "" && item.kind == .image && item.width == nil && item.code == nil)
    }

    @Test func rewardsKeepTheServersTitleAndSync() throws {
        let snapshot = try decode(StageSnapshot.self, wireSnapshot)
        #expect(snapshot.rewards.map(\.action) == [.summon, .chaos, .shuffle, .pin])
        let shuffle = snapshot.rewards[2]
        #expect(shuffle.title == "capystore shuffle" && shuffle.cost == 1000 && shuffle.cooldownSeconds == 120 && shuffle.enabled && !shuffle.synced)
        #expect(!snapshot.rewards[3].enabled)
    }

    @Test func anUnknownRewardIsSkipped() throws {
        let json = #"{"stage":\#(wireStage),"rewards":[{"action":"explode","cost":1},{"action":"pin","cost":300,"cooldown_seconds":60,"enabled":true,"synced":true}]}"#
        let snapshot = try decode(StageSnapshot.self, json)
        #expect(snapshot.rewards.map(\.action) == [.pin])
    }

    @Test func twitchStatusesDecode() throws {
        for (wire, expected) in [("ok", StageTwitch.Status.ok), ("reconnect", .reconnect), ("not_affiliate", .notAffiliate), ("setting_up", .settingUp)] {
            let t = try decode(StageTwitch.self, #"{"login":"a","display_name":"A","connected_at":1,"status":"\#(wire)","last_event_at":null}"#)
            #expect(t.status == expected, "\(wire)")
        }
        // an unknown status is never claimed to be healthy
        #expect(try decode(StageTwitch.self, #"{"login":"a","status":"quantum"}"#).status == .settingUp)
    }

    @Test func redemptionsDecodeIncludingTheOwnersOwn() throws {
        struct Wire: Decodable { var redemptions: [StageRedemption] }
        let list = try decode(Wire.self, wireRedemptions).redemptions
        #expect(list.count == 3)
        #expect(list[0].userName == "mochi" && list[0].input == "cat" && list[0].item?.code == "CAT" && list[0].status == .done)
        #expect(list[0].kind == .summon && !list[0].isOwner)
        #expect(list[0].createdAt == Date(timeIntervalSince1970: 1_790_000_800))
        #expect(list[1].status == .refunded && list[1].reason == .noMatch && list[1].item == nil)
        #expect(list[2].isOwner && list[2].action == "skip" && list[2].kind == nil && list[2].userName == "you")
    }

    @Test func aPoolPageDecodes() throws {
        let json = #"{"status":"success","total":130,"offset":60,"next":120,"items":[\#(wireItem),{"broken":true},\#(wireVideoItem)]}"#
        let page = try decode(StagePoolPage.self, json)
        #expect(page.total == 130 && page.offset == 60 && page.next == 120)
        #expect(page.items.map(\.id) == ["PrEvIeWstage00002", "PrEvIeWstage00000"])
        let last = try decode(StagePoolPage.self, #"{"total":2,"offset":0,"next":null,"items":[]}"#)
        #expect(last.next == nil && last.items.isEmpty)
    }

    @Test func aSpotlightKnowsWhenItIsPinned() throws {
        let now = Date(timeIntervalSince1970: 1_790_001_000)
        var spot = try decode(StageSpotlight.self, wireSpotlight)
        #expect(!spot.isPinned(now: now))
        spot.pinnedUntil = now.addingTimeInterval(60)
        #expect(spot.isPinned(now: now) && !spot.isPinned(now: now.addingTimeInterval(61)))
    }
}

// MARK: - rules and the patch

struct StagePatchTests {
    private func live() throws -> StageSettings { try decode(StageSettings.self, wireStage) }

    @Test func theRangesAreTheContracts() {
        #expect(StageRule.densityRange == 5...100 && StageRule.tileSecondsRange == 3...30)
        #expect(StageRule.tileScaleRange == 0.5...1.6 && StageRule.spotlightSecondsRange == 10...120)
        #expect(StageRule.videoMaxRange == 0...24 && StageRule.costRange == 1...1_000_000 && StageRule.cooldownRange == 0...604_800)
        #expect(StageRule.debounce == 0.3 && StageRule.pollInterval == 4)
    }

    @Test func clampingHoldsEveryNumberInItsRange() {
        let p = StagePatch(density: 4, tileSeconds: 99, tileScale: 0.1, spotlightSeconds: 1, videoMax: 99).clamped()
        #expect(p.density == 5 && p.tileSeconds == 30 && p.tileScale == 0.5 && p.spotlightSeconds == 10 && p.videoMax == 24)
        let q = StagePatch(density: 500, tileSeconds: -3, tileScale: 9, spotlightSeconds: 500, videoMax: -1).clamped()
        #expect(q.density == 100 && q.tileSeconds == 3 && q.tileScale == 1.6 && q.spotlightSeconds == 120 && q.videoMax == 0)
        #expect(StageRule.clamp(.nan, to: StageRule.tileScaleRange) == 0.5)
        #expect(StagePatch(density: 40).clamped().tileSeconds == nil)
    }

    @Test func theBodyHasOnlyWhatIsSetInTheWiresWords() throws {
        #expect(StagePatch().body().isEmpty && StagePatch().isEmpty)
        let body = StagePatch(
            onAir: true, pool: .group(id: "g1"), density: 500, tileSeconds: 12, tileScale: 0.8, spotlightAuto: false,
            spotlightSeconds: 30, sound: false, videoMax: 6, storeOpen: true, storeHint: false).body()
        #expect(body["on_air"] as? Bool == true && body["density"] as? Int == 100 && body["tile_seconds"] as? Int == 12)
        #expect(body["tile_scale"] as? Double == 0.8 && body["spotlight_auto"] as? Bool == false && body["spotlight_seconds"] as? Int == 30)
        #expect(body["sound"] as? Bool == false && body["video_max"] as? Int == 6)
        #expect(body["store_open"] as? Bool == true && body["store_hint"] as? Bool == false)
        let pool = try #require(body["pool"] as? [String: Any])
        #expect(pool["kind"] as? String == "group" && pool["ref"] as? String == "g1" && pool.count == 2)
        #expect(body.count == 11)
    }

    @Test func theLibraryPoolHasNoRef() throws {
        let pool = try #require(StagePatch(pool: .library).body()["pool"] as? [String: Any])
        #expect(pool["kind"] as? String == "library" && pool["ref"] == nil)
        let words = try #require(StagePatch(pool: .search(words: "cats")).body()["pool"] as? [String: Any])
        #expect(words["kind"] as? String == "search" && words["ref"] as? String == "cats")
    }

    @Test func theLastWriteWinsWhenPatchesMerge() {
        let merged = StagePatch(density: 10, tileSeconds: 5).merging(StagePatch(density: 77, sound: false))
        #expect(merged.density == 77 && merged.tileSeconds == 5 && merged.sound == false)
        #expect(StagePatch().merging(StagePatch()).isEmpty)
    }

    @Test func aPatchShowsOnAStageClampedAndWithoutTheServersPool() throws {
        let s = try live()
        let shown = s.applying(StagePatch(pool: .library, density: 3, tileScale: 5, sound: false))
        #expect(shown.density == 5 && shown.tileScale == 1.6 && !shown.sound)
        #expect(shown.pool == s.pool, "the pool's name and count are the server's")
        #expect(shown.tileSeconds == s.tileSeconds)
    }

    @Test func aFailedWritePutsTheOldValuesBack() throws {
        let before = try live()
        let patch = StagePatch(density: 77, sound: false)
        let after = before.applying(patch)
        #expect(after.applying(patch.values(in: before)) == before)
        #expect(patch.values(in: before).density == 30 && patch.values(in: before).tileSeconds == nil)
    }

    @Test func aPoolChoiceKnowsItsKindAndMatches() throws {
        let pool = StagePool(kind: .collection, ref: "c1", name: "memes", count: 3)
        #expect(StagePoolChoice.collection(id: "c1").matches(pool))
        #expect(!StagePoolChoice.group(id: "c1").matches(pool) && !StagePoolChoice.library.matches(pool))
        #expect(StagePoolChoice.library.matches(StagePool(kind: .library)))
        #expect(StagePoolChoice.search(words: "x").kind == .search && StagePoolChoice.group(id: "g").ref == "g")
    }

    @Test func searchWordsAreCleanedAndCut() {
        #expect(StageRule.cleanSearch("  cats doing crimes \n") == "cats doing crimes")
        #expect(StageRule.cleanSearch("a\u{0007}b") == "ab")
        #expect(StageRule.cleanSearch("   ") == nil)
        let long = String(repeating: "x", count: 300)
        #expect(StageRule.cleanSearch(long)?.unicodeScalars.count == StageRule.searchLimit)
    }

    @Test func theTwitchReturnLinkParses() throws {
        #expect(StageTwitchReturn(url: try #require(URL(string: "cobalt-apple://stage?twitch=connected"))) == .connected)
        #expect(StageTwitchReturn(url: try #require(URL(string: "cobalt-apple://stage?twitch=failed&reason=state"))) == .failed(reason: "state"))
        #expect(StageTwitchReturn(url: try #require(URL(string: "cobalt-apple://stage?twitch=failed"))) == .failed(reason: nil))
        #expect(StageTwitchReturn(url: try #require(URL(string: "cobalt-apple://stage"))) == nil)
        #expect(StageTwitchReturn(url: try #require(URL(string: "cobalt-apple://library?twitch=connected"))) == nil)
        #expect(StageTwitchReturn(url: try #require(URL(string: "https://example.com/stage?twitch=connected"))) == nil)
    }

    @Test func errorsAreClassified() {
        #expect(StageError.from(StageError.offAir) == .offAir)
        #expect(StageError.from(PipelineFailure.unsupported) == .off)
        #expect(StageError.from(CobaltError.network(.notConnectedToInternet)) == .offline)
        #expect(StageError.from(URLError(.timedOut)) == .offline)
        #expect(StageError.from(CobaltError.api(code: "error.stage.off_air", httpStatus: 409)) == .offAir)
        #expect(StageError.from(CobaltError.api(code: "error.api.generic", httpStatus: 503)) == .unavailable)
        #expect(StageError.from(CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)) == .other)
        #expect(StageError.from(CancellationError()) == .other)
        #expect(StageError(code: "error.stage.search_unavailable") == .searchUnavailable && StageError(code: "nope") == nil)
    }
}

// MARK: - the routes

struct StageHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { stageKey })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    private func refusing(_ body: String, status: Int) async throws -> LoopbackServer {
        try await LoopbackServer.start { _ in .json(body, status: status) }
    }

    @Test func readIsGetKeyedAndGivesTheStageAndRewards() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/stage" ? .json(wireSnapshot) : .init(status: 404)
        }
        defer { server.stop() }
        let snapshot = try await client(server).stage()
        let req = try #require(server.requests.first)
        #expect(req.headers["authorization"] == "Api-Key \(stageKey)" && req.body.isEmpty)
        #expect(snapshot.stage.onAir && snapshot.rewards.count == 4)
    }

    @Test func patchSendsOnlyWhatIsSetAndClamps() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "PATCH" && req.path == "/stage" ? .json(#"{"status":"success","stage":\#(wireStage)}"#) : .init(status: 404)
        }
        defer { server.stop() }
        let stage = try await client(server).updateStage(StagePatch(pool: .collection(id: "PrEvIeWcoll00001"), density: 999, sound: false))
        let req = try #require(server.requests.first)
        #expect(req.headers["authorization"] == "Api-Key \(stageKey)" && req.headers["content-type"] == "application/json")
        let body = try bodyJSON(req)
        #expect(body["density"] as? Int == 100 && body["sound"] as? Bool == false && body.count == 3)
        let pool = try #require(body["pool"] as? [String: Any])
        #expect(pool["kind"] as? String == "collection" && pool["ref"] as? String == "PrEvIeWcoll00001")
        #expect(stage.pool.name == "memes")
    }

    @Test func rotateIsAPostWithNoBody() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "POST" && req.path == "/stage/rotate" ? .json(#"{"status":"success","stage":\#(wireStage)}"#) : .init(status: 404)
        }
        defer { server.stop() }
        let stage = try await client(server).rotateStage()
        #expect(try #require(server.requests.first).body.isEmpty && stage.liveURL.lastPathComponent.hasSuffix("k7Q2"))
    }

    @Test func actionSendsTheTypeAndTheItemOnlyForASpotlightPick() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "POST" && req.path == "/stage/action" ? .json(#"{"status":"success","stage":\#(wireStage)}"#) : .init(status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        for action in [StageAction.skip, .pin, .unpin, .shuffle, .chaos, .spotlight(itemID: "PrEvIeWstage00002")] {
            _ = try await c.stageAction(action)
        }
        let bodies = try server.requests.map(bodyJSON)
        #expect(bodies.map { $0["type"] as? String } == ["skip", "pin", "unpin", "shuffle", "chaos", "spotlight"])
        #expect(bodies[0].count == 1 && bodies[5]["item_id"] as? String == "PrEvIeWstage00002" && bodies[5].count == 2)
    }

    @Test func poolPagesWithOffsetAndLimit() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/stage/pool"
                ? .json(#"{"status":"success","total":2,"offset":0,"next":null,"items":[\#(wireItem),\#(wireVideoItem)]}"#) : .init(status: 404)
        }
        defer { server.stop() }
        let page = try await client(server).stagePool(offset: 60, limit: 500)
        let req = try #require(server.requests.first)
        #expect(req.query == "offset=60&limit=100", "the limit is held to 100")
        #expect(req.headers["authorization"] == "Api-Key \(stageKey)")
        #expect(page.items.count == 2 && page.next == nil)
    }

    @Test func redemptionsAskForLimitAndBefore() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/stage/redemptions" ? .json(wireRedemptions) : .init(status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        let list = try await c.stageRedemptions(limit: 30, before: nil)
        _ = try await c.stageRedemptions(limit: 30, before: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(server.requests[0].query == "limit=30" && server.requests[1].query == "limit=30&before=1790000000000")
        #expect(list.count == 3 && list[0].userName == "mochi")
    }

    @Test func rewardPatchSendsOnlyWhatIsGivenAndClamps() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "PATCH" && req.path == "/stage/rewards/chaos"
                ? .json(#"{"status":"success","reward":{"action":"chaos","title":"chaos","cost":2500,"cooldown_seconds":300,"enabled":true,"synced":false}}"#)
                : .init(status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        let reward = try await c.updateStageReward(.chaos, cost: 2_500, cooldownSeconds: nil, enabled: nil)
        _ = try await c.updateStageReward(.chaos, cost: 0, cooldownSeconds: 9_999_999, enabled: false)
        let bodies = try server.requests.map(bodyJSON)
        #expect(bodies[0]["cost"] as? Int == 2_500 && bodies[0].count == 1)
        #expect(bodies[1]["cost"] as? Int == 1 && bodies[1]["cooldown_seconds"] as? Int == 604_800 && bodies[1]["enabled"] as? Bool == false)
        #expect(reward.cost == 2_500 && !reward.synced)
    }

    @Test func connectGivesTheAuthorizeURLAndDisconnectDeletes() async throws {
        let authorize = "https://id.twitch.tv/oauth2/authorize?response_type=code&client_id=abc&scope=channel%3Amanage%3Aredemptions&state=xyz&force_verify=true"
        let server = try await LoopbackServer.start { req in
            switch (req.method, req.path) {
            case ("POST", "/stage/twitch/connect"): return .json(#"{"status":"success","authorize_url":"\#(authorize)"}"#)
            case ("DELETE", "/stage/twitch"): return .json(#"{"status":"success","stage":\#(wireStage)}"#)
            default: return .init(status: 404)
            }
        }
        defer { server.stop() }
        let c = client(server)
        let url = try await c.connectStageTwitch()
        #expect(url.absoluteString == authorize)
        _ = try await c.disconnectStageTwitch()
        #expect(server.requests.map(\.method) == ["POST", "DELETE"])
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == "Api-Key \(stageKey)" })
    }

    @Test func errorsAreMapped() async throws {
        let cases: [(String, Int, StageError)] = [
            (#"{"status":"error","error":{"code":"error.stage.bad_request"}}"#, 400, .badRequest),
            (#"{"status":"error","error":{"code":"error.stage.off"}}"#, 404, .off),
            (#"{"status":"error","error":{"code":"error.stage.not_found"}}"#, 404, .notFound),
            (#"{"status":"error","error":{"code":"error.stage.twitch_off"}}"#, 404, .twitchOff),
            (#"{"status":"error","error":{"code":"error.stage.off_air"}}"#, 409, .offAir),
            (#"{"status":"error","error":{"code":"error.stage.search_unavailable"}}"#, 503, .searchUnavailable),
            (#"{"status":"error","error":{"code":"error.api.generic"}}"#, 503, .unavailable),
        ]
        for (body, status, expected) in cases {
            let server = try await refusing(body, status: status)
            defer { server.stop() }
            let c = client(server)
            await #expect(throws: expected, "stage \(status) \(expected)") { try await c.stage() }
            await #expect(throws: expected, "patch \(status) \(expected)") { try await c.updateStage(StagePatch(density: 10)) }
            await #expect(throws: expected, "action \(status) \(expected)") { try await c.stageAction(.skip) }
            await #expect(throws: expected, "connect \(status) \(expected)") { try await c.connectStageTwitch() }
        }
    }

    @Test func anyOtherRefusalStaysTheGenericOne() async throws {
        let revoked = try await refusing(#"{"status":"error","error":{"code":"error.api.auth.key.invalid"}}"#, status: 401)
        defer { revoked.stop() }
        await #expect(throws: CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)) { try await client(revoked).stage() }
    }

    @Test func anUnreadableAnswerIsInvalid() async throws {
        let server = try await refusing(#"{"status":"success"}"#, status: 200)
        defer { server.stop() }
        await #expect(throws: CobaltError.invalidResponse(httpStatus: 200)) { try await client(server).stage() }
        await #expect(throws: CobaltError.invalidResponse(httpStatus: 200)) { try await client(server).rotateStage() }
    }

    @Test func aMissingKeyNeverReachesTheNetwork() async throws {
        let server = try await LoopbackServer.start { _ in .json(wireSnapshot) }
        defer { server.stop() }
        let noKey = HTTPCobaltClient(baseURL: server.base, apiKey: { nil })
        await #expect(throws: CobaltError.noAPIKey) { try await noKey.stage() }
        #expect(server.requests.isEmpty)
    }

    @Test func aClientThatPredatesTheRoutesSaysUnsupported() async {
        struct Bare: CobaltClient {
            var baseURL: URL { URL(string: "https://x.test")! }
            func capabilities() async -> Capabilities { .unknown }
            func resolve(_ link: URL) async throws -> CobaltResult { throw PipelineFailure.unsupported }
            func createStudio(link: URL) async throws -> StudioCreated { throw PipelineFailure.unsupported }
            func upload(file: URL, name: String, contentType: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult { throw PipelineFailure.unsupported }
            func session(_ id: String, wait: Int) async throws -> StudioSession { throw PipelineFailure.unsupported }
            func sourceURL(session id: String) -> URL { baseURL }
            func render(session id: String, _ request: RenderRequest) async throws -> String { throw PipelineFailure.unsupported }
            func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus { throw PipelineFailure.unsupported }
            func publish(session id: String) async throws -> HostedFile { throw PipelineFailure.unsupported }
            func publish(item id: String) async throws -> HostedFile { throw PipelineFailure.unsupported }
            func openStudio(item id: String) async throws -> StudioCreated { throw PipelineFailure.unsupported }
            func library(cursor: String?, limit: Int) async throws -> LibraryPage { throw PipelineFailure.unsupported }
            func deleteMedia(name: String) async throws {}
            func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult { throw PipelineFailure.unsupported }
            func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {}
            func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply { throw PipelineFailure.unsupported }
            func relayLiveState(run: UUID, _ state: LiveContentState) async throws {}
            func endLiveRun(_ run: UUID) async throws {}
            func liveSelftest() async throws -> LiveSelftest { throw PipelineFailure.unsupported }
            func download(_ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL { destination }
        }
        let bare = Bare()
        await #expect(throws: PipelineFailure.unsupported) { try await bare.stage() }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.updateStage(StagePatch(density: 10)) }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.rotateStage() }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.stageAction(.skip) }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.stagePool(offset: 0, limit: 10) }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.stageRedemptions(limit: 10, before: nil) }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.updateStageReward(.pin, cost: 1, cooldownSeconds: nil, enabled: nil) }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.connectStageTwitch() }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.disconnectStageTwitch() }
    }
}

// MARK: - the store on the preview server

@MainActor
struct StageStoreTests {
    private func app(_ scenario: PreviewScenario = .happy) -> AppModel {
        AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
    }

    private func server(_ app: AppModel) throws -> PreviewStageState {
        try #require(app.ctx.client as? PreviewClient).stageState
    }

    @Test func loadReadsTheConnectedStageOnAir() async throws {
        let app = app()
        #expect(app.stage.state == .idle && app.stage.stage == nil)
        await app.stage.load()
        #expect(app.stage.state == .loaded)
        let stage = try #require(app.stage.stage)
        #expect(stage.onAir && stage.pool.kind == .collection && stage.pool.name == "memes" && stage.density == 30)
        #expect(!stage.storeOpen, "the store starts locked")
        #expect(stage.twitch?.status == .ok && stage.spotlight?.by == "mochi")
        #expect(app.stage.rewards.map(\.action) == [.summon, .chaos, .shuffle, .pin])
        #expect(app.stage.reward(.pin)?.enabled == false && app.stage.reward(.summon)?.cost == 500)
    }

    @Test func theNotConnectedScenarioIsOffAirWithNoTwitch() async throws {
        let app = app(.stageNotConnected)
        await app.stage.load()
        let stage = try #require(app.stage.stage)
        #expect(!stage.onAir && stage.twitch == nil && stage.spotlight == nil && stage.pool.kind == .library)
        #expect(app.stage.rewards.count == 4 && app.stage.rewards.allSatisfy { !$0.synced })
    }

    @Test func aFailingServerGivesTheFailedState() async {
        let app = app(.stageFail)
        await app.stage.load()
        #expect(app.stage.state == .failed(.unavailable) && app.stage.stage == nil)
    }

    @Test func aFailedReloadKeepsWhatWasLoaded() async throws {
        let app = app()
        await app.stage.load()
        try server(app).loadFails = true
        await app.stage.load()
        #expect(app.stage.state == .failed(.unavailable) && app.stage.stage?.onAir == true && app.stage.rewards.count == 4)
    }

    @Test func aServerChangeForgetsTheStage() async {
        let app = app()
        await app.stage.load()
        app.stage.reset()
        #expect(app.stage.stage == nil && app.stage.rewards.isEmpty && app.stage.state == .idle && app.stage.redemptions.isEmpty)
    }

    @Test func goLiveAndStop() async throws {
        let app = app(.stageNotConnected)
        await app.stage.load()
        try await app.stage.setOnAir(true)
        #expect(app.stage.stage?.onAir == true)
        #expect(try server(app).stage.onAir)
        try await app.stage.setOnAir(false)
        #expect(app.stage.stage?.onAir == false)
    }

    @Test func theStoreLockIsASwitch() async throws {
        let app = app()
        await app.stage.load()
        try await app.stage.setStoreOpen(true)
        #expect(app.stage.stage?.storeOpen == true)
        try await app.stage.setStoreOpen(false)
        #expect(app.stage.stage?.storeOpen == false)
    }

    @Test func pickingAPoolShowsTheServersName() async throws {
        let app = app()
        await app.shareSets.refresh()
        await app.stage.load()
        try await app.stage.setPool(.collection(id: "PrEvIeWcoll00002"))
        #expect(app.stage.stage?.pool.name == "for discord" && app.stage.stage?.pool.kind == .collection)
        try await app.stage.setPool(.group(id: "PrEvIeWgrup00001"))
        #expect(app.stage.stage?.pool.name == "weekend" && app.stage.stage?.pool.kind == .group)
        try await app.stage.setPool(.search(words: "  cats doing crimes "))
        #expect(app.stage.stage?.pool.name == "cats doing crimes" && app.stage.stage?.pool.kind == .search)
        try await app.stage.setPool(.library)
        #expect(app.stage.stage?.pool.kind == .library && app.stage.stage?.pool.ref == nil)
    }

    @Test func aBadPoolIsRefusedAndNothingChanges() async throws {
        let app = app()
        await app.stage.load()
        let before = app.stage.stage
        await #expect(throws: StageError.badRequest) { try await app.stage.setPool(.collection(id: "gone")) }
        await #expect(throws: StageError.badRequest) { try await app.stage.setPool(.search(words: "   ")) }
        #expect(app.stage.stage == before)
        try server(app).searchUnavailable = true
        await #expect(throws: StageError.searchUnavailable) { try await app.stage.setPool(.search(words: "cats")) }
        #expect(app.stage.stage == before)
    }

    @Test func aRefusedSwitchPutsTheOldValueBack() async throws {
        let app = app()
        await app.stage.load()
        let client = try #require(app.ctx.client as? PreviewClient)
        // a collection that is not there makes the server refuse the whole patch
        await #expect(throws: StageError.badRequest) {
            try await app.stage.apply(StagePatch(pool: .collection(id: "gone"), sound: false))
        }
        #expect(app.stage.stage?.sound == true, "the optimistic value was put back")
        #expect(client.stageState.patches.count == 1)
    }

    // MARK: sliders

    @Test func aBurstOfSliderMovesIsOneRequestWithTheLastValue() async throws {
        let app = app()
        await app.stage.load()
        for value in [12, 40, 63, 250] { app.stage.setDensity(value) }
        #expect(app.stage.stage?.density == 100, "shown at once, clamped")
        app.stage.setTileSeconds(2)
        #expect(app.stage.stage?.tileSeconds == 3)
        await app.stage.settle()
        let patches = try server(app).patches
        #expect(patches.count == 1, "one request for the burst")
        #expect(patches[0].density == 100 && patches[0].tileSeconds == 3 && patches[0].sound == nil && patches[0].onAir == nil)
        #expect(app.stage.stage?.density == 100 && app.stage.stage?.tileSeconds == 3)
        #expect(try server(app).stage.density == 100)
    }

    @Test func aMoveAfterTheSendGoesInASecondRequest() async throws {
        let app = app()
        await app.stage.load()
        app.stage.setDensity(50)
        await app.stage.settle()
        app.stage.setDensity(60)
        await app.stage.settle()
        let patches = try server(app).patches
        #expect(patches.map(\.density) == [50, 60])
        #expect(app.stage.stage?.density == 60)
    }

    @Test func aSliderBeforeTheStageIsLoadedDoesNothing() async throws {
        let app = app()
        app.stage.setDensity(50)
        await app.stage.settle()
        let state = try server(app)
        #expect(app.stage.stage == nil && state.patches.isEmpty)
    }

    @Test func aServerChangeDropsSliderValuesNotYetSent() async throws {
        let app = app()
        await app.stage.load()
        app.stage.setVideoMax(99)
        #expect(app.stage.stage?.videoMax == 24)
        // the preview server refuses a write only for a pool, so a failed slider write is not reachable here: a reset
        // (another server) must at least drop what was waiting to be sent
        app.stage.reset()
        await app.stage.settle()
        #expect(app.stage.notice == nil && app.stage.stage == nil, "a reset drops what was pending")
    }

    // MARK: actions

    @Test func anActionNeedsTheStageOnAir() async throws {
        let app = app(.stageNotConnected)
        await app.stage.load()
        await #expect(throws: StageError.offAir) { try await app.stage.perform(.skip) }
        try await app.stage.setOnAir(true)
        try await app.stage.perform(.skip)
        #expect(app.stage.stage?.spotlight != nil)
    }

    @Test func pinAndUnpinTouchTheSpotlight() async throws {
        let app = app()
        await app.stage.load()
        try await app.stage.perform(.pin)
        let pinned = try #require(app.stage.stage?.spotlight)
        #expect(pinned.isPinned(now: Date()))
        try await app.stage.perform(.unpin)
        #expect(app.stage.stage?.spotlight?.pinnedUntil == nil)
    }

    @Test func aPickPutsThatItemInTheSpotlightAndShowsAYouLine() async throws {
        let app = app()
        await app.stage.load()
        await app.stage.loadPool()
        let pick = try #require(app.stage.poolItems.last)
        try await app.stage.perform(.spotlight(itemID: pick.id))
        let spotlight = try #require(app.stage.stage?.spotlight)
        #expect(spotlight.item.id == pick.id && spotlight.action == .owner && spotlight.by == nil)
        let first = try #require(app.stage.redemptions.first)
        #expect(first.isOwner && first.userName == "you" && first.action == "spotlight")
        await #expect(throws: StageError.notFound) { try await app.stage.perform(.spotlight(itemID: "not in the pool")) }
    }

    @Test func rotateGivesANewLink() async throws {
        let app = app()
        await app.stage.load()
        let before = try #require(app.stage.stage).liveURL
        try await app.stage.rotate()
        let after = try #require(app.stage.stage).liveURL
        #expect(after != before && !after.absoluteString.hasSuffix("k7Q2"))
        #expect(app.stage.stage?.maskedLiveLink.hasSuffix("r001") == true)
    }

    // MARK: rewards

    @Test func aRewardSavesItsCostCooldownAndSwitch() async throws {
        let app = app()
        await app.stage.load()
        try await app.stage.updateReward(.chaos, cost: 2_500)
        #expect(app.stage.reward(.chaos)?.cost == 2_500 && app.stage.reward(.chaos)?.cooldownSeconds == 300)
        try await app.stage.updateReward(.pin, enabled: true)
        #expect(app.stage.reward(.pin)?.enabled == true)
        try await app.stage.updateReward(.shuffle, cost: 0, cooldownSeconds: 99_999_999)
        #expect(app.stage.reward(.shuffle)?.cost == 1 && app.stage.reward(.shuffle)?.cooldownSeconds == 604_800)
        #expect(app.stage.rewards.map(\.action) == [.summon, .chaos, .shuffle, .pin], "the order holds")
    }

    @Test func aRewardNotSyncedToTwitchSaysSo() async throws {
        let app = app(.stageNotConnected)
        await app.stage.load()
        try await app.stage.updateReward(.summon, cost: 600)
        #expect(app.stage.reward(.summon)?.cost == 600 && app.stage.reward(.summon)?.synced == false)
    }

    // MARK: Twitch

    @Test func connectingGivesTheAuthorizeURLAndTheNextLoadFindsItConnected() async throws {
        let app = app(.stageNotConnected)
        await app.stage.load()
        #expect(app.stage.stage?.twitch == nil)
        let url = try await app.stage.connectTwitch()
        #expect(url.host == "id.twitch.tv" && url.absoluteString.contains("channel%3Amanage%3Aredemptions"))
        #expect(app.stage.stage?.twitch == nil, "nothing is claimed until the sign-in comes back")
        await app.stage.load()
        #expect(app.stage.stage?.twitch?.login == "capybaraharmony" && app.stage.reward(.summon)?.synced == true)
    }

    @Test func disconnectingTakesTwitchOffTheStage() async throws {
        let app = app()
        await app.stage.load()
        try await app.stage.disconnectTwitch()
        #expect(app.stage.stage?.twitch == nil)
        #expect(app.stage.rewards.count == 4 && app.stage.rewards.allSatisfy { !$0.synced })
    }

    @Test func theTwitchReturnLinkOpensTheStudioTab() async throws {
        let app = app()
        app.selectedTab = .save
        app.open(try #require(URL(string: "cobalt-apple://stage?twitch=connected")))
        #expect(app.selectedTab == .stage)
        for _ in 0..<200 where app.stage.state != .loaded { try await Task.sleep(for: .milliseconds(5)) }
        #expect(app.stage.state == .loaded && app.stage.stage != nil, "it reads the stage again")
    }

    @Test func theStudioTabLeavesWhenTheServerLosesTheStage() {
        let app = app()
        app.selectedTab = .stage
        var caps = app.capabilities
        caps.stage = false
        app.apply(caps)
        #expect(app.selectedTab == .save)
    }

    // MARK: the feed and the pool

    @Test func theFeedIsNewestFirst() async throws {
        let app = app()
        #expect(app.stage.redemptions.isEmpty)
        await app.stage.refreshRedemptions()
        #expect(app.stage.redemptions.count == 7 && app.stage.redemptions[0].userName == "mochi")
        #expect(app.stage.redemptions[5].reason == .noMatch && app.stage.redemptions[6].isOwner)
        #expect(!app.stage.feedProblem)
    }

    @Test func aFailingFeedKeepsWhatItHad() async throws {
        let app = app()
        await app.stage.refreshRedemptions()
        try server(app).loadFails = true
        await app.stage.refreshRedemptions()
        #expect(app.stage.redemptions.count == 7 && app.stage.feedProblem)
        try server(app).loadFails = false
        await app.stage.refreshRedemptions()
        #expect(!app.stage.feedProblem)
    }

    @Test func thePoolPagesSixtyAtATime() async throws {
        let app = app()
        await app.stage.load()
        #expect(app.stage.poolState == .idle && app.stage.poolItems.isEmpty)
        await app.stage.loadPool()
        // the connected stage's collection holds 24 of the 72 public files
        #expect(app.stage.poolItems.count == 24 && app.stage.poolTotal == 24 && !app.stage.poolHasMore && app.stage.poolState == .loaded)
        try await app.stage.setPool(.library)
        await app.stage.loadPool()
        #expect(app.stage.poolItems.count == 60 && app.stage.poolTotal == 72 && app.stage.poolHasMore)
        await app.stage.loadMorePool()
        #expect(app.stage.poolItems.count == 72 && !app.stage.poolHasMore)
        #expect(Set(app.stage.poolItems.map(\.id)).count == 72, "no item twice")
        await app.stage.loadMorePool()
        #expect(app.stage.poolItems.count == 72, "the last page is not asked for again")
        let codes = app.stage.poolItems.compactMap(\.code)
        #expect(codes.count == 72 && Set(codes).count == 72, "every item has its own code")
    }
}

// MARK: - time: the debounce and the 4 s feed

@MainActor
struct StageRig {
    let clock = VirtualClock()
    let app: AppModel

    init(_ scenario: PreviewScenario = .happy) {
        app = AppModel.makePreview(scenario, timeScale: 1, clock: clock)
    }

    var client: PreviewClient { app.ctx.client as! PreviewClient }
    var server: PreviewStageState { client.stageState }
    func calls(_ call: String) -> Int { server.calls.filter { $0 == call }.count }

    func settle() async {
        var last = clock.registrations
        var stable = 0
        while stable < 4 {
            try? await Task.sleep(for: .milliseconds(1))
            let r = clock.registrations
            if r == last { stable += 1 } else { stable = 0; last = r }
        }
    }

    func drive(until condition: @MainActor () -> Bool, maxVirtualSeconds: Double = 300) async {
        let start = clock.elapsed
        var idle = 0
        while !condition(), clock.elapsed - start < maxVirtualSeconds {
            await settle()
            if condition() { return }
            if clock.advance() { idle = 0 } else {
                idle += 1
                if idle > 30 { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func loadStage() async {
        let task = Task { @MainActor in await app.stage.load() }
        await drive(until: { app.stage.state == .loaded })
        await task.value
    }
}

@MainActor
struct StageTimingTests {
    @Test func aSliderIsSentThreeHundredMillisecondsAfterTheLastMove() async throws {
        let rig = StageRig()
        await rig.loadStage()
        rig.app.stage.setDensity(40)
        await rig.settle()
        let first = try #require(rig.clock.nextWake)
        #expect(abs(first - (rig.clock.elapsed + 0.3)) < 0.001)
        #expect(rig.server.patches.isEmpty)
        // a later move restarts the wait: nothing was sent for the first one
        rig.clock.jump(by: 0.2)
        rig.app.stage.setDensity(55)
        await rig.settle()
        #expect(rig.server.patches.isEmpty)
        await rig.drive(until: { rig.server.patches.count == 1 && rig.app.stage.stage?.density == 55 && !rig.app.stage.isPolling })
        #expect(rig.server.patches.map(\.density) == [55])
        #expect(rig.app.stage.stage?.density == 55)
    }

    @Test func theFeedIsReadEveryFourSecondsOnlyWhileItIsAskedFor() async throws {
        let rig = StageRig()
        await rig.loadStage()
        #expect(rig.calls("GET redemptions") == 0, "nothing is read before the screen asks")
        rig.app.stage.startPolling()
        #expect(rig.app.stage.isPolling)
        await rig.settle()
        #expect(rig.calls("GET redemptions") == 1, "the first read is at once")
        // the read takes 0.1 s, then the next waits 4 s
        rig.clock.advance()
        await rig.settle()
        let next = try #require(rig.clock.nextWake)
        #expect(abs(next - (rig.clock.elapsed + 4)) < 0.001)
        rig.app.stage.startPolling()                    // already polling: not doubled
        await rig.settle()
        rig.app.stage.stopPolling()
        #expect(!rig.app.stage.isPolling)
        let reads = rig.calls("GET redemptions")
        for _ in 0..<10 {
            rig.clock.advance()
            await rig.settle()
        }
        #expect(rig.calls("GET redemptions") == reads, "stopped means no more reads")
    }

    @Test func aFailingFeedBacksOff() async throws {
        let rig = StageRig()
        await rig.loadStage()
        rig.server.loadFails = true
        rig.app.stage.startPolling()
        await rig.settle()
        rig.clock.advance()                              // the failed read's own latency
        await rig.settle()
        #expect(rig.app.stage.feedProblem)
        let next = try #require(rig.clock.nextWake)
        #expect(abs(next - (rig.clock.elapsed + 8)) < 0.001, "4 s doubled after the first failure")
        rig.app.stage.stopPolling()
    }
}

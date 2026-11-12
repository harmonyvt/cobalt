import Foundation
import Testing
@testable import CobaltKit

// 7TV accounts (APP-API-CONTRACT 57): the wire shapes of 57.4/57.5, the refusals, the bookmarklet's link and the token checks,
// the paths and bodies of every route, and the store and set model on the preview server.

private let sevenTvKey = "2d6b9e10-5c3a-4f7e-8a21-9b0c4d7e1f35"
private let fakeToken = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIwMUdCMlMyQkNSIn0.c2lnbmF0dXJlLXBhcnQ"

private let wireAccount = """
{"id":"01GB2S2BCR000AHHX5S1Y9TQW2","name":"capybaraharmony","avatar_url":"https://cdn.7tv.app/user/01GB2S2BCR000AHHX5S1Y9TQW2/av_1/3x.webp",
 "linked_at":1790000000000,"expires_at":1792592000000,"status":"ok"}
"""

private let wireChannels = """
[{"id":"01GB2S2BCR000AHHX5S1Y9TQW2","name":"capybaraharmony","avatar_url":null,"you":true,"active_set_id":"01HM0000000000000000MAIN01",
  "can":{"manage_sets":false,"create_sets":false,"make_live":false}},
 {"id":"01GC0000000000000000L1AC4T","name":"liacat","avatar_url":"","you":false,"active_set_id":null,
  "can":{"manage_sets":true,"create_sets":true,"make_live":false}},
 {"name":"no id, dropped"}]
"""

private let wireStatus = """
{"status":"success","linked":true,"account":\(wireAccount),"channels":\(wireChannels)}
"""

private let wireSets = """
{"status":"success","channel_id":"01GB2S2BCR000AHHX5S1Y9TQW2","active_set_id":"01HM0000000000000000MAIN01","sets":[
 {"id":"01HM0000000000000000MAIN01","name":"main","capacity":500,"count":310,"live":true},
 {"id":"01HM00000000000000CHR15TM5","name":"christmas","capacity":null,"count":92,"live":false}]}
"""

private let wireSetInfo = """
{"id":"01HM0000000000000000MAIN01","name":"main","capacity":500,"count":310,"owner_id":"01GB2S2BCR000AHHX5S1Y9TQW2","live":true}
"""

private let wirePage = """
{"status":"success","set":\(wireSetInfo),"page":1,"has_more":true,"emotes":[
 {"emote_id":"01F6MQ33FG000FFJ97ZB8MWV52","alias":"catJAM","name":"catJAM","renamed":false,"animated":true,
  "preview_url":"https://cdn.7tv.app/emote/01F6MQ33FG000FFJ97ZB8MWV52/2x.webp","file_url":"https://cdn.7tv.app/emote/01F6MQ33FG000FFJ97ZB8MWV52/4x.webp",
  "added_at":1790000000000},
 {"emote_id":"01F00000000000000000000001","alias":"liaWave","name":"peepoHey","renamed":true,"animated":false,
  "preview_url":null,"file_url":null,"added_at":null}]}
"""

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try CobaltJSON.decoder().decode(T.self, from: Data(json.utf8))
}

// MARK: - shapes

struct SevenTvShapeTests {
    @Test func aLinkedStatusDecodesWithTheOwnChannelFirstAndAllRights() throws {
        let status = try decode(SevenTvStatus.self, wireStatus)
        #expect(status.linked && !status.needsRelink)
        let account = try #require(status.account)
        #expect(account.name == "capybaraharmony" && account.status == .ok)
        #expect(account.avatarURL?.host() == "cdn.7tv.app")
        #expect(account.linkedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(status.channels.count == 2, "a row without an id is dropped, not the answer")
        #expect(status.channels[0].you && status.channels[0].can == .all, "the own channel can do everything")
        #expect(status.channels[0].activeSetID == "01HM0000000000000000MAIN01")
        #expect(status.channels[1].can == SevenTvRights(manageSets: true, createSets: true, makeLive: false))
        #expect(status.channels[1].avatarURL == nil && status.channels[1].activeSetID == nil)
    }

    @Test func notLinkedAndRelinkDecode() throws {
        let off = try decode(SevenTvStatus.self, #"{"status":"success","linked":false}"#)
        #expect(!off.linked && off.account == nil && off.channels.isEmpty)
        let relink = try decode(
            SevenTvStatus.self,
            #"{"status":"success","linked":true,"account":{"id":"x","name":"capybaraharmony","linked_at":1,"expires_at":null,"status":"relink"},"channels":[]}"#)
        #expect(relink.needsRelink && relink.channels.isEmpty && relink.account?.expiresAt == nil)
    }

    @Test func expiryCountsWholeDaysAndShowsUnderSeven() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var account = SevenTvUser(id: "x", name: "a", expiresAt: now.addingTimeInterval(5 * 86_400 + 60))
        #expect(account.daysLeft(now: now) == 5 && account.expiresSoon(now: now))
        account.expiresAt = now.addingTimeInterval(20 * 86_400)
        #expect(!account.expiresSoon(now: now))
        account.expiresAt = now.addingTimeInterval(-1)
        #expect(account.daysLeft(now: now) == nil && !account.expiresSoon(now: now))
    }

    @Test func aChannelsSetsDecodeAndOrderLiveFirst() throws {
        let sets = try decode(SevenTvChannelSets.self, wireSets)
        #expect(sets.channelID == "01GB2S2BCR000AHHX5S1Y9TQW2" && sets.activeSetID == "01HM0000000000000000MAIN01")
        #expect(sets.sets.map(\.name) == ["main", "christmas"])
        #expect(sets.sets[0].fill == 0.62 && sets.sets[1].capacity == nil && sets.sets[1].fill == 0)
        let ordered = SevenTvChannelSets.ordered([
            SevenTvSetRow(id: "b", name: "subathon", capacity: 500, count: 1, live: false),
            SevenTvSetRow(id: "a", name: "Christmas", capacity: 500, count: 1, live: false),
            SevenTvSetRow(id: "c", name: "zzz", capacity: 500, count: 1, live: true),
        ])
        #expect(ordered.map(\.id) == ["c", "a", "b"])
    }

    @Test func aSetPageDecodesItsEmotes() throws {
        let page = try decode(SevenTvSetPage.self, wirePage)
        #expect(page.set.ownerID == "01GB2S2BCR000AHHX5S1Y9TQW2" && page.set.live && page.set.count == 310)
        #expect(page.page == 1 && page.hasMore && page.emotes.count == 2)
        let jam = page.emotes[0]
        #expect(jam.id == "01F6MQ33FG000FFJ97ZB8MWV52/catJAM" && !jam.renamed && jam.animated)
        #expect(jam.previewURL?.absoluteString.hasSuffix("/2x.webp") == true && jam.fileURL?.absoluteString.hasSuffix("/4x.webp") == true)
        let wave = page.emotes[1]
        #expect(wave.alias == "liaWave" && wave.name == "peepoHey" && wave.renamed && wave.previewURL == nil && wave.addedAt == nil)
    }

    @Test func aRenameSetAnswerWithoutCountsStillDecodes() throws {
        let set = try decode(SevenTvSetInfo.self, #"{"id":"01HM0000000000000000MAIN01","name":"main 2","capacity":null}"#)
        #expect(set.name == "main 2" && set.count == 0 && set.capacity == nil && !set.live && set.ownerID == nil)
    }

    @Test func theWriteAnswersDecode() throws {
        let add = try decode(SevenTvEmoteChange.self, #"{"status":"success","set_id":"s","emote_id":"e","alias":"liaWave"}"#)
        #expect(add.setID == "s" && add.emoteID == "e" && add.alias == "liaWave" && !add.removed)
        let removed = try decode(SevenTvEmoteChange.self, #"{"status":"success","set_id":"s","emote_id":"e","removed":true}"#)
        #expect(removed.removed && removed.alias == nil)
        let live = try decode(SevenTvLiveChange.self, #"{"status":"success","channel_id":"c","active_set_id":null}"#)
        #expect(live.channelID == "c" && live.activeSetID == nil)
    }
}

// MARK: - refusals, link, rules

struct SevenTvRuleTests {
    @Test func errorCodesAreClassifiedWithSevenTvsMessage() {
        #expect(SevenTvError(code: "error.seventv.not_linked") == .notLinked)
        #expect(SevenTvError(code: "error.seventv.relink") == .relink)
        #expect(SevenTvError(code: "error.seventv.token_invalid") == .tokenInvalid)
        #expect(SevenTvError(code: "error.seventv.forbidden", message: "you do not have permission") == .forbidden("you do not have permission"))
        #expect(SevenTvError(code: "error.seventv.rejected", message: "  ") == .rejected(nil))
        #expect(SevenTvError(code: "error.seventv.rate_limited") == .rateLimited)
        #expect(SevenTvError(code: "error.seventv.unavailable") == .unavailable)
        #expect(SevenTvError(code: "error.seventv.not_ready") == .notReady)
        #expect(SevenTvError(code: "error.seventv.not_found") == .notFound)
        #expect(SevenTvError(code: "error.stage.off") == nil)
        #expect(SevenTvError.from(PipelineFailure.unsupported) == .off)
        #expect(SevenTvError.from(CobaltError.api(code: "error.api.not_found", httpStatus: 404)) == .off)
        #expect(SevenTvError.from(CobaltError.network(.notConnectedToInternet)) == .offline)
        #expect(SevenTvError.from(CobaltError.api(code: "error.seventv.relink", httpStatus: 409)) == .relink)
        #expect(SevenTvError.relink.needsLink && SevenTvError.notLinked.needsLink && !SevenTvError.rateLimited.needsLink)
        #expect(SevenTvError.rejected("set is full").message == "set is full")
    }

    @Test func theBookmarkletsLinkGivesTheToken() throws {
        let encoded = fakeToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let url = try #require(URL(string: "cobalt-apple://7tv-link?token=\(encoded)"))
        #expect(SevenTvLink.isLink(url))
        #expect(SevenTvLink.token(from: url) == fakeToken)
        let quoted = try #require(URL(string: "COBALT-APPLE://7TV-LINK?token=%22\(encoded)%22"))
        #expect(SevenTvLink.token(from: quoted) == fakeToken, "the quotes localStorage keeps go")
        #expect(SevenTvLink.token(from: try #require(URL(string: "cobalt-apple://7tv-link"))) == nil)
        #expect(SevenTvLink.token(from: try #require(URL(string: "cobalt-apple://stage?token=abc"))) == nil)
        #expect(!SevenTvLink.isLink(try #require(URL(string: "https://7tv-link/?token=abc"))))
    }

    @Test func aLoggedLinkNeverCarriesTheToken() throws {
        let url = try #require(URL(string: "cobalt-apple://7tv-link?token=\(fakeToken)"))
        let logged = SevenTvLink.redacted(url)
        #expect(!logged.contains(fakeToken) && !logged.contains("eyJ") && logged.contains("7tv-link"))
        let other = try #require(URL(string: "cobalt-apple://library"))
        #expect(SevenTvLink.redacted(other) == "cobalt-apple://library")
    }

    @Test func theBookmarkletOpensTheAppsLinkAndSaysLogInFirst() {
        let js = SevenTvLink.bookmarklet
        #expect(js.hasPrefix("javascript:"))
        #expect(js.contains("localStorage.getItem('7tv-token')"))
        #expect(js.contains("cobalt-apple://7tv-link?token="))
        #expect(js.contains("alert('log in to 7tv.app first')"))
        #expect(js.contains(#"t.replace(/^"|"$/g,'')"#))
    }

    @Test func aTokenLooksLikeAJwt() {
        #expect(SevenTvLink.looksLikeToken(fakeToken))
        #expect(!SevenTvLink.looksLikeToken(""))
        #expect(!SevenTvLink.looksLikeToken("abc.def"))
        #expect(!SevenTvLink.looksLikeToken("a..c"))
        #expect(!SevenTvLink.looksLikeToken("a.b c.d"))
        #expect(!SevenTvLink.looksLikeToken(String(repeating: "a", count: 4_095) + ".b.c"))
        #expect(SevenTvLink.clean("  \"\(fakeToken)\"\n") == fakeToken)
    }

    @Test func namesFollowTheRoutesRules() {
        #expect(SevenTvRule.cleanSetName("  christmas ") == "christmas")
        #expect(SevenTvRule.cleanSetName("   ") == nil && SevenTvRule.cleanSetName(String(repeating: "x", count: 101)) == nil)
        #expect(SevenTvRule.cleanAlias(" liaWave ") == "liaWave")
        #expect(SevenTvRule.cleanAlias("lia wave") == nil && SevenTvRule.cleanAlias("") == nil)
        #expect(SevenTvRule.cleanFilter("  ") == nil && SevenTvRule.cleanFilter(String(repeating: "c", count: 150))?.count == 100)
        #expect(SevenTvRule.isID("01HM0000000000000000MAIN01") && !SevenTvRule.isID("short") && !SevenTvRule.isID("01HM00000000000000000/AIN01"))
    }

    @Test func pathsAndBodiesAreTheContracts() throws {
        #expect(SevenTvRoute.channelSets("01GB2S2BCR000AHHX5S1Y9TQW2") == "/7tv/channels/01GB2S2BCR000AHHX5S1Y9TQW2/sets")
        #expect(SevenTvRoute.channelLive("c1") == "/7tv/channels/c1/live")
        #expect(SevenTvRoute.set("s1") == "/7tv/sets/s1")
        #expect(SevenTvRoute.emotes("s1") == "/7tv/sets/s1/emotes")
        #expect(SevenTvRoute.emote("s1", "e1") == "/7tv/sets/s1/emotes/e1")
        #expect(SevenTvRoute.emote("s/1", "e?1") == "/7tv/sets/s%2F1/emotes/e%3F1")
        let first = SevenTvRoute.setQuery(query: nil, page: 0)
        #expect(first.count == 1 && first[0].0 == "page" && first[0].1 == "1")
        let filtered = SevenTvRoute.setQuery(query: " cat ", page: 3)
        #expect(filtered.map(\.0) == ["q", "page"] && filtered[0].1 == "cat" && filtered[1].1 == "3")
        #expect(SevenTvRoute.addBody(emoteID: "e", alias: nil, overrideConflicts: false).count == 1)
        let add = SevenTvRoute.addBody(emoteID: "e", alias: "liaWave", overrideConflicts: true)
        #expect(add["alias"] as? String == "liaWave" && add["override_conflicts"] as? Bool == true)
        #expect(SevenTvRoute.renameBody(alias: "b", from: nil).count == 1 && SevenTvRoute.renameBody(alias: "b", from: "a")["from"] as? String == "a")
        let clear = try #require(HTTPCobaltClient.jsonBody(SevenTvRoute.liveBody(setID: nil)))
        #expect(String(decoding: clear, as: UTF8.self) == #"{"set_id":null}"#)
        let live = try #require(HTTPCobaltClient.jsonBody(SevenTvRoute.liveBody(setID: "s1")))
        #expect(String(decoding: live, as: UTF8.self) == #"{"set_id":"s1"}"#)
    }
}

// MARK: - the routes

struct SevenTvHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { sevenTvKey })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test func statusIsAKeyedGet() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/7tv" ? .json(wireStatus) : .init(status: 404)
        }
        defer { server.stop() }
        let status = try await client(server).sevenTvStatus()
        let req = try #require(server.requests.first)
        #expect(req.headers["authorization"] == "Api-Key \(sevenTvKey)" && req.body.isEmpty)
        #expect(status.linked && status.channels.count == 2)
    }

    @Test func linkPostsTheTokenAndUnlinkDeletes() async throws {
        let server = try await LoopbackServer.start { req in
            switch (req.method, req.path) {
            case ("POST", "/7tv/link"): return .json(wireStatus)
            case ("DELETE", "/7tv"): return .json(#"{"status":"success","linked":false}"#)
            default: return .init(status: 404)
            }
        }
        defer { server.stop() }
        let c = client(server)
        let linked = try await c.linkSevenTv(token: fakeToken)
        #expect(linked.account?.name == "capybaraharmony")
        let body = try bodyJSON(try #require(server.requests.first))
        #expect(body["token"] as? String == fakeToken && body.count == 1)
        let gone = try await c.unlinkSevenTv()
        #expect(!gone.linked)
    }

    @Test func aSetPageSendsTheFilterAndPage() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/7tv/sets/01HM0000000000000000MAIN01" ? .json(wirePage) : .init(status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        _ = try await c.sevenTvSet(id: "01HM0000000000000000MAIN01", query: "cat jam", page: 2)
        _ = try await c.sevenTvSet(id: "01HM0000000000000000MAIN01", query: nil, page: 1)
        #expect(server.requests.map(\.query) == ["q=cat%20jam&page=2", "page=1"])
    }

    @Test func channelSetsAndLive() async throws {
        let server = try await LoopbackServer.start { req in
            switch (req.method, req.path) {
            case ("GET", "/7tv/channels/c1/sets"): return .json(wireSets)
            case ("POST", "/7tv/channels/c1/live"): return .json(#"{"status":"success","channel_id":"c1","active_set_id":"s2"}"#)
            default: return .init(status: 404)
            }
        }
        defer { server.stop() }
        let c = client(server)
        #expect(try await c.sevenTvSets(channelID: "c1").sets.count == 2)
        let live = try await c.makeSevenTvSetLive(channelID: "c1", setID: "s2")
        #expect(live.activeSetID == "s2")
        #expect(try bodyJSON(server.requests[1])["set_id"] as? String == "s2")
    }

    @Test func setWritesSendTheirBodies() async throws {
        let server = try await LoopbackServer.start { req in
            switch (req.method, req.path) {
            case ("POST", "/7tv/sets"): return .json(#"{"status":"success","set":\#(wireSetInfo)}"#, status: 201)
            case ("PATCH", "/7tv/sets/s1"): return .json(#"{"status":"success","set":\#(wireSetInfo)}"#)
            case ("POST", "/7tv/sets/s1/emotes"): return .json(#"{"status":"success","set_id":"s1","emote_id":"e1","alias":"liaWave"}"#, status: 201)
            case ("PATCH", "/7tv/sets/s1/emotes/e1"): return .json(#"{"status":"success","set_id":"s1","emote_id":"e1","alias":"wave"}"#)
            case ("DELETE", "/7tv/sets/s1/emotes/e1"): return .json(#"{"status":"success","set_id":"s1","emote_id":"e1","removed":true}"#)
            default: return .init(status: 404)
            }
        }
        defer { server.stop() }
        let c = client(server)
        _ = try await c.createSevenTvSet(ownerID: "c1", name: "christmas")
        _ = try await c.renameSevenTvSet(id: "s1", name: "main")
        let added = try await c.addSevenTvEmote(setID: "s1", emoteID: "e1", alias: "liaWave", overrideConflicts: true)
        let renamed = try await c.renameSevenTvEmote(setID: "s1", emoteID: "e1", alias: "wave", from: "liaWave")
        let removed = try await c.removeSevenTvEmote(setID: "s1", emoteID: "e1", alias: "wave")
        #expect(added.alias == "liaWave" && renamed.alias == "wave" && removed.removed)
        let r = server.requests
        #expect(try bodyJSON(r[0])["owner_id"] as? String == "c1" && bodyJSON(r[0])["name"] as? String == "christmas")
        #expect(try bodyJSON(r[1])["name"] as? String == "main")
        let add = try bodyJSON(r[2])
        #expect(add["emote_id"] as? String == "e1" && add["alias"] as? String == "liaWave" && add["override_conflicts"] as? Bool == true)
        let rename = try bodyJSON(r[3])
        #expect(rename["alias"] as? String == "wave" && rename["from"] as? String == "liaWave")
        #expect(r[4].query == "alias=wave" && r[4].body.isEmpty)
    }

    @Test func refusalsCarrySevenTvsWords() async throws {
        let server = try await LoopbackServer.start { req in
            switch req.path {
            case "/7tv/sets/s1/emotes":
                return .json(#"{"status":"error","error":{"code":"error.seventv.forbidden"},"message":"you do not have permission to manage this emote set"}"#, status: 403)
            case "/7tv":
                return .json(#"{"status":"error","error":{"code":"error.seventv.relink"}}"#, status: 409)
            case "/7tv/link":
                return .json(#"{"status":"error","error":{"code":"error.seventv.token_invalid"}}"#, status: 400)
            default:
                return .init(status: 502)
            }
        }
        defer { server.stop() }
        let c = client(server)
        await #expect(throws: SevenTvError.forbidden("you do not have permission to manage this emote set")) {
            _ = try await c.addSevenTvEmote(setID: "s1", emoteID: "e1", alias: nil, overrideConflicts: false)
        }
        await #expect(throws: SevenTvError.relink) { _ = try await c.sevenTvStatus() }
        await #expect(throws: SevenTvError.tokenInvalid) { _ = try await c.linkSevenTv(token: "a.b.c") }
        await #expect(throws: SevenTvError.unavailable) { _ = try await c.sevenTvSets(channelID: "c9") }
    }
}

// MARK: - the store on the preview server

@MainActor
struct SevenTvStoreTests {
    private func app(_ scenario: PreviewScenario = .happy) -> AppModel {
        AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
    }

    @Test func loadReadsTheAccountAndTheOwnChannelsSets() async throws {
        let app = app()
        await app.sevenTv.load()
        #expect(app.sevenTv.state == .loaded && app.sevenTv.isLinked)
        #expect(app.sevenTv.channels.map(\.name) == ["capybaraharmony", "liacat", "mochi_vt"])
        let own = try #require(app.sevenTv.selectedChannel)
        #expect(own.you && own.can == .all)
        #expect(app.sevenTv.sets(of: own.id).map(\.name) == ["main", "christmas", "subathon"])
        #expect(app.sevenTv.sets(of: own.id).first?.live == true && app.sevenTv.sets(of: own.id).first?.count == 310)
        #expect(app.sevenTv.account?.expiresSoon(now: app.sevenTv.now()) == true)
    }

    @Test func theScenariosCoverNotLinkedRelinkAndNoRoutes() async {
        let off = app(.stageNotConnected)
        await off.sevenTv.load()
        #expect(off.sevenTv.state == .loaded && !off.sevenTv.isLinked)
        let relink = app(.renditions)
        await relink.sevenTv.load()
        #expect(relink.sevenTv.status?.needsRelink == true && relink.sevenTv.channels.isEmpty)
        let none = app(.coldStart)
        await none.sevenTv.load()
        #expect(none.sevenTv.state == .failed(.off))
    }

    @Test func linkingSaysWhatCameOfItOnce() async throws {
        let app = app(.stageNotConnected)
        await app.sevenTv.load()
        #expect(await app.sevenTv.link(token: "not a token") == .failed(.tokenInvalid))
        #expect(await app.sevenTv.link(token: "bad.bad.bad") == .failed(.tokenInvalid))
        #expect(await app.sevenTv.link(token: fakeToken) == .linked("capybaraharmony"))
        #expect(app.sevenTv.isLinked && app.sevenTv.channels.count == 3)
        let outcome = try #require(app.sevenTv.unsaidOutcome)
        #expect(outcome.result == .linked("capybaraharmony"))
        app.sevenTv.acknowledge(outcome)
        #expect(app.sevenTv.unsaidOutcome == nil)
        try await app.sevenTv.unlink()
        #expect(!app.sevenTv.isLinked && app.sevenTv.channels.isEmpty)
    }

    @Test func theBookmarkletsLinkOpensTheStudioAndLinks() async throws {
        let app = app(.stageNotConnected)
        let encoded = fakeToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(app.openSevenTvLink(try #require(URL(string: "cobalt-apple://7tv-link?token=\(encoded)"))))
        #expect(!app.openSevenTvLink(try #require(URL(string: "cobalt-apple://library"))))
        for _ in 0..<200 where app.sevenTv.unsaidOutcome == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(app.sevenTv.unsaidOutcome?.result == .linked("capybaraharmony"))
    }

    @Test func makeLiveMovesTheSetFirstAndRightsAreChecked() async throws {
        let app = app()
        await app.sevenTv.load()
        let own = try #require(app.sevenTv.selectedChannel)
        let christmas = try #require(app.sevenTv.sets(of: own.id).first { $0.name == "christmas" })
        try await app.sevenTv.makeLive(channelID: own.id, setID: christmas.id)
        #expect(app.sevenTv.sets(of: own.id).first?.id == christmas.id && app.sevenTv.sets(of: own.id).first?.live == true)
        #expect(app.sevenTv.selectedChannel?.activeSetID == christmas.id)
        let lia = try #require(app.sevenTv.channels.first { $0.name == "liacat" })
        await app.sevenTv.select(channelID: lia.id)
        let liaSet = try #require(app.sevenTv.sets(of: lia.id).last)
        await #expect(throws: SevenTvError.self) { try await app.sevenTv.makeLive(channelID: lia.id, setID: liaSet.id) }
        let made = try await app.sevenTv.createSet(channelID: lia.id, name: " stream ")
        #expect(made.name == "stream" && app.sevenTv.sets(of: lia.id).contains { $0.id == made.id })
    }

    @Test func theSetModelPagesFiltersAndEditsInPlace() async throws {
        let app = app()
        await app.sevenTv.load()
        let own = try #require(app.sevenTv.selectedChannel)
        let main = try #require(app.sevenTv.sets(of: own.id).first)
        let set = app.sevenTv.openSet(main.id, channelID: own.id)
        await set.load()
        #expect(set.state == .loaded && set.emotes.count == 60 && set.hasMore && set.info?.count == 310)
        await set.loadMore()
        #expect(set.emotes.count == 120)
        await set.loadEverything()
        #expect(set.everythingLoaded && set.all.count == 310)

        set.filter = "liaWave"
        await set.applyFilter()
        #expect(set.isFiltered && set.emotes.map(\.alias) == ["liaWave"])
        let wave = try #require(set.emotes.first)
        try await set.rename(wave, to: "liaHi")
        #expect(set.emotes.first?.alias == "liaHi" && set.all.contains { $0.alias == "liaHi" })
        await #expect(throws: SevenTvError.self) { try await set.rename(wave, to: "has space") }

        set.filter = ""
        await set.applyFilter()
        let jam = try #require(set.all.first { $0.alias == "catJAM" })
        try await set.remove(jam)
        #expect(set.info?.count == 309 && !set.all.contains { $0.id == jam.id })
        #expect(app.sevenTv.sets(of: own.id).first { $0.id == main.id }?.count == 309, "the card's count follows")

        let hit = EmoteHit(
            id: jam.emoteID, name: "catJAM", animated: true, previewURL: PreviewData.sevenTvCDN(jam.emoteID, "2x"),
            fileURL: PreviewData.sevenTvCDN(jam.emoteID, "4x"))
        try await set.add(hit, alias: nil, overrideConflicts: false)
        #expect(set.memberIDs.contains(jam.emoteID) && set.info?.count == 310)
        await #expect(throws: SevenTvError.self) { try await set.add(hit, alias: "BOOBA", overrideConflicts: false) }
        try await set.add(hit, alias: "BOOBA", overrideConflicts: true)
        #expect(set.info?.count == 310 && set.emote(aliased: "BOOBA")?.emoteID == jam.emoteID)

        let christmas = try #require(set.otherSets.first { $0.name == "christmas" })
        let before = christmas.count
        try await set.copy(try #require(set.emote(aliased: "liaHi")), to: christmas.id)
        #expect(app.sevenTv.sets(of: own.id).first { $0.id == christmas.id }?.count == before + 1)

        try await set.renameSet("main 2")
        #expect(set.info?.name == "main 2" && app.sevenTv.sets(of: own.id).first { $0.id == main.id }?.name == "main 2")
    }

    @Test func aDeadSessionPutsTheCardInRelink() async throws {
        let app = app()
        await app.sevenTv.load()
        app.sevenTv.note(.relink)
        #expect(app.sevenTv.status?.needsRelink == true && app.sevenTv.channels.isEmpty)
        app.sevenTv.note(.notLinked)
        #expect(!app.sevenTv.isLinked)
    }

    @Test func aServerChangeForgetsTheAccount() async {
        let app = app()
        await app.sevenTv.load()
        app.sevenTv.reset()
        #expect(app.sevenTv.status == nil && app.sevenTv.state == .idle && app.sevenTv.channelSets.isEmpty)
    }
}

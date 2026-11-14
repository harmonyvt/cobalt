import Foundation
import Testing
@testable import CobaltKit

// 7TV accounts (APP-API-CONTRACT 57): the wire shapes of 57.4/57.5, the refusals, the bookmarklet's link and the token checks,
// the paths and bodies of every route, and the store and set model on the preview server. Uploading a picture as a new emote
// (57.9): its shapes, rules, routes and refusals, and the upload model's polling. The fit (57.10): crop and size in the body,
// `fitted` in the answer, its refusals, and which files are shrunk, refused or need a crop. The 7tv tab: `name_taken` and its
// `conflict`, the local clash check and the suggested names, the three ways out, copy to set, `GET /7tv/uploads`.

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

    @Test func theLoginSheetReadsTheTokenWithoutItsJsonQuotes() {
        // `localStorage.getItem` answers a string (7tv.app may keep it JSON-quoted), NSNull or nothing
        #expect(SevenTvLink.token(fromStorage: fakeToken) == fakeToken)
        #expect(SevenTvLink.token(fromStorage: "\"\(fakeToken)\"") == fakeToken)
        #expect(SevenTvLink.token(fromStorage: " \"\(fakeToken)\"\n") == fakeToken)
        #expect(SevenTvLink.token(fromStorage: "'\(fakeToken)'") == fakeToken)
        #expect(SevenTvLink.token(fromStorage: "\"\"") == nil && SevenTvLink.token(fromStorage: "") == nil)
        #expect(SevenTvLink.token(fromStorage: "  ") == nil)
        #expect(SevenTvLink.token(fromStorage: NSNull()) == nil && SevenTvLink.token(fromStorage: nil) == nil)
        #expect(SevenTvLink.token(fromStorage: 42) == nil)
    }

    @Test func theLoginSheetKeepsOnlySevenTvAndItsSignInsInside() {
        #expect(SevenTvLink.loginURL.absoluteString == "https://7tv.app/login")
        for host in ["7tv.app", "api.7tv.app", "7tv.io", "id.twitch.tv", "twitch.tv", "passport.twitch.tv", "www.twitch.tv",
                     "discord.com", "canary.discord.com", "kick.com", "id.kick.com", "7TV.APP"] {
            #expect(SevenTvLink.loginAllows(host: host), "\(host) stays in the web view")
        }
        for host in ["evil7tv.app", "7tv.app.evil.com", "twitch.tv.example.org", "example.com", "x.com", "", nil] {
            #expect(!SevenTvLink.loginAllows(host: host), "\(host ?? "nil") opens in the system browser")
        }
        // only 7tv.app's own localStorage is read
        #expect(SevenTvLink.isSevenTvHost("7tv.app") && SevenTvLink.isSevenTvHost("api.7tv.app"))
        #expect(!SevenTvLink.isSevenTvHost("7tv.io") && !SevenTvLink.isSevenTvHost("id.twitch.tv") && !SevenTvLink.isSevenTvHost("not7tv.app"))
        #expect(!SevenTvLink.isSevenTvHost(nil))
        #expect(SevenTvLink.storageKey == "7tv-token")
        #expect(SevenTvLink.loginDataStoreID.uuidString == "6F3A5C1E-7B24-4D8E-9A10-5E7C2B9D4F36", "a fixed id keeps the session between launches")
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

    @Test func unlinkAsksForLogoutOnlyWhenToldTo() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "DELETE" && req.path == "/7tv" ? .json(#"{"status":"success","linked":false,"logged_out":true}"#) : .init(status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        _ = try await c.unlinkSevenTv()
        _ = try await c.unlinkSevenTv(logout: false)
        let gone = try await c.unlinkSevenTv(logout: true)
        #expect(!gone.linked)
        #expect(server.requests.map(\.method) == ["DELETE", "DELETE", "DELETE"])
        #expect(server.requests.map(\.path) == ["/7tv", "/7tv", "/7tv"])
        #expect(server.requests.map(\.query) == ["", "", "logout=1"])
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

    @Test func aLinkFromTheSheetIsRememberedAndAnyOtherLinkForgetsIt() async throws {
        let app = app(.stageNotConnected)
        await app.sevenTv.load()
        #expect(!app.sevenTv.linkedBySheet)
        #expect(await app.sevenTv.link(token: fakeToken, viaSheet: true) == .linked("capybaraharmony"))
        #expect(app.sevenTv.linkedBySheet, "the sheet's link sets the flag")
        #expect(await app.sevenTv.link(token: fakeToken) == .linked("capybaraharmony"))
        #expect(!app.sevenTv.linkedBySheet, "a pasted or bookmarked token clears it")
        #expect(await app.sevenTv.link(token: fakeToken, viaSheet: true) == .linked("capybaraharmony"))
        #expect(await app.sevenTv.link(token: "bad.bad.bad", viaSheet: true) == .failed(.tokenInvalid))
        #expect(app.sevenTv.linkedBySheet, "a refused token leaves the current link and its flag alone")
        // the flag is kept in the settings defaults (the app group's in the app), so a relaunch still knows
        let settings = app.ctx.settings
        #expect(settings.defaults.bool(forKey: SevenTvStore.sheetKey))
    }

    @Test func unlinkEndsTheSevenTvSessionOnlyForALoginMadeInTheSheet() async throws {
        let app = app(.stageNotConnected)
        let preview = try #require(app.ctx.client as? PreviewClient)
        await app.sevenTv.load()

        #expect(await app.sevenTv.link(token: fakeToken) == .linked("capybaraharmony"))
        try await app.sevenTv.unlink()
        #expect(!app.sevenTv.isLinked && !app.sevenTv.linkedBySheet)
        #expect(preview.sevenTvState.calls.filter { $0.hasPrefix("DELETE") } == ["DELETE"], "a pasted token: plain DELETE /7tv")

        #expect(await app.sevenTv.link(token: fakeToken, viaSheet: true) == .linked("capybaraharmony"))
        try await app.sevenTv.unlink()
        #expect(!app.sevenTv.isLinked && !app.sevenTv.linkedBySheet, "unlinking clears the flag")
        #expect(preview.sevenTvState.calls.filter { $0.hasPrefix("DELETE") } == ["DELETE", "DELETE logout"], "the sheet's token: ?logout=1")

        #expect(await app.sevenTv.link(token: fakeToken) == .linked("capybaraharmony"))
        try await app.sevenTv.unlink()
        #expect(preview.sevenTvState.calls.filter { $0.hasPrefix("DELETE") } == ["DELETE", "DELETE logout", "DELETE"], "the flag does not outlive its link")
    }

    @Test func theFlagGoesWhenTheServerSaysNothingIsLinked() async throws {
        let app = app(.stageNotConnected)
        await app.sevenTv.load()
        await app.sevenTv.link(token: fakeToken, viaSheet: true)
        #expect(app.sevenTv.linkedBySheet)
        app.sevenTv.note(.notLinked)
        #expect(!app.sevenTv.isLinked && !app.sevenTv.linkedBySheet)
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

// MARK: - uploading a picture as a new emote (57.9)

private let wireUpload = """
{"status":"success","emote_id":"01HU0000000000000000000001","name":"capyDance","file_id":"f_123","page_url":"https://7tv.app/emotes/01HU0000000000000000000001",
 "pending":true,"added":{"set_id":"01HM0000000000000000MAIN01","alias":"capyDance"}}
"""

private let wireEmote = """
{"status":"success","emote_id":"01HU0000000000000000000001","name":"capyDance","owner_id":"01GB2S2BCR000AHHX5S1Y9TQW2","pending":false,
 "animated":true,"private":true,"zero_width":false,"preview_url":"https://cdn.7tv.app/emote/01HU0000000000000000000001/2x.webp",
 "file_url":"https://cdn.7tv.app/emote/01HU0000000000000000000001/4x.webp","page_url":"https://7tv.app/emotes/01HU0000000000000000000001"}
"""

struct SevenTvUploadShapeTests {
    @Test func anUploadAnswerDecodesWithWhereItWent() throws {
        let result = try decode(SevenTvUploadResult.self, wireUpload)
        #expect(result.emoteID == "01HU0000000000000000000001" && result.name == "capyDance" && result.fileID == "f_123")
        #expect(result.pending && result.addError == nil)
        #expect(result.added == SevenTvUploadPlacement(setID: "01HM0000000000000000MAIN01", alias: "capyDance"))
        #expect(result.pageURL.absoluteString == "https://7tv.app/emotes/01HU0000000000000000000001")
    }

    @Test func aRefusedAddKeepsTheUploadAndSaysWhy() throws {
        let json = """
        {"status":"success","emote_id":"e1","name":"x","file_id":"f","page_url":"","pending":true,"added":null,
         "add_error":{"code":"error.seventv.forbidden","message":"you do not have permission to manage this emote set"}}
        """
        let result = try decode(SevenTvUploadResult.self, json)
        #expect(result.added == nil)
        #expect(result.addError == .forbidden("you do not have permission to manage this emote set"))
        #expect(result.pageURL.absoluteString == "https://7tv.app/emotes/e1", "a missing page falls back to 7tv.app")
        let odd = try decode(SevenTvUploadResult.self, #"{"emote_id":"e1","add_error":{"code":"error.seventv.weird","message":"no"}}"#)
        #expect(odd.addError == .rejected("no"))
    }

    @Test func anEmoteDecodesPrivateAndPending() throws {
        let info = try decode(SevenTvEmoteInfo.self, wireEmote)
        #expect(!info.pending && info.animated && info.isPrivate && !info.zeroWidth)
        #expect(info.ownerID == "01GB2S2BCR000AHHX5S1Y9TQW2" && info.previewURL != nil && info.fileURL != nil)
        let bare = try decode(SevenTvEmoteInfo.self, #"{"emote_id":"e1","name":"x","pending":true,"preview_url":null}"#)
        #expect(bare.pending && bare.previewURL == nil && bare.pageURL.absoluteString == "https://7tv.app/emotes/e1")
    }

    @Test func theUploadsRefusalsHaveTheirOwnCodes() {
        #expect(SevenTvError(code: "error.seventv.file_not_found") == .fileNotFound)
        #expect(SevenTvError(code: "error.seventv.file_type") == .fileType)
        #expect(SevenTvError(code: "error.seventv.too_big") == .tooBig)
        #expect(SevenTvError.from(CobaltError.api(code: "error.seventv.too_big", httpStatus: 413)) == .tooBig)
    }

    @Test func theFitsRefusalsHaveTheirOwnCodes() {
        #expect(SevenTvError(code: "error.seventv.fit_failed", message: "ffmpeg could not decode it") == .fitFailed("ffmpeg could not decode it"))
        #expect(SevenTvError(code: "error.seventv.fit_failed", message: "  ") == .fitFailed(nil))
        #expect(SevenTvError(code: "error.seventv.fit_failed", message: "out of time")?.message == "out of time")
        #expect(SevenTvError(code: "error.seventv.busy") == .busy)
        #expect(SevenTvError(code: "error.seventv.too_large") == .tooLarge)
        #expect(SevenTvError.from(CobaltError.api(code: "error.seventv.busy", httpStatus: 429)) == .busy)
        #expect(SevenTvError.from(CobaltError.api(code: "error.seventv.fit_failed", httpStatus: 502)) == .fitFailed(nil))
    }

    @Test func aFittedAnswerSaysWhatWasSent() throws {
        let json = """
        {"status":"success","emote_id":"e1","name":"capyDance","file_id":"f","page_url":"","pending":true,
         "fitted":{"width":512,"height":288,"frames":48,"bytes":812345,"quality":65},"added":null}
        """
        let result = try decode(SevenTvUploadResult.self, json)
        #expect(result.fitted == SevenTvFitResult(width: 512, height: 288, frames: 48, bytes: 812_345, quality: 65))
        let floats = try decode(
            SevenTvUploadResult.self, #"{"emote_id":"e1","fitted":{"width":512.0,"height":512,"frames":1,"bytes":1024.0,"quality":82.0}}"#)
        #expect(floats.fitted == SevenTvFitResult(width: 512, height: 512, frames: 1, bytes: 1_024, quality: 82))
        #expect(try decode(SevenTvUploadResult.self, #"{"emote_id":"e1","fitted":null}"#).fitted == nil)
        #expect(try decode(SevenTvUploadResult.self, wireUpload).fitted == nil, "an answer without fitted went as it was")
    }

    @Test func bigFilesAreShrunkUnlessAvifAndOddShapesNeedACrop() {
        #expect(SevenTvEmoteRule.isFittable(contentType: "image/webp", name: nil))
        #expect(SevenTvEmoteRule.isFittable(contentType: "image/JPEG; q=1", name: nil))
        #expect(SevenTvEmoteRule.isFittable(contentType: "image/gif", name: "x.avif"), "the type wins over the name")
        #expect(!SevenTvEmoteRule.isFittable(contentType: "image/avif", name: nil))
        #expect(!SevenTvEmoteRule.isFittable(contentType: nil, name: "dance.AVIF"))
        #expect(SevenTvEmoteRule.isFittable(contentType: nil, name: "dance.png"))
        #expect(SevenTvEmoteRule.isFittable(contentType: nil, name: nil), "unknown passes; the server checks")
        #expect(SevenTvEmoteRule.isOverSide(width: 1_001, height: 10) && !SevenTvEmoteRule.isOverSide(width: 1_000, height: 1_000))
        #expect(!SevenTvEmoteRule.isOverSide(width: nil, height: nil))
        #expect(SevenTvEmoteRule.shapeFits(width: 300, height: 100) && SevenTvEmoteRule.shapeFits(width: 10, height: 320))
        #expect(!SevenTvEmoteRule.shapeFits(width: 301, height: 100) && !SevenTvEmoteRule.shapeFits(width: 10, height: 321))
        #expect(SevenTvEmoteRule.shapeFits(width: 0, height: 100), "an unknown size passes")
        let box = SevenTvEmoteRule.croppedSize(width: 1_280, height: 720, crop: ImageCropRect(x: 0.25, y: 0, w: 0.5, h: 0.5))
        #expect(box?.width == 640 && box?.height == 360)
        #expect(SevenTvEmoteRule.croppedSize(width: nil, height: 720, crop: nil) == nil)
        #expect(SevenTvEmoteRule.clampSize(8) == 32 && SevenTvEmoteRule.clampSize(4_000) == 1_000 && SevenTvEmoteRule.clampSize(nil) == nil)
        #expect(SevenTvEmoteRule.sizeChoices == [nil, 128, 256, 512, 1_000])
    }

    @Test func namesFollowSevenTvsRule() {
        #expect(SevenTvEmoteRule.isValidName("catJAM"))
        #expect(SevenTvEmoteRule.isValidName("(:!+|.'?><*$#)_-"))
        #expect(SevenTvEmoteRule.isValidName("pepe😀"), "an emoji shown as an emoji is fine")
        #expect(!SevenTvEmoteRule.isValidName(""))
        #expect(!SevenTvEmoteRule.isValidName("cat jam"))
        #expect(!SevenTvEmoteRule.isValidName("café"))
        #expect(!SevenTvEmoteRule.isValidName("a©"), "© is text, not an emoji presentation")
        #expect(SevenTvEmoteRule.isValidName(String(repeating: "a", count: 100)))
        #expect(!SevenTvEmoteRule.isValidName(String(repeating: "a", count: 101)))
    }

    @Test func tagsAreCleanedAndCapped() {
        let tags = SevenTvEmoteRule.cleanTags(["#cat", "ab", "Cat", "funny_one", "two words", "dance", "x1y", "capy", "more", "last"])
        #expect(tags == ["cat", "funny_one", "dance", "x1y", "capy", "more"])
        #expect(SevenTvEmoteRule.isValidTag("abc") && !SevenTvEmoteRule.isValidTag(String(repeating: "a", count: 31)))
    }

    @Test func aNameIsSuggestedFromTheTitle() {
        #expect(SevenTvEmoteRule.suggestName(from: "cat jam!!") == "catJam")
        #expect(SevenTvEmoteRule.suggestName(from: "Peepo Héy") == "PeepoHey")
        #expect(SevenTvEmoteRule.suggestName(from: "BOOBA 2") == "BOOBA2")
        #expect(SevenTvEmoteRule.suggestName(from: "capy's dance-off") == "capySDanceOff")
        #expect(SevenTvEmoteRule.suggestName(from: "dance party.webp") == "danceParty", "a file name's extension goes")
        #expect(SevenTvEmoteRule.suggestName(from: "v1.2") == "v12")
        #expect(SevenTvEmoteRule.suggestName(from: nil) == "emote")
        #expect(SevenTvEmoteRule.suggestName(from: "🎉 🎉") == "emote")
        #expect(SevenTvEmoteRule.suggestName(from: String(repeating: "ab ", count: 80)).count == 100)
        #expect(SevenTvEmoteRule.isValidName(SevenTvEmoteRule.suggestName(from: "über-cool ✨ clip #3")))
    }

    @Test func onlyPictures7tvTakesAreUploadable() {
        #expect(SevenTvEmoteRule.isUploadable(contentType: "image/webp", name: nil))
        #expect(SevenTvEmoteRule.isUploadable(contentType: "image/JPEG; q=1", name: nil))
        #expect(SevenTvEmoteRule.isUploadable(contentType: "image/avif", name: "x.bin"))
        #expect(!SevenTvEmoteRule.isUploadable(contentType: "video/mp4", name: "x.gif"), "the type wins over the name")
        #expect(!SevenTvEmoteRule.isUploadable(contentType: "image/heic", name: nil))
        #expect(SevenTvEmoteRule.isUploadable(contentType: nil, name: "dance.GIF"))
        #expect(!SevenTvEmoteRule.isUploadable(contentType: nil, name: "webp"))
        #expect(!SevenTvEmoteRule.isUploadable(contentType: nil, name: nil))
        #expect(SevenTvEmoteRule.maxBytes == 7_274_496)
        #expect(SevenTvEmoteRule.isTooBig(7_274_497) && !SevenTvEmoteRule.isTooBig(7_274_496) && !SevenTvEmoteRule.isTooBig(nil))
    }

    @Test func uploadPathsAndBodiesAreTheContracts() throws {
        #expect(SevenTvRoute.uploads == "/7tv/emotes")
        #expect(SevenTvRoute.emoteInfo("01HU0000000000000000000001") == "/7tv/emotes/01HU0000000000000000000001")
        let bare = SevenTvRoute.uploadBody(SevenTvUploadDraft(fileID: "f1", name: "capyDance"))
        #expect(bare.count == 2 && bare["file"] as? String == "f1" && bare["name"] as? String == "capyDance")
        let aliasWithoutSet = SevenTvRoute.uploadBody(SevenTvUploadDraft(fileID: "f1", name: "n", alias: "a"))
        #expect(aliasWithoutSet["alias"] == nil, "an alias only means something with a set")
        let full = SevenTvRoute.uploadBody(SevenTvUploadDraft(
            fileID: "f1", name: "capyDance", tags: ["capy", "no"], zeroWidth: true, isPrivate: true, setID: "s1", alias: "dance"))
        #expect(full["tags"] as? [String] == ["capy"])
        #expect(full["zero_width"] as? Bool == true && full["private"] as? Bool == true)
        #expect(full["set_id"] as? String == "s1" && full["alias"] as? String == "dance")
        #expect(full["crop"] == nil && full["size"] == nil, "no crop or size: the file goes as it is")
    }

    @Test func cropAndSizeGoInTheBody() throws {
        let draft = SevenTvUploadDraft(fileID: "f1", name: "n", crop: ImageCropRect(x: 0.1, y: 0.2, w: 0.5, h: 0.25), size: 256)
        let body = SevenTvRoute.uploadBody(draft)
        let crop = try #require(body["crop"] as? [String: Double])
        #expect(crop == ["x": 0.1, "y": 0.2, "w": 0.5, "h": 0.25])
        #expect(body["size"] as? Int == 256)
        let wire = try #require(HTTPCobaltClient.jsonBody(body))
        let parsed = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let parsedCrop = try #require(parsed["crop"] as? [String: Double])
        #expect(Set(parsedCrop.keys) == ["x", "y", "w", "h"] && parsedCrop["w"] == 0.5)
        #expect(parsed["size"] as? Int == 256)
        let whole = SevenTvRoute.uploadBody(SevenTvUploadDraft(fileID: "f1", name: "n", crop: .whole, size: 5_000))
        #expect(whole["crop"] == nil, "the whole picture is no crop")
        #expect(whole["size"] as? Int == 1_000, "size is clamped to 32...1000")
        let outside = SevenTvRoute.uploadBody(
            SevenTvUploadDraft(fileID: "f1", name: "n", crop: ImageCropRect(x: 0.8, y: -1, w: 0.5, h: 0.5)))
        let clamped = try #require(outside["crop"] as? [String: Double])
        let x = try #require(clamped["x"]), w = try #require(clamped["w"])
        #expect(clamped["y"] == 0 && abs(x + w - 1) < 1e-9, "a box is clamped into the picture")
    }
}

struct SevenTvUploadHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { sevenTvKey })
    }

    @Test func uploadPostsTheDraftAndStatusIsAGet() async throws {
        let server = try await LoopbackServer.start { req in
            switch (req.method, req.path) {
            case ("POST", "/7tv/emotes"): return .json(wireUpload, status: 201)
            case ("GET", "/7tv/emotes/01HU0000000000000000000001"): return .json(wireEmote)
            default: return .init(status: 404)
            }
        }
        defer { server.stop() }
        let c = client(server)
        let result = try await c.uploadSevenTvEmote(
            SevenTvUploadDraft(fileID: "f_123", name: "capyDance", isPrivate: true, setID: "01HM0000000000000000MAIN01"))
        let info = try await c.sevenTvEmote(id: result.emoteID)
        #expect(result.pending && result.added?.setID == "01HM0000000000000000MAIN01")
        #expect(!info.pending && info.isPrivate)
        let post = try #require(server.requests.first)
        #expect(post.headers["authorization"] == "Api-Key \(sevenTvKey)")
        let body = try #require(JSONSerialization.jsonObject(with: post.body) as? [String: Any])
        #expect(body["file"] as? String == "f_123" && body["name"] as? String == "capyDance")
        #expect(body["private"] as? Bool == true && body["zero_width"] == nil && body["set_id"] as? String == "01HM0000000000000000MAIN01")
        #expect(server.requests.count == 2 && server.requests[1].body.isEmpty)
    }

    @Test func theUploadsRefusalsAreTyped() async throws {
        let server = try await LoopbackServer.start { req in
            let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
            switch body?["file"] as? String {
            case "gone": return .json(#"{"status":"error","error":{"code":"error.seventv.file_not_found"}}"#, status: 404)
            case "clip": return .json(#"{"status":"error","error":{"code":"error.seventv.file_type"}}"#, status: 415)
            case "huge": return .json(#"{"status":"error","error":{"code":"error.seventv.too_big"}}"#, status: 413)
            case "busy": return .json(#"{"status":"error","error":{"code":"error.seventv.busy"}}"#, status: 429)
            case "tall":
                return .json(#"{"status":"error","error":{"code":"error.seventv.too_large"},"message":"pass a crop box"}"#, status: 400)
            case "broken":
                return .json(
                    #"{"status":"error","error":{"code":"error.seventv.fit_failed","message":"could not decode the picture"}}"#, status: 422)
            case "gateway": return .json(#"{"status":"error","error":{"code":"error.seventv.fit_failed"}}"#, status: 502)
            default: return .json(#"{"status":"error","error":{"code":"error.seventv.rejected"},"message":"emote name is taken"}"#, status: 400)
            }
        }
        defer { server.stop() }
        let c = client(server)
        await #expect(throws: SevenTvError.fileNotFound) { _ = try await c.uploadSevenTvEmote(SevenTvUploadDraft(fileID: "gone", name: "a")) }
        await #expect(throws: SevenTvError.fileType) { _ = try await c.uploadSevenTvEmote(SevenTvUploadDraft(fileID: "clip", name: "a")) }
        await #expect(throws: SevenTvError.tooBig) { _ = try await c.uploadSevenTvEmote(SevenTvUploadDraft(fileID: "huge", name: "a")) }
        await #expect(throws: SevenTvError.busy) { _ = try await c.uploadSevenTvEmote(SevenTvUploadDraft(fileID: "busy", name: "a")) }
        await #expect(throws: SevenTvError.tooLarge) { _ = try await c.uploadSevenTvEmote(SevenTvUploadDraft(fileID: "tall", name: "a")) }
        await #expect(throws: SevenTvError.fitFailed("could not decode the picture")) {
            _ = try await c.uploadSevenTvEmote(SevenTvUploadDraft(fileID: "broken", name: "a"))
        }
        await #expect(throws: SevenTvError.fitFailed(nil)) {
            _ = try await c.uploadSevenTvEmote(SevenTvUploadDraft(fileID: "gateway", name: "a"))
        }
        await #expect(throws: SevenTvError.rejected("emote name is taken")) {
            _ = try await c.uploadSevenTvEmote(SevenTvUploadDraft(fileID: "ok", name: "a"))
        }
    }
}

@MainActor
struct SevenTvUploadModelTests {
    private func linkedApp(_ scenario: PreviewScenario = .happy) async -> AppModel {
        let app = AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
        await app.sevenTv.load()
        return app
    }

    private func fast(_ model: SevenTvUploadModel) -> SevenTvUploadModel {
        model.pollEvery = 0.01
        return model
    }

    @Test func anUploadIntoASetProcessesThenIsDone() async throws {
        let app = await linkedApp()
        let own = try #require(app.sevenTv.selectedChannel)
        let before = try #require(app.sevenTv.sets(of: own.id).first?.count)
        let model = fast(app.sevenTv.uploader(fileID: "f_webp_1", bytes: 200_000, title: "capy dance"))
        #expect(model.name == "capyDance" && model.nameIsValid && model.canUpload)
        model.addToSet = true
        await model.prepareSets()
        #expect(model.channelID == own.id && model.pickedSet?.name == "main", "the account's own live set is picked")
        model.isPrivate = true
        await model.upload()
        #expect(model.phase == .done && !model.timedOut)
        let result = try #require(model.result)
        #expect(result.added?.setID == "01HM0000000000000000MAIN01" && result.addError == nil)
        #expect(model.addedSetName == "main")
        #expect(model.emote?.pending == false && model.emote?.isPrivate == true)
        #expect(app.sevenTv.sets(of: own.id).first?.count == before + 1)
        let preview = try #require(app.ctx.client as? PreviewClient)
        let reads = preview.sevenTvState.calls.filter { $0.hasPrefix("GET emote") }.count
        #expect(reads == 2, "pending on the first read, done on the second")
    }

    @Test func aRefusedAddStillUploads() async throws {
        let app = await linkedApp()
        let model = fast(app.sevenTv.uploader(fileID: "f_webp_2", bytes: nil, title: "catJAM"))
        model.addToSet = true
        await model.prepareSets()
        await model.upload()
        #expect(model.phase == .done && model.result?.added == nil)
        #expect(model.result?.addError == .nameTaken(conflictEmoteID: PreviewData.sevenTvEmoteID(0), alias: "catJAM"))
    }

    @Test func refusalsAndChecksStopBeforeOrAfterAsking() async throws {
        let app = await linkedApp()
        let video = fast(app.sevenTv.uploader(fileID: "f_video_1", bytes: nil, title: "clip"))
        await video.upload()
        #expect(video.phase == .failed(.fileType))
        video.edit()
        #expect(video.phase == .editing)

        let big = app.sevenTv.uploader(fileID: "f_webp_3", bytes: 8_000_000, title: "big", contentType: "image/avif")
        #expect(big.isTooBig && !big.willShrink && !big.canUpload, "an avif over the cap can't be shrunk")
        let wideAvif = app.sevenTv.uploader(
            fileID: "f_avif", bytes: 100, title: "w", contentType: "image/avif", width: 1_200, height: 600)
        #expect(wideAvif.isTooBig && !wideAvif.isOverBytes && wideAvif.isOverSide && !wideAvif.fittable)
        let badName = app.sevenTv.uploader(fileID: "f_webp_4", bytes: nil, title: "x")
        badName.name = "two words"
        #expect(!badName.canUpload)
        let noSet = app.sevenTv.uploader(fileID: "f_webp_5", bytes: nil, title: "x")
        noSet.addToSet = true
        #expect(!noSet.canUpload, "add to a set needs a set")

        let relink = await linkedApp(.renditions)
        #expect(!relink.sevenTv.canUpload && !relink.sevenTv.uploader(fileID: "f", bytes: nil, title: "x").canUpload)
    }

    @Test func bigFittableFilesAreShrunkNotRefused() async throws {
        let app = await linkedApp()
        let big = fast(app.sevenTv.uploader(fileID: "f_big_webp", bytes: 9_400_000, title: "big", contentType: "image/webp"))
        #expect(big.fittable && big.isOverBytes && big.willShrink && !big.isTooBig && big.canUpload)
        let wide = app.sevenTv.uploader(fileID: "f_png", bytes: 100, title: "w", contentType: "image/png", width: 2_000, height: 1_000)
        #expect(wide.willShrink && wide.isOverSide && !wide.isOverBytes && wide.canUpload)
        let unknown = app.sevenTv.uploader(fileID: "f_x", bytes: 9_400_000, title: "x")
        #expect(unknown.willShrink && unknown.canUpload, "an unknown type is left to the server")
        await big.upload()
        #expect(big.phase == .done)
        let fitted = try #require(big.result?.fitted)
        #expect(fitted.width == 512 && fitted.height == 512 && fitted.frames == 48 && fitted.quality == 82)
    }

    @Test func anOddShapeNeedsACropAndTheCropAndSizeAreSent() async throws {
        let app = await linkedApp()
        let file = LibraryFile(
            id: "f_tall_webp", kind: .public, source: .upload, name: "tall.webp", url: nil, contentType: "image/webp", bytes: 400_000,
            width: 100, height: 3_600, duration: nil, createdAt: Date(timeIntervalSince1970: 1_790_000_000), mediaName: nil,
            deletable: true)
        let model = fast(app.sevenTv.uploader(file: file, title: "tall"))
        #expect(model.needsCrop && !model.canUpload, "1:36 is outside 1:32..3:1")
        #expect(model.cropPixels == nil)
        model.useCrop(ImageCropRect(x: 0, y: 0, w: 1, h: 0.95))
        #expect(model.needsCrop, "100 x 3420 is still too tall")
        model.useCrop(ImageCropRect(x: 0, y: 0.4, w: 1, h: 0.05))
        #expect(!model.needsCrop && model.canUpload)
        #expect(model.cropPixels?.width == 100 && model.cropPixels?.height == 180)
        model.size = 128
        await model.upload()
        #expect(model.phase == .done)
        let fitted = try #require(model.result?.fitted)
        #expect(fitted.width == 71 && fitted.height == 128, "the box scaled to a longest side of 128")
        model.useCrop(.whole)
        #expect(model.crop == nil && model.needsCrop, "the whole picture clears the crop")
    }

    @Test func theCropSheetsSizeFillsAnUnknownSize() async throws {
        let app = await linkedApp()
        let model = app.sevenTv.uploader(fileID: "f_webp_7", bytes: nil, title: "x", contentType: "image/webp")
        #expect(model.width == nil && !model.needsCrop)
        model.useCrop(ImageCropRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5), width: 1_280, height: 720)
        #expect(model.width == 1_280 && model.height == 720 && model.isOverSide && model.willShrink)
        #expect(model.cropPixels?.width == 640 && model.cropPixels?.height == 360)
    }

    @Test func theFitsRefusalsFailTheUpload() async throws {
        let app = await linkedApp()
        let busy = fast(app.sevenTv.uploader(fileID: "f_busy_webp", bytes: nil, title: "b"))
        await busy.upload()
        #expect(busy.phase == .failed(.busy))
        let broken = fast(app.sevenTv.uploader(fileID: "f_broken_webp", bytes: nil, title: "b"))
        await broken.upload()
        #expect(broken.phase == .failed(.fitFailed("could not decode the picture")))
        let tall = fast(app.sevenTv.uploader(fileID: "f_tall_webp", bytes: nil, title: "t"))
        await tall.upload()
        #expect(tall.phase == .failed(.tooLarge), "the server refuses a shape the app could not see")
    }

    @Test func pollingGivesUpAfterItsReads() async throws {
        let app = await linkedApp()
        let model = fast(app.sevenTv.uploader(fileID: "f_webp_6", bytes: nil, title: "slow"))
        model.maxPolls = 1
        await model.upload()
        #expect(model.phase == .done && model.timedOut && model.emote?.pending == true)
    }
}

// MARK: - the 7tv tab: name clashes, copies, uploads (57.4, 57.7, 57.9)

private let wireUploads = """
{"status":"success","uploads":[
 {"file_id":"f_old","emote_id":"01HU0000000000000000000002","name":"coffeeLoop","created_at":1790000000000,"set_id":null},
 {"file_id":"f_new","emote_id":"01HU0000000000000000000001","name":"liaSpin","created_at":1790000600000,"set_id":"01HM0000000000000000MAIN01"},
 {"file_id":"f_bad","name":"no emote id, dropped"}]}
"""

private let wireNameTaken = """
{"status":"error","error":{"code":"error.seventv.name_taken"},"message":"an emote named catJam is already in this set",
 "conflict":{"emote_id":"01F6MQ33FG000FFJ97ZB8MWV52","alias":"catJam"}}
"""

/// An emote that is in none of the preview sets.
private func outsider(_ n: Int, name: String) -> EmoteHit {
    let id = "01FZZ" + String(format: "%021d", n)
    return EmoteHit(
        id: id, name: name, animated: true, previewURL: PreviewData.sevenTvCDN(id, "2x"), fileURL: PreviewData.sevenTvCDN(id, "4x"))
}

struct SevenTvManageShapeTests {
    @Test func nameTakenDecodesWithTheEmoteHoldingTheName() throws {
        #expect(SevenTvError(code: "error.seventv.name_taken") == .nameTaken(conflictEmoteID: nil, alias: nil))
        #expect(
            SevenTvError.from(CobaltError.api(code: "error.seventv.name_taken", httpStatus: 409))
                == .nameTaken(conflictEmoteID: nil, alias: nil))
        #expect(SevenTvRefusal.parse(Data(wireNameTaken.utf8)) == .nameTaken(conflictEmoteID: "01F6MQ33FG000FFJ97ZB8MWV52", alias: "catJam"))
        let bare = SevenTvRefusal.parse(Data(#"{"status":"error","error":{"code":"error.seventv.name_taken"}}"#.utf8))
        #expect(bare == .nameTaken(conflictEmoteID: nil, alias: nil))
        let odd = SevenTvRefusal.parse(Data(#"{"status":"error","error":{"code":"error.seventv.name_taken"},"conflict":"catJam"}"#.utf8))
        #expect(odd == .nameTaken(conflictEmoteID: nil, alias: nil), "an odd conflict never loses the code")
        let empty = SevenTvRefusal.parse(
            Data(#"{"status":"error","error":{"code":"error.seventv.name_taken"},"conflict":{"emote_id":"","alias":null}}"#.utf8))
        #expect(empty == .nameTaken(conflictEmoteID: nil, alias: nil))
        #expect(SevenTvError.nameTaken(conflictEmoteID: nil, alias: "x").isNameTaken && !SevenTvError.rejected(nil).isNameTaken)
        #expect(SevenTvRefusal.parse(Data(#"{"status":"error","error":{"code":"error.seventv.rejected"},"conflict":{"alias":"x"}}"#.utf8)) == .rejected(nil))
    }

    @Test func uploadsDecodeNewestFirst() throws {
        let list = try decode(SevenTvUploadList.self, wireUploads)
        #expect(list.uploads.map(\.name) == ["liaSpin", "coffeeLoop"], "newest first; a row without an emote id is dropped")
        let spin = try #require(list.uploads.first)
        #expect(spin.fileID == "f_new" && spin.emoteID == "01HU0000000000000000000001" && spin.setID == "01HM0000000000000000MAIN01")
        #expect(spin.createdAt == Date(timeIntervalSince1970: 1_790_000_600))
        #expect(list.uploads[1].setID == nil && list.uploads[1].fileID == "f_old")
        #expect(spin.pageURL.absoluteString == "https://7tv.app/emotes/01HU0000000000000000000001")
        #expect(try decode(SevenTvUploadList.self, #"{"status":"success"}"#).uploads.isEmpty)
    }

    @Test func theClashIsFoundInTheLoadedSetAndAFreeNameSuggested() {
        #expect(SevenTvRule.nextAlias(after: "catJam") == "catJam2")
        #expect(SevenTvRule.nextAlias(after: "catJam2") == "catJam3")
        #expect(SevenTvRule.nextAlias(after: "catJam9") == "catJam10")
        #expect(SevenTvRule.suggestAlias(for: "catJam", taken: ["catJam"]) == "catJam2")
        #expect(SevenTvRule.suggestAlias(for: "catJam2", taken: ["catJam2"]) == "catJam3")
        #expect(SevenTvRule.suggestAlias(for: "catJam", taken: ["catJam", "catJam2", "catJam3"]) == "catJam4")
        #expect(SevenTvRule.freeAlias("catJamOld", taken: ["catJam"]) == "catJamOld")
        #expect(SevenTvRule.freeAlias("catJamOld", taken: ["catJamOld"]) == "catJamOld2")
        let next = SevenTvRule.nextAlias(after: String(repeating: "a", count: 100))
        #expect(next.count == 100 && next.hasSuffix("a2"), "kept to 100 characters by cutting the name")
        let emotes = PreviewData.sevenTvEmotes(count: 3, renameSecond: true, now: Date())
        #expect(SevenTvRule.clash(alias: "catJAM", in: emotes)?.emoteID == PreviewData.sevenTvEmoteID(0))
        #expect(SevenTvRule.clash(alias: "catjam", in: emotes) == nil, "7TV compares names exactly")
        #expect(SevenTvRule.clash(alias: "liaWave", in: emotes) != nil && SevenTvRule.clash(alias: "peepoHey", in: emotes) == nil)
        let clash = SevenTvNameClash.make(
            setID: "s1", setName: "main", alias: "catJam", incoming: outsider(1, name: "catJam"), existing: nil,
            conflictEmoteID: "e9", taken: ["catJam2"])
        #expect(clash.suggestion == "catJam3" && clash.renameSuggestion == "catJamOld" && clash.existingEmoteID == "e9")
        #expect(clash.canRenameExisting)
    }

    @Test func copyToSetSendsTheEmoteAndTheAliasItHasHere() throws {
        let renamed = SevenTvSetItem(emoteID: "e1", alias: "liaWave", name: "peepoHey", animated: true, previewURL: nil, fileURL: nil)
        let body = SevenTvRoute.copyBody(renamed)
        #expect(body["emote_id"] as? String == "e1" && body["alias"] as? String == "liaWave" && body["override_conflicts"] == nil)
        let plain = SevenTvSetItem(emoteID: "e2", alias: "catJAM", name: "catJAM", animated: true, previewURL: nil, fileURL: nil)
        #expect(SevenTvRoute.copyBody(plain)["alias"] as? String == "catJAM", "the alias always goes, renamed or not")
        #expect(SevenTvRoute.copyBody(plain, overrideConflicts: true)["override_conflicts"] as? Bool == true)
        let hit = renamed.asHit
        #expect(hit.id == "e1" && hit.name == "peepoHey" && hit.previewURL.absoluteString == "https://cdn.7tv.app/emote/e1/2x.webp")
        #expect(SevenTvRoute.myUploads == "/7tv/uploads")
    }
}

struct SevenTvManageHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { sevenTvKey })
    }

    @Test func aTakenNameIsA409WithTheEmoteHoldingIt() async throws {
        let server = try await LoopbackServer.start { req in
            switch (req.method, req.path) {
            case ("POST", "/7tv/sets/s1/emotes"): return .json(wireNameTaken, status: 409)
            case ("POST", "/7tv/sets/s2/emotes"):
                return .json(#"{"status":"success","set_id":"s2","emote_id":"e1","alias":"liaWave"}"#, status: 201)
            default: return .init(status: 404)
            }
        }
        defer { server.stop() }
        let c = client(server)
        await #expect(throws: SevenTvError.nameTaken(conflictEmoteID: "01F6MQ33FG000FFJ97ZB8MWV52", alias: "catJam")) {
            _ = try await c.addSevenTvEmote(setID: "s1", emoteID: "e1", alias: "catJam", overrideConflicts: false)
        }
        // copy to set: the emote and the alias it has in the set it comes from
        let copied = try await c.addSevenTvEmote(setID: "s2", emoteID: "e1", alias: "liaWave", overrideConflicts: false)
        #expect(copied.alias == "liaWave")
        let body = try #require(JSONSerialization.jsonObject(with: server.requests[1].body) as? [String: Any])
        #expect(body["emote_id"] as? String == "e1" && body["alias"] as? String == "liaWave" && body["override_conflicts"] == nil)
    }

    @Test func uploadsIsAKeyedGet() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/7tv/uploads" ? .json(wireUploads) : .init(status: 404)
        }
        defer { server.stop() }
        let uploads = try await client(server).sevenTvUploads()
        #expect(uploads.map(\.fileID) == ["f_new", "f_old"])
        let req = try #require(server.requests.first)
        #expect(req.headers["authorization"] == "Api-Key \(sevenTvKey)" && req.body.isEmpty)
    }
}

@MainActor
struct SevenTvManageModelTests {
    private func linkedApp(_ scenario: PreviewScenario = .happy) async -> AppModel {
        let app = AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
        await app.sevenTv.load()
        return app
    }

    @Test func theTabIsRightAfterLinksOnTheStudiosRule() {
        var c = Capabilities.unknown
        #expect(!AppTab.sevenTv.isAvailable(with: c))
        c.stage = true
        #expect(AppTab.sevenTv.isAvailable(with: c))
        let all = AppTab.allCases
        #expect(all.firstIndex(of: .sevenTv) == all.firstIndex(of: .links).map { $0 + 1 })
    }

    @Test func aTakenNameIsCaughtBeforeAskingAndResolvedThreeWays() async throws {
        let app = await linkedApp()
        let own = try #require(app.sevenTv.selectedChannel)
        let main = try #require(app.sevenTv.sets(of: own.id).first)
        let set = app.sevenTv.openSet(main.id, channelID: own.id)
        await set.load()
        await set.loadEverything()
        let preview = try #require(app.ctx.client as? PreviewClient)
        let jam = try #require(set.emote(aliased: "catJAM"))

        // the loaded set answers without asking 7TV; main has catJAM2…catJAM11 too
        let calls = preview.sevenTvState.calls.count
        let first = try #require(try await set.addChecking(outsider(1, name: "catJAM"), alias: nil))
        #expect(preview.sevenTvState.calls.count == calls, "no request for a name the loaded set has")
        #expect(first.alias == "catJAM" && first.setName == "main" && first.existing?.emoteID == jam.emoteID)
        #expect(first.suggestion == "catJAM12" && first.renameSuggestion == "catJAMOld" && first.canRenameExisting)
        #expect(set.suggestedAlias(for: "catJAM") == "catJAM12")

        // 1. under another name
        #expect(try await set.resolve(first, .addAs(first.suggestion)) == nil)
        #expect(set.emote(aliased: "catJAM12")?.emoteID == first.incoming.id && set.info?.count == 311)

        // 2. rename the one in the set, then the new one goes in under the name
        let second = try #require(try await set.addChecking(outsider(2, name: "catJAM"), alias: nil))
        await #expect(throws: SevenTvError.self) { try await set.resolve(second, .renameExisting(to: "BOOBA")) }
        #expect(try await set.resolve(second, .renameExisting(to: second.renameSuggestion)) == nil)
        #expect(set.emote(aliased: "catJAMOld")?.emoteID == jam.emoteID)
        #expect(set.emote(aliased: "catJAM")?.emoteID == second.incoming.id && set.info?.count == 312)

        // 3. replace it: the old one leaves
        let clap = try #require(set.emote(aliased: "Clap"))
        let third = try #require(try await set.addChecking(outsider(3, name: "Clap"), alias: nil))
        #expect(try await set.resolve(third, .replace) == nil)
        #expect(set.emote(aliased: "Clap")?.emoteID == third.incoming.id && !set.all.contains { $0.id == clap.id })
        #expect(set.info?.count == 312, "a swap keeps the count")

        // a name past the loaded pages: 7TV's 409 answers, with the emote holding it
        let fresh = app.sevenTv.openSet(main.id, channelID: own.id)
        await fresh.load()
        let late = try #require(try await fresh.addChecking(outsider(4, name: "x"), alias: "catJAM5"))
        #expect(late.existing == nil && late.existingEmoteID == PreviewData.sevenTvEmoteID(400) && late.alias == "catJAM5")
    }

    @Test func copiesGoUnderTheAliasAndAClashInTheOtherSetIsAnswered() async throws {
        let app = await linkedApp()
        let own = try #require(app.sevenTv.selectedChannel)
        let main = try #require(app.sevenTv.sets(of: own.id).first)
        let set = app.sevenTv.openSet(main.id, channelID: own.id)
        await set.load()
        let christmas = try #require(set.otherSets.first { $0.name == "christmas" })

        let wave = try #require(set.emote(aliased: "liaWave"))
        #expect(try await set.copy(wave, to: christmas.id) == nil)
        #expect(app.sevenTv.sets(of: own.id).first { $0.id == christmas.id }?.count == christmas.count + 1)
        let target = app.sevenTv.openSet(christmas.id, channelID: own.id)
        await target.load()
        #expect(target.all.first?.alias == "liaWave" && target.all.first?.emoteID == wave.emoteID, "copied under its name here")

        let booba = try #require(set.emote(aliased: "BOOBA"))
        let clash = try #require(try await set.copy(booba, to: christmas.id))
        #expect(clash.setID == christmas.id && clash.setName == "christmas" && clash.existing == nil)
        #expect(clash.existingEmoteID == PreviewData.sevenTvEmoteID(2) && clash.suggestion == "BOOBA2")
        // christmas has BOOBA2 too: the answer is the next clash
        let again = try #require(try await set.resolve(clash, .addAs(clash.suggestion)))
        #expect(again.alias == "BOOBA2" && again.suggestion == "BOOBA3")
        let before = app.sevenTv.sets(of: own.id).first { $0.id == christmas.id }?.count
        #expect(try await set.resolve(clash, .replace) == nil)
        #expect(app.sevenTv.sets(of: own.id).first { $0.id == christmas.id }?.count == before, "a swap keeps the count")

        // several at once: the clash is left for its sheet, the rest go
        let subathon = try #require(set.otherSets.first { $0.name == "subathon" })
        let sadge = try #require(set.emote(aliased: "Sadge"))
        let copied = await set.copyMany([sadge, wave], to: subathon.id)
        #expect(copied.done == 1 && copied.clashes.map(\.alias) == ["Sadge"] && copied.failed == 0)
        let removed = await set.removeMany(Array(set.all.prefix(3)))
        #expect(removed.done == 3 && set.info?.count == 307)
    }

    @Test func uploadsMarkTheLibraryFilesAndFollowTheirState() async throws {
        let app = await linkedApp()
        await app.sevenTv.loadUploads()
        #expect(app.sevenTv.uploadsState == .loaded && app.sevenTv.uploads.map(\.name) == ["liaSpin", "coffeeLoop"])
        #expect(app.sevenTv.uploadedFileIDs == ["PrEvIeWitem000013", "PrEvIeWitem000008"])
        #expect(app.sevenTv.upload(forFile: "PrEvIeWitem000008")?.name == "coffeeLoop")
        let spin = app.sevenTv.uploads[0]
        #expect(app.sevenTv.state(of: spin) == .unknown)
        await app.sevenTv.readUploadStates()
        #expect(app.sevenTv.state(of: spin) == .processing && app.sevenTv.state(of: app.sevenTv.uploads[1]) == .ready)
        #expect(app.sevenTv.hasProcessingUploads)
        await app.sevenTv.watchUploads(every: 0.01, rounds: 3)
        #expect(app.sevenTv.state(of: spin) == .ready && !app.sevenTv.hasProcessingUploads)

        // an upload from the sheet joins the list at once, and its polling fills the state
        let upload = app.sevenTv.uploader(fileID: "PrEvIeWitem000003", bytes: 200_000, title: "dog dance")
        upload.pollEvery = 0.01
        await upload.upload()
        #expect(app.sevenTv.uploads.first?.fileID == "PrEvIeWitem000003" && app.sevenTv.uploads.first?.name == "dogDance")
        #expect(app.sevenTv.uploadedFileIDs.contains("PrEvIeWitem000003"))
        let newest = try #require(app.sevenTv.uploads.first)
        #expect(app.sevenTv.state(of: newest) == .ready)
        await app.sevenTv.loadUploads()
        #expect(app.sevenTv.uploads.count == 3, "the server lists it too, once")

        let off = await linkedApp(.stageNotConnected)
        await off.sevenTv.loadUploads()
        #expect(off.sevenTv.uploadsState == .failed(.notLinked) && off.sevenTv.uploads.isEmpty)
        app.sevenTv.reset()
        #expect(app.sevenTv.uploads.isEmpty && app.sevenTv.uploadsState == .idle && app.sevenTv.uploadInfo.isEmpty)
    }
}

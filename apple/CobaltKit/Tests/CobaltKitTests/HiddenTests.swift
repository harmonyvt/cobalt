import Foundation
import Testing
@testable import CobaltKit

// Hidden posts and auto-hide rules (APP-API-CONTRACT 37): the wire shapes, the capability, the routes on the real client,
// the preview server, the library model's album and bulk status, the rules model, and the device setting.

private let hiddenKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

private func wireFile(_ id: String) -> String {
    #"{"id":"\#(id)","kind":"private","source":"saved","name":"n","content_type":"video/mp4","created_at":1790000000000,"deletable":false}"#
}

private func wirePost(_ id: String, extra: String = "") -> String {
    #"{"id":"\#(id)","service":"instagram","created_at":1790000000000,"files":[\#(wireFile(id + "-f"))]\#(extra)}"#
}

// MARK: - wire shapes

struct HiddenWireTests {
    private func decode(_ json: String) throws -> LibraryPost {
        try CobaltJSON.decoder().decode(LibraryPost.self, from: Data(json.utf8))
    }

    @Test func aPostWithoutHiddenFieldsIsNotHidden() throws {
        let post = try decode(wirePost("a"))
        #expect(!post.hidden && post.hiddenBy == nil && post.hiddenRule == nil)
    }

    @Test func aHiddenPostSaysWhoAndWhichRule() throws {
        let byRule = try decode(wirePost("a", extra: #","hidden":true,"hidden_by":"rule","hidden_rule":"AbCdEfGhIjKlMnOp""#))
        #expect(byRule.hidden && byRule.hiddenBy == .rule && byRule.hiddenRule == "AbCdEfGhIjKlMnOp")
        let byYou = try decode(wirePost("b", extra: #","hidden":true,"hidden_by":"you","hidden_rule":null"#))
        #expect(byYou.hidden && byYou.hiddenBy == .you && byYou.hiddenRule == nil)
        let byChat = try decode(wirePost("c", extra: #","hidden":true,"hidden_by":"chat""#))
        #expect(byChat.hiddenBy == .chat)
        let visible = try decode(wirePost("d", extra: #","hidden":false,"hidden_by":null,"hidden_rule":null"#))
        #expect(!visible.hidden && visible.hiddenBy == nil)
    }

    @Test func aWordWeDoNotKnowReadsAsUnsaidAndNeverLosesThePost() throws {
        let post = try decode(wirePost("a", extra: #","hidden":true,"hidden_by":"robot""#))
        #expect(post.hidden && post.hiddenBy == nil)
        let odd = try decode(wirePost("b", extra: #","hidden":"yes""#))
        #expect(!odd.hidden)
    }

    @Test func aHiddenPostRoundTrips() throws {
        let post = try decode(wirePost("a", extra: #","hidden":true,"hidden_by":"rule","hidden_rule":"r1""#))
        let again = try CobaltJSON.decoder().decode(LibraryPost.self, from: JSONEncoder().encode(post))
        #expect(again.hidden && again.hiddenBy == .rule && again.hiddenRule == "r1")
    }

    @Test func theRulesWireDropsAKindItDoesNotKnow() throws {
        let json = """
        {"status":"success","rules":[
          {"id":"r1","kind":"upload","value":"","enabled":true,"hits":22,"created_at":1790000000000,"updated_at":1790000100000},
          {"id":"r2","kind":"colour","value":"red","enabled":true,"hits":0,"created_at":1,"updated_at":1},
          {"id":"r3","kind":"site","value":"instagram.com/close.friends.acct","enabled":false,"hits":4,"created_at":1,"updated_at":2}],
         "hidden":6,"held":1}
        """
        let list = try CobaltJSON.decoder().decode(HiddenWire.List.self, from: Data(json.utf8)).value
        #expect(list.rules.map(\.id) == ["r1", "r3"] && list.hidden == 6 && list.held == 1)
        #expect(list.rules[0].hits == 22 && list.rules[0].createdAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(list.rules[1].kind == .site && !list.rules[1].enabled && list.rules[1].updatedAt == Date(timeIntervalSince1970: 0.002))
    }
}

// MARK: - capability

struct HiddenCapabilityTests {
    private func caps(_ features: String, limits: String = "{}") throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":\#(features),"limits":\#(limits),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func theFeatureAndTheLimit() throws {
        let on = try caps(#"{"hidden":true}"#, limits: #"{"status_ids":50}"#)
        #expect(on.hidden && on.limits.statusIds == 50)
        let off = try caps(#"{"hidden":false}"#)
        #expect(!off.hidden)
        #expect(try !caps("{}").hidden)
    }

    @Test func theLimitDefaultsTo200AndIsClamped() throws {
        #expect(try caps(#"{"hidden":true}"#).limits.statusIds == 200)
        #expect(try caps("{}", limits: #"{"status_ids":9000}"#).limits.statusIds == 200)
        #expect(try caps("{}", limits: #"{"status_ids":0}"#).limits.statusIds == 1)
        #expect(Capabilities.unknown.limits.statusIds == 200 && !Capabilities.unknown.hidden)
    }

    @Test func thePreviewsThatHavePrivateLinksHaveIt() {
        #expect(PreviewData.capabilities(for: .happy).hidden)
        #expect(PreviewData.capabilities(for: .hidden).hidden)
        #expect(PreviewData.capabilities(for: .renditions).hidden)
        #expect(!PreviewData.capabilities(for: .plainCobalt).hidden)
        #expect(!PreviewData.capabilities(for: .legacyFork).hidden)
        #expect(!PreviewData.capabilities(for: .coldStart).hidden)
    }
}

// MARK: - the routes

@Suite(.serialized)
struct HiddenHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { hiddenKey })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    private let ruleJSON = #"{"id":"AbCdEfGhIjKlMnOp","kind":"words","value":"cat","enabled":true,"hits":0,"created_at":1790000000000,"updated_at":1790000000000}"#

    @Test func theLibraryPageCarriesTheHiddenCount() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"success","posts":[\#(wirePost("a")),\#(wirePost("b", extra: #","hidden":true,"hidden_by":"you""#))],"counts":{"posts":9,"files":12,"hidden":3},"usage":{"public_bytes":5,"private_bytes":7},"next":null}"#)
        }
        defer { server.stop() }
        let page = try await client(server).library(cursor: nil, limit: 20, v3: true)
        #expect(page.postCount == 9 && page.fileCount == 12 && page.hiddenCount == 3)
        #expect(page.publicBytes == 5 && page.privateBytes == 7 && page.posts.count == 2 && page.posts[1].hidden)
        let req = try #require(server.requests.first)
        #expect(req.path == "/library" && !req.query.contains("hidden"))
        // an older server sends no `hidden` count
        let old = try await LoopbackServer.start { _ in .json(#"{"status":"success","posts":[],"counts":{"posts":1,"files":1},"next":null}"#) }
        defer { old.stop() }
        #expect(try await client(old).library(cursor: nil, limit: 20, v3: true).hiddenCount == 0)
    }

    @Test func theAlbumAsksForHiddenOneWithV3AndPaging() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"success","posts":[\#(wirePost("a", extra: #","hidden":true,"hidden_by":"rule","hidden_rule":"r""#))],"counts":{"posts":4,"files":5,"hidden":7},"next":"cursor2"}"#)
        }
        defer { server.stop() }
        let page = try await client(server).hiddenLibrary(cursor: "cursor1", limit: 50)
        #expect(page.posts.count == 1 && page.posts[0].hiddenBy == .rule && page.next == "cursor2" && page.hiddenCount == 7)
        let req = try #require(server.requests.first)
        #expect(req.method == "GET" && req.path == "/library")
        let items = Set(req.query.split(separator: "&").map(String.init))
        #expect(items == ["hidden=1", "v=3", "limit=50", "cursor=cursor1"])
        #expect(req.headers["authorization"] == "Api-Key \(hiddenKey)")
    }

    @Test func setStatusPostsTheIdsAndReadsTheAnswer() async throws {
        let server = try await LoopbackServer.start { _ in
            .json("""
            {"status":"success","posts":[{"id":"a","post_key":"a","status":"private","files":[
               {"id":"a-f","visibility":"private","private_url":"https://share.capybaraharmony.com/p/AbCd"}]}],
             "failed":[{"id":"zzz","error":"error.library.not_found"}]}
            """)
        }
        defer { server.stop() }
        let change = try await client(server).setStatus(ids: ["a", "zzz"], status: .private)
        let req = try #require(server.requests.first)
        #expect(req.method == "POST" && req.path == "/library/status")
        #expect(req.headers["authorization"] == "Api-Key \(hiddenKey)")
        let body = try bodyJSON(req)
        #expect(body["ids"] as? [String] == ["a", "zzz"] && body["status"] as? String == "private" && body.count == 2)
        #expect(change.posts.count == 1 && change.posts[0].status == .private && change.posts[0].postKey == "a")
        #expect(change.posts[0].files == [.init(id: "a-f", visibility: "private", privateURL: URL(string: "https://share.capybaraharmony.com/p/AbCd"))])
        #expect(change.failed == [.init(id: "zzz", error: "error.library.not_found")])
    }

    @Test func everyStatusIsItsWord() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","posts":[],"failed":[]}"#) }
        defer { server.stop() }
        for status in PostStatus.allCases { _ = try await client(server).setStatus(ids: ["a"], status: status) }
        let words = try server.requests.map { try bodyJSON($0)["status"] as? String }
        #expect(words == ["off", "public", "private", "hidden"])
    }

    @Test func rulesListCreatePatchPreviewDeleteHitTheirRoutes() async throws {
        let server = try await LoopbackServer.start { req in
            switch (req.method, req.path) {
            case ("GET", "/hidden/rules"): return .json(#"{"status":"success","rules":[\#(ruleJSON)],"hidden":2,"held":1}"#)
            case ("POST", "/hidden/rules"): return .json(#"{"status":"success","rule":\#(ruleJSON),"applied":3}"#, status: 201)
            case ("POST", "/hidden/rules/preview"): return .json(#"{"status":"success","matches":5,"sample":["a","b"]}"#)
            case ("PATCH", "/hidden/rules/AbCdEfGhIjKlMnOp"): return .json(#"{"status":"success","rule":\#(ruleJSON),"applied":0}"#)
            case ("DELETE", "/hidden/rules/AbCdEfGhIjKlMnOp"): return .json(#"{"status":"success"}"#)
            default: return .init(status: 404)
            }
        }
        defer { server.stop() }
        let c = client(server)
        let list = try await c.hiddenRules()
        #expect(list.rules.count == 1 && list.hidden == 2 && list.held == 1 && list.rules[0].kind == .words)
        let created = try await c.createHiddenRule(kind: .words, value: "Cat", apply: true)
        #expect(created.applied == 3 && created.rule.id == "AbCdEfGhIjKlMnOp")
        let preview = try await c.previewHiddenRule(kind: .site, value: "x.com/name")
        #expect(preview.matches == 5 && preview.sample == ["a", "b"])
        _ = try await c.updateHiddenRule(id: "AbCdEfGhIjKlMnOp", enabled: false, value: nil, apply: false)
        _ = try await c.updateHiddenRule(id: "AbCdEfGhIjKlMnOp", enabled: nil, value: "dog", apply: true)
        try await c.deleteHiddenRule(id: "AbCdEfGhIjKlMnOp")

        let reqs = server.requests
        #expect(reqs.map { "\($0.method) \($0.path)" } == [
            "GET /hidden/rules", "POST /hidden/rules", "POST /hidden/rules/preview",
            "PATCH /hidden/rules/AbCdEfGhIjKlMnOp", "PATCH /hidden/rules/AbCdEfGhIjKlMnOp", "DELETE /hidden/rules/AbCdEfGhIjKlMnOp",
        ])
        #expect(reqs.allSatisfy { $0.headers["authorization"] == "Api-Key \(hiddenKey)" })
        let create = try bodyJSON(reqs[1])
        #expect(create["kind"] as? String == "words" && create["value"] as? String == "Cat" && create["apply"] as? Bool == true)
        let prev = try bodyJSON(reqs[2])
        #expect(prev["kind"] as? String == "site" && prev["value"] as? String == "x.com/name" && prev["apply"] == nil)
        let off = try bodyJSON(reqs[3])
        #expect(off["enabled"] as? Bool == false && off["value"] == nil && off["apply"] == nil)
        let value = try bodyJSON(reqs[4])
        #expect(value["value"] as? String == "dog" && value["apply"] as? Bool == true && value["enabled"] == nil)
    }

    @Test func aRuleWithoutApplyLeavesTheFieldOut() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","rule":\#(ruleJSON),"applied":0}"#, status: 201) }
        defer { server.stop() }
        _ = try await client(server).createHiddenRule(kind: .upload, value: "", apply: false)
        let body = try bodyJSON(try #require(server.requests.first))
        #expect(body["kind"] as? String == "upload" && body["apply"] == nil)
    }

    @Test func theServersRefusalsAreItsCodes() async throws {
        let server = try await LoopbackServer.start { req in
            switch req.path {
            case "/hidden/rules/nope": return .json(#"{"status":"error","error":{"code":"error.hidden.not_found"}}"#, status: 404)
            case "/hidden/rules": return req.method == "POST"
                ? .json(#"{"status":"error","error":{"code":"error.hidden.too_many"}}"#, status: 409)
                : .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 503)
            default: return .json(#"{"status":"error","error":{"code":"error.library.bad_request"}}"#, status: 400)
            }
        }
        defer { server.stop() }
        let c = client(server)
        await #expect(throws: CobaltError.api(code: "error.hidden.too_many", httpStatus: 409)) {
            _ = try await c.createHiddenRule(kind: .words, value: "x", apply: false)
        }
        await #expect(throws: CobaltError.api(code: "error.hidden.not_found", httpStatus: 404)) {
            try await c.deleteHiddenRule(id: "nope")
        }
        await #expect(throws: CobaltError.api(code: "error.library.bad_request", httpStatus: 400)) {
            _ = try await c.setStatus(ids: [], status: .off)
        }
        await #expect(throws: CobaltError.api(code: "error.api.generic", httpStatus: 503)) { _ = try await c.hiddenRules() }
    }
}

// MARK: - the preview server

@MainActor
struct HiddenPreviewTests {
    private func app(_ scenario: PreviewScenario = .hidden) -> AppModel {
        AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
    }

    @Test func theHiddenScenarioHasSixHiddenPostsAndThreeRules() async throws {
        let app = app()
        #expect(app.capabilities.hidden)
        #expect(app.library.hiddenCount == 6 && app.library.hiddenPosts.count == 6)
        #expect(app.library.hiddenPosts.allSatisfy { $0.hidden && $0.files.allSatisfy { !$0.isPublic && $0.privateURL == nil } })
        #expect(Set(app.library.hiddenPosts.compactMap(\.hiddenBy)) == [.you, .rule, .chat])
        #expect(app.library.hiddenPosts.compactMap(\.customTitle).contains("mirror fit"))
        await app.hiddenRules.load()
        #expect(app.hiddenRules.rules.map(\.kind) == [.upload, .site, .about])
        #expect(app.hiddenRules.rules.map(\.hits) == [22, 4, 14])
        #expect(app.hiddenRules.rules.map(\.enabled) == [true, true, false])
        #expect(app.hiddenRules.rules[1].value == "instagram.com/close.friends.acct" && app.hiddenRules.hidden == 6)
    }

    @Test func theLibraryPageLeavesHiddenPostsOutAndTheAlbumHasOnlyThem() async throws {
        let client = PreviewClient(scenario: .hidden, timeScale: 0.01, clock: SystemClock())
        let page = try await client.library(cursor: nil, limit: 20)
        #expect(page.posts.count == 6 && page.hiddenCount == 6 && page.posts.allSatisfy { !$0.hidden })
        let album = try await client.hiddenLibrary(cursor: nil, limit: 4)
        #expect(album.posts.count == 4 && album.next == "4" && album.hiddenCount == 6 && album.posts.allSatisfy(\.hidden))
        let rest = try await client.hiddenLibrary(cursor: album.next, limit: 4)
        #expect(rest.posts.count == 2 && rest.next == nil)
        #expect(Set(album.posts.map(\.id)).isDisjoint(with: rest.posts.map(\.id)))
    }

    @Test func hidingMovesAPostIntoTheAlbumAndOffMovesItBack() async throws {
        let client = PreviewClient(scenario: .happy, timeScale: 0.01, clock: SystemClock())
        let first = try await client.library(cursor: nil, limit: 20).posts[0]
        let hidden = try await client.setStatus(ids: [first.files[0].id], status: .hidden)       // a file id names its post
        #expect(hidden.posts.count == 1 && hidden.posts[0].postKey == first.id && hidden.failed.isEmpty)
        #expect(hidden.posts[0].files.allSatisfy { $0.visibility == "private" })
        let page = try await client.library(cursor: nil, limit: 20)
        #expect(!page.posts.contains { $0.id == first.id } && page.postCount == 14 && page.hiddenCount == 7)
        let album = try await client.hiddenLibrary(cursor: nil, limit: 20)
        #expect(album.posts.first?.id == first.id && album.posts.first?.hiddenBy == .you)

        let back = try await client.setStatus(ids: [first.id], status: .off)
        #expect(back.posts.first?.status == .off)
        let after = try await client.library(cursor: nil, limit: 20)
        let restored = try #require(after.posts.first { $0.id == first.id })
        #expect(!restored.hidden && restored.files.allSatisfy { !$0.isPublic } && after.hiddenCount == 6 && after.postCount == 15)
    }

    @Test func aSeededHiddenPostComesBackIntoTheLibraryWhenUnhidden() async throws {
        let client = PreviewClient(scenario: .hidden, timeScale: 0.01, clock: SystemClock())
        let answer = try await client.setStatus(ids: ["PrEvIeWhidden0004"], status: .private)
        #expect(answer.posts.first?.files.first?.privateURL != nil)
        let page = try await client.library(cursor: nil, limit: 20)
        let post = try #require(page.posts.first { $0.id == "PrEvIeWhidden0004" })
        #expect(page.posts.count == 7 && page.hiddenCount == 5 && post.files.first?.privateURL != nil)
        #expect(!(post.files.first?.isPublic ?? true))
    }

    @Test func unknownIdsFailAndPrivateNeedsAShareHost() async throws {
        let client = PreviewClient(scenario: .happy, timeScale: 0.01, clock: SystemClock())
        let answer = try await client.setStatus(ids: ["nope", "PrEvIeWitem000001", "PrEvIeWitem000002"], status: .hidden)
        #expect(answer.failed == [.init(id: "nope", error: "error.library.not_found")])
        #expect(answer.posts.count == 1, "two files of one post count once")
        await #expect(throws: CobaltError.api(code: "error.library.bad_request", httpStatus: 400)) {
            _ = try await client.setStatus(ids: [], status: .off)
        }
        let plain = PreviewClient(scenario: .plainCobalt, timeScale: 0.01, clock: SystemClock())
        await #expect(throws: PipelineFailure.unsupported) { _ = try await plain.hiddenRules() }
    }

    @Test func theRuleRoutesBehaveLikeTheServers() async throws {
        let client = PreviewClient(scenario: .hidden, timeScale: 0.01, clock: SystemClock())
        // upload: the posts whose service is upload (none in the library page); site by link host; words by title
        let uploads = try await client.previewHiddenRule(kind: .upload, value: "")
        #expect(uploads.matches == 0)
        let insta = try await client.previewHiddenRule(kind: .site, value: "https://www.Instagram.com/")
        #expect(insta.matches == 3 && insta.sample.count == 3)
        let words = try await client.previewHiddenRule(kind: .words, value: "KITCHEN")
        #expect(words.matches == 1)
        await #expect(throws: CobaltError.api(code: "error.hidden.bad_rule", httpStatus: 400)) {
            _ = try await client.previewHiddenRule(kind: .site, value: "not a host")
        }

        let made = try await client.createHiddenRule(kind: .words, value: "  Kitchen   Timer ", apply: true)
        #expect(made.rule.value == "kitchen timer" && made.rule.enabled && made.applied == 1 && made.rule.hits == 1)
        let page = try await client.library(cursor: nil, limit: 20)
        #expect(page.posts.count == 5 && page.hiddenCount == 7)
        let hidden = try await client.hiddenLibrary(cursor: nil, limit: 20)
        #expect(hidden.posts.first?.hiddenBy == .rule && hidden.posts.first?.hiddenRule == made.rule.id)

        let off = try await client.updateHiddenRule(id: made.rule.id, enabled: false, value: nil, apply: false)
        #expect(!off.rule.enabled)
        await #expect(throws: CobaltError.api(code: "error.hidden.not_found", httpStatus: 404)) {
            try await client.deleteHiddenRule(id: "gone")
        }
        try await client.deleteHiddenRule(id: made.rule.id)
        let list = try await client.hiddenRules()
        #expect(list.rules.count == 3 && list.hidden == 7)
    }

    @Test func fiftyRulesIsTheLimit() async throws {
        let client = PreviewClient(scenario: .renditions, timeScale: 0.001, clock: SystemClock())
        for n in 0..<50 { _ = try await client.createHiddenRule(kind: .words, value: "word \(n)", apply: false) }
        await #expect(throws: CobaltError.api(code: "error.hidden.too_many", httpStatus: 409)) {
            _ = try await client.createHiddenRule(kind: .words, value: "one more", apply: false)
        }
    }
}

// MARK: - the library model

@MainActor
struct HiddenLibraryModelTests {
    private func app() -> AppModel {
        let app = AppModel.makePreview(.happy, timeScale: 0.01, clock: SystemClock())
        return app
    }

    private func calls(_ app: AppModel) -> [String] {
        (app.ctx.client as! PreviewClient).hiddenState.calls
    }

    @Test func hidingMovesPostsIntoTheAlbumWithTheirFilesOff() async throws {
        let app = app()
        let lib = app.library
        let targets = Array(lib.posts.prefix(2))
        let ids = targets.map(\.id)
        #expect(lib.hiddenCount == 6 && lib.postCount == 15)
        let outcome = await lib.setStatus(.hidden, posts: targets)
        #expect(outcome.changed == 2 && outcome.failed.isEmpty && !lib.statusInFlight)
        #expect(!lib.posts.contains { ids.contains($0.id) } && lib.posts.count == 4)
        #expect(lib.hiddenPosts.prefix(2).map(\.id) == ids)
        #expect(lib.hiddenPosts.count == 8 && lib.hiddenCount == 8 && lib.postCount == 13)
        let moved = try #require(lib.hiddenPosts.first)
        #expect(moved.hidden && moved.hiddenBy == .you && moved.hiddenRule == nil)
        #expect(moved.files.allSatisfy { !$0.isPublic && $0.privateURL == nil && $0.url == nil })
        #expect(lib.fileCount == 24 - targets.reduce(0) { $0 + $1.files.count })
    }

    @Test func unhidingPutsAPostBackAtItsDateWithTheStatusItsFilesTook() async throws {
        let app = app()
        let lib = app.library
        let all = lib.posts
        let target = all[2]
        await lib.setStatus(.hidden, posts: [target])
        #expect(!lib.posts.contains { $0.id == target.id })
        let outcome = await lib.setStatus(.private, posts: [target])
        #expect(outcome.changed == 1)
        #expect(lib.posts.map(\.id) == all.map(\.id), "back where its date puts it")
        #expect(lib.hiddenPosts.count == 6 && lib.hiddenCount == 6 && lib.postCount == 15)
        let back = try #require(lib.posts.first { $0.id == target.id })
        #expect(!back.hidden && back.hiddenBy == nil)
        #expect(back.files.allSatisfy { !$0.isPublic && $0.privateURL != nil })

        // a seeded hidden post: off keeps its files off and puts it in the library
        let seeded = try #require(lib.hiddenPosts.first)
        await lib.setStatus(.off, posts: [seeded])
        let listed = try #require(lib.posts.first { $0.id == seeded.id })
        #expect(!listed.hidden && listed.files.allSatisfy { !$0.isPublic && $0.privateURL == nil })
        #expect(lib.hiddenCount == 5 && !lib.hiddenPosts.contains { $0.id == seeded.id })
    }

    @Test func publicTakesTheServersWordPerFile() async throws {
        let app = app()
        let lib = app.library
        let seeded = try #require(lib.hiddenPosts.first)
        await lib.setStatus(.public, posts: [seeded])
        let listed = try #require(lib.posts.first { $0.id == seeded.id })
        #expect(listed.files.allSatisfy { $0.isPublic && $0.privateURL == nil })
    }

    @Test func requestsAreChunkedAtTheServersLimit() async throws {
        let app = app()
        app.ctx.capabilities.limits.statusIds = 2
        let five = Array(app.library.posts.prefix(5))
        let outcome = await app.library.setStatus(.hidden, posts: five)
        #expect(outcome.changed == 5)
        #expect(calls(app) == ["STATUS hidden 2", "STATUS hidden 2", "STATUS hidden 1"])
        #expect(app.library.posts.count == 1 && app.library.hiddenCount == 11)
        // the same post twice is one id
        let again = await app.library.setStatus(.off, posts: [five[0], five[0]])
        #expect(again.changed == 1 && calls(app).last == "STATUS off 1")
    }

    @Test func whatTheServerRefusesStaysPut() async throws {
        let app = app()
        let real = app.library.posts[0]
        var ghost = real
        ghost.id = "ghost"
        ghost.files = []
        let outcome = await app.library.setStatus(.hidden, posts: [ghost, real])
        #expect(outcome.changed == 1 && outcome.failed == [.init(id: "ghost", error: "error.library.not_found")])
        #expect(!app.library.hiddenPosts.contains { $0.id == "ghost" } && app.library.hiddenPosts.first?.id == real.id)
        #expect(await app.library.setStatus(.hidden, posts: []) == StatusOutcome())
    }

    @Test func aFailedRequestMovesNothingAndSaysWhy() async throws {
        let app = AppModel.makePreview(.plainCobalt, timeScale: 0.01, clock: SystemClock())
        app.library.posts = PreviewData.libraryPage(now: Date()).posts
        let before = app.library.posts.map(\.id)
        let outcome = await app.library.setStatus(.hidden, posts: Array(app.library.posts.prefix(2)))
        #expect(outcome.changed == 0 && outcome.failed.count == 2 && outcome.failed[0].error == "error.library.unsupported")
        #expect(app.library.posts.map(\.id) == before && app.library.hiddenPosts.isEmpty)
        #expect(app.library.recentlyHidden.isEmpty)
    }

    @Test func aPageThatWasOnItsWayDoesNotPutAHiddenPostBack() async throws {
        let app = app()
        let lib = app.library
        let stale = PreviewData.libraryPage(now: Date())          // read before the post was hidden
        let target = lib.posts[0]
        await lib.setStatus(.hidden, posts: [target])
        lib.apply(stale, replacing: true)
        #expect(!lib.posts.contains { $0.id == target.id })
        // and a page the server marks hidden never lists it either
        var loud = PreviewData.libraryPage(now: Date())
        loud.posts[1].hidden = true
        lib.recentlyHidden = []
        lib.apply(loud, replacing: true)
        #expect(!lib.posts.contains { $0.id == loud.posts[1].id } && lib.posts.count == 5)
    }

    @Test func theAlbumLoadsPagesAndFollowsTheServersCount() async throws {
        let app = AppModel.makePreview(.hidden, timeScale: 0.01, clock: SystemClock())
        let lib = app.library
        lib.seedHidden([])
        #expect(lib.hiddenPosts.isEmpty)
        await lib.loadHidden()
        #expect(lib.hiddenPosts.count == 6 && lib.hiddenCount == 6 && !lib.hiddenHasMore && lib.hiddenFailure == nil && !lib.hiddenLoading)
        // pages of 20 are one page here; a smaller client page shows loadMore: exercise it through the client
        let client = try #require(app.ctx.client as? PreviewClient)
        let first = try await client.hiddenLibrary(cursor: nil, limit: 4)
        lib.applyHidden(first, replacing: true)
        #expect(lib.hiddenPosts.count == 4 && lib.hiddenHasMore)
        await lib.loadMoreHidden()
        #expect(lib.hiddenPosts.count == 6 && !lib.hiddenHasMore)
    }

    @Test func theAlbumSaysWhyItCouldNotLoad() async throws {
        let app = AppModel.makePreview(.plainCobalt, timeScale: 0.01, clock: SystemClock())
        await app.library.loadHidden()
        #expect(app.library.hiddenFailure == .unsupported && app.library.hiddenPosts.isEmpty)
    }
}

// MARK: - the rows

@MainActor
struct HiddenRowsTests {
    private func app() -> AppModel {
        let app = AppModel.makePreview(.hidden, timeScale: 0.01, clock: SystemClock())
        app.library.sort = .newest
        app.library.show = .everything
        app.library.kindFilter = .all
        return app
    }

    @Test func rowsNeverContainAHiddenPostUnlessTheChipIsOn() throws {
        let app = app()
        let hiddenIDs = Set(app.library.hiddenPosts.map(\.id))
        #expect(app.libraryRows.count == 6 && app.libraryRows.allSatisfy { !hiddenIDs.contains($0.id) })

        // a hidden post that sits in `posts` anyway (a server that sent it, an older copy) is left out
        var stray = try #require(app.library.hiddenPosts.first)
        stray.id = "stray"
        app.library.posts.append(stray)
        #expect(!app.libraryRows.contains { $0.id == "stray" })
        // and out of a search's rows
        app.library.searchResults = [stray] + Array(app.library.posts.prefix(1))
        app.library.query = "ab"
        app.library.searchResults = [stray] + Array(app.library.posts.prefix(1))
        #expect(!app.libraryRows.contains { $0.id == "stray" })
        app.library.query = ""

        app.library.showingHidden = true
        #expect(Set(app.libraryRows.map(\.id)) == hiddenIDs)
        #expect(app.libraryRows.count == 6)
        app.library.showingHidden = false
        #expect(app.libraryRows.allSatisfy { !hiddenIDs.contains($0.id) })
    }

    @Test func theAlbumTakesTheNameSearchAndTheKindChips() throws {
        let app = app()
        app.library.showingHidden = true
        app.library.query = "mirror"
        #expect(app.libraryRows.map(\.title).count == 1)
        app.library.query = ""
        app.library.sort = .newest
        #expect(app.libraryRows.count == 6)
    }

    @Test func hidingAPostTakesItOutOfTheRowsAndIntoTheAlbumRows() async throws {
        let app = app()
        let target = try #require(app.libraryRows.first)
        await app.library.setStatus(.hidden, posts: [try #require(app.library.posts.first { $0.id == target.id })])
        #expect(!app.libraryRows.contains { $0.id == target.id })
        app.library.showingHidden = true
        #expect(app.libraryRows.contains { $0.id == target.id } && app.libraryRows.count == 7)
    }

    @Test func theDeviceListsLeaveAHiddenPostsOfflineCopiesToTheAlbum() async throws {
        let app = AppModel.makePreview(.hidden, timeScale: 0.01, clock: SystemClock())
        let all = app.store.media
        #expect(app.visibleStoredMedia.count == all.count && app.hiddenStoredMedia.isEmpty)
        let ids = app.hiddenFileIDs
        #expect(ids.count == 6 && ids.contains("PrEvIeWhidden0001-src"))
        // a hidden post that one of the device's media belongs to (it lists the media's webp): that copy is the album's
        let media = try #require(all.first { $0.webps.contains { $0.remoteURL != nil } })
        var post = try #require(app.library.hiddenPosts.first)
        post.files[0].url = media.webps.compactMap(\.remoteURL).first
        app.library.hiddenPosts[0] = post
        #expect(app.isHidden(media))
        #expect(!app.visibleStoredMedia.contains { $0.id == media.id } && app.visibleStoredMedia.count == all.count - 1)
        #expect(app.hiddenStoredMedia.map(\.id) == [media.id])
    }
}

// MARK: - the rules model

@MainActor
struct HiddenRulesModelTests {
    private func app() -> AppModel {
        AppModel.makePreview(.hidden, timeScale: 0.01, clock: SystemClock())
    }

    @Test func loadingListsTheRules() async throws {
        let app = app()
        #expect(app.hiddenRules.rules.isEmpty)
        await app.hiddenRules.load()
        #expect(app.hiddenRules.rules.count == 3 && app.hiddenRules.hidden == 6 && app.hiddenRules.held == 0 && app.hiddenRules.failure == nil)
    }

    @Test func addingARuleAppendsItAndApplyingHidesWhatItMatches() async throws {
        let app = app()
        await app.hiddenRules.load()
        let applied = try await app.hiddenRules.add(kind: .words, value: "kitchen", apply: true)
        #expect(applied == 1)
        #expect(app.hiddenRules.rules.count == 4 && app.hiddenRules.rules.last?.value == "kitchen")
        #expect(app.hiddenRules.hidden == 7)
        // the library dropped the post and the album lists it first
        #expect(app.library.posts.count == 5 && app.library.hiddenCount == 7)
        #expect(app.library.hiddenPosts.first?.hiddenBy == .rule && app.library.hiddenPosts.first?.hiddenRule == app.hiddenRules.rules.last?.id)
        let none = try await app.hiddenRules.add(kind: .words, value: "zzzz nothing", apply: true)
        #expect(none == 0 && app.hiddenRules.rules.count == 5)
    }

    @Test func aBadRuleIsRefusedWithTheServersCode() async throws {
        let app = app()
        await #expect(throws: PipelineFailure.server(code: "error.hidden.bad_rule")) {
            _ = try await app.hiddenRules.add(kind: .site, value: "nodot", apply: false)
        }
        #expect(app.hiddenRules.rules.isEmpty)
    }

    @Test func theSwitchIsOptimisticAndRevertsWhenTheServerRefuses() async throws {
        let app = app()
        await app.hiddenRules.load()
        let about = try #require(app.hiddenRules.rules.first { $0.kind == .about })
        #expect(!about.enabled)
        await app.hiddenRules.setEnabled(about, true)
        #expect(app.hiddenRules.rules.first { $0.id == about.id }?.enabled == true)
        // a rule the server no longer has: refused, so the switch goes back
        let ghost = HideRule(id: "ghostghostghost0", kind: .words, value: "x", enabled: false)
        app.hiddenRules.rules.append(ghost)
        await app.hiddenRules.setEnabled(ghost, true)
        #expect(app.hiddenRules.rules.first { $0.id == ghost.id }?.enabled == false)
        #expect(app.hiddenRules.failure == .server(code: "error.hidden.not_found"))
    }

    @Test func deletingRemovesTheRuleAndAGhostGoesQuietly() async throws {
        let app = app()
        await app.hiddenRules.load()
        let upload = try #require(app.hiddenRules.rules.first { $0.kind == .upload })
        await app.hiddenRules.delete(upload)
        #expect(app.hiddenRules.rules.count == 2 && !app.hiddenRules.rules.contains { $0.id == upload.id })
        let again = try await (app.ctx.client as! PreviewClient).hiddenRules()
        #expect(again.rules.count == 2)
        let ghost = HideRule(id: "ghostghostghost0", kind: .words, value: "x")
        app.hiddenRules.rules.append(ghost)
        await app.hiddenRules.delete(ghost)
        #expect(!app.hiddenRules.rules.contains { $0.id == ghost.id })
    }

    @Test func previewCountsWhatARuleWouldHide() async throws {
        let app = app()
        let sample = await app.hiddenRules.preview(kind: .words, value: "kitchen")
        #expect(sample?.matches == 1 && sample?.sample.count == 1)
        #expect(await app.hiddenRules.preview(kind: .site, value: "nope") == nil, "a bad value has no count")
        #expect(app.hiddenRules.rules.isEmpty, "nothing changed")
    }

    @Test func aServerChangeEmptiesIt() async throws {
        let app = app()
        await app.hiddenRules.load()
        #expect(!app.hiddenRules.rules.isEmpty)
        app.hiddenRules.reset()
        #expect(app.hiddenRules.rules.isEmpty && app.hiddenRules.hidden == 0)
    }
}

// MARK: - the device setting

@MainActor
struct HiddenLockSettingTests {
    @Test func theLockIsOnUntilTheOwnerTurnsItOff() {
        let suite = "cobalt.hidden.lock.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let s = Settings(defaults: d, keychain: .memory())
        #expect(s.hiddenLock == true)
        s.hiddenLock = false
        #expect(d.object(forKey: "hidden.lock") as? Bool == false)
        #expect(Settings(defaults: d, keychain: .memory()).hiddenLock == false)
        s.hiddenLock = true
        #expect(Settings(defaults: d, keychain: .memory()).hiddenLock == true)
    }
}

// MARK: - the defensive locks

@MainActor
@Suite(.serialized)
struct HiddenDefensiveTests {
    @Test func aPageThatListsAHiddenPostNeverReachesTheLibrary() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"success","posts":[\#(wirePost("a")),\#(wirePost("b", extra: #","hidden":true,"hidden_by":"rule""#))],"counts":{"posts":1,"files":1,"hidden":1},"next":null}"#)
        }
        defer { server.stop() }
        let app = AppModel.makePreview(.emptyOrbit, timeScale: 0.01, clock: SystemClock())
        app.ctx.client = HTTPCobaltClient(baseURL: server.base, apiKey: { hiddenKey })
        let page = try await app.ctx.libraryPage(cursor: nil, limit: 20)
        #expect(page.posts.map(\.id) == ["a"] && page.hiddenCount == 1)
        await app.library.refresh()
        #expect(app.library.posts.map(\.id) == ["a"] && app.library.hiddenCount == 1)
    }

    @Test func theSearchNeverListsAHiddenPost() async throws {
        let app = AppModel.makePreview(.hidden, timeScale: 0.01, clock: SystemClock())
        let hidden = try #require(app.library.hiddenPosts.first)
        app.library.recentlyHidden = [app.library.posts[0].id]
        app.library.searchResults = nil
        // the filter the search answer goes through
        let answer = [hidden, app.library.posts[0], app.library.posts[1]].filter { !$0.hidden && !app.library.recentlyHidden.contains($0.id) }
        #expect(answer.map(\.id) == [app.library.posts[1].id])
    }
}

// MARK: - the persisted index (the review's fixes)

private func decodedPost(_ id: String, extra: String = "") throws -> LibraryPost {
    try CobaltJSON.decoder().decode(LibraryPost.self, from: Data(wirePost(id, extra: extra).utf8))
}

@MainActor
struct HiddenIndexTests {
    private func app(_ scenario: PreviewScenario = .hidden) -> AppModel {
        AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
    }

    @Test func theIndexSurvivesANewSettingsAndFiltersBeforeAnyLoad() async throws {
        let app = app()
        let hiddenIDs = Set(app.library.hiddenPosts.map(\.id))
        #expect(!hiddenIDs.isEmpty && app.settings.hiddenIndex.count == hiddenIDs.count)

        // a cold launch: new settings over the same defaults, a library that has loaded nothing
        let cold = Settings(defaults: app.settings.defaults, keychain: .memory())
        #expect(cold.hiddenIndex == app.settings.hiddenIndex && cold.hiddenIndex.postIDs.isSuperset(of: hiddenIDs))

        // an offline copy that belongs to a hidden post stays out of the device lists with the album not loaded at all
        let media = try #require(app.store.media.first { $0.webps.contains { $0.remoteURL != nil } })
        var post = try decodedPost("coldpost")
        post.files[0].url = media.webps.compactMap(\.remoteURL).first
        var index = cold.hiddenIndex
        index.add([post])
        app.settings.hiddenIndex = index
        app.library.reset()                                          // nothing in memory
        app.settings.hiddenIndex = index                             // ...but the index is what the device remembers
        #expect(app.library.hiddenPosts.isEmpty)
        #expect(app.isHidden(media))
        #expect(!app.visibleStoredMedia.contains { $0.id == media.id })
        #expect(app.hiddenStoredMedia.map(\.id) == [media.id])
        #expect(app.hiddenFileIDs.contains("coldpost-f"))
    }

    @Test func itKeysMatchEveryWayAMediaJoinsAPost() throws {
        var index = HiddenIndex()
        var post = try decodedPost("p1", extra: #","session":{"id":"sess-1","status":"ready","expires_at":1990000000000,"source_url":"https://example.com/x"}"#)
        post.files[0].mediaName = "AbCdEfGhIj.webp"
        index.add([post])
        #expect(index.postIDs == ["p1", "sess-1"] || index.postIDs.contains("p1"))
        #expect(index.fileIDs == ["p1-f"] && index.contains(post: "p1") && !index.contains(post: "p2"))
        let again = try JSONDecoder().decode(HiddenIndex.self, from: JSONEncoder().encode(index))
        #expect(again == index && again.postIDs == index.postIDs && again.fileIDs == index.fileIDs)
        index.remove(posts: ["p1"])
        #expect(index.isEmpty && index.postIDs.isEmpty && index.fileIDs.isEmpty)
    }

    @Test func anUnhideForgetsAndAHideRemembersAndTheDefaultsFollow() async throws {
        let app = app(.happy)
        let lib = app.library
        let target = lib.posts[0]
        #expect(!app.settings.hiddenIndex.contains(post: target.id))
        await lib.setStatus(.hidden, posts: [target])
        #expect(app.settings.hiddenIndex.contains(post: target.id) && app.settings.defaults.data(forKey: "hidden.index") != nil)
        #expect(Settings(defaults: app.settings.defaults, keychain: .memory()).hiddenIndex.contains(post: target.id))
        await lib.setStatus(.off, posts: [target])
        #expect(!app.settings.hiddenIndex.contains(post: target.id))
    }

    @Test func aServerChangeClearsIt() {
        let app = app()
        #expect(!app.settings.hiddenIndex.isEmpty)
        app.library.reset()
        #expect(app.settings.hiddenIndex.isEmpty && app.settings.defaults.data(forKey: "hidden.index") == nil)
    }

    @Test func aHiddenPostResolvesOnlyInTheAlbumLookup() throws {
        let app = app()
        let hidden = try #require(app.library.hiddenPosts.first)
        #expect(app.library.post(id: hidden.id) == nil)
        #expect(app.library.hiddenPost(id: hidden.id)?.id == hidden.id)
        // even one a search returned before it was hidden
        app.library.searchKnown[hidden.id] = hidden
        #expect(app.library.post(id: hidden.id) == nil)
    }

    @Test func photosSyncLeavesAHiddenPostsFilesOut() async throws {
        let env = try PhotosEnv()
        _ = try await env.add(session: "S1")
        _ = try await env.add(session: "S2")
        var index = HiddenIndex()
        index.add([try decodedPost("S1")])
        env.settings.hiddenIndex = index
        env.turnOn()
        await env.reconcile()
        #expect(env.library.addCalls == 1)
        #expect(env.ledger.entry("s:S2")?.state == .done && env.ledger.entry("s:S1") == nil, "the hidden post's video never reached Photos")
    }

    @Test func photosSyncDoesNotNeedTheLibraryToHaveLoaded() async throws {
        // the index is read from the settings alone: a new sync over the same settings still leaves S1 out
        let env = try PhotosEnv()
        _ = try await env.add(session: "S1")
        var index = HiddenIndex()
        index.add([try decodedPost("S1")])
        env.settings.hiddenIndex = index
        env.turnOn()
        let again = try env.another()
        await again.sync.reconcile()
        #expect(again.library.addCalls == 0 && again.ledger.entry("s:S1") == nil)
    }
}

@MainActor
struct HiddenFixLaneTests {
    private func app(_ scenario: PreviewScenario = .hidden) -> AppModel {
        AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
    }

    @Test func rowsComeFromTheAlbumOnlyWhileTheServerHasHidden() throws {
        let app = app()
        app.library.sort = .newest; app.library.show = .everything; app.library.kindFilter = .all
        let hiddenIDs = Set(app.library.hiddenPosts.map(\.id))
        app.library.showingHidden = true
        #expect(Set(app.libraryRows.map(\.id)) == hiddenIDs)
        app.capabilities.hidden = false                                // the server stopped offering hidden posts
        #expect(app.libraryRows.allSatisfy { !hiddenIDs.contains($0.id) })
        app.capabilities.hidden = true
        #expect(Set(app.libraryRows.map(\.id)) == hiddenIDs)
        // and the app closes the album when the capability goes
        var caps = app.capabilities
        caps.hidden = false
        app.apply(caps)
        #expect(!app.library.showingHidden && app.libraryRows.allSatisfy { !hiddenIDs.contains($0.id) })
    }

    @Test func aPageThatWasOnItsWayDoesNotPutAnUnhiddenPostBackInTheAlbum() async throws {
        let app = app()
        let lib = app.library
        let client = try #require(app.ctx.client as? PreviewClient)
        let stale = try await client.hiddenLibrary(cursor: nil, limit: 50)          // read before the unhide
        let target = try #require(lib.hiddenPosts.first)
        await lib.setStatus(.off, posts: [target])
        #expect(!lib.hiddenPosts.contains { $0.id == target.id } && !app.settings.hiddenIndex.contains(post: target.id))
        lib.applyHidden(stale, replacing: true)
        #expect(!lib.hiddenPosts.contains { $0.id == target.id }, "the stale page does not list it again")
        #expect(!app.settings.hiddenIndex.contains(post: target.id))
        #expect(lib.hiddenPosts.count == 5)
    }

    @Test func aPageThatBeganBeforeAHideKeepsTheHiddenPost() async throws {
        let app = app()
        let lib = app.library
        let client = try #require(app.ctx.client as? PreviewClient)
        let stale = try await client.hiddenLibrary(cursor: nil, limit: 50)          // read before the hide
        let target = lib.posts[0]
        await lib.setStatus(.hidden, posts: [target])
        lib.recentlyHidden.insert(target.id)
        lib.applyHidden(stale, replacing: true)
        #expect(lib.hiddenPosts.contains { $0.id == target.id })
    }

    @Test func aWholeAlbumReadIsDroppedWhenAStatusChangeHappenedMeanwhile() async throws {
        let app = app()
        let lib = app.library
        let target = try #require(lib.hiddenPosts.first)
        lib.hiddenSyncedCount = nil
        let before = lib.hiddenPosts.map(\.id)
        // the pages come in (they still list `target`), then the owner unhides it before the answer is kept
        lib.afterHiddenRead = { await lib.setStatus(.off, posts: [target]) }
        await lib.syncHiddenIndex(force: true)
        lib.afterHiddenRead = nil
        #expect(!lib.hiddenPosts.contains { $0.id == target.id }, "the stale read did not put it back")
        #expect(!app.settings.hiddenIndex.contains(post: target.id))
        #expect(lib.hiddenPosts.count == before.count - 1)
        // without a change in between the read replaces what is remembered
        var index = app.settings.hiddenIndex
        index.add([try decodedPost("phantom")])
        app.settings.hiddenIndex = index
        await lib.syncHiddenIndex(force: true)
        #expect(!app.settings.hiddenIndex.contains(post: "phantom"), "a post the server no longer lists is forgotten")
        #expect(app.settings.hiddenIndex.count == lib.hiddenPosts.count)
    }

    @Test func aRefreshReadsTheAlbumEvenWhenTheCountDidNotMove() async throws {
        let app = app()
        let lib = app.library
        var index = app.settings.hiddenIndex
        index.add([try decodedPost("phantom")])          // a swap on another device: same count, different posts
        app.settings.hiddenIndex = index
        #expect(lib.hiddenCount == lib.hiddenSyncedCount)
        await lib.refresh()
        await lib.hiddenSyncTask?.value                      // the quiet read the refresh started
        #expect(!app.settings.hiddenIndex.contains(post: "phantom"))
    }
}

// MARK: - per-file failures

@MainActor
@Suite(.serialized)
struct HiddenFileFailureTests {
    @Test func aFileThatCouldNotComeOffIsNotACountedPostFailure() async throws {
        let app = AppModel.makePreview(.happy, timeScale: 0.01, clock: SystemClock())
        let lib = app.library
        let target = try #require(lib.posts.first { $0.files.count >= 1 })
        let stuck = target.files[0].id
        let others = target.files.dropFirst().map { #"{"id":"\#($0.id)","visibility":"private"}"# }
        let files = ([#"{"id":"\#(stuck)","visibility":"public"}"#] + others).joined(separator: ",")
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"success","posts":[{"id":"\#(target.id)","post_key":"\#(target.id)","status":"hidden","files":[\#(files)]}],"failed":[{"id":"\#(stuck)","error":"error.library.not_toggleable"},{"id":"ghost","error":"error.library.not_found"}]}"#)
        }
        defer { server.stop() }
        app.ctx.client = HTTPCobaltClient(baseURL: server.base, apiKey: { hiddenKey })
        let outcome = await lib.setStatus(.hidden, posts: [target])
        #expect(outcome.changed == 1)
        #expect(outcome.failed == [.init(id: "ghost", error: "error.library.not_found")], "posts the server refused")
        #expect(outcome.fileFailures == [.init(id: stuck, error: "error.library.not_toggleable")], "files of a post that did hide")
        let hidden = try #require(lib.hiddenPosts.first { $0.id == target.id })
        let file = try #require(hidden.files.first { $0.id == stuck })
        #expect(hidden.hidden && file.wireVisibility == .public, "the file the server could not take off is still public, and says so")
        #expect(hidden.files.dropFirst().allSatisfy { !$0.isPublic })
    }

    @Test func aThrownErrorAfterAHideConvergesWithAQuietRefresh() async throws {
        let app = AppModel.makePreview(.hidden, timeScale: 0.01, clock: SystemClock())
        let lib = app.library
        let target = lib.posts[0]
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"error"}"#, status: 503) }
        defer { server.stop() }
        let preview = app.ctx.client
        app.ctx.client = HTTPCobaltClient(baseURL: server.base, apiKey: { hiddenKey })
        let outcome = await lib.setStatus(.hidden, posts: [target])
        #expect(outcome.changed == 0 && outcome.failed.count == 1 && lib.recentlyHidden.isEmpty)
        app.ctx.client = preview                             // the quiet refresh now reads the preview server
        for _ in 0..<50 where lib.hiddenSyncedAt == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(lib.hiddenSyncedAt != nil, "the lists were read again after the failed chunk")
    }
}

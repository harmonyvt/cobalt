import Foundation
import Testing
@testable import CobaltKit

// Share link collections (APP-API-CONTRACT 26): the capability, the wire shapes, the four routes and their refusals,
// the naming rule, the preview server and the store behind the links tab.

private let colKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

private let wireCollection = """
{"id":"AbCd1234EfGh5678","name":"memes","created_at":1790000000000,"updated_at":1790000500000,
 "set_ids":["9000000000000000002","9000000000000000001"]}
"""

// MARK: - capability

struct ShareCollectionCapabilityTests {
    private func caps(features: String, share: String = #","share_base_url":"https://share.capybaraharmony.com/""#) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":\#(features)\#(share),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func theFlagIsOnWithShareSets() throws {
        let on = try caps(features: #"{"library":true,"share_sets":true,"share_collections":true}"#)
        #expect(on.shareSets && on.shareCollections)
    }

    @Test func theFlagIsForcedOffWithoutShareSets() throws {
        #expect(try !caps(features: #"{"share_sets":false,"share_collections":true}"#).shareCollections)
        #expect(try !caps(features: #"{"share_collections":true}"#).shareCollections)
        // share_sets needs the share base, so collections do too
        #expect(try !caps(features: #"{"share_sets":true,"share_collections":true}"#, share: "").shareCollections)
        #expect(try !caps(features: #"{"share_sets":true,"share_collections":true}"#, share: #","share_base_url":null"#).shareCollections)
    }

    @Test func theFlagIsOffWhenAbsent() throws {
        #expect(try !caps(features: #"{"share_sets":true}"#).shareCollections)
        #expect(try !caps(features: #"{"share_sets":true,"share_collections":false}"#).shareCollections)
        #expect(!Capabilities.unknown.shareCollections)
    }

    @Test func thePreviewServersWithLinksHaveCollections() {
        for scenario in [PreviewScenario.happy, .renditions, .shareLinksEmpty, .shareLinksFail] {
            #expect(PreviewData.capabilities(for: scenario).shareCollections, "\(scenario)")
        }
        #expect(!PreviewData.capabilities(for: .renditionsLegacy).shareCollections)
        #expect(!PreviewData.capabilities(for: .plainCobalt).shareCollections)
    }
}

// MARK: - models and the rule

struct ShareCollectionModelTests {
    private func decode(_ json: String) throws -> ShareCollection {
        try CobaltJSON.decoder().decode(ShareCollection.self, from: Data(json.utf8))
    }

    @Test func aCollectionDecodesFromTheWire() throws {
        let c = try decode(wireCollection)
        #expect(c.id == "AbCd1234EfGh5678" && c.name == "memes")
        #expect(c.createdAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(c.updatedAt == Date(timeIntervalSince1970: 1_790_000_500))
        #expect(c.setIDs == ["9000000000000000002", "9000000000000000001"])
        #expect(c.contains("9000000000000000001") && !c.contains("nope"))
    }

    @Test func missingSetIDsIsEmpty() throws {
        let c = try decode(#"{"id":"AbCd1234EfGh5678","name":"x","created_at":1,"updated_at":2}"#)
        #expect(c.setIDs.isEmpty)
    }
}

struct ShareCollectionRuleTests {
    @Test func cleanNameTrimsAndStripsControls() {
        #expect(ShareCollectionRule.cleanName("memes") == "memes")
        #expect(ShareCollectionRule.cleanName("  for discord \n") == "for discord")
        #expect(ShareCollectionRule.cleanName("me\u{0007}mes\u{2028}") == "memes")
        #expect(ShareCollectionRule.cleanName("tab\there") == "tabhere")
    }

    @Test func emptyIsNil() {
        #expect(ShareCollectionRule.cleanName("") == nil)
        #expect(ShareCollectionRule.cleanName("   \n ") == nil)
        #expect(ShareCollectionRule.cleanName("\u{0001}\u{007F}") == nil)
    }

    @Test func sixtyIsTheLimit() {
        #expect(ShareCollectionRule.cleanName(String(repeating: "a", count: 60)) != nil)
        #expect(ShareCollectionRule.cleanName(String(repeating: "a", count: 61)) == nil)
        // the spaces around a 60-long name do not count
        #expect(ShareCollectionRule.cleanName("  " + String(repeating: "a", count: 60) + "  ") == String(repeating: "a", count: 60))
        #expect(ShareCollectionRule.nameLimit == 60)
    }

    @Test func codePointsAreCounted() {
        // "é" as e + combining accent is two code points: 31 of them are 62
        #expect(ShareCollectionRule.cleanName(String(repeating: "e\u{0301}", count: 30)) != nil)
        #expect(ShareCollectionRule.cleanName(String(repeating: "e\u{0301}", count: 31)) == nil)
    }
}

// MARK: - the four routes

struct ShareCollectionHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { colKey })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test func listIsGetKeyedAndKeepsTheServersOrder() async throws {
        let other = wireCollection.replacingOccurrences(of: "AbCd1234EfGh5678", with: "ZzZz1234EfGh5678")
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/share/collections"
                ? .json(#"{"status":"success","collections":["# + wireCollection + "," + other + "]}") : .init(status: 404)
        }
        defer { server.stop() }
        let list = try await client(server).shareCollections()
        let req = try #require(server.requests.first)
        #expect(req.headers["authorization"] == "Api-Key \(colKey)" && req.body.isEmpty)
        #expect(list.map(\.id) == ["AbCd1234EfGh5678", "ZzZz1234EfGh5678"])
    }

    @Test func createSendsTheNameAndTheLinks() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "POST" && req.path == "/share/collections"
                ? .json(#"{"status":"success","collection":"# + wireCollection + "}", status: 201) : .init(status: 404)
        }
        defer { server.stop() }
        let made = try await client(server).createShareCollection(name: "memes", setIDs: ["a", "b"])
        let req = try #require(server.requests.first)
        #expect(req.headers["authorization"] == "Api-Key \(colKey)" && req.headers["content-type"] == "application/json")
        let body = try bodyJSON(req)
        #expect(body["name"] as? String == "memes" && body["set_ids"] as? [String] == ["a", "b"] && body.count == 2)
        #expect(made.id == "AbCd1234EfGh5678")
    }

    @Test func createWithoutLinksOmitsSetIDs() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","collection":"# + wireCollection + "}", status: 201) }
        defer { server.stop() }
        _ = try await client(server).createShareCollection(name: "memes", setIDs: [])
        let body = try bodyJSON(try #require(server.requests.first))
        #expect(body["name"] as? String == "memes" && body["set_ids"] == nil && body.count == 1)
    }

    @Test func updateSendsOnlyWhatIsGiven() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "PATCH" && req.path == "/share/collections/AbCd1234EfGh5678"
                ? .json(#"{"status":"success","collection":"# + wireCollection + "}") : .init(status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        _ = try await c.updateShareCollection(id: "AbCd1234EfGh5678", name: "new", add: [], remove: [])
        _ = try await c.updateShareCollection(id: "AbCd1234EfGh5678", name: nil, add: ["a"], remove: [])
        _ = try await c.updateShareCollection(id: "AbCd1234EfGh5678", name: nil, add: [], remove: ["b", "c"])
        _ = try await c.updateShareCollection(id: "AbCd1234EfGh5678", name: "n", add: ["a"], remove: ["b"])
        let bodies = try server.requests.map(bodyJSON)
        #expect(bodies.count == 4)
        #expect(bodies[0]["name"] as? String == "new" && bodies[0].count == 1)
        #expect(bodies[1]["add"] as? [String] == ["a"] && bodies[1].count == 1)
        #expect(bodies[2]["remove"] as? [String] == ["b", "c"] && bodies[2].count == 1)
        #expect(bodies[3].count == 3 && bodies[3]["name"] as? String == "n")
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == "Api-Key \(colKey)" })
    }

    @Test func deleteIsDeleteKeyed() async throws {
        let server = try await LoopbackServer.start { req in
            req.path == "/share/collections/AbCd1234EfGh5678"
                ? .json(#"{"status":"success"}"#) : .json(#"{"status":"error","error":{"code":"error.collection.not_found"}}"#, status: 404)
        }
        defer { server.stop() }
        try await client(server).deleteShareCollection(id: "AbCd1234EfGh5678")
        let req = try #require(server.requests.first)
        #expect(req.method == "DELETE" && req.headers["authorization"] == "Api-Key \(colKey)")
        await #expect(throws: ShareCollectionError.notFound) { try await client(server).deleteShareCollection(id: "nope") }
    }

    private func refusing(_ body: String, status: Int) async throws -> LoopbackServer {
        try await LoopbackServer.start { _ in .json(body, status: status) }
    }

    @Test func errorsAreMapped() async throws {
        let cases: [(String, Int, ShareCollectionError)] = [
            (#"{"status":"error","error":{"code":"error.collection.bad_request"}}"#, 400, .badRequest),
            (#"{"status":"error","error":{"code":"error.collection.not_found"}}"#, 404, .notFound),
            (#"{"status":"error","error":{"code":"error.collection.link_not_found"},"set_ids":["x","y"]}"#, 409, .linkNotFound(["x", "y"])),
            (#"{"status":"error","error":{"code":"error.collection.link_not_found"}}"#, 409, .linkNotFound([])),
            (#"{"status":"error","error":{"code":"error.collection.too_many"}}"#, 409, .tooMany),
            (#"{"status":"error","error":{"code":"error.collection.full"}}"#, 409, .full),
            (#"{"status":"error","error":{"code":"error.api.generic"}}"#, 503, .unavailable),
        ]
        for (body, status, expected) in cases {
            let server = try await refusing(body, status: status)
            defer { server.stop() }
            let c = client(server)
            await #expect(throws: expected, "create \(status) \(expected)") { try await c.createShareCollection(name: "x", setIDs: []) }
            await #expect(throws: expected, "update \(status) \(expected)") {
                try await c.updateShareCollection(id: "AbCd1234EfGh5678", name: "x", add: [], remove: [])
            }
            await #expect(throws: expected, "list \(status) \(expected)") { try await c.shareCollections() }
        }
    }

    @Test func shareOffAndOtherCodesStayTheGenericOnes() async throws {
        let off = try await refusing(#"{"status":"error","error":{"code":"error.share.off"}}"#, status: 404)
        defer { off.stop() }
        await #expect(throws: CobaltError.api(code: "error.share.off", httpStatus: 404)) { try await client(off).shareCollections() }
        let auth = try await refusing(#"{"status":"error","error":{"code":"error.api.auth.key.invalid"}}"#, status: 401)
        defer { auth.stop() }
        await #expect(throws: CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)) { try await client(auth).shareCollections() }
    }

    @Test func aClientThatPredatesTheRoutesSaysUnsupported() async {
        // the defaults live on the protocol extension: a minimal conformer gets them
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
        await #expect(throws: PipelineFailure.unsupported) { try await bare.shareCollections() }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.createShareCollection(name: "x", setIDs: []) }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.updateShareCollection(id: "x", name: "y", add: [], remove: []) }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.deleteShareCollection(id: "x") }
    }
}

// MARK: - the preview server and the store

@MainActor
struct ShareCollectionStoreTests {
    private let one = "9000000000000000001"
    private let two = "9000000000000000002"
    private let three = "9000000000000000003"
    private let memes = "PrEvIeWcoll00001"
    private let discord = "PrEvIeWcoll00002"

    private func app(_ scenario: PreviewScenario = .happy) -> AppModel {
        AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
    }

    private func loaded(_ scenario: PreviewScenario = .happy) async -> AppModel {
        let app = app(scenario)
        await app.shareSets.refresh()
        return app
    }

    @Test func oneRefreshLoadsSetsAndCollections() async {
        let app = app()
        #expect(app.shareSets.collections.isEmpty)
        await app.shareSets.refresh()
        #expect(app.shareSets.state == .loaded && app.shareSets.sets.count == 3)
        #expect(app.shareSets.collections.map(\.id) == [memes, discord])
        #expect(app.shareSets.collections[0].name == "memes" && app.shareSets.collections[0].setIDs == [two, one])
        #expect(app.shareSets.collections[1].name == "for discord" && app.shareSets.collections[1].setIDs == [three])
    }

    @Test func theEmptyScenarioHasNone() async {
        let app = await loaded(.shareLinksEmpty)
        #expect(app.shareSets.state == .loaded && app.shareSets.collections.isEmpty && app.shareSets.sets.isEmpty)
    }

    @Test func theFailScenarioFailsToList() async {
        let app = await loaded(.shareLinksFail)
        guard case .failed = app.shareSets.state else { Issue.record("\(app.shareSets.state)"); return }
        #expect(app.shareSets.collections.isEmpty)
    }

    @Test func collectionsAreNotAskedForWithoutTheCapability() async throws {
        let app = app()
        app.ctx.capabilities.shareCollections = false
        await app.shareSets.refresh()
        #expect(app.shareSets.state == .loaded && app.shareSets.sets.count == 3 && app.shareSets.collections.isEmpty)
        let client = try #require(app.ctx.client as? PreviewClient)
        #expect(!client.shareState.calls.contains("GET collections"))
    }

    @Test func theJoinFollowsTheCollectionsOrderAndSkipsUnknownLinks() async throws {
        let app = await loaded()
        let memesCollection = try #require(app.shareSets.collection(memes))
        #expect(app.shareSets.sets(in: memesCollection).map(\.id) == [two, one])        // not the sets' newest-first order
        let odd = ShareCollection(id: "x", name: "x", createdAt: .now, updatedAt: .now, setIDs: [three, "ghost", one])
        #expect(app.shareSets.sets(in: odd).map(\.id) == [three, one])
        #expect(app.shareSets.collections(containing: one).map(\.id) == [memes])
        #expect(app.shareSets.collections(containing: three).map(\.id) == [discord])
    }

    @Test func createInsertsFirstWithItsLinks() async throws {
        let app = await loaded()
        let made = try await app.shareSets.createCollection(name: "work", setIDs: [one, three])
        #expect(app.shareSets.collections.first?.id == made.id && app.shareSets.collections.count == 3)
        #expect(made.name == "work" && made.setIDs == [one, three])
        await app.shareSets.refresh()
        #expect(app.shareSets.collections.first?.id == made.id, "the server lists it too")
        let empty = try await app.shareSets.createCollection(name: "later")
        #expect(empty.setIDs.isEmpty && app.shareSets.collections.first?.id == empty.id)
    }

    @Test func createEnforcesTheRules() async throws {
        let app = await loaded()
        await #expect(throws: ShareCollectionError.badRequest) { try await app.shareSets.createCollection(name: "   ") }
        await #expect(throws: ShareCollectionError.badRequest) {
            try await app.shareSets.createCollection(name: String(repeating: "x", count: 61))
        }
        await #expect(throws: ShareCollectionError.linkNotFound(["ghost"])) {
            try await app.shareSets.createCollection(name: "x", setIDs: [one, "ghost"])
        }
        #expect(app.shareSets.collections.count == 2, "nothing was inserted")
    }

    @Test func aHundredCollectionsIsTheCap() async throws {
        let app = await loaded()
        for i in 0..<98 { try await app.shareSets.createCollection(name: "c\(i)") }
        #expect(app.shareSets.collections.count == 100)
        await #expect(throws: ShareCollectionError.tooMany) { try await app.shareSets.createCollection(name: "one more") }
        #expect(app.shareSets.collections.count == 100)
    }

    @Test func renameMovesItFirst() async throws {
        let app = await loaded()
        let renamed = try await app.shareSets.renameCollection(discord, to: "  for discord!  ")
        #expect(renamed.name == "for discord!")
        #expect(app.shareSets.collections.map(\.id) == [discord, memes])
        #expect(app.shareSets.collection(discord)?.name == "for discord!" && app.shareSets.collection(discord)?.setIDs == [three])
        await #expect(throws: ShareCollectionError.badRequest) { try await app.shareSets.renameCollection(memes, to: " ") }
        #expect(app.shareSets.collection(memes)?.name == "memes")
    }

    @Test func addAndRemoveALink() async throws {
        let app = await loaded()
        let added = try await app.shareSets.addLink(three, to: memes)
        #expect(added.setIDs == [three, two, one], "most recently added first")
        #expect(app.shareSets.collections.first?.id == memes)
        #expect(app.shareSets.collections(containing: three).count == 2, "a link can be in several collections")
        // adding it again changes nothing
        let again = try await app.shareSets.addLink(three, to: memes)
        #expect(again.setIDs == [three, two, one])
        let removed = try await app.shareSets.removeLink(two, from: memes)
        #expect(removed.setIDs == [three, one])
        // removing one that is not there is a no-op
        let noop = try await app.shareSets.removeLink(two, from: memes)
        #expect(noop.setIDs == [three, one])
        #expect(app.shareSets.sets.count == 3, "the links themselves stay")
    }

    @Test func addingAGoneLinkSaysSoAndDropsIt() async throws {
        let app = await loaded()
        // the link was revoked elsewhere: the server no longer knows it
        let client = try #require(app.ctx.client as? PreviewClient)
        try await client.revokeShareSet(id: two)
        await #expect(throws: ShareCollectionError.linkNotFound([two])) { try await app.shareSets.addLink(two, to: discord) }
        #expect(!app.shareSets.sets.contains { $0.id == two }, "and the stale row goes")
        #expect(app.shareSets.collection(memes)?.setIDs == [one])
    }

    @Test func aCollectionGoneElsewhereIsDroppedOnAChange() async throws {
        let app = await loaded()
        let client = try #require(app.ctx.client as? PreviewClient)
        try await client.deleteShareCollection(id: discord)
        await #expect(throws: ShareCollectionError.notFound) { try await app.shareSets.addLink(one, to: discord) }
        #expect(app.shareSets.collection(discord) == nil)
    }

    @Test func deleteKeepsTheLinks() async throws {
        let app = await loaded()
        try await app.shareSets.deleteCollection(memes)
        #expect(app.shareSets.collections.map(\.id) == [discord] && app.shareSets.sets.count == 3)
        await app.shareSets.refresh()
        #expect(app.shareSets.collections.map(\.id) == [discord] && app.shareSets.sets.count == 3)
    }

    @Test func deletingOneTheServerNoLongerKnowsRemovesItToo() async throws {
        let app = await loaded()
        let client = try #require(app.ctx.client as? PreviewClient)
        try await client.deleteShareCollection(id: memes)
        await #expect(throws: ShareCollectionError.notFound) { try await client.deleteShareCollection(id: memes) }
        try await app.shareSets.deleteCollection(memes)
        #expect(app.shareSets.collection(memes) == nil)
    }

    @Test func anotherDeleteErrorLeavesIt() async throws {
        let app = await loaded(.renditionsLegacy)        // no share routes: `.unsupported`
        await #expect(throws: PipelineFailure.unsupported) { try await app.shareSets.deleteCollection("x") }
    }

    @Test func revokingALinkDropsItFromEveryCollection() async throws {
        let app = await loaded()
        _ = try await app.shareSets.addLink(one, to: discord)
        #expect(app.shareSets.collections(containing: one).count == 2)
        try await app.shareSets.revoke(one)
        #expect(app.shareSets.collection(memes)?.setIDs == [two])
        #expect(app.shareSets.collection(discord)?.setIDs == [three])
        #expect(app.shareSets.collections(containing: one).isEmpty)
        // and the server agrees
        await app.shareSets.refresh()
        #expect(app.shareSets.collection(memes)?.setIDs == [two] && app.shareSets.collection(discord)?.setIDs == [three])
    }

    @Test func aServerChangeForgetsTheCollections() async {
        let app = await loaded()
        #expect(app.shareSets.collections.count == 2)
        app.serverChanged()
        #expect(app.shareSets.collections.isEmpty && app.shareSets.sets.isEmpty && app.shareSets.state == .idle)
    }
}

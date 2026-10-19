import Foundation
import Testing
@testable import CobaltKit

// Collection sets (APP-API-CONTRACT 28): the capability, the wire shape, the four routes and their refusals, the
// preview server and the group half of the store behind the links tab.

private let groupKey = "5e2a7c41-0d9b-4f3a-8c16-2b7e9f0a4d33"

private let wireGroup = """
{"id":"GrOuP1234EfGh567","name":"weekend","created_at":1790000000000,"updated_at":1790000500000,
 "collection_ids":["PrEvIeWcoll00001","PrEvIeWcoll00002"]}
"""

// MARK: - capability

struct CollectionGroupCapabilityTests {
    private func caps(features: String, share: String = #","share_base_url":"https://share.capybaraharmony.com/""#) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":\#(features)\#(share),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func theFlagIsOnWithCollections() throws {
        let on = try caps(features: #"{"share_sets":true,"share_collections":true,"share_groups":true}"#)
        #expect(on.shareCollections && on.shareGroups)
    }

    @Test func theFlagIsForcedOffWithoutCollections() throws {
        #expect(try !caps(features: #"{"share_sets":true,"share_collections":false,"share_groups":true}"#).shareGroups)
        #expect(try !caps(features: #"{"share_sets":true,"share_groups":true}"#).shareGroups)
        #expect(try !caps(features: #"{"share_sets":true,"share_collections":true,"share_groups":true}"#, share: "").shareGroups)
    }

    @Test func theFlagIsOffWhenAbsent() throws {
        #expect(try !caps(features: #"{"share_sets":true,"share_collections":true}"#).shareGroups)
        #expect(!Capabilities.unknown.shareGroups)
    }

    @Test func thePreviewServersWithLinksHaveGroups() {
        for scenario in [PreviewScenario.happy, .renditions, .shareLinksEmpty, .shareLinksFail] {
            #expect(PreviewData.capabilities(for: scenario).shareGroups, "\(scenario)")
        }
        #expect(!PreviewData.capabilities(for: .renditionsLegacy).shareGroups)
        #expect(!PreviewData.capabilities(for: .plainCobalt).shareGroups)
    }
}

// MARK: - model and rule

struct CollectionGroupModelTests {
    private func decode(_ json: String) throws -> CollectionGroup {
        try CobaltJSON.decoder().decode(CollectionGroup.self, from: Data(json.utf8))
    }

    @Test func aGroupDecodesFromTheWire() throws {
        let g = try decode(wireGroup)
        #expect(g.id == "GrOuP1234EfGh567" && g.name == "weekend")
        #expect(g.createdAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(g.updatedAt == Date(timeIntervalSince1970: 1_790_000_500))
        #expect(g.collectionIDs == ["PrEvIeWcoll00001", "PrEvIeWcoll00002"])
        #expect(g.contains("PrEvIeWcoll00002") && !g.contains("nope"))
    }

    @Test func missingCollectionIDsIsEmpty() throws {
        #expect(try decode(#"{"id":"GrOuP1234EfGh567","name":"x","created_at":1,"updated_at":2}"#).collectionIDs.isEmpty)
    }

    @Test func theNameRuleIsACollections() {
        #expect(CollectionGroupRule.nameLimit == 60)
        #expect(CollectionGroupRule.cleanName("  weekend \n") == "weekend")
        #expect(CollectionGroupRule.cleanName("   ") == nil)
        #expect(CollectionGroupRule.cleanName(String(repeating: "a", count: 61)) == nil)
    }
}

// MARK: - the four routes

struct CollectionGroupHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { groupKey })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    private func refusing(_ body: String, status: Int) async throws -> LoopbackServer {
        try await LoopbackServer.start { _ in .json(body, status: status) }
    }

    @Test func listIsGetKeyedAndKeepsTheServersOrder() async throws {
        let other = wireGroup.replacingOccurrences(of: "GrOuP1234EfGh567", with: "ZzZz1234EfGh5678")
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/share/groups"
                ? .json(#"{"status":"success","groups":["# + wireGroup + "," + other + "]}") : .init(status: 404)
        }
        defer { server.stop() }
        let list = try await client(server).collectionGroups()
        let req = try #require(server.requests.first)
        #expect(req.headers["authorization"] == "Api-Key \(groupKey)" && req.body.isEmpty)
        #expect(list.map(\.id) == ["GrOuP1234EfGh567", "ZzZz1234EfGh5678"])
    }

    @Test func createSendsTheNameAndTheCollections() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "POST" && req.path == "/share/groups"
                ? .json(#"{"status":"success","group":"# + wireGroup + "}", status: 201) : .init(status: 404)
        }
        defer { server.stop() }
        let made = try await client(server).createCollectionGroup(name: "weekend", collectionIDs: ["a", "b"])
        let req = try #require(server.requests.first)
        #expect(req.headers["authorization"] == "Api-Key \(groupKey)" && req.headers["content-type"] == "application/json")
        let body = try bodyJSON(req)
        #expect(body["name"] as? String == "weekend" && body["collection_ids"] as? [String] == ["a", "b"] && body.count == 2)
        #expect(made.id == "GrOuP1234EfGh567")
    }

    @Test func createWithoutCollectionsOmitsTheField() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","group":"# + wireGroup + "}", status: 201) }
        defer { server.stop() }
        _ = try await client(server).createCollectionGroup(name: "weekend", collectionIDs: [])
        let body = try bodyJSON(try #require(server.requests.first))
        #expect(body["name"] as? String == "weekend" && body["collection_ids"] == nil && body.count == 1)
    }

    @Test func updateSendsOnlyWhatIsGiven() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "PATCH" && req.path == "/share/groups/GrOuP1234EfGh567"
                ? .json(#"{"status":"success","group":"# + wireGroup + "}") : .init(status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        _ = try await c.updateCollectionGroup(id: "GrOuP1234EfGh567", name: "new", add: [], remove: [])
        _ = try await c.updateCollectionGroup(id: "GrOuP1234EfGh567", name: nil, add: ["a"], remove: [])
        _ = try await c.updateCollectionGroup(id: "GrOuP1234EfGh567", name: nil, add: [], remove: ["b", "c"])
        let bodies = try server.requests.map(bodyJSON)
        #expect(bodies.count == 3)
        #expect(bodies[0]["name"] as? String == "new" && bodies[0].count == 1)
        #expect(bodies[1]["add"] as? [String] == ["a"] && bodies[1].count == 1)
        #expect(bodies[2]["remove"] as? [String] == ["b", "c"] && bodies[2].count == 1)
    }

    @Test func deleteIsDeleteKeyed() async throws {
        let server = try await LoopbackServer.start { req in
            req.path == "/share/groups/GrOuP1234EfGh567"
                ? .json(#"{"status":"success"}"#) : .json(#"{"status":"error","error":{"code":"error.group.not_found"}}"#, status: 404)
        }
        defer { server.stop() }
        try await client(server).deleteCollectionGroup(id: "GrOuP1234EfGh567")
        let req = try #require(server.requests.first)
        #expect(req.method == "DELETE" && req.headers["authorization"] == "Api-Key \(groupKey)")
        await #expect(throws: CollectionGroupError.notFound) { try await client(server).deleteCollectionGroup(id: "nope") }
    }

    @Test func errorsAreMapped() async throws {
        let cases: [(String, Int, CollectionGroupError)] = [
            (#"{"status":"error","error":{"code":"error.group.bad_request"}}"#, 400, .badRequest),
            (#"{"status":"error","error":{"code":"error.group.not_found"}}"#, 404, .notFound),
            (#"{"status":"error","error":{"code":"error.group.collection_not_found"},"collection_ids":["x","y"]}"#, 409, .collectionNotFound(["x", "y"])),
            (#"{"status":"error","error":{"code":"error.group.collection_not_found"}}"#, 409, .collectionNotFound([])),
            (#"{"status":"error","error":{"code":"error.group.too_many"}}"#, 409, .tooMany),
            (#"{"status":"error","error":{"code":"error.group.full"}}"#, 409, .full),
            (#"{"status":"error","error":{"code":"error.api.generic"}}"#, 503, .unavailable),
        ]
        for (body, status, expected) in cases {
            let server = try await refusing(body, status: status)
            defer { server.stop() }
            let c = client(server)
            await #expect(throws: expected, "create \(status) \(expected)") { try await c.createCollectionGroup(name: "x", collectionIDs: []) }
            await #expect(throws: expected, "update \(status) \(expected)") {
                try await c.updateCollectionGroup(id: "GrOuP1234EfGh567", name: "x", add: [], remove: [])
            }
            await #expect(throws: expected, "list \(status) \(expected)") { try await c.collectionGroups() }
        }
    }

    @Test func shareOffStaysTheGenericOne() async throws {
        let off = try await refusing(#"{"status":"error","error":{"code":"error.share.off"}}"#, status: 404)
        defer { off.stop() }
        await #expect(throws: CobaltError.api(code: "error.share.off", httpStatus: 404)) { try await client(off).collectionGroups() }
    }

    @Test func anUnreadableAnswerIsInvalid() async throws {
        let server = try await refusing(#"{"status":"success"}"#, status: 200)
        defer { server.stop() }
        await #expect(throws: CobaltError.invalidResponse(httpStatus: 200)) {
            try await client(server).createCollectionGroup(name: "x", collectionIDs: [])
        }
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
        await #expect(throws: PipelineFailure.unsupported) { try await bare.collectionGroups() }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.createCollectionGroup(name: "x", collectionIDs: []) }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.updateCollectionGroup(id: "x", name: "y", add: [], remove: []) }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.deleteCollectionGroup(id: "x") }
    }
}

// MARK: - the preview server and the store

@MainActor
struct CollectionGroupStoreTests {
    private let one = "9000000000000000001"
    private let two = "9000000000000000002"
    private let three = "9000000000000000003"
    private let memes = "PrEvIeWcoll00001"
    private let discord = "PrEvIeWcoll00002"
    private let weekend = "PrEvIeWgrup00001"
    private let work = "PrEvIeWgrup00002"

    private func app(_ scenario: PreviewScenario = .happy) -> AppModel {
        AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
    }

    private func loaded(_ scenario: PreviewScenario = .happy) async -> AppModel {
        let app = app(scenario)
        await app.shareSets.refresh()
        return app
    }

    @Test func oneRefreshLoadsSetsCollectionsAndGroups() async {
        let app = app()
        #expect(app.shareSets.groups.isEmpty)
        await app.shareSets.refresh()
        #expect(app.shareSets.state == .loaded && app.shareSets.sets.count == 3 && app.shareSets.collections.count == 2)
        #expect(app.shareSets.groups.map(\.id) == [weekend, work])
        #expect(app.shareSets.groups[0].name == "weekend" && app.shareSets.groups[0].collectionIDs == [memes, discord])
        #expect(app.shareSets.groups[1].name == "work" && app.shareSets.groups[1].collectionIDs == [discord])
    }

    @Test func theEmptyAndFailScenarios() async {
        let empty = await loaded(.shareLinksEmpty)
        #expect(empty.shareSets.state == .loaded && empty.shareSets.groups.isEmpty)
        let fail = await loaded(.shareLinksFail)
        guard case .failed = fail.shareSets.state else { Issue.record("\(fail.shareSets.state)"); return }
        #expect(fail.shareSets.groups.isEmpty)
    }

    @Test func groupsAreNotAskedForWithoutTheCapability() async throws {
        let app = app()
        app.ctx.capabilities.shareGroups = false
        await app.shareSets.refresh()
        #expect(app.shareSets.state == .loaded && app.shareSets.collections.count == 2 && app.shareSets.groups.isEmpty)
        let client = try #require(app.ctx.client as? PreviewClient)
        #expect(!client.shareState.calls.contains("GET groups"))
    }

    @Test func groupsNeedCollections() async throws {
        let app = app()
        app.ctx.capabilities.shareCollections = false
        await app.shareSets.refresh()
        #expect(app.shareSets.groups.isEmpty)
        let client = try #require(app.ctx.client as? PreviewClient)
        #expect(!client.shareState.calls.contains("GET groups"))
    }

    @Test func theJoinFollowsTheGroupsOrderAndSkipsUnknownCollections() async throws {
        let app = await loaded()
        let g = try #require(app.shareSets.group(weekend))
        #expect(app.shareSets.collections(in: g).map(\.id) == [memes, discord])
        let odd = CollectionGroup(id: "x", name: "x", createdAt: .now, updatedAt: .now, collectionIDs: [discord, "ghost", memes])
        #expect(app.shareSets.collections(in: odd).map(\.id) == [discord, memes])
        #expect(app.shareSets.groups(containing: discord).map(\.id) == [weekend, work])
        #expect(app.shareSets.groups(containing: memes).map(\.id) == [weekend])
    }

    @Test func copyAllJoinsEveryLinkOnceInTheGroupsOrder() async throws {
        let app = await loaded()
        _ = try await app.shareSets.addLink(one, to: discord)       // `one` is in both collections now
        let g = try #require(app.shareSets.group(weekend))
        let url = { (id: String) in PreviewData.shareURL(id: id).absoluteString }
        // memes: [two, one]; for discord: [one, three] — `one` shows once, where it first shows
        #expect(app.shareSets.linksText(in: g) == [url(two), url(one), url(three)].joined(separator: "\n"))
        let empty = CollectionGroup(id: "z", name: "z", createdAt: .now, updatedAt: .now, collectionIDs: [])
        #expect(app.shareSets.linksText(in: empty) == nil)
    }

    @Test func createInsertsFirstWithItsCollections() async throws {
        let app = await loaded()
        let made = try await app.shareSets.createGroup(name: "  all  ", collectionIDs: [discord, memes])
        #expect(made.name == "all" && made.collectionIDs == [discord, memes])
        #expect(app.shareSets.groups.first?.id == made.id && app.shareSets.groups.count == 3)
        await app.shareSets.refresh()
        #expect(app.shareSets.groups.first?.id == made.id, "the server lists it too")
        let empty = try await app.shareSets.createGroup(name: "later")
        #expect(empty.collectionIDs.isEmpty && app.shareSets.groups.first?.id == empty.id)
    }

    @Test func createEnforcesTheRules() async throws {
        let app = await loaded()
        await #expect(throws: CollectionGroupError.badRequest) { try await app.shareSets.createGroup(name: " ") }
        await #expect(throws: CollectionGroupError.collectionNotFound(["ghostghostghost1"])) {
            try await app.shareSets.createGroup(name: "x", collectionIDs: [memes, "ghostghostghost1"])
        }
        #expect(app.shareSets.groups.count == 2, "nothing was inserted")
        for i in 0..<98 { try await app.shareSets.createGroup(name: "g\(i)") }
        await #expect(throws: CollectionGroupError.tooMany) { try await app.shareSets.createGroup(name: "one more") }
        #expect(app.shareSets.groups.count == 100)
    }

    @Test func renameAddAndRemove() async throws {
        let app = await loaded()
        let renamed = try await app.shareSets.renameGroup(work, to: "work stuff")
        #expect(renamed.name == "work stuff" && app.shareSets.groups.map(\.id) == [work, weekend])
        let added = try await app.shareSets.addCollection(memes, to: work)
        #expect(added.collectionIDs == [memes, discord], "most recently added first")
        let again = try await app.shareSets.addCollection(memes, to: work)
        #expect(again.collectionIDs == [memes, discord])
        let removed = try await app.shareSets.removeCollection(discord, from: work)
        #expect(removed.collectionIDs == [memes])
        #expect(app.shareSets.group(work)?.collectionIDs == [memes])
        #expect(app.shareSets.collections.count == 2, "the collections themselves stay")
    }

    @Test func aGroupGoneElsewhereIsDroppedOnAChange() async throws {
        let app = await loaded()
        let client = try #require(app.ctx.client as? PreviewClient)
        try await client.deleteCollectionGroup(id: work)
        await #expect(throws: CollectionGroupError.notFound) { try await app.shareSets.addCollection(memes, to: work) }
        #expect(app.shareSets.group(work) == nil && app.shareSets.group(weekend) != nil)
    }

    @Test func addingAGoneCollectionSaysSoAndDropsIt() async throws {
        let app = await loaded()
        let client = try #require(app.ctx.client as? PreviewClient)
        try await client.deleteShareCollection(id: memes)
        await #expect(throws: CollectionGroupError.collectionNotFound([memes])) { try await app.shareSets.addCollection(memes, to: work) }
        #expect(app.shareSets.collection(memes) == nil)
        #expect(app.shareSets.group(weekend)?.collectionIDs == [discord])
    }

    @Test func deletingAGroupKeepsItsCollections() async throws {
        let app = await loaded()
        try await app.shareSets.deleteGroup(weekend)
        #expect(app.shareSets.groups.map(\.id) == [work] && app.shareSets.collections.count == 2)
        // one the server no longer knows goes locally too
        try await app.shareSets.deleteGroup(weekend)
        await app.shareSets.refresh()
        #expect(app.shareSets.groups.map(\.id) == [work] && app.shareSets.collections.count == 2)
    }

    @Test func deletingACollectionDropsItFromEveryGroup() async throws {
        let app = await loaded()
        try await app.shareSets.deleteCollection(discord)
        #expect(app.shareSets.group(weekend)?.collectionIDs == [memes])
        #expect(app.shareSets.group(work)?.collectionIDs == [])
        await app.shareSets.refresh()
        #expect(app.shareSets.group(weekend)?.collectionIDs == [memes] && app.shareSets.group(work)?.collectionIDs == [])
    }

    @Test func aServerWithoutRoutesIsUnsupported() async {
        let app = await loaded(.renditionsLegacy)
        await #expect(throws: PipelineFailure.unsupported) { try await app.shareSets.deleteGroup("x") }
    }

    @Test func aServerChangeForgetsTheGroups() async {
        let app = await loaded()
        #expect(app.shareSets.groups.count == 2)
        app.serverChanged()
        #expect(app.shareSets.groups.isEmpty && app.shareSets.state == .idle)
    }
}

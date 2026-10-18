import Foundation
import Testing
@testable import CobaltKit

// Gallery share links (APP-API-CONTRACT 24): the capability, the wire shapes, the three routes, the rule the select bar
// and the server share, the file that stands for a post, and the store behind the links tab.

private let setKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private let wireSet = """
{"id":"9000000000000000001","url":"https://share.capybaraharmony.com/g/9000000000000000001","title":null,"created_at":1790000000000,
 "items":[
  {"id":"v1","url":"https://media.capybaraharmony.com/AbCdEfGhIj.mp4","content_type":"video/mp4","poster_url":"https://media.capybaraharmony.com/AbCdEfGhIj.jpg","width":720,"height":1280,"duration":3.5},
  {"id":"w1","url":"https://media.capybaraharmony.com/KlMnOpQrSt.webp","content_type":"image/webp","poster_url":null,"width":480,"height":480,"duration":null},
  {"id":"gone","url":null,"content_type":"video/mp4","poster_url":null,"width":null,"height":null,"duration":null}]}
"""

// MARK: - capability

struct ShareSetCapabilityTests {
    private func caps(features: String, limits: String = "", share: String = #","share_base_url":"https://share.capybaraharmony.com/""#) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":\#(features)\#(limits)\#(share),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func theFlagNeedsTheShareBase() throws {
        #expect(try caps(features: #"{"library":true,"share_sets":true}"#).shareSets)
        #expect(try !caps(features: #"{"library":true,"share_sets":true}"#, share: #","share_base_url":null"#).shareSets)
        #expect(try !caps(features: #"{"library":true,"share_sets":true}"#, share: "").shareSets)
        #expect(try !caps(features: #"{"library":true,"share_sets":false}"#).shareSets)
        #expect(try !caps(features: #"{"library":true}"#).shareSets)
        #expect(!Capabilities.unknown.shareSets)
    }

    @Test func theMaximumIsReadDefaultsToFourAndNeverDropsBelowTwo() throws {
        let f = #"{"share_sets":true}"#
        #expect(try caps(features: f).limits.shareSetMax == 4)
        #expect(try caps(features: f, limits: #","limits":{"share_set_max":6}"#).limits.shareSetMax == 6)
        #expect(try caps(features: f, limits: #","limits":{"share_set_max":1}"#).limits.shareSetMax == 2)
        #expect(try caps(features: f, limits: #","limits":{"max_webp_seconds":10}"#).limits.shareSetMax == 4)
        #expect(Capabilities.Limits.fork.shareSetMax == 4)
    }

    @Test func theTabIsAvailableOnlyWithTheFeature() throws {
        var c = Capabilities.unknown
        c.library = true
        #expect(AppTab.links.isAvailable(with: c) == false)
        c.shareSets = true
        #expect(AppTab.links.isAvailable(with: c))
        #expect(AppTab.allCases == [.save, .library, .links, .chat, .queue, .settings])
    }
}

// MARK: - models

struct ShareSetModelTests {
    private func decode(_ json: String) throws -> ShareSet {
        try CobaltJSON.decoder().decode(ShareSet.self, from: Data(json.utf8))
    }

    @Test func aSetDecodesFromTheWire() throws {
        let set = try decode(wireSet)
        #expect(set.id == "9000000000000000001")
        #expect(set.url.absoluteString == "https://share.capybaraharmony.com/g/9000000000000000001")
        #expect(set.title == nil)
        #expect(set.createdAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(set.items.map(\.id) == ["v1", "w1", "gone"])
        let video = set.items[0]
        #expect(video.contentType == "video/mp4" && video.width == 720 && video.height == 1280 && video.duration == 3.5)
        #expect(video.posterURL?.lastPathComponent == "AbCdEfGhIj.jpg" && video.isPublic)
        #expect(set.items[2].url == nil && !set.items[2].isPublic)
        #expect(set.publicItemCount == 2)
    }

    @Test func theTitleIsShownElseTheCount() throws {
        #expect(try decode(wireSet).displayTitle == "3 files")
        let titled = try decode(wireSet.replacingOccurrences(of: #""title":null"#, with: #""title":"harbour""#))
        #expect(titled.title == "harbour" && titled.displayTitle == "harbour")
    }

    @Test func theThumbnailIsThePosterElseAnImageItself() throws {
        let set = try decode(wireSet)
        #expect(set.items[0].thumbnailURL?.lastPathComponent == "AbCdEfGhIj.jpg")        // video with a poster
        #expect(set.items[1].thumbnailURL?.lastPathComponent == "KlMnOpQrSt.webp")        // an image: itself
        #expect(set.items[2].thumbnailURL == nil)                                         // private video
        let bare = ShareSetItem(id: "x", url: URL(string: "https://media.capybaraharmony.com/AbCdEfGhIj.mp4"), contentType: "video/mp4")
        #expect(bare.thumbnailURL == nil)
        let photo = ShareSetItem(id: "p", url: URL(string: "https://media.capybaraharmony.com/PpPpPpPp01.jpg"), contentType: "image/jpeg")
        #expect(photo.thumbnailURL == photo.url)
    }

    @Test func oneOddItemNeverLosesTheSet() throws {
        let set = try decode(wireSet.replacingOccurrences(of: #"{"id":"gone""#, with: #"{"nope":1},{"id":"gone""#))
        #expect(set.items.map(\.id) == ["v1", "w1", "gone"])
    }
}

// MARK: - the rule

struct ShareSetRuleTests {
    @Test func verdicts() {
        #expect(ShareSetRule.verdict(publicFlags: [], max: 4) == .tooFew)
        #expect(ShareSetRule.verdict(publicFlags: [true], max: 4) == .tooFew)
        #expect(ShareSetRule.verdict(publicFlags: [false], max: 4) == .tooFew)
        #expect(ShareSetRule.verdict(publicFlags: [true, true], max: 4) == .ready)
        #expect(ShareSetRule.verdict(publicFlags: [true, true, true], max: 4) == .ready)
        #expect(ShareSetRule.verdict(publicFlags: [true, true, true, true], max: 4) == .ready)
        #expect(ShareSetRule.verdict(publicFlags: Array(repeating: true, count: 5), max: 4) == .tooMany(max: 4))
        #expect(ShareSetRule.verdict(publicFlags: [true, false, true], max: 4) == .notPublic(count: 1))
        #expect(ShareSetRule.verdict(publicFlags: [false, false, true, true], max: 4) == .notPublic(count: 2))
    }

    @Test func tooManyComesBeforePrivateAndTooFewBeforePrivate() {
        #expect(ShareSetRule.verdict(publicFlags: [true, true, true, true, false], max: 4) == .tooMany(max: 4))
        #expect(ShareSetRule.verdict(publicFlags: [false], max: 4) == .tooFew)
    }

    @Test func aCustomMaximumAndTheFloor() {
        #expect(ShareSetRule.verdict(publicFlags: Array(repeating: true, count: 6), max: 6) == .ready)
        #expect(ShareSetRule.verdict(publicFlags: Array(repeating: true, count: 7), max: 6) == .tooMany(max: 6))
        #expect(ShareSetRule.verdict(publicFlags: [true, true, true], max: 2) == .tooMany(max: 2))
        #expect(ShareSetRule.verdict(publicFlags: [true, true], max: 1) == .ready, "a maximum under 2 is raised to 2")
        #expect(ShareSetRule.minimum == 2)
    }
}

// MARK: - the file that stands for a post

private func lf(
    _ id: String, _ kind: LibraryFile.Kind, _ source: LibraryFile.Source, type: String = "video/mp4", url: String? = nil,
    visibility: Visibility? = nil, at: Double = 0, media: String? = nil
) -> LibraryFile {
    var f = LibraryFile(
        id: id, kind: kind, source: source, name: id, url: url.flatMap(URL.init(string:)), contentType: type, bytes: 1_000,
        width: 720, height: 1280, duration: 10, createdAt: t0.addingTimeInterval(at), mediaName: media, deletable: false)
    f.wireVisibility = visibility
    return f
}

private func lpost(_ files: [LibraryFile], kind: MediaKind? = nil) -> LibraryPost {
    var p = LibraryPost(
        id: "Post", service: "instagram", link: URL(string: "https://www.instagram.com/reel/Dd7P496wolG/"), title: nil,
        duration: 10, width: 720, height: 1280, createdAt: t0, session: nil, files: files)
    p.kind = kind
    return p
}

private let pubMP4 = "https://media.capybaraharmony.com/AbCdEfGhIj.mp4"
private func pubWebp(_ n: Int) -> String { "https://media.capybaraharmony.com/WeBpWeBp0\(n).webp" }

struct ShareSetFileIDTests {
    private func item(_ post: LibraryPost) throws -> MediaItem { try #require(MediaItem.merge(local: nil, post: post)) }

    @Test func aPublicFaceIsTheFile() throws {
        // a public webp is the post's face; the original is private
        let post = lpost([
            lf("orig", .private, .saved, visibility: .private),
            lf("webp", .public, .studio, type: "image/webp", url: pubWebp(1), visibility: .public, at: 10),
        ])
        #expect(ShareSetRule.fileID(for: try item(post)) == "webp")
    }

    @Test func aPrivateFaceFallsBackToAPublicOriginal() throws {
        let post = lpost([
            lf("orig", .private, .saved, url: pubMP4, visibility: .public),
            lf("webp", .public, .studio, type: "image/webp", url: nil, visibility: .private, at: 10, media: "WeBpWeBp01.webp"),
        ])
        let m = try item(post)
        #expect(m.face.isWebp, "the face is the private webp")
        #expect(ShareSetRule.fileID(for: m) == "orig")
    }

    @Test func aLegacyHostedLinkCountsAsTheOriginalsPublicFile() throws {
        let post = lpost([
            lf("host", .public, .host, url: pubMP4),
            lf("orig", .private, .saved),
        ])
        #expect(ShareSetRule.fileID(for: try item(post)) == "host")
    }

    @Test func otherwiseTheNewestOtherPublicRendition() throws {
        let post = lpost([
            lf("orig", .private, .saved, visibility: .private),
            lf("old", .public, .studio, type: "image/webp", url: pubWebp(1), visibility: .public, at: 10),
            lf("new", .public, .studio, type: "image/webp", url: nil, visibility: .private, at: 20, media: "WeBpWeBp02.webp"),
        ])
        let m = try item(post)
        #expect(m.face.file?.id == "new")
        #expect(ShareSetRule.fileID(for: m) == "old")
    }

    @Test func nothingPublicIsNil() throws {
        let post = lpost([
            lf("orig", .private, .saved, visibility: .private),
            lf("webp", .public, .studio, type: "image/webp", url: nil, visibility: .private, at: 10, media: "WeBpWeBp01.webp"),
        ])
        #expect(ShareSetRule.fileID(for: try item(post)) == nil)
        #expect(ShareSetRule.fileID(for: try item(lpost([lf("only", .private, .saved)]))) == nil)
    }

    @Test func aPublicFileWithoutALinkIsNotPublicEnough() throws {
        let post = lpost([lf("orig", .private, .saved, url: nil, visibility: .public)])
        #expect(ShareSetRule.fileID(for: try item(post)) == nil)
    }

    @Test func aGalleryIsNil() throws {
        let post = lpost([lf("orig", .private, .saved, url: pubMP4, visibility: .public)], kind: .gallery)
        #expect(try item(post).kind == .gallery)
        #expect(ShareSetRule.fileID(for: try item(post)) == nil)
    }

    @Test func thePreviewLibraryHasPublicAndPrivatePosts() throws {
        let page = PreviewData.libraryPage(now: t0)
        let ids = try page.posts.map { try #require(MediaItem.merge(local: nil, post: $0)) }.map(ShareSetRule.fileID(for:))
        #expect(ids.compactMap { $0 }.count == 5 && ids.contains { $0 == nil }, "five public posts and one private one")
        let v2 = PreviewData.libraryPageV2(now: t0)
        let v2ids = try v2.posts.map { try #require(MediaItem.merge(local: nil, post: $0)) }.map(ShareSetRule.fileID(for:))
        #expect(v2ids.contains { $0 == nil } && v2ids.compactMap { $0 }.count >= 3)
    }
}

// MARK: - the three routes

@Suite(.serialized)
struct ShareSetHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { setKey })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test func createIsPostedKeyedWithTheItemsInOrderAndTheTitle() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "POST" && req.path == "/share/sets"
                ? .json(#"{"status":"success","set":"# + wireSet + "}", status: 201) : .init(status: 404)
        }
        defer { server.stop() }
        let set = try await client(server).createShareSet(items: ["b", "a", "c"], title: "harbour")
        let req = try #require(server.requests.first)
        #expect(req.method == "POST" && req.path == "/share/sets")
        #expect(req.headers["authorization"] == "Api-Key \(setKey)")
        #expect(req.headers["content-type"] == "application/json")
        let body = try bodyJSON(req)
        #expect(body["items"] as? [String] == ["b", "a", "c"] && body["title"] as? String == "harbour" && body.count == 2)
        #expect(set.id == "9000000000000000001" && set.items.count == 3)
    }

    @Test func createWithoutATitleOmitsTheField() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","set":"# + wireSet + "}", status: 201) }
        defer { server.stop() }
        _ = try await client(server).createShareSet(items: ["a", "b"], title: nil)
        let body = try bodyJSON(try #require(server.requests.first))
        #expect(body["items"] as? [String] == ["a", "b"] && body["title"] == nil && body.count == 1)
    }

    @Test func notPublicNamesTheFiles() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"error","error":{"code":"error.share.not_public"},"items":["b","c"]}"#, status: 409)
        }
        defer { server.stop() }
        await #expect(throws: ShareSetError.notPublic(["b", "c"])) {
            try await client(server).createShareSet(items: ["a", "b", "c"], title: nil)
        }
    }

    @Test func badRequestAndUnavailableAreMapped() async throws {
        let server = try await LoopbackServer.start { req in
            req.body.count > 40
                ? .json(#"{"status":"error","error":{"code":"error.share.bad_request"}}"#, status: 400)
                : .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 503)
        }
        defer { server.stop() }
        await #expect(throws: ShareSetError.badRequest) {
            try await client(server).createShareSet(items: ["a", "a", "a", "a", "a", "a", "a"], title: "x")
        }
        await #expect(throws: ShareSetError.unavailable) {
            try await client(server).createShareSet(items: ["a"], title: nil)
        }
    }

    @Test func otherErrorsStayTheGenericOnes() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"error","error":{"code":"error.api.auth.key.invalid"}}"#, status: 401)
        }
        defer { server.stop() }
        await #expect(throws: CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)) {
            try await client(server).shareSets()
        }
    }

    @Test func listIsGetKeyedAndKeepsTheServersOrder() async throws {
        let older = wireSet.replacingOccurrences(of: "9000000000000000001", with: "9000000000000000002")
            .replacingOccurrences(of: "1790000000000", with: "1780000000000")
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/share/sets"
                ? .json(#"{"status":"success","sets":["# + wireSet + "," + older + "]}") : .init(status: 404)
        }
        defer { server.stop() }
        let sets = try await client(server).shareSets()
        let req = try #require(server.requests.first)
        #expect(req.method == "GET" && req.headers["authorization"] == "Api-Key \(setKey)" && req.body.isEmpty)
        #expect(sets.map(\.id) == ["9000000000000000001", "9000000000000000002"])
    }

    @Test func revokeIsDeleteAndAnUnknownIdIsNotFound() async throws {
        let server = try await LoopbackServer.start { req in
            if req.path == "/share/sets/9000000000000000001" { return .json(#"{"status":"success"}"#) }
            return .json(#"{"status":"error","error":{"code":"error.share.not_found"}}"#, status: 404)
        }
        defer { server.stop() }
        try await client(server).revokeShareSet(id: "9000000000000000001")
        let req = try #require(server.requests.first)
        #expect(req.method == "DELETE" && req.path == "/share/sets/9000000000000000001")
        #expect(req.headers["authorization"] == "Api-Key \(setKey)")
        await #expect(throws: ShareSetError.notFound) { try await client(server).revokeShareSet(id: "nope") }
    }

    @Test func aClientThatPredatesTheRoutesSaysUnsupported() async {
        struct Old: CobaltClient {
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
        let old = Old()
        await #expect(throws: PipelineFailure.unsupported) { try await old.shareSets() }
        await #expect(throws: PipelineFailure.unsupported) { try await old.createShareSet(items: ["a", "b"], title: nil) }
        await #expect(throws: PipelineFailure.unsupported) { try await old.revokeShareSet(id: "x") }
    }
}

// MARK: - the preview server and the store

@MainActor
struct ShareSetStoreTests {
    private func app(_ scenario: PreviewScenario = .happy) -> AppModel {
        AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
    }

    /// The library file ids of the preview library that are public now (v1 shape).
    private func publicIDs(_ app: AppModel) -> [String] {
        app.library.posts.compactMap { post in
            MediaItem.merge(local: nil, post: post).flatMap(ShareSetRule.fileID(for:))
        }
    }

    @Test func theSharingScenariosAdvertiseTheFeature() {
        for scenario in [PreviewScenario.happy, .renditions, .shareLinksEmpty, .shareLinksFail] {
            let caps = PreviewData.capabilities(for: scenario)
            #expect(caps.shareSets && caps.shareBaseURL != nil && caps.limits.shareSetMax == 4, "\(scenario)")
        }
        #expect(!PreviewData.capabilities(for: .renditionsLegacy).shareSets)
        #expect(!PreviewData.capabilities(for: .plainCobalt).shareSets)
        #expect(!PreviewData.capabilities(for: .galleryInstagram).shareSets)
    }

    @Test func refreshListsThreeSampleSetsNewestFirst() async {
        let app = app()
        #expect(app.shareSets.state == .idle && app.shareSets.sets.isEmpty)
        await app.shareSets.refresh()
        #expect(app.shareSets.state == .loaded)
        #expect(app.shareSets.sets.map(\.id) == ["9000000000000000001", "9000000000000000002", "9000000000000000003"])
        let sets = app.shareSets.sets
        #expect(sets[0].title == "harbour and the dog" && sets[0].items.count == 3)
        #expect(sets[1].title == nil && sets[1].displayTitle == "2 files")
        #expect(sets[2].items.count == 4 && sets[2].items.contains { !$0.isPublic })
        #expect(sets[0].items.contains { $0.contentType == "video/mp4" && $0.posterURL != nil })
        #expect(sets[0].items.contains { $0.contentType == "image/jpeg" })
    }

    @Test func theEmptyScenarioHasNoSets() async {
        let app = app(.shareLinksEmpty)
        await app.shareSets.refresh()
        #expect(app.shareSets.state == .loaded && app.shareSets.sets.isEmpty)
    }

    @Test func theFailScenarioFailsToListButStillMakesLinks() async throws {
        let app = app(.shareLinksFail)
        await app.shareSets.refresh()
        guard case .failed(let message) = app.shareSets.state else { Issue.record("\(app.shareSets.state)"); return }
        #expect(!message.isEmpty && app.shareSets.sets.isEmpty)
        let ids = publicIDs(app)
        let made = try await app.shareSets.create(items: Array(ids.prefix(2)), title: nil)
        #expect(app.shareSets.sets.map(\.id) == [made.id])
    }

    @Test func createInsertsAtTheTopWithRealItems() async throws {
        let app = app()
        await app.shareSets.refresh()
        let ids = publicIDs(app)
        #expect(ids.count == 5)
        let made = try await app.shareSets.create(items: Array(ids.prefix(3)), title: "  three  ")
        #expect(app.shareSets.sets.count == 4 && app.shareSets.sets.first?.id == made.id)
        #expect(made.title == "three" && made.items.map(\.id) == Array(ids.prefix(3)))
        #expect(made.items.allSatisfy(\.isPublic) && made.url.absoluteString == "https://share.capybaraharmony.com/g/\(made.id)")
        // and the "server" lists it, newest first
        await app.shareSets.refresh()
        #expect(app.shareSets.sets.first?.id == made.id && app.shareSets.sets.count == 4)
    }

    @Test func createEnforcesTheRule() async throws {
        let app = app()
        let ids = publicIDs(app)
        // a private file (post 4's video) is named back
        let privateID = "PrEvIeWitem000007"
        await #expect(throws: ShareSetError.notPublic([privateID])) {
            try await app.shareSets.create(items: [ids[0], privateID], title: nil)
        }
        await #expect(throws: ShareSetError.notPublic(["nope"])) {
            try await app.shareSets.create(items: [ids[0], "nope"], title: nil)
        }
        await #expect(throws: ShareSetError.badRequest) { try await app.shareSets.create(items: [ids[0]], title: nil) }
        await #expect(throws: ShareSetError.badRequest) { try await app.shareSets.create(items: ids, title: nil) }       // 5 files
        await #expect(throws: ShareSetError.badRequest) { try await app.shareSets.create(items: [ids[0], ids[0]], title: nil) }
        await #expect(throws: ShareSetError.badRequest) { try await app.shareSets.create(items: Array(ids.prefix(2)), title: String(repeating: "x", count: 81)) }
        await #expect(throws: ShareSetError.badRequest) { try await app.shareSets.create(items: Array(ids.prefix(2)), title: "   ") }
        #expect(app.shareSets.sets.isEmpty, "nothing was inserted")
    }

    @Test func revokeRemovesTheRow() async throws {
        let app = app()
        await app.shareSets.refresh()
        try await app.shareSets.revoke("9000000000000000002")
        #expect(app.shareSets.sets.map(\.id) == ["9000000000000000001", "9000000000000000003"])
        await app.shareSets.refresh()
        #expect(app.shareSets.sets.map(\.id) == ["9000000000000000001", "9000000000000000003"])
    }

    @Test func aSetTheServerNoLongerKnowsIsRemovedToo() async throws {
        let app = app()
        await app.shareSets.refresh()
        // revoked from another device: the second revoke is a 404 and the row still goes
        try await app.shareSets.revoke("9000000000000000001")
        let client = app.ctx.client
        await #expect(throws: ShareSetError.notFound) { try await client.revokeShareSet(id: "9000000000000000001") }
        try await app.shareSets.revoke("9000000000000000001")
        #expect(!app.shareSets.sets.contains { $0.id == "9000000000000000001" })
    }

    @Test func anotherErrorLeavesTheRow() async throws {
        let app = app(.renditionsLegacy)                    // no share routes: `.unsupported`
        await app.shareSets.refresh()
        guard case .failed = app.shareSets.state else { Issue.record("\(app.shareSets.state)"); return }
        await #expect(throws: PipelineFailure.unsupported) { try await app.shareSets.revoke("x") }
    }

    @Test func aServerChangeForgetsTheSets() async {
        let app = app()
        await app.shareSets.refresh()
        #expect(app.shareSets.sets.count == 3)
        app.serverChanged()
        #expect(app.shareSets.sets.isEmpty && app.shareSets.state == .idle)
    }

    @Test func theLinksTabFallsBackWhenTheFeatureGoes() {
        let app = app()
        app.selectedTab = .links
        var caps = app.capabilities
        caps.shareSets = false
        app.apply(caps)
        #expect(app.selectedTab == .save)
    }
}

import Foundation
import Testing
@testable import CobaltKit

// Private share links (APP-API-CONTRACT 36): the capability, the wire shapes (a link, the list, a set's and a file's new
// fields), the routes on the real client, the preview server and the links store, and a file's three-way link on the
// app model.

private let privateKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

private let wireLink = """
{"kind":"set","target_id":"9000000000000000001","url":"https://share.capybaraharmony.com/p/AbCdEfGhIjKlMnOpQrStUv",
 "created_at":1790000000000,"opened":14,"last_opened_at":1790000120000}
"""

// MARK: - capability

struct PrivateLinkCapabilityTests {
    private func caps(_ features: String, share: String = #","share_base_url":"https://share.capybaraharmony.com/""#) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":\#(features)\#(share),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func theFlagNeedsShareSets() throws {
        #expect(try caps(#"{"share_sets":true,"private_links":true}"#).privateLinks)
        #expect(try !caps(#"{"share_sets":false,"private_links":true}"#).privateLinks)
        #expect(try !caps(#"{"share_sets":true,"private_links":true}"#, share: "").privateLinks)
        #expect(try !caps(#"{"share_sets":true}"#).privateLinks)
        #expect(!Capabilities.unknown.privateLinks)
    }

    @Test func theSharingPreviewsAdvertiseIt() {
        #expect(PreviewData.capabilities(for: .happy).privateLinks)
        #expect(PreviewData.capabilities(for: .renditions).privateLinks)
        #expect(!PreviewData.capabilities(for: .plainCobalt).privateLinks)
    }
}

// MARK: - wire shapes

struct PrivateLinkWireTests {
    @Test func decodesALink() throws {
        let link = try PrivateLink.decode(Data(wireLink.utf8))
        #expect(link.kind == .set && link.targetID == "9000000000000000001")
        #expect(link.url.absoluteString == "https://share.capybaraharmony.com/p/AbCdEfGhIjKlMnOpQrStUv")
        #expect(link.createdAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(link.opened == 14 && link.lastOpenedAt == Date(timeIntervalSince1970: 1_790_000_120))
        #expect(link.id == "set:9000000000000000001")
        let never = try PrivateLink.decode(Data(#"{"kind":"item","target_id":"f1","url":"https://s.example/p/x","created_at":1,"opened":0,"last_opened_at":null}"#.utf8))
        #expect(never.lastOpenedAt == nil && never.kind == .item && never.id == "item:f1")
    }

    @Test func decodesTheListDroppingOddRowsAndReadingNewLinks() throws {
        let json = #"{"status":"success","links":[\#(wireLink),{"kind":"folder","target_id":"x"}],"new_links":"private"}"#
        let list = try PrivateLinkList.decode(Data(json.utf8))
        #expect(list.links.count == 1 && list.newLinks == .private)
        // before migration 0024 the server answers an empty list; a word this build does not know reads as public
        #expect(try PrivateLinkList.decode(Data(#"{"links":[],"new_links":"public"}"#.utf8)) == PrivateLinkList())
        #expect(try PrivateLinkList.decode(Data(#"{"links":[],"new_links":"secret"}"#.utf8)).newLinks == .public)
        #expect(try PrivateLinkList.decode(Data("{}".utf8)).newLinks == .public)
    }

    @Test func aSetCarriesItsPrivateLink() throws {
        let json = """
        {"id":"9000000000000000001","url":"https://share.capybaraharmony.com/p/AbCdEfGhIjKlMnOpQrStUv","title":null,
         "created_at":1790000000000,"items":[],"private":true,
         "public_url":"https://share.capybaraharmony.com/g/9000000000000000001","link":\(wireLink)}
        """
        let set = try CobaltJSON.decoder().decode(ShareSet.self, from: Data(json.utf8))
        #expect(set.isPrivate && set.link?.opened == 14)
        #expect(set.url == set.link?.url)
        #expect(set.publicURL?.absoluteString == "https://share.capybaraharmony.com/g/9000000000000000001")
        // the older shape: public, no link
        let old = try CobaltJSON.decoder().decode(ShareSet.self, from: Data(
            #"{"id":"1","url":"https://share.capybaraharmony.com/g/1","created_at":1,"items":[]}"#.utf8))
        #expect(!old.isPrivate && old.link == nil && old.publicURL == nil)
    }

    @Test func aSetGoesPrivateAndBack() throws {
        let set = ShareSet(id: "1", url: URL(string: "https://share.capybaraharmony.com/g/1")!, createdAt: .now, items: [])
        let link = PrivateLink(kind: .set, targetID: "1", url: URL(string: "https://share.capybaraharmony.com/p/k")!, createdAt: .now)
        let on = set.makingPrivate(link)
        #expect(on.isPrivate && on.url == link.url && on.publicURL == set.url)
        let off = on.makingPublic(fallback: nil)
        #expect(!off.isPrivate && off.link == nil && off.url == set.url)
    }

    @Test func aFileCarriesItsPrivateURLAndKeepsItThroughTheCache() throws {
        let json = """
        {"id":"f1","kind":"private","source":"studio","name":"clip.mp4","url":null,"created_at":1,"deletable":true,
         "visibility":"private","visibility_toggle":true,"private_url":"https://share.capybaraharmony.com/p/AbCdEfGhIjKlMnOpQrStUv"}
        """
        let file = try CobaltJSON.decoder().decode(LibraryFile.self, from: Data(json.utf8))
        #expect(file.privateURL?.lastPathComponent == "AbCdEfGhIjKlMnOpQrStUv")
        #expect(file.linkState == .private && !file.isPublic)
        let again = try CobaltJSON.decoder().decode(LibraryFile.self, from: CobaltJSON.encoder().encode(file))
        #expect(again.privateURL == file.privateURL)
        // no private_url: public or off by its visibility
        let off = try CobaltJSON.decoder().decode(LibraryFile.self, from: Data(json.replacingOccurrences(
            of: #","private_url":"https://share.capybaraharmony.com/p/AbCdEfGhIjKlMnOpQrStUv""#, with: "").utf8))
        #expect(off.privateURL == nil && off.linkState == .off)
    }

    @Test func theLiveLinkPrefersThePrivateOne() {
        var caps = Capabilities.unknown
        caps.mediaBaseURL = URL(string: "https://media.capybaraharmony.com/")
        caps.shareBaseURL = URL(string: "https://share.capybaraharmony.com/")
        let key = URL(string: "https://share.capybaraharmony.com/p/AbCdEfGhIjKlMnOpQrStUv")!
        var file = LibraryFile(
            id: "f1", kind: .private, source: .studio, name: "clip.mp4", url: nil, contentType: "video/mp4", bytes: nil,
            width: nil, height: nil, duration: nil, createdAt: .now, mediaName: nil, deletable: true, posterURL: nil,
            wireVisibility: .private, canToggleVisibility: true)
        file.privateURL = key
        let r = Rendition(id: "video", kind: .video, file: file, createdAt: .now, visibility: .private, canToggleVisibility: true)
        #expect(r.privateURL == key && r.fileLink == .private && caps.liveLink(for: r) == key)
        let pub = Rendition(
            id: "video", kind: .video, publicURL: URL(string: "https://media.capybaraharmony.com/AbCdEfGhIj.mp4"),
            createdAt: .now, visibility: .public)
        #expect(caps.liveLink(for: pub)?.absoluteString == "https://share.capybaraharmony.com/AbCdEfGhIj")
        #expect(pub.fileLink == .public)
        let none = Rendition(id: "video", kind: .video, createdAt: .now)
        #expect(caps.liveLink(for: none) == nil && none.fileLink == .off)
    }
}

// MARK: - the routes

@Suite(.serialized)
struct PrivateLinkHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { privateKey })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test func listIsGetKeyed() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/share/private"
                ? .json(#"{"status":"success","links":[\#(wireLink)],"new_links":"private"}"#) : .init(status: 404)
        }
        defer { server.stop() }
        let list = try await client(server).privateLinks()
        #expect(list.links.count == 1 && list.newLinks == .private)
        #expect(server.requests.first?.headers["authorization"] == "Api-Key \(privateKey)")
    }

    @Test func turningOnRotatingAndRevokingHitTheirPaths() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "DELETE" ? .json(#"{"status":"success"}"#) : .json(#"{"status":"success","link":\#(wireLink)}"#)
        }
        defer { server.stop() }
        let c = client(server)
        _ = try await c.enablePrivateLink(.item, id: "f1")
        _ = try await c.enablePrivateLink(.set, id: "9000000000000000001")
        let rotated = try await c.rotatePrivateLink(.set, id: "9000000000000000001")
        try await c.revokePrivateLink(.item, id: "f1")
        #expect(rotated.opened == 14)
        #expect(server.requests.map { "\($0.method) \($0.path)" } == [
            "PUT /share/private/items/f1",
            "PUT /share/private/sets/9000000000000000001",
            "POST /share/private/sets/9000000000000000001/rotate",
            "DELETE /share/private/items/f1",
        ])
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == "Api-Key \(privateKey)" })
    }

    @Test func rotateAllSettingsAndCollectionPrivacySendTheirBodies() async throws {
        let server = try await LoopbackServer.start { req in
            switch req.path {
            case "/share/private/rotate-all": return .json(#"{"status":"success","links":[\#(wireLink)],"rotated":1}"#)
            case "/share/private/settings": return .json(#"{"status":"success","new_links":"private"}"#)
            default: return .json(#"{"status":"success","links":[\#(wireLink)]}"#)
            }
        }
        defer { server.stop() }
        let c = client(server)
        let all = try await c.rotateAllPrivateLinks()
        #expect(all.rotated == 1 && all.links.count == 1)
        #expect(try await c.setNewLinks(.private) == .private)
        let links = try await c.setCollectionPrivacy(id: "AbCd1234EfGh5678", .makePrivate)
        _ = try await c.setCollectionPrivacy(id: "AbCd1234EfGh5678", .makePublic)
        _ = try await c.setCollectionPrivacy(id: "AbCd1234EfGh5678", .rotate)
        #expect(links.count == 1)
        let reqs = server.requests
        #expect(reqs.map { "\($0.method) \($0.path)" } == [
            "POST /share/private/rotate-all", "PATCH /share/private/settings",
            "POST /share/collections/AbCd1234EfGh5678/privacy", "POST /share/collections/AbCd1234EfGh5678/privacy",
            "POST /share/collections/AbCd1234EfGh5678/privacy",
        ])
        #expect(try bodyJSON(reqs[1])["new_links"] as? String == "private")
        #expect(try bodyJSON(reqs[2])["private"] as? Bool == true)
        #expect(try bodyJSON(reqs[3])["private"] as? Bool == false)
        #expect(try bodyJSON(reqs[4])["rotate"] as? Bool == true && bodyJSON(reqs[4]).count == 1)
    }

    @Test func createSendsPrivateOnlyWhenAsked() async throws {
        let set = #"{"id":"1","url":"https://share.capybaraharmony.com/p/k","created_at":1,"items":[],"private":true,"public_url":"https://share.capybaraharmony.com/g/1","link":null}"#
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","set":\#(set)}"#, status: 201) }
        defer { server.stop() }
        let made = try await client(server).createShareSet(items: ["a", "b"], title: nil, private: true)
        _ = try await client(server).createShareSet(items: ["a", "b"], title: nil)
        #expect(made.isPrivate)
        #expect(try bodyJSON(server.requests[0])["private"] as? Bool == true)
        #expect(try bodyJSON(server.requests[1])["private"] == nil)
    }

    @Test func refusalsAreMapped() async throws {
        let server = try await LoopbackServer.start { req in
            switch req.path {
            case "/share/private/items/gone": return .json(#"{"status":"error","error":{"code":"error.private.not_found"}}"#, status: 404)
            case "/share/private/items/made": return .json(#"{"status":"error","error":{"code":"error.private.not_toggleable"}}"#, status: 409)
            case "/share/private/settings": return .json(#"{"status":"error","error":{"code":"error.private.bad_request"}}"#, status: 400)
            case "/share/collections/nope/privacy": return .json(#"{"status":"error","error":{"code":"error.collection.not_found"}}"#, status: 404)
            case "/share/private/rotate-all": return .json(#"{"status":"error","error":{"code":"error.api.auth.key.invalid"}}"#, status: 401)
            default: return .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 503)
            }
        }
        defer { server.stop() }
        let c = client(server)
        await #expect(throws: PrivateLinkError.notFound) { try await c.enablePrivateLink(.item, id: "gone") }
        await #expect(throws: PrivateLinkError.notToggleable) { try await c.enablePrivateLink(.item, id: "made") }
        await #expect(throws: PrivateLinkError.badRequest) { try await c.setNewLinks(.public) }
        await #expect(throws: ShareCollectionError.notFound) { try await c.setCollectionPrivacy(id: "nope", .rotate) }
        await #expect(throws: CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)) { try await c.rotateAllPrivateLinks() }
        await #expect(throws: PrivateLinkError.unavailable) { try await c.privateLinks() }
    }

    @Test func anOlderClientHasNoneOfThem() async throws {
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
        await #expect(throws: PipelineFailure.unsupported) { try await bare.privateLinks() }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.enablePrivateLink(.item, id: "x") }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.createShareSet(items: ["a", "b"], title: nil, private: true) }
    }
}

// MARK: - the preview server and the store

@MainActor
struct PrivateLinkStoreTests {
    private let one = "9000000000000000001"
    private let two = "9000000000000000002"
    private let memes = "PrEvIeWcoll00001"          // [two, one]

    private func app(_ scenario: PreviewScenario = .happy) -> AppModel {
        AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
    }

    private func publicIDs(_ app: AppModel) -> [String] {
        app.library.posts.compactMap { post in
            MediaItem.merge(local: nil, post: post).flatMap(ShareSetRule.fileID(for:))
        }
    }

    @Test func refreshListsNoPrivateLinksAndPublicNewLinks() async {
        let app = app()
        await app.shareSets.refresh()
        #expect(app.shareSets.privateLoaded && app.shareSets.privateLinks.isEmpty && app.shareSets.newLinks == .public)
        #expect(app.shareSets.sets.allSatisfy { !$0.isPrivate && $0.url == PreviewData.shareURL(id: $0.id) })
    }

    @Test func aLinkGoesPrivateRotatesAndComesBack() async throws {
        let app = app()
        await app.shareSets.refresh()
        let key = try await app.shareSets.makePrivate(two)
        let row = try #require(app.shareSets.sets.first { $0.id == two })
        #expect(row.isPrivate && row.url == key.url && key.url.path.hasPrefix("/p/") && key.url.lastPathComponent.count == 22)
        #expect(app.shareSets.privateLink(forSet: two) == key && app.shareSets.privateLinkCount == 1)
        // copy all copies the live link
        let collection = try #require(app.shareSets.collection(memes))
        #expect(app.shareSets.linksText(in: collection)?.hasPrefix(key.url.absoluteString) == true)
        // turning it on again answers the same key
        #expect(try await app.shareSets.makePrivate(two) == key)

        let rotated = try await app.shareSets.rotate(two)
        #expect(rotated.url != key.url && app.shareSets.sets.first { $0.id == two }?.url == rotated.url)
        #expect(app.shareSets.privateLinkCount == 1)

        try await app.shareSets.makePublic(two)
        #expect(app.shareSets.sets.first { $0.id == two }?.url == PreviewData.shareURL(id: two))
        #expect(app.shareSets.privateLinkCount == 0)
        await #expect(throws: PrivateLinkError.notFound) { try await app.shareSets.rotate(two) }

        // the server agrees
        await app.shareSets.refresh()
        #expect(app.shareSets.sets.allSatisfy { !$0.isPrivate } && app.shareSets.privateLinks.isEmpty)
    }

    @Test func revokingALinkRevokesItsKey() async throws {
        let app = app()
        await app.shareSets.refresh()
        _ = try await app.shareSets.makePrivate(one)
        try await app.shareSets.revoke(one)
        #expect(app.shareSets.privateLinks.isEmpty)
        try await app.shareSets.refreshPrivate()
        #expect(app.shareSets.privateLinks.isEmpty)
    }

    @Test func aCollectionGoesPrivateRotatesAndGoesPublic() async throws {
        let app = app()
        await app.shareSets.refresh()
        let collection = try #require(app.shareSets.collection(memes))
        let on = try await app.shareSets.setPrivacy(of: memes, .makePrivate)
        #expect(Set(on.map(\.targetID)) == [one, two] && app.shareSets.privateCount(in: collection) == 2)
        let rotated = try await app.shareSets.setPrivacy(of: memes, .rotate)
        #expect(rotated.count == 2 && Set(rotated.map(\.url)).isDisjoint(with: Set(on.map(\.url))))
        #expect(app.shareSets.sets(in: collection).map(\.url) == [two, one].compactMap { id in rotated.first { $0.targetID == id }?.url })
        _ = try await app.shareSets.setPrivacy(of: memes, .makePublic)
        #expect(app.shareSets.privateCount(in: collection) == 0 && app.shareSets.privateLinks.isEmpty)
        await #expect(throws: ShareCollectionError.notFound) { try await app.shareSets.setPrivacy(of: "ghostghostghost1", .rotate) }
    }

    @Test func rotatingEveryKeyReplacesEachOne() async throws {
        let app = app()
        await app.shareSets.refresh()
        let a = try await app.shareSets.makePrivate(one)
        let b = try await app.shareSets.makePrivate(two)
        let answer = try await app.shareSets.rotateAll()
        #expect(answer.rotated == 2 && app.shareSets.privateLinkCount == 2)
        #expect(!app.shareSets.privateLinks.contains { $0.url == a.url || $0.url == b.url })
        #expect(app.shareSets.sets.first { $0.id == one }?.url == app.shareSets.privateLink(forSet: one)?.url)
    }

    @Test func newLinksDecidesWhatACreateWithoutAChoiceMakes() async throws {
        let app = app()
        await app.shareSets.refresh()
        let ids = publicIDs(app)
        try await app.shareSets.setNewLinks(.private)
        #expect(app.shareSets.newLinks == .private)
        let made = try await app.shareSets.create(items: Array(ids.prefix(2)), title: nil)
        #expect(made.isPrivate && made.url.path.hasPrefix("/p/"))
        let pub = try await app.shareSets.create(items: Array(ids.prefix(2)), title: nil, private: false)
        #expect(!pub.isPrivate && pub.url == PreviewData.shareURL(id: pub.id))
        #expect(app.shareSets.privateLink(forSet: made.id) != nil && app.shareSets.privateLink(forSet: pub.id) == nil)
    }

    @Test func aPrivateLinkTakesFilesThatAreNotPublic() async throws {
        let (app, privateID, publicID) = try visibilityApp()
        await app.shareSets.refresh()
        await #expect(throws: ShareSetError.notPublic([privateID])) {
            try await app.shareSets.create(items: [publicID, privateID], title: nil, private: false)
        }
        let made = try await app.shareSets.create(items: [publicID, privateID], title: nil, private: true)
        #expect(made.isPrivate && made.items.map(\.id) == [publicID, privateID])
        // the PUBLIC links that hold the public file (the private one does not count)
        #expect(app.shareSets.publicSets(containing: publicID).allSatisfy { !$0.isPrivate })
    }

    @Test func thePrivatePickTakesAnyFileOfAPost() throws {
        let (app, _, _) = try visibilityApp()
        // a post with a public file: the same file as a public link takes
        for post in app.library.posts {
            guard let item = MediaItem.merge(local: nil, post: post), item.kind != .gallery,
                  let pub = ShareSetRule.fileID(for: item) else { continue }
            #expect(ShareSetRule.privateFileID(for: item) == pub, "\(post.id)")
        }
        // a private video is a file a private link can take
        let post = try #require(app.library.posts.first { $0.id == "Dd7P496wolG" })
        let item = app.mediaItem(for: post)
        let video = try #require(item.video)
        #expect(video.visibility == .private && ShareSetRule.anyFile(of: video)?.id == video.file?.id)
        #expect(ShareSetRule.privateFileID(for: item) != nil)
    }

    /// The visibility preview (one file per rendition, a private video); a private and a public file id.
    private func visibilityApp() throws -> (AppModel, String, String) {
        let app = AppModel.makePreviewVisibility(.working, timeScale: 0.01, clock: SystemClock())
        let files = app.library.posts.flatMap(\.files)
        let privateID = try #require(files.first { !$0.isPublic }?.id)
        let publicID = try #require(files.first { $0.isPublic }?.id)
        return (app, privateID, publicID)
    }
}

// MARK: - a file's three-way link (the detail)

@MainActor
struct FileLinkModelTests {
    private let publicPost = "Dd55fEyN1Yy"             // its video is public (PrEvIeW011.mp4)

    private func app() -> AppModel { AppModel.makePreviewVisibility(.working, timeScale: 0.01, clock: SystemClock()) }

    private func video(_ app: AppModel) throws -> Rendition {
        let post = try #require(app.library.posts.first { $0.id == publicPost })
        return try #require(app.mediaItem(for: post).video)
    }

    @Test func offPublicPrivateAndRotate() async throws {
        let app = app()
        let before = try video(app)
        let publicURL = try #require(before.publicURL)
        #expect(app.canChoosePrivateLink(before) && app.fileLink(of: before) == .public)

        // private: the public link goes, the file carries its key, and every hand-out gives the key
        let made = try await app.setFileLink(before, to: .private)
        let key = try #require(made)
        let priv = try video(app)
        let fileID = try #require(priv.file?.id)
        #expect(app.fileLink(of: priv) == .private && priv.fileLink == .private)
        #expect(priv.publicURL == nil && priv.privateURL == key.url && app.privateURL(of: priv) == key.url)
        #expect(app.capabilities.liveLink(for: priv) == key.url)
        #expect(app.privateLink(of: priv) == key && app.shareSets.privateLink(forItem: fileID) == key)

        // rotate: a new key
        let rotated = try await app.rotateFileLink(priv)
        let afterRotate = try video(app)
        #expect(rotated.url != key.url && app.privateURL(of: afterRotate) == rotated.url)

        // public: the section 16 switch, which revokes the key; the same public link comes back
        try await app.setFileLink(afterRotate, to: .public)
        let pub = try video(app)
        #expect(app.fileLink(of: pub) == .public && pub.privateURL == nil && pub.publicURL == publicURL)
        #expect(app.shareSets.privateLinks.isEmpty)

        // private again, then off: the key is revoked and the file stays not public
        _ = try await app.setFileLink(pub, to: .private)
        let privAgain = try video(app)
        try await app.setFileLink(privAgain, to: .off)
        let off = try video(app)
        #expect(app.fileLink(of: off) == .off && off.privateURL == nil && off.publicURL == nil)
        #expect(app.capabilities.liveLink(for: off) == nil)
        await #expect(throws: PrivateLinkError.notFound) { try await app.rotateFileLink(off) }
    }

    @Test func turningPrivateOnCanTakeItsPublicLinksAlong() async throws {
        let app = app()
        await app.shareSets.refresh()
        let v = try video(app)
        let fileID = try #require(v.file?.id)
        let other = try #require(app.library.posts.flatMap(\.files).first { $0.isPublic && $0.id != fileID }?.id)
        let link = try await app.shareSets.create(items: [fileID, other], title: nil, private: false)
        let along = app.publicSets(containing: v).map(\.id)
        #expect(along.contains(link.id))
        _ = try await app.setFileLink(v, to: .private, alsoMakePrivate: along)
        #expect(along.allSatisfy { id in app.shareSets.sets.first { $0.id == id }?.isPrivate == true })
        let after = try video(app)
        #expect(app.publicSets(containing: after).isEmpty && app.fileLink(of: after) == .private)
    }

    @Test func withoutTheCapabilityThereIsNoChoice() async throws {
        let app = app()
        app.capabilities.privateLinks = false
        let v = try video(app)
        #expect(!app.canChoosePrivateLink(v))
        await #expect(throws: PipelineFailure.unsupported) { try await app.setFileLink(v, to: .private) }
    }
}

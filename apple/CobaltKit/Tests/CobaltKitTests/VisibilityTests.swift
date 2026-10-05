import Foundation
import Testing
@testable import CobaltKit

// CONTRACT-VISIBILITY.md section 6.1 (wave K): one file per rendition, public or private. Decoding the v2 and
// the legacy listing, the merge without a "private copy" / "mp4 link" pair, `AppModel.setVisibility` (optimistic,
// reverts on failure), the default-public flag on saves, and the old shape for a server without the feature.

private let key = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"
private let media = URL(string: "https://media.capybaraharmony.com/")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func file(
    _ id: String, _ kind: LibraryFile.Kind, _ source: LibraryFile.Source, type: String = "video/mp4",
    url: String? = nil, mediaName: String? = nil, visibility: Visibility? = nil, toggle: Bool = false,
    at: Double = 0, poster: String? = nil
) -> LibraryFile {
    var f = LibraryFile(
        id: id, kind: kind, source: source, name: id, url: url.flatMap(URL.init(string:)), contentType: type, bytes: 1_000,
        width: 720, height: 1280, duration: 10, createdAt: t0.addingTimeInterval(at), mediaName: mediaName,
        deletable: false, posterURL: poster.flatMap(URL.init(string:)))
    f.wireVisibility = visibility
    f.canToggleVisibility = toggle
    return f
}

private func post(_ id: String = "PostOne", files: [LibraryFile]) -> LibraryPost {
    LibraryPost(
        id: id, service: "instagram", link: URL(string: "https://www.instagram.com/reel/Dd7P496wolG/"), title: nil,
        duration: 10, width: 720, height: 1280, createdAt: t0, session: nil, files: files)
}

// MARK: - decoding

struct VisibilityDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try CobaltJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    private let publicOriginal = #"{"id":"f1","kind":"private","source":"saved","name":"x","url":"https://media.capybaraharmony.com/AbCdEfGhIj.mp4","content_type":"video/mp4","bytes":1,"created_at":1790000000000,"media_name":null,"deletable":false,"visibility":"public","visibility_toggle":true,"poster_url":"https://media.capybaraharmony.com/p.jpg"}"#

    @Test func aV2FileCarriesItsVisibilityAndTheSwitch() throws {
        let f = try decode(LibraryFile.self, publicOriginal)
        // `kind` still says where the bytes live: an original is `private` even while it has a public link
        #expect(f.kind == .private && f.role == .privateCopy)
        #expect(f.visibility == .public && f.isPublic && f.canToggleVisibility)
        #expect(f.url?.lastPathComponent == "AbCdEfGhIj.mp4")
    }

    @Test func aPrivateWebpHasNoLinkAndKeepsItsPublicName() throws {
        let f = try decode(LibraryFile.self, #"{"id":"w1","kind":"public","source":"studio","name":"x.webp","url":null,"content_type":"image/webp","bytes":1,"created_at":1790000000000,"media_name":"AbCdEfGhIj.webp","deletable":true,"visibility":"private","visibility_toggle":true}"#)
        #expect(f.role == .webp && f.visibility == .private && !f.isPublic && f.url == nil && f.mediaName == "AbCdEfGhIj.webp")
    }

    @Test func aLegacyFileDerivesItsVisibilityFromItsKind() throws {
        let pub = try decode(LibraryFile.self, #"{"id":"f","kind":"public","source":"host","name":"x","url":"https://media.capybaraharmony.com/AbCdEfGhIj.mp4","created_at":1790000000000}"#)
        let priv = try decode(LibraryFile.self, #"{"id":"f","kind":"private","source":"saved","name":"x","created_at":1790000000000}"#)
        #expect(pub.visibility == .public && priv.visibility == .private)
        #expect(!pub.canToggleVisibility && !priv.canToggleVisibility)
        #expect(pub.wireVisibility == nil, "nothing was said")
    }

    @Test func aWordThisBuildDoesNotKnowReadsAsUnsaid() throws {
        var json = publicOriginal
        json = json.replacingOccurrences(of: "\"visibility\":\"public\"", with: "\"visibility\":\"friends\"")
        let f = try decode(LibraryFile.self, json)
        #expect(f.wireVisibility == nil && f.visibility == .private)      // derived from `kind`, the file is not lost
        #expect(f.canToggleVisibility)
    }

    @Test func aPostSaysItsVisibilityWhenTheServerDoes() throws {
        let p = try decode(LibraryPost.self, #"{"id":"a","created_at":1790000000000,"files":[],"visibility":"private"}"#)
        #expect(p.visibility == .private)
        let old = try decode(LibraryPost.self, #"{"id":"a","created_at":1790000000000,"files":[]}"#)
        #expect(old.visibility == nil)
    }

    @Test func theFlagsAreRead() {
        let on = #"{"server":"cobalt-cloudflare","features":{"studio":true,"public_default":true,"visibility":true}}"#
        let caps = HTTPCobaltClient.parseForkCapabilities(Data(on.utf8))
        #expect(caps?.visibility == true && caps?.publicDefault == true)
        let off = HTTPCobaltClient.parseForkCapabilities(Data(#"{"server":"cobalt-cloudflare","features":{"studio":true}}"#.utf8))
        #expect(off?.visibility == false && off?.publicDefault == false)
    }

    @Test func aSessionNamesItsItemAndVisibility() throws {
        let s = try decode(StudioSession.self, #"{"id":"aB3dE6gH9jK2mN5pQ8sTuV","status":"ready","created_at":1790000000000,"expires_at":1790600000000,"item_id":"mkudC5urEwe5bHqT","visibility":"public"}"#)
        #expect(s.itemID == "mkudC5urEwe5bHqT" && s.visibility == .public)
        let old = try decode(StudioSession.self, #"{"id":"aB3dE6gH9jK2mN5pQ8sTuV","status":"ready","created_at":1790000000000,"expires_at":1790600000000}"#)
        #expect(old.itemID == nil && old.visibility == nil)
    }
}

// MARK: - the merge

struct VisibilityMergeTests {
    private let link = "https://media.capybaraharmony.com/2k13zJWqF3.mp4"

    @Test func aV2PostIsOneVideoRenditionNotAPairOfLinks() throws {
        let p = post(files: [
            file("orig", .private, .saved, url: link, visibility: .public, toggle: true, poster: "https://media.capybaraharmony.com/p.jpg"),
            file("w1", .public, .studio, type: "image/webp", url: "https://media.capybaraharmony.com/AbCdEfGhIj.webp",
                 mediaName: "AbCdEfGhIj.webp", visibility: .public, toggle: true, at: 5),
        ])
        let item = try #require(MediaItem.merge(local: nil, post: p))
        #expect(item.renditions.count == 2)
        let video = try #require(item.video)
        #expect(video.hosted == nil && video.file?.id == "orig")
        #expect(video.publicURL?.absoluteString == link && video.visibility == .public && video.canToggleVisibility && video.isPublic)
        #expect(video.posterURL?.lastPathComponent == "p.jpg")
        #expect(item.webps.map(\.visibility) == [.public] && item.webps[0].canToggleVisibility)
        #expect(LibraryRow(item: item).isPublic)
    }

    @Test func aPrivateVideoHasNoLinkAndAStaleDeviceLinkNeverWins() throws {
        let p = post(files: [file("orig", .private, .saved, visibility: .private, toggle: true)])
        let stale = StoredVideo(
            id: "v1", kind: .original, fileURL: nil, posterURL: nil, name: "x", duration: 10, width: 720, height: 1280,
            bytes: 1_000, sessionID: "sid", link: p.link, remoteURL: nil, createdAt: t0,
            publicURL: URL(string: link), mediaID: "m1")
        let local = try #require(StoredMedia(id: "m1", original: stale, webps: []))
        let item = try #require(MediaItem.merge(local: local, post: p))
        let video = try #require(item.video)
        #expect(video.publicURL == nil && video.visibility == .private && !video.isPublic)
        #expect(!LibraryRow(item: item).isPublic)
    }

    @Test func aLegacyListingStillGivesTheHostedLink() throws {
        // an older shape of the new server: the original says "public" with no url, a synthesized host file has it
        let p = post(files: [
            file("orig", .private, .saved, visibility: .public, toggle: true),
            file("pub", .public, .host, url: link, mediaName: "2k13zJWqF3.mp4", at: 1),
        ])
        let video = try #require(MediaItem.merge(local: nil, post: p)?.video)
        #expect(video.publicURL?.absoluteString == link && video.visibility == .public)
        #expect(video.hosted?.id == "pub" && video.file?.id == "orig")
    }

    @Test func aServerThatSaysNothingKeepsTheOldRule() throws {
        let hosted = post(files: [file("orig", .private, .saved), file("pub", .public, .host, url: link, at: 1)])
        let video = try #require(MediaItem.merge(local: nil, post: hosted)?.video)
        #expect(video.publicURL?.absoluteString == link && video.visibility == .public && !video.canToggleVisibility)

        let bare = try #require(MediaItem.merge(local: nil, post: post(files: [file("orig", .private, .saved)]))?.video)
        #expect(bare.publicURL == nil && bare.visibility == nil)
        #expect(!LibraryRow(item: MediaItem.merge(local: nil, post: post(files: [file("orig", .private, .saved)]))!).isPublic)

        // this device hosted it, the library does not list the post yet: the device's link stands
        let local = StoredVideo(
            id: "v1", kind: .original, fileURL: nil, posterURL: nil, name: "x", duration: 10, width: 720, height: 1280,
            bytes: 1_000, sessionID: "sid", link: nil, remoteURL: nil, createdAt: t0, publicURL: URL(string: link), mediaID: "m1")
        let alone = try #require(MediaItem.merge(local: StoredMedia(id: "m1", original: local, webps: []), post: nil)?.video)
        #expect(alone.publicURL?.absoluteString == link && alone.visibility == .public)
    }

    @Test func aWebpSwitchedPrivateIsStillTheSameTabAsThisDevicesCopy() throws {
        let name = "AbCdEfGhIj.webp"
        let local = StoredVideo(
            id: "w-local", kind: .webp, fileURL: nil, posterURL: nil, name: "x.webp", duration: 10, width: 480, height: 854,
            bytes: 1_000, sessionID: nil, link: nil, remoteURL: media.appendingPathComponent(name), createdAt: t0.addingTimeInterval(5),
            mediaID: "m1")
        let stored = try #require(StoredMedia(id: "m1", original: nil, webps: [local]))
        let p = post(files: [
            file("orig", .private, .saved, visibility: .private, toggle: true),
            file("w1", .public, .studio, type: "image/webp", url: nil, mediaName: name, visibility: .private, toggle: true, at: 5),
        ])
        #expect(MediaItem.joins(stored, p), "joined by the public name when the post lists no link")
        let item = try #require(MediaItem.merge(local: stored, post: p))
        #expect(item.webps.count == 1, "one tab, not the device's copy and the server's")
        let webp = item.webps[0]
        #expect(webp.local?.id == "w-local" && webp.file?.id == "w1")
        #expect(webp.visibility == .private && webp.publicURL == nil && webp.canToggleVisibility)
    }

    @Test func aPostWithoutTheListedVisibilityKeepsItsRowPublicWhenOnlyAWebpIs() throws {
        let p = post(files: [file("w1", .public, .studio, type: "image/webp", url: "https://media.capybaraharmony.com/AbCdEfGhIj.webp", visibility: .public, toggle: true)])
        let item = try #require(MediaItem.merge(local: nil, post: p))
        #expect(item.video == nil && LibraryRow(item: item).isPublic)
        let hidden = post(files: [file("w1", .public, .studio, type: "image/webp", url: nil, mediaName: "AbCdEfGhIj.webp", visibility: .private, toggle: true)])
        #expect(!LibraryRow(item: MediaItem.merge(local: nil, post: hidden)!).isPublic)
    }

    @Test func theRowsBadgeIsTheVideosSwitchNotAnyPublicFile() throws {
        let p = post(files: [
            file("orig", .private, .saved, visibility: .private, toggle: true),
            file("w1", .public, .studio, type: "image/webp", url: "https://media.capybaraharmony.com/AbCdEfGhIj.webp", visibility: .public, toggle: true, at: 5),
        ])
        let row = LibraryRow(item: try #require(MediaItem.merge(local: nil, post: p)))
        #expect(!row.isPublic && row.visibilityRank == 0)
    }
}

// MARK: - the client

@Suite(.serialized)
struct VisibilityClientTests {
    private func client(_ server: LoopbackServer, key: String? = key) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { key })
    }

    private let changed = #"{"status":"success","item":{"id":"mkudC5urEwe5bHqT","kind":"private","source":"saved","name":"x","url":"https://media.capybaraharmony.com/2k13zJWqF3.mp4","content_type":"video/mp4","bytes":1,"created_at":1790000000000,"visibility":"public","visibility_toggle":true},"cache_cleared":null}"#

    @Test func theSwitchIsAKeyedPatchWithTheFlag() async throws {
        let server = try await LoopbackServer.start { _ in .json(changed) }
        defer { server.stop() }
        let change = try await client(server).setVisibility(item: "mkudC5urEwe5bHqT", public: true)
        let request = try #require(server.requests.first)
        #expect(request.method == "PATCH" && request.path == "/library/items/mkudC5urEwe5bHqT/visibility")
        #expect(request.headers["authorization"] == "Api-Key \(key)" && request.headers["content-type"] == "application/json")
        #expect(String(decoding: request.body, as: UTF8.self).contains("\"public\":true"))
        #expect(change.file.id == "mkudC5urEwe5bHqT" && change.file.isPublic && change.file.url != nil && change.cacheCleared == nil)

        let off = #"{"status":"success","item":{"id":"mkudC5urEwe5bHqT","kind":"private","source":"saved","name":"x","url":null,"content_type":"video/mp4","bytes":1,"created_at":1790000000000,"visibility":"private","visibility_toggle":true},"cache_cleared":false}"#
        let server2 = try await LoopbackServer.start { _ in .json(off) }
        defer { server2.stop() }
        let gone = try await client(server2).setVisibility(item: "mkudC5urEwe5bHqT", public: false)
        #expect(String(decoding: try #require(server2.requests.first).body, as: UTF8.self).contains("\"public\":false"))
        #expect(!gone.file.isPublic && gone.file.url == nil && gone.cacheCleared == false)
    }

    @Test func withoutAKeyNothingIsSent() async throws {
        let server = try await LoopbackServer.start { _ in .json(changed) }
        defer { server.stop() }
        await #expect(throws: CobaltError.noAPIKey) { _ = try await client(server, key: nil).setVisibility(item: "mkudC5urEwe5bHqT", public: true) }
        #expect(server.requests.isEmpty)
    }

    @Test func theServersRefusalsAreWords() async throws {
        let notToggleable = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.library.not_toggleable"}}"#, status: 409) }
        defer { notToggleable.stop() }
        do {
            _ = try await client(notToggleable).setVisibility(item: "x", public: true)
            Issue.record("expected a refusal")
        } catch let error as CobaltError {
            #expect(error == .api(code: "error.library.not_toggleable", httpStatus: 409))
            #expect(pipelineFailure(from: error, during: .saving) == .unsupported)
        }
        let storage = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.library.storage"}}"#, status: 502) }
        defer { storage.stop() }
        do {
            _ = try await client(storage).setVisibility(item: "x", public: false)
            Issue.record("expected a failure")
        } catch let error as CobaltError {
            #expect(pipelineFailure(from: error, during: .saving) == .server(code: "error.library.storage"))
        }
    }

    @Test func v2IsAskedForOnlyWhenTheCallSaysSo() async throws {
        let empty = #"{"status":"success","posts":[],"counts":{"posts":0,"files":0},"usage":{"public_bytes":0,"private_bytes":0},"next":null}"#
        let server = try await LoopbackServer.start { _ in .json(empty) }
        defer { server.stop() }
        let c = client(server)
        _ = try await c.library(cursor: nil, limit: 20)
        _ = try await c.library(cursor: nil, limit: 20, v2: false)
        _ = try await c.library(cursor: "CUR", limit: 20, v2: true)
        #expect(server.requests.map(\.query) == ["limit=20", "limit=20", "limit=20&cursor=CUR&v=2"])
    }

    @Test func aSaveAsksForAPublicLinkOnlyWhenTold() async throws {
        let server = try await LoopbackServer.start { request in
            request.path == "/studio" ? .json(#"{"status":"success","id":"aB3dE6gH9jK2mN5pQ8sTuV"}"#, status: 201) : .init(status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        _ = try await c.createStudio(link: URL(string: "https://x.com/i/status/1")!)
        _ = try await c.createStudio(link: URL(string: "https://x.com/i/status/1")!, public: nil)
        _ = try await c.createStudio(link: URL(string: "https://x.com/i/status/1")!, public: true)
        let bodies = server.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(!bodies[0].contains("public") && !bodies[1].contains("public"))
        #expect(bodies[2].contains("\"public\":true"))
    }

    @Test func anUploadAsksWithTheQueryFlag() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"success","id":"aB3dE6gH9jK2mN5pQ8sTuV","item":{"id":"it","kind":"private","source":"upload","name":"a.mov","content_type":"video/quicktime","bytes":1000,"created_at":1790000000000}}"#, status: 201)
        }
        defer { server.stop() }
        let c = client(server)
        let url = try makeTempFile("clip.mov")
        _ = try await c.upload(file: url, name: "clip.mov", contentType: "video/quicktime", progress: { _ in })
        _ = try await c.upload(file: url, name: "clip.mov", contentType: "video/quicktime", public: true, progress: { _ in })
        _ = try await c.upload(file: url, name: "clip.mov", contentType: "video/quicktime", public: false, progress: { _ in })
        #expect(server.requests.map(\.query) == ["name=clip.mov", "name=clip.mov&public=1", "name=clip.mov"])
    }
}

// MARK: - the app model

/// Waits (real milliseconds) until nothing new has parked on the virtual clock for a few ticks.
@MainActor
private func settle(_ clock: VirtualClock) async {
    var last = clock.registrations
    var stable = 0
    while stable < 4 {
        try? await Task.sleep(for: .milliseconds(1))
        let r = clock.registrations
        if r == last { stable += 1 } else { stable = 0; last = r }
    }
}

@MainActor
private func visibilityApp(_ mode: VisibilityPreviewMode, clock: VirtualClock = VirtualClock()) -> (AppModel, VirtualClock) {
    (AppModel.makePreviewVisibility(mode, timeScale: 1, clock: clock), clock)
}

@MainActor
private func video(of app: AppModel, post id: String) throws -> Rendition {
    let post = try #require(app.library.posts.first { $0.id == id })
    return try #require(app.mediaItem(for: post).video)
}

@MainActor
private func calls(_ app: AppModel) -> [String] { (app.ctx.client as? PreviewClient)?.visibilityState.calls ?? ["no preview client"] }

@MainActor
struct VisibilityModelTests {
    private let publicPost = "Dd55fEyN1Yy"             // video public (PrEvIeW011.mp4), no local copy
    private let privatePost = "Dd7P496wolG"            // video private, three webps (the third private), a local copy

    @Test func thePreviewServerListsOneFilePerRendition() throws {
        let (app, _) = visibilityApp(.working)
        #expect(app.capabilities.visibility && app.capabilities.publicDefault)
        let files = app.library.posts.flatMap(\.files)
        #expect(files.allSatisfy(\.canToggleVisibility) && !files.contains { $0.source == .host })
        let pub = try video(of: app, post: publicPost)
        #expect(pub.visibility == .public && pub.hosted == nil && pub.publicURL?.lastPathComponent == "PrEvIeW011.mp4")
        let priv = try video(of: app, post: privatePost)
        #expect(priv.visibility == .private && priv.publicURL == nil)
        // the third webp is private: the device's copy of it is the same tab, with no link
        let item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == privatePost }))
        #expect(item.webps.count == 3 && item.webps.map(\.visibility) == [.public, .public, .private])
        #expect(item.webps[2].publicURL == nil)
        // the rows: the video decides, so a private video with public webps is private
        let rows = Dictionary(uniqueKeysWithValues: app.libraryRows.map { ($0.id, $0.isPublic) })
        #expect(rows[publicPost] == true && rows[privatePost] == false)
    }

    @Test func turningALinkOffIsOptimisticThenConfirmed() async throws {
        let (app, clock) = visibilityApp(.working)
        let before = try video(of: app, post: publicPost)
        let url = try #require(before.publicURL)
        let task = Task { try await app.setVisibility(before, public: false) }
        await settle(clock)
        // while the request runs: the file already reads private, the switch is in flight
        let mid = try video(of: app, post: publicPost)
        let fileID = try #require(before.file?.id)
        #expect(app.isChangingVisibility(before) && app.visibilityInFlight == [fileID])
        #expect(mid.visibility == .private && mid.publicURL == nil)
        #expect(calls(app) == ["\(before.file!.id) off"])
        clock.advance()
        let change = try await task.value
        #expect(change.cacheCleared == true && !change.file.isPublic)
        #expect(!app.isChangingVisibility(before) && app.visibilityInFlight.isEmpty)
        let after = try video(of: app, post: publicPost)
        #expect(after.visibility == .private && after.publicURL == nil)
        #expect(app.library.posts.first { $0.id == publicPost }?.visibility == .private)

        // and back on: the same link, as the server keeps it
        let again = Task { try await app.setVisibility(after, public: true) }
        await settle(clock)
        clock.advance()
        let on = try await again.value
        #expect(on.file.url == url)
        #expect(try video(of: app, post: publicPost).publicURL == url)
        #expect(app.library.posts.first { $0.id == publicPost }?.visibility == .public)
    }

    @Test func aSecondCallWhileOneRunsChangesNothing() async throws {
        let (app, clock) = visibilityApp(.working)
        let v = try video(of: app, post: publicPost)
        let first = Task { try await app.setVisibility(v, public: false) }
        await settle(clock)
        let second = try await app.setVisibility(v, public: true)           // answered at once, nothing sent
        #expect(second.file.id == v.file?.id && calls(app).count == 1)
        clock.advance()
        _ = try await first.value
        #expect(try video(of: app, post: publicPost).visibility == .private)
    }

    @Test func aFailureRevertsAndSaysSo() async throws {
        let (app, clock) = visibilityApp(.failing)
        let v = try video(of: app, post: publicPost)
        let url = try #require(v.publicURL)
        let task = Task { try await app.setVisibility(v, public: false) }
        await settle(clock)
        #expect(try video(of: app, post: publicPost).visibility == .private, "optimistic while it runs")
        clock.advance()
        do {
            _ = try await task.value
            Issue.record("expected a failure")
        } catch {
            #expect((error as? PipelineFailure) == .server(code: "error.library.storage"))
        }
        let after = try video(of: app, post: publicPost)
        #expect(after.visibility == .public && after.publicURL == url, "back to what it was")
        #expect(app.visibilityInFlight.isEmpty)
    }

    @Test func aFailedOnLeavesTheVideoPrivateAndTheRetryWorks() async throws {
        let (app, clock) = visibilityApp(.failsOnce)
        let v = try video(of: app, post: privatePost)
        let task = Task { try await app.setVisibility(v, public: true) }
        await settle(clock)
        clock.advance()
        await #expect(throws: PipelineFailure.self) { _ = try await task.value }
        #expect(try video(of: app, post: privatePost).visibility == .private)

        let retry = Task { try await app.setVisibility(v, public: true) }
        await settle(clock)
        clock.advance()
        let change = try await retry.value
        #expect(change.file.isPublic && change.file.url != nil)
        let now = try video(of: app, post: privatePost)
        #expect(now.visibility == .public && now.publicURL == change.file.url)
    }

    @Test func theDevicesRecordFollowsTheSwitch() async throws {
        let (app, clock) = visibilityApp(.working)
        let v = try video(of: app, post: privatePost)
        let record = try #require(v.local)
        #expect(record.publicURL == nil)

        let on = Task { try await app.setVisibility(v, public: true) }
        await settle(clock); clock.advance()
        let changed = try await on.value
        let link = try #require(changed.file.url)
        #expect(app.store.videos.first { $0.id == record.id }?.publicURL == link)

        let fresh = try video(of: app, post: privatePost)
        let off = Task { try await app.setVisibility(fresh, public: false) }
        await settle(clock); clock.advance()
        _ = try await off.value
        #expect(app.store.videos.first { $0.id == record.id }?.publicURL == nil, "a cleared link is not kept as a stale one")
    }

    @Test func aWebpSwitchesLikeAVideo() async throws {
        let (app, clock) = visibilityApp(.working)
        let item = app.mediaItem(for: try #require(app.library.posts.first { $0.id == privatePost }))
        let webp = item.webps[2]
        #expect(webp.visibility == .private && webp.canToggleVisibility && webp.isWebp)
        let task = Task { try await app.setVisibility(webp, public: true) }
        await settle(clock); clock.advance()
        let change = try await task.value
        #expect(change.file.url?.lastPathComponent == "PrEvIeW006.webp", "the same name comes back")
        let after = app.mediaItem(for: try #require(app.library.posts.first { $0.id == privatePost })).webps[2]
        #expect(after.visibility == .public && after.publicURL == change.file.url)
        #expect(app.libraryRows.first { $0.id == privatePost }?.isPublic == false, "the row still follows the video")
    }

    @Test func withoutTheCapabilityOrAServerFileThereIsNoSwitch() async throws {
        let (off, _) = visibilityApp(.working)
        var caps = off.capabilities
        caps.visibility = false
        off.apply(caps)
        let v = try video(of: off, post: publicPost)
        await #expect(throws: PipelineFailure.unsupported) { _ = try await off.setVisibility(v, public: false) }
        #expect(calls(off).isEmpty)

        let (app, _) = visibilityApp(.working)
        let local = Rendition(id: "video", kind: .video, createdAt: t0)
        await #expect(throws: PipelineFailure.unsupported) { _ = try await app.setVisibility(local, public: true) }
        #expect(local.canToggleVisibility == false)
    }

    @Test func theLibraryAsksForV2OnlyOnAServerThatHasIt() async throws {
        // a server with the feature: the whole list is the v2 shape (no separate hosted copy ever)
        let (app, _) = visibilityApp(.working)
        await app.library.refresh()
        #expect(!app.library.posts.flatMap(\.files).contains { $0.source == .host })
        #expect(app.library.posts.allSatisfy { $0.visibility != nil })

        // one without it keeps the old shape, the hosted copy and all, and nothing offers a switch
        let legacy = AppModel.makePreview(.happy, timeScale: 1, clock: SystemClock())
        #expect(!legacy.capabilities.visibility)
        await legacy.library.refresh()
        #expect(legacy.library.posts.flatMap(\.files).contains { $0.source == .host })
        #expect(legacy.library.posts.allSatisfy { $0.visibility == nil })
        let first = try #require(legacy.library.posts.first)
        let v = try #require(legacy.mediaItem(for: first).video)
        #expect(v.hosted != nil && v.publicURL != nil && !v.canToggleVisibility)
    }
}

// MARK: - public by default

@MainActor
struct DefaultPublicTests {
    private func saves(_ h: Harness) -> [String] { (h.ctx.client as? PreviewClient)?.visibilityState.saves ?? ["no preview client"] }

    private func harness(publicDefault: Bool, setting: Bool?) -> Harness {
        let h = Harness(.happy)
        var caps = h.app.capabilities
        caps.publicDefault = publicDefault
        h.app.apply(caps)
        if let setting { h.ctx.settings.newSavesPublic = setting }
        return h
    }

    @Test func theSettingIsOnByDefaultAndSurvivesInTheAppGroupDefaults() {
        let suite = "cobalt.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults, keychain: .memory())
        #expect(settings.newSavesPublic, "on until the owner turns it off")
        settings.newSavesPublic = false
        #expect(defaults.object(forKey: "save.newSavesPublic") as? Bool == false)
        #expect(Settings(defaults: defaults, keychain: .memory()).newSavesPublic == false)
        settings.newSavesPublic = true
        #expect(Settings(defaults: defaults, keychain: .memory()).newSavesPublic)
    }

    @Test func aLinkSaveSendsPublicWhenTheSettingIsOnAndTheServerTakesIt() async throws {
        let h = harness(publicDefault: true, setting: nil)
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(h.pipeline.state == .ready)
        #expect(saves(h) == ["create public"])
    }

    @Test func aLinkSaveSendsNothingWhenTheSettingIsOff() async throws {
        let h = harness(publicDefault: true, setting: false)
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(saves(h) == ["create -"])
    }

    @Test func aServerThatDoesNotTakeTheFieldIsNeverSentIt() async throws {
        let h = harness(publicDefault: false, setting: true)
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        #expect(saves(h) == ["create -"])
    }

    @Test func anUploadFollowsTheSameRule() async throws {
        let on = harness(publicDefault: true, setting: true)
        on.pipeline.start(file: try makeTempFile("clip.mov", bytes: 200_000))
        await on.driveToSettled()
        #expect(saves(on) == ["upload public"])

        let off = harness(publicDefault: true, setting: false)
        off.pipeline.start(file: try makeTempFile("clip.mov", bytes: 200_000))
        await off.driveToSettled()
        #expect(saves(off) == ["upload -"])
    }

    @Test func theShareSheetsRequestCarriesPublicOnlyWhileTheSettingIsOn() throws {
        let client = HTTPCobaltClient(baseURL: URL(string: "https://api.capybaraharmony.com")!, apiKey: { key })
        let link = URL(string: "https://www.instagram.com/p/Dc2QA4ng-US/")!
        let on = try client.shareSaveRequest(link: link, label: "x")
        let off = try client.shareSaveRequest(link: link, label: "x", public: false)
        let onJSON = try #require(try JSONSerialization.jsonObject(with: on.body) as? [String: Any])
        let offJSON = try #require(try JSONSerialization.jsonObject(with: off.body) as? [String: Any])
        #expect(onJSON["public"] as? Bool == true)
        #expect(Set(offJSON.keys) == ["url", "origin", "notify"])
    }

    @Test func theInstantEngineHandsTheSettingToTheRequest() async throws {
        let client = HTTPCobaltClient(baseURL: URL(string: "https://api.capybaraharmony.com")!, apiKey: { key })
        let link = try #require(LinkInfo(URL(string: "https://www.instagram.com/p/Dc2QA4ng-US/")!))
        for makePublic in [true, false] {
            let transport = FakeSaveTransport(background: true)
            var engine = InstantShareEngine(transport: transport, directory: try makeTempDirectory(), foregroundWait: 1, registerWait: 0.1)
            engine.makePublic = makePublic
            #expect(await engine.enqueue(link: link, client: client, job: UUID()) == .saved)
            let upload = try #require(transport.uploads.first)
            let json = try #require(try JSONSerialization.jsonObject(with: upload.body) as? [String: Any])
            #expect((json["public"] as? Bool) == (makePublic ? true : nil))
        }
    }
}

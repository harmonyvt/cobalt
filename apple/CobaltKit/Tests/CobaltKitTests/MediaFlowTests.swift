import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// CONTRACT-MEDIA.md section 9, the flow half: `delete_post` and the client's answers, `AppModel`'s
// "delete everything" (the keyed route and the per-webp fallback), busy, "another webp", and the
// `.renditions` preview data.

private let mediaKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"
private let dd7p = "preview-media-dd7p496wolg"

@MainActor
private func realClockApp(_ scenario: PreviewScenario) -> AppModel {
    AppModel.makePreview(scenario, timeScale: 1, clock: SystemClock())
}

@MainActor
private func item(_ app: AppModel, _ mediaID: String = dd7p) throws -> MediaItem {
    app.mediaItem(for: try #require(app.store.media(id: mediaID)))
}

// MARK: - capability and client

@Suite(.serialized)
struct DeletePostClientTests {
    private func client(_ server: LoopbackServer, key: String? = mediaKey) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { key })
    }

    @Test func theCapabilityComesFromFeaturesDeletePostAndIsFalseWhenAbsent() {
        func caps(_ features: String) -> Capabilities? {
            HTTPCobaltClient.parseForkCapabilities(Data(#"{"server":"cobalt-cloudflare","features":{\#(features)}}"#.utf8))
        }
        #expect(caps(#""delete_post":true"#)?.deletePost == true)
        #expect(caps(#""delete_post":false"#)?.deletePost == false)
        #expect(caps(#""studio":true"#)?.deletePost == false)
        #expect(Capabilities.unknown.deletePost == false)
    }

    @Test func twoHundredIsTheResultAndTheCallIsAKeyedDelete() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"success","post":"Dd7P496wolG","deleted":{"files":4,"bytes":12471210},"remaining":[]}"#)
        }
        defer { server.stop() }
        let result = try await client(server).deletePost(anchor: "AbCdEfGhIjKlMnOp")
        #expect(result == PostDeleteResult(deletedFiles: 4, deletedBytes: 12_471_210, remaining: []))
        let sent = try #require(server.requests.first)
        #expect(sent.method == "DELETE" && sent.path == "/library/items/AbCdEfGhIjKlMnOp/post")
        #expect(sent.headers["authorization"] == "Api-Key \(mediaKey)" && sent.headers["accept"] == "application/json")
    }

    @Test func aPartialAnswerIsDecodedNotThrown() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"error","error":{"code":"error.library.partial"},"post":"P","deleted":{"files":3,"bytes":900},"remaining":["ITEM0001","ITEM0002"]}"#, status: 502)
        }
        defer { server.stop() }
        let result = try await client(server).deletePost(anchor: "AbCdEfGhIjKlMnOp")
        #expect(result == PostDeleteResult(deletedFiles: 3, deletedBytes: 900, remaining: ["ITEM0001", "ITEM0002"]))
    }

    @Test func busyIsAServerBusyFailureAndNotFoundMeansItIsGone() async throws {
        let busy = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.library.busy"}}"#, status: 409) }
        defer { busy.stop() }
        let error = await #expect(throws: CobaltError.api(code: "error.library.busy", httpStatus: 409)) {
            try await client(busy).deletePost(anchor: "AbCdEfGhIjKlMnOp")
        }
        #expect(error.flatMap { pipelineFailure(from: $0, during: .saving) } == .serverBusy)

        let gone = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.library.not_found"}}"#, status: 404) }
        defer { gone.stop() }
        await #expect(throws: PipelineFailure.expired) { try await client(gone).deletePost(anchor: "AbCdEfGhIjKlMnOp") }

        // a 502 that is not the partial answer is an ordinary server error
        let odd = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 502) }
        defer { odd.stop() }
        await #expect(throws: CobaltError.api(code: "error.api.generic", httpStatus: 502)) {
            try await client(odd).deletePost(anchor: "AbCdEfGhIjKlMnOp")
        }
    }

    @Test func aRevokedKeyIsKeyInvalidAndAMissingKeyNeverLeavesTheDevice() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"error","error":{"code":"error.api.auth.key.invalid"}}"#, status: 401)
        }
        defer { server.stop() }
        let error = await #expect(throws: CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)) {
            try await client(server).deletePost(anchor: "AbCdEfGhIjKlMnOp")
        }
        #expect(error.flatMap { pipelineFailure(from: $0, during: .saving) } == .keyInvalid)

        let quiet = try await LoopbackServer.start { _ in .json("{}") }
        defer { quiet.stop() }
        await #expect(throws: CobaltError.noAPIKey) { try await client(quiet, key: nil).deletePost(anchor: "AbCdEfGhIjKlMnOp") }
        #expect(quiet.requests.isEmpty)
    }

    @Test func aClientThatPredatesTheRouteSaysItIsUnsupported() async {
        struct Old: CobaltClient {
            let base: any CobaltClient
            var baseURL: URL { base.baseURL }
            func capabilities() async -> Capabilities { await base.capabilities() }
            func resolve(_ link: URL) async throws -> CobaltResult { try await base.resolve(link) }
            func createStudio(link: URL) async throws -> StudioCreated { try await base.createStudio(link: link) }
            func upload(file: URL, name: String, contentType: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult {
                try await base.upload(file: file, name: name, contentType: contentType, progress: progress)
            }
            func session(_ id: String, wait: Int) async throws -> StudioSession { try await base.session(id, wait: wait) }
            func sourceURL(session id: String) -> URL { base.sourceURL(session: id) }
            func render(session id: String, _ request: RenderRequest) async throws -> String { try await base.render(session: id, request) }
            func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus { try await base.renderStatus(session: id, job: job, wait: wait) }
            func publish(session id: String) async throws -> HostedFile { try await base.publish(session: id) }
            func publish(item id: String) async throws -> HostedFile { try await base.publish(item: id) }
            func openStudio(item id: String) async throws -> StudioCreated { try await base.openStudio(item: id) }
            func library(cursor: String?, limit: Int) async throws -> LibraryPage { try await base.library(cursor: cursor, limit: limit) }
            func deleteMedia(name: String) async throws { try await base.deleteMedia(name: name) }
            func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {}
            func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply { LiveRunReply(pushing: false, started: false) }
            func relayLiveState(run: UUID, _ state: LiveContentState) async throws {}
            func endLiveRun(_ run: UUID) async throws {}
            func liveSelftest() async throws -> LiveSelftest { LiveSelftest(configured: false) }
            func download(_ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL {
                try await base.download(file, to: destination, progress: progress)
            }
        }
        await #expect(throws: PipelineFailure.unsupported) { try await Old(base: PreviewClient()).deletePost(anchor: "x") }
    }
}

// MARK: - preview data

@MainActor
struct RenditionsPreviewTests {
    @Test func theRenditionsScenarioHoldsTheMediaWithThreeWebpsAWebpOnlyMediaAndPlainSaves() throws {
        for scenario in [PreviewScenario.renditions, .renditionsLegacy, .happy] {
            let app = AppModel.preview(scenario)
            #expect(app.store.media.count == 9, "\(scenario): 7 plain saves, the media with webps, the webp-only media")
            let m = try #require(app.store.media(id: dd7p))
            #expect(m.original?.name == "instagram_Dd7P496wolG" && m.original?.bytes == 4_331_778 && m.original?.duration == 14.77)
            #expect(m.webps.map { $0.remoteURL?.lastPathComponent } == ["PrEvIeW001.webp", "PrEvIeW005.webp", "PrEvIeW006.webp"])
            #expect(m.webps.map(\.width) == [480, 480, 480] && m.webps.map(\.height) == [854, 480, 600])
            #expect(m.webps.map(\.bytes) == [4_500_000, 2_371_210, 1_600_000])
            #expect(m.face.remoteURL?.lastPathComponent == "PrEvIeW006.webp")
            #expect(app.store.media.first?.id == dd7p, "the newest webp makes it the first planet")
            let clips = m.webps.compactMap(\.clip)
            #expect(clips.map(\.start) == [0, 2.0, 9.0] && clips.map(\.length) == [10.1, 10.0, 5.4])
            #expect(clips[0].crop == nil && clips[1].crop != nil && clips[2].crop != nil)

            let only = try #require(app.store.media.first { $0.original == nil })
            #expect(only.webps.count == 1 && only.face.remoteURL?.lastPathComponent == "PrEvIeW003.webp")
            #expect(app.store.media.filter { $0.id.hasPrefix("preview-orbit-") }.count == 7)
        }
        #expect(AppModel.preview(.coldStart).store.media.count == 7, "other scenarios keep the orbit alone")
        #expect(AppModel.preview(.emptyOrbit).store.media.isEmpty)
    }

    @Test func theLocalMediaAndTheLibraryPostMergeIntoFourTabs() throws {
        let app = AppModel.preview(.renditions)
        let merged = try item(app)
        #expect(merged.post?.id == "Dd7P496wolG" && merged.id == dd7p && merged.service == "instagram" && merged.ref == "Dd7P496wolG")
        #expect(merged.renditions.map(\.kind) == [.video, .webp(number: 1), .webp(number: 2), .webp(number: 3)])
        #expect(merged.webps.allSatisfy { $0.local != nil && $0.file != nil && $0.deletableName != nil })
        #expect(merged.video?.local != nil && merged.video?.file != nil && merged.video?.hosted == nil)
        #expect(merged.face.kind == .webp(number: 3) && merged.face.deletableName == "PrEvIeW006.webp")
        #expect(merged.webps.map(\.deletableName) == ["PrEvIeW001.webp", "PrEvIeW005.webp", "PrEvIeW006.webp"])
        // from the library's side: the same item
        let post = try #require(app.library.posts.first { $0.id == "Dd7P496wolG" })
        #expect(post.files.count == 4)
        #expect(app.mediaItem(for: post) == merged)
        // the webp-only media joins the post of its link through the webp's URL: its video is the server's private copy
        let only = try item(app, try #require(app.store.media.first { $0.original == nil }).id)
        #expect(only.post?.id == "Dd5JFkMDt4N" && only.video?.local == nil && only.video?.file != nil && only.webpCount == 1)
        // a plain save has no post
        let plain = try item(app, "preview-orbit-7")
        #expect(plain.post == nil && plain.renditions.count == 1 && plain.face.kind == .video && !plain.hasServerCopy)
    }

    @Test func thePreviewServerAnswersPartialThenDoneAndTheLegacyScenarioHasNoRoute() async throws {
        #expect(AppModel.preview(.renditions).capabilities.deletePost && AppModel.preview(.happy).capabilities.deletePost)
        #expect(!AppModel.preview(.renditionsLegacy).capabilities.deletePost && !AppModel.preview(.plainCobalt).capabilities.deletePost)
        #expect(!AppModel.preview(.legacyFork).capabilities.deletePost)

        let client = PreviewClient(scenario: .renditions)
        let first = try await client.deletePost(anchor: "PrEvIeWitem000003")
        #expect(first.deletedFiles == 3 && first.remaining == ["PrEvIeWitem000004"])      // the private copy stays
        let page = try await client.library(cursor: nil, limit: 20)
        #expect(page.posts.first { $0.id == "Dd7P496wolG" }?.files.map(\.id) == ["PrEvIeWitem000004"])
        let second = try await client.deletePost(anchor: "PrEvIeWitem000004")
        #expect(second.deletedFiles == 1 && second.remaining.isEmpty)
        let again = try await client.deletePost(anchor: "PrEvIeWitem000003")             // idempotent
        #expect(again == PostDeleteResult(deletedFiles: 0, deletedBytes: 0, remaining: []))
        #expect(try await client.library(cursor: nil, limit: 20).posts.contains { $0.id == "Dd7P496wolG" } == false)
        await #expect(throws: PipelineFailure.expired) { try await client.deletePost(anchor: "nope") }

        let happy = PreviewClient(scenario: .happy)
        let once = try await happy.deletePost(anchor: "PrEvIeWitem000003")
        #expect(once.remaining.isEmpty && once.deletedFiles == 4)
    }
}

// MARK: - delete everything

@MainActor
struct DeleteEverythingTests {
    @Test func theKeyedRouteDeletesTheWholePostAndEverythingLocal() async throws {
        let app = realClockApp(.happy)
        let calls = Log<String>()
        let names = Log<String>()
        let base = app.ctx.client
        var stub = ScriptedClient(base: base)
        stub.deletePostHook = { calls.add($0); return try await base.deletePost(anchor: $0) }
        stub.deleteMediaHook = { names.add($0) }
        app.ctx.client = stub
        let target = try item(app)
        let posts = app.library.postCount
        #expect(app.library.fileCount == 24)

        let outcome = try await app.deleteEverything(target)
        #expect(outcome == .done)
        #expect(calls.all == ["PrEvIeWitem000003"] && names.all.isEmpty, "one call, anchored on the post's first file")
        #expect(app.store.media(id: dd7p) == nil && app.store.media.count == 8)
        #expect(!app.store.videos.contains { $0.mediaID == dd7p })
        #expect(!app.library.posts.contains { $0.id == "Dd7P496wolG" })
        #expect(app.library.postCount == posts - 1 && app.library.fileCount == 20)
        #expect(app.store.media.contains { $0.id == "preview-orbit-1" }, "other media are untouched")
    }

    @Test func aPartialAnswerRemovesOnlyWhatWasConfirmedAndTheRetryFinishes() async throws {
        let app = realClockApp(.renditions)
        let target = try item(app)
        let first = try await app.deleteEverything(target)
        #expect(first == .partial(remaining: 1))
        // the three webps are gone for good (locally and on the library's list); the video, whose
        // private copy the server still has, stays on its tab
        let left = try #require(app.store.media(id: dd7p))
        #expect(left.webps.isEmpty && left.original != nil)
        let afterPartial = app.mediaItem(for: left)
        #expect(afterPartial.webpCount == 0 && afterPartial.video?.file?.id == "PrEvIeWitem000004" && afterPartial.renditions.count == 1)
        #expect(app.library.posts.first { $0.id == "Dd7P496wolG" }?.files.map(\.id) == ["PrEvIeWitem000004"])
        #expect(app.library.fileCount == 21)

        let second = try await app.deleteEverything(afterPartial)                       // the same call again
        #expect(second == .done)
        #expect(app.store.media(id: dd7p) == nil && !app.library.posts.contains { $0.id == "Dd7P496wolG" })
        #expect(app.library.postCount == 14 && app.library.fileCount == 20)
    }

    @Test func aPostTheServerNoLongerHasCountsAsDone() async throws {
        let app = realClockApp(.happy)
        var stub = ScriptedClient(base: app.ctx.client)
        stub.deletePostHook = { _ in throw PipelineFailure.expired }
        app.ctx.client = stub
        #expect(try await app.deleteEverything(try item(app)) == .done)
        #expect(app.store.media(id: dd7p) == nil && !app.library.posts.contains { $0.id == "Dd7P496wolG" })
    }

    @Test func busyAndNoAnswerThrowAndRemoveNothing() async throws {
        let app = realClockApp(.happy)
        var stub = ScriptedClient(base: app.ctx.client)
        stub.deletePostHook = { _ in throw CobaltError.api(code: "error.library.busy", httpStatus: 409) }
        app.ctx.client = stub
        let target = try item(app)
        await #expect(throws: PipelineFailure.serverBusy) { _ = try await app.deleteEverything(target) }
        stub.deletePostHook = { _ in throw CobaltError.network(.notConnectedToInternet) }
        app.ctx.client = stub
        await #expect(throws: PipelineFailure.unreachable) { _ = try await app.deleteEverything(target) }
        #expect(app.store.media(id: dd7p)?.webps.count == 3 && app.library.posts.contains { $0.id == "Dd7P496wolG" })
    }

    @Test func withoutTheFlagEachDeletableWebpIsDeletedOneByOneAndWhatStaysIsSaid() async throws {
        let app = realClockApp(.renditionsLegacy)
        let calls = Log<String>()
        let names = Log<String>()
        let base = app.ctx.client
        var stub = ScriptedClient(base: base)
        stub.deletePostHook = { calls.add($0); throw PipelineFailure.unsupported }
        stub.deleteMediaHook = { names.add($0); try await base.deleteMedia(name: $0) }
        app.ctx.client = stub

        let outcome = try await app.deleteEverything(try item(app))
        #expect(calls.all.isEmpty, "the keyed route is never tried without the flag")
        #expect(names.all == ["PrEvIeW001.webp", "PrEvIeW005.webp", "PrEvIeW006.webp"])
        #expect(outcome == .leftOnServer(hostedLink: false, privateCopy: true))
        let left = try #require(app.store.media(id: dd7p))
        #expect(left.webps.isEmpty && left.original != nil, "only the local copies of what was deleted go")
        #expect(app.library.posts.first { $0.id == "Dd7P496wolG" }?.files.map(\.id) == ["PrEvIeWitem000004"])
    }

    @Test func theFallbackSaysWhenTheVideoWasHostedAndWhenNothingStaysOnTheServer() async throws {
        let app = realClockApp(.renditionsLegacy)
        // the post also lists a hosted mp4 link
        let i = try #require(app.library.posts.firstIndex { $0.id == "Dd7P496wolG" })
        app.library.posts[i].files.append(LibraryFile(
            id: "PrEvIeWitem000099", kind: .public, source: .host, name: "x.mp4",
            url: URL(string: "https://media.capybaraharmony.com/PrEvIeW099.mp4"), contentType: "video/mp4", bytes: 1,
            width: nil, height: nil, duration: nil, createdAt: .now, mediaName: "PrEvIeW099.mp4", deletable: false))
        #expect(try await app.deleteEverything(try item(app)) == .leftOnServer(hostedLink: true, privateCopy: true))

        // a webp-only media (the server has no video of it): nothing stays
        let app2 = realClockApp(.renditionsLegacy)
        let only = try #require(app2.store.media.first { $0.original == nil })
        var post = try #require(app2.library.posts.first { $0.id == "Dd5JFkMDt4N" })
        post.files.removeAll { $0.role == .privateCopy }
        app2.library.posts = app2.library.posts.map { $0.id == post.id ? post : $0 }
        #expect(try await app2.deleteEverything(try item(app2, only.id)) == .done)
        #expect(app2.store.media(id: only.id) == nil)
    }

    @Test func aFailingWebpIsPartialAndKeepsItsLocalCopy() async throws {
        let app = realClockApp(.renditionsLegacy)
        let base = app.ctx.client
        var stub = ScriptedClient(base: base)
        stub.deleteMediaHook = { name in
            if name == "PrEvIeW005.webp" { throw CobaltError.network(.timedOut) }
            try await base.deleteMedia(name: name)
        }
        app.ctx.client = stub
        let outcome = try await app.deleteEverything(try item(app))
        #expect(outcome == .partial(remaining: 1))
        let left = try #require(app.store.media(id: dd7p))
        #expect(left.webps.map { $0.remoteURL?.lastPathComponent } == ["PrEvIeW005.webp"] && left.original != nil)
        #expect(app.library.posts.first { $0.id == "Dd7P496wolG" }?.files.contains { $0.mediaName == "PrEvIeW005.webp" } == true)
        // the retry deletes the rest
        stub.deleteMediaHook = nil
        app.ctx.client = stub
        #expect(try await app.deleteEverything(try item(app)) == .leftOnServer(hostedLink: false, privateCopy: true))
        #expect(app.store.media(id: dd7p)?.webps.isEmpty == true)
    }

    @Test func aRevokedKeyIsToldToTheAppAndAWebpTheServerLostIsAsGoodAsDeleted() async throws {
        let app = realClockApp(.renditionsLegacy)
        var stub = ScriptedClient(base: app.ctx.client)
        stub.deleteMediaHook = { _ in throw CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401) }
        app.ctx.client = stub
        await #expect(throws: PipelineFailure.keyInvalid) { _ = try await app.deleteEverything(try item(app)) }
        #expect(app.capabilities.key == .invalid)
        stub.deleteMediaHook = { _ in throw CobaltError.api(code: "error.library.not_found", httpStatus: 404) }
        app.ctx.client = stub
        #expect(try await app.deleteEverything(try item(app)) == .leftOnServer(hostedLink: false, privateCopy: true))
        #expect(app.store.media(id: dd7p)?.webps.isEmpty == true)
    }

    @Test func theAlbumInPhotosIsNeverTouched() async throws {
        let app = realClockApp(.happy)
        let ledger = PhotosLedger(directory: try makeTempDirectory())
        app.ctx.photosLedger = ledger
        ledger.recordManual("s:anything", asset: "A1", inAlbum: .yes, now: .now)
        ledger.recordManual("w:https://media.capybaraharmony.com/PrEvIeW006.webp", asset: "A2", inAlbum: .no, now: .now)
        let before = ledger.snapshot()
        #expect(try await app.deleteEverything(try item(app)) == .done)
        #expect(ledger.snapshot() == before)
    }

    @Test func deletingOneWebpGoesToTheServerThenTheLibraryThenThisDevice() async throws {
        let app = realClockApp(.renditions)
        let names = Log<String>()
        let base = app.ctx.client
        var stub = ScriptedClient(base: base)
        stub.deleteMediaHook = { names.add($0); try await base.deleteMedia(name: $0) }
        app.ctx.client = stub
        let target = try item(app)
        let second = target.webps[1]                                   // the 1:1 crop
        try await app.deleteWebp(second, of: target)
        #expect(names.all == ["PrEvIeW005.webp"])
        let left = try #require(app.store.media(id: dd7p))
        #expect(left.webps.count == 2 && left.original != nil && left.face.remoteURL?.lastPathComponent == "PrEvIeW006.webp")
        #expect(app.library.posts.first { $0.id == "Dd7P496wolG" }?.files.count == 3)
        #expect(app.library.fileCount == 23)
        // the video is not a webp
        await #expect(throws: PipelineFailure.unsupported) { try await app.deleteWebp(target.renditions[0], of: target) }

        // a webp with no name only leaves this device: no call
        var nameless = try item(app).webps[0]
        nameless.deletableName = nil
        try await app.deleteWebp(nameless, of: try item(app))
        #expect(names.all == ["PrEvIeW005.webp"])
        #expect(app.store.media(id: dd7p)?.webps.count == 1)
    }

    @Test func removeFromThisDeviceKeepsTheServerAndRefusesWhileInUse() async throws {
        let app = realClockApp(.renditions)
        let target = try item(app)
        let recordIDs = target.local?.renditions.map(\.id) ?? []
        app.store.pin(recordIDs[1])
        #expect(await app.removeFromDevice(target) == false)
        #expect(app.store.media(id: dd7p) != nil)
        app.store.unpin(recordIDs[1])
        #expect(await app.removeFromDevice(target))
        #expect(app.store.media(id: dd7p) == nil && app.library.posts.contains { $0.id == "Dd7P496wolG" })
        // the server's post is still there: the library item is now server-only, with its four tabs
        let post = try #require(app.library.posts.first { $0.id == "Dd7P496wolG" })
        let serverOnly = app.mediaItem(for: post)
        #expect(serverOnly.local == nil && serverOnly.renditions.count == 4 && serverOnly.id == "post:Dd7P496wolG")
        #expect(await app.removeFromDevice(serverOnly) == false)
    }
}

// MARK: - busy, another webp, the run's media

@MainActor
struct MediaRunTests {
    @Test func aRunAimedAtTheMediaMakesItBusyUntilTheRunEnds() async throws {
        let h = Harness(.renditions)
        let app = h.app
        let target = try item(app)
        let other = try item(app, "preview-orbit-2")
        #expect(!app.isBusy(target) && !app.isBusy(other))
        await app.makeWebp(for: target)
        #expect(h.pipeline.targetMediaID == dd7p && h.pipeline.mediaID == dd7p)
        #expect(app.isBusy(target) && !app.isBusy(other))
        h.pipeline.reset()
        #expect(h.pipeline.targetMediaID == nil)
        #expect(!app.isBusy(target))
    }

    @Test func aRunOnASessionOfTheMediaMakesItBusy() async throws {
        let app = realClockApp(.renditions)
        let p = app.pipeline
        p.start(link: postLink)
        for _ in 0..<300 where p.sessionID == nil { try await Task.sleep(for: .milliseconds(10)) }
        let sid = try #require(p.sessionID)
        // the original of this session lands in the store (keep videos on this device)
        let kept = try await app.store.add(
            file: try makeTempFile("o.mp4", bytes: 2_000), kind: .original,
            media: MediaInfo(name: "x", duration: 6, width: 96, height: 160, bytes: 2_000, isImage: false),
            sessionID: sid, link: postLink, remoteURL: nil, move: true)
        let own = try item(app, kept.mediaID)
        #expect(own.local?.sessionIDs == [sid] && app.isBusy(own))
        #expect(p.mediaID == kept.mediaID, "the run's media is found through its session")
        p.reset()
        #expect(!app.isBusy(own) && p.mediaID == nil)
    }

    @Test func anotherWebpJoinsThisMediaWithItsClipAndBecomesTheFace() async throws {
        let h = Harness(.renditions)
        let app = h.app
        h.ctx.capabilities.crop = true
        let target = try item(app)
        #expect(app.store.media(id: dd7p)?.webps.count == 3)

        await app.makeWebp(for: target)
        #expect(app.selectedTab == .save)
        await h.driveToSettled()
        #expect(h.pipeline.state == .ready)
        h.pipeline.setCrop(CropRect(x: 0, y: 0.2, w: 1, h: 0.5625))
        let crop = try #require(h.pipeline.crop)
        h.pipeline.makeWebp()
        await h.driveToSettled()
        guard case .done(let result) = h.pipeline.state else { Issue.record("expected .done, got \(h.pipeline.state)"); return }
        #expect(result.url.lastPathComponent == "PrEvIeW101.webp", "a render in this scenario is a webp of its own")

        // the new webp is the fourth of the same media: a different session, so only the explicit target joined it
        let media = try #require(app.store.media(id: dd7p))
        #expect(media.webps.count == 4 && app.store.media.count == 9 && app.store.media.first?.id == dd7p)
        let stored = try #require(media.webps.last)
        #expect(media.face.id == stored.id && stored.mediaID == dd7p && stored.sessionID == h.pipeline.sessionID)
        #expect(stored.remoteURL == result.url && h.pipeline.sessionID.map(media.sessionIDs.contains) == true)
        let clip = try #require(stored.clip)
        #expect(clip == WebpClip(
            start: 0, length: 10, crop: crop, quality: h.ctx.settings.webpQuality, width: h.ctx.settings.webpWidth))
        #expect(h.pipeline.mediaID == dd7p && h.pipeline.targetMediaID == dd7p)
        // the merged item shows it as `webp 4`, newest, with the clip on its meta line
        let merged = try item(app)
        #expect(merged.webpCount == 4 && merged.face.kind == .webp(number: 4) && merged.face.clip == clip)
        #expect(merged.face.deletableName == "PrEvIeW101.webp")
        // the planet's own state: the run is still this media's
        #expect(app.isBusy(merged))
        h.pipeline.reset()
        #expect(!app.isBusy(try item(app)))
    }

    @Test func aMediaWithoutAnOpenSessionGoesThroughTheLibrarysReopenRoute() async throws {
        let h = Harness(.renditions)
        let opened = Log<String>()
        let base = h.ctx.client
        var stub = ScriptedClient(base: base)
        stub.openStudioHook = { opened.add($0); return try await base.openStudio(item: $0) }
        h.ctx.client = stub
        // the post's session ran out (5 days)
        let i = try #require(h.app.library.posts.firstIndex { $0.id == "Dd7P496wolG" })
        h.app.library.posts[i].session?.expiresAt = h.clock.now().addingTimeInterval(-60)

        await h.app.makeWebp(for: try item(h.app))
        if case .fetching = h.pipeline.state {} else { Issue.record("expected .fetching, got \(h.pipeline.state)") }
        await h.driveToSettled()
        #expect(opened.all == ["PrEvIeWitem000004"], "POST /library/items/<private copy>/studio")
        #expect(h.pipeline.state == .ready && h.pipeline.sessionID?.hasPrefix("PrEvIeWsession") == true)
        #expect(h.pipeline.targetMediaID == dd7p)
    }

    @Test func aMediaTheLibraryHasNotLoadedYetLoadsItFirst() async throws {
        let h = Harness(.renditions)
        let app = h.app
        let local = try #require(app.store.media(id: dd7p))
        app.library.reset()                                              // nothing loaded: no post to reopen from
        #expect(app.library.posts.isEmpty)
        await app.makeWebp(for: app.mediaItem(for: local))
        #expect(!app.library.posts.isEmpty && app.selectedTab == .save && h.pipeline.targetMediaID == dd7p)
    }
}

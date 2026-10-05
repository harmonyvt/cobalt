import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// CONTRACT-LIBRARY2.md section 9 K2: the typed title in the run, the store, the queue and the sync-down.

// MARK: - A client that logs the calls whose order matters

final class TitleLog: Sendable {
    private let lines = Mutex<[String]>([])
    private let failing = Mutex(false)
    private let missing = Mutex(false)
    var entries: [String] { lines.withLock { $0 } }
    func add(_ s: String) { lines.withLock { $0.append(s) } }
    func failPatches(_ on: Bool) { failing.withLock { $0 = on } }
    func answerNotFound(_ on: Bool) { missing.withLock { $0 = on } }
    var shouldFail: Bool { failing.withLock { $0 } }
    var shouldAnswerNotFound: Bool { missing.withLock { $0 } }
    var patches: [String] { entries.filter { $0.hasPrefix("PATCH") } }
}

/// The preview client, with the upload and the title calls logged, and the title call failing on demand.
struct TitleSpyClient: CobaltClient {
    var base: any CobaltClient
    let log: TitleLog
    /// The item the upload "returns": a file of a post the preview library lists, so `setTitle` finds it.
    static let item = "PrEvIeWitem000003"

    var baseURL: URL { base.baseURL }
    func capabilities() async -> Capabilities { await base.capabilities() }
    func resolve(_ link: URL) async throws -> CobaltResult { try await base.resolve(link) }
    func createStudio(link: URL) async throws -> StudioCreated { try await base.createStudio(link: link) }
    func upload(
        file: URL, name: String, contentType: String, progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> UploadResult {
        var result = try await base.upload(file: file, name: name, contentType: contentType, progress: progress)
        result.item.id = Self.item
        log.add("PUT upload")
        return result
    }
    func session(_ id: String, wait: Int) async throws -> StudioSession { try await base.session(id, wait: wait) }
    func sourceURL(session id: String) -> URL { base.sourceURL(session: id) }
    func render(session id: String, _ request: RenderRequest) async throws -> String { try await base.render(session: id, request) }
    func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus {
        try await base.renderStatus(session: id, job: job, wait: wait)
    }
    func publish(session id: String) async throws -> HostedFile { try await base.publish(session: id) }
    func publish(item id: String) async throws -> HostedFile { try await base.publish(item: id) }
    func openStudio(item id: String) async throws -> StudioCreated { try await base.openStudio(item: id) }
    func library(cursor: String?, limit: Int) async throws -> LibraryPage { try await base.library(cursor: cursor, limit: limit) }
    func deleteMedia(name: String) async throws { try await base.deleteMedia(name: name) }
    func deletePost(anchor itemID: String) async throws -> PostDeleteResult { try await base.deletePost(anchor: itemID) }
    func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult {
        log.add("PATCH \(itemID) \(title ?? "-")")
        if log.shouldFail { throw CobaltError.api(code: "error.api.generic", httpStatus: 503) }
        if log.shouldAnswerNotFound { throw PipelineFailure.server(code: "error.library.not_found") }
        return try await base.setTitle(anchor: itemID, title)
    }
    func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {
        try await base.registerLiveStartToken(token, environment: environment)
    }
    func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply { try await base.registerLiveRun(r) }
    func relayLiveState(run: UUID, _ state: LiveContentState) async throws { try await base.relayLiveState(run: run, state) }
    func endLiveRun(_ run: UUID) async throws { try await base.endLiveRun(run) }
    func liveSelftest() async throws -> LiveSelftest { try await base.liveSelftest() }
    func setNotify(session id: String, _ optIn: NotifyOptIn) async throws {
        log.add("NOTIFY \(id) \(optIn.label)")
        try await base.setNotify(session: id, optIn)
    }
    func cancelNotify(session id: String) async throws { try await base.cancelNotify(session: id) }
    func download(
        _ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> URL {
        try await base.download(file, to: destination, progress: progress)
    }
}

@MainActor
private final class Flag { var on = false }

@MainActor
private struct Rig {
    let h: Harness
    let log = TitleLog()

    init(_ scenario: PreviewScenario = .shortClip) {
        h = Harness(scenario)
        h.ctx.client = TitleSpyClient(base: h.ctx.client, log: log)
        h.ctx.capabilities.titles = true
    }

    var pipeline: Pipeline { h.pipeline }

    func startUpload(_ name: String = "IMG_0412.mov") throws {
        pipeline.start(file: try makeTempFile(name, bytes: 5_000))
    }

    /// Everything the title chain has been given has answered.
    func settleTitles() async {
        let done = Flag()
        Task { @MainActor in
            await pipeline.titlesSettled()
            done.on = true
        }
        await h.drive(until: { done.on })
    }
}

// MARK: - The run

@MainActor
@Suite(.serialized)
struct TitleRunTests {
    @Test func aTitleTypedBeforeTheItemIDGoesRightAfterThePutAnswers() async throws {
        let rig = Rig()
        try rig.startUpload()
        await rig.h.settle()
        if case .uploading = rig.pipeline.state {} else { Issue.record("the upload should be running: \(rig.pipeline.state)") }

        rig.pipeline.setTitle("  my clip \n")
        #expect(rig.pipeline.runTitle == "my clip")
        #expect(rig.log.patches.isEmpty, "no item id yet: the title is held on the run")

        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.settleTitles()
        #expect(rig.log.entries == ["PUT upload", "PATCH PrEvIeWitem000003 my clip"], "\(rig.log.entries)")
    }

    @Test func aTitleTypedAfterTheItemIDGoesAtOnce() async throws {
        let rig = Rig()
        try rig.startUpload()
        await rig.h.drive { rig.pipeline.state == .ready }
        #expect(rig.log.entries == ["PUT upload"])

        rig.pipeline.setTitle("later")
        await rig.settleTitles()
        #expect(rig.log.entries == ["PUT upload", "PATCH PrEvIeWitem000003 later"])

        rig.pipeline.setTitle("   ")                                   // blank: back to the default
        await rig.settleTitles()
        #expect(rig.pipeline.runTitle == nil)
        #expect(rig.log.entries.last == "PATCH PrEvIeWitem000003 -", "a clear is sent as a null title")
    }

    @Test func titlesTypedInARowAreSentInOrderAndTheSameOneIsNotSentTwice() async throws {
        let rig = Rig()
        try rig.startUpload()
        await rig.h.drive { rig.pipeline.state == .ready }
        rig.pipeline.setTitle("one")
        rig.pipeline.setTitle("one")                                   // unchanged: nothing
        rig.pipeline.setTitle("two")
        await rig.settleTitles()
        #expect(rig.log.patches == ["PATCH PrEvIeWitem000003 one", "PATCH PrEvIeWitem000003 two"])
    }

    @Test func aServerWithoutTheTitlesCapabilitySendsNothingButKeepsTheRunTitle() async throws {
        let rig = Rig()
        rig.h.ctx.capabilities.titles = false
        try rig.startUpload()
        rig.pipeline.setTitle("mine")
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.settleTitles()
        #expect(rig.log.patches.isEmpty)
        #expect(rig.pipeline.runTitle == "mine")
    }

    @Test func aResetRunIgnoresATitleAndForgetsTheOldOne() async throws {
        let rig = Rig()
        try rig.startUpload()
        rig.pipeline.setTitle("before")
        rig.pipeline.reset()
        #expect(rig.pipeline.runTitle == nil)
        rig.pipeline.setTitle("after the reset")                       // idle: no run to name
        #expect(rig.pipeline.runTitle == nil)
        await rig.h.settle()
        #expect(rig.log.patches.isEmpty)
    }

    @Test func aFailedPatchGoesToTheQueueAndTheNextRefreshSendsIt() async throws {
        let rig = Rig()
        rig.log.failPatches(true)
        try rig.startUpload()
        rig.pipeline.setTitle("keep me")
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.settleTitles()
        let queue = rig.h.ctx.titles
        #expect(queue.all().map(\.itemID) == ["PrEvIeWitem000003"] && queue.all().first?.title == "keep me")
        #expect(rig.log.patches.count == 1)

        rig.log.failPatches(false)
        let refreshed = Flag()
        Task { @MainActor in
            await rig.h.app.library.refresh()
            refreshed.on = true
        }
        await rig.h.drive(until: { refreshed.on })
        #expect(rig.log.patches == ["PATCH PrEvIeWitem000003 keep me", "PATCH PrEvIeWitem000003 keep me"])
        #expect(queue.all().isEmpty, "a 200 empties the queue")
        // the preview server now has it, so the refreshed library carries it
        let post = rig.h.app.library.posts.first { $0.files.contains { $0.id == "PrEvIeWitem000003" } }
        #expect(post?.customTitle == "keep me")
    }

    @Test func aNewerTitleSentDirectlySupersedesWhatWasQueued() async throws {
        let rig = Rig()
        rig.log.failPatches(true)
        try rig.startUpload()
        rig.pipeline.setTitle("old")
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.settleTitles()
        #expect(rig.h.ctx.titles.all().first?.title == "old")

        rig.log.failPatches(false)
        rig.pipeline.setTitle("new")
        await rig.settleTitles()
        #expect(rig.h.ctx.titles.all().isEmpty)
    }

    @Test func aNotFoundAnswerDropsTheTitleInsteadOfQueueingIt() async throws {
        let rig = Rig()
        rig.log.answerNotFound(true)
        try rig.startUpload()
        rig.pipeline.setTitle("gone")
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.settleTitles()
        #expect(rig.log.patches.count == 1 && rig.h.ctx.titles.all().isEmpty)
    }

    @Test func theTitleLandsOnThisDevicesRecordsAtOnce() async throws {
        let rig = Rig(.renditions)
        let id = "preview-media-dd7p496wolg"
        rig.pipeline.start(link: URL(string: shortLink)!)
        rig.pipeline.targetMediaID = id                                 // "another webp" of a media this device has
        rig.pipeline.setTitle("device copy")
        #expect(rig.pipeline.mediaID == id)
        #expect(rig.h.ctx.store.media(id: id)?.renditions.allSatisfy { $0.title == "device copy" } == true)
        #expect(rig.h.ctx.store.media(id: id)?.customTitle == "device copy")
        rig.pipeline.setTitle(nil)                                      // this run had set it: clears it
        #expect(rig.h.ctx.store.media(id: id)?.customTitle == nil)
    }

    @Test func aRunThatNeverTypedATitleLeavesTheMediasTitleAlone() async throws {
        let rig = Rig(.renditions)
        let id = "preview-media-dd7p496wolg"
        await rig.h.ctx.store.setTitle("from before", media: id)
        rig.pipeline.start(link: URL(string: shortLink)!)
        rig.pipeline.targetMediaID = id
        rig.pipeline.setTitle(nil)
        rig.pipeline.setTitle("")
        #expect(rig.h.ctx.store.media(id: id)?.customTitle == "from before")
    }
}

// MARK: - Label and Live Activity

@MainActor
@Suite(.serialized)
struct TitleLabelTests {
    @Test func theNotifyLabelIsTheResolvedTitleCutToSixty() async throws {
        let rig = Rig()
        rig.pipeline.start(link: URL(string: shortLink)!)
        #expect(rig.pipeline.notifyLabel == "x · 2105435404002562056", "no title: the link save")
        rig.pipeline.setTitle(String(repeating: "ab", count: 45))        // 90 code points; the title itself caps at 80
        let label = rig.pipeline.notifyLabel
        #expect(label.unicodeScalars.count == MediaTitle.notifyLength && label.hasSuffix("…"))
        #expect(label.hasPrefix("ababab"))
        rig.pipeline.setTitle("short one")
        #expect(rig.pipeline.notifyLabel == "short one")
        rig.pipeline.setTitle(nil)
        #expect(rig.pipeline.notifyLabel == "x · 2105435404002562056")
    }

    @Test func aFileRunLabelIsItsNameWithoutTheExtension() async throws {
        let rig = Rig()
        try rig.startUpload("IMG_0412.mov")
        #expect(rig.pipeline.notifyLabel == "IMG_0412")
    }

    @Test func aRenameWhileAnOptInIsLiveSendsItAgainWithTheNewLabel() async throws {
        let rig = Rig()
        rig.h.ctx.capabilities.notifyBridge = true
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.h.drive { rig.pipeline.state == .ready }
        let sid = try #require(rig.pipeline.sessionID)
        rig.pipeline.makeWebp()                                          // a render in flight: there is something to announce
        await rig.h.settle()
        let optIn = try #require(rig.pipeline.notifyOptIn)
        await rig.h.ctx.registerNotify(session: sid, optIn, source: .detached)
        #expect(rig.log.entries.filter { $0.hasPrefix("NOTIFY") } == ["NOTIFY \(sid) x · 2105435404002562056"])

        rig.pipeline.setTitle("renamed mid-run")
        await rig.h.ctx.notify.settled()
        #expect(rig.log.entries.filter { $0.hasPrefix("NOTIFY") }.last == "NOTIFY \(sid) renamed mid-run")
        #expect(rig.h.ctx.notify.registered[sid] == .detached, "same source: only the label changed")
    }

    @Test func theLiveActivityTitleIsTheRunTitleElseTheNameWithoutTheExtension() async throws {
        let rig = Rig()
        try rig.startUpload("IMG_0412.mov")
        #expect(rig.pipeline.liveSnapshot(previous: nil, now: Date()).title == "IMG_0412")
        rig.pipeline.setTitle("trip to the sea")
        #expect(rig.pipeline.liveSnapshot(previous: nil, now: Date()).title == "trip to the sea")
        rig.pipeline.setTitle(nil)
        #expect(rig.pipeline.liveSnapshot(previous: nil, now: Date()).title == "IMG_0412")
    }
}

// MARK: - The store

@MainActor
struct StoredTitleTests {
    @Test func aRecordWrittenBeforeTitlesExistedDecodesWithNoTitle() throws {
        let json = """
        {"id":"a","kind":"original","name":"clip","bytes":1,"createdAt":770000000}
        """
        let video = try JSONDecoder().decode(StoredVideo.self, from: Data(json.utf8))
        #expect(video.title == nil)
        let withTitle = try JSONDecoder().decode(
            StoredVideo.self, from: Data(#"{"id":"a","kind":"original","name":"clip","bytes":1,"createdAt":770000000,"title":"mine"}"#.utf8))
        #expect(withTitle.title == "mine")
        // and it survives a round trip
        let again = try JSONDecoder().decode(StoredVideo.self, from: try JSONEncoder().encode(withTitle))
        #expect(again == withTitle)
    }

    @Test func setTitleWritesEveryRecordOfTheMediaAndOnlyThose() async throws {
        let root = try makeTempDirectory()
        let store = OfflineStore(root: root, tools: SystemMediaTools())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func video(_ id: String, _ kind: StoredVideo.Kind, media: String) -> StoredVideo {
            StoredVideo(id: id, kind: kind, fileURL: nil, posterURL: nil, name: id, duration: nil, width: nil, height: nil,
                        bytes: 1, sessionID: nil, link: nil, remoteURL: nil, createdAt: now, mediaID: media)
        }
        store.seed([video("o", .original, media: "m1"), video("w1", .webp, media: "m1"), video("w2", .webp, media: "m1"),
                    video("other", .original, media: "m2")])

        await store.setTitle("  my clip\n ", media: "m1")
        #expect(store.videos.filter { $0.mediaID == "m1" }.map(\.title) == ["my clip", "my clip", "my clip"].map { Optional($0) })
        #expect(store.videos.first { $0.id == "other" }?.title == nil)
        #expect(store.media(id: "m1")?.customTitle == "my clip")

        // written to the index: a second store over the same folder (the extension, the next launch) sees it
        let reopened = OfflineStore(root: root, tools: SystemMediaTools())
        #expect(reopened.media(id: "m1")?.customTitle == "my clip")
        #expect(reopened.videos.filter { $0.mediaID == "m1" }.allSatisfy { $0.title == "my clip" })

        await store.setTitle(nil, media: "m1")                             // clears every record
        #expect(store.videos.allSatisfy { $0.title == nil })
        await store.setTitle("ignored", media: "no such media")           // unknown: a no-op
        #expect(store.videos.allSatisfy { $0.title == nil })
        await store.setTitle(String(repeating: "x", count: 100), media: "m2")
        #expect(store.media(id: "m2")?.customTitle?.unicodeScalars.count == 80, "cleaned like every title")
    }

    @Test func aNewRenditionOfATitledMediaInheritsItsTitle() async throws {
        let root = try makeTempDirectory()
        let store = OfflineStore(root: root, tools: SystemMediaTools())
        let file = try makeTempFile("second.webp", bytes: 200)
        let first = try await store.add(
            file: try makeTempFile("first.mp4", bytes: 200), kind: .original,
            media: MediaInfo(name: "first", duration: nil, width: nil, height: nil, bytes: nil, isImage: false),
            sessionID: "s1", link: nil, remoteURL: nil, move: true)
        await store.setTitle("named", media: first.mediaID)
        let webp = try await store.add(
            file: file, kind: .webp,
            media: MediaInfo(name: "first.webp", duration: 1, width: nil, height: nil, bytes: nil, isImage: false),
            sessionID: "s1", link: nil, remoteURL: URL(string: "https://media.example/AAAAAAAAAA.webp")!, move: true)
        #expect(webp.mediaID == first.mediaID && webp.title == "named")
    }
}

// MARK: - The sync-down and the rename

@MainActor
struct TitleSyncDownTests {
    private func app() -> AppModel {
        let app = AppModel.makePreview(.renditions, timeScale: 1, clock: SystemClock())
        var caps = app.capabilities
        caps.titles = true
        app.apply(caps)
        return app
    }

    @Test func aJoinedMediaTakesTheServersCustomTitle() async throws {
        let app = app()
        let id = "preview-media-dd7p496wolg"
        #expect(app.store.media(id: id)?.customTitle == nil)
        let client = try #require(app.ctxForTests.client as? PreviewClient)
        client.server.setTitle("from the server", post: "Dd7P496wolG")

        await app.library.refresh()
        #expect(app.store.media(id: id)?.customTitle == "from the server")
        #expect(app.store.videos.filter { $0.mediaID == id }.allSatisfy { $0.title == "from the server" })
        let item = app.mediaItem(for: try #require(app.store.media(id: id)))
        #expect(item.titleText == "from the server")

        // the owner changes it elsewhere: the next refresh follows
        client.server.setTitle("changed on the web", post: "Dd7P496wolG")
        await app.library.refresh()
        #expect(app.store.media(id: id)?.customTitle == "changed on the web")
    }

    @Test func aPostWithNoCustomTitleChangesNothingOnThisDevice() async throws {
        let app = app()
        let id = "preview-media-dd7p496wolg"
        await app.store.setTitle("typed offline", media: id)
        await app.library.refresh()                                     // the server has no custom title for it yet
        #expect(app.store.media(id: id)?.customTitle == "typed offline")
    }

    @Test func aTitleStillWaitingInTheQueueIsNewerThanTheServersCopy() async throws {
        let app = app()
        let id = "preview-media-dd7p496wolg"
        let client = try #require(app.ctxForTests.client as? PreviewClient)
        client.server.setTitle("old on the server", post: "Dd7P496wolG")
        await app.store.setTitle("mine, not sent yet", media: id)
        let post = try #require(app.library.posts.first { $0.id == "Dd7P496wolG" })
        app.ctx.titles.enqueue(itemID: try #require(post.files.first).id, title: "mine, not sent yet")

        app.library.didApply(page: LibraryPage(
            posts: [{ var p = post; p.customTitle = "old on the server"; return p }()],
            postCount: 1, fileCount: 1, publicBytes: 0, privateBytes: 0, next: nil))
        #expect(app.store.media(id: id)?.customTitle == "mine, not sent yet")
    }

    @Test func renamingAMediaThisDeviceHoldsWritesTheStoreNotJustMemory() async throws {
        let app = app()
        let id = "preview-media-dd7p496wolg"
        let post = try #require(app.library.posts.first { $0.id == "Dd7P496wolG" })
        try await app.rename(app.mediaItem(for: post), to: "persisted")
        #expect(app.store.media(id: id)?.customTitle == "persisted")
        #expect(app.library.localTitles[id] == nil, "the store is the copy now")
        try await app.rename(app.mediaItem(for: post), to: nil)
        #expect(app.store.media(id: id)?.customTitle == nil)
    }
}

// MARK: - The queue and the shared job

@MainActor
struct TitleQueueTests {
    private func queue() throws -> TitleQueue {
        TitleQueue(fileURL: try makeTempDirectory().appendingPathComponent("titles.json"))
    }

    @Test func oneEntryPerItemTheNewestReplacesTheOlderAndItSurvivesAReopen() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("titles.json")
        let queue = TitleQueue(fileURL: file)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        queue.enqueue(itemID: "a", title: "one", now: now)
        queue.enqueue(itemID: "b", title: nil, now: now)
        queue.enqueue(itemID: "a", title: "two", now: now.addingTimeInterval(1))
        #expect(queue.all().map(\.itemID).sorted() == ["a", "b"])
        #expect(TitleQueue(fileURL: file).all().first { $0.itemID == "a" }?.title == "two")
        #expect(TitleQueue(fileURL: file).all().first { $0.itemID == "b" }?.title == nil)
        queue.remove(itemID: "a")
        #expect(!queue.contains(itemID: "a") && queue.contains(itemID: "b"))
    }

    @Test func flushDropsOn200404And400KeepsOnFailuresAndDropsAfterSevenDays() async throws {
        let queue = try queue()
        let log = TitleLog()
        let h = Harness(.shortClip)
        let client = TitleSpyClient(base: h.ctx.client, log: log)
        let now = Date()
        queue.enqueue(itemID: "PrEvIeWitem000003", title: "fine", now: now)                       // a real item: 200
        queue.enqueue(itemID: "missing-item", title: "gone", now: now)                           // not in the library: 404
        queue.enqueue(itemID: "PrEvIeWitem000008", title: "ancient", now: now.addingTimeInterval(-8 * 24 * 3600))
        let flushed = Flag()
        Task { @MainActor in
            await queue.flush(client: client, now: now)
            flushed.on = true
        }
        await h.drive(until: { flushed.on })
        #expect(queue.all().isEmpty, "\(queue.all())")
        #expect(!log.patches.contains { $0.contains("PrEvIeWitem000008") }, "past seven days nothing is sent")

        queue.enqueue(itemID: "PrEvIeWitem000003", title: "retry me", now: now)
        log.failPatches(true)
        let again = Flag()
        Task { @MainActor in
            await queue.flush(client: client, now: now)
            again.on = true
        }
        await h.drive(until: { again.on })
        #expect(queue.all().map(\.itemID) == ["PrEvIeWitem000003"], "a 503 keeps it")
    }

    @Test func aSharedJobWrittenBeforeTitlesDecodesAndCarriesOne() throws {
        let job = SharedJob(
            id: UUID(), origin: .shareExtension, link: nil, sessionID: "s", media: nil, trim: nil, stage: .saving,
            wantsTrim: false, pickedUp: false, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(job.pendingTitle == nil)
        var dict = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        dict["pendingTitle"] = nil
        let old = try JSONDecoder().decode(SharedJob.self, from: JSONSerialization.data(withJSONObject: dict))
        #expect(old.pendingTitle == nil)
        var titled = job
        titled.pendingTitle = "from the sheet"
        #expect(try JSONDecoder().decode(SharedJob.self, from: JSONEncoder().encode(titled)).pendingTitle == "from the sheet")
    }

    @Test func aResumedJobAppliesItsPendingTitleAndFindsTheItemFromTheSession() async throws {
        let rig = Rig()
        let created = try await rig.h.ctx.client.createStudio(link: URL(string: shortLink)!)
        var job = SharedJob(
            id: UUID(), origin: .shareExtension, link: URL(string: shortLink), sessionID: created.id, media: nil, trim: nil,
            stage: .saving, wantsTrim: false, pickedUp: false, updatedAt: rig.h.clock.now())
        job.pendingTitle = "typed in the sheet"
        rig.pipeline.resume(job)
        #expect(rig.pipeline.runTitle == "typed in the sheet")
        #expect(rig.pipeline.notifyLabel == "typed in the sheet")
    }
}

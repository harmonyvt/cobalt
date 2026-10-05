import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// Lane CORE (2026-10-04): the notify bridge, continuing in the background, "save to photos" in the
// share sheet, the filmstrip's transient failures, continued processing, and the spatial crop.

// MARK: - Fakes

final class FakePhotos: PhotosSaver, Sendable {
    private let state = Mutex<(saved: [URL], failure: (any Error)?)>(([], nil))
    var saved: [URL] { state.withLock { $0.saved } }
    func fail(with error: (any Error)?) { state.withLock { $0.failure = error } }
    func save(fileURL: URL, isImage: Bool) async throws -> String? {
        if let e = state.withLock({ $0.failure }) { throw e }
        state.withLock { $0.saved.append(fileURL) }
        return "ASSET-\(state.withLock { $0.saved.count })"
    }
}

/// Fails its first `failures` calls to `frames`, then behaves like the preview tools; remembers
/// the edge it was asked for.
final class FlakyTools: MediaTools, Sendable {
    private let inner: PreviewMediaTools
    private let state = Mutex<(calls: Int, edges: [CGFloat], inputs: [FrameInput])>((0, [], []))
    let failures: Int
    /// Only these frame indices are produced (nil = all nine).
    let only: [Int]?

    init(inner: PreviewMediaTools, failures: Int, only: [Int]? = nil) {
        self.inner = inner
        self.failures = failures
        self.only = only
    }

    var calls: Int { state.withLock { $0.calls } }
    var edges: [CGFloat] { state.withLock { $0.edges } }
    var inputs: [FrameInput] { state.withLock { $0.inputs } }

    func probe(file: URL) async -> MediaInfo? { await inner.probe(file: file) }
    func poster(for file: URL, isImage: Bool, to destination: URL) async -> Bool { false }

    func frames(of input: FrameInput, duration: Double?, count: Int) -> AsyncThrowingStream<Frame, Error> {
        frames(of: input, duration: duration, count: count, maxEdge: 360)
    }

    func frames(of input: FrameInput, duration: Double?, count: Int, maxEdge: CGFloat) -> AsyncThrowingStream<Frame, Error> {
        let n = state.withLock { s -> Int in s.calls += 1; s.edges.append(maxEdge); s.inputs.append(input); return s.calls }
        if n <= failures {
            return AsyncThrowingStream { $0.finish(throwing: MediaError.noFrames) }
        }
        let only = only
        let source = inner.frames(of: input, duration: duration, count: count)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in source where only?.contains(frame.index) ?? true { continuation.yield(frame) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class FakeContinuedHandle: ContinuedTaskHandle {
    private(set) var progress: [Int64] = []
    private(set) var total: Int64 = 0
    private(set) var titles: [String] = []
    private(set) var completed: Bool?
    var expire: (@MainActor () -> Void)?

    func setProgress(completed: Int64, total: Int64) { progress.append(completed); self.total = total }
    func update(title: String, subtitle: String) { titles.append(title) }
    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) { expire = handler }
    func complete(success: Bool) { completed = success }
}

@MainActor
final class FakeContinuedScheduler: ContinuedTaskScheduler {
    var isAvailable = true
    var failSubmit: (any Error)?
    private(set) var registeredPattern: String?
    private(set) var submitted: [(id: String, title: String)] = []
    private(set) var cancelled: [String] = []
    private var launch: (@MainActor (any ContinuedTaskHandle, String) -> Void)?

    func register(pattern: String, launch: @escaping @MainActor (any ContinuedTaskHandle, String) -> Void) -> Bool {
        registeredPattern = pattern
        self.launch = launch
        return true
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        if let failSubmit { throw failSubmit }
        submitted.append((identifier, title))
    }

    func cancel(identifier: String) { cancelled.append(identifier) }

    /// What the system does after a submission: starts the task.
    func start(_ handle: FakeContinuedHandle) {
        guard let id = submitted.last?.id else { return }
        launch?(handle, id)
    }
}

/// A preview context on the harness's clock with the given collaborators swapped in.
@MainActor
private func makeContext(
    _ h: Harness, photos: (any PhotosSaver)? = nil, tools: (any MediaTools)? = nil, preview: Bool = true,
    notifyBridge: Bool = false, crop: Bool = false
) -> PipelineContext {
    let base = h.ctx
    let ctx = PipelineContext(
        client: base.client, capabilities: base.capabilities, settings: base.settings, store: base.store,
        jobs: base.jobs, tools: tools ?? base.tools, clock: h.clock, photos: photos ?? base.photos,
        clipboard: base.clipboard, intake: base.intake, isPreview: preview)
    ctx.capabilities.notifyBridge = notifyBridge
    ctx.capabilities.crop = crop
    return ctx
}

@MainActor
private func previewServer(_ ctx: PipelineContext) -> PreviewServer { (ctx.client as! PreviewClient).server }

// MARK: - Client shapes

@Suite(.serialized)
struct NotifyClientTests {
    private let key = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

    @Test func notifyIsAKeyedPutAndDelete() async throws {
        let server = try await LoopbackServer.start { _ in .json("{}", status: 200) }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { key })
        let optIn = NotifyOptIn(on: [.saved, .failed], label: String(repeating: "x", count: 90))
        #expect(optIn.label.count == 60)
        try await client.setNotify(session: "SESS", optIn)
        try await client.cancelNotify(session: "SESS")
        let put = try #require(server.requests.first)
        #expect(put.method == "PUT" && put.path == "/studio/SESS/notify")
        #expect(put.headers["authorization"] == "Api-Key \(key)")
        let body = try #require(try JSONSerialization.jsonObject(with: put.body) as? [String: Any])
        #expect(body["on"] as? [String] == ["saved", "failed"] && (body["label"] as? String)?.count == 60)
        let del = try #require(server.requests.last)
        #expect(del.method == "DELETE" && del.path == "/studio/SESS/notify" && del.headers["authorization"] == "Api-Key \(key)")
    }

    @Test func aMissingKeyNeverReachesTheNetwork() async throws {
        let server = try await LoopbackServer.start { _ in .json("{}") }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { nil })
        await #expect(throws: CobaltError.noAPIKey) { try await client.setNotify(session: "S", NotifyOptIn(on: [.saved], label: "a")) }
        #expect(server.requests.isEmpty)
    }

    @Test func renderCarriesNotifyAndCropOnlyWhenAsked() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"pending","job":"JOB1"}"#, status: 202) }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { key })
        func body(_ request: RenderRequest) async throws -> [String: Any] {
            _ = try await client.render(session: "S", request)
            let last = try #require(server.requests.last)
            return try #require(try JSONSerialization.jsonObject(with: last.body) as? [String: Any])
        }
        let plain = try await body(RenderRequest(start: 0, length: 5, width: 480, quality: .med))
        #expect(plain["notify"] == nil && plain["crop"] == nil, "absent unless asked: older servers see today's body")
        let notify = try await body(RenderRequest(start: 0, length: 5, width: 480, quality: .med, notify: true))
        #expect(notify["notify"] as? Bool == true)
        let full = try await body(RenderRequest(start: 0, length: 5, width: 480, quality: .med, crop: .full))
        #expect(full["crop"] == nil, "a whole-frame crop is not sent")
        let cropped = try await body(RenderRequest(
            start: 0, length: 5, width: 480, quality: .med, crop: CropRect(x: 0.1234567, y: 0.2, w: 0.5, h: 0.6)))
        let crop = try #require(cropped["crop"] as? [String: Double])
        #expect(crop == ["x": 0.1235, "y": 0.2, "w": 0.5, "h": 0.6])
    }

    @Test func capabilitiesReadNotifyBridgeAndCrop() {
        func caps(_ features: String) -> Capabilities? {
            HTTPCobaltClient.parseForkCapabilities(Data(#"{"server":"cobalt-cloudflare","features":{\#(features)}}"#.utf8))
        }
        let on = caps(#""studio":true,"notify_bridge":true,"crop":true"#)
        #expect(on?.notifyBridge == true && on?.crop == true)
        let off = caps(#""studio":true"#)
        #expect(off?.notifyBridge == false && off?.crop == false, "absent means false")
        #expect(Capabilities.unknown.notifyBridge == false && Capabilities.unknown.crop == false)
    }
}

// MARK: - Save to photos

@MainActor
@Suite(.serialized)
struct PhotosTests {
    final class FakeLibrary: PhotoLibrary, @unchecked Sendable {
        var current: PhotosAccess
        var afterRequest: PhotosAccess
        var addError: (any Error)?
        var requested = 0
        var added: [URL] = []
        init(_ current: PhotosAccess, afterRequest: PhotosAccess? = nil) {
            self.current = current
            self.afterRequest = afterRequest ?? current
        }
        func status() -> PhotosAccess { current }
        func requestAccess() async -> PhotosAccess { requested += 1; current = afterRequest; return afterRequest }
        func add(fileURL: URL, isImage: Bool) async throws -> String? {
            if let addError { throw addError }
            added.append(fileURL)
            return "ASSET-\(added.count)"
        }
    }

    @Test func aRefusedPermissionIsReportedNotSwallowed() async throws {
        let file = try makeTempFile("a.mp4")
        let lib = FakeLibrary(.denied)
        await #expect(throws: PhotosError.denied) { try await SystemPhotosSaver(library: lib).save(fileURL: file, isImage: false) }
        #expect(lib.added.isEmpty && lib.requested == 0, "a standing refusal is not asked again")
    }

    @Test func anOpenAnswerStillTriesTheSave() async throws {
        // inside an extension `requestAuthorization` can come back "not determined" without a prompt
        let file = try makeTempFile("a.mp4")
        let lib = FakeLibrary(.notDetermined)
        try await SystemPhotosSaver(library: lib).save(fileURL: file, isImage: false)
        #expect(lib.requested == 1 && lib.added == [file])
    }

    @Test func aDeniedRequestStops() async throws {
        let lib = FakeLibrary(.notDetermined, afterRequest: .denied)
        await #expect(throws: PhotosError.denied) {
            try await SystemPhotosSaver(library: lib).save(fileURL: try makeTempFile("a.mp4"), isImage: false)
        }
    }

    @Test func aMissingFileAndAPhotosErrorAreNamed() async throws {
        let lib = FakeLibrary(.authorized)
        await #expect(throws: PhotosError.unreadable) {
            try await SystemPhotosSaver(library: lib).save(fileURL: URL(fileURLWithPath: "/nonexistent/a.mp4"), isImage: false)
        }
        lib.addError = NSError(domain: "PHPhotosErrorDomain", code: 3302)
        await #expect(throws: PhotosError.failed(code: 3302)) {
            try await SystemPhotosSaver(library: lib).save(fileURL: try makeTempFile("a.mp4"), isImage: false)
        }
    }

    @Test func errorsMapToFailuresTheUICanWord() {
        #expect(pipelineFailure(from: PhotosError.denied, during: .saving)?.isPhotosDenied == true)
        #expect(pipelineFailure(from: PhotosError.failed(code: 1), during: .saving) == .server(code: PipelineFailure.photosFailedCode))
        #expect(pipelineFailure(from: PhotosError.unreadable, during: .saving) == .server(code: "error.app.no_original"))
    }

    @Test func theDownloadShowsRealBytesThenAddsToPhotos() async throws {
        let h = Harness(.shortClip)
        let photos = FakePhotos()
        let ctx = makeContext(h, photos: photos)
        let p = Pipeline(context: ctx)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        #expect(p.photosStep == .idle)
        // The filmstrip race already fetched a copy; "save to photos" reuses it. Drop it to see the download itself.
        if let copy = p.localFile { try? FileManager.default.removeItem(at: copy) }
        p.localFile = nil
        p.saveToPhotos()
        #expect(p.photos == .working)
        var sawBytes = false
        await h.drive {
            if case .downloading(let t) = p.photosStep, t.bytes > 0, t.total != nil { sawBytes = true }
            return p.photos == .done
        }
        #expect(sawBytes, "the button can show how much of the original has arrived")
        #expect(photos.saved.count == 1 && p.photosStep == .idle && p.photosFailure == nil)
    }

    @Test func aFailureIsExposedForTheUI() async throws {
        let h = Harness(.shortClip)
        let photos = FakePhotos()
        photos.fail(with: PhotosError.denied)
        let p = Pipeline(context: makeContext(h, photos: photos))
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        p.saveToPhotos()
        await h.drive { p.photos != .working }
        #expect(p.photosFailure?.isPhotosDenied == true && p.photosStep == .idle)
        // and it can be asked again
        photos.fail(with: nil)
        p.saveToPhotos()
        await h.drive { p.photos == .done }
        #expect(photos.saved.count == 1)
    }

    @Test func theCopyFetchedForFramesIsReusedAndRemovedWithTheRun() async throws {
        let h = Harness(.shortClip)
        let photos = FakePhotos()
        let tools = FlakyTools(inner: PreviewMediaTools(clock: h.clock, clip: PreviewData.clip(for: .shortClip)), failures: 3)
        let ctx = makeContext(h, photos: photos, tools: tools)
        let p = Pipeline(context: ctx)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        let copy = try #require(p.localFile, "three remote rungs failed: the device's own copy was fetched")
        #expect(FileManager.default.fileExists(atPath: copy.path))
        p.saveToPhotos()
        await h.drive { p.photos == .done }
        #expect(photos.saved == [copy], "save to photos used that copy instead of downloading again")
        p.reset()
        #expect(!FileManager.default.fileExists(atPath: copy.path), "a temporary copy goes with its run")
    }
}

// MARK: - The filmstrip

@MainActor
@Suite(.serialized)
struct FramesResilienceTests {
    private func rig(failures: Int, only: [Int]? = nil) -> (Harness, Pipeline, FlakyTools) {
        let h = Harness(.shortClip)
        let tools = FlakyTools(inner: PreviewMediaTools(clock: h.clock, clip: PreviewData.clip(for: .shortClip)), failures: failures, only: only)
        let ctx = makeContext(h, tools: tools)
        return (h, Pipeline(context: ctx), tools)
    }

    @Test func aFirstFailureFollowedBySuccessYieldsFrames() async {
        let (h, p, tools) = rig(failures: 1)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        #expect(p.frames.allSatisfy { $0 != nil } && !p.framesFailed)
        #expect((2...3).contains(tools.calls), "the failed ranged read and the device copy it raced (calls: \(tools.calls))")
        if case .remote = tools.inputs[0] {} else { Issue.record("the ranged read of the server's copy goes first") }
    }

    @Test func everyRungFailingSetsFramesFailedAndTheRunGoesOn() async {
        let (h, p, tools) = rig(failures: 99)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        #expect(p.framesFailed && p.frames.allSatisfy { $0 == nil })
        #expect(tools.calls == 4, "three remote rungs, then the device's copy")
        #expect(p.state == .ready, "the webp still works without the preview")
    }

    @Test func laterRungsAskForSmallerFrames() async {
        let (h, p, tools) = rig(failures: 99)
        p.ctx.frameEdge = 360
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        #expect(tools.edges == [360, 360, 360, 160], "ranged rungs 360, 360, 160; the raced copy asks for 360 as its read lands in between")
    }

    @Test func theShareSheetAsksForSmallFramesFromTheStart() async {
        let (h, p, tools) = rig(failures: 0)
        p.ctx.frameEdge = 160
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        #expect(tools.edges.allSatisfy { $0 == 160 } && !tools.edges.isEmpty)
    }

    @Test func gapsTakeTheirNeighboursPicture() async {
        let (h, p, _) = rig(failures: 0, only: [0, 4])
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        #expect(p.frames.allSatisfy { $0 != nil } && !p.framesFailed, "never a half-black strip")
        #expect(p.frames.enumerated().allSatisfy { $0.element?.index == $0.offset })
    }

    @Test func aSourceThatAnswers409ThenWorksStillYieldsFramesForReal() async throws {
        let data = try Data(contentsOf: try await TestVideo.clip())
        let seen = Mutex(0)
        let server = try await LoopbackServer.start { request in
            let n = seen.withLock { $0 += 1; return $0 }
            if n <= 3 { return .json(#"{"status":"error","error":{"code":"error.studio.not_ready"}}"#, status: 409) }
            return LoopbackServer.serve(data, contentType: "video/mp4", for: request)
        }
        defer { server.stop() }
        let url = server.base.appendingPathComponent("studio/AbCdEfGhIjKlMnOpQrStUv/source")
        var frames: [Frame] = []
        for try await frame in SystemMediaTools().frames(of: .remote(url), duration: 6, count: 9) { frames.append(frame) }
        #expect(frames.count == 9)
        #expect(server.requests.count > 3, "the early failures were retried, not given up on")
    }
}

// MARK: - Continue in the background (share sheet)

@MainActor
@Suite(.serialized)
struct ShareContinueTests {
    final class Counter: @unchecked Sendable { var completed = 0 }

    private func share(_ h: Harness, bridge: Bool) -> (pipeline: Pipeline, core: ShareCore, notifier: FakeNotifier, counter: Counter, ctx: PipelineContext) {
        let ctx = makeContext(h, notifyBridge: bridge)
        let pipeline = Pipeline(context: ctx)
        let notifier = FakeNotifier()
        let counter = Counter()
        let core = ShareCore(context: ctx, pipeline: pipeline, notifier: notifier)
        core.complete = { counter.completed += 1 }
        return (pipeline, core, notifier, counter, ctx)
    }

    private func toSaving(_ h: Harness, _ p: Pipeline) async {
        p.start(link: URL(string: shortLink)!)
        await h.drive {
            if case .saving = p.state, p.sessionID != nil { return true }
            return false
        }
    }

    private func toRendering(_ h: Harness, _ p: Pipeline) async {
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        p.makeWebp()
        await h.drive { p.renderJobID != nil }
    }

    @Test func canContinueOnlyWhileTheServerHasWork() async {
        let h = Harness(.shortClip)
        let s = share(h, bridge: true)
        #expect(!s.core.canContinueInBackground)
        await toSaving(h, s.pipeline)
        #expect(s.core.canContinueInBackground)
        await h.drive { s.pipeline.state == .ready }
        #expect(!s.core.canContinueInBackground, "a clip waiting for the owner has nothing on the server")
        s.pipeline.makeWebp()
        await h.drive { s.pipeline.renderJobID != nil }
        #expect(s.core.canContinueInBackground)
    }

    @Test func midRenderWithTheBridgeRegistersTheOptInAndSkipsTheLocalNote() async throws {
        let h = Harness(.shortClip)
        let s = share(h, bridge: true)
        await toRendering(h, s.pipeline)
        let sid = try #require(s.pipeline.sessionID)
        let job = try #require(s.pipeline.renderJobID)
        let outcome = await s.core.continueInBackground()
        #expect(outcome == .continuesInBackground && s.counter.completed == 1)
        let optIn = try #require(previewServer(s.ctx).notifications[sid])
        #expect(Set(optIn.on) == [.rendered, .failed] && !optIn.label.isEmpty)
        #expect(s.notifier.posts.isEmpty, "the server speaks for it")
        let record = try #require(s.ctx.jobs.all().first)
        #expect(record.stage == .rendering(job: job) && record.origin == .shareExtension)
    }

    @Test func midSaveRegistersSavedAndLeavesASavingJob() async throws {
        let h = Harness(.shortClip)
        let s = share(h, bridge: true)
        await toSaving(h, s.pipeline)
        let sid = try #require(s.pipeline.sessionID)
        #expect(await s.core.close() == .continuesInBackground, "closing mid-save with the bridge is the same thing")
        let optIn = try #require(previewServer(s.ctx).notifications[sid])
        #expect(Set(optIn.on) == [.saved, .failed])
        #expect(s.ctx.jobs.all().first?.stage == .saving && s.notifier.posts.isEmpty)
    }

    @Test func withoutTheBridgeALocalNotificationSaysItIsStillGoing() async throws {
        let h = Harness(.shortClip)
        let s = share(h, bridge: false)
        await toRendering(h, s.pipeline)
        #expect(await s.core.continueInBackground() == .continuesInBackground)
        #expect(s.notifier.posts.map(\.kind) == [.stillMaking] && s.notifier.authorizationRequests == 1)
        #expect(previewServer(s.ctx).notifications.isEmpty && previewServer(s.ctx).notifyCalls.isEmpty)

        let h2 = Harness(.shortClip)
        let s2 = share(h2, bridge: false)
        await toSaving(h2, s2.pipeline)
        #expect(await s2.core.continueInBackground() == .continuesInBackground)
        #expect(s2.notifier.posts.map(\.kind) == [.stillSaving])
    }

    @Test func closingMidSaveWithoutTheBridgeJustStops() async throws {
        let h = Harness(.shortClip)
        let s = share(h, bridge: false)
        await toSaving(h, s.pipeline)
        #expect(await s.core.close() == .dismissed && s.counter.completed == 1)
        #expect(s.notifier.posts.isEmpty && s.ctx.jobs.all().isEmpty)
    }

    @Test func aFailedOptInFallsBackToTheLocalNote() async throws {
        struct Refusing: Sendable {}
        let h = Harness(.shortClip)
        let s = share(h, bridge: true)
        s.ctx.client = RefusingNotifyClient(base: s.ctx.client)
        await toRendering(h, s.pipeline)
        #expect(await s.core.continueInBackground() == .continuesInBackground)
        #expect(s.notifier.posts.map(\.kind) == [.stillMaking])
    }

    @Test func nothingToContinueIsADismissal() async {
        let h = Harness(.shortClip)
        let s = share(h, bridge: true)
        #expect(await s.core.continueInBackground() == .dismissed && s.counter.completed == 1)
    }
}

/// A server whose notify bridge answers with an error.
struct RefusingNotifyClient: CobaltClient {
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
    func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus {
        try await base.renderStatus(session: id, job: job, wait: wait)
    }
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
    func setNotify(session id: String, _ optIn: NotifyOptIn) async throws { throw CobaltError.api(code: "error.api.generic", httpStatus: 500) }
    func download(_ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL {
        try await base.download(file, to: destination, progress: progress)
    }
}

// MARK: - detach() and the bridge

@MainActor
@Suite(.serialized)
struct DetachNotifyTests {
    @Test func detachMidRenderRegistersTheOptInWhenTheBridgeIsOn() async throws {
        let h = Harness(.shortClip)
        let ctx = makeContext(h, notifyBridge: true)
        let p = Pipeline(context: ctx)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        p.makeWebp()
        await h.drive { p.renderJobID != nil }
        let sid = try #require(p.sessionID)
        p.detach()
        await ctx.notify.settled()
        #expect(Set(previewServer(ctx).notifications[sid]?.on ?? []) == [.rendered, .failed])
        #expect(ctx.notify.registered[sid] == .detached)
        // the run finishes here: the server need not say it too
        await h.drive { ctx.background.isEmpty }
        await ctx.notify.settled()
        #expect(previewServer(ctx).notifications[sid] == nil && previewServer(ctx).notifyCalls == ["PUT \(sid)", "DELETE \(sid)"])
    }

    @Test func noBridgeNoCalls() async throws {
        let h = Harness(.shortClip)
        let ctx = makeContext(h, notifyBridge: false)
        let p = Pipeline(context: ctx)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        p.makeWebp()
        await h.drive { p.renderJobID != nil }
        p.detach()
        await h.drive { ctx.background.isEmpty }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(previewServer(ctx).notifyCalls.isEmpty)
    }

    @Test func detachingWithNothingOnTheServerRegistersNothing() async throws {
        let h = Harness(.shortClip)
        let ctx = makeContext(h, notifyBridge: true)
        let p = Pipeline(context: ctx)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        p.detach()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(previewServer(ctx).notifyCalls.isEmpty)
    }
}

// MARK: - Continued processing

@MainActor
@Suite(.serialized)
struct ContinuedProcessingTests {
    @MainActor private struct Rig {
        let h: Harness
        let ctx: PipelineContext
        let pipeline: Pipeline
        let scheduler = FakeContinuedScheduler()
        let controller: ContinuedProcessing
        let notifier = FakeNotifier()
        let activity = FakeActivity()

        init(bridge: Bool = false) {
            h = Harness(.shortClip)
            ctx = makeContext(h, notifyBridge: bridge)
            pipeline = Pipeline(context: ctx)
            ctx.notifier = notifier
            ctx.background.activity = activity
            activity.isActive = true
            let p = pipeline
            controller = ContinuedProcessing(context: ctx, scheduler: scheduler, home: { p }, makeIdentifier: { "com.capybaraharmony.cobalt.run.t1" })
            ctx.continued = controller
            controller.register()
        }
    }

    @Test func itRegistersTheWildcardAndSubmitsWhenAWorkStarts() async throws {
        let r = Rig()
        #expect(r.scheduler.registeredPattern == "com.capybaraharmony.cobalt.run.*")
        r.pipeline.start(link: URL(string: shortLink)!)
        #expect(r.scheduler.submitted.map(\.id) == ["com.capybaraharmony.cobalt.run.t1"])
        #expect(r.scheduler.submitted.first?.title == "saving your video")
        await r.h.drive { r.pipeline.state == .ready }
        #expect(r.scheduler.submitted.count == 1, "one task per spell of work")
    }

    @Test func progressIsRealMonotonicAndTheTaskCompletes() async throws {
        let r = Rig()
        let handle = FakeContinuedHandle()
        r.pipeline.start(link: URL(string: shortLink)!)
        r.scheduler.start(handle)
        #expect(r.controller.isRunning && handle.expire != nil)
        await r.h.drive { r.pipeline.state == .ready }
        #expect(!handle.progress.isEmpty && handle.total == 1000)
        #expect(zip(handle.progress, handle.progress.dropFirst()).allSatisfy { $0 <= $1 }, "never backwards")
        #expect(handle.progress.allSatisfy { $0 < 1000 })
        #expect(handle.completed == true && !r.controller.isRunning)
    }

    @Test func aRenderGetsItsOwnTaskAndSaysWebpReadyInTheBackground() async throws {
        let r = Rig()
        r.pipeline.start(link: URL(string: shortLink)!)
        await r.h.drive { r.pipeline.state == .ready }
        r.pipeline.makeWebp()
        #expect(r.scheduler.submitted.count == 2 && r.scheduler.submitted.last?.title == "making your webp")
        let handle = FakeContinuedHandle()
        r.scheduler.start(handle)
        await r.h.drive { if case .rendering(.decoding) = r.pipeline.state { return true } else { return false } }
        r.activity.isActive = false                    // the owner left
        await r.h.drive { if case .done = r.pipeline.state { return true } else { return false } }
        for _ in 0..<200 where r.notifier.posts.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(r.notifier.posts.map(\.kind) == [.webpReady])
        #expect(handle.completed == true)
        #expect(handle.progress.contains { $0 > 100 && $0 < 1000 }, "decoded frames drive the number")
    }

    @Test func aSaveFinishedInTheBackgroundIsAnnouncedAndAFinishedAppSaysNothing() async throws {
        let r = Rig()
        r.pipeline.start(link: URL(string: shortLink)!)
        r.scheduler.start(FakeContinuedHandle())
        r.activity.isActive = false
        await r.h.drive { r.pipeline.state == .ready }
        for _ in 0..<200 where r.notifier.posts.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(r.notifier.posts.map(\.kind) == [.saved])

        let quiet = Rig()
        quiet.pipeline.start(link: URL(string: shortLink)!)
        quiet.scheduler.start(FakeContinuedHandle())
        await quiet.h.drive { quiet.pipeline.state == .ready }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(quiet.notifier.posts.isEmpty, "the owner watched it finish")
    }

    @Test func expiryCompletesUnsuccessfullyAndTheServerTakesOver() async throws {
        let r = Rig(bridge: true)
        let handle = FakeContinuedHandle()
        r.pipeline.start(link: URL(string: shortLink)!)
        r.scheduler.start(handle)
        await r.h.drive { r.pipeline.sessionID != nil }
        r.activity.isActive = false
        handle.expire?()
        #expect(handle.completed == false && !r.controller.isRunning && r.controller.expirations == 1)
        let sid = try #require(r.pipeline.sessionID)
        await r.ctx.notify.settled()
        #expect(previewServer(r.ctx).notifications[sid] != nil, "Hark covers what the task could not finish")
        #expect(r.scheduler.submitted.count == 1, "no second request from the background")
    }

    @Test func leavingRegistersTheOptInAndComingBackTakesItBack() async throws {
        let r = Rig(bridge: true)
        r.pipeline.start(link: URL(string: shortLink)!)
        await r.h.drive { if case .saving = r.pipeline.state { return true } else { return false } }
        let sid = try #require(r.pipeline.sessionID)
        r.controller.appResigned()
        await r.ctx.notify.settled()                   // intents are recorded at the call; this waits for the wire
        #expect(Set(previewServer(r.ctx).notifications[sid]?.on ?? []) == [.saved, .failed])
        r.controller.appBecameActive()
        await r.ctx.notify.settled()
        #expect(previewServer(r.ctx).notifications[sid] == nil)
        #expect(previewServer(r.ctx).notifyCalls == ["PUT \(sid)", "DELETE \(sid)"])
    }

    /// The race behind the flaky version of the test above: the owner comes back while the PUT is
    /// still on the wire. The look-up for what to take back used to run before the PUT had answered,
    /// found nothing, and the opt-in landed after: Hark said "saved" for a run the owner watched.
    @Test func comingBackWhileThePutIsOnTheWireStillTakesItBack() async throws {
        let r = Rig(bridge: true)
        let g = GatedNotify(r.ctx.client, clock: r.h.clock)
        r.ctx.client = g.client
        r.pipeline.start(link: URL(string: shortLink)!)
        await r.h.drive { if case .saving = r.pipeline.state { return true } else { return false } }
        let sid = try #require(r.pipeline.sessionID)
        r.controller.appResigned()
        await g.puts.next()                            // the PUT is parked: sent, not yet applied
        #expect(g.calls.isEmpty)
        r.controller.appBecameActive()
        await g.gate.open()
        await r.ctx.notify.settled()
        #expect(g.calls == ["PUT \(sid)", "DELETE \(sid)"], "\(g.calls)")
        #expect(g.server.notifications[sid] == nil, "no opt-in is left for a run the owner watched")
    }

    /// The PUT timed out on the app's side but the server recorded it: coming back still cleans it.
    @Test func aPutThatNeverAnsweredButLandedIsTakenBackWhenTheOwnerReturns() async throws {
        let r = Rig(bridge: true)
        let base = r.ctx.client
        let server = previewServer(r.ctx)
        var stub = ScriptedClient(base: base)
        stub.setNotifyHook = { id, optIn in
            try await base.setNotify(session: id, optIn)
            throw CobaltError.network(.timedOut)
        }
        r.ctx.client = stub
        r.pipeline.start(link: URL(string: shortLink)!)
        await r.h.drive { if case .saving = r.pipeline.state { return true } else { return false } }
        let sid = try #require(r.pipeline.sessionID)
        r.controller.appResigned()
        await r.ctx.notify.settled()
        #expect(server.notifications[sid] != nil, "the server has an opt-in the app was never told about")
        r.controller.appBecameActive()
        await r.ctx.notify.settled()
        #expect(server.notifications[sid] == nil)
        #expect(server.notifyCalls == ["PUT \(sid)", "DELETE \(sid)"])
    }

    @Test func aRefusedSubmissionIsRecordedAndHarmless() async throws {
        let r = Rig()
        r.scheduler.failSubmit = NSError(domain: "BGTaskSchedulerErrorDomain", code: 1)
        r.pipeline.start(link: URL(string: shortLink)!)
        #expect(r.controller.lastSubmitError != nil && !r.controller.hasRequest)
        await r.h.drive { r.pipeline.state == .ready }
        #expect(r.pipeline.state == .ready)
    }

    @Test func aTaskThatNeverStartedIsCancelledWhenTheWorkEnds() async throws {
        let r = Rig()
        r.pipeline.start(link: URL(string: shortLink)!)
        await r.h.drive { r.pipeline.state == .ready }
        #expect(r.scheduler.cancelled == ["com.capybaraharmony.cobalt.run.t1"])
    }

    @Test func noSchedulerNoRequests() async throws {
        let r = Rig()
        r.scheduler.isAvailable = false
        r.pipeline.start(link: URL(string: shortLink)!)
        #expect(r.scheduler.submitted.isEmpty)
    }

    @Test func progressFractionsFollowTheRealNumbers() async throws {
        let h = Harness(.shortClip)
        let p = Pipeline(context: makeContext(h))
        let now = h.clock.now()
        p.setState(.saving(bytes: 500, total: 1000, since: now))
        #expect(abs(ContinuedProgress.fraction(of: p, now: now) - 0.37) < 0.001)
        p.setState(.rendering(.decoding(done: 5, total: 10)))
        #expect(abs(ContinuedProgress.fraction(of: p, now: now) - 0.43) < 0.001)
        p.setState(.ready)
        #expect(ContinuedProgress.fraction(of: p, now: now) == 1)
        p.keepProgress = TransferProgress(bytes: 50, total: 100)
        #expect(abs(ContinuedProgress.fraction(of: p, now: now) - 0.525) < 0.001, "the original still arriving")
    }
}

// MARK: - Crop

@MainActor
@Suite(.serialized)
struct CropTests {
    let landscape = CGSize(width: 1920, height: 1080)
    let portrait = CGSize(width: 1080, height: 1920)

    @Test func presetsAreTheLargestCentredRectOfThatAspect() {
        let square = CropRect.centered(.square, in: landscape)
        #expect(abs(square.h - 1) < 1e-9 && abs(square.w - 1080.0 / 1920) < 1e-9 && abs(square.x - (1 - square.w) / 2) < 1e-9 && square.y == 0)
        let tall = CropRect.centered(.nineSixteen, in: landscape)
        #expect(abs(tall.w * 1920 / (tall.h * 1080) - 9.0 / 16) < 0.01 && tall.h == 1)
        let wide = CropRect.centered(.sixteenNine, in: portrait)
        #expect(wide.w == 1 && abs(wide.w * 1080 / (wide.h * 1920) - 16.0 / 9) < 0.01 && abs(wide.y - (1 - wide.h) / 2) < 1e-9)
        let four5 = CropRect.centered(.fourFive, in: portrait)
        #expect(abs(four5.w * 1080 / (four5.h * 1920) - 0.8) < 0.01)
        #expect(CropRect.centered(.original, in: landscape).isFull && CropRect.centered(.free, in: landscape).isFull)
        #expect(CropRect.centered(.sixteenNine, in: landscape).isFull, "a 16:9 source is already 16:9")
        #expect(CropRect.centered(.square, in: .zero).isFull)
    }

    @Test func matchedAspectNamesWhatWasPicked() {
        for a in [CropRect.Aspect.square, .fourFive, .nineSixteen, .sixteenNine] {
            for size in [landscape, portrait] {
                let rect = CropRect.centered(a, in: size)
                // a preset that is the source's own shape is the whole frame
                #expect(rect.matchedAspect(in: size) == (rect.isFull ? .original : a))
            }
        }
        #expect(CropRect.full.matchedAspect(in: landscape) == .original)
        #expect(CropRect(x: 0.1, y: 0.1, w: 0.33, h: 0.5).matchedAspect(in: landscape) == nil)
    }

    @Test func clampingKeepsItInsideAndAtLeast64Pixels() {
        let over = CropRect(x: 0.9, y: -0.5, w: 0.5, h: 2).clamped(in: landscape)
        #expect(over.w == 0.5 && over.h == 1 && abs(over.x - 0.5) < 1e-9 && over.y == 0, "moved, not shrunk")
        let tiny = CropRect(x: 0.5, y: 0.5, w: 0.001, h: 0.001).clamped(in: landscape)
        #expect(abs(tiny.w * 1920 - 64) < 1e-6 && abs(tiny.h * 1080 - 64) < 1e-6)
        let unknown = CropRect(x: 0, y: 0, w: 0, h: 0).clamped()
        #expect(unknown.w == 0.01 && unknown.h == 0.01)
        let nan = CropRect(x: .nan, y: .infinity, w: .nan, h: 0.5).clamped(in: landscape)
        #expect(nan.w == 1 && nan.x == 0 && nan.y <= 0.5 && nan.y.isFinite)
    }

    @Test func pixelsAreEvenLikeTheServers() {
        let px = CropRect(x: 0, y: 0, w: 0.5013, h: 0.3333).pixelSize(in: CGSize(width: 1001, height: 999))
        #expect(Int(px.width) % 2 == 0 && Int(px.height) % 2 == 0)
        #expect(px.width == 500 && px.height == 332)
    }

    @Test func codableRoundTrips() throws {
        let rect = CropRect(x: 0.1, y: 0.2, w: 0.3, h: 0.4)
        #expect(try JSONDecoder().decode(CropRect.self, from: JSONEncoder().encode(rect)) == rect)
    }

    private func readyPipeline(_ h: Harness, crop: Bool) async -> (Pipeline, PipelineContext) {
        let ctx = makeContext(h, crop: crop)
        let p = Pipeline(context: ctx)
        p.start(link: URL(string: shortLink)!)
        await h.drive { p.state == .ready }
        return (p, ctx)
    }

    @Test func theCropSurvivesBackToTrimAndGoesWithANewRun() async throws {
        let h = Harness(.shortClip)
        let (p, _) = await readyPipeline(h, crop: true)
        let size = try #require(p.sourceSize)
        p.setCrop(CropRect.centered(.square, in: size))
        let set = try #require(p.crop)
        p.makeWebp()
        await h.drive { if case .done = p.state { return true } else { return false } }
        p.backToTrim()
        #expect(p.state == .ready && p.crop == set, "back to the trim keeps it")
        p.setCrop(.full)
        #expect(p.crop == nil, "a whole-frame crop is no crop")
        p.setCrop(set)
        p.start(link: URL(string: pastedLink)!)
        #expect(p.crop == nil, "a new run starts uncropped")
    }

    @Test func setCropClampsToTheSource() async throws {
        let h = Harness(.shortClip)
        let (p, _) = await readyPipeline(h, crop: true)
        p.setCrop(CropRect(x: 0.99, y: 0.99, w: 0.0001, h: 5))
        let c = try #require(p.crop)
        let s = try #require(p.sourceSize)
        #expect(c.w * s.width >= 63.9 && c.h <= 1 && c.x + c.w <= 1.000001 && c.y + c.h <= 1.000001)
    }

    @Test func outputSizeFollowsCropAndWidth() async throws {
        let h = Harness(.shortClip)
        let (p, _) = await readyPipeline(h, crop: true)
        let s = try #require(p.sourceSize)
        let whole = try #require(p.outputSize(width: 480))
        #expect(whole.width == min(480, s.width) && abs(whole.width / whole.height - s.width / s.height) < 0.03)
        p.setCrop(CropRect.centered(.square, in: s))
        let square = try #require(p.outputSize(width: 480))
        #expect(square.width == min(480, (s.height / 2).rounded(.down) * 2) && square.width == square.height)
        let narrow = try #require(p.outputSize(width: 100))
        #expect(narrow.width == 100 && narrow.height == 100)
        // never wider than the crop itself
        p.setCrop(CropRect(x: 0.2, y: 0, w: 0.1, h: 0.5))
        let thin = try #require(p.outputSize(width: 480))
        #expect(thin.width <= (p.crop!.pixelSize(in: s).width))
        #expect(Pipeline(context: makeContext(h)).outputSize(width: 480) == nil, "unknown until the source is")
    }

    @Test func theRenderSendsTheCropOnlyToAServerThatHasIt() async throws {
        for supported in [true, false] {
            let h = Harness(.shortClip)
            let (p, ctx) = await readyPipeline(h, crop: supported)
            let s = try #require(p.sourceSize)
            p.setCrop(CropRect.centered(.square, in: s))
            p.makeWebp()
            await h.drive { if case .done = p.state { return true } else { return false } }
            let job = try #require(previewServer(ctx).render(p.webpResult?.job ?? ""))
            if supported {
                #expect(job.request.crop == p.crop)
                let r = try #require(p.webpResult)
                #expect(r.width == r.height, "the result carries the real cropped aspect")
                #expect(CGSize(width: r.width, height: r.height) == p.outputSize(width: ctx.settings.webpWidth))
            } else {
                #expect(job.request.crop == nil, "an old server would ignore it and make the whole frame")
                let r = try #require(p.webpResult)
                #expect(r.width != r.height)
            }
        }
    }

    @Test func aWholeFrameCropIsNeverSent() async throws {
        let h = Harness(.shortClip)
        let (p, ctx) = await readyPipeline(h, crop: true)
        p.setCrop(CropRect(x: 0, y: 0, w: 1, h: 1))
        p.makeWebp()
        await h.drive { if case .done = p.state { return true } else { return false } }
        let job = try #require(previewServer(ctx).render(p.webpResult?.job ?? ""))
        #expect(job.request.crop == nil)
    }
}

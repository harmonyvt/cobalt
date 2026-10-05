// Deliberately a plain `import CobaltKit` (no @testable): this file only sees what the app and the
// share extension see. It type-checks the pinned section 4 surface; nothing here is run for its
// results except the final smoke test.
import CoreGraphics
import Foundation
import Testing
import CobaltKit

@MainActor
private func touchPipeline(_ p: Pipeline) {
    _ = p.id
    _ = Pipeline.frameCount
    let _: PipelineState = p.state
    let _: PipelineInput? = p.input
    let _: MediaInfo? = p.media
    let _: Rail = p.rail
    let _: [Frame?] = p.frames
    let _: TrimRange = p.trim
    let _: Bool = p.trimOverLimit
    let _: Int = p.limitHits
    let _: SharedJob.Origin? = p.origin
    let _: Bool = p.resumedFromShare
    let _: ActionStatus = p.photos
    let _: ActionStatus = p.hosting
    let _: URL? = p.hostedURL
    let _: String? = p.sessionID
    let _: WebpResult? = p.result
    let _: StoredVideo? = p.stored
    let _: Double = p.maxClipSeconds
    let _: Set<Int> = p.litFrames
    // focus flow (CONTRACT-ORBIT.md 2)
    let _: WebpResult? = p.webpResult
    let _: URL? = p.hostedOriginalURL
    let _: Bool = p.canMakeWebp
    let _: Bool = p.canHostOriginal

    let _: (String?) -> Void = p.start(pastedText:)
    let _: (URL) -> Void = p.start(link:)
    let _: (URL) -> Void = p.start(file:)
    let _: (SharedJob) -> Void = p.resume(_:)
    let _: (String, MediaInfo?) -> Void = p.resume(session:media:)
    let _: (PickerItem, PickerAction) -> Void = p.choose(_:_:)
    let _: () -> Void = p.saveAllPickerItemsToPhotos
    let _: (TrimHandle, Double) -> Void = p.dragTrim(_:to:)
    let _: () -> Void = p.endTrimDrag
    let _: (TrimHandle, Double) -> Void = p.nudgeTrim(_:by:)
    let _: () -> Void = p.makeWebp
    let _: () -> Void = p.backToTrim
    let _: () -> Void = p.saveToPhotos
    let _: () -> Void = p.hostOriginal
    let _: () -> Void = p.copyResultLink
    let _: () -> Void = p.cancel
    let _: () -> Void = p.reset

    switch p.state {
    case .idle, .fetching(since: _, waking: _), .uploading(_), .saving(bytes: _, total: _, since: _),
         .reading(developed: _, of: _), .picker(items: _), .image(_), .ready, .rendering(_), .done(_),
         .savedLocally(_), .failed(_):
        break
    }
    switch p.rail.steps.first {
    case .fetch?, .upload?, .save?, .read?, .webp?, .host?, nil: break
    }
    _ = (p.rail.index, p.rail.finished)
    if case .rendering(let r) = p.state {
        switch r {
        case .decoding(done: _, total: _), .packing(since: _), .working(since: _): break
        }
    }
    if case .failed(let f) = p.state {
        _ = f.keepsTrim
        switch f {
        case .noLink, .tooLarge(limit: _), .fetchFailed(code: _), .unsupported, .serverBusy, .renderBusy,
             .renderLost, .expired, .keyMissing, .keyInvalid, .unreachable, .server(code: _): break
        }
    }
    if let f = p.frames.compactMap({ $0 }).first { _ = (f.index, f.image) }
    _ = (p.trim.start, p.trim.end, p.trim.length)
}

@MainActor
private func touchModels(_ app: AppModel) async throws {
    let _: Settings = app.settings
    let _: OfflineStore = app.store
    let _: SharedJobStore = app.jobs
    let _: LibraryModel = app.library
    // re-download of an evicted offline item (CONTRACT-LIVE.md 4.2)
    let _: [String: TransferProgress] = app.library.redownloads
    let _: (StoredVideo) async throws -> StoredVideo = app.library.redownload(_:)
    let _: String? = LiveRunReply(pushing: false, started: false, reason: nil).reason
    let _: Capabilities = app.capabilities
    let _: Bool = app.isCheckingServer
    let _: Pipeline = app.pipeline
    app.selectedTab = .library
    for tab in AppTab.allCases { _ = tab.rawValue }
    let summary: ServerSummary = app.serverSummary
    _ = (summary.host, summary.kind, summary.version, summary.features, summary.key, summary.keyName)
    await app.refreshServer()
    app.open(URL(string: "cobalt-apple://open")!)
    await app.pickUpSharedJobs()
    await app.trimNewWebp(from: app.library.posts[0])
    try await app.setServer(pasted: "https://example.com")
    try await app.setAPIKey(pasted: "x")
    _ = AppModel.live
    _ = AppModel.preview(.happy)
    for s in PreviewScenario.allCases { _ = s.rawValue }

    let l = app.library
    let _: [LibraryPost] = l.posts
    let _: (Int, Int, Bool, PipelineFailure?, Bool) = (l.postCount, l.fileCount, l.isLoading, l.failure, l.hasMore)
    l.expandedPostID = "x"
    await l.refresh()
    await l.loadMore()
    let file = l.posts[0].files[0]
    l.copyLink(file)
    try await l.save(file)
    let _: URL = try await l.localCopy(file)
    let _: URL = try await l.host(file)
    try await l.delete(file)
    let _: LibraryFile.Role = file.role
    _ = (file.id, file.kind, file.source, file.name, file.url, file.contentType, file.bytes, file.width,
         file.height, file.duration, file.createdAt, file.mediaName, file.deletable)
    let post = l.posts[0]
    _ = (post.id, post.service, post.link, post.title, post.duration, post.width, post.height, post.createdAt,
         post.session?.id, post.session?.status, post.session?.expiresAt, post.session?.sourceURL, post.ref, post.pills)
    for pill in LibraryPill.allCases { _ = pill }

    let s = app.settings
    _ = (s.serverURL, s.hasAPIKey, s.webpQuality, s.webpWidth, s.keepVideosOnDevice, s.haptics, s.apiKey())
    s.webpQuality = .low; s.webpWidth = 320; s.keepVideosOnDevice = false; s.haptics = false
    try s.setAPIKey(pasted: "x")
    s.clearAPIKey()
    try s.setServer(pasted: "x")
    s.resetServer()
    _ = Settings.defaultServer
    _ = Settings.apiKey(in: Keychain(accessGroup: nil), forServer: Settings.defaultServer)         // addition: key bound to its server
    _ = PipelineFailure.renderPhasePrefix                                                           // addition: phase carried by .server codes
    _ = Settings.shared
    let _: Settings = Settings(defaults: .standard, keychain: Keychain(accessGroup: nil))
    _ = Keychain.shared
    let k = Keychain(service: "x", accessGroup: nil)
    _ = k.string(for: "a")
    try k.set("v", for: "a")

    let st = app.store
    let _: [StoredVideo] = st.videos
    let _: StorageUsage = st.usage
    let _: [StoredVideo] = st.latest(3)
    let v = st.videos[0]
    _ = (v.id, v.kind, v.fileURL, v.posterURL, v.name, v.duration, v.width, v.height, v.bytes, v.sessionID,
         v.link, v.remoteURL, v.createdAt)
    _ = st.inboxURL(for: "a")
    await st.remove("a")
    await st.dropFilesKeepingPosters()
    await st.reload()
    // additions: the offline limit (CONTRACT-LIVE.md section 4)
    let _: Int64? = st.limitBytes
    await st.setLimit(StorageLimit.gb5.bytes)
    let _: Int64 = st.bytesToFree(for: nil)
    await st.clearAll()
    let _: StoredVideo = try await st.attach(file: URL(fileURLWithPath: "/tmp/x"), to: "a", move: false)
    for l in StorageLimit.allCases { _ = (l.rawValue, l.bytes) }
    s.storageLimit = .gb10
    let _: StorageLimit = s.storageLimit
    let _: String = Format.bytes(5_000_000_000)
    _ = OfflineStore.shared
    _ = OfflineStore(root: URL(fileURLWithPath: "/tmp"))

    let jobs = app.jobs
    _ = SharedJobStore(directory: URL(fileURLWithPath: "/tmp"))
    _ = SharedJobStore.shared
    let _: [SharedJob] = jobs.all()
    let _: SharedJob? = jobs.nextHandoff()
    let _: SharedJob? = jobs.nextHandoff(now: Date(), maxAge: SharedJobStore.handoffMaxAge)      // additions: review fixes
    if let j = jobs.all().first {
        jobs.upsert(j)
        jobs.remove(j.id)
        _ = (j.id, j.origin, j.link, j.sessionID, j.media, j.trim, j.stage, j.wantsTrim, j.pickedUp, j.updatedAt)
        switch j.stage {
        case .saving, .uploadInterrupted(localFile: _), .ready, .rendering(job: _), .done(_), .failed(code: _): break
        }
    }

    let c = app.capabilities
    _ = (c.kind, c.cobaltVersion, c.studio, c.upload, c.library, c.saveProgress, c.renderProgress,
         c.finishesUnpolled, c.mediaBaseURL, c.key, c.keyName)
    let lim: Capabilities.Limits = c.limits
    _ = (lim.maxWebpSeconds, lim.minWebpSeconds, lim.webpWidths, lim.renderFPS, lim.maxUploadBytes,
         lim.maxSourceBytes, lim.sessionTTL)
    _ = Capabilities.Limits.fork
    _ = Capabilities.unknown
    let _: Bool = c.livePush                                                // addition: live_activity_push
    switch app.liveStatus {                                                  // addition: the Settings row
    case .pushed, .localOnly, .off, .unavailable: break
    }
    let _: LiveEnvironment? = LiveEnvironment.current
    _ = LiveContentState.samples["done"]?.isTerminal
    for stage in LiveContentState.Stage.allCases { _ = stage.rawValue }
    var live = LiveContentState(stage: .saving, rail: 1, since: 1, waking: false, packing: false)
    live.bytes = 1; live.total = 2; live.framesDone = 1; live.framesTotal = 2; live.title = "t"; live.duration = 1
    live.resultURL = "u"; live.resultBytes = 1; live.resultWidth = 1; live.resultHeight = 1; live.resultSeconds = 1
    live.failure = "f"; live.code = "c"
    _ = (live.stage, live.rail, live.since, live.waking, live.packing)
}

private func touchClient(_ client: any CobaltClient) async throws {
    _ = HTTPCobaltClient(baseURL: URL(string: "https://x")!, apiKey: { nil })
    _ = HTTPCobaltClient(baseURL: URL(string: "https://x")!, apiKey: { nil }, session: .shared)
    _ = PreviewClient()
    _ = PreviewClient(scenario: .coldStart, timeScale: 5)
    let u = URL(string: "https://x.com/i/status/1")!
    _ = client.baseURL
    _ = await client.capabilities()
    switch try await client.resolve(u) {
    case .file(url: _, filename: _), .picker(items: _, audio: _), .localProcessing: break
    }
    let created: StudioCreated = try await client.createStudio(link: u)
    _ = (created.id, created.pageURL)
    let up: UploadResult = try await client.upload(file: u, name: "a", contentType: "b", progress: { (p: TransferProgress) in _ = (p.bytes, p.total) })
    _ = (up.sessionID, up.item, up.studioErrorCode)
    let s: StudioSession = try await client.session("a", wait: 1)
    _ = (s.id, s.status, s.link, s.service, s.title, s.duration, s.width, s.height, s.bytes, s.createdAt,
         s.expiresAt, s.errorCode, s.renders, s.step, s.stepBytes, s.stepTotal, s.waking)
    _ = client.sourceURL(session: "a")
    _ = try await client.render(session: "a", RenderRequestProbe.make())
    switch try await client.renderStatus(session: "a", job: "b", wait: 1) {
    case .pending(phase: _, framesDone: _, framesTotal: _), .success(_), .failed(code: _): break
    }
    let h: HostedFile = try await client.publish(session: "a")
    _ = (h.url, h.bytes, h.contentType, h.itemID)
    _ = try await client.publish(item: "a")
    _ = try await client.openStudio(item: "a")
    let page: LibraryPage = try await client.library(cursor: nil, limit: 20)
    _ = (page.posts, page.postCount, page.fileCount, page.publicBytes, page.privateBytes, page.next)
    try await client.deleteMedia(name: "a")
    // additions: Live Activities (CONTRACT-LIVE.md section 2.2)
    try await client.registerLiveStartToken("ab", environment: .sandbox)
    let reg = LiveRunRegistration(
        run: UUID(), environment: .production, updateToken: nil, session: nil, start: true,
        attributes: LiveRunAttributes(run: UUID(), input: "link", service: "x", ref: "1", origin: "share"),
        state: LiveContentState(stage: .fetching, rail: 0, since: 0))
    _ = (reg.run, reg.environment, reg.updateToken, reg.session, reg.start, reg.attributes, reg.state)
    let reply: LiveRunReply = try await client.registerLiveRun(reg)
    _ = (reply.pushing, reply.started)
    try await client.relayLiveState(run: reg.run, reg.state)
    try await client.endLiveRun(reg.run)
    let selftest: LiveSelftest = try await client.liveSelftest()
    _ = (selftest.configured, selftest.transport, selftest.host, selftest.jwt, selftest.apnsStatus, selftest.apnsReason, selftest.isHealthy)
    _ = try await client.download(.open(u), to: u, progress: { _ in })
    _ = try await client.download(.studioSource(session: "a"), to: u, progress: { _ in })
    _ = try await client.download(.libraryItem(id: "a"), to: u, progress: { _ in })
}

/// Values the app never constructs (only the models do): stand-ins for type-checking field access.
private func never<T>() -> T { fatalError("type-check only") }

private enum RenderRequestProbe {
    static func make() -> RenderRequest { never() }
}

private func touchValues() {
    let info = LinkInfo(URL(string: "https://x.com/i/status/1")!)
    _ = (info?.url, info?.service, info?.ref)
    _ = LinkInfo.firstLink(in: "x")
    _ = Format.bytes(1); _ = Format.seconds(1); _ = Format.timecode(1); _ = Format.size(1, 1)
    _ = Format.when(Date(), now: Date())
    let p: PickerItem = never()
    _ = (p.id, p.type, p.url, p.thumb, p.canWebp)
    for t in [MediaType.photo, .video, .gif] { _ = t }
    for q in WebpQuality.allCases { _ = q.rawValue }
    let m: MediaInfo = never()
    _ = (m.name, m.duration, m.width, m.height, m.bytes, m.isImage)
    let w: WebpResult = never()
    _ = (w.job, w.url, w.bytes, w.width, w.height, w.seconds)
    let r: StudioRender = never()
    _ = (r.id, r.url, r.start, r.length, r.width, r.quality, r.bytes, r.createdAt)
    let rr: RenderRequest = never()
    _ = (rr.start, rr.length, rr.width, rr.quality)
    for k in [KeyState.valid, .invalid, .missing, .unknown] { _ = k }
    for k in [ServerKind.fork, .legacyFork, .plainCobalt, .notCobalt, .unreachable] { _ = k }
    let e: CobaltError = .api(code: "x", httpStatus: 1)
    switch e {
    case .api(code: _, httpStatus: _), .network(_), .invalidResponse(httpStatus: _), .noAPIKey, .tooLarge(limit: _), .cancelled: break
    }
    _ = KeyInputError.notAKey
    _ = KeyInputError.couldNotSave                                                   // addition: a valid key the device would not store
    _ = ServerInputError.notAURL
    for s in [SessionStatus.saving, .ready, .error] { _ = s }
    for s in [SaveStep.fetching, .reading, .storing] { _ = s }
    for s in [RenderPhase.fetching, .decode, .pack] { _ = s }
    for s in [PickerAction.save, .webp] { _ = s }
    let _: (StoredVideo.Kind, SharedJob.Origin, LibraryFile.Kind, LibraryFile.Source) = (.original, .app, .public, .host)
    // memberwise inits for unit-level SwiftUI previews
    let _: Rail = Rail(steps: [.fetch, .save, .read, .webp], index: 1, finished: false)
    let _: TrimRange = TrimRange(start: 0, end: 10)
    let _: PickerItem = PickerItem(id: 0, type: .video, url: URL(string: "https://a.b/v.mp4")!, thumb: nil)
    let _: PickerItem = PickerItem(id: 1, type: .photo, url: URL(string: "https://a.b/p.jpg")!)
}

#if os(iOS)
@MainActor
private func touchShare(_ m: ShareModel) async {
    _ = m.pipeline
    _ = m.isLong
    let _: Capabilities = m.capabilities
    let _: Bool = m.webpAvailable
    switch await m.close() {
    case .dismissed, .continuesInBackground: break
    }
    await m.handOffToApp()
}
#endif

@MainActor
struct PublicAPISmokeTests {
    @Test func previewModelsAreReachableThroughThePublicSurface() async throws {
        let app = AppModel.preview(.happy)
        touchPipeline(app.pipeline)
        #expect(app.pipeline.state == .idle)
        #expect(app.library.posts.count == 6)
        #expect(app.capabilities.kind == .fork)
        // the functions above are type-checked, not run: they would call the network
        _ = touchModels
        _ = touchClient
        _ = touchValues
    }
}

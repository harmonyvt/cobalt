import CoreGraphics
import Foundation
import Observation

/// One run of "fetch|upload → save → read → webp". UI only renders `state` (plus the few
/// published fields); everything that talks to the server lives in `PipelineFlows.swift`.
@MainActor @Observable
public final class Pipeline: Identifiable {
    public nonisolated let id: UUID
    public static let frameCount = 9

    /// Changes whenever a new run begins (a link, a file, a resume, a library reopen) and on
    /// `reset()`: lets the UI snapshot "the run I'm closing" before `detach()`.
    public internal(set) var runID = UUID()

    public internal(set) var state: PipelineState = .idle
    public internal(set) var input: PipelineInput?
    public internal(set) var media: MediaInfo?
    public internal(set) var frames: [Frame?] = Array(repeating: nil, count: Pipeline.frameCount)
    public internal(set) var trim: TrimRange = TrimRange(start: 0, end: 10)
    public internal(set) var trimOverLimit: Bool = false      // dragging past the limit: bracket turns red
    /// The spatial crop the webp will be made with (CONTRACT-ORBIT 2d), nil = the whole frame. Per
    /// run: it survives "back to trim" and a failed render, and goes with a new run.
    public internal(set) var crop: CropRect?
    public internal(set) var limitHits: Int = 0               // +1 per hit; drive .sensoryFeedback
    public internal(set) var photos: ActionStatus = .idle     // "save to photos"
    /// What "save to photos" is doing while `photos == .working`: fetching the original (with real
    /// byte counts), then handing it to Photos.
    public internal(set) var photosStep: PhotosStep = .idle
    /// Why "save to photos" failed, when it did (`photos == .failed`).
    public var photosFailure: PipelineFailure? {
        if case .failed(let f) = photos { return f }
        return nil
    }
    /// Where this run's original is in the owner's Photos (CONTRACT-SYNC.md decision 12): drives the
    /// "in your cobalt album" / "in your photos" button states.
    public var photosPlacement: PhotosPlacement {
        if let previewPlacement { return previewPlacement }
        _ = photosTick                                   // a manual save in this process redraws the button
        guard let key = photosKey else { return .none }
        return ctx.photosPlacement(forKey: key)
    }
    /// The ledger key of this run's original: the stored copy's, else the session's.
    var photosKey: String? {
        if let stored { return PhotosKey.of(stored) }
        if let sid = sessionID { return PhotosKey.original(session: sid) }
        return nil
    }
    /// Bumped when this run's own "save to photos" records itself.
    var photosTick = 0
    /// `#Preview`s only: pins `photosPlacement` to a state. Nil goes back to the real answer.
    public func previewPhotosPlacement(_ placement: PhotosPlacement?) { previewPlacement = placement }
    var previewPlacement: PhotosPlacement?
    /// The original's download into the device (keep-on-device, or the share sheet's own copy for
    /// the filmstrip and "save to photos"), while it is under way.
    public internal(set) var keepProgress: TransferProgress?
    /// The filmstrip could not be read at all, from the server or from a local copy. The run goes on
    /// without it; UI may say so instead of showing an empty strip.
    public internal(set) var framesFailed = false
    public internal(set) var hosting: ActionStatus = .idle    // "host original" / "host as-is"
    public internal(set) var hostedURL: URL?
    public internal(set) var sessionID: String? {
        didSet {
            guard sessionID != oldValue else { return }
            ctx.live?.sessionChanged(self)
            jobEvent?(self, .session)
        }
    }
    /// Why this run is waiting (CONTRACT-PARALLEL.md 3.2): its place in the server's line or in the device's, or "the
    /// server is busy with something not in this line". Nil when it is not waiting. The state stays `.fetching` (a
    /// save) or `.rendering(.working)` (a webp) meanwhile; this says why.
    public internal(set) var line: LinePosition? {
        didSet { if line != oldValue { jobEvent?(self, .line) } }
    }
    public internal(set) var result: WebpResult?
    public internal(set) var stored: StoredVideo?             // the local original, once downloaded
    /// Where this run came from when it was resumed from a `SharedJob`: `.shareExtension` for a
    /// handoff from the share sheet, `.app` for the app's own run followed after a relaunch; nil
    /// for a run started in this pipeline. Drives "still making the webp you started in the share
    /// sheet…" and "finished while the sheet was closed."
    public internal(set) var origin: SharedJob.Origin?
    /// The run came from a share-sheet "trim in cobalt" job: the focus card opens on the trim
    /// timeline instead of the plain ready card. One-shot, read with `takeTrimRequest()`.
    public internal(set) var opensOnTrim: Bool = false
    /// `origin == .shareExtension`.
    public var resumedFromShare: Bool { origin == .shareExtension }

    /// The title the owner typed for this run (CONTRACT-LIBRARY2 decision 4); nil = the default shows.
    /// `setTitle(_:)` sets it, at any state; it goes with the run (`begin`, `reset()`).
    public internal(set) var runTitle: String?

    /// The media this run adds to ("another webp", the library's "make a webp"): its webp joins that
    /// media instead of being placed by session (CONTRACT-MEDIA 4.3). Set by `AppModel.makeWebp(for:)`
    /// right after the run begins; cleared with the run.
    public internal(set) var targetMediaID: String?

    /// The run's media once anything is stored: the target when the store has it, else the media of
    /// this run's stored original, else of its session. Nil until then. Reads the store, so a view
    /// that asks redraws when the store changes.
    public var mediaID: String? {
        if let target = targetMediaID, ctx.store.media(id: target) != nil { return target }
        if let stored, let m = ctx.store.media(containing: stored.id) { return m.id }
        if let sid = sessionID, let m = ctx.store.media(session: sid) { return m.id }
        return nil
    }

    @ObservationIgnored let ctx: PipelineContext
    @ObservationIgnored var runToken = UUID()
    @ObservationIgnored var mainTask: Task<Void, Never>?
    @ObservationIgnored var sideTasks: [Task<Void, Never>] = []
    @ObservationIgnored var lastRailIndex = 0
    @ObservationIgnored var stateLog: [PipelineState] = [.idle]
    @ObservationIgnored var errorPhase: ErrorPhase = .saving
    @ObservationIgnored var runStart = Date()
    @ObservationIgnored var uploadedItemID: String?
    /// The library file the run's post is anchored on, once known: the upload's item, a reopened post's
    /// first file, or the item a resumed upload session names. `PATCH /library/items/<id>/post` goes here.
    @ObservationIgnored var titleItemID: String?
    /// `runTitle` changed and the server has not been told yet (it waits for `titleItemID`).
    @ObservationIgnored var titleUnsent = false
    /// The server calls for titles, one after another, so the last title typed is the last one sent.
    @ObservationIgnored var titleChain: Task<Void, Never>?
    /// Set by `adoptPhotosAsset`, taken by the next `start(file:)` of that file.
    @ObservationIgnored var pendingPhotosAsset: (path: String, id: String)?
    @ObservationIgnored var renderJobID: String?
    @ObservationIgnored var localFile: URL?
    /// Files this run downloaded only to read frames from or to add to Photos: removed with the run.
    @ObservationIgnored var temporaryFiles: [URL] = []
    @ObservationIgnored var activeHandle: TrimHandle?
    /// The `SharedJob` this run keeps current while it has server work in flight, so a relaunched
    /// app can follow it (only when `ctx.recordsJobs`).
    @ObservationIgnored var jobRecordID = UUID()
    /// The one id of this run for everything outside the pipeline (CONTRACT-LIVE.md 2.1): the Live
    /// Activity, the `SharedJob`, the server's run record. A fresh run's is its `jobRecordID`; a
    /// run that takes over a share-sheet job uses the job's id; the share sheet's pipeline starts
    /// with `ShareCore.jobID`.
    @ObservationIgnored var liveRunID = UUID()
    /// The id the next `begin` adopts (set once, by `ShareCore`, before the pipeline starts).
    @ObservationIgnored var nextLiveRunID: UUID?
    /// A share-extension job this run took over: removed from the store when the run settles.
    @ObservationIgnored var takenOverJobID: UUID?
    /// Store entries this run reads frames from or plays: the offline limit never evicts them while
    /// the run lives (released when the next run begins).
    @ObservationIgnored var pinnedStoreIDs: Set<String> = []

    // In-flight server calls that outlive the flow that started them, so `detach()` can hand them
    // to a background run instead of dropping them (see `PipelineDetach.swift`).
    /// `POST /render`, until it answers with the job id.
    @ObservationIgnored var renderRequest: Task<String, Error>?
    /// `POST /studio/<id>/publish` (or the image publish) of "host original".
    @ObservationIgnored var hostRequest: Task<HostedFile, Error>?
    /// The keep-original download into the store.
    @ObservationIgnored var keepRequest: Task<StoredVideo?, Never>?
    /// When the current render began (the work card's clock).
    @ObservationIgnored var renderStart: Date?
    /// The render this run sent (start, length, crop, quality, width): stored on the finished webp
    /// as its `clip`. Nil for a render this process did not start (a resumed job).
    @ObservationIgnored var lastRenderRequest: RenderRequest?
    /// This pipeline is a hidden background run carried on after `detach()`; it never shows.
    @ObservationIgnored var isDetached = false
    @ObservationIgnored var detachedCoordinator: Task<Void, Never>?
    @ObservationIgnored var detachedRendering = false
    @ObservationIgnored var detachedSettled = false

    // The job queue (Jobs/JobQueue.swift). A pipeline outside a queue (the share extension's, a hidden detached run)
    // never sets any of these.
    /// The queue's job id for this pipeline (stable across the runs it carries); the line's key.
    @ObservationIgnored var jobKey: UUID?
    /// What the caller of `JobQueue.add` asked: the title, the visibility.
    @ObservationIgnored var jobOptions = JobOptions()
    /// Created by `JobQueue.add`: takes turns in the device line when the server has none, and waits out a busy server
    /// (10 minutes) instead of failing at 60 s. The pipeline the owner started by hand keeps today's flow.
    @ObservationIgnored var takesPartInDeviceLine = false
    /// A batch, a drop of several links, a Shortcut: sent straight to the server's line, no "checking the link" first.
    @ObservationIgnored var skipsLinkCheck = false
    /// The queue's ear: state, session, line and acceptance changes.
    @ObservationIgnored var jobEvent: (@MainActor (Pipeline, PipelineJobEvent) -> Void)?
    /// The server has this run (`201`/`202`), for `JobQueue.accepted`.
    @ObservationIgnored var acceptance: JobAcceptance?

    /// The key this run goes by in the line.
    var lineKey: UUID { jobKey ?? liveRunID }

    init(context: PipelineContext) {
        self.id = UUID()
        self.ctx = context
        self.runStart = context.clock.now()
    }

    // MARK: - Derived

    /// `capabilities.limits.maxWebpSeconds`
    public var maxClipSeconds: Double { ctx.capabilities.limits.maxWebpSeconds }

    public var rail: Rail {
        let plain = ctx.capabilities.kind == .plainCobalt
        let isFile: Bool
        if case .file = input { isFile = true } else { isFile = false }
        let isImage: Bool
        if case .image = state { isImage = true } else { isImage = media?.isImage == true }
        let first: Rail.Step = isFile ? .upload : .fetch
        let steps: [Rail.Step] = plain ? [first, .save, .read] : [first, .save, .read, isImage ? .host : .webp]
        let finished: Bool
        switch state {
        case .done, .savedLocally: finished = true
        default: finished = false
        }
        return Rail(steps: steps, index: min(lastRailIndex, steps.count - 1), finished: finished)
    }

    /// Frames inside the bracket already decoded (render lights).
    public var litFrames: Set<Int> {
        let ratio: Double
        switch state {
        case .rendering(.decoding(let done, let total)): ratio = total > 0 ? Double(done) / Double(total) : 0
        case .rendering(.packing), .done: ratio = 1
        default: return []
        }
        let d = media?.duration ?? maxClipSeconds
        guard d > 0 else { return [] }
        let doneTo = trim.start + ratio * trim.length
        var lit: Set<Int> = []
        for i in 0..<Pipeline.frameCount {
            let f0 = Double(i) / Double(Pipeline.frameCount) * d
            let f1 = Double(i + 1) / Double(Pipeline.frameCount) * d
            if f1 > trim.start && f0 < trim.end && f0 < doneTo { lit.insert(i) }
        }
        return lit
    }

    // MARK: - State plumbing

    func setState(_ requested: PipelineState) {
        var new = requested
        // "waking server" is sticky within one fetch: once shown (the server said so, or a request ran
        // long), a later poll that says `waking: false` must not flip it back to "fetching from x".
        // It ends when the state leaves `.fetching` (the step changed or the fetch completed).
        if case .fetching(let since, false) = requested, case .fetching(let current, true) = state, current == since {
            new = .fetching(since: since, waking: true)
        }
        guard new != state else { return }
        logTransition(to: new)
        state = new
        stateLog.append(new)
        defer { ctx.continued?.pipelineChanged(self) }
        switch new {
        case .idle, .fetching, .uploading, .picker: lastRailIndex = 0
        case .saving: lastRailIndex = 1
        case .reading, .savedLocally: lastRailIndex = 2
        case .image, .ready, .rendering, .done: lastRailIndex = 3
        case .failed: break
        }
        switch new {
        case .idle, .picker, .image, .ready, .done, .savedLocally, .failed: settleJobRecords()
        default: break
        }
        ctx.live?.stateChanged(self)
        jobEvent?(self, .state)
    }

    /// The run on screen finished and the owner went on with it (back to the trim, a retry): the
    /// next steps are a new run for the Live Activity and the server, which keep a finished one
    /// final.
    func renewRun() {
        let id = UUID()
        jobRecordID = id
        liveRunID = id
    }

    // MARK: - Store pins

    func pinStored(_ id: String) {
        guard pinnedStoreIDs.insert(id).inserted else { return }
        ctx.store.pin(id)
    }

    func releaseStorePins() {
        for id in pinnedStoreIDs { ctx.store.unpin(id) }
        pinnedStoreIDs = []
    }

    // MARK: - Job records (app relaunch, share handoff)

    /// Keeps this run's `SharedJob` (origin `.app`) current while the server works for it.
    func recordJob(_ stage: SharedJob.Stage) {
        guard ctx.recordsJobs, sessionID != nil else { return }
        var link: URL?
        if case .link(let info) = input { link = info.url }
        ctx.jobs.upsert(SharedJob(
            id: jobRecordID, origin: .app, link: link, sessionID: sessionID, media: media, trim: trim,
            stage: stage, wantsTrim: false, pickedUp: false, updatedAt: ctx.clock.now(), pendingTitle: runTitle))
    }

    /// The run no longer has anything in flight: its own record and a taken-over handoff go.
    func settleJobRecords() {
        if ctx.recordsJobs { ctx.jobs.remove(jobRecordID) }
        if let id = takenOverJobID {
            ctx.jobs.remove(id)
            takenOverJobID = nil
        }
    }

    func fail(_ failure: PipelineFailure) {
        if failure == .keyInvalid { ctx.keyRejected?() }
        setState(.failed(failure))
    }

    /// Anything a flow throws ends up here. Cancellation says nothing.
    func handle(_ error: Error) {
        guard let f = pipelineFailure(from: error, during: errorPhase, limits: ctx.capabilities.limits) else { return }
        logPipelineError(error, failure: f)
        fail(f)
    }

    func cancelRunning() {
        runToken = UUID()
        mainTask?.cancel()
        mainTask = nil
        for t in sideTasks { t.cancel() }
        sideTasks = []
        renderRequest?.cancel()
        renderRequest = nil
        hostRequest?.cancel()
        hostRequest = nil
        keepRequest?.cancel()
        keepRequest = nil
        // A cancelled side job never reports back (its run token is gone): leave nothing stuck on
        // "working", so the owner can ask again.
        if hosting == .working { hosting = .idle }
        if photos == .working { photos = .idle; photosStep = .idle }
        keepProgress = nil
        ctx.continued?.pipelineChanged(self)
    }

    /// Removes the copies of the original this run fetched only for itself (the stored original,
    /// if any, is never touched).
    func removeTemporaryFiles() {
        let keep = stored?.fileURL
        for url in temporaryFiles where url != keep { try? FileManager.default.removeItem(at: url) }
        temporaryFiles = []
    }

    /// Starts a new run: everything from the last one is dropped.
    func begin(input: PipelineInput?) {
        cancelRunning()
        removeTemporaryFiles()
        releaseStorePins()
        settleJobRecords()
        runID = UUID()
        renderStart = nil
        // A run a queue job asked for (`nextLiveRunID`) has one id everywhere: its record, its Live Activity and the job.
        jobRecordID = nextLiveRunID ?? UUID()
        liveRunID = nextLiveRunID ?? jobRecordID
        nextLiveRunID = nil
        origin = nil
        opensOnTrim = false
        targetMediaID = nil
        lastRenderRequest = nil
        self.input = input
        media = nil
        frames = Array(repeating: nil, count: Pipeline.frameCount)
        trim = TrimRange(start: 0, end: maxClipSeconds)
        trimOverLimit = false
        crop = nil
        photos = .idle
        photosStep = .idle
        keepProgress = nil
        framesFailed = false
        hosting = .idle
        hostedURL = nil
        sessionID = nil
        line = nil
        acceptance = nil
        result = nil
        stored = nil
        uploadedItemID = nil
        titleItemID = nil
        titleUnsent = false
        runTitle = nil
        renderJobID = nil
        localFile = nil
        activeHandle = nil
        errorPhase = .saving
        runStart = ctx.clock.now()
        lastRailIndex = 0
        ctx.live?.runBegan(self)
        flushTitleQueue()                        // titles that failed to send go out with the next run
    }

    /// The flow that owns the visible state. A newer flow cancels the one before it.
    func launch(_ body: @escaping @MainActor (Pipeline) async throws -> Void) {
        mainTask?.cancel()
        let token = runToken
        mainTask = Task { [weak self] in
            // Cancelled (or replaced) before it got to run: the body must not touch a run it no
            // longer belongs to (a `reset()` right after a start).
            guard let self, !Task.isCancelled, self.runToken == token else { return }
            do { try await body(self) }
            catch {
                guard self.runToken == token, !Task.isCancelled else { return }
                self.handle(error)
            }
        }
    }

    /// A side job (keeping the original, saving to photos, hosting): dies with the run, never
    /// touches `state` unless the body does.
    func spawn(_ body: @escaping @MainActor (Pipeline) async -> Void) {
        let token = runToken
        let task = Task { [weak self] in
            guard let self, self.runToken == token else { return }
            await body(self)
        }
        sideTasks.append(task)
    }

    // MARK: - Public: start

    public func start(pastedText: String?) {
        guard let text = pastedText, let url = LinkInfo.firstLink(in: text) else {
            begin(input: nil)
            setState(.failed(.noLink))
            return
        }
        start(link: url)
    }

    public func start(link: URL) {
        guard let info = LinkInfo(link) else {
            begin(input: nil)
            setState(.failed(.noLink))
            return
        }
        begin(input: .link(info))
        let skipCheck = skipsLinkCheck
        skipsLinkCheck = false                                    // one-shot: a later run on this pipeline checks the link
        setState(.fetching(since: runStart, waking: false))
        if let title = jobOptions.title { applyTitle(title) }     // sent with the create as well (server line)
        launch { try await $0.runLink(info, skipCheck: skipCheck) }
    }

    /// The file the owner picked in the Photos picker came from the library asset `localIdentifier`
    /// (`PhotosPickerItem.itemIdentifier`): call it right before `start(file:)` with the same URL. The
    /// uploaded original then goes into the cobalt album as THAT asset, not as a second copy
    /// (`PhotosSync.adoptExistingAsset`). One-shot: only the next `start(file:)` of that very file
    /// takes it. A nil identifier (a picker made without the shared photo library) does nothing.
    public func adoptPhotosAsset(_ localIdentifier: String?, forFile url: URL) {
        pendingPhotosAsset = localIdentifier.flatMap { $0.isEmpty ? nil : (url.standardizedFileURL.path, $0) }
    }

    /// `file` is security-scoped; it is copied into the store's inbox first.
    public func start(file url: URL) {
        begin(input: nil)
        var file: IntakeFile
        do { file = try ctx.intake.inspect(url) }
        catch {
            pendingPhotosAsset = nil
            setState(.failed(.server(code: "error.app.file_unreadable")))
            return
        }
        if let pending = pendingPhotosAsset, pending.path == url.standardizedFileURL.path { file.photosAssetID = pending.id }
        pendingPhotosAsset = nil
        input = .file(name: file.name, bytes: file.bytes, contentType: file.contentType)
        let caps = ctx.capabilities
        switch caps.kind {
        case .plainCobalt, .legacyFork:
            setState(.failed(.unsupported)); return
        case .fork where !caps.upload:
            setState(.failed(.unsupported)); return
        case .fork where caps.limits.maxUploadBytes > 0 && file.bytes > caps.limits.maxUploadBytes:
            setState(.failed(.tooLarge(limit: caps.limits.maxUploadBytes))); return
        default: break
        }
        setState(.uploading(TransferProgress(bytes: 0, total: file.bytes)))
        if let title = jobOptions.title { applyTitle(title) }
        launch { try await $0.runFile(file) }
    }

    public func resume(_ job: SharedJob) {
        resumeJob(job)
    }

    /// Whether the focus card should open on the trim, once: returns `opensOnTrim` and clears it, so
    /// a later redraw (or "back to trim") does not reopen it.
    @discardableResult
    public func takeTrimRequest() -> Bool {
        let wanted = opensOnTrim
        if wanted { opensOnTrim = false }
        return wanted
    }

    /// Library "trim a new webp": the session is open (or was just reopened).
    public func resume(session id: String, media: MediaInfo?) {
        begin(input: nil)
        sessionID = id
        self.media = media
        setState(.reading(developed: 0, of: Pipeline.frameCount))
        launch { p in
            let m = try await p.mediaForSession(id, known: media)
            try await p.develop(m, from: p.sourceInput(session: id), readyFirst: true)
        }
    }

    // MARK: - Public: picker

    public func choose(_ item: PickerItem, _ action: PickerAction) {
        guard case .picker = state else { return }
        switch action {
        case .save: savePickerItems([item])
        case .webp: convertPickerItem(item)
        }
    }

    public func saveAllPickerItemsToPhotos() {
        guard case .picker(let items) = state else { return }
        savePickerItems(items)
    }

    // MARK: - Public: trim

    public func dragTrim(_ handle: TrimHandle, to seconds: Double) {
        guard case .ready = state else { return }
        activeHandle = handle
        let result = TrimMath.drag(handle, to: seconds, from: trim, duration: clipDuration, limit: maxClipSeconds)
        trim = result.range
        if result.over && !trimOverLimit { limitHits += 1 }
        trimOverLimit = result.over
    }

    /// Springs back inside the limit: the moved handle snaps to exactly the limit from the other.
    public func endTrimDrag() {
        defer { activeHandle = nil }
        guard case .ready = state else { return }
        trim = TrimMath.release(trim, moved: activeHandle, limit: maxClipSeconds)
        trimOverLimit = false
    }

    /// ±0.1 for arrow keys / I-O.
    public func nudgeTrim(_ handle: TrimHandle, by seconds: Double) {
        guard case .ready = state else { return }
        let result = TrimMath.nudge(handle, by: seconds, from: trim, duration: clipDuration, limit: maxClipSeconds)
        trim = result.range
        if result.hitLimit { limitHits += 1 }
    }

    // MARK: - Public: crop

    /// Sets (or, with nil or the whole frame, clears) the crop. Kept inside the frame and at least
    /// 64 px each way when the source size is known.
    public func setCrop(_ rect: CropRect?) {
        guard let rect, !rect.isFull else { crop = nil; return }
        let clamped = rect.clamped(in: sourceSize)
        crop = clamped.isFull ? nil : clamped
    }

    /// The source's pixel size in display orientation, when known.
    public var sourceSize: CGSize? {
        guard let w = media?.width, let h = media?.height, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// The webp's expected pixel size at `width` (the setting): the crop (or the whole frame), at
    /// most `width` wide, keeping the crop's aspect, rounded to even like the server. Nil until the
    /// source size is known. The trim does not change it.
    public func outputSize(width: Int) -> CGSize? {
        guard let source = sourceSize else { return nil }
        let region = (crop ?? .full).pixelSize(in: source)
        let outW = min(Double(max(2, width)), Double(region.width))
        let outH = max(2, (Double(region.height) * outW / Double(region.width) / 2).rounded() * 2)
        return CGSize(width: outW, height: outH)
    }

    /// The clip's length for trim math; unknown means "as long as a webp may be".
    var clipDuration: Double { media?.duration ?? maxClipSeconds }

    // MARK: - Public: actions

    public func makeWebp() {
        guard let sid = sessionID else { return }
        switch state {
        case .ready: break
        case .failed(let f) where f.keepsTrim: break
        default: return
        }
        // Moves at once, like `start(link:)`: the work card must not wait for a task to get scheduled.
        errorPhase = .rendering
        let since = ctx.clock.now()
        setState(.rendering(.working(since: since)))
        launch { try await $0.runRender(sid, existingJob: nil, since: since) }
    }

    public func backToTrim() {
        guard sessionID != nil, media != nil else { return }
        switch state {
        case .done, .failed:
            trimOverLimit = false
            setState(.ready)
        default: break
        }
    }

    public func saveToPhotos() {
        guard photos != .working else { return }
        photos = .working
        photosStep = .adding
        ctx.continued?.pipelineChanged(self)
        spawn { p in await p.runSaveToPhotos() }
    }

    /// Also "host as-is" for an image. Once per run: a hosted original is not published again
    /// (a failed attempt may be retried). It never touches `state` or `result`, so it can run before
    /// or after "make webp" and a failure in one leaves the other's result in place.
    public func hostOriginal() {
        guard hosting != .working, hosting != .done else { return }
        hosting = .working
        let request = makeHostRequest()
        hostRequest = request
        spawn { p in await p.finishHostOriginal(request) }
    }

    // MARK: - Focus flow (CONTRACT-ORBIT.md 2): public share and webp, in either order

    /// The animated webp this run made. Same value as `.done`'s payload, and it stays on the run
    /// when the owner goes back to the trim, when a later render fails, and while the original is
    /// being hosted.
    public var webpResult: WebpResult? { result }

    /// The public link of the hosted original (`hostOriginal()`); `hostedURL` under the name the
    /// focus view uses.
    public var hostedOriginalURL: URL? { hostedURL }

    /// "convert to webp" can start: a trimmed clip is waiting (or a render failed and keeps its trim).
    public var canMakeWebp: Bool {
        guard sessionID != nil, ctx.capabilities.studio else { return false }
        switch state {
        case .ready: return true
        case .failed(let f): return f.keepsTrim
        default: return false
        }
    }

    /// "public share" can start: the original is saved (or an image was uploaded) and was not
    /// hosted yet. Available while the webp renders and after it is done.
    public var canHostOriginal: Bool {
        guard hosting != .working, hosting != .done, ctx.capabilities.studio else { return false }
        switch state {
        case .ready, .rendering, .done: return sessionID != nil
        case .failed(let f): return f.keepsTrim && sessionID != nil
        case .image: return uploadedItemID != nil
        default: return false
        }
    }

    public func copyResultLink() {
        guard let r = result else { return }
        ctx.clipboard.copy(r.url.absoluteString)
    }

    /// Stops polling and transfers; server work continues.
    public func cancel() {
        cancelRunning()
    }

    /// Cancel and go back to `.idle`.
    public func reset() {
        begin(input: nil)
        setState(.idle)
    }
}

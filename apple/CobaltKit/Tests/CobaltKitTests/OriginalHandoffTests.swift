import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// The original follows the sheet out (CONTRACT-SYNC.md decision 6): the hand-off at close, the
// background download and its answers, the app's wake and foreground reconcile. The transport is a
// fake; the clock is virtual.

/// Real milliseconds: the delegate's hop onto the main actor is a plain `Task`.
@MainActor
func eventually(_ seconds: Double = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(4))
    }
    return condition()
}

private let notReady = Data(#"{"status":"error","error":{"code":"error.studio.not_ready"}}"#.utf8)
private func bytes(_ n: Int = 3_000) -> Data { Data(repeating: 9, count: n) }
private let sourceBase = URL(string: "https://api.capybaraharmony.com/studio/S1/source")!

// MARK: - The fetcher on its own

@MainActor
struct FetcherRig {
    let h = Harness(.shortClip)
    let transport = FakeBackgroundTransport()
    let pending: PendingOriginals
    let fetcher: OriginalFetcher
    var store: OfflineStore { h.ctx.store }
    var session: FakeBackgroundTransport.Session? { transport.session(fetcher.identifier) }

    init(identifier: String = BackgroundSessionID.app, directory: URL? = nil) throws {
        let dir = try directory ?? makeTempDirectory()
        pending = PendingOriginals(directory: dir)
        fetcher = OriginalFetcher(
            identifier: identifier, transport: transport, pending: pending, store: h.ctx.store, clock: h.clock)
    }

    var media: MediaInfo { MediaInfo(name: "clip", duration: 5, width: 720, height: 1280, bytes: nil, isImage: false) }

    @discardableResult
    func handOff(_ sid: String = "S1", sourceWait: Bool = true, saveReady: Bool = false) -> PendingOriginal {
        fetcher.handOff(
            session: sid, link: URL(string: shortLink), media: media,
            sourceURL: URL(string: "https://api.capybaraharmony.com/studio/\(sid)/source")!, sourceWait: sourceWait, saveReady: saveReady)
    }

    func state(_ sid: String = "S1") -> PendingOriginal.State? { pending.entry(sid)?.state }
}

@MainActor
@Suite(.serialized)
struct OriginalFetcherTests {
    @Test func theIdentifiersAndWhoOwnsThem() {
        #expect(BackgroundSessionID.app == "com.capybaraharmony.cobalt.bg.app")
        let id = UUID()
        #expect(BackgroundSessionID.share(job: id) == "com.capybaraharmony.cobalt.bg.share.\(id.uuidString.lowercased())")
        #expect(AppModel.ownsBackgroundSession(BackgroundSessionID.app) && AppModel.ownsBackgroundSession(BackgroundSessionID.share(job: id)))
        #expect(!AppModel.ownsBackgroundSession("com.apple.something") && !AppModel.ownsBackgroundSession("com.capybaraharmony.cobalt.run.x"))
    }

    @Test func aTaskWaitsForTheServerWhenItCanAndAsksPlainlyWhenTheSaveIsReady() throws {
        let rig = try FetcherRig()
        rig.handOff(saveReady: false)
        let waiting = try #require(rig.session?.tasks.first)
        #expect(waiting.label == "S1" && waiting.request.url?.absoluteString == "https://api.capybaraharmony.com/studio/S1/source?wait=90")
        #expect(waiting.request.httpMethod == "GET" && waiting.request.value(forHTTPHeaderField: "Authorization") == nil, "the source needs no key")
        let ready = try FetcherRig()
        ready.handOff(saveReady: true)
        #expect(ready.session?.tasks.first?.request.url?.absoluteString == "https://api.capybaraharmony.com/studio/S1/source")
        #expect(OriginalFetcher.sourceURL(sourceBase, wait: false) == sourceBase)
        #expect(OriginalFetcher.sourceURL(URL(string: sourceBase.absoluteString + "?wait=3")!, wait: true).absoluteString.hasSuffix("wait=90"))
    }

    @Test func aServerWithoutSourceWaitOnlyQueuesUnlessTheSaveIsReady() throws {
        let rig = try FetcherRig()
        let entry = rig.handOff(sourceWait: false, saveReady: false)
        #expect(entry.state == .queued && rig.session == nil, "no task: the entry waits for the foreground")
        let ready = try FetcherRig()
        ready.handOff(sourceWait: false, saveReady: true)
        #expect(ready.session?.tasks.count == 1, "a finished save can be fetched at once")
    }

    @Test func the200IsMovedInsideTheCallbackThenStored() async throws {
        let rig = try FetcherRig()
        rig.handOff()
        let session = try #require(rig.session)
        session.respond(task: 1, status: 200, body: bytes(4_321))
        // the file is in the inbox, `arrived`, before anything else happens
        if case .arrived(let file) = rig.state() {
            #expect(file.path.contains("/inbox/"))
        } else if case .stored = rig.state() {
        } else { Issue.record("expected arrived or stored, got \(String(describing: rig.state()))") }
        #expect(await eventually { if case .stored = rig.state() { return true } else { return false } })
        let video = try #require(rig.store.videos.first { $0.sessionID == "S1" && $0.kind == .original })
        #expect(video.link == URL(string: shortLink) && video.name == "clip")
        let file = try #require(video.fileURL)
        #expect((try? Data(contentsOf: file))?.count == 4_321)
        #expect(rig.store.videos.filter { $0.sessionID == "S1" }.count == 1)
    }

    @Test func aFreshProcessInstanceLandsWhatWasLeftArrived() async throws {
        let dir = try makeTempDirectory()
        let first = try FetcherRig(directory: dir)
        first.handOff()
        let file = first.store.inboxURL(for: "clip.mp4")
        try bytes(2_000).write(to: file)
        first.pending.update("S1", now: first.h.clock.now()) { $0.state = .arrived(file: file) }

        // the process was killed between the move and `store.add`: another one picks it up
        let second = try FetcherRig(directory: dir)
        let fresh = OriginalFetcher(
            identifier: BackgroundSessionID.app, transport: second.transport, pending: PendingOriginals(directory: dir),
            store: first.store, clock: second.h.clock)
        await fresh.reconcile()
        #expect(PendingOriginals(directory: dir).entry("S1").map { if case .stored = $0.state { true } else { false } } == true)
        #expect(first.store.videos.contains { $0.sessionID == "S1" && $0.kind == .original && $0.fileURL != nil })
        #expect(second.transport.created.isEmpty, "nothing needed the network")
    }

    @Test func notReadyGoesBackToQueuedAndABackgroundWakeRestartsItTwiceAtMost() async throws {
        let rig = try FetcherRig()
        rig.fetcher.isActive = { false }                                   // the app is not in front
        rig.handOff()
        let session = try #require(rig.session)
        session.respond(task: 1, status: 409, body: notReady)
        #expect(await eventually { session.tasks.count == 2 })
        session.respond(task: 2, status: 409, body: notReady)
        #expect(await eventually { session.tasks.count == 3 })
        session.respond(task: 3, status: 409, body: notReady)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(session.tasks.count == 3, "two re-enqueues from a background wake, then it waits")
        #expect(rig.state() == .queued && rig.pending.entry("S1")?.backgroundStarts == 2)

        // the foreground starts it again: nothing is rate-limited there
        rig.fetcher.isActive = { true }
        await rig.fetcher.reconcile()
        #expect(session.tasks.count == 4)
        if case .downloading = rig.state() {} else { Issue.record("expected downloading, got \(String(describing: rig.state()))") }
    }

    @Test func aForegroundAppNeverRestartsOnItsOwnAnswer() async throws {
        let rig = try FetcherRig()
        rig.handOff()
        let session = try #require(rig.session)
        session.respond(task: 1, status: 409, body: notReady)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(session.tasks.count == 1 && rig.state() == .queued, "no hot loop against a server that answers at once")
    }

    @Test func goneAnswersEndTheEntry() async throws {
        for (status, body, expected) in [
            (410, #"{"status":"error","error":{"code":"error.studio.expired"}}"#, "error.studio.expired"),
            (404, #"{"status":"error","error":{"code":"error.studio.not_found"}}"#, "error.studio.not_found"),
            (422, #"{"status":"error","error":{"code":"error.studio.fetch_failed"}}"#, "error.studio.fetch_failed"),
            (410, "not json", "http.410"),
        ] {
            let rig = try FetcherRig()
            rig.fetcher.isActive = { false }
            rig.handOff()
            let session = try #require(rig.session)
            session.respond(task: 1, status: status, body: Data(body.utf8))
            #expect(rig.state() == .gone(code: expected), "\(status)")
            try? await Task.sleep(for: .milliseconds(40))
            #expect(session.tasks.count == 1, "never retried")
            await rig.fetcher.reconcile()
            #expect(session.tasks.count == 1, "nor on the foreground")
            #expect(rig.store.videos.allSatisfy { $0.sessionID != "S1" })
        }
    }

    @Test func serverErrorsAndNetworkErrorsAreRetriedAndAFullDiskWaitsForTheForeground() async throws {
        // 5xx: failed, retried by the background wake
        let rig = try FetcherRig()
        rig.fetcher.isActive = { false }
        rig.handOff()
        let session = try #require(rig.session)
        session.respond(task: 1, status: 503, body: Data())
        #expect(await eventually { session.tasks.count == 2 })

        // a dropped connection
        session.fail(task: 2, code: NSURLErrorNetworkConnectionLost)
        #expect(await eventually { session.tasks.count == 3 })
        if case .downloading = rig.state() {} else { Issue.record("expected downloading") }

        // our own cancel says nothing
        session.fail(task: 3, code: NSURLErrorCancelled)
        try? await Task.sleep(for: .milliseconds(40))
        if case .downloading = rig.state() {} else { Issue.record("a cancel is not a failure: \(String(describing: rig.state()))") }

        // ENOSPC: failed, not retried from the background, retried on the foreground
        let full = try FetcherRig()
        full.fetcher.isActive = { false }
        full.handOff()
        let s = try #require(full.session)
        s.fail(task: 1, code: 28)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(s.tasks.count == 1)
        if case .failed(let code, let tries) = full.state() { #expect(code == 28 && tries == 1) } else { Issue.record("expected failed") }
        full.fetcher.isActive = { true }
        await full.fetcher.reconcile()
        #expect(s.tasks.count == 2, "the foreground tries again")
    }

    @Test func aTaskTheSystemLostIsRestartedFromTheForeground() async throws {
        let rig = try FetcherRig()
        rig.handOff()
        let session = try #require(rig.session)
        await rig.fetcher.reconcile()
        #expect(session.tasks.count == 1, "a live task is left alone")
        session.lose(task: 1)
        await rig.fetcher.reconcile()
        #expect(session.tasks.count == 2, "no live task and nothing landed: started again")
    }

    @Test func aQueuedEntryStartsOnTheForegroundWhateverTheServerSays() async throws {
        let rig = try FetcherRig()
        rig.handOff(sourceWait: false, saveReady: false)
        #expect(rig.session == nil)
        await rig.fetcher.reconcile()
        let task = try #require(rig.session?.tasks.first)
        #expect(task.request.url?.query == nil, "this server cannot hold the request")
        rig.fetcher.serverHoldsRequests = { true }
        rig.pending.update("S1", now: rig.h.clock.now()) { $0.state = .queued }
        await rig.fetcher.reconcile()
        #expect(rig.session?.tasks.last?.request.url?.query == "wait=90", "the app now knows the server can")
    }

    @Test func theSystemWakingTheAppForAnExtensionsSessionLandsItsFile() async throws {
        // the extension's task, started in its own session
        let job = UUID()
        let extID = BackgroundSessionID.share(job: job)
        let dir = try makeTempDirectory()
        let ext = try FetcherRig(identifier: extID, directory: dir)
        ext.handOff()
        let extTask = try #require(ext.session?.tasks.first)
        #expect(extTask.label == "S1")

        // the app, woken for that identifier: it attaches a session with the same id and gets the event
        let app = OriginalFetcher(
            identifier: BackgroundSessionID.app, transport: ext.transport, pending: PendingOriginals(directory: dir),
            store: ext.store, clock: ext.h.clock)
        let landed = Mutex(0)
        app.landed = { landed.withLock { $0 += 1 } }
        let wake = Task { await app.handleWake(identifier: extID) }
        await wake.value
        ext.session?.respond(task: extTask.id, status: 200, body: bytes())
        #expect(await eventually { ext.store.videos.contains { $0.sessionID == "S1" } })
        await app.handleWake(identifier: extID)
        #expect(landed.withLock { $0 } >= 1)
        #expect(PendingOriginals(directory: dir).entry("S1").map { if case .stored = $0.state { true } else { false } } == true)
    }

    @Test func aDownloadingEntryOfAnotherSessionIsAdoptedOnTheForeground() async throws {
        let job = UUID()
        let extID = BackgroundSessionID.share(job: job)
        let dir = try makeTempDirectory()
        let ext = try FetcherRig(identifier: extID, directory: dir)
        ext.handOff()
        let task = try #require(ext.session?.tasks.first)

        let app = OriginalFetcher(
            identifier: BackgroundSessionID.app, transport: ext.transport, pending: PendingOriginals(directory: dir),
            store: ext.store, clock: ext.h.clock)
        await app.reconcile()
        #expect(ext.transport.created == [extID], "still going in the extension's session: nothing new started")
        ext.session?.lose(task: task.id)
        await app.reconcile()
        #expect(ext.transport.created.contains(BackgroundSessionID.app), "gone and nothing landed: restarted in the app's own session")
        #expect(ext.transport.session(BackgroundSessionID.app)?.tasks.count == 1)
    }

    @Test func theSameSessionSharedTwiceIsOneDownloadAndOldEntriesAreDropped() async throws {
        let rig = try FetcherRig()
        rig.handOff()
        rig.handOff()
        #expect(rig.session?.tasks.count == 1 && rig.pending.all().count == 1)
        // a dead entry is replaced
        rig.pending.update("S1", now: rig.h.clock.now()) { $0.state = .gone(code: "error.studio.expired") }
        rig.handOff()
        #expect(rig.session?.tasks.count == 2)
        // a week later it is gone
        let old = PendingOriginal(
            id: "OLD", link: nil, media: nil, sourceURL: sourceBase, sourceWait: true,
            createdAt: rig.h.clock.now().addingTimeInterval(-8 * 86_400), state: .queued, updatedAt: rig.h.clock.now())
        rig.pending.enqueue(old, now: rig.h.clock.now().addingTimeInterval(-8 * 86_400))
        rig.pending.enqueue(
            PendingOriginal(id: "NEW", link: nil, media: nil, sourceURL: sourceBase, sourceWait: true,
                            createdAt: rig.h.clock.now(), state: .queued, updatedAt: rig.h.clock.now()),
            now: rig.h.clock.now())
        #expect(rig.pending.entry("OLD") == nil && rig.pending.entry("NEW") != nil)
    }
}

// MARK: - The sheet hands it off

@MainActor
struct HandoffRig {
    let h: Harness
    let ctx: PipelineContext
    let pipeline: Pipeline
    let core: ShareCore
    let transport = FakeBackgroundTransport()
    let pending: PendingOriginals
    let fetcher: OriginalFetcher
    let notifier = FakeNotifier()
    let counter = Counter()
    let gate = Gate()
    final class Counter: @unchecked Sendable { var completed = 0 }

    /// `holdKeep`: the keep download parks until `gate` opens. The context is not a preview, so the
    /// keep download runs like the real extension's.
    init(
        _ scenario: PreviewScenario = .shortClip, sourceWait: Bool = true, holdKeep: Bool = false, keep: Bool = true,
        countdown: Int? = nil
    ) throws {
        let h = Harness(scenario)
        self.h = h
        let base = h.ctx
        let ctx = PipelineContext(
            client: base.client, capabilities: base.capabilities, settings: base.settings, store: base.store,
            jobs: base.jobs, tools: base.tools, clock: h.clock, photos: base.photos, clipboard: base.clipboard,
            intake: base.intake, isPreview: false)
        ctx.capabilities.sourceWait = sourceWait
        ctx.settings.keepVideosOnDevice = keep
        if let countdown {
            ctx.settings.autoContinue = true
            ctx.settings.autoContinueSeconds = countdown
        }
        if holdKeep {
            let gate = gate
            let inner = ctx.client
            var stub = ScriptedClient(base: inner)
            stub.downloadHook = { file, dest in
                if case .studioSource = file { await gate.wait() }
                return try await inner.download(file, to: dest, progress: { _ in })
            }
            ctx.client = stub
        }
        self.ctx = ctx
        pipeline = Pipeline(context: ctx)
        core = ShareCore(context: ctx, pipeline: pipeline, notifier: notifier, assistiveRunning: false)
        let counter = counter
        core.complete = { counter.completed += 1 }
        pending = PendingOriginals(directory: try makeTempDirectory())
        fetcher = OriginalFetcher(
            identifier: BackgroundSessionID.share(job: core.jobID), transport: transport, pending: pending, store: ctx.store,
            clock: h.clock)
        ctx.originals = fetcher
    }

    var session: FakeBackgroundTransport.Session? { transport.session(BackgroundSessionID.share(job: core.jobID)) }

    func park() async {
        var spins = 0
        while await gate.waiting == 0, spins < 400 {
            await h.settle()
            h.clock.advance()
            spins += 1
        }
    }

    func start() { pipeline.start(link: URL(string: shortLink)!) }
}

@MainActor
@Suite(.serialized)
struct OriginalHandoffTests {
    @Test func continuingDuringTheSaveQueuesAndStartsATaskInTheSheetsOwnSession() async throws {
        let rig = try HandoffRig(.coldStart)
        rig.start()
        await rig.h.drive { rig.core.canContinueInBackground }
        let sid = try #require(rig.pipeline.sessionID)
        #expect(await rig.core.continueInBackground() == .continuesInBackground)
        #expect(rig.counter.completed == 1)
        let entry = try #require(rig.pending.entry(sid))
        #expect(entry.link == URL(string: shortLink) && entry.sourceWait && entry.id == sid)
        if case .downloading(let session, _, _) = entry.state {
            #expect(session == BackgroundSessionID.share(job: rig.core.jobID))
        } else { Issue.record("expected a running task, got \(entry.state)") }
        let task = try #require(rig.session?.tasks.first)
        #expect(task.request.url?.query == "wait=90", "the server holds it until the save is ready")
        #expect(rig.transport.allTasks.count == 1)
    }

    @Test func aServerWithoutSourceWaitOnlyQueues() async throws {
        let rig = try HandoffRig(.coldStart, sourceWait: false)
        rig.start()
        await rig.h.drive { rig.core.canContinueInBackground }
        let sid = try #require(rig.pipeline.sessionID)
        _ = await rig.core.continueInBackground()
        #expect(rig.pending.entry(sid)?.state == .queued && rig.pending.entry(sid)?.sourceWait == false)
        #expect(rig.transport.allTasks.isEmpty && rig.session == nil)
    }

    @Test func closingAtReadyWithTheKeepDownloadRunningCancelsItAndQueuesTheHandoff() async throws {
        let rig = try HandoffRig(holdKeep: true)
        rig.start()
        await rig.park()
        await rig.h.drive { rig.pipeline.state == .ready }
        let sid = try #require(rig.pipeline.sessionID)
        #expect(rig.pipeline.state == .ready && rig.pipeline.keepRequest != nil && rig.pipeline.stored == nil)

        #expect(await rig.core.close() == .dismissed)
        #expect(rig.counter.completed == 1)
        #expect(rig.pipeline.keepRequest == nil, "the in-sheet download is cancelled")
        let entry = try #require(rig.pending.entry(sid))
        if case .downloading = entry.state {} else { Issue.record("expected a running task, got \(entry.state)") }
        #expect(rig.session?.tasks.first?.request.url?.query == nil, "the save is ready: no wait")

        // the cancelled download never reaches the store
        await rig.gate.open()
        await rig.h.settle()
        #expect(rig.ctx.store.videos.allSatisfy { !($0.kind == .original && $0.sessionID == sid) })
    }

    @Test func theCountdownFiringAtReadyHandsTheRunningKeepDownloadOver() async throws {
        let rig = try HandoffRig(holdKeep: true, countdown: 10)
        rig.start()
        await rig.park()
        await rig.h.drive { rig.pipeline.state == .ready }
        #expect(rig.pipeline.keepRequest != nil)
        if case .counting = rig.core.autoContinue {} else { Issue.record("still counting at ready, got \(rig.core.autoContinue)") }
        await rig.h.drive { rig.core.autoContinue == .fired }
        let sid = try #require(rig.pipeline.sessionID)
        #expect(rig.core.autoContinue == .fired && rig.counter.completed == 1)
        #expect(rig.pending.entry(sid) != nil, "the sheet closed at ready: the original went to the background download")
        #expect(rig.ctx.jobs.all().isEmpty)
        await rig.gate.open()
    }

    @Test func anOriginalAlreadyOnThePhoneHandsNothingOver() async throws {
        let rig = try HandoffRig()
        rig.start()
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.h.drive { rig.pipeline.keepRequest == nil && rig.pipeline.stored != nil }
        let sid = try #require(rig.pipeline.sessionID)
        #expect(await rig.core.close() == .dismissed)
        #expect(rig.pending.entry(sid) == nil && rig.transport.allTasks.isEmpty)
    }

    @Test func keepOffHandsNothingOver() async throws {
        let rig = try HandoffRig(.coldStart, keep: false)
        rig.start()
        await rig.h.drive { rig.core.canContinueInBackground }
        let sid = try #require(rig.pipeline.sessionID)
        _ = await rig.core.continueInBackground()
        #expect(rig.pending.entry(sid) == nil && rig.transport.allTasks.isEmpty)
        let ready = try HandoffRig(keep: false)
        ready.start()
        await ready.h.drive { ready.pipeline.state == .ready }
        _ = await ready.core.close()
        #expect(ready.pending.all().isEmpty)
    }

    @Test func trimInCobaltHandsNothingOverTheAppTakesTheRun() async throws {
        let rig = try HandoffRig(holdKeep: true)
        rig.start()
        await rig.park()
        await rig.h.drive { rig.pipeline.state == .ready }
        await rig.core.handOffToApp()
        #expect(rig.pending.all().isEmpty && rig.transport.allTasks.isEmpty)
        let job = try #require(rig.ctx.jobs.all().first)
        #expect(job.wantsTrim && job.stage == .ready)
        await rig.gate.open()
    }

    @Test func aFileShareHandsNothingOver() async throws {
        let rig = try HandoffRig()
        rig.pipeline.start(file: try makeTempFile("clip.mov", bytes: 5_000))
        await rig.h.drive { rig.pipeline.state == .ready }
        _ = await rig.core.close()
        #expect(rig.pending.all().isEmpty)
    }

    @Test func closingBeforeAnythingWasSavedHandsNothingOver() async throws {
        let rig = try HandoffRig()
        _ = await rig.core.close()
        #expect(rig.pending.all().isEmpty && rig.counter.completed == 1)
    }
}

// MARK: - The app takes over

@MainActor
@Suite(.serialized)
struct OriginalTakeoverTests {
    /// An app-side pipeline on a non-preview context sharing the rig's server and store.
    private func appContext(_ rig: HandoffRig) -> PipelineContext {
        let base = rig.h.ctx
        let ctx = PipelineContext(
            client: base.client, capabilities: rig.ctx.capabilities, settings: base.settings, store: base.store,
            jobs: base.jobs, tools: base.tools, clock: rig.h.clock, photos: base.photos, clipboard: base.clipboard,
            intake: base.intake, isPreview: false)
        return ctx
    }

    @Test func aLiveEntryKeepsTheAppFromStartingASecondDownload() async throws {
        let rig = try HandoffRig(.coldStart)
        rig.start()
        await rig.h.drive { rig.core.canContinueInBackground }
        let sid = try #require(rig.pipeline.sessionID)
        _ = await rig.core.continueInBackground()
        #expect(rig.pending.isLive(session: sid))

        let ctx = appContext(rig)
        ctx.originals = rig.fetcher
        let app = Pipeline(context: ctx)
        let job = try #require(rig.ctx.jobs.all().first)
        app.resume(job)
        await rig.h.drive { app.state == .ready }
        #expect(app.keepRequest == nil, "the background download is the one bringing it")
        #expect(ctx.store.videos.allSatisfy { !($0.kind == .original && $0.sessionID == sid) })
    }

    @Test func takingOverAStillSavingSheetJobKeepsTheOriginal() async throws {
        let rig = try HandoffRig(.coldStart, sourceWait: false)
        rig.start()
        await rig.h.drive { rig.core.canContinueInBackground }
        let sid = try #require(rig.pipeline.sessionID)
        _ = await rig.core.continueInBackground()
        // the app never got the background download going (no source_wait, never reconciled): it is the
        // app's own run that must keep the original (the second gap)
        rig.pending.remove(sid)
        let ctx = appContext(rig)
        let app = Pipeline(context: ctx)
        let job = try #require(rig.ctx.jobs.all().first)
        #expect(job.stage == .saving)
        app.resume(job)
        await rig.h.drive { app.state == .ready }
        await rig.h.drive { app.keepRequest == nil && app.stored != nil }
        #expect(app.stored?.sessionID == sid)
        #expect(ctx.store.videos.contains { $0.kind == .original && $0.sessionID == sid && $0.fileURL != nil })
    }

    @Test func foregroundingStartsTheQueuedDownloadAfterTakingTheHandoff() async throws {
        let rig = try HandoffRig(.coldStart, sourceWait: false)
        rig.start()
        await rig.h.drive { rig.core.canContinueInBackground }
        let sid = try #require(rig.pipeline.sessionID)
        _ = await rig.core.continueInBackground()
        #expect(rig.pending.entry(sid)?.state == .queued)

        let app = rig.h.app
        let appFetcher = OriginalFetcher(
            identifier: BackgroundSessionID.app, transport: rig.transport, pending: rig.pending, store: rig.ctx.store,
            clock: rig.h.clock)
        app.ctx.originals = appFetcher
        let seen = Mutex<[String]>([])
        appFetcher.serverHoldsRequests = {
            seen.withLock { $0.append(app.pipeline.state == .idle ? "idle" : "taken") }
            return false
        }
        await app.pickUpSharedJobs()
        #expect(seen.withLock { $0 } == ["taken"], "the handoff is taken first, then the originals are reconciled")
        #expect(rig.transport.session(BackgroundSessionID.app)?.tasks.count == 1)
        if case .downloading = rig.pending.entry(sid)?.state {} else { Issue.record("expected a running task") }
    }

    @Test func aWakeLandsTheClipInTheAlbumInTheSameForeground() async throws {
        let dir = try makeTempDirectory()
        let env = try PhotosEnv(directory: dir)
        let h = Harness(.shortClip)
        let ctx = PipelineContext(
            client: h.ctx.client, capabilities: h.ctx.capabilities, settings: env.settings, store: env.store, jobs: h.ctx.jobs,
            tools: h.ctx.tools, clock: h.clock, photos: h.ctx.photos, clipboard: h.ctx.clipboard, intake: h.ctx.intake, isPreview: true)
        let client = ctx.client
        let app = AppModel(context: ctx, library: LibraryModel(context: ctx), photosSync: env.sync, makeClient: { _ in client })
        let transport = FakeBackgroundTransport()
        let fetcher = OriginalFetcher(
            identifier: BackgroundSessionID.app, transport: transport, pending: PendingOriginals(directory: dir),
            store: env.store, clock: h.clock)
        ctx.originals = fetcher
        env.turnOn()
        _ = await env.sync.enable()
        fetcher.handOff(
            session: "S1", link: URL(string: shortLink), media: MediaInfo(name: "clip", duration: 5, width: 1, height: 1, bytes: nil, isImage: false),
            sourceURL: sourceBase, sourceWait: true, saveReady: false)
        transport.session(BackgroundSessionID.app)?.respond(task: 1, status: 200, body: bytes())

        await app.handleBackgroundDownloads(identifier: BackgroundSessionID.app)
        #expect(await eventually { env.library.addCalls == 1 })
        await env.sync.reconcile()
        #expect(env.library.addCalls == 1)
        let album = try #require(env.ledger.album)
        #expect(env.library.members(of: album.id).count == 1 && env.ledger.entry("s:S1")?.inAlbum == .yes)
    }
}

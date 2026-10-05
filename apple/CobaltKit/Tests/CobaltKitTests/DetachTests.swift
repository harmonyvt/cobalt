import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// Pipeline.detach(): "close without throwing work away". Every test runs on the virtual clock and
// stubs: no network, no real sleeping.

@MainActor
final class FakeActivity: AppActivity {
    var isActive = false
}

@MainActor
private func isRendering(_ p: Pipeline) -> Bool {
    if case .rendering = p.state { return true }
    return false
}

/// A non-preview app (so the keep-original download and the job records run) on the virtual clock,
/// with a Live manager on a fake ActivityKit and a fake notifier.
@MainActor
struct DetachRig {
    let h: Harness
    let ctx: PipelineContext
    let app: AppModel
    let manager: LiveActivityManager
    let adapter: FakeLiveAdapter
    let notifier = FakeNotifier()
    let activity = FakeActivity()
    var pipeline: Pipeline { app.pipeline }
    var store: OfflineStore { ctx.store }
    var clipboard: MemoryClipboard { ctx.clipboard as! MemoryClipboard }

    /// `preview`: no real notification center is touched (taking a job clears its notifications, which
    /// needs an app bundle); no keep-original download either.
    init(_ scenario: PreviewScenario = .shortClip, sharing other: DetachRig? = nil, preview: Bool = false) {
        let h = other?.h ?? Harness(scenario)
        self.h = h
        let base = other?.ctx ?? h.ctx
        let ctx = PipelineContext(
            client: base.client, capabilities: base.capabilities, settings: base.settings, store: base.store,
            jobs: base.jobs, tools: base.tools, clock: h.clock, photos: base.photos, clipboard: base.clipboard,
            intake: base.intake, isPreview: preview)
        ctx.recordsJobs = true
        ctx.notifier = notifier
        ctx.background.activity = activity
        self.ctx = ctx
        adapter = FakeLiveAdapter()
        let clock = h.clock
        adapter.clock = { clock.now() }
        manager = LiveActivityManager(context: ctx, adapter: adapter, environment: nil, grace: FakeGrace())
        ctx.live = manager
        let client = ctx.client
        app = AppModel(context: ctx, library: LibraryModel(context: ctx), makeClient: { _ in client })
        app.liveManager = manager
    }

    func drive(_ condition: @escaping @MainActor () -> Bool) async {
        await h.drive(until: condition)
        await manager.settle()
    }

    /// Runs time forward until `gate` has a parked caller.
    func park(_ gate: Gate) async {
        var spins = 0
        while await gate.waiting == 0, spins < 400 {
            await h.settle()
            h.clock.advance()
            spins += 1
        }
    }

    func toReady(keeping: Bool = true) async {
        pipeline.start(link: URL(string: shortLink)!)
        await drive { self.pipeline.state == .ready }
        if keeping { await drive { self.pipeline.keepRequest == nil && self.pipeline.stored != nil } }
    }

    func handle(forRun run: UUID) -> FakeLiveHandle? {
        adapter.handles.first { $0.attributes.run == run.uuidString.lowercased() }
    }

    func waitForPosts(_ n: Int) async {
        for _ in 0..<300 where notifier.posts.count < n { try? await Task.sleep(for: .milliseconds(2)) }
        try? await Task.sleep(for: .milliseconds(10))
    }

    var webps: [StoredVideo] { store.videos.filter { $0.kind == .webp } }
    func originals(session: String) -> [StoredVideo] {
        store.videos.filter { $0.kind == .original && $0.sessionID == session }
    }
}

private let hosted = URL(string: "https://media.capybaraharmony.com/DeTaChEd01.mp4")!

@MainActor
@Suite(.serialized)
struct DetachTests {
    // MARK: render

    @Test func detachMidRenderFreesTheScreenAndTheWebpStillJoinsTheStore() async throws {
        let r = DetachRig()
        let p = r.pipeline
        await r.toReady()
        p.makeWebp()
        await r.drive { isRendering(p) && p.renderJobID != nil }
        let runBefore = p.runID
        let liveRun = p.liveRunID
        let webpsBefore = r.webps.count
        let record = try #require(r.ctx.jobs.all().first { $0.id == liveRun })
        guard case .rendering = record.stage else { Issue.record("expected a rendering record"); return }
        let handle = try #require(r.handle(forRun: liveRun))

        p.detach()
        // the visible pipeline is free at once, with a new run
        #expect(p.state == .idle)
        #expect(p.runID != runBefore && p.liveRunID != liveRun)
        #expect(p.result == nil && p.sessionID == nil && p.media == nil)
        #expect(r.ctx.background.count == 1)
        // the run's record and activity are still alive
        #expect(r.ctx.jobs.all().contains { $0.id == liveRun })
        #expect(!handle.ended)

        await r.drive { r.ctx.background.isEmpty }
        #expect(p.state == .idle && p.result == nil, "the detached run never shows")
        #expect(r.webps.count == webpsBefore + 1, "the webp joined the store exactly as .done does")
        #expect(r.ctx.jobs.all().isEmpty, "the SharedJob ended with the run")
        #expect(handle.ended && handle.end?.state.stage == .done, "the Live Activity ended done")
        await r.waitForPosts(1)
        #expect(r.notifier.posts.map(\.kind) == [.webpReady])
    }

    @Test func noNotificationWhileTheAppIsActive() async throws {
        let r = DetachRig()
        r.activity.isActive = true
        await r.toReady()
        r.pipeline.makeWebp()
        await r.drive { isRendering(r.pipeline) && r.pipeline.renderJobID != nil }
        r.pipeline.detach()
        await r.drive { r.ctx.background.isEmpty }
        #expect(r.webps.count == 1)
        await r.waitForPosts(1)
        #expect(r.notifier.posts.isEmpty)
    }

    @Test func detachWhileTheRenderRequestIsOnTheWireStartsOnlyOneRender() async throws {
        let r = DetachRig()
        let p = r.pipeline
        await r.toReady()
        let gate = Gate()
        let posts = Mutex(0)
        let base = r.ctx.client
        var stub = ScriptedClient(base: base)
        stub.renderHook = { sid, request in
            posts.withLock { $0 += 1 }
            await gate.wait()
            return try await base.render(session: sid, request)
        }
        r.ctx.client = stub
        p.makeWebp()
        await r.park(gate)
        #expect(p.renderJobID == nil && isRendering(p))

        p.detach()
        #expect(p.state == .idle && r.ctx.background.count == 1)
        await gate.open()
        await r.drive { r.ctx.background.isEmpty }
        #expect(posts.withLock { $0 } == 1, "the handed-over POST is the only one")
        #expect(r.webps.count == 1)
        #expect(p.state == .idle)
    }

    /// Regression: a status poll already on the wire when `detach()` runs (focus closed during the pack
    /// phase) came back with `.pending(.pack, ...)` and wrote `.rendering(.packing)` into the now-idle
    /// visible pipeline, stranding home with no session. `runRender` must drop the stale poll.
    @Test func aRenderPollThatLandsAfterDetachNeverWritesIntoTheVisiblePipeline() async throws {
        let r = DetachRig()
        let p = r.pipeline
        await r.toReady()
        let gate = Gate()
        let polls = Mutex(0)
        let base = r.ctx.client
        var stub = ScriptedClient(base: base)
        stub.renderStatusHook = { sid, job, wait in
            // only the first poll is held; it answers "packing" once the screen has been closed
            let n = polls.withLock { $0 += 1; return $0 }
            if n == 1 {
                await gate.wait()
                return .pending(phase: .pack, framesDone: 10, framesTotal: 10)
            }
            return try await base.renderStatus(session: sid, job: job, wait: wait)
        }
        r.ctx.client = stub
        p.makeWebp()
        await r.park(gate)
        #expect(p.renderJobID != nil && isRendering(p), "the first poll is in flight")
        let webpsBefore = r.webps.count

        p.detach()
        let runAfter = p.runID
        #expect(p.state == .idle && r.ctx.background.count == 1)

        await gate.open()                                 // the in-flight poll now returns .pending(.pack)
        // drive the whole detached run; the visible pipeline must be idle at every step
        var spins = 0
        while !r.ctx.background.isEmpty, spins < 2000 {
            await r.h.settle()
            r.h.clock.advance()
            #expect(p.state == .idle, "the stale poll wrote \(p.state) into the visible pipeline")
            if p.state != .idle { break }
            spins += 1
        }
        await r.drive { r.ctx.background.isEmpty }
        #expect(p.state == .idle && p.runID == runAfter, "the visible pipeline is still the new, idle run")
        #expect(p.result == nil && p.sessionID == nil)
        #expect(polls.withLock { $0 } >= 2, "the detached run kept polling after the stale answer")
        #expect(r.webps.count == webpsBefore + 1, "the detached run still completed and the webp joined the store once")
    }

    @Test func aDetachedRenderThatFailsEndsItsActivityFailedAndPostsNothing() async throws {
        let r = DetachRig(.renderLost)
        let p = r.pipeline
        await r.toReady()
        p.makeWebp()
        await r.drive { isRendering(p) && p.renderJobID != nil }
        let liveRun = p.liveRunID
        let handle = try #require(r.handle(forRun: liveRun))
        p.detach()
        await r.drive { r.ctx.background.isEmpty }
        #expect(handle.ended && handle.end?.state.stage == .failed)
        #expect(r.webps.isEmpty && r.ctx.jobs.all().isEmpty)
        await r.waitForPosts(1)
        #expect(r.notifier.posts.isEmpty)
    }

    // MARK: publish

    @Test func detachMidPublishRecordsThePublicLinkOnTheStoredOriginal() async throws {
        let r = DetachRig()
        let p = r.pipeline
        await r.toReady()
        let sid = try #require(p.sessionID)
        #expect(r.originals(session: sid).count == 1)
        let gate = Gate()
        var stub = ScriptedClient(base: r.ctx.client)
        stub.publishSessionHook = { _ in
            await gate.wait()
            return HostedFile(url: hosted, bytes: 1, contentType: "video/mp4", itemID: nil)
        }
        r.ctx.client = stub
        p.hostOriginal()
        await r.park(gate)
        #expect(p.hosting == .working)

        p.detach()
        #expect(p.state == .idle && p.hosting == .idle && p.hostedURL == nil)
        #expect(r.ctx.background.count == 1)
        await gate.open()
        await r.drive { r.ctx.background.isEmpty }

        let original = try #require(r.originals(session: sid).first)
        #expect(original.publicURL == hosted, "the orbit's link badge reads real storage")
        #expect(r.clipboard.copies.isEmpty, "a background completion never touches the pasteboard")
        #expect(p.hostedURL == nil && p.state == .idle, "the finished publish is not the visible run's")
        // it was persisted: a fresh store over the same index sees it
        let reopened = OfflineStore(root: r.store.root, tools: r.ctx.tools)
        #expect(reopened.videos.first { $0.id == original.id }?.publicURL == hosted)
    }

    @Test func anAttachedPublishAlsoRecordsTheLinkAndNeverCopiesIt() async throws {
        let r = DetachRig()
        let p = r.pipeline
        await r.toReady()
        let sid = try #require(p.sessionID)
        p.hostOriginal()
        await r.drive { p.hosting == .done }
        let url = try #require(p.hostedURL)
        #expect(r.originals(session: sid).first?.publicURL == url)
        #expect(p.stored?.publicURL == url)
        #expect(r.clipboard.copies.isEmpty, "the owner copies explicitly")
        p.copyResultLink()                                      // no webp yet: nothing to copy either
        #expect(r.clipboard.copies.isEmpty)
    }

    @Test func aPublishThatFinishesBeforeTheOriginalLandsIsAppliedWhenItDoes() async throws {
        let r = DetachRig()
        let p = r.pipeline
        let gate = Gate()
        let base = r.ctx.client
        var stub = ScriptedClient(base: base)
        stub.downloadHook = { file, dest in
            if case .studioSource = file { await gate.wait() }
            return try await base.download(file, to: dest, progress: { _ in })
        }
        r.ctx.client = stub
        p.start(link: URL(string: shortLink)!)
        await r.park(gate)
        await r.drive { p.state == .ready }
        let sid = try #require(p.sessionID)
        p.hostOriginal()
        await r.drive { p.hosting == .done }
        #expect(r.originals(session: sid).isEmpty)
        await gate.open()
        await r.drive { p.keepRequest == nil && p.stored != nil }
        #expect(r.originals(session: sid).first?.publicURL == p.hostedURL)
    }

    // MARK: keep original

    @Test func detachMidKeepOriginalStillLandsTheFileInTheStore() async throws {
        let r = DetachRig()
        let p = r.pipeline
        let gate = Gate()
        let base = r.ctx.client
        var stub = ScriptedClient(base: base)
        stub.downloadHook = { file, dest in
            if case .studioSource = file { await gate.wait() }
            return try await base.download(file, to: dest, progress: { _ in })
        }
        r.ctx.client = stub
        p.start(link: URL(string: shortLink)!)
        await r.park(gate)
        await r.drive { p.state == .ready }
        let sid = try #require(p.sessionID)
        let liveRun = p.liveRunID
        #expect(p.keepRequest != nil && r.originals(session: sid).isEmpty)

        p.detach()
        #expect(p.state == .idle && r.ctx.background.count == 1)
        await gate.open()
        await r.drive { r.ctx.background.isEmpty }
        let original = try #require(r.originals(session: sid).first)
        let file = try #require(original.fileURL)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(p.state == .idle && p.stored == nil)
        let handle = try #require(r.handle(forRun: liveRun))
        #expect(handle.ended, "the run's activity ended with its last piece of work")
        #expect(r.ctx.jobs.all().isEmpty)
    }

    // MARK: nothing in flight

    @Test func detachWithNothingInFlightIsReset() async throws {
        let r = DetachRig()
        let p = r.pipeline
        await r.toReady()
        let liveRun = p.liveRunID
        let runBefore = p.runID
        let handle = try #require(r.handle(forRun: liveRun))
        p.detach()
        #expect(p.state == .idle && p.runID != runBefore && p.liveRunID != liveRun)
        #expect(r.ctx.background.isEmpty)
        await r.manager.settle()
        #expect(handle.ended, "reset's behaviour: the unfinished activity goes at once")
        #expect(r.ctx.jobs.all().isEmpty)
        await r.waitForPosts(1)
        #expect(r.notifier.posts.isEmpty)
    }

    @Test func detachOnAPreviewPipelineWithNothingToKeepIsReset() async throws {
        let h = Harness(.shortClip)
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.driveToSettled()
        #expect(h.pipeline.state == .ready)
        let before = h.pipeline.runID
        h.pipeline.detach()
        #expect(h.pipeline.state == .idle && h.pipeline.runID != before && h.ctx.background.isEmpty)
    }

    @Test func detachInTheShareExtensionIsAlwaysReset() async throws {
        let r = DetachRig()
        r.ctx.background.allowsDetach = false
        await r.toReady()
        r.pipeline.makeWebp()
        await r.drive { isRendering(r.pipeline) && r.pipeline.renderJobID != nil }
        r.pipeline.detach()
        #expect(r.pipeline.state == .idle && r.ctx.background.isEmpty)
        #expect(r.ctx.jobs.all().isEmpty)
    }

    // MARK: runID

    @Test func runIDChangesOnEveryNewRunAndOnResetOnly() async throws {
        let h = Harness(.shortClip)
        let p = h.pipeline
        let initial = p.runID
        p.start(link: URL(string: shortLink)!)
        let first = p.runID
        #expect(first != initial)
        await h.driveToSettled()
        #expect(p.runID == first, "the states of one run keep its id")
        p.makeWebp()
        await h.drive { if case .done = p.state { true } else { false } }
        #expect(p.runID == first)
        p.backToTrim()
        #expect(p.runID == first, "back to the trim is still the run on screen")
        p.reset()
        let afterReset = p.runID
        #expect(afterReset != first)
        p.start(link: URL(string: shortLink)!)
        #expect(p.runID != afterReset)
    }

    // MARK: relaunch

    @Test func aRelaunchResumesADetachedRenderFromItsRecord() async throws {
        let first = DetachRig()
        let p = first.pipeline
        await first.toReady()
        p.makeWebp()
        await first.drive { isRendering(p) && p.renderJobID != nil }
        let run = p.liveRunID
        p.detach()
        let saved = try #require(first.ctx.jobs.all().first { $0.id == run })

        // while this process runs the render itself, the foreground pickup leaves its job alone
        await first.app.pickUpSharedJobs()
        #expect(first.pipeline.state == .idle)

        // the process is killed: its work stops and the record it left is all that remains
        first.ctx.background.cancelAll()
        first.ctx.jobs.upsert(saved)
        let webpsBefore = first.webps.count

        let second = DetachRig(sharing: first, preview: true)         // a relaunch: the job is picked up from the store
        await second.app.pickUpSharedJobs()
        guard case .rendering = second.pipeline.state else {
            Issue.record("expected the relaunched app to follow the render, got \(second.pipeline.state)")
            return
        }
        await second.drive { if case .done = second.pipeline.state { true } else { false } }
        #expect(second.webps.count == webpsBefore + 1)
        #expect(second.ctx.jobs.all().isEmpty)
    }

    @Test func aServerChangeCancelsDetachedRunsAndEndsTheirActivity() async throws {
        let r = DetachRig()
        await r.toReady()
        r.pipeline.makeWebp()
        await r.drive { isRendering(r.pipeline) && r.pipeline.renderJobID != nil }
        let run = r.pipeline.liveRunID
        let handle = try #require(r.handle(forRun: run))
        r.pipeline.detach()
        #expect(r.ctx.background.count == 1)
        r.app.serverChanged()
        #expect(r.ctx.background.isEmpty)
        await r.manager.settle()
        #expect(handle.ended)
        #expect(r.ctx.jobs.all().isEmpty)
    }
}

// MARK: - The Live manager keeps exactly one activity per run

@MainActor
@Suite(.serialized)
struct DuplicateActivityTests {
    private func shareJob(_ rig: LiveRig) -> SharedJob {
        SharedJob(
            id: UUID(), origin: .shareExtension, link: URL(string: shortLink), sessionID: "PrEvIeWsession00000009",
            media: MediaInfo(name: "twitter_2105435404002562056", duration: 5.46, width: 480, height: 568, bytes: 1, isImage: false),
            trim: nil, stage: .ready, wantsTrim: true, pickedUp: false, updatedAt: rig.h.clock.now())
    }

    private func pushStarted(run: UUID, _ rig: LiveRig) -> FakeLiveHandle {
        FakeLiveHandle(
            attributes: LiveRunAttributes(run: run, input: "link", service: "x", ref: "2105435404002562056", origin: "share"),
            state: LiveContentState.samples["fetching_waking"]!,
            staleDate: rig.h.clock.now().addingTimeInterval(120), clock: { rig.h.clock.now() })
    }

    @Test func aPushStartThatLandsAfterTheAppTookTheRunOverIsEndedAndOursStays() async throws {
        let rig = LiveRig(push: false)
        rig.manager.start(observeLifecycle: false)
        let job = shareJob(rig)
        rig.h.ctx.jobs.upsert(job)
        rig.pipeline.resume(job)                                   // the app's own activity for the run
        await rig.settle()
        let ours = try #require(rig.adapter.handles.first)
        #expect(rig.adapter.requests.count == 1 && !ours.ended)

        let late = pushStarted(run: job.id, rig)                   // the server's push-start arrives afterwards
        rig.adapter.systemStarts(late)
        await rig.settle()
        #expect(late.ended && late.end?.dismissAt == nil, "the newcomer goes at once")
        #expect(!ours.ended)
        #expect(rig.adapter.handles.filter { !$0.ended }.count == 1)

        // and ours keeps following the run
        await rig.drive { rig.pipeline.state == .ready }
        #expect(ours.updates.last?.state.stage == .ready && late.updates.isEmpty)
    }

    @Test func aDuplicateFoundOnForegroundIsEndedToo() async throws {
        let rig = LiveRig(push: false)
        let job = shareJob(rig)
        rig.h.ctx.jobs.upsert(job)
        rig.pipeline.resume(job)
        await rig.settle()
        let ours = try #require(rig.adapter.handles.first)
        let late = pushStarted(run: job.id, rig)
        rig.adapter.handles.append(late)                           // no stream event: only a reconcile sees it
        rig.manager.foreground()
        await rig.settle()
        #expect(late.ended && !ours.ended)
        #expect(rig.adapter.handles.filter { !$0.ended }.count == 1)
    }

    @Test func aPushStartForAnotherRunIsStillAdopted() async throws {
        let rig = LiveRig(push: true, environment: .sandbox)
        rig.manager.start(observeLifecycle: false)
        let job = shareJob(rig)
        rig.h.ctx.jobs.upsert(job)
        rig.pipeline.resume(job)
        await rig.settle()
        let other = pushStarted(run: UUID(), rig)
        rig.adapter.systemStarts(other)
        await rig.settle()
        #expect(!other.ended, "only a duplicate of the current run is ended")
    }
}

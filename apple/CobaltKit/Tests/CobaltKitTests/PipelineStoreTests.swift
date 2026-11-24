import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// Phase 3 lane (a): the `PipelineStore` (`JobQueue`) as the one place this device's own work lives.
//
//  1. **No hidden work.** Dismissing or cancelling a job never hands anything to a hidden run (every run the app
//     carries is a job of the queue): a job with a device copy, a publish or a render still in flight is let go of (off the tray), stays in
//     `activity.items` until that settles, then retires.
//  2. **Minimize** keeps a job listed, counted and re-focusable, through the retire pass, and it leaves a line in "recent" when
//     it finishes.
//  3. The gallery make's poll is paced like the save's and the render's.
//  4. The busy period's number on the island is the one count (`activity.activeCount`).

/// How many times a call was made, readable from a `Sendable` client.
final class CallCounter: Sendable {
    private let count = Mutex(0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

@MainActor
private func isRendering(_ p: Pipeline) -> Bool {
    if case .rendering = p.state { return true }
    return false
}

extension DetachRig {
    /// A link whose original's download is held by `gate`: the run reaches the save with the copy onto the device still in
    /// flight (`keepRequest`).
    func startHoldingTheOriginal() async -> (pipeline: Pipeline, gate: Gate) {
        let gate = Gate()
        let base = ctx.client
        var stub = ScriptedClient(base: base)
        stub.downloadHook = { file, dest in
            if case .studioSource = file { await gate.wait() }
            return try await base.download(file, to: dest, progress: { _ in })
        }
        ctx.client = stub
        let p = pipeline
        p.start(link: URL(string: shortLink)!)
        await park(gate)
        return (p, gate)
    }

    /// Every run the app carries without a screen is a job of the queue (`activity.items` lists it): nothing hidden.
    func hasNothingHidden() -> Bool { ctx.background.runs.allSatisfy { run in queue.jobs.contains { $0.pipeline === run } } }
}

// MARK: - 1. Dismiss and cancel hide nothing

@MainActor
@Suite(.serialized)
struct PipelineStoreLifetimeTests {
    @Test func dismissingASavedJobWhoseCopyIsStillLandingKeepsItListedUntilTheFileIsHere() async throws {
        let r = DetachRig()
        let (p, gate) = await r.startHoldingTheOriginal()
        await r.drive { p.state == .ready }
        let job = try #require(r.job(of: p))
        let sid = try #require(p.sessionID)
        #expect(p.keepRequest != nil)

        r.queue.dismiss(job.id)
        #expect(r.hasNothingHidden(), "a dismiss never makes a hidden run")
        let kept = try #require(r.queue.job(job.id), "the copy is still coming: the job stays")
        #expect(kept.isReleased && r.queue.alongside.isEmpty && r.queue.focusedID == nil)
        let status = try #require(r.status(of: p))
        if case .deviceCopy = status.stage {} else { Issue.record("expected deviceCopy, got \(status.stage)") }
        #expect(status.isActive && r.app.activity.activeCount == 1 && r.app.activity.attentionCount == 0)

        // asking again changes nothing
        r.queue.dismiss(job.id)
        #expect(r.queue.job(job.id) != nil)

        await gate.open()
        await r.drive { r.isGone(p) }
        #expect(r.originals(session: sid).count == 1, "the copy landed")
        #expect(r.app.activity.items.isEmpty)
    }

    @Test func aDismissedJobThatSettlesWithAFailedCopyLeavesItsReceiptInRecent() async throws {
        let r = DetachRig()
        let (p, gate) = await r.startHoldingTheOriginal()
        await r.drive { p.state == .ready }
        let job = try #require(r.job(of: p))
        r.queue.dismiss(job.id)
        #expect(r.queue.job(job.id)?.isReleased == true)
        // the copy gives up (the engine's own retries are not what is tested here): nothing is in flight, and it failed
        p.keepRequest?.cancel()
        p.runToken = UUID()                                          // its follower answers into a run that is over: it says nothing
        p.keepRequest = nil
        p.localCopyState = .failed(code: "error.app.offline")
        await r.drive { r.isGone(p) }
        let recent = r.app.activity.items.filter { $0.id.hasPrefix("finished:") }
        #expect(recent.count == 1, "the failed copy is not lost with the dismiss: history \(r.app.unifiedQueue.finishedHistory.count), jobs \(r.queue.jobs.count)")
        await gate.open()
    }

    @Test func cancelWhileReadingFramesOnlyStopsTheFilmstripAndTheCopyKeepsGoing() async throws {
        let r = DetachRig()
        let (p, gate) = await r.startHoldingTheOriginal()
        await r.drive { if case .reading = p.state, p.keepRequest != nil { true } else { false } }
        guard case .reading = p.state else { Issue.record("expected reading, got \(p.state)"); return }
        let job = try #require(r.job(of: p))
        let sid = try #require(p.sessionID)

        await r.queue.cancel(job.id)
        #expect(r.queue.notice?.kind == .stoppedReading)
        #expect(p.state == .ready, "the save is done: the run settles as saved without its filmstrip")
        #expect(r.queue.job(job.id)?.isReleased == true)
        let status = try #require(r.status(of: p))
        if case .deviceCopy = status.stage {} else { Issue.record("expected deviceCopy, got \(status.stage)") }

        await gate.open()
        await r.drive { r.isGone(p) }
        #expect(r.originals(session: sid).count == 1, "the copy that was in flight still landed")
        #expect(r.app.activity.items.isEmpty)
    }

    @Test func cancelWhileReadingWithNothingElseInFlightEndsTheJob() async throws {
        let r = DetachRig()
        r.ctx.settings.keepVideosOnDevice = false
        let p = r.pipeline
        p.start(link: URL(string: shortLink)!)
        await r.drive { if case .reading = p.state { true } else { false } }
        guard case .reading = p.state else { return }                       // too quick to catch on this scenario
        let job = try #require(r.job(of: p))
        await r.queue.cancel(job.id)
        #expect(r.queue.notice?.kind == .stoppedReading && r.isGone(p))
    }

    @Test func cancellingARenderTheServerIsRunningKeepsTheJobUntilTheWebpIsMade() async throws {
        let r = DetachRig()
        await r.toReady()
        let p = r.pipeline
        p.makeWebp()
        await r.drive { isRendering(p) && p.renderJobID != nil }
        let job = try #require(r.job(of: p))

        await r.queue.cancel(job.id)
        #expect(r.hasNothingHidden())
        let kept = try #require(r.queue.job(job.id), "a render that is running cannot be called back: it is followed on")
        #expect(kept.isReleased && r.queue.focusedID == nil)
        #expect(r.queue.notice?.kind == .stoppedFollowing, "the card is let go of, as it always was")
        let status = try #require(r.status(of: p))
        if case .rendering = status.stage {} else { Issue.record("expected rendering, got \(status.stage)") }
        #expect(r.app.activity.activeCount == 1)

        await r.drive { r.isGone(p) }
        #expect(r.webps.count == 1 && r.app.activity.items.isEmpty)
    }

    /// The server started the queued render first: the cancel is refused (`started`), and the job goes on alongside.
    @Test func aQueuedRenderTheServerStartedFirstIsFollowedOnNotHidden() async throws {
        let rig = LineRig(.server)
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(job.pipeline.state == .ready)
        rig.server.withLine(at: rig.clock.now()) {
            _ = $0.enqueue(.init(kind: .save, sid: "x", job: nil, focused: false, duration: 40, mine: false, origin: "share", keyName: "iphone", link: nil, failure: nil), at: rig.clock.now())
        }
        job.pipeline.makeWebp()
        await rig.drive(until: { job.pipeline.line != nil }, maxVirtualSeconds: 20)
        #expect(job.pipeline.line != nil)
        rig.clock.jump(by: 45)                                    // the foreign job ended and this render started; the app has not polled
        await rig.queue.cancel(job.id)
        #expect(rig.queue.job(job.id)?.isReleased == true, "the server's render is not cancelled: the job is let go of and listed")
        #expect(rig.app.activity.status("job:\(job.id.uuidString)") != nil)
        await rig.drive(until: { rig.queue.job(job.id) == nil }, maxVirtualSeconds: 200)
        #expect(rig.queue.job(job.id) == nil && rig.app.activity.items.filter { $0.ref == .pipeline(job.id) }.isEmpty)
    }

    /// Every state a job can be dismissed or cancelled in, none of them leaves anything hidden, and what is still going is listed.
    @Test func everyDismissAndCancelLeavesNothingHidden() async throws {
        let rig = LineRig(.server)
        // a failed job, two saved ones, one waiting behind them in the line
        let jobs = rig.queue.add([.link(linkPrivate), .link(linkA), .link(linkB)], via: .review)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 200)
        func noLeak(_ what: String) {
            #expect(rig.ctx.background.runs.allSatisfy { run in rig.queue.jobs.contains { $0.pipeline === run } }, "\(what)")
        }
        await rig.queue.cancel(jobs[0].id)                       // failed: the cancel is a dismiss
        noLeak("failed"); #expect(rig.queue.job(jobs[0].id) == nil)
        rig.queue.dismiss(jobs[1].id)                            // saved, nothing in flight
        noLeak("saved"); #expect(rig.queue.job(jobs[1].id) == nil)
        await rig.queue.cancel(jobs[2].id)                       // saved
        noLeak("saved too"); #expect(rig.queue.jobs.isEmpty)

        // a save still running on the server: stop following, nothing of it is on this device
        let running = rig.queue.add([.link(linkA)], via: .review)[0]
        await rig.drive(until: { running.pipeline.sessionID != nil && running.pipeline.line == nil && running.isLive }, maxVirtualSeconds: 10)
        await rig.queue.cancel(running.id)
        noLeak("running"); #expect(rig.queue.notice?.kind == .stoppedFollowing && rig.queue.job(running.id) == nil)

        // a link still being checked, locally
        let checking = rig.queue.add([.link(linkB)], via: .paste)[0]
        await rig.queue.cancel(checking.id)
        noLeak("checking"); #expect(rig.queue.job(checking.id) == nil && rig.queue.notice?.kind == .cancelled)
        #expect(rig.app.activity.items.filter { $0.ref == .pipeline(checking.id) }.isEmpty)
    }

    @Test func dismissingAJobThatIsStillLiveAndHasWorkOfItsOwnStillListsIt() async throws {
        let r = DetachRig()
        await r.toReady()
        let p = r.pipeline
        p.makeWebp()
        await r.drive { isRendering(p) && p.renderJobID != nil }
        let job = try #require(r.job(of: p))
        r.queue.dismiss(job.id)                                  // a caller that dismisses a live render
        #expect(r.queue.job(job.id)?.isReleased == true && r.status(of: p) != nil)
        await r.drive { r.isGone(p) }
    }

    @Test func aReleasedJobIsStillOwnedByThisProcessSoAForegroundPickupLeavesItAlone() async throws {
        let r = DetachRig()
        await r.toReady()
        let p = r.pipeline
        p.makeWebp()
        await r.drive { isRendering(p) && p.renderJobID != nil }
        let id = p.liveRunID
        r.queue.dismiss(try #require(r.job(of: p)).id)
        #expect(r.ctx.background.owns(job: id), "the queue still carries it (its record is not taken over)")
        #expect(r.ctx.background.runs.contains { $0 === p }, "continued processing and the media checks see it")
        await r.drive { r.isGone(p) }
    }

    @Test func theShareExtensionNeverKeepsARunInAQueue() async throws {
        let r = DetachRig()
        r.ctx.background.allowsDetach = false
        let (p, gate) = await r.startHoldingTheOriginal()
        await r.drive { p.state == .ready }
        p.detach()
        #expect(p.state == .idle && r.isGone(p))
        await gate.open()
        await r.h.settle()
    }

    @Test func noJobQueueMeansReset() async throws {
        // a pipeline outside a queue (previews, the share sheet's own) has nowhere to be kept: detach is a reset
        let h = Harness(.shortClip)
        let p = Pipeline(context: h.ctx)
        p.start(link: URL(string: shortLink)!)
        await h.drive(until: { p.state == .ready })
        p.detach()
        #expect(p.state == .idle)
    }
}

// MARK: - 2. Minimize

@MainActor
@Suite(.serialized)
struct PipelineStoreMinimizeTests {
    @Test func aMinimizedLiveJobSurvivesTheRetirePassAndStaysCounted() async throws {
        let rig = LineRig(.serverBusyWithShare)
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.settle()
        #expect(rig.queue.focusedID == job.id && job.pipeline.line != nil)
        #expect(rig.app.activity.minimize(job.id))
        #expect(rig.queue.focusedID == nil)
        await rig.run(for: 3)                                       // the share ahead of it holds the server for 15 s
        rig.queue.retireLapsed()
        #expect(rig.queue.job(job.id) != nil, "a job that is still going is never retired")
        #expect(rig.app.activity.activeCount == 1)
        let status = try #require(rig.app.activity.status("job:\(job.id.uuidString)"))
        #expect(status.canFocus && status.canCancel && !status.isFocused)
    }

    @Test func aMinimizedJobThatFinishesLeavesALineInRecentAndIsGoneFromTheQueue() async throws {
        let rig = LineRig(.server)
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        rig.app.activity.minimize(job.id)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 100)
        #expect(job.pipeline.state == .ready)
        let id = "job:\(job.id.uuidString)"
        #expect(rig.app.activity.status(id) != nil && rig.app.activity.activeCount == 0, "finished: listed, not running")
        // its time beside the live ones passes
        await rig.run(for: JobQueue.finishedLinger + 2)
        #expect(rig.queue.job(job.id) == nil, "the finished job left the queue")
        #expect(rig.app.activity.status(id) == nil)
        let recent = rig.app.activity.summary.recent(limit: 10)
        #expect(recent.contains { $0.id.hasPrefix("finished:") }, "a line under recent: \(recent.map(\.id))")
    }

    @Test func aFinishedJobCanBeMinimizedAndComesBack() async throws {
        let rig = LineRig(.server)
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 100)
        #expect(rig.queue.focusedID == job.id)
        #expect(rig.app.activity.minimize(job.id), "a finished job is listed after minimize")
        #expect(rig.queue.focusedID == nil)
        await rig.app.activity.perform(.focus, on: "job:\(job.id.uuidString)")
        #expect(rig.queue.focusedID == job.id && rig.app.pipeline === job.pipeline)
    }

    @Test func aPickerWaitsForTheOwnerMinimizedOrNot() async throws {
        let h = Harness(.picker)
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.driveToSettled()
        let app = h.app
        let job = try #require(app.queue.jobs.first)
        #expect(job.isPicker)
        let id = "job:\(job.id.uuidString)"
        #expect(app.activity.status(id)?.stage == .awaitingChoice)
        #expect(app.activity.minimize(job.id))
        #expect(app.activity.status(id)?.stage == .awaitingChoice && app.queue.focusedID == nil)
        app.queue.retireLapsed()
        #expect(app.queue.job(job.id) != nil, "a picker is never retired: it waits for the owner")
        await app.activity.perform(.focus, on: id)
        #expect(app.queue.focusedID == job.id)
    }

    @Test func aMinimizedJobThatFailsComesBackNeedingAttention() async throws {
        let rig = LineRig(.server)
        let job = rig.queue.add([.link(linkPrivate)], via: .paste)[0]
        rig.app.activity.minimize(job.id)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 100)
        #expect(job.isFailed)
        #expect(rig.app.activity.attentionCount == 1 && rig.app.activity.activeCount == 0)
        let status = try #require(rig.app.activity.status("job:\(job.id.uuidString)"))
        #expect(status.needsAttention && status.canDismiss, "back in the activity's attention list")
    }
}

// MARK: - 3. The gallery make's poll is paced

@MainActor
struct MakePollPacingTests {
    private let clock = VirtualClock()
    private let working = MakeStatus.pending(phase: .composing, done: 3, total: 10, queueAhead: nil)

    @Test func theSameReplyAgainDoublesTheGapAndNeverPastTenSeconds() {
        var pacer = PollPacer()
        pacer.observe(working, clock: clock)
        #expect(pacer.interval == 1)
        pacer.observe(working, clock: clock)
        #expect(pacer.interval == 2)
        pacer.observe(working, clock: clock)
        #expect(pacer.interval == 4)
        for _ in 0..<6 { pacer.observe(working, clock: clock) }
        #expect(pacer.interval == PollPacer.ceiling)
    }

    @Test func aChangedReplyIsNewsAndPutsTheGapBack() {
        var pacer = PollPacer()
        for _ in 0..<4 { pacer.observe(working, clock: clock) }
        #expect(pacer.interval > 1)
        pacer.observe(.pending(phase: .composing, done: 4, total: 10, queueAhead: nil), clock: clock)
        #expect(pacer.interval == 1)
        pacer.observe(.pending(phase: .encoding, done: 0, total: 6, queueAhead: nil), clock: clock)
        #expect(pacer.interval == 1)
    }

    @Test func aMakeNeverPollsMoreThanOncePerSecondWhileTheServerAnswersAtOnce() async throws {
        let h = Harness(.galleryInstagram)
        let counter = CallCounter()
        let base = try #require(h.ctx.client as? PreviewClient)
        var client = ForwardingClient(base: base)
        client.makeStatusCalls = counter
        h.ctx.client = client
        let p = h.pipeline
        p.start(link: URL(string: "https://www.instagram.com/p/Ddy0-gpGg5U/")!)
        await h.driveToSettled()
        guard case .gallery = p.state else { Issue.record("\(p.state)"); return }
        let plan = GalleryMake.slideshow(SlideshowPlan(format: .webp, items: Array(0..<10), photoSeconds: 2, quality: .med, width: 480))
        await p.make(plan)
        let started = h.clock.elapsed
        await h.drive(until: { !(p.galleryRun?.make.isActive ?? true) })
        let elapsed = h.clock.elapsed - started
        let polls = counter.value
        #expect(polls >= 1, "the make was followed")
        #expect(Double(polls) <= elapsed / PollPacer.floor + 2, "\(polls) polls in \(elapsed) s: one a second at most")
        if case .done? = p.galleryRun?.make {} else { Issue.record("\(String(describing: p.galleryRun?.make))") }
    }
}

// MARK: - 4. The island says the one count

@MainActor
@Suite(.serialized)
struct IslandCountTests {
    /// The busy period's writes in order (they carry `rows`), on any activity the fake ActivityKit holds.
    private func periodWrites(_ adapter: FakeLiveAdapter) -> [JobLiveState] {
        adapter.handles.flatMap { handle -> [JobLiveState] in
            let first = adapter.requests.first { $0.attributes.id == handle.attributes.id }.map(\.state)
            return ([first].compactMap { $0 } + handle.updates.map(\.state)).filter { $0.rows != nil }
        }
    }

    @Test func aLiveJobBesideACopyStillLandingMakesABusyPeriodThatSaysTwoGoing() async throws {
        let r = DetachRig()
        let (a, gate) = await r.startHoldingTheOriginal()
        await r.drive { a.state == .ready }
        #expect(r.queue.live.isEmpty && r.app.activity.activeCount == 1, "a saved job whose copy is coming: counted, not live")
        #expect(periodWrites(r.adapter).isEmpty)

        // one live job and one count of two: the island speaks for both
        let b = r.queue.add([.link(URL(string: shortLink)!)], via: .review)[0]
        #expect(b.isLive && r.app.activity.activeCount == 2)
        // the saved job's own activity is kept for the period; its next write waits out the one-a-second rule
        await r.drive { !periodWrites(r.adapter).isEmpty }
        let first = try #require(periodWrites(r.adapter).last, "a period began with one live job: \(r.manager.inBusyPeriod), live \(r.queue.live.count)")
        #expect(first.count("going") == r.app.activity.activeCount, "\(first.headline) vs \(r.app.activity.activeCount)")
        #expect(first.compact == "0/2" && first.rows?.count == 1)

        await gate.open()
        await r.drive { r.queue.live.isEmpty }
        await r.manager.settle()
        let end = try #require(r.adapter.handles.last?.end?.state)
        #expect(end.isFinishedPeriod, "the period ends as it always did: when no job of the app is live")
    }

    @Test func theBusyPreviewsIslandNumberIsTheSheetsNumberAndFollowsADownloadEnding() async throws {
        let queue = QueueRig(.busy)
        let adapter = FakeLiveAdapter()
        let clock = queue.clock
        adapter.clock = { clock.now() }
        let manager = LiveActivityManager(context: queue.app.ctx, adapter: adapter, environment: nil, grace: FakeGrace())
        queue.app.ctx.live = manager
        queue.app.liveManager = manager
        await queue.unified.refresh()
        queue.app.queue.add([.link(linkA)], via: .paste)                     // an event of the queue: the period is looked at
        await queue.settle()
        await manager.settle()
        let activity = queue.app.activity
        let state = try #require(periodWrites(adapter).last, "an activity was asked for")
        #expect(activity.activeCount > queue.app.queue.live.count, "downloads and the server's rows are in the count")
        #expect(state.count("going") == activity.activeCount, "\(state.headline) vs \(activity.activeCount)")
        #expect((state.compact ?? "").hasSuffix("/\(state.count("done") + state.count("failed") + activity.activeCount)"))

        // a download ends: no event of the app's own jobs, and the number follows
        let before = activity.activeCount
        let running = try #require(queue.app.offlineDownloads.rows.first { !$0.isFailed })
        queue.app.offlineDownloads.stop(key: running.id)
        #expect(activity.activeCount == before - 1)
        await queue.run(for: 3)                                              // inside the share's 15 s: the jobs still wait
        await manager.settle()
        let after = try #require(periodWrites(adapter).last)
        #expect(queue.app.queue.live.count == 3, "no job of the app ended meanwhile")
        #expect(after.count("going") == activity.activeCount && after.count("going") == before - 1, "\(after.headline), count \(activity.activeCount)")
    }

    @Test func withoutAModelTheNumberIsTheRowsOwnAndAGivenCountReplacesIt() async throws {
        // `JobLive.many` with no count keeps the rows' own: the fixture's shape
        let a = JobLive.job(save: LiveContentState(stage: .saving, rail: 1, since: 1), attributes: LiveRunAttributes(run: UUID(), input: "link", service: "x", ref: "1", origin: "app"))
        let b = JobLive.job(save: LiveContentState(stage: .done, rail: 3, since: 2), attributes: LiveRunAttributes(run: UUID(), input: "link", service: "x", ref: "2", origin: "app"))
        let plain = JobLive.many(id: "p", jobs: [a, b], since: 1).state
        #expect(plain.headline == "1 done, 1 going" && plain.compact == "1/2")
        let counted = JobLive.many(id: "p", jobs: [a, b], since: 1, going: 4).state
        #expect(counted.headline == "1 done, 4 going" && counted.compact == "1/5" && counted.rows?.count == 2)
        let none = JobLive.many(id: "p", jobs: [a, b], since: 1, going: 0).state
        #expect(none.headline == "1 done" && none.phase == .done)
    }
}

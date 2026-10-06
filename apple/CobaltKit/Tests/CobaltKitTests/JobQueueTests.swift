import Foundation
import Testing
@testable import CobaltKit

/// The queue (CONTRACT-PARALLEL.md 3.2, section 13), in both line modes where it applies.
@MainActor
struct JobQueueTests {
    // MARK: Focus

    @Test(arguments: [LinePreviewMode.server, .off])
    func aSinglePasteOnAQuietScreenFocusesAndChecksTheLinkFirst(mode: LinePreviewMode) async {
        let rig = LineRig(mode)
        let jobs = rig.queue.add([.link(linkA)], via: .paste)
        #expect(jobs.count == 1 && rig.queue.focusedID == jobs[0].id)
        #expect(rig.app.pipeline === jobs[0].pipeline, "AppModel.pipeline is the focused job's pipeline")
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(jobs[0].pipeline.state == .ready)
        #expect(rig.calls.first == "POST /", "the link is checked with cobalt before the save: \(rig.calls)")
        #expect(rig.queue.focusedID == jobs[0].id)
    }

    @Test func aBatchNeverFocusesAndSkipsTheCheckOnAServerLine() async {
        let rig = LineRig(.server)
        let jobs = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        #expect(jobs.count == 3 && rig.queue.focusedID == nil)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 120)
        #expect(rig.count("POST /") == 0, "each link goes straight to the server's line: \(rig.calls)")
        #expect(rig.calls.filter { $0.hasPrefix("POST /studio") }.allSatisfy { $0.contains("queue=true") })
        #expect(rig.calls.filter { $0.hasPrefix("POST /studio") }.count == 3)
        #expect(jobs.allSatisfy { $0.pipeline.state == .ready })
        #expect(rig.queue.focusedID == nil)
    }

    @Test func aBatchOnADeviceLineChecksEachLinkAndTakesTurns() async {
        let rig = LineRig(.off)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 120)
        #expect(rig.count("POST /") == 2, "no server line: the check comes first for every link")
        #expect(jobs.allSatisfy { $0.pipeline.state == .ready } && rig.queue.focusedID == nil)
    }

    @Test func aSecondPasteDuringAFocusGoesAlongsideAndNeverTakesIt() async {
        let rig = LineRig(.server)
        let first = rig.queue.add([.link(linkA)], via: .paste)[0]
        let second = rig.queue.add([.link(linkB)], via: .paste)[0]
        #expect(rig.queue.focusedID == first.id && second.id != first.id)
        #expect(rig.queue.alongside.map(\.id) == [second.id])
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 120)
        #expect(rig.queue.focusedID == first.id, "a background landing never moves the focus")
        #expect(second.pipeline.state == .ready)
    }

    @Test func aBackgroundLandingKeepsTheFocus() async {
        let rig = LineRig(.server)
        let focused = rig.queue.add([.link(linkA)], via: .paste)[0]
        let others = rig.queue.add([.link(linkB), .link(linkC)], via: .review)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 120)
        #expect(others.allSatisfy { $0.pipeline.state == .ready })
        #expect(rig.queue.focusedID == focused.id && rig.queue.focused?.pipeline === rig.app.pipeline)
    }

    @Test func aShortcutNeverFocuses() async {
        let rig = LineRig(.server)
        let jobs = rig.queue.add([.link(linkA)], via: .shortcut)
        #expect(rig.queue.focusedID == nil && jobs[0].origin == .shortcut)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(jobs[0].pipeline.state == .ready && rig.queue.focusedID == nil)
        #expect(rig.count("POST /") == 0, "a Shortcut sends the link straight to the line")
    }

    @Test func aRelaunchWithOneInFlightJobOnAQuietScreenTakesTheFocus() async {
        let rig = LineRig(.server)
        let created = try? await rig.client.createStudio(link: linkA, public: nil, queue: true, title: nil)
        let shared = SharedJob(
            id: UUID(), origin: .app, link: linkA, sessionID: created?.id, media: nil, trim: nil, stage: .saving,
            wantsTrim: false, pickedUp: false, updatedAt: rig.clock.now())
        let jobs = rig.queue.add([.shared(shared)], via: .relaunch)
        #expect(jobs[0].id == shared.id && rig.queue.focusedID == shared.id && jobs[0].origin == .relaunch)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(jobs[0].pipeline.state == .ready)
    }

    @Test func aLinkThatIsAlreadyALiveJobIsNotAddedTwice() async {
        let rig = LineRig(.server)
        let first = rig.queue.add([.link(linkA)], via: .paste)
        let again = rig.queue.add([.link(linkA)], via: .paste)
        #expect(again[0].id == first[0].id && rig.queue.jobs.count == 1)
        let dup = rig.queue.add([.link(linkB), .link(linkB)], via: .review)
        #expect(dup[0].id == dup[1].id && rig.queue.jobs.count == 2)
        #expect(rig.queue.liveJob(for: linkA)?.id == first[0].id)
    }

    // MARK: Direct starts (the old UI, library flows)

    @Test func aRunStartedByHandOnTheIdlePipelineBecomesTheFocusedJob() async {
        let rig = LineRig(.off)
        let idle = rig.app.pipeline
        #expect(rig.queue.jobs.isEmpty)
        idle.start(link: linkA)
        #expect(rig.queue.jobs.count == 1 && rig.queue.focused?.pipeline === idle && rig.app.pipeline === idle)
        #expect(rig.queue.idlePipeline !== idle, "a new idle pipeline waits for the next run")
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(idle.state == .ready)
        idle.reset()
        #expect(rig.queue.jobs.isEmpty && rig.queue.focusedID == nil)
        #expect(rig.app.pipeline === idle, "the pipeline the owner holds is the idle one again")
    }

    // MARK: Closing and cancelling

    @Test func unfocusMidRenderKeepsTheRenderAndItsSharedJob() async {
        let rig = LineRig(.server)
        rig.ctx.recordsJobs = true
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(job.pipeline.state == .ready)
        job.pipeline.makeWebp()
        await rig.drive(until: { job.pipeline.renderJobID != nil }, maxVirtualSeconds: 30)   // the server has the job: its record is written
        rig.queue.unfocus()
        #expect(rig.queue.focusedID == nil && rig.queue.job(job.id) != nil)
        #expect(job.isLive, "closing the focus does not stop the render")
        #expect(rig.app.jobs.all().contains { $0.id == job.id && { if case .rendering = $0.stage { return true } else { return false } }($0) },
                "the render keeps its SharedJob, so a relaunch can follow it")
        #expect(rig.app.pipeline !== job.pipeline, "the screen no longer shows it")
        #expect(rig.queue.alongside.map(\.id) == [job.id])
        await rig.drive(until: { if case .done = job.pipeline.state { return true } else { return false } }, maxVirtualSeconds: 120)
        if case .done = job.pipeline.state {} else { Issue.record("the render should finish alongside: \(job.pipeline.state)") }
    }

    @Test func cancelWhileWaitingInTheDeviceLineSendsNothingAndRemovesTheJob() async {
        let rig = LineRig(.off)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.drive(until: { jobs[1].pipeline.line != nil }, maxVirtualSeconds: 30)
        #expect(jobs[1].pipeline.line == .inLine(2, behind: nil), "the second save waits for the first on this device")
        await rig.queue.cancel(jobs[1].id)
        #expect(rig.queue.job(jobs[1].id) == nil)
        #expect(rig.queue.notice?.kind == .cancelled)
        #expect(rig.calls.filter { $0.hasPrefix("DELETE") }.isEmpty && rig.calls.filter { $0.hasPrefix("POST /studio") }.count <= 1)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(jobs[0].pipeline.state == .ready)
    }

    @Test func cancelAQueuedJobOnTheServerSendsDeleteAndRemovesIt() async throws {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.settle()
        let sid = try #require(jobs[1].pipeline.sessionID)
        await rig.queue.cancel(jobs[1].id)
        #expect(rig.calls.contains("DELETE line \(sid)"))
        #expect(rig.queue.job(jobs[1].id) == nil && rig.queue.notice?.kind == .cancelled)
        await rig.drive(until: { jobs[0].pipeline.state == .ready }, maxVirtualSeconds: 60)
        #expect(jobs[0].pipeline.state == .ready, "the other save is untouched")
    }

    @Test func cancelWhoseTurnCameFirstSaysStoppedFollowing() async throws {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA)], via: .review)
        await rig.settle()
        #expect(jobs[0].pipeline.line != nil)
        rig.clock.jump(by: 16)                            // the share ended and the server started this save; the app has not polled
        await rig.queue.cancel(jobs[0].id)
        #expect(rig.queue.notice?.kind == .stoppedFollowing)
        #expect(rig.queue.job(jobs[0].id) == nil)
        #expect(rig.calls.contains { $0.hasPrefix("DELETE line") }, "it asked, and the server said it had started")
    }

    @Test func cancelThatCannotReachTheServerKeepsTheJob() async {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA)], via: .review)
        await rig.settle()
        rig.server.cancelFails = true
        await rig.queue.cancel(jobs[0].id)
        #expect(rig.queue.job(jobs[0].id) != nil && rig.queue.notice?.kind == .couldntCancel)
    }

    @Test func cancelOnTheServerThatIsRunningStopsFollowingWithoutAskingToCancel() async {
        let rig = LineRig(.server)
        let jobs = rig.queue.add([.link(linkA)], via: .review)
        await rig.drive(until: { jobs[0].pipeline.sessionID != nil && jobs[0].pipeline.line == nil && jobs[0].isLive }, maxVirtualSeconds: 10)
        await rig.queue.cancel(jobs[0].id)
        #expect(rig.queue.notice?.kind == .stoppedFollowing)
        #expect(rig.calls.filter { $0.hasPrefix("DELETE") }.isEmpty, "a running save cannot be cancelled, so nothing pretends to")
    }

    @Test func aQueuedWebpCancelsBackToTheTrim() async {
        let rig = LineRig(.server)
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        // a foreign job holds the server: this render waits
        rig.server.withLine(at: rig.clock.now()) {
            _ = $0.enqueue(.init(kind: .save, sid: "x", job: nil, focused: false, duration: 40, mine: false, origin: "share", keyName: "iphone", link: nil, failure: nil), at: rig.clock.now())
        }
        job.pipeline.makeWebp()
        await rig.drive(until: { job.pipeline.line != nil }, maxVirtualSeconds: 20)
        #expect(job.pipeline.line != nil)
        await rig.queue.cancel(job.id)
        #expect(rig.queue.notice?.kind == .cancelledWebp)
        #expect(job.pipeline.state == .ready && rig.queue.job(job.id) != nil, "the save stays, the trim is back")
    }

    // MARK: Retry, dismiss, ordering

    @Test func threeLinksWithOneFailingLeaveTheOtherTwoSaved() async {
        let rig = LineRig(.server)
        let jobs = rig.queue.add([.link(linkA), .link(linkPrivate), .link(linkB)], via: .review)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 200)
        #expect(jobs[0].pipeline.state == .ready && jobs[2].pipeline.state == .ready)
        if case .failed(.fetchFailed) = jobs[1].pipeline.state {} else { Issue.record("the private post fails: \(jobs[1].pipeline.state)") }
        #expect(rig.queue.summary == JobSummary(live: 0, waiting: 0, finished: 2, failed: 1))
    }

    @Test func retryGoesToTheBackOfTheLine() async {
        let rig = LineRig(.server)
        let jobs = rig.queue.add([.link(linkPrivate), .link(linkA)], via: .review)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 100)
        guard case .failed = jobs[0].pipeline.state else { Issue.record("expected a failure"); return }
        rig.queue.retry(jobs[0].id)
        #expect(rig.queue.job(jobs[0].id) == nil, "the failed job is replaced")
        #expect(rig.queue.jobs.count == 2 && rig.queue.jobs.last.map { Self.link($0) } == linkPrivate, "same input, at the back")
        #expect(rig.queue.jobs.first?.id == jobs[1].id)
    }

    @Test func dismissRemovesAFailedJob() async {
        let rig = LineRig(.server)
        let jobs = rig.queue.add([.link(linkPrivate)], via: .review)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(rig.queue.alongside.map(\.id) == [jobs[0].id])
        rig.queue.dismiss(jobs[0].id)
        #expect(rig.queue.jobs.isEmpty)
    }

    @Test func alongsideOrderIsServerThenNetworkStepsThenLineThenFailedThenFinished() async {
        let rig = LineRig(.server)
        // 1: a save that finished a moment ago and one that failed
        let failed = rig.queue.add([.link(linkPrivate)], via: .review)[0]
        let done = rig.queue.add([.link(linkB)], via: .review)[0]
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        // 2: the server is held by a foreign share; two of ours queue behind it
        rig.server.withLine(at: rig.clock.now()) {
            _ = $0.enqueue(.init(kind: .save, sid: "x", job: nil, focused: false, duration: 60, mine: false, origin: "share", keyName: "iphone", link: nil, failure: nil), at: rig.clock.now())
        }
        let queued = rig.queue.add([.link(linkA), .link(linkC)], via: .review)
        await rig.settle()
        // 3: a link being checked (no session yet): a single paste while something is live goes alongside and checks first
        let checking = rig.queue.add([.link(URL(string: "https://x.com/i/status/778")!)], via: .paste)[0]
        #expect(rig.queue.focusedID == nil, "something is live, so the paste does not take the focus")
        let order = rig.queue.alongside.map(\.id)
        let rank = { (job: Job) in order.firstIndex(of: job.id) ?? -1 }
        #expect(rank(checking) < rank(queued[0]), "network steps before the line: \(order)")
        #expect(rank(queued[0]) < rank(queued[1]), "line order")
        #expect(rank(queued[1]) < rank(failed), "failed after the waiting ones")
        #expect(rank(failed) < rank(done), "a job that just finished is last")
    }

    @Test func summaryCountsLiveWaitingFinishedAndFailed() async {
        let rig = LineRig(.serverBusyWithShare)
        _ = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.settle()
        #expect(rig.queue.summary == JobSummary(live: 2, waiting: 2, finished: 0, failed: 0))
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 100)
        #expect(rig.queue.summary == JobSummary(live: 0, waiting: 0, finished: 2, failed: 0))
    }

    @Test func clearFinishedKeepsFailedAndTheFocus() async {
        let rig = LineRig(.server)
        let focus = rig.queue.add([.link(linkA)], via: .paste)[0]
        let jobs = rig.queue.add([.link(linkB), .link(linkPrivate)], via: .review)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 100)
        rig.queue.clearFinished()
        #expect(rig.queue.job(jobs[0].id) == nil)
        #expect(rig.queue.job(jobs[1].id) != nil && rig.queue.job(focus.id) != nil)
    }

    // MARK: Uploads

    @Test func anUploadQueuesBehindAShareOnAServerLineAndLands() async throws {
        let rig = LineRig(.serverBusyWithShare)
        let file = try makeTempFile("clip.mov", bytes: 200_000)
        let jobs = rig.queue.add([.file(file, photosAssetID: nil)], via: .shortcut)
        await rig.drive(until: { jobs[0].pipeline.line != nil }, maxVirtualSeconds: 60)
        #expect(jobs[0].pipeline.line != nil, "the adopt joined the line: the answer carried queued and queue_ahead")
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 200)
        #expect(jobs[0].pipeline.state == .ready && jobs[0].pipeline.line == nil)
    }

    @Test func anUploadOnADeviceLineWaitsOutABusyServerThroughTheItemRoute() async throws {
        let rig = LineRig(.deviceBusy(seconds: 20))
        let file = try makeTempFile("clip.mov", bytes: 200_000)
        let jobs = rig.queue.add([.file(file, photosAssetID: nil)], via: .shortcut)
        await rig.drive(until: { rig.settled(jobs[0]) }, maxVirtualSeconds: 200)
        #expect(jobs[0].pipeline.state == .ready, "\(jobs[0].pipeline.state)")
        #expect(rig.calls.filter { $0.hasPrefix("POST library/items") }.count >= 1, "the item route retried after the busy adopt: \(rig.calls)")
        #expect(rig.queue.localLine.isFree, "the slot is released once the server has read the upload")
    }

    @Test func aDeviceLineIsFreeAgainAfterEveryJobEnds() async {
        let rig = LineRig(.off)
        let jobs = rig.queue.add([.link(linkA), .link(linkPrivate), .link(linkB)], via: .review)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 200)
        #expect(jobs.count == 3 && rig.queue.localLine.isFree && rig.queue.localLine.holders.isEmpty)
    }

    // MARK: Device mode waiting

    @Test func aForeignBusyKeepsAJobWaitingPastSixtySecondsAndFailsAfterTenMinutes() async {
        let rig = LineRig(.deviceBusy(seconds: 100_000))
        let job = rig.queue.add([.link(linkA)], via: .review)[0]
        await rig.run(for: 70)
        if case .fetching = job.pipeline.state {} else { Issue.record("still waiting at 70 s: \(job.pipeline.state)") }
        if case .serverBusy? = job.pipeline.line {} else { Issue.record("busy elsewhere: \(String(describing: job.pipeline.line))") }
        await rig.drive(until: { rig.settled(job) }, maxVirtualSeconds: 700)
        #expect(job.pipeline.state == .failed(.serverBusy))
        #expect(rig.clock.elapsed >= 590 && rig.clock.elapsed <= 640, "the ceiling is 10 minutes: \(rig.clock.elapsed)")
    }

    @Test func aBusyServerThatFreesUpLetsTheJobThrough() async {
        let rig = LineRig(.deviceBusy(seconds: 25))
        let job = rig.queue.add([.link(linkA)], via: .review)[0]
        await rig.drive(until: { rig.settled(job) }, maxVirtualSeconds: 200)
        #expect(job.pipeline.state == .ready && job.pipeline.line == nil)
    }

    @Test func renderBusyWaitsInsteadOfFailingOnADeviceLine() async {
        let rig = LineRig(.deviceBusy(seconds: 0))
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(job.pipeline.state == .ready)
        rig.server.withLine(at: rig.clock.now()) { $0.foreignUntil = rig.clock.now().addingTimeInterval(40) }
        job.pipeline.makeWebp()
        await rig.run(for: 20)
        if case .rendering = job.pipeline.state {} else { Issue.record("a busy webp waits: \(job.pipeline.state)") }
        await rig.drive(until: { if case .done = job.pipeline.state { return true } else { return job.isFailed } }, maxVirtualSeconds: 200)
        if case .done = job.pipeline.state {} else { Issue.record("it renders once the server is free: \(job.pipeline.state)") }
    }

    @Test func anOldFlowOnTheHomePipelineKeepsTodaysSixtySecondBusyRetry() async {
        let rig = LineRig(.deviceBusy(seconds: 100_000))
        rig.app.pipeline.start(link: linkA)                 // not through `add`: today's flow
        await rig.drive(until: { rig.settled(rig.queue.jobs[0]) }, maxVirtualSeconds: 200)
        #expect(rig.queue.jobs[0].pipeline.state == .failed(.serverBusy))
        #expect(rig.clock.elapsed < 90, "60 s, as before: \(rig.clock.elapsed)")
    }

    // MARK: Server mode

    @Test func lineFullFailsTheJobAsLineFull() async {
        let rig = LineRig(.serverFull)
        let jobs = rig.queue.add([.link(linkA)], via: .review)
        await rig.drive(until: { rig.settled(jobs[0]) }, maxVirtualSeconds: 30)
        #expect(jobs[0].pipeline.state == .failed(.lineFull))
        #expect(PipelineFailure.lineFull == .server(code: "error.studio.line_full"))
    }

    @Test func aRenderFromTheFocusSendsPriorityFocused() async {
        let rig = LineRig(.server)
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        job.pipeline.makeWebp()
        await rig.drive(until: { if case .done = job.pipeline.state { return true } else { return job.isFailed } }, maxVirtualSeconds: 200)
        #expect(rig.calls.contains("POST render queue=true priority=focused"), "\(rig.calls)")
        if case .done = job.pipeline.state {} else { Issue.record("webp: \(job.pipeline.state)") }
    }

    @Test func aFocusedWebpGoesAheadOfWaitingSavesOnTheServer() async {
        let rig = LineRig(.server)
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        // a batch of three saves fills the line, then the webp is asked for
        let batch = rig.queue.add([.link(linkB), .link(linkC), .link(URL(string: "https://x.com/i/status/9")!)], via: .review)
        await rig.run(for: 1)
        job.pipeline.makeWebp()
        await rig.run(for: 1)
        var finishOrder: [String] = []
        await rig.drive(until: {
            if finishOrder.isEmpty, case .done = job.pipeline.state { finishOrder.append("webp") }
            return rig.queue.jobs.allSatisfy { !$0.isLive }
        }, maxVirtualSeconds: 300)
        let landedBeforeLast = batch.filter { $0.pipeline.state == .ready }.count
        #expect(finishOrder == ["webp"] && landedBeforeLast == 3)
        if case .done = job.pipeline.state {} else { Issue.record("webp: \(job.pipeline.state)") }
    }

    // MARK: Server change

    @Test func aServerChangeCancelsEveryJobAndSendsNothingToTheOldServer() async {
        let rig = LineRig(.serverBusyWithShare)
        let a = rig.queue.add([.link(linkA)], via: .paste)[0]
        _ = rig.queue.add([.link(linkB), .link(linkC)], via: .review)
        await rig.settle()
        let before = rig.calls.count
        rig.app.serverChanged()
        #expect(rig.queue.jobs.isEmpty && rig.queue.focusedID == nil)
        #expect(a.pipeline.state == .idle)
        #expect(rig.calls.count == before, "nothing is sent to the server the jobs belonged to")
    }

    // MARK: Options

    @Test func aTitleAndTheVisibilityGoWithTheCreate() async {
        let rig = LineRig(.server)
        rig.app.settings.newSavesPublic = false
        let jobs = rig.queue.add([.link(linkA)], via: .shortcut, options: JobOptions(title: "the good part", makePublic: true))
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(rig.calls.contains("POST /studio queue=true title=the good part"))
        #expect(rig.client.visibilityState.saves == ["create public"], "makePublic overrides the setting")
        #expect(jobs[0].pipeline.runTitle == "the good part")
        // several inputs: the title is for one-input adds only
        let many = rig.queue.add([.link(linkB), .link(linkC)], via: .shortcut, options: JobOptions(title: "ignored"))
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 120)
        #expect(many.allSatisfy { $0.pipeline.runTitle == nil })
        #expect(rig.calls.filter { $0.contains("title=ignored") }.isEmpty)
    }

    @Test func theAppSettingDecidesWhenMakePublicIsNil() async {
        let rig = LineRig(.server)
        rig.app.settings.newSavesPublic = true
        _ = rig.queue.add([.link(linkA)], via: .shortcut)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 60)
        #expect(rig.client.visibilityState.saves == ["create public"])
    }

    // MARK: Acceptance (Shortcuts)

    @Test func acceptedReturnsOnServerWithThePostKeyForALink() async throws {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA)], via: .shortcut)
        var answers: [Job.ID: JobAcceptance] = [:]
        let task = Task { @MainActor in answers = await rig.queue.accepted(jobs.map(\.id), timeout: 20) }
        await rig.drive(until: { !answers.isEmpty }, maxVirtualSeconds: 25)
        await task.value
        let sid = try #require(jobs[0].pipeline.sessionID)
        #expect(answers[jobs[0].id] == .onServer(session: sid, postKey: sid, queued: true, ahead: 1))
    }

    @Test func acceptedReportsAFailureBeforeTheServerAnswered() async {
        let rig = LineRig(.serverFull)
        let jobs = rig.queue.add([.link(linkA)], via: .shortcut)
        var answers: [Job.ID: JobAcceptance] = [:]
        let task = Task { @MainActor in answers = await rig.queue.accepted(jobs.map(\.id), timeout: 20) }
        await rig.drive(until: { !answers.isEmpty }, maxVirtualSeconds: 25)
        await task.value
        #expect(answers[jobs[0].id] == .failed(.lineFull))
    }

    @Test func acceptedIsStillLocalAtTheTimeout() async {
        let rig = LineRig(.deviceBusy(seconds: 100_000))
        let jobs = rig.queue.add([.link(linkA)], via: .shortcut)
        var answers: [Job.ID: JobAcceptance] = [:]
        let task = Task { @MainActor in answers = await rig.queue.accepted(jobs.map(\.id), timeout: 5) }
        await rig.drive(until: { !answers.isEmpty }, maxVirtualSeconds: 20)
        await task.value
        #expect(answers[jobs[0].id] == .stillLocal)
        #expect(rig.clock.elapsed >= 5 && rig.clock.elapsed < 15)
    }

    @Test func acceptedAnUploadUsesTheItemIdAsThePostKey() async throws {
        let rig = LineRig(.server)
        let file = try makeTempFile("clip.mov", bytes: 200_000)
        let jobs = rig.queue.add([.file(file, photosAssetID: nil)], via: .shortcut, options: JobOptions(title: "my clip"))
        var answers: [Job.ID: JobAcceptance] = [:]
        let task = Task { @MainActor in answers = await rig.queue.accepted(jobs.map(\.id), timeout: 60) }
        await rig.drive(until: { !answers.isEmpty }, maxVirtualSeconds: 90)
        await task.value
        guard case .onServer(let session, let postKey, _, _)? = answers[jobs[0].id] else { Issue.record("\(String(describing: answers[jobs[0].id]))"); return }
        #expect(postKey == "PrEvIeWupload0001" && session.hasPrefix("PrEvIeWsession"))
        #expect(rig.calls.contains("PUT /studio/upload queue=true title=my clip"))
        #expect(rig.server.pendingTitles[session] == "my clip")
    }

    // MARK: Helpers

    private static func link(_ job: Job) -> URL? {
        if case .link(let info)? = job.pipeline.input { return info.url }
        return nil
    }
}

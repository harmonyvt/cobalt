import Foundation
import Testing
@testable import CobaltKit

// Phase 3 lane (c) (apple 03-PHASE3 3.3; 06 matrix, Phase 3 test 4): `ServerActivityStore` is the one poller of the server's
// work. Everything runs on a `VirtualClock`: the loop's sleeps are the clock's only sleepers in a quiet app, so the cadence is read
// off `currentWait` (the seconds it is sleeping for) and off the reads the preview server counted, never off wall time.

#if os(macOS)
private let leaveEvents: [LifecycleEvent] = [.willResignActive, .hidden]
private let backEvents: [LifecycleEvent] = [.unhidden, .becameActive]
#else
private let leaveEvents: [LifecycleEvent] = [.willResignActive, .didEnterBackground]
private let backEvents: [LifecycleEvent] = [.willEnterForeground, .becameActive]
#endif

@MainActor
private func feed(_ events: [LifecycleEvent], to life: AppLifecycle) { for e in events { life.feed(e) } }

/// Waits (real milliseconds, bounded) until the store's loop is parked on the clock again: no read in flight, a sleep registered
/// (or, with `sleeping: false`, no loop at all), and `polls` reads taken when given. Tests interleave on the main actor, so a
/// "nothing registered for a few ticks" settle alone can come early under load.
@MainActor
private func parked(_ rig: QueueRig, polls: Int? = nil, sleeping: Bool = true) async {
    let store = rig.app.serverActivity
    for _ in 0..<4000 {
        let enough = polls.map { store.polls >= $0 } ?? true
        let quiet = store.inFlight == 0
        let there = sleeping ? store.currentWait != nil : store.currentWait == nil
        if enough && quiet && there { break }
        try? await Task.sleep(for: .milliseconds(1))
    }
    await rig.settle()
}

/// A running share from another device's key: server work nobody in this app follows.
private let foreignShare = ServerLineSnapshot(
    running: .init(kind: "save", mine: false, origin: "share", keyName: "iphone"), entries: [], max: 50, waitMs: 1_800_000)

// MARK: - The cadence (matrix test 4)

@MainActor
struct ServerActivityCadenceTests {
    private func store(_ rig: QueueRig) -> ServerActivityStore { rig.app.serverActivity }

    @Test func theCadenceIsOnePureFunction() {
        #expect(ServerActivityStore.delay(active: false, failures: 0) == 30)
        #expect(ServerActivityStore.delay(active: true, failures: 0) == 3)
        let backoff = (1...9).map { ServerActivityStore.delay(active: $0.isMultiple(of: 2), failures: $0) }
        #expect(backoff == [6, 12, 24, 48, 96, 120, 120, 120, 120], "the same whether the server was idle or busy: \(backoff)")
        #expect(ServerActivityStore.delay(active: false, failures: 500) == 120)
    }

    @Test func idleReadsEvery30SecondsOnEveryScreen() async {
        let rig = QueueRig(.quiet)
        #expect(!rig.unified.isVisible, "the queue tab is not on screen: the store reads anyway")
        await parked(rig, polls: 1)
        #expect(rig.count("GET queue") == 1, "the first read is at once")
        #expect(store(rig).currentWait == 30)
        for n in 2...5 {
            rig.clock.advance()
            await parked(rig, polls: n)
            #expect(rig.count("GET queue") == n, "read \(n)")
            #expect(store(rig).currentWait == 30)
        }
        #expect(rig.clock.elapsed == 120, "four sleeps of exactly 30 s: \(rig.clock.elapsed)")
        #expect(store(rig).maxInFlight == 1 && store(rig).loopsStarted == 1)
    }

    @Test func activeReadsEvery3Seconds() async {
        let rig = QueueRig(.busy)                                       // a share from the iphone runs; two links of this app wait behind it
        await parked(rig, polls: 1)
        #expect(store(rig).isBusy)
        #expect(store(rig).currentWait == 3)
        let first = rig.count("GET queue")
        await rig.run(for: 9)
        let reads = rig.count("GET queue") - first
        #expect(reads >= 2 && reads <= 4, "every 3 s while it moves: \(reads)")
    }

    @Test func afterTheServerQuietensItSlowsTo30SecondsAndAfterItBusiesItSpeedsUp() async {
        let rig = QueueRig(.busy)
        await parked(rig, polls: 1)
        #expect(store(rig).currentWait == 3)
        // nothing waits on the server any more, here or anywhere
        for job in rig.app.queue.jobs { await rig.app.queue.cancel(job.id) }
        rig.server.queueLineOverride = ServerLineSnapshot()
        await rig.unified.refresh()
        await parked(rig)
        #expect(!store(rig).isBusy)
        #expect(store(rig).currentWait == 30, "idle again: \(String(describing: store(rig).currentWait))")
        // another device starts a save
        rig.server.queueLineOverride = foreignShare
        await rig.unified.refresh()
        await parked(rig)
        #expect(store(rig).isBusy)
        #expect(store(rig).currentWait == 3, "an answer with work in it re-times the sleep at once")
    }

    @Test func notInTheBackgroundAndAtOnceOnComingBack() async {
        let life = AppLifecycle()
        let rig = QueueRig(.quiet)
        rig.unified.observeLifecycle(life)
        feed([.becameActive], to: life)
        await parked(rig, polls: 1)
        #expect(rig.count("GET queue") == 1 && store(rig).currentWait == 30)

        feed(leaveEvents, to: life)
        #expect(!store(rig).isForeground && !store(rig).shouldPoll)
        #expect(store(rig).currentWait == nil && rig.clock.pending == 0, "the loop is gone, not asleep")
        await rig.run(for: 600)
        #expect(rig.count("GET queue") == 1, "never while the app is away")

        feed(backEvents, to: life)
        await parked(rig, polls: 2)
        #expect(rig.count("GET queue") == 2, "refresh on foreground")
        #expect(store(rig).currentWait == 30 && rig.clock.pending == 1)
    }

    @Test func aBackgroundedBusyServerIsNotPolledEither() async {
        let life = AppLifecycle()
        let rig = QueueRig(.busy)
        rig.unified.observeLifecycle(life)
        feed([.becameActive], to: life)
        await parked(rig, polls: 1)
        #expect(store(rig).currentWait == 3)
        feed(leaveEvents, to: life)
        await parked(rig, sleeping: false)
        let before = rig.count("GET queue")
        await rig.run(for: 120)
        #expect(rig.count("GET queue") == before)
    }

    @Test func failuresBackOff6_12_24_48_96_then120AndOneAnswerResets() async {
        let rig = QueueRig(.quiet)
        rig.server.queueFails = true
        await parked(rig, polls: 1)
        #expect(rig.unified.serverProblem && store(rig).failures == 1)
        var waits: [Double] = []
        for n in 1...7 {
            waits.append(store(rig).currentWait ?? -1)
            rig.clock.advance()
            await parked(rig, polls: n + 1)
        }
        #expect(waits == [6, 12, 24, 48, 96, 120, 120], "\(waits)")
        #expect(store(rig).failures == 8)
        #expect(rig.count("GET queue") == 8, "one read per sleep, none extra")

        rig.server.queueFails = false
        rig.clock.advance()                                             // the 120 s wait ends: this read works
        await parked(rig, polls: 9)
        #expect(!rig.unified.serverProblem && store(rig).failures == 0)
        #expect(store(rig).currentWait == 30, "one answer and the cadence is idle again, not the old backoff")
        #expect(rig.unified.snapshot != nil)
    }

    @Test func aFailureKeepsTheLastGoodAnswerAndSaysSo() async {
        let rig = QueueRig(.quiet)
        await parked(rig, polls: 1)
        let good = rig.unified.snapshot
        #expect(good != nil && !rig.unified.serverProblem)
        rig.server.queueFails = true
        rig.clock.advance()
        await parked(rig, polls: 2)
        #expect(rig.unified.serverProblem && rig.unified.snapshot == good)
    }

    @Test func aMutationReadsNowAndRetimesTheLoop() async {
        let rig = QueueRig(.quiet)
        await parked(rig, polls: 1)
        #expect(rig.count("GET queue") == 1)
        let ok = await rig.unified.refresh()
        #expect(ok && rig.count("GET queue") == 2, "an action's refresh does not wait for the 30 s")
        await parked(rig)
        #expect(store(rig).currentWait == 30)
        #expect(store(rig).loopsStarted == 1, "re-timed, not restarted")
    }

    @Test func theTabsBecomingVisibleReadsOnlyWhenTheAnswerIsOld() async {
        let rig = QueueRig(.quiet)
        await parked(rig, polls: 1)
        rig.unified.setVisible(true)
        await parked(rig)
        #expect(rig.count("GET queue") == 1, "the answer is fresh: no extra read")
        rig.clock.jump(by: 20)
        rig.unified.setVisible(false)
        rig.unified.setVisible(true)
        await parked(rig, polls: 2)
        #expect(rig.count("GET queue") == 2, "20 s old: read now")
    }
}

// MARK: - Exactly one loop

@MainActor
struct ServerActivityOneLoopTests {
    @Test func everyWayToAskCollapsesToOneRead() async {
        let rig = QueueRig(.quiet)
        await parked(rig, polls: 1)
        let store = rig.app.serverActivity
        let before = rig.count("GET queue")
        async let a = rig.unified.refresh()
        async let b = rig.unified.refresh()
        async let c = store.refresh()
        async let d = rig.unified.refresh()
        _ = await (a, b, c, d)
        #expect(rig.count("GET queue") == before + 1, "four callers, one request")
        #expect(store.maxInFlight == 1)
    }

    @Test func stormsOfInputsNeverMakeASecondLoop() async {
        let life = AppLifecycle()
        let rig = QueueRig(.quiet)
        rig.unified.observeLifecycle(life)
        let store = rig.app.serverActivity
        await parked(rig, polls: 1)
        for _ in 0..<5 {
            rig.app.apply(rig.app.capabilities)                          // capabilitiesChanged
            rig.unified.setForeground(true)
            rig.unified.setVisible(true)
            rig.unified.setVisible(false)
        }
        await parked(rig)
        #expect(store.loopsStarted == 1, "re-timing is not restarting")
        #expect(rig.clock.pending == 1, "one sleeper on the clock: one loop")
        let polled = store.polls
        for i in 0..<3 {
            feed(leaveEvents, to: life)
            await parked(rig, sleeping: false)
            #expect(rig.clock.pending == 0)
            feed(backEvents, to: life)
            await parked(rig, polls: polled + i + 1)
            #expect(rig.clock.pending == 1, "a loop that left and came back is the only one")
        }
        #expect(store.loopsStarted == 4 && store.maxInFlight == 1)
        // the sleeping loop wakes once, reads once
        let n = rig.count("GET queue")
        rig.clock.advance()
        await parked(rig, polls: n + 1)
        #expect(rig.count("GET queue") == n + 1)
    }

    @Test func aContextHasOneStore() async {
        let rig = QueueRig(.quiet)
        await parked(rig, polls: 1)
        #expect(ServerActivityStore.current(for: rig.app.ctx) === rig.app.serverActivity)
        #expect(rig.unified.activityStore === rig.app.serverActivity, "the queue is a view over the model's store")
        // a second store for the same context takes over and stops the first (one loop, ever)
        let first = rig.app.serverActivity
        let second = ServerActivityStore(context: rig.app.ctx)
        #expect(ServerActivityStore.current(for: rig.app.ctx) === second)
        #expect(!first.shouldPoll && first.currentWait == nil)
        for _ in 0..<4000 where second.currentWait == nil { try? await Task.sleep(for: .milliseconds(1)) }
        await rig.settle()
        #expect(rig.clock.pending == 1, "the first store's sleeper is gone: one loop for the context")
        #expect(second.currentWait == 30)
    }

    @Test func capabilityOffStopsAndForgets() async {
        let rig = QueueRig(.quiet)
        await parked(rig, polls: 1)
        #expect(rig.unified.snapshot != nil)
        var caps = rig.app.capabilities
        caps.queue = false
        rig.app.apply(caps)
        #expect(rig.unified.snapshot == nil && rig.app.serverActivity.currentWait == nil)
        let before = rig.count("GET queue")
        await rig.run(for: 120)
        #expect(rig.count("GET queue") == before)
        // and it comes back with the route
        caps.queue = true
        rig.app.apply(caps)
        await parked(rig, polls: before + 1)
        #expect(rig.count("GET queue") == before + 1 && rig.unified.snapshot != nil)
    }

    @Test func anAnswerFromTheOldServerIsNotKept() async {
        let rig = QueueRig(.quiet)
        await parked(rig, polls: 1)
        let store = rig.app.serverActivity
        rig.unified.serverChanged()
        #expect(rig.unified.snapshot == nil && rig.unified.updatedAt == nil)
        await parked(rig, polls: 2)
        #expect(store.polls == 2 && rig.unified.snapshot != nil, "a new server is read at once")
    }
}

// MARK: - The legacy line, and what the line mirror takes from the store

@MainActor
struct ServerActivityLegacyLineTests {
    @Test func aServerWithoutTheQueueRouteIsReadOnTheLineOnlyWhileAJobWaits() async {
        let rig = LineRig(.serverBusyWithShare)
        #expect(!rig.app.capabilities.queue && rig.app.capabilities.line)
        let store = rig.app.serverActivity
        await rig.run(for: 120)
        #expect(rig.count("GET line") == 0 && store.loopsStarted == 0, "nothing waits: nothing is read")
        _ = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        for _ in 0..<4000 where store.currentWait == nil { try? await Task.sleep(for: .milliseconds(1)) }
        await rig.settle()
        #expect(rig.count("GET line") >= 1, "a waiting job needs the labels at once")
        #expect(store.currentWait == 3)
        #expect(!rig.calls.contains("GET queue"), "the route is not there: the line is read")
        #expect(store.loopsStarted == 1)
        await rig.drive(until: { rig.queue.jobs.allSatisfy { rig.settled($0) } && store.currentWait == nil }, maxVirtualSeconds: 200)
        #expect(store.currentWait == nil, "nobody waits in the line any more: the loop ends")
    }

    @Test func theLineMirrorLabelsComeFromTheStoresAnswer() async {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA)], via: .review)
        let store = rig.app.serverActivity
        for _ in 0..<4000 where store.snapshot == nil { try? await Task.sleep(for: .milliseconds(1)) }
        await rig.settle()
        #expect(jobs[0].pipeline.line == .inLine(2, behind: "a share from your iphone"))
        #expect(store.snapshot?.line?.running?.keyName == "iphone")
    }

    @Test func aFailedReadKeepsThePositionAndDropsTheLabel() async {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA)], via: .review)
        let store = rig.app.serverActivity
        for _ in 0..<4000 where store.snapshot == nil { try? await Task.sleep(for: .milliseconds(1)) }
        await rig.settle()
        rig.server.lineFails = true
        await rig.run(for: 4)
        #expect(jobs[0].pipeline.line == .inLine(2, behind: nil))
        #expect(store.serverProblem)
    }
}

// MARK: - Editor renders (the fourth loop)

@MainActor
struct ServerActivityRenderWatchTests {
    private func render(_ id: String, _ status: EditRender.Status, progress: Double? = nil) -> EditRender {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        return EditRender(
            id: id, projectID: "p", revision: 1, title: "t", status: status, queueAhead: nil, progress: progress, secondsTotal: 10,
            error: nil, itemID: status == .done ? "item" : nil, cancelRequested: false, createdAt: at,
            startedAt: at, finishedAt: status == .done ? at : nil)
    }

    @Test func aWatcherHearsItsRenderAndSpeedsTheLoopUp() async {
        let rig = QueueRig(.quiet)
        await parked(rig, polls: 1)
        let store = rig.app.serverActivity
        #expect(store.currentWait == 30)
        var heard: [String] = []
        let watch = store.watchRender(id: "r1") { event in
            switch event {
            case .render(let r): heard.append("render:\(r.status.rawValue)")
            case .missing: heard.append("missing")
            case .failed: heard.append("failed")
            }
        }
        await parked(rig, polls: 2)
        #expect(store.currentWait == 3, "a render being watched is work: 3 s")
        #expect(heard == ["missing"], "the read the watcher asked for: the preview's /queue lists no editor render")
        store.accept(QueueSnapshot(edits: [render("r1", .rendering, progress: 0.4), render("other", .queued)]))
        #expect(heard.last == "render:rendering")
        store.accept(QueueSnapshot())                                   // the server went quiet
        watch.cancel()
        #expect(store.watchedRenderCount == 0)
        await parked(rig)
        #expect(store.currentWait == 30, "nobody watches and the server is quiet: idle again")
        store.accept(QueueSnapshot(edits: [render("r1", .done)]))
        #expect(heard.count == 3, "a cancelled watch hears nothing: \(heard)")
    }

    @Test func aFailedReadReachesTheWatcher() async {
        let rig = QueueRig(.quiet)
        await parked(rig, polls: 1)
        let store = rig.app.serverActivity
        var failures = 0
        let watch = store.watchRender(id: "r1") { event in if case .failed = event { failures += 1 } }
        await parked(rig, polls: 2)
        rig.server.queueFails = true
        rig.clock.advance()
        await parked(rig, polls: 3)
        rig.clock.advance()
        await parked(rig, polls: 4)
        #expect(failures >= 2, "two reads in a row: the editor's 'connection lost' banner needs two")
        watch.cancel()
    }

    /// An editor-capable preview server that also has `features.queue`, on a virtual clock.
    private func editorApp(queue: Bool) -> (clock: VirtualClock, app: AppModel) {
        let clock = VirtualClock()
        let ctx = PipelineContext.preview(.editorRendering, timeScale: 1, clock: clock)
        let client = PreviewClient(scenario: .editorRendering, timeScale: 1, clock: clock, line: .off, queue: queue ? .quiet : .off)
        ctx.client = client
        var caps = ctx.capabilities
        caps.queue = queue
        ctx.capabilities = caps
        let app = AppModel(
            context: ctx, library: LibraryModel(context: ctx, seed: PreviewData.libraryPage(now: clock.now())),
            photosSync: PhotosSync.preview(.init(access: .album, enabled: false)), makeClient: { _ in client })
        ctx.settings.autoContinue = false
        return (clock, app)
    }

    private func openSession(_ app: AppModel, clock: VirtualClock) async throws -> EditSession {
        let ctx = app.ctx
        let client = ctx.client as! PreviewClient
        let (full, named) = try await client.editProject(id: PreviewEditorIDs.beach)
        var summary = full
        summary.timeline = nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edit-tests-\(UUID().uuidString)", isDirectory: true)
        let cache = EditSourceCache(directory: dir, client: { [ctx] in ctx.client }, provider: { _ in nil })
        summary.render = try await client.editRender(id: PreviewEditorIDs.liveRender)
        return EditSession(
            project: summary, timeline: try #require(full.timeline), sources: named, context: ctx, cache: cache,
            onProject: { _ in }, onRender: { _ in })
    }

    private func settle(_ clock: VirtualClock) async {
        var last = clock.registrations
        var stable = 0
        while stable < 6 {
            try? await Task.sleep(for: .milliseconds(2))
            let r = clock.registrations
            if r == last { stable += 1 } else { stable = 0; last = r }
        }
    }

    @Test func theEditorFollowsItsRenderThroughTheStoreWhenTheServerHasTheQueue() async throws {
        let (clock, app) = editorApp(queue: true)
        let store = app.serverActivity
        let session = try await openSession(app, clock: clock)
        defer { session.tearDown() }
        await settle(clock)
        #expect(store.watchedRenderCount == 1, "the session subscribed to the store: no loop of its own")
        #expect(session.renderPollState == .polling)
        #expect(store.currentWait == 3)
        clock.jump(by: 21)                                              // the server's render finishes in 20 s
        var guardTicks = 0
        while session.activeRender?.isActive == true, guardTicks < 200 {
            guardTicks += 1
            clock.advance()
            await settle(clock)
        }
        #expect(session.activeRender?.isActive == false, "the render ran to its end through the store's reads")
        #expect(store.watchedRenderCount == 0 && session.renderPollState == .idle)
        #expect(store.polls >= 2, "the store's reads, not the session's: \(store.polls)")
    }

    @Test func withoutTheQueueRouteTheEditorKeepsItsOwnLoop() async throws {
        let (clock, app) = editorApp(queue: false)
        let store = app.serverActivity
        let session = try await openSession(app, clock: clock)
        defer { session.tearDown() }
        await settle(clock)
        #expect(store.watchedRenderCount == 0 && session.renderPollState == .polling)
        #expect(store.polls == 0 && store.loopsStarted == 0)
        clock.jump(by: 21)                                              // the server's render finishes in 20 s
        var guardTicks = 0
        while session.activeRender?.isActive == true, guardTicks < 200 {
            guardTicks += 1
            clock.advance()
            await settle(clock)
        }
        #expect(session.activeRender?.isActive == false)
    }
}

// MARK: - What recent shows

@MainActor
struct ServerActivityRecentTests {
    @Test func aFinishedJobKeepsItsDeviceCopyReceipt() async {
        let rig = QueueRig(.quiet)
        let store = rig.app.serverActivity
        let at = rig.clock.now()
        let ok = FinishedWork(id: UUID(), title: "a", outcome: .saved, finishedAt: at, mediaID: "m1", deviceCopy: .savedOnDevice)
        let bad = FinishedWork(id: UUID(), title: "b", outcome: .saved, finishedAt: at, mediaID: nil, deviceCopy: .failed(code: "error.app.disk_full"))
        let none = FinishedWork(id: UUID(), title: "c", outcome: .saved, finishedAt: at, mediaID: nil)
        let guessed = FinishedWork(id: UUID(), title: "d", outcome: .saved, finishedAt: at, mediaID: "m2")
        store.finishedHistory = [ok, bad, none, guessed]
        let items = rig.app.activity.items
        func stage(_ w: FinishedWork) -> JobStatus.Stage? { items.first { $0.id == "finished:\(w.id.uuidString)" }?.stage }
        #expect(stage(ok) == .completed(cloudSaved: true, deviceCopy: .savedOnDevice))
        #expect(stage(bad) == .completed(cloudSaved: true, deviceCopy: .failed(code: "error.app.disk_full")), "Device warning, truthfully")
        #expect(stage(none) == .completed(cloudSaved: true, deviceCopy: .notNeeded))
        #expect(stage(guessed) == .completed(cloudSaved: true, deviceCopy: .savedOnDevice), "no receipt: the stored media says it is on the device")
        #expect(rig.app.activity.attentionCount >= 1, "a failed device copy needs a look")
        #expect(rig.unified.finishedHistory == store.finishedHistory, "the queue's list is the store's")
    }

    @Test func aJobThatLeftTheQueueIsRememberedWithItsReceipt() async {
        let rig = QueueRig(.quiet)
        let job = rig.app.queue.add([.link(linkA)], via: .review)[0]
        await rig.drive(until: { job.isFinished })
        await rig.drive(until: { rig.app.queue.job(job.id) == nil }, maxVirtualSeconds: 120)
        let work = rig.unified.finishedHistory.first { $0.id == job.id }
        #expect(work != nil && work?.deviceCopy != nil, "the receipt is taken when the job leaves")
        #expect(rig.app.activity.status("finished:\(job.id.uuidString)") != nil)
    }
}

// MARK: - The badge

@MainActor
struct ServerActivityBadgeTests {
    @Test func theBadgeIsTheOneCount() async {
        let rig = QueueRig(.busy)
        await parked(rig, polls: 1)
        #expect(rig.unified.badgeCount == rig.app.activity.activeCount)
        #expect(rig.unified.badgeCount > rig.app.queue.live.count + rig.app.offlineDownloads.unfinishedCount,
                "the server's own rows and the photos album count too: it no longer disagrees with the summary")
    }
}

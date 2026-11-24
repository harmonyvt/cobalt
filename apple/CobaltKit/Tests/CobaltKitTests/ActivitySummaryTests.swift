import Foundation
import Testing
@testable import CobaltKit

// Phase 3, the one count (apple 03-PHASE3 3.2; 06 matrix, CobaltKit tests 2 and 3): the focused job, the minimized ones, the
// downloads and the server's rows are each counted once, a job that shares a `sessionID` is never counted twice, and
// minimizing keeps a job listed.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func job(
    _ id: String, _ stage: JobStatus.Stage, session: String? = nil, ref: JobStatus.Ref? = nil, focused: Bool = false,
    kind: JobStatus.Kind = .save, at: Double = 0
) -> JobStatus {
    JobStatus(
        id: id, ref: ref ?? .pipeline(UUID()), kind: kind, sessionID: session, stage: stage,
        startedAt: t0.addingTimeInterval(at), updatedAt: t0.addingTimeInterval(at), isFocused: focused)
}

private let fetching = JobStatus.Stage.fetching(engine: nil, fallbackFrom: nil)
private let failed = JobStatus.Stage.failed(failure: .unreachable, retryable: true)

// MARK: - The pure builder

struct ActivitySummaryBuilderTests {
    @Test func theFocusedAndTheMinimizedAndTheDownloadAndTheServerAreEachCountedOnce() {
        let s = ActivitySummary.build(
            pipelines: [job("job:a", fetching, session: "A", focused: true), job("job:b", .downloading(bytes: 1, total: 2), session: "B")],
            downloads: [job("download:f:1", .deviceCopy(bytes: 1, total: 2), kind: .deviceDownload)],
            server: [job("server:z", fetching, session: "Z")])
        #expect(s.items.count == 4 && s.activeCount == 4 && s.attentionCount == 0)
        #expect(s.items.contains { $0.isFocused }, "the focused job is one of them")
    }

    @Test func aPipelineBeatsAServerRowOfTheSameSession() {
        let mine = job("job:a", .storing(bytes: 1, total: 2), session: "S1", focused: true)
        let theirs = job("server:S1", fetching, session: "S1")
        let s = ActivitySummary.build(pipelines: [mine], server: [theirs])
        #expect(s.items.map(\.id) == ["job:a"] && s.activeCount == 1)
        #expect(s.items[0].stage == .storing(bytes: 1, total: 2), "the pipeline's word, not the server's")
        // whichever order the lists are given in
        #expect(ActivitySummary.build(server: [theirs], recent: []).items.map(\.id) == ["server:S1"])
    }

    @Test func aPipelineBeatsItsOwnDownload() {
        // a pipeline keeps its original on the device through an `s:<session>` download: one piece of work
        let pipeline = job("job:a", .deviceCopy(bytes: 3, total: 4), session: "S1")
        let download = job("download:s:S1", .deviceCopy(bytes: 3, total: 4), session: "S1", kind: .deviceDownload)
        let s = ActivitySummary.build(pipelines: [pipeline], downloads: [download])
        #expect(s.items.map(\.id) == ["job:a"] && s.activeCount == 1)
    }

    @Test func aDownloadBeatsAServerRowAndAServerRowBeatsARecentOne() {
        let download = job("download:s:S1", .queued(ahead: nil), session: "S1", kind: .deviceDownload)
        let row = job("server:S1", fetching, session: "S1")
        #expect(ActivitySummary.build(downloads: [download], server: [row]).items.map(\.id) == ["download:s:S1"])
        let recent = job("finished:1", .completed(cloudSaved: true, deviceCopy: .notNeeded), session: "S1")
        #expect(ActivitySummary.build(server: [row], recent: [recent]).items.map(\.id) == ["server:S1"])
    }

    @Test func aRenderTheServerNamesByJobIsTheJobsOwn() {
        // the server's row carries a session and a job; the pipeline only knows the job it asked for
        let mine = JobStatus(
            id: "job:a", ref: .pipeline(UUID()), kind: .webpRender, serverJobID: "J9", stage: .rendering(phase: nil, done: nil, total: nil),
            startedAt: t0, updatedAt: t0)
        let row = JobStatus(
            id: "server:J9", ref: .server(id: "server:J9"), kind: .webpRender, sessionID: "S9", serverJobID: "J9",
            stage: .rendering(phase: nil, done: nil, total: nil), startedAt: t0, updatedAt: t0)
        #expect(ActivitySummary.build(pipelines: [mine], server: [row]).items.map(\.id) == ["job:a"])
        #expect(ActivitySummary.build(server: [row]).items.map(\.id) == ["server:J9"])
    }

    @Test func twoJobsOnOnePostAreTwoJobs() {
        let s = ActivitySummary.build(pipelines: [job("job:a", fetching, session: "S1"), job("job:b", .rendering(phase: nil, done: nil, total: nil), session: "S1", kind: .webpRender)])
        #expect(s.activeCount == 2, "dedupe is across sources, never inside one")
    }

    @Test func theSameIdIsNeverListedTwice() {
        let s = ActivitySummary.build(pipelines: [job("job:a", fetching)], downloads: [job("job:a", fetching)])
        #expect(s.items.count == 1)
    }

    @Test func attentionIsFailuresAndFailedDeviceCopies() {
        let s = ActivitySummary.build(
            pipelines: [
                job("job:a", failed, session: "A"),
                job("job:b", .completed(cloudSaved: true, deviceCopy: .failed(code: "error.app.disk_full")), session: "B"),
                job("job:c", .completed(cloudSaved: true, deviceCopy: .savedOnDevice), session: "C"),
                job("job:d", fetching, session: "D"),
            ],
            downloads: [job("download:f:2", failed, kind: .deviceDownload)])
        #expect(s.attentionCount == 3 && s.activeCount == 1 && s.items.count == 5)
        #expect(s.attention.map(\.id).sorted() == ["download:f:2", "job:a", "job:b"])
        #expect(!s.isQuiet)
    }

    @Test func aFinishedJobWhoseDeviceCopyIsStillArrivingIsStillActive() {
        let s = ActivitySummary.build(pipelines: [job("job:a", .deviceCopy(bytes: 1, total: 9), session: "A")])
        #expect(s.activeCount == 1 && s.attentionCount == 0)
    }

    @Test func theCountsAreDerivedFromTheItemsSoTheyCannotDisagree() {
        let s = ActivitySummary.build(
            pipelines: [job("job:a", fetching), job("job:b", failed), job("job:c", .awaitingChoice)],
            recent: [job("finished:1", .completed(cloudSaved: true, deviceCopy: .notNeeded))])
        #expect(s.activeCount == s.items.filter(\.isActive).count)
        #expect(s.attentionCount == s.items.filter(\.needsAttention).count)
        #expect(s.running.count + s.attention.count + s.recent(limit: 100).count == s.items.count, "three groups, nothing twice, nothing lost")
        #expect(ActivitySummary(items: s.items) == s)
    }

    @Test func nothingIsQuiet() {
        #expect(ActivitySummary.empty.isQuiet && ActivitySummary.empty.activeCount == 0 && ActivitySummary.build() == .empty)
    }

    @Test func theSheetOrderIsRunningThenAttentionThenSettled() {
        let s = ActivitySummary.build(
            pipelines: [
                job("job:done", .completed(cloudSaved: true, deviceCopy: .notNeeded), at: 1),
                job("job:failed", failed, at: 2),
                job("job:waiting2", .queued(ahead: 2), at: 3),
                job("job:waiting1", .queued(ahead: 1), at: 4),
                job("job:running", fetching, at: 9),
                job("job:picker", .awaitingChoice, at: 5),
            ])
        #expect(s.items.map(\.id) == ["job:running", "job:waiting1", "job:waiting2", "job:failed", "job:picker", "job:done"],
                "a running job before a waiting one, waiting ones by place; failed; then settled newest first")
        #expect(s.recent(limit: 1).map(\.id) == ["job:picker"])
    }
}

// MARK: - The model, over the real stores

@MainActor
struct ActivityModelTests {
    @Test func theFocusedAndTheMinimizedJobsAreBothCountedAndMinimizingLosesNeither() {
        let rig = LineRig(.server)
        let a = rig.queue.add([.link(linkA)], via: .paste)[0]          // takes the focus
        let b = rig.queue.add([.link(linkB)], via: .paste)[0]          // goes alongside
        #expect(rig.queue.focusedID == a.id)
        let activity = rig.app.activity
        #expect(activity.activeCount == 2 && activity.attentionCount == 0)
        #expect(activity.status("job:\(a.id.uuidString)")?.isFocused == true)
        #expect(activity.status("job:\(b.id.uuidString)")?.isFocused == false)

        // minimize: the focus closes, the job stays (matrix test 3)
        let listed = activity.minimize(a.id)
        #expect(listed, "the minimized job is still in the activity")
        #expect(rig.queue.focusedID == nil)
        #expect(rig.ctx.background.runs.contains { $0 === a.pipeline }, "carried by the queue, not by a hidden run")
        #expect(activity.activeCount == 2)
        #expect(activity.status("job:\(a.id.uuidString)")?.isFocused == false)
        #expect(activity.status("job:\(a.id.uuidString)")?.canFocus == true && activity.status("job:\(a.id.uuidString)")?.canCancel == true)
    }

    @Test func minimizeByPipelineAndOfAnUnknownJob() {
        let rig = LineRig(.server)
        let a = rig.queue.add([.link(linkA)], via: .paste)[0]
        #expect(rig.app.activity.minimize(a.pipeline))
        #expect(rig.queue.focusedID == nil && rig.app.activity.activeCount == 1)
        #expect(!rig.app.activity.minimize(UUID()))
        #expect(!rig.app.activity.minimize(Pipeline(context: rig.ctx)))
    }

    @Test func aFocusedJobIsRefocusedWithOneTap() async {
        let rig = LineRig(.server)
        let a = rig.queue.add([.link(linkA)], via: .paste)[0]
        let id = "job:\(a.id.uuidString)"
        rig.app.activity.minimize(a.id)
        await rig.app.activity.perform(.focus, on: id)
        #expect(rig.queue.focusedID == a.id)
        await rig.app.activity.perform(.cancel, on: "job:unknown")        // an unknown id does nothing
    }

    @Test func theBusyPreviewCountsEachThingOnceAcrossEverySource() async {
        let rig = QueueRig(.busy)
        await rig.unified.refresh()
        let activity = rig.app.activity
        let s = activity.summary

        // each owner's own idea of what it holds
        let jobs = rig.app.queue.jobs
        let downloads = rig.app.offlineDownloads.rows
        #expect(jobs.count == 2 && downloads.count == 2)
        let ids = s.items.map(\.id)
        #expect(Set(ids).count == ids.count, "no id twice")
        for job in jobs { #expect(ids.contains("job:\(job.id.uuidString)")) }
        for row in downloads { #expect(ids.contains("download:\(row.id)")) }
        #expect(ids.contains("photos"), "the album adding 3 of 7")

        let live = jobs.filter(\.isLive).count
        let running = downloads.filter { !$0.isFailed }.count
        let foreign = s.items.filter { $0.remote != nil }
        #expect(foreign.count == 1 && foreign.first?.remote?.keyName == "iphone" && foreign.first?.remote?.fromShare == true, "the share sheet's save running on the server")
        #expect(s.activeCount == live + running + 1 + foreign.count, "jobs + downloads + photos + the server's own")
        #expect(s.attentionCount == downloads.filter(\.isFailed).count)
        // the three surfaces that used to disagree read this one number
        #expect(activity.activeCount == s.activeCount && activity.attentionCount == s.attentionCount && activity.items == s.items)
    }

    @Test func aServerRowOfASessionThisDeviceFollowsIsNotCountedTwice() async {
        let rig = QueueRig(.busy)
        let line = ServerLineSnapshot(
            running: .init(kind: "save", mine: true, sid: "S1", keyName: "iphone"),
            entries: [.init(position: 2, kind: "save", mine: true, sid: "S2", keyName: "iphone", link: "https://x.com/i/status/9")])
        rig.server.queueLineOverride = line
        await rig.unified.refresh()
        let before = rig.app.activity.summary
        #expect(before.items.filter { $0.id.hasPrefix("server:") }.count == 2)

        // the first two jobs of this app are those sessions: the pipeline is the one that shows
        let jobs = rig.app.queue.jobs
        jobs[0].pipeline.sessionID = "S1"
        jobs[1].pipeline.sessionID = "S2"
        let after = rig.app.activity.summary
        #expect(after.items.filter { $0.id.hasPrefix("server:") }.isEmpty)
        #expect(after.items.count == before.items.count - 2)
        #expect(after.items.filter { $0.sessionID == "S1" }.map(\.ref) == [.pipeline(jobs[0].id)])
        // a render this app started is its job's, not a second row
        jobs[0].pipeline.renderJobID = "J9"
        rig.server.queueLineOverride = ServerLineSnapshot(running: .init(kind: "render", mine: true, sid: "S9", job: "J9"))
        await rig.unified.refresh()
        #expect(rig.app.activity.items.filter { $0.id.hasPrefix("server:") }.isEmpty)
    }

    /// The rule (`ServerActivityStore.isFresh`): while the app is in front and reads work, the server's answer is news wherever the
    /// owner is (the store keeps it fresh itself); it is dropped `serverFreshness` seconds after it arrived only when the app is
    /// backgrounded or the reads keep failing. The device's own work (the album) stays either way.
    @Test func theServersAnswerIsStaleOnlyWhenTheAppIsAwayOrReadsFail() async {
        let fresh = ServerActivitySource.serverFreshness
        func hasServerRows(_ rig: QueueRig) -> Bool { rig.app.activity.items.contains { $0.remote != nil } }
        // another device's save the server keeps running for the whole test (the preview's own busy line finishes by itself)
        let foreign = ServerLineSnapshot(running: .init(kind: "save", mine: false, sid: "F1", keyName: "mac"))
        func rig() async -> QueueRig {
            let r = QueueRig(.busy)
            r.server.queueLineOverride = foreign
            await r.unified.refresh()
            return r
        }

        // in front, reads working: well past the freshness window the rows are still there
        let front = await rig()
        #expect(hasServerRows(front))
        await front.run(for: fresh * 3)
        #expect(front.app.serverActivity.isForeground && !front.app.serverActivity.serverProblem)
        #expect(hasServerRows(front), "an answer the store keeps refreshing never goes stale")

        // backgrounded: the answer is used for `serverFreshness` seconds, then dropped
        let away = await rig()
        away.app.serverActivity.setForeground(false)
        let sleeper = Task { try? await away.clock.sleep(seconds: fresh + 5) }
        await away.run(for: fresh - 15)
        #expect(hasServerRows(away), "still inside the window")
        await away.run(for: 20)
        sleeper.cancel()
        #expect(!hasServerRows(away), "past the window with nobody refreshing it")
        #expect(away.app.activity.items.contains { $0.id == "photos" }, "the device's own work stays")
        // coming back reads at once and the rows return
        away.app.serverActivity.setForeground(true)
        await away.run(for: 1)
        #expect(hasServerRows(away))

        // in front but every read fails: the last answer is kept for the window, then dropped
        let failing = await rig()
        #expect(hasServerRows(failing))
        failing.server.queueFails = true
        await failing.run(for: fresh + 20)
        #expect(failing.app.serverActivity.serverProblem)
        #expect(!hasServerRows(failing), "a failing server's old answer is not news")
        #expect(failing.app.activity.items.contains { $0.id == "photos" })
    }

    @Test func downloadsRouteBackToTheirOwner() async {
        let rig = QueueRig(.busy)
        let activity = rig.app.activity
        let failedRow = rig.app.offlineDownloads.rows.first { $0.isFailed }
        let id = "download:\(failedRow?.id ?? "?")"
        #expect(failedRow != nil && activity.status(id)?.canDismiss == true)
        await activity.perform(.dismiss, on: id)
        #expect(activity.status(id) == nil, "the failed download is taken off the list")
    }

    @Test func aFailedJobIsRetriedFromTheActivity() async {
        let rig = LineRig(.server)
        let a = rig.queue.add([.link(linkA)], via: .review)[0]
        a.pipeline.setState(.failed(.unreachable))
        let id = "job:\(a.id.uuidString)"
        #expect(rig.app.activity.attentionCount == 1 && rig.app.activity.status(id)?.canRetry == true)
        await rig.app.activity.perform(.retry, on: id)
        #expect(rig.app.activity.status(id) == nil && rig.app.activity.activeCount == 1, "a new job took its place")
        await rig.app.activity.perform(.dismiss, on: rig.app.activity.items[0].id)   // a running job offers no dismiss: nothing happens
        #expect(rig.app.activity.activeCount == 1)
    }
}

// MARK: - The seam the next lanes replace sources through

@MainActor
private final class FakeSource: ActivitySource {
    let tier: ActivityTier
    var held: [JobStatus]
    private(set) var performed: [(ActivityModel.Action, String)] = []
    init(_ tier: ActivityTier, _ held: [JobStatus]) { self.tier = tier; self.held = held }
    func statuses(now: Date) -> [JobStatus] { held }
    func perform(_ action: ActivityModel.Action, on status: JobStatus) async -> Bool {
        guard held.contains(where: { $0.id == status.id }) else { return false }
        performed.append((action, status.id))
        return true
    }
}

@MainActor
struct ActivitySourceSeamTests {
    @Test func aSourceIsAllTheModelNeedsToKnowAnOwnerOfWork() async {
        let app = AppModel.preview()
        let pipelines = PipelineActivitySource(context: app.ctx, queue: app.queue)
        let failedJob = JobStatus(id: "job:z", ref: .server(id: "job:z"), kind: .save, sessionID: "S1", stage: failed, startedAt: t0, updatedAt: t0, canRetry: true)
        let store = FakeSource(.server, [failedJob])
        let model = ActivityModel(clock: app.ctx.clock, pipelines: pipelines, sources: [pipelines, store])
        #expect(model.attentionCount == 1 && model.items.map(\.id) == ["job:z"])
        await model.perform(.retry, on: "job:z")
        #expect(store.performed.map(\.1) == ["job:z"] && store.performed.first?.0 == .retry)
        // an action the status does not offer never reaches the source
        await model.perform(.cancel, on: "job:z")
        #expect(store.performed.count == 1)
        // the same session in a higher-ranked source hides it
        let mine = FakeSource(.pipeline, [job("job:a", fetching, session: "S1")])
        let both = ActivityModel(clock: app.ctx.clock, pipelines: pipelines, sources: [pipelines, store, mine])
        #expect(both.items.map(\.id) == ["job:a"])
    }
}

@MainActor
struct ActivityContextTests {
    @Test func theContextReadsTheSameCountAsTheModel() {
        let rig = LineRig(.server)
        #expect(rig.ctx.activitySummary?().activeCount == 0)
        rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        #expect(rig.ctx.activitySummary?().activeCount == 2 && rig.app.activity.activeCount == 2)
        #expect(rig.ctx.activitySummary?() == rig.app.activity.summary, "the island and the pill read one answer")
        #expect(rig.app.serverActivity.ctx === rig.ctx && rig.app.health.ctx === rig.ctx, "the lanes' stubs are wired to the app's context")
    }
}

import Foundation
import Testing
@testable import CobaltKit

// The busy period's one Live Activity (CONTRACT-PARALLEL.md section 6) on a fake ActivityKit and the virtual clock:
// one job is today's per-run activity; the second live job keeps the first activity and asks ActivityKit for no other;
// the activity is written at most once a second; the lead is the job running on the server; it ends with what came out
// of the period.

// MARK: - the pure parts

struct LiveSummaryBuilderTests {
    @Test func theSummaryIsTheLeadsContentPlusTheCounts() {
        var lead = LiveContentState(stage: .saving, rail: 1, since: 10)
        lead.bytes = 5
        lead.total = 10
        lead.title = "clip"
        let s = LiveContentState.summary(lead: lead, jobs: 3, waiting: 1)
        #expect(s.stage == .saving && s.rail == 1 && s.since == 10 && s.bytes == 5 && s.title == "clip")
        #expect(s.jobs == 3 && s.waiting == 1 && s.isSummary && !s.isFinishedSummary)
        #expect(LiveContentState.summary(lead: lead, jobs: 2, waiting: 9).waiting == 2, "never more waiting than jobs")
    }

    @Test func theFinishedSummaryCountsWhatCameOutOfThePeriod() throws {
        let done = try #require(LiveContentState.finishedSummary(saved: 3, webps: 1, failed: 0, jobs: 3, now: 5))
        #expect(done.stage == .done && done.rail == 3 && done.since == 5)
        #expect(done.savedCount == 3 && done.webpCount == 1 && done.failedCount == 0 && done.isFinishedSummary)
        let mixed = try #require(LiveContentState.finishedSummary(saved: 2, webps: 0, failed: 1, jobs: 3, now: 5))
        #expect(mixed.stage == .done, "something came out of it")
        let failed = try #require(LiveContentState.finishedSummary(saved: 0, webps: 0, failed: 2, jobs: 2, now: 5))
        #expect(failed.stage == .failed && failed.isTerminal)
        #expect(LiveContentState.finishedSummary(saved: 0, webps: 0, failed: 0, jobs: 0, now: 5) == nil, "everything was cancelled")
    }

    @Test func theAdditiveFieldsRoundTripAndAnOldPerRunStateHasNone() throws {
        let s = try #require(LiveContentState.finishedSummary(saved: 2, webps: 1, failed: 1, jobs: 3, now: 5))
        let data = try JSONEncoder().encode(s)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["stage", "rail", "since", "waking", "packing", "jobs", "waiting", "savedCount", "webpCount", "failedCount"])
        #expect(try JSONDecoder().decode(LiveContentState.self, from: data) == s)
        // a per-run state (and the server's fixture) carries none of them
        for (name, sample) in LiveContentState.samples {
            #expect(sample.jobs == nil && sample.waiting == nil && sample.savedCount == nil, "\(name)")
            let keys = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any]).keys
            #expect(!keys.contains("jobs") && !keys.contains("waiting"), "\(name)")
        }
        // a state from before the fields existed still decodes
        let old = #"{"stage":"saving","rail":1,"since":5,"waking":false,"packing":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LiveContentState.self, from: old)
        #expect(decoded.jobs == nil && !decoded.isSummary)
    }

    @Test func theSummarySamplesAreAllSummaries() {
        #expect(!LiveContentState.summarySamples.isEmpty)
        for (name, sample) in LiveContentState.summarySamples { #expect(sample.isSummary, "\(name)") }
    }
}

// MARK: - the manager

/// A preview app whose server holds a line (so a save can fail, queue and wait), with the Live manager on a fake
/// ActivityKit. Local mode: nothing is pushed.
@MainActor
struct SummaryRig {
    let line: LineRig
    let adapter = FakeLiveAdapter()
    let grace = FakeGrace()
    let manager: LiveActivityManager

    init(_ mode: LinePreviewMode = .server) {
        line = LineRig(mode)
        let clock = line.clock
        adapter.clock = { clock.now() }
        manager = LiveActivityManager(context: line.ctx, adapter: adapter, environment: nil, grace: grace)
        line.ctx.live = manager
        line.app.liveManager = manager
    }

    var queue: JobQueue { line.queue }
    var handle: FakeLiveHandle? { adapter.handles.first }

    func settle() async {
        await line.settle()
        await manager.settle()
    }

    func drive(until condition: @escaping @MainActor () -> Bool) async {
        await line.drive(until: condition)
        await manager.settle()
    }

    func run(for seconds: Double) async {
        await line.run(for: seconds)
        await manager.settle()
    }

    func isSaved(_ job: Job) -> Bool { if case .ready = job.pipeline.state { true } else { false } }
    func isDone(_ job: Job) -> Bool { if case .done = job.pipeline.state { true } else { false } }
    func isFailed(_ job: Job) -> Bool { job.isFailed }

    /// What the activity was told, in order: the request's content, every update, the end.
    func contents(of handle: FakeLiveHandle) -> [LiveContentState] {
        var out: [LiveContentState] = []
        if let request = adapter.requests.first(where: { $0.attributes.run == handle.attributes.run }) { out.append(request.state) }
        out += handle.updates.map(\.state)
        if let end = handle.end { out.append(end.state) }
        return out
    }

    /// The moment each update was sent: its stale date is that moment plus 120 s.
    func sendTimes(of handle: FakeLiveHandle) -> [Date] {
        handle.updates.compactMap { $0.staleDate?.addingTimeInterval(-LiveActivityManager.staleSeconds) }
    }
}

@MainActor
@Suite(.serialized)
struct LiveSummaryTests {
    // MARK: one job

    @Test func oneLiveJobIsTodaysPerRunActivityWithNoSummaryFields() async throws {
        let rig = SummaryRig()
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive { rig.isSaved(job) }
        await rig.settle()
        #expect(rig.adapter.requests.count == 1)
        #expect(rig.adapter.requests[0].attributes.run == job.pipeline.liveRunID.uuidString.lowercased(), "the run's own activity")
        let handle = try #require(rig.handle)
        let contents = rig.contents(of: handle)
        #expect(contents.allSatisfy { $0.jobs == nil && $0.waiting == nil }, "a per-run activity carries no summary")
        #expect(!rig.manager.inBusyPeriod)
    }

    // MARK: the second job

    @Test func theSecondLiveJobKeepsTheFirstActivityAndNeverRequestsAnother() async throws {
        let rig = SummaryRig()
        let first = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive { if case .saving = first.pipeline.state { true } else { false } }
        #expect(rig.adapter.requests.count == 1)
        let handle = try #require(rig.handle)
        #expect(!rig.manager.inBusyPeriod)

        let batch = rig.queue.add([.link(linkB), .link(linkC)], via: .review)
        await rig.settle()
        #expect(rig.manager.inBusyPeriod)
        #expect(rig.adapter.requests.count == 1, "no second Activity.request")
        #expect(rig.manager.summaryHandle === handle, "the first job's activity is the summary")

        await rig.drive { ([first] + batch).allSatisfy { rig.isSaved($0) } }
        await rig.settle()
        #expect(rig.adapter.requests.count == 1, "never two requests in the whole period")
        #expect(!rig.manager.inBusyPeriod)
        let writes = handle.updates.map(\.state)
        let began = try #require(writes.firstIndex { $0.jobs != nil }, "the period wrote its first summary")
        #expect(writes[..<began].allSatisfy { $0.jobs == nil }, "before the second job it was the run's own activity")
        #expect(writes[began...].allSatisfy { $0.jobs != nil }, "every write after that speaks for the period")
        #expect((writes.compactMap(\.jobs).max() ?? 0) == 3)
        let end = try #require(handle.end)
        #expect(end.state.stage == .done && end.state.isFinishedSummary)
        #expect(end.state.savedCount == 3 && end.state.webpCount == 0 && end.state.failedCount == 0)
        let dismiss = try #require(end.dismissAt)
        #expect(abs(dismiss.timeIntervalSince(rig.line.clock.now()) - 900) < 30, "a done summary stays 15 minutes")
        #expect(handle.endCalls.count == 1)
    }

    @Test func theSummaryIsWrittenAtMostOncePerSecondInTotal() async throws {
        let rig = SummaryRig()
        let jobs = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        await rig.drive { jobs.allSatisfy { rig.isSaved($0) } }
        await rig.settle()
        let handle = try #require(rig.handle)
        let times = rig.sendTimes(of: handle)
        #expect(times.count >= 3, "the period had several writes to space out")
        for (a, b) in zip(times, times.dropFirst()) {
            #expect(b.timeIntervalSince(a) >= 0.99, "writes closer than 1 s: \(a) -> \(b)")
        }
        for (a, b) in zip(handle.updates, handle.updates.dropFirst()) where b.at.timeIntervalSince(a.at) < 30 {
            #expect(a.state != b.state, "equal states are not re-sent (only the once-a-minute keepalive repeats one)")
        }
    }

    @Test func waitingCountsTheJobsInALineAndTheCountsOnlyGoDownAsJobsFinish() async throws {
        // a server that is busy with a share from the iphone: every job of this app waits behind it
        let rig = SummaryRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        await rig.drive { jobs.allSatisfy { rig.isSaved($0) } }
        await rig.settle()
        let handle = try #require(rig.handle)
        let writes = handle.updates.map(\.state).filter { !$0.isTerminal }
        let waits = writes.compactMap(\.waiting)
        #expect(waits.contains { $0 >= 2 }, "queued jobs are counted as waiting: \(waits)")
        let counts = writes.compactMap(\.jobs)
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 >= $1 }, "jobs never grows once the period began: \(counts)")
        #expect(writes.allSatisfy { ($0.waiting ?? 0) <= ($0.jobs ?? 0) })
    }

    @Test func theLeadIsTheJobRunningOnTheServerThenThisDevicesWorkThenAJobInLine() async throws {
        let rig = SummaryRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.settle()
        let ranks = jobs.map { $0.pipeline.liveLeadRank }
        #expect(ranks.allSatisfy { (0...2).contains($0) })
        // before any session exists a job is device work (1); a waiting one is 2; a running one is 0
        let p = Pipeline(context: Harness(.shortClip).ctx)             // its own context: nothing reports to the manager
        p.setState(.fetching(since: Date(), waking: false))
        #expect(p.liveLeadRank == 1, "checking the link or sending the create is this device's work")
        p.sessionID = "SESSION"
        #expect(p.liveLeadRank == 0, "the server has it")
        p.line = .inLine(2, behind: nil)
        #expect(p.liveLeadRank == 2, "waiting in a line")
        p.line = nil
        p.setState(.reading(developed: 1, of: 9))
        #expect(p.liveLeadRank == 1)
    }

    // MARK: ending

    @Test func aFailureIsCountedAndAPeriodWithSomethingSavedStaysFifteenMinutes() async throws {
        let rig = SummaryRig()
        let jobs = rig.queue.add([.link(linkA), .link(linkPrivate), .link(linkC)], via: .review)
        await rig.drive { jobs.allSatisfy { rig.isSaved($0) || rig.isFailed($0) } }
        await rig.settle()
        let handle = try #require(rig.handle)
        let end = try #require(handle.end)
        #expect(end.state.savedCount == 2 && end.state.failedCount == 1 && end.state.webpCount == 0, "\(end.state)")
        #expect(end.state.stage == .done)
        #expect(abs(try #require(end.dismissAt).timeIntervalSince(rig.line.clock.now()) - 900) < 30)
        #expect(rig.adapter.requests.count == 1)
    }

    @Test func aPeriodWhereNothingCameOutEndsAsFailedForFiveMinutes() async throws {
        let rig = SummaryRig()
        let alsoPrivate = URL(string: "https://www.instagram.com/reel/Dd55fEyN1Yy/?igsh=other")!
        let jobs = rig.queue.add([.link(linkPrivate), .link(alsoPrivate)], via: .review)
        await rig.drive { jobs.allSatisfy { rig.isFailed($0) } }
        await rig.settle()
        let handle = try #require(rig.handle)
        let end = try #require(handle.end)
        #expect(end.state.stage == .failed && end.state.failedCount == 2 && end.state.savedCount == 0, "\(end.state)")
        #expect(abs(try #require(end.dismissAt).timeIntervalSince(rig.line.clock.now()) - 300) < 30)
    }

    @Test func aWebpIsCountedAndASaveBeforeThePeriodIsNot() async throws {
        let rig = SummaryRig()
        let first = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive { rig.isSaved(first) }
        let before = rig.adapter.requests.count
        #expect(before == 1)
        // the saved job renders while a new one saves: the period has two live jobs, one of them already saved before it
        let other = rig.queue.add([.link(linkB)], via: .review)[0]
        first.pipeline.makeWebp()
        await rig.drive { rig.isDone(first) && rig.isSaved(other) }
        await rig.settle()
        let last = try #require(rig.adapter.handles.last)
        let end = try #require(last.end)
        #expect(end.state.isFinishedSummary, "\(end.state)")
        #expect(end.state.webpCount == 1, "the webp is counted")
        #expect(end.state.savedCount == 1, "only the new save: the first was saved before the period")
    }

    @Test func cancellingEveryJobEndsTheActivityQuietly() async throws {
        let rig = SummaryRig()
        let first = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive { if case .saving = first.pipeline.state { true } else { false } }
        let rest = rig.queue.add([.link(linkB), .link(linkC)], via: .review)
        await rig.settle()
        #expect(rig.manager.inBusyPeriod)
        for job in [first] + rest { await rig.queue.cancel(job.id) }
        await rig.settle()
        let handle = try #require(rig.handle)
        #expect(handle.ended && handle.end?.dismissAt == nil, "nothing to say: it goes at once")
        #expect(handle.end?.state.isFinishedSummary != true)
        #expect(!rig.manager.inBusyPeriod)
        #expect(rig.adapter.requests.count == 1)
    }

    @Test func aNewPeriodAfterAnEndedOneStartsAFreshActivity() async throws {
        let rig = SummaryRig()
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.drive { jobs.allSatisfy { rig.isSaved($0) } }
        await rig.settle()
        let firstHandle = try #require(rig.handle)
        #expect(firstHandle.ended)
        let more = rig.queue.add([.link(linkC), .link(URL(string: "https://x.com/i/status/2105435404002562057")!)], via: .review)
        await rig.drive { more.allSatisfy { rig.isSaved($0) } }
        await rig.settle()
        #expect(rig.adapter.requests.count == 2, "one activity per period")
        let second = try #require(rig.adapter.handles.last)
        #expect(second !== firstHandle && second.end?.state.savedCount == 2)
        #expect(firstHandle.endCalls.count == 1, "the first period's finished activity is left alone")
    }

    // MARK: per-run mode beside the queue

    @Test func aSavedJobNobodyHasOpenEndsItsReadyActivityAndATitleChangeDoesNotBringItBack() async throws {
        let rig = SummaryRig()
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive { rig.isSaved(job) }
        let handle = try #require(rig.handle)
        #expect(!handle.ended, "ready to trim, on the focused job")
        rig.queue.unfocus()
        await rig.settle()
        #expect(handle.ended && handle.end?.dismissAt == nil)
        // a second report of the same saved job (a title change tells the sink again) is not a new run
        rig.manager.stateChanged(job.pipeline)
        rig.manager.jobsChanged(rig.queue)
        await rig.settle()
        #expect(rig.adapter.requests.count == 1)
    }

    @Test func aSavedJobWaitingForItsTrimYieldsTheIslandToTheNextJob() async throws {
        let rig = SummaryRig()
        let first = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive { rig.isSaved(first) }
        let readyHandle = try #require(rig.handle)
        let next = rig.queue.add([.link(linkB)], via: .paste)[0]            // alongside: the first holds the focus
        #expect(rig.queue.focusedID == first.id)
        await rig.drive { rig.isSaved(next) }
        await rig.settle()
        #expect(readyHandle.ended, "the ready activity went when another job began")
        #expect(rig.adapter.requests.count == 2, "the next job's own activity: one live job is today's per-run activity")
        #expect(!rig.manager.inBusyPeriod)
    }

    // MARK: background time

    @Test func theGraceIsHeldWhileTheSummaryHasWorkInFlightInTheBackground() async throws {
        let rig = SummaryRig()
        _ = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        await rig.settle()
        #expect(rig.grace.begins == 0, "in the foreground there is nothing to ask for")
        rig.manager.didEnterBackground()
        #expect(rig.grace.active, "local mode needs the process while the summary has work")
        rig.manager.foreground()
        #expect(!rig.grace.active)
    }
}

// MARK: - push mode: the first job's server run

@MainActor
@Suite(.serialized)
struct LiveSummaryPushTests {
    private func rig() -> LiveRig {
        LiveRig(.shortClip, push: true, environment: .sandbox)
    }

    @Test func theFirstJobsServerRunIsDeletedAndTheSummaryAsksForItsOwnActivity() async throws {
        let rig = rig()
        let queue = rig.h.app.queue
        let first = queue.add([.link(URL(string: shortLink)!)], via: .paste)[0]
        await rig.drive { if case .saving = first.pipeline.state { true } else { false } }
        let firstHandle = try #require(rig.handle)
        firstHandle.sendToken(hexToken)
        await rig.settle()
        #expect(rig.log.runs.count == 1, "push mode registered the first run")
        let firstRun = first.pipeline.liveRunID

        let batch = queue.add([.link(linkC)], via: .review)               // (`shortLink` is `linkB`: a repeat would be folded)
        await rig.settle()
        #expect(rig.log.ends == [firstRun], "the server stops writing that run")
        // Deleting a run the server has a token for ends its activity (APP-API-CONTRACT 8.2): it cannot carry the summary.
        #expect(firstHandle.ended && firstHandle.end?.dismissAt == nil)
        #expect(rig.adapter.requests.count == 2)
        let second = try #require(rig.adapter.requests.dropFirst().first)
        #expect(second.push == false, "the summary is local: it asks for no push token")
        #expect(second.attributes.run != firstRun.uuidString.lowercased(), "its own run id: the server never hears of it")
        await rig.drive { first.pipeline.state == .ready && batch.allSatisfy { $0.pipeline.state == .ready } }
        await rig.settle()
        let summary = try #require(rig.adapter.handles.last)
        #expect(summary !== firstHandle && summary.end?.state.isFinishedSummary == true)
        #expect(rig.log.runs.count == 1, "no registration after the period began")
        #expect(rig.adapter.requests.count == 2)
    }

    @Test func localModeNeverRegisteredTheRunSoNothingIsDeletedAndTheActivityIsKept() async throws {
        let rig = LiveRig(.shortClip, push: false)
        let queue = rig.h.app.queue
        let first = queue.add([.link(URL(string: shortLink)!)], via: .paste)[0]
        await rig.drive { if case .saving = first.pipeline.state { true } else { false } }
        let batch = queue.add([.link(linkC)], via: .review)
        await rig.drive { first.pipeline.state == .ready && batch.allSatisfy { $0.pipeline.state == .ready } }
        await rig.settle()
        #expect(rig.log.ends.isEmpty && rig.log.runs.isEmpty)
        #expect(rig.adapter.requests.count == 1)
        #expect(rig.handle?.end?.state.isFinishedSummary == true)
    }
}

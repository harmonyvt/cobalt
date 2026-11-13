import Foundation
import Testing
@testable import CobaltKit

// The busy period's one Live Activity (CONTRACT-PARALLEL.md section 6) on a fake ActivityKit and the virtual clock:
// one job is today's per-run activity; the second live job keeps the first activity and asks ActivityKit for no other;
// the activity is written at most once a second; it shows the period's jobs as rows (`JobLive.many`, CONTRACT-JOBLIVE.md
// 2.1: "1 done, 2 going", at most 3 rows); it ends with what came out of the period ("3 done").

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
    func contents(of handle: FakeLiveHandle) -> [JobLiveState] {
        var out: [JobLiveState] = []
        if let request = adapter.requests.first(where: { $0.attributes.id == handle.attributes.id }) { out.append(request.state) }
        out += handle.updates.map(\.state)
        if let end = handle.end { out.append(end.state) }
        return out
    }

    /// The moment each update was sent: its stale date is that moment plus 180 s.
    func sendTimes(of handle: FakeLiveHandle) -> [Date] {
        handle.updates.compactMap { $0.staleDate?.addingTimeInterval(-LiveActivityManager.staleSeconds) }
    }
}

extension JobLiveState {
    /// How many jobs the busy period's headline says are in `word` ("done", "going", "failed"): "2 done, 1 failed".
    func count(_ word: String) -> Int {
        for part in headline.components(separatedBy: ", ") {
            let bits = part.split(separator: " ")
            if bits.count == 2, bits[1] == word, let n = Int(bits[0]) { return n }
        }
        return 0
    }

    /// The busy period's state (it has rows) and it has ended.
    var isFinishedPeriod: Bool { rows != nil && isTerminal }
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
        #expect(rig.adapter.requests[0].attributes.id == job.pipeline.liveRunID.uuidString.lowercased(), "the run's own activity")
        let handle = try #require(rig.handle)
        let contents = rig.contents(of: handle)
        #expect(contents.allSatisfy { $0.rows == nil }, "a per-run activity carries no rows")
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
        let began = try #require(writes.firstIndex { $0.rows != nil }, "the period wrote its first rows")
        #expect(writes[..<began].allSatisfy { $0.rows == nil }, "before the second job it was the run's own activity")
        #expect(writes[began...].allSatisfy { $0.rows != nil }, "every write after that speaks for the period")
        #expect((writes.compactMap { $0.rows?.count }.max() ?? 0) == 3)
        let end = try #require(handle.end)
        #expect(end.state.phase == .done && end.state.isFinishedPeriod && end.state.headline == "3 done")
        #expect(end.state.rows?.allSatisfy { $0.phase == .done && $0.status == "saved" } == true)
        #expect(end.state.fraction == 1 && end.state.compact == "3/3")
        let dismiss = try #require(end.dismissAt)
        #expect(abs(dismiss.timeIntervalSince(rig.line.clock.now()) - 60) < 1, "a done period stays a minute")
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

    @Test func theRowsSpeakForEveryJobAndTheDoneCountOnlyGrows() async throws {
        // a server that is busy with a share from the iphone: every job of this app waits behind it
        let rig = SummaryRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        await rig.drive { jobs.allSatisfy { rig.isSaved($0) } }
        await rig.settle()
        let handle = try #require(rig.handle)
        let writes = handle.updates.map(\.state).filter { $0.rows != nil && !$0.isTerminal }
        #expect(!writes.isEmpty)
        #expect(writes.allSatisfy { $0.count("done") + $0.count("going") + $0.count("failed") == 3 }, "every job is counted")
        #expect(writes.contains { $0.count("going") == 3 }, "while they wait, all three are going")
        let done = writes.map { $0.count("done") }
        #expect(zip(done, done.dropFirst()).allSatisfy { $0 <= $1 }, "done never goes down: \(done)")
        let fractions = writes.compactMap(\.fraction)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }, "the bar is done / total: \(fractions)")
    }

    @Test func aPeriodOfFourJobsShowsAtMostThreeRowsNewestFirst() async throws {
        let rig = SummaryRig()
        let fourth = URL(string: "https://x.com/i/status/2105435404002562057")!
        let jobs = rig.queue.add([.link(linkA), .link(linkB), .link(linkC), .link(fourth)], via: .review)
        await rig.drive { jobs.allSatisfy { rig.isSaved($0) } }
        await rig.settle()
        let handle = try #require(rig.handle)
        let states = rig.contents(of: handle).filter { $0.rows != nil }
        #expect(!states.isEmpty)
        #expect(states.allSatisfy { ($0.rows?.count ?? 0) <= 3 }, "at most 3 rows (CONTRACT-JOBLIVE.md 2.1)")
        #expect(states.contains { $0.rows?.count == 3 })
        #expect(states.allSatisfy { $0.steps == ["jobs"] && $0.compact?.hasSuffix("/4") == true }, "the count covers all four")
        // newest first by when each job joined, the same rows in the same order on every write (a stage change used to
        // reshuffle them and hide the newest job)
        let newestFirst = ["x · 2105435404002562057", "tiktok · @cobalt", "x · 2105435404002562056"]
        for state in states where state.rows?.count == 3 {
            #expect(state.rows?.map(\.title) == newestFirst, "\(state.rows?.map(\.title) ?? [])")
        }
        // the clock counts from the period's start: it never moves
        let sinces = Set(states.map(\.since))
        #expect(sinces.count == 1, "since moved: \(states.map(\.since))")
        let end = try #require(handle.end)
        #expect(end.state.headline == "4 done" && end.state.rows?.map(\.title) == newestFirst)
        #expect(end.state.since == states.first?.since)
        #expect(rig.adapter.requests.count == 1)
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

    @Test func aFailureIsCountedAndKeepsAPeriodWithSomethingSavedFiveMinutes() async throws {
        let rig = SummaryRig()
        let jobs = rig.queue.add([.link(linkA), .link(linkPrivate), .link(linkC)], via: .review)
        await rig.drive { jobs.allSatisfy { rig.isSaved($0) || rig.isFailed($0) } }
        await rig.settle()
        let handle = try #require(rig.handle)
        let end = try #require(handle.end)
        #expect(end.state.headline == "2 done, 1 failed", "\(end.state)")
        #expect(end.state.phase == .done && end.state.rows?.filter { $0.phase == .failed }.count == 1)
        #expect(abs(try #require(end.dismissAt).timeIntervalSince(rig.line.clock.now()) - 300) < 1, "a failure is seen: 300 s")
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
        #expect(end.state.phase == .failed && end.state.headline == "2 failed", "\(end.state)")
        #expect(abs(try #require(end.dismissAt).timeIntervalSince(rig.line.clock.now()) - 300) < 1)
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
        #expect(end.state.isFinishedPeriod, "\(end.state)")
        let statuses = end.state.rows?.map(\.status) ?? []
        #expect(statuses.filter { $0 == "webp ready" }.count == 1, "the webp is its row: \(statuses)")
        #expect(statuses.filter { $0 == "saved" }.count == 1, "the new save: \(statuses)")
        #expect(end.state.headline == "2 done")
        #expect(abs(try #require(end.dismissAt).timeIntervalSince(rig.line.clock.now()) - 120) < 1, "all done, one with a link: 120 s")
    }

    @Test func aJobDismissedWhileItsWebpRendersEndsThePeriodAsSaved() async throws {
        let rig = SummaryRig()
        let jobs = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        let first = jobs[0]
        await rig.drive { rig.isSaved(first) }
        #expect(rig.manager.inBusyPeriod)
        first.pipeline.makeWebp()
        await rig.drive { if case .rendering = first.pipeline.state { true } else { false } }
        // off the tray mid-render: its save stands, the render goes on unseen
        rig.queue.dismiss(first.id)
        await rig.drive { jobs.dropFirst().allSatisfy { rig.isSaved($0) } }
        await rig.settle()
        let end = try #require(rig.handle?.end)
        #expect(end.state.isFinishedPeriod, "\(end.state)")
        #expect(end.state.count("going") == 0 && end.state.headline == "3 done", "\(end.state.headline)")
        #expect(end.state.rows?.allSatisfy { $0.phase == .done } == true, "\(end.state.rows ?? [])")
        #expect(abs(try #require(end.dismissAt).timeIntervalSince(rig.line.clock.now()) - 60) < 1)
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
        #expect(handle.end?.state.isTerminal == false, "it ends on what it showed, not on a result")
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
        #expect(second !== firstHandle && second.end?.state.headline == "2 done")
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

// MARK: - a busy period that begins while the app is away

@MainActor
@Suite(.serialized)
struct LiveSummaryBackgroundTests {
    @Test func aPeriodOverAPushActivityWaitsForTheForegroundAndKeepsTheActivity() async throws {
        let rig = LiveRig(.shortClip, push: true, environment: .sandbox)
        let queue = rig.h.app.queue
        let first = queue.add([.link(URL(string: shortLink)!)], via: .paste)[0]
        await rig.drive { if case .saving = first.pipeline.state { true } else { false } }
        let firstHandle = try #require(rig.handle)
        firstHandle.sendToken(hexToken)
        await rig.settle()
        #expect(rig.log.runs.count == 1)
        let attemptsBefore = rig.adapter.requestAttempts

        rig.manager.didEnterBackground()
        rig.adapter.inForeground = false                              // ActivityKit would refuse a request now
        _ = queue.add([.link(linkC)], via: .shortcut)
        await rig.settle()
        #expect(!rig.manager.inBusyPeriod, "the period waits: it would have to end the push activity and ask for a new one")
        #expect(!firstHandle.ended && rig.log.ends.isEmpty, "the first activity and its server run are left alone")
        #expect(rig.adapter.requestAttempts == attemptsBefore, "nothing is requested from the background")

        rig.adapter.inForeground = true
        rig.manager.foreground()
        await rig.settle()
        #expect(rig.manager.inBusyPeriod, "foreground begins the period")
        #expect(rig.log.ends == [first.pipeline.liveRunID], "now the server stops writing the first run")
        #expect(firstHandle.ended)
        let summary = try #require(rig.manager.summaryHandle as? FakeLiveHandle)
        #expect(summary !== firstHandle && summary.state.rows?.count == 2)
    }

    @Test func aRefusedSummaryRequestIsNotMarkedTriedAndTheForegroundAsksAgain() async throws {
        let rig = SummaryRig()
        rig.manager.didEnterBackground()
        rig.adapter.inForeground = false
        _ = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.settle()
        #expect(rig.manager.inBusyPeriod && rig.manager.summaryHandle == nil, "no activity could be started from the background")
        #expect(rig.adapter.requests.isEmpty)

        rig.adapter.inForeground = true
        rig.manager.foreground()
        await rig.settle()
        let summary = try #require(rig.manager.summaryHandle as? FakeLiveHandle, "foreground() asked again")
        #expect(summary.state.rows?.count == 2 && summary.attributes.kind == "many")
        #expect(rig.adapter.requests.count == 1)
    }

    @Test func aRefusalInTheForegroundIsRetriedAfterAPauseNotOnEveryEvent() async throws {
        let rig = SummaryRig(.serverBusyWithShare)                   // the jobs wait in the server's line: they are still live later
        rig.adapter.inForeground = false                             // refused although the app thinks it is in front
        _ = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.settle()
        let tries = rig.adapter.requestAttempts
        #expect(tries >= 1 && rig.manager.summaryHandle == nil)
        rig.manager.jobsChanged(rig.queue)
        rig.manager.jobsChanged(rig.queue)
        #expect(rig.adapter.requestAttempts == tries, "a refused request waits before it is tried again")
        rig.adapter.inForeground = true
        rig.line.clock.jump(by: LiveActivityManager.requestRetrySeconds + 1)
        rig.manager.jobsChanged(rig.queue)
        #expect(rig.manager.summaryHandle != nil, "it came through on the next try")
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
        #expect(second.attributes.id != firstRun.uuidString.lowercased(), "its own id: the server never hears of it")
        #expect(second.attributes.kind == "many" && second.attributes.title == "2 jobs" && second.attributes.open == "cobalt-apple://jobs")
        #expect(second.state.rows?.count == 2 && second.state.headline == "2 going")
        await rig.drive { first.pipeline.state == .ready && batch.allSatisfy { $0.pipeline.state == .ready } }
        await rig.settle()
        let summary = try #require(rig.adapter.handles.last)
        #expect(summary !== firstHandle && summary.end?.state.isFinishedPeriod == true)
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
        #expect(rig.handle?.end?.state.isFinishedPeriod == true)
    }
}

import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// The fixes found by the read-only review of f6619e52b (1.13): a share job asks for no Live Activity of its own, one
// leave is one `PUT /studio/line/notify`, a second tap on cancel is ignored, finished jobs leave the queue (and the
// memory) after their time in the tray, and the Upload files action reads its bytes lazily, one file at a time.
// The Live manager's background rules are in `LiveSummaryBackgroundTests` (LiveSummaryTests.swift).

// MARK: - 2. a share job never asks for an activity

@MainActor
@Suite(.serialized)
struct ShareJobLiveTests {
    private func shareSession(_ rig: SummaryRig) async throws -> StudioSession {
        let created = try await rig.line.client.createStudio(link: linkA, public: nil, queue: true, title: nil)
        let now = rig.line.clock.now()
        return StudioSession(
            id: created.id, status: .saving, link: linkA.absoluteString, service: "instagram", title: nil, duration: nil,
            width: nil, height: nil, bytes: nil, createdAt: now, expiresAt: now.addingTimeInterval(3600),
            errorCode: nil, renders: [], step: .queued, stepBytes: nil, stepTotal: nil, waking: false, queueAhead: 1)
    }

    @Test func anAdoptedShareJobNeverRequestsALocalActivityNextToTheServersOne() async throws {
        let rig = SummaryRig(.serverBusyWithShare)
        let session = try await shareSession(rig)
        rig.line.ctx.recentShares = { [session] }
        await rig.line.queue.adoptRecentShares()
        #expect(rig.queue.jobs.count == 1 && rig.queue.jobs[0].via == .share)
        await rig.run(for: 5)
        #expect(rig.adapter.requestAttempts == 0, "the activity the server started for the share is the only one")
        #expect(rig.adapter.handles.isEmpty && !rig.manager.inBusyPeriod)
    }

    @Test func aShareJobStillCountsInTheBusyPeriodsSummary() async throws {
        let rig = SummaryRig(.serverBusyWithShare)
        let session = try await shareSession(rig)
        rig.line.ctx.recentShares = { [session] }
        await rig.line.queue.adoptRecentShares()
        let own = rig.queue.add([.link(linkB)], via: .paste)[0]
        await rig.run(for: 1)
        #expect(rig.manager.inBusyPeriod, "two live jobs: one of them is the share")
        let summary = try #require(rig.manager.summaryHandle as? FakeLiveHandle)
        #expect(summary.state.jobs == 2)
        #expect(rig.adapter.requests.count == 1, "the summary's own request, none for the share")
        #expect(rig.adapter.requests[0].attributes.run != rig.queue.jobs[0].pipeline.liveRunID.uuidString.lowercased())
        _ = own
    }

    @Test func aPipelineTheOwnerStartsKeepsAskingForItsOwnActivity() async throws {
        let rig = SummaryRig()
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        #expect(job.pipeline.requestsLiveActivity)
        await rig.drive { rig.isSaved(job) }
        #expect(rig.adapter.requests.count == 1)
    }
}

// MARK: - (a) one leave, one PUT

@MainActor
struct LeaveOnceTests {
    @Test func resigningAndThenEnteringTheBackgroundSendsOnePutPerLeave() async throws {
        let rig = CQRig(.server, notifyBridge: true)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.line.drive(until: { rig.hasSessions(jobs) })
        await rig.line.settle()
        rig.activity.isActive = false
        rig.controller.appResigned()                       // ContinuedProcessing: the scene resigns active
        await rig.settleNotify()                           // (the first PUT is answered before the background arrives)
        rig.queue.appLeft()                                // AppShell: scenePhase becomes .background
        await rig.settleNotify()
        #expect(rig.line.calls.filter { $0 == "PUT line/notify" }.count == 1, "\(rig.line.calls)")

        rig.activity.isActive = true
        rig.controller.appBecameActive()
        await rig.settleNotify()
        #expect(rig.line.calls.filter { $0 == "DELETE line/notify" }.count == 1)

        rig.activity.isActive = false                      // the next leave is a new one
        rig.queue.appLeft()
        await rig.settleNotify()
        rig.controller.appResigned()
        rig.queue.appLeft()
        await rig.settleNotify()
        #expect(rig.line.calls.filter { $0 == "PUT line/notify" }.count == 2, "\(rig.line.calls)")
    }

    @Test func theBackgroundAloneStillSendsItsOnePut() async throws {
        let rig = CQRig(.server, notifyBridge: true)
        let jobs = rig.queue.add([.link(linkA)], via: .review)
        await rig.line.drive(until: { rig.hasSessions(jobs) })
        rig.queue.appLeft()
        await rig.settleNotify()
        rig.queue.appLeft()
        await rig.settleNotify()
        #expect(rig.line.calls.filter { $0 == "PUT line/notify" }.count == 1)
    }
}

// MARK: - (c) a second tap on cancel

@MainActor
struct CancelOnceTests {
    @Test func aSecondCancelWhileTheFirstIsInFlightSendsNothingAndSaysNothing() async throws {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.settle()
        let sid = try #require(jobs[1].pipeline.sessionID)
        async let first: Void = rig.queue.cancel(jobs[1].id)
        async let second: Void = rig.queue.cancel(jobs[1].id)
        _ = await (first, second)
        #expect(rig.calls.filter { $0 == "DELETE line \(sid)" }.count == 1, "\(rig.calls)")
        #expect(rig.queue.job(jobs[1].id) == nil)
        #expect(rig.queue.notice?.kind == .cancelled, "not a false \"couldn't cancel\"")
    }

    @Test func aCancelThatFailedMayBeTriedAgain() async throws {
        let rig = LineRig(.serverBusyWithShare)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.settle()
        rig.server.cancelFails = true
        await rig.queue.cancel(jobs[1].id)
        #expect(rig.queue.notice?.kind == .couldntCancel && rig.queue.job(jobs[1].id) != nil)
        rig.server.cancelFails = false
        await rig.queue.cancel(jobs[1].id)
        #expect(rig.queue.job(jobs[1].id) == nil && rig.queue.notice?.kind == .cancelled)
    }
}

// MARK: - (e) finished jobs leave the queue

@MainActor
struct FinishedJobsLeaveTests {
    @Test func aFinishedJobIsReleasedAfterItsTimeInTheTrayAndStillCounts() async throws {
        let rig = LineRig(.server)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 120)
        #expect(rig.queue.jobs.count == 2 && rig.queue.summary.finished == 2)
        weak var gone = jobs[0].pipeline
        await rig.run(for: JobQueue.finishedLinger + 2)
        #expect(rig.queue.jobs.isEmpty, "nothing finished stays in memory after the tray let go")
        #expect(rig.queue.summary == JobSummary(live: 0, waiting: 0, finished: 2, failed: 0), "the counts survive")
        await yieldMain()
        #expect(gone == nil || gone !== rig.app.pipeline)
    }

    @Test func aFailedJobStaysUntilTheOwnerActsOnIt() async throws {
        let rig = LineRig(.server)
        _ = rig.queue.add([.link(linkPrivate), .link(linkA)], via: .review)
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 120)
        await rig.run(for: JobQueue.finishedLinger + 2)
        #expect(rig.queue.jobs.count == 1 && rig.queue.jobs[0].isFailed)
        #expect(rig.queue.summary.failed == 1 && rig.queue.summary.finished == 1)
    }

    @Test func theFocusedJobStaysWhileItIsFocusedAndGoesAfterItIsClosed() async throws {
        let rig = LineRig(.server)
        let job = rig.queue.add([.link(linkA)], via: .paste)[0]
        await rig.drive(until: { rig.allSettled() }, maxVirtualSeconds: 120)
        #expect(rig.queue.focusedID == job.id)
        await rig.run(for: JobQueue.finishedLinger * 3)
        #expect(rig.queue.job(job.id) != nil, "the screen is showing it")
        rig.queue.unfocus()
        await rig.run(for: JobQueue.finishedLinger + 2)
        #expect(rig.queue.job(job.id) == nil && rig.queue.summary.finished == 1)
    }

    @Test func aBusyPeriodStillCountsWhatALeftJobHadSaved() async throws {
        let rig = SummaryRig()
        let jobs = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        await rig.drive { jobs.allSatisfy { rig.isSaved($0) } }
        await rig.run(for: JobQueue.finishedLinger + 2)
        #expect(rig.queue.jobs.isEmpty)
        let handle = try #require(rig.handle)
        #expect(handle.end?.state.savedCount == 3, "\(String(describing: handle.end?.state))")
    }
}

// MARK: - 3. Upload files reads its bytes lazily

private final class ReadProbe: Sendable {
    private let state = Mutex((reads: [String](), inbox: [Int]()))
    func read(_ name: String, inboxFiles: Int) { state.withLock { $0.reads.append(name); $0.inbox.append(inboxFiles) } }
    var reads: [String] { state.withLock { $0.reads } }
    /// How many files were already in the inbox at the moment each read began.
    var inboxAtRead: [Int] { state.withLock { $0.inbox } }
}

@MainActor
struct LazyUploadTests {
    /// Files under the inbox (each copy gets its own folder there).
    nonisolated private static func filesUnder(_ inbox: URL) -> Int {
        guard let walk = FileManager.default.enumerator(at: inbox, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        return walk.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
    }

    private func inbox(_ t: ShortcutRig) -> URL {
        t.ctx.store.inboxURL(for: "probe").deletingLastPathComponent().deletingLastPathComponent()
    }

    private func inboxCount(_ t: ShortcutRig) -> Int { Self.filesUnder(inbox(t)) }

    private func deferred(_ name: String, _ bytes: Int, _ probe: ReadProbe, _ t: ShortcutRig) -> ShortcutFile {
        let dir = inbox(t)
        return ShortcutFile(name: name, source: .deferred {
            let count = LazyUploadTests.filesUnder(dir)
            probe.read(name, inboxFiles: count)
            return Data(repeating: 5, count: bytes)
        })
    }

    @Test func nothingIsReadUntilTheActionStagesItAndOneFileIsWrittenBeforeTheNextIsRead() async throws {
        let t = ShortcutRig(.server)
        let probe = ReadProbe()
        let base = inboxCount(t)
        let files = [deferred("a.mp4", 30_000, probe, t), deferred("b.mp4", 40_000, probe, t)]
        #expect(probe.reads.isEmpty, "building the action's input reads nothing")
        let outcome = try await t.run { try await t.actions.uploadFiles(files) }.get()
        #expect(outcome.saves.count == 2)
        #expect(probe.reads == ["a.mp4", "b.mp4"])
        #expect(probe.inboxAtRead == [base, base + 1], "the first was on disk, and let go, before the second was read: \(probe.inboxAtRead)")
    }

    @Test func aRefusedActionReadsNothing() async {
        let t = ShortcutRig(.off)                                          // an old server: refused before any file is touched
        let probe = ReadProbe()
        let result = await t.run { try await t.actions.uploadFiles([self.deferred("a.mp4", 10, probe, t)]) }
        #expect(throws: ShortcutError.oldServer) { try result.get() }
        #expect(probe.reads.isEmpty)
        #expect(t.queue.jobs.isEmpty)
    }

    @Test func aDeferredFileOverTheLimitIsRefusedAfterTheReadAndNeverWritten() async {
        let t = ShortcutRig(.server) { $0.capsHook = { $0.notifyBridge = true; $0.limits.maxUploadBytes = 1_000 } }
        let probe = ReadProbe()
        let base = inboxCount(t)
        let result = await t.run {
            try await t.actions.uploadFiles([
                self.deferred("ok.mp4", 100, probe, t), self.deferred("big.mp4", 5_000, probe, t), self.deferred("never.mp4", 10, probe, t),
            ])
        }
        #expect(throws: ShortcutError.fileTooLarge(limit: 1_000)) { try result.get() }
        #expect(probe.reads == ["ok.mp4", "big.mp4"], "the third file is never touched once one is over the limit")
        #expect(t.calls.isEmpty && t.queue.jobs.isEmpty)
        #expect(inboxCount(t) == base, "the first copy was cleaned up and the big one never written")
    }

    @Test func aFileURLIsStillPreferredAndSizedFromItsAttributes() async throws {
        let t = ShortcutRig(.server) { $0.capsHook = { $0.limits.maxUploadBytes = 1_000 } }
        let big = try makeTempFile("big.mov", bytes: 5_000)
        let result = await t.run { try await t.actions.uploadFiles([ShortcutFile(name: "big.mov", source: .url(big))]) }
        #expect(throws: ShortcutError.fileTooLarge(limit: 1_000)) { try result.get() }
        #expect(ShortcutActions.size(of: ShortcutFile(name: "big.mov", source: .url(big))) == 5_000)
        #expect(t.queue.jobs.isEmpty)
    }
}

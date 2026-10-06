import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// Continued processing for the queue (CONTRACT-PARALLEL.md section 6): one task per busy period, wanted on a server that
// holds the line only while work of THIS device remains, a number that counts every job of the spell, and one message
// to the server for everything left behind. The single-run behaviour is `ContinuedProcessingTests` in CoreLaneTests.

@MainActor
final class CQScheduler: ContinuedTaskScheduler {
    var isAvailable = true
    var failSubmit: (any Error)?
    private(set) var registeredPattern: String?
    private(set) var submitted: [(id: String, title: String, subtitle: String)] = []
    private(set) var cancelled: [String] = []
    private var launch: (@MainActor (any ContinuedTaskHandle, String) -> Void)?

    func register(pattern: String, launch: @escaping @MainActor (any ContinuedTaskHandle, String) -> Void) -> Bool {
        registeredPattern = pattern
        self.launch = launch
        return true
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        if let failSubmit { throw failSubmit }
        submitted.append((identifier, title, subtitle))
    }

    func cancel(identifier: String) { cancelled.append(identifier) }

    /// The system starts the last submitted task.
    func start(_ handle: CQHandle) {
        guard let id = submitted.last?.id else { return }
        launch?(handle, id)
    }
}

@MainActor
final class CQHandle: ContinuedTaskHandle {
    private(set) var progress: [Int64] = []
    private(set) var total: Int64 = 0
    private(set) var titles: [String] = []
    private(set) var subtitles: [String] = []
    private(set) var completed: Bool?
    var expire: (@MainActor () -> Void)?

    func setProgress(completed: Int64, total: Int64) { progress.append(completed); self.total = total }
    func update(title: String, subtitle: String) { titles.append(title); subtitles.append(subtitle) }
    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) { expire = handler }
    func complete(success: Bool) { completed = success }
}

/// What the owner was told: the share kinds and the "waiting for cobalt" notices.
final class CQNotifier: NotificationPosting, WaitingNoticePosting, Sendable {
    private let kinds = Mutex<[Notifications.Kind]>([])
    private let notices = Mutex<[WaitingNotice]>([])
    private let clears = Mutex(0)
    func post(_ kind: Notifications.Kind, jobID: UUID) async { kinds.withLock { $0.append(kind) } }
    func postWaiting(_ notice: WaitingNotice) async { notices.withLock { $0.append(notice) } }
    func clearWaiting() async { clears.withLock { $0 += 1 } }
    var posts: [Notifications.Kind] { kinds.withLock { $0 } }
    var waiting: [WaitingNotice] { notices.withLock { $0 } }
    var cleared: Int { clears.withLock { $0 } }
}

@MainActor
private final class CQCounter {
    var n = 0
    func next() -> String { n += 1; return "com.capybaraharmony.cobalt.run.q\(n)" }
}

@MainActor
struct CQRig {
    let line: LineRig
    let scheduler = CQScheduler()
    let notifier = CQNotifier()
    let activity = FakeActivity()
    let controller: ContinuedProcessing

    init(_ mode: LinePreviewMode, notifyBridge: Bool = false) {
        line = LineRig(mode, notifyBridge: notifyBridge)
        line.ctx.notifier = notifier
        line.ctx.background.activity = activity
        activity.isActive = true
        let app = line.app
        let counter = CQCounter()
        controller = ContinuedProcessing(
            context: line.ctx, scheduler: scheduler, home: { app.pipeline }, makeIdentifier: { counter.next() })
        line.ctx.continued = controller
        controller.register()
    }

    var queue: JobQueue { line.queue }
    var server: PreviewServer { line.server }

    func hasSessions(_ jobs: [Job]) -> Bool { jobs.allSatisfy { $0.pipeline.sessionID != nil } }

    /// The notify bridge's calls reach the (preview) server.
    func settleNotify() async {
        await line.ctx.notify.settled()
        await line.settle()
    }
}

// MARK: - what needs this process

@MainActor
struct ContinuedNeedsProcessTests {
    private func pipeline(_ state: PipelineState, session: String? = nil) -> Pipeline {
        let p = Pipeline(context: Harness(.shortClip).ctx)
        p.setState(state)
        p.sessionID = session
        return p
    }

    @Test func withoutALineEveryStepOfARunNeedsTheProcess() {
        let t = Date()
        for state: PipelineState in [
            .fetching(since: t, waking: false), .uploading(TransferProgress(bytes: 1, total: 2)),
            .saving(bytes: 1, total: 2, since: t), .reading(developed: 1, of: 9), .rendering(.working(since: t)),
        ] {
            #expect(ContinuedProcessing.needsProcess(pipeline(state, session: "S"), serverMode: false), "\(state)")
        }
        #expect(!ContinuedProcessing.needsProcess(pipeline(.ready), serverMode: false))
        #expect(ContinuedProcessing.isBusy(pipeline(.saving(bytes: nil, total: nil, since: t))))
    }

    @Test func withALineOnlyWorkOfThisDeviceNeedsIt() {
        let t = Date()
        // before the server has it: the create in flight, a link check, an upload, frames being read
        #expect(ContinuedProcessing.needsProcess(pipeline(.fetching(since: t, waking: false)), serverMode: true))
        #expect(ContinuedProcessing.needsProcess(pipeline(.uploading(TransferProgress(bytes: 1, total: 2))), serverMode: true))
        #expect(ContinuedProcessing.needsProcess(pipeline(.reading(developed: 1, of: 9), session: "S"), serverMode: true))
        // after: the server downloads, saves and renders without anybody polling
        #expect(!ContinuedProcessing.needsProcess(pipeline(.fetching(since: t, waking: false), session: "S"), serverMode: true), "queued or fetching")
        #expect(!ContinuedProcessing.needsProcess(pipeline(.saving(bytes: 1, total: 2, since: t), session: "S"), serverMode: true))
        #expect(!ContinuedProcessing.needsProcess(pipeline(.rendering(.decoding(done: 1, total: 2)), session: "S"), serverMode: true))
        #expect(!ContinuedProcessing.needsProcess(pipeline(.ready), serverMode: true))
    }

    @Test func theOriginalArrivingIsAlwaysThisDevicesWork() {
        let p = pipeline(.ready, session: "S")
        p.keepRequest = Task { nil }
        #expect(ContinuedProcessing.needsProcess(p, serverMode: true))
        p.keepRequest?.cancel()
        p.keepRequest = nil
        p.photos = .working
        #expect(ContinuedProcessing.needsProcess(p, serverMode: true))
    }
}

// MARK: - words and the number

@MainActor
struct ContinuedWordsTests {
    private func pipeline(_ state: PipelineState, line: LinePosition? = nil) -> Pipeline {
        let p = Pipeline(context: Harness(.shortClip).ctx)
        p.setState(state)
        p.line = line
        return p
    }

    @Test func severalJobsSayHowManySavesAndHowManyWait() {
        let t = Date()
        let a = pipeline(.saving(bytes: 1, total: 2, since: t))
        let b = pipeline(.fetching(since: t, waking: false), line: .inLine(2, behind: nil))
        let c = pipeline(.fetching(since: t, waking: false), line: .inLine(3, behind: nil))
        #expect(ContinuedProgress.subtitle(of: [a, b, c], lead: a) == "3 saves · 2 waiting")
        #expect(ContinuedProgress.subtitle(of: [a, pipeline(.saving(bytes: 1, total: 2, since: t))], lead: a) == "2 saves")
        #expect(ContinuedProgress.title(of: [a, b, c], lead: a) == "saving your videos")
        // a finished job is no longer counted; one left is its own label again
        let done = pipeline(.ready)
        #expect(ContinuedProgress.subtitle(of: [a, done], lead: a) == ContinuedProgress.subtitle(of: a))
        #expect(ContinuedProgress.title(of: [a, done], lead: a) == "saving your video")
    }

    @Test func severalRendersAreWebps() {
        let t = Date()
        let a = pipeline(.rendering(.working(since: t)))
        let b = pipeline(.rendering(.working(since: t)), line: .inLine(2, behind: nil))
        #expect(ContinuedProgress.title(of: [a, b], lead: a) == "making your webps")
        #expect(ContinuedProgress.subtitle(of: [a, b], lead: a) == "2 webps · 1 waiting")
    }

    @Test func theNumberIsTheMeanOverEveryJobOfTheSpellAndAFinishedJobCountsAsDone() {
        let t = Date()
        let now = t.addingTimeInterval(100)
        let running = pipeline(.saving(bytes: 50, total: 100, since: t))       // 0.12 + 0.5 * 0.5 = 0.37
        let done = pipeline(.ready)                                           // 1
        let mean = ContinuedProgress.fraction(ofSpell: [running, done], now: now)
        #expect(abs(mean - (0.37 + 1) / 2) < 0.001, "\(mean)")
        let reset = pipeline(.idle)
        #expect(ContinuedProgress.fraction(ofSpell: [running, reset], now: now) == ContinuedProgress.fraction(of: running, now: now), "a job the owner reset is not part of it")
        #expect(ContinuedProgress.fraction(ofSpell: [], now: now) == 0)
    }

    @Test func theWaitingNoticeNamesWhatIsWaiting() {
        #expect(WaitingNotice(links: 0, uploads: 1).title == "1 upload is waiting for cobalt")
        #expect(WaitingNotice(links: 0, uploads: 1).body == "open cobalt to finish it.")
        #expect(WaitingNotice(links: 2, uploads: 0).title == "2 links are waiting for cobalt")
        #expect(WaitingNotice(links: 2, uploads: 0).body == "open cobalt to finish them.")
        #expect(WaitingNotice(links: 1, uploads: 1).title == "2 jobs are waiting for cobalt")
        #expect(WaitingNotice(links: 1, uploads: 0).title == "1 link is waiting for cobalt")
    }
}

// MARK: - the task

@MainActor
@Suite(.serialized)
struct ContinuedQueueTests {
    @Test func aBatchGetsOneTaskForTheBusyPeriodNotOnePerJob() async throws {
        let rig = CQRig(.server)
        let handle = CQHandle()
        let jobs = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        #expect(rig.scheduler.submitted.count == 1, "one task for the three links being handed to the server")
        rig.scheduler.start(handle)
        #expect(handle.titles.first == "saving your videos" && handle.subtitles.first == "3 saves", "\(handle.titles) \(handle.subtitles)")
        // once the server has every one of them nothing of this device is left: the task is not needed
        await rig.line.drive(until: {
            rig.hasSessions(jobs) && jobs.contains { if case .saving = $0.pipeline.state { true } else { false } }
        })
        await rig.line.settle()
        #expect(rig.hasSessions(jobs))
        #expect(!rig.controller.isRunning, "a job queued or running on the server needs no process to finish")
        #expect(handle.completed == true, "the task ends when the last of this device's work is done")
        #expect(rig.scheduler.submitted.count == 1)
    }

    @Test func withoutALineTheTaskStaysForTheWholeSave() async throws {
        let rig = CQRig(.off)
        let handle = CQHandle()
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        #expect(rig.scheduler.submitted.count == 1)
        rig.scheduler.start(handle)
        #expect(rig.controller.isRunning)
        await rig.line.drive(until: { jobs.allSatisfy { rig.line.settled($0) } })
        await rig.line.settle()
        #expect(jobs.allSatisfy { $0.pipeline.state == .ready })
        #expect(rig.scheduler.submitted.count == 1, "one task for the whole period")
        #expect(handle.completed == true && !rig.controller.isRunning)
    }

    @Test func progressCountsEveryJobAndNeverGoesBackwards() async throws {
        let rig = CQRig(.off)
        let handle = CQHandle()
        let jobs = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        rig.scheduler.start(handle)
        await rig.line.drive(until: { jobs.allSatisfy { rig.line.settled($0) } })
        await rig.line.settle()
        #expect(handle.total == 1000 && !handle.progress.isEmpty)
        #expect(zip(handle.progress, handle.progress.dropFirst()).allSatisfy { $0 <= $1 }, "never backwards: \(handle.progress)")
        #expect(handle.progress.allSatisfy { $0 < 1000 })
        // the first job finishing is a third of the way, not the whole task
        #expect(handle.progress.contains { $0 > 200 && $0 < 800 }, "\(handle.progress)")
        #expect(handle.titles.contains("saving your videos"))
        #expect(handle.subtitles.first?.hasPrefix("3 saves") == true, "\(handle.subtitles)")
        #expect(handle.subtitles.contains { $0 == "2 saves" || $0 == "2 saves · 1 waiting" }, "the words follow what is left: \(handle.subtitles)")
        #expect(handle.completed == true)
    }

    // MARK: leaving

    @Test func leavingWithJobsOnTheServerSendsOneLineNotifyAndNothingPerSession() async throws {
        let rig = CQRig(.server, notifyBridge: true)
        let jobs = rig.queue.add([.link(linkA), .link(linkB), .link(linkC)], via: .review)
        await rig.line.drive(until: { rig.hasSessions(jobs) })
        await rig.line.settle()
        rig.activity.isActive = false
        rig.controller.appResigned()
        await rig.settleNotify()
        #expect(rig.line.calls.filter { $0 == "PUT line/notify" }.count == 1, "\(rig.line.calls)")
        #expect(rig.server.notifyCalls.isEmpty, "no per-session opt-in in server mode: \(rig.server.notifyCalls)")
        rig.activity.isActive = true
        rig.controller.appBecameActive()
        await rig.settleNotify()
        #expect(rig.line.calls.filter { $0 == "DELETE line/notify" }.count == 1, "\(rig.line.calls)")
        #expect(rig.server.notifyCalls.isEmpty)
    }

    @Test func leavingWithNothingOnTheServerStillTellsItNothing() async throws {
        let rig = CQRig(.server, notifyBridge: true)
        rig.activity.isActive = false
        rig.controller.appResigned()
        await rig.settleNotify()
        #expect(!rig.line.calls.contains("PUT line/notify"), "nothing is in flight: nothing to watch")
    }

    @Test func withoutALineEveryRunWithASessionKeepsItsOwnOptIn() async throws {
        let rig = CQRig(.off, notifyBridge: true)
        let jobs = rig.queue.add([.link(linkA)], via: .paste)
        await rig.line.drive(until: { if case .saving = jobs[0].pipeline.state { true } else { false } })
        let sid = try #require(jobs[0].pipeline.sessionID)
        rig.controller.appResigned()
        await rig.settleNotify()
        #expect(rig.server.notifyCalls == ["PUT \(sid)"], "\(rig.server.notifyCalls)")
        #expect(!rig.line.calls.contains("PUT line/notify"))
        rig.controller.appBecameActive()
        await rig.settleNotify()
        #expect(rig.server.notifyCalls == ["PUT \(sid)", "DELETE \(sid)"])
    }

    // MARK: work the server does not have

    @Test func anUploadMidWayIsToldToTheOwnerWhenTheTaskIsRefused() async throws {
        let rig = CQRig(.server)
        rig.scheduler.failSubmit = NSError(domain: "BGTaskSchedulerErrorDomain", code: 1)
        let file = try makeTempFile("clip.mov", bytes: 200_000)
        let jobs = rig.queue.add([.file(file, photosAssetID: nil)], via: .shortcut)
        await rig.line.settle()
        #expect(jobs[0].pipeline.sessionID == nil)
        rig.activity.isActive = false
        rig.controller.appResigned()
        await yieldMain()
        #expect(rig.notifier.waiting == [WaitingNotice(links: 0, uploads: 1)], "\(rig.notifier.waiting)")
        #expect(rig.notifier.waiting.first?.title == "1 upload is waiting for cobalt")
        // coming back says it is no longer true
        rig.activity.isActive = true
        rig.controller.appBecameActive()
        await yieldMain()
        #expect(rig.notifier.cleared == 1)
    }

    @Test func aTaskThatRunsNeedsNoNotice() async throws {
        let rig = CQRig(.server)
        let file = try makeTempFile("clip.mov", bytes: 200_000)
        _ = rig.queue.add([.file(file, photosAssetID: nil)], via: .shortcut)
        rig.scheduler.start(CQHandle())
        #expect(rig.controller.isRunning)
        rig.activity.isActive = false
        rig.controller.appResigned()
        await yieldMain()
        #expect(rig.notifier.waiting.isEmpty)
    }

    @Test func anExpiredTaskTellsTheOwnerWhatIsStillWaiting() async throws {
        let rig = CQRig(.server)
        let handle = CQHandle()
        let file = try makeTempFile("clip.mov", bytes: 200_000)
        _ = rig.queue.add([.file(file, photosAssetID: nil)], via: .shortcut)
        rig.scheduler.start(handle)
        rig.activity.isActive = false
        handle.expire?()
        await yieldMain()
        #expect(handle.completed == false && rig.controller.expirations == 1)
        #expect(rig.notifier.waiting == [WaitingNotice(links: 0, uploads: 1)], "\(rig.notifier.waiting)")
    }

    @Test func workTheServerHasIsLeftToTheServer() async throws {
        let rig = CQRig(.server, notifyBridge: true)
        rig.scheduler.failSubmit = NSError(domain: "BGTaskSchedulerErrorDomain", code: 1)
        let jobs = rig.queue.add([.link(linkA), .link(linkB)], via: .review)
        await rig.line.drive(until: { rig.hasSessions(jobs) })
        await rig.line.settle()
        rig.activity.isActive = false
        rig.controller.appResigned()
        await rig.settleNotify()
        #expect(rig.notifier.waiting.isEmpty, "the server says it when it is done")
        #expect(rig.line.calls.filter { $0 == "PUT line/notify" }.count == 1)
    }
}

import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import CobaltKit

final class FakeNotifier: NotificationPosting, Sendable {
    private let log = Mutex<[(kind: Notifications.Kind, job: UUID)]>([])
    private let asked = Mutex(0)
    func post(_ kind: Notifications.Kind, jobID: UUID) async { log.withLock { $0.append((kind, jobID)) } }
    func requestAuthorization() async { asked.withLock { $0 += 1 } }
    var authorizationRequests: Int { asked.withLock { $0 } }
    var posts: [(kind: Notifications.Kind, job: UUID)] { log.withLock { $0 } }
}

// MARK: - What the extension is handed

@MainActor
struct ShareInboxTests {
    private func store() throws -> OfflineStore {
        OfflineStore(root: try makeTempDirectory(), tools: PreviewMediaTools(clock: VirtualClock(), clip: PreviewData.long))
    }

    private func item(_ providers: [NSItemProvider]) -> NSExtensionItem {
        let i = NSExtensionItem()
        i.attachments = providers
        return i
    }

    @Test func aWebUrlBecomesALink() async throws {
        let url = URL(string: pastedLink)!
        let result = await ShareInbox.load([item([NSItemProvider(object: url as NSURL)])], store: try store())
        #expect(result == .link(url))
    }

    @Test func aFileUrlIsNotALink() async throws {
        let file = URL(fileURLWithPath: "/tmp/not-a-link.txt")
        let result = await ShareInbox.load([item([NSItemProvider(object: file as NSURL)])], store: try store())
        #expect(result == .none)
    }

    @Test func textContainingALinkYieldsTheFirstLink() async throws {
        let text = "look at this \(pastedLink) and \(shortLink) too"
        let result = await ShareInbox.load([item([NSItemProvider(object: text as NSString)])], store: try store())
        #expect(result == .link(URL(string: pastedLink)!))
    }

    @Test func textWithoutALinkIsNothing() async throws {
        let result = await ShareInbox.load([item([NSItemProvider(object: "just words, no link" as NSString)])], store: try store())
        #expect(result == .none)
        #expect(await ShareInbox.load([], store: try store()) == .none)
    }

    @Test func aMovieIsCopiedIntoTheInboxAndWinsOverALink() async throws {
        let s = try store()
        let source = try makeTempDirectory().appendingPathComponent("IMG_0412.MOV")
        let bytes = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: source)
        let movie = try #require(NSItemProvider(contentsOf: source))
        movie.suggestedName = "IMG_0412"                                              // what Photos names its movie
        let providers = [NSItemProvider(object: URL(string: pastedLink)! as NSURL), movie]
        guard case .file(let copied) = await ShareInbox.load([item(providers)], store: s) else {
            Issue.record("expected the movie")
            return
        }
        #expect(copied.lastPathComponent == "IMG_0412.mov")                           // the other app's name, the copy's extension
        #expect(try Data(contentsOf: copied) == bytes)
        #expect(copied.path.hasPrefix(s.root.appendingPathComponent("inbox").path))   // inside the store, where the pipeline will not copy it again
        #expect(FileManager.default.fileExists(atPath: source.path))                  // the original is left alone
    }

    @Test func theCopyKeepsTheNameTheOtherAppGaveTheFile() {
        let temp = URL(fileURLWithPath: "/tmp/QuickTime movie.mov")
        #expect(ShareInbox.fileName(for: temp, suggested: "IMG_0412") == "IMG_0412.mov")
        #expect(ShareInbox.fileName(for: temp, suggested: "IMG_0412.MOV") == "IMG_0412.mov")
        #expect(ShareInbox.fileName(for: temp, suggested: "a/b:c") == "a_b_c.mov")
        #expect(ShareInbox.fileName(for: temp, suggested: nil) == "QuickTime movie.mov")
        #expect(ShareInbox.fileName(for: temp, suggested: "") == "QuickTime movie.mov")
    }

    @Test func someAppsPutTheLinkOnlyInTheItemsOwnText() async throws {
        let i = NSExtensionItem()
        i.attributedContentText = NSAttributedString(string: "sent from somewhere: \(shortLink)")
        #expect(await ShareInbox.load([i], store: try store()) == .link(URL(string: shortLink)!))
        let titled = NSExtensionItem()
        titled.attributedTitle = NSAttributedString(string: pastedLink)
        #expect(await ShareInbox.load([titled], store: try store()) == .link(URL(string: pastedLink)!))
    }
}

// MARK: - Closing the sheet, handing off to the app

@MainActor
@Suite(.serialized)
struct ShareHandoffTests {
    final class Counter: @unchecked Sendable { var completed = 0; var opened: [URL] = [] }

    /// An extension-side pipeline and core on the harness's (preview) context.
    private func share(_ h: Harness, openApp: (@MainActor (URL) async -> Bool)? = nil)
        -> (pipeline: Pipeline, core: ShareCore, notifier: FakeNotifier, counter: Counter)
    {
        let pipeline = Pipeline(context: h.ctx)
        let notifier = FakeNotifier()
        let counter = Counter()
        let core = ShareCore(context: h.ctx, pipeline: pipeline, notifier: notifier)
        core.complete = { counter.completed += 1 }
        core.openApp = openApp ?? { url in counter.opened.append(url); return true }
        return (pipeline, core, notifier, counter)
    }

    private func drive(_ h: Harness, to condition: @escaping @MainActor () -> Bool) async { await h.drive(until: condition) }

    @Test func closingMidRenderLeavesAJobAndANotification() async throws {
        let h = Harness(.shortClip)
        let s = share(h)
        s.pipeline.start(link: URL(string: shortLink)!)
        await drive(h) { s.pipeline.state == .ready }
        s.pipeline.makeWebp()
        await drive(h) { s.pipeline.renderJobID != nil }
        guard case .rendering = s.pipeline.state, let renderJob = s.pipeline.renderJobID, let sid = s.pipeline.sessionID else {
            Issue.record("expected a render in flight, got \(s.pipeline.state)")
            return
        }

        let outcome = await s.core.close()
        #expect(outcome == .continuesInBackground)
        #expect(s.counter.completed == 1)
        let job = try #require(h.ctx.jobs.all().first)
        #expect(job.id == s.core.jobID && job.origin == .shareExtension && !job.pickedUp && !job.wantsTrim)
        #expect(job.stage == .rendering(job: renderJob) && job.sessionID == sid)
        #expect(job.link == URL(string: shortLink) && job.trim == s.pipeline.trim)
        #expect(s.notifier.posts.map(\.kind) == [.stillMaking] && s.notifier.posts.map(\.job) == [job.id])
    }

    @Test func closingAnythingElseJustStops() async throws {
        let h = Harness(.shortClip)
        let s = share(h)
        s.pipeline.start(link: URL(string: shortLink)!)
        await drive(h) { s.pipeline.state == .ready }
        #expect(await s.core.close() == .dismissed)
        #expect(s.counter.completed == 1 && h.ctx.jobs.all().isEmpty && s.notifier.posts.isEmpty)

        let idle = share(h)                                    // nothing started at all (no link in what was shared)
        #expect(await idle.core.close() == .dismissed)
        #expect(idle.counter.completed == 1 && h.ctx.jobs.all().isEmpty)
    }

    @Test func trimInCobaltOpensTheAppAndAsksForNothingWhenItWorked() async throws {
        let h = Harness(.happy)
        let s = share(h)
        s.pipeline.start(link: URL(string: pastedLink)!)
        await drive(h) { s.pipeline.state == .ready }
        #expect(s.core.isLong && s.pipeline.trim == TrimRange(start: 0, end: 10))

        await s.core.handOffToApp()
        #expect(s.counter.opened == [URL(string: "cobalt-apple://job/\(s.core.jobID.uuidString)")!])
        #expect(s.notifier.posts.isEmpty && s.counter.completed == 1)
        #expect(s.notifier.authorizationRequests == 0, "the app opened: no notification, no permission prompt")
        let job = try #require(h.ctx.jobs.nextHandoff(now: h.clock.now()))
        #expect(job.stage == .ready && job.wantsTrim && job.sessionID == s.pipeline.sessionID)
        #expect(job.media?.duration == 14.77 && job.trim == TrimRange(start: 0, end: 10))
    }

    @Test func trimInCobaltNotifiesWhenTheSystemWillNotOpenTheApp() async throws {
        let h = Harness(.happy)
        let refused = share(h, openApp: { _ in false })
        refused.pipeline.start(link: URL(string: pastedLink)!)
        await drive(h) { refused.pipeline.state == .ready }
        await refused.core.handOffToApp()
        #expect(refused.notifier.posts.map(\.kind) == [.trimInCobalt] && refused.notifier.posts.map(\.job) == [refused.core.jobID])
        #expect(refused.notifier.authorizationRequests == 1, "permission is asked before the fallback notification is posted")
        #expect(h.ctx.jobs.nextHandoff(now: h.clock.now())?.id == refused.core.jobID)               // the app still takes it on its next foreground
        #expect(refused.counter.completed == 1)

        let h2 = Harness(.happy)
        let noOpener = share(h2)
        noOpener.core.openApp = nil
        noOpener.pipeline.start(link: URL(string: pastedLink)!)
        await drive(h2) { noOpener.pipeline.state == .ready }
        await noOpener.core.handOffToApp()
        #expect(noOpener.notifier.posts.map(\.kind) == [.trimInCobalt])
    }

    @Test func handingOffBeforeTheSessionExistsDoesNothingButFinish() async throws {
        let h = Harness(.happy)
        let s = share(h)
        await s.core.handOffToApp()
        #expect(s.counter.completed == 1 && h.ctx.jobs.all().isEmpty && s.notifier.posts.isEmpty && s.counter.opened.isEmpty)
    }

    @Test func theAppTakesTheHandoffOnItsNextForegroundOnTheTrim() async throws {
        let h = Harness(.happy)
        let s = share(h)
        s.pipeline.start(link: URL(string: pastedLink)!)
        await drive(h) { s.pipeline.state == .ready }
        await s.core.handOffToApp()

        // the app comes to the front
        h.app.selectedTab = .library
        let app = Task { @MainActor in await h.app.pickUpSharedJobs() }
        await app.value
        #expect(h.app.selectedTab == .save)
        await h.driveToSettled()
        #expect(h.pipeline.state == .ready && h.pipeline.trim == TrimRange(start: 0, end: 10))
        #expect(h.pipeline.sessionID == s.pipeline.sessionID && h.pipeline.media?.duration == 14.77)
        // the handoff is spent: gone from the store once the app has it
        #expect(h.ctx.jobs.all().isEmpty)
    }

    @Test func aRenderLeftRunningInTheSheetFinishesInTheApp() async throws {
        let h = Harness(.shortClip)
        let s = share(h)
        s.pipeline.start(link: URL(string: shortLink)!)
        await drive(h) { s.pipeline.state == .ready }
        s.pipeline.makeWebp()
        await drive(h) { s.pipeline.renderJobID != nil }
        _ = await s.core.close()

        let app = Task { @MainActor in await h.app.pickUpSharedJobs() }
        await app.value
        guard case .rendering = h.pipeline.state else { Issue.record("expected .rendering, got \(h.pipeline.state)"); return }
        await h.driveToSettled()
        guard case .done(let result) = h.pipeline.state else { Issue.record("expected .done, got \(h.pipeline.state)"); return }
        #expect(Format.bytes(result.bytes) == "841 KB")
        #expect(h.ctx.jobs.all().isEmpty)
        #expect(h.app.store.videos.contains { $0.kind == .webp && $0.sessionID == s.pipeline.sessionID })   // it joined the orbit
    }

    @Test func theSheetKnowsWhetherTheServerHasAStudio() async throws {
        let fork = Harness(.happy)
        let forkCore = ShareCore(context: fork.ctx, pipeline: Pipeline(context: fork.ctx), notifier: FakeNotifier())
        #expect(forkCore.webpAvailable && forkCore.capabilities.kind == .fork)

        let plain = Harness(.plainCobalt)
        let plainCore = ShareCore(context: plain.ctx, pipeline: Pipeline(context: plain.ctx), notifier: FakeNotifier())
        #expect(!plainCore.webpAvailable && plainCore.capabilities.kind == .plainCobalt)

        let legacy = Harness(.legacyFork)
        let legacyCore = ShareCore(context: legacy.ctx, pipeline: Pipeline(context: legacy.ctx), notifier: FakeNotifier())
        #expect(legacyCore.webpAvailable)                                           // old forks still have a studio

        // a context that does not know yet (the extension at launch) learns when the pipeline asks
        let h = Harness(.happy)
        h.ctx.capabilities = .unknown
        let core = ShareCore(context: h.ctx, pipeline: Pipeline(context: h.ctx), notifier: FakeNotifier())
        #expect(!core.webpAvailable && core.capabilities.kind == .unreachable)
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking { _ = core.capabilities } onChange: { flag.fired = true }
        let fresh = await h.ctx.refreshCapabilities()
        #expect(fresh.kind == .fork && core.webpAvailable && flag.fired)
        #expect(h.app.capabilities.kind == .fork)                                    // the app model heard it too
    }

    @Test func notificationsCarryTheJobLinkTheAppOpens() {
        let id = UUID()
        let still = Notifications.request(.stillMaking, jobID: id)
        #expect(still.content.title == "cobalt is still making your webp")
        #expect(still.content.userInfo["url"] as? String == "cobalt-apple://job/\(id.uuidString)")
        #expect(still.trigger == nil && still.identifier == "job-\(id.uuidString)-stillMaking")
        let trim = Notifications.request(.trimInCobalt, jobID: id)
        #expect(trim.content.title == "your clip is saved · tap to trim in cobalt")
        #expect(trim.identifier != still.identifier)
        // what the app delegate hands to `AppModel.open`
        #expect(URL(string: Notifications.url(forJob: id))?.scheme == "cobalt-apple")
    }
}

// MARK: - A file the extension already copied

@MainActor
@Suite(.serialized)
struct InboxFileTests {
    @Test func aFileAlreadyInTheInboxIsNotCopiedAgain() async throws {
        let h = Harness(.happy)
        let inside = h.ctx.store.inboxURL(for: "IMG_0412.mov")                       // where ShareInbox put it
        try Data(repeating: 1, count: 2_000).write(to: inside)
        h.pipeline.start(file: inside)
        await h.driveToSettled()
        #expect(h.pipeline.state == .ready)
        #expect(h.pipeline.localFile?.resolvingSymlinksInPath() == inside.resolvingSymlinksInPath())

        let h2 = Harness(.happy)
        let outside = try makeTempFile("IMG_0413.mov")                               // a file the owner picked
        h2.pipeline.start(file: outside)
        await h2.driveToSettled()
        #expect(h2.pipeline.state == .ready)
        #expect(h2.pipeline.localFile?.resolvingSymlinksInPath() != outside.resolvingSymlinksInPath())   // copied into the inbox
        #expect(h2.pipeline.localFile?.path.hasPrefix(h2.ctx.store.root.appendingPathComponent("inbox").resolvingSymlinksInPath().path) == true)
    }
}

// MARK: - The app following its own work across a relaunch

@MainActor
@Suite(.serialized)
struct AppRelaunchTests {
    private func appJobs(_ h: Harness) -> [SharedJob] { h.ctx.jobs.all().filter { $0.origin == .app } }

    @Test func aRunKeepsItsRecordWhileTheServerWorksAndDropsItWhenSettled() async throws {
        let h = Harness(.shortClip)
        h.ctx.recordsJobs = true
        h.pipeline.start(link: URL(string: shortLink)!)
        #expect(appJobs(h).isEmpty)                                                  // no session yet, nothing to follow

        await h.drive { h.pipeline.sessionID != nil }
        let saving = try #require(appJobs(h).first)
        #expect(saving.stage == .saving && saving.sessionID == h.pipeline.sessionID && !saving.pickedUp)
        #expect(saving.link == URL(string: shortLink))

        await h.driveToSettled()
        #expect(h.pipeline.state == .ready && appJobs(h).isEmpty)                    // ready: nothing left in flight

        h.pipeline.makeWebp()
        await h.drive { h.pipeline.renderJobID != nil }
        let rendering = try #require(appJobs(h).first)
        #expect(rendering.stage == .rendering(job: try #require(h.pipeline.renderJobID)))
        #expect(rendering.trim == h.pipeline.trim)

        await h.driveToSettled()
        guard case .done = h.pipeline.state else { Issue.record("expected .done, got \(h.pipeline.state)"); return }
        #expect(appJobs(h).isEmpty)
    }

    @Test func resetForgetsTheRun() async throws {
        let h = Harness(.shortClip)
        h.ctx.recordsJobs = true
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { h.pipeline.sessionID != nil }
        #expect(appJobs(h).count == 1)
        h.pipeline.reset()
        #expect(appJobs(h).isEmpty && h.pipeline.state == .idle)
    }

    @Test func extensionsAndPreviewsNeverRecord() async throws {
        let h = Harness(.shortClip)                                                  // recordsJobs defaults to false
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.driveToSettled()
        #expect(h.ctx.jobs.all().isEmpty)
    }

    @Test func aRelaunchedAppFollowsTheRenderItLeftOnTheServer() async throws {
        let h = Harness(.shortClip)
        h.ctx.recordsJobs = true
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.driveToSettled()
        h.pipeline.makeWebp()
        await h.drive { h.pipeline.renderJobID != nil }
        let record = try #require(appJobs(h).first)

        // the process dies: the home pipeline is gone, the record is what is left on disk
        h.pipeline.reset()
        h.ctx.jobs.upsert(record)
        #expect(h.pipeline.state == .idle)

        let relaunch = Task { @MainActor in await h.app.pickUpSharedJobs() }
        await relaunch.value
        guard case .rendering = h.pipeline.state else { Issue.record("expected .rendering, got \(h.pipeline.state)"); return }
        #expect(h.app.selectedTab == .save)
        await h.driveToSettled()
        guard case .done(let result) = h.pipeline.state else { Issue.record("expected .done, got \(h.pipeline.state)"); return }
        #expect(Format.bytes(result.bytes) == "841 KB")
        #expect(appJobs(h).isEmpty)
    }

    @Test func aRelaunchedAppFollowsASaveAndLandsOnTheTrim() async throws {
        let h = Harness(.happy)
        h.ctx.recordsJobs = true
        h.pipeline.start(link: URL(string: pastedLink)!)
        await h.drive { h.pipeline.sessionID != nil }
        let record = try #require(appJobs(h).first)
        #expect(record.stage == .saving)
        h.pipeline.reset()
        h.ctx.jobs.upsert(record)

        let relaunch = Task { @MainActor in await h.app.pickUpSharedJobs() }
        await relaunch.value
        await h.driveToSettled()
        #expect(h.pipeline.state == .ready && h.pipeline.media?.duration == 14.77)
        #expect(appJobs(h).isEmpty)
    }

    @Test func aRunSaysWhereItCameFrom() async throws {
        let h = Harness(.shortClip)
        #expect(h.pipeline.origin == nil && !h.pipeline.resumedFromShare)
        h.pipeline.start(link: URL(string: shortLink)!)
        #expect(h.pipeline.origin == nil)
        h.pipeline.reset()                                                           // home is quiet again

        let handoff = SharedJob(
            id: UUID(), origin: .shareExtension, link: URL(string: shortLink), sessionID: nil, media: nil, trim: nil,
            stage: .failed(code: "error.api.fetch.fail"), wantsTrim: false, pickedUp: false, updatedAt: h.clock.now())
        h.ctx.jobs.upsert(handoff)
        await h.app.pickUpSharedJobs()
        #expect(h.pipeline.origin == .shareExtension && h.pipeline.resumedFromShare)

        h.pipeline.start(link: URL(string: shortLink)!)                              // the owner starts something new
        #expect(h.pipeline.origin == nil && !h.pipeline.resumedFromShare)

        h.pipeline.resume(SharedJob(
            id: UUID(), origin: .app, link: nil, sessionID: nil, media: nil, trim: nil, stage: .failed(code: "x"),
            wantsTrim: false, pickedUp: false, updatedAt: h.clock.now()))
        #expect(h.pipeline.origin == .app && !h.pipeline.resumedFromShare)
        h.pipeline.reset()
        #expect(h.pipeline.origin == nil)
    }

    @Test func staleOrBusyAppsAreLeftAlone() async throws {
        let h = Harness(.shortClip)
        let stale = SharedJob(
            id: UUID(), origin: .app, link: URL(string: shortLink), sessionID: "s", media: nil, trim: nil,
            stage: .rendering(job: "j"), wantsTrim: false, pickedUp: false, updatedAt: h.clock.now().addingTimeInterval(-3_600))
        h.ctx.jobs.upsert(stale)
        await h.app.pickUpSharedJobs()
        #expect(h.pipeline.state == .idle)                                           // an hour old: not followed

        var fresh = stale
        fresh.id = UUID()
        fresh.updatedAt = h.clock.now()
        h.ctx.jobs.upsert(fresh)
        h.pipeline.start(link: URL(string: shortLink)!)                              // the owner is already doing something
        let before = h.pipeline.state
        await h.app.pickUpSharedJobs()
        #expect(h.pipeline.state == before)
        #expect(h.pipeline.input != nil)
    }

    @Test func aShareHandoffBeatsTheAppsOwnLeftovers() async throws {
        let h = Harness(.shortClip)
        let now = h.clock.now()
        let own = SharedJob(
            id: UUID(), origin: .app, link: URL(string: shortLink), sessionID: nil, media: nil, trim: nil,
            stage: .failed(code: "own"), wantsTrim: false, pickedUp: false, updatedAt: now)
        let handoff = SharedJob(
            id: UUID(), origin: .shareExtension, link: URL(string: shortLink), sessionID: nil, media: nil, trim: nil,
            stage: .failed(code: "error.api.fetch.fail"), wantsTrim: false, pickedUp: false, updatedAt: now.addingTimeInterval(-5))
        h.ctx.jobs.upsert(own)
        h.ctx.jobs.upsert(handoff)
        await h.app.pickUpSharedJobs()
        #expect(h.pipeline.state == .failed(.fetchFailed(code: "error.api.fetch.fail")))
    }
}

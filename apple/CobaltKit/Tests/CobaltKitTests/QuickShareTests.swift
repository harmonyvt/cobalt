import Foundation
import Testing
@testable import CobaltKit

// The quick share card (CONTRACT-SHARE-QUICK.md section 3) and the run links (section 4).

@MainActor
@Suite(.serialized)
struct QuickShareTests {
    final class Counter: @unchecked Sendable {
        var completed = 0
        var opened: [URL] = []
    }

    private struct Card {
        let pipeline: Pipeline
        let core: ShareCore
        let counter: Counter
        let notifier: FakeNotifier
    }

    private func card(_ h: Harness, quick: Bool = true, autoContinue: Bool = true) -> Card {
        h.ctx.settings.autoContinue = autoContinue
        let pipeline = Pipeline(context: h.ctx)
        let notifier = FakeNotifier()
        let counter = Counter()
        let core = ShareCore(context: h.ctx, pipeline: pipeline, notifier: notifier, quick: quick)
        core.complete = { counter.completed += 1 }
        core.openApp = { url in counter.opened.append(url); return true }
        return Card(pipeline: pipeline, core: core, counter: counter, notifier: notifier)
    }

    private func isExpanded(_ q: QuickShare, _ why: QuickExpand) -> Bool { q == .expanded(why) }

    @Test func theSettingDefaultsToTheCardAndRoundTrips() {
        let suite = "cobalt.quick.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let s = Settings(defaults: defaults, keychain: .memory())
        #expect(s.shareFullSheet == false, "the quick card is the default")
        s.shareFullSheet = true
        #expect(Settings(defaults: defaults, keychain: .memory()).shareFullSheet == true, "the extension reads the app's choice")
    }

    @Test func aFullSheetBuildKeepsTheCountdownAndNeverTheCard() async {
        let h = Harness(.coldStart)
        let c = card(h, quick: false)
        #expect(c.core.quick == .off)
        #expect(c.core.autoContinue == .armed)
    }

    @Test func theCardHandsOffAsSoonAsTheServerHoldsTheSaveThenCloses() async throws {
        let h = Harness(.coldStart)                       // a save that takes ~5 s
        let c = card(h)
        #expect(c.core.quick == .working)
        #expect(c.core.autoContinue == .off, "no countdown on top of the card")
        c.pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { c.core.quick == .holding })
        #expect(c.core.quick == .holding)
        #expect(c.core.canContinueInBackground, "it holds only once the server has the save")
        let held = h.clock.now()
        #expect(c.counter.completed == 0, "the check shows first")
        await h.drive(until: { c.counter.completed == 1 })
        #expect(c.counter.completed == 1)
        let waited = h.clock.now().timeIntervalSince(held)
        #expect(waited >= ShareCore.quickHold - 0.001 && waited < ShareCore.quickHold + 0.5)
        #expect(h.clock.now().timeIntervalSince(c.core.openedAt) < 5, "closed long before the save finished")
        let job = try #require(h.ctx.jobs.all().first)
        #expect(job.id == c.core.jobID && job.stage == .saving && job.origin == .shareExtension && job.sessionID != nil)
        // exactly once
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 30)
        #expect(c.counter.completed == 1)
    }

    @Test func expandingKeepsTheRunAndNeverCloses() async throws {
        let h = Harness(.coldStart)
        let c = card(h)
        c.pipeline.start(link: URL(string: shortLink)!)
        c.core.expandQuick(.asked)
        #expect(c.core.quick == .expanded(.asked))
        await h.drive(until: { c.pipeline.state == .ready })
        #expect(c.pipeline.state == .ready, "the run carried on in the full sheet")
        #expect(c.counter.completed == 0)
        #expect(c.core.autoContinue == .off, "the owner chose to look: no countdown")
    }

    @Test func expandingDuringTheCheckCancelsTheHandOff() async throws {
        let h = Harness(.coldStart)
        let c = card(h)
        c.pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { c.core.quick == .holding })
        c.core.expandQuick(.asked)
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 3)
        #expect(c.counter.completed == 0)
        #expect(c.core.quick == .expanded(.asked))
    }

    @Test func aFailureKeepsTheCardWithTheReasonAndRetryRunsTheLinkAgain() async throws {
        let h = Harness(.privatePost)
        let c = card(h)
        c.pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { if case .failed = c.core.quick { true } else { false } })
        guard case .failed(let f) = c.core.quick else { Issue.record("not failed: \(c.core.quick)"); return }
        #expect(c.pipeline.state == .failed(f))
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 10)
        #expect(c.counter.completed == 0, "the card stays")
        c.core.retryQuick()
        #expect(c.core.quick == .working)
        await h.drive(until: { if case .failed = c.core.quick { true } else { false } })
        #expect(c.core.quick == .failed(f), "the same answer again, still on the card")
    }

    @Test func openCobaltOpensTheAppAndCloses() async throws {
        let h = Harness(.privatePost)
        let c = card(h)
        c.pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { if case .failed = c.core.quick { true } else { false } })
        await c.core.openCobalt()
        #expect(c.counter.opened == [URL(string: "cobalt-apple://open")!])
        #expect(c.counter.completed == 1)
    }

    @Test func runsTheCardCannotFinishBecomeTheFullSheet() async throws {
        // plain cobalt: the extension downloads the file itself
        let plain = Harness(.plainCobalt)
        let a = card(plain)
        a.pipeline.start(link: URL(string: shortLink)!)
        await plain.drive(until: { a.core.quick != .working })
        #expect(isExpanded(a.core.quick, .needsSheet))

        // a server that would lose an unpolled save
        let old = Harness(.coldStart)
        old.ctx.capabilities.finishesUnpolled = false
        let b = card(old)
        b.pipeline.start(link: URL(string: shortLink)!)
        await old.drive(until: { b.core.quick != .working })
        #expect(isExpanded(b.core.quick, .needsSheet))

        // a picker post: a choice only the sheet has controls for
        let picker = Harness(.picker)
        let d = card(picker)
        d.pipeline.start(link: URL(string: shortLink)!)
        await picker.drive(until: { d.core.quick != .working })
        #expect(isExpanded(d.core.quick, .needsSheet))

        // a file: its upload runs inside the extension
        let file = Harness(.happy)
        let e = card(file)
        let inside = file.ctx.store.inboxURL(for: "IMG_0412.mov")
        try Data(repeating: 1, count: 2_000).write(to: inside)
        e.pipeline.start(file: inside)
        await file.drive(until: { e.core.quick != .working })
        #expect(isExpanded(e.core.quick, .needsSheet))
        for c in [a, b, d, e] { #expect(c.counter.completed == 0) }
    }

    @Test func aSaveThatFinishedFirstIsLeftForTheAppAndToldLocally() async throws {
        let h = Harness(.coldStart)
        let c = card(h)
        c.core.previewQuick(.off)                         // let the run reach ready without the card acting
        c.pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { c.pipeline.state == .ready })
        let sid = try #require(c.pipeline.sessionID)
        c.core.previewQuick(.working)
        c.core.quickPinned = false                        // back to the real logic, now at ready
        c.core.evaluateQuick()
        #expect(c.core.quick == .holding)
        await h.drive(until: { c.counter.completed == 1 })
        let job = try #require(h.ctx.jobs.all().first)
        #expect(job.stage == .saving && job.sessionID == sid, "the app's poll answers at once")
        #expect(c.notifier.posts.map(\.kind) == [.saved])
    }

    @Test func closingTheCardWhileTheServerHoldsTheSaveHandsItOff() async throws {
        let h = Harness(.coldStart)
        h.ctx.capabilities.notifyBridge = true
        let c = card(h)
        c.pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { c.core.quick == .holding })
        let outcome = await c.core.close()
        #expect(outcome == .continuesInBackground)
        #expect(c.counter.completed == 1)
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 3)
        #expect(c.counter.completed == 1, "the card's own hand-off does not fire after a close")
    }

    @Test func theOverlayHandsOffWhenItsMorphEndsNotBefore() async throws {
        let h = Harness(.coldStart)
        let c = card(h)
        c.core.quickHoldSeconds = 4                       // the overlay's ceiling
        c.pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { c.core.quick == .holding })
        let held = h.clock.now()
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 1.5)
        #expect(c.counter.completed == 0, "still morphing")
        await c.core.finishHoldNow()
        #expect(c.counter.completed == 1)
        #expect(h.clock.now().timeIntervalSince(held) < 4)
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 6)
        #expect(c.counter.completed == 1, "the ceiling timer does not fire a second hand-off")
        await c.core.finishHoldNow()
        #expect(c.counter.completed == 1)
    }

    @Test func aPinnedPreviewNeverHandsOff() async throws {
        let h = Harness(.coldStart)
        let c = card(h)
        c.core.previewQuick(.working)
        c.pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { c.pipeline.state == .ready })
        #expect(c.core.quick == .working && c.counter.completed == 0)
    }

    @Test func theTitleNamesTheLink() {
        let h = Harness(.coldStart)
        let c = card(h)
        #expect(c.core.quickTitle == nil)
        c.pipeline.start(link: URL(string: shortLink)!)
        #expect(c.core.quickTitle == "x · 2105435404002562056")
    }
}

// MARK: - Links

struct QuickLinkTests {
    @Test func notificationLinksCarryTheSessionWhenThereIsOne() {
        let id = UUID()
        #expect(Notifications.url(forJob: id) == "cobalt-apple://job/\(id.uuidString)")
        #expect(Notifications.url(forJob: id, session: "SymmlXTu") == "cobalt-apple://job/\(id.uuidString)?session=SymmlXTu")
        #expect(Notifications.url(forJob: id, session: "SymmlXTu", trim: true) == "cobalt-apple://job/\(id.uuidString)?session=SymmlXTu&trim=1")
        #expect(Notifications.url(for: .stillSaving, jobID: id, session: "abc") == "cobalt-apple://job/\(id.uuidString)?session=abc")
        #expect(Notifications.url(for: .trimInCobalt, jobID: id, session: "abc") == "cobalt-apple://job/\(id.uuidString)?session=abc&trim=1")
        #expect(Notifications.url(for: .saved, jobID: id) == "cobalt-apple://job/\(id.uuidString)", "a saved run opens its run")
        #expect(Notifications.url(for: .webpReady, jobID: id) == "cobalt-apple://library")
    }

    @Test func runLinksParse() throws {
        let id = UUID()
        let a = try #require(RunLink(URL(string: "cobalt-apple://job/\(id.uuidString)")!))
        #expect(a.run == id && a.session == nil && !a.trim)
        let b = try #require(RunLink(URL(string: "cobalt-apple://job/\(id.uuidString.lowercased())?session=SymmlXTu&trim=1")!))
        #expect(b.run == id && b.session == "SymmlXTu" && b.trim)
        let c = try #require(RunLink(URL(string: "cobalt-apple://session/SymmlXTu")!))
        #expect(c.run == nil && c.session == "SymmlXTu")
        #expect(RunLink(URL(string: "cobalt-apple://open")!) == nil)
        #expect(RunLink(URL(string: "cobalt-apple://library")!) == nil)
        #expect(RunLink(URL(string: "https://job/\(id.uuidString)")!) == nil)
        #expect(RunLink(URL(string: "cobalt-apple://job/not-a-uuid")!) == nil)
        #expect(RunLink(URL(string: "cobalt-apple://session/a%20b")!) == nil, "a session is a plain token")
        let d = try #require(RunLink(URL(string: "cobalt-apple://job/\(id.uuidString)?session=../../x")!))
        #expect(d.session == nil, "a junk session is dropped, the run stays")
    }
}

@MainActor
@Suite(.serialized)
struct RunLinkOpenTests {
    private func shareJob(_ h: Harness, session: String?, stage: SharedJob.Stage = .saving) -> SharedJob {
        SharedJob(
            id: UUID(), origin: .shareExtension, link: URL(string: shortLink), sessionID: session, media: nil, trim: nil,
            stage: stage, wantsTrim: false, pickedUp: false, updatedAt: h.clock.now())
    }

    @Test func aJobTheAppHasIsTakenAsBefore() async throws {
        let h = Harness(.coldStart)
        let created = try await h.ctx.client.createStudio(link: URL(string: shortLink)!)
        let job = shareJob(h, session: created.id)
        h.ctx.jobs.upsert(job)
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://job/\(job.id.uuidString)")!))
        #expect(h.pipeline.liveRunID == job.id && h.pipeline.sessionID == created.id)
        #expect(h.ctx.jobs.all().first?.pickedUp == true)
    }

    @Test func aSessionAloneIsFollowedWhenTheAppHasNoRecord() async throws {
        // a build re-signed without the app group: the extension's job record is not here
        let h = Harness(.coldStart)
        let created = try await h.ctx.client.createStudio(link: URL(string: shortLink)!)
        let run = UUID()
        #expect(h.ctx.jobs.all().isEmpty)
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://job/\(run.uuidString)?session=\(created.id)")!))
        #expect(h.pipeline.liveRunID == run && h.pipeline.sessionID == created.id)
        #expect(h.pipeline.origin == .shareExtension)
        await h.drive(until: { h.pipeline.state == .ready })
        #expect(h.pipeline.state == .ready, "the save is followed to the clip")
    }

    @Test func aHarkSessionLinkFindsTheJobBySession() async throws {
        let h = Harness(.coldStart)
        let created = try await h.ctx.client.createStudio(link: URL(string: shortLink)!)
        let job = shareJob(h, session: created.id)
        h.ctx.jobs.upsert(job)
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://session/\(created.id)")!))
        #expect(h.pipeline.liveRunID == job.id)
    }

    @Test func theRunOnScreenIsLeftAlone() async throws {
        let h = Harness(.coldStart)
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { h.pipeline.sessionID != nil })
        let run = h.pipeline.liveRunID
        let state = h.pipeline.state
        h.app.selectedTab = .library
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://job/\(run.uuidString)")!))
        #expect(h.app.selectedTab == .save)
        #expect(h.pipeline.liveRunID == run && h.pipeline.state == state, "nothing restarted")
    }

    @Test func aBusyHomeScreenIsNeverPushedAside() async throws {
        let h = Harness(.coldStart)
        h.pipeline.start(link: URL(string: shortLink)!)
        await h.drive(until: { h.pipeline.sessionID != nil })
        let run = h.pipeline.liveRunID
        #expect(h.app.openRunLink(URL(string: "cobalt-apple://session/SomeOtherSid")!))
        #expect(h.pipeline.liveRunID == run, "a link never cancels what the owner is waiting on")
    }

    @Test func otherLinksAreNotRunLinks() {
        let h = Harness(.coldStart)
        #expect(!h.app.openRunLink(URL(string: "cobalt-apple://open")!))
        #expect(!h.app.openRunLink(URL(string: "cobalt-apple://library")!))
    }
}

// MARK: - The activity of a share-sheet run the app took over

@MainActor
@Suite(.serialized)
struct QuickLiveOriginTests {
    @Test func aTakenOverShareRunKeepsTheShareOriginSoItsTapOpensTheRun() async throws {
        let rig = LiveRig(.coldStart)
        let created = try await rig.h.ctx.client.createStudio(link: URL(string: shortLink)!)
        let job = SharedJob(
            id: UUID(), origin: .shareExtension, link: URL(string: shortLink), sessionID: created.id, media: nil, trim: nil,
            stage: .saving, wantsTrim: false, pickedUp: false, updatedAt: rig.h.clock.now())
        rig.h.ctx.jobs.upsert(job)
        await rig.h.app.pickUpSharedJobs()                // the app comes to the foreground
        await rig.settle()
        let request = try #require(rig.adapter.requests.first, "the app starts the activity at once")
        #expect(request.attributes.run == job.id.uuidString.lowercased())
        #expect(request.attributes.origin == "share")
        #expect(request.state.stage == .saving)
    }

    @Test func theAppsOwnRunsStayAppOrigin() async throws {
        let rig = LiveRig(.coldStart)
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.drive { rig.pipeline.sessionID != nil }
        #expect(rig.adapter.requests.first?.attributes.origin == "app")
    }
}

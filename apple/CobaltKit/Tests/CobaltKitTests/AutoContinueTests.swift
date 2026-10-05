import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// The share sheet's countdown and the new settings keys (CONTRACT-SYNC.md decisions 1 to 5, section 4).

@MainActor
struct SyncSettingsTests {
    private func settings() -> Settings {
        let suite = "cobalt.sync.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Settings(defaults: defaults, keychain: .memory())
    }

    @Test func defaultsAreOnFiveSecondsAndAlbumOn() {
        let s = settings()
        #expect(s.autoContinue == true)
        #expect(s.autoContinueSeconds == 5)
        #expect(s.photosAlbumSync == true, "automatic is the owner's expectation (2026-10-05)")
        #expect(s.photosSyncWebps == true)
        #expect(Settings.autoContinueChoices == [3, 5, 10])
    }

    @Test func valuesRoundTripThroughTheDefaults() {
        let s = settings()
        s.autoContinue = false
        s.autoContinueSeconds = 10
        s.photosAlbumSync = true
        s.photosSyncWebps = true
        #expect(s.autoContinue == false && s.autoContinueSeconds == 10)
        #expect(s.photosAlbumSync == true && s.photosSyncWebps == true)
        // another Settings over the same defaults (the share extension) reads the same
        let other = Settings(defaults: s.defaults, keychain: .memory())
        #expect(other.autoContinue == false && other.autoContinueSeconds == 10 && other.photosAlbumSync && other.photosSyncWebps)
    }

    @Test func junkWaitReadsAsFive() {
        let s = settings()
        for junk in [0, 1, 4, 7, 99, -3] {
            s.defaults.set(junk, forKey: "autoContinueSeconds")
            #expect(s.autoContinueSeconds == 5, "\(junk)")
        }
        for ok in [3, 5, 10] {
            s.autoContinueSeconds = ok
            #expect(s.autoContinueSeconds == ok)
        }
    }

    @Test func sourceWaitComesFromTheFeatureFlag() {
        func caps(_ features: String) -> Capabilities? {
            HTTPCobaltClient.parseForkCapabilities(Data(#"{"server":"cobalt-cloudflare","features":{\#(features)}}"#.utf8))
        }
        #expect(caps(#""studio":true,"source_wait":true"#)?.sourceWait == true)
        #expect(caps(#""studio":true"#)?.sourceWait == false, "absent means false")
        #expect(Capabilities.unknown.sourceWait == false)
    }
}

@MainActor
@Suite(.serialized)
struct AutoContinueTests {
    final class Counter: @unchecked Sendable { var completed = 0 }

    private struct Sheet {
        let pipeline: Pipeline
        let core: ShareCore
        let counter: Counter
        let notifier: FakeNotifier
    }

    private func sheet(_ h: Harness, wait: Int = 5, on: Bool = true, assistive: Bool = false) -> Sheet {
        h.ctx.settings.autoContinue = on
        h.ctx.settings.autoContinueSeconds = wait
        let pipeline = Pipeline(context: h.ctx)
        let notifier = FakeNotifier()
        let counter = Counter()
        let core = ShareCore(context: h.ctx, pipeline: pipeline, notifier: notifier, assistiveRunning: assistive)
        core.complete = { counter.completed += 1 }
        return Sheet(pipeline: pipeline, core: core, counter: counter, notifier: notifier)
    }

    private func isCounting(_ c: AutoContinue) -> Bool { if case .counting = c { return true } else { return false } }
    private func secondsOf(_ c: AutoContinue) -> Int? { if case .counting(_, let s) = c { return s } else { return nil } }

    @Test func armedUntilTheServerHoldsTheSaveThenCounts() async throws {
        let h = Harness(.coldStart)
        let s = sheet(h)
        #expect(s.core.autoContinue == .armed)
        await h.settle()
        #expect(s.core.autoContinue == .armed, "nothing to continue before a run exists")
        s.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { self.isCounting(s.core.autoContinue) }
        #expect(isCounting(s.core.autoContinue))
        #expect(s.pipeline.sessionID != nil && s.core.canContinueInBackground)
        guard case .counting(let endsAt, let seconds) = s.core.autoContinue else { return }
        #expect(seconds == 5)
        #expect(abs(endsAt.timeIntervalSince(h.clock.now()) - 5) < 1.0)
    }

    @Test func aServerThatDoesNotFinishUnpolledNeverGetsACountdown() async throws {
        let h = Harness(.coldStart)
        h.ctx.capabilities.finishesUnpolled = false
        let s = sheet(h)
        s.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { s.core.autoContinue != .armed }
        #expect(s.core.autoContinue == .off)
    }

    @Test func firesOnceAtTheWaitAndContinuesInTheBackground() async throws {
        let h = Harness(.coldStart)            // a save that takes 5.1 s: still going when 3 s are up
        let s = sheet(h, wait: 3)
        s.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { self.isCounting(s.core.autoContinue) }
        guard case .counting(let endsAt, _) = s.core.autoContinue else { Issue.record("not counting"); return }
        let counted = h.clock.now()
        await h.drive { s.core.autoContinue == .fired }
        #expect(s.core.autoContinue == .fired)
        #expect(h.clock.now() >= endsAt && h.clock.now().timeIntervalSince(counted) < 4)
        #expect(s.counter.completed == 1)
        let job = try #require(h.ctx.jobs.all().first)
        #expect(job.id == s.core.jobID && job.stage == .saving && job.origin == .shareExtension)
        #expect(s.notifier.posts.map(\.kind) == [.stillSaving])
        // exactly once: more time passing does nothing more
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 30)
        #expect(s.counter.completed == 1 && s.core.autoContinue == .fired)
    }

    @Test func stayStopsItForGood() async throws {
        let h = Harness(.coldStart)
        let s = sheet(h, wait: 3)
        s.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { self.isCounting(s.core.autoContinue) }
        s.core.stay()
        #expect(s.core.autoContinue == .stopped(.stay))
        await h.drive(until: { s.pipeline.state == .ready })
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 30)
        #expect(s.counter.completed == 0)
        #expect(s.core.autoContinue == .stopped(.stay), "never restarts in this sheet")
        s.core.noteInteraction()
        #expect(s.core.autoContinue == .stopped(.stay), "the first reason stands")
    }

    @Test func anyOtherControlStopsIt() async throws {
        let h = Harness(.coldStart)
        let s = sheet(h, wait: 3)
        s.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { self.isCounting(s.core.autoContinue) }
        s.core.noteInteraction()
        #expect(s.core.autoContinue == .stopped(.interaction))
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 30)
        #expect(s.counter.completed == 0)
    }

    @Test func theRunFailingStopsIt() async throws {
        let h = Harness(.coldStart)
        let s = sheet(h, wait: 10)
        s.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { self.isCounting(s.core.autoContinue) }
        s.pipeline.fail(.unreachable)
        await h.settle()
        #expect(s.core.autoContinue == .stopped(.failed))
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 30)
        #expect(s.counter.completed == 0)
    }

    @Test func aRunThatFailsBeforeAnySessionStopsTheArmedCountdown() async throws {
        let h = Harness(.privatePost)
        let s = sheet(h)
        s.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { s.core.autoContinue != .armed }
        #expect(s.core.autoContinue == .stopped(.failed))
    }

    @Test func theSaveFinishingDoesNotStopItAndTheEndClosesThroughTheClosePath() async throws {
        let h = Harness(.shortClip)            // ready after ~3 s; the countdown is 10 s
        let s = sheet(h, wait: 10)
        s.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { s.pipeline.state == .ready }
        #expect(s.pipeline.state == .ready)
        #expect(isCounting(s.core.autoContinue), "reaching ready does not stop it (owner decision)")
        #expect(s.counter.completed == 0)
        await h.drive { s.core.autoContinue == .fired }
        #expect(s.core.autoContinue == .fired)
        #expect(s.counter.completed == 1, "the sheet closed")
        #expect(h.ctx.jobs.all().isEmpty, "the close path at ready leaves no job: nothing is left on the server to follow")
        #expect(s.notifier.posts.isEmpty)
    }

    @Test func noCountdownForFilesPlainCobaltPickersOrASettingThatIsOff() async throws {
        // setting off
        let off = Harness(.shortClip)
        let a = sheet(off, on: false)
        #expect(a.core.autoContinue == .off)
        a.pipeline.start(link: URL(string: shortLink)!)
        await off.drive { a.pipeline.state == .ready }
        #expect(a.core.autoContinue == .off)

        // a file share: the upload runs inside the extension
        let file = Harness(.shortClip)
        let b = sheet(file)
        b.pipeline.start(file: try makeTempFile("clip.mov", bytes: 5_000))
        await file.drive { b.core.autoContinue != .armed }
        #expect(b.core.autoContinue == .off)

        // plain cobalt: no server session, the extension downloads the file itself
        let plain = Harness(.plainCobalt)
        let c = sheet(plain)
        c.pipeline.start(link: URL(string: shortLink)!)
        await plain.drive { c.core.autoContinue != .armed }
        #expect(c.core.autoContinue == .off)

        // a picker post
        let picker = Harness(.picker)
        let d = sheet(picker)
        d.pipeline.start(link: URL(string: shortLink)!)
        await picker.drive { d.core.autoContinue != .armed }
        #expect(d.core.autoContinue == .off)
        await picker.drive(until: { false }, maxVirtualSeconds: picker.clock.elapsed + 30)
        #expect(d.counter.completed == 0)
    }

    @Test func voiceOverAndSwitchControlGetAtLeastTenSeconds() async throws {
        let h = Harness(.coldStart)
        let s = sheet(h, wait: 3, assistive: true)
        s.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { self.isCounting(s.core.autoContinue) }
        #expect(secondsOf(s.core.autoContinue) == 10)

        let h2 = Harness(.coldStart)
        let t = sheet(h2, wait: 3, assistive: false)
        t.pipeline.start(link: URL(string: shortLink)!)
        await h2.drive { self.isCounting(t.core.autoContinue) }
        #expect(secondsOf(t.core.autoContinue) == 3)

        // the floor never shortens a longer wait
        let h3 = Harness(.coldStart)
        let u = sheet(h3, wait: 10, assistive: true)
        u.pipeline.start(link: URL(string: shortLink)!)
        await h3.drive { self.isCounting(u.core.autoContinue) }
        #expect(secondsOf(u.core.autoContinue) == 10)
    }

    @Test func closingTheSheetYourselfMeansNothingFiresAfterwards() async throws {
        let h = Harness(.coldStart)
        let s = sheet(h, wait: 3)
        s.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { self.isCounting(s.core.autoContinue) }
        _ = await s.core.close()
        #expect(s.counter.completed == 1)
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 30)
        #expect(s.counter.completed == 1, "the countdown did not close it a second time")
        #expect(s.core.autoContinue != .fired)
    }

    @Test func aPreviewCanPinTheState() async throws {
        let h = Harness(.coldStart)
        let s = sheet(h, wait: 3)
        s.pipeline.start(link: URL(string: shortLink)!)
        await h.drive { self.isCounting(s.core.autoContinue) }
        let pinned = AutoContinue.counting(endsAt: h.clock.now().addingTimeInterval(5), seconds: 5)
        s.core.previewAutoContinue(pinned)
        await h.drive(until: { false }, maxVirtualSeconds: h.clock.elapsed + 30)
        #expect(s.core.autoContinue == pinned && s.counter.completed == 0)
    }
}

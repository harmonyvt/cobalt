import Foundation
import Testing
@testable import SyncGlowKit

@Suite("glow state")
struct SyncGlowResolveTests {
    @Test func aQuietReachableLibraryIsUpToDate() {
        #expect(SyncGlowResolve.state(SyncGlowFacts()) == .upToDate)
    }

    @Test func theFlagOrAMissingRouteTurnsTheGlowOff() {
        #expect(SyncGlowResolve.state(SyncGlowFacts(engineEnabled: false)) == .off)
        #expect(SyncGlowResolve.state(SyncGlowFacts(routeActive: false, passRunning: true, pendingCount: 4)) == .off)
    }

    @Test func aPassOrAWaitingEditIsSyncingWhileThePathIsUp() {
        #expect(SyncGlowResolve.state(SyncGlowFacts(passRunning: true)) == .syncing)
        #expect(SyncGlowResolve.state(SyncGlowFacts(pendingCount: 1)) == .syncing)
    }

    @Test func offlineWinsOverAPassAndKeepsThePendingCountForTheDashes() {
        let facts = SyncGlowFacts(reachable: false, passRunning: true, pendingCount: 2)
        #expect(SyncGlowResolve.state(facts) == .offlinePending)
    }

    @Test func offlineWithNothingWaitingIsStillTheDimState() {
        #expect(SyncGlowResolve.state(SyncGlowFacts(reachable: false)) == .offlinePending)
    }

    @Test func aRefusalARepullAndANudgeCoverTheSteadyStateUntilTickClearsThem() {
        #expect(SyncGlowResolve.state(SyncGlowFacts(passRunning: true, transient: .refused, transientAge: 5)) == .refused)
        #expect(SyncGlowResolve.state(SyncGlowFacts(transient: .nudge, transientAge: 5)) == .nudge)
        #expect(SyncGlowResolve.state(SyncGlowFacts(passRunning: false, transient: .repull, transientAge: 5)) == .repull)
        #expect(SyncGlowResolve.state(SyncGlowFacts(passRunning: true, pendingCount: 2)) == .syncing)
    }
}

@Suite("glow status")
@MainActor
struct SyncGlowStatusTests {
    @Test func aPassThenQuietReturnsToUpToDate() {
        let clock = GlowClock()
        let status = SyncGlowStatus(clock: { clock.now })
        status.passBegan()
        #expect(status.state == .syncing)
        #expect(status.lastEvent == .passBegan)
        status.passEnded(pending: 0)
        #expect(status.state == .upToDate)
        #expect(status.lastEvent == .caughtUp)
        #expect(status.pendingCount == 0)
    }

    @Test func anUnsentEditWhileOfflineIsACountedDash() {
        let status = SyncGlowStatus(clock: { Date(timeIntervalSince1970: 50) })
        status.reachability(false, pending: 4)
        #expect(status.state == .offlinePending)
        #expect(status.pendingCount == 4)
        #expect(status.lastEvent == .wentOffline)
    }

    @Test func aRefusalFlickersThenFallsBackToWhateverThePathIs() {
        let clock = GlowClock()
        let status = SyncGlowStatus(clock: { clock.now })
        status.reachability(false, pending: 2)
        status.refused(pending: 1)
        #expect(status.state == .refused)
        #expect(status.lastEvent == .refused)
        #expect(status.pendingCount == 1)
        clock.advance(0.4)
        status.tick()
        #expect(status.state == .refused)
        clock.advance(1)
        status.tick()
        #expect(status.state == .offlinePending)
        #expect(status.lastEvent == .wentOffline)
    }

    @Test func aRepullHoldsWhileTheRestartIsRunningAndFinishesItsRedrawAfter() {
        let clock = GlowClock()
        let status = SyncGlowStatus(clock: { clock.now })
        status.passBegan()
        status.repullBegan()
        #expect(status.state == .repull)
        clock.advance(3)
        status.tick()
        #expect(status.state == .repull)
        status.passEnded(pending: 0)
        // The pass ending does not eat the redraw. The screen's tick does, now that the pass is over.
        #expect(status.state == .repull)
        status.tick()
        #expect(status.state == .upToDate)
    }

    @Test func aFastRepullStillPlaysOutTheRedraw() {
        let clock = GlowClock()
        let status = SyncGlowStatus(clock: { clock.now })
        status.passBegan()
        status.repullBegan()
        clock.advance(0.2)
        status.passEnded(pending: 0)
        #expect(status.state == .repull)
        clock.advance(2.3)
        status.tick()
        #expect(status.state == .upToDate)
        #expect(status.lastEvent == .caughtUp)
    }

    @Test func aNudgeShowsItsPulseWithoutForgettingAPass() {
        let clock = GlowClock()
        let status = SyncGlowStatus(clock: { clock.now })
        status.nudged()
        status.passBegan()
        #expect(status.state == .nudge)
        #expect(status.lastEvent == .nudge)
        clock.advance(1.85)
        status.tick()
        #expect(status.state == .syncing)
    }

    @Test func aSlowCatchUpDoesNotReplaceANudge() {
        let clock = GlowClock()
        let status = SyncGlowStatus(clock: { clock.now })
        status.nudged()
        clock.advance(9)
        status.passBegan()
        status.passEnded(pending: 0)
        #expect(status.lastEvent == .nudge)
        #expect(status.state == .nudge)
        status.tick()
        #expect(status.state == .upToDate)
        #expect(status.lastEvent == .caughtUp)
    }

    @Test func aMissingRouteTurnsTheGlowOffAndDropsAForce() {
        let status = SyncGlowStatus()
        status.passBegan()
        status.debugForce(.syncing, pending: 0)
        #expect(status.state == .syncing)
        status.routeFellBack()
        #expect(status.state == .off)
        #expect(status.lastEvent == .fellBack)
        status.passEnded(pending: 3)
        #expect(status.state == .off)
    }

    @Test func theGlowComesBackWhenAPassAfterAFallbackFindsTheRoute() {
        let status = SyncGlowStatus()
        status.passBegan()
        status.routeFellBack()
        status.passEnded(pending: 0)
        #expect(status.state == .off)
        // The engine was reset for another server and tries again. The band waits for the answer.
        status.passBegan()
        #expect(status.state == .off)
        #expect(status.lastEvent == .fellBack)
        status.passEnded(pending: 0)
        #expect(status.state == .upToDate)
        #expect(status.lastEvent == .caughtUp)
        // From here it is an ordinary band again: offline and waiting edits show.
        status.reachability(false, pending: 2)
        #expect(status.state == .offlinePending)
        #expect(status.pendingCount == 2)
    }

    @Test func aSecondMissingRouteLeavesTheGlowOff() {
        let status = SyncGlowStatus()
        status.passBegan()
        status.routeFellBack()
        status.passEnded(pending: 0)
        status.passBegan()
        status.routeFellBack()
        status.passEnded(pending: 4)
        #expect(status.state == .off)
        #expect(status.lastEvent == .fellBack)
    }

    @Test func aDebugForcePinsTheAgeAndIgnoresTheEngineUntilItIsCleared() {
        let clock = GlowClock()
        let status = SyncGlowStatus(clock: { clock.now })
        status.debugForce(.refused, pending: 2)
        #expect(status.state == .refused)
        #expect(status.pendingCount == 2)
        #expect(status.pinsEventAge)
        #expect(status.eventAge(at: clock.now) == SyncGlowTiming.screenshotAge(.refused))
        status.passBegan()
        status.passEnded(pending: 9)
        #expect(status.state == .refused)
        #expect(status.pendingCount == 2)
        status.debugForce(nil, pending: 0)
        #expect(!status.pinsEventAge)
        // The force was hiding a pass that left nine edits waiting.
        #expect(status.pendingCount == 9)
        #expect(status.state == .syncing)
    }
}

@Suite("glow uniforms and pace")
struct SyncGlowComposerTests {
    @Test func reduceMotionSnapsTheCrossfadeAndFreezesTime() {
        #expect(SyncGlowComposer.transition(elapsed: 0, reduceMotion: false) == 0)
        #expect(SyncGlowComposer.transition(elapsed: 0.425, reduceMotion: false) == 0.5)
        #expect(SyncGlowComposer.transition(elapsed: 2, reduceMotion: false) == 1)
        #expect(SyncGlowComposer.transition(elapsed: 0, reduceMotion: true) == 1)
        let uniforms = SyncGlowComposer.uniforms(
            time: 9, state: .syncing, previous: .upToDate, transition: 0.5,
            pendingCount: 20, reduceMotion: true, lowPower: false, headroom: 0.4,
            eventAge: -3, width: 10, height: 4)
        #expect(uniforms.time == SyncGlowTiming.stillTime)
        #expect(uniforms.transition == 1)
        #expect(uniforms.pending == Float(SyncGlowTiming.visiblePendingCap))
        #expect(uniforms.headroom == 1)
        #expect(uniforms.eventAge == 0)
        #expect(uniforms.reducedMotion == 1)
        #expect(uniforms.state == 1)
        #expect(uniforms.previous == 0)
    }

    @Test func lowPowerDimsTheLevelAndThePackedBlockMatchesTheMetalStruct() {
        let uniforms = SyncGlowComposer.uniforms(
            time: 2, state: .offlinePending, previous: .syncing, transition: 0.25,
            pendingCount: 3, reduceMotion: false, lowPower: true, headroom: 2.5,
            eventAge: 0.4, width: 390, height: 148, intensity: 0.72)
        let packed = uniforms.packed
        #expect(packed.count == SyncGlowUniforms.Index.count)
        #expect(packed[SyncGlowUniforms.Index.time] == 2)
        #expect(packed[SyncGlowUniforms.Index.state] == 2)
        #expect(packed[SyncGlowUniforms.Index.previous] == 1)
        #expect(packed[SyncGlowUniforms.Index.transition] == 0.25)
        #expect(packed[SyncGlowUniforms.Index.pending] == 3)
        #expect(abs(packed[SyncGlowUniforms.Index.intensity] - Float(0.72) * Float(0.8)) < 0.000_1)
        #expect(packed[SyncGlowUniforms.Index.reducedMotion] == 0)
        #expect(packed[SyncGlowUniforms.Index.headroom] == 2.5)
        #expect(packed[SyncGlowUniforms.Index.lowPower] == 1)
        #expect(packed[SyncGlowUniforms.Index.eventAge] == 0.4)
        #expect(packed[SyncGlowUniforms.Index.width] == 390)
        #expect(packed[SyncGlowUniforms.Index.height] == 148)
        #expect(packed[SyncGlowUniforms.Index.pointScale] == 1)
        #expect(packed[SyncGlowUniforms.Index.dark] == 1)
    }

    @Test func theBlockIsTwentyFloatsAndCarriesScaleAndAppearance() {
        // `setFragmentBytes` wants a multiple of 16 bytes; the Metal struct is twenty floats.
        #expect(SyncGlowUniforms.Index.count == 20)
        #expect((SyncGlowUniforms.Index.count * MemoryLayout<Float>.size) % 16 == 0)
        #expect(MemoryLayout<SyncGlowUniforms>.size == SyncGlowUniforms.Index.count * MemoryLayout<Float>.size)
        let uniforms = SyncGlowComposer.uniforms(
            time: 1, state: .nudge, previous: .upToDate, transition: 1, pendingCount: 0,
            reduceMotion: false, lowPower: false, headroom: 1, eventAge: 0.5, width: 1206, height: 417,
            pointScale: 3, dark: false)
        let packed = uniforms.packed
        #expect(packed.count == SyncGlowUniforms.Index.count)
        #expect(packed[SyncGlowUniforms.Index.pointScale] == 3)
        #expect(packed[SyncGlowUniforms.Index.dark] == 0)
        #expect(packed[SyncGlowUniforms.Index.pad0] == 0)
        #expect(packed[SyncGlowUniforms.Index.pad1] == 0)
        // A drawable with no size yet, or a bad scale or headroom, cannot reach the shader as NaN or below 1.
        let odd = SyncGlowComposer.uniforms(
            time: 1, state: .upToDate, previous: .upToDate, transition: 1, pendingCount: 0,
            reduceMotion: false, lowPower: false, headroom: .nan, eventAge: 0, width: 0, height: 0,
            pointScale: .nan)
        #expect(odd.pointScale == 1)
        #expect(odd.headroom == 1)
    }

    @Test func theSyncingLightGlidesSlowlyAndNothingDrawsWhenItShouldNot() {
        // Nothing drifts or twinkles any more: the only steady motion is the syncing light, at a calm pace.
        #expect(SyncGlowPace.framesPerSecond(state: .syncing, transitioning: false, reduceMotion: false, lowPower: false, visible: true, sceneActive: true) == 20)
        #expect(SyncGlowPace.framesPerSecond(state: .syncing, transitioning: false, reduceMotion: false, lowPower: true, visible: true, sceneActive: true) == 10)
        #expect(SyncGlowPace.framesPerSecond(state: .syncing, transitioning: true, reduceMotion: false, lowPower: false, visible: true, sceneActive: true) == 30)
        #expect(SyncGlowPace.framesPerSecond(state: .nudge, transitioning: true, reduceMotion: false, lowPower: true, visible: true, sceneActive: true) == 15)
        #expect(SyncGlowPace.framesPerSecond(state: .upToDate, transitioning: false, reduceMotion: true, lowPower: false, visible: true, sceneActive: true) == nil)
        #expect(SyncGlowPace.framesPerSecond(state: .syncing, transitioning: false, reduceMotion: false, lowPower: false, visible: false, sceneActive: true) == nil)
        #expect(SyncGlowPace.framesPerSecond(state: .syncing, transitioning: false, reduceMotion: false, lowPower: false, visible: true, sceneActive: false) == nil)
        #expect(SyncGlowPace.framesPerSecond(state: .off, transitioning: false, reduceMotion: false, lowPower: false, visible: true, sceneActive: true) == nil)
    }

    @Test func aCalmOrOfflineBandIsOneStillFrameOnceItsCrossfadeIsOver() {
        // In sync, or offline with its dashes, and settled: no frames, with or without Low Power Mode.
        for state in [SyncGlowState.upToDate, .offlinePending] {
            #expect(SyncGlowPace.framesPerSecond(state: state, transitioning: false, reduceMotion: false, lowPower: false, visible: true, sceneActive: true) == nil)
            #expect(SyncGlowPace.framesPerSecond(state: state, transitioning: false, reduceMotion: false, lowPower: true, visible: true, sceneActive: true) == nil)
        }
        // The crossfade into calm still plays, then the band stops.
        #expect(SyncGlowPace.framesPerSecond(state: .upToDate, transitioning: true, reduceMotion: false, lowPower: false, visible: true, sceneActive: true) == 30)
        #expect(SyncGlowPace.framesPerSecond(state: .upToDate, transitioning: true, reduceMotion: false, lowPower: true, visible: true, sceneActive: true) == 15)
        #expect(!SyncGlowPace.isSettled(transition: 0.5))
        #expect(SyncGlowPace.isSettled(transition: 1))
        // A covered band (the view's window is gone or occluded) is passed as not visible.
        #expect(SyncGlowPace.framesPerSecond(state: .upToDate, transitioning: true, reduceMotion: false, lowPower: false, visible: false, sceneActive: true) == nil)
    }

    @Test func oneShotMomentsPlayInFullAndAreTheOnlyStatesThatNeedTheTick() {
        for state in [SyncGlowState.refused, .repull, .nudge] {
            #expect(SyncGlowPace.isOneShot(state))
            // After the crossfade the moment itself is still running: it keeps its frames.
            #expect(SyncGlowPace.framesPerSecond(state: state, transitioning: false, reduceMotion: false, lowPower: false, visible: true, sceneActive: true) == 30)
            #expect(SyncGlowPace.framesPerSecond(state: state, transitioning: false, reduceMotion: false, lowPower: true, visible: true, sceneActive: true) == 15)
            #expect(SyncGlowPace.needsTick(state: state))
        }
        for state in [SyncGlowState.upToDate, .syncing, .offlinePending, .off] {
            #expect(!SyncGlowPace.isOneShot(state))
            #expect(!SyncGlowPace.needsTick(state: state))
        }
    }

    @MainActor @Test func aNudgeOnACalmBandWakesItPlaysAndLetsItRestAgain() {
        let clock = GlowClock()
        let status = SyncGlowStatus(clock: { clock.now })
        func fps(_ transitioning: Bool) -> Int? {
            SyncGlowPace.framesPerSecond(
                state: status.state, transitioning: transitioning, reduceMotion: false, lowPower: false,
                visible: true, sceneActive: true)
        }
        #expect(status.state == .upToDate)
        #expect(fps(false) == nil)
        status.nudged()
        #expect(fps(true) == 30)
        clock.advance(SyncGlowTiming.nudge - 0.1)
        status.tick()
        #expect(status.state == .nudge)
        #expect(fps(false) == 30)
        clock.advance(0.2)
        status.tick()
        #expect(status.state == .upToDate)
        #expect(fps(true) == 30)
        #expect(fps(false) == nil)
    }

    @MainActor @Test func aRefusalBehindAnotherWindowHasEndedByTheTimeTheWindowIsBack() {
        let clock = GlowClock()
        let status = SyncGlowStatus(clock: { clock.now })
        status.refused(pending: 0)
        // The band's loop, as the view runs it while the scene is not active: it draws no frames
        // there, and the tick must still go on until the moment is over.
        #expect(SyncGlowPace.framesPerSecond(state: status.state, transitioning: false, reduceMotion: false, lowPower: false, visible: true, sceneActive: false) == nil)
        var ticks = 0
        while SyncGlowPace.needsTick(state: status.state), ticks < 50 {
            clock.advance(0.2)
            status.tick()
            ticks += 1
        }
        #expect(status.state == .upToDate)
        #expect(ticks == 6)
        // Minutes later the window comes back: nothing is left to fade out of.
        clock.advance(300)
        status.tick()
        #expect(status.state == .upToDate)
        #expect(!SyncGlowPace.needsTick(state: status.state))
    }
}

@Suite("offline dashes")
struct SyncGlowDashesTests {
    /// Bright dash runs across a band `width` points wide, sampled every quarter point.
    private func brightRuns(width: Float, pending: Int) -> [ClosedRange<Float>] {
        var runs: [ClosedRange<Float>] = []
        var start: Float?
        var x: Float = 0
        while x <= width {
            let bright = SyncGlowDashes.isBright(x: x, width: width, pending: pending)
            if bright, start == nil { start = x }
            if !bright, let s = start { runs.append(s...(x - 0.25)); start = nil }
            x += 0.25
        }
        if let s = start { runs.append(s...width) }
        return runs
    }

    @Test func oneBrightDashPerWaitingEditCappedAtEight() {
        for pending in [0, 1, 3, 5, 8, 12] {
            let runs = brightRuns(width: 402, pending: pending)
            #expect(runs.count == min(pending, SyncGlowTiming.visiblePendingCap), "pending \(pending)")
            for run in runs {
                #expect(abs((run.upperBound - run.lowerBound) - SyncGlowLook.dashLength) < 0.6)
            }
        }
    }

    @Test func theBrightRunIsCentredAndTheGridLinesUpOnIt() throws {
        let width: Float = 402
        let runs = brightRuns(width: width, pending: 4)
        let first = try #require(runs.first)
        let last = try #require(runs.last)
        #expect(abs((first.lowerBound + last.upperBound) / 2 - width / 2) < 0.6)
        for pair in zip(runs, runs.dropFirst()) {
            #expect(abs(pair.1.lowerBound - pair.0.lowerBound - SyncGlowLook.dashPeriod) < 0.6)
        }
        // The grey dashes either side keep the same rhythm, and a gap is a gap whatever the count.
        let before = first.lowerBound - SyncGlowLook.dashPeriod + 1
        #expect(SyncGlowDashes.onDash(x: before, width: width, pending: 4))
        #expect(!SyncGlowDashes.isBright(x: before, width: width, pending: 4))
        #expect(!SyncGlowDashes.onDash(x: first.lowerBound - 1, width: width, pending: 4))
        #expect(SyncGlowLook.dashLength < SyncGlowLook.dashPeriod)
    }
}

@Suite("glow readability")
struct SyncGlowLookTests {
    @Test func theCoverIsConcentratedAtTheBottomEdgeWithinTheCapsAndGoneAtTheTop() {
        #expect(SyncGlowLook.peakCover(dark: true) <= 0.5)
        #expect(SyncGlowLook.peakCover(dark: false) <= 0.5)
        #expect(SyncGlowLook.peakCover(dark: true) <= SyncGlowLook.totalCoverCap)
        for dark in [true, false] {
            #expect(SyncGlowLook.washCover(heightFraction: 0, dark: dark) == SyncGlowLook.peakCover(dark: dark))
            #expect(SyncGlowLook.washCover(heightFraction: 1, dark: dark) == 0)
            // No visible top edge: the last tenth of the band is all but clear.
            #expect(SyncGlowLook.washCover(heightFraction: 0.9, dark: dark) < 0.01)
            var last = Float.infinity
            for step in 0...20 {
                let cover = SyncGlowLook.washCover(heightFraction: Float(step) / 20, dark: dark)
                #expect(cover <= last)
                last = cover
            }
            for state in SyncGlowState.allCases {
                let cover = SyncGlowLook.washCover(heightFraction: 0, dark: dark, amplitude: SyncGlowLook.amplitude(state))
                #expect(cover <= SyncGlowLook.peakCover(dark: dark))
            }
            #expect(SyncGlowLook.washCover(heightFraction: .nan, dark: dark) == 0)
        }
        #expect(SyncGlowLook.amplitude(.off) == 0)
        #expect(SyncGlowLook.totalCoverCap <= 0.6)
        #expect(abs(SyncGlowLook.horizonThickness - 1.5) < 0.001)
    }

    @Test func theRowsJustAboveTheTabBarAreBarelyTinted() {
        // An iPhone tab: 83 pt of bars, the band 56 pt above them. Most of the cover is under the
        // glass; the last rows above the bar top get little, and the top half of the visible part none.
        let bars: Double = 83
        let band = SyncGlowPlacement.bandHeight(bottomInset: bars)
        #expect(band == 139)
        for dark in [true, false] {
            let underBar = SyncGlowLook.washCover(heightFraction: Float(52 / band), dark: dark)
            let barTop = SyncGlowLook.washCover(heightFraction: Float(bars / band), dark: dark)
            let higher = SyncGlowLook.washCover(heightFraction: Float((bars + 28) / band), dark: dark)
            #expect(underBar > 0.2)
            #expect(underBar < 0.3)
            #expect(barTop < 0.1)
            #expect(higher < 0.015)
            #expect(underBar > barTop * 2.5)
        }
    }

    @Test func withNoBarsTheEdgeStaysNearTheOldStrengthOverTheLastRows() {
        // The Mac's detail column: content runs to the edge, so the peak is lower than under a tab bar,
        // and a row's text 12 to 24 pt up is under no more cover than the old wash put at the very edge.
        for dark in [true, false] {
            let bare = SyncGlowLook.edgePeak(dark: dark, bars: 0)
            #expect(bare < SyncGlowLook.edgePeak(dark: dark, bars: 83))
            #expect(SyncGlowLook.edgePeak(dark: dark, bars: 83) == SyncGlowLook.peakCover(dark: dark))
            #expect(SyncGlowLook.edgePeak(dark: dark, bars: .nan) == bare)
            #expect(bare <= 0.38)
            let band = Float(SyncGlowPlacement.bandHeight(bottomInset: 0))
            #expect(SyncGlowLook.washCover(heightFraction: 12 / band, dark: dark, bars: 0) < 0.3)
            #expect(SyncGlowLook.washCover(heightFraction: 24 / band, dark: dark, bars: 0) < 0.2)
        }
    }

    @Test func darkModeLightIsHottestAtTheEdgeAndUsesHeadroom() {
        #expect(SyncGlowLook.coreLift(heightFraction: 1, headroom: 1) == 1)
        #expect(abs(SyncGlowLook.coreLift(heightFraction: 0, headroom: 1) - (1 + SyncGlowLook.coreBoost)) < 0.000_1)
        #expect(SyncGlowLook.coreLift(heightFraction: 0, headroom: 3) > SyncGlowLook.coreLift(heightFraction: 0, headroom: 1))
        // Headroom past 4 does not push it further, and a bad value counts as none.
        #expect(SyncGlowLook.coreLift(heightFraction: 0, headroom: 16) == SyncGlowLook.coreLift(heightFraction: 0, headroom: 4))
        #expect(SyncGlowLook.coreLift(heightFraction: 0, headroom: .nan) == SyncGlowLook.coreLift(heightFraction: 0, headroom: 1))
        var last = Float.infinity
        for step in 0...10 {
            let lift = SyncGlowLook.coreLift(heightFraction: Float(step) / 10, headroom: 2)
            #expect(lift <= last && lift >= 1)
            last = lift
        }
    }

    @Test func theShaderRepeatsTheseNumbers() throws {
        // The shader cannot import SyncGlowKit, so its constants are checked here against the source.
        let shader = try String(contentsOf: Self.repo.appending(path: "Cobalt/Screens/Library/SyncGlow.metal"), encoding: .utf8)
        func has(_ line: String) { #expect(shader.contains(line), "shader is missing: \(line)") }
        has("constant float kPeakDark = \(SyncGlowLook.peakCover(dark: true));")
        has("constant float kPeakLight = \(SyncGlowLook.peakCover(dark: false));")
        has("constant float kFalloff = \(SyncGlowLook.falloff);")
        has("constant float kBarelessShare = \(SyncGlowLook.barelessShare);")
        has("constant float kFullBars = \(SyncGlowLook.fullBars);")
        has("constant float kBandHeight = \(SyncGlowLook.bandHeight);")
        has("constant float kTotalCap = \(SyncGlowLook.totalCoverCap);")
        has("constant float kCoreBoost = \(SyncGlowLook.coreBoost);")
        has("constant float kHorizonY = \(SyncGlowLook.horizonHeight);")
        has("constant float kHorizonWidth = \(SyncGlowLook.horizonThickness);")
        has("constant float kDashPeriod = \(SyncGlowLook.dashPeriod);")
        has("constant float kDashLength = \(SyncGlowLook.dashLength);")
        has("constant float kLightSpeed = \(SyncGlowLook.lightSpeed);")
        has("constant float kLightWidth = \(SyncGlowLook.lightWidth);")
        has("safePow(1.0 - s, kFalloff)")
        has("safePow(1.0 - saturate(f), 3.0)")
        for state in SyncGlowState.allCases where state != .off {
            has("return \(SyncGlowLook.amplitude(state));")
        }
        // Nothing left of the star field.
        for gone in ["atlas", "glyph", "starLayer", "kStar", "blur"] {
            #expect(!shader.contains(gone), "shader still has \(gone)")
        }
        // Twenty floats, in Index order.
        let fields = ["time", "state", "previous", "transition", "pending", "intensity", "reduced",
                      "headroom", "lowPower", "eventAge", "width", "height", "pointScale", "dark", "activity", "touchX", "touchLevel", "scroll", "pad0", "pad1"]
        #expect(fields.count == SyncGlowUniforms.Index.count)
        let body = try #require(shader.range(of: "struct GlowUniforms {")).upperBound
        let end = try #require(shader.range(of: "};", range: body..<shader.endIndex)).lowerBound
        let declared = shader[body..<end].split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        #expect(declared == fields.map { "float \($0);" })
    }

    @Test func thePaletteComesFromTheAppsTokens() throws {
        // Each colour the shader draws with is one of CobaltColor's, so the band matches the app.
        let shader = try String(contentsOf: Self.repo.appending(path: "Cobalt/Screens/Library/SyncGlow.metal"), encoding: .utf8)
        let tokens = try String(contentsOf: Self.repo.appending(path: "Cobalt/Design/Tokens.swift"), encoding: .utf8)
        let pairs = [
            ("linkBlue = Color(light: 0x196bd4, dark: 0x2f8af9)", ["0x196bd4", "0x2f8af9"]),
            ("sharedInk = Color(hex: 0x8ab8ff)", ["0x8ab8ff"]),
            ("caption = Color(light: 0x6e6e75, dark: 0x8f8f8f)", ["0x6e6e75", "0x8f8f8f"]),
            ("errorText = Color(light: 0xc4142a, dark: 0xff5c6c)", ["0xc4142a", "0xff5c6c"]),
        ]
        for (token, hexes) in pairs {
            #expect(tokens.contains(token), "Tokens.swift changed: \(token)")
            for hex in hexes { #expect(shader.contains("hexLinear(\(hex))"), "shader does not use \(hex)") }
        }
        let used = shader.matches(of: /hexLinear\((0x[0-9a-f]{6})\)/).map { String($0.1) }
        let allowed = Set(pairs.flatMap(\.1))
        for hex in used { #expect(allowed.contains(hex), "\(hex) is not a design token") }
    }

    /// apple/, found from this file: apple/SyncGlowKit/Tests/SyncGlowKitTests/SyncGlowTests.swift.
    static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}

@Suite("glow placement")
struct SyncGlowPlacementTests {
    @Test func aTabKeepsItsBandUntilAPresentationDrawsItsOwn() {
        #expect(SyncGlowPlacement.tabShowsBand(queueSheet: false, editorCover: false))
        #expect(!SyncGlowPlacement.tabShowsBand(queueSheet: true, editorCover: false))
        #expect(!SyncGlowPlacement.tabShowsBand(queueSheet: false, editorCover: true))
        #expect(!SyncGlowPlacement.tabShowsBand(queueSheet: true, editorCover: true))
    }

    @Test func theBandReachesUnderTheBarsToTheBottomEdge() {
        // 56 pt in view, plus whatever the tab bar and home indicator cover, so their glass sits on it.
        #expect(SyncGlowLook.bandHeight == 56)
        #expect(SyncGlowPlacement.bandHeight(bottomInset: 0) == 56)
        #expect(SyncGlowPlacement.bandHeight(bottomInset: 83) == 139)
        #expect(SyncGlowPlacement.bandHeight(bottomInset: -4) == 56)
        #expect(SyncGlowPlacement.bandHeight(bottomInset: .nan) == 56)
    }
}

@Suite("glow debug arguments")
struct SyncGlowDebugParseTests {
    @Test func theLaunchWordsMapOntoEachState() {
        #expect(SyncGlowDebugParse.state(from: "syncing") == .syncing)
        #expect(SyncGlowDebugParse.state(from: " Syncing ") == .syncing)
        #expect(SyncGlowDebugParse.state(from: "offline") == .offlinePending)
        #expect(SyncGlowDebugParse.state(from: "up-to-date") == .upToDate)
        #expect(SyncGlowDebugParse.state(from: "410") == .repull)
        #expect(SyncGlowDebugParse.state(from: "re-pull") == .repull)
        #expect(SyncGlowDebugParse.state(from: "rollback") == .refused)
        #expect(SyncGlowDebugParse.state(from: "nudge") == .nudge)
        #expect(SyncGlowDebugParse.state(from: "off") == .off)
        #expect(SyncGlowDebugParse.state(from: "nope") == nil)
        #expect(SyncGlowDebugParse.state(from: nil) == nil)
        #expect(SyncGlowDebugParse.pending(from: "4") == 4)
        #expect(SyncGlowDebugParse.pending(from: "0") == 0)
        #expect(SyncGlowDebugParse.pending(from: "-2") == 0)
        #expect(SyncGlowDebugParse.pending(from: nil) == nil)
        #expect(SyncGlowDebugParse.pending(from: "many") == nil)
    }
}

@MainActor
private final class GlowClock {
    var now = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

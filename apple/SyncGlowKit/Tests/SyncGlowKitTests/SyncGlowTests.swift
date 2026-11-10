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

    @Test func offlineWinsOverAPassAndKeepsThePendingCountForTheCluster() {
        let facts = SyncGlowFacts(reachable: false, passRunning: true, pendingCount: 2)
        #expect(SyncGlowResolve.state(facts) == .offlinePending)
    }

    @Test func offlineWithNothingWaitingIsStillTheDimState() {
        #expect(SyncGlowResolve.state(SyncGlowFacts(reachable: false)) == .offlinePending)
    }

    @Test func aRefusalARepullAndANudgeCoverTheSteadyStateUntilTheyExpire() {
        #expect(SyncGlowResolve.state(SyncGlowFacts(passRunning: true, transient: .refused, transientAge: 0.2)) == .refused)
        #expect(SyncGlowResolve.state(SyncGlowFacts(passRunning: true, transient: .refused, transientAge: 1.2)) == .syncing)
        #expect(SyncGlowResolve.state(SyncGlowFacts(transient: .nudge, transientAge: 0.4)) == .nudge)
        #expect(SyncGlowResolve.state(SyncGlowFacts(transient: .nudge, transientAge: 1.8)) == .upToDate)
        #expect(SyncGlowResolve.state(SyncGlowFacts(passRunning: true, transient: .repull, transientAge: 3)) == .repull)
        #expect(SyncGlowResolve.state(SyncGlowFacts(passRunning: false, transient: .repull, transientAge: 1)) == .repull)
        #expect(SyncGlowResolve.state(SyncGlowFacts(passRunning: false, transient: .repull, transientAge: 2.4)) == .upToDate)
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

    @Test func anUnsentEditWhileOfflineIsTheWaitingCluster() {
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

    @Test func aNudgeShowsTheShootingStarWithoutForgettingAPass() {
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
            eventAge: 0.4, width: 390, height: 148, glyphsEnabled: false, intensity: 0.72, density: 1.4)
        let packed = uniforms.packed
        #expect(packed.count == SyncGlowUniforms.Index.count)
        #expect(packed[SyncGlowUniforms.Index.time] == 2)
        #expect(packed[SyncGlowUniforms.Index.state] == 2)
        #expect(packed[SyncGlowUniforms.Index.previous] == 1)
        #expect(packed[SyncGlowUniforms.Index.transition] == 0.25)
        #expect(packed[SyncGlowUniforms.Index.pending] == 3)
        #expect(abs(packed[SyncGlowUniforms.Index.intensity] - Float(0.72) * Float(0.8)) < 0.000_1)
        #expect(packed[SyncGlowUniforms.Index.density] == 1)
        #expect(packed[SyncGlowUniforms.Index.reducedMotion] == 0)
        #expect(packed[SyncGlowUniforms.Index.headroom] == 2.5)
        #expect(packed[SyncGlowUniforms.Index.lowPower] == 1)
        #expect(packed[SyncGlowUniforms.Index.eventAge] == 0.4)
        #expect(packed[SyncGlowUniforms.Index.width] == 390)
        #expect(packed[SyncGlowUniforms.Index.height] == 148)
        #expect(packed[SyncGlowUniforms.Index.atlasColumns] == 12)
        #expect(packed[SyncGlowUniforms.Index.glyphsEnabled] == 0)
    }

    @Test func theFrameRateDropsWhenIdleAndStopsWhenItShouldNotDraw() {
        #expect(SyncGlowPace.framesPerSecond(state: .upToDate, transitioning: false, reduceMotion: false, lowPower: false, visible: true, sceneActive: true) == 15)
        #expect(SyncGlowPace.framesPerSecond(state: .offlinePending, transitioning: false, reduceMotion: false, lowPower: false, visible: true, sceneActive: true) == 15)
        #expect(SyncGlowPace.framesPerSecond(state: .syncing, transitioning: false, reduceMotion: false, lowPower: false, visible: true, sceneActive: true) == 30)
        #expect(SyncGlowPace.framesPerSecond(state: .nudge, transitioning: true, reduceMotion: false, lowPower: true, visible: true, sceneActive: true) == 15)
        #expect(SyncGlowPace.framesPerSecond(state: .upToDate, transitioning: false, reduceMotion: false, lowPower: true, visible: true, sceneActive: true) == 8)
        #expect(SyncGlowPace.framesPerSecond(state: .upToDate, transitioning: false, reduceMotion: true, lowPower: false, visible: true, sceneActive: true) == nil)
        #expect(SyncGlowPace.framesPerSecond(state: .syncing, transitioning: false, reduceMotion: false, lowPower: false, visible: false, sceneActive: true) == nil)
        #expect(SyncGlowPace.framesPerSecond(state: .syncing, transitioning: false, reduceMotion: false, lowPower: false, visible: true, sceneActive: false) == nil)
        #expect(SyncGlowPace.framesPerSecond(state: .off, transitioning: false, reduceMotion: false, lowPower: false, visible: true, sceneActive: true) == nil)
    }
}

@Suite("glyph atlas")
struct GlyphAtlasTests {
    @Test func theRowIsStarsThenTheLineCharacters() {
        let layout = GlyphAtlasLayout(cell: 64)
        #expect(GlyphAtlasLayout.glyphs.count == 12)
        #expect(layout.pixelWidth == 768)
        #expect(layout.pixelHeight == 64)
        #expect(layout.index(of: ".") == 0)
        #expect(layout.index(of: "*") == 1)
        #expect(layout.index(of: "+") == 2)
        #expect(layout.index(of: "o") == 3)
        #expect(layout.index(of: "'") == 4)
        #expect(layout.index(of: "`") == 5)
        #expect(layout.index(of: "-") == 6)
        #expect(layout.index(of: "/") == 7)
        #expect(layout.index(of: "\\") == 8)
        #expect(layout.index(of: "|") == 9)
        #expect(layout.index(of: "_") == 10)
        #expect(layout.index(of: ":") == 11)
        #expect(layout.index(of: "x") == nil)
        #expect(layout.glyph(at: 8) == "\\")
        #expect(layout.glyph(at: 12) == nil)
    }

    @Test func cellsTileTheAtlasWithoutOverlap() throws {
        let layout = GlyphAtlasLayout(cell: 32)
        var covered: [GlyphUV] = []
        for index in 0..<GlyphAtlasLayout.columns {
            let uv = try #require(layout.uv(index: index))
            #expect(uv.v0 == 0)
            #expect(uv.v1 == 1)
            #expect(abs((uv.u1 - uv.u0) - 1 / Float(GlyphAtlasLayout.columns)) < 0.000_1)
            #expect(uv.u0 == Float(index) / 12)
            covered.append(uv)
        }
        for pair in zip(covered, covered.dropFirst()) {
            #expect(pair.0.u1 == pair.1.u0)
        }
        #expect(layout.uv(index: -1) == nil)
        #expect(GlyphAtlasLayout(cell: 1).cell == 8)
    }

    @Test func linkGlyphsFollowTheSegmentAndUseEveryLineCharacter() {
        #expect(GlyphAtlasLayout.linkGlyph(dx: 1, dy: 0) == "-")
        #expect(GlyphAtlasLayout.linkGlyph(dx: 0, dy: 1) == "|")
        #expect(GlyphAtlasLayout.linkGlyph(dx: 1, dy: 1) == "\\")
        #expect(GlyphAtlasLayout.linkGlyph(dx: 1, dy: -1) == "/")
        #expect(GlyphAtlasLayout.linkGlyph(dx: -1, dy: 1) == "/")
        #expect(GlyphAtlasLayout.linkGlyph(dx: 1, dy: 0.1, salt: 0.9) == "_")
        #expect(GlyphAtlasLayout.linkGlyph(dx: 0.1, dy: 1, salt: 0.9) == ":")
        #expect(GlyphAtlasLayout.linkGlyphIndex(dx: 1, dy: -1) == 7)
        #expect(GlyphAtlasLayout.linkGlyphIndex(dx: 1, dy: 1) == 8)
    }

    @Test func theCellGridAndStarPickMatchTheShaderConstants() {
        let grid = SyncGlowField.cellGrid(density: 0.7)
        #expect(grid.x == 7 + 12 * Float(0.7))
        #expect(grid.y == 3 + Float(2.2) * Float(0.7))
        #expect(SyncGlowField.cellGrid(density: 4).x == SyncGlowField.cellGrid(density: 1).x)
        #expect(!SyncGlowField.showsStar(hash: 0.9, density: 0.7))
        #expect(SyncGlowField.showsStar(hash: 0.1, density: 0.7))
        #expect(SyncGlowField.starGlyphIndex(hash: 0) == 0)
        #expect(SyncGlowField.starGlyphIndex(hash: 0.999) == 5)
        let h = SyncGlowField.hash(1, 2)
        #expect(h >= 0 && h < 1)
        #expect(SyncGlowField.hash(1, 2) == h)
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

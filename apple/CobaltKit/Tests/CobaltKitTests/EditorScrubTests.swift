import Foundation
import Testing
@testable import CobaltKit

// The timeline's feel (CONTRACT-EDITOR 15.5): coalesced seeks, the fling, the tick on a clip edge, trim snapping, and lane
// heights.

struct EditorScrubTests {
    // MARK: coalescer

    @Test func theFirstMoveStartsASeekAndItIsTolerant() {
        var c = SeekCoalescer()
        #expect(c.request(frame: 10) == ScrubSeek(frame: 10, exact: false))
        #expect(c.inFlight == ScrubSeek(frame: 10, exact: false))
    }

    @Test func onlyOneSeekIsInFlightAndTheLatestTargetWins() {
        var c = SeekCoalescer()
        #expect(c.request(frame: 10) != nil)
        #expect(c.request(frame: 11) == nil)
        #expect(c.request(frame: 12) == nil)
        #expect(c.request(frame: 15) == nil)
        #expect(c.pending == ScrubSeek(frame: 15, exact: false))
        // the first lands: the newest waiting target goes, the ones in between never did
        #expect(c.landed() == ScrubSeek(frame: 15, exact: false))
        #expect(c.inFlight?.frame == 15)
        #expect(c.landed() == nil)
        #expect(c.inFlight == nil)
    }

    @Test func letGoEndsWithAnExactSeekOnTheLastFrame() {
        var c = SeekCoalescer()
        _ = c.request(frame: 10)
        _ = c.request(frame: 20)
        // released while the first is still in flight: the exact seek waits behind it and replaces the tolerant one
        #expect(c.release(frame: 20) == nil)
        #expect(c.pending == ScrubSeek(frame: 20, exact: true))
        #expect(c.landed() == ScrubSeek(frame: 20, exact: true))
        #expect(c.landed() == nil)
    }

    @Test func letGoWithNothingInFlightSeeksAtOnceAndExactly() {
        var c = SeekCoalescer()
        #expect(c.release(frame: 7) == ScrubSeek(frame: 7, exact: true))
        // the same again is a no-op
        _ = c.landed()
        #expect(c.release(frame: 7) == nil)
    }

    @Test func aTolerantSeekOnTheFrameStillNeedsItsExactOneOnRelease() {
        var c = SeekCoalescer()
        _ = c.request(frame: 9)
        #expect(c.landed() == nil)
        // the picture is on frame 9 but only roughly
        #expect(c.release(frame: 9) == ScrubSeek(frame: 9, exact: true))
    }

    @Test func aLaterMoveNeverDowngradesTheExactSeekWaitingForTheSameFrame() {
        var c = SeekCoalescer()
        _ = c.request(frame: 3)
        _ = c.release(frame: 4)
        #expect(c.request(frame: 4) == nil)
        #expect(c.pending == ScrubSeek(frame: 4, exact: true))
    }

    @Test func aNewScrubDropsWhatWaitedFromTheLastOne() {
        var c = SeekCoalescer()
        _ = c.request(frame: 3)
        _ = c.request(frame: 8)
        c.begin()
        #expect(c.pending == nil)
        #expect(c.landed() == nil)
    }

    @Test func sameFrameTwiceInARowIsNotSentAgain() {
        var c = SeekCoalescer()
        _ = c.request(frame: 5)
        _ = c.landed()
        #expect(c.request(frame: 5) == nil)
        #expect(c.request(frame: 6) != nil)
    }

    @Test func aWaitingTargetOnTheFrameJustLandedIsDropped() {
        var c = SeekCoalescer()
        _ = c.request(frame: 5)
        _ = c.request(frame: 6)
        _ = c.request(frame: 5)
        #expect(c.landed() == nil)
    }

    @Test func aLongDragSendsFarFewerSeeksThanMoves() {
        var c = SeekCoalescer()
        var sent = 0
        for frame in 0..<300 {
            if c.request(frame: frame) != nil { sent += 1 }
            // the player lands one seek every ten moves
            if frame % 10 == 9, c.landed() != nil { sent += 1 }
        }
        #expect(sent < 70)
        #expect(c.inFlight == nil || c.inFlight!.frame >= 290)
    }

    // MARK: fling

    @Test func aFlingSlowsDownAndComesToRest() {
        let fling = TimelineFling(position: 2, velocity: 6, bounds: 0...100)
        #expect(fling.duration > 0.5)
        var last = fling.position(at: 0)
        #expect(last == 2)
        var speed = abs(fling.velocity(at: 0))
        var t = 0.0
        while t < fling.duration {
            t += 1.0 / 60
            let p = fling.position(at: t)
            #expect(p >= last)                          // forward only, never back
            #expect(abs(fling.velocity(at: t)) <= speed + 1e-9)
            last = p
            speed = abs(fling.velocity(at: t))
        }
        #expect(fling.isFinished(at: fling.duration))
        #expect(fling.velocity(at: fling.duration) == 0)
        #expect(abs(fling.restingPosition - fling.position(at: fling.duration + 5)) < 1e-12)
    }

    @Test func theDecayIsAScrollViewsPointNineNineEightPerMillisecond() {
        let fling = TimelineFling(position: 0, velocity: 10, bounds: 0...1000)
        // 0.998 per ms: after half a second the speed is 0.998^500 of the start
        let expected = 10 * exp(500 * log(0.998))
        #expect(abs(fling.velocity(at: 0.5) - expected) < 1e-6)
        // and it goes v0 / rate in all
        #expect(abs(fling.restingPosition - 10 / (-1000 * log(0.998))) < 0.05)
    }

    @Test func aFlingBackwardStopsAtZero() {
        let fling = TimelineFling(position: 1, velocity: -50, bounds: 0...30)
        #expect(fling.restingPosition == 0)
        #expect(fling.position(at: fling.duration) == 0)
        #expect(fling.position(at: 100) == 0)
        for step in 0...60 {
            let p = fling.position(at: Double(step) / 60)
            #expect(p >= 0 && p <= 1)
        }
    }

    @Test func aFlingForwardStopsAtTheEnd() {
        let fling = TimelineFling(position: 28, velocity: 80, bounds: 0...30)
        #expect(fling.restingPosition == 30)
        #expect(fling.duration < 1)
        var last = 28.0
        for step in 0...120 {
            let p = fling.position(at: Double(step) / 60)
            #expect(p >= last && p <= 30)
            last = p
        }
    }

    @Test func aSlowReleaseDoesNotFlingAndAReleaseAtTheBoundDoesNotMove() {
        #expect(TimelineFling(position: 4, velocity: 0.01, bounds: 0...30).duration == 0)
        #expect(TimelineFling(position: 4, velocity: 0, bounds: 0...30).restingPosition == 4)
        let atEnd = TimelineFling(position: 30, velocity: 40, bounds: 0...30)
        #expect(atEnd.duration == 0)
        #expect(atEnd.restingPosition == 30)
        let atStart = TimelineFling(position: 0, velocity: -40, bounds: 0...30)
        #expect(atStart.restingPosition == 0)
    }

    @Test func nonsenseInputsStayInsideTheBounds() {
        let fling = TimelineFling(position: .nan, velocity: .infinity, bounds: 0...10)
        #expect(fling.restingPosition >= 0 && fling.restingPosition <= 10)
        let wild = TimelineFling(position: 100, velocity: 3, bounds: 0...10)
        #expect(wild.position(at: 1) <= 10)
    }

    // MARK: edges

    private let edges = [0.0, 2.0, 5.5, 9.0]

    @Test func crossingAnEdgeForwardOrBackwardIsOneTick() {
        #expect(TimelineEdges.crossed(from: 1.9, to: 2.1, edges: edges))
        #expect(TimelineEdges.crossed(from: 2.1, to: 1.9, edges: edges))
        #expect(!TimelineEdges.crossed(from: 2.1, to: 2.4, edges: edges))
        #expect(!TimelineEdges.crossed(from: 3, to: 3, edges: edges))
    }

    @Test func landingOnAnEdgeCountsOnceAndLeavingItDoesNot() {
        // forward: arriving on it counts, then moving off it does not
        #expect(TimelineEdges.crossed(from: 1.5, to: 2, edges: edges))
        #expect(!TimelineEdges.crossed(from: 2, to: 2.5, edges: edges))
        // backward: arriving on it counts, then moving off it does not
        #expect(TimelineEdges.crossed(from: 2.5, to: 2, edges: edges))
        #expect(!TimelineEdges.crossed(from: 2, to: 1.5, edges: edges))
    }

    @Test func manyEdgesInOneStepAreStillOneCrossingAndNoEdgesIsNone() {
        #expect(TimelineEdges.crossed(from: 1, to: 10, edges: edges))
        #expect(!TimelineEdges.crossed(from: 1, to: 10, edges: []))
        #expect(!TimelineEdges.crossed(from: .nan, to: 3, edges: edges))
    }

    @Test func edgesAreSortedAndNearDuplicatesMerge() {
        let out = TimelineEdges.edges(of: [(start: 3, end: 6), (start: 0, end: 3.0004), (start: 6, end: 8)])
        #expect(out == [0, 3, 6, 8])
    }

    // MARK: trim snapping

    @Test func aTrimmedEdgeSnapsToTheNearestPointWithinTheThreshold() {
        let points = [4.0, 4.05, 9.0]
        let hit = TimelineTrimSnap.snap(end: 6, delta: -1.96, points: points, threshold: 0.1)
        #expect(hit.point == 4.05 || hit.point == 4.0)
        #expect(abs(6 + hit.delta - (hit.point ?? 0)) < 1e-12)
        // the closer of the two wins
        #expect(TimelineTrimSnap.snap(end: 6, delta: -1.97, points: points, threshold: 0.1).point == 4.05)
    }

    @Test func outsideTheThresholdTheDeltaIsLeftAlone() {
        let miss = TimelineTrimSnap.snap(end: 6, delta: 1, points: [9], threshold: 0.1)
        #expect(miss.point == nil)
        #expect(miss.delta == 1)
        #expect(TimelineTrimSnap.snap(end: 6, delta: 2.95, points: [9], threshold: 0).point == nil)
    }

    // MARK: lane heights

    @Test func oneLaneGrowsToItsCap() {
        let layout = TimelineLaneLayout(available: 300, priority: [true])
        #expect(layout.heights == [130])
        #expect(!layout.scrolls)
    }

    @Test func laneZeroAndKeyedLanesGrowBeforeTheOthers() {
        // lane 0, a plain layer, a keyed layer in 260 pt: floors are 120, so 140 pt is spare and the two big lanes share it
        let layout = TimelineLaneLayout(available: 260, priority: [true, false, true])
        #expect(layout.heights == [110, 40, 110])
        #expect(layout.contentHeight == 260)
        #expect(!layout.scrolls)
        // with 300 pt both reach the 130 pt cap and the plain layer is still 40
        let more = TimelineLaneLayout(available: 300, priority: [true, false, true])
        #expect(more.heights == [130, 40, 130])
        // and past the slot it scrolls
        #expect(TimelineLaneLayout(available: 100, priority: [true, false, true]).scrolls)
    }

    @Test func theLeftoversGoToTheOtherLanesUpToTheirCap() {
        let layout = TimelineLaneLayout(available: 600, priority: [true, false, false])
        #expect(layout.heights[0] == 130)
        #expect(layout.heights[1] == TimelineLaneLayout.otherMaximum && layout.heights[2] == TimelineLaneLayout.otherMaximum)
        #expect(!layout.scrolls)
    }

    @Test func everyLaneKeepsItsFortyPointFloorAndTheStackScrollsPastTheSlot() {
        let layout = TimelineLaneLayout(available: 180, priority: [true, false, false, false, false, false])
        #expect(layout.heights.allSatisfy { $0 == 40 })
        #expect(layout.contentHeight == 240)
        #expect(layout.scrolls)
    }

    @Test func theStackNeverExceedsTheSlotWhileItFits() {
        for available in stride(from: 100.0, through: 700, by: 17) {
            for count in 1...5 {
                let priority = (0..<count).map { $0 == 0 || $0 == 3 }
                let layout = TimelineLaneLayout(available: available, priority: priority)
                #expect(layout.heights.allSatisfy { $0 >= 40 })
                for (lane, height) in layout.heights.enumerated() {
                    #expect(height <= (priority[lane] ? 130 : 72) + 1e-9)
                }
                if layout.contentHeight <= available { #expect(!layout.scrolls) }
                if Double(count) * 40 <= available { #expect(layout.contentHeight <= available + 1e-9) }
            }
        }
    }

    @Test func topsRunFromTheHighestLaneDownAndLookUpFindsTheLane() {
        let layout = TimelineLaneLayout(available: 300, priority: [true, false, true])
        // lane 2 is drawn first
        #expect(layout.tops[2] == 0)
        #expect(layout.tops[1] == layout.heights[2])
        #expect(layout.tops[0] == layout.heights[2] + layout.heights[1])
        #expect(layout.lane(atY: -20) == 2)
        #expect(layout.lane(atY: layout.tops[1] + 1) == 1)
        #expect(layout.lane(atY: layout.tops[0] + 1) == 0)
        #expect(layout.lane(atY: 9999) == 0)
    }

    @Test func noLanesIsEmptyAndANegativeSlotIsFloors() {
        let none = TimelineLaneLayout(available: 200, priority: [])
        #expect(none.heights.isEmpty && none.contentHeight == 0 && !none.scrolls)
        #expect(none.lane(atY: 5) == 0)
        let tiny = TimelineLaneLayout(available: -5, priority: [true, false])
        #expect(tiny.heights == [40, 40])
    }
}

import Testing
@testable import CobaltKit

@Suite("frame stats")
struct FrameStatsTests {
    private let r120 = 1.0 / 120

    @Test func aSmoothStretchHasNoHitches() {
        var s = FrameStats()
        for i in 0...120 { s.tick(timestamp: Double(i) * r120, refresh: r120) }
        #expect(s.frames == 120)
        #expect(s.hitches == 0)
        #expect(s.hitchRatio == 0)
        #expect(s.hz == 120)
        #expect(abs(s.spanMs - 1000) < 0.01)
    }

    @Test func aLateFrameCountsOnlyItsLateness() {
        var s = FrameStats()
        var t = 0.0
        s.tick(timestamp: t, refresh: r120)
        for _ in 0..<10 { t += r120; s.tick(timestamp: t, refresh: r120) }
        t += 4 * r120                                    // three refreshes missed
        let gap = s.tick(timestamp: t, refresh: r120)
        #expect(gap.map { abs($0 - 33.33) < 0.01 } == true)
        #expect(s.hitches == 1)
        #expect(abs(s.hitchMs - 25) < 0.01)
        #expect(s.severe == 0)
        #expect(abs(s.worstMs - 33.33) < 0.01)
    }

    @Test func aHalfRefreshWobbleIsNotAHitch() {
        var s = FrameStats()
        s.tick(timestamp: 0, refresh: r120)
        s.tick(timestamp: r120 * 1.4, refresh: r120)
        #expect(s.hitches == 0)
    }

    @Test func aLongStallIsSevere() {
        var s = FrameStats()
        s.tick(timestamp: 0, refresh: r120)
        s.tick(timestamp: 0.2, refresh: r120)
        #expect(s.severe == 1)
        #expect(s.hitchRatio > 900)
    }

    @Test func theFirstTickOnlyStartsTheClockAndBadRefreshesAreIgnored() {
        var s = FrameStats()
        #expect(s.tick(timestamp: 5, refresh: r120) == nil)
        #expect(s.tick(timestamp: 6, refresh: 0) == nil)
        #expect(s.frames == 0)
        #expect(s.values["frames"] == .int(0))
    }
}

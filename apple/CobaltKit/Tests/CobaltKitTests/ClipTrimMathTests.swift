import Foundation
import Testing
@testable import CobaltKit

// The clip trim's time math: a point on the strip and a source second, zoom 1×...8×, the clamp the
// session already applies (0.1 s of output, longer in source when the clip is sped up), and the readout.

struct ClipTrimMathTests {
    @Test func zoomStaysBetweenOneAndEight() {
        #expect(ClipTrimMath.clampedZoom(1) == 1)
        #expect(ClipTrimMath.clampedZoom(8) == 8)
        #expect(ClipTrimMath.clampedZoom(0.2) == 1)
        #expect(ClipTrimMath.clampedZoom(9) == 8)
        #expect(ClipTrimMath.clampedZoom(.nan) == 1)
        #expect(ClipTrimMath.clampedZoom(.infinity) == 8)
        #expect(ClipTrimMath.zoomStops == [1, 2, 4, 8])
    }

    @Test func oneTimesShowsTheWholeFileWhereverItIsAnchored() {
        let early = ClipTrimMath.window(duration: 10, zoom: 1, anchor: 0)
        let late = ClipTrimMath.window(duration: 10, zoom: 1, anchor: 10)
        #expect(early.start == 0 && early.span == 10 && early.end == 10)
        #expect(late.start == 0 && late.span == 10)
    }

    @Test func zoomCentersOnTheAnchorAndClampsToTheFile() {
        let middle = ClipTrimMath.window(duration: 10, zoom: 2, anchor: 5)
        #expect(middle.start == 2.5)
        #expect(middle.span == 5)
        #expect(middle.end == 7.5)

        let start = ClipTrimMath.window(duration: 10, zoom: 8, anchor: 0)
        #expect(start.start == 0)
        #expect(abs(start.span - 1.25) < 1e-9)
        #expect(abs(start.end - 1.25) < 1e-9)

        let end = ClipTrimMath.window(duration: 10, zoom: 8, anchor: 10)
        #expect(abs(end.start - 8.75) < 1e-9)
        #expect(abs(end.end - 10) < 1e-9)
    }

    @Test func aPointAndASourceSecondConvertBothWays() {
        let window = ClipTrimMath.window(duration: 10, zoom: 2, anchor: 5)
        let width = 200.0
        #expect(ClipTrimMath.seconds(atX: 0, width: width, window: window) == 2.5)
        #expect(ClipTrimMath.seconds(atX: width, width: width, window: window) == 7.5)
        let x = ClipTrimMath.x(forSeconds: 4, width: width, window: window)
        #expect(abs(x - 60) < 1e-9)
        let back = ClipTrimMath.seconds(atX: x, width: width, window: window)
        #expect(abs(back - 4) < 1e-9)
        // Past the edges lands on the window's ends.
        #expect(ClipTrimMath.seconds(atX: -20, width: width, window: window) == window.start)
        #expect(ClipTrimMath.seconds(atX: 999, width: width, window: window) == window.end)
        #expect(ClipTrimMath.x(forSeconds: 0, width: width, window: window) == 0)
        #expect(ClipTrimMath.x(forSeconds: 99, width: width, window: window) == width)
    }

    @Test func aDragMovesByTheWindowAtItsStart() {
        // 20 pt on a 200 pt strip showing 10 s is 1 s. A zoomed window of 1.25 s is much finer.
        #expect(ClipTrimMath.seconds(moved: 20, width: 200, span: 10) == 1)
        #expect(abs(ClipTrimMath.seconds(moved: 20, width: 200, span: 1.25) - 0.125) < 1e-9)
        #expect(ClipTrimMath.seconds(moved: .nan, width: 200, span: 10) == 0)
        #expect(ClipTrimMath.seconds(moved: 10, width: 0, span: 10) == 0)
    }

    @Test func thePlayheadStaysInsideTheFile() {
        #expect(ClipTrimMath.clampedPlayhead(-2, duration: 10) == 0)
        #expect(ClipTrimMath.clampedPlayhead(4.5, duration: 10) == 4.5)
        #expect(ClipTrimMath.clampedPlayhead(12, duration: 10) == 10)
        #expect(ClipTrimMath.clampedPlayhead(.nan, duration: 10) == 0)
    }

    @Test @MainActor func aFasterClipKeepsMoreSourceForTheSameOutput() {   // EditSession.clampTrim is main-actor
        #expect(ClipTrimMath.minimumSourceSpan(speed: 1) == 0.1)
        #expect(abs(ClipTrimMath.minimumSourceSpan(speed: 1.5) - 0.15) < 1e-9)   // 0.1 * 1.5 is not exactly 0.15 in binary
        #expect(ClipTrimMath.minimumSourceSpan(speed: 2) == 0.2)
        #expect(ClipTrimMath.minimumSourceSpan(speed: 0.5) == 0.1)   // slow still keeps 0.1 s of source
        #expect(ClipTrimMath.minimumSourceSpan(speed: .nan) == 0.1)

        let (inPoint, outPoint) = EditSession.clampTrim(
            in: 0, out: 10, minSpan: ClipTrimMath.minimumSourceSpan(speed: 1.5), newIn: 9.9, newOut: nil, duration: 10)
        #expect(abs(inPoint - 9.85) < 1e-9)
        #expect(outPoint == 10)

        let pushed = EditSession.clampTrim(
            in: 1, out: 2, minSpan: ClipTrimMath.minimumSourceSpan(speed: 2), newIn: nil, newOut: 1.05, duration: 10)
        #expect(abs(pushed.0 - 1) < 1e-9)
        #expect(abs(pushed.1 - 1.2) < 1e-9)
    }

    @Test func wholeSecondsAndTheEndsTickOnce() {
        #expect(ClipTrimMath.crossedWholeSecond(from: 0.9, to: 1.1))
        #expect(ClipTrimMath.crossedWholeSecond(from: 2.2, to: 1.4))
        #expect(!ClipTrimMath.crossedWholeSecond(from: 1.1, to: 1.8))
        #expect(!ClipTrimMath.crossedWholeSecond(from: 1, to: 1))
        #expect(!ClipTrimMath.crossedWholeSecond(from: .nan, to: 1))

        #expect(ClipTrimMath.arrivedAtBound(from: 0.2, to: 0, low: 0, high: 8.6))
        #expect(ClipTrimMath.arrivedAtBound(from: 8.4, to: 8.6, low: 0, high: 8.6))
        #expect(!ClipTrimMath.arrivedAtBound(from: 0, to: 0, low: 0, high: 8.6))
        #expect(!ClipTrimMath.arrivedAtBound(from: 3, to: 3.4, low: 0, high: 8.6))
    }

    @Test func theReadoutIsInSourceSeconds() {
        #expect(ClipTrimMath.readout(in: 3.2, out: 11.8) == "0:03.2 – 0:11.8 · 8.6 s")
        #expect(ClipTrimMath.readout(in: 0, out: 65) == "0:00.0 – 1:05.0 · 65.0 s")
        #expect(ClipTrimMath.readout(in: 1, out: 1) == "0:01.0 – 0:01.0 · 0.0 s")
        // A span that is not a clean tenth still rounds: 8.64 s → 8.6 s, and the clocks match.
        #expect(ClipTrimMath.clockTenths(11.84) == "0:11.8")
        #expect(ClipTrimMath.spanText(8.64) == "8.6 s")
        #expect(ClipTrimMath.readout(in: .nan, out: -4) == "0:00.0 – 0:00.0 · 0.0 s")
    }
}

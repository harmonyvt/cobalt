import Foundation

/// Pixel, zoom and readout math for the editor's clip trim. In and out are source seconds.
/// The strip sends those seconds to `EditSession.trim`, which clamps with `clampTrim`
/// (`minimumSourceSpan` keeps 0.1 s of output) and records one undo step for a drag.
public enum ClipTrimMath {
    public static let minimumZoom = 1.0
    public static let maximumZoom = 8.0
    /// The chips. Pinch and ⌘-scroll land anywhere in `minimumZoom...maximumZoom`.
    public static let zoomStops: [Double] = [1, 2, 4, 8]
    /// How close a time is to a bound before a drag counts as hitting it (source seconds).
    /// Trim times are stored to the millisecond, so this is wider than one rounding step.
    public static let boundEpsilon = 0.002

    /// The source range a zoomed strip shows. `span` is `duration / zoom`, centred on `anchor`,
    /// and kept inside the file.
    public struct Window: Equatable, Sendable {
        public var start: Double
        public var span: Double
        public var end: Double { start + span }

        public init(start: Double, span: Double) {
            self.start = start
            self.span = span
        }
    }

    public static func clampedZoom(_ zoom: Double) -> Double {
        let z = zoom.isNaN ? minimumZoom : zoom      // +inf clamps to the maximum, -inf to the minimum
        return min(maximumZoom, max(minimumZoom, z))
    }

    /// Source seconds a trim must keep so the clip stays at least 0.1 s of output.
    /// Matches `EditSession.trim`: `0.1 * max(1, speed)`. A slow clip still keeps 0.1 s of source.
    public static func minimumSourceSpan(speed: Double) -> Double {
        0.1 * max(1, speed.isFinite ? speed : 1)
    }

    public static func clampedPlayhead(_ time: Double, duration: Double) -> Double {
        let limit = max(0, duration.isFinite ? duration : 0)
        let t = time.isFinite ? time : 0
        return min(limit, max(0, t))
    }

    public static func window(duration: Double, zoom: Double, anchor: Double) -> Window {
        let d = max(0.001, duration.isFinite ? duration : 0.001)
        let span = d / clampedZoom(zoom)
        let center = anchor.isFinite ? anchor : 0
        var start = center - span / 2
        if start < 0 { start = 0 }
        if start + span > d { start = d - span }
        if start < 0 { start = 0 }
        return Window(start: start, span: min(span, d))
    }

    /// Source time under a point `x` on a strip `width` points wide showing `window`.
    public static func seconds(atX x: Double, width: Double, window: Window) -> Double {
        guard width > 0, width.isFinite, x.isFinite else { return window.start }
        let fraction = min(1, max(0, x / width))
        return window.start + fraction * window.span
    }

    /// The point for a source time. Off-window times land on the nearer edge.
    public static func x(forSeconds seconds: Double, width: Double, window: Window) -> Double {
        guard width > 0, width.isFinite, window.span > 0, seconds.isFinite else { return 0 }
        let fraction = (seconds - window.start) / window.span
        return min(width, max(0, fraction * width))
    }

    /// Source seconds a drag of `points` covers. `span` is the window at the start of the drag,
    /// so the handle stays 1:1 with the finger while the window is held still.
    public static func seconds(moved points: Double, width: Double, span: Double) -> Double {
        guard width > 0, width.isFinite, points.isFinite, span.isFinite else { return 0 }
        return points / width * span
    }

    /// True when `previous` and `next` sit on different whole seconds (a haptic tick).
    public static func crossedWholeSecond(from previous: Double, to next: Double) -> Bool {
        guard previous.isFinite, next.isFinite else { return false }
        return Int(floor(previous)) != Int(floor(next))
    }

    /// True the moment `next` lands on `low` or `high` and `previous` was not already there.
    public static func arrivedAtBound(from previous: Double, to next: Double, low: Double, high: Double) -> Bool {
        guard previous.isFinite, next.isFinite else { return false }
        func on(_ bound: Double) -> Bool { bound.isFinite && abs(next - bound) <= boundEpsilon }
        func was(_ bound: Double) -> Bool { bound.isFinite && abs(previous - bound) <= boundEpsilon }
        if on(low), !was(low) { return true }
        if abs(high - low) > boundEpsilon, on(high), !was(high) { return true }
        return false
    }

    /// "0:03.2 – 0:11.8 · 8.6 s". The two clocks are source in and out; the last number is the source span.
    public static func readout(in inPoint: Double, out outPoint: Double) -> String {
        let start = inPoint.isFinite ? max(0, inPoint) : 0
        let end = outPoint.isFinite ? max(start, outPoint) : start
        return "\(clockTenths(start)) – \(clockTenths(end)) · \(spanText(end - start))"
    }

    /// "0:09.0", "0:11.8", "1:05.0". Tenths, rounded, never negative.
    public static func clockTenths(_ seconds: Double) -> String {
        let tenths = max(0, Int((seconds.isFinite ? seconds * 10 : 0).rounded()))
        let whole = tenths / 10
        return "\(whole / 60):" + two(whole % 60) + ".\(tenths % 10)"
    }

    /// "8.6 s". One decimal, rounded.
    public static func spanText(_ seconds: Double) -> String {
        let tenths = max(0, Int((seconds.isFinite ? seconds * 10 : 0).rounded()))
        return "\(tenths / 10).\(tenths % 10) s"
    }

    private static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}

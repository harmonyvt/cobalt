import Foundation

// The maths behind the timeline's feel (apple/CONTRACT-EDITOR.md 15.5): coalesced seeks, the fling after a scrub, the tick
// on a clip edge, snapping a trimmed edge, and how tall each lane is. All pure, so the views only measure points and
// pass them in.

// MARK: - coalesced seeks

/// One seek the picture should make. `exact` is false while the finger is down (any nearby frame will do, so the picture
/// keeps up) and true for the last one (the frame the finger stopped on).
public struct ScrubSeek: Equatable, Sendable {
    public var frame: Int
    public var exact: Bool

    public init(frame: Int, exact: Bool) {
        self.frame = frame
        self.exact = exact
    }
}

/// Decides which seeks reach the player while a finger scrubs: at most one in flight, the newest target waits and wins, and
/// letting go always ends with an exact seek on the frame the finger stopped on.
///
/// Usage: `request` on every move, `release` when the finger lifts (or a fling ends), and `landed` when the seek that was
/// handed out finishes; each returns the seek to start now, if any.
public struct SeekCoalescer: Sendable {
    /// The seek the player is working on.
    public private(set) var inFlight: ScrubSeek?
    /// The one that goes next. Only the newest target is ever kept.
    public private(set) var pending: ScrubSeek?
    /// The frame the last handed-out seek went to (nil before the first).
    public private(set) var lastFrame: Int?
    private var lastExact = false

    public init() {}

    /// A new scrub starts: whatever was waiting from the last one is dropped. A seek already in flight is left alone.
    public mutating func begin() {
        pending = nil
    }

    /// The scrub moved to `frame`.
    public mutating func request(frame: Int) -> ScrubSeek? {
        if inFlight != nil {
            // the newest target replaces the waiting one; an exact one waiting for this same frame stays exact
            if let waiting = pending, waiting.exact, waiting.frame == frame { return nil }
            pending = ScrubSeek(frame: frame, exact: false)
            return nil
        }
        // the picture is already on that frame (a tolerant seek is good enough while the finger is down)
        if frame == lastFrame { return nil }
        return start(ScrubSeek(frame: frame, exact: false))
    }

    /// The finger lifted on `frame`: one exact seek, now or as soon as the one in flight lands.
    public mutating func release(frame: Int) -> ScrubSeek? {
        let exact = ScrubSeek(frame: frame, exact: true)
        if let current = inFlight {
            if current == exact { pending = nil } else { pending = exact }
            return nil
        }
        if frame == lastFrame, lastExact { return nil }
        return start(exact)
    }

    /// The seek in flight landed (or was cancelled). Returns the next one to start.
    public mutating func landed() -> ScrubSeek? {
        let done = inFlight
        inFlight = nil
        guard let next = pending else { return nil }
        pending = nil
        // the same frame again, and not needing to be exact: nothing to do
        if !next.exact, next.frame == done?.frame { return nil }
        return start(next)
    }

    /// Forgets everything (the player was rebuilt, or the editor closed).
    public mutating func reset() {
        self = SeekCoalescer()
    }

    private mutating func start(_ seek: ScrubSeek) -> ScrubSeek {
        inFlight = seek
        lastFrame = seek.frame
        lastExact = seek.exact
        return seek
    }
}

// MARK: - fling

/// What a scrub does after the finger lifts: the speed decays the way a scroll view's does (0.998 per millisecond, so it
/// falls to 1/e in about half a second) and the playhead stops at 0 or the end. Times are seconds since release; positions
/// are seconds of output.
public struct TimelineFling: Equatable, Sendable {
    /// The scroll view's decay rate per millisecond.
    public static let decayPerMillisecond = 0.998
    /// Slower than this (seconds of output per second, about a quarter of a frame per frame) is a stop.
    public static let defaultStopSpeed = 0.05

    public let origin: Double
    public let velocity: Double
    public let lower: Double
    public let upper: Double
    /// The decay constant: speed is `velocity * exp(-rate * t)`.
    public let rate: Double
    /// Seconds after release until it stops, at a bound or by slowing down.
    public let duration: Double

    /// `velocity` is seconds of output per second, signed (a finger swiping left plays forward: positive).
    public init(
        position: Double, velocity: Double, bounds: ClosedRange<Double>,
        decayPerMillisecond: Double = TimelineFling.decayPerMillisecond, stopSpeed: Double = TimelineFling.defaultStopSpeed
    ) {
        let low = bounds.lowerBound.isFinite ? bounds.lowerBound : 0
        let high = bounds.upperBound.isFinite ? max(low, bounds.upperBound) : low
        let start = position.isFinite ? min(max(low, position), high) : low
        let speed = velocity.isFinite ? velocity : 0
        let decay = min(0.99999, max(0.5, decayPerMillisecond))
        let rate = -1000 * log(decay)
        self.origin = start
        self.velocity = speed
        self.lower = low
        self.upper = high
        self.rate = rate

        let slow = max(1e-9, stopSpeed)
        guard abs(speed) > slow else {
            duration = 0
            return
        }
        // the time the speed falls to the stop speed
        var stops = log(abs(speed) / slow) / rate
        // the time a bound is reached, when the unbroken glide would pass it
        let target = speed > 0 ? high : low
        let travel = (target - start) * rate / speed        // 1 - exp(-rate t) = travel
        if travel < 1 {
            let reach = travel <= 0 ? 0 : -log(1 - travel) / rate
            stops = min(stops, reach)
        }
        duration = max(0, stops)
    }

    /// Where the playhead is `t` seconds after release.
    public func position(at t: Double) -> Double {
        let time = min(max(0, t.isFinite ? t : 0), duration)
        let travelled = velocity * (1 - exp(-rate * time)) / rate
        return min(max(lower, origin + travelled), upper)
    }

    /// Seconds of output per second at `t` (zero once finished).
    public func velocity(at t: Double) -> Double {
        guard t < duration else { return 0 }
        return velocity * exp(-rate * max(0, t))
    }

    public func isFinished(at t: Double) -> Bool { t >= duration }

    /// Where it comes to rest.
    public var restingPosition: Double { position(at: duration) }
}

// MARK: - clip edges

public enum TimelineEdges {
    /// Every clip start and end, in seconds, sorted, with the ones within a millisecond merged.
    public static func edges(of spans: [(start: Double, end: Double)]) -> [Double] {
        var all: [Double] = []
        for span in spans {
            if span.start.isFinite { all.append(span.start) }
            if span.end.isFinite { all.append(span.end) }
        }
        all.sort()
        var merged: [Double] = []
        for value in all where merged.last.map({ value - $0 > 0.001 }) ?? true { merged.append(value) }
        return merged
    }

    /// The playhead went from `previous` to `current` and passed over an edge (or landed on one). Moving forward an edge
    /// counts when `previous < edge <= current`, backward when `current <= edge < previous`, so a tick happens once however
    /// the playhead settles on it. Many edges in one step are still one crossing.
    public static func crossed(from previous: Double, to current: Double, edges: [Double]) -> Bool {
        guard previous.isFinite, current.isFinite, previous != current else { return false }
        if current > previous { return edges.contains { $0 > previous && $0 <= current } }
        return edges.contains { $0 >= current && $0 < previous }
    }
}

// MARK: - trim snapping

public enum TimelineTrimSnap {
    /// A trimmed clip's end sits at `end` (output seconds) and the finger asks to move it by `delta`. Within `threshold`
    /// seconds of a point (the playhead, a neighbouring clip's edge, 0, the end of the edit) it lands on that point.
    /// Returns the delta to use and the point it snapped to, nil when it did not.
    public static func snap(end: Double, delta: Double, points: [Double], threshold: Double) -> (delta: Double, point: Double?) {
        guard end.isFinite, delta.isFinite else { return (0, nil) }
        guard threshold > 0 else { return (delta, nil) }
        let wanted = end + delta
        var best: Double?
        for point in points where point.isFinite {
            if abs(point - wanted) <= threshold, abs(point - wanted) < abs((best ?? .infinity) - wanted) { best = point }
        }
        guard let best else { return (delta, nil) }
        return (best - end, best)
    }
}

// MARK: - lane heights

/// How the timeline slot is shared between the lanes (15.1): every lane is at least 40 pt; lane 0 and the lanes with a
/// keyed or large clip grow first, up to 130 pt; the rest then grow a little; past the slot's height the stack scrolls.
public struct TimelineLaneLayout: Equatable, Sendable {
    public static let minimum = 40.0
    public static let priorityMaximum = 130.0
    /// How far a lane without a keyed or large clip grows once the others are full.
    public static let otherMaximum = 72.0

    /// Height of each lane, indexed by lane number (lane 0 first).
    public let heights: [Double]
    /// Distance from the top of the stack to the top of each lane. The highest lane is drawn first, so it is at 0.
    public let tops: [Double]
    public let contentHeight: Double
    /// The stack is taller than the slot: it scrolls vertically.
    public let scrolls: Bool

    /// `priority[n]`: lane `n` is lane 0, or holds a keyed or large clip.
    public init(available: Double, priority: [Bool]) {
        let count = priority.count
        let room = available.isFinite ? max(0, available) : 0
        var heights = [Double](repeating: Self.minimum, count: count)
        var spare = room - Self.minimum * Double(count)
        if spare > 0, count > 0 {
            spare = Self.grow(&heights, where: { priority[$0] }, to: Self.priorityMaximum, spare: spare)
            _ = Self.grow(&heights, where: { !priority[$0] }, to: Self.otherMaximum, spare: spare)
        }
        self.heights = heights
        var tops = [Double](repeating: 0, count: count)
        var y = 0.0
        for lane in stride(from: count - 1, through: 0, by: -1) {
            tops[lane] = y
            y += heights[lane]
        }
        self.tops = tops
        self.contentHeight = y
        self.scrolls = y > room + 0.5
    }

    /// The lane under `y` (measured from the top of the stack). A y above the stack is the highest lane, below it lane 0.
    public func lane(atY y: Double) -> Int {
        guard !heights.isEmpty else { return 0 }
        for lane in stride(from: heights.count - 1, through: 0, by: -1) where y < tops[lane] + heights[lane] { return lane }
        return 0
    }

    /// Raises the chosen lanes by the same amount, to at most `limit`, using up to `spare`. Returns what is left.
    private static func grow(_ heights: inout [Double], where chosen: (Int) -> Bool, to limit: Double, spare: Double) -> Double {
        let lanes = heights.indices.filter(chosen)
        guard !lanes.isEmpty, spare > 0 else { return spare }
        let each = min(limit - minimum, spare / Double(lanes.count))
        for lane in lanes { heights[lane] = minimum + each }
        return spare - each * Double(lanes.count)
    }
}

import Foundation

// Where a clip lands when it is dragged across the equal-lane timeline (section 69). Pure geometry: the views measure
// points and seconds, and these functions answer the lane, the new-lane zone and the snapped time. Lane 0 is the bottom
// row. The dashed "+ new lane" zone sits above the top lane.

public enum LaneDropTarget: Equatable, Sendable {
    /// A lane that is already drawn. 0 is the bottom.
    case lane(Int)
    /// The zone above the top lane.
    case newLane

    public var lane: Int? {
        if case .lane(let number) = self { return number }
        return nil
    }
}

public enum EditLaneDrop {
    /// `y` is measured from the top of the lane stack. `0 ..< zoneHeight` is the new-lane zone. Under it the lanes run
    /// from the highest down to lane 0, each `rowHeight` tall. Past the last row stays on lane 0. A y above the stack,
    /// or a stack with no lanes, is the new-lane zone.
    public static func hit(y: Double, laneCount: Int, rowHeight: Double, zoneHeight: Double) -> LaneDropTarget {
        let lanes = max(0, laneCount)
        guard lanes > 0, y.isFinite, y >= zoneHeight else { return .newLane }
        let row: Int
        if rowHeight > 0 {
            row = max(0, Int(((y - zoneHeight) / rowHeight).rounded(.down)))
        } else {
            row = 0
        }
        return .lane(min(lanes - 1, max(0, lanes - 1 - row)))
    }

    /// Moves `start` so that the clip's start, or its end (`start + length`), lands on the nearest point within
    /// `threshold` seconds. Points are the playhead, 0, the edit's end and other clips' edges. The result is never
    /// negative. `snapped` is false when nothing was close enough.
    public static func snap(
        start: Double, length: Double, points: [Double], threshold: Double
    ) -> (value: Double, snapped: Bool) {
        guard start.isFinite else { return (0, false) }
        let span = length.isFinite ? length : 0
        guard threshold > 0 else { return (max(0, start), false) }
        var best: Double?
        for edge in [start, start + span] {
            for point in points where point.isFinite {
                let delta = point - edge
                if abs(delta) <= threshold, abs(delta) < abs(best ?? .infinity) { best = delta }
            }
        }
        guard let best else { return (max(0, start), false) }
        return (max(0, start + best), true)
    }

    /// A new lane can open above `lane` while every occupied lane stays under `limit` (64).
    public static func canInsertLane(above lane: Int, occupied: [Int], limit: Int = EditLanes.laneLimit) -> Bool {
        guard lane >= 0, lane + 1 < limit else { return false }
        return !occupied.contains { $0 > lane && $0 + 1 >= limit }
    }

    /// How far to nudge a scroll while the finger sits within `edge` of either side of `viewport`. Negative is toward
    /// the start (left, or up). Zero when the finger is in the middle, or the numbers are not usable.
    public static func autoscroll(position: Double, viewport: Double, edge: Double, step: Double) -> Double {
        guard viewport > 0, edge > 0, step > 0, position.isFinite, viewport.isFinite else { return 0 }
        if position < edge { return -step }
        if position > viewport - edge { return step }
        return 0
    }
}

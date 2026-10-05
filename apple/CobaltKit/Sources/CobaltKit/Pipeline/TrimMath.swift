import Foundation

/// The trim bracket's math, pinned from `Main.dc.html` `moveDrag` / `endDrag` / `nudge`.
/// D is the clip's duration, L the longest webp, 0.5 s the shortest.
enum TrimMath {
    static let minimumLength = 0.5
    static let rubberBand = 0.25

    static func drag(
        _ handle: TrimHandle, to t: Double, from range: TrimRange, duration D: Double, limit L: Double
    ) -> (range: TrimRange, over: Bool) {
        var a = range.start
        var b = range.end
        var over = false
        switch handle {
        case .start:
            a = max(0, min(t, b - minimumLength))
            if b - a > L {
                let excess = (b - a) - L
                a = b - L - excess * rubberBand
                over = true
            }
        case .end:
            b = min(D, max(t, a + minimumLength))
            if b - a > L {
                let excess = (b - a) - L
                b = a + L + excess * rubberBand
                over = true
            }
        case .span:
            let len = b - a
            a = max(0, min(t, D - len))
            b = a + len
        }
        return (TrimRange(start: a, end: b), over)
    }

    /// Release: if over, the handle that moved snaps to exactly L from the other one.
    static func release(_ range: TrimRange, moved: TrimHandle?, limit L: Double) -> TrimRange {
        var a = range.start
        var b = range.end
        if b - a > L {
            if moved == .start { a = b - L } else { b = a + L }
        }
        return TrimRange(start: a, end: b)
    }

    static func nudge(
        _ handle: TrimHandle, by step: Double, from range: TrimRange, duration D: Double, limit L: Double
    ) -> (range: TrimRange, hitLimit: Bool) {
        var a = range.start
        var b = range.end
        var hit = false
        switch handle {
        case .start:
            a = max(0, min(a + step, b - minimumLength))
            if b - a > L { a = b - L; hit = true }
        case .end:
            b = min(D, max(b + step, a + minimumLength))
            if b - a > L { b = a + L; hit = true }
        case .span:
            let len = b - a
            a = max(0, min(a + step, D - len))
            b = a + len
        }
        return (TrimRange(start: a, end: b), hit)
    }
}

import CobaltKit
import SwiftUI

// The orbit's geometry: 2D rainbow arcs (CONTRACT-ORBIT section 1, the owner's pick "2d · option c"),
// with ORBIT E, "orbits that grow" (CONTRACT-MEDIA, the owner's own idea): today's arcs at every count,
// with fewer bands below 10 media. 1-3 media share one orbit, then a new orbit every two more (4-5: 2,
// 6-7: 3, 8-9: 4); from 10 on it is exactly today's plan.
//
// Flat and top-down: concentric semicircular bands centred on the two glass circles, like a rainbow
// fanned over them. Each band is a conveyor: planets glide along the arc from one end to the other
// and fade back in at the start, so nothing is parked off screen. Inner bands are faster, neighbouring
// bands run opposite ways (one constant), size depends on the band only, inner bands draw on top.
//
// The maths is a port of the design generators: `RainbowArcsGeometry` is the 2D engine of `gen.js`
// (GEOM2.c and G2_COMMON: `ringPlan`, `capFn`, `cEnd`, `cT`, `cSlot`, `okLo`/`okHi`, `roomR`, `slotAt`),
// and the growth below 10 is `ePlan`, `part`, `eArc`, `layE` and E's `step` easing from
// `Sparse-E.dc.html`. Everything here is a pure function of size, centre, the entries, their history
// (`OrbitDynamics`, closed-form: no state ticks) and the clock.
//
// THE SWAP POINT: `RainbowArcsGeometry.growsWithCount` is the whole of orbit E's plan. `false` is
// today's plan at every count (the transitions still apply); a different geometry replaces
// `CurrentOrbitGeometry`.

/// One planet's place on a given frame.
struct OrbitSlot: Identifiable {
    let index: Int          // into the scene's entries (0 = newest); -1 for a planet that is leaving
    let entry: String       // the entry's id: a media id, or the reserved focus slot
    let ring: Int           // 0 = innermost band
    let position: CGPoint
    let fit: CGFloat        // the box the thumbnail fits at scale 1
    let dims: CGSize        // the picture's own shape (eases when the face changes shape)
    let scale: CGFloat      // by band only (eases when a planet changes band)
    let opacity: Double     // the conveyor's fade at the ends of the band, and arrivals and departures
    let z: Double           // inner bands on top
    var id: String { entry }

    /// The box the picture fills at scale 1.
    var box: CGSize { RainbowArcsGeometry.box(width: dims.width, height: dims.height, fit: fit) }
}

/// A faint hairline: a band (the planets' path) or a lane (a fainter line either side of it).
struct OrbitGuide {
    let path: Path
    let isLane: Bool
}

/// What the orbit knows about one entry: its id and the shape of its picture (a planet's box follows
/// the face's real aspect, and springs to the new one when the face changes).
struct OrbitEntry: Equatable {
    var id: String
    var width: CGFloat = 720
    var height: CGFloat = 1280
}

/// What eases around the geometry while the star lives and a planet is born (all closed-form, see
/// `OrbitDynamics`): the star makes room by parting the bands around it (the star sits at the visual
/// centre of the orbit area, CONTRACT-ORBIT 1b), the newest band is held so the newborn lands in view,
/// a failed star shoves the innermost band, and when a planet or a band is added or removed the radii
/// and the planets' box ease from where they were.
struct OrbitTuning: Equatable {
    /// 1 at rest, up to 1.32 while the star reads: how much of the star's clearance is open, `(room - 1) / 0.32`.
    var room: CGFloat = 1
    /// How far above the circles' midpoint the star sits (nil: no star, so nothing to part around).
    var starDistance: CGFloat?
    /// Phase offset of band 0 (a fraction of a lap), moved while a planet is born.
    var offset0: Double = 0
    /// Multiplier on band 0's radius (the failure shockwave).
    var push: CGFloat = 1
    /// Each band's radius minus where it settles, easing to 0 when the plan changed (radii glide, rate 4 / s).
    var ringOffset: [CGFloat] = []
    /// The planets' box minus where it settles, easing to 0 when the count changed (rate 5.5 / s).
    var fitLag: CGFloat = 0
}

/// A planet's slot on the plan: the band, its place on it, how many share the band, how many bands
/// there are (`pk` of the reference: when it changes the planet moves).
struct OrbitSlotKey: Hashable {
    var ring: Int
    var j: Int
    var m: Int
    var rings: Int
}

/// Where the conveyor itself puts a slot at one moment (before any transition is applied).
struct OrbitPose {
    let key: OrbitSlotKey
    let radius: CGFloat
    let angle: CGFloat
}

/// THE SEAM. Everything about where the planets are lives behind this protocol.
protocol OrbitGeometry {
    init(size: CGSize, center: CGPoint, count: Int, topInset: CGFloat, tuning: OrbitTuning)
    /// How many items the design shows at most (older ones are not drawn).
    static var maxItems: Int { get }
    var size: CGSize { get }
    var bandCount: Int { get }
    /// The thumbnail box of the nearest planet as drawn now: the star morphs into one this size.
    var nearFit: CGFloat { get }
    /// A planet's slot on the plan, and where the conveyor puts it.
    func key(at index: Int) -> OrbitSlotKey
    func pose(at index: Int, time: Double) -> OrbitPose
    /// The conveyor's fade of a planet that sits at `angle` on the band of `key`.
    func fade(_ key: OrbitSlotKey, angle: CGFloat) -> Double
    func point(radius: CGFloat, angle: CGFloat) -> CGPoint
    /// Where a planet leaving its band holds: its angle, kept on screen on the band it is going to.
    func holdAngle(_ angle: CGFloat, in key: OrbitSlotKey) -> CGFloat
    /// While the star lives its rings must not be covered: a box (centre, half-size) that would touch the star is
    /// moved straight away from it, only as far as it takes to clear.
    func dodge(_ centre: CGPoint, half: CGSize) -> CGPoint
    /// A band's scale (inner = newest = slightly larger).
    func scale(ring: Int) -> CGFloat
    /// The radii the bands settle at, as drawn now, and as drawn now without the easing of a plan change.
    func bandRadii() -> [CGFloat]
    func targetRadii() -> [CGFloat]
    /// The newest slot's phase on band 0, and the window in which it is in the open part of its band.
    func phase0(time: Double) -> Double
    var newestWindow: ClosedRange<Double> { get }
    /// A band's hairline and its two lanes, drawn from the apex outward up to `draw` (0...1).
    func guides(ring: Int, draw: Double) -> [OrbitGuide]
    func guides(radius: CGFloat, lane: CGFloat, draw: Double) -> [OrbitGuide]
}

extension OrbitGeometry {
    /// The three items nearest the viewer that are on screen: the ones that get a real player.
    func frontEntries(_ slots: [OrbitSlot], limit: Int = 3) -> [String] {
        slots
            .filter { $0.opacity >= 0.9 && $0.position.x > 0 && $0.position.x < size.width && $0.position.y > 0 && $0.position.y < size.height }
            .sorted { $0.z > $1.z }
            .prefix(limit).map(\.entry)
    }

    /// The topmost tappable item under `point`. Planets that have faded out at the end of their band are
    /// not tappable (opacity < 0.5), as in the design harness; neither is one that is leaving.
    func hit(_ point: CGPoint, slots: [OrbitSlot]) -> String? {
        for slot in slots.sorted(by: { $0.z > $1.z }) where slot.opacity >= 0.5 && slot.index >= 0 {
            let box = slot.box
            let w = box.width * slot.scale, h = box.height * slot.scale
            let rect = CGRect(x: slot.position.x - w / 2, y: slot.position.y - h / 2, width: w, height: h)
            if rect.contains(point) { return slot.entry }
        }
        return nil
    }
}

typealias CurrentOrbitGeometry = RainbowArcsGeometry

struct RainbowArcsGeometry: OrbitGeometry {
    static let maxItems = 35
    /// THE one constant (CONTRACT-ORBIT section 1): neighbouring bands run opposite ways. `false`
    /// makes every band run the same way.
    static let alternatesDirection = true
    /// Pixels per second along the inner band at unit scale; outer bands go slower (~ 1 / sqrt(radius)).
    /// Slow enough that a planet can be tapped deliberately (halved from 7.5, owner's live run).
    static let innerSpeed: Double = 3.75

    // MARK: orbit E

    /// ORBIT E (CONTRACT-MEDIA): fewer bands below `growsBelow` media. `false` = today's plan at every count.
    static let growsWithCount = true
    static let growsBelow = 10
    /// The planet box (in the design's units, times `unit / 0.94`) by count, the bands by count, where the
    /// innermost band sits by band count, and how many planets each band carries: `FIT`, `RINGS`, `INNER`
    /// and `COUNTS` of `ePlan`. 1-3 media: one orbit with the box 220 -> 165 -> 122; a new orbit every 2 more.
    static let growFit: [CGFloat] = [220, 220, 165, 122, 116, 110, 104, 97, 91, 86]
    static let growRings = [1, 1, 1, 1, 2, 2, 3, 3, 4, 4]
    static let growInner: [CGFloat] = [0, 300, 215, 175, 150]
    static let growCounts = [[0], [1], [2], [3], [3, 1], [3, 2], [3, 2, 1], [3, 2, 2], [3, 2, 2, 1], [3, 2, 2, 2]]

    let size: CGSize
    let center: CGPoint
    let count: Int
    let topInset: CGFloat
    let tuning: OrbitTuning

    /// The design unit: the mock's phone is 368 pt wide (k = 1); this window scales it.
    let unit: CGFloat
    /// Inner band radius, outer band radius (the plan's, which sets how speed falls off), and the
    /// half-width the bands run to.
    let r0: CGFloat
    let top: CGFloat
    let edge: CGFloat
    /// How far above the circles' midpoint the inner bands stop.
    let bottom: CGFloat
    let plan: Plan
    /// The box a planet on band 0 fits at scale 1 once the count has settled (bigger when there are few,
    /// smaller when there are many).
    let fitSettled: CGFloat
    /// The bands' resting radii, where the star has parted them to, and as drawn (the easing of a plan
    /// change added).
    let baseRadii: [CGFloat]
    let target: [CGFloat]
    let radii: [CGFloat]

    struct Plan: Equatable {
        let rings: Int
        let counts: [Int]
    }

    init(size: CGSize, center: CGPoint, count: Int, topInset: CGFloat = 60, tuning: OrbitTuning = OrbitTuning()) {
        self.size = size
        self.center = center
        self.topInset = topInset
        let n = min(count, Self.maxItems)
        self.count = n
        self.tuning = tuning
        let edge = max(120, min(center.x, size.width - center.x))
        // the planets' top edge stays under the bar: the available radius, in the mock's units
        let available = max(200, center.y - topInset - 6)
        let k = min(1.2, max(0.8, min(edge / 184, available / 559)))
        self.unit = k
        self.edge = edge
        self.bottom = 26 * k
        let grows = Self.growsWithCount && n < Self.growsBelow
        let base: [CGFloat]
        let fit: CGFloat
        let plan: Plan
        if grows {
            // `ePlan`: the box scales with the unit of the 10-media plan (k / 0.94), the outermost band keeps
            // the planets' top edge under the bar, the innermost sits by how many bands there are
            let u = k / 0.94
            fit = Self.growFit[n] * u
            let rings = Self.growRings[n]
            let inner = Self.growInner[rings] * u
            let outer = available - 0.5 * fit
            base = (0..<rings).map { rings == 1 ? inner : inner + CGFloat($0) * (outer - inner) / CGFloat(rings - 1) }
            plan = Plan(rings: rings, counts: Self.growCounts[n])
            self.r0 = base[0]
            self.top = base[rings - 1]
        } else {
            let r0 = 144 * k
            fit = Self.bx(n) * Self.sparse(n) * k
            let top = max(r0 + 40, available - 0.5 * fit)
            plan = Self.makePlan(n: n, fit: fit, unit: k, r0: r0, top: top, edge: edge, bottom: 26 * k)
            base = (0..<plan.rings).map { plan.rings <= 1 ? r0 : r0 + CGFloat($0) * (top - r0) / CGFloat(plan.rings - 1) }
            self.r0 = r0
            self.top = top
        }
        self.fitSettled = fit
        self.plan = plan
        self.baseRadii = base
        let rest = plan.rings <= 1 ? 0 : (base[plan.rings - 1] - base[0]) / CGFloat(plan.rings - 1)
        let open = min(1, max(0, (tuning.room - 1) / 0.32))
        let parted: [CGFloat]
        if grows && plan.rings <= 1 {
            // one orbit: it moves out of the star's way (the star's clearance and the planet box, 66 pt)
            if let d = tuning.starDistance, base[0] < d + 66 {
                parted = [base[0] + open * (d + 66 - base[0])]
            } else {
                parted = base
            }
        } else {
            // the star's clearance: as wide as the band spacing allows without opening a gap bigger than about
            // 1.5x the others (dense orbits, spacing ~80 pt, get 56 % of the spacing; sparse ones 68 %; the
            // growing orbits 60 %)
            let share = grows ? 0.6 : 0.56 + 0.12 * min(1, max(0, (rest / k - 73) / 18))
            parted = Self.part(base, around: tuning.starDistance, clearance: open * min(share * rest, 62 * k))
        }
        self.target = parted
        self.radii = parted.enumerated().map { i, r in r + (i < tuning.ringOffset.count ? tuning.ringOffset[i] : 0) }
    }

    // MARK: sizes

    /// More media: slightly smaller planets, so 35 still fit a phone at >= 36 pt on the short side.
    static func bx(_ n: Int) -> CGFloat {
        n <= 16 ? 78 : (78 - CGFloat(min(n, 35) - 16) * 8 / 19).rounded()
    }

    /// Few media: bigger planets (up to 1.3x at 3 items or fewer, 1 from 14 on), so a sparse orbit still
    /// fills the band spacing instead of leaving a hollow middle.
    static func sparse(_ n: Int) -> CGFloat { 1 + 0.3 * CGFloat(min(1, max(0, Double(14 - n) / 11))) }

    /// Band scale: a little smaller per band outward (inner = newest = slightly larger).
    static func sC(_ ring: Int) -> CGFloat { 1 - 0.016 * CGFloat(ring) }

    /// The box a planet on band 0 fits at scale 1, as drawn now (it eases when the count changes).
    var fit: CGFloat { fitSettled + tuning.fitLag }
    var nearFit: CGFloat { fit }
    var bandCount: Int { plan.rings }
    func scale(ring: Int) -> CGFloat { Self.sC(ring) }

    /// The box a picture of `width` x `height` fills inside `fit`.
    static func box(width w: CGFloat, height h: CGFloat, fit: CGFloat) -> CGSize {
        let k = min(fit / max(w, 1), fit / max(h, 1))
        return CGSize(width: (w * k).rounded(), height: (h * k).rounded())
    }

    // MARK: the plan (bands and how many planets each carries)

    /// The angle at which a band at radius `r` meets the screen edge (outer bands) or stops just above
    /// the circles (inner bands).
    private static func cEnd(_ r: CGFloat, edge: CGFloat, bottom: CGFloat) -> CGFloat {
        var a = asin(max(-1, min(1, bottom / r)))
        if r > edge { a = max(a, acos(edge / r)) }
        return a
    }

    private func cEnd(_ r: CGFloat) -> CGFloat { Self.cEnd(r, edge: edge, bottom: bottom) }

    private static func capacity(_ r: CGFloat, ring i: Int, fit: CGFloat, unit: CGFloat, edge: CGFloat, bottom: CGFloat) -> Int {
        let span = CGFloat.pi - 2 * cEnd(r, edge: edge, bottom: bottom)
        return max(1, Int((r * span / (fit * sC(i) + 6 * unit)).rounded(.down)))
    }

    /// How many bands from 10 media on (today's plan): the orbit area is always spread over its whole
    /// height, so a handful of media still gets a few bands (about two items per band, at least three, at
    /// most six) rather than one wide gap; more media need more bands only up to the capacity of what fits.
    private static func makePlan(n: Int, fit: CGFloat, unit: CGFloat, r0: CGFloat, top: CGFloat, edge: CGFloat, bottom: CGFloat) -> Plan {
        guard n > 0 else { return Plan(rings: 1, counts: [0]) }
        let kmax = max(1, min(6, 1 + Int(((top - r0) / (fit * 0.92 + 4 * unit)).rounded(.down))))
        let kmin = min(kmax, min(n, max(3, Int((Double(n) / 1.75).rounded(.up)))))
        var rings = kmin
        var caps: [Int] = []
        var sum = 0
        for k in kmin...kmax {
            rings = k
            caps = []
            sum = 0
            for i in 0..<k {
                let r = k <= 1 ? r0 : r0 + CGFloat(i) * (top - r0) / CGFloat(k - 1)
                let c = capacity(r, ring: i, fit: fit, unit: unit, edge: edge, bottom: bottom)
                caps.append(c)
                sum += c
            }
            if sum >= n { break }
        }
        var counts: [Int] = []
        var left = n
        var rem: [(Double, Int)] = []
        for i in 0..<rings {
            let q = sum > 0 ? Double(n) * Double(caps[i]) / Double(sum) : 0
            counts.append(Int(q.rounded(.down)))
            left -= counts[i]
            rem.append((q - Double(counts[i]), i))
        }
        rem.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        for i in 0..<max(0, left) { counts[rem[i % rings].1] += 1 }
        // every band carries at least one planet when there are enough to go round
        while n >= rings, let empty = counts.firstIndex(of: 0),
              let big = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[big] > 1 {
            counts[big] -= 1
            counts[empty] += 1
        }
        return Plan(rings: rings, counts: counts)
    }

    /// The bands' radii once the star has parted them: a band that would pass within `clearance` of the
    /// star (which sits `d` above the centre) moves to the edge of that clearance, and the bands on the
    /// same side are compressed (uniformly, never below 45 %) so the order, the outermost band and the
    /// even look are kept. Continuous in `clearance`, so it eases with the star.
    static func part(_ base: [CGFloat], around d: CGFloat?, clearance rho: CGFloat) -> [CGFloat] {
        guard let d, rho > 0.5, base.count > 1 else { return base }
        var out = base
        let j = base.filter { $0 < d }.count - 1
        let low = d - rho, high = d + rho
        if j >= 0, base[j] > low {
            if j >= 1 {
                let a = base[0], b = base[j]
                let nb = max(low, a + 0.45 * (b - a))
                for i in 0...j { out[i] = a + (base[i] - a) * (nb - a) / (b - a) }
            } else {
                out[0] = max(low, 0.8 * base[0])
            }
        }
        let last = base.count - 1
        if j + 1 <= last, base[j + 1] < high {
            if last > j + 1 {
                let a = base[j + 1], b = base[last]
                let na = min(high, b - 0.45 * (b - a))
                for i in (j + 1)...last { out[i] = b - (b - base[i]) * (b - na) / (b - a) }
            } else {
                out[last] = min(high, base[last] * 1.2)
            }
        }
        return out
    }

    private func ringIndex(_ idx: Int) -> (ring: Int, j: Int) {
        var c = 0
        for i in 0..<plan.rings {
            if idx < c + plan.counts[i] { return (i, idx - c) }
            c += plan.counts[i]
        }
        return (plan.rings - 1, idx - c + plan.counts[plan.rings - 1])
    }

    func key(at index: Int) -> OrbitSlotKey {
        let (ring, j) = ringIndex(max(0, index))
        return OrbitSlotKey(ring: ring, j: j, m: max(1, plan.counts[ring]), rings: plan.rings)
    }

    // MARK: radii and periods

    private func radius(_ ring: Int) -> CGFloat { radii[ring] * (ring == 0 ? tuning.push : 1) }

    /// Every band's radius as drawn right now (the shockwave on band 0 included): what the DEBUG audit measures.
    func bandRadii() -> [CGFloat] { (0..<plan.rings).map(radius) }

    /// Where the bands settle for this count and this star, before the easing of a plan change.
    func targetRadii() -> [CGFloat] { target }

    /// The mock's equivalent radius (146...520) of a real one, so speed falls off the same way.
    private func rp(_ r: CGFloat) -> Double { 146 + Double(r - r0) * 374 / Double(max(1, top - r0)) }

    /// Seconds for one pass of a band: its length at 7.5 pt/s on the inner band, slower further out.
    private func period(_ r: CGFloat) -> Double {
        let length = Double(r) * Double(CGFloat.pi - 2 * cEnd(r))
        return length / (Double(unit) * Self.innerSpeed * (146 / rp(r)).squareRoot())
    }

    // MARK: poses

    private func frac(_ x: Double) -> Double { x - x.rounded(.down) }
    private func smooth(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

    func phase0(time: Double) -> Double {
        let m0 = Double(max(1, plan.counts[0]))
        return frac(0.5 / m0 + time / period(baseRadii[0]) + tuning.offset0)
    }

    /// Newest slot early on the band, so the planets after it (one step ahead) are in view too.
    var newestWindow: ClosedRange<Double> {
        let m = Double(max(1, plan.counts[0]))
        let hi = max(0.12, min(0.55, 1 - 1 / m - 0.14))
        let lo = min(0.15, hi)
        return lo...hi
    }

    /// Where the conveyor puts the slot of entry `index`: on its band, at the angle the band has reached.
    func pose(at index: Int, time: Double) -> OrbitPose {
        let k = key(at: index)
        let r = radius(k.ring)
        let m = Double(k.m)
        let s = frac((Double(k.j) + 0.5) / m + 0.31 * Double(k.ring) + time / period(baseRadii[k.ring]) + (k.ring == 0 ? tuning.offset0 : 0))
        let ae = cEnd(r)
        let span = CGFloat.pi - 2 * ae
        let flip = Self.alternatesDirection && k.ring % 2 == 1
        let angle = flip ? CGFloat.pi - ae - CGFloat(s) * span : ae + CGFloat(s) * span
        return OrbitPose(key: k, radius: r, angle: angle)
    }

    func fade(_ key: OrbitSlotKey, angle: CGFloat) -> Double {
        let ae = cEnd(radius(key.ring))
        let span = CGFloat.pi - 2 * ae
        let flip = Self.alternatesDirection && key.ring % 2 == 1
        let sd = Double(flip ? (CGFloat.pi - ae - angle) / span : (angle - ae) / span)
        if sd <= 0 || sd >= 1 { return 0 }
        let e0 = min(0.5 / Double(key.m), 0.09)
        return smooth(sd / e0) * smooth((1 - sd) / e0)
    }

    func point(radius r: CGFloat, angle a: CGFloat) -> CGPoint {
        CGPoint(x: center.x + r * cos(a), y: center.y - r * sin(a))
    }

    /// The star's outermost accretion ring (`StarCanvas`: 20 + 3.6 x 8 = 48.8 pt) and a little air, at full growth.
    static let starRadius: CGFloat = 52

    func dodge(_ c: CGPoint, half: CGSize) -> CGPoint {
        guard let d = tuning.starDistance else { return c }
        let open = min(1, max(0, (tuning.room - 1) / 0.32))
        let rho = Self.starRadius * open
        guard rho > 0.5 else { return c }
        let s = CGPoint(x: center.x, y: center.y - d)
        func gap(_ p: CGPoint) -> CGFloat {
            hypot(max(abs(p.x - s.x) - half.width, 0), max(abs(p.y - s.y) - half.height, 0))
        }
        guard gap(c) < rho else { return c }
        // straight away from the star (up, when the box is right on it)
        var ux = c.x - s.x, uy = c.y - s.y
        let len = hypot(ux, uy)
        if len < 0.001 { ux = 0; uy = -1 } else { ux /= len; uy /= len }
        // the gap only grows along that line: find where it reaches the star's radius
        var lo: CGFloat = 0, hi = rho + hypot(half.width, half.height)
        for _ in 0..<22 {
            let mid = (lo + hi) / 2
            if gap(CGPoint(x: c.x + ux * mid, y: c.y + uy * mid)) < rho { lo = mid } else { hi = mid }
        }
        return CGPoint(x: c.x + ux * hi, y: c.y + uy * hi)
    }

    func holdAngle(_ angle: CGFloat, in key: OrbitSlotKey) -> CGFloat {
        let aeT = cEnd(baseRadii[key.ring])
        let margin = CGFloat(min(0.5 / Double(key.m), 0.09)) * (CGFloat.pi - 2 * aeT) * 1.3
        let lo = aeT + margin, hi = CGFloat.pi - aeT - margin
        return lo < hi ? max(lo, min(hi, angle)) : CGFloat.pi / 2
    }

    // MARK: guides

    /// A hairline that draws itself from the apex outward (`draw` 0...1), or the whole arc once drawn
    /// (`eArc`).
    private func arc(_ r: CGFloat, draw: Double) -> Path {
        let ae = cEnd(r)
        var path = Path()
        if draw >= 0.999 {
            let steps = 96
            for s in 0...steps {
                let a = ae + (CGFloat.pi - 2 * ae) * CGFloat(s) / CGFloat(steps)
                let p = point(radius: r, angle: a)
                if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path
        }
        guard draw > 0.001 else { return path }
        let steps = 48
        for end in [ae, CGFloat.pi - ae] {
            for s in 0...steps {
                let a = CGFloat.pi / 2 + (end - CGFloat.pi / 2) * CGFloat(draw) * CGFloat(s) / CGFloat(steps)
                let p = point(radius: r, angle: a)
                if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        return path
    }

    func guides(radius r: CGFloat, lane h: CGFloat, draw: Double) -> [OrbitGuide] {
        guard draw > 0.001 else { return [] }
        return [
            OrbitGuide(path: arc(r, draw: draw), isLane: false),
            OrbitGuide(path: arc(r - h, draw: draw), isLane: true),
            OrbitGuide(path: arc(r + h, draw: draw), isLane: true),
        ]
    }

    func guides(ring i: Int, draw: Double) -> [OrbitGuide] {
        guides(radius: radius(i), lane: fit * Self.sC(i) * 0.36, draw: draw)
    }
}

extension RainbowArcsGeometry {
    /// The same geometry with band 0's offset replaced (the hold is computed against the final offset).
    func withOffset(_ offset: Double) -> RainbowArcsGeometry {
        var t = tuning
        t.offset0 = offset
        return RainbowArcsGeometry(size: size, center: center, count: count, topInset: topInset, tuning: t)
    }
}

// MARK: - eased state

enum OrbitMath {
    static func smooth(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

    /// An angle difference wrapped into -pi...pi.
    static func wrap(_ d: CGFloat) -> CGFloat {
        var x = d
        while x > .pi { x -= 2 * .pi }
        while x < -.pi { x += 2 * .pi }
        return x
    }

    /// 1 -> 0, critically damped (no overshoot): `(1 + w t) e^(-w t)`. Done (0) long before it is asked for infinity.
    static func settle(_ dt: Double, _ w: Double) -> Double {
        guard dt < 30 else { return 0 }
        return (1 + w * max(0, dt)) * exp(-w * max(0, dt))
    }
}

/// `value(at:)` moves from `from` to `target` exponentially, starting at `since`: closed-form, so it is
/// a pure function of the wall clock and nothing has to tick to keep it running.
struct Eased: Equatable {
    var from: Double
    var target: Double
    var since: Double
    let rate: Double

    init(_ value: Double, rate: Double) {
        from = value
        target = value
        since = 0
        self.rate = rate
    }

    func value(at t: Double) -> Double { target + (from - target) * exp(-rate * max(0, t - since)) }

    mutating func retarget(_ new: Double, at t: Double, instant: Bool = false) {
        guard new != target else { return }
        from = instant ? new : value(at: t)
        target = new
        since = t
    }
}

/// The orbit's clock: orbit time advances at `speed` x wall time, and the speed eases (1 at rest, 0.3
/// behind a focused planet, 0 when paused), so the integral is closed-form too.
struct OrbitClock: Equatable {
    var base: Double = 0
    var since: Double = 0
    var from: Double = 1
    var target: Double = 1
    /// How quickly the speed eases (per second): 2.5 normally, fast when a finger holds the orbit still,
    /// gentle when it lets go.
    var rate = 2.5

    /// Orbit time 0 at wall time `now`, running at speed 1.
    init(now: Double = 0) { since = now }

    func speed(at t: Double) -> Double { target + (from - target) * exp(-rate * max(0, t - since)) }

    func time(at t: Double) -> Double {
        let dt = max(0, t - since)
        return base + target * dt + (from - target) * (1 - exp(-rate * dt)) / rate
    }

    mutating func retarget(speed new: Double, at t: Double, instant: Bool = false, rate newRate: Double? = nil) {
        guard new != target else { return }
        base = time(at: t)
        from = instant ? new : speed(at: t)
        target = new
        since = t
        rate = newRate ?? 2.5
    }

    /// Pins the orbit to a fixed time (the deterministic `-previewOrbitPaused` mode).
    mutating func freeze(at orbitTime: Double, now t: Double) {
        base = orbitTime
        since = t
        from = 0
        target = 0
    }
}

// MARK: - transitions (orbit E's `step`)

/// One planet's history on the plan. When its slot changes (a save arrives or leaves, the count needs
/// another band) it holds its angle for 0.3 s, then slides to the new slot over 1.6 s, so a planet that
/// changes orbit travels straight out (or in) first; its radius and its band scale ease from where they
/// were, and what the angle is short of the slide eases out (all closed-form, from `since`).
struct PlanetMotion: Equatable {
    var key: OrbitSlotKey
    var since = -Double.infinity
    var hold: CGFloat = 0
    var angleLag: CGFloat = 0
    var radiusLag: CGFloat = 0
    var scaleFrom: CGFloat = 1
    /// When it arrived: it fades and grows in.
    var born = -Double.infinity
    /// How long it holds its angle, then how long the slide takes. A planet that has to clear the slot a
    /// newborn is landing in does not hold, and slides in time to be gone when the newborn arrives.
    var holdFor = PlanetMotion.holdFor
    var slideFor = PlanetMotion.slideFor

    static let holdFor = 0.3
    static let slideFor = 1.6
    static let clearFor = 0.55
    static let radiusRate = 5.5
    static let angleRate = 11.0
    static let appearFor = 0.45
}

/// One band of the current plan: its radius eases from where it was (rate 4 / s), and a band that is new
/// draws its hairline from the apex outward over 0.8 s.
struct RingMotion: Equatable {
    var lag: CGFloat = 0
    var since = -Double.infinity
    var born = -Double.infinity

    static let radiusRate = 4.0
    static let drawFor = 0.8
}

/// A band the plan no longer has: its hairline undraws (after 0.2 s, over 0.8 s).
struct DyingRing: Equatable {
    var radius: CGFloat
    var lane: CGFloat
    var since: Double
}

/// A planet that left (deleted, or pushed out of the 35): it fades where it was.
struct LeavingPlanet: Equatable {
    var entry: String
    var radius: CGFloat
    var angle: CGFloat
    var ring: Int
    var scale: CGFloat
    var opacity: Double
    var fit: CGFloat
    var dims: CGSize
    var since: Double

    static let fadeFor = 0.35
}

/// A picture's shape that eases (critically damped, no overshoot) when the face changes: a webp with
/// another aspect replaces the video on the same planet.
struct DimsMotion: Equatable {
    var from: CGSize
    var to: CGSize
    var since = -Double.infinity

    static let rate = 9.0

    func value(at t: Double) -> CGSize {
        let k = CGFloat(OrbitMath.settle(t - since, Self.rate))
        return CGSize(width: to.width + (from.width - to.width) * k, height: to.height + (from.height - to.height) * k)
    }
}

/// Everything about the orbit that changes over time except the planets themselves.
struct OrbitDynamics: Equatable {
    var clock: OrbitClock
    var room = Eased(1, rate: 3)
    var offset0 = Eased(0, rate: 5)
    /// The entries as last synced, newest first: the scene draws these, so a frame never mixes an old
    /// plan with a new list.
    var ids: [String] = []
    var motions: [String: PlanetMotion] = [:]
    var dims: [String: DimsMotion] = [:]
    var rings: [RingMotion] = []
    var dying: [DyingRing] = []
    var leaving: [LeavingPlanet] = []
    /// The planets' box minus where it settles, as of `fitSince`.
    var fitLag: CGFloat = 0
    var fitSince = -Double.infinity

    static let fitRate = 5.5

    init(now: Double = Date.timeIntervalSinceReferenceDate) { clock = OrbitClock(now: now) }

    func tuning(at t: Double, push: CGFloat = 1) -> OrbitTuning {
        var tuning = OrbitTuning(room: CGFloat(room.value(at: t)), offset0: offset0.value(at: t), push: push)
        tuning.ringOffset = rings.map { $0.lag * CGFloat(exp(-RingMotion.radiusRate * max(0, t - $0.since))) }
        tuning.fitLag = fitLag * CGFloat(exp(-Self.fitRate * max(0, t - fitSince)))
        return tuning
    }

    /// The hairline of band `ring` is drawn this far (0...1).
    func draw(ring: Int, at t: Double) -> Double {
        guard ring < rings.count else { return 1 }
        return OrbitMath.smooth((t - rings[ring].born) / RingMotion.drawFor)
    }
}

/// Where a planet is on a frame, with every transition applied.
struct OrbitPlacement {
    let key: OrbitSlotKey
    let radius: CGFloat
    let angle: CGFloat
    let scale: CGFloat
    let opacity: Double
}

/// A frozen description of the orbit that both the orbit view and the screen around it evaluate: the
/// same function, so a tap, the star's landing spot and the focused planet's return all agree with
/// what is drawn.
struct OrbitScene: Equatable {
    /// The reserved slot of the planet that is being born or is in focus: an id, no planet drawn.
    static let focusID = "·focus"

    var size: CGSize = .zero
    var center: CGPoint = .zero
    var topInset: CGFloat = 60
    /// The lowest y the star may sit at: just above the work capsule (the top of the capsule stack).
    var starCeiling: CGFloat?
    var dynamics = OrbitDynamics()

    /// The entries as last synced, newest first. A reserved focus slot is just an id with no planet drawn.
    var ids: [String] { dynamics.ids }

    var isReady: Bool { size.width > 0 && size.height > 0 }

    /// Where the star is born (CONTRACT-ORBIT 1b): the visual centre of the orbit area, halfway between
    /// the title and the rail / circles, on the vertical axis.
    var starPoint: CGPoint {
        let top = topInset + 14
        var y = (top + center.y) / 2
        if let starCeiling { y = min(y, starCeiling - 48) }
        return CGPoint(x: center.x, y: max(y, top + 30))
    }

    /// `settled`: without the easing of a plan change (where everything is heading).
    func geometry(at now: Double, count: Int? = nil, push: CGFloat = 1, settled: Bool = false) -> CurrentOrbitGeometry {
        var tuning = dynamics.tuning(at: now, push: push)
        if settled { tuning.ringOffset = []; tuning.fitLag = 0 }
        tuning.starDistance = center.y - starPoint.y
        return CurrentOrbitGeometry(size: size, center: center, count: count ?? ids.count, topInset: topInset, tuning: tuning)
    }

    func orbitTime(at now: Double) -> Double { dynamics.clock.time(at: now) }

    /// A scene of five ghost planets: what an empty store shows.
    func ghosting() -> OrbitScene {
        var scene = self
        scene.dynamics.ids = (0..<5).map { "ghost\($0)" }
        scene.dynamics.motions = [:]
        scene.dynamics.dims = [:]
        scene.dynamics.rings = []
        scene.dynamics.dying = []
        scene.dynamics.leaving = []
        scene.dynamics.fitLag = 0
        return scene
    }

    // MARK: placement

    /// Entry `i` with its history applied (`step` of the reference): the conveyor's angle, held for 0.3 s
    /// when its slot changed and then slid to the new slot over 1.6 s, plus the easing of the radius and
    /// of the band's scale from where it came.
    func placement(_ i: Int, id: String, geometry g: CurrentOrbitGeometry, orbitTime time: Double, now t: Double) -> OrbitPlacement {
        let pose = g.pose(at: i, time: time)
        var angle = pose.angle
        var radius = pose.radius
        var scale = g.scale(ring: pose.key.ring)
        var appear = 1.0
        if let m = dynamics.motions[id], m.key == pose.key {
            let dt = max(0, t - m.since)
            let slide = 1 - OrbitMath.smooth((dt - m.holdFor) / m.slideFor)
            angle = pose.angle + OrbitMath.wrap(m.hold - pose.angle) * CGFloat(slide)
            angle += m.angleLag * CGFloat(exp(-PlanetMotion.angleRate * dt))
            let decay = CGFloat(exp(-PlanetMotion.radiusRate * dt))
            radius += m.radiusLag * decay
            scale += (m.scaleFrom - scale) * decay
            appear = OrbitMath.smooth((t - m.born) / PlanetMotion.appearFor)
        }
        return OrbitPlacement(key: pose.key, radius: radius, angle: angle, scale: scale, opacity: g.fade(pose.key, angle: angle) * appear)
    }

    /// The shape of entry `id`'s picture now.
    func dims(of id: String, at t: Double) -> CGSize {
        dynamics.dims[id]?.value(at: t) ?? CGSize(width: 720, height: 1280)
    }

    /// Every entry's slot at wall time `now`, and the planets that are leaving.
    func slots(at now: Double, geometry g: CurrentOrbitGeometry, orbitTime time: Double) -> [OrbitSlot] {
        var out: [OrbitSlot] = []
        for (i, id) in ids.enumerated() {
            let p = placement(i, id: id, geometry: g, orbitTime: time, now: now)
            // a planet that has just arrived also grows in
            var scale = p.scale
            if let m = dynamics.motions[id], m.key == p.key {
                scale *= 0.7 + 0.3 * CGFloat(OrbitMath.smooth((now - m.born) / PlanetMotion.appearFor))
            }
            let shape = dims(of: id, at: now)
            // the star makes room: a planet whose box would touch it is moved clear, away from the star
            let box = RainbowArcsGeometry.box(width: shape.width, height: shape.height, fit: g.fit)
            let pos = g.dodge(
                g.point(radius: p.radius, angle: p.angle), half: CGSize(width: box.width * scale / 2, height: box.height * scale / 2))
            let z = -Double(p.key.ring) * 1000 - Double(abs(pos.x - g.center.x)) * 0.01
            out.append(OrbitSlot(
                index: i, entry: id, ring: p.key.ring, position: pos, fit: g.fit, dims: shape,
                scale: scale, opacity: p.opacity, z: z))
        }
        for q in dynamics.leaving where !ids.contains(q.entry) {
            let fade = 1 - OrbitMath.smooth((now - q.since) / LeavingPlanet.fadeFor)
            guard fade > 0.01 else { continue }
            out.append(OrbitSlot(
                index: -1, entry: q.entry, ring: q.ring, position: g.point(radius: q.radius, angle: q.angle), fit: q.fit,
                dims: q.dims, scale: q.scale, opacity: q.opacity * fade, z: -Double(q.ring) * 1000))
        }
        return out
    }

    /// Where entry `i` is at `now`, with the geometry as it is then.
    func slot(_ i: Int, at now: Double) -> OrbitSlot? {
        guard isReady, ids.indices.contains(i) else { return nil }
        let g = geometry(at: now)
        return slots(at: now, geometry: g, orbitTime: orbitTime(at: now)).first { $0.index == i }
    }

    /// The bands' hairlines at `now`: a new band draws itself from the apex, a band the plan lost undraws.
    func guides(at now: Double, geometry g: CurrentOrbitGeometry) -> [OrbitGuide] {
        guard !ids.isEmpty else { return [] }
        var out: [OrbitGuide] = []
        for i in 0..<g.bandCount { out += g.guides(ring: i, draw: dynamics.draw(ring: i, at: now)) }
        for q in dynamics.dying {
            let p = 1 - OrbitMath.smooth((now - q.since - 0.2) / RingMotion.drawFor)
            out += g.guides(radius: q.radius, lane: q.lane, draw: p)
        }
        return out
    }

    /// While a planet is born, band 0 is eased so its newest slot is in the open part of the band when
    /// it lands (the harness's `holdNew`): the shortest wrap of the phase into the window.
    func holdOffset(landingIn lead: Double, now: Double) -> Double? {
        guard isReady, !ids.isEmpty else { return nil }
        let g = geometry(at: now + lead).withOffset(dynamics.offset0.target)
        let ph = g.phase0(time: orbitTime(at: now + lead))
        let w = g.newestWindow
        if w.contains(ph) { return nil }
        var d1 = w.lowerBound - ph, d2 = w.upperBound - ph
        d1 -= d1.rounded()
        d2 -= d2.rounded()
        return abs(d1) < abs(d2) ? d1 : d2
    }

    // MARK: sync

    /// A new entry list (an arrival, a deletion, a face with another shape) or a first one. Each planet
    /// whose slot changed holds its angle where it is (kept on screen on its new band), then slides; the
    /// bands' radii and the planets' box ease from where they were; a band the count needs is born (its
    /// hairline draws from the apex) and one it no longer needs undraws; an arrival fades and grows in; a
    /// departure fades out where it was. Everything is evaluated at `t` against the old plan, so an
    /// interrupted transition continues from exactly where it is. `instant` (Reduce Motion): nothing moves,
    /// the new plan is simply there.
    mutating func sync(entries: [OrbitEntry], now t: Double, instant: Bool) {
        let newIDs = entries.map(\.id)
        let old = dynamics.ids
        let animate = isReady && !instant
        // the pictures' shapes first: they ease on their own, whatever the list did
        var dims: [String: DimsMotion] = [:]
        for e in entries {
            let to = CGSize(width: e.width, height: e.height)
            if var d = dynamics.dims[e.id] {
                if d.to != to {
                    d.from = animate ? d.value(at: t) : to
                    d.to = to
                    d.since = animate ? t : -.infinity
                }
                dims[e.id] = d
            } else {
                dims[e.id] = DimsMotion(from: to, to: to)
            }
        }
        guard newIDs != old else {
            dynamics.dims = dims
            return
        }

        let gOld = geometry(at: t)
        let time = orbitTime(at: t)
        let oldRings = old.isEmpty ? 0 : gOld.bandCount
        let oldRadii = gOld.bandRadii()
        let oldFit = gOld.nearFit
        var placed: [String: OrbitPlacement] = [:]
        if animate { for (i, id) in old.enumerated() { placed[id] = placement(i, id: id, geometry: gOld, orbitTime: time, now: t) } }

        var next = dynamics
        next.ids = newIDs
        next.dims = dims
        let gNew = geometry(at: t, count: newIDs.count, settled: true)
        let target = gNew.targetRadii()

        // the bands: each eases from where it was; one that is new draws itself from the apex, starting
        // where the old outermost band was
        var rings: [RingMotion] = []
        for i in 0..<gNew.bandCount {
            var m = i < dynamics.rings.count ? dynamics.rings[i] : RingMotion()
            if animate {
                if i < oldRings {
                    m.lag = oldRadii[i] - target[i]
                    m.since = t
                } else {
                    m.lag = oldRings > 0 ? (oldRadii.last ?? target[i]) - target[i] : 0
                    m.since = t
                    m.born = t
                }
            } else {
                m = RingMotion()
            }
            rings.append(m)
        }
        next.rings = rings
        var dying = dynamics.dying.filter { t - $0.since < 1.4 }
        if animate, oldRings > gNew.bandCount {
            for i in gNew.bandCount..<oldRings {
                dying.append(DyingRing(radius: oldRadii[i], lane: oldFit * gOld.scale(ring: i) * 0.36, since: t))
            }
        }
        next.dying = animate ? dying : []
        next.fitLag = animate && !old.isEmpty ? oldFit - gNew.fitSettled : 0
        next.fitSince = animate ? t : -.infinity

        // the planets
        let focusAdded = newIDs.contains(Self.focusID) && !old.contains(Self.focusID)
        let focusTaken = focusAdded
        var alias: [String: String] = [:]
        if let focusIndex = old.firstIndex(of: Self.focusID), !newIDs.contains(Self.focusID) {
            // the planet comes home from focus into the slot that was held for it: no arrival, no fade
            let fresh = newIDs.filter { !old.contains($0) }
            if newIDs.indices.contains(focusIndex), fresh.contains(newIDs[focusIndex]) {
                alias[newIDs[focusIndex]] = Self.focusID
            } else if let first = fresh.first {
                alias[first] = Self.focusID
            }
        }
        var motions: [String: PlanetMotion] = [:]
        for (i, id) in newIDs.enumerated() {
            let key = gNew.key(at: i)
            let from = alias[id] ?? id
            if let oldIndex = old.firstIndex(of: from) {
                let oldKey = gOld.key(at: oldIndex)
                var m = dynamics.motions[from].flatMap { $0.key == oldKey ? $0 : nil } ?? PlanetMotion(key: oldKey)
                if oldKey != key {
                    m.key = key
                    if animate, let p = placed[from] {
                        let hold = gNew.holdAngle(p.angle, in: key)
                        let ringNow = target[key.ring] + (key.ring < rings.count ? rings[key.ring].lag : 0)
                        m.hold = hold
                        m.angleLag = OrbitMath.wrap(p.angle - hold)
                        m.radiusLag = p.radius - ringNow
                        m.scaleFrom = p.scale
                        m.since = t
                        // the newborn lands in 0.8 s: whoever sits in its way leaves at once, and is gone by then
                        m.holdFor = focusAdded ? 0 : PlanetMotion.holdFor
                        m.slideFor = focusAdded ? PlanetMotion.clearFor : PlanetMotion.slideFor
                    } else {
                        m = PlanetMotion(key: key, born: m.born)
                    }
                }
                motions[id] = m
            } else {
                // an arrival fades and grows in (not when the orbit is still being laid out, or under Reduce Motion)
                motions[id] = PlanetMotion(key: key, born: animate && id != Self.focusID ? t : -.infinity)
            }
        }
        next.motions = motions

        // departures fade where they were; a planet that went into focus just goes (the focus layer has it)
        var leaving = dynamics.leaving.filter { t - $0.since < LeavingPlanet.fadeFor }
        if animate, !focusTaken {
            for id in old where id != Self.focusID && !newIDs.contains(id) {
                guard let p = placed[id], p.opacity > 0.05 else { continue }
                let box = dynamics.dims[id]?.value(at: t) ?? CGSize(width: 720, height: 1280)
                leaving.append(LeavingPlanet(
                    entry: id, radius: p.radius, angle: p.angle, ring: p.key.ring, scale: p.scale, opacity: p.opacity,
                    fit: oldFit, dims: box, since: t))
            }
        }
        next.leaving = leaving
        dynamics = next
    }
}

#if DEBUG
import os

extension OrbitScene {
    /// `-previewOrbitAudit YES` (CONTRACT-ORBIT 1b): for every item count and every state (rest and the
    /// capsule states, where the star parts the bands) the radii of the bands, the gaps between
    /// neighbours, the largest gap over the median gap (must stay under about 1.5), where the outer band
    /// sits under the title and the inner one above the circles, and the clearance the star has.
    func audit() -> [String] {
        let d = center.y - starPoint.y
        var lines = [
            "orbit audit: size \(Int(size.width))x\(Int(size.height)) centre y \(Int(center.y)) topInset \(Int(topInset)) star y \(Int(starPoint.y)) (d = \(Int(d)))"
        ]
        let states: [(String, CGFloat)] = [("rest", 1), ("fetching", 1.14), ("saving", 1.23), ("reading", 1.32)]
        func f(_ x: CGFloat) -> String { String(format: "%.0f", Double(x)) }
        let counts = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 14, 16, 24, 35]
        for n in counts {
            for (name, room) in states {
                var tuning = OrbitTuning()
                tuning.room = room
                tuning.starDistance = d
                let g = CurrentOrbitGeometry(size: size, center: center, count: n, topInset: topInset, tuning: tuning)
                let radii = g.bandRadii()
                let gaps = zip(radii.dropFirst(), radii).map { $0 - $1 }
                let sorted = gaps.sorted()
                let median: CGFloat = sorted.isEmpty ? 0 : (sorted.count % 2 == 1
                    ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2)
                let ratio = median > 0 ? (gaps.max() ?? 0) / median : 1
                let apexTop = center.y - (radii.last ?? 0) - g.nearFit / 2
                let starFree = radii.map { abs($0 - d) }.min().map { $0 - g.nearFit / 2 } ?? 0
                lines.append(
                    "n=\(n) \(name): bands \(g.plan.rings) counts \(g.plan.counts) fit \(f(g.nearFit)) radii [\(radii.map(f).joined(separator: ", "))] "
                    + "gaps [\(gaps.map(f).joined(separator: ", "))] median \(f(median)) max/median \(String(format: "%.2f", Double(ratio))) "
                    + "| top planet edge y \(f(apexTop)) (bar line \(f(topInset))) | star clear of planets by \(f(starFree)) pt")
            }
        }
        // how many planets are on screen at once, over a whole lap: only the conveyor's own end fades hide
        // any (nothing is reserved over the orbit any more)
        for n in [3, 7, 14, 16, 24, 35] {
            var scene = self
            scene.sync(entries: (0..<n).map { OrbitEntry(id: "audit\($0)") }, now: 0, instant: true)
            var minVisible = Double.infinity, sumVisible = 0.0
            let samples = 400
            for step in 0..<samples {
                let g = scene.geometry(at: 0)
                let visible = scene.slots(at: 0, geometry: g, orbitTime: Double(step) * 1.5).filter { $0.opacity >= 0.5 }.count
                minVisible = min(minVisible, Double(visible) / Double(n))
                sumVisible += Double(visible) / Double(n)
            }
            lines.append("visible n=\(n): over \(samples) moments, planets on screen at once: fewest \(String(format: "%.0f", minVisible * 100)) %, mean \(String(format: "%.0f", sumVisible / Double(samples) * 100)) %")
        }
        return lines
    }

    func writeAudit() {
        let log = Logger(subsystem: "com.capybaraharmony.cobalt", category: "orbit-audit")
        let lines = audit()
        for line in lines { log.notice("\(line, privacy: .public)") }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? lines.joined(separator: "\n").write(to: docs.appendingPathComponent("orbit-audit.txt"), atomically: true, encoding: .utf8)
        }
    }
}

/// `-previewOrbitSelfTest YES`: a deterministic check of orbit E on the design's own phone frame (368 x 822,
/// centre 184 x 640, top inset 108): the plan for 0-35 media (printed in the reference's own format, so it
/// can be diffed against `ePlan` run in node), the star's `part`, and the transitions (continuity at the
/// moment of a change, the 0.3 s hold, the 1.6 s slide, a band's birth and death, the focus slot's hand-over,
/// a face that changes shape). The app target has no test bundle: this runs inside the app and writes
/// Documents/orbit-selftest.txt (and os_log, category orbit-selftest).
enum OrbitSelfTest {
    static let size = CGSize(width: 368, height: 822)
    static let center = CGPoint(x: 184, y: 640)
    static let topInset: CGFloat = 108

    static func run() -> [String] {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " · \(detail)")")
            if !ok { failures += 1 }
        }
        func f2(_ x: CGFloat) -> String { String(format: "%.2f", Double(x)) }
        func geometry(_ n: Int, _ tuning: OrbitTuning = OrbitTuning()) -> CurrentOrbitGeometry {
            CurrentOrbitGeometry(size: size, center: center, count: n, topInset: topInset, tuning: tuning)
        }
        func scene() -> OrbitScene {
            var s = OrbitScene()
            s.size = size
            s.center = center
            s.topInset = topInset
            s.dynamics = OrbitDynamics(now: 0)      // orbit time = wall time, so the tests can name both
            return s
        }
        func entries(_ ids: [String]) -> [OrbitEntry] { ids.map { OrbitEntry(id: $0) } }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        // the plan, in the reference's format
        lines.append("frame: cx 184 cy 640 topInset 108 W 368 H 822")
        for n in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 14, 16, 24, 35] {
            let g = geometry(n)
            lines.append("n=\(n) rings=\(g.plan.rings) counts=[\(g.plan.counts.map(String.init).joined(separator: ","))] fit=\(f2(g.fitSettled)) radii=[\(g.baseRadii.map(f2).joined(separator: ", "))] k=\(String(format: "%.4f", Double(g.unit)))")
        }
        let nine = geometry(9)
        let rest9 = (nine.baseRadii[3] - nine.baseRadii[0]) / 3
        let parted = RainbowArcsGeometry.part(nine.baseRadii, around: 257, clearance: min(0.6 * rest9, 62 * nine.unit))
        lines.append("d 257.00 part(9) = [\(parted.map(f2).joined(separator: ", "))]")

        // the rule: 1-3 share one orbit (the box 220 -> 165 -> 122 of the same unit), a new orbit every 2 more
        let expectedCounts = [[0], [1], [2], [3], [3, 1], [3, 2], [3, 2, 1], [3, 2, 2], [3, 2, 2, 1], [3, 2, 2, 2]]
        check("plan 0...9 counts are the owner's table", (0..<10).allSatisfy { geometry($0).plan.counts == expectedCounts[$0] })
        check("plan: 1-3 media share one orbit, 4-5 two, 6-7 three, 8-9 four",
              [1, 2, 3, 4, 5, 6, 7, 8, 9].map { geometry($0).plan.rings } == [1, 1, 1, 2, 2, 3, 3, 4, 4])
        check("plan: every count places every media (sum of counts == n) up to 35", (1...35).allSatisfy { geometry($0).plan.counts.reduce(0, +) == $0 })
        let u = geometry(10).unit / 0.94
        check("planet box 220 -> 165 -> 122 times the same unit at 1, 2, 3 media",
              abs(geometry(1).fitSettled - 220 * u) < 0.01 && abs(geometry(2).fitSettled - 165 * u) < 0.01 && abs(geometry(3).fitSettled - 122 * u) < 0.01,
              "\(f2(geometry(1).fitSettled)) \(f2(geometry(2).fitSettled)) \(f2(geometry(3).fitSettled))")
        check("planet box only shrinks as media are added (1...9)", zip(1...8, 2...9).allSatisfy { geometry($0).fitSettled >= geometry($1).fitSettled })
        check("bands strictly outward, outermost planet under the bar, at every count",
              (1...35).allSatisfy { n in
                  let g = geometry(n)
                  let r = g.baseRadii
                  return zip(r, r.dropFirst()).allSatisfy { $0 < $1 } && center.y - r[r.count - 1] - g.fitSettled / 2 >= topInset - 1
              })
        // from 10 on it is exactly today's plan: nothing in the growth tables is read
        check("10+ does not read the growth tables (n=10 has today's 5 bands)", geometry(10).plan.rings == 5 && geometry(10).plan.counts == [2, 2, 2, 2, 2])

        // the star
        var tuning = OrbitTuning()
        tuning.room = 1.32
        tuning.starDistance = 259
        let withStar = (1...9).allSatisfy { n in
            let g = geometry(n, tuning)
            let r = g.targetRadii()
            return r.allSatisfy { $0.isFinite && $0 > 0 } && zip(r, r.dropFirst()).allSatisfy { $0 < $1 } && r.allSatisfy { abs($0 - 259) >= 0 }
        }
        check("the star parts the bands without crossing them (1...9)", withStar)
        let single = geometry(2, tuning).targetRadii()[0]
        check("one orbit moves out of the star's way (300 -> d + 66)", single > geometry(2).targetRadii()[0] && abs(single - (259 + 66)) < 0.5, f2(single))

        // 3 -> 4: a new orbit is born
        var s = scene()
        let t0 = 100.0
        s.sync(entries: entries(["a", "b", "c"]), now: t0 - 5, instant: true)
        let before = s
        let timeBefore = before.orbitTime(at: t0)
        let slotsBefore = before.slots(at: t0, geometry: before.geometry(at: t0), orbitTime: timeBefore)
        s.sync(entries: entries(["d", "a", "b", "c"]), now: t0, instant: false)
        let after = s
        let slotsAfter = after.slots(at: t0, geometry: after.geometry(at: t0), orbitTime: timeBefore)
        let carried = ["a", "b", "c"].compactMap { id -> CGFloat? in
            guard let x = slotsBefore.first(where: { $0.entry == id }), let y = slotsAfter.first(where: { $0.entry == id }) else { return nil }
            return dist(x.position, y.position)
        }
        check("3 -> 4: nobody jumps at the moment of the change (positions continuous to 0.75 pt)", carried.count == 3 && carried.allSatisfy { $0 < 0.75 }, carried.map(f2).joined(separator: " "))
        check("3 -> 4: the box is continuous at the change", abs(slotsBefore[0].fit - slotsAfter[0].fit) < 0.01, "\(f2(slotsBefore[0].fit)) \(f2(slotsAfter[0].fit))")
        check("3 -> 4: a second orbit is born (its hairline starts undrawn, is drawn after 0.8 s)",
              after.geometry(at: t0).bandCount == 2 && after.dynamics.draw(ring: 1, at: t0) < 0.01 && after.dynamics.draw(ring: 1, at: t0 + 0.8) > 0.99 && after.dynamics.draw(ring: 0, at: t0) > 0.99)
        check("3 -> 4: the old orbit has not been redrawn (its hairline stays drawn)", after.dynamics.draw(ring: 0, at: t0 + 0.1) > 0.99)
        let guidesStart = after.guides(at: t0 + 0.4, geometry: after.geometry(at: t0 + 0.4)).count
        let guidesEnd = after.guides(at: t0 + 1.0, geometry: after.geometry(at: t0 + 1.0)).count
        check("3 -> 4: the new hairline draws outward from the apex (partial arc at 0.4 s, whole at 1 s)", guidesStart == 6 && guidesEnd == 6)
        // hold, then slide: the planet that moves to the new orbit keeps its angle for 0.3 s
        let moved = ["a", "b", "c"].filter { after.dynamics.motions[$0]?.since == t0 }
        check("3 -> 4: every planet's slot changed (the list shifted), so each holds then slides", moved.count == 3)
        var holdOK = true, slideOK = true, radialOK = true
        for id in ["a", "b", "c"] {
            guard let i = after.ids.firstIndex(of: id) else { continue }
            let p0 = after.placement(i, id: id, geometry: after.geometry(at: t0), orbitTime: timeBefore, now: t0)
            let p1 = after.placement(i, id: id, geometry: after.geometry(at: t0 + 0.25), orbitTime: timeBefore, now: t0 + 0.25)
            holdOK = holdOK && abs(OrbitMath.wrap(p1.angle - p0.angle)) < 0.02
            if !holdOK { lines.append("  hold debug \(id): ring \(p0.key.ring) angle \(p0.angle) -> \(p1.angle) hold \(after.dynamics.motions[id]?.hold ?? -1) lag \(after.dynamics.motions[id]?.angleLag ?? -1)") }
            let pe = after.placement(i, id: id, geometry: after.geometry(at: t0 + 3), orbitTime: timeBefore, now: t0 + 3)
            let raw = after.geometry(at: t0 + 3).pose(at: i, time: timeBefore)
            slideOK = slideOK && abs(OrbitMath.wrap(pe.angle - raw.angle)) < 0.01 && abs(pe.radius - raw.radius) < 0.5
            // a planet that changed orbit moves radially while it holds: radius changed, angle did not
            if p0.key.ring != p1.key.ring || abs(p1.radius - p0.radius) > 1 { radialOK = radialOK && abs(OrbitMath.wrap(p1.angle - p0.angle)) < 0.02 }
        }
        check("3 -> 4: a slot change holds the angle for 0.3 s", holdOK)
        check("3 -> 4: ... then slides onto the conveyor within 1.9 s (angle and radius settle)", slideOK)
        check("3 -> 4: a planet that changes orbit moves radially (radius moves, angle holds)", radialOK)
        check("3 -> 4: nothing is leaving", after.dynamics.leaving.isEmpty)

        // 4 -> 3: the emptied orbit undraws
        s.sync(entries: entries(["a", "b", "c"]), now: t0 + 10, instant: false)
        check("4 -> 3: the emptied orbit is kept as a dying band", s.dynamics.dying.count == 1 && s.geometry(at: t0 + 10).bandCount == 1)
        let gs0 = s.guides(at: t0 + 10.1, geometry: s.geometry(at: t0 + 10.1)).count
        let gs1 = s.guides(at: t0 + 11.5, geometry: s.geometry(at: t0 + 11.5)).count
        check("4 -> 3: its hairline is whole for 0.2 s, then undraws; gone by 1.2 s", gs0 == 6 && gs1 == 3, "\(gs0) \(gs1)")
        check("4 -> 3: the departing planet 'd' fades where it was", s.dynamics.leaving.count == 1 && s.dynamics.leaving[0].entry == "d")
        let leaveSlots = s.slots(at: t0 + 10.1, geometry: s.geometry(at: t0 + 10.1), orbitTime: s.orbitTime(at: t0 + 10.1)).filter { $0.index < 0 }
        check("4 -> 3: the departing planet is drawn fading, then gone",
              leaveSlots.count == 1 && leaveSlots[0].opacity > 0 && s.slots(at: t0 + 11, geometry: s.geometry(at: t0 + 11), orbitTime: s.orbitTime(at: t0 + 11)).allSatisfy { $0.index >= 0 })

        // the focus slot comes home: no arrival, no fade, same place
        var h = scene()
        h.sync(entries: entries(["x", "y", "z"]), now: 1, instant: true)
        h.sync(entries: entries([OrbitScene.focusID, "x", "y", "z"]), now: 50, instant: false)
        let tFocus = 53.0
        let reserved = h.slot(0, at: tFocus)
        let stillX = h.slots(at: tFocus, geometry: h.geometry(at: tFocus), orbitTime: h.orbitTime(at: tFocus)).filter { $0.index >= 0 }.count
        h.sync(entries: entries(["M", "x", "y", "z"]), now: tFocus, instant: false)
        let home = h.slot(0, at: tFocus)
        check("focus: the planet that comes home takes the held slot (same place, same opacity, not an arrival)",
              reserved != nil && home != nil && dist(reserved!.position, home!.position) < 0.5 && abs(reserved!.opacity - home!.opacity) < 0.001
                  && abs(reserved!.scale - home!.scale) < 0.001 && h.dynamics.motions["M"]?.born == -.infinity, "slots \(stillX)")
        check("focus: nothing fades out when a media goes into focus", { () -> Bool in
            var g = scene()
            g.sync(entries: entries(["m", "x"]), now: 1, instant: true)
            g.sync(entries: entries([OrbitScene.focusID, "x"]), now: 2, instant: false)
            return g.dynamics.leaving.isEmpty
        }())
        check("a deleted media fades out where it was (and does not when under Reduce Motion)", { () -> Bool in
            var g = scene()
            g.sync(entries: entries(["m", "x", "y"]), now: 1, instant: true)
            g.sync(entries: entries(["x", "y"]), now: 2, instant: false)
            var r = scene()
            r.sync(entries: entries(["m", "x", "y"]), now: 1, instant: true)
            r.sync(entries: entries(["x", "y"]), now: 2, instant: true)
            return g.dynamics.leaving.count <= 1 && r.dynamics.leaving.isEmpty
        }())

        // a face that changes shape: the picture's box eases (critically damped), the same planet
        var d = scene()
        d.sync(entries: [OrbitEntry(id: "a", width: 720, height: 1280)], now: 1, instant: true)
        d.sync(entries: [OrbitEntry(id: "a", width: 480, height: 480)], now: 10, instant: false)
        let start = d.dims(of: "a", at: 10), mid = d.dims(of: "a", at: 10.15), end = d.dims(of: "a", at: 12)
        check("a new face with another shape: the box eases to it (same planet, no second one)",
              abs(start.width - 720) < 0.01 && abs(start.height - 1280) < 0.01 && mid.width < 720 && mid.width > 480 && abs(end.width - 480) < 0.5 && abs(end.height - 480) < 0.5 && d.ids == ["a"],
              "\(Int(start.width))x\(Int(start.height)) -> \(Int(mid.width))x\(Int(mid.height)) -> \(Int(end.width))x\(Int(end.height))")
        d.sync(entries: [OrbitEntry(id: "a", width: 480, height: 600)], now: 20, instant: true)
        check("Reduce Motion: a new shape is simply there", d.dims(of: "a", at: 20) == CGSize(width: 480, height: 600))

        // Reduce Motion: no transitions at all
        var r = scene()
        r.sync(entries: entries(["a", "b", "c"]), now: 1, instant: true)
        r.sync(entries: entries(["d", "a", "b", "c"]), now: 2, instant: true)
        check("Reduce Motion: the new plan is simply there (no hold, no lag, no born band, nothing leaving)",
              r.dynamics.motions.values.allSatisfy { $0.since == -.infinity && $0.born == -.infinity } && r.dynamics.rings.allSatisfy { $0.lag == 0 && $0.born == -.infinity }
                  && r.dynamics.fitLag == 0 && r.dynamics.dying.isEmpty)

        // the whole range, over time: everything finite, opacity in 0...1, at 1 media the planet sweeps its orbit
        var finite = true
        for n in 0...35 {
            var g = scene()
            g.sync(entries: entries((0..<n).map { "p\($0)" }), now: 1, instant: true)
            for step in 0..<60 {
                let t = 1 + Double(step) * 2.3
                let geo = g.geometry(at: t)
                for slot in g.slots(at: t, geometry: geo, orbitTime: g.orbitTime(at: t)) {
                    finite = finite && slot.position.x.isFinite && slot.position.y.isFinite && slot.opacity >= 0 && slot.opacity <= 1.0001 && slot.scale.isFinite
                }
            }
        }
        check("0...35 media over 140 s: every position finite, every opacity in 0...1", finite)
        var one = scene()
        one.sync(entries: entries(["solo"]), now: 1, instant: true)
        let xs = stride(from: 0.0, to: 600.0, by: 5.0).compactMap { t in one.slots(at: t, geometry: one.geometry(at: t), orbitTime: one.orbitTime(at: t)).first }.filter { $0.opacity > 0.9 }.map(\.position.x)
        check("1 media: the one planet sweeps most of the orbit's width", (xs.max() ?? 0) - (xs.min() ?? 0) > 250, "x \(Int(xs.min() ?? 0))...\(Int(xs.max() ?? 0))")

        // MARK: the star's rings are never covered, and neighbours never overlap
        func rect(_ s: OrbitSlot) -> CGRect {
            let w = s.box.width * s.scale, h = s.box.height * s.scale
            return CGRect(x: s.position.x - w / 2, y: s.position.y - h / 2, width: w, height: h)
        }
        /// The deepest overlap (pt) between two planets that are on the same band.
        func worstOverlap(_ slots: [OrbitSlot], minOpacity: Double = 0.5) -> CGFloat {
            var worst: CGFloat = 0
            let live = slots.filter { $0.opacity >= minOpacity }
            for (i, a) in live.enumerated() {
                for b in live.dropFirst(i + 1) where a.ring == b.ring {
                    let ra = rect(a), rb = rect(b)
                    let dx = min(ra.maxX, rb.maxX) - max(ra.minX, rb.minX), dy = min(ra.maxY, rb.maxY) - max(ra.minY, rb.minY)
                    if dx > 0 && dy > 0 { worst = max(worst, min(dx, dy)) }
                }
            }
            return worst
        }
        let starPoint: CGPoint = scene().starPoint
        var worstStar = CGFloat.infinity, worstTop = CGFloat.infinity, worstRest: (n: Int, v: CGFloat) = (0, 0), worstGrow: (n: Int, v: CGFloat) = (0, 0)
        var restWorst: [Int: CGFloat] = [:], growWorst: [Int: CGFloat] = [:], landWorst: [Int: CGFloat] = [:]
        for n in 1...35 {
            var g = scene()
            g.sync(entries: entries((0..<n).map { "p\($0)" }), now: 0, instant: true)
            var grow = g
            grow.dynamics.room = Eased(1.32, rate: 3)       // the star is fully read: its 9 rings are out
            for step in 0..<1500 {
                let t = Double(step) * 0.41
                let rest = g.slots(at: t, geometry: g.geometry(at: t), orbitTime: g.orbitTime(at: t))
                let wr = worstOverlap(rest)
                if n < 32, wr > worstRest.v { worstRest = (n, wr) }
                restWorst[n] = max(restWorst[n] ?? 0, wr)
                let during = grow.slots(at: t, geometry: grow.geometry(at: t), orbitTime: grow.orbitTime(at: t))
                let wg = worstOverlap(during)
                if n < 32, wg > worstGrow.v { worstGrow = (n, wg) }
                growWorst[n] = max(growWorst[n] ?? 0, wg)
                for s in during where s.opacity > 0.02 {
                    let r = rect(s)
                    let gap = hypot(max(abs(s.position.x - starPoint.x) - r.width / 2, 0), max(abs(s.position.y - starPoint.y) - r.height / 2, 0))
                    worstStar = min(worstStar, gap)
                    worstTop = min(worstTop, r.minY)
                }
            }
        }
        check("the star's outer ring (50 pt) is never covered at any count 1...35 while it grows (closest planet edge \(f2(worstStar)) pt)", worstStar >= 50)
        lines.append("  info: highest planet edge while the star grows: y \(f2(worstTop)) (bar line \(Int(topInset)))")
        lines.append("  info: worst same-band overlap at rest by count (over 1 pt): " + restWorst.keys.sorted().filter { (restWorst[$0] ?? 0) > 1 }.map { "n=\($0) \(f2(restWorst[$0] ?? 0))" }.joined(separator: ", "))
        check("no two planets on one band overlap by more than 4 pt at rest, at any count 1...31 (worst \(f2(worstRest.v)) pt at n=\(worstRest.n))", worstRest.v <= 4)
        check("... nor while the star grows and the planets part around it (worst \(f2(worstGrow.v)) pt at n=\(worstGrow.n))", worstGrow.v <= 4)

        // the landing: the newborn's slot is reserved (the focus slot) and whoever sat there clears it before it arrives
        var worstLand: (n: Int, v: CGFloat, t: Double) = (0, 0, 0)
        for n in 0...34 {
            for phase in [0.0, 41.7, 133.3, 289.1, 377.7] {
                var g = scene()
                let ids = (0..<n).map { "p\($0)" }
                g.sync(entries: entries(ids), now: phase, instant: true)
                let t0 = phase + 20
                g.sync(entries: entries([OrbitScene.focusID] + ids), now: t0, instant: false)
                for step in 11...52 {   // the hero reaches its slot from 0.55 s on (it flies from the star first)
                    let t = t0 + Double(step) * 0.05
                    let slots = g.slots(at: t, geometry: g.geometry(at: t), orbitTime: g.orbitTime(at: t))
                    let w = worstOverlap(slots, minOpacity: 0.3)
                    if n < 31, w > worstLand.v { worstLand = (n, w, t - t0) }
                    landWorst[n] = max(landWorst[n] ?? 0, w)
                }
            }
        }
        lines.append("  info: the densest plans (today's, 32+ media with the newborn's slot: 32+) overlap by corners already at rest: rest \(restWorst.filter { $0.key >= 32 && $0.value > 1 }.sorted { $0.key < $1.key }.map { "n=\($0.key) \(f2($0.value))" }.joined(separator: ", ")); star grows \(growWorst.filter { $0.key >= 32 && $0.value > 1 }.sorted { $0.key < $1.key }.map { "n=\($0.key) \(f2($0.value))" }.joined(separator: ", ")); landing \(landWorst.filter { $0.key >= 31 && $0.value > 1 }.sorted { $0.key < $1.key }.map { "n=\($0.key) \(f2($0.value))" }.joined(separator: ", "))")
        check("landing: the newborn's slot is clear (no two planets on one band overlap by more than 4 pt from the star's landing to 2.6 s, 0...30 media; worst \(f2(worstLand.v)) pt at n=\(worstLand.n) after \(String(format: "%.2f", worstLand.t)) s)", worstLand.v <= 4)

        // one planet more at every count (a save arrives): the hand-off from the growing plan to today's plan is smooth
        var handoff = true
        var h2 = scene()
        h2.sync(entries: entries((0..<1).map { "q\($0)" }), now: 1, instant: true)
        for n in 2...35 {
            h2.sync(entries: entries((0..<n).map { "q\($0)" }), now: 1 + Double(n) * 3, instant: false)
            for k in 0...30 {
                let t = 1 + Double(n) * 3 + Double(k) * 0.1
                for s in h2.slots(at: t, geometry: h2.geometry(at: t), orbitTime: h2.orbitTime(at: t)) {
                    handoff = handoff && s.position.x.isFinite && s.position.y.isFinite && s.opacity.isFinite && s.scale.isFinite && s.fit.isFinite && s.fit > 0
                }
            }
        }
        check("1 -> 35 media one at a time (through the 9 -> 10 hand-off): every frame finite", handoff)

        lines.append(failures == 0 ? "orbit self-test: all checks passed" : "orbit self-test: \(failures) FAILED")
        return lines
    }

    static func write() {
        let log = Logger(subsystem: "com.capybaraharmony.cobalt", category: "orbit-selftest")
        let lines = run()
        for line in lines { log.notice("\(line, privacy: .public)") }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? lines.joined(separator: "\n").write(to: docs.appendingPathComponent("orbit-selftest.txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif

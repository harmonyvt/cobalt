import CobaltKit
import SwiftUI

// The star: while a video is being fetched the orbit births a star at its centre; it gathers the
// real progress (a pulse for time, growth for bytes, one ring per frame read), morphs into the
// video's thumbnail when it is ready, and implodes if the job fails. Everything is drawn in one
// `Canvas` (radial gradients, no blur filters), clocked by the orbit's own 30 fps timeline, and
// only while a star exists.

enum StarPhase: Equatable {
    case none
    /// Fetching, uploading, saving, reading: the star lives.
    case alive
    /// Ready: the star stretches into the video's thumbnail (aspect = width / height). `lands` is the
    /// video case: the thumbnail settles in the newest slot of band 0 and the focus layer takes it from
    /// there; otherwise (an image) the thumbnail simply fades after it has formed.
    case morphing(aspect: CGFloat, lands: Bool)
    /// Any failure: contract, shockwave, error.
    case imploding
    /// Cancelled or reset: a gentle fade, no implosion.
    case fading
}

struct StarState: Equatable {
    var phase: StarPhase = .none
    var since: Date = .distantPast

    static let none = StarState()

    /// How long the phase's animation runs before the star is gone.
    var duration: TimeInterval {
        switch phase {
        case .none: return 0
        case .alive: return .infinity
        case .morphing(_, let lands): return lands ? 1.0 : 1.7
        // the shockwave on band 0 rings for about 2.5 s after the star is gone (the harness's pushM)
        case .imploding: return 2.5
        case .fading: return 0.45
        }
    }
}

/// What the star gathers: only real numbers, nothing invented.
struct StarSignal: Equatable {
    /// Bytes over total, when the server says it (upload, save); nil keeps the seed pulsing.
    var fraction: Double?
    /// The server is waking: the pulse runs twice as fast.
    var waking = false
    /// Frames developed so far (0...9): one accretion ring each.
    var developed = 0

    /// 0...1: how far the star has grown, from real progress only.
    var growth: Double {
        if developed > 0 { return 0.9 }
        if let fraction { return 0.35 + 0.55 * StarMath.clamp(fraction) }
        return 0.45
    }
}

enum StarMath {
    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.5, c3 = c1 + 1
        let u = x - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    /// How the star's growth and rings follow the signal.
    static let swell = Animation.easeInOut(duration: 0.6)

    /// The failure shockwave on the innermost band: a multiplier on its radius, 1 + 0.26 e^(-3.2 t) sin(9 t)
    /// for 2.5 s after the star implodes (the harness's `pushM`). 1 otherwise, and always 1 under Reduce Motion.
    static func push(_ state: StarState, t: Double, reduced: Bool) -> CGFloat {
        guard !reduced, case .imploding = state.phase, t >= 0, t <= 2.5 else { return 1 }
        return 1 + CGFloat(0.26 * exp(-3.2 * t) * sin(9 * t))
    }
}

/// Draws the star for one frame of the timeline. `t` is seconds since the phase began.
///
/// How far the star has grown and how many accretion rings it wears are Animatable: the signal behind them
/// moves in steps (a poll lands, the next phase begins), and an eased value turns each step into a swell
/// instead of a pop. A ring that is being added fades in rather than appearing.
struct StarCanvas: View, @preconcurrency Animatable {
    let state: StarState
    let t: Double
    let signal: StarSignal
    /// `signal.growth`, eased by whoever animates the change.
    var growth: Double
    /// `signal.developed` as a number that eases from one ring count to the next.
    var rings: Double
    let poster: CGImage?
    /// Where the thumbnail settles, relative to the orbit's centre (the front slot).
    let frontSlot: CGPoint
    /// The thumbnail's box at scale 1 (the orbit's `fit`).
    let fit: CGFloat
    let reduceMotion: Bool
    let lowPower: Bool
    @Environment(\.colorScheme) private var scheme

    private var ink: Color { scheme == .dark ? .white : .black }
    private var haloOpacity: Double { scheme == .dark ? 0.55 : 0.26 }

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(growth, rings) }
        set { growth = newValue.first; rings = newValue.second }
    }

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            switch state.phase {
            case .none:
                break
            case .alive:
                drawSeed(&ctx, at: c, birth: reduceMotion ? 1 : StarMath.easeOutBack(StarMath.clamp(t / 0.6)), opacity: reduceMotion ? StarMath.clamp(t / 0.3) : 1)
            case .fading:
                drawSeed(&ctx, at: c, birth: 1, opacity: 1 - StarMath.clamp(t / 0.4))
            case .imploding:
                drawImplosion(&ctx, at: c)
            case .morphing(let aspect, let lands):
                drawMorph(&ctx, at: c, aspect: aspect, lands: lands)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: seed

    private func drawSeed(_ ctx: inout GraphicsContext, at c: CGPoint, birth: Double, opacity: Double, scale extra: Double = 1) {
        let period = signal.waking ? 0.9 : 1.8
        let pulse = (reduceMotion || lowPower) ? 0.5 : 0.5 + 0.5 * sin(2 * Double.pi * t / period)
        let core = (4 + 7 * growth) * birth * extra
        let bloom = core * (3.2 + 1.3 * pulse)
        guard core > 0.2 else { return }
        // soft radial bloom
        let halo = Gradient(stops: [
            .init(color: ink.opacity(haloOpacity * opacity), location: 0),
            .init(color: ink.opacity(haloOpacity * 0.35 * opacity), location: 0.45),
            .init(color: ink.opacity(0), location: 1),
        ])
        ctx.fill(
            Path(ellipseIn: CGRect(x: c.x - bloom, y: c.y - bloom, width: bloom * 2, height: bloom * 2)),
            with: .radialGradient(halo, center: c, startRadius: 0, endRadius: bloom))
        // one thin ring per frame read: the star gathering them
        for i in 0..<9 {
            let shown = StarMath.clamp(rings - Double(i))
            guard shown > 0.01 else { break }
            let r = (20 + 3.6 * Double(i)) * extra
            ctx.stroke(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: .color(ink.opacity((0.55 - 0.03 * Double(i)) * opacity * shown)), lineWidth: 1)
        }
        // the core
        ctx.fill(
            Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)),
            with: .color(ink.opacity(opacity)))
    }

    // MARK: implosion

    private func drawImplosion(_ ctx: inout GraphicsContext, at c: CGPoint) {
        if reduceMotion {
            drawSeed(&ctx, at: c, birth: 1, opacity: 1 - StarMath.clamp(t / 0.3))
            return
        }
        let u = StarMath.clamp(t / 0.45)
        // 1 -> 1.12 -> 0
        let s = u < 0.3 ? 1 + 0.12 * (u / 0.3) : 1.12 * (1 - pow((u - 0.3) / 0.7, 2))
        drawSeed(&ctx, at: c, birth: 1, opacity: 1 - u * 0.6, scale: max(0, s))
        // the shockwave
        let v = StarMath.clamp(t / 0.6)
        if v < 1 {
            let r = 12 + 62 * StarMath.easeOut(v)
            ctx.stroke(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: .color(ink.opacity(0.8 * (1 - v))), lineWidth: 0.6 + 1.0 * (1 - v))
        }
    }

    // MARK: morph

    private func drawMorph(_ ctx: inout GraphicsContext, at c: CGPoint, aspect: CGFloat, lands: Bool) {
        let w1 = aspect < 1 ? fit * aspect : fit
        let h1 = aspect < 1 ? fit : fit / max(aspect, 0.2)
        let u = reduceMotion ? 1 : StarMath.clamp(t / 0.8)
        let e = reduceMotion ? 1 : StarMath.easeOutBack(u)
        let seed = (4 + 7 * 0.9)
        let w = lerp(seed * 2, w1, e), h = lerp(seed * 2, h1, e)
        let center = CGPoint(x: lerp(c.x, c.x + frontSlot.x, e), y: lerp(c.y, c.y + frontSlot.y, e))
        let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        let corner = lerp(min(w, h) / 2, Metrics.thumbRadius, min(1, e))
        let hold = reduceMotion ? StarMath.clamp(t / 0.3) : 1
        // a landing thumbnail is handed to the focus layer (same rect, same picture) at 0.82 s; any
        // other thumbnail fades after it has formed
        let fadeOut = lands ? (t < 0.82 ? 1 : 0) : 1 - StarMath.clamp((t - 1.3) / 0.4)
        let thumb = hold * fadeOut
        // the star's glow gives way to the thumbnail
        if !reduceMotion || t < 0.3 {
            drawSeed(&ctx, at: c, birth: 1, opacity: (1 - StarMath.clamp(u * 1.4)) * (reduceMotion ? 1 - hold : 1), scale: 1 - 0.5 * u)
        }
        // A landing planet is NOT drawn here: the focus layer's one hero view is born at the star and rides
        // this same morph, so the picture is never handed from one view to another.
        if lands { return }
        let shape = Path(roundedRect: rect, cornerRadius: corner, style: .continuous)
        ctx.drawLayer { layer in
            layer.opacity = thumb
            layer.clip(to: shape)
            layer.fill(shape, with: .linearGradient(
                Gradient(colors: [CobaltColor.frameTopAlt, CobaltColor.frameBottomAlt]),
                startPoint: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY),
                endPoint: CGPoint(x: rect.minX + rect.width * 0.65, y: rect.maxY)))
            if let poster {
                let img = layer.resolve(Image(decorative: poster, scale: 1))
                let ia = CGFloat(poster.width) / CGFloat(max(1, poster.height))
                let ra = rect.width / max(1, rect.height)
                var fill = rect
                if ia > ra { fill.size.width = rect.height * ia; fill.origin.x -= (fill.width - rect.width) / 2 }
                else { fill.size.height = rect.width / ia; fill.origin.y -= (fill.height - rect.height) / 2 }
                layer.draw(img, in: fill)
            }
        }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat { a + (b - a) * CGFloat(x) }
}

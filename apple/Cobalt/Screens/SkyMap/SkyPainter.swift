import CobaltKit
import SwiftUI

// Draws the sky: background, nebulae, constellation lines, stars, labels. A port of the web's `paintSky` and `paintStars`
// (`deploy/cloudflare/web/src/library/page.html`, about lines 1660 to 1760) onto a SwiftUI `Canvas`.

/// How far the user has zoomed and panned. Zoom 1 fits the whole sky.
struct SkyViewport: Equatable {
    var zoom: Double = 1
    var pan: CGSize = .zero

    static let zoomRange: ClosedRange<Double> = 1...12
    var isHome: Bool { zoom == 1 && pan == .zero }

    /// Zoom by `factor` keeping the screen point `anchor` (relative to the box's centre `c`) where it is.
    func zoomed(by factor: Double, anchor: CGPoint, centre c: CGPoint) -> SkyViewport {
        let z = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
        let k = z / zoom
        let dx = anchor.x - c.x, dy = anchor.y - c.y
        return SkyViewport(zoom: z, pan: CGSize(width: dx - (dx - pan.width) * k, height: dy - (dy - pan.height) * k))
    }

    /// The pan kept so some of the sky always stays on screen.
    func clamped(in size: CGSize) -> SkyViewport {
        let mx = size.width * (zoom - 1) / 2 + size.width * 0.3
        let my = size.height * (zoom - 1) / 2 + size.height * 0.3
        var v = self
        v.pan = CGSize(width: min(mx, max(-mx, pan.width)), height: min(my, max(-my, pan.height)))
        return v
    }
}

/// The room the sky has on screen: the header sits over the top, a bar may sit under it.
struct SkyInsets: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var side: CGFloat = 28
}

/// World (the unit square the model lays out in) to screen: fit the layout into the box, then the user's zoom and pan.
/// The web's `fitter`.
struct SkyFrame {
    /// Points per world unit, zoom included.
    let k: Double
    /// The world point at the middle of the box.
    let mid: SIMD2<Double>
    /// Where that point is on screen before panning.
    let centre: CGPoint
    let pan: CGSize

    init(bounds: SkyBounds, size: CGSize, insets: SkyInsets, viewport: SkyViewport) {
        let spanX = bounds.maxX - bounds.minX == 0 ? 1 : bounds.maxX - bounds.minX
        let spanY = bounds.maxY - bounds.minY == 0 ? 1 : bounds.maxY - bounds.minY
        let box = CGRect(
            x: insets.side, y: insets.top, width: max(40, size.width - 2 * insets.side),
            height: max(40, size.height - insets.top - insets.bottom))
        let fit = min(box.width / spanX, box.height / spanY)
        k = fit * viewport.zoom
        mid = SIMD2((bounds.minX + bounds.maxX) / 2, (bounds.minY + bounds.maxY) / 2)
        centre = CGPoint(x: box.midX, y: box.midY)
        pan = viewport.pan
    }

    func point(_ p: SIMD2<Double>) -> CGPoint {
        CGPoint(x: centre.x + (p.x - mid.x) * k + pan.width, y: centre.y + (p.y - mid.y) * k + pan.height)
    }

    func world(_ s: CGPoint) -> SIMD2<Double> {
        SIMD2((s.x - centre.x - pan.width) / k + mid.x, (s.y - centre.y - pan.height) / k + mid.y)
    }
}

/// What the canvas remembers between frames: the stars as they are drawn now (easing towards the model's latest
/// layout), when the sky settled, the dust and the glow sprites. A class, so the canvas can update it as it draws.
final class SkyStage {
    private(set) var shown: [SIMD2<Double>] = []
    private var lastTime: TimeInterval?
    private var readyAt: TimeInterval?
    private var dust: (size: CGSize, items: [SkyDust]) = (.zero, [])
    private var glows: [UInt32: CGImage] = [:]
    private var labels: (key: SkyLabelKey, items: [SkyLabelPlacement])?

    /// Moves the drawn stars towards `target`. They snap when the count changes (a new sky) or when `animate` is off.
    func advance(target: [SIMD2<Double>], now: TimeInterval, animate: Bool) {
        defer { lastTime = now }
        guard animate, shown.count == target.count, let last = lastTime else {
            shown = target
            return
        }
        let dt = min(0.25, max(0, now - last))
        let f = 1 - exp(-dt * 9)
        for i in shown.indices { shown[i] += (target[i] - shown[i]) * f }
    }

    /// 0...1 over 0.9 s from the first frame the sky is `ready`; nil while it is not.
    func reveal(ready: Bool, now: TimeInterval, animate: Bool) -> Double {
        guard ready else {
            readyAt = nil
            return 0
        }
        guard animate else { return 1 }
        let start = readyAt ?? now
        readyAt = start
        let t = min(1, max(0, (now - start) / 0.9))
        return t * t * (3 - 2 * t)
    }

    func dust(for size: CGSize) -> [SkyDust] {
        if dust.size != size { dust = (size, SkyDustField.make(size: size)) }
        return dust.items
    }

    func glow(_ rgb: SkyRGB) -> CGImage? {
        if let hit = glows[rgb.key] { return hit }
        guard let made = SkyBitmaps.glow(rgb) else { return nil }
        glows[rgb.key] = made
        return made
    }

    /// The labels placed for `key`, worked out again only when the view, the size or the sky changes.
    func labels(for key: SkyLabelKey, make: () -> [SkyLabelPlacement]) -> [SkyLabelPlacement] {
        if let labels, labels.key == key { return labels.items }
        let items = make()
        labels = (key, items)
        return items
    }
}

/// What label placement depends on: the frame, the canvas size, the sky and the text size.
struct SkyLabelKey: Equatable {
    var k: Double
    var mid: SIMD2<Double>
    var centre: CGPoint
    var pan: CGSize
    var size: CGSize
    var constellations: [SkyConstellation]
    var typeSize: DynamicTypeSize
}

/// One label that fitted: its words and the bottom-centre point it is drawn at.
struct SkyLabelPlacement {
    var text: String
    var at: CGPoint
}

/// Everything one frame needs.
struct SkyScene {
    var theme: SkyTheme
    var size: CGSize
    var frame: SkyFrame?
    var viewport: SkyViewport
    var points: [SIMD2<Double>] = []
    var degrees: [Int] = []
    var membership: [Int] = []
    var constellations: [SkyConstellation] = []
    var nebulae: [SkyNebula] = []
    var nebulaImages: [CGImage] = []
    /// 0 while the stars settle, 1 once the nebulae, lines and labels have faded in.
    var reveal: Double = 0
    var time: TimeInterval = 0
    var twinkle = false
    /// The star the pointer is on, or the one a card is open for.
    var focus: Int?
    var showsStars = true
}

enum SkyPainter {
    static func draw(_ scene: SkyScene, stage: SkyStage, into ctx: inout GraphicsContext) {
        paintBackdrop(scene, dust: stage.dust(for: scene.size), into: &ctx)
        guard scene.showsStars, let f = scene.frame, !scene.points.isEmpty else { return }
        if !scene.theme.dark { paintGrid(scene, frame: f, into: &ctx) }
        if scene.reveal > 0 { paintNebulae(scene, frame: f, into: &ctx) }
        if scene.reveal > 0 { paintLines(scene, frame: f, into: &ctx) }
        paintStars(scene, frame: f, stage: stage, into: &ctx)
        if scene.reveal > 0 { paintLabels(scene, frame: f, stage: stage, into: &ctx) }
    }

    // MARK: backdrop

    /// The night gradient (or the paper) with its faint star field; the dust drifts at 15 % of the pan.
    static func paintBackdrop(_ scene: SkyScene, dust: [SkyDust], into ctx: inout GraphicsContext) {
        let w = scene.size.width, h = scene.size.height, t = scene.theme
        let rect = CGRect(origin: .zero, size: scene.size)
        ctx.fill(
            Path(rect),
            with: .radialGradient(
                Gradient(colors: [t.top.color(), t.bottom.color()]), center: CGPoint(x: w * 0.5, y: h * 0.35),
                startRadius: 0, endRadius: max(w, h) * 0.75))
        guard w > 0, h > 0 else { return }
        let px = scene.viewport.pan.width * 0.15, py = scene.viewport.pan.height * 0.15
        let ink = t.star.color()
        for s in dust {
            let twinkle = scene.twinkle ? 0.65 + 0.35 * sin(scene.time * s.speed + s.phase) : 1
            let x = (s.x + px).truncatingRemainder(dividingBy: w), y = (s.y + py).truncatingRemainder(dividingBy: h)
            let cx = x < 0 ? x + w : x, cy = y < 0 ? y + h : y
            var c = ctx
            c.opacity = s.alpha * twinkle * (t.dark ? 1 : 0.55)
            c.fill(Path(ellipseIn: CGRect(x: cx - s.radius, y: cy - s.radius, width: s.radius * 2, height: s.radius * 2)), with: .color(ink))
        }
    }

    /// The day chart's faint grid, fixed to the sky (it moves and scales with the map).
    static func paintGrid(_ scene: SkyScene, frame f: SkyFrame, into ctx: inout GraphicsContext) {
        var step = 0.1
        while step * f.k < 18 { step *= 2 }
        let lo = f.world(.zero), hi = f.world(CGPoint(x: scene.size.width, y: scene.size.height))
        var minor = Path(), major = Path()
        var gx = (lo.x / step).rounded(.down)
        while gx * step <= hi.x {
            let x = f.point(SIMD2(gx * step, 0)).x
            if Int(gx) % 5 == 0 { major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: scene.size.height)) }
            else { minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: scene.size.height)) }
            gx += 1
        }
        var gy = (lo.y / step).rounded(.down)
        while gy * step <= hi.y {
            let y = f.point(SIMD2(0, gy * step)).y
            if Int(gy) % 5 == 0 { major.move(to: CGPoint(x: 0, y: y)); major.addLine(to: CGPoint(x: scene.size.width, y: y)) }
            else { minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: scene.size.width, y: y)) }
            gy += 1
        }
        let ink = scene.theme.star
        ctx.stroke(minor, with: .color(ink.color(0.05)), lineWidth: 0.5)
        ctx.stroke(major, with: .color(ink.color(0.10)), lineWidth: 0.6)
    }

    // MARK: nebulae, lines

    /// Each constellation's cloud: night clouds add light, day clouds multiply into the paper.
    static func paintNebulae(_ scene: SkyScene, frame f: SkyFrame, into ctx: inout GraphicsContext) {
        guard scene.nebulaImages.count == scene.nebulae.count else { return }
        var c = ctx
        c.blendMode = scene.theme.dark ? .plusLighter : .multiply
        c.opacity = scene.reveal
        for (nebula, image) in zip(scene.nebulae, scene.nebulaImages) {
            let a = f.point(SIMD2(nebula.bounds.minX, nebula.bounds.minY))
            let b = f.point(SIMD2(nebula.bounds.maxX, nebula.bounds.maxY))
            let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            guard rect.intersects(CGRect(origin: .zero, size: scene.size)) else { continue }
            c.draw(Image(decorative: image, scale: 1).resizable().interpolation(.high), in: rect)
        }
    }

    /// The star lines, one stroke per constellation, tinted towards its hue.
    static func paintLines(_ scene: SkyScene, frame f: SkyFrame, into ctx: inout GraphicsContext) {
        let t = scene.theme
        var c = ctx
        c.opacity = scene.reveal
        for cl in scene.constellations {
            var path = Path()
            for e in cl.edges where scene.points.indices.contains(e.a) && scene.points.indices.contains(e.b) {
                path.move(to: f.point(scene.points[e.a]))
                path.addLine(to: f.point(scene.points[e.b]))
            }
            let tint = t.line.mixed(with: SkyRGB(SkyPalette.hue(cl.hue, dark: t.dark)), 0.5)
            c.stroke(path, with: .color(tint.color(min(0.5, t.lineAlpha * 1.25))), lineWidth: 1.2)
        }
    }

    // MARK: stars

    /// Size and brightness by degree (the hubs of a constellation are the big ones), hue by constellation, a glow at
    /// night, a four-point twinkle on the hubs.
    static func paintStars(_ scene: SkyScene, frame f: SkyFrame, stage: SkyStage, into ctx: inout GraphicsContext) {
        let t = scene.theme
        let scale = min(1.6, scene.viewport.zoom.squareRoot())
        let bounds = CGRect(origin: .zero, size: scene.size).insetBy(dx: -40, dy: -40)
        let tintMix = t.dark ? 0.38 : 0.45
        var glows: [UInt32: GraphicsContext.ResolvedImage] = [:]
        var hues: [Int: SkyRGB] = [:]
        for cl in scene.constellations { hues[cl.id] = SkyRGB(SkyPalette.hue(cl.hue, dark: t.dark)) }

        func glowImage(_ rgb: SkyRGB) -> GraphicsContext.ResolvedImage? {
            if let hit = glows[rgb.key] { return hit }
            guard let cg = stage.glow(rgb) else { return nil }
            let resolved = ctx.resolve(Image(decorative: cg, scale: 1))
            glows[rgb.key] = resolved
            return resolved
        }

        for i in scene.points.indices {
            let p = f.point(scene.points[i])
            guard bounds.contains(p) else { continue }
            let focus = scene.focus == i
            let degree = scene.degrees.indices.contains(i) ? scene.degrees[i] : 0
            var r = (1.3 + 0.55 * Double(min(degree, 4))) * scale
            if focus { r += 1.2 * scale }
            let hue: SkyRGB? = scene.membership.indices.contains(i) ? hues[scene.membership[i]] : nil
            let full = hue.map { t.star.mixed(with: $0, tintMix) } ?? t.star
            let body = hue.map { t.star.mixed(with: $0, tintMix * scene.reveal) } ?? t.star
            let ink = focus ? t.hit : body
            if t.dark || focus {
                let size = r * (focus ? 9 : 6)
                if let glow = glowImage(focus ? t.hit : full) {
                    ctx.draw(glow, in: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
                }
            }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(ink.color()))
            if t.dark, degree >= 3 || focus {
                let l = r * 3.2
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - l, y: p.y)); cross.addLine(to: CGPoint(x: p.x + l, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - l)); cross.addLine(to: CGPoint(x: p.x, y: p.y + l))
                var c = ctx
                c.opacity = 0.55
                c.stroke(cross, with: .color(ink.color()), lineWidth: 0.7)
            }
        }
        if let focus = scene.focus, scene.points.indices.contains(focus) {
            let p = f.point(scene.points[focus])
            var c = ctx
            c.opacity = 0.9
            c.stroke(Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)), with: .color(t.hit.color()), lineWidth: 1.2)
        }
    }

    // MARK: labels

    /// The constellation's words, upper-case and spaced out, centred above its top star with a halo. The biggest
    /// constellations go first. A label is slid inside the screen (12 pt in from every edge); one that is still too wide
    /// loses its trailing keywords, and one that would land on a label already placed is tried again with fewer
    /// keywords (down to one) before it is left out at this zoom. A label first has to fit with at most 30 pt of
    /// sliding (so it still sits over its own constellation); only if no version does may it slide further.
    static func paintLabels(_ scene: SkyScene, frame f: SkyFrame, stage: SkyStage, into ctx: inout GraphicsContext) {
        let t = scene.theme
        var c = ctx
        c.opacity = scene.reveal
        let key = SkyLabelKey(
            k: f.k, mid: f.mid, centre: f.centre, pan: f.pan, size: scene.size, constellations: scene.constellations,
            typeSize: ctx.environment.dynamicTypeSize)
        let measurer = c
        let placed = stage.labels(for: key) { placeLabels(scene, frame: f, measurer: measurer) }
        for label in placed {
            let base = labelText(label.text)
            let halo = c.resolve(base.foregroundColor(t.halo.color(t.haloAlpha)))
            let ink = c.resolve(base.foregroundColor(t.label.color()))
            for (dx, dy) in [(-1.5, 0.0), (1.5, 0), (0, -1.5), (0, 1.5), (-1.1, -1.1), (1.1, -1.1), (-1.1, 1.1), (1.1, 1.1)] {
                c.draw(halo, at: CGPoint(x: label.at.x + dx, y: label.at.y + dy), anchor: .bottom)
            }
            c.draw(ink, at: label.at, anchor: .bottom)
        }
    }

    private static func labelText(_ label: String) -> Text {
        Text(label).font(Font.cobalt(11, .semibold)).tracking(2)
    }

    /// The search described above; measuring is the slow part, so its answer is cached in the stage.
    private static func placeLabels(_ scene: SkyScene, frame f: SkyFrame, measurer c: GraphicsContext) -> [SkyLabelPlacement] {
        let inset: CGFloat = 12
        var placed: [CGRect] = []
        var out: [SkyLabelPlacement] = []
        let screen = CGRect(origin: .zero, size: scene.size)
        for cl in scene.constellations.sorted(by: { $0.members.count != $1.members.count ? $0.members.count > $1.members.count : $0.id < $1.id })
        where cl.members.count >= 2 && !cl.keywords.isEmpty {
            let anchor = f.point(SIMD2(cl.centroid.x, cl.top))
            var done = false
            for slack in [CGFloat(30), .infinity] where !done {
                var count = cl.keywords.count
                while count >= 1 {
                    let label = cl.keywords.prefix(count).joined(separator: " · ").uppercased()
                    let size = c.resolve(labelText(label)).measure(in: CGSize(width: 800, height: 40))
                    // too wide for the screen: fewer words
                    guard size.width <= scene.size.width - 2 * inset else { count -= 1; continue }
                    let natural = CGRect(x: anchor.x - size.width / 2, y: anchor.y - 12 - size.height, width: size.width, height: size.height)
                    // the constellation is off screen: no label floating over nothing
                    guard screen.intersects(natural) else { done = true; break }
                    let x = min(max(anchor.x, inset + size.width / 2), scene.size.width - inset - size.width / 2)
                    if abs(x - anchor.x) > slack {
                        count -= 1
                        continue
                    }
                    let rect = CGRect(x: x - size.width / 2, y: natural.minY, width: size.width, height: size.height)
                    if placed.contains(where: { $0.insetBy(dx: -6, dy: -3).intersects(rect) }) {
                        count -= 1
                        continue
                    }
                    placed.append(rect)
                    out.append(SkyLabelPlacement(text: label, at: CGPoint(x: x, y: anchor.y - 12)))
                    done = true
                    break
                }
            }
        }
        return out
    }
}

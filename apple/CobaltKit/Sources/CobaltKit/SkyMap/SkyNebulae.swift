import Foundation

/// The layout's bounding box (the web's `M.bounds`).
public struct SkyBounds: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// The box around `points` (all zero for none).
    public init(points: [SIMD2<Double>]) {
        guard let first = points.first else {
            self.init(minX: 0, minY: 0, maxX: 0, maxY: 0)
            return
        }
        var b = SkyBounds(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for p in points {
            b.minX = min(b.minX, p.x); b.maxX = max(b.maxX, p.x)
            b.minY = min(b.minY, p.y); b.maxY = max(b.maxY, p.y)
        }
        self = b
    }

    /// How far the nebula image reaches past the stars, as a fraction of the layout's size on every side (`NEB_PAD`).
    public static let nebulaPad = 0.3

    /// The box the nebula images cover: these bounds grown by 30 % of their size on every side, so clouds fade out
    /// instead of stopping at the outer stars (`nebulaBox`, page.html 1620). A flat axis counts as size 1.
    public var nebulaBox: SkyBounds {
        let spanX = maxX - minX, spanY = maxY - minY
        let px = (spanX == 0 ? 1 : spanX) * Self.nebulaPad, py = (spanY == 0 ? 1 : spanY) * Self.nebulaPad
        return SkyBounds(minX: minX - px, minY: minY - py, maxX: maxX + px, maxY: maxY + py)
    }
}

/// A small density image for one constellation: draw it scaled up (smoothed) over `bounds`, in the constellation's hue.
public struct SkyNebula: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Row by row, top (smallest y) first, 0...1.
    public var values: [Float]
    /// The constellation's hue index (`SkyPalette`).
    public var hue: Int
    /// The area of the layout the image covers: the layout's bounds grown by `SkyBounds.nebulaPad`.
    public var bounds: SkyBounds

    public init(width: Int, height: Int, values: [Float], hue: Int, bounds: SkyBounds) {
        self.width = width
        self.height = height
        self.values = values
        self.hue = hue
        self.bounds = bounds
    }
}

/// Shades the dense areas, a port of the web's `nebulaImages` (page.html 1624 to 1650).
public enum SkyNebulae {
    /// The image size, 96 x 96.
    public static let side = 96
    /// The width of each star's glow, as a fraction of the image (`sig`).
    public static let sigma = 0.05

    /// The most opaque a nebula pixel is drawn: 125 of 255 on the night sky, 95 of 255 on the day chart. Multiply a
    /// `SkyNebula` value by this for the pixel's alpha (the web additionally blends night nebulae with "lighter" and
    /// day ones with "multiply").
    public static func alpha(dark: Bool) -> Double { dark ? 125.0 / 255 : 95.0 / 255 }

    /// One nebula per constellation, in order. Each member adds a Gaussian glow (3 sigma wide); the grid is divided by
    /// its peak, but never by less than 3, so a lone star is a faint wisp and a dense constellation a bright cloud,
    /// then eased with a power of 0.9. `bounds` is the layout's own box (`SkyBounds(points:)`), not the grown one.
    public static func build(points: [SIMD2<Double>], constellations: [SkyConstellation], bounds: SkyBounds) -> [SkyNebula] {
        let box = bounds.nebulaBox
        let w = side, h = side
        let spanX = (box.maxX - box.minX) == 0 ? 1 : box.maxX - box.minX
        let spanY = (box.maxY - box.minY) == 0 ? 1 : box.maxY - box.minY
        let radius = Int((3 * sigma * Double(w)).rounded(.up))
        let sx = sigma * Double(w), sy = sigma * Double(h)
        return constellations.map { cl in
            var grid = [Float](repeating: 0, count: w * h)
            for q in cl.members where points.indices.contains(q) {
                let px = (points[q].x - box.minX) / spanX * Double(w - 1)
                let py = (points[q].y - box.minY) / spanY * Double(h - 1)
                let y0 = max(0, Int((py - Double(radius)).rounded(.down))), y1 = min(h - 1, Int((py + Double(radius)).rounded(.up)))
                let x0 = max(0, Int((px - Double(radius)).rounded(.down))), x1 = min(w - 1, Int((px + Double(radius)).rounded(.up)))
                guard y0 <= y1, x0 <= x1 else { continue }
                for y in y0...y1 {
                    let dy = (Double(y) - py) / sy
                    for x in x0...x1 {
                        let dx = (Double(x) - px) / sx
                        grid[y * w + x] += Float(exp(-(dx * dx + dy * dy) / 2))
                    }
                }
            }
            let norm = max(grid.max() ?? 0, 3)
            let values = grid.map { Float(pow(Double(min(1, $0 / norm)), 0.9)) }
            return SkyNebula(width: w, height: h, values: values, hue: cl.hue, bounds: box)
        }
    }
}

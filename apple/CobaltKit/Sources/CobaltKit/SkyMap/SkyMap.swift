import Foundation

/// The sky map's constants and small helpers: the library's embeddings laid out in 2D (t-SNE), grouped into
/// constellations, shaded as nebulae. A port of the web library's map (`deploy/cloudflare/web/src/library/page.html`,
/// "the map" section, about lines 1323 to 1720) so the app and the web draw the same sky. Pure maths: no UI, no network.
public enum SkyMap {
    /// Newest posts kept on the map (t-SNE is n squared). `MAP_MAX`, page.html 1327.
    public static let maxPosts = 3000
    /// t-SNE iterations. `MAP_ITERS`, page.html 1329.
    public static let iterations = 650
    /// The seed the web lays the map out with (`rng(42)`, page.html 1429).
    public static let layoutSeed: UInt64 = 42
    /// The seed the web picks the constellations with (`rng(7)`, page.html 1507).
    public static let constellationSeed: UInt64 = 7

    /// The vector scaled to unit length (a zero vector stays zero). The web normalises after decoding (`decode8`,
    /// page.html 1347), so cosine similarity is a plain dot product.
    public static func normalized(_ v: [Float]) -> [Float] {
        var s: Float = 0
        for x in v { s += x * x }
        s = s.squareRoot()
        if s == 0 { return v }
        return v.map { $0 / s }
    }

    /// Cosine similarity of two vectors (any scale).
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let x = normalized(a), y = normalized(b)
        var s: Float = 0
        for i in 0..<min(x.count, y.count) { s += x[i] * y[i] }
        return s
    }

    /// Fits points into the unit square, keeping their shape: the longer side spans 0...1 and the shorter is centred.
    /// A single point (or none spread) lands in the middle. A uniform scale and shift, so k-means, the star lines and
    /// the nebulae computed on the result match the ones computed on the raw layout.
    public static func fitToUnitSquare(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard let first = points.first else { return [] }
        var lo = first, hi = first
        for p in points { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) }
        let span = hi - lo
        let side = max(span.x, span.y)
        guard side > 0 else { return points.map { _ in SIMD2(0.5, 0.5) } }
        let offset = SIMD2((1 - span.x / side) / 2, (1 - span.y / side) / 2)
        return points.map { ($0 - lo) / side + offset }
    }
}

/// mulberry32, the generator the web uses (`rng`, page.html 1339): the same library lays out the same way every time.
/// The seed is taken as 32 bits, like `seed | 0` in the web.
struct SkyRNG: Sendable {
    private var state: UInt32

    init(seed: UInt64) { state = UInt32(truncatingIfNeeded: seed) }

    /// The next value in 0..<1.
    mutating func next() -> Double {
        state = state &+ 0x6D2B79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

import Foundation

/// A look at the layout while it settles.
struct SkyLayoutSnapshot: Sendable {
    /// 0...1 of the t-SNE iterations done.
    var progress: Double
    /// Fitted to the unit square.
    var points: [SIMD2<Double>]
}

/// Everything the sky needs once the layout has settled.
struct SkyLayoutResult: Sendable {
    var points: [SIMD2<Double>]
    var constellations: [SkyConstellation]
    var nebulae: [SkyNebula]
    var words: SkyWords
    var bounds: SkyBounds
    var degrees: [Int]
    var membership: [Int]
}

/// The whole sky for a list of posts, off any actor: t-SNE, then constellations and nebulae on the layout fitted to the
/// unit square (a uniform scale, so they come out the same as on the raw layout).
enum SkyMapLayout {
    /// Runs the layout, calling `snapshot` first and then about every 50 ms. Returns nil if the surrounding task was
    /// cancelled (checked after every iteration).
    static func run(posts: [MapPost], iterations: Int, snapshot: (SkyLayoutSnapshot) -> Void) -> SkyLayoutResult? {
        var tsne = SkyTSNE(vectors: posts.map(\.vector), seed: SkyMap.layoutSeed, iterations: iterations)
        if Task.isCancelled { return nil }
        func progress() -> Double { tsne.iterations == 0 ? 1 : Double(tsne.iteration) / Double(tsne.iterations) }
        snapshot(SkyLayoutSnapshot(progress: progress(), points: SkyMap.fitToUnitSquare(tsne.points)))
        let clock = ContinuousClock()
        var last = clock.now
        while tsne.step() {
            if Task.isCancelled { return nil }
            let now = clock.now
            if now - last >= .milliseconds(50) {
                last = now
                snapshot(SkyLayoutSnapshot(progress: progress(), points: SkyMap.fitToUnitSquare(tsne.points)))
            }
        }
        if Task.isCancelled { return nil }
        return settle(posts: posts, raw: tsne.points)
    }

    /// The finished layout's constellations, star lines, nebulae and word counts.
    static func settle(posts: [MapPost], raw: [SkyPoint]) -> SkyLayoutResult {
        let points = SkyMap.fitToUnitSquare(raw)
        let words = SkyWords(posts: posts)
        let constellations = SkyConstellations.build(points: points, words: words, seed: SkyMap.constellationSeed)
        let bounds = SkyBounds(points: points)
        return SkyLayoutResult(
            points: points, constellations: constellations,
            nebulae: SkyNebulae.build(points: points, constellations: constellations, bounds: bounds),
            words: words, bounds: bounds,
            degrees: SkyConstellations.degrees(of: constellations, count: points.count),
            membership: SkyConstellations.membership(of: constellations, count: points.count))
    }
}

typealias SkyPoint = SIMD2<Double>

import Foundation

/// A star line between two posts of one constellation (indices into the posts and points).
public struct SkyEdge: Sendable, Equatable {
    public var a: Int
    public var b: Int

    public init(a: Int, b: Int) {
        self.a = a
        self.b = b
    }
}

/// One island of the sky: a group of nearby posts with its label words, star lines and nebula colour.
public struct SkyConstellation: Sendable, Equatable, Identifiable {
    public var id: Int
    /// Indices into the posts and points, ascending.
    public var members: [Int]
    /// Up to 3 words (only for 2 or more posts; the web labels nothing else).
    public var keywords: [String]
    /// The minimum spanning tree over the members, minus the long jumps.
    public var edges: [SkyEdge]
    /// Index into `SkyPalette` (cycles through its 10 colours).
    public var hue: Int
    /// The k-means centre, where the label is centred.
    public var centroid: SIMD2<Double>
    /// The smallest y of any member: the label sits above it (the web's `cl.top`).
    public var top: Double

    public init(
        id: Int, members: [Int], keywords: [String], edges: [SkyEdge], hue: Int, centroid: SIMD2<Double>, top: Double
    ) {
        self.id = id
        self.members = members
        self.keywords = keywords
        self.edges = edges
        self.hue = hue
        self.centroid = centroid
        self.top = top
    }
}

/// Groups the laid-out posts into constellations, a port of the web's `finishLayout` and `mst` (page.html 1499 to 1570).
public enum SkyConstellations {
    /// How many constellations `n` posts make: one under 8 posts, else `round(sqrt(n / 2.5))` kept within 2...12.
    public static func clusterCount(for n: Int) -> Int {
        n < 8 ? 1 : max(2, min(12, Int((Double(n) / 2.5).squareRoot().rounded(.toNearestOrAwayFromZero))))
    }

    /// k-means++ on the 2D layout (seeded; the web uses 7), at most 50 rounds, then each cluster's keywords, its
    /// minimum spanning tree and the tree's long jumps removed (an edge longer than 2.6 times the median edge). Empty
    /// clusters are dropped and the rest numbered in order. Fewer than 2 points make none. `posts[i]` belongs to
    /// `points[i]`.
    public static func build(points: [SIMD2<Double>], posts: [MapPost], seed: UInt64) -> [SkyConstellation] {
        build(points: points, words: SkyWords(posts: Array(posts.prefix(points.count))), seed: seed)
    }

    /// `build` with the posts' words already counted (the model keeps them for the neighbourhood labels).
    public static func build(points: [SIMD2<Double>], words: SkyWords, seed: UInt64) -> [SkyConstellation] {
        let n = points.count
        guard n >= 2 else { return [] }
        let k = clusterCount(for: n)
        var rng = SkyRNG(seed: seed)

        var centres = [points[Int((rng.next() * Double(n)).rounded(.down))]]
        while centres.count < k {
            var d2 = [Double](repeating: 0, count: n)
            var total = 0.0
            for i in 0..<n {
                var best = Double.infinity
                for c in centres { best = min(best, distanceSquared(points[i], c)) }
                d2[i] = best
                total += best
            }
            var pick = rng.next() * total
            var chosen = 0
            for i in 0..<n {
                pick -= d2[i]
                if pick <= 0 { chosen = i; break }
            }
            centres.append(points[chosen])
        }

        var assignment = [Int](repeating: -1, count: n)
        for _ in 0..<50 {
            var moved = false
            for i in 0..<n {
                var bestIndex = 0, bestDistance = Double.infinity
                for j in 0..<k {
                    let d = distanceSquared(points[i], centres[j])
                    if d < bestDistance { bestDistance = d; bestIndex = j }
                }
                if assignment[i] != bestIndex { assignment[i] = bestIndex; moved = true }
            }
            var sums = [SIMD2<Double>](repeating: .zero, count: k)
            var counts = [Int](repeating: 0, count: k)
            for i in 0..<n { sums[assignment[i]] += points[i]; counts[assignment[i]] += 1 }
            for j in 0..<k where counts[j] > 0 { centres[j] = sums[j] / Double(counts[j]) }
            if !moved { break }
        }

        var out: [SkyConstellation] = []
        for j in 0..<k {
            let members = (0..<n).filter { assignment[$0] == j }
            if members.isEmpty { continue }
            let id = out.count
            let keywords = members.count >= 2 ? words.keywords(of: members, max: 3) : []
            var edges: [SkyEdge] = []
            let tree = minimumSpanningTree(members, points)
            if !tree.isEmpty {
                let lengths = tree.map(\.length).sorted()
                let cut = lengths[lengths.count / 2] * 2.6
                edges = tree.filter { $0.length <= cut }.map { SkyEdge(a: $0.a, b: $0.b) }
            }
            out.append(SkyConstellation(
                id: id, members: members, keywords: keywords, edges: edges, hue: id % SkyPalette.count,
                centroid: centres[j], top: members.map { points[$0].y }.min() ?? 0))
        }
        return out
    }

    /// How many star lines meet at each point: the web's `deg`, which makes the hubs of a constellation brighter.
    public static func degrees(of constellations: [SkyConstellation], count: Int) -> [Int] {
        var degree = [Int](repeating: 0, count: count)
        for c in constellations {
            for e in c.edges where e.a < count && e.b < count { degree[e.a] += 1; degree[e.b] += 1 }
        }
        return degree
    }

    /// For each point, the id of its constellation, or -1.
    public static func membership(of constellations: [SkyConstellation], count: Int) -> [Int] {
        var of = [Int](repeating: -1, count: count)
        for c in constellations { for m in c.members where m < count { of[m] = c.id } }
        return of
    }

    // MARK: - Minimum spanning tree (Prim, as `mst` in page.html 1554)

    struct TreeEdge: Equatable {
        var a: Int
        var b: Int
        var length: Double
    }

    static func minimumSpanningTree(_ idx: [Int], _ points: [SIMD2<Double>]) -> [TreeEdge] {
        let m = idx.count
        guard m >= 2 else { return [] }
        var inTree = [Bool](repeating: false, count: m)
        var dist = [Double](repeating: .infinity, count: m)
        var from = [Int](repeating: -1, count: m)
        var out: [TreeEdge] = []
        dist[0] = 0
        for _ in 0..<m {
            var u = -1
            for i in 0..<m where !inTree[i] && (u < 0 || dist[i] < dist[u]) { u = i }
            inTree[u] = true
            if from[u] >= 0 { out.append(TreeEdge(a: idx[from[u]], b: idx[u], length: dist[u].squareRoot())) }
            for v in 0..<m where !inTree[v] {
                let d = distanceSquared(points[idx[u]], points[idx[v]])
                if d < dist[v] { dist[v] = d; from[v] = u }
            }
        }
        return out
    }

    private static func distanceSquared(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = a - b
        return d.x * d.x + d.y * d.y
    }
}

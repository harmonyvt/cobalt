import Dispatch
import Foundation

/// Exact t-SNE over the posts' embeddings, a port of the web's `tsneInit` / `tsneStep` (page.html 1405 to 1467): posts
/// with similar meaning land close together. Cosine distance on unit vectors, perplexity `max(2, min(30, (n-1)/3))`,
/// learning rate `max(n/48, 50)`, early exaggeration 12 for 100 iterations, momentum 0.5 then 0.8 from iteration 250,
/// gains (+0.2 / x0.8, floor 0.01), the layout re-centred after every step, 650 iterations.
///
/// A value you step by hand (`while t.step() {}`) so the caller can show it settling: read `points` between steps.
/// Deterministic for a seed. At most `SkyMap.maxPosts` vectors are used (the first ones: newest first, like the web).
/// With fewer than 3 vectors there is nothing to lay out: the points sit on a line and `iterations` is 0.
public struct SkyTSNE: Sendable {
    /// How many steps this run takes in all (0 for fewer than 3 posts).
    public let iterations: Int
    /// How many steps have run.
    public private(set) var iteration: Int = 0

    private let n: Int
    private let learningRate: Double
    private let affinities: [Double]        // P, n x n, symmetric, zero diagonal
    private var layout: [Double]            // x0, y0, x1, y1, ...
    private var gains: [Double]
    private var velocity: [Double]
    private var attraction: [Double]
    private var repulsion: [Double]
    private var rowSums: [Double]

    /// The layout now, one point per vector, centred on the origin. Not yet scaled to any box: see
    /// `SkyMap.fitToUnitSquare`.
    public var points: [SIMD2<Double>] {
        (0..<n).map { SIMD2(layout[2 * $0], layout[2 * $0 + 1]) }
    }

    /// Computes the affinities (the slow part: about n squared times the vector size, spread over the cores) and the
    /// seeded starting scatter. `iterations` is a test hook; the app always runs `SkyMap.iterations`.
    public init(vectors: [[Float]], seed: UInt64, iterations: Int = SkyMap.iterations) {
        let n = min(vectors.count, SkyMap.maxPosts)
        self.n = n
        self.learningRate = max(Double(n) / 12 / 4, 50)
        self.gains = Array(repeating: 1, count: 2 * n)
        self.velocity = Array(repeating: 0, count: 2 * n)
        self.attraction = Array(repeating: 0, count: 2 * n)
        self.repulsion = Array(repeating: 0, count: 2 * n)
        self.rowSums = Array(repeating: 0, count: n)
        if n < 3 {
            self.iterations = 0
            self.affinities = []
            var line = Array(repeating: 0.0, count: 2 * n)
            for i in 0..<n { line[2 * i] = Double(i) }
            self.layout = line
            return
        }
        self.iterations = max(0, iterations)
        self.affinities = Self.makeAffinities(vectors: vectors, n: n)
        var rng = SkyRNG(seed: seed)
        var y = Array(repeating: 0.0, count: 2 * n)
        for i in 0..<(2 * n) { y[i] = (rng.next() - 0.5) * 1e-2 }
        self.layout = y
    }

    /// One iteration. Returns true while more remain, false once the run is finished (the call that ran the last
    /// iteration returns false, and so does every call after it, which does nothing).
    @discardableResult
    public mutating func step() -> Bool {
        guard iteration < iterations else { return false }
        let n = self.n
        let exaggeration = iteration < 100 ? 12.0 : 1.0
        let momentum = iteration < 250 ? 0.5 : 0.8

        // The gradient of the KL divergence. With q = 1 / (1 + d^2) and Z the sum of every q, the force on point i is
        // sum_j (exag * P - q / Z) * q * (y_i - y_j). It is computed as an attraction part (exag * P * q) and a repulsion
        // part (q * q), so the n x n matrix of q is never stored and Z is only needed at the end of the pass.
        let rowsPerChunk = 32
        let chunks = (n + rowsPerChunk - 1) / rowsPerChunk
        affinities.withUnsafeBufferPointer { p in
            layout.withUnsafeBufferPointer { y in
                attraction.withUnsafeMutableBufferPointer { a in
                    repulsion.withUnsafeMutableBufferPointer { r in
                        rowSums.withUnsafeMutableBufferPointer { z in
                            let buffers = StepBuffers(p: p.baseAddress!, y: y.baseAddress!, a: a.baseAddress!, r: r.baseAddress!, z: z.baseAddress!)
                            let work: @Sendable (Int) -> Void = { chunk in
                                let lo = chunk * rowsPerChunk, hi = min(n, lo + rowsPerChunk)
                                for i in lo..<hi { Self.forceRow(i, n: n, exaggeration: exaggeration, buffers) }
                            }
                            if n >= 256 {
                                DispatchQueue.concurrentPerform(iterations: chunks, execute: work)
                            } else {
                                for chunk in 0..<chunks { work(chunk) }
                            }
                        }
                    }
                }
            }
        }
        var z = 0.0
        for i in 0..<n { z += rowSums[i] }
        if z == 0 { z = 1e-12 }

        for i in 0..<(2 * n) {
            let g = 4 * (attraction[i] - repulsion[i] / z)
            let same = (g > 0) == (velocity[i] > 0)
            gains[i] = max(0.01, same ? gains[i] * 0.8 : gains[i] + 0.2)
            velocity[i] = momentum * velocity[i] - learningRate * gains[i] * g
            layout[i] += velocity[i]
        }
        // keep it centred
        var mx = 0.0, my = 0.0
        for i in 0..<n { mx += layout[2 * i]; my += layout[2 * i + 1] }
        mx /= Double(n); my /= Double(n)
        for i in 0..<n { layout[2 * i] -= mx; layout[2 * i + 1] -= my }

        iteration += 1
        return iteration < iterations
    }

    // MARK: - The force on one point

    private struct StepBuffers: @unchecked Sendable {
        let p: UnsafePointer<Double>
        let y: UnsafePointer<Double>
        let a: UnsafeMutablePointer<Double>
        let r: UnsafeMutablePointer<Double>
        let z: UnsafeMutablePointer<Double>
    }

    /// Row `i` of the pass: its attraction and repulsion sums and its share of Z. Rows are independent, so they run in
    /// parallel and the result does not depend on how they are scheduled.
    private static func forceRow(_ i: Int, n: Int, exaggeration: Double, _ b: StepBuffers) {
        let xi = b.y[2 * i], yi = b.y[2 * i + 1]
        let row = b.p + i * n
        var zi = 0.0, ax = 0.0, ay = 0.0, rx = 0.0, ry = 0.0
        for j in 0..<n {
            let dx = xi - b.y[2 * j], dy = yi - b.y[2 * j + 1]
            let q = 1 / (1 + dx * dx + dy * dy)
            zi += q
            let pq = exaggeration * row[j] * q
            let qq = q * q
            ax += pq * dx; ay += pq * dy
            rx += qq * dx; ry += qq * dy
        }
        // j == i contributed q = 1 to Z and nothing to the forces (dx = dy = 0)
        b.z[i] = zi - 1
        b.a[2 * i] = ax; b.a[2 * i + 1] = ay
        b.r[2 * i] = rx; b.r[2 * i + 1] = ry
    }

    // MARK: - Affinities (tsneInit)

    private struct AffinityBuffers: @unchecked Sendable {
        let v: UnsafePointer<Float>
        let p: UnsafeMutablePointer<Double>
    }

    private static func makeAffinities(vectors: [[Float]], n: Int) -> [Double] {
        let d = vectors.first?.count ?? 0
        // unit vectors, side by side
        var flat = Array(repeating: Float(0), count: n * d)
        for i in 0..<n {
            let unit = SkyMap.normalized(vectors[i])
            for k in 0..<min(d, unit.count) { flat[i * d + k] = unit[k] }
        }
        var p = Array(repeating: 0.0, count: n * n)
        let perplexity = max(2, min(30, Double(n - 1) / 3))
        let target = log(perplexity)
        let rowsPerChunk = 16
        let chunks = (n + rowsPerChunk - 1) / rowsPerChunk
        flat.withUnsafeBufferPointer { v in
            p.withUnsafeMutableBufferPointer { out in
                let buffers = AffinityBuffers(v: v.baseAddress!, p: out.baseAddress!)
                let work: @Sendable (Int) -> Void = { chunk in
                    var dist = Array(repeating: 0.0, count: n)
                    let lo = chunk * rowsPerChunk, hi = min(n, lo + rowsPerChunk)
                    for i in lo..<hi { affinityRow(i, n: n, d: d, target: target, dist: &dist, buffers) }
                }
                if n >= 64 {
                    DispatchQueue.concurrentPerform(iterations: chunks, execute: work)
                } else {
                    for chunk in 0..<chunks { work(chunk) }
                }
            }
        }
        // symmetrise: (P_ij + P_ji) / 2n, floored
        for i in 0..<n {
            for j in (i + 1)..<n {
                let s = max((p[i * n + j] + p[j * n + i]) / Double(2 * n), 1e-12)
                p[i * n + j] = s; p[j * n + i] = s
            }
        }
        return p
    }

    /// One row of P: the Gaussian width found by bisection (60 tries, until the entropy hits the perplexity).
    private static func affinityRow(_ i: Int, n: Int, d: Int, target: Double, dist: inout [Double], _ b: AffinityBuffers) {
        let vi = b.v + i * d
        for j in 0..<n {
            if j == i { dist[j] = 0; continue }
            let vj = b.v + j * d
            var dot = 0.0
            for k in 0..<d { dot += Double(vi[k]) * Double(vj[k]) }
            dist[j] = max(0, 2 - 2 * dot)
        }
        let row = b.p + i * n
        var lo = 0.0, hi = Double.infinity, beta = 1.0
        for _ in 0..<60 {
            var sum = 0.0, hsum = 0.0
            for j in 0..<n where j != i {
                let e = exp(-dist[j] * beta)
                row[j] = e; sum += e; hsum += dist[j] * e
            }
            if sum == 0 { sum = 1e-12 }
            let h = log(sum) + beta * hsum / sum
            for j in 0..<n where j != i { row[j] /= sum }
            if abs(h - target) < 1e-5 { break }
            if h > target {
                lo = beta
                beta = hi == .infinity ? beta * 2 : (beta + hi) / 2
            } else {
                hi = beta
                beta = (beta + lo) / 2
            }
        }
        row[i] = 0
    }
}

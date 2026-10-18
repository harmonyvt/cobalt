import Foundation
import Observation

/// The library as a sky map (APP-API-CONTRACT 21, `GET /library/map`): fetches every embedded post, lays the vectors out
/// in 2D with t-SNE off the main actor while publishing a snapshot about every 50 ms (the UI animates the stars settling,
/// like the web), then groups them into constellations with their nebulae. The finished layout is kept in memory by the
/// set of post ids, so reopening the map does not compute it again. Reads the app model's current client on every
/// call; `reset()` (a new server) forgets everything.
@MainActor @Observable
public final class SkyMapModel {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Fetching `GET /library/map`.
        case loading
        /// The posts are in and the stars are settling: `points` is the latest snapshot. `progress` is 0...1.
        case laying(progress: Double)
        /// Settled: `constellations` and `nebulae` are filled.
        case ready
        /// The fetch failed, with a message to show. A map that was already on screen stays instead.
        case failed(String)
        /// The server has no embedded posts.
        case empty
    }

    public private(set) var phase: Phase = .idle
    /// The posts on the map, newest first, at most `SkyMap.maxPosts`. `points[i]` is where `posts[i]` sits.
    public private(set) var posts: [MapPost] = []
    /// The latest layout, one point per post, fitted to the unit square (the longer side spans 0...1). While `laying`
    /// this is the newest snapshot; once settled it is final.
    public private(set) var points: [SIMD2<Double>] = []
    /// Filled when settled; coordinates in the same unit square.
    public private(set) var constellations: [SkyConstellation] = []
    /// One per constellation, in order, over `bounds.nebulaBox`.
    public private(set) var nebulae: [SkyNebula] = []
    /// Live posts the server has no vector for yet.
    public private(set) var unmapped = 0
    /// How many star lines meet at each post (the stars with 3 or more are the hubs); filled when settled.
    public private(set) var degrees: [Int] = []
    /// The id of each post's constellation, or -1; filled when settled.
    public private(set) var constellationOf: [Int] = []
    /// The settled layout's box (`SkyBounds(points: points)`).
    public private(set) var bounds = SkyBounds(minX: 0, minY: 0, maxX: 1, maxY: 1)

    private struct Settled {
        var signature: [String]
        var result: SkyLayoutResult
    }

    @ObservationIgnored private let ctx: PipelineContext
    /// Bumped by `reset()`, `cancel()` and every `load()`: whatever an older run says afterwards is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var settled: Settled?
    @ObservationIgnored private var words: SkyWords?
    /// The t-SNE length; tests make it shorter.
    @ObservationIgnored var iterations = SkyMap.iterations
    /// How many layouts this model has computed (the cache serves the rest); tests read it.
    @ObservationIgnored private(set) var layouts = 0

    init(context: PipelineContext) {
        self.ctx = context
    }

    // MARK: - Loading

    /// Fetches the map and lays it out. Returns when the sky is ready (or failed, or empty), or was cancelled. A second
    /// call while one runs cancels it and starts over. If the calling task is cancelled the layout stops.
    public func load() async {
        generation += 1
        let gen = generation
        run?.cancel()
        let task = Task { @MainActor [self] in await self.perform(gen) }
        run = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Stops the fetch or the layout. A sky that had settled stays; a half-laid one is dropped.
    public func cancel() {
        generation += 1
        run?.cancel()
        run = nil
        if settledIsShown { phase = .ready } else { clearSky(); phase = .idle }
    }

    /// A new server: nothing from the old one is kept.
    func reset() {
        generation += 1
        run?.cancel()
        run = nil
        settled = nil
        clearSky()
        unmapped = 0
        phase = .idle
    }

    /// True while the posts on screen have a finished layout.
    @ObservationIgnored private var settledIsShown = false

    private func clearSky() {
        posts = []; points = []; constellations = []; nebulae = []; degrees = []; constellationOf = []
        words = nil
        settledIsShown = false
    }

    private func perform(_ gen: Int) async {
        if !settledIsShown { phase = .loading }          // a map on screen stays while it is fetched again
        let map: LibraryMap
        do {
            map = try await ctx.client.libraryMap()
        } catch {
            guard gen == generation else { return }
            if Task.isCancelled || error is CancellationError {
                finishCancelled()
            } else if !settledIsShown {
                clearSky()
                phase = .failed(Self.message(for: error))
            }
            return
        }
        guard gen == generation else { return }
        if Task.isCancelled { return finishCancelled() }

        let capped = Array(map.posts.prefix(SkyMap.maxPosts))
        unmapped = map.unmapped
        guard !capped.isEmpty else {
            settled = nil
            clearSky()
            phase = .empty
            return
        }
        let signature = capped.map(\.id)
        if let settled, settled.signature == signature {
            posts = capped
            publish(settled.result)
            return
        }

        settled = nil
        clearSky()
        posts = capped
        phase = .laying(progress: 0)
        layouts += 1
        guard let result = await layOut(capped, generation: gen) else {
            if gen == generation { finishCancelled() }
            return
        }
        guard gen == generation else { return }
        settled = Settled(signature: signature, result: result)
        publish(result)
    }

    private func finishCancelled() {
        if settledIsShown { phase = .ready } else { clearSky(); phase = .idle }
    }

    private func publish(_ result: SkyLayoutResult) {
        points = result.points
        constellations = result.constellations
        nebulae = result.nebulae
        degrees = result.degrees
        constellationOf = result.membership
        bounds = result.bounds
        words = result.words
        settledIsShown = true
        phase = .ready
    }

    /// The t-SNE and what follows it on a detached task; its snapshots reach the main actor through a stream that keeps
    /// only the newest, so a slow screen never queues them up.
    private func layOut(_ posts: [MapPost], generation gen: Int) async -> SkyLayoutResult? {
        let iterations = self.iterations
        let (stream, continuation) = AsyncStream.makeStream(of: SkyLayoutSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task.detached(priority: .userInitiated) { () -> SkyLayoutResult? in
            defer { continuation.finish() }
            return SkyMapLayout.run(posts: posts, iterations: iterations) { continuation.yield($0) }
        }
        return await withTaskCancellationHandler {
            for await snapshot in stream where gen == generation {
                points = snapshot.points
                phase = .laying(progress: snapshot.progress)
            }
            return await worker.value
        } onCancel: {
            worker.cancel()
            continuation.finish()
        }
    }

    // MARK: - Around one post

    /// The `count` posts closest in meaning to `posts[index]` (cosine), nearest first. For the post's detail.
    public func neighbours(of index: Int, count: Int = 6) -> [Int] {
        guard posts.indices.contains(index) else { return [] }
        let own = SkyMap.normalized(posts[index].vector)
        let scored = posts.indices.filter { $0 != index }.map { j -> (index: Int, score: Float) in
            let other = SkyMap.normalized(posts[j].vector)
            var s: Float = 0
            for k in 0..<min(own.count, other.count) { s += own[k] * other[k] }
            return (j, s)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(count).map(\.index)
    }

    /// "What its neighbourhood is about": the keywords of the post and its 10 nearest, at most `max`. Empty until the
    /// sky has settled.
    public func neighbourhoodKeywords(of index: Int, max count: Int = 6) -> [String] {
        guard let words, posts.indices.contains(index) else { return [] }
        return words.keywords(of: [index] + neighbours(of: index, count: 10), max: count)
    }

    // MARK: - Messages

    static func message(for error: Error) -> String {
        switch error {
        case PipelineFailure.unsupported: return "This server has no sky map."
        case CobaltError.network: return "Can't reach the server."
        case CobaltError.noAPIKey: return "No API key."
        case CobaltError.api(let code, _) where code.hasPrefix("error.api.auth.key."): return "The API key was refused."
        case CobaltError.api, CobaltError.invalidResponse: return "The server can't load the map right now."
        case is CancellationError: return "Cancelled."
        default: return "Something went wrong."
        }
    }
}

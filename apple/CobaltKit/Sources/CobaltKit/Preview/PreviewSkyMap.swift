import Foundation

extension PreviewScenario {
    /// The preview server answers `GET /library/map` (APP-API-CONTRACT 21). Only `.skyMap` also has `features.search`.
    var hasSkyMap: Bool {
        switch self {
        case .happy, .renditions, .skyMap: return true
        default: return false
        }
    }
}

extension PreviewData {
    /// One synthetic island of the mock sky: posts about one thing, close together in meaning.
    struct SkyCluster {
        /// Said by every post of the cluster, so the constellation's label is certain.
        var signature: String
        /// What the posts are about, a few of them in each title.
        var topics: [String]
        /// The file extension and the link's host and path.
        var host: String
    }

    static let skyClusters: [SkyCluster] = [
        SkyCluster(signature: "cat", topics: ["kitten", "sofa", "jump", "fail", "whiskers", "purring", "zoomies"], host: "instagram.com/reel"),
        SkyCluster(signature: "minecraft", topics: ["creeper", "redstone", "survival", "speedrun", "village", "build"], host: "x.com/i/status"),
        SkyCluster(signature: "anime", topics: ["opening", "episode", "fight", "sakura", "amv", "studio"], host: "instagram.com/reel"),
        SkyCluster(signature: "cooking", topics: ["recipe", "pasta", "kitchen", "dinner", "knife", "timer"], host: "instagram.com/reel"),
        SkyCluster(signature: "coffee", topics: ["latte", "cafe", "espresso", "beans", "pour", "morning"], host: "x.com/i/status"),
        SkyCluster(signature: "harbour", topics: ["boats", "sunset", "waves", "dock", "fishing", "sailing"], host: "instagram.com/reel"),
        SkyCluster(signature: "guitar", topics: ["chords", "riff", "solo", "amp", "practice", "cover"], host: "x.com/i/status"),
        SkyCluster(signature: "skate", topics: ["kickflip", "ramp", "park", "trick", "board", "session"], host: "instagram.com/reel"),
    ]

    /// `GET /library/map` for the preview: about 150 posts (about 19 in each of 8 clusters, interleaved newest first, every 12th between two topics) with
    /// 256-number vectors made the way the server makes them (a cluster's centre plus noise, int8, largest component
    /// 127), cluster-themed titles and file names, the preview posters for images, a few without a title or an image,
    /// and 3 posts the server has no vector for yet. Deterministic.
    static func skyMap(now: Date, count: Int = 150) -> LibraryMap {
        let dims = 256
        var rng = SkyRNG(seed: 2026)
        // the topics share part of their direction (they are all short clips), so the islands sit close enough to read as
        // one sky, and the posts between two topics bridge them
        let shared: [Float] = (0..<dims).map { _ in Float(rng.next() - 0.5) }
        let centres: [[Float]] = skyClusters.map { _ in (0..<dims).map { 0.7 * shared[$0] + Float(rng.next() - 0.5) } }
        let posters = ["PrEvIeWp11", "PrEvIeWp22", "PrEvIeWp31", "PrEvIeWp32"]
        var posts: [MapPost] = []
        // per-post noise is wide (a post is only about as close to its cluster's centre as to a stranger's), so each
        // cluster spreads into a constellation with visible star lines; every 12th post sits between two topics
        let noiseScale: Float = 1.25
        let others = skyClusters.count - 1
        for i in 0..<count {
            let c = i % skyClusters.count
            let cluster = skyClusters[c]
            let noise = (0..<dims).map { _ in Float(rng.next() - 0.5) * noiseScale }
            let between = c + 1 + Int(rng.next() * Double(others))
            let mixed = i % 12 == 11
            let neighbour = skyClusters[between % skyClusters.count]
            var vector = zip(centres[c], noise).map { $0 + $1 }
            if mixed {
                let other = centres[between % skyClusters.count]
                vector = (0..<dims).map { 0.6 * centres[c][$0] + 0.5 * other[$0] + 0.8 * noise[$0] }
            }
            var words = [cluster.signature]
            if mixed { words.append(neighbour.signature) }
            while words.count < 3 {
                let w = cluster.topics[Int(rng.next() * Double(cluster.topics.count))]
                if !words.contains(w) { words.append(w) }
            }
            let key = String(format: "PrEvIeWmap%04d", i + 1)
            let file = words.joined(separator: "_") + ".mp4"
            let title = i % 7 == 6 ? nil : words.joined(separator: " ")
            posts.append(MapPost(
                id: key, title: title, text: "\(file) · \(cluster.host)/\(key)",
                imageURL: i % 5 == 4 ? nil : mediaBase.appendingPathComponent(posters[i % posters.count] + ".jpg"),
                latest: now.addingTimeInterval(-Double(i) * 3 * 3_600),
                vector: MapPost.decodeVector(base64: MapPost.encodeVector(vector)) ?? vector))
        }
        return LibraryMap(model: "google/embeddinggemma-2", dims: dims, searchEnabled: true, posts: posts, unmapped: 3)
    }
}

extension PreviewClient {
    /// `GET /library/map` after a short think (0.4 s on the clock, scaled): `PreviewData.skyMap`. A scenario without the
    /// route is a server that answers 404.
    public func libraryMap() async throws -> LibraryMap {
        try await clock.sleep(seconds: 0.4 * timeScale)
        guard scenario.hasSkyMap else { throw CobaltError.api(code: "error.api.generic", httpStatus: 404) }
        return PreviewData.skyMap(now: startedAt)
    }
}

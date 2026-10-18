import Foundation
import Testing
@testable import CobaltKit

// The sky map (APP-API-CONTRACT 21, `GET /library/map`; the maths ported from the web library's map, page.html 1323 to
// 1720): the wire, mulberry32, t-SNE, constellations, nebulae, the fingerprint and the model that runs them.

private let mapKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

// MARK: - Synthetic data

/// `clusters` blobs of `per` vectors in `dims` dimensions: a random centre per blob plus noise, in blob order.
private func blobVectors(clusters: Int, per: Int, dims: Int = 32, seed: UInt64 = 9) -> [[Float]] {
    var rng = SkyRNG(seed: seed)
    let centres = (0..<clusters).map { _ in (0..<dims).map { _ in Float(rng.next() - 0.5) } }
    return (0..<(clusters * per)).map { i in
        centres[i / per].map { $0 + Float(rng.next() - 0.5) * 0.3 }
    }
}

private func mapPost(_ i: Int, title: String?, text: String = "", vector: [Float] = [1, 0]) -> MapPost {
    MapPost(id: "p\(i)", title: title, text: text, imageURL: nil, latest: Date(timeIntervalSince1970: 1_790_000_000 - Double(i)), vector: vector)
}

/// `count` points in a tight blob around `(x, y)`.
private func blob(_ count: Int, _ x: Double, _ y: Double, spread: Double = 0.4, rng: inout SkyRNG) -> [SIMD2<Double>] {
    (0..<count).map { _ in SIMD2(x + (rng.next() - 0.5) * spread, y + (rng.next() - 0.5) * spread) }
}

private func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let d = a - b
    return (d.x * d.x + d.y * d.y).squareRoot()
}

private func finishedLayout(_ vectors: [[Float]], seed: UInt64 = SkyMap.layoutSeed, iterations: Int = SkyMap.iterations) -> SkyTSNE {
    var t = SkyTSNE(vectors: vectors, seed: seed, iterations: iterations)
    while t.step() {}
    return t
}

// MARK: - The wire

struct SkyMapWireTests {
    @Test func v8IsSignedBytesOverOneTwentySeven() {
        let bytes: [UInt8] = [127, 0, 0x81, 0x80, 1, 64]
        let decoded = MapPost.decodeVector(base64: Data(bytes).base64EncodedString())
        #expect(decoded.map { zip($0, [1, 0, -1, -128.0 / 127, 1.0 / 127, 64.0 / 127]).allSatisfy { abs($0 - Float($1)) < 1e-6 } } == true)
        #expect(decoded?.count == 6)
        #expect(MapPost.decodeVector(base64: "") == nil)
        #expect(MapPost.decodeVector(base64: "not base64 !!") == nil)
        // a missing pad is tolerated
        #expect(MapPost.decodeVector(base64: "fwA") == [1, 0])
    }

    @Test func theServersEncodingRoundTrips() {
        let v: [Float] = [0.5, -0.25, 0.1, -1.0]
        let back = MapPost.decodeVector(base64: MapPost.encodeVector(v))
        #expect(back?.count == 4)
        // largest component is +-127 on the wire, so +-1 here; the rest keep their ratios to within a byte
        #expect(back?[3] == -1)
        #expect(abs((back?[0] ?? 0) - 0.5) < 0.01 && abs((back?[1] ?? 0) + 0.25) < 0.01)
    }

    @Test func theMapDecodesAndDropsMalformedPosts() throws {
        let good = Data([127, 0, 0x81]).base64EncodedString()
        let json = """
        {"status":"success","model":"google/embeddinggemma-2","dims":3,"search_enabled":true,"unmapped":4,"posts":[
          {"post_key":"a","title":"A cat","text":"cat.mp4 · x.com/i/status/1","image_url":"https://media.example/a.jpg","latest":1790000000000,"v8":"\(good)"},
          {"post_key":"b","title":null,"text":"","image_url":null,"latest":1789999999000,"v8":"\(good)"},
          {"post_key":"","title":"no key","text":"","latest":1,"v8":"\(good)"},
          {"title":"missing key","text":"","latest":1,"v8":"\(good)"},
          {"post_key":"c","title":"bad vector","text":"","latest":1,"v8":"%%%"},
          {"post_key":"d","title":"empty vector","text":"","latest":1,"v8":""},
          {"post_key":"e","title":"no time","text":"","v8":"\(good)"},
          "garbage",
          {"post_key":"f","latest":1789999000000,"v8":"\(good)"}
        ]}
        """
        let map = try LibraryMap.decode(Data(json.utf8))
        #expect(map.model == "google/embeddinggemma-2" && map.dims == 3 && map.searchEnabled && map.unmapped == 4)
        #expect(map.posts.map(\.id) == ["a", "b", "f"])
        let a = try #require(map.posts.first)
        #expect(a.title == "A cat" && a.text == "cat.mp4 · x.com/i/status/1")
        #expect(a.imageURL == URL(string: "https://media.example/a.jpg"))
        #expect(a.latest == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(a.vector == [1, 0, -1])
        #expect(map.posts[1].title == nil && map.posts[1].imageURL == nil)
        #expect(map.posts[2].text == "")                                  // a missing text is empty
    }

    @Test func aBodyThatIsNotTheMapThrows() {
        #expect(throws: (any Error).self) { try LibraryMap.decode(Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try LibraryMap.decode(Data(#"{"status":"error","posts":[]}"#.utf8)) }
        #expect(throws: (any Error).self) { try LibraryMap.decode(Data("nope".utf8)) }
    }
}

@Suite(.serialized)
struct SkyMapHTTPTests {
    @Test func theMapIsAKeyedGetWithNoQuery() async throws {
        let v8 = Data([127, 5, 0xFB]).base64EncodedString()
        let server = try await LoopbackServer.start { req in
            guard req.path == "/library/map" else { return .init(status: 404) }
            return .json(#"{"status":"success","model":"m","dims":3,"search_enabled":false,"unmapped":1,"posts":[{"post_key":"p1","title":null,"text":"t","image_url":null,"latest":1790000000000,"v8":"\#(v8)"}]}"#)
        }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { mapKey })
        let map = try await client.libraryMap()
        let req = try #require(server.requests.first)
        #expect(req.method == "GET" && req.path == "/library/map" && req.query.isEmpty)
        #expect(req.headers["authorization"] == "Api-Key \(mapKey)")
        #expect(map.posts.map(\.id) == ["p1"] && map.unmapped == 1 && !map.searchEnabled)
        #expect(map.posts.first?.vector.count == 3)
        let wire = try #require(map.posts.first?.vector)
        #expect(wire[0] == 1 && abs(wire[1] - 5.0 / 127) < 1e-6 && abs(wire[2] + 5.0 / 127) < 1e-6)
    }

    @Test func noKeyNeverLeavesTheDevice() async throws {
        let server = try await LoopbackServer.start { _ in .json("{}") }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { nil })
        await #expect(throws: CobaltError.noAPIKey) { try await client.libraryMap() }
        #expect(server.requests.isEmpty)
    }

    @Test func errorsAreTheServersCodes() async throws {
        let server = try await LoopbackServer.start { req in
            switch req.headers["x-case"] ?? "" {
            default: return .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 503)
            }
        }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { mapKey })
        await #expect(throws: CobaltError.api(code: "error.api.generic", httpStatus: 503)) { try await client.libraryMap() }
    }

    @Test func aTwoHundredWithAnErrorEnvelopeIsAnErrorAndGarbageIsInvalid() async throws {
        let server = try await LoopbackServer.start { req in
            .json(req.target.contains("never") ? "x" : #"{"status":"error","error":{"code":"error.library.bad_request"}}"#)
        }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { mapKey })
        await #expect(throws: CobaltError.api(code: "error.library.bad_request", httpStatus: 200)) { try await client.libraryMap() }
        let garbage = try await LoopbackServer.start { _ in .json("<html>") }
        defer { garbage.stop() }
        let other = HTTPCobaltClient(baseURL: garbage.base, apiKey: { mapKey })
        await #expect(throws: CobaltError.invalidResponse(httpStatus: 200)) { try await other.libraryMap() }
    }

    @Test func aClientThatPredatesTheRouteIsUnsupported() async {
        let client = PreviewClient(scenario: .plainCobalt, timeScale: 0.01)
        await #expect(throws: CobaltError.api(code: "error.api.generic", httpStatus: 404)) { try await client.libraryMap() }
    }
}

// MARK: - mulberry32

struct SkyRNGTests {
    @Test func matchesTheWebsGenerator() {
        // the first values of the web's `rng(42)` and `rng(7)` (run in node)
        var a = SkyRNG(seed: 42)
        let first = (0..<4).map { _ in a.next() }
        let expected42 = [0.60110375192016363, 0.44829055899754167, 0.85246579349040985, 0.66973404143936932]
        for (x, y) in zip(first, expected42) { #expect(abs(x - y) < 1e-15) }
        var b = SkyRNG(seed: 7)
        let second = (0..<3).map { _ in b.next() }
        let expected7 = [0.011704753153026104, 0.061958257574588060, 0.97690763277933002]
        for (x, y) in zip(second, expected7) { #expect(abs(x - y) < 1e-15) }
    }

    @Test func aSeedMakesTheSameStream() {
        var a = SkyRNG(seed: 1), b = SkyRNG(seed: 1), c = SkyRNG(seed: 2)
        #expect((0..<10).map { _ in a.next() } == (0..<10).map { _ in b.next() })
        #expect(a.next() != c.next())
    }
}

// MARK: - t-SNE

struct SkyTSNETests {
    @Test func isDeterministicForASeed() {
        let vectors = blobVectors(clusters: 3, per: 10)
        let a = finishedLayout(vectors, iterations: 120)
        let b = finishedLayout(vectors, iterations: 120)
        #expect(a.points == b.points)
        #expect(finishedLayout(vectors, seed: 43, iterations: 120).points != a.points)
    }

    @Test func finishesAfterItsIterations() {
        var t = SkyTSNE(vectors: blobVectors(clusters: 2, per: 8), seed: 42, iterations: 25)
        #expect(t.iterations == 25 && t.iteration == 0)
        var steps = 0
        while t.step() { steps += 1 }
        #expect(t.iteration == 25 && steps == 24)               // the 25th call returns false
        let settled = t.points
        #expect(t.step() == false && t.iteration == 25 && t.points == settled)
        #expect(SkyTSNE(vectors: [], seed: 1).iterations == 0)
        #expect(SkyMap.iterations == 650 && SkyTSNE(vectors: blobVectors(clusters: 2, per: 5), seed: 1).iterations == 650)
    }

    @Test func startsAsATinyScatterAndStaysCentred() {
        var t = SkyTSNE(vectors: blobVectors(clusters: 3, per: 10), seed: 42, iterations: 30)
        #expect(t.points.allSatisfy { abs($0.x) <= 0.005 && abs($0.y) <= 0.005 })
        while t.step() {}
        let sum = t.points.reduce(SIMD2<Double>.zero, +)
        #expect(abs(sum.x) < 1e-9 && abs(sum.y) < 1e-9)
        #expect(t.points.contains { abs($0.x) > 0.05 || abs($0.y) > 0.05 })
    }

    @Test func wellSeparatedClustersEndUpSeparated() {
        let per = 20
        let t = finishedLayout(blobVectors(clusters: 3, per: per))
        let p = t.points
        #expect(p.count == 60)
        var intra = 0.0, inter = 0.0, nIntra = 0, nInter = 0
        for i in 0..<p.count {
            for j in (i + 1)..<p.count {
                if i / per == j / per { intra += distance(p[i], p[j]); nIntra += 1 } else { inter += distance(p[i], p[j]); nInter += 1 }
            }
        }
        let meanIntra = intra / Double(nIntra), meanInter = inter / Double(nInter)
        #expect(meanIntra * 3 < meanInter, "intra \(meanIntra), inter \(meanInter)")
        // and every point is nearer its own cluster's centre than any other cluster's
        let centres = (0..<3).map { c in (0..<per).reduce(SIMD2<Double>.zero) { $0 + p[c * per + $1] } / Double(per) }
        for i in 0..<p.count {
            let own = distance(p[i], centres[i / per])
            #expect((0..<3).filter { $0 != i / per }.allSatisfy { distance(p[i], centres[$0]) > own })
        }
    }

    @Test func fewerThanThreePostsAreJustPlaced() {
        var one = SkyTSNE(vectors: [[1, 0]], seed: 1)
        #expect(one.iterations == 0 && one.points == [SIMD2(0, 0)] && one.step() == false)
        let two = SkyTSNE(vectors: [[1, 0], [0, 1]], seed: 1)
        #expect(two.points == [SIMD2(0, 0), SIMD2(1, 0)])
    }

    @Test func unitSquareFitKeepsTheShape() {
        let fitted = SkyMap.fitToUnitSquare([SIMD2(-2, 0), SIMD2(2, 1), SIMD2(0, 0.5)])
        #expect(fitted == [SIMD2(0, 0.375), SIMD2(1, 0.625), SIMD2(0.5, 0.5)])
        #expect(SkyMap.fitToUnitSquare([SIMD2(3, 3)]) == [SIMD2(0.5, 0.5)])
        #expect(SkyMap.fitToUnitSquare([]).isEmpty)
        let tall = SkyMap.fitToUnitSquare([SIMD2(0, 0), SIMD2(1, 4)])
        #expect(tall == [SIMD2(0.375, 0), SIMD2(0.625, 1)])
    }
}

// MARK: - Words and constellations

struct SkyWordsTests {
    @Test func wordsAreLowerCaseDistinctAndLeaveTheHostOut() {
        let post = mapPost(1, title: "Cat Sofa Fail", text: "cat_sofa.mp4 · instagram.com/reel/Dd55fEyN1Yy")
        #expect(SkyWords.words(of: post) == ["cat", "sofa", "fail"])
        // stop words, digits, too short and too long words go
        let noisy = mapPost(2, title: "The video 2024 of an ox and zebra-crossing", text: String(repeating: "x", count: 25) + " · www.example.com/status/orange")
        #expect(SkyWords.words(of: noisy) == ["zebra", "crossing", "orange"])
        // a path stays, a host with a port or a file name that is not a host stays too
        #expect(SkyWords.strippingHost("www.instagram.com/reel/x") == " /reel/x")
        #expect(SkyWords.strippingHost("example.com") == " ")
        #expect(SkyWords.strippingHost("localhost:8080/x") == "localhost:8080/x")
        #expect(SkyWords.strippingHost("clip2.mp4") == "clip2.mp4")
        #expect(SkyWords.strippingHost("kitchen timer") == "kitchen timer")
        #expect(SkyWords.words(of: mapPost(3, title: "Café ünïcode 日本語", text: "")) == ["café", "ünïcode", "日本語"])
    }

    @Test func keywordsPreferWhatTheGroupSharesAndTheLibraryLacks() {
        var posts: [MapPost] = []
        for i in 0..<6 { posts.append(mapPost(i, title: "cat \(["sofa", "jump", "fail", "nap", "box", "nap"][i])")) }
        for i in 6..<12 { posts.append(mapPost(i, title: "dog \(["park", "ball", "swim", "nap", "walk", "fetch"][i - 6])")) }
        let words = SkyWords(posts: posts)
        #expect(words.keywords(of: Array(0..<6), max: 3).first == "cat")
        #expect(words.keywords(of: Array(6..<12), max: 3).first == "dog")
        // "nap" is in 2 cat posts and 1 dog post: it follows the group's own word
        let cat = words.keywords(of: Array(0..<6), max: 3)
        #expect(cat == ["cat", "nap"])
        // 4 or more posts need a word in 2 of them: the one-off "sofa" cannot be a keyword
        #expect(!cat.contains("sofa") && !cat.contains("jump"))
        // fewer than 4 posts: one is enough, alphabetical on ties
        #expect(words.keywords(of: [0, 1], max: 10).first == "cat")
        #expect(words.keywords(of: [], max: 3).isEmpty)
    }
}

struct SkyConstellationTests {
    private struct Sky {
        var points: [SIMD2<Double>]
        var posts: [MapPost]
    }

    /// Three far-apart blobs of 10 posts about cats, minecraft and cooking.
    private func threeBlobs() -> Sky {
        var rng = SkyRNG(seed: 3)
        let themes = [
            ("cat", ["sofa", "jump", "fail", "nap", "box"]),
            ("minecraft", ["creeper", "redstone", "build", "speedrun", "village"]),
            ("cooking", ["pasta", "recipe", "kitchen", "knife", "dinner"]),
        ]
        let centres = [SIMD2(0.1, 0.1), SIMD2(0.9, 0.2), SIMD2(0.5, 0.95)]
        var points: [SIMD2<Double>] = [], posts: [MapPost] = []
        for (c, theme) in themes.enumerated() {
            points += blob(10, centres[c].x, centres[c].y, spread: 0.08, rng: &rng)
            for i in 0..<10 {
                posts.append(mapPost(c * 10 + i, title: "\(theme.0) \(theme.1[i % 5]) \(theme.1[(i + 2) % 5])"))
            }
        }
        return Sky(points: points, posts: posts)
    }

    @Test func clusterCountFollowsTheWebsRule() {
        #expect(SkyConstellations.clusterCount(for: 2) == 1 && SkyConstellations.clusterCount(for: 7) == 1)
        #expect(SkyConstellations.clusterCount(for: 8) == 2)                           // sqrt(3.2) = 1.8 -> 2
        #expect(SkyConstellations.clusterCount(for: 30) == 3)                          // sqrt(12) = 3.46 -> 3
        #expect(SkyConstellations.clusterCount(for: 150) == 8)                         // sqrt(60) = 7.75 -> 8
        #expect(SkyConstellations.clusterCount(for: 3000) == 12)                       // sqrt(1200) = 34 -> capped
    }

    @Test func everyPointIsInExactlyOneConstellationAndTheBlobsAreFound() {
        let sky = threeBlobs()
        let built = SkyConstellations.build(points: sky.points, posts: sky.posts, seed: SkyMap.constellationSeed)
        #expect(built.count == 3)
        #expect(built.flatMap(\.members).sorted() == Array(0..<30))
        for c in built {
            #expect(c.members.count == 10)
            #expect(Set(c.members.map { $0 / 10 }).count == 1, "constellation \(c.id) mixes blobs: \(c.members)")
            #expect(c.members == c.members.sorted())
        }
        #expect(built.map(\.id) == [0, 1, 2])
        let membership = SkyConstellations.membership(of: built, count: 30)
        #expect(membership.allSatisfy { $0 >= 0 } && Set(membership).count == 3)
    }

    @Test func isDeterministic() {
        let sky = threeBlobs()
        let a = SkyConstellations.build(points: sky.points, posts: sky.posts, seed: 7)
        let b = SkyConstellations.build(points: sky.points, posts: sky.posts, seed: 7)
        #expect(a == b)
    }

    @Test func edgesAreTheSpanningTreeMinusLongJumps() {
        let sky = threeBlobs()
        let built = SkyConstellations.build(points: sky.points, posts: sky.posts, seed: 7)
        for c in built {
            // a tight blob has no long jump: a tree over the members, members - 1 edges, all inside the constellation
            #expect(c.edges.count == c.members.count - 1)
            #expect(c.edges.allSatisfy { c.members.contains($0.a) && c.members.contains($0.b) && $0.a != $0.b })
            // connected: every member reachable
            var reached: Set<Int> = [c.members[0]]
            var grew = true
            while grew {
                grew = false
                for e in c.edges where reached.contains(e.a) != reached.contains(e.b) {
                    reached.insert(e.a); reached.insert(e.b); grew = true
                }
            }
            #expect(reached == Set(c.members))
        }
        #expect(SkyConstellations.degrees(of: built, count: 30).reduce(0, +) == 2 * built.reduce(0) { $0 + $1.edges.count })
    }

    @Test func aLongJumpIsCut() {
        // 7 posts make one constellation (under 8); six sit in a row 1 apart and one is 95 away
        let points: [SIMD2<Double>] = [0, 1, 2, 3, 4, 5, 100].map { SIMD2($0, 0) }
        let posts = (0..<7).map { mapPost($0, title: "star \($0)") }
        let built = SkyConstellations.build(points: points, posts: posts, seed: 7)
        #expect(built.count == 1 && built[0].members == Array(0..<7))
        // the tree has 6 edges (five of length 1, one of 95); the cut is 2.6 x the median (1) so the 95 goes
        #expect(built[0].edges.count == 5)
        #expect(!built[0].edges.contains { $0.a == 6 || $0.b == 6 })
        let tree = SkyConstellations.minimumSpanningTree(Array(0..<7), points)
        #expect(tree.count == 6 && tree.map(\.length).sorted() == [1, 1, 1, 1, 1, 95])
        #expect(built[0].centroid == SIMD2(115.0 / 7, 0) && built[0].top == 0)
    }

    @Test func keywordsComeFromTheMembersTitlesAndTexts() {
        let sky = threeBlobs()
        let built = SkyConstellations.build(points: sky.points, posts: sky.posts, seed: 7)
        for c in built {
            let signature = ["cat", "minecraft", "cooking"][c.members[0] / 10]
            #expect(c.keywords.first == signature, "\(c.keywords)")
            #expect(c.keywords.count <= 3)
            let used = Set(c.members.flatMap { SkyWords.words(of: sky.posts[$0]) })
            #expect(c.keywords.allSatisfy { used.contains($0) })
        }
    }

    @Test func aLoneStarHasNoLabelAndFewerThanTwoPointsMakeNothing() {
        #expect(SkyConstellations.build(points: [SIMD2(0, 0)], posts: [mapPost(0, title: "cat")], seed: 7).isEmpty)
        #expect(SkyConstellations.build(points: [], posts: [], seed: 7).isEmpty)
        let two = SkyConstellations.build(points: [SIMD2(0, 0), SIMD2(1, 1)], posts: [mapPost(0, title: "cat"), mapPost(1, title: "cat")], seed: 7)
        #expect(two.count == 1 && two[0].keywords == ["cat"] && two[0].edges == [SkyEdge(a: 0, b: 1)])
    }

    @Test func hueIndicesCycleThroughTheTen() {
        var rng = SkyRNG(seed: 5)
        let points = (0..<400).map { _ in SIMD2(rng.next(), rng.next()) }
        let posts = (0..<400).map { mapPost($0, title: "star") }
        let built = SkyConstellations.build(points: points, posts: posts, seed: 7)
        #expect(built.count > 10)                                              // k = round(sqrt(160)) = 13
        #expect(built.map(\.id) == Array(0..<built.count))
        #expect(built.allSatisfy { $0.hue == $0.id % 10 })
        #expect(built.contains { $0.id >= 10 && $0.hue == $0.id - 10 })
        #expect(built.flatMap(\.members).sorted() == Array(0..<400))
    }
}

// MARK: - Palette, nebulae, fingerprint

struct SkyPaletteTests {
    @Test func theTenHuesCycle() {
        #expect(SkyPalette.count == 10)
        let first = SkyPalette.hue(0, dark: true)
        #expect(abs(first.r - 0x7b / 255) < 1e-12 && abs(first.g - 0x6c / 255) < 1e-12 && abs(first.b - 1) < 1e-12)
        #expect(SkyPalette.hue(10, dark: false) == SkyPalette.hue(0, dark: false))
        #expect(SkyPalette.hue(-1, dark: true) == SkyPalette.hue(9, dark: true))
        let last = SkyPalette.hue(9, dark: false)                              // #f07c5c
        #expect(abs(last.r - 0xf0 / 255) < 1e-12 && abs(last.b - 0x5c / 255) < 1e-12)
        #expect(SkyPalette.cool(dark: true).b == 1 && SkyPalette.warm(dark: false).r == 176.0 / 255)
    }
}

struct SkyNebulaTests {
    @Test func theBoxGrowsByAThirdOfTheSizeOnEverySide() {
        let box = SkyBounds(minX: 0, minY: 0, maxX: 10, maxY: 20).nebulaBox
        #expect(box == SkyBounds(minX: -3, minY: -6, maxX: 13, maxY: 26))
        #expect(SkyBounds(minX: 5, minY: 5, maxX: 5, maxY: 5).nebulaBox == SkyBounds(minX: 4.7, minY: 4.7, maxX: 5.3, maxY: 5.3))
        #expect(SkyBounds(points: [SIMD2(1, 5), SIMD2(-2, 3), SIMD2(0, 9)]) == SkyBounds(minX: -2, minY: 3, maxX: 1, maxY: 9))
    }

    private func sky() -> (points: [SIMD2<Double>], constellations: [SkyConstellation]) {
        var rng = SkyRNG(seed: 11)
        let points = blob(12, 0.2, 0.2, spread: 0.04, rng: &rng) + blob(12, 0.8, 0.7, spread: 0.04, rng: &rng) + [SIMD2(0.5, 0.95)]
        let constellations = [
            SkyConstellation(id: 0, members: Array(0..<12), keywords: [], edges: [], hue: 0, centroid: SIMD2(0.2, 0.2), top: 0.18),
            SkyConstellation(id: 1, members: Array(12..<24), keywords: [], edges: [], hue: 1, centroid: SIMD2(0.8, 0.7), top: 0.68),
            SkyConstellation(id: 2, members: [24], keywords: [], edges: [], hue: 12, centroid: SIMD2(0.5, 0.95), top: 0.95),
        ]
        return (points, constellations)
    }

    @Test func oneGridPerConstellationWithDensityInZeroToOne() {
        let (points, constellations) = sky()
        let bounds = SkyBounds(points: points)
        let nebulae = SkyNebulae.build(points: points, constellations: constellations, bounds: bounds)
        #expect(nebulae.count == 3 && nebulae.map(\.hue) == [0, 1, 12])
        for n in nebulae {
            #expect(n.width == 96 && n.height == 96 && n.values.count == 96 * 96)
            #expect(n.values.allSatisfy { $0 >= 0 && $0 <= 1 })
            #expect(n.bounds == bounds.nebulaBox)
        }
        // a dense constellation reaches full strength, a lone star only a faint wisp (the grid is divided by at least 3)
        #expect(nebulae[0].values.max() == 1)
        #expect((nebulae[2].values.max() ?? 0) < 0.4 && (nebulae[2].values.max() ?? 0) > 0.3)
    }

    @Test func thePeakIsNearTheCluster() {
        let (points, constellations) = sky()
        let bounds = SkyBounds(points: points)
        let box = bounds.nebulaBox
        let nebulae = SkyNebulae.build(points: points, constellations: constellations, bounds: bounds)
        for (n, centre) in [(nebulae[0], SIMD2(0.2, 0.2)), (nebulae[1], SIMD2(0.8, 0.7))] {
            let peak = n.values.indices.max { n.values[$0] < n.values[$1] }!
            let px = Double(peak % n.width), py = Double(peak / n.width)
            let ex = (centre.x - box.minX) / (box.maxX - box.minX) * 95
            let ey = (centre.y - box.minY) / (box.maxY - box.minY) * 95
            #expect(abs(px - ex) < 5 && abs(py - ey) < 5, "peak at \(px),\(py), cluster at \(ex),\(ey)")
        }
        // far from its stars a nebula is empty
        let first = nebulae[0]
        #expect(first.values[90 * 96 + 90] == 0)
        #expect(SkyNebulae.alpha(dark: true) == 125.0 / 255 && SkyNebulae.alpha(dark: false) == 95.0 / 255)
    }
}

struct SkyFingerprintTests {
    @Test func oneStarPerComponentLaidOutSixteenBySixteen() {
        var v = [Float]()
        for i in 0..<256 { v.append(i % 2 == 0 ? Float(i + 1) : -Float(i + 1)) }
        let stars = SkyFingerprint.stars(for: v)
        #expect(stars.count == 256)
        #expect(stars[0].x == 0.5 / 16 && stars[0].y == 0.5 / 16)
        #expect(stars[17].x == 1.5 / 16 && stars[17].y == 1.5 / 16)
        #expect(stars[255].x == 15.5 / 16 && stars[255].y == 15.5 / 16)
        // the sign decides the colour
        #expect(stars.enumerated().allSatisfy { $0.element.positive == (v[$0.offset] >= 0) })
        // bigger numbers, bigger stars: radius grows with |value|
        let order = v.indices.sorted { abs(v[$0]) < abs(v[$1]) }
        for (a, b) in zip(order, order.dropFirst()) { #expect(stars[a].radius < stars[b].radius) }
        #expect(stars[255].strength == 1 && stars[255].radius == 3.2 / 208)
        #expect(stars[1].radius > 0.6 / 208)
    }

    @Test func edgesOfTheRange() {
        #expect(SkyFingerprint.stars(for: []).isEmpty)
        #expect(SkyFingerprint.stars(for: Array(repeating: 0.5, count: 300)).count == 256)
        let few = SkyFingerprint.stars(for: [1, -1, 0])
        #expect(few.count == 3 && few[2].positive && few[2].strength == 0 && few[2].radius == 0.6 / 208)
        let zero = SkyFingerprint.stars(for: [0, 0])
        #expect(zero.allSatisfy { $0.strength == 0 && $0.positive })
        // only the ratio matters: scaled vectors give the same stars
        #expect(SkyFingerprint.stars(for: [1, -0.5, 0.25]) == SkyFingerprint.stars(for: [2, -1, 0.5]))
    }
}

// MARK: - The layout pipeline

struct SkyMapLayoutTests {
    @Test func snapshotsStartScatteredAndFitTheUnitSquare() throws {
        let posts = blobVectors(clusters: 3, per: 10).enumerated().map { mapPost($0.offset, title: "post \($0.offset / 10)", vector: $0.element) }
        var snapshots: [SkyLayoutSnapshot] = []
        let result = try #require(SkyMapLayout.run(posts: posts, iterations: 40) { snapshots.append($0) })
        #expect(snapshots.first?.progress == 0 && snapshots.first?.points.count == 30)
        for s in snapshots {
            let xs = s.points.map(\.x), ys = s.points.map(\.y)
            #expect(xs.min() ?? -1 >= 0 && xs.max() ?? 2 <= 1 && ys.min() ?? -1 >= 0 && ys.max() ?? 2 <= 1)
            #expect(max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0)) > 0.999)
        }
        #expect(result.points.count == 30 && result.nebulae.count == result.constellations.count)
        #expect(result.degrees.count == 30 && result.membership.count == 30)
        #expect(result.constellations.flatMap(\.members).sorted() == Array(0..<30))
    }
}

// MARK: - The model

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SkyMapModelTests {
    /// A preview app on the sky-map scenario, almost without latency, with a short t-SNE.
    private func rig(iterations: Int = 250) -> AppModel {
        let app = AppModel.makePreview(.skyMap, timeScale: 0.01, clock: SystemClock())
        app.skyMap.iterations = iterations
        return app
    }

    private func useServer(_ app: AppModel, _ server: LoopbackServer) {
        app.ctx.client = HTTPCobaltClient(baseURL: server.base, apiKey: { mapKey })
    }

    @Test func thePreviewServesASearchServerWithASkyMap() async throws {
        let app = rig()
        #expect(app.capabilities.search && app.skyMap.phase == .idle && app.skyMap.posts.isEmpty)
        let map = try await app.ctx.client.libraryMap()
        #expect(map.posts.count == 150 && map.unmapped == 3 && map.dims == 256 && map.searchEnabled)
        #expect(map.posts.allSatisfy { $0.vector.count == 256 && $0.vector.map(abs).max() == 1 })
        #expect(Set(map.posts.map(\.id)).count == 150)
        #expect(map.posts.map(\.latest) == map.posts.map(\.latest).sorted(by: >))          // newest first
        #expect(map.posts.contains { $0.imageURL != nil } && map.posts.contains { $0.imageURL == nil })
        #expect(map.posts.contains { $0.title == nil })
        // .happy serves the map too, without advertising search
        let happy = AppModel.makePreview(.happy, timeScale: 0.01, clock: SystemClock())
        #expect(!happy.capabilities.search)
        #expect(try await happy.ctx.client.libraryMap().posts.count == 150)
    }

    @Test func loadReachesReadyWithConstellationsAndNebulae() async throws {
        let app = rig()
        let sky = app.skyMap
        await sky.load()
        #expect(sky.phase == .ready)
        #expect(sky.posts.count == 150 && sky.points.count == 150 && sky.unmapped == 3)
        #expect(!sky.constellations.isEmpty && sky.nebulae.count == sky.constellations.count)
        #expect(sky.constellations.flatMap(\.members).sorted() == Array(0..<150))
        #expect(sky.degrees.count == 150 && sky.constellationOf.count == 150 && sky.constellationOf.allSatisfy { $0 >= 0 })
        #expect(sky.points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        // the themes each name a constellation
        let keywords = Set(sky.constellations.flatMap(\.keywords))
        for word in PreviewData.skyClusters.map(\.signature) { #expect(keywords.contains(word), "\(word) in \(keywords)") }
        // the posts of a theme land together: a sizeable constellation is one theme (post i is theme i % the number of themes), and the
        // sizeable ones hold nearly every post (k-means++ also seeds a few small ones on stray stars)
        let big = sky.constellations.filter { $0.members.count >= 10 }
        for c in big {
            var counts = [Int: Int]()
            for m in c.members { counts[m % PreviewData.skyClusters.count, default: 0] += 1 }
            #expect(Double(counts.values.max() ?? 0) >= 0.9 * Double(c.members.count), "constellation \(c.id): \(counts)")
        }
        #expect(big.reduce(0) { $0 + $1.members.count } >= 120)
    }

    @Test func aSecondLoadReusesTheLayoutAndAResetForgetsIt() async {
        let app = rig()
        let sky = app.skyMap
        await sky.load()
        let first = sky.points
        #expect(sky.layouts == 1)
        await sky.load()
        #expect(sky.phase == .ready && sky.layouts == 1 && sky.points == first)
        sky.reset()
        #expect(sky.phase == .idle && sky.posts.isEmpty && sky.points.isEmpty && sky.constellations.isEmpty && sky.nebulae.isEmpty)
        await sky.load()
        #expect(sky.layouts == 2 && sky.points == first)              // computed again, the same way
    }

    @Test func aNewServerResetsTheMap() async {
        let app = rig()
        await app.skyMap.load()
        #expect(app.skyMap.phase == .ready)
        app.serverChanged()
        #expect(app.skyMap.phase == .idle && app.skyMap.posts.isEmpty)
    }

    @Test func noPostsIsEmptyNotFailed() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"success","model":"m","dims":256,"search_enabled":true,"posts":[],"unmapped":2}"#)
        }
        defer { server.stop() }
        let app = rig()
        useServer(app, server)
        await app.skyMap.load()
        #expect(app.skyMap.phase == .empty && app.skyMap.posts.isEmpty && app.skyMap.unmapped == 2)
    }

    @Test func aFailedFetchSaysWhy() async throws {
        let down = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 503) }
        let app = rig()
        useServer(app, down)
        await app.skyMap.load()
        #expect(app.skyMap.phase == .failed("The server can't load the map right now."))
        down.stop()
        await app.skyMap.load()                                       // nobody is listening any more
        #expect(app.skyMap.phase == .failed("Can't reach the server."))
        app.ctx.client = PreviewClient(scenario: .plainCobalt, timeScale: 0.01)
        await app.skyMap.load()
        #expect(app.skyMap.phase == .failed("The server can't load the map right now."))
        #expect(SkyMapModel.message(for: PipelineFailure.unsupported) == "This server has no sky map.")
        #expect(SkyMapModel.message(for: CobaltError.noAPIKey) == "No API key.")
    }

    @Test func aMapOnScreenSurvivesAFailedRefresh() async throws {
        let app = rig()
        await app.skyMap.load()
        let points = app.skyMap.points
        let down = try await LoopbackServer.start { _ in .json("{}", status: 500) }
        defer { down.stop() }
        useServer(app, down)
        await app.skyMap.load()
        #expect(app.skyMap.phase == .ready && app.skyMap.points == points && app.skyMap.posts.count == 150)
    }

    @Test func cancelDuringTheFetchLeavesItIdleAndLoadWorksAfter() async throws {
        let server = try await LoopbackServer.start { _ in
            Thread.sleep(forTimeInterval: 0.4)
            return .json(#"{"status":"success","model":"m","dims":2,"search_enabled":true,"posts":[],"unmapped":0}"#)
        }
        defer { server.stop() }
        let app = rig()
        useServer(app, server)
        let task = Task { await app.skyMap.load() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.skyMap.phase == .loading)
        app.skyMap.cancel()
        await task.value
        #expect(app.skyMap.phase == .idle)
        await app.skyMap.load()
        #expect(app.skyMap.phase == .empty)
    }

    @Test func snapshotsArriveWhileTheStarsSettleAndCancelStopsTheLayout() async throws {
        let app = rig(iterations: 1_000_000)                           // far longer than any test would wait
        let sky = app.skyMap
        let task = Task { await sky.load() }
        var sawProgress = false
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(25))
            if case .laying(let progress) = sky.phase, progress > 0, sky.points.count == 150 { sawProgress = true; break }
        }
        #expect(sawProgress)
        #expect(sky.points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        #expect(sky.constellations.isEmpty)                             // only when settled
        sky.cancel()
        await task.value                                               // returns: the layout stopped
        #expect(sky.phase == .idle && sky.points.isEmpty && sky.posts.isEmpty)
    }

    @Test func aSecondLoadWhileRunningRestartsAndSettlesOnce() async {
        let app = rig()
        let sky = app.skyMap
        async let first: Void = sky.load()
        try? await Task.sleep(for: .milliseconds(5))
        async let second: Void = sky.load()
        _ = await (first, second)
        #expect(sky.phase == .ready && sky.posts.count == 150 && sky.points.count == 150 && !sky.constellations.isEmpty)
    }

    @Test func aPostsNeighboursShareItsTheme() async {
        let app = rig()
        let sky = app.skyMap
        await sky.load()
        let near = sky.neighbours(of: 0, count: 6)
        #expect(near.count == 6 && !near.contains(0) && near.allSatisfy { $0 % PreviewData.skyClusters.count == 0 })
        #expect(sky.neighbourhoodKeywords(of: 0).contains("cat"))
        #expect(sky.neighbours(of: 999).isEmpty && sky.neighbourhoodKeywords(of: -1).isEmpty)
    }
}

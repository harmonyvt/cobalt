import Foundation
import Testing
@testable import CobaltKit

// The library's server search (APP-API-CONTRACT 21; apple/CONTRACT.md section 13): the wire, the capability, the
// debounce and cancel, the fallback to the local name filter, the waking retry, and a post's index state.

private let searchKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

/// A preview app whose server searches (`AppModel.makePreviewSearch`), on a virtual clock.
@MainActor
struct SearchRig {
    let clock = VirtualClock()
    let app: AppModel

    init(_ mode: PreviewSearchMode) {
        app = AppModel.makePreviewSearch(mode, timeScale: 1, clock: clock)
        app.ctx.settings.autoContinue = false
    }

    var library: LibraryModel { app.library }
    var client: PreviewClient { app.ctx.client as! PreviewClient }
    var calls: [String] { client.searchState.calls }

    func settle() async {
        var last = clock.registrations
        var stable = 0
        while stable < 4 {
            try? await Task.sleep(for: .milliseconds(1))
            let r = clock.registrations
            if r == last { stable += 1 } else { stable = 0; last = r }
        }
    }

    /// Runs virtual time forward by exactly `seconds`: wakes the sleepers due by then, in order, and no later one.
    func run(for seconds: Double) async {
        let target = clock.elapsed + seconds
        await settle()
        while let next = clock.nextWake, next <= target + 1e-9 {
            clock.advance()
            await settle()
        }
        if clock.elapsed < target { clock.jump(by: target - clock.elapsed) }
    }

    /// The local name filter's answer, the same rows `libraryRows` gives without server results.
    func localIDs(_ query: String) -> [String] {
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return library.posts.map { LibraryRow(item: app.mediaItem(for: $0)) }
            .filter { $0.matches(folded: folded) }
            .sorted { LibraryRow.areInIncreasingOrder($0, $1, by: library.sort) }
            .map(\.id)
    }
}

private let kitchenPost = "2105435404002562056"      // custom title "kitchen timer loop"
private let coffeePost = "Dd5JFkMDt4N"                // "shows" coffee (PreviewData.searchMeaning)
private let harbourPost = "Dd55fEyN1Yy"               // "shows" boats

// MARK: - The wire

struct LibrarySearchDecodingTests {
    @Test func postsDecodeLikeTheLibraryWithTheirScore() throws {
        let result = try LibrarySearchWire.decode(Data("""
        {"status":"success","query":"boats","model":"google/embeddinggemma-2",
         "posts":[
           {"id":"p1","created_at":1790000000000,"custom_title":"harbour","kind":"video","poster_url":"https://media.capybaraharmony.com/a.jpg",
            "files":[{"id":"f1","kind":"private","source":"saved","name":"a.mp4","created_at":1790000000000}],"score":0.83},
           {"id":"p2","created_at":1790000000000,"files":[]},
           {"created_at":5,"score":0.5},
           {"id":"p3","created_at":1790000000000,"files":[],"score":"high"}
         ],
         "index":{"posts":10,"pending":2}}
        """.utf8), asked: "boats ")
        #expect(result.query == "boats" && result.model == "google/embeddinggemma-2")
        #expect(result.posts.map(\.id) == ["p1", "p2", "p3"])            // the post with no id is dropped, never the answer
        #expect(result.hits.map(\.score) == [0.83, 0, 0])                // missing or odd score: 0, the order stands
        #expect(result.posts[0].customTitle == "harbour" && result.posts[0].kind == .video)
        #expect(result.posts[0].createdAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(result.indexed == 10 && result.pending == 2)
    }

    @Test func aMissingIndexAndQueryAreNil() throws {
        let result = try LibrarySearchWire.decode(Data(#"{"status":"success","posts":[]}"#.utf8), asked: "cats")
        #expect(result.query == "cats" && result.model == nil && result.hits.isEmpty)
        #expect(result.indexed == nil && result.pending == nil)
        let noPosts = try LibrarySearchWire.decode(Data(#"{"status":"success","index":{"pending":4}}"#.utf8), asked: "x")
        #expect(noPosts.hits.isEmpty && noPosts.indexed == nil && noPosts.pending == 4)
    }

    @Test func aPostStatusDecodesEveryField() throws {
        let s = try LibrarySearchStatus.decode(Data("""
        {"status":"success","post_key":"sid1","state":"failed","model":"google/embeddinggemma-2","dims":256,
         "embedded_at":1790000000000,"failed_at":1790000600000,"retry_at":1790004200000,"attempts":2,"has_image":true,
         "input":{"title":"harbour","text":"title: harbour | text: a.mp4 · instagram.com/reel/x","image_url":"https://media.capybaraharmony.com/a.jpg"},
         "embedded_matches_input":false}
        """.utf8))
        #expect(s.postKey == "sid1" && s.state == .failed && s.model == "google/embeddinggemma-2" && s.dims == 256)
        #expect(s.embeddedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(s.failedAt == Date(timeIntervalSince1970: 1_790_000_600))
        #expect(s.retryAt == Date(timeIntervalSince1970: 1_790_004_200))
        #expect(s.attempts == 2 && s.hasImage == true && s.embeddedMatchesInput == false && s.searchEnabled)
        #expect(s.input?.title == "harbour" && s.input?.imageURL?.absoluteString == "https://media.capybaraharmony.com/a.jpg")
    }

    @Test func aPostStatusToleratesMissingAndOddFields() throws {
        let minimal = try LibrarySearchStatus.decode(Data(#"{"post_key":"k"}"#.utf8))
        #expect(minimal.state == .unknown && minimal.attempts == 0 && minimal.input == nil && minimal.searchEnabled)
        #expect(minimal.embeddedAt == nil && minimal.hasImage == nil && minimal.embeddedMatchesInput == nil)
        let gaveUp = try LibrarySearchStatus.decode(Data("""
        {"post_key":"k","state":"gave_up","attempts":3,"input":{"title":null,"text":"x","image_url":null},"dims":"many"}
        """.utf8))
        #expect(gaveUp.state == .gaveUp && gaveUp.attempts == 3 && gaveUp.dims == nil)
        #expect(gaveUp.input?.title == nil && gaveUp.input?.text == "x" && gaveUp.input?.imageURL == nil)
        let off = try LibrarySearchStatus.decode(Data(#"{"post_key":"k","state":"pending","attempts":0,"search_enabled":false}"#.utf8))
        #expect(!off.searchEnabled && off.state == .pending)
        let future = try LibrarySearchStatus.decode(Data(#"{"post_key":"k","state":"queued"}"#.utf8))
        #expect(future.state == .unknown)
        #expect(throws: (any Error).self) { try LibrarySearchStatus.decode(Data(#"{"state":"indexed"}"#.utf8)) }
    }

    @Test func theCapabilityIsReadAndAbsentMeansOff() throws {
        func caps(_ features: String) throws -> Capabilities {
            let json = #"{"server":"cobalt-cloudflare","features":\#(features),"key":"valid"}"#
            return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
        }
        #expect(try caps(#"{"library":true,"search":true}"#).search)
        #expect(try !caps(#"{"library":true,"search":false}"#).search)
        #expect(try !caps(#"{"library":true}"#).search)
        #expect(!Capabilities.unknown.search)
    }
}

// MARK: - The HTTP client

@Suite(.serialized)
struct LibrarySearchHTTPTests {
    @Test func theSearchIsKeyedAndCarriesQueryLimitAndShape() async throws {
        let server = try await LoopbackServer.start { req in
            guard req.path == "/library/search" else { return .init(status: 404) }
            return .json(#"{"status":"success","query":"boats at sea","model":"m","posts":[{"id":"p1","created_at":1790000000000,"files":[],"score":0.4}]}"#)
        }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { searchKey })
        let result = try await client.librarySearch(query: "boats at sea", limit: 80, version: 3)
        #expect(server.requests.map(\.query) == ["q=boats%20at%20sea&limit=50&v=3"])       // the limit is clamped to 50
        #expect(server.requests.first?.headers["authorization"] == "Api-Key \(searchKey)")
        #expect(result.posts.map(\.id) == ["p1"] && result.hits.first?.score == 0.4 && result.pending == nil)
        _ = try await client.librarySearch(query: "a&b", limit: 20, version: nil)
        #expect(server.requests.last?.query == "q=a%26b&limit=20")                         // no shape: no `v`
    }

    @Test func errorsAreTheServersCodes() async throws {
        let server = try await LoopbackServer.start { req in
            switch req.query.split(separator: "&").first.map(String.init) ?? "" {
            case "q=sleepy": return .json(#"{"status":"error","error":{"code":"error.search.waking"}}"#, status: 503)
            case "q=off": return .json(#"{"status":"error","error":{"code":"error.search.off"}}"#, status: 503)
            default: return .json(#"{"status":"error","error":{"code":"error.search.failed"}}"#, status: 502)
            }
        }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { searchKey })
        await #expect(throws: CobaltError.api(code: "error.search.waking", httpStatus: 503)) {
            try await client.librarySearch(query: "sleepy", limit: 20)
        }
        await #expect(throws: CobaltError.api(code: "error.search.off", httpStatus: 503)) {
            try await client.librarySearch(query: "off", limit: 20)
        }
        await #expect(throws: CobaltError.api(code: "error.search.failed", httpStatus: 502)) {
            try await client.librarySearch(query: "boom", limit: 20)
        }
    }

    @Test func aPostStatusIsAskedByKey() async throws {
        let server = try await LoopbackServer.start { req in
            guard req.path == "/library/search/post" else { return .init(status: 404) }
            if req.query == "key=gone" {
                return .json(#"{"status":"error","error":{"code":"error.library.not_found"}}"#, status: 404)
            }
            return .json(#"{"status":"success","post_key":"abc","state":"indexed","attempts":1,"embedded_at":1790000000000}"#)
        }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { searchKey })
        let status = try await client.librarySearchStatus(postKey: "abc")
        #expect(server.requests.first?.query == "key=abc")
        #expect(status.state == .indexed && status.embeddedAt == Date(timeIntervalSince1970: 1_790_000_000))
        await #expect(throws: CobaltError.api(code: "error.library.not_found", httpStatus: 404)) {
            try await client.librarySearchStatus(postKey: "gone")
        }
    }
}

// MARK: - The model: debounce, cancel, fallback, waking

@MainActor
@Suite(.serialized)
struct LibrarySearchModelTests {
    @Test func typingQuicklyAsksOnceForTheLastWords() async {
        let rig = SearchRig(.ready)
        rig.library.query = "bo"
        rig.library.query = "boa"
        rig.library.query = "boats"
        #expect(rig.library.searchState == .searching)
        await rig.run(for: 0.3)
        #expect(rig.calls.isEmpty)                                      // still inside the 350 ms pause
        await rig.run(for: 1)
        #expect(rig.calls == ["boats"])
        #expect(rig.library.searchResults?.first?.id == harbourPost)
        #expect(rig.library.searchState == .results(count: rig.library.posts.count, pending: 0))
    }

    @Test func aNewQueryCancelsTheOneInFlightAndItsAnswerNeverLands() async {
        let rig = SearchRig(.ready)
        rig.library.query = "boats"
        await rig.run(for: 0.5)                                         // asked at 0.35; the answer is due at 0.75
        #expect(rig.calls == ["boats"] && rig.library.searchResults == nil)
        rig.library.query = "coffee"
        #expect(rig.library.searchResults == nil && rig.library.searchState == .searching)
        await rig.run(for: 2)
        #expect(rig.calls == ["boats", "coffee"])
        #expect(rig.library.searchResults?.first?.id == coffeePost)
        #expect(rig.app.libraryRows.first?.id == coffeePost)
    }

    @Test func serverResultsShowInScoreOrder() async {
        let rig = SearchRig(.ready)
        rig.library.query = "kitchen"
        await rig.run(for: 1)
        let results = rig.library.searchResults ?? []
        #expect(results.first?.id == kitchenPost)
        #expect(rig.app.libraryRows.map(\.id) == results.map(\.id))   // score order, not the date sort
        let scores = results.map { rig.library.searchScores[$0.id] ?? -1 }
        #expect(scores == scores.sorted(by: >) && scores.allSatisfy { $0 >= 0 })
    }

    @Test func theLocalFilterAnswersWhileTheServerThinks() async {
        let rig = SearchRig(.ready)
        rig.library.query = "kitchen"
        #expect(rig.app.libraryRows.map(\.id) == [kitchenPost])
        #expect(rig.app.libraryRows.map(\.id) == rig.localIDs("kitchen"))
    }

    @Test func withoutTheCapabilityOnlyTheLocalFilterRuns() async {
        let rig = SearchRig(.off)
        #expect(!rig.app.capabilities.search)
        rig.library.query = "kitchen"
        #expect(rig.library.searchState == .idle)
        await rig.run(for: 5)
        #expect(rig.calls.isEmpty && rig.library.searchResults == nil)
        #expect(rig.app.libraryRows.map(\.id) == rig.localIDs("kitchen"))
    }

    @Test func aFailedSearchFallsBackToTheLocalFilter() async {
        let rig = SearchRig(.failing)
        rig.library.query = "kitchen"
        await rig.run(for: 2)
        #expect(rig.calls == ["kitchen"])
        #expect(rig.library.searchState == .failed && rig.library.searchResults == nil)
        #expect(rig.app.libraryRows.map(\.id) == [kitchenPost])
    }

    @Test func searchOffOnTheServerStopsAsking() async {
        let rig = SearchRig(.disabled)
        rig.library.query = "kitchen"
        await rig.run(for: 2)
        #expect(rig.library.searchState == .off && rig.app.libraryRows.map(\.id) == [kitchenPost])
        rig.library.query = "coffee"
        #expect(rig.library.searchState == .off)
        await rig.run(for: 2)
        #expect(rig.calls == ["kitchen"])                               // no second call until the server changes
        rig.library.reset()
        rig.library.query = "dog"
        await rig.run(for: 2)
        #expect(rig.calls == ["kitchen", "dog"])
    }

    @Test func wakingRetriesAfterFifteenSeconds() async {
        let rig = SearchRig(.waking)
        rig.library.query = "boats"
        await rig.run(for: 1)
        #expect(rig.calls == ["boats"] && rig.library.searchState == .waking)
        await rig.run(for: 10)
        #expect(rig.calls.count == 1)                                   // not before 15 s
        #expect(rig.library.searchState == .waking)
        await rig.run(for: 10)
        #expect(rig.calls == ["boats", "boats"])
        #expect(rig.library.searchResults?.first?.id == harbourPost)
        if case .results = rig.library.searchState {} else { Issue.record("expected results, got \(rig.library.searchState)") }
    }

    @Test func wakingKeepsRetryingThenGivesUp() async {
        let rig = SearchRig(.stillWaking)
        rig.library.query = "boats"
        await rig.run(for: 60)
        #expect(rig.library.searchState == .waking)                     // still trying, not stuck after one retry
        #expect(rig.calls.count > 2)
        await rig.run(for: 600)
        #expect(rig.calls.count == 1 + LibraryModel.wakingRetries)
        #expect(rig.library.searchState == .failed && rig.library.searchResults == nil)   // no endless spinner
        #expect(rig.app.libraryRows.map(\.id) == rig.localIDs("boats"))
    }

    @Test func typingDuringTheWakingWaitDropsTheRetry() async {
        let rig = SearchRig(.waking)
        rig.library.query = "boats"
        await rig.run(for: 5)
        #expect(rig.library.searchState == .waking)
        rig.library.query = "coffee"                                     // the Space is awake for this one
        await rig.run(for: 40)
        #expect(rig.calls == ["boats", "coffee"])
        #expect(rig.library.searchResults?.first?.id == coffeePost)
    }

    @Test func clearingTheQueryReturnsToTheLibrary() async {
        let rig = SearchRig(.indexing)
        rig.library.query = "coffee"
        await rig.run(for: 1)
        #expect(rig.library.searchState == .results(count: rig.library.posts.count, pending: 3))
        rig.library.query = ""
        #expect(rig.library.searchState == .idle && rig.library.searchResults == nil && rig.library.activeSearchResults == nil)
        #expect(rig.app.libraryRows.count == rig.library.posts.count)
        #expect(rig.library.post(id: coffeePost) != nil)
        await rig.run(for: 5)
        #expect(rig.calls == ["coffee"])
    }

    @Test func aOneLetterQueryStaysLocal() async {
        let rig = SearchRig(.ready)
        rig.library.query = " k "
        #expect(rig.library.searchState == .idle)
        await rig.run(for: 2)
        #expect(rig.calls.isEmpty)
        #expect(LibraryModel.isServerQuery("ab") && !LibraryModel.isServerQuery(" a ") && LibraryModel.isServerQuery("a b"))
    }

    @Test func theKindChipStillFiltersServerResults() async {
        let rig = SearchRig(.ready)
        rig.library.query = "boats"
        await rig.run(for: 1)
        rig.library.kindFilter = .galleries                              // the preview library has none
        #expect(rig.app.libraryRows.isEmpty)
        rig.library.kindFilter = .all
        #expect(!rig.app.libraryRows.isEmpty)
    }

    @Test func aPostStatusComesFromTheServer() async throws {
        let rig = SearchRig(.ready)
        let library = rig.library
        let indexed = Task { try await library.searchStatus(postKey: harbourPost) }
        await rig.run(for: 1)
        let s = try await indexed.value
        #expect(s.state == .indexed && s.hasImage == true && s.input?.imageURL != nil && s.embeddedMatchesInput == true)

        let gone = Task { try await library.searchStatus(postKey: "nope") }
        await rig.run(for: 1)
        await #expect(throws: CobaltError.api(code: "error.library.not_found", httpStatus: 404)) { try await gone.value }

        let off = SearchRig(.off)
        await #expect(throws: PipelineFailure.unsupported) { try await off.library.searchStatus(postKey: harbourPost) }
    }
}

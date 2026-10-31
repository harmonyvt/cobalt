import Foundation
import Testing
@testable import CobaltKit

// Search names (APP-API-CONTRACT 48): the wire shapes (samples from 48.4), the capability, the routes on the real client,
// `names=0` on the search, the draft, the preview server, and the names model with its editor's debounced preview.

private let namesKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

private func wirePost(_ id: String) -> String {
    #"{"id":"\#(id)","service":"instagram","created_at":1790000000000,"files":[{"id":"\#(id)-f","kind":"private","source":"saved","name":"n","content_type":"video/mp4","created_at":1790000000000,"deletable":false}]}"#
}

/// A `Name` as 48.4 lists it.
private let liaJSON = """
{"id":"AbCdEfGhIjKlMnOp","name":"Lia","aliases":["lia-chan","my model"],
 "meaning":"pink-haired cat girl with cat ears, my vtuber model","strength":0.6,"cutoff":0.45,"enabled":true,
 "yes":["post2","post1"],"no":["post9"],"posts":14,"embedded":true,"created_at":1790000000000,"updated_at":1790000100000}
"""

// MARK: - wire shapes

struct NamesWireTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try CobaltJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func aNameDecodesEveryField() throws {
        let name = try decode(NamesWire.Name.self, liaJSON).value
        #expect(name.id == "AbCdEfGhIjKlMnOp" && name.name == "Lia" && name.aliases == ["lia-chan", "my model"])
        #expect(name.meaning.hasPrefix("pink-haired") && name.strength == 0.6 && name.cutoff == 0.45 && name.enabled)
        #expect(name.yes == ["post2", "post1"] && name.no == ["post9"] && name.posts == 14 && name.embedded)
        #expect(name.createdAt == Date(timeIntervalSince1970: 1_790_000_000) && name.updatedAt == Date(timeIntervalSince1970: 1_790_000_100))
        #expect(name.mark(of: "post1") == .yes && name.mark(of: "post9") == .no && name.mark(of: "other") == nil)
    }

    @Test func theListDropsAnOddRowAndDefaultsMissingFields() throws {
        let json = """
        {"status":"success","names":[\(liaJSON),
          {"name":"no id"},
          {"id":"capyCapyCapyCapy","name":"capy","meaning":"capybara","enabled":false}]}
        """
        let names = try decode(NamesWire.List.self, json).value
        #expect(names.map(\.id) == ["AbCdEfGhIjKlMnOp", "capyCapyCapyCapy"])
        let capy = names[1]
        #expect(!capy.enabled && capy.aliases.isEmpty && capy.yes.isEmpty && capy.posts == 0 && !capy.embedded)
        #expect(capy.strength == TaughtName.defaultStrength && capy.cutoff == TaughtName.defaultCutoff)
        #expect(try decode(NamesWire.List.self, #"{"status":"success"}"#).value.isEmpty)
    }

    @Test func aPreviewCarriesItsPostsInTheLibraryShape() throws {
        let json = """
        {"status":"success","embedded":true,"carries":3,"indexed":120,"posts":[
          {"post_key":"post2","score":1,"mark":"yes","carries":true,"post":\(wirePost("post2"))},
          {"post_key":"post9","score":0.5123,"mark":"no","carries":false,"post":null},
          {"post_key":"post4","score":0.4871,"mark":null,"carries":true,"post":\(wirePost("post4"))},
          {"score":0.3}]}
        """
        let preview = try decode(NamesWire.Preview.self, json).value
        #expect(preview.embedded && preview.carries == 3 && preview.indexed == 120)
        #expect(preview.posts.map(\.postKey) == ["post2", "post9", "post4"], "a row without a key is dropped")
        #expect(preview.posts[0].mark == .yes && preview.posts[0].carries && preview.posts[0].post?.id == "post2")
        #expect(preview.posts[1].mark == .no && !preview.posts[1].carries && preview.posts[1].post == nil && preview.posts[1].score == 0.5123)
        #expect(preview.posts[2].mark == nil && preview.posts[2].carries && preview.posts[2].post?.files.count == 1)
    }

    @Test func aPreviewWithoutTheMeaningsVectorSaysSo() throws {
        let preview = try decode(NamesWire.Preview.self, #"{"status":"success","embedded":false,"carries":0,"indexed":0,"posts":[]}"#).value
        #expect(!preview.embedded && preview.posts.isEmpty)
    }

    @Test func aPostsNamesReadBestFirst() throws {
        let json = """
        {"status":"success","names":[
          {"id":"a","name":"Lia","score":0.7134,"mark":null,"carries":true},
          {"id":"b","name":"capy","score":null,"mark":"yes","carries":true},
          {"id":"c","name":"odd","score":0.2,"mark":"maybe","carries":false}]}
        """
        let names = try decode(NamesWire.ForPost.self, json).value
        #expect(names.map(\.id) == ["a", "b", "c"])
        #expect(names[0].score == 0.7134 && names[0].mark == nil && names[0].carries)
        #expect(names[1].score == nil && names[1].mark == .yes)
        #expect(names[2].mark == nil, "a mark this build does not know reads as none")
    }

    @Test func theSearchAnswerListsTheNamesItUsed() throws {
        let with = try LibrarySearchWire.decode(Data("""
        {"status":"success","query":"Lia dancing","posts":[\(wirePost("p").dropLast()),"score":0.81}],
         "names":[{"id":"AbCdEfGhIjKlMnOp","name":"Lia"}]}
        """.utf8), asked: "Lia dancing")
        #expect(with.names == [SearchNameRef(id: "AbCdEfGhIjKlMnOp", name: "Lia")] && with.hits.first?.score == 0.81)
        let empty = try LibrarySearchWire.decode(Data(#"{"status":"success","posts":[],"names":[]}"#.utf8), asked: "x")
        #expect(empty.names.isEmpty)
        let older = try LibrarySearchWire.decode(Data(#"{"status":"success","posts":[]}"#.utf8), asked: "x")
        #expect(older.names.isEmpty, "a server without names sends none")
    }
}

// MARK: - the draft and the bodies

struct NamesDraftTests {
    @Test func aTapCyclesExampleNotAndNoMark() {
        var draft = SearchNameDraft(name: "Lia", meaning: "cat girl", yes: ["a"])
        draft.cycle("b")
        #expect(draft.yes == ["b", "a"] && draft.mark(of: "b") == .yes)
        draft.cycle("b")
        #expect(draft.yes == ["a"] && draft.no == ["b"] && draft.mark(of: "b") == .no)
        draft.cycle("b")
        #expect(draft.mark(of: "b") == nil && draft.no.isEmpty)
    }

    @Test func alsoCalledIsNormalizedAndKeptApart() {
        var draft = SearchNameDraft(name: "Lia", meaning: "cat girl")
        #expect(draft.addAlias("  Lia   Chan "))
        #expect(!draft.addAlias("lia chan"), "already there")
        #expect(!draft.addAlias(" LIA "), "the name itself")
        #expect(!draft.addAlias("   "))
        #expect(draft.aliases == ["lia chan"])
        for n in 0..<10 { draft.addAlias("word \(n)") }
        #expect(draft.aliases.count == TaughtName.maxAliases)
    }

    @Test func validityFollowsTheLimits() {
        #expect(!SearchNameDraft(name: " ", meaning: "x").isValid)
        #expect(!SearchNameDraft(name: "Lia", meaning: "   ").isValid)
        #expect(!SearchNameDraft(name: String(repeating: "a", count: 41), meaning: "x").isValid)
        #expect(SearchNameDraft(name: " Lia ", meaning: " cat girl ").isValid)
        #expect(TaughtName.normalize("  Lia \n Chan ") == "lia chan")
    }

    @Test func aMarkOfNoneIsNull() throws {
        let body = SearchNamePatch(mark: [.init(postKey: "a", kind: .no), .init(postKey: "b", kind: nil)]).body
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let marks = try #require(json["mark"] as? [[String: Any]])
        #expect(json.count == 1 && marks.count == 2)
        #expect(marks[0]["post_key"] as? String == "a" && marks[0]["kind"] as? String == "no")
        #expect(marks[1]["post_key"] as? String == "b" && marks[1]["kind"] is NSNull)
    }
}

// MARK: - capability

struct NamesCapabilityTests {
    private func caps(_ features: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":\#(features),"limits":{},"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func namesNeedSearch() throws {
        #expect(try caps(#"{"search":true,"names":true}"#).names)
        #expect(try !caps(#"{"search":false,"names":true}"#).names)
        #expect(try !caps(#"{"search":true}"#).names)
        #expect(!Capabilities.unknown.names)
    }
}

// MARK: - the routes

@Suite(.serialized)
struct NamesHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { namesKey })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test func everyRouteHitsItsPathWithTheKey() async throws {
        let server = try await LoopbackServer.start { req in
            switch (req.method, req.path) {
            case ("GET", "/library/names"): return .json(#"{"status":"success","names":[\#(liaJSON)]}"#)
            case ("POST", "/library/names"): return .json(#"{"status":"success","name":\#(liaJSON)}"#, status: 201)
            case ("PATCH", "/library/names/AbCdEfGhIjKlMnOp"): return .json(#"{"status":"success","name":\#(liaJSON)}"#)
            case ("DELETE", "/library/names/AbCdEfGhIjKlMnOp"): return .json(#"{"status":"success"}"#)
            case ("POST", "/library/names/preview"):
                return .json(#"{"status":"success","embedded":true,"carries":1,"indexed":5,"posts":[{"post_key":"p","score":0.6,"mark":null,"carries":true,"post":\#(wirePost("p"))}]}"#)
            case ("GET", "/library/names/post"):
                return .json(#"{"status":"success","names":[{"id":"AbCdEfGhIjKlMnOp","name":"Lia","score":0.71,"mark":null,"carries":true}]}"#)
            default: return .init(status: 404)
            }
        }
        defer { server.stop() }
        let c = client(server)
        #expect(try await c.searchNames().map(\.name) == ["Lia"])
        let draft = SearchNameDraft(name: " Lia ", aliases: ["lia-chan"], meaning: "pink cat girl", yes: ["p1"], no: ["p2"])
        #expect(try await c.createSearchName(draft).id == "AbCdEfGhIjKlMnOp")
        _ = try await c.updateSearchName(id: "AbCdEfGhIjKlMnOp", SearchNamePatch(enabled: false))
        let preview = try await c.previewSearchName(SearchNamePreviewRequest(id: "AbCdEfGhIjKlMnOp", strength: 0.8, limit: 500))
        #expect(preview.carries == 1 && preview.posts.first?.post?.id == "p")
        let forPost = try await c.searchNames(forPost: "post 1")
        #expect(forPost == [PostName(id: "AbCdEfGhIjKlMnOp", name: "Lia", score: 0.71, mark: nil, carries: true)])
        try await c.deleteSearchName(id: "AbCdEfGhIjKlMnOp")

        let reqs = server.requests
        #expect(reqs.map { "\($0.method) \($0.path)" } == [
            "GET /library/names", "POST /library/names", "PATCH /library/names/AbCdEfGhIjKlMnOp",
            "POST /library/names/preview", "GET /library/names/post", "DELETE /library/names/AbCdEfGhIjKlMnOp",
        ])
        #expect(reqs.allSatisfy { $0.headers["authorization"] == "Api-Key \(namesKey)" })
        let create = try bodyJSON(reqs[1])
        #expect(create["name"] as? String == "Lia" && create["meaning"] as? String == "pink cat girl")
        #expect(create["aliases"] as? [String] == ["lia-chan"] && create["yes"] as? [String] == ["p1"] && create["no"] as? [String] == ["p2"])
        #expect(create["strength"] as? Double == 0.5 && create["cutoff"] as? Double == 0.5 && create["enabled"] as? Bool == true)
        let patch = try bodyJSON(reqs[2])
        #expect(patch.count == 1 && patch["enabled"] as? Bool == false)
        let prev = try bodyJSON(reqs[3])
        #expect(prev["id"] as? String == "AbCdEfGhIjKlMnOp" && prev["strength"] as? Double == 0.8 && prev["limit"] as? Int == 100)
        #expect(prev["meaning"] == nil && prev["yes"] == nil)
        #expect(reqs[4].query == "key=post%201")
    }

    @Test func aTakenWordComesBackWithTheWord() async throws {
        let server = try await LoopbackServer.start { req in
            switch req.method {
            case "POST": return .json(#"{"status":"error","error":{"code":"error.names.taken"},"word":"lia-chan"}"#, status: 409)
            case "PATCH": return .json(#"{"status":"error","error":{"code":"error.names.taken","word":"capy"}}"#, status: 409)
            case "DELETE": return .json(#"{"status":"error","error":{"code":"error.names.not_found"}}"#, status: 404)
            default: return .json(#"{"status":"error","error":{"code":"error.api.generic"}}"#, status: 503)
            }
        }
        defer { server.stop() }
        let c = client(server)
        await #expect(throws: SearchNameTaken(word: "lia-chan")) {
            _ = try await c.createSearchName(SearchNameDraft(name: "Lia", meaning: "x"))
        }
        await #expect(throws: SearchNameTaken(word: "capy")) {
            _ = try await c.updateSearchName(id: "a", SearchNamePatch(aliases: ["capy"]))
        }
        await #expect(throws: CobaltError.api(code: "error.names.not_found", httpStatus: 404)) {
            try await c.deleteSearchName(id: "a")
        }
        await #expect(throws: CobaltError.api(code: "error.api.generic", httpStatus: 503)) {
            _ = try await c.searchNames()
        }
    }

    @Test func namesOffAddsNamesZero() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","posts":[],"names":[]}"#) }
        defer { server.stop() }
        let c = client(server)
        _ = try await c.librarySearch(query: "Lia", limit: 10, version: 3)
        _ = try await c.librarySearch(query: "Lia", limit: 10, version: 3, names: false)
        let queries = server.requests.map { Set($0.query.split(separator: "&").map(String.init)) }
        #expect(queries[0] == ["q=Lia", "limit=10", "v=3"])
        #expect(queries[1] == ["q=Lia", "limit=10", "v=3", "names=0"])
    }
}

// MARK: - the preview server

struct NamesPreviewServerTests {
    private func client() -> PreviewClient {
        PreviewClient(scenario: .happy, timeScale: 0.001, clock: SystemClock(), search: .ready)
    }

    @Test func itStartsWithLiaCapyAndTheRamenPlace() async throws {
        let c = client()
        let names = try await c.searchNames()
        #expect(names.map(\.name) == ["Lia", "capy", "the ramen place"])
        let lia = names[0]
        #expect(lia.posts >= lia.yes.count && lia.aliases == ["lia-chan", "my model"] && !names[2].enabled)
        #expect(await c.capabilities().names)
        let plain = PreviewClient(scenario: .happy, timeScale: 0.001, clock: SystemClock())
        #expect(await !plain.capabilities().names)
    }

    @Test func aPreviewListsExamplesThenNotThenTheRest() async throws {
        let c = client()
        let lia = try #require(try await c.searchNames().first)
        let preview = try await c.previewSearchName(SearchNamePreviewRequest(id: lia.id))
        let marks = preview.posts.map(\.mark)
        #expect(Array(marks.prefix(3)) == [.yes, .yes, .no])
        #expect(preview.posts.prefix(2).allSatisfy(\.carries) && !preview.posts[2].carries)
        let rest = preview.posts.dropFirst(3).map(\.score)
        #expect(rest == rest.sorted(by: >))
        #expect(preview.posts.allSatisfy { $0.post?.id == $0.postKey })
        // a stricter cut-off never lets more posts in
        let strict = try await c.previewSearchName(SearchNamePreviewRequest(id: lia.id, cutoff: 0.95))
        #expect(strict.carries <= preview.carries && strict.carries >= 2)
        await #expect(throws: CobaltError.api(code: "error.names.bad", httpStatus: 400)) {
            _ = try await c.previewSearchName(SearchNamePreviewRequest())
        }
    }

    @Test func theRoutesRefuseLikeTheServer() async throws {
        let c = client()
        await #expect(throws: SearchNameTaken(word: "lia-chan")) {
            _ = try await c.createSearchName(SearchNameDraft(name: "Lia-Chan", meaning: "someone else"))
        }
        await #expect(throws: CobaltError.api(code: "error.names.bad", httpStatus: 400)) {
            _ = try await c.createSearchName(SearchNameDraft(name: "x", meaning: "y", yes: ["a"], no: ["a"]))
        }
        let made = try await c.createSearchName(SearchNameDraft(name: " Boats ", aliases: [" The  Harbour "], meaning: " boats on water "))
        #expect(made.name == "Boats" && made.meaning == "boats on water" && made.aliases == ["the harbour"])
        let marked = try await c.updateSearchName(id: made.id, SearchNamePatch(mark: [.init(postKey: "Dd55fEyN1Yy", kind: .yes)]))
        #expect(marked.yes == ["Dd55fEyN1Yy"])
        let names = try await c.searchNames(forPost: "Dd55fEyN1Yy")
        #expect(names.contains { $0.id == made.id && $0.mark == .yes })
        try await c.deleteSearchName(id: made.id)
        await #expect(throws: CobaltError.api(code: "error.names.not_found", httpStatus: 404)) {
            try await c.deleteSearchName(id: made.id)
        }
    }

    @Test func aSearchThatSaysANameUsesIt() async throws {
        let c = client()
        let with = try await c.librarySearch(query: "Lia dancing", limit: 50, version: 3)
        #expect(with.names.map(\.name) == ["Lia"])
        let alias = try await c.librarySearch(query: "my model", limit: 50, version: 3)
        #expect(alias.names.map(\.name) == ["Lia"])
        let without = try await c.librarySearch(query: "Lia dancing", limit: 50, version: 3, names: false)
        #expect(without.names.isEmpty)
        let off = try await c.librarySearch(query: "ramen place", limit: 50, version: 3)
        #expect(off.names.isEmpty, "a name that is off is never said")
        let inside = try await c.librarySearch(query: "liam", limit: 50, version: 3)
        #expect(inside.names.isEmpty, "whole words only")
    }
}

// MARK: - the model

@MainActor
struct NamesModelTests {
    @Test func loadToggleAndDelete() async throws {
        let rig = SearchRig(.ready)
        let names = rig.app.searchNames
        async let loading: Void = names.load()
        await rig.run(for: 1)
        await loading
        #expect(names.hasLoaded && names.names.map(\.name) == ["Lia", "capy", "the ramen place"])
        let capy = names.names[1]
        async let toggling: Void = names.setEnabled(capy, false)
        await rig.run(for: 1)
        await toggling
        #expect(!names.names[1].enabled && names.failure == nil)
        let ramen = names.names[2]
        async let deleting: Void = names.delete(ramen)
        await rig.run(for: 1)
        await deleting
        #expect(names.names.map(\.name) == ["Lia", "capy"])
    }

    @Test func theEditorPreviewsAfterThePauseAndSaves() async throws {
        let rig = SearchRig(.ready)
        let names = rig.app.searchNames
        async let loading: Void = names.load()
        await rig.run(for: 1)
        await loading
        names.open(names.names[0])
        let editor = try #require(names.editor)
        #expect(names.showingList && !editor.isNew && !editor.isDirty)
        editor.start()
        await rig.run(for: 1)
        let first = try #require(editor.preview)
        let calls = rig.client.searchState.names.calls.filter { $0 == "NAME preview" }.count
        #expect(calls == 1 && first.posts.first?.mark == .yes)

        // a slider move waits out 300 ms; a second one inside it starts the wait again
        editor.draft.cutoff = 0.9
        editor.draftChanged()
        await rig.run(for: 0.2)
        editor.draft.cutoff = 0.95
        editor.draftChanged()
        await rig.run(for: 0.2)
        #expect(rig.client.searchState.names.calls.filter { $0 == "NAME preview" }.count == 1)
        await rig.run(for: 1)
        #expect(rig.client.searchState.names.calls.filter { $0 == "NAME preview" }.count == 2)
        #expect(editor.isDirty && editor.canSave)

        // a tap in who's in marks the post, and save writes it
        let key = try #require(editor.notCarrying.first?.postKey ?? editor.carrying.last?.postKey)
        editor.cycle(key)
        #expect(editor.draft.mark(of: key) == .yes || editor.draft.mark(of: key) == .no)
        async let saving = editor.save()
        await rig.run(for: 1)
        #expect(await saving)
        #expect(!editor.isDirty && editor.savedTick == 1 && names.names[0].cutoff == 0.95)
    }

    @Test func aNewNameStartsWithThePostAsItsExample() async throws {
        let rig = SearchRig(.ready)
        let names = rig.app.searchNames
        names.startNew(example: "Dd55fEyN1Yy")
        let editor = try #require(names.editor)
        #expect(editor.isNew && editor.draft.yes == ["Dd55fEyN1Yy"] && !editor.canSave)
        editor.start()
        await rig.run(for: 1)
        #expect(editor.preview == nil, "no meaning yet: nothing to ask")
        editor.draft.name = "boats"
        editor.draft.meaning = "boats in a harbour"
        editor.draftChanged()
        await rig.run(for: 2)
        #expect(editor.preview?.posts.first?.postKey == "Dd55fEyN1Yy")
        async let saving = editor.save()
        await rig.run(for: 1)
        #expect(await saving)
        #expect(names.names.contains { $0.name == "boats" } && !editor.isNew)

        // taken: the word is said
        names.startNew()
        let other = try #require(names.editor)
        other.draft = SearchNameDraft(name: "BOATS", meaning: "x")
        async let refused = other.save()
        await rig.run(for: 1)
        #expect(await !refused)
        #expect(other.saveProblem == .taken(word: "boats"))
    }

    @Test func aMarkFromTheDetailReachesTheList() async throws {
        let rig = SearchRig(.ready)
        let names = rig.app.searchNames
        async let loading: Void = names.load()
        await rig.run(for: 1)
        await loading
        let lia = names.names[0]
        let before = names.revision
        async let marking = names.mark("Dd55fEyN1Yy", .no, on: lia.id)
        await rig.run(for: 1)
        let saved = try #require(await marking)
        #expect(saved.no.first == "Dd55fEyN1Yy" && names.names[0].no.first == "Dd55fEyN1Yy" && names.revision > before)
    }
}

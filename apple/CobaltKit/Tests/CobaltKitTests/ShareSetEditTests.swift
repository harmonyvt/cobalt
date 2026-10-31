import Foundation
import Testing
@testable import CobaltKit

// Editing a gallery link's files (APP-API-CONTRACT 41): the capability, the draft's rules and what the save bar says,
// the library's "add to link" verdict, the PATCH on the wire (the 409 that carries the current link), and the store on
// the preview server.

private let editKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

private func wire(id: String = "9000000000000000001", items: [String], title: String? = nil, isPrivate: Bool = false) -> String {
    let files = items.map { item in
        #"{"id":"\#(item)","url":"https://media.capybaraharmony.com/\#(item)AbCdE.webp","content_type":"image/webp","poster_url":null,"width":480,"height":480,"duration":null}"#
    }
    let titleJSON = title.map { #""\#($0)""# } ?? "null"
    return #"{"id":"\#(id)","url":"https://share.capybaraharmony.com/g/\#(id)","title":\#(titleJSON),"created_at":1790000000000,"private":\#(isPrivate),"items":[\#(files.joined(separator: ","))]}"#
}

private func link(_ items: [String], isPrivate: Bool = false) -> ShareSet {
    ShareSet(
        id: "9000000000000000001", url: URL(string: "https://share.capybaraharmony.com/g/9000000000000000001")!,
        createdAt: Date(timeIntervalSince1970: 1_790_000_000),
        items: items.map { ShareSetItem(id: $0, url: URL(string: "https://media.capybaraharmony.com/\($0).webp")) },
        isPrivate: isPrivate)
}

// MARK: - capability and wire shape

struct ShareSetEditCapabilityTests {
    private func caps(_ features: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":\#(features),"share_base_url":"https://share.capybaraharmony.com/","key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func theFlagIsReadAndNeedsShareSets() throws {
        #expect(try caps(#"{"share_sets":true,"share_set_edit":true}"#).shareSetEdit)
        #expect(try !caps(#"{"share_sets":false,"share_set_edit":true}"#).shareSetEdit)
        #expect(try !caps(#"{"share_sets":true}"#).shareSetEdit)
        #expect(!Capabilities.unknown.shareSetEdit)
        #expect(PreviewData.capabilities(for: .happy).shareSetEdit)
        #expect(!PreviewData.capabilities(for: .plainCobalt).shareSetEdit)
    }

    @Test func aHiddenFileIsMarked() throws {
        let json = #"{"id":"h1","url":null,"content_type":"video/mp4","hidden":true}"#
        let item = try CobaltJSON.decoder().decode(ShareSetItem.self, from: Data(json.utf8))
        #expect(item.hidden && !item.isPublic && item.isVideo)
        let plain = try CobaltJSON.decoder().decode(ShareSetItem.self, from: Data(#"{"id":"p1","url":null}"#.utf8))
        #expect(!plain.hidden)
    }
}

// MARK: - the draft

struct ShareSetEditRuleTests {
    @Test func aFreshDraftHasNoChanges() {
        let edit = ShareSetEdit(original: ["a", "b", "c"], originalTitle: "friday", maximum: 10)
        #expect(edit.items == ["a", "b", "c"] && edit.title == "friday")
        #expect(edit.changes.isEmpty && !edit.hasChanges && !edit.canSave)
        #expect(edit.room == 7 && !edit.isFull && edit.canRemove)
        #expect(edit.itemsToSend == nil && edit.titleChange == .keep)
    }

    @Test func theSummaryNamesEachKindOfChangeInOrder() {
        var edit = ShareSetEdit(original: ["a", "b", "c", "d"], originalTitle: nil, maximum: 10)
        edit.remove("b")
        edit.append(["x", "y"])
        edit.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)          // d first
        edit.title = "  new  "
        #expect(edit.items == ["d", "a", "c", "x", "y"])
        #expect(edit.added == ["x", "y"] && edit.removed == ["b"] && edit.moved)
        #expect(edit.changes == [.added(2), .removed(1), .reordered, .retitled])
        #expect(edit.canSave && edit.itemsToSend == ["d", "a", "c", "x", "y"] && edit.titleChange == .set("new"))
    }

    @Test func addingAndRemovingIsNotAMove() {
        var edit = ShareSetEdit(original: ["a", "b", "c"], originalTitle: nil, maximum: 10)
        edit.remove("b")
        edit.append(["z"])
        #expect(!edit.moved && edit.changes == [.added(1), .removed(1)])
    }

    @Test func movingBackIsNoChange() {
        var edit = ShareSetEdit(original: ["a", "b", "c"], originalTitle: nil, maximum: 10)
        edit.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)          // a last
        #expect(edit.items == ["b", "c", "a"] && edit.changes == [.reordered])
        edit.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)          // a first again
        #expect(edit.items == ["a", "b", "c"] && !edit.hasChanges)
    }

    @Test func twoFilesIsTheFloor() {
        var edit = ShareSetEdit(original: ["a", "b", "c"], originalTitle: nil, maximum: 10)
        edit.remove("a")
        #expect(edit.items == ["b", "c"] && !edit.canRemove && edit.canSave)
        edit.remove("b")                                                  // refused at 2
        #expect(edit.items == ["b", "c"])
    }

    @Test func theRoomStopsTheAppend() {
        var edit = ShareSetEdit(original: ["a", "b", "c"], originalTitle: nil, maximum: 4)
        #expect(edit.room == 1)
        let taken = edit.append(["a", "x", "y"])                           // a is in already, y does not fit
        #expect(taken == ["x"] && edit.items == ["a", "b", "c", "x"] && edit.isFull)
    }

    @Test func theTitleIsCleanedClearedAndCapped() {
        var edit = ShareSetEdit(original: ["a", "b"], originalTitle: "friday", maximum: 10)
        edit.title = " friday "
        #expect(!edit.titleChanged && edit.titleChange == .keep)
        edit.title = "   "
        #expect(edit.titleChanged && edit.titleChange == .clear && edit.changes == [.retitled] && edit.canSave)
        edit.title = String(repeating: "x", count: 81)
        #expect(!edit.titleFits && !edit.canSave)
        let untitled = ShareSetEdit(original: ["a", "b"], originalTitle: nil, maximum: 10)
        #expect(untitled.title == "" && !untitled.titleChanged)
    }

    @Test func resetPutsTheLinkBack() {
        var edit = ShareSetEdit(original: ["a", "b", "c"], originalTitle: "t", maximum: 10)
        edit.remove("a")
        edit.title = "u"
        edit.reset()
        #expect(edit.items == ["a", "b", "c"] && edit.title == "t" && !edit.hasChanges)
    }

    @Test func moveMatchesTheListsMeaning() {
        let list = ["a", "b", "c", "d"]
        #expect(ShareSetEdit.moving(list, fromOffsets: IndexSet(integer: 0), toOffset: 2) == ["b", "a", "c", "d"])
        #expect(ShareSetEdit.moving(list, fromOffsets: IndexSet(integer: 3), toOffset: 1) == ["a", "d", "b", "c"])
        #expect(ShareSetEdit.moving(list, fromOffsets: IndexSet([0, 1]), toOffset: 4) == ["c", "d", "a", "b"])
        #expect(ShareSetEdit.moving(list, fromOffsets: IndexSet(integer: 9), toOffset: 0) == list)
    }
}

// MARK: - "add to link"

struct ShareSetAddVerdictTests {
    private func pick(_ publicID: String?, _ anyID: String?) -> ShareSetPick {
        ShareSetPick(publicFileID: publicID, anyFileID: anyID, fileIDs: Set([publicID, anyID].compactMap { $0 }))
    }

    @Test func freshPublicPicksFit() {
        let l = link(["a", "b", "c"])
        let picks = [pick("x", "x"), pick("y", "y")]
        #expect(ShareSetRule.addVerdict(picks, to: l, maximum: 10) == .ready(adding: 2))
        #expect(ShareSetRule.fileIDs(adding: picks, to: l) == ["x", "y"])
    }

    @Test func picksAlreadyInAreSkippedAndAllInSaysSo() {
        let l = link(["a", "b", "c"])
        #expect(ShareSetRule.addVerdict([pick("a", "a"), pick("b", "b")], to: l, maximum: 10) == .alreadyIn)
        #expect(ShareSetRule.addVerdict([pick("a", "a"), pick("x", "x")], to: l, maximum: 10) == .ready(adding: 1))
        // a post whose other file is in the link counts as in it
        let other = ShareSetPick(publicFileID: "w2", anyFileID: "w2", fileIDs: ["w2", "b"])
        #expect(ShareSetRule.addVerdict([other], to: l, maximum: 10) == .alreadyIn)
    }

    @Test func noRoomSaysHowMuch() {
        let l = link(["a", "b", "c", "d", "e", "f", "g", "h", "i"])
        #expect(ShareSetRule.addVerdict([pick("x", "x"), pick("y", "y")], to: l, maximum: 10) == .noRoom(room: 1))
        #expect(ShareSetRule.addVerdict([pick("x", "x")], to: l, maximum: 10) == .ready(adding: 1))
    }

    @Test func aPrivatePickOnlyGoesInAPrivateLink() {
        let picks = [pick("x", "x"), pick(nil, "p")]
        #expect(ShareSetRule.addVerdict(picks, to: link(["a", "b"]), maximum: 10) == .hasPrivate)
        let privateLink = link(["a", "b"], isPrivate: true)
        #expect(ShareSetRule.addVerdict(picks, to: privateLink, maximum: 10) == .ready(adding: 2))
        #expect(ShareSetRule.fileIDs(adding: picks, to: privateLink) == ["x", "p"])
    }

    @Test func theOrderIsAlreadyInThenRoomThenPrivate() {
        let full = link(["a", "b", "c", "d"])
        #expect(ShareSetRule.addVerdict([pick(nil, "p")], to: full, maximum: 4) == .noRoom(room: 0))
    }
}

// MARK: - the PATCH on the wire

@Suite(.serialized)
struct ShareSetEditHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { editKey })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test func updateIsAKeyedPatchWithTheListTitleAndExpect() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "PATCH" && req.path == "/share/sets/9000000000000000001"
                ? .json(#"{"status":"success","set":"# + wire(items: ["b", "a", "x"], title: "harbour") + "}") : .init(status: 404)
        }
        defer { server.stop() }
        let set = try await client(server).updateShareSet(
            id: "9000000000000000001", items: ["b", "a", "x"], title: .set("harbour"), expect: ["a", "b"])
        let req = try #require(server.requests.first)
        #expect(req.headers["authorization"] == "Api-Key \(editKey)")
        let body = try bodyJSON(req)
        #expect(body["items"] as? [String] == ["b", "a", "x"] && body["title"] as? String == "harbour")
        #expect(body["expect"] as? [String] == ["a", "b"] && body.count == 3)
        #expect(set.items.map(\.id) == ["b", "a", "x"] && set.title == "harbour")
    }

    @Test func keepLeavesTheTitleOutAndClearSendsNull() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"status":"success","set":"# + wire(items: ["a", "b"]) + "}") }
        defer { server.stop() }
        _ = try await client(server).updateShareSet(id: "9000000000000000001", items: ["a", "b"], title: .keep, expect: nil)
        _ = try await client(server).updateShareSet(id: "9000000000000000001", items: nil, title: .clear, expect: nil)
        let first = try bodyJSON(server.requests[0])
        #expect(first["items"] as? [String] == ["a", "b"] && first["title"] == nil && first["expect"] == nil && first.count == 1)
        let second = try bodyJSON(server.requests[1])
        #expect(second["title"] is NSNull && second["items"] == nil && second.count == 1)
    }

    @Test func changedCarriesTheCurrentLink() async throws {
        let current = wire(items: ["c", "a", "b"], title: "moved on")
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"error","error":{"code":"error.share.changed"},"set":"# + current + "}", status: 409)
        }
        defer { server.stop() }
        do {
            _ = try await client(server).updateShareSet(id: "9000000000000000001", items: ["a", "b", "x"], title: .keep, expect: ["a", "b"])
            Issue.record("expected a refusal")
        } catch ShareSetError.changed(let set) {
            #expect(set.items.map(\.id) == ["c", "a", "b"] && set.title == "moved on")
        }
    }

    @Test func changedWithoutALinkIsTheGenericAnswer() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"error","error":{"code":"error.share.changed"}}"#, status: 409)
        }
        defer { server.stop() }
        await #expect(throws: CobaltError.api(code: "error.share.changed", httpStatus: 409)) {
            try await client(server).updateShareSet(id: "9000000000000000001", items: ["a", "b"], title: .keep, expect: ["a"])
        }
    }

    @Test func hiddenNotPublicAndNotFoundAreMapped() async throws {
        let server = try await LoopbackServer.start { req in
            let body = String(decoding: req.body, as: UTF8.self)
            if body.contains("\"h\"") { return .json(#"{"status":"error","error":{"code":"error.hidden"},"ids":["h"]}"#, status: 409) }
            if body.contains("\"p\"") {
                return .json(#"{"status":"error","error":{"code":"error.share.not_public"},"items":["p"]}"#, status: 409)
            }
            return .json(#"{"status":"error","error":{"code":"error.share.not_found"}}"#, status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        await #expect(throws: ShareSetError.hidden(["h"])) { try await c.updateShareSet(id: "1", items: ["a", "h"], title: .keep, expect: nil) }
        await #expect(throws: ShareSetError.notPublic(["p"])) { try await c.updateShareSet(id: "1", items: ["a", "p"], title: .keep, expect: nil) }
        await #expect(throws: ShareSetError.notFound) { try await c.updateShareSet(id: "1", items: ["a", "b"], title: .keep, expect: nil) }
    }
}

// MARK: - the store on the preview server

@MainActor
struct ShareSetEditStoreTests {
    private let harbour = "9000000000000000001"          // video, webp, photo: room for 1 under the preview's 4

    private func app() -> AppModel {
        AppModel.makePreview(.happy, timeScale: 0.01, clock: SystemClock())
    }

    /// Public library file ids of the preview library that the harbour link does not hold (no file of their post in it).
    private func freshPublicIDs(_ app: AppModel) -> [String] {
        let held = Set(app.shareSets.set(harbour)?.items.map(\.id) ?? [])
        return app.library.posts.compactMap { post -> String? in
            guard let item = MediaItem.merge(local: nil, post: post) else { return nil }
            guard ShareSetIndex.fileIDs(of: item).isDisjoint(with: held) else { return nil }
            return ShareSetRule.fileID(for: item)
        }
    }

    @Test func updateReplacesTheLinkInPlace() async throws {
        let app = app()
        await app.shareSets.refresh()
        let before = try #require(app.shareSets.set(harbour))
        let reordered = Array(before.items.map(\.id).reversed())
        let updated = try await app.shareSets.update(harbour, items: reordered, title: .set("new name"), expect: before.items.map(\.id))
        #expect(updated.items.map(\.id) == reordered && updated.title == "new name")
        #expect(app.shareSets.sets.first?.id == harbour, "it keeps its place")
        #expect(app.shareSets.set(harbour)?.items.map(\.id) == reordered)
        await app.shareSets.refresh()
        #expect(app.shareSets.set(harbour)?.items.map(\.id) == reordered && app.shareSets.set(harbour)?.title == "new name")
    }

    @Test func aTitleOnlySaveAndAClear() async throws {
        let app = app()
        await app.shareSets.refresh()
        _ = try await app.shareSets.update(harbour, items: nil, title: .clear, expect: nil)
        #expect(app.shareSets.set(harbour)?.title == nil && app.shareSets.set(harbour)?.items.count == 3)
    }

    @Test func aLinkChangedElsewhereIsReloadedAndTheErrorRethrown() async throws {
        let app = app()
        await app.shareSets.refresh()
        let seen = try #require(app.shareSets.set(harbour)).items.map(\.id)
        let client = try #require(app.ctx.client as? PreviewClient)
        let behind = try #require(client.shareState.set(harbour)).items.reversed()
        client.shareState.changeBehind(harbour, items: Array(behind))
        do {
            try await app.shareSets.update(harbour, items: Array(seen.prefix(2)), expect: seen)
            Issue.record("expected changed")
        } catch ShareSetError.changed(let current) {
            #expect(current.items.map(\.id) == behind.map(\.id))
        }
        #expect(app.shareSets.set(harbour)?.items.map(\.id) == behind.map(\.id), "the store shows the server's link")
    }

    @Test func addFilesAppendsAndStopsAtTheMaximum() async throws {
        let app = app()
        await app.shareSets.refresh()
        let fresh = freshPublicIDs(app)
        #expect(fresh.count >= 2)
        let updated = try await app.shareSets.addFiles([fresh[0]], to: harbour)
        #expect(updated.items.count == 4 && updated.items.last?.id == fresh[0])
        // the same file again changes nothing and asks nothing
        let again = try await app.shareSets.addFiles([fresh[0]], to: harbour)
        #expect(again.items.count == 4)
        await #expect(throws: ShareSetError.badRequest) { try await app.shareSets.addFiles([fresh[1]], to: harbour) }
        await #expect(throws: ShareSetError.notFound) { try await app.shareSets.addFiles([fresh[1]], to: "nope") }
    }

    @Test func aPrivateFileIsRefusedInAPublicLink() async throws {
        let app = app()
        await app.shareSets.refresh()
        let seen = try #require(app.shareSets.set(harbour)).items.map(\.id)
        let privateID = "PrEvIeWitem000007"
        await #expect(throws: ShareSetError.notPublic([privateID])) {
            try await app.shareSets.update(harbour, items: seen + [privateID], expect: seen)
        }
        #expect(app.shareSets.set(harbour)?.items.map(\.id) == seen, "nothing changed")
    }

    @Test func aRevokedLinkGoesFromTheList() async throws {
        let app = app()
        await app.shareSets.refresh()
        let seen = try #require(app.shareSets.set(harbour)).items.map(\.id)
        try await app.ctx.client.revokeShareSet(id: harbour)
        await #expect(throws: ShareSetError.notFound) {
            try await app.shareSets.update(harbour, items: Array(seen.prefix(2)), expect: seen)
        }
        #expect(app.shareSets.set(harbour) == nil)
    }

    @Test func anOldClientIsUnsupported() async throws {
        let app = AppModel.makePreview(.plainCobalt, timeScale: 0.01, clock: SystemClock())
        await #expect(throws: PipelineFailure.unsupported) {
            try await app.ctx.client.updateShareSet(id: "x", items: ["a", "b"], title: .keep, expect: nil)
        }
    }
}

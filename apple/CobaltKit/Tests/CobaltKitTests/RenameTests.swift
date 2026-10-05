import Foundation
import Testing
@testable import CobaltKit

// CONTRACT-LIBRARY2.md section 9 K: `AppModel.rename` (decisions 5-8) over `PreviewClient`.
// Tests marked `titlesFlagIsStored` need a server with `features.titles`; they are skipped while
// `Capabilities.titles` is the K1 shim (`k1-requests.md` 1).

private let ddPost = "Dd7P496wolG"        // video + three webps; its first file is PrEvIeWitem000003
private let fivePost = "Dd5JFkMDt4N"      // first file PrEvIeWitem000008: the one `.renameFails` fails once
private let renameFailsExists = PreviewScenario(rawValue: "renameFails") != nil

@MainActor
private func app(_ scenario: PreviewScenario = .renditions, titles: Bool) -> AppModel {
    let app = AppModel.makePreview(scenario, timeScale: 1, clock: SystemClock())
    var caps = app.capabilities
    caps.titles = titles
    app.apply(caps)
    return app
}

@MainActor
private func itemOf(_ app: AppModel, post id: String) throws -> MediaItem {
    app.mediaItem(for: try #require(app.library.posts.first { $0.id == id }))
}

@MainActor
private func calls(_ app: AppModel) -> [String] { (app.ctxForTests.client as? PreviewClient)?.server.titleCalls ?? ["no preview client"] }

@MainActor
struct RenameLocalTests {
    @Test func withoutTheCapabilityTheRenameStaysOnThisDeviceAndSendsNothing() async throws {
        let app = app(titles: false)
        let before = try itemOf(app, post: ddPost)
        #expect(before.titleText == "instagram · Dd7P496wolG" && before.customTitle == nil)

        try await app.rename(before, to: "  my clip \n")
        let after = try itemOf(app, post: ddPost)
        #expect(after.titleText == "my clip" && after.customTitle == "my clip" && after.defaultTitleText == "instagram · Dd7P496wolG")
        #expect(app.libraryRows.first { $0.id == ddPost }?.title == "my clip")
        #expect(calls(app).isEmpty)
        #expect(app.library.posts.first { $0.id == ddPost }?.customTitle == nil)          // the server's copy is untouched
        // the device's media shows it too, before the library has anything to say
        let local = try #require(app.store.media(id: "preview-media-dd7p496wolg"))
        #expect(app.mediaItem(for: local).titleText == "my clip")
    }

    @Test func theDefaultTextOrAnEmptyOneClears() async throws {
        let app = app(titles: false)
        try await app.rename(try itemOf(app, post: ddPost), to: "my clip")
        #expect(try itemOf(app, post: ddPost).customTitle == "my clip")

        try await app.rename(try itemOf(app, post: ddPost), to: "instagram · Dd7P496wolG")   // the default text
        #expect(try itemOf(app, post: ddPost).customTitle == nil)
        #expect(try itemOf(app, post: ddPost).titleText == "instagram · Dd7P496wolG")

        try await app.rename(try itemOf(app, post: ddPost), to: "again")
        try await app.rename(try itemOf(app, post: ddPost), to: "   ")                       // blank
        #expect(try itemOf(app, post: ddPost).customTitle == nil)
        try await app.rename(try itemOf(app, post: ddPost), to: "third")
        try await app.rename(try itemOf(app, post: ddPost), to: nil)
        #expect(try itemOf(app, post: ddPost).customTitle == nil)
        #expect(calls(app).isEmpty)
    }

    @Test func theTitleIsCleanedAndCutAtEightyCodePoints() async throws {
        let app = app(titles: false)
        try await app.rename(try itemOf(app, post: ddPost), to: String(repeating: "é", count: 100) + "\n")
        let title = try #require(try itemOf(app, post: ddPost).customTitle)
        #expect(title.unicodeScalars.count == 80)
    }

    @Test func aMediaThatOnlyThisDeviceHasIsRenamedLocally() async throws {
        let app = app(titles: true)                                    // even with the capability: no server file
        let local = try #require(app.store.media.first { MediaItem.merge(local: $0, post: nil)?.post == nil && app.mediaItem(for: $0).post == nil })
        let before = app.mediaItem(for: local)
        #expect(!before.hasServerCopy || before.post == nil)
        try await app.rename(before, to: "orbit one")
        #expect(app.mediaItem(for: local).titleText == "orbit one")
        #expect(calls(app).isEmpty)
    }

    @Test func renamingToWhatItAlreadyIsDoesNothing() async throws {
        let app = app(titles: false)
        try await app.rename(try itemOf(app, post: ddPost), to: "same")
        let before = app.library.localTitles
        try await app.rename(try itemOf(app, post: ddPost), to: "same")
        #expect(app.library.localTitles == before)
        try await app.rename(try itemOf(app, post: "2105432512428445875"), to: "x · 2105432512428445875")    // its default
        #expect(app.library.localTitles == before)
    }
}

@MainActor
struct RenameServerTests {
    @Test(.enabled(if: titlesFlagIsStored)) func theTitleShowsAtOnceThenTheServerConfirms() async throws {
        let app = app(titles: true)
        let client = try #require(app.ctxForTests.client as? PreviewClient)
        let target = try itemOf(app, post: ddPost)
        let task = Task { @MainActor in try await app.rename(target, to: "my clip") }

        for _ in 0..<100 where app.library.posts.first(where: { $0.id == ddPost })?.customTitle == nil { await Task.yield() }
        // optimistic: the library shows it while the request is still in flight
        #expect(app.library.posts.first { $0.id == ddPost }?.customTitle == "my clip")
        #expect(try itemOf(app, post: ddPost).titleText == "my clip")
        #expect(client.server.titles.isEmpty)

        try await task.value
        #expect(client.server.titleCalls == ["PrEvIeWitem000003 my clip"])             // the post's first file is the anchor
        #expect(client.server.titles[ddPost] == "my clip")
        #expect(try itemOf(app, post: ddPost).titleText == "my clip")
        // and a refresh brings the server's copy, which agrees
        await app.library.refresh()
        #expect(app.library.posts.first { $0.id == ddPost }?.customTitle == "my clip")
    }

    @Test(.enabled(if: titlesFlagIsStored)) func clearingSendsANullTitle() async throws {
        let app = app(titles: true)
        try await app.rename(try itemOf(app, post: ddPost), to: "my clip")
        try await app.rename(try itemOf(app, post: ddPost), to: "instagram · Dd7P496wolG")  // the default text clears
        #expect(calls(app) == ["PrEvIeWitem000003 my clip", "PrEvIeWitem000003 -"])
        #expect(try itemOf(app, post: ddPost).customTitle == nil)
        await app.library.refresh()
        #expect(app.library.posts.first { $0.id == ddPost }?.customTitle == nil)
    }

    @Test(.enabled(if: titlesFlagIsStored)) func aFailureRevertsAndThrows() async throws {
        let app = app(titles: true)
        // an item the "server" no longer knows: its post's files are not in the preview library
        var post = try #require(app.library.posts.first { $0.id == ddPost })
        post.files = post.files.map { var f = $0; f.id = "gone-\(f.id)"; return f }
        app.library.posts = app.library.posts.map { $0.id == ddPost ? post : $0 }
        let before = try itemOf(app, post: ddPost)

        await #expect(throws: PipelineFailure.server(code: "error.library.not_found")) {
            try await app.rename(before, to: "my clip")
        }
        let after = try itemOf(app, post: ddPost)
        #expect(after.customTitle == nil && after.titleText == "instagram · Dd7P496wolG")
        #expect(app.library.posts.first { $0.id == ddPost }?.customTitle == nil && app.library.localTitles.isEmpty)
    }

    @Test(.enabled(if: titlesFlagIsStored && renameFailsExists)) func theRenameFailsScenarioFailsOnceThenWorks() async throws {
        let scenario = try #require(PreviewScenario(rawValue: "renameFails"))
        let app = app(scenario, titles: true)
        let before = try itemOf(app, post: fivePost)
        let kept = try #require(app.library.posts.first { $0.id == fivePost }?.customTitle ?? .some(""))
        #expect(kept.isEmpty)

        await #expect(throws: PipelineFailure.server(code: "error.api.generic")) {
            try await app.rename(before, to: "my cat")
        }
        let reverted = try itemOf(app, post: fivePost)
        #expect(reverted.customTitle == nil && reverted.titleText == before.titleText)
        #expect(app.library.localTitles.isEmpty)

        try await app.rename(try itemOf(app, post: fivePost), to: "my cat")                 // the retry works
        #expect(try itemOf(app, post: fivePost).titleText == "my cat")
        #expect(calls(app) == ["PrEvIeWitem000008 my cat", "PrEvIeWitem000008 my cat"])
    }

    @Test func theCapabilityIsOnForTheForkScenariosAndOffWhereTheServerCannotDoIt() {
        func titles(_ s: PreviewScenario) -> Bool { PreviewData.capabilities(for: s).titles }
        // whatever the flag's storage, the answer for plain cobalt and the legacy fork is "no"
        #expect(!titles(.plainCobalt) && !titles(.legacyFork) && !titles(.renditionsLegacy))
        #expect(titles(.renditions) == titlesFlagIsStored && titles(.happy) == titlesFlagIsStored)
    }
}

import Foundation
import Testing
@testable import CobaltKit

// The editor's list and its preview server (apple/CONTRACT-EDITOR.md 3.6, 3.8): scenarios, open and close, rename and delete, renders
// that move on the clock, `create(from:)`, and the capability.

private func mediaItem(
    _ key: String, title: String? = nil, custom: String? = nil, file: String?, w: Int = 1280, h: Int = 720, seconds: Double = 8,
    contentType: String = "video/mp4"
) -> MediaItem {
    let libraryFile = file.map {
        LibraryFile(
            id: $0, kind: .private, source: .upload, name: title ?? "\(key).mp4", url: nil, contentType: contentType, bytes: 1_000,
            width: w, height: h, duration: seconds, createdAt: Date(timeIntervalSince1970: 1_790_000_000), mediaName: nil, deletable: true)
    }
    let post = LibraryPost(
        id: key, service: "upload", link: nil, title: title, duration: seconds, width: w, height: h,
        createdAt: Date(timeIntervalSince1970: 1_790_000_000), session: nil, files: libraryFile.map { [$0] } ?? [],
        customTitle: custom)
    let video = Rendition(
        id: "video", kind: .video, file: libraryFile, width: w, height: h, duration: seconds, createdAt: post.createdAt)
    return MediaItem(id: "post:\(key)", local: nil, post: post, service: "upload", ref: nil, link: nil, renditions: [video])
}

private func gallery(_ key: String, items: [(String?, MediaType)]) -> MediaItem {
    var renditions: [Rendition] = []
    var files: [LibraryFile] = []
    for (i, entry) in items.enumerated() {
        let file = entry.0.map {
            LibraryFile(
                id: $0, kind: .private, source: .upload, name: "item\(i)", url: nil,
                contentType: entry.1 == .photo ? "image/jpeg" : (entry.1 == .gif ? "image/gif" : "video/mp4"), bytes: 1_000,
                width: 1080, height: 1920, duration: entry.1 == .photo ? nil : 6, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                mediaName: nil, deletable: true)
        }
        if let file { files.append(file) }
        renditions.append(Rendition(
            id: "item\(i)", kind: .item(index: i, type: entry.1), file: file, width: 1080, height: 1920,
            duration: entry.1 == .photo ? nil : 6, createdAt: Date(timeIntervalSince1970: 1_790_000_000)))
    }
    let post = LibraryPost(
        id: key, service: "instagram", link: nil, title: nil, duration: nil, width: nil, height: nil,
        createdAt: Date(timeIntervalSince1970: 1_790_000_000), session: nil, files: files, kind: .gallery, itemCount: items.count)
    return MediaItem(id: "post:\(key)", local: nil, post: post, service: "instagram", ref: nil, link: nil, renditions: renditions)
}

@MainActor
private struct StoreRig {
    let h: Harness
    var store: EditorStore { h.app.editor }
    var client: PreviewClient { h.ctx.client as! PreviewClient }

    init(_ scenario: PreviewScenario = .happy) { h = Harness(scenario) }

    func finish() { store.closeAnyway() }
}

// MARK: - the list

@MainActor
struct EditorListTests {
    @Test func theCapabilityFollowsTheServer() {
        let on = StoreRig(.happy)
        #expect(on.store.isAvailable && on.h.app.capabilities.editor)
        let off = StoreRig(.legacyFork)
        #expect(!off.store.isAvailable)
        #expect(!StoreRig(.plainCobalt).store.isAvailable)
        #expect(StoreRig(.editorEmpty).store.isAvailable)
    }

    @Test func theHappyServerHasTwoProjectsNewestFirst() async throws {
        let rig = StoreRig()
        #expect(rig.store.listState == .idle)
        await rig.store.refresh()
        #expect(rig.store.listState == .loaded)
        #expect(rig.store.projects.map(\.title) == ["beach day edit", "cat compilation"])
        let beach = rig.store.projects[0]
        #expect(beach.canvas == EditCanvas(w: 1080, h: 1920, fps: 30) && beach.duration == 26 && beach.clipCount == 4)
        #expect(beach.revision == 4 && beach.timeline == nil)
        let cats = rig.store.projects[1]
        #expect(cats.canvas == EditCanvas(w: 1280, h: 720, fps: 60) && cats.clipCount == 6)
        #expect(cats.render?.status == .done)
        #expect(rig.store.render(PreviewEditorIDs.catsRender)?.itemID != nil)
    }

    @Test func anEmptyServerHasNoProjects() async {
        let rig = StoreRig(.editorEmpty)
        await rig.store.refresh()
        #expect(rig.store.listState == .loaded && rig.store.projects.isEmpty && rig.store.renders.isEmpty)
    }

    @Test func aFailingListSaysSoAndKeepsTheStateHonest() async {
        let rig = StoreRig(.editorFail)
        await rig.store.refresh()
        #expect(rig.store.listState == .failed(.unavailable))
        #expect(rig.store.projects.isEmpty)
    }

    @Test func aServerWithoutTheEditorLoadsNothing() async {
        let rig = StoreRig(.legacyFork)
        await rig.store.refresh()
        #expect(rig.store.listState == .idle && rig.store.projects.isEmpty)
        #expect(rig.client.editorState.calls.isEmpty)
    }

    @Test func renamingAndDeletingChangeTheList() async throws {
        let rig = StoreRig()
        await rig.store.refresh()
        try await rig.store.rename(PreviewEditorIDs.cats, to: "  cats, again ")
        #expect(rig.store.projects.first?.title == "cats, again")          // renaming makes it the newest
        try await rig.store.delete(PreviewEditorIDs.beach)
        #expect(rig.store.projects.map(\.id) == [PreviewEditorIDs.cats])
        do {
            try await rig.store.delete(PreviewEditorIDs.beach)
        } catch {
            Issue.record("deleting twice should be quiet, got \(error)")
        }
        do {
            try await rig.store.rename("nothing", to: "x")
            Issue.record("renaming a missing project should throw")
        } catch {
            #expect(error == .notFound)
        }
    }
}

// MARK: - open and close

@MainActor
struct EditorOpenTests {
    @Test func openingShowsTheProjectWithItsFiles() async throws {
        let rig = StoreRig()
        defer { rig.finish() }
        await rig.store.refresh()
        try await rig.store.open(PreviewEditorIDs.beach)
        let session = try #require(rig.store.session)
        #expect(session.project.id == PreviewEditorIDs.beach && session.project.title == "beach day edit")
        #expect(session.timeline == EditJSON.rounded(PreviewData.editorBeachTimeline()))
        #expect(Set(session.sources.keys) == [
            PreviewEditorIDs.pier, PreviewEditorIDs.surf, PreviewEditorIDs.sunset, PreviewEditorIDs.friends, PreviewEditorIDs.dance,
        ])
        #expect(session.sources[PreviewEditorIDs.friends]?.display == PixelSize(w: 1080, h: 1920))
        try await rig.store.open(PreviewEditorIDs.beach)                   // already open: the same session
        #expect(rig.store.session === session)
    }

    @Test func aMissingProjectThrowsNotFound() async {
        let rig = StoreRig()
        do {
            try await rig.store.open("nothing")
            Issue.record("should have thrown")
        } catch {
            #expect(error == .notFound)
        }
        #expect(rig.store.session == nil)
    }

    @Test func closingFlushesTheAutosaveAndShowsTheListAgain() async throws {
        let rig = StoreRig()
        try await rig.store.open(PreviewEditorIDs.beach)
        let session = try #require(rig.store.session)
        session.setVolume(0.5, clip: session.timeline.main[0].id)
        let closed = await rig.store.close()
        #expect(closed && rig.store.session == nil)
        #expect(rig.client.editorState.timeline(of: PreviewEditorIDs.beach)?.main[0].volume == 0.5)
        #expect(rig.store.projects.first { $0.id == PreviewEditorIDs.beach }?.revision == 5)
    }

    @Test func closingWithUnsavedChangesKeepsTheEditorUntilTheOwnerSaysSo() async throws {
        let rig = StoreRig()
        defer { rig.finish() }
        try await rig.store.open(PreviewEditorIDs.beach)
        let session = try #require(rig.store.session)
        rig.client.editorState.failNextSaves(20)
        session.setVolume(0.5, clip: session.timeline.main[0].id)
        let closed = await rig.store.close()
        #expect(!closed && rig.store.session === session)
        rig.store.closeAnyway()
        #expect(rig.store.session == nil)
    }

    @Test func aConflictAlsoKeepsTheEditorOpen() async throws {
        let rig = StoreRig(.editorConflict)
        defer { rig.finish() }
        try await rig.store.open(PreviewEditorIDs.beach)
        let session = try #require(rig.store.session)
        session.setVolume(0.5, clip: session.timeline.main[0].id)
        let closed = await rig.store.close()
        #expect(!closed)
        if case .conflict = session.saveState {} else { Issue.record("expected a conflict, got \(session.saveState)") }
    }

    @Test func deletingTheOpenProjectClosesIt() async throws {
        let rig = StoreRig()
        try await rig.store.open(PreviewEditorIDs.cats)
        #expect(rig.store.session != nil)
        try await rig.store.delete(PreviewEditorIDs.cats)
        #expect(rig.store.session == nil && !rig.store.projects.contains { $0.id == PreviewEditorIDs.cats })
    }

    @Test func openingAnotherProjectClosesTheFirst() async throws {
        let rig = StoreRig()
        defer { rig.finish() }
        try await rig.store.open(PreviewEditorIDs.beach)
        try await rig.store.open(PreviewEditorIDs.cats)
        #expect(rig.store.session?.project.id == PreviewEditorIDs.cats)
    }

    @Test func losingTheCapabilityClosesTheEditor() async throws {
        let rig = StoreRig()
        await rig.store.refresh()
        try await rig.store.open(PreviewEditorIDs.beach)
        var caps = rig.h.app.capabilities
        caps.editor = false
        rig.h.app.apply(caps)
        for _ in 0..<500 where rig.store.session != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.store.session == nil && rig.store.projects.isEmpty && rig.store.listState == .idle)
        #expect(!rig.store.isAvailable)
    }

    @Test func losingTheCapabilityWithUnsavedEditsSavesThemFirst() async throws {
        let rig = StoreRig()
        try await rig.store.open(PreviewEditorIDs.beach)
        let session = try #require(rig.store.session)
        session.setVolume(0.5, clip: session.timeline.main[0].id)
        var caps = rig.h.app.capabilities
        caps.editor = false
        rig.h.app.apply(caps)
        for _ in 0..<500 where rig.store.session != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.store.session == nil)
        #expect(rig.client.editorState.timeline(of: PreviewEditorIDs.beach)?.main[0].volume == 0.5)
    }

    @Test func renamingFromTheListWhileOpenKeepsTheNextSaveFromConflicting() async throws {
        let rig = StoreRig()
        defer { rig.finish() }
        try await rig.store.open(PreviewEditorIDs.beach)
        let session = try #require(rig.store.session)
        try await rig.store.rename(PreviewEditorIDs.beach, to: "renamed")
        #expect(session.project.revision == 5 && session.project.title == "renamed")
        session.setVolume(0.5, clip: session.timeline.main[0].id)
        #expect(await session.settle())
        #expect(session.saveState == .saved && session.project.revision == 6)
    }

    @Test func thePreviewHelperOpensAProjectDirectly() async throws {
        let model = AppModel.previewEditor(.happy, open: "cats")
        for _ in 0..<500 where model.editor.session == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.editor.session?.project.id == PreviewEditorIDs.cats)
        model.editor.closeAnyway()
    }
}

// MARK: - renders on the clock

@MainActor
struct EditorRenderTests {
    @Test func aRenderMovesThroughItsStatesAndEndsInAPrivateLibraryItem() async throws {
        let rig = StoreRig(.editorRendering)
        let client = rig.client
        let id = PreviewEditorIDs.liveRender
        #expect(try await client.editRender(id: id).status == .queued)
        rig.h.clock.jump(by: 2)                                              // 10 % of 20 s
        #expect(try await client.editRender(id: id).status == .preparing)
        rig.h.clock.jump(by: 4)                                              // 30 %
        let rendering = try await client.editRender(id: id)
        #expect(rendering.status == .rendering)
        let progress = try #require(rendering.progress)
        #expect(abs(progress - (0.1 + 0.85 * (0.1 / 0.7))) < 1e-9)
        rig.h.clock.jump(by: 13)                                             // 95 %
        #expect(try await client.editRender(id: id).status == .finishing)
        rig.h.clock.jump(by: 1)
        let done = try await client.editRender(id: id)
        #expect(done.status == .done && done.progress == 1)
        let item = try #require(done.itemID)
        let page = try await client.library(cursor: nil, limit: 50)
        let post = try #require(page.posts.first { $0.id == item })
        #expect(post.files.first?.kind == .private && post.title == "beach day edit.mp4")
    }

    @Test func theSlowerTheClockScaleTheLongerARenderTakes() async throws {
        let h = Harness(.editorRendering, timeScale: 5)
        let client = h.ctx.client as! PreviewClient
        h.clock.jump(by: 20)
        #expect(try await client.editRender(id: PreviewEditorIDs.liveRender).status != .done)
        h.clock.jump(by: 80)
        #expect(try await client.editRender(id: PreviewEditorIDs.liveRender).status == .done)
    }

    @Test func aFailingRenderEndsAtSixtyPercent() async throws {
        let rig = StoreRig(.editorRenderFails)
        let started = try await rig.client.renderEdit(id: PreviewEditorIDs.beach, revision: 4, notify: false)
        rig.h.clock.jump(by: 12)
        #expect(try await rig.client.editRender(id: started.id).status == .rendering)
        rig.h.clock.jump(by: 1)
        let failed = try await rig.client.editRender(id: started.id)
        #expect(failed.status == .error && failed.error == "error.edit.render_failed" && failed.progress == 0.6)
        #expect(failed.itemID == nil && failed.finishedAt != nil)
    }

    @Test func aStaleRevisionCannotBeRendered() async throws {
        let rig = StoreRig()
        do {
            _ = try await rig.client.renderEdit(id: PreviewEditorIDs.beach, revision: 3, notify: false)
            Issue.record("should have thrown")
        } catch {
            if case .conflict(let theirs) = EditError.from(error) { #expect(theirs.revision == 4) } else { Issue.record("\(error)") }
        }
    }

    @Test func cancellingAQueuedOrRunningRenderEndsIt() async throws {
        let rig = StoreRig(.editorRendering)
        await rig.store.refresh()
        #expect(rig.store.render(PreviewEditorIDs.liveRender)?.isActive == true)
        rig.h.clock.jump(by: 6)
        try await rig.store.cancel(render: PreviewEditorIDs.liveRender)
        #expect(rig.store.render(PreviewEditorIDs.liveRender)?.status == .cancelled)
        rig.h.clock.jump(by: 30)
        #expect(try await rig.client.editRender(id: PreviewEditorIDs.liveRender).status == .cancelled)
        try await rig.store.cancel(render: PreviewEditorIDs.liveRender)      // cancelling twice answers the same render
    }

    @Test func aFinishedRenderCannotBeCancelled() async throws {
        let rig = StoreRig()
        await rig.store.refresh()
        do {
            try await rig.store.cancel(render: PreviewEditorIDs.catsRender)
            Issue.record("should have thrown")
        } catch {
            #expect(error == .finished)
        }
    }

    @Test func theRenderListIsNewestFirstAndCapped() async throws {
        let rig = StoreRig(.editorRendering)
        let all = try await rig.client.editRenders(limit: 20)
        #expect(all.map(\.id) == [PreviewEditorIDs.liveRender, PreviewEditorIDs.catsRender])
        #expect(try await rig.client.editRenders(limit: 1).count == 1)
    }

    @Test func theStoreKeepsTheFresherCopyOfARender() async throws {
        let rig = StoreRig(.editorRendering)
        await rig.store.refresh()
        rig.h.clock.jump(by: 8)
        let newer = try await rig.client.editRender(id: PreviewEditorIDs.liveRender)
        rig.store.mergeRenders([newer])
        let older = EditRender(
            id: PreviewEditorIDs.liveRender, projectID: PreviewEditorIDs.beach, revision: 4, title: "beach day edit",
            status: .queued, secondsTotal: 26, createdAt: newer.createdAt)
        rig.store.mergeRenders([older])
        #expect(rig.store.render(PreviewEditorIDs.liveRender)?.status == newer.status)
    }
}

// MARK: - the preview server's saves

@MainActor
struct EditorPreviewServerTests {
    @Test func aSaveBumpsTheRevisionAndAStaleOneConflicts() async throws {
        let rig = StoreRig()
        let timeline = PreviewData.editorBeachTimeline()
        let saved = try await rig.client.saveEditProject(id: PreviewEditorIDs.beach, timeline: timeline, baseRevision: 4, title: nil)
        #expect(saved.revision == 5)
        do {
            _ = try await rig.client.saveEditProject(id: PreviewEditorIDs.beach, timeline: timeline, baseRevision: 4, title: nil)
            Issue.record("a stale save should conflict")
        } catch {
            if case .conflict(let theirs) = EditError.from(error) {
                #expect(theirs.revision == 5 && theirs.timeline == EditJSON.rounded(timeline))
            } else {
                Issue.record("\(error)")
            }
        }
    }

    @Test func theFirstSaveOfAConflictScenarioConflictsOnce() async throws {
        let rig = StoreRig(.editorConflict)
        let timeline = PreviewData.editorBeachTimeline()
        do {
            _ = try await rig.client.saveEditProject(id: PreviewEditorIDs.beach, timeline: timeline, baseRevision: 4, title: nil)
            Issue.record("should have conflicted")
        } catch {
            if case .conflict(let theirs) = EditError.from(error) {
                #expect(theirs.revision == 5 && theirs.title == "beach day (iphone)")
            } else {
                Issue.record("\(error)")
            }
        }
        let again = try await rig.client.saveEditProject(id: PreviewEditorIDs.beach, timeline: timeline, baseRevision: 5, title: nil)
        #expect(again.revision == 6 && again.title == "beach day (iphone)")
    }

    @Test func theServerRefusesWhatTheRealOneRefuses() async throws {
        let rig = StoreRig()
        var bad = PreviewData.editorBeachTimeline()
        bad.canvas = EditCanvas(w: 1000, h: 1000, fps: 30)
        do {
            _ = try await rig.client.saveEditProject(id: PreviewEditorIDs.beach, timeline: bad, baseRevision: 4, title: nil)
            Issue.record("should have thrown")
        } catch {
            #expect(EditError.from(error) == .invalid(.canvas))
        }
        #expect(rig.client.editorState.project(PreviewEditorIDs.beach)?.revision == 4)
    }

    @Test func aNewProjectStartsAtRevisionOne() async throws {
        let rig = StoreRig(.editorEmpty)
        let timeline = EditTimeline.new(
            canvas: EditCanvas(w: 1920, h: 1080, fps: 30), main: [EditClip.added(item: PreviewEditorIDs.pier, duration: 12)])
        let created = try await rig.client.createEditProject(title: "first", timeline: timeline)
        #expect(created.revision == 1 && created.title == "first" && created.timeline == timeline)
        let (full, sources) = try await rig.client.editProject(id: created.id)
        #expect(full.timeline == timeline && Set(sources.keys) == [PreviewEditorIDs.pier])
        #expect(try await rig.client.editProjects().map(\.id) == [created.id])
    }
}

// MARK: - create(from:)

@MainActor
struct EditorCreateTests {
    @Test func theVideosGoOnTheTimelineInTapOrder() async throws {
        let rig = StoreRig()
        defer { rig.finish() }
        let picks = [
            mediaItem("p1", title: "Pier Day.mp4", file: PreviewEditorIDs.pier, seconds: 12),
            mediaItem("p2", file: PreviewEditorIDs.friends, w: 1080, h: 1920, seconds: 4),
        ]
        let left = try await rig.store.create(from: picks)
        #expect(left == EditLeftOut(photosAndGifs: 0, notOnServer: 0))
        let session = try #require(rig.store.session)
        #expect(session.timeline.main.map(\.item) == [PreviewEditorIDs.pier, PreviewEditorIDs.friends])
        #expect(session.timeline.main.map(\.out) == [12, 4])
        #expect(session.timeline.main.allSatisfy { $0.`in` == 0 && $0.speed == 1 && $0.crop == nil && !$0.muted })
        #expect(session.project.title == "Pier Day")
        #expect(session.timeline.canvas == EditCanvas(w: 1920, h: 1080, fps: 30))      // 1280 x 720 is wide
        #expect(rig.store.projects.contains { $0.id == session.project.id })
    }

    @Test func thePhoneVideoMakesAStoryCanvas() async throws {
        let rig = StoreRig()
        defer { rig.finish() }
        _ = try await rig.store.create(from: [mediaItem("p1", file: PreviewEditorIDs.friends, w: 1080, h: 1920, seconds: 4)])
        #expect(rig.store.session?.timeline.canvas == EditCanvas(w: 1080, h: 1920, fps: 30))
    }

    @Test func photosAndPostsWithNoServerCopyAreCountedNotUsed() async throws {
        let rig = StoreRig()
        defer { rig.finish() }
        let picks = [
            mediaItem("p1", file: PreviewEditorIDs.pier, seconds: 12),
            mediaItem("p2", file: PreviewEditorIDs.photo, contentType: "image/jpeg"),
            mediaItem("p3", file: nil),
            mediaItem("p4", file: PreviewEditorIDs.surf, seconds: 10),
        ]
        let left = try await rig.store.create(from: picks)
        #expect(left == EditLeftOut(photosAndGifs: 1, notOnServer: 1))
        #expect(rig.store.session?.timeline.main.map(\.item) == [PreviewEditorIDs.pier, PreviewEditorIDs.surf])
    }

    @Test func aGalleryContributesItsVideosInItemOrder() async throws {
        let rig = StoreRig()
        defer { rig.finish() }
        let g = gallery("g1", items: [
            (PreviewEditorIDs.photo, .photo), (PreviewEditorIDs.friends, .video), (PreviewEditorIDs.dance, .gif),
            (PreviewEditorIDs.sunset, .video), (nil, .video),
        ])
        let left = try await rig.store.create(from: [g, mediaItem("p1", file: PreviewEditorIDs.pier, seconds: 12)])
        #expect(left == EditLeftOut(photosAndGifs: 2, notOnServer: 1))
        #expect(rig.store.session?.timeline.main.map(\.item) == [PreviewEditorIDs.friends, PreviewEditorIDs.sunset, PreviewEditorIDs.pier])
    }

    @Test func nothingToEditIsRefusedBeforeAnythingIsCreated() async throws {
        let rig = StoreRig()
        do {
            _ = try await rig.store.create(from: [mediaItem("p1", file: PreviewEditorIDs.photo, contentType: "image/png"), mediaItem("p2", file: nil)])
            Issue.record("should have thrown")
        } catch {
            #expect(error == .invalid(.empty))
        }
        #expect(rig.client.editorState.calls.filter { $0 == "POST /edits" }.isEmpty)
        #expect(rig.store.session == nil)
    }

    @Test func theTitleIsTheCustomOneElseTheFileNameCutToSixtyCodePoints() {
        #expect(EditorStore.title(for: mediaItem("p1", title: "Pier Day.mp4", custom: "my trip", file: "x")) == "my trip")
        #expect(EditorStore.title(for: mediaItem("p1", title: "Pier Day.mp4", file: "x")) == "Pier Day")
        #expect(EditorStore.title(for: mediaItem("p1", file: "x")) == "untitled edit")
        #expect(EditorStore.title(for: nil) == "untitled edit")
        let long = String(repeating: "\u{1F600}", count: 80)
        let cut = EditorStore.title(for: mediaItem("p1", title: "\(long).mp4", file: "x"))
        #expect(cut.unicodeScalars.count == 60)
        #expect(EditorStore.title(for: mediaItem("p1", title: "mixed.name.mov", file: "x")) == "mixed.name")
    }

    @Test func aServerWithoutTheEditorRefuses() async {
        let rig = StoreRig(.legacyFork)
        do {
            _ = try await rig.store.create(from: [mediaItem("p1", file: PreviewEditorIDs.pier, seconds: 12)])
            Issue.record("should have thrown")
        } catch {
            #expect(error == .off)
        }
    }
}

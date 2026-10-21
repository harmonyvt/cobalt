import Foundation
import Testing
@testable import CobaltKit

// The editor's renders in the queue tab (apple/CONTRACT-EDITOR.md 6): the wire, the merge with this device's copy, the sections,
// the actions and where `open` goes.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func render(
    _ id: String, _ status: EditRender.Status, age: Double = 10, progress: Double? = nil, item: String? = nil,
    ahead: Int? = nil, cancelRequested: Bool = false, error: String? = nil
) -> EditRender {
    let at = now.addingTimeInterval(-age)
    let ended = status == .done || status == .error || status == .cancelled
    return EditRender(
        id: id, projectID: "proj-\(id)", revision: 3, title: "title \(id)", status: status, queueAhead: ahead, progress: progress,
        secondsTotal: 26, error: error, itemID: item, cancelRequested: cancelRequested, createdAt: at,
        startedAt: status == .queued ? nil : at, finishedAt: ended ? at : nil)
}

@MainActor
private func rows(_ edits: [EditRender], dismissed: Set<String> = []) -> [QueueItem] {
    UnifiedQueue.build(
        jobs: [], snapshot: nil, downloads: [], photos: PhotosSync.Status(access: .album, enabled: false), finished: [], now: now,
        edits: edits, dismissedEdits: dismissed)
}

struct EditorQueueWireTests {
    private func decode(_ json: String) throws -> QueueSnapshot {
        try CobaltJSON.decoder().decode(QueueSnapshot.self, from: Data(json.utf8))
    }

    @Test func editsDecodeAndDropWhatIsMalformed() throws {
        let s = try decode("""
        {"edits":[{"id":"a","project_id":"p","status":"rendering","progress":0.4,"seconds_total":26,"created_at":1790000000000},
                  {"id":"b","status":"???","seconds_total":4,"created_at":1790000000000}, 7]}
        """)
        #expect(s.edits?.map(\.id) == ["a"])
        #expect(s.isActive)
    }

    @Test func absentNullOrBrokenEditsAreNil() throws {
        #expect(try decode("{}").edits == nil)
        #expect(try decode(#"{"edits":null}"#).edits == nil)
        #expect(try decode(#"{"edits":"nope"}"#).edits == nil)
    }

    @Test func onlyUnfinishedRendersKeepThePollingFast() throws {
        let done = try decode(#"{"edits":[{"id":"a","status":"done","seconds_total":4,"created_at":1790000000000}]}"#)
        #expect(done.edits?.count == 1 && !done.isActive)
        let queued = try decode(#"{"edits":[{"id":"a","status":"queued","seconds_total":4,"created_at":1790000000000}]}"#)
        #expect(queued.isActive)
    }
}

@MainActor
struct EditorQueueRowsTests {
    @Test func eachStatusLandsInItsSection() {
        let all = rows([
            render("q", .queued, ahead: 2), render("p", .preparing, progress: 0.05), render("r", .rendering, progress: 0.5),
            render("f", .finishing, progress: 0.95), render("d", .done, item: "item1"), render("e", .error, error: "error.edit.timeout"),
            render("c", .cancelled),
        ])
        func section(_ id: String) -> QueueSection? { all.first { $0.id == "edit:\(id)" }?.section }
        #expect(section("q") == .waiting)
        #expect(section("p") == .now && section("r") == .now && section("f") == .now)
        #expect(section("d") == .finished && section("e") == .failed)
        #expect(section("c") == nil)
    }

    @Test func endedRendersLeaveAfterThirtyMinutes() {
        let all = rows([render("d", .done, age: 31 * 60, item: "x"), render("e", .error, age: 31 * 60), render("n", .done, age: 29 * 60, item: "y")])
        #expect(all.map(\.id) == ["edit:n"])
    }

    @Test func queuedRendersWaitInOrderOfTheirPlace() {
        let all = rows([render("b", .queued, ahead: 3), render("a", .queued, ahead: 0)]).filter { $0.section == .waiting }
        #expect(all.map(\.id) == ["edit:a", "edit:b"])
    }

    @Test func actionsFollowTheState() {
        let all = rows([
            render("q", .queued), render("r", .rendering), render("x", .rendering, cancelRequested: true),
            render("d", .done, item: "i"), render("e", .error),
        ])
        func actions(_ id: String) -> [QueueAction]? { all.first { $0.id == "edit:\(id)" }?.actions }
        #expect(actions("q") == [.cancel, .open] && actions("r") == [.cancel, .open])
        #expect(actions("x") == [.open])
        #expect(actions("d") == [.open, .dismiss])
        #expect(actions("e") == [.retry, .open, .dismiss])
    }

    @Test func openGoesToTheVideoWhenDoneAndToTheProjectOtherwise() {
        let all = rows([render("d", .done, item: "item1"), render("r", .rendering), render("e", .error)])
        func destination(_ id: String) -> QueueDestination? { all.first { $0.id == "edit:\(id)" }?.destination }
        #expect(destination("d") == .media("post:item1"))
        #expect(destination("r") == .edit(projectID: "proj-r"))
        #expect(destination("e") == .edit(projectID: "proj-e"))
    }

    @Test func dismissedRendersAreHidden() {
        #expect(rows([render("d", .done, item: "i")], dismissed: ["d"]).isEmpty)
    }

    @Test func theSummaryCountsThem() {
        let s = UnifiedQueue.summary(of: rows([render("q", .queued), render("r", .rendering), render("d", .done, item: "i"), render("e", .error)]))
        #expect(s == QueueSummary(running: 1, waiting: 1, failed: 1, finished: 1))
    }

    @Test func theFresherCopyOfARenderWins() {
        let server = [render("a", .rendering, progress: 0.3), render("b", .done, item: "i")]
        let local = [render("a", .rendering, progress: 0.6), render("b", .rendering, progress: 0.9), render("c", .queued)]
        let merged = UnifiedQueue.mergeEdits(server: server, local: local)
        #expect(Set(merged.map(\.id)) == ["a", "b", "c"])
        #expect(merged.first { $0.id == "a" }?.progress == 0.6)
        #expect(merged.first { $0.id == "b" }?.status == .done)
    }
}

@MainActor
struct EditorQueueModelTests {
    @Test func theQueueShowsAndCancelsARunningRender() async throws {
        let h = Harness(.editorRendering)
        await h.app.editor.refresh()
        let item = try #require(h.app.unifiedQueue.items.first { $0.id == "edit:\(PreviewEditorIDs.liveRender)" })
        #expect(item.section == .waiting)
        #expect(h.app.unifiedQueue.badgeCount == 1)
        await h.app.perform(.cancel, on: item)
        #expect(h.app.editor.render(PreviewEditorIDs.liveRender)?.status == .cancelled)
        #expect(h.app.unifiedQueue.items.first { $0.id == item.id } == nil)
        #expect(h.app.unifiedQueue.badgeCount == 0)
    }

    @Test func dismissingAFinishedRenderHidesIt() async throws {
        let h = Harness(.editorRendering)
        await h.app.editor.refresh()
        h.clock.jump(by: 21)
        let fresh = try await (h.ctx.client as! PreviewClient).editRender(id: PreviewEditorIDs.liveRender)
        h.app.editor.mergeRenders([fresh])
        let item = try #require(h.app.unifiedQueue.items.first { $0.id == "edit:\(fresh.id)" })
        #expect(item.section == .finished)
        await h.app.perform(.dismiss, on: item)
        #expect(h.app.unifiedQueue.items.first { $0.id == item.id } == nil)
    }

    @Test func tryAgainOpensTheProjectWithTheConfirmUp() async throws {
        let h = Harness(.editorRenderFails)
        let client = h.ctx.client as! PreviewClient
        let started = try await client.renderEdit(id: PreviewEditorIDs.beach, revision: 4, notify: false)
        h.clock.jump(by: 13)
        await h.app.editor.refresh()
        let item = try #require(h.app.unifiedQueue.items.first { $0.id == "edit:\(started.id)" })
        #expect(item.section == .failed)
        await h.app.perform(.retry, on: item)
        let session = try #require(h.app.editor.session)
        #expect(session.project.id == PreviewEditorIDs.beach && session.renderConfirmRequested)
        h.app.editor.closeAnyway()
    }
}

import Foundation
import Testing
@testable import CobaltKit

// Live Activities for editor renders (APP-API-CONTRACT.md section 32, apple/CONTRACT-EDITOR.md section 11): the state built
// from a render (the server's `editLiveState`, line for line), the capability, and the manager against a fake ActivityKit.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func render(
    _ status: EditRender.Status, id: String = "Rq7sTu0vWx3yZa6bCd9e", progress: Double? = nil, queueAhead: Int? = nil,
    error: String? = nil, created: Date = t0
) -> EditRender {
    EditRender(
        id: id, projectID: "ProjectAAAAAAAAA", revision: 1, title: "beach day", status: status, queueAhead: queueAhead,
        progress: progress, secondsTotal: 20, error: error, bytes: status == .done ? 9_000_000 : nil,
        width: status == .done ? 1080 : nil, height: status == .done ? 1920 : nil, duration: status == .done ? 20.0333 : nil,
        createdAt: created, startedAt: status == .queued ? nil : created.addingTimeInterval(5),
        finishedAt: [.done, .error, .cancelled].contains(status) ? created.addingTimeInterval(60) : nil)
}

private func capsOf(editor: Bool, push: Bool) -> Capabilities {
    let json = #"{"server":"cobalt-cloudflare","features":{"editor":\#(editor),"edit_live_push":\#(push)},"key":"valid"}"#
    return HTTPCobaltClient.parseForkCapabilities(Data(json.utf8))!
}

struct EditLiveStateTests {
    @Test func eachStatusMapsLikeTheServer() {
        #expect(EditLiveContentState(render(.queued, queueAhead: 2)) == {
            var s = EditLiveContentState(status: .queued, since: 1_800_000_000, title: "beach day"); s.queueAhead = 2; return s
        }())
        let rendering = EditLiveContentState(render(.rendering, progress: 0.52512))
        #expect(rendering.status == .rendering && rendering.progress == 0.525 && rendering.since == 1_800_000_005)
        let done = EditLiveContentState(render(.done, progress: 1))
        #expect(done.status == .done && done.resultSeconds == 20.033 && done.resultWidth == 1080 && done.resultBytes == 9_000_000)
        #expect(done.since == 1_800_000_060)
        let failed = EditLiveContentState(render(.error, error: "error.edit.timeout"))
        #expect(failed.status == .failed && failed.code == "error.edit.timeout")
        #expect(EditLiveContentState(render(.error, error: "error.edit.cancelled")).status == .cancelled)
        #expect(EditLiveContentState(render(.cancelled)).isTerminal)
    }

    /// The object the server pushes decodes into the same state (the keys are the Swift names, absent optionals omitted).
    @Test func thePushedContentStateDecodes() throws {
        let pushed = #"{"status":"done","since":1800000060,"title":"beach day","progress":1,"resultSeconds":20.033,"resultWidth":1080,"resultHeight":1920,"resultBytes":9000000}"#
        let s = try JSONDecoder().decode(EditLiveContentState.self, from: Data(pushed.utf8))
        #expect(s == EditLiveContentState(render(.done, progress: 1)))
        let encoded = String(decoding: try JSONEncoder().encode(EditLiveContentState(render(.queued, queueAhead: 0))), as: UTF8.self)
        #expect(!encoded.contains("null"))
    }

    @Test func theCapabilityIsReadFromFeatures() throws {
        func caps(_ features: String) throws -> Capabilities {
            try #require(HTTPCobaltClient.parseForkCapabilities(Data(#"{"server":"cobalt-cloudflare","features":\#(features),"key":"valid"}"#.utf8)))
        }
        #expect(try caps(#"{"editor":true,"edit_live_push":true}"#).editLivePush)
        #expect(try !caps(#"{"editor":true}"#).editLivePush)
    }
}

// MARK: - the manager

@MainActor
private final class FakeEditHandle: EditLiveHandle {
    let render: String
    var state: EditLiveContentState
    var isEnded = false
    var updates: [EditLiveContentState] = []
    var ended: (state: EditLiveContentState, dismissAt: Date?)?
    let tokenStream: AsyncStream<String>
    let tokenSink: AsyncStream<String>.Continuation

    init(render: String, state: EditLiveContentState) {
        self.render = render
        self.state = state
        (tokenStream, tokenSink) = AsyncStream.makeStream(of: String.self)
    }

    func pushTokens() -> AsyncStream<String> { tokenStream }
    func update(_ state: EditLiveContentState, staleDate: Date?) async {
        self.state = state
        updates.append(state)
    }
    func end(_ state: EditLiveContentState, dismissAt: Date?) async {
        self.state = state
        isEnded = true
        ended = (state, dismissAt)
    }
}

@MainActor
private final class FakeEditAdapter: EditLiveAdapter {
    var isAvailable = true
    var refuse = false
    var made: [FakeEditHandle] = []
    var pushRequested: [Bool] = []
    var activities: [any EditLiveHandle] { made }
    func request(_ attributes: EditLiveAttributes, state: EditLiveContentState, staleDate: Date, push: Bool) throws -> any EditLiveHandle {
        if refuse { throw CancellationError() }
        let h = FakeEditHandle(render: attributes.render, state: state)
        made.append(h)
        pushRequested.append(push)
        return h
    }
}

private final class FakeEditorClient: EditorClient, @unchecked Sendable {
    var tokens: [(String, String, LiveEnvironment)] = []
    var served: [String: EditRender] = [:]
    func editProjects() async throws -> [EditProject] { [] }
    func createEditProject(title: String?, timeline: EditTimeline) async throws -> EditProject { throw EditError.off }
    func editProject(id: String) async throws -> (EditProject, [String: EditSource]) { throw EditError.off }
    func saveEditProject(id: String, timeline: EditTimeline, baseRevision: Int, title: String?) async throws -> EditProject { throw EditError.off }
    func renameEditProject(id: String, title: String) async throws -> EditProject { throw EditError.off }
    func deleteEditProject(id: String) async throws {}
    func renderEdit(id: String, revision: Int, notify: Bool) async throws -> EditRender { throw EditError.off }
    func editRenders(limit: Int) async throws -> [EditRender] { [] }
    func editRender(id: String) async throws -> EditRender {
        guard let r = served[id] else { throw EditError.off }
        return r
    }
    func cancelEditRender(id: String) async throws -> EditRender { throw EditError.off }
    func putEditLiveToken(renderID: String, token: String, environment: LiveEnvironment) async throws -> Bool {
        tokens.append((renderID, token, environment))
        return true
    }
}

@MainActor
struct EditLiveManagerTests {
    private func world(push: Bool = true, editor: Bool = true, environment: LiveEnvironment? = .production)
        -> (EditLiveManager, FakeEditAdapter, FakeEditorClient)
    {
        let adapter = FakeEditAdapter()
        let client = FakeEditorClient()
        let caps = capsOf(editor: editor, push: push)
        let manager = EditLiveManager(
            adapter: adapter, environment: environment, capabilities: { caps }, client: { client },
            now: { t0.addingTimeInterval(30) })
        return (manager, adapter, client)
    }

    @Test func aRunningRenderGetsOneActivityThatFollowsItAndEndsWithIt() async throws {
        let (m, adapter, _) = world()
        await m.observe([render(.queued, queueAhead: 1)])
        await m.observe([render(.queued, queueAhead: 1)])
        #expect(adapter.made.count == 1)
        let h = try #require(adapter.made.first)
        await m.observe([render(.rendering, progress: 0.4)])
        // an older copy (the queue's snapshot from before) never moves it back
        await m.observe([render(.preparing, progress: 0.05)])
        #expect(h.updates.map(\.status) == [.rendering])
        await m.observe([render(.done, progress: 1)])
        #expect(h.ended?.state.status == .done)
        #expect(h.ended?.dismissAt == t0.addingTimeInterval(30 + 900))
        // once ended it is never started again, whatever copy comes later
        await m.observe([render(.rendering, progress: 0.9)])
        #expect(adapter.made.count == 1)
    }

    @Test func aFailureDismissesSoonerAndACancelAtOnce() async throws {
        let (m, adapter, _) = world()
        await m.observe([render(.rendering, id: "AAAAAAAAAAAAAAAAAAAA", progress: 0.2), render(.rendering, id: "BBBBBBBBBBBBBBBBBBBB", progress: 0.2)])
        await m.observe([render(.error, id: "AAAAAAAAAAAAAAAAAAAA", error: "error.edit.timeout"), render(.cancelled, id: "BBBBBBBBBBBBBBBBBBBB")])
        #expect(adapter.made[0].ended?.dismissAt == t0.addingTimeInterval(30 + 300))
        #expect(adapter.made[1].ended != nil && adapter.made[1].ended?.dismissAt == nil)
    }

    @Test func endedOldOrUnavailableRendersGetNoActivity() async {
        let (m, adapter, _) = world()
        await m.observe([render(.done, progress: 1), render(.rendering, id: "OldOldOldOldOldOldOl", created: t0.addingTimeInterval(-7 * 3600))])
        #expect(adapter.made.isEmpty)
        adapter.isAvailable = false
        await m.observe([render(.rendering, progress: 0.3)])
        #expect(adapter.made.isEmpty)
        // a refused request (the app is in the background) is tried again with the next copy
        adapter.isAvailable = true
        adapter.refuse = true
        await m.observe([render(.rendering, progress: 0.3)])
        adapter.refuse = false
        await m.observe([render(.rendering, progress: 0.35)])
        #expect(adapter.made.count == 1)
    }

    @Test func theTokenGoesToTheServerOnlyWithThePushCapabilityAndASignedBuild() async throws {
        let (m, adapter, client) = world()
        await m.observe([render(.rendering, progress: 0.1)])
        #expect(adapter.pushRequested == [true])
        adapter.made[0].tokenSink.yield("ab12")
        for _ in 0..<50 where client.tokens.isEmpty { await Task.yield() }
        #expect(client.tokens.map(\.1) == ["ab12"])
        #expect(client.tokens.first?.2 == .production)

        let (m2, adapter2, client2) = world(push: false)
        await m2.observe([render(.rendering, progress: 0.1)])
        #expect(adapter2.pushRequested == [false])
        adapter2.made[0].tokenSink.yield("cd34")
        for _ in 0..<20 { await Task.yield() }
        #expect(client2.tokens.isEmpty)

        let (m3, adapter3, _) = world(environment: nil)
        await m3.observe([render(.rendering, progress: 0.1)])
        #expect(adapter3.pushRequested == [false])
    }

    @Test func inFrontAgainAnActivityWhoseRenderEndedUnseenIsEnded() async throws {
        let (m, adapter, client) = world()
        await m.observe([render(.rendering, progress: 0.5)])
        // a relaunch: a new manager over the same system activities
        let caps = capsOf(editor: true, push: true)
        let fresh = EditLiveManager(adapter: adapter, environment: .production, capabilities: { caps }, client: { client }, now: { t0.addingTimeInterval(120) })
        client.served["Rq7sTu0vWx3yZa6bCd9e"] = render(.done, progress: 1)
        await fresh.foreground()
        #expect(adapter.made[0].ended?.state.status == .done)
        _ = m
    }

    @Test func noEditorNoActivities() async {
        let (m, adapter, _) = world(editor: false)
        await m.observe([render(.rendering, progress: 0.2)])
        #expect(adapter.made.isEmpty)
    }
}

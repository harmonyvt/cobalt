import Foundation
import Testing
@testable import CobaltKit

// Chat videos (APP-API-CONTRACT 45): the render's new `kind` and `thread_id` (and old servers without them), the capability,
// `POST /chat/threads/<id>/video` (its body and refusals), the queue rows of a chat render, and the preview server.

private let videoKey = "5d0c2b1e-8f3a-4a6b-9c27-1e4f6a8b2d90"
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let wireChatRender = """
{"id":"Rq7sTu0vWx3yZa6bCd9e","kind":"chat","thread_id":"Ab12Cd34Ef56Gh78","project_id":"chat:Ab12Cd34Ef56Gh78","revision":0,\
"title":"cat clips from october","status":"queued","queue_ahead":0,"progress":null,"seconds_done":null,"seconds_total":42,\
"error":null,"item_id":null,"poster_url":null,"bytes":null,"width":null,"height":null,"duration":null,"cancel_requested":false,\
"created_at":1790000000000,"started_at":null,"finished_at":null}
"""

private let wireEditRender = """
{"id":"Rq7sTu0vWx3yZa6bCd9f","project_id":"ProjectAAAAAAAAA","revision":3,"title":"beach day","status":"rendering",\
"progress":0.5,"seconds_total":26,"created_at":1790000000000}
"""

private func decodeRender(_ json: String) throws -> EditRender {
    try CobaltJSON.decoder().decode(EditRender.self, from: Data(json.utf8))
}

struct ChatVideoWireTests {
    @Test func aChatRenderDecodesItsKindAndThread() throws {
        let r = try decodeRender(wireChatRender)
        #expect(r.kind == .chat && r.isChat)
        #expect(r.threadID == "Ab12Cd34Ef56Gh78")
        #expect(r.projectID == "chat:Ab12Cd34Ef56Gh78" && r.revision == 0)
        #expect(r.title == "cat clips from october" && r.status == .queued && r.queueAhead == 0 && r.secondsTotal == 42)
    }

    @Test func anEditorRenderWithoutTheNewKeysIsAnEdit() throws {
        let r = try decodeRender(wireEditRender)
        #expect(r.kind == .edit && !r.isChat)
        #expect(r.threadID == nil)
        #expect(r.projectID == "ProjectAAAAAAAAA" && r.progress == 0.5)
        let explicit = try decodeRender(wireEditRender.replacingOccurrences(of: #""revision":3"#, with: #""revision":3,"kind":"edit","thread_id":null"#))
        #expect(explicit.kind == .edit && explicit.threadID == nil)
    }

    @Test func aChatProjectIDWithoutKindIsStillAChat() throws {
        let r = try decodeRender(wireChatRender.replacingOccurrences(of: #""kind":"chat","#, with: ""))
        #expect(r.kind == .chat && r.isChat)
    }

    @Test func anUnknownOrBrokenKindIsAnEdit() throws {
        let odd = try decodeRender(wireEditRender.replacingOccurrences(of: #""revision":3"#, with: #""revision":3,"kind":"slideshow""#))
        #expect(odd.kind == .edit)
        let broken = try decodeRender(wireEditRender.replacingOccurrences(of: #""revision":3"#, with: #""revision":3,"kind":7,"thread_id":9"#))
        #expect(broken.kind == .edit && broken.threadID == nil)
    }

    @Test func aChatRenderRidesInTheQueueSnapshot() throws {
        let s = try CobaltJSON.decoder().decode(QueueSnapshot.self, from: Data(#"{"edits":[\#(wireChatRender),\#(wireEditRender)]}"#.utf8))
        #expect(s.edits?.map(\.kind) == [.chat, .edit])
        #expect(s.isActive)
    }
}

struct ChatVideoCapabilityTests {
    private func caps(_ rest: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare"\#(rest),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func chatVideoIsReadAndOffWhenAbsent() throws {
        #expect(try caps(#","features":{"chat":true,"editor":true,"chat_video":true}"#).chatVideo)
        #expect(try !caps(#","features":{"chat":true,"editor":true}"#).chatVideo)
        #expect(try !caps("").chatVideo)
    }

    @Test func chatVideoNeedsChat() throws {
        #expect(try !caps(#","features":{"editor":true,"chat_video":true}"#).chatVideo)
    }
}

struct ChatVideoHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { videoKey })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    private func accepting() async throws -> LoopbackServer {
        try await LoopbackServer.start { req in
            req.method == "POST" && req.path == "/chat/threads/Ab12Cd34Ef56Gh78/video"
                ? .json(#"{"status":"success","render":\#(wireChatRender)}"#, status: 202) : .init(status: 404)
        }
    }

    @Test func everyOptionIsSentByItsWireName() async throws {
        let server = try await accepting()
        defer { server.stop() }
        let r = try await client(server).makeChatVideo(
            threadID: "Ab12Cd34Ef56Gh78", shape: .landscape, theme: .light, speed: 1.5, from: "101", to: "102", notify: true)
        let req = try #require(server.requests.first)
        let json = try bodyJSON(req)
        #expect(req.headers["authorization"] == "Api-Key \(videoKey)" && req.headers["content-type"] == "application/json")
        #expect(json["shape"] as? String == "landscape" && json["theme"] as? String == "light")
        #expect(json["speed"] as? Double == 1.5)
        #expect(json["from"] as? String == "101" && json["to"] as? String == "102")
        #expect(json["notify"] as? Bool == true)
        #expect(json.count == 6)
        #expect(r.kind == .chat && r.threadID == "Ab12Cd34Ef56Gh78" && r.status == .queued)
    }

    @Test func nilOptionsAndAFalseNotifyAreLeftOut() async throws {
        let server = try await accepting()
        defer { server.stop() }
        _ = try await client(server).makeChatVideo(
            threadID: "Ab12Cd34Ef56Gh78", shape: nil, theme: nil, speed: nil, from: nil, to: nil, notify: false)
        let json = try bodyJSON(try #require(server.requests.first))
        #expect(json.isEmpty, "the server's defaults: \(json)")
    }

    @Test func theSpeedIsHeldToTheServersRange() {
        #expect(HTTPCobaltClient.chatVideoBody(shape: nil, theme: nil, speed: 9, from: nil, to: nil, notify: false)["speed"] as? Double == 2)
        #expect(HTTPCobaltClient.chatVideoBody(shape: nil, theme: nil, speed: 0.1, from: nil, to: nil, notify: false)["speed"] as? Double == 0.5)
        #expect(HTTPCobaltClient.chatVideoBody(shape: nil, theme: nil, speed: .nan, from: nil, to: nil, notify: false)["speed"] == nil)
        let full = HTTPCobaltClient.chatVideoBody(shape: .square, theme: .dark, speed: 0.75, from: "7", to: nil, notify: false)
        #expect(full["shape"] as? String == "square" && full["theme"] as? String == "dark" && full["speed"] as? Double == 0.75)
        #expect(full["from"] as? String == "7" && full["to"] == nil && full["notify"] == nil)
    }

    @Test func refusalsAreMapped() async throws {
        func refused(_ code: String, _ status: Int) async throws -> Error? {
            let server = try await LoopbackServer.start { _ in .json(#"{"status":"error","error":{"code":"\#(code)"}}"#, status: status) }
            defer { server.stop() }
            do {
                _ = try await client(server).makeChatVideo(threadID: "x", shape: nil, theme: nil, speed: nil, from: nil, to: nil, notify: false)
                return nil
            } catch {
                return error
            }
        }
        let chatCases: [(String, Int, ChatError)] = [
            ("error.chat.busy", 409, .busy), ("error.chat.video.empty", 409, .videoEmpty), ("error.chat.not_found", 404, .notFound),
            ("error.chat.off", 404, .off), ("error.chat.bad_request", 400, .badRequest), ("error.api.generic", 503, .unavailable),
        ]
        for (code, status, expected) in chatCases {
            let error = try await refused(code, status)
            #expect(error as? ChatError == expected, "\(code)")
        }
        let editCases: [(String, Int, EditError)] = [("error.edit.queue_full", 429, .queueFull), ("error.edit.off", 404, .off)]
        for (code, status, expected) in editCases {
            let error = try await refused(code, status)
            #expect(error as? EditError == expected, "\(code)")
        }
    }

    @Test func theVideoEmptyCodeRoundTrips() {
        #expect(ChatError(code: "error.chat.video.empty") == .videoEmpty)
        #expect(ChatError.videoEmpty.code == "error.chat.video.empty")
    }
}

@MainActor
struct ChatVideoQueueTests {
    private func chatRender(_ id: String, _ status: EditRender.Status, item: String? = nil, cancelRequested: Bool = false) -> EditRender {
        let at = now.addingTimeInterval(-10)
        let ended = status == .done || status == .error || status == .cancelled
        return EditRender(
            id: id, projectID: "chat:T\(id)", revision: 0, title: "chat \(id)", status: status, secondsTotal: 40, itemID: item,
            cancelRequested: cancelRequested, createdAt: at, startedAt: status == .queued ? nil : at, finishedAt: ended ? at : nil,
            kind: .chat, threadID: "T\(id)")
    }

    private func rows(_ edits: [EditRender]) -> [QueueItem] {
        UnifiedQueue.build(
            jobs: [], snapshot: nil, downloads: [], photos: PhotosSync.Status(access: .album, enabled: false), finished: [], now: now,
            edits: edits, dismissedEdits: [])
    }

    @Test func aChatVideoNeverOpensAProject() {
        let all = rows([
            chatRender("q", .queued), chatRender("r", .rendering), chatRender("x", .rendering, cancelRequested: true),
            chatRender("d", .done, item: "item1"), chatRender("e", .error),
        ])
        func item(_ id: String) -> QueueItem? { all.first { $0.id == "edit:\(id)" } }
        #expect(item("q")?.section == .waiting && item("r")?.section == .now)
        #expect(item("q")?.actions == [.cancel] && item("r")?.actions == [.cancel] && item("x")?.actions == [])
        #expect(item("e")?.section == .failed && item("e")?.actions == [.dismiss])
        #expect(item("d")?.actions == [.open, .dismiss])
        #expect(item("q")?.destination == nil && item("r")?.destination == nil && item("e")?.destination == nil)
        #expect(item("d")?.destination == .media("post:item1"), "a finished one opens its library post")
    }
}

@MainActor
struct ChatVideoPreviewTests {
    private final class Flag { var done = false; var render: EditRender?; var error: Error? }

    @Test func thePreviewQueuesAChatRenderAndTheEditorKnowsIt() async throws {
        let h = Harness(.happy)
        #expect(h.app.canMakeChatVideos)
        let thread = PreviewData.chatThreadIDs[1]
        let flag = Flag()
        let task = Task { @MainActor in
            do {
                flag.render = try await h.app.makeChatVideo(threadID: thread, options: ChatVideoOptions(shape: .square, from: "112"))
            } catch {
                flag.error = error
            }
            flag.done = true
        }
        await h.drive(until: { flag.done })
        await task.value
        #expect(flag.error == nil)
        let r = try #require(flag.render)
        #expect(r.kind == .chat && r.threadID == thread && r.projectID == "chat:\(thread)" && r.title == "roast my taste")
        #expect(r.isActive)
        #expect(h.app.editor.render(r.id) != nil, "in the editor's renders at once, so the queue shows it before the next poll")
    }

    @Test func thePreviewRefusesAMessageThatIsNotInTheThread() async throws {
        let h = Harness(.happy)
        let flag = Flag()
        let task = Task { @MainActor in
            do {
                _ = try await h.app.makeChatVideo(threadID: PreviewData.chatThreadIDs[1], options: ChatVideoOptions(from: "nope"))
            } catch {
                flag.error = error
            }
            flag.done = true
        }
        await h.drive(until: { flag.done })
        await task.value
        #expect(flag.error as? ChatError == .badRequest)
    }
}

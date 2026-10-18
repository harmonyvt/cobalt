import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// Chat (APP-API-CONTRACT 27): the capability, the wire shapes, the reply stream's parser, the routes and their refusals,
// the preview server, and the store: events applied in order, and a reply whose stream dropped followed by reading the
// thread every 2 s.

private let chatKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

private let wireThread = """
{"id":"Ab12Cd34Ef56Gh78","title":"cat clips from october","created_at":1790000000000,"updated_at":1790000500000,"preview":"the harbour one at 37 s","message_count":4}
"""

private let wireStep = """
{"id":"toolu_01","kind":"code","status":"done","code":"return 1","logs":["a","b"],"result":"1","error":null,"duration_ms":820}
"""

private let wireUser = """
{"id":"101","role":"user","text":"what did i save?","post_ids":["Dd7P496wolG"],"steps":[],"status":"done","error":null,"created_at":1790000001000}
"""

private let wireAssistant = """
{"id":"102","role":"assistant","text":"","post_ids":[],"steps":[],"status":"running","error":null,"created_at":1790000002000}
"""

private let wirePost = """
{"id":"Dd7P496wolG","service":"instagram","title":"the dog","duration":14.7,"created_at":1790000000000,"files":[],"kind":"video"}
"""

// MARK: - capability

struct ChatCapabilityTests {
    private func caps(features: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":\#(features),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func theFlagIsOnWhenTheServerSaysSo() throws {
        #expect(try caps(features: #"{"library":true,"chat":true}"#).chat)
    }

    @Test func theFlagIsOffWhenAbsentOrFalse() throws {
        #expect(try !caps(features: #"{"library":true}"#).chat)
        #expect(try !caps(features: #"{"chat":false}"#).chat)
        #expect(!Capabilities.unknown.chat)
    }

    @Test func thePreviewServersWithChat() {
        for scenario in [PreviewScenario.happy, .renditions, .chatEmpty, .chatFail, .chatReplyFails] {
            #expect(PreviewData.capabilities(for: scenario).chat, "\(scenario)")
        }
        #expect(!PreviewData.capabilities(for: .plainCobalt).chat)
        #expect(!PreviewData.capabilities(for: .shareLinksEmpty).chat)
    }

    @Test func theTabShowsOnlyWithTheFlag() {
        var c = Capabilities.unknown
        #expect(!AppTab.chat.isAvailable(with: c))
        c.chat = true
        #expect(AppTab.chat.isAvailable(with: c))
        #expect(AppTab.allCases == [.save, .library, .links, .chat, .queue, .settings])
    }
}

// MARK: - models

struct ChatModelTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try CobaltJSON.decoder().decode(type, from: Data(json.utf8))
    }

    @Test func aThreadDecodes() throws {
        let t = try decode(ChatThread.self, wireThread)
        #expect(t.id == "Ab12Cd34Ef56Gh78" && t.title == "cat clips from october")
        #expect(t.createdAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(t.updatedAt == Date(timeIntervalSince1970: 1_790_000_500))
        #expect(t.preview == "the harbour one at 37 s" && t.messageCount == 4)
    }

    @Test func aStepDecodes() throws {
        let s = try decode(ChatStep.self, wireStep)
        #expect(s.id == "toolu_01" && s.kind == "code" && s.status == .done && s.code == "return 1")
        #expect(s.logs == ["a", "b"] && s.result == "1" && s.error == nil && s.durationMS == 820)
        let running = try decode(ChatStep.self, #"{"id":"x","kind":"code","status":"running","code":"await 1","logs":[],"result":null,"error":null,"duration_ms":null}"#)
        #expect(running.status == .running && running.durationMS == nil && running.result == nil)
    }

    @Test func aMessageDecodes() throws {
        let m = try decode(ChatMessage.self, wireUser)
        #expect(m.id == "101" && m.role == .user && m.text == "what did i save?" && m.postIDs == ["Dd7P496wolG"])
        #expect(m.status == .done && m.error == nil && m.steps.isEmpty && !m.isLocal)
        let running = try decode(ChatMessage.self, wireAssistant)
        #expect(running.role == .assistant && running.status == .running)
        let failed = try decode(ChatMessage.self, #"{"id":"103","role":"assistant","text":"half","post_ids":[],"steps":[\#(wireStep)],"status":"error","error":"error.chat.model","created_at":1}"#)
        #expect(failed.status == .error && failed.error == "error.chat.model" && failed.steps.count == 1)
    }

    @Test func aMessageIsLenient() throws {
        // a bare number id, an unknown status, a step that does not decode
        let m = try decode(ChatMessage.self, #"{"id":7,"role":"assistant","text":"x","status":"weird","steps":[{"nope":1},\#(wireStep)],"created_at":1}"#)
        #expect(m.id == "7" && m.status == .done && m.steps.map(\.id) == ["toolu_01"] && m.postIDs.isEmpty)
        #expect(throws: (any Error).self) { try decode(ChatMessage.self, #"{"id":"1","role":"system","text":"x","created_at":1}"#) }
    }

    @Test func aThreadReadDecodesMessagesAndThePostsMap() throws {
        let json = """
        {"status":"success","thread":\(wireThread),"messages":[\(wireUser),\(wireAssistant),{"id":"x","role":"bad"}],
         "posts":{"Dd7P496wolG":\(wirePost),"Broken":{"nope":true}}}
        """
        let d = try decode(ChatThreadDetail.self, json)
        #expect(d.thread.id == "Ab12Cd34Ef56Gh78")
        #expect(d.messages.map(\.id) == ["101", "102"], "oldest first as sent; the bad one is dropped")
        #expect(d.posts.keys.sorted() == ["Dd7P496wolG"])
        #expect(d.posts["Dd7P496wolG"]?.title == "the dog" && d.posts["Dd7P496wolG"]?.kind == .video)
    }

    @Test func aThreadReadWithoutPostsIsFine() throws {
        let d = try decode(ChatThreadDetail.self, #"{"thread":\#(wireThread),"messages":[]}"#)
        #expect(d.messages.isEmpty && d.posts.isEmpty)
    }

    @Test func errorsNameTheirCodes() {
        let all: [ChatError] = [.badRequest, .notFound, .off, .busy, .full, .tooMany, .model, .interrupted]
        for e in all { #expect(ChatError(code: e.code) == e) }
        #expect(ChatError(code: "error.api.generic") == nil)
        #expect(ChatError.unavailable.code == "error.api.generic")
    }

    @Test func theTextRules() {
        #expect(ChatRule.cleanMessage("  hi \n") == "hi")
        #expect(ChatRule.cleanMessage("  \n ") == nil)
        #expect(ChatRule.cleanMessage(String(repeating: "a", count: 4000)) != nil)
        #expect(ChatRule.cleanMessage(String(repeating: "a", count: 4001)) == nil)
        #expect(ChatRule.cleanTitle("  roast my taste ") == "roast my taste")
        #expect(ChatRule.cleanTitle(String(repeating: "t", count: 61)) == nil)
        #expect(ChatRule.cleanTitle("   ") == nil)
    }
}

// MARK: - the stream's parser

struct ChatSSEParserTests {
    private func sse(_ events: [(String, String)]) -> String {
        events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
    }

    private func parse(_ text: String) -> [ChatEvent] {
        var parser = ChatSSEParser()
        return parser.feed(Array(text.utf8)) + parser.finish()
    }

    @Test func everyEventOfAReply() {
        let text = sse([
            ("user", #"{"message":\#(wireUser)}"#),
            ("assistant", #"{"message":\#(wireAssistant)}"#),
            ("step", #"{"step":\#(wireStep)}"#),
            ("text", #"{"delta":"hello "}"#),
            ("text", #"{"delta":"world"}"#),
            ("posts", #"{"post_ids":["Dd7P496wolG"],"posts":{"Dd7P496wolG":\#(wirePost)}}"#),
            ("title", #"{"thread":\#(wireThread)}"#),
            ("done", #"{"message":\#(wireAssistant),"thread":\#(wireThread)}"#),
        ])
        let events = parse(text)
        #expect(events.count == 8, "\(events)")
        guard events.count == 8 else { return }
        guard case .user(let user) = events[0], case .assistant(let assistant) = events[1], case .step(let step) = events[2],
              case .text(let a) = events[3], case .text(let b) = events[4], case .posts(let ids, let posts) = events[5],
              case .title(let thread) = events[6], case .done(let message, let current) = events[7]
        else { Issue.record("wrong events: \(events)"); return }
        #expect(user.id == "101" && assistant.status == .running && step.id == "toolu_01")
        #expect(a + b == "hello world")
        #expect(ids == ["Dd7P496wolG"] && posts.map(\.id) == ["Dd7P496wolG"])
        #expect(thread.id == "Ab12Cd34Ef56Gh78" && message.id == "102" && current.title == "cat clips from october")
        #expect(events[7].isFinal && !events[0].isFinal)
    }

    @Test func anErrorEventWithAndWithoutItsMessage() {
        let with = parse(sse([("error", #"{"code":"error.chat.model","message":\#(wireAssistant)}"#)]))
        let without = parse(sse([("error", #"{"code":"error.chat.interrupted","message":null}"#)]))
        guard case .error(let code, let message) = with.first else { Issue.record("\(with)"); return }
        #expect(code == "error.chat.model" && message?.id == "102")
        #expect(without == [.error(code: "error.chat.interrupted", message: nil)])
    }

    @Test func pingsAndCommentsAreIgnored() {
        let text = ": ping\n\n: another\nevent: text\n: in the middle\ndata: {\"delta\":\"x\"}\n\n: ping\n\n"
        #expect(parse(text) == [.text("x")])
    }

    @Test func crlfAndLoneCRAreLineEnds() {
        let crlf = "event: text\r\ndata: {\"delta\":\"a\"}\r\n\r\nevent: text\r\ndata: {\"delta\":\"b\"}\r\n\r\n"
        #expect(parse(crlf) == [.text("a"), .text("b")])
        let cr = "event: text\rdata: {\"delta\":\"c\"}\r\r"
        #expect(parse(cr) == [.text("c")])
    }

    @Test func multiLineDataIsJoinedWithANewline() {
        // the JSON is split over three data lines (whitespace between tokens is fine JSON)
        let text = "event: text\ndata: {\ndata: \"delta\": \"multi\"\ndata: }\n\n"
        #expect(parse(text) == [.text("multi")])
        // and a newline inside a string stays one (it is escaped on the wire)
        #expect(parse("event: text\ndata: {\"delta\":\"a\\nb\"}\n\n") == [.text("a\nb")])
    }

    @Test func aSingleLeadingSpaceIsStrippedNoMore() {
        #expect(parse("event:text\ndata:{\"delta\":\" x\"}\n\n") == [.text(" x")])
        #expect(parse("event:  text\ndata: {\"delta\":\"y\"}\n\n") == [], "two spaces make the name ' text'")
    }

    @Test func unknownEventsAndBadDataAreDropped() {
        let text = sse([("mystery", "{}"), ("text", "not json"), ("text", #"{"delta":"ok"}"#), ("user", #"{"message":{"nope":1}}"#)])
        #expect(parse(text) == [.text("ok")])
        #expect(parse("event: text\n\n") == [], "no data, no event")
        #expect(parse("data: {\"delta\":\"x\"}\n\n") == [], "no event name")
    }

    @Test func aMissingClosingBlankLineIsCompletedByFinish() {
        var parser = ChatSSEParser()
        #expect(parser.feed(Array("event: text\ndata: {\"delta\":\"tail\"}".utf8)).isEmpty)
        #expect(parser.finish() == [.text("tail")])
        #expect(parser.finish().isEmpty, "nothing left to flush")
    }

    @Test func bytesMayArriveInAnyPieces() {
        let text = sse([("text", #"{"delta":"héllo 🙂"}"#), ("text", #"{"delta":"two"}"#)])
        let bytes = Array(text.utf8)
        // one byte at a time, which also splits the multi-byte characters
        var parser = ChatSSEParser()
        var events: [ChatEvent] = []
        for byte in bytes { events += parser.feed([byte]) }
        events += parser.finish()
        #expect(events == [.text("héllo 🙂"), .text("two")])
        // a CRLF split between two feeds
        var split = ChatSSEParser()
        var out = split.feed(Array("event: text\r\ndata: {\"delta\":\"s\"}\r".utf8))
        out += split.feed(Array("\n\r".utf8))
        out += split.feed(Array("\n".utf8))
        #expect(out == [.text("s")])
    }

    @Test func linesCanBeFedWhole() {
        var parser = ChatSSEParser()
        var out: [ChatEvent] = []
        for line in ["event: text", "data: {\"delta\":\"l\"}", ""] { out += parser.feed(line: line) }
        #expect(out == [.text("l")])
    }

    @Test func postsAreOrderedLikeTheirIDs() {
        let other = wirePost.replacingOccurrences(of: "Dd7P496wolG", with: "Zz9")
        let events = parse(sse([("posts", #"{"post_ids":["Zz9","Dd7P496wolG","Gone1"],"posts":{"Dd7P496wolG":\#(wirePost),"Zz9":\#(other)}}"#)]))
        guard case .posts(let ids, let posts) = events.first else { Issue.record("\(events)"); return }
        #expect(ids == ["Zz9", "Dd7P496wolG", "Gone1"] && posts.map(\.id) == ["Zz9", "Dd7P496wolG"])
    }
}

// MARK: - the routes

struct ChatHTTPTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { chatKey })
    }

    private func bodyJSON(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var out: [ChatEvent] = []
        for try await event in stream { out.append(event) }
        return out
    }

    @Test func listIsGetKeyedAndKeepsTheServersOrder() async throws {
        let other = wireThread.replacingOccurrences(of: "Ab12Cd34Ef56Gh78", with: "Zz12Cd34Ef56Gh78")
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/chat/threads"
                ? .json(#"{"status":"success","threads":[\#(wireThread),\#(other),{"nope":1}]}"#) : .init(status: 404)
        }
        defer { server.stop() }
        let list = try await client(server).chatThreads()
        let req = try #require(server.requests.first)
        #expect(req.headers["authorization"] == "Api-Key \(chatKey)" && req.body.isEmpty)
        #expect(list.map(\.id) == ["Ab12Cd34Ef56Gh78", "Zz12Cd34Ef56Gh78"])
    }

    @Test func createSendsTheTitleOrNothing() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "POST" && req.path == "/chat/threads"
                ? .json(#"{"status":"success","thread":\#(wireThread)}"#, status: 201) : .init(status: 404)
        }
        defer { server.stop() }
        let c = client(server)
        let made = try await c.createChatThread(title: "roast my taste")
        _ = try await c.createChatThread(title: nil)
        let bodies = try server.requests.map(bodyJSON)
        #expect(bodies[0]["title"] as? String == "roast my taste" && bodies[0].count == 1)
        #expect(bodies[1].isEmpty, "no title, no field")
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == "Api-Key \(chatKey)" && $0.headers["content-type"] == "application/json" })
        #expect(made.id == "Ab12Cd34Ef56Gh78")
    }

    @Test func readIsGetKeyedWithThePostsMap() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "GET" && req.path == "/chat/threads/Ab12Cd34Ef56Gh78"
                ? .json(#"{"status":"success","thread":\#(wireThread),"messages":[\#(wireUser),\#(wireAssistant)],"posts":{"Dd7P496wolG":\#(wirePost)}}"#)
                : .init(status: 404)
        }
        defer { server.stop() }
        let d = try await client(server).chatThread(id: "Ab12Cd34Ef56Gh78")
        let req = try #require(server.requests.first)
        #expect(req.headers["authorization"] == "Api-Key \(chatKey)" && req.body.isEmpty)
        #expect(d.messages.map(\.id) == ["101", "102"] && d.posts.count == 1)
    }

    @Test func renameIsPatchWithTheTitle() async throws {
        let server = try await LoopbackServer.start { req in
            req.method == "PATCH" && req.path == "/chat/threads/Ab12Cd34Ef56Gh78"
                ? .json(#"{"status":"success","thread":\#(wireThread)}"#) : .init(status: 404)
        }
        defer { server.stop() }
        _ = try await client(server).renameChatThread(id: "Ab12Cd34Ef56Gh78", title: "new name")
        let req = try #require(server.requests.first)
        let body = try bodyJSON(req)
        #expect(req.headers["authorization"] == "Api-Key \(chatKey)" && body["title"] as? String == "new name" && body.count == 1)
    }

    @Test func deleteIsDeleteKeyed() async throws {
        let server = try await LoopbackServer.start { req in
            req.path == "/chat/threads/Ab12Cd34Ef56Gh78"
                ? .json(#"{"status":"success"}"#) : .json(#"{"status":"error","error":{"code":"error.chat.not_found"}}"#, status: 404)
        }
        defer { server.stop() }
        try await client(server).deleteChatThread(id: "Ab12Cd34Ef56Gh78")
        let req = try #require(server.requests.first)
        #expect(req.method == "DELETE" && req.headers["authorization"] == "Api-Key \(chatKey)")
        await #expect(throws: ChatError.notFound) { try await client(server).deleteChatThread(id: "nope") }
    }

    @Test func sendPostsTheTextAndStreamsTheReply() async throws {
        let body = [
            "event: user\ndata: {\"message\":\(wireUser)}\n\n",
            ": ping\n\n",
            "event: assistant\ndata: {\"message\":\(wireAssistant)}\n\n",
            "event: text\ndata: {\"delta\":\"hi \"}\n\n",
            "event: text\ndata: {\"delta\":\"there\"}\n\n",
            "event: done\ndata: {\"message\":\(wireAssistant),\"thread\":\(wireThread)}\n\n",
        ].joined()
        let server = try await LoopbackServer.start { req in
            req.method == "POST" && req.path == "/chat/threads/Ab12Cd34Ef56Gh78/messages"
                ? .init(status: 200, headers: ["content-type": "text/event-stream", "cache-control": "no-store"], body: Data(body.utf8))
                : .init(status: 404)
        }
        defer { server.stop() }
        let events = try await collect(client(server).sendChatMessage(
            threadID: "Ab12Cd34Ef56Gh78", text: "what did i save?", postIDs: ["Dd7P496wolG", "Other"]))
        let req = try #require(server.requests.first)
        let json = try bodyJSON(req)
        #expect(req.headers["authorization"] == "Api-Key \(chatKey)")
        #expect(req.headers["accept"] == "text/event-stream" && req.headers["content-type"] == "application/json")
        #expect(json["text"] as? String == "what did i save?" && json["post_ids"] as? [String] == ["Dd7P496wolG", "Other"] && json.count == 2)
        #expect(events.count == 5, "the ping is not an event")
        #expect(events.last?.isFinal == true)
        if case .text(let t) = events[2] { #expect(t == "hi ") } else { Issue.record("\(events)") }
    }

    @Test func sendWithoutPostIDsOmitsTheField() async throws {
        let server = try await LoopbackServer.start { _ in
            .init(status: 200, headers: ["content-type": "text/event-stream"], body: Data("event: text\ndata: {\"delta\":\"x\"}\n\n".utf8))
        }
        defer { server.stop() }
        let events = try await collect(client(server).sendChatMessage(threadID: "t", text: "hello", postIDs: []))
        let json = try bodyJSON(try #require(server.requests.first))
        #expect(json["text"] as? String == "hello" && json["post_ids"] == nil && json.count == 1)
        #expect(events == [.text("x")])
    }

    @Test func aStreamWithoutItsFinalBlankLineStillDeliversTheLastEvent() async throws {
        let server = try await LoopbackServer.start { _ in
            .init(status: 200, headers: ["content-type": "text/event-stream"], body: Data("event: text\ndata: {\"delta\":\"end\"}".utf8))
        }
        defer { server.stop() }
        #expect(try await collect(client(server).sendChatMessage(threadID: "t", text: "x", postIDs: [])) == [.text("end")])
    }

    private func refusing(_ body: String, status: Int) async throws -> LoopbackServer {
        try await LoopbackServer.start { _ in .json(body, status: status) }
    }

    @Test func errorsAreMappedOnEveryRoute() async throws {
        let cases: [(String, Int, ChatError)] = [
            (#"{"status":"error","error":{"code":"error.chat.bad_request"}}"#, 400, .badRequest),
            (#"{"status":"error","error":{"code":"error.chat.not_found"}}"#, 404, .notFound),
            (#"{"status":"error","error":{"code":"error.chat.off"}}"#, 404, .off),
            (#"{"status":"error","error":{"code":"error.chat.busy"}}"#, 409, .busy),
            (#"{"status":"error","error":{"code":"error.chat.full"}}"#, 409, .full),
            (#"{"status":"error","error":{"code":"error.chat.too_many"}}"#, 409, .tooMany),
            (#"{"status":"error","error":{"code":"error.api.generic"}}"#, 503, .unavailable),
        ]
        for (body, status, expected) in cases {
            let server = try await refusing(body, status: status)
            defer { server.stop() }
            let c = client(server)
            await #expect(throws: expected, "list \(status)") { try await c.chatThreads() }
            await #expect(throws: expected, "create \(status)") { try await c.createChatThread(title: nil) }
            await #expect(throws: expected, "read \(status)") { try await c.chatThread(id: "x") }
            await #expect(throws: expected, "rename \(status)") { try await c.renameChatThread(id: "x", title: "y") }
            await #expect(throws: expected, "delete \(status)") { try await c.deleteChatThread(id: "x") }
            await #expect(throws: expected, "send \(status)") { try await self.collect(c.sendChatMessage(threadID: "x", text: "y", postIDs: [])) }
        }
    }

    @Test func aRefusalBeforeTheStreamYieldsNoEvent() async throws {
        let server = try await refusing(#"{"status":"error","error":{"code":"error.chat.busy"}}"#, status: 409)
        defer { server.stop() }
        var seen = 0
        do {
            for try await _ in client(server).sendChatMessage(threadID: "x", text: "y", postIDs: []) { seen += 1 }
            Issue.record("should have thrown")
        } catch {
            #expect(error as? ChatError == .busy)
        }
        #expect(seen == 0)
    }

    @Test func otherCodesStayTheGenericOnes() async throws {
        let auth = try await refusing(#"{"status":"error","error":{"code":"error.api.auth.key.invalid"}}"#, status: 401)
        defer { auth.stop() }
        await #expect(throws: CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)) { try await client(auth).chatThreads() }
        await #expect(throws: CobaltError.api(code: "error.api.auth.key.invalid", httpStatus: 401)) {
            try await self.collect(client(auth).sendChatMessage(threadID: "x", text: "y", postIDs: []))
        }
    }

    @Test func theKeyIsRequired() async throws {
        let server = try await LoopbackServer.start { _ in .json("{}") }
        defer { server.stop() }
        let keyless = HTTPCobaltClient(baseURL: server.base, apiKey: { nil })
        await #expect(throws: CobaltError.noAPIKey) { try await keyless.chatThreads() }
        await #expect(throws: CobaltError.noAPIKey) { try await self.collect(keyless.sendChatMessage(threadID: "x", text: "y", postIDs: [])) }
        #expect(server.requests.isEmpty)
    }

    @Test func aClientThatPredatesChatSaysUnsupported() async {
        struct Bare: CobaltClient {
            var baseURL: URL { URL(string: "https://x.test")! }
            func capabilities() async -> Capabilities { .unknown }
            func resolve(_ link: URL) async throws -> CobaltResult { throw PipelineFailure.unsupported }
            func createStudio(link: URL) async throws -> StudioCreated { throw PipelineFailure.unsupported }
            func upload(file: URL, name: String, contentType: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult { throw PipelineFailure.unsupported }
            func session(_ id: String, wait: Int) async throws -> StudioSession { throw PipelineFailure.unsupported }
            func sourceURL(session id: String) -> URL { baseURL }
            func render(session id: String, _ request: RenderRequest) async throws -> String { throw PipelineFailure.unsupported }
            func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus { throw PipelineFailure.unsupported }
            func publish(session id: String) async throws -> HostedFile { throw PipelineFailure.unsupported }
            func publish(item id: String) async throws -> HostedFile { throw PipelineFailure.unsupported }
            func openStudio(item id: String) async throws -> StudioCreated { throw PipelineFailure.unsupported }
            func library(cursor: String?, limit: Int) async throws -> LibraryPage { throw PipelineFailure.unsupported }
            func deleteMedia(name: String) async throws {}
            func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult { throw PipelineFailure.unsupported }
            func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {}
            func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply { throw PipelineFailure.unsupported }
            func relayLiveState(run: UUID, _ state: LiveContentState) async throws {}
            func endLiveRun(_ run: UUID) async throws {}
            func liveSelftest() async throws -> LiveSelftest { throw PipelineFailure.unsupported }
            func download(_ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL { destination }
        }
        let bare = Bare()
        await #expect(throws: PipelineFailure.unsupported) { try await bare.chatThreads() }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.createChatThread(title: nil) }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.chatThread(id: "x") }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.renameChatThread(id: "x", title: "y") }
        await #expect(throws: PipelineFailure.unsupported) { try await bare.deleteChatThread(id: "x") }
        await #expect(throws: PipelineFailure.unsupported) {
            for try await _ in bare.sendChatMessage(threadID: "x", text: "y", postIDs: []) {}
        }
    }
}

// MARK: - events applied

struct ChatContentTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func thread(_ title: String = "new chat") -> ChatThread {
        ChatThread(id: "T1", title: title, createdAt: t0, updatedAt: t0)
    }

    private func user(_ id: String = "1", _ text: String = "hi", posts: [String] = []) -> ChatMessage {
        ChatMessage(id: id, role: .user, text: text, postIDs: posts, createdAt: t0)
    }

    private func assistant(_ id: String = "2", status: ChatMessage.Status = .running, text: String = "") -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: text, status: status, createdAt: t0)
    }

    private func post(_ id: String) throws -> LibraryPost {
        try CobaltJSON.decoder().decode(LibraryPost.self, from: Data(wirePost.replacingOccurrences(of: "Dd7P496wolG", with: id).utf8))
    }

    @Test func aWholeReplyInOrder() throws {
        var c = ChatThreadContent(thread: thread())
        c.messages.append(ChatMessage(id: "local-A", role: .user, text: "hi", createdAt: t0))
        c.apply(.user(user("1", "hi")))
        #expect(c.messages.map(\.id) == ["1"], "the stand-in is replaced, not doubled")
        c.apply(.assistant(assistant()))
        #expect(c.isReplying)
        for piece in ["a", "b", "c", " ", "d"] { c.apply(.text(piece)) }
        #expect(c.messages[1].text == "abc d", "deltas land in order")
        c.apply(.step(ChatStep(id: "s1", status: .running, code: "x")))
        c.apply(.text("!"))
        c.apply(.step(ChatStep(id: "s2", status: .running, code: "y")))
        c.apply(.step(ChatStep(id: "s1", status: .done, code: "x", logs: ["l"], result: "1", durationMS: 5)))
        #expect(c.messages[1].steps.map(\.id) == ["s1", "s2"], "the same id replaces, in place")
        #expect(c.messages[1].steps[0].status == .done && c.messages[1].steps[0].durationMS == 5 && c.messages[1].steps[1].status == .running)
        c.apply(.posts(ids: ["P1", "P2"], posts: [try post("P1"), try post("P2")]))
        c.apply(.posts(ids: ["P2", "P3"], posts: [try post("P3")]))
        #expect(c.messages[1].postIDs == ["P1", "P2", "P3"], "appended, never doubled")
        #expect(Set(c.posts.keys) == ["P1", "P2", "P3"])
        #expect(c.posts(of: c.messages[1]).map(\.id) == ["P1", "P2", "P3"])
        c.apply(.title(thread("the title")))
        #expect(c.thread.title == "the title")
        var final = assistant("2", status: .done, text: "abc d!")
        final.postIDs = ["P1", "P2", "P3"]
        c.apply(.done(final, ChatThread(id: "T1", title: "the title", createdAt: t0, updatedAt: t0, preview: "abc d!", messageCount: 2)))
        #expect(c.messages.count == 2 && c.messages[1].status == .done && c.messages[1].text == "abc d!")
        #expect(!c.isReplying && c.thread.preview == "abc d!" && c.thread.messageCount == 2)
    }

    @Test func missingPostsStayMissing() throws {
        var c = ChatThreadContent(thread: thread(), messages: [assistant()])
        c.apply(.posts(ids: ["Gone", "P1"], posts: [try post("P1")]))
        #expect(c.messages[0].postIDs == ["Gone", "P1"])
        #expect(c.posts(of: c.messages[0]).map(\.id) == ["P1"], "the deleted one has no post: the screen draws removed")
    }

    @Test func anErrorMarksTheRunningMessage() {
        var c = ChatThreadContent(thread: thread(), messages: [user(), assistant(text: "half")])
        c.apply(.error(code: "error.chat.model", message: nil))
        #expect(c.messages[1].status == .error && c.messages[1].error == "error.chat.model" && c.messages[1].text == "half")
        #expect(!c.isReplying)
    }

    @Test func anErrorWithItsSavedMessageReplacesIt() {
        var c = ChatThreadContent(thread: thread(), messages: [user(), assistant(text: "ha")])
        var saved = assistant("2", status: .error, text: "half of it")
        saved.error = nil
        c.apply(.error(code: "error.chat.interrupted", message: saved))
        #expect(c.messages.count == 2 && c.messages[1].text == "half of it" && c.messages[1].status == .error)
        #expect(c.messages[1].error == "error.chat.interrupted", "the event's code fills in a message that carries none")
    }

    @Test func anErrorBeforeAnyAssistantRowGetsOne() {
        var c = ChatThreadContent(thread: thread(), messages: [user()])
        c.apply(.error(code: "error.api.generic", message: nil))
        #expect(c.messages.count == 2 && c.messages[1].role == .assistant && c.messages[1].status == .error)
    }

    @Test func eventsActOnTheRunningMessageNotAnOldOne() {
        var older = assistant("2", status: .done, text: "old")
        older.steps = [ChatStep(id: "old", status: .done)]
        var c = ChatThreadContent(thread: thread(), messages: [user("1"), older, user("3"), assistant("4")])
        c.apply(.text("new"))
        c.apply(.step(ChatStep(id: "s", status: .running)))
        #expect(c.messages[1].text == "old" && c.messages[1].steps.map(\.id) == ["old"])
        #expect(c.messages[3].text == "new" && c.messages[3].steps.map(\.id) == ["s"])
    }

    @Test func thePromptBeforeAFailedReplyIsTheUsersText() {
        let c = ChatThreadContent(thread: thread(), messages: [user("1", "first"), assistant("2", status: .done), user("3", "second"), assistant("4", status: .error)])
        #expect(c.prompt(before: c.messages[3])?.text == "second")
        #expect(c.prompt(before: c.messages[1])?.text == "first")
        #expect(c.prompt(before: assistant("zz")) == nil)
    }
}

// MARK: - the store on the preview server

@MainActor
struct ChatStoreTests {
    private func app(_ scenario: PreviewScenario = .happy) -> AppModel {
        AppModel.makePreview(scenario, timeScale: 0.01, clock: SystemClock())
    }

    private let t1 = PreviewData.chatThreadIDs[0]
    private let t2 = PreviewData.chatThreadIDs[1]
    private let t3 = PreviewData.chatThreadIDs[2]

    @Test func refreshListsTheThreadsNewestFirst() async {
        let app = app()
        #expect(app.chat.state == .idle)
        await app.chat.refresh()
        #expect(app.chat.state == .loaded)
        #expect(app.chat.threads.map(\.id) == [t1, t2, t3])
        #expect(app.chat.threads[0].title == "funny things from yesterday")
    }

    @Test func theEmptyAndFailingScenarios() async {
        let empty = app(.chatEmpty)
        await empty.chat.refresh()
        #expect(empty.chat.state == .loaded && empty.chat.threads.isEmpty)
        let failing = app(.chatFail)
        await failing.chat.refresh()
        #expect(failing.chat.state == .failed(.unavailable))
    }

    @Test func aFailedRefreshKeepsWhatWasListed() async throws {
        let app = app()
        await app.chat.refresh()
        let client = try #require(app.ctx.client as? PreviewClient)
        client.chatState.listFails = true
        await app.chat.refresh()
        #expect(app.chat.state == .failed(.unavailable) && app.chat.threads.count == 3)
    }

    @Test func readingAThreadLoadsMessagesAndPosts() async throws {
        let app = app()
        await app.chat.load(t1)
        let content = try #require(app.chat.content(of: t1))
        #expect(app.chat.loadStates[t1] == .loaded)
        #expect(content.messages.map(\.id) == ["101", "102", "103", "104"])
        #expect(content.messages[1].steps.count == 1 && content.messages[1].steps[0].status == .done)
        #expect(content.messages[1].postIDs.count == 3 && content.posts.count == 3)
        #expect(content.messages[3].steps.map(\.status) == [.error, .done])
    }

    @Test func aDeletedPostIsMissingFromTheMap() async throws {
        let app = app()
        await app.chat.load(t3)
        let content = try #require(app.chat.content(of: t3))
        let shown = content.messages[1]
        #expect(shown.postIDs.count == 2 && content.posts(of: shown).count == 1, "the second post was deleted")
        #expect(content.posts[PreviewData.chatGonePostID] == nil)
    }

    @Test func anUnknownThreadIsGone() async {
        let app = app()
        await app.chat.load("nope")
        #expect(app.chat.loadStates["nope"] == .gone && app.chat.content(of: "nope") == nil)
    }

    @Test func aReplyStreamsIntoTheOpenThread() async throws {
        let app = app()
        await app.chat.load(t1)
        try await app.chat.send(text: "  only the videos  ", in: t1)
        let content = try #require(app.chat.content(of: t1))
        #expect(content.messages.count == 6)
        #expect(content.messages[4].role == .user && content.messages[4].text == "only the videos" && !content.messages[4].isLocal)
        let reply = content.messages[5]
        #expect(reply.role == .assistant && reply.status == .done && reply.error == nil)
        #expect(reply.text.hasPrefix("found **12 posts**") && reply.text.hasSuffix("videos only."))
        #expect(reply.steps.count == 1 && reply.steps[0].status == .done && reply.steps[0].logs == ["found 12, showing 3"])
        #expect(reply.postIDs.count == 3 && content.posts(of: reply).count == 3)
        #expect(!app.chat.isBusy(t1) && app.chat.threads.first?.id == t1)
        // the server holds the same
        let read = try await app.ctx.client.chatThread(id: t1)
        #expect(read.messages.map(\.id) == content.messages.map(\.id) && read.messages.last?.status == .done)
    }

    @Test func aNewThreadIsTitledFromItsFirstMessageAndRenamedByTheReply() async throws {
        let app = app()
        let made = try await app.chat.create()
        #expect(made.title == "new chat" && app.chat.threads.first?.id == made.id)
        #expect(app.chat.content(of: made.id)?.messages.isEmpty == true)
        try await app.chat.send(text: "which clips have a dog in them", in: made.id)
        #expect(app.chat.thread(made.id)?.title == "the harbour clips")
        #expect(app.chat.content(of: made.id)?.thread.title == "the harbour clips")
        #expect(app.chat.content(of: made.id)?.messages.count == 2)
    }

    @Test func aSecondSendWhileBusyIsRefused() async throws {
        let app = app()
        await app.chat.load(t1)
        let first = Task { try await app.chat.send(text: "one", in: t1) }
        while !app.chat.isBusy(t1) { await Task.yield() }
        await #expect(throws: ChatError.busy) { try await app.chat.send(text: "two", in: t1) }
        try await first.value
        #expect(app.chat.content(of: t1)?.messages.count == 6, "only the first went")
    }

    @Test func badTextIsRefusedBeforeAnything() async throws {
        let app = app()
        await app.chat.load(t1)
        await #expect(throws: ChatError.badRequest) { try await app.chat.send(text: "   ", in: t1) }
        await #expect(throws: ChatError.badRequest) { try await app.chat.send(text: String(repeating: "x", count: 4001), in: t1) }
        #expect(app.chat.content(of: t1)?.messages.count == 4)
    }

    @Test func aRefusalBeforeTheStreamRestoresTheDraft() async throws {
        let app = app()
        await app.chat.load(t1)
        app.chat.setDraftText("one more thing", for: t1)
        app.chat.attach(["Dd7P496wolG"], to: t1)
        let client = try #require(app.ctx.client as? PreviewClient)
        try client.chatState.beginReply(t1)                       // the server is still writing another reply
        await #expect(throws: ChatError.busy) { try await app.chat.send(text: "one more thing", postIDs: ["Dd7P496wolG"], in: t1) }
        #expect(app.chat.content(of: t1)?.messages.count == 4, "the stand-in is taken back")
        #expect(app.chat.draft(t1) == ChatDraft(text: "one more thing", postIDs: ["Dd7P496wolG"]))
        #expect(!app.chat.isBusy(t1))
    }

    @Test func aFailedReplyIsMarkedAndKeepsItsWords() async throws {
        let app = app(.chatReplyFails)
        await app.chat.load(t1)
        try await app.chat.send(text: "try", in: t1)
        let reply = try #require(app.chat.content(of: t1)?.messages.last)
        #expect(reply.status == .error && reply.error == "error.chat.model" && reply.text == "let me look at that")
        #expect(reply.steps.map(\.status) == [.error])
        #expect(!app.chat.isBusy(t1))
    }

    @Test func attachmentsGoWithTheFirstMessageAndTheDraftEmpties() async throws {
        let app = app()
        let library = PreviewData.libraryPage(now: Date()).posts
        let made = try await app.chat.startThread(with: [library[0].id, library[1].id], posts: Array(library.prefix(2)))
        #expect(app.chat.openThreadID == made.id && app.chat.composerFocus == 1)
        #expect(app.chat.draft(made.id).postIDs == [library[0].id, library[1].id])
        #expect(app.chat.content(of: made.id)?.posts.count == 2, "the chips can draw them before any read")
        app.chat.detach(library[1].id, from: made.id)
        let draft = app.chat.draft(made.id)
        try await app.chat.send(text: "what are these", postIDs: draft.postIDs, in: made.id)
        #expect(app.chat.draft(made.id).isEmpty)
        #expect(app.chat.content(of: made.id)?.messages.first?.postIDs == [library[0].id])
    }

    @Test func attachingIsCappedAndUnique() {
        let app = app()
        app.chat.attach(["a", "a", "b"], to: "T")
        #expect(app.chat.draft("T").postIDs == ["a", "b"])
        app.chat.attach((0..<30).map { "p\($0)" }, to: "T")
        #expect(app.chat.draft("T").postIDs.count == ChatRule.attachmentLimit)
        app.chat.setDraftText("x", for: "U")
        app.chat.setDraftText("", for: "U")
        #expect(app.chat.draft("U").isEmpty)
    }

    @Test func renameCleansAndPutsFirst() async throws {
        let app = app()
        await app.chat.refresh()
        let renamed = try await app.chat.rename(t3, to: "  pasta joke  ")
        #expect(renamed.title == "pasta joke" && app.chat.thread(t3)?.title == "pasta joke")
        await #expect(throws: ChatError.badRequest) { try await app.chat.rename(t3, to: "  ") }
        await #expect(throws: ChatError.badRequest) { try await app.chat.rename(t3, to: String(repeating: "x", count: 61)) }
    }

    @Test func deleteDropsTheThreadEverywhere() async throws {
        let app = app()
        await app.chat.refresh()
        await app.chat.load(t2)
        app.chat.openThreadID = t2
        try await app.chat.delete(t2)
        #expect(app.chat.threads.map(\.id) == [t1, t3] && app.chat.content(of: t2) == nil && app.chat.openThreadID == nil)
        // a thread the server no longer has is gone locally too
        try await app.chat.delete(t2)
        await app.chat.refresh()
        #expect(app.chat.threads.map(\.id) == [t1, t3])
    }

    @Test func aServerChangeForgetsEverything() async {
        let app = app()
        await app.chat.refresh()
        await app.chat.load(t1)
        app.chat.setDraftText("draft", for: t1)
        app.serverChanged()
        #expect(app.chat.threads.isEmpty && app.chat.contents.isEmpty && app.chat.state == .idle && app.chat.draft(t1).isEmpty)
    }

    @Test func askingAboutAPostOpensTheChatTab() async throws {
        let app = app()
        let post = try #require(app.library.posts.first)
        try await app.askAbout([post])
        #expect(app.selectedTab == .chat)
        let id = try #require(app.chat.openThreadID)
        #expect(app.chat.draft(id).postIDs == [post.id] && app.chat.composerFocus == 1)
        app.capabilities.chat = false
        await #expect(throws: ChatError.off) { try await app.askAbout([post]) }
    }

    @Test func theChatTabFallsBackWhenTheServerLosesChat() {
        let app = app()
        app.selectedTab = .chat
        var caps = app.capabilities
        caps.chat = false
        app.apply(caps)
        #expect(app.selectedTab == .save)
    }
}

// MARK: - a reply whose stream drops

/// What the scripted client answers and counts (a class: a `Mutex` cannot live in a copyable struct).
private final class ChatScript: Sendable {
    /// What each `chatThread` call answers, in order (the last repeats).
    let reads: Mutex<[Result<ChatThreadDetail, ChatError>]>
    let readCount = Mutex(0)

    init(_ reads: [Result<ChatThreadDetail, ChatError>]) { self.reads = Mutex(reads) }

    var count: Int { readCount.withLock { $0 } }

    func next() throws -> ChatThreadDetail {
        let n = readCount.withLock { c -> Int in c += 1; return c }
        return try reads.withLock { $0[min(n, $0.count) - 1] }.get()
    }
}

/// A client whose reply stream says a few things and then fails, and whose thread reads follow a script.
private struct DroppingClient: CobaltClient {
    var baseURL: URL { URL(string: "https://x.test")! }
    let script: ChatScript
    /// The events sent before the stream fails (nil failure: the stream just ends).
    let events: [ChatEvent]
    let failure: (any Error)?

    func chatThread(id: String) async throws -> ChatThreadDetail { try script.next() }

    func sendChatMessage(threadID: String, text: String, postIDs: [String]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish(throwing: failure)
        }
    }

    func capabilities() async -> Capabilities { .unknown }
    func resolve(_ link: URL) async throws -> CobaltResult { throw PipelineFailure.unsupported }
    func createStudio(link: URL) async throws -> StudioCreated { throw PipelineFailure.unsupported }
    func upload(file: URL, name: String, contentType: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> UploadResult { throw PipelineFailure.unsupported }
    func session(_ id: String, wait: Int) async throws -> StudioSession { throw PipelineFailure.unsupported }
    func sourceURL(session id: String) -> URL { baseURL }
    func render(session id: String, _ request: RenderRequest) async throws -> String { throw PipelineFailure.unsupported }
    func renderStatus(session id: String, job: String, wait: Int) async throws -> RenderStatus { throw PipelineFailure.unsupported }
    func publish(session id: String) async throws -> HostedFile { throw PipelineFailure.unsupported }
    func publish(item id: String) async throws -> HostedFile { throw PipelineFailure.unsupported }
    func openStudio(item id: String) async throws -> StudioCreated { throw PipelineFailure.unsupported }
    func library(cursor: String?, limit: Int) async throws -> LibraryPage { throw PipelineFailure.unsupported }
    func deleteMedia(name: String) async throws {}
    func setTitle(anchor itemID: String, _ title: String?) async throws -> PostTitleResult { throw PipelineFailure.unsupported }
    func registerLiveStartToken(_ token: String, environment: LiveEnvironment) async throws {}
    func registerLiveRun(_ r: LiveRunRegistration) async throws -> LiveRunReply { throw PipelineFailure.unsupported }
    func relayLiveState(run: UUID, _ state: LiveContentState) async throws {}
    func endLiveRun(_ run: UUID) async throws {}
    func liveSelftest() async throws -> LiveSelftest { throw PipelineFailure.unsupported }
    func download(_ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL { destination }
}

@MainActor
private final class Flag { var done = false; var error: Error? }

@MainActor
struct ChatPollingTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func thread(_ count: Int) -> ChatThread { ChatThread(id: "T1", title: "t", createdAt: t0, updatedAt: t0, messageCount: count) }

    private func message(_ id: String, _ role: ChatMessage.Role, _ text: String, _ status: ChatMessage.Status = .done) -> ChatMessage {
        ChatMessage(id: id, role: role, text: text, status: status, createdAt: t0)
    }

    private func detail(replyText: String, status: ChatMessage.Status) -> ChatThreadDetail {
        ChatThreadDetail(thread: thread(2), messages: [message("1", .user, "hi"), message("2", .assistant, replyText, status)])
    }

    private func setup(
        events: [ChatEvent], failure: (any Error)?, reads: [Result<ChatThreadDetail, ChatError>]
    ) -> (Harness, ChatScript) {
        let h = Harness(.happy)
        let script = ChatScript(reads)
        h.ctx.client = DroppingClient(script: script, events: events, failure: failure)
        h.app.chat.seed(ChatThreadContent(thread: thread(0)))
        return (h, script)
    }

    private let dropped: any Error = CobaltError.network(.networkConnectionLost)

    @Test func aDroppedStreamIsFollowedByReadingEveryTwoSeconds() async throws {
        let events: [ChatEvent] = [
            .user(message("1", .user, "hi")), .assistant(message("2", .assistant, "", .running)), .text("hel"),
        ]
        let reads: [Result<ChatThreadDetail, ChatError>] = [
            .success(detail(replyText: "hello w", status: .running)),
            .success(detail(replyText: "hello wor", status: .running)),
            .success(detail(replyText: "hello world", status: .done)),
        ]
        let (h, client) = setup(events: events, failure: dropped, reads: reads)
        let flag = Flag()
        let task = Task { @MainActor in
            do { try await h.app.chat.send(text: "hi", in: "T1") } catch { flag.error = error }
            flag.done = true
        }
        await h.drive(until: { flag.done })
        await task.value
        #expect(flag.error == nil)
        #expect(client.count == 3)
        #expect(h.clock.elapsed == 4, "two waits of 2 s between three reads")
        let content = try #require(h.app.chat.content(of: "T1"))
        #expect(content.messages.map(\.id) == ["1", "2"])
        #expect(content.messages[1].text == "hello world" && content.messages[1].status == .done)
        #expect(!h.app.chat.isBusy("T1"))
    }

    @Test func aReplyThatNeverFinishesIsInterruptedAfterThreeMinutes() async throws {
        let events: [ChatEvent] = [.user(message("1", .user, "hi")), .assistant(message("2", .assistant, "", .running)), .text("partial")]
        let (h, client) = setup(events: events, failure: dropped, reads: [.success(detail(replyText: "partial", status: .running))])
        let flag = Flag()
        let task = Task { @MainActor in
            do { try await h.app.chat.send(text: "hi", in: "T1") } catch { flag.error = error }
            flag.done = true
        }
        await h.drive(until: { flag.done }, maxVirtualSeconds: 400)
        await task.value
        #expect(flag.error == nil)
        let reads = client.count
        #expect(reads == ChatStore.pollLimit)
        #expect(h.clock.elapsed >= 170 && h.clock.elapsed <= 180, "about three minutes: \(h.clock.elapsed)")
        let reply = try #require(h.app.chat.content(of: "T1")?.messages.last)
        #expect(reply.status == .error && reply.error == "error.chat.interrupted" && reply.text == "partial")
        #expect(!h.app.chat.isBusy("T1"))
    }

    @Test func aStreamThatEndsWithoutDoneIsFollowedToo() async throws {
        let events: [ChatEvent] = [.user(message("1", .user, "hi")), .assistant(message("2", .assistant, "", .running))]
        let (h, client) = setup(events: events, failure: nil, reads: [.success(detail(replyText: "all of it", status: .done))])
        let flag = Flag()
        let task = Task { @MainActor in
            try? await h.app.chat.send(text: "hi", in: "T1")
            flag.done = true
        }
        await h.drive(until: { flag.done })
        await task.value
        #expect(client.count == 1)
        #expect(h.app.chat.content(of: "T1")?.messages.last?.text == "all of it")
    }

    @Test func aBadReadDuringFollowingIsRetried() async throws {
        let events: [ChatEvent] = [.user(message("1", .user, "hi")), .assistant(message("2", .assistant, "", .running))]
        let reads: [Result<ChatThreadDetail, ChatError>] = [
            .failure(.unavailable), .success(detail(replyText: "ok", status: .done)),
        ]
        let (h, client) = setup(events: events, failure: dropped, reads: reads)
        let flag = Flag()
        let task = Task { @MainActor in
            try? await h.app.chat.send(text: "hi", in: "T1")
            flag.done = true
        }
        await h.drive(until: { flag.done })
        await task.value
        #expect(client.count == 2)
        #expect(h.app.chat.content(of: "T1")?.messages.last?.status == .done)
    }

    @Test func aMessageThatNeverReachedTheServerIsTakenBack() async throws {
        // nothing came back and the server has nothing new: the send fails, the draft returns
        let (h, _) = setup(events: [], failure: dropped, reads: [.success(ChatThreadDetail(thread: thread(0), messages: []))])
        h.app.chat.setDraftText("hi", for: "T1")
        let flag = Flag()
        let task = Task { @MainActor in
            do { try await h.app.chat.send(text: "hi", in: "T1") } catch { flag.error = error }
            flag.done = true
        }
        await h.drive(until: { flag.done })
        await task.value
        #expect(flag.error as? CobaltError == CobaltError.network(.networkConnectionLost))
        #expect(h.app.chat.content(of: "T1")?.messages.isEmpty == true)
        #expect(h.app.chat.draft("T1").text == "hi")
        #expect(!h.app.chat.isBusy("T1"))
    }

    @Test func aMessageTheServerSavedDespiteTheDropIsAdoptedAndFollowed() async throws {
        let reads: [Result<ChatThreadDetail, ChatError>] = [
            .success(detail(replyText: "", status: .running)),
            .success(detail(replyText: "so", status: .running)),
            .success(detail(replyText: "done now", status: .done)),
        ]
        let (h, client) = setup(events: [], failure: dropped, reads: reads)
        let flag = Flag()
        let task = Task { @MainActor in
            try? await h.app.chat.send(text: "hi", in: "T1")
            flag.done = true
        }
        await h.drive(until: { flag.done })
        await task.value
        #expect(client.count == 3, "one to ask whether it landed, then two to follow")
        #expect(h.app.chat.content(of: "T1")?.messages.last?.text == "done now")
    }

    @Test func openingAThreadWhoseReplyIsStillRunningFollowsIt() async throws {
        let reads: [Result<ChatThreadDetail, ChatError>] = [
            .success(detail(replyText: "so far", status: .running)),
            .success(detail(replyText: "so far, and more", status: .running)),
            .success(detail(replyText: "finished", status: .done)),
        ]
        let (h, client) = setup(events: [], failure: nil, reads: reads)
        await h.app.chat.load("T1")
        #expect(h.app.chat.isBusy("T1"), "the reply is another device's, still running")
        await h.drive(until: { !h.app.chat.isBusy("T1") })
        #expect(client.count == 3)
        #expect(h.app.chat.content(of: "T1")?.messages.last?.text == "finished")
    }
}

// MARK: - the reply's Markdown

struct ChatMarkdownTests {
    @Test func paragraphsAreSplitAtBlankLinesAndKeepTheirLineBreaks() {
        #expect(ChatMarkdown.blocks("one\ntwo\n\nthree") == [.paragraph("one\ntwo"), .paragraph("three")])
        #expect(ChatMarkdown.blocks("").isEmpty)
        #expect(ChatMarkdown.blocks("  \n\n ").isEmpty)
    }

    @Test func bulletsAndNumbersAreListsWithNesting() {
        let blocks = ChatMarkdown.blocks("found 3:\n\n1. one\n2. two\n   - nested\n3. three\n\n- a\n* b\n+ c")
        #expect(blocks.count == 3)
        guard blocks.count == 3, case .list(let numbers) = blocks[1], case .list(let bullets) = blocks[2] else {
            Issue.record("\(blocks)")
            return
        }
        #expect(numbers.map(\.marker) == ["1.", "2.", "•", "3."] && numbers.map(\.level) == [0, 0, 1, 0])
        #expect(numbers.map(\.text) == ["one", "two", "nested", "three"])
        #expect(bullets.map(\.text) == ["a", "b", "c"] && bullets.allSatisfy { $0.marker == "•" })
    }

    @Test func aListRightAfterAParagraphStartsANewBlock() {
        #expect(ChatMarkdown.blocks("here:\n- a\n- b\nback") == [
            .paragraph("here:"), .list([ChatListItem(marker: "•", text: "a"), ChatListItem(marker: "•", text: "b")]), .paragraph("back"),
        ])
    }

    @Test func headingsQuotesAndRules() {
        #expect(ChatMarkdown.blocks("## the day\n> a quote\n> more\n---") == [
            .heading(level: 2, text: "the day"), .quote("a quote\nmore"), .rule,
        ])
        #expect(ChatMarkdown.blocks("#nothing") == [.paragraph("#nothing")], "no space, no heading")
        #expect(ChatMarkdown.blocks("-5 degrees") == [.paragraph("-5 degrees")])
    }

    @Test func fencesKeepEverythingInside() {
        let text = "before\n```js\nconst a = 1;\n\n- not a list\n```\nafter"
        #expect(ChatMarkdown.blocks(text) == [
            .paragraph("before"), .code(language: "js", text: "const a = 1;\n\n- not a list"), .paragraph("after"),
        ])
        #expect(ChatMarkdown.blocks("```\nplain") == [.code(language: nil, text: "plain")], "a half-streamed fence runs to the end")
    }

    @Test func crlfIsFine() {
        #expect(ChatMarkdown.blocks("a\r\n\r\n- b") == [.paragraph("a"), .list([ChatListItem(marker: "•", text: "b")])])
    }
}

import Foundation
import Testing
@testable import CobaltKit

// Sub-agents (APP-API-CONTRACT 43): the `Agent` and `AgentMail` shapes, `GET /chat/threads/<id>/agents`, the `agent` of a
// helper's own thread, the `agents` tool card, and the store on the `.chatAgents` preview server.

private let wireAgents = """
{"status":"success","agents":[
 {"agent":"AbCdEfGhIjKlMnOp","job":"agent:AbCdEfGhIjKlMnOp","name":"lia share 11","status":"running","task":"go through lia share 11",
  "activity":"library.search","result":null,"post_ids":[],"error":null,"turns":2,"unread":1,
  "created_at":1761900000000,"updated_at":1761900060000,"ended_at":null},
 {"agent":"QrStUvWxYz012345","job":"agent:QrStUvWxYz012345","name":"lia share 12","status":"done","task":"go through lia share 12",
  "activity":null,"result":"14 videos, mostly cats","post_ids":["P1","P2"],"error":null,"turns":1,"unread":0,
  "created_at":1761900000000,"updated_at":1761900120000,"ended_at":1761900120000},
 {"agent":"ZzZzZzZzZzZzZzZz","name":"from the future","status":"hibernating","task":"x","created_at":1761900000000},
 {"name":"no id"}
],"mail":[
 {"id":1,"from":"parent","from_name":"parent","to":"QrStUvWxYz012345","to_name":"lia share 12","text":"only videos","created_at":1761900010000,"read":true},
 {"id":2,"from":"AbCdEfGhIjKlMnOp","from_name":"lia share 11","to":"parent","to_name":"parent","text":"two repeats, flag both?","created_at":1761900030000,"read":false},
 {"from":"parent","text":"no id"}
]}
"""

@Suite struct ChatAgentDecodingTests {
    private func list() throws -> ChatAgentList {
        try CobaltJSON.decoder().decode(ChatAgentList.self, from: Data(wireAgents.utf8))
    }

    @Test func agentsDecodeAndOddOnesAreDropped() throws {
        let l = try list()
        // the row with no id is dropped, never the list
        #expect(l.agents.map(\.name) == ["lia share 11", "lia share 12", "from the future"])
        let running = l.agents[0]
        #expect(running.id == "AbCdEfGhIjKlMnOp" && running.job == "agent:AbCdEfGhIjKlMnOp" && running.status == .running)
        #expect(running.activity == "library.search" && running.turns == 2 && running.unread == 1 && running.endedAt == nil)
        #expect(running.updatedAt == Date(timeIntervalSince1970: 1_761_900_060))
        let done = l.agents[1]
        #expect(done.status == .done && done.result == "14 videos, mostly cats" && done.postIDs == ["P1", "P2"])
        #expect(done.endedAt == Date(timeIntervalSince1970: 1_761_900_120))
        // a status this app does not know is `.unknown`; the job id falls back to agent:<id>
        #expect(l.agents[2].status == .unknown && l.agents[2].job == "agent:ZzZzZzZzZzZzZzZz" && !l.agents[2].isLive)
        #expect(l.isLive && !l.isEmpty)
    }

    @Test func mailDecodesWithNumberIds() throws {
        let l = try list()
        #expect(l.mail.map(\.id) == ["1", "2"])
        #expect(l.mail[0].isFromParent && l.mail[0].toName == "lia share 12" && l.mail[0].read)
        #expect(!l.mail[1].isFromParent && !l.mail[1].read)
        #expect(l.mail(with: "QrStUvWxYz012345").map(\.id) == ["1"])
        #expect(l.mail(with: "AbCdEfGhIjKlMnOp").map(\.id) == ["2"])
        // lia share 11 asked the chat something it has not read yet
        #expect(l.hasAsked("AbCdEfGhIjKlMnOp") && !l.hasAsked("QrStUvWxYz012345"))
    }

    @Test func statusWords() {
        #expect(ChatAgent.Status(wire: "queued") == .queued && ChatAgent.Status(wire: "queued").isLive)
        #expect(ChatAgent.Status(wire: "error") == .error)
        #expect(ChatAgent.Status(wire: "stopped") == .stopped)
        // a stopped agent's job reads "cancelled"
        #expect(ChatAgent.Status(wire: "cancelled") == .stopped)
        #expect(ChatAgent.Status(wire: "napping") == .unknown && ChatAgent.Status(wire: nil) == .unknown)
    }

    @Test func emptyListsBeforeTheMigration() throws {
        let l = try CobaltJSON.decoder().decode(ChatAgentList.self, from: Data(#"{"status":"success","agents":[],"mail":[]}"#.utf8))
        #expect(l.isEmpty && l.mail.isEmpty && !l.isLive)
        let bare = try CobaltJSON.decoder().decode(ChatAgentList.self, from: Data("{}".utf8))
        #expect(bare == ChatAgentList())
    }

    @Test func aHelpersThreadReadCarriesItsAgent() throws {
        let json = """
        {"status":"success","thread":{"id":"QrStUvWxYz012345","title":"lia share 12","created_at":1761900000000,"updated_at":1761900120000},
         "messages":[{"id":"1","role":"user","text":"go through lia share 12","created_at":1761900000000}],"posts":{},
         "agent":{"id":"QrStUvWxYz012345","parent":"PaReNtThReAd0001","name":"lia share 12","status":"done","task":"go through lia share 12"}}
        """
        let detail = try CobaltJSON.decoder().decode(ChatThreadDetail.self, from: Data(json.utf8))
        #expect(detail.agent == ChatAgentRef(id: "QrStUvWxYz012345", parent: "PaReNtThReAd0001", name: "lia share 12", status: .done, task: "go through lia share 12"))
        #expect(ChatThreadContent(detail).isAgentThread)
        // a plain thread has none
        let plain = try CobaltJSON.decoder().decode(ChatThreadDetail.self, from: Data(#"{"thread":{"id":"T","title":"t","created_at":1},"messages":[]}"#.utf8))
        #expect(plain.agent == nil && !ChatThreadContent(plain).isAgentThread)
        // an odd agent object is dropped, never the thread
        let odd = try CobaltJSON.decoder().decode(ChatThreadDetail.self, from: Data(#"{"thread":{"id":"T","title":"t","created_at":1},"messages":[],"agent":{"name":5}}"#.utf8))
        #expect(odd.agent == nil && odd.thread.id == "T")
    }
}

// MARK: - the agents card (43.5)

private let wireAgentCards = """
{"id":"toolu_43","kind":"code","status":"done","code":"","logs":[],"duration_ms":300,"calls":[
 {"op":"agents.spawn","ms":60,"status":"done","card":{"type":"agents","change":"started","agents":[
   {"id":"AbCdEfGhIjKlMnOp","name":"lia share 11","status":"queued","task":"go through lia share 11","activity":null,"result":null,"post_ids":[],"watching":false}],
   "message":null,"mail":[]}},
 {"op":"agents.send","ms":12,"status":"done","card":{"type":"agents","change":"sent","agents":[],"message":{"to":"lia share 11","text":"only videos"},"mail":[]}},
 {"op":"agents.inbox","ms":9,"status":"done","card":{"type":"agents","change":"inbox","agents":[],"message":null,
   "mail":[{"from":"lia share 12","text":"done, 14 videos"},{"from":"lia share 11","text":"two repeats"}]}},
 {"op":"jobs.onDone","ms":8,"status":"done","card":{"type":"agents","change":"waiting","agents":[
   {"id":"AbCdEfGhIjKlMnOp","name":"lia share 11","status":"running","task":"go through lia share 11","activity":"look","result":null,"post_ids":[],"watching":true}],
   "message":null,"mail":[]}},
 {"op":"agents.list","ms":10,"status":"done","card":{"type":"agents","change":"listed","agents":[
   {"id":"AbCdEfGhIjKlMnOp","name":"lia share 11","status":"running","task":"","post_ids":[]},
   {"id":"QrStUvWxYz012345","name":"lia share 12","status":"cancelled","task":"","result":"stopped early","post_ids":["P1","P2"]},
   {"status":"done"}],"message":null,"mail":[]}},
 {"op":"agents.get","ms":10,"status":"done","card":{"type":"agents","change":"teleported","agents":[{"id":"QrStUvWxYz012345","name":"lia share 12","status":"done","post_ids":["P3"]}]}}
]}
"""

@Suite struct ChatAgentCardTests {
    private func step() throws -> ChatStep {
        try CobaltJSON.decoder().decode(ChatStep.self, from: Data(wireAgentCards.utf8))
    }

    private func agents(_ call: ChatToolCall) -> ChatToolCard.Agents? {
        if case .agents(let a) = call.card { return a }
        return nil
    }

    @Test func everyChangeDecodes() throws {
        let s = try step()
        #expect(s.calls.count == 6 && s.calls.allSatisfy { $0.card != nil })
        let started = try #require(agents(s.calls[0]))
        #expect(started.change == .started && started.agents.map(\.status) == [.queued] && started.message == nil)
        let sent = try #require(agents(s.calls[1]))
        #expect(sent.change == .sent && sent.message == ChatToolCard.Agents.Message(to: "lia share 11", text: "only videos") && sent.agents.isEmpty)
        let inbox = try #require(agents(s.calls[2]))
        #expect(inbox.change == .inbox && inbox.mail.map(\.from) == ["lia share 12", "lia share 11"])
        let waiting = try #require(agents(s.calls[3]))
        #expect(waiting.change == .waiting && waiting.agents.first?.watching == true && waiting.agents.first?.activity == "look")
        let listed = try #require(agents(s.calls[4]))
        // the row with neither id nor name is dropped; a cancelled job reads as stopped
        #expect(listed.change == .listed && listed.agents.map(\.name) == ["lia share 11", "lia share 12"])
        #expect(listed.agents[1].status == .stopped && listed.agents[1].result == "stopped early")
        // a change this app does not know still draws the rows
        let odd = try #require(agents(s.calls[5]))
        #expect(odd.change == .listed && odd.agents.first?.postIDs == ["P3"])
    }

    @Test func itsPostsJoinTheThreadMap() throws {
        let s = try step()
        #expect(s.calls[4].card?.postIDs == ["P1", "P2"])
        #expect(s.calls[1].card?.postIDs == [])
        #expect(Set(s.cards.flatMap { $0.card.postIDs }) == ["P1", "P2", "P3"])
    }

    @Test func aLaterCardOfTheSameHelperReplacesTheEarlier() throws {
        let cards = try step().cards
        // the waiting card takes the started card's place; lists, messages and mail are never folded
        #expect(cards.map(\.call.op) == ["agents.send", "agents.inbox", "jobs.onDone", "agents.list", "agents.get"])
    }

    @Test func anUnknownCardTypeStaysAChip() throws {
        let json = #"{"op":"agents.dance","ms":1,"status":"done","card":{"type":"agents2","x":1}}"#
        let call = try CobaltJSON.decoder().decode(ChatToolCall.self, from: Data(json.utf8))
        #expect(call.op == "agents.dance" && call.card == nil)
    }
}

// MARK: - the store on the preview server

@MainActor
struct ChatAgentStoreTests {
    private func app() -> AppModel {
        AppModel.makePreview(.chatAgents, timeScale: 0.01, clock: SystemClock())
    }

    private let parent = PreviewData.agentsThreadID
    private let running = PreviewData.agentIDs[0]
    private let done = PreviewData.agentIDs[1]

    @Test func helpersThreadsAreNotListed() async {
        let app = app()
        await app.chat.refresh()
        #expect(app.chat.threads.first?.id == parent)
        #expect(!app.chat.threads.contains { PreviewData.agentIDs.contains($0.id) })
    }

    @Test func theOpenThreadReadsItsHelpers() async {
        let app = app()
        app.chat.openThreadID = parent
        await app.chat.load(parent)
        await app.chat.loadAgents(parent)
        let list = app.chat.agents(of: parent)
        #expect(list.agents.map(\.id) == [running, done])
        #expect(list.agents.map(\.status) == [.running, .done] && list.isLive)
        #expect(list.mail(with: running).count == 2 && list.hasAsked(running))
        // a thread with no helpers has empty lists
        await app.chat.loadAgents(PreviewData.chatThreadIDs[0])
        #expect(app.chat.agents(of: PreviewData.chatThreadIDs[0]).isEmpty)
    }

    @Test func aHelpersThreadIsReadOnlyAndStaysOutOfTheList() async {
        let app = app()
        await app.chat.refresh()
        await app.chat.load(done)
        let content = app.chat.content(of: done)
        #expect(content?.isAgentThread == true && content?.agent?.parent == parent && content?.agent?.status == .done)
        // its task is the first bubble
        #expect(content?.messages.first?.role == .user && content?.messages.first?.text.hasPrefix("go through") == true)
        #expect(!app.chat.threads.contains { $0.id == done })
    }

    @Test func aServerChangeForgetsTheHelpers() async {
        let app = app()
        app.chat.openThreadID = parent
        await app.chat.load(parent)
        await app.chat.loadAgents(parent)
        app.chat.openAgentID = done
        app.serverChanged()
        #expect(app.chat.agentLists.isEmpty && app.chat.openAgentID == nil)
    }
}

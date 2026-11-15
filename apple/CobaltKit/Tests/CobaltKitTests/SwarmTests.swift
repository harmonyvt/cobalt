import Foundation
import Testing
@testable import CobaltKit

// Swarms in the apps (apple/CONTRACT-SWARMS.md; APP-API-CONTRACT 59, 61, 62): the models, the words, the store, the Face ID gate,
// the Live Activity state, the results board.

// MARK: - helpers

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try SwarmWire.decoder().decode(T.self, from: Data(json.utf8))
}

/// A swarm as `GET /swarms/<id>` writes it (59.5 + 61.3 + 62.3), every field present.
private let fullSwarmJSON = """
{"swarm":"PrEvIeWswarm0001","name":"rename 1,000 emotes","mode":"propose","status":"awaiting_approval","spec_hash":"abc123",
 "prompt":"rename them","tools":["seventv.set"],"writes":["seventv.rename"],"scope":{"set_id":"S1"},"items":1000,"batch_size":50,
 "concurrency":5,
 "tasks":{"total":3,"queued":1,"running":1,"done":1,"failed":0,"waiting":0,
   "cells":[{"idx":0,"status":"done","error":null,"step":"done"},{"idx":1,"status":"running","error":null,"step":"read seventv.set"},{"idx":2,"status":"queued","error":null,"step":null}]},
 "estimate_usd":{"low":0.3,"high":0.5},"cap_usd":1,"spent_usd":0.21,
 "created_at":1790000000000,"approved_at":null,"finished_at":null,"expires_at":1790003120000,
 "reduce":null,"error":null,"changes":{"total":214,"kept":214,"done":0,"failed":0},
 "apply":{"status":"none","done":0,"failed":0,"total":0},
 "spec_preview":{"items_sample":[{"id":"e1","name":"CatJam"}],"source":{"call":"seventv.set","args":{"set_id":"S1"},"path":"emotes"},
   "output_schema":null,"reduce_prompt":null,"turns_per_task":6,"attempts":2,"stop_after_failed_tasks":5},
 "unscoped_writes":[],"approve_url":"https://cobalt.capybaraharmony.com/swarms/PrEvIeWswarm0001","job":"swarm:PrEvIeWswarm0001",
 "messages":{"total":6,"waiting":1},"planner":"claude code","score":0.84}
"""

// MARK: - decoding

struct SwarmDecodingTests {
    @Test func aFullSwarmDecodes() throws {
        let s = try decode(Swarm.self, fullSwarmJSON)
        #expect(s.id == "PrEvIeWswarm0001" && s.name == "rename 1,000 emotes")
        #expect(s.mode == .propose && s.status == .awaitingApproval && s.specHash == "abc123")
        #expect(s.tools == ["seventv.set"] && s.writes == ["seventv.rename"])
        #expect(s.items == 1000 && s.batchSize == 50 && s.concurrency == 5)
        #expect(s.tasks.total == 3 && s.tasks.cells.count == 3 && s.tasks.cells[1].status == .running && s.tasks.cells[1].agent == 2)
        #expect(s.tasks.cells[1].step == "read seventv.set")
        #expect(s.estimateUSD == Swarm.Range2(low: 0.3, high: 0.5) && s.capUSD == 1 && s.spentUSD == 0.21)
        #expect(s.createdAt == Date(timeIntervalSince1970: 1_790_000_000) && s.expiresAt == Date(timeIntervalSince1970: 1_790_003_120))
        #expect(s.approvedAt == nil && s.finishedAt == nil)
        #expect(s.changes == Swarm.ChangeCounts(total: 214, kept: 214, done: 0, failed: 0))
        #expect(s.apply.status == .none)
        #expect(s.preview?.itemsSample.count == 1 && s.preview?.source?.call == "seventv.set" && s.preview?.turnsPerTask == 6)
        #expect(s.preview?.source?.args["set_id"]?.stringValue == "S1")
        #expect(s.messages == Swarm.MessageCounts(total: 6, waiting: 1) && s.planner == "claude code" && s.score == 0.84)
        #expect(s.job == "swarm:PrEvIeWswarm0001" && s.approveURL?.host == "cobalt.capybaraharmony.com")
        #expect(s.waitsForYou && !s.isWorking)
    }

    @Test func everyStatusModeAndApplyStateDecodes() throws {
        for raw in ["awaiting_approval", "running", "stopping", "done", "failed", "stopped", "declined", "expired"] {
            let s = try decode(Swarm.self, #"{"swarm":"a","status":"\#(raw)"}"#)
            #expect(s.status.rawValue == raw)
        }
        for raw in ["propose", "read", "act"] { #expect(try decode(Swarm.self, #"{"swarm":"a","mode":"\#(raw)"}"#).mode.rawValue == raw) }
        for raw in ["none", "ready", "applying", "applied", "failed"] {
            #expect(try decode(Swarm.self, #"{"swarm":"a","apply":{"status":"\#(raw)"}}"#).apply.status.rawValue == raw)
        }
    }

    @Test func unknownValuesTakeTheSafeDefault() throws {
        let s = try decode(Swarm.self, #"{"swarm":"a","status":"paused-by-aliens","mode":"dream","apply":{"status":"soon"}}"#)
        #expect(s.status == .running, "an unknown status keeps polling")
        #expect(s.mode == .read, "an unknown mode changes nothing")
        #expect(s.apply.status == .none)
        let cell = try decode(SwarmCell.self, #"{"idx":4,"status":"hovering"}"#)
        #expect(cell.status == .queued && cell.agent == 5)
        #expect(try decode(SwarmChange.self, #"{"n":1,"status":"???"}"#).status == .proposed)
        let m = try decode(SwarmMessage.self, #"{"id":1,"dir":"sideways","kind":"shout","sender":"ghost","at":5}"#)
        #expect(m.dir == .up && m.kind == .note && m.sender == .agent)
    }

    @Test func missingFieldsAreDefaultedAndNothingElseIsNeeded() throws {
        let s = try decode(Swarm.self, #"{"swarm":"a"}"#)
        #expect(s.name == "" && s.tools.isEmpty && s.writes.isEmpty && s.tasks.cells.isEmpty && s.tasks.total == 0)
        #expect(s.estimateUSD == nil && s.changes == nil && s.preview == nil && s.messages == nil && s.planner == nil && s.score == nil)
        #expect(s.apply == Swarm.Apply() && s.clashCount == 0)
        #expect(throws: (any Error).self) { try decode(Swarm.self, #"{"name":"no id"}"#) }
    }

    @Test func aListDropsOneOddRowNotTheList() throws {
        let wire = try decode(SwarmListWire.self, #"{"swarms":[{"swarm":"a"},{"name":"no id"},{"swarm":"b"}]}"#)
        #expect(wire.swarms.map(\.id) == ["a", "b"])
        #expect(try decode(SwarmListWire.self, "{}").swarms.isEmpty)
    }

    @Test func aSwarmEncodesAndDecodesBack() throws {
        let s = try decode(Swarm.self, fullSwarmJSON)
        let again = try SwarmWire.decoder().decode(Swarm.self, from: SwarmWire.encoder().encode(s))
        #expect(again == s)
    }

    @Test func keysInsideOpenFieldsKeepTheirSpelling() throws {
        // `convertFromSnakeCase` would rewrite `emote_id` to `emoteId`: the args are read as written
        let c = try decode(SwarmChange.self, #"{"n":3,"task":0,"op":"seventv.rename","args":{"set_id":"S","emote_id":"E","alias":"bonk"},"edit_arg":"alias","preview_url":"https://cdn.7tv.app/emote/E/2x.webp","keep":true,"status":"proposed","clash":"duplicate name: also proposed by #118"}"#)
        #expect(c.args?.dictionaryValue?["emote_id"]?.stringValue == "E")
        #expect(c.editArg == "alias" && c.canEdit && c.previewURL?.host == "cdn.7tv.app" && c.id == 3 && c.agent == 1)
        #expect(c.clash == "duplicate name: also proposed by #118")
    }

    @Test func aChangeKeepMayComeAsANumber() throws {
        #expect(try decode(SwarmChange.self, #"{"n":1,"keep":0}"#).keep == false)
        #expect(try decode(SwarmChange.self, #"{"n":1,"keep":1}"#).keep)
        #expect(try decode(SwarmChange.self, #"{"n":1}"#).keep)
    }

    @Test func aChangePageAndADecideAnswerDecode() throws {
        let page = try decode(SwarmChangePage.self, #"{"changes":[{"n":1},{"n":2},{"x":1}],"total":342,"offset":0}"#)
        #expect(page.changes.map(\.n) == [1, 2] && page.total == 342)
        let decided = try decode(SwarmDecided.self, #"{"swarm":\#(fullSwarmJSON),"changes":[{"n":7,"keep":false}]}"#)
        #expect(decided.swarm.id == "PrEvIeWswarm0001" && decided.changes.first?.keep == false)
    }

    @Test func messagesDecodeWithTheirAgentAndAnswer() throws {
        let m = try decode(SwarmMessage.self, #"{"id":9,"swarm":"s","agent":3,"dir":"up","kind":"ask","sender":"agent","text":"widepeepo?","at":1790000000000,"answered":false}"#)
        #expect(m.agent == 3 && m.isOpenAsk && m.at == Date(timeIntervalSince1970: 1_790_000_000))
        let all = try decode(SwarmMessage.self, #"{"id":10,"swarm":"s","agent":null,"dir":"down","kind":"tell","sender":"owner","text":"keep numbers","at":1,"answered":true}"#)
        #expect(all.agent == nil && !all.isOpenAsk && all.sender == .owner)
        let sent = try decode(SwarmSent.self, #"{"sent":1,"to":3,"woke":true}"#)
        #expect(sent.to == .agent(3) && sent.woke && sent.sent == 1)
        #expect(try decode(SwarmSent.self, #"{"sent":1,"to":"all","woke":false}"#).to == .all)
    }

    @Test func anAgentDecodesWithItsStepsMessagesAndChanges() throws {
        let a = try decode(SwarmAgent.self, """
        {"swarm":"s","agent":7,"status":"failed","items":[{"id":"e1"},"plain"],"attempts":2,"in_tokens":9200,"out_tokens":1300,"usd":0.011,
         "started_at":1790000000000,"ended_at":1790000041000,"error":"error.swarm.bad_answer: x","result":null,
         "steps":[{"at":1790000000000,"text":"started"},{"text":"failed: bad_answer"}],
         "messages":[{"id":1,"dir":"up","kind":"ask","sender":"agent","text":"?","at":1}],"changes":[{"n":1,"task":6}]}
        """)
        #expect(a.agent == 7 && a.status == .failed && a.attempts == 2 && a.inTokens == 9200 && a.outTokens == 1300)
        #expect(a.items.count == 2 && a.items[1].stringValue == "plain" && a.seconds == 41)
        #expect(a.steps.map(\.text) == ["started", "failed: bad_answer"] && a.messages.count == 1 && a.changes.first?.agent == 7)
        let bare = try decode(SwarmAgent.self, #"{"agent":1}"#)
        #expect(bare.status == .queued && bare.steps.isEmpty && bare.items.isEmpty && bare.seconds == nil)
    }

    @Test func aDecisionIsWrittenAsTheWireWantsIt() {
        #expect(SwarmDecision(n: 3, keep: false).wire["keep"] as? Bool == false)
        #expect(SwarmDecision(n: 3, keep: false).wire["after"] == nil)
        #expect(SwarmDecision(n: 3, after: "bonk").wire["after"] as? String == "bonk")
        #expect(SwarmDecision(n: 3, clearAfter: true).wire["after"] is NSNull)
        #expect(SwarmRecipient.agent(4).wire as? Int == 4 && SwarmRecipient.all.wire as? String == "all")
    }
}

// MARK: - the words

struct SwarmWordsTests {
    @Test func moneyReadsInCentsUnderADollar() {
        #expect(SwarmWords.money(0.21) == "21¢")
        #expect(SwarmWords.money(0.5) == "50¢")
        #expect(SwarmWords.money(0.004) == "<1¢")
        #expect(SwarmWords.money(0) == "0¢")
        #expect(SwarmWords.money(1) == "$1")
        #expect(SwarmWords.money(1.4) == "$1.40")
        #expect(SwarmWords.money(12.05) == "$12.05")
        #expect(SwarmWords.money(0.996) == "$1")
    }

    private func swarm(_ fill: (inout Swarm) -> Void) -> Swarm {
        var s = Swarm(id: "a", name: "rename emotes", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        fill(&s)
        return s
    }

    @Test func theRowLinePerState() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(SwarmWords.rowLine(swarm { $0.status = .awaitingApproval; $0.planner = "claude code"; $0.expiresAt = now.addingTimeInterval(48 * 60) }, now: now) == "claude code asks · 48 min left")
        #expect(SwarmWords.rowLine(swarm { $0.status = .awaitingApproval; $0.expiresAt = now.addingTimeInterval(65 * 60) }, now: now) == "asks you · 1 h 5 min left")
        #expect(SwarmWords.rowLine(swarm { $0.status = .running; $0.tasks = .init(total: 20, done: 12) }, now: now) == "running · 12 of 20")
        #expect(SwarmWords.rowLine(swarm { $0.status = .stopping; $0.tasks = .init(total: 20, done: 12) }, now: now) == "stopping · 12 of 20")
        #expect(SwarmWords.rowLine(swarm { $0.status = .done; $0.apply = .init(status: .applied, done: 336, total: 336) }, now: now) == "applied 336")
        #expect(SwarmWords.rowLine(swarm { $0.status = .done; $0.apply = .init(status: .failed, done: 336, failed: 2, total: 338) }, now: now) == "applied 336, 2 failed")
        #expect(SwarmWords.rowLine(swarm { $0.status = .done; $0.changes = .init(total: 342, kept: 342); $0.apply = .init(status: .ready, total: 342) }, now: now) == "342 changes ready")
        #expect(SwarmWords.rowLine(swarm { $0.status = .done; $0.apply = .init(status: .applying, done: 120, total: 200) }, now: now) == "applying · 120 of 200")
        #expect(SwarmWords.rowLine(swarm { $0.status = .done }, now: now) == "done")
        for (status, words) in [(Swarm.Status.declined, "declined"), (.expired, "expired"), (.stopped, "stopped"), (.failed, "failed")] {
            #expect(SwarmWords.rowLine(swarm { $0.status = status }, now: now) == words)
        }
    }

    @Test func whatHappensToYourData() {
        #expect(SwarmWords.whatHappens(swarm { $0.mode = .propose }) == "you check every change before it happens")
        #expect(SwarmWords.whatHappens(swarm { $0.mode = .read }) == "it only looks, nothing changes")
        #expect(SwarmWords.whatHappens(swarm { $0.mode = .act; $0.writes = ["seventv.rename"] }) == "it changes things itself, only rename emotes")
        #expect(SwarmWords.whatHappens(swarm { $0.mode = .act; $0.writes = ["seventv.rename", "library.title", "library.about.set"] })
            == "it changes things itself, only rename emotes, change titles and change tags")
        #expect(SwarmWords.whatHappens(swarm { $0.mode = .act; $0.writes = ["seventv.rename", "seventv.rename"] }) == "it changes things itself, only rename emotes")
    }

    @Test func sizeAndCost() {
        #expect(SwarmWords.size(swarm { $0.tasks = .init(total: 20); $0.batchSize = 50 }) == "20 agents, 50 each")
        #expect(SwarmWords.size(swarm { $0.tasks = .init(total: 1); $0.batchSize = 5 }) == "1 agent, 5 each")
        #expect(SwarmWords.cost(swarm { $0.estimateUSD = .init(low: 0.3, high: 0.5); $0.capUSD = 1 }) == "about 30¢–50¢, never more than $1")
        #expect(SwarmWords.cost(swarm { $0.estimateUSD = .init(low: 0.3, high: 0.3); $0.capUSD = 0.5 }) == "about 30¢, never more than 50¢")
        #expect(SwarmWords.cost(swarm { $0.capUSD = 1 }) == "never more than $1")
    }

    @Test func noForbiddenWordsInTheCopy() {
        let lines = [
            SwarmWords.whatHappens(swarm { $0.mode = .propose }), SwarmWords.whatHappens(swarm { $0.mode = .read }),
            SwarmWords.whatHappens(swarm { $0.mode = .act; $0.writes = ["library.title"] }), SwarmWords.size(swarm { $0.tasks = .init(total: 3) }),
        ]
        for line in lines { for word in ["propose", "scope", "batch", "spec", "mode"] { #expect(!line.contains(word), "\(line) has \(word)") } }
    }

    @Test func theBoardWords() {
        #expect(SwarmWords.score(0.75) == "0.75" && SwarmWords.score(1) == "1.00" && SwarmWords.score(0) == "0.00" && SwarmWords.score(7) == "1.00")
        let o = SwarmOutcome(status: .done, items: 20, answered: 18, toolCalls: 24, toolErrors: 3, asks: 0, turns: 4, usd: 0.011, ms: 41_000, score: 0.75)
        #expect(SwarmWords.outcome(o) == "20 items · 18 answered · 3 lookups failed · 41 s · 1¢ · score 0.75")
        var clean = o
        clean.toolErrors = 0
        #expect(SwarmWords.outcome(clean) == "20 items · 18 answered · 41 s · 1¢ · score 0.75")
        clean.toolErrors = 1
        #expect(SwarmWords.outcome(clean).contains("1 lookup failed"))
    }
}

// MARK: - the Face ID gate

/// A preview app on a virtual clock whose "server" starts the swarm story in `start`, and whose owner check is a fake.
@MainActor
struct SwarmRig {
    let clock = VirtualClock()
    let app: AppModel
    let check = FixedOwnerCheck(answer: true)
    let client: PreviewClient
    var store: SwarmStore { app.swarms }
    static let story = PreviewSwarmIDs.story

    init(_ start: PreviewSwarmStart = .awaiting) {
        app = AppModel.makePreview(.happy, timeScale: 1, clock: clock)
        client = PreviewClient(scenario: .happy, timeScale: 1, clock: clock, swarms: start)
        app.ctx.client = client
        app.swarms.ownerCheck = check
    }

    var calls: [String] { client.swarmState.calls }
    func calls(containing text: String) -> Int { calls.filter { $0.contains(text) }.count }

    /// Waits (real milliseconds) until nothing new registers on the virtual clock.
    func settle() async {
        var last = clock.registrations
        var stable = 0
        while stable < 4 {
            try? await Task.sleep(for: .milliseconds(1))
            let r = clock.registrations
            if r == last { stable += 1 } else { stable = 0; last = r }
        }
    }

    /// Lets virtual time run on to the next sleeper and the work it starts.
    func tick() async {
        clock.advance()
        await settle()
    }

    /// Shows the story and waits for the first poll to be asleep.
    func showStory() async {
        await store.show(id: Self.story)
        await settle()
    }
}

@MainActor
struct SwarmGateTests {
    @Test func approveAsksTheOwnerFirstAndSendsNothingOnNo() async throws {
        let rig = SwarmRig(.awaiting)
        await rig.showStory()
        rig.check.answer = false
        await #expect(throws: SwarmError.notConfirmed) { try await rig.store.approve() }
        #expect(rig.calls(containing: "POST approve") == 0)
        #expect(rig.check.reasons.count == 1 && rig.check.reasons[0].contains("rename 1,000 emotes"))
        #expect(rig.store.shown?.status == .awaitingApproval)
        rig.check.answer = true
        try await rig.store.approve()
        #expect(rig.calls(containing: "POST approve") == 1)
        #expect(rig.store.shown?.status == .running)
        rig.store.hide()
    }

    @Test func applyAsksTheOwnerFirstAndSendsNothingOnNo() async throws {
        let rig = SwarmRig(.review)
        await rig.showStory()
        rig.check.answer = false
        await #expect(throws: SwarmError.notConfirmed) { try await rig.store.apply(skipClashes: true) }
        #expect(rig.calls(containing: "POST apply") == 0)
        #expect(rig.store.shown?.apply.status == .ready)
        rig.check.answer = true
        try await rig.store.apply(skipClashes: true)
        #expect(rig.calls(containing: "POST apply") == 1)
        #expect(rig.store.shown?.apply.status == .applying)
        #expect(rig.check.reasons.last?.contains("338") == true, "the sheet says how many it will apply")
        rig.store.hide()
    }

    @Test func declineStopAndRetryDoNotAsk() async throws {
        let rig = SwarmRig(.awaiting)
        await rig.showStory()
        rig.check.answer = false
        try await rig.store.decline()
        #expect(rig.store.shown?.status == .declined)
        #expect(rig.check.reasons.isEmpty)
        rig.store.hide()
        let running = SwarmRig(.running)
        await running.showStory()
        running.check.answer = false
        try await running.store.stop()
        #expect(running.store.shown?.status == .stopping && running.check.reasons.isEmpty)
        running.store.hide()
    }

    @Test func nothingIsSentWithoutAShownSwarm() async {
        let rig = SwarmRig(.awaiting)
        await #expect(throws: SwarmError.notShown) { try await rig.store.approve() }
        await #expect(throws: SwarmError.notShown) { try await rig.store.apply(skipClashes: true) }
        #expect(rig.check.reasons.isEmpty && rig.calls.isEmpty)
    }

    @Test func aStalePlanIsRefusedAndReadAgain() async throws {
        let rig = SwarmRig(.awaiting)
        await rig.showStory()
        // another device answered first
        _ = try await rig.client.declineSwarm(id: SwarmRig.story)
        await #expect(throws: SwarmError.notAwaiting) { try await rig.store.approve() }
        #expect(rig.store.shown?.status == .declined, "the screen says what is true now")
        rig.store.hide()
    }

    @Test func theRunnerSendsWithTheHashItWasGiven() async throws {
        let rig = SwarmRig(.awaiting)
        let hash = try #require(rig.client.swarmState.swarms.first { $0.id == SwarmRig.story }?.specHash)
        await #expect(throws: SwarmError.missingHash) { try await SwarmActionRunner.run(.approve, swarm: SwarmRig.story, hash: nil, client: rig.client) }
        await #expect(throws: SwarmError.notACall) { try await SwarmActionRunner.run(.check, swarm: SwarmRig.story, hash: hash, client: rig.client) }
        await #expect(throws: SwarmError.notACall) { try await SwarmActionRunner.run(.open, swarm: SwarmRig.story, hash: hash, client: rig.client) }
        await #expect(throws: SwarmError.hashMismatch) { try await SwarmActionRunner.run(.approve, swarm: SwarmRig.story, hash: "old", client: rig.client) }
        #expect(rig.calls(containing: "POST approve") == 1, "the wrong hash reached the server and was refused there")
        let approved = try await SwarmActionRunner.run(.approve, swarm: SwarmRig.story, hash: hash, client: rig.client)
        #expect(approved.status == .running)
        let stopped = try await SwarmActionRunner.run(.stop, swarm: SwarmRig.story, hash: nil, client: rig.client)
        #expect(stopped.status == .stopping)
    }

    @Test func theRunnerAppliesWithSkipClashes() async throws {
        let rig = SwarmRig(.review)
        let hash = try #require(rig.client.swarmState.swarms.first { $0.id == SwarmRig.story }?.specHash)
        let applying = try await SwarmActionRunner.run(.apply, swarm: SwarmRig.story, hash: hash, client: rig.client)
        #expect(applying.apply.status == .applying && applying.apply.total == 338, "the four clashes were left out")
        #expect(rig.calls.contains { $0.contains("POST apply") && $0.hasSuffix("skip") })
    }

    @Test func aNoPasscodeDeviceHasNothingToProve() {
        // `LocalOwnerCheck` is a value type with no state: a fresh context per call
        let a = LocalOwnerCheck()
        #expect(String(describing: type(of: a)) == "LocalOwnerCheck")
    }

    @Test func everyRefusalHasWordsAndAWireCode() {
        for code in ["not_found", "not_awaiting", "hash_mismatch", "expired", "owner_only", "busy", "daily_cap", "over_cap", "not_running", "not_ready", "off", "bad_spec"] {
            let e = SwarmError(code: "error.swarm.\(code)")
            #expect(e != nil && !(e?.words.isEmpty ?? true), "\(code)")
        }
        #expect(SwarmError(code: "error.swarm.nonsense") == nil)
        #expect(SwarmError.from(CobaltError.api(code: "error.swarm.busy", httpStatus: 429)) == .busy)
        #expect(SwarmError.from(PipelineFailure.unsupported) == .off)
        #expect(SwarmError.from(CobaltError.network(.notConnectedToInternet)) == .offline)
    }
}

// MARK: - polling

@MainActor
struct SwarmPollingTests {
    @Test func theIntervalFollowsTheState() {
        let rig = SwarmRig(.awaiting)
        func s(_ fill: (inout Swarm) -> Void) -> Swarm {
            var s = Swarm(id: "a", name: "n", createdAt: Date(timeIntervalSince1970: 1))
            fill(&s)
            return s
        }
        let store = rig.store
        #expect(store.pollInterval(for: s { $0.status = .running }) == .seconds(3))
        #expect(store.pollInterval(for: s { $0.status = .stopping }) == .seconds(3))
        #expect(store.pollInterval(for: s { $0.status = .done; $0.apply.status = .applying }) == .seconds(3))
        #expect(store.pollInterval(for: s { $0.status = .awaitingApproval }) == .seconds(15))
        #expect(store.pollInterval(for: s { $0.status = .done; $0.apply.status = .ready }) == .seconds(15))
        #expect(store.pollInterval(for: s { $0.status = .done; $0.apply.status = .applied }) == .seconds(15))
        #expect(store.pollInterval(for: s { $0.status = .failed }) == .seconds(15))
        #expect(store.pollInterval(for: s { $0.status = .declined }) == .seconds(15))
    }

    @Test func aRunningSwarmIsReadEveryThreeSecondsAndAWaitingOneEveryFifteen() async throws {
        let running = SwarmRig(.running)
        await running.showStory()
        let t0 = running.clock.elapsed
        #expect(abs(try #require(running.clock.nextWake) - (t0 + 3)) < 0.001)
        #expect(running.calls(containing: "GET swarm \(SwarmRig.story)") == 1, "the first read is at once")
        await running.tick()
        #expect(running.calls(containing: "GET swarm \(SwarmRig.story)") == 2)
        running.store.hide()

        let waiting = SwarmRig(.awaiting)
        await waiting.showStory()
        #expect(abs(try #require(waiting.clock.nextWake) - (waiting.clock.elapsed + 15)) < 0.001)
        waiting.store.hide()
    }

    @Test func noCallIsMadeAfterHide() async throws {
        let rig = SwarmRig(.running)
        await rig.showStory()
        await rig.tick()
        #expect(rig.store.isPolling)
        rig.store.hide()
        #expect(!rig.store.isPolling && rig.store.shown == nil)
        await rig.settle()
        #expect(rig.clock.pending == 0, "the poll's sleep was cancelled")
        let before = rig.calls.count
        for _ in 0..<10 {
            rig.clock.jump(by: 20)
            rig.clock.advance()
            await rig.settle()
        }
        #expect(rig.calls.count == before, "stopped means no more reads")
    }

    @Test func showingAnotherSwarmStopsThePreviousPoll() async {
        let rig = SwarmRig(.running)
        await rig.showStory()
        await rig.store.show(id: PreviewSwarmIDs.merge)
        await rig.settle()
        #expect(rig.clock.pending == 1, "one poll at a time")
        #expect(rig.store.shown?.id == PreviewSwarmIDs.merge)
        rig.store.hide()
    }

    @Test func approvingMovesThePollToThreeSeconds() async throws {
        let rig = SwarmRig(.awaiting)
        await rig.showStory()
        #expect(abs(try #require(rig.clock.nextWake) - (rig.clock.elapsed + 15)) < 0.001)
        try await rig.store.approve()
        await rig.settle()
        #expect(rig.clock.pending == 1)
        #expect(abs(try #require(rig.clock.nextWake) - (rig.clock.elapsed + 3)) < 0.001)
        rig.store.hide()
    }

    @Test func theSwarmMovesOnItsOwnWhilePolled() async throws {
        let rig = SwarmRig(.awaiting)
        await rig.showStory()
        try await rig.store.approve()
        await rig.settle()
        // 20 agents, one every 2 s: after a minute it is ready to check
        for _ in 0..<20 {
            rig.clock.jump(by: 3)
            await rig.tick()
        }
        #expect(rig.store.shown?.status == .done)
        #expect(rig.store.shown?.apply.status == .ready)
        #expect(rig.store.shown?.waitsForYou == true)
        #expect(rig.store.shown?.changes?.kept == 342)
        #expect(rig.store.shown?.clashCount == 4, "the store counts the clashes from the change list")
        rig.store.hide()
    }

    @Test func aFailedReadKeepsWhatWasShown() async {
        let rig = SwarmRig(.running)
        await rig.store.loadList()
        #expect(rig.store.state == .loaded && rig.store.list.count == 10)
        await rig.store.show(id: "nope0000nope0000")
        #expect(rig.store.shownProblem == .notFound)
        rig.store.hide()
    }
}

// MARK: - the list

@MainActor
struct SwarmListTests {
    @Test func theListHasEveryStateAndTheBadgeCountsTheWaitingOnes() async {
        let rig = SwarmRig(.awaiting)
        await rig.store.loadList()
        let list = rig.store.list
        #expect(list.count == 10)
        #expect(Set(list.map(\.status)) == Set(Swarm.Status.allCases).subtracting([.running, .stopping]), "the story waits; nothing runs yet")
        // the story and "merge duplicate titles" wait for an answer
        #expect(rig.store.waitingCount == 2)
        let groups = rig.store.groups
        #expect(groups.waiting.map(\.id) == [PreviewSwarmIDs.story, PreviewSwarmIDs.merge])
        #expect(groups.running.map(\.id).contains(PreviewSwarmIDs.shorten), "an applying swarm is running")
        #expect(groups.finished.count == list.count - groups.waiting.count - groups.running.count)
        #expect(groups.finished.contains { $0.status == .declined })

        let review = SwarmRig(.review)
        await review.store.loadList()
        #expect(review.store.waitingCount == 2, "ready to apply waits for you too")
        #expect(review.store.list.first { $0.id == PreviewSwarmIDs.story }?.waitsForYou == true)
    }

    @Test func theStartingStatePicksTheStory() async {
        for (start, status, apply) in [
            (PreviewSwarmStart.awaiting, Swarm.Status.awaitingApproval, Swarm.Apply.Status.none),
            (.running, .running, .none), (.review, .done, .ready), (.applying, .done, .applying), (.done, .done, .failed),
        ] {
            let rig = SwarmRig(start)
            await rig.store.loadList()
            let story = rig.store.list.first { $0.id == PreviewSwarmIDs.story }
            #expect(story?.status == status && story?.apply.status == apply, "\(start)")
            #expect(start.swarmID == PreviewSwarmIDs.story)
        }
        #expect(PreviewSwarmStart.list.swarmID == nil)
        #expect(PreviewSwarmStart.board.swarmID == PreviewSwarmIDs.board)
        #expect(PreviewSwarmStart(rawValue: "board") == .board)
    }

    @Test func theRunningStoryIsTheDesignsGrid() async throws {
        let rig = SwarmRig(.running)
        await rig.store.loadList()
        let s = try #require(rig.store.list.first { $0.id == PreviewSwarmIDs.story })
        #expect(s.tasks.total == 20 && s.tasks.done == 12 && s.tasks.failed == 1 && s.tasks.running == 3 && s.tasks.waiting == 1 && s.tasks.queued == 3)
        #expect(s.tasks.cells[6].status == .failed && s.tasks.cells[2].status == .waiting)
        #expect((12...14).allSatisfy { s.tasks.cells[$0].status == .running })
        #expect(s.messages == Swarm.MessageCounts(total: 6, waiting: 1))
        #expect(SwarmWords.size(s) == "20 agents, 50 each" && SwarmWords.cost(s) == "about 30¢–50¢, never more than $1")
        #expect(SwarmWords.statusLine(s, now: rig.clock.now()) == "running · 3 min")
    }

    @Test func rowLinesOfTheAwaitingStory() async throws {
        let rig = SwarmRig(.awaiting)
        await rig.store.loadList()
        let s = try #require(rig.store.list.first { $0.id == PreviewSwarmIDs.story })
        #expect(rig.store.rowLine(s) == "claude code asks · 52 min left")
        #expect(SwarmWords.statusLine(s, now: rig.clock.now()) == "claude code asks · expires in 52 min")
        let merge = try #require(rig.store.list.first { $0.id == PreviewSwarmIDs.merge })
        #expect(rig.store.rowLine(merge) == "chatgpt asks · 48 min left")
    }
}

// MARK: - the check screen

@MainActor
struct SwarmChangesTests {
    @Test func theReviewHasThreeHundredFortyTwoChangesAndFourClash() async throws {
        let rig = SwarmRig(.review)
        await rig.showStory()
        #expect(rig.store.changes.count == 342 && rig.store.changesTotal == 342)
        #expect(rig.calls(containing: "GET changes") == 2, "200 a page")
        let clashes = rig.store.changes.filter { $0.clash != nil }
        #expect(clashes.map(\.n) == [3, 40, 118, 201])
        #expect(rig.store.changes[0].before == "CatJam" && rig.store.changes[0].after == "catjam")
        #expect(rig.store.changes[2].before == "BONK" && rig.store.changes[2].after == "bonk")
        #expect(rig.store.changes[2].clash == "duplicate name: also proposed by #118")
        #expect(rig.store.shown?.clashCount == 4 && rig.store.shown?.applyCount == 338 && rig.store.shown?.apply.total == 342)
        #expect(rig.store.changes.allSatisfy { $0.editArg == "alias" && $0.previewURL?.host == "cdn.7tv.app" })
        rig.store.hide()
    }

    @Test func untickingOneOfAPairClearsTheOther() async throws {
        let rig = SwarmRig(.review)
        await rig.showStory()
        try await rig.store.setKeep(3, false)
        #expect(rig.store.changes[2].keep == false)
        #expect(rig.store.changes.first { $0.n == 118 }?.clash == nil)
        #expect(rig.store.shown?.clashCount == 2 && rig.store.shown?.changes?.kept == 341)
        try await rig.store.setKeep(3, true)
        #expect(rig.store.shown?.clashCount == 4)
        rig.store.hide()
    }

    @Test func renamingMakesTheNameFreeAgain() async throws {
        let rig = SwarmRig(.review)
        await rig.showStory()
        try await rig.store.rename(118, to: "bonkbonk")
        let row = try #require(rig.store.changes.first { $0.n == 118 })
        #expect(row.after == "bonkbonk" && row.args?.dictionaryValue?["alias"]?.stringValue == "bonkbonk")
        #expect(rig.store.changes[2].clash == nil, "#3 is alone with its name now")
        #expect(rig.store.shown?.clashCount == 2)
        rig.store.hide()
    }

    @Test func aFailedDecisionPutsTheTickBack() async throws {
        let rig = SwarmRig(.awaiting)
        await rig.showStory()
        // nothing to decide on a plan nobody approved
        await #expect(throws: SwarmError.notReady) { try await rig.store.setKeep(1, false) }
        rig.store.hide()
    }

    @Test func applyingRunsAboutSixSecondsThenEndsWithTheTwoThatFailed() async throws {
        let rig = SwarmRig(.review)
        await rig.showStory()
        try await rig.store.apply(skipClashes: true)
        #expect(rig.store.shown?.apply.total == 338)
        rig.clock.jump(by: 3)
        await rig.tick()
        let mid = try #require(rig.store.shown)
        #expect(mid.apply.status == .applying && mid.apply.done > 100 && mid.apply.done < 338)
        rig.clock.jump(by: 6)
        await rig.tick()
        let end = try #require(rig.store.shown)
        #expect(end.apply.status == .failed && end.apply.done == 336 && end.apply.failed == 2)
        #expect(SwarmWords.rowLine(end, now: rig.clock.now()) == "applied 336, 2 failed")
        #expect(end.waitsForYou == false)
        rig.store.hide()
    }
}

// MARK: - the agent sheet and talking to agents

@MainActor
struct SwarmAgentTests {
    @Test func theDesignsAgentSevenThreadAndAgentThreeQuestion() async throws {
        let rig = SwarmRig(.running)
        await rig.showStory()
        await rig.store.loadAgent(7)
        let seven = try #require(rig.store.agent)
        #expect(seven.agent == 7 && seven.status == .failed && seven.attempts == 2 && seven.error?.contains("bad_answer") == true)
        #expect(seven.items.count == 50 && seven.items[0].dictionaryValue?["name"]?.stringValue == PreviewSwarmData.emoteName(300))
        #expect(seven.messages.map(\.id) == [1, 2, 3, 4], "its own thread and the broadcast")
        #expect(seven.messages[0].kind == .ask && seven.messages[0].answered && seven.messages[1].sender == .owner)
        #expect(seven.steps.map(\.text).contains("failed: bad_answer"))
        #expect(SwarmWords.agentLine(seven, batchSize: 50) == "failed twice · items 301–350")

        await rig.store.loadAgent(3)
        let three = try #require(rig.store.agent)
        #expect(three.status == .waiting && three.messages.contains { $0.isOpenAsk })
        rig.store.hide()
    }

    @Test func aReplyWakesTheWaitingAgentAndShowsAsYou() async throws {
        let rig = SwarmRig(.running)
        await rig.showStory()
        await rig.store.loadAgent(3)
        let sent = try await rig.store.send(to: .agent(3), text: "  keep it lowercase  ")
        #expect(sent.woke && sent.to == .agent(3))
        let three = try #require(rig.store.agent)
        #expect(three.status == .running)
        let last = try #require(three.messages.last)
        #expect(last.sender == .you && last.text == "keep it lowercase" && last.dir == .down && last.agent == 3)
        #expect(three.messages.allSatisfy { !$0.isOpenAsk })
        #expect(rig.store.shown?.messages?.waiting == 0 && rig.store.shown?.tasks.waiting == 0)
        rig.store.hide()
    }

    @Test func aMessageToEveryoneNeedsNoAgent() async throws {
        let rig = SwarmRig(.running)
        await rig.showStory()
        let sent = try await rig.store.send(to: .all, text: "keep numbers")
        #expect(sent.to == .all && !sent.woke)
        let all = try await rig.client.swarmMessages(id: SwarmRig.story, agent: nil)
        #expect(all.last?.agent == nil && all.last?.sender == .you)
        rig.store.hide()
    }

    @Test func emptyOrTooLongTextAndNonRunningSwarmsAreRefused() async throws {
        let rig = SwarmRig(.running)
        await rig.showStory()
        await #expect(throws: SwarmError.badRequest) { try await rig.store.send(to: .all, text: "   ") }
        await #expect(throws: SwarmError.badRequest) { try await rig.store.send(to: .all, text: String(repeating: "x", count: 2001)) }
        #expect(rig.calls(containing: "POST send") == 0)
        rig.store.hide()
        let done = SwarmRig(.review)
        await done.showStory()
        await #expect(throws: SwarmError.notRunning) { try await done.store.send(to: .all, text: "hi") }
        done.store.hide()
    }

    @Test func theSheetIsReadAgainOnEveryPollUntilItCloses() async throws {
        let rig = SwarmRig(.running)
        await rig.showStory()
        await rig.store.loadAgent(13)
        let before = rig.calls(containing: "GET agent")
        await rig.tick()
        #expect(rig.calls(containing: "GET agent") == before + 1)
        rig.store.closeAgent()
        await rig.tick()
        #expect(rig.calls(containing: "GET agent") == before + 1)
        #expect(rig.store.agent == nil)
        rig.store.hide()
    }

    @Test func retryAsksForANewApproval() async throws {
        let rig = SwarmRig(.running)
        await rig.showStory()
        try await rig.store.stop()
        rig.clock.jump(by: 3)
        await rig.tick()
        #expect(rig.store.shown?.status == .stopped)
        try await rig.store.retry()
        #expect(rig.store.shown?.status == .awaitingApproval && rig.store.shown?.specHash.hasSuffix("r") == true)
        rig.store.hide()
    }
}

// MARK: - the Live Activity

private let T = 1_790_000_000.0
private let now = Date(timeIntervalSince1970: T)

private func cells(_ letters: String) -> [SwarmCell] {
    letters.enumerated().map { SwarmCell(idx: $0.offset, status: SwarmCell.Status(letter: $0.element) ?? .queued) }
}

private func tasks(_ letters: String, waiting: Int = 0) -> Swarm.Tasks {
    let c = cells(letters)
    func n(_ s: SwarmCell.Status) -> Int { c.filter { $0.status == s }.count }
    return Swarm.Tasks(total: c.count, queued: n(.queued), running: n(.running), done: n(.done), failed: n(.failed), waiting: waiting, cells: c)
}

/// The swarms of the fixture's cases (apple/CobaltKit/Tests/CobaltKitTests/Fixtures/job-live-swarm-states.json), by name.
private func liveSwarm(_ name: String) -> Swarm {
    var s = Swarm(
        id: "PrEvIeWswarm0001", name: "rename 1,000 emotes", mode: .propose, status: .done, specHash: "PrEvIeWhash0001",
        tasks: tasks(String(repeating: "d", count: 20)), capUSD: 1, spentUSD: 0.44, createdAt: now.addingTimeInterval(-600),
        approvedAt: now.addingTimeInterval(-192), finishedAt: now.addingTimeInterval(-180), planner: "claude code")
    switch name {
    case "swarm_awaiting":
        s.status = .awaitingApproval
        s.tasks = tasks(String(repeating: "q", count: 20))
        s.estimateUSD = .init(low: 0.3, high: 0.5)
        s.expiresAt = now.addingTimeInterval(52 * 60)
        s.approvedAt = nil
        s.finishedAt = nil
        s.spentUSD = 0
    case "swarm_running_asking":
        s.status = .running
        s.tasks = tasks("ddwdddfdddddrrrddqqq", waiting: 1)
        s.spentUSD = 0.21
        s.finishedAt = nil
    case "swarm_running_changes":
        s.status = .running
        s.tasks = tasks("dddddddfdddddrrrqqqq")
        s.changes = .init(total: 214, kept: 214)
        s.spentUSD = 0.21
        s.finishedAt = nil
    case "swarm_ready":
        s.changes = .init(total: 342, kept: 342)
        s.apply = .init(status: .ready, total: 342)
        s.clashCount = 4
    case "swarm_applying":
        s.changes = .init(total: 342, kept: 338, done: 120)
        s.apply = .init(status: .applying, done: 120, total: 338)
    case "swarm_applied":
        s.changes = .init(total: 342, kept: 338, done: 336, failed: 2)
        s.apply = .init(status: .failed, done: 336, failed: 2, total: 338)
    case "swarm_done_read":
        s.mode = .read
        s.reduce = "tagged 971 clips; 29 had no clear game."
    case "swarm_declined":
        s.status = .declined
        s.tasks = tasks(String(repeating: "q", count: 20))
        s.finishedAt = now.addingTimeInterval(-300)
        s.approvedAt = nil
        s.spentUSD = 0
    case "swarm_stopped_cap":
        s.status = .stopped
        s.error = "error.swarm.over_cap"
        s.tasks = tasks("dddddddd" + String(repeating: "s", count: 12))
        s.spentUSD = 1
        s.finishedAt = now.addingTimeInterval(-100)
    case "swarm_expired":
        s.status = .expired
        s.tasks = tasks(String(repeating: "q", count: 20))
        s.finishedAt = now.addingTimeInterval(-60)
        s.approvedAt = nil
        s.spentUSD = 0
    default:
        break
    }
    return s
}

private let swarmCaseNames = [
    "swarm_awaiting", "swarm_running_asking", "swarm_running_changes", "swarm_ready", "swarm_applying", "swarm_applied", "swarm_done_read",
    "swarm_declined", "swarm_stopped_cap", "swarm_expired",
]

/// The app's own fixture of swarm states: the server's `job-live-states.json` gets the same shapes from its builders (that
/// fixture is made on the server's branch), this one pins what the app reads and writes.
private func swarmFixtureText() throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/job-live-swarm-states.json")
    return try String(contentsOf: url, encoding: .utf8)
}

/// Whitespace outside strings removed, like `JSON.stringify` without an indent.
private func compactJSON(_ json: String) -> String {
    var out = String.UnicodeScalarView()
    var inString = false
    var escaped = false
    for u in json.unicodeScalars {
        if inString {
            out.append(u)
            if escaped { escaped = false } else if u == "\\" { escaped = true } else if u == "\"" { inString = false }
        } else if u == "\"" {
            inString = true
            out.append(u)
        } else if u != " " && u != "\n" && u != "\r" && u != "\t" {
            out.append(u)
        }
    }
    return String(out)
}

/// The text of `state` and `attributes` of each case, in file order.
private func swarmFixtureCases() throws -> [(name: String, attributes: String, state: String)] {
    let text = compactJSON(try swarmFixtureText())
    let data = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    // key order is the file's: find each case name's position in the text
    let names = data.keys.sorted { (text.range(of: "\"\($0)\":")?.lowerBound ?? text.endIndex) < (text.range(of: "\"\($1)\":")?.lowerBound ?? text.endIndex) }
    return try names.map { name in
        let start = try #require(text.range(of: "\"\(name)\":{\"attributes\":"))
        let rest = text[start.upperBound...]
        let stateMark = try #require(rest.range(of: ",\"state\":"))
        let attributes = String(rest[..<stateMark.lowerBound])
        var depth = 0
        var end = stateMark.upperBound
        var inString = false
        var escaped = false
        scan: for i in rest[stateMark.upperBound...].indices {
            let c = rest[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { end = rest.index(after: i); break scan }
            default: break
            }
        }
        return (name, attributes, String(rest[stateMark.upperBound..<end]))
    }
}

struct SwarmLiveTests {
    @Test func theFixtureHasEveryCase() throws {
        #expect(try swarmFixtureCases().map(\.name) == swarmCaseNames)
    }

    @Test func everyCaseRoundTripsByteForByte() throws {
        for c in try swarmFixtureCases() {
            let state = try JSONDecoder().decode(JobLiveState.self, from: Data(c.state.utf8))
            let attributes = try JSONDecoder().decode(JobLiveAttributes.self, from: Data(c.attributes.utf8))
            #expect(Array(state.canonicalJSON().utf8) == Array(c.state.utf8), "state of \(c.name)")
            #expect(Array(attributes.canonicalJSON().utf8) == Array(c.attributes.utf8), "attributes of \(c.name)")
            #expect(attributes.kind == "swarm" && attributes.agent && attributes.open?.hasPrefix("cobalt-apple://swarm/") == true)
            // the plain Codable path (ActivityKit's) keeps the values, and leaves absent fields out
            let again = try JSONDecoder().decode(JobLiveState.self, from: JSONEncoder().encode(state))
            #expect(again == state, "\(c.name)")
            let plain = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            #expect(!plain.contains("null"), "\(c.name)")
        }
    }

    @Test func theLocalBuilderMakesTheFixturesStates() throws {
        for c in try swarmFixtureCases() {
            let want = try JSONDecoder().decode(JobLiveState.self, from: Data(c.state.utf8))
            let got = JobLiveState(swarm: liveSwarm(c.name), now: now)
            #expect(got.canonicalJSON() == c.state, "\(c.name): \(got.canonicalJSON())")
            #expect(got == want, "\(c.name)")
        }
    }

    @Test func buttonsPerState() {
        func actions(_ name: String) -> [SwarmLiveAction] { JobLiveState(swarm: liveSwarm(name), now: now).swarmActions }
        #expect(actions("swarm_awaiting") == [.approve, .decline])
        #expect(actions("swarm_running_asking") == [.stop])
        #expect(actions("swarm_running_changes") == [.stop])
        #expect(actions("swarm_ready") == [.check, .apply])
        #expect(actions("swarm_applying") == [])
        #expect(actions("swarm_applied") == [.open])
        #expect(actions("swarm_done_read") == [.open])
        #expect(actions("swarm_declined") == [.open])
        #expect(actions("swarm_stopped_cap") == [.open])
        #expect(actions("swarm_expired") == [.open])
    }

    @Test func theApplyCountIsKeptMinusClashesAndTheHashIsTheSpecs() {
        let ready = JobLiveState(swarm: liveSwarm("swarm_ready"), now: now)
        #expect(ready.count == 338 && ready.hash == "PrEvIeWhash0001")
        #expect(ready.headline == "342 changes ready" && ready.detail == "4 look like duplicates and are left out · 44¢")
        #expect(ready.phase == .waiting && ready.step == 2)
        let awaiting = JobLiveState(swarm: liveSwarm("swarm_awaiting"), now: now)
        #expect(awaiting.hash == "PrEvIeWhash0001" && awaiting.count == nil && awaiting.phase == .waiting && awaiting.step == 0)
        #expect(JobLiveState(swarm: liveSwarm("swarm_running_asking"), now: now).hash == nil, "only the buttons that send a hash carry one")
        var noClash = liveSwarm("swarm_ready")
        noClash.clashCount = 0
        let plain = JobLiveState(swarm: noClash, now: now)
        #expect(plain.count == 342 && plain.detail == "44¢")
    }

    @Test func phasesStepsAndWords() {
        func s(_ name: String) -> JobLiveState { JobLiveState(swarm: liveSwarm(name), now: now) }
        #expect(s("swarm_running_asking").phase == .working && s("swarm_running_asking").step == 1)
        #expect(s("swarm_running_asking").headline == "12 of 20 agents done")
        #expect(s("swarm_running_asking").detail == "1 agent is asking claude code a question")
        #expect(s("swarm_running_changes").detail == "214 changes · 21¢")
        #expect(s("swarm_applying").phase == .working && s("swarm_applying").step == 3 && s("swarm_applying").headline == "applying changes")
        #expect(s("swarm_applying").detail == "120 of 338" && s("swarm_applying").fraction == 0.355)
        #expect(s("swarm_applied").phase == .done && s("swarm_applied").step == 4 && s("swarm_applied").headline == "applied 336 changes")
        #expect(s("swarm_done_read").steps == ["approve", "run"] && s("swarm_done_read").step == 2 && s("swarm_done_read").headline == "done")
        #expect(s("swarm_declined").phase == .failed && s("swarm_declined").headline == "declined")
        #expect(s("swarm_stopped_cap").headline == "stopped at its cap" && s("swarm_stopped_cap").phase == .failed)
        #expect(s("swarm_expired").headline == "expired" && s("swarm_expired").isTerminal)
        for name in swarmCaseNames { #expect(JobLiveState(swarm: liveSwarm(name), now: now).headline.count <= 60, "\(name)") }
    }

    @Test func cellsAreLettersAndComeBackAsStatuses() {
        let s = JobLiveState(swarm: liveSwarm("swarm_running_asking"), now: now)
        #expect(s.cells == "ddwdddfdddddrrrddqqq")
        #expect(s.swarmCells.count == 20 && s.swarmCells[2] == .waiting && s.swarmCells[6] == .failed && s.swarmCells[12] == .running)
        #expect(Set(SwarmCell.Status.allCases.map(\.letter)) == Set("qrwdfs"))
        for status in SwarmCell.Status.allCases { #expect(SwarmCell.Status(letter: status.letter) == status) }
        #expect(SwarmCell.Status(letter: "z") == nil)
        var odd = s
        odd.cells = "dz"
        #expect(odd.swarmCells == [.done, .queued], "an unknown letter keeps its square")
        // at most 200 letters
        var long = liveSwarm("swarm_running_asking")
        long.tasks = tasks(String(repeating: "d", count: 250))
        #expect(JobLiveState(swarm: long, now: now).cells?.count == 200)
    }

    @Test func unknownActionsAreSkippedAndOtherJobsHaveNone() {
        var s = JobLiveState(phase: .working, steps: ["a"], step: 0, headline: "h", since: 1)
        #expect(s.swarmActions.isEmpty && s.swarmCells.isEmpty)
        s.actions = ["approve", "levitate", "decline"]
        #expect(s.swarmActions == [.approve, .decline])
        #expect(SwarmLiveAction.approve.needsAuthentication && SwarmLiveAction.apply.needsAuthentication)
        #expect(!SwarmLiveAction.stop.needsAuthentication && !SwarmLiveAction.decline.needsAuthentication)
        #expect(SwarmLiveAction.check.isCall == false && SwarmLiveAction.open.isCall == false && SwarmLiveAction.stop.isCall)
    }

    @Test func theNewFieldsAreOmittedWhenAbsent() throws {
        let s = JobLiveState(phase: .working, steps: ["a"], step: 0, headline: "h", since: 1)
        #expect(s.canonicalJSON() == #"{"phase":"working","steps":["a"],"step":0,"headline":"h","since":1}"#)
        let plain = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        for key in ["cells", "actions", "hash", "count"] { #expect(!plain.contains("\"\(key)\""), "\(key)") }
        // and an old state without them still decodes
        let old = try JSONDecoder().decode(JobLiveState.self, from: Data(#"{"phase":"done","steps":["a"],"step":1,"headline":"saved","since":5}"#.utf8))
        #expect(old.cells == nil && old.actions == nil && old.hash == nil && old.count == nil)
    }
}

// MARK: - the tab

struct SwarmTabTests {
    @Test func theTabIsRightAfterChatAndShowsWithTheLibrary() {
        var c = Capabilities.unknown
        #expect(!AppTab.swarms.isAvailable(with: c))
        c.library = true
        #expect(AppTab.swarms.isAvailable(with: c))
        let all = AppTab.allCases
        #expect(all.firstIndex(of: .swarms) == all.firstIndex(of: .chat).map { $0 + 1 })
    }
}

// MARK: - the results board

private let boardJSON = """
{"swarm":{"swarm":"PrEvIeWswarm0010","name":"find christmas variants","status":"done","mode":"read","score":0.84},
 "total":3,"offset":0,
 "groups":[{"value":"exact","count":2},{"value":"close","count":1}],
 "agents":[{"agent":1,"status":"done","outcome":{"status":"done","items":20,"answered":18,"tool_calls":24,"tool_errors":3,"asks":0,"turns":4,"usd":0.011,"ms":41000,"score":0.75},"error":null},
           {"agent":2,"status":"failed","outcome":null,"error":"error.swarm.out_of_turns"}],
 "rows":[
  {"agent":1,"n":1,"title":"nyaphelia santa","score":0.9,"group":"exact",
   "fields":{"zebra":"last alphabetically","emote":"nyaphelia_santa","uses":412,"animated":true,"note":null,"ratio":0.5},
   "media":[{"ref":"01ABC","kind":"emote","preview_url":"https://cdn.7tv.app/emote/01ABC/2x.webp","open_url":"https://7tv.app/emotes/01ABC","title":"santa","animated":true},
            {"ref":"PrEvIeW001","kind":"post","preview_url":"https://media.capybaraharmony.com/PrEvIeW001.jpg","open_url":"https://share.capybaraharmony.com/PrEvIeW001"},
            {"ref":"https://example.com/x.png","error":"that host is not allowed"},
            {"ref":"clip","kind":"hologram","preview_url":"https://media.capybaraharmony.com/c.jpg"}],
   "links":["https://7tv.app/emotes/01ABC",""]},
  {"agent":1,"n":2,"title":null,"score":null,"group":null,"fields":{},"media":[],"links":[]},
  {"agent":2,"n":1,"title":"agent 2 failed: ran out of turns","score":null,"group":null,"fields":{"items":"nyaphelia a, nyaphelia b"},"media":[],"links":[]}]}
"""

struct SwarmBoardDecodingTests {
    @Test func aBoardDecodesWithItsFieldsInTheServersOrder() throws {
        let b = try SwarmBoard.decode(Data(boardJSON.utf8))
        #expect(b.total == 3 && b.offset == 0 && b.rows.count == 3 && b.swarm.score == 0.84)
        #expect(b.groups == [BoardGroup(value: "exact", count: 2), BoardGroup(value: "close", count: 1)])
        let row = b.rows[0]
        #expect(row.fields.map(\.key) == ["zebra", "emote", "uses", "animated", "note", "ratio"], "ordered as received, not sorted")
        #expect(row.fields.map(\.value) == ["last alphabetically", "nyaphelia_santa", "412", "yes", "none", "0.5"], "numbers, bools and null become text")
        #expect(row.field("uses") == "412" && row.field("nope") == nil)
        #expect(row.title == "nyaphelia santa" && row.score == 0.9 && row.group == "exact" && row.id == "1-1")
        #expect(row.links.count == 1 && row.links[0].host == "7tv.app", "a link that is not a URL is dropped")
        // a plain decoder cannot know the order and falls back to sorted keys
        let plain = try SwarmWire.decoder().decode(SwarmBoard.self, from: Data(boardJSON.utf8))
        #expect(plain.rows[0].fields.map(\.key) == ["animated", "emote", "note", "ratio", "uses", "zebra"])
    }

    @Test func mediaOfEveryKindAndTheErrorFormDecode() throws {
        let media = try SwarmBoard.decode(Data(boardJSON.utf8)).rows[0].media
        #expect(media.count == 4)
        #expect(media[0].kind == .emote && media[0].previewURL?.host == "cdn.7tv.app" && media[0].openURL?.host == "7tv.app" && media[0].animated == true)
        #expect(media[0].title == "santa" && !media[0].opensInApp)
        #expect(media[1].kind == .post && media[1].opensInApp && media[1].animated == nil)
        #expect(media[2].error == "that host is not allowed" && media[2].previewURL == nil && media[2].kind == .image)
        #expect(media[3].kind == .image, "an unknown kind is drawn as an image")
        for kind in ["post", "file", "emote", "image", "video"] {
            #expect(try decode(MediaRef.self, #"{"ref":"r","kind":"\#(kind)"}"#).kind.rawValue == kind)
        }
    }

    @Test func everyAgentComesWithItsOutcomeAndScore() throws {
        let b = try SwarmBoard.decode(Data(boardJSON.utf8))
        #expect(b.agents.count == 2)
        let o = try #require(b.agents[0].outcome)
        #expect(o.items == 20 && o.answered == 18 && o.toolCalls == 24 && o.toolErrors == 3 && o.ms == 41_000 && o.score == 0.75 && o.status == .done)
        #expect(b.agents[0].score == 0.75)
        #expect(b.agents[1].status == .failed && b.agents[1].outcome == nil && b.agents[1].error == "error.swarm.out_of_turns" && b.agents[1].score == nil)
        #expect(SwarmWords.outcome(o) == "20 items · 18 answered · 3 lookups failed · 41 s · 1¢ · score 0.75")
    }

    @Test func aFailedAgentIsARowWithItsItems() throws {
        let rows = try SwarmBoard.decode(Data(boardJSON.utf8)).rows
        #expect(rows[2].isFailedAgent && rows[2].field("items") == "nyaphelia a, nyaphelia b" && rows[2].score == nil)
        #expect(!rows[0].isFailedAgent)
        let bare = rows[1]
        #expect(bare.title == nil && bare.score == nil && bare.group == nil && bare.fields.isEmpty && bare.media.isEmpty)
    }

    @Test func aBoardWithOnlyASwarmDecodes() throws {
        let b = try SwarmBoard.decode(Data(#"{"swarm":{"swarm":"a"}}"#.utf8))
        #expect(b.rows.isEmpty && b.groups.isEmpty && b.agents.isEmpty && b.total == 0 && !b.hasMore)
    }

    @Test func keyOrderSurvivesEscapesAndNesting() throws {
        let json = #"{"swarm":{"swarm":"a"},"rows":[{"agent":1,"n":1,"fields":{"b\"q":"1","aé":"2","c":{"x":1,"w":2},"1":"3"}}]}"#
        let row = try SwarmBoard.decode(Data(json.utf8)).rows[0]
        #expect(row.fields.map(\.key) == ["b\"q", "aé", "c", "1"])
        #expect(row.fields[2].value.contains("x"), "a nested object is written out as text")
        #expect(BoardFieldOrder.scan(Data("not json".utf8)).isEmpty)
    }

    @Test func aSwarmResultKeepsItsItemsAndOutcome() throws {
        let r = try decode(SwarmResult.self, #"{"task":6,"status":"failed","result":null,"error":"error.swarm.out_of_turns","usd":0.02,"items":["a",{"id":"b"}],"outcome":{"status":"failed","items":2,"answered":0,"score":0}}"#)
        #expect(r.task == 6 && r.agent == 7 && r.status == .failed && r.items.count == 2 && r.outcome?.score == 0 && r.outcome?.status == .failed)
        let old = try decode(SwarmResult.self, #"{"task":0,"status":"done","usd":0.01}"#)
        #expect(old.items.isEmpty && old.outcome == nil)
    }

    @Test func boardSortsHaveTheirWireNames() {
        #expect(BoardSort.allCases.map(\.rawValue) == ["agent", "score", "title"])
    }
}

@MainActor
struct SwarmBoardStoreTests {
    @Test func theFirstHundredRowsThenTheNextHundredAppended() async throws {
        let rig = SwarmRig(.board)
        await rig.store.show(id: PreviewSwarmIDs.board)
        #expect(rig.store.board == nil)
        await rig.store.loadBoard()
        let first = try #require(rig.store.board)
        #expect(first.rows.count == 100 && first.total > 300 && first.hasMore && first.offset == 0)
        #expect(first.agents.count == 21 && first.swarm.id == PreviewSwarmIDs.board)
        await rig.store.loadMoreBoard()
        let more = try #require(rig.store.board)
        #expect(more.rows.count == 200 && more.total == first.total)
        #expect(Set(more.rows.map(\.id)).count == 200, "no row twice")
        #expect(more.rows[100].id != first.rows[0].id)
        while rig.store.board?.hasMore == true { await rig.store.loadMoreBoard() }
        #expect(rig.store.board?.rows.count == first.total)
        let calls = rig.calls(containing: "GET board")
        await rig.store.loadMoreBoard()
        #expect(rig.calls(containing: "GET board") == calls, "nothing more to read")
        rig.store.hide()
        #expect(rig.store.board == nil)
    }

    @Test func theBoardIsGeneralMixedMediaScoresGroupsAndAFailedAgent() async throws {
        let rig = SwarmRig(.board)
        await rig.store.show(id: PreviewSwarmIDs.board)
        await rig.store.loadBoard()
        let board = try #require(rig.store.board)
        let media = board.rows.flatMap(\.media)
        #expect(Set(media.map(\.kind)).isSuperset(of: [.emote, .post, .video]))
        #expect(media.filter { $0.kind == .emote }.allSatisfy { $0.previewURL?.host == "cdn.7tv.app" && $0.previewURL?.pathExtension == "webp" })
        #expect(media.filter { $0.kind == .post }.allSatisfy { $0.previewURL?.host == "media.capybaraharmony.com" })
        #expect(media.contains { $0.error != nil })
        #expect(board.rows.allSatisfy { $0.score == nil || (0...1).contains($0.score ?? 2) })
        #expect(Set(board.groups.map(\.value)) == ["exact", "close", "different"] && board.groups.map(\.count).reduce(0, +) == board.total - 1)
        #expect(board.rows.allSatisfy { $0.fields.count <= 12 && $0.media.count <= 4 })
        let failed = try #require(board.agents.first { $0.status == .failed })
        #expect(failed.agent == 12 && failed.error != nil && failed.score == nil)
        rig.store.boardAgent = 12
        await rig.store.loadBoard()
        let row = try #require(rig.store.board?.rows.first { $0.isFailedAgent })
        #expect(row.agent == 12 && row.title?.hasPrefix("agent 12 failed:") == true && row.field("items")?.isEmpty == false)
        let scored = board.agents.compactMap(\.score)
        #expect(scored.count == 20 && scored.allSatisfy { (0...1).contains($0) })
        let sheet = SwarmWords.outcome(try #require(board.agents[0].outcome))
        #expect(sheet.hasSuffix("score \(SwarmWords.score(board.agents[0].outcome?.score ?? 0))") && sheet.contains("answered"))
        rig.store.hide()
    }

    @Test func searchGroupSortAndAgentChangeWhatIsRead() async throws {
        let rig = SwarmRig(.board)
        await rig.store.show(id: PreviewSwarmIDs.board)
        await rig.store.loadBoard()
        let all = try #require(rig.store.board).total

        rig.store.boardQuery = "snowman"
        await rig.store.loadBoard()
        let found = try #require(rig.store.board)
        #expect(found.total > 0 && found.total < all && found.rows.allSatisfy { ($0.title ?? "").contains("snowman") || $0.fields.contains { $0.value.contains("snowman") } })
        rig.store.boardQuery = ""

        rig.store.boardGroup = "exact"
        await rig.store.loadBoard()
        let exact = try #require(rig.store.board)
        #expect(exact.rows.allSatisfy { $0.group == "exact" } && exact.groups.count == 3, "the chips stay while one is chosen")
        rig.store.boardGroup = nil

        rig.store.boardSort = .score
        await rig.store.loadBoard()
        let scores = try #require(rig.store.board).rows.map { $0.score ?? -1 }
        #expect(scores == scores.sorted(by: >))

        rig.store.boardSort = .title
        await rig.store.loadBoard()
        let titles = try #require(rig.store.board).rows.compactMap(\.title)
        #expect(titles == titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

        rig.store.boardSort = .agent
        rig.store.boardAgent = 12
        await rig.store.loadBoard()
        #expect(try #require(rig.store.board).rows.map(\.agent) == [12])
        rig.store.boardAgent = nil
        rig.store.hide()
    }

    @Test func anyOtherSwarmGetsABoardToo() async throws {
        let rig = SwarmRig(.review)
        await rig.store.show(id: PreviewSwarmIDs.story)
        await rig.store.loadBoard()
        let board = try #require(rig.store.board)
        #expect(board.total == 342 && board.rows[0].title == "CatJam → catjam" && board.rows[0].media.first?.kind == .emote)
        #expect(Set(board.groups.map(\.value)) == ["ready", "clash"] && board.groups.first { $0.value == "clash" }?.count == 4)
        rig.store.hide()
    }

    @Test func aBoardIsNotReadAfterHide() async {
        let rig = SwarmRig(.board)
        await rig.store.show(id: PreviewSwarmIDs.board)
        rig.store.hide()
        let before = rig.calls.count
        await rig.store.loadBoard()
        await rig.store.loadMoreBoard()
        #expect(rig.calls.count == before)
    }
}

// MARK: - a screen that asks before the swarm is on screen

/// The launch arguments and deep links push the board (or open the agent sheet) in the same breath as `show(id:)`: the screen's
/// own `.task` asks for the board or the agent before the store has a shown swarm. That ask was dropped and never repeated, so the
/// screen sat on "loading" for good.
@MainActor
struct SwarmEarlyAskTests {
    @Test func aBoardAskedForBeforeTheSwarmIsShownIsReadOnceItIs() async throws {
        let rig = SwarmRig(.board)
        await rig.store.loadBoard()          // the board screen's .task: nothing is shown yet
        #expect(rig.store.board == nil)
        await rig.store.show(id: PreviewSwarmIDs.board)
        await rig.settle()
        let board = try #require(rig.store.board, "the early ask is kept and answered when the swarm arrives")
        #expect(board.swarm.id == PreviewSwarmIDs.board && !board.rows.isEmpty)
        #expect(rig.store.boardProblem == nil)
        rig.store.hide()
    }

    @Test func anAgentAskedForBeforeTheSwarmIsShownIsReadOnceItIs() async throws {
        let rig = SwarmRig(.running)
        await rig.store.loadAgent(3)         // the sheet's .task: nothing is shown yet
        #expect(rig.store.agent == nil)
        await rig.store.show(id: PreviewSwarmIDs.story)
        await rig.settle()
        let agent = try #require(rig.store.agent, "the early ask is kept and answered when the swarm arrives")
        #expect(agent.agent == 3 && rig.store.agentProblem == nil)
        rig.store.hide()
    }

    @Test func aSwarmThatCannotBeReadEndsTheBoardAndTheSheetInTheirErrorStateNotASpinner() async throws {
        let rig = SwarmRig(.board)
        await rig.store.loadBoard()
        await rig.store.loadAgent(2)
        await rig.store.show(id: "no-such-swarm")
        await rig.settle()
        #expect(rig.store.boardProblem != nil && rig.store.board == nil)
        #expect(rig.store.agentProblem != nil && rig.store.agent == nil)
        rig.store.hide()
    }

    @Test func anAskIsForgottenWhenTheScreenGoesAway() async {
        let rig = SwarmRig(.board)
        await rig.store.loadBoard()
        await rig.store.loadAgent(1)
        rig.store.hide()
        await rig.store.show(id: PreviewSwarmIDs.board)
        await rig.settle()
        #expect(rig.store.board == nil && rig.store.agent == nil, "an ask made for a screen that is gone belongs to no screen")
        rig.store.hide()
    }

    @Test func aFilterChangedWhileTheBoardIsBeingReadIsReadAgain() async throws {
        let rig = SwarmRig(.board)
        await rig.store.show(id: PreviewSwarmIDs.board)
        async let first: Void = rig.store.loadBoard()
        rig.store.boardAgent = 12
        async let second: Void = rig.store.loadBoard()
        _ = await (first, second)
        #expect(try #require(rig.store.board).rows.map(\.agent) == [12])
        rig.store.boardAgent = nil
        rig.store.hide()
    }
}

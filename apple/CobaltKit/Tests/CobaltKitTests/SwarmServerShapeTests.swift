import Foundation
import Testing
@testable import CobaltKit

// The app's swarm models against what the server really answers. `Fixtures/swarm-server-answers.json` is not written by hand: it
// holds the answers of the real routes, captured by running the server's own handlers (`handleRequest` over node:sqlite, the
// harness of deploy/cloudflare/api/test/swarm.test.ts) through a propose swarm end to end, a read swarm with a board and a
// failed agent, and an agent asking its owner a question. So these are the exact bytes the routes write (GET /swarms,
// /swarms/<id>, /results, /changes, /agents/<n>, /messages, /inbox, /board, POST /changes, /apply, /messages).
//
// Two kinds of check: a round trip (decode, write again, and every key the server sent must come back with the same value, so a
// field that decoded to its default because of a wrong type or name is caught), and the facts the screens rely on.

private func answerText() throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/swarm-server-answers.json")
    return try String(contentsOf: url, encoding: .utf8)
}

private func answers() throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(answerText().utf8)) as? [String: Any])
}

/// One answer as bytes (key order is lost: `rawAnswer` keeps it).
private func answer(_ key: String) throws -> Data {
    let value = try #require(try answers()[key], "no captured answer \(key)")
    return try JSONSerialization.data(withJSONObject: value)
}

/// One answer's own text, in the server's key order: the balanced value after `"<key>": `.
private func rawAnswer(_ key: String) throws -> Data {
    let text = try answerText()
    let mark = try #require(text.range(of: "\"\(key)\": "), "no captured answer \(key)")
    var depth = 0
    var inString = false
    var escaped = false
    var end = mark.upperBound
    var started = false
    for i in text[mark.upperBound...].indices {
        let c = text[i]
        if inString {
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            continue
        }
        if c == "\"" { inString = true; started = true; continue }
        if c == "{" || c == "[" { depth += 1; started = true }
        if c == "}" || c == "]" { depth -= 1 }
        if started && depth == 0 { end = text.index(after: i); break }
    }
    return Data(text[mark.upperBound..<end].utf8)
}

private func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
    try SwarmWire.decoder().decode(T.self, from: answer(key))
}

/// Every key the server sent must come back out of the model with the same value (null and absent are the same; keys the model
/// does not write, such as `spec_preview.board`, are skipped).
private func expectRoundTrip<T: Codable>(_ type: T.Type, _ data: Data, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let model = try SwarmWire.decoder().decode(T.self, from: data)
    let written = try JSONSerialization.jsonObject(with: SwarmWire.encoder().encode(model), options: [.fragmentsAllowed])
    let sent = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    var problems: [String] = []
    func compare(_ a: Any, _ b: Any?, _ path: String) {
        switch (a, b) {
        case (is NSNull, nil), (is NSNull, is NSNull): return
        case (let a as [String: Any], let b as [String: Any]):
            for (k, v) in a { compare(v, b[k], "\(path).\(k)") }
        case (let a as [Any], let b as [Any]):
            if a.count != b.count { problems.append("\(path): \(a.count) items sent, \(b.count) kept"); return }
            for (i, v) in a.enumerated() { compare(v, b[i], "\(path)[\(i)]") }
        case (let a as NSNumber, let b as NSNumber):
            if a.doubleValue != b.doubleValue { problems.append("\(path): sent \(a), kept \(b)") }
        case (let a as String, let b as String):
            if a != b { problems.append("\(path): sent \(a), kept \(b)") }
        default:
            // a key the model does not write at all is fine only when it is one of the known extras
            let skipped = [".spec_preview.board", ".spec_preview.prefetch"]
            if !skipped.contains(where: { path.hasSuffix($0) }) { problems.append("\(path): sent \(a), kept \(String(describing: b))") }
        }
    }
    compare(sent, written, "")
    #expect(problems.isEmpty, "\(label): \(problems.joined(separator: "; "))", sourceLocation: sourceLocation)
}

private let swarmAnswerKeys = [
    "plan.propose", "approve", "get.running", "get.propose.ready", "get.propose.applied", "plan.read", "get.read.done", "get.asking", "apply",
]

// MARK: - Swarm

struct SwarmServerShapeTests {
    @Test func everySwarmAnswerRoundTripsWithoutLosingAField() throws {
        for key in swarmAnswerKeys { try expectRoundTrip(Swarm.self, try answer(key), key) }
        // the same swarm inside the other answers
        let board = try #require(try answers()["board.read"] as? [String: Any])
        try expectRoundTrip(Swarm.self, JSONSerialization.data(withJSONObject: try #require(board["swarm"])), "board.read.swarm")
        let decided = try #require(try answers()["decided"] as? [String: Any])
        try expectRoundTrip(Swarm.self, JSONSerialization.data(withJSONObject: try #require(decided["swarm"])), "decided.swarm")
        let list = try #require(try answers()["list"] as? [String: Any])
        for (i, s) in try #require(list["swarms"] as? [Any]).enumerated() {
            try expectRoundTrip(Swarm.self, JSONSerialization.data(withJSONObject: s), "list[\(i)]")
        }
    }

    @Test func aPlanAwaitingApproval() throws {
        let s = try decode(Swarm.self, "plan.propose")
        #expect(s.status == .awaitingApproval && s.mode == .propose && s.waitsForYou)
        #expect(s.specHash.count == 64 && s.job == "swarm:\(s.id)" && s.approveURL?.absoluteString == "https://cobalt.capybaraharmony.com/swarms/\(s.id)")
        #expect(s.estimateUSD != nil && s.expiresAt != nil && s.approvedAt == nil && s.finishedAt == nil)
        #expect(s.createdAt == Date(timeIntervalSince1970: 1_800_000_000), "milliseconds since the epoch")
        #expect(s.tasks.total == 2 && s.tasks.queued == 2 && s.tasks.cells.map(\.status) == [.queued, .queued])
        #expect(s.tasks.cells.allSatisfy { $0.step == nil && $0.error == nil })
        #expect(s.changes == Swarm.ChangeCounts() && s.apply == Swarm.Apply())
        #expect(s.messages == Swarm.MessageCounts(total: 0, waiting: 0) && s.planner == "agent key")
        #expect(s.score == nil, "no agent has ended: null")
        #expect(s.items == 4 && s.batchSize == 2 && s.concurrency == 2 && s.scope != nil)
        #expect(s.writes == ["seventv.rename"] && s.tools == ["seventv.emote"] && s.unscopedWrites.isEmpty)
        let p = try #require(s.preview)
        #expect(p.itemsSample.count == 4 && p.source == nil && p.outputSchema == nil && p.reducePrompt == nil)
        #expect(p.turnsPerTask == 6 && p.attempts == 2 && p.stopAfterFailedTasks == 5)
    }

    @Test func aFinishedProposeSwarmReadyToApplyThenApplied() throws {
        let ready = try decode(Swarm.self, "get.propose.ready")
        #expect(ready.status == .done && ready.apply.status == .ready && ready.waitsForYou)
        #expect(ready.changes == Swarm.ChangeCounts(total: 4, kept: 4, done: 0, failed: 0) && ready.apply.total == 4)
        #expect(ready.expiresAt == nil && ready.finishedAt != nil && ready.score == 1)
        let applied = try decode(Swarm.self, "get.propose.applied")
        #expect(applied.apply == Swarm.Apply(status: .applied, done: 3, failed: 0, total: 3))
        #expect(applied.changes == Swarm.ChangeCounts(total: 4, kept: 3, done: 3, failed: 0) && !applied.waitsForYou)
        // the Live Activity's own numbers from the server's counts: nothing open, so nothing left to apply
        #expect(SwarmLiveInput(swarm: applied).changes.open == 0)
        // the apply answer is a swarm too (applying)
        let applying = try decode(Swarm.self, "apply")
        #expect(applying.apply.status == .applying && applying.isWorking)
    }

    @Test func aReadSwarmHasNoChangesAndAFailedAgentsCellSaysWhy() throws {
        let s = try decode(Swarm.self, "get.read.done")
        #expect(s.mode == .read && s.changes == nil && s.scope?.dictionaryValue?.isEmpty == true && s.writes.isEmpty)
        #expect(s.tasks.done == 1 && s.tasks.failed == 1 && s.score == 0.5)
        #expect(s.tasks.cells[1].status == .failed && s.tasks.cells[1].error == "error.swarm.bad_answer: it is not JSON")
        #expect(s.tasks.cells[1].step == "failed: error.swarm.bad_answer: it is not JSON")
    }

    @Test func anAgentAskingItsOwnerShowsAsWaitingEverywhere() throws {
        let s = try decode(Swarm.self, "get.asking")
        #expect(s.status == .running && s.isWorking)
        #expect(s.tasks.waiting == 1 && s.tasks.cells[0].status == .waiting && s.tasks.cells[0].step == "told the owner")
        #expect(s.messages == Swarm.MessageCounts(total: 2, waiting: 1))
        #expect(s.score == 0, "0 is a score; only null is none")
        // the island says so
        let state = JobLiveState(swarm: s, now: Date(timeIntervalSince1970: 1_800_000_010))
        #expect(state.detail == "1 agent is asking agent key a question" && state.cells == "wd")
    }

    @Test func theListHoldsTheSwarmsNewestFirst() throws {
        let list = try SwarmWire.decoder().decode(SwarmListWire.self, from: answer("list"))
        #expect(list.swarms.count == 1 && list.swarms[0].status == .done)
    }

    // MARK: results

    @Test func resultsKeepEachAgentsItemsAndOutcomeWithNullsWhereTheServerSendsThem() throws {
        struct Page: Decodable { var results: [SwarmResult]; var total: Int; var offset: Int }
        let read = try decode(Page.self, "results.read")
        #expect(read.total == 2 && read.offset == 0 && read.results.count == 2)
        let ok = read.results[0]
        #expect(ok.task == 0 && ok.agent == 1 && ok.status == .done && ok.error == nil && ok.items.count == 2)
        #expect(ok.result?.dictionaryValue?["matches"]?.arrayValue?.count == 2)
        #expect(ok.outcome == SwarmOutcome(status: .done, items: 2, answered: 2, toolCalls: 0, toolErrors: 0, asks: 0, turns: 1, usd: 0.0015, ms: 0, score: 1))
        let failed = read.results[1]
        #expect(failed.status == .failed && failed.result == nil && failed.error == "error.swarm.bad_answer: it is not JSON")
        #expect(failed.items.count == 2, "a failed agent keeps its items")
        #expect(failed.outcome?.score == 0 && failed.outcome?.turns == 2)
        // a parked agent has no score and no duration yet: null, not 0
        let asking = try decode(Page.self, "results.asking")
        let parked = try #require(asking.results[0].outcome)
        #expect(parked.status == .waiting && parked.asks == 1 && parked.ms == nil && parked.score == nil)
        #expect(asking.results[1].outcome?.score == 0 && asking.results[1].outcome?.ms == 0)
    }

    @Test func everyResultAndMessageRoundTripsWithoutLosingAField() throws {
        for key in ["results.read", "results.asking", "results.propose"] {
            let page = try #require(try answers()[key] as? [String: Any])
            for (i, r) in try #require(page["results"] as? [Any]).enumerated() {
                try expectRoundTrip(SwarmResult.self, JSONSerialization.data(withJSONObject: r), "\(key)[\(i)]")
            }
        }
        for key in ["inbox", "messages", "messages.after"] {
            let page = try #require(try answers()[key] as? [String: Any])
            for (i, m) in try #require(page["messages"] as? [Any]).enumerated() {
                try expectRoundTrip(SwarmMessage.self, JSONSerialization.data(withJSONObject: m), "\(key)[\(i)]")
            }
        }
    }

    @Test func theOutcomeWordsSayNothingAboutWhatIsNotKnownYet() throws {
        struct Page: Decodable { var results: [SwarmResult] }
        let parked = try #require(try decode(Page.self, "results.asking").results[0].outcome)
        let line = SwarmWords.outcome(parked)
        #expect(!line.contains("score") && !line.contains("0 s"), "\(line)")
    }

    @Test func changesCarryTheirArgsAndClashes() throws {
        let page = try decode(SwarmChangePage.self, "changes")
        #expect(page.total == 4 && page.offset == 0 && page.changes.count == 4)
        for i in page.changes.indices { try expectRoundTrip(SwarmChange.self, JSONSerialization.data(withJSONObject: (try #require(try answers()["changes"] as? [String: Any])["changes"] as! [Any])[i]), "changes[\(i)]") }
        let first = page.changes[0]
        #expect(first.op == "seventv.rename" && first.editArg == "alias" && first.canEdit && first.agent == 1)
        #expect(first.args?.dictionaryValue?["alias"]?.stringValue == "Cat" && first.before == "emote_0" && first.after == "Cat")
        #expect(first.previewURL?.host == "cdn.7tv.app" && first.keep && first.status == .proposed && first.clash == "duplicate name: also proposed by #1")
        #expect(page.changes[1].clash == nil)
    }

    @Test func aDecideAnswersTheSwarmAndTheChangesNamed() throws {
        let d = try decode(SwarmDecided.self, "decided")
        #expect(d.swarm.changes?.kept == 3 && d.swarm.apply.total == 3)
        #expect(d.changes.count == 2)
        let dog = try #require(d.changes.first { $0.after == "dog" })
        #expect(!dog.keep && dog.clash == nil)
        let kitty = try #require(d.changes.first { $0.after == "kitty" })
        #expect(kitty.keep && kitty.args?.dictionaryValue?["alias"]?.stringValue == "kitty")
    }

    // MARK: one agent

    @Test func oneAgentWithItsStepsAndMessages() throws {
        for key in ["agent.propose", "agent.read.failed", "agent.read.done", "agent.asking"] { try expectRoundTrip(SwarmAgent.self, try answer(key), key) }
        let a = try decode(SwarmAgent.self, "agent.asking")
        #expect(a.agent == 1 && a.status == .waiting && a.attempts == 1 && a.inTokens == 10_000 && a.outTokens == 1_000 && a.usd == 0.0015)
        #expect(a.startedAt == Date(timeIntervalSince1970: 1_800_000_002) && a.endedAt == nil && a.error == nil && a.result == nil)
        #expect(a.steps.map(\.text) == ["started", "asked a question", "told the owner"] && a.steps[0].at == Date(timeIntervalSince1970: 1_800_000_002))
        #expect(a.items.count == 2 && a.changes.isEmpty)
        #expect(a.messages.count == 2)
        let ask = a.messages[0]
        #expect(ask.kind == .ask && ask.dir == .up && ask.sender == .agent && ask.agent == 1 && !ask.answered && ask.isOpenAsk)
        #expect(ask.text == "Which set should Cat go in?" && ask.at == Date(timeIntervalSince1970: 1_800_000_002))
        #expect(a.messages[1].kind == .tell && !a.messages[1].isOpenAsk)
        let failed = try decode(SwarmAgent.self, "agent.read.failed")
        #expect(failed.status == .failed && failed.result == nil && failed.error?.hasPrefix("error.swarm.bad_answer") == true && failed.seconds == 0)
        let proposed = try decode(SwarmAgent.self, "agent.propose")
        #expect(proposed.changes.count == 2 && proposed.changes[0].after == "Cat" && proposed.status == .done)
    }

    // MARK: messages

    @Test func theInboxAndTheMessageList() throws {
        let inbox = try SwarmWire.decoder().decode(SwarmMessagesWire.self, from: answer("inbox"))
        #expect(inbox.messages.map(\.kind) == [.ask, .tell] && inbox.messages.allSatisfy { $0.dir == .up && $0.sender == .agent && $0.agent == 1 })
        #expect(inbox.messages.map(\.id) == [1, 2])
        let before = try SwarmWire.decoder().decode(SwarmMessagesWire.self, from: answer("messages"))
        #expect(before.messages == inbox.messages)
        // after the owner answered and then told every agent
        let after = try SwarmWire.decoder().decode(SwarmMessagesWire.self, from: answer("messages.after")).messages
        #expect(after.count == 4)
        let reply = after[2]
        #expect(reply.dir == .down && reply.kind == .reply && reply.sender == .owner && reply.agent == 1 && reply.text == "the first one")
        #expect(after[0].answered && after[0].kind == .ask, "the ask the reply answered")
        let note = after[3]
        #expect(note.dir == .down && note.kind == .note && note.sender == .you && note.agent == nil && note.text == "hurry up")
        for m in after { #expect(!m.isOpenAsk) }
    }

    @Test func theSendAnswerIsABooleanAndAnAgentNumberOrAll() throws {
        let one = try decode(SwarmSent.self, "send")
        #expect(one.sent == 1 && one.to == .agent(1) && one.woke)
        let all = try decode(SwarmSent.self, "send.all")
        #expect(all.sent == 1 && all.to == .all && !all.woke)
    }

    // MARK: the board

    @Test func theReadBoardWithItsMediaGroupsAndAFailedAgent() throws {
        let board = try SwarmBoard.decode(rawAnswer("board.read"))
        #expect(board.total == 3 && board.offset == 0 && !board.hasMore && board.rows.count == 3)
        #expect(board.swarm.mode == .read && board.swarm.score == 0.5)
        #expect(board.groups == [BoardGroup(value: "cats", count: 1), BoardGroup(value: "dogs", count: 1)])
        #expect(board.agents.map(\.agent) == [1, 2] && board.agents.map(\.status) == [.done, .failed])
        #expect(board.agents[0].outcome?.score == 1 && board.agents[0].score == 1)
        #expect(board.agents[1].outcome?.score == 0 && board.agents[1].score == nil, "a failed agent is drawn red, not as a score")
        #expect(board.agents[1].error == "error.swarm.bad_answer: it is not JSON")

        let cat = board.rows[0]
        #expect(cat.agent == 1 && cat.n == 1 && cat.title == "emote_0" && cat.score == 0.9 && cat.group == "cats" && cat.id == "1-1")
        #expect(cat.fields.map(\.key) == ["note", "seen_on"], "the server's order")
        #expect(cat.field("note") == "a cat")
        #expect(cat.links.map(\.absoluteString) == ["https://7tv.app/emotes/01HEMOTE000000000000000000"])
        let pic = try #require(cat.media.first)
        #expect(cat.media.count == 1 && pic.kind == .emote && pic.ref == "01HEMOTE000000000000000000" && pic.error == nil)
        #expect(pic.previewURL?.absoluteString == "https://cdn.7tv.app/emote/01HEMOTE000000000000000000/2x.webp")
        #expect(pic.openURL?.absoluteString == "https://7tv.app/emotes/01HEMOTE000000000000000000" && !pic.opensInApp)

        // numbers, booleans and null come as text, in the server's order
        let dog = board.rows[1]
        #expect(dog.fields.map(\.key) == ["link", "count", "flag", "nothing"])
        #expect(dog.field("count") == "3" && dog.field("flag") == "yes" && dog.field("nothing") == "none")
        #expect(dog.score == 0.5 && dog.group == "dogs")

        let failed = board.rows[2]
        #expect(failed.isFailedAgent && failed.agent == 2 && failed.score == nil && failed.group == nil && failed.media.isEmpty)
        #expect(failed.title?.hasPrefix("agent 2 failed: error.swarm.bad_answer") == true)
        #expect(failed.field("items") == "emote_2, emote_3")
    }

    @Test func aFilteredBoardPageKeepsEveryAgentAndAllGroups() throws {
        let page = try SwarmBoard.decode(rawAnswer("board.read.group"))
        #expect(page.total == 1 && page.rows.map(\.title) == ["emote_0"])
        #expect(page.groups.count == 2, "groups are counted before the group filter")
        #expect(page.agents.count == 2)
    }

    @Test func aProposeBoardHasOneRowPerChange() throws {
        let board = try SwarmBoard.decode(rawAnswer("board.propose"))
        #expect(board.total == 4 && board.rows.count == 4 && board.swarm.mode == .propose)
        #expect(board.groups == [BoardGroup(value: "seventv.rename", count: 4)])
        let first = board.rows[0]
        #expect(first.title == "Cat" && first.score == nil && first.group == "seventv.rename")
        #expect(first.fields.map(\.key) == ["op", "target", "before", "after", "status", "keep", "clash"])
        #expect(first.field("keep") == "yes" && first.field("clash") == "duplicate name: also proposed by #1")
        #expect(first.media.first?.kind == .emote)
        let titled = try SwarmBoard.decode(rawAnswer("board.propose.q"))
        #expect(titled.rows.map(\.title) == ["Cat", "cat"].sorted { $0.localizedCompare($1) == .orderedAscending }, "q=cat, sort=title")
    }

    @Test func aRunningAgentOnTheBoardHasNoScoreAndNoRows() throws {
        let board = try SwarmBoard.decode(rawAnswer("board.asking"))
        #expect(board.rows.isEmpty && board.total == 0 && board.groups.isEmpty)
        let parked = board.agents[0]
        #expect(parked.status == .waiting && parked.outcome?.score == nil && parked.outcome?.ms == nil && parked.score == nil)
        #expect(parked.outcome?.asks == 1)
        #expect(board.agents[1].score == 0, "an agent that finished with nothing to show scores 0")
    }

    @Test func aMediaRefThatCouldNotBeResolvedDecodesAsItsError() throws {
        let m = try SwarmWire.decoder().decode(MediaRef.self, from: Data(#"{"ref":"nope","error":"error.media.not_found"}"#.utf8))
        #expect(m.ref == "nope" && m.error == "error.media.not_found" && m.previewURL == nil)
        // a private post: a picture and no public link; a video outside capystore: a link and no picture
        let post = try SwarmWire.decoder().decode(MediaRef.self, from: Data(#"{"ref":"p1","kind":"post","preview_url":"https://media.capybaraharmony.com/a.jpg","open_url":null,"title":"clip","animated":true}"#.utf8))
        #expect(post.kind == .post && post.opensInApp && post.openURL == nil && post.title == "clip" && post.animated == true)
        let video = try SwarmWire.decoder().decode(MediaRef.self, from: Data(#"{"ref":"https://cdn.7tv.app/v.mp4","kind":"video","preview_url":null,"open_url":"https://cdn.7tv.app/v.mp4"}"#.utf8))
        #expect(video.kind == .video && video.previewURL == nil && video.openURL != nil)
    }
}

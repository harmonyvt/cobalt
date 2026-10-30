import Foundation
import Testing
@testable import CobaltKit

// Rich tool cards (APP-API-CONTRACT 38): a step's calls and cards decode from the server's JSON, odd ones are dropped
// without losing the step, later cards of the same thing replace earlier ones, and `card_posts` merges into the thread.

private let wireCalls = """
{"id":"toolu_9","kind":"code","status":"done","code":"","logs":[],"result":null,"error":null,"duration_ms":2100,"calls":[
 {"op":"library.search","ms":640,"status":"done","card":{"type":"search","query":"cat girl","within":null,"total":38,"hits":[{"post_id":"P1","score":0.62},{"post_id":"P2","score":0.5}]}},
 {"op":"look","ms":12,"status":"done","card":{"type":"look","post_ids":["P1","P2"]}},
 {"op":"emotes.find","ms":410,"status":"done","card":{"type":"emotes","query":"catJAM","sort":"trending_weekly","saved":false,"emotes":[
   {"id":"01F6MQ33FG000FFJ97ZB8MWV52","name":"catJAM","animated":true,"url":"https://cdn.7tv.app/emote/01F6MQ33FG000FFJ97ZB8MWV52/2x.webp","library_id":null},
   {"id":"bad","name":"x","animated":true,"url":"javascript:alert(1)","library_id":null}]}},
 {"op":"edits.update","ms":80,"status":"done","card":{"type":"edit","project_id":"G4cxbjOcOYHusDG4","title":"shrek","revision":4,"duration":34.4,"width":720,"height":1280,"change":"updated",
   "tracks":[{"name":"main","index":0,"clips":[{"id":"m1","item":"I1","post_id":"P1","kind":"video","title":"shrek","picture":null,"at":0,"length":18,"in":0,"out":18.02,"speed":1,"pitch":null,"is_new":false}]},
             {"name":"overlay","index":0,"clips":[{"id":"o1","item":"I2","post_id":"I2","kind":"emote","title":"catJAM","picture":"https://media.capybaraharmony.com/e.webp","at":3,"length":6,"in":0,"out":6,"speed":1,"pitch":null,"is_new":true}]}],
   "render":null}},
 {"op":"edits.get","ms":20,"status":"done","card":{"type":"edit","project_id":"G4cxbjOcOYHusDG4","title":"shrek","revision":4,"duration":34.4,"change":"viewed","tracks":[]}},
 {"op":"make.webp","ms":300,"status":"done","card":{"type":"job","op":"make.webp","job":"J1","status":"running","progress":0.4,"error":null,"post_id":null,"kind":null,"seconds":null,"width":null,"height":null,"bytes":null,"share_url":null,"watching":false,"project_id":null}},
 {"op":"jobs.onDone","ms":8000,"status":"done","card":{"type":"job","op":"jobs.onDone","job":"J1","status":"done","progress":1,"post_id":"P3","kind":"image","bytes":1200000,"share_url":"https://share.capybaraharmony.com/x","watching":false}},
 {"op":"box.run","ms":6200,"status":"done","card":{"type":"box","cmd":"ffmpeg -i a b","code":0,"timed_out":false,"stdout":"ok","stderr":""}},
 {"op":"links.create","ms":220,"status":"done","card":{"type":"link","id":"3301","url":"https://share.capybaraharmony.com/g/3301","title":"two","files":2,"private":false}},
 {"op":"collections.add","ms":90,"status":"done","card":{"type":"collection","of":"collection","id":"C1","name":"Lia Share 12","count":11,"change":"added"}},
 {"op":"stage.get","ms":30,"status":"error","error":"the studio is off"},
 {"op":"library.delete","ms":5,"status":"asked"},
 {"op":"future.op","ms":5,"status":"done","card":{"type":"hologram","x":1}},
 {"ms":5}
]}
"""

@Suite struct ChatToolCardTests {
    private func step() throws -> ChatStep {
        try CobaltJSON.decoder().decode(ChatStep.self, from: Data(wireCalls.utf8))
    }

    @Test func callsDecodeAndOddOnesAreDropped() throws {
        let s = try step()
        // the call with no op is dropped; an unknown card type is a chip only
        #expect(s.calls.count == 13)
        #expect(s.calls.map(\.op).last == "future.op" && s.calls.last?.card == nil)
        #expect(s.calls[10].status == .error && s.calls[10].error == "the studio is off" && s.calls[10].card == nil)
        #expect(s.calls[11].status == .asked)
        #expect(s.durationMS == 2100)
    }

    @Test func cardsDecode() throws {
        let s = try step()
        guard case .search(let search) = s.calls[0].card else { Issue.record("no search"); return }
        #expect(search.query == "cat girl" && search.total == 38 && search.hits.map(\.postID) == ["P1", "P2"] && search.topScore == 0.62)
        #expect(s.calls[1].card == .look(postIDs: ["P1", "P2"]))
        guard case .emotes(let emotes) = s.calls[2].card else { Issue.record("no emotes"); return }
        // the emote with a non-https url is dropped
        #expect(emotes.emotes.map(\.name) == ["catJAM"] && emotes.sort == "trending_weekly")
        guard case .edit(let edit) = s.calls[3].card else { Issue.record("no edit"); return }
        #expect(edit.projectID == "G4cxbjOcOYHusDG4" && edit.change == .updated && edit.tracks.count == 2)
        #expect(edit.tracks[0].isMain && !edit.tracks[1].isMain && edit.tracks[1].index == 0)
        let clip = try #require(edit.tracks[0].clips.first)
        #expect(clip.sourceIn == 0 && clip.sourceOut == 18.02 && clip.kind == .video && !clip.isPicture)
        #expect(edit.added.map(\.id) == ["o1"] && edit.added.first?.kind == .emote && edit.added.first?.isPicture == true)
        // the emote overlay is on top at 4 s, the main clip under it
        #expect(edit.clips(at: 4).map(\.id) == ["o1", "m1"])
        guard case .box(let box) = s.calls[7].card else { Issue.record("no box"); return }
        #expect(box.succeeded && box.cmd == "ffmpeg -i a b")
        guard case .link(let link) = s.calls[8].card else { Issue.record("no link"); return }
        #expect(link.url.absoluteString == "https://share.capybaraharmony.com/g/3301" && !link.isPrivate && link.files == 2)
        guard case .collection(let folder) = s.calls[9].card else { Issue.record("no collection"); return }
        #expect(!folder.isSet && folder.name == "Lia Share 12" && folder.change == .added)
    }

    @Test func laterCardsOfTheSameThingReplaceEarlierOnes() throws {
        let cards = try step().cards
        // the job's later card wins; the plain look at the edit keeps the card that showed the change
        #expect(cards.map(\.call.op) == ["library.search", "look", "emotes.find", "edits.update", "jobs.onDone", "box.run", "links.create", "collections.add"])
        guard case .job(let job) = cards[4].card else { Issue.record("no job"); return }
        #expect(job.isDone && job.postID == "P3" && job.shareURL != nil)
        #expect(cards.flatMap { $0.card.postIDs }.contains("P3"))
    }

    @Test func anOlderStepHasNoCalls() throws {
        let s = try CobaltJSON.decoder().decode(ChatStep.self, from: Data(#"{"id":"x","kind":"code","status":"done","code":"return 1"}"#.utf8))
        #expect(s.calls.isEmpty && s.cards.isEmpty)
    }

    @Test func cardPostsMergeIntoTheThread() throws {
        let json = #"{"posts":{"Dd7P496wolG":{"id":"Dd7P496wolG","service":"instagram","title":"the dog","duration":14.7,"created_at":1790000000000,"files":[],"kind":"video"}}}"#
        let event = try #require(ChatSSEParser.event(named: "card_posts", data: Data(json.utf8)))
        guard case .cardPosts(let posts) = event else { Issue.record("not cardPosts"); return }
        #expect(posts.map(\.id) == ["Dd7P496wolG"])
        var content = ChatThreadContent(
            thread: ChatThread(id: "T", title: "t", createdAt: Date(), updatedAt: Date()),
            messages: [ChatMessage(id: "1", role: .assistant, status: .running, createdAt: Date())], posts: [:])
        content.apply(event)
        #expect(content.posts["Dd7P496wolG"] != nil && content.messages[0].postIDs.isEmpty)
        // a step with calls replaces the running one
        content.apply(.step(try step()))
        #expect(content.messages[0].steps.first?.calls.count == 13)
    }
}

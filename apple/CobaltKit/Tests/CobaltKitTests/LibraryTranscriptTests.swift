import Foundation
import Testing
@testable import CobaltKit

// Timed transcripts (APP-API-CONTRACT 47): the wire of `GET /library/transcript`, the line on screen at a time, the .srt,
// `said` on search hits, the capability, and the keyed request.

private let transcriptKey = "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21"

struct LibraryTranscriptTests {
    private func decode(_ json: String) throws -> LibraryTranscript {
        try LibraryTranscript.decode(Data(json.utf8))
    }

    @Test func theWireDecodesLinesAndWordsLeniently() throws {
        let t = try decode(#"""
        {"status":"success","post_key":"p1","state":"done","language":"en","model":"m","updated_at":1,
         "lines":[{"start":4.1,"end":7.9,"text":"sir, you cannot","words":[{"text":"sir,","start":4.1,"end":4.52},{"bad":1},
                   {"text":"you","start":4.6,"end":4.9}]},
                  {"start":0.6,"end":3.4,"text":"wait"},
                  {"text":"no start"}]}
        """#)
        #expect(t.postKey == "p1" && t.state == .done && t.language == "en")
        #expect(t.lines.map(\.text) == ["wait", "sir, you cannot"], "sorted by start, a broken line dropped")
        #expect(t.lines[1].words.map(\.text) == ["sir,", "you"])
        #expect(t.lines[0].words.isEmpty)
        #expect(t.hasLines)
        #expect(try decode(#"{"post_key":"p","state":"no_speech","lines":[]}"#).state == .noSpeech)
        #expect(try decode(#"{"post_key":"p","state":"no_sound"}"#).state == .noSound)
        #expect(try decode(#"{"post_key":"p","state":"later"}"#).state == .unknown)
        #expect(try !decode(#"{"post_key":"p","state":"pending","lines":[]}"#).hasLines)
    }

    @Test func theLineOnScreenFollowsTheTimeAndLingers() {
        let t = LibraryTranscript(postKey: "p", state: .done, lines: [
            .init(start: 1, end: 2, text: "a"),
            .init(start: 2.3, end: 4, text: "b"),
            .init(start: 10, end: 11, text: "c"),
        ])
        #expect(t.lineIndex(at: 0.5) == nil)
        #expect(t.lineIndex(at: 1) == 0)
        #expect(t.lineIndex(at: 2.2) == 0, "lingers after its end until the next starts")
        #expect(t.lineIndex(at: 2.3) == 1)
        #expect(t.lineIndex(at: 4.5) == 1)
        #expect(t.lineIndex(at: 4.7) == nil, "gone after the linger")
        #expect(t.lineIndex(at: 10.5) == 2)
        #expect(t.lineIndex(at: .nan) == nil)
        #expect(t.lastLineIndex(at: 7) == 1)
        #expect(t.lastLineIndex(at: 0) == nil)
        let line = t.lines[0]
        let word = LibraryTranscript.Word(text: "a", start: 1, end: 1.5)
        #expect(line.phase(of: word, at: 0.9) == .coming)
        #expect(line.phase(of: word, at: 1.2) == .now)
        #expect(line.phase(of: word, at: 1.5) == .said)
    }

    @Test func theSrtHasOneCuePerLine() {
        let t = LibraryTranscript(postKey: "p", state: .done, lines: [
            .init(start: 0.6, end: 3.4, text: "wait"),
            .init(start: 3723.25, end: 3723.25, text: "late"),
        ])
        #expect(t.srt() == "1\n00:00:00,600 --> 00:00:03,400\nwait\n\n2\n01:02:03,250 --> 01:02:03,750\nlate\n")
    }

    @Test func searchHitsCarryWhereItWasSaid() throws {
        let json = #"""
        {"status":"success","query":"tail","posts":[
          {"id":"p1","created_at":1790000000000,"files":[],"score":0.9,
           "said":[{"start":4.1,"end":7.9,"text":"bring the tail","match":"words"},{"start":"x"}]},
          {"id":"p2","created_at":1790000000000,"files":[],"score":0.5,"said":[{"start":3,"end":6,"text":"cabin rules","match":"meaning"}]},
          {"id":"p3","created_at":1790000000000,"files":[],"score":0.1}]}
        """#
        let r = try LibrarySearchWire.decode(Data(json.utf8), asked: "tail")
        #expect(r.hits.count == 3)
        #expect(r.hits[0].said == [LibrarySaid(start: 4.1, end: 7.9, text: "bring the tail", match: .words)])
        #expect(r.hits[1].said.first?.match == .meaning)
        #expect(r.hits[2].said.isEmpty)
    }

    @Test func theCapabilityNeedsTheSound() throws {
        func caps(_ features: String) throws -> Capabilities {
            let json = #"{"server":"cobalt-cloudflare","features":\#(features),"key":"valid"}"#
            return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
        }
        #expect(try caps(#"{"library":true,"search":true,"about":true,"about_sound":true,"transcripts":true}"#).transcripts)
        #expect(try !caps(#"{"library":true,"search":true,"about":true,"transcripts":true}"#).transcripts)
        #expect(try !caps(#"{"library":true,"search":true,"about":true,"about_sound":true}"#).transcripts)
        #expect(!Capabilities.unknown.transcripts)
    }

    @MainActor @Test func thePreviewServerSaysTheSampleLines() async throws {
        let app = AppModel.makePreviewSearch(.ready, timeScale: 0.01, clock: SystemClock())
        let video = try #require(app.library.posts.first { $0.kind == .video || $0.kind == nil })
        let t = try await app.library.transcript(postKey: video.id)
        #expect(t.hasLines && t.lines.first?.text == "wait is that a fox in first class?")
        #expect(t.lines.allSatisfy { line in line.words.allSatisfy { $0.start >= line.start - 0.01 && $0.end <= line.end + 0.01 } })
    }
}

@Suite(.serialized)
struct LibraryTranscriptHTTPTests {
    @Test func theReadIsAKeyedGetByKey() async throws {
        let server = try await LoopbackServer.start { req in
            guard req.path == "/library/transcript" else { return .init(status: 404) }
            if req.query == "key=gone" {
                return .json(#"{"status":"error","error":{"code":"error.library.not_found"}}"#, status: 404)
            }
            return .json(#"{"status":"success","post_key":"a b","state":"done","lines":[{"start":1,"end":2,"text":"hi"}]}"#)
        }
        defer { server.stop() }
        let client = HTTPCobaltClient(baseURL: server.base, apiKey: { transcriptKey })
        let t = try await client.libraryTranscript(postKey: "a b")
        #expect(server.requests.first?.method == "GET" && server.requests.first?.query == "key=a%20b")
        #expect(server.requests.first?.headers["authorization"] == "Api-Key \(transcriptKey)")
        #expect(t.state == .done && t.lines.map(\.text) == ["hi"])
        await #expect(throws: CobaltError.api(code: "error.library.not_found", httpStatus: 404)) {
            try await client.libraryTranscript(postKey: "gone")
        }
    }
}

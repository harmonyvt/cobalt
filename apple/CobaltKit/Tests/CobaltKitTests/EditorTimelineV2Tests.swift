import CoreImage
import Foundation
import Testing
@testable import CobaltKit

// Timeline v2 parity (APP-API-CONTRACT 69.5). The fixtures are the server's directory, not a copy: SwiftPM would have to
// duplicate them into the test bundle, and the contract says the app loads that directory and does not copy the JSON.
// `#filePath` is this source file. Five directories up is the repo root, then the path named in index.json.
//
//   apple/CobaltKit/Tests/CobaltKitTests/EditorTimelineV2Tests.swift
//   → deploy/cloudflare/editor/helper/test/fixtures/timeline-v2

private func fixtureRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("deploy/cloudflare/editor/helper/test/fixtures/timeline-v2", isDirectory: true)
}

private func timeline(of result: EditParseResult) -> EditTimeline? {
    if case .ok(let timeline) = result { return timeline }
    return nil
}

private func failure(of result: EditParseResult) -> (String, String)? {
    if case .failed(let code, let path) = result { return (code, path) }
    return nil
}

private let story = EditCanvas(w: 1080, h: 1920, fps: 30)
private let itemA = "AAAAAAAAAAAAAAAA"
private let itemB = "BBBBBBBBBBBBBBBB"

private func lane(_ id: String, _ lane: Int, at: Double, out: Double, item: String = itemA, frame: EditFrame? = nil) -> EditLaneClip {
    EditLaneClip(id: id, item: item, lane: lane, at: at, in: 0, out: out, frame: frame)
}

struct EditTimelineV2FixtureTests {
    @Test func theFixtureIndexNamesTheServerDirectory() throws {
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureRoot().appendingPathComponent("index.json"))) as! [String: Any]
        #expect(index["path"] as? String == "deploy/cloudflare/editor/helper/test/fixtures/timeline-v2")
        let listed = index["cases"] as? [String] ?? []
        let files = try FileManager.default.contentsOfDirectory(atPath: fixtureRoot().path)
            .filter { $0.hasSuffix(".json") && $0 != "index.json" }
            .map { String($0.dropLast(5)) }
            .sorted()
        #expect(listed.sorted() == files)
    }

    @Test func everySharedFixtureMatchesTheServer() throws {
        let root = fixtureRoot()
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("index.json"))) as! [String: Any]
        let cases = try #require(index["cases"] as? [String])
        #expect(cases.count >= 8)
        for name in cases {
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("\(name).json"))) as! [String: Any]
            let input = try JSONSerialization.data(withJSONObject: try #require(raw["input"]))
            let parsed = EditLanes.parse(input)
            let expect = try #require(raw["parse"] as? [String: Any])
            if expect["ok"] as? Bool == true {
                let timeline = try #require(timeline(of: parsed), "\(name) \(parsed)")
                #expect(EditLanes.canonical(timeline) == expect["canonical"] as? String, "\(name)")
                let again = try EditJSON.decode(Data((expect["canonical"] as! String).utf8))
                #expect(EditLanes.canonical(again) == expect["canonical"] as? String, "\(name) stable")
                #expect(EditLanes.clipCount(timeline) == raw["clip_count"] as? Int, "\(name) count")
                #expect(EditLanes.coverItem(timeline) == raw["cover_item"] as? String, "\(name) cover")
                #expect(EditTiming(timeline).frames == raw["timing_frames"] as? Int, "\(name) frames")
            } else {
                let got = try #require(failure(of: parsed), "\(name)")
                #expect(got.0 == expect["code"] as? String, "\(name)")
                #expect(got.1 == expect["path"] as? String, "\(name)")
            }
            if let toV2 = raw["to_v2"] as? [String: Any] {
                let v1 = try #require(timeline(of: parsed), "\(name)")
                let converted = EditLanes.v1ToV2(v1)
                if toV2["ok"] as? Bool == true {
                    let v2 = try #require(timeline(of: converted), "\(name) \(converted)")
                    #expect(EditLanes.canonical(v2) == toV2["canonical"] as? String, "\(name) to v2")
                } else {
                    let got = try #require(failure(of: converted), "\(name)")
                    #expect(got.0 == toV2["code"] as? String && got.1 == toV2["path"] as? String, "\(name) to v2")
                }
            }
            if let toV1 = raw["to_v1"] as? [String: Any] {
                let source: EditTimeline
                if let toV2 = raw["to_v2"] as? [String: Any], toV2["ok"] as? Bool == true {
                    let v1 = try #require(timeline(of: parsed), "\(name)")
                    source = try #require(timeline(of: EditLanes.v1ToV2(v1)), "\(name)")
                } else {
                    source = try #require(timeline(of: parsed), "\(name)")
                }
                var kinds: [String: String?]?
                if let listed = raw["kinds"] as? [String: String] { kinds = listed.mapValues { $0 } }
                let converted = EditLanes.v2ToV1(source, kinds: kinds)
                if toV1["ok"] as? Bool == true {
                    let v1 = try #require(timeline(of: converted), "\(name) \(converted)")
                    #expect(EditLanes.canonical(v1) == toV1["canonical"] as? String, "\(name) to v1")
                    if (raw["input"] as? [String: Any])?["version"] as? Int == 1 {
                        #expect(toV1["canonical"] as? String == expect["canonical"] as? String, "\(name) round trip")
                    }
                } else {
                    let got = try #require(failure(of: converted), "\(name) \(converted)")
                    #expect(got.0 == toV1["code"] as? String && got.1 == toV1["path"] as? String, "\(name) to v1")
                }
            }
        }
    }
}

struct EditTimelineV2ModelTests {
    @Test func aGapIsBlackAndIsNotVersionOne() {
        let t = EditTimeline(canvas: story, clips: [lane("a", 0, at: 0, out: 1), lane("b", 0, at: 3, out: 1)])
        #expect(EditTiming(t).frames == 120)
        #expect(EditTiming(t).main.map(\.start) == [0, 90])
        let back = EditLanes.v2ToV1(t, kinds: [itemA: "video"])
        #expect(failure(of: back)?.0 == "error.edit.needs_timeline_v2")
        #expect(failure(of: back)?.1 == "clips[1].at")
    }

    @Test func picturesOnLaneZeroStayVersionTwo() {
        let t = EditTimeline(canvas: story, clips: [lane("p", 0, at: 0, out: 3, item: "HHHHHHHHHHHHHHHH")])
        let problems = EditValidation.check(t, sources: [
            "HHHHHHHHHHHHHHHH": EditSource(id: "HHHHHHHHHHHHHHHH", name: "p.png", kind: .photo, width: 100, height: 100),
        ])
        #expect(!problems.contains { if case .notVideo = $0 { true } else { false } })
        #expect(failure(of: EditLanes.v2ToV1(t, kinds: ["HHHHHHHHHHHHHHHH": "photo"]))?.1 == "clips[0].item")
    }

    @Test func laneSpansLeaveAGapBlackAndDrawBottomToTop() {
        let t = EditTimeline(canvas: story, clips: [
            lane("top", 2, at: 0, out: 1, item: itemB),
            lane("a", 0, at: 0, out: 1),
            lane("b", 0, at: 3, out: 1),
        ])
        let spans = EditComposition.laneSpans(t, timing: EditTiming(t))
        #expect(spans.map(\.start) == [0, 30, 90])
        #expect(spans[0].clipIDs == ["a", "top"])
        #expect(spans[1].clipIDs.isEmpty)
        #expect(spans[2].clipIDs == ["b"])
    }

    @Test func aHiddenClipIsNotDrawnAndStillEndsTheEdit() {
        var hidden = lane("a", 0, at: 0, out: 2)
        hidden.hidden = true
        let t = EditTimeline(canvas: story, clips: [hidden])
        let spans = EditComposition.laneSpans(t, timing: EditTiming(t))
        #expect(EditTiming(t).frames == 60)
        #expect(spans.allSatisfy { $0.clipIDs.isEmpty })
    }

    @Test func intervalColouringSharesATrackWhenClipsDoNotOverlap() {
        let same = EditLanes.colorTracks([("a", 0, 30), ("b", 30, 60)])
        #expect(same.map(\.1) == [0, 0])
        let over = EditLanes.colorTracks([("a", 0, 40), ("b", 10, 50), ("c", 40, 70)])
        #expect(over.map(\.1) == [0, 1, 0])
    }
}

@MainActor
struct EditTimelineV2OpsTests {
    private func open(_ clips: [EditLaneClip], version: Int = 2) -> EditSession {
        let h = Harness(.happy)
        h.ctx.capabilities.limits.editTimelineVersion = version
        h.ctx.capabilities.limits.editOverlayTracks = 64
        let timeline = EditTimeline(canvas: story, clips: clips)
        let project = EditProject(
            id: "AbCdEfGhIjKlMnOp", title: "lanes", revision: 1, timeline: timeline, canvas: story, duration: 4,
            clipCount: clips.count, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        var summary = project
        summary.timeline = nil
        let cache = EditSourceCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("lanes-\(UUID().uuidString)"),
            client: { [ctx = h.ctx] in ctx.client }, provider: { _ in nil })
        return EditSession(
            project: summary, timeline: timeline, sources: [:], context: h.ctx, cache: cache,
            onProject: { _ in }, onRender: { _ in })
    }

    private func at(_ session: EditSession, _ id: String) -> Double? {
        session.timeline.clips.first { $0.id == id }?.at
    }

    @Test func leavingLaneZeroClosesTheGapUnlessAskedToKeepIt() {
        let session = open([lane("a", 0, at: 0, out: 1), lane("b", 0, at: 1, out: 1)])
        defer { session.tearDown() }
        let before = session.timeline
        #expect(session.moveClip(id: "a", toLane: 1, at: 0))
        #expect(at(session, "b") == 0)
        #expect(session.timeline.clips.first { $0.id == "a" }?.lane == 1)
        session.undo()
        #expect(session.timeline == before)
        #expect(session.moveClip(id: "a", toLane: 1, at: 0, keepGap: true))
        #expect(at(session, "b") == 1)
        #expect(session.laneRefusal == nil)
    }

    @Test func deleteOnLaneZeroClosesTheGap() {
        let session = open([lane("a", 0, at: 0, out: 1), lane("b", 0, at: 1, out: 1)])
        defer { session.tearDown() }
        session.remove(.main("a"))
        #expect(session.timeline.clips.map(\.id) == ["b"])
        #expect(at(session, "b") == 0)
    }

    @Test func droppingOnATakenSpotOpensALaneAboveIt() {
        let session = open([lane("a", 0, at: 0, out: 2), lane("b", 0, at: 2, out: 1)])
        defer { session.tearDown() }
        #expect(session.moveClip(id: "b", toLane: 0, at: 0))
        #expect(session.timeline.clips.first { $0.id == "a" }?.lane == 0)
        #expect(session.timeline.clips.first { $0.id == "b" }?.lane == 1)
        #expect(at(session, "b") == 0)
    }

    @Test func insertLaneAboveShiftsHigherLanesAndStopsAtSixtyFour() {
        let session = open([lane("lo", 0, at: 0, out: 1), lane("hi", 2, at: 0, out: 1, item: itemB)])
        defer { session.tearDown() }
        #expect(session.insertLaneAbove(0))
        #expect(session.timeline.clips.first { $0.id == "lo" }?.lane == 0)
        #expect(session.timeline.clips.first { $0.id == "hi" }?.lane == 3)
        var full: [EditLaneClip] = []
        for laneNumber in 0..<64 {
            full.append(lane("l\(laneNumber)", laneNumber, at: 0, out: 1))
        }
        let packed = open(full)
        defer { packed.tearDown() }
        #expect(!packed.insertLaneAbove(10))
        #expect(packed.laneRefusal == EditLanes.lanesFullMessage)
        #expect(packed.timeline.clips.map(\.lane) == Array(0..<64))
    }

    @Test func splitDuplicateHideAndLayerAreOneUndoStep() {
        let session = open([lane("a", 0, at: 0, out: 2), lane("c", 1, at: 0, out: 2, item: itemB, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3))])
        defer { session.tearDown() }
        session.split(clip: "a", atFrame: 30)
        #expect(session.timeline.clips.filter { $0.lane == 0 }.count == 2)
        session.undo()
        #expect(session.timeline.clips.filter { $0.lane == 0 }.count == 1)
        #expect(session.duplicateClip(id: "a"))
        #expect(session.timeline.clips.filter { $0.lane == 0 }.count == 2)
        #expect(at(session, session.timeline.clips.last!.id) == 2)
        session.setClipHidden(id: "c", true)
        #expect(session.timeline.clips.first { $0.id == "c" }?.hidden == true)
        #expect(session.moveClipLayer(id: "a", by: 1) == false)
        #expect(session.laneRefusal == EditLanes.spotTakenMessage)
        #expect(session.timeline.clips.first { $0.id == "a" }?.lane == 0)
    }

    @Test func anOlderServerRefusesAMoveItCannotSave() {
        let session = open([
            lane("a", 0, at: 0, out: 2),
            lane("b", 1, at: 0, out: 1, item: itemB, frame: EditFrame(x: 0.2, y: 0.2, w: 0.3)),
        ], version: 1)
        defer { session.tearDown() }
        let before = session.timeline
        #expect(!session.moveClip(id: "a", toLane: 2, at: 0, keepGap: true))
        #expect(session.laneRefusal == EditLanes.needsServerMessage)
        #expect(session.timeline == before)
        #expect(session.moveClip(id: "b", toLane: 2, at: 0.5))
        #expect(session.timeline.clips.first { $0.id == "b" }?.lane == 2)
    }

    @Test func needsTimelineV2IsUpdateNeeded() {
        let error = EditError(
            code: "error.edit.needs_timeline_v2", path: "clips[0].key", items: [], project: nil,
            title: "beach", projectID: "AbCdEfGhIjKlMnOp")
        guard case .needsTimelineV2(let path, let title, let id) = error else {
            Issue.record("\(error)")
            return
        }
        #expect(path == "clips[0].key" && title == "beach" && id == "AbCdEfGhIjKlMnOp")
    }
}

// MARK: - Turned and off-canvas frames (APP-API-CONTRACT 69.7)

private func parseFrameDoc(_ frame: String) -> EditParseResult {
    let json = """
    {"version":2,"canvas":{"w":1080,"h":1920,"fps":30},"clips":[
      {"id":"b","item":"AAAAAAAAAAAAAAAA","lane":0,"at":0,"in":0,"out":2},
      {"id":"t","item":"BBBBBBBBBBBBBBBB","lane":1,"at":0,"in":0,"out":2,"frame":\(frame)}]}
    """
    return EditLanes.parse(Data(json.utf8))
}

struct EditFrameTurnModelTests {
    @Test func aFrameWithoutRKeepsItsBytesAndOneWithRRoundTrips() throws {
        let plain = try JSONEncoder().encode(EditFrame(x: 0.1, y: 0.2, w: 0.3))
        #expect(!String(decoding: plain, as: UTF8.self).contains("\"r\""))
        #expect(EditFrame(x: 0.1, y: 0.2, w: 0.3) == EditFrame(x: 0.1, y: 0.2, w: 0.3, r: 0))
        let old = try JSONDecoder().decode(EditFrame.self, from: Data(#"{"x":0.1,"y":0.2,"w":0.3}"#.utf8))
        #expect(old.r == 0)
        let turned = EditFrame(x: -0.1, y: 0.2, w: 0.3, r: -12.4)
        let data = try JSONEncoder().encode(turned)
        #expect(String(decoding: data, as: UTF8.self).contains("\"r\":-12.4"))
        #expect(try JSONDecoder().decode(EditFrame.self, from: data) == turned)
        // a clip: canonical bytes carry r only when it is not 0
        let clip = EditLaneClip(id: "t", item: itemB, lane: 1, at: 0, in: 0, out: 2, frame: EditFrame(x: 0.2, y: 0.1, w: 0.5, r: 0))
        let t = EditTimeline(canvas: story, clips: [lane("b", 0, at: 0, out: 2), clip])
        #expect(EditLanes.canonical(t)?.contains("\"r\"") == false)
        var turnedClip = clip
        turnedClip.frame?.r = 45.04
        let t2 = EditTimeline(canvas: story, clips: [lane("b", 0, at: 0, out: 2), turnedClip])
        #expect(EditLanes.canonical(t2)?.contains("\"frame\":{\"r\":45,\"w\":0.5,\"x\":0.2,\"y\":0.1}") == true)
    }

    @Test func roundingIsHalfAwayFromZeroAndNeverMinusZero() {
        #expect(EditJSON.fraction(-0.00005) == -0.0001)
        #expect(EditJSON.fraction(0.00005) == 0.0001)
        #expect(EditJSON.fraction(-0.12345) == -0.1235)
        #expect(EditJSON.fraction(-0.00004) == 0 && EditJSON.fraction(-0.00004).sign == .plus)
        #expect(EditJSON.angle(-12.35) == -12.4)
        #expect(EditJSON.angle(12.35) == 12.4)
        #expect(EditJSON.angle(-0.04) == 0 && EditJSON.angle(-0.04).sign == .plus)
        let t = EditTimeline(canvas: story, clips: [
            lane("b", 0, at: 0, out: 2),
            lane("t", 1, at: 0, out: 2, item: itemB, frame: EditFrame(x: -0.00005, y: -0.12345, w: 1.50004, r: -12.35)),
        ])
        let f = EditJSON.rounded(t).clips[1].frame
        #expect(f == EditFrame(x: -0.0001, y: -0.1235, w: 1.5, r: -12.4))
    }

    @Test func theStrictParseHoldsTheFrameBounds() {
        func code(_ frame: String) -> String {
            switch parseFrameDoc(frame) {
            case .ok: return "ok"
            case .failed(let code, let path): return "\(code) \(path)"
            }
        }
        #expect(code(#"{"x":0.2,"y":0.1,"w":0.5,"r":-12.35}"#) == "ok")
        #expect(code(#"{"x":-0.5,"y":-0.05,"w":4}"#) == "ok")                                   // 4 canvas widths
        #expect(code(#"{"x":0,"y":0,"w":4.00004}"#) == "ok")                                    // rounds to 4
        #expect(code(#"{"x":0,"y":0,"w":4.0001}"#) == "error.edit.range clips[1].frame.w")
        #expect(code(#"{"x":0,"y":0,"w":0.04}"#) == "error.edit.range clips[1].frame.w")
        #expect(code(#"{"x":0,"y":0,"w":-1}"#) == "error.edit.range clips[1].frame.w")
        #expect(code(#"{"x":1,"y":0,"w":0.5}"#) == "error.edit.range clips[1].frame.x")          // x < 1
        #expect(code(#"{"x":0.9999,"y":0,"w":0.5}"#) == "ok")
        #expect(code(#"{"x":-0.5,"y":0,"w":0.5}"#) == "error.edit.range clips[1].frame.x")      // x + w > 0
        #expect(code(#"{"x":-0.4999,"y":0,"w":0.5}"#) == "ok")
        #expect(code(#"{"x":0,"y":1,"w":0.5}"#) == "error.edit.range clips[1].frame.y")         // y < 1
        #expect(code(#"{"x":0,"y":-3,"w":0.5}"#) == "ok")                                       // y + h needs the size
        #expect(code(#"{"x":0,"y":-8,"w":0.5}"#) == "ok")
        #expect(code(#"{"x":0,"y":0,"w":0.5,"r":180}"#) == "ok")
        #expect(code(#"{"x":0,"y":0,"w":0.5,"r":-180}"#) == "ok")
        #expect(code(#"{"x":0,"y":0,"w":0.5,"r":180.04}"#) == "ok")                             // rounds to 180
        #expect(code(#"{"x":0,"y":0,"w":0.5,"r":180.06}"#) == "error.edit.range clips[1].frame.r")
        #expect(code(#"{"x":0,"y":0,"w":0.5,"r":"left"}"#) == "error.edit.bad_request clips[1].frame.r")
        #expect(code(#"{"x":0,"y":0,"w":0.5,"q":1}"#) == "error.edit.bad_request clips[1].frame.q")
        #expect(code(#"{"x":0,"y":0}"#) == "error.edit.bad_request clips[1].frame.w")
        // r of 0 is not kept
        if case .ok(let t) = parseFrameDoc(#"{"x":0.2,"y":0.1,"w":0.5,"r":0.04}"#) {
            #expect(EditLanes.canonical(t)?.contains("\"r\"") == false)
        } else {
            Issue.record("r 0.04 should parse")
        }
    }

    @Test func aVersionOneOverlayStillRefusesAnUnknownKeyAndAnOutsideFrame() {
        let json = """
        {"version":1,"canvas":{"w":1080,"h":1920,"fps":30},"main":[{"id":"cMain0001","item":"AAAAAAAAAAAAAAAA","in":0,"out":2,"speed":1,"fit":"fill","volume":1,"muted":false}],
         "overlay":[{"id":"cOver0001","item":"BBBBBBBBBBBBBBBB","at":0,"in":0,"out":1,"frame":{"x":-0.1,"y":0,"w":0.5},"opacity":1,"volume":1,"muted":false}]}
        """
        guard case .failed(let code, let path) = EditLanes.parse(Data(json.utf8)) else {
            Issue.record("a version 1 overlay must stay inside the canvas")
            return
        }
        #expect(code == "error.edit.range" && path == "overlay[0].frame.x")
        let withR = json.replacingOccurrences(of: #""x":-0.1,"y":0,"w":0.5"#, with: #""x":0.1,"y":0,"w":0.5,"r":10"#)
        guard case .failed(let code2, let path2) = EditLanes.parse(Data(withR.utf8)) else {
            Issue.record("r is not a version 1 key")
            return
        }
        #expect(code2 == "error.edit.bad_request" && path2 == "overlay[0].frame.r")
    }

    @Test func validationHoldsTheBoundsAtTheEdges() {
        // a story canvas and a story picture: the box is as tall as it is wide in canvas fractions (h = w)
        let sources = [
            itemA: EditSource(id: itemA, name: "a.mp4", kind: .video, width: 1080, height: 1920, duration: 10),
            itemB: EditSource(id: itemB, name: "b.png", kind: .photo, width: 1080, height: 1920),
        ]
        func problems(_ frame: EditFrame) -> [EditProblem] {
            let t = EditTimeline(canvas: story, clips: [lane("b", 0, at: 0, out: 2), lane("t", 1, at: 0, out: 2, item: itemB, frame: frame)])
            return EditValidation.check(t, sources: sources).filter { if case .range = $0 { true } else { false } }
        }
        #expect(problems(EditFrame(x: -0.2, y: -0.2, w: 4)).isEmpty)
        #expect(problems(EditFrame(x: 0.2, y: 0.1, w: 0.5, r: 180)).isEmpty)
        #expect(problems(EditFrame(x: 0.2, y: 0.1, w: 0.5, r: -180)).isEmpty)
        #expect(problems(EditFrame(x: 0.2, y: 0.1, w: 0.5, r: 181)) == [.range(path: "clips[1].frame.r")])
        #expect(problems(EditFrame(x: 0.2, y: 0.1, w: 4.0001)) == [.range(path: "clips[1].frame.w")])
        #expect(problems(EditFrame(x: 0.2, y: 0.1, w: 0.04)) == [.range(path: "clips[1].frame.w")])
        #expect(problems(EditFrame(x: 1, y: 0, w: 0.5)) == [.range(path: "clips[1].frame.x")])
        #expect(problems(EditFrame(x: 0.9999, y: 0, w: 0.5)).isEmpty)
        #expect(problems(EditFrame(x: -0.5, y: 0, w: 0.5)) == [.range(path: "clips[1].frame.x")])
        #expect(problems(EditFrame(x: -0.4999, y: 0, w: 0.5)).isEmpty)
        #expect(problems(EditFrame(x: 0, y: 1, w: 0.5)) == [.range(path: "clips[1].frame.y")])
        #expect(problems(EditFrame(x: 0, y: 0.9999, w: 0.5)).isEmpty)                 // part of it hangs off the bottom: fine
        #expect(problems(EditFrame(x: 0, y: -0.5, w: 0.5)) == [.range(path: "clips[1].frame.y")])        // y + h = 0
        #expect(problems(EditFrame(x: 0, y: -0.4999, w: 0.5)).isEmpty)
        // the size of the picture decides y + h: a wide picture is short
        let wide = [itemB: EditSource(id: itemB, name: "b.png", kind: .photo, width: 1920, height: 1080)]
        let t = EditTimeline(canvas: story, clips: [lane("b", 0, at: 0, out: 2), lane("t", 1, at: 0, out: 2, item: itemB, frame: EditFrame(x: 0, y: -0.2, w: 0.5))])
        #expect(EditValidation.check(t, sources: wide).contains(.range(path: "clips[1].frame.y")))      // h = 0.5 * 1080/1920 * 1080/1920 ≈ 0.158
        // no source size: the check is skipped, as the server's parse does
        #expect(EditValidation.check(t, sources: [:]).filter { if case .range = $0 { true } else { false } }.isEmpty)
    }

    @Test func versionTwoToOneRefusesATurnedOrOutsideFrame() {
        func attempt(_ frame: EditFrame) -> (String, String)? {
            let t = EditTimeline(canvas: story, clips: [lane("b", 0, at: 0, out: 2), lane("t", 1, at: 0, out: 2, item: itemB, frame: frame)])
            return failure(of: EditLanes.v2ToV1(t, kinds: [itemA: "video", itemB: "video"]))
        }
        #expect(attempt(EditFrame(x: 0.2, y: 0.1, w: 0.5)) == nil)
        #expect(attempt(EditFrame(x: 0, y: 0, w: 1)) == nil)
        for frame in [
            EditFrame(x: 0.2, y: 0.1, w: 0.5, r: 12.3), EditFrame(x: -0.1, y: 0.1, w: 0.5), EditFrame(x: 0.2, y: -0.1, w: 0.5),
            EditFrame(x: 0, y: 0, w: 1.5), EditFrame(x: 0.6, y: 0.1, w: 0.5),
        ] {
            let got = attempt(frame)
            #expect(got?.0 == "error.edit.needs_timeline_v2" && got?.1 == "clips[1].frame", "\(frame)")
        }
    }
}

struct EditFrameTurnGeometryTests {
    private let canvas = EditCanvas(w: 1080, h: 1920, fps: 30)
    private let portrait = PixelSize(w: 1080, h: 1920)

    @Test func anUnturnedBoxIsLikeTheOverlayBoxButNotPushedBackInside() throws {
        let inside = try #require(EditGeometry.laneBox(display: portrait, frame: EditFrame(x: 0.2, y: 0.1, w: 0.5), canvas: canvas))
        #expect(PixelRect(x: inside.x, y: inside.y, w: inside.w, h: inside.h) == EditGeometry.overlay(display: portrait, frame: EditFrame(x: 0.2, y: 0.1, w: 0.5), canvas: canvas))
        #expect(inside.turned == nil && inside.bounds == PixelRect(x: 216, y: 192, w: 540, h: 960))
        let off = try #require(EditGeometry.laneBox(display: portrait, frame: EditFrame(x: -0.3, y: -0.1, w: 1.5), canvas: canvas))
        #expect(off.x == -324 && off.y == -192 && off.w == 1620 && off.h == 2880)
        let clamped = EditGeometry.overlay(display: portrait, frame: EditFrame(x: -0.3, y: -0.1, w: 1.5), canvas: canvas)
        #expect(clamped.x == 0 && clamped.y == 0)                                    // the v1 box is pushed back
        let widest = try #require(EditGeometry.laneBox(display: portrait, frame: EditFrame(x: 0, y: 0, w: 4), canvas: canvas))
        #expect(widest.w == 4320)
    }

    @Test func aBoxWithNothingOnTheCanvasDrawsNothing() {
        #expect(EditGeometry.laneBox(display: portrait, frame: EditFrame(x: -0.5, y: 0, w: 0.5), canvas: canvas) == nil)    // x + w = 0
        #expect(EditGeometry.laneBox(display: portrait, frame: EditFrame(x: 0.9999, y: 0, w: 0.5), canvas: canvas) == nil)   // 1079.89 -> 1080
        #expect(EditGeometry.laneBox(display: portrait, frame: EditFrame(x: 0.5, y: 1, w: 0.5), canvas: canvas) == nil)
        #expect(EditGeometry.laneBox(display: portrait, frame: EditFrame(x: 0.5, y: -0.5, w: 0.5), canvas: canvas) == nil)    // y + h = 0
        #expect(EditGeometry.laneBox(display: portrait, frame: EditFrame(x: -0.4, y: 0, w: 0.5), canvas: canvas) != nil)
        // a turn can bring a box that missed back onto the canvas: the test is on the box that holds the turned picture
        let tall = EditFrame(x: -0.5, y: 0, w: 0.5, r: 90)
        #expect(EditGeometry.laneBox(display: portrait, frame: tall, canvas: canvas) != nil)
    }

    @Test func aTurnedBoxTurnsAboutItsCentreAndTheCentreStaysPut() throws {
        let box = try #require(EditGeometry.laneBox(display: portrait, frame: EditFrame(x: 0.2, y: 0.1, w: 0.5, r: 90), canvas: canvas))
        #expect(box.w == 540 && box.h == 960)
        #expect(box.turned == PixelRect(x: 6, y: 402, w: 960, h: 540))
        #expect(box.center == CGPoint(x: 486, y: 672))
        // the top-left corner of the portrait box goes clockwise to the top-right of the landscape one
        let tl = box.corners[0]
        #expect(abs(tl.x - 966) < 1e-9 && abs(tl.y - 402) < 1e-9)
        #expect(box.contains(CGPoint(x: 486, y: 672)))
        #expect(box.contains(CGPoint(x: 900, y: 672)))             // only the turned picture is out there
        #expect(!box.contains(CGPoint(x: 486, y: 200)))            // only the unturned one was up there
        // Core Image: the picture's bottom-left lands on the turned box's top-left (y up)
        let m = box.coreImageTransform(canvasHeight: 1920)
        let p = CGPoint(x: 0, y: 0).applying(m)
        #expect(abs(p.x - 6) < 1e-9 && abs(p.y - 1518) < 1e-9)
        let centre = CGPoint(x: 270, y: 480).applying(m)
        #expect(abs(centre.x - 486) < 1e-9 && abs(centre.y - (1920 - 672)) < 1e-9)
        // 12.35 turned: the holding box is even-sized and keeps the same centre
        let odd = try #require(EditGeometry.laneBox(display: portrait, frame: EditFrame(x: 0.2, y: 0.1, w: 0.5, r: -12.4), canvas: canvas))
        let rot = try #require(odd.turned)
        #expect(rot.w % 2 == 0 && rot.h % 2 == 0)
        #expect(abs(Double(rot.x) + Double(rot.w) / 2 - odd.center.x) < 1e-9 && abs(Double(rot.y) + Double(rot.h) / 2 - odd.center.y) < 1e-9)
    }

    @Test func theFitBoxIsTheBoxFitOrFillGave() throws {
        let wide = PixelSize(w: 1920, h: 1080)
        let fill = try #require(EditGeometry.fitFrame(display: wide, crop: nil, fit: .fill, canvas: canvas))
        #expect(fill.w > 3.1 && fill.w < 3.2 && fill.x < -1 && fill.y == 0)
        // drawn as a frame, the box is the one fill made (to the pixel)
        let g = try #require(EditGeometry.main(display: wide, crop: nil, fit: .fill, canvas: canvas))
        let box = try #require(EditGeometry.laneBox(display: wide, frame: fill, canvas: canvas))
        #expect(abs(box.w - g.scaled.w) <= 2 && abs(box.h - g.scaled.h) <= 2 && abs(box.x - g.place.x) <= 1 && abs(box.y - g.place.y) <= 1)
        let fit = try #require(EditGeometry.fitFrame(display: wide, crop: nil, fit: .fit, canvas: canvas))
        #expect(fit.w == 1 && fit.x == 0 && fit.y > 0.3)
        // a very wide picture cannot be wider than 4 canvases: it keeps its centre
        let strip = try #require(EditGeometry.fitFrame(display: PixelSize(w: 10_000, h: 500), crop: nil, fit: .fill, canvas: canvas))
        #expect(strip.w == 4 && abs(strip.x + strip.w / 2 - 0.5) < 1e-3)
    }
}

struct EditFrameTurnComposerTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let canvas = EditCanvas(w: 200, h: 200, fps: 30)

    private func solid(_ w: Int, _ h: Int) -> CIImage {
        CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func black() -> CIImage {
        CIImage(color: CIColor.black).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    /// Red channel at canvas pixel (x, y), top row first.
    private func red(_ image: CIImage, _ x: Int, _ y: Int) -> Int {
        var buffer = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &buffer, rowBytes: 4, bounds: CGRect(x: x, y: 200 - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Int(buffer[0])
    }

    private func draw(_ frame: EditFrame) -> CIImage {
        let clip = EditLaneClip(id: "t", item: itemB, lane: 1, at: 0, in: 0, out: 1, frame: frame)
        return EditFrameComposer.drawLaneBox(solid(100, 50), clip: clip, frame: frame, canvas: canvas, under: black())
    }

    @Test func aTurnedPictureIsDrawnAboutItsCentreWithSeeThroughCorners() {
        // 100 x 50 at (50, 75); a quarter turn makes it 50 x 100 about (100, 100)
        let turned = draw(EditFrame(x: 0.25, y: 0.375, w: 0.5, r: 90))
        #expect(red(turned, 100, 100) > 240)
        #expect(red(turned, 100, 60) > 240)          // the turned picture reaches up here
        #expect(red(turned, 60, 100) < 15)           // and no longer out here, where the unturned one was
        let straight = draw(EditFrame(x: 0.25, y: 0.375, w: 0.5))
        #expect(red(straight, 60, 100) > 240 && red(straight, 100, 60) < 15)
        // 45 degrees: the corner of the holding box is not covered, so the black under it shows
        let slant = draw(EditFrame(x: 0.25, y: 0.375, w: 0.5, r: 45))
        #expect(red(slant, 100, 100) > 240)
        #expect(red(slant, 52, 52) < 15)          // the corner of the holding box
    }

    @Test func aBoxPastTheEdgeIsNotPushedBackAndOneOffTheCanvasDrawsNothing() {
        // x = -0.3 -> the box covers -60 ... 40
        let past = draw(EditFrame(x: -0.3, y: 0.375, w: 0.5))
        #expect(red(past, 10, 100) > 240)
        #expect(red(past, 60, 100) < 15)
        let gone = draw(EditFrame(x: -0.6, y: 0.375, w: 0.5))
        #expect((0..<200).allSatisfy { red(gone, $0, 100) < 15 })
    }
}

@MainActor
struct EditFrameTurnSessionTests {
    private func open(_ clips: [EditLaneClip], version: Int = 2) -> EditSession {
        open(timeline: EditTimeline(canvas: story, clips: clips), version: version)
    }

    private func open(timeline: EditTimeline, version: Int = 2) -> EditSession {
        let h = Harness(.happy)
        h.ctx.capabilities.limits.editTimelineVersion = version
        h.ctx.capabilities.limits.editOverlayTracks = 64
        let project = EditProject(
            id: "AbCdEfGhIjKlMnOp", title: "lanes", revision: 1, timeline: timeline, canvas: story, duration: 4,
            clipCount: EditLanes.clipCount(timeline), createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        var summary = project
        summary.timeline = nil
        let cache = EditSourceCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("lanes-\(UUID().uuidString)"),
            client: { [ctx = h.ctx] in ctx.client }, provider: { _ in nil })
        return EditSession(
            project: summary, timeline: timeline,
            sources: [
                itemA: EditSource(id: itemA, name: "a.mp4", kind: .video, width: 1920, height: 1080, duration: 10),
                itemB: EditSource(id: itemB, name: "b.png", kind: .photo, width: 1080, height: 1920),
            ],
            context: h.ctx, cache: cache, onProject: { _ in }, onRender: { _ in })
    }

    private func frame(_ session: EditSession, _ id: String) -> EditFrame? {
        session.timeline.clips.first { $0.id == id }?.frame
    }

    @Test func aClipWithNoFrameGetsTheBoxFillGaveIt() throws {
        let session = open([lane("a", 0, at: 0, out: 2)])
        defer { session.tearDown() }
        #expect(frame(session, "a") == nil)
        let box = try #require(session.frameBox(ofClip: "a"))
        #expect(box.w > 3.1 && box.w < 3.2 && box.x < -1)
        #expect(session.pictureSize(ofClip: "a") == PixelSize(w: 1920, h: 1080))
        // the first turn starts from that box, so it does not jump
        var turned = box
        turned.r = 15
        #expect(session.setClipFrame(id: "a", turned))
        #expect(frame(session, "a") == EditFrame(x: box.x, y: box.y, w: box.w, r: 15))
        #expect(session.frameBox(ofClip: "a") == frame(session, "a"))
    }

    @Test func aGestureIsOneUndoStepAndUndoPutsTheOldFrameBack() {
        let first = EditFrame(x: 0.1, y: 0.1, w: 0.3)
        let session = open([lane("a", 0, at: 0, out: 2), lane("c", 1, at: 0, out: 2, item: itemB, frame: first)])
        defer { session.tearDown() }
        session.beginGesture()
        for step in 1...6 {
            #expect(session.setClipFrame(id: "c", EditFrame(x: 0.1 - 0.05 * Double(step), y: 0.1, w: 0.3, r: 10 * Double(step))))
        }
        session.endGesture()
        #expect(frame(session, "c") == EditFrame(x: -0.2, y: 0.1, w: 0.3, r: 60))
        session.undo()
        #expect(frame(session, "c") == first)
        session.redo()
        #expect(frame(session, "c")?.r == 60)
        session.undo()
        #expect(frame(session, "c") == first && !session.canUndo)
    }

    @Test func theFrameIsHeldToTheBoundsAndTheTurnWraps() {
        let session = open([lane("a", 0, at: 0, out: 2), lane("c", 1, at: 0, out: 2, item: itemB, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3))])
        defer { session.tearDown() }
        #expect(session.setClipFrame(id: "c", EditFrame(x: -5, y: 7, w: 9, r: 190)))
        let held = frame(session, "c")
        #expect(held?.w == 4 && held?.r == -170)
        #expect((held?.x ?? 9) + (held?.w ?? 0) > 0 && (held?.y ?? 9) < 1)
        #expect(session.setClipFrame(id: "c", EditFrame(x: 0.2, y: -9, w: 0.5, r: .nan)))
        let low = frame(session, "c")
        // a story picture: h = w, so y stays above -w
        #expect((low?.y ?? 0) + 0.5 > 0 && low?.r == 0)
        #expect(session.problems.isEmpty || !session.problems.contains { if case .range = $0 { true } else { false } })
        #expect(!session.setClipFrame(id: "nope", EditFrame(x: 0, y: 0, w: 1)))
    }

    @Test func aVersionOneServerRefusesATurnAndKeepsAFrameInsideTheCanvas() {
        let session = open([lane("a", 0, at: 0, out: 2), lane("c", 1, at: 0, out: 2, item: itemB, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3))], version: 1)
        defer { session.tearDown() }
        let before = session.timeline
        #expect(!session.setClipFrame(id: "c", EditFrame(x: 0.1, y: 0.1, w: 0.3, r: 20)))
        #expect(session.laneRefusal == EditLanes.needsServerMessage)
        #expect(!session.setClipFrame(id: "c", EditFrame(x: -0.1, y: 0.1, w: 0.3)))
        #expect(session.timeline == before)
        #expect(session.setClipFrame(id: "c", EditFrame(x: 0.4, y: 0.3, w: 0.3)))
        #expect(session.laneRefusal == nil && frame(session, "c") == EditFrame(x: 0.4, y: 0.3, w: 0.3))
    }

    @Test func aVersionOneProjectIsVersionTwoWhenItOpensAndTurnsFromThere() {
        let main = EditClip(id: "cMain0001", item: itemA, in: 0, out: 2)
        let overlay = EditOverlay(id: "cOver0001", item: itemB, at: 0, in: 0, out: 1, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3))
        let session = open(timeline: EditTimeline(version: 1, canvas: story, main: [main], overlay: [overlay]))
        defer { session.tearDown() }
        #expect(session.timeline.version == 2)
        #expect(session.setClipFrame(id: "cOver0001", EditFrame(x: -0.2, y: 0.1, w: 0.3, r: 30)))
        #expect(frame(session, "cOver0001") == EditFrame(x: -0.2, y: 0.1, w: 0.3, r: 30))
        #expect(failure(of: EditLanes.v2ToV1(session.timeline, kinds: [itemA: "video", itemB: "photo"]))?.1 == "clips[1].frame")
        // the main clip too: a first move gives it the frame its fill gave it
        #expect(session.setClipFrame(id: "cMain0001", EditFrame(x: -0.5, y: 0.2, w: 1.5)))
        #expect(frame(session, "cMain0001") == EditFrame(x: -0.5, y: 0.2, w: 1.5))
    }

    @Test func aVersionOneProjectThatCannotBecomeVersionTwoRefusesTheEdit() {
        // layer 63 would be lane 64, which does not exist: the project stays version 1
        var overlay = EditOverlay(id: "cOver0001", item: itemB, at: 0, in: 0, out: 1, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3))
        overlay.track = 63
        let main = EditClip(id: "cMain0001", item: itemA, in: 0, out: 2)
        let session = open(timeline: EditTimeline(version: 1, canvas: story, main: [main], overlay: [overlay]))
        defer { session.tearDown() }
        #expect(session.timeline.version == 1)
        let before = session.timeline
        #expect(!session.setClipFrame(id: "cOver0001", EditFrame(x: 0.1, y: 0.1, w: 0.3, r: 10)))
        #expect(session.laneRefusal == EditLanes.staysV1Message)
        #expect(session.timeline == before)
        #expect(session.frameBox(ofClip: "cOver0001") == EditFrame(x: 0.1, y: 0.1, w: 0.3))
        #expect(session.frameBox(ofClip: "cMain0001") != nil)
    }
}

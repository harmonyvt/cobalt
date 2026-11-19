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

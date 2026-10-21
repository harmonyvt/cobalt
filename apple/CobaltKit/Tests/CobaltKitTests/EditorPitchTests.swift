import AVFoundation
import Foundation
import Testing
@testable import CobaltKit

// Pitch (APP-API-CONTRACT 31.16): the optional `pitch` key (left out at 0, so old timelines keep their bytes), its rounding and
// range, `limits.edit_pitch`, the session's setters and what a save sends, the preview's cache key, and the shifter on a real sine.

private let story = EditCanvas(w: 1080, h: 1920, fps: 30)

private func clip(pitch: Double = 0) -> EditClip {
    EditClip(id: "cAAAAAAAA", item: "Ab3dEf6hIj9kLm2n", in: 0, out: 4, pitch: pitch)
}

private func text(_ t: EditTimeline) throws -> String { String(decoding: try EditJSON.encode(t), as: UTF8.self) }

// MARK: - the wire

struct EditPitchWireTests {
    @Test func aZeroPitchIsLeftOutSoTheBytesStayTheSame() throws {
        let t = EditTimeline.new(canvas: story, main: [clip()])
        #expect(try text(t) == #"{"canvas":{"fps":30,"h":1920,"w":1080},"main":[{"fit":"fill","id":"cAAAAAAAA","in":0,"item":"Ab3dEf6hIj9kLm2n","muted":false,"out":4,"speed":1,"volume":1}],"overlay":[],"version":1}"#)
        #expect(try !text(EditTimeline.new(canvas: story, main: [clip(pitch: -0.0)])).contains("pitch"))
        #expect(try !text(EditTimeline.new(canvas: story, main: [clip(pitch: 0.2)])).contains("pitch"))    // rounds to 0
    }

    @Test func aPitchIsWrittenWhereItSorts() throws {
        let t = EditTimeline.new(canvas: story, main: [clip(pitch: 3)])
        #expect(try text(t) == #"{"canvas":{"fps":30,"h":1920,"w":1080},"main":[{"fit":"fill","id":"cAAAAAAAA","in":0,"item":"Ab3dEf6hIj9kLm2n","muted":false,"out":4,"pitch":3,"speed":1,"volume":1}],"overlay":[],"version":1}"#)
        let back = try EditJSON.decode(try EditJSON.encode(t))
        #expect(back.main[0].pitch == 3)
        #expect(try EditJSON.encode(back) == EditJSON.encode(t))
    }

    @Test func anOverlayPitchRoundTripsToo() throws {
        let o = EditOverlay(
            id: "cBBBBBBBB", item: "Gh7jKl0nOp3rSt6v", at: 1, in: 0, out: 2, frame: EditFrame(x: 0.6, y: 0.05, w: 0.35), pitch: -2.5)
        let t = EditTimeline(canvas: story, main: [clip()], overlay: [o])
        let s = try text(t)
        #expect(s.contains(#""out":2,"pitch":-2.5,"volume":1"#))
        #expect(try EditJSON.decode(Data(s.utf8)).overlay[0].pitch == -2.5)
        var plain = o
        plain.pitch = 0
        #expect(try !text(EditTimeline(canvas: story, main: [clip()], overlay: [plain])).contains("pitch"))
    }

    @Test func anAbsentPitchDecodesAsZero() throws {
        let json = #"{"canvas":{"fps":30,"h":1920,"w":1080},"main":[{"fit":"fill","id":"cAAAAAAAA","in":0,"item":"Ab3dEf6hIj9kLm2n","muted":false,"out":4,"speed":1,"volume":1}],"overlay":[{"at":1,"frame":{"w":0.35,"x":0.6,"y":0.05},"id":"cBBBBBBBB","in":0,"item":"Gh7jKl0nOp3rSt6v","muted":true,"opacity":1,"out":2,"volume":1}],"version":1}"#
        let t = try EditJSON.decode(Data(json.utf8))
        #expect(t.main[0].pitch == 0 && t.overlay[0].pitch == 0)
        #expect(try text(t) == json)
    }

    @Test func theFixtureStillRoundTripsByteForByte() throws {
        let url = try #require(Bundle.module.url(forResource: "timeline-beach", withExtension: "json", subdirectory: "Fixtures/Editor"))
        let data = try Data(contentsOf: url)
        let t = try EditJSON.decode(data)
        #expect(t.main.allSatisfy { $0.pitch == 0 } && t.overlay.allSatisfy { $0.pitch == 0 })
        #expect(try EditJSON.encode(t) == data)
    }

    @Test func withoutPitchZeroesEveryClip() {
        let o = EditOverlay(id: "cBBBBBBBB", item: "Gh7jKl0nOp3rSt6v", at: 1, in: 0, out: 2, frame: EditFrame(x: 0.6, y: 0.05, w: 0.35), pitch: 4)
        let t = EditJSON.withoutPitch(EditTimeline(canvas: story, main: [clip(pitch: 3)], overlay: [o]))
        #expect(t.main[0].pitch == 0 && t.overlay[0].pitch == 0)
    }
}

// MARK: - rounding and range

struct EditPitchRuleTests {
    @Test func pitchRoundsToTheNearestHalfTheServersWay() {
        #expect(EditJSON.pitch(2.74) == 2.5)
        #expect(EditJSON.pitch(2.75) == 3)
        #expect(EditJSON.pitch(2.2) == 2)
        #expect(EditJSON.pitch(-2.75) == -2.5)          // halves go up, as Math.floor(x + 0.5)
        #expect(EditJSON.pitch(-2.76) == -3)
        #expect(EditJSON.pitch(-0.2) == 0 && EditJSON.pitch(-0.2).sign == .plus)
        #expect(EditJSON.pitch(1e20) == 1_000)          // never traps; still out of range
        let r = EditJSON.rounded(EditTimeline.new(canvas: story, main: [clip(pitch: 11.8)]))
        #expect(r.main[0].pitch == 12)
    }

    /// The server's three parity values (timeline.js `parsePitch`): halves go toward +infinity, then the range is checked.
    @Test func theServersParityValues() {
        #expect(EditJSON.pitch(-2.25) == -2)
        #expect(EditJSON.pitch(3.25) == 3.5)
        #expect(EditJSON.pitch(12.25) == 12.5)
        let sources = [
            "Ab3dEf6hIj9kLm2n": EditSource(id: "Ab3dEf6hIj9kLm2n", name: "a.mp4", kind: .video, width: 1280, height: 720, duration: 10),
        ]
        #expect(EditValidation.check(EditTimeline.new(canvas: story, main: [clip(pitch: 12.25)]), sources: sources)
            == [.range(path: "main[0].pitch")])
        #expect(EditValidation.check(EditTimeline.new(canvas: story, main: [clip(pitch: -2.25)]), sources: sources).isEmpty)
        #expect(EditValidation.check(EditTimeline.new(canvas: story, main: [clip(pitch: 3.25)]), sources: sources).isEmpty)
    }

    @Test func outOfRangeIsARangeProblemAtThePitchPath() {
        let sources = [
            "Ab3dEf6hIj9kLm2n": EditSource(id: "Ab3dEf6hIj9kLm2n", name: "a.mp4", kind: .video, width: 1280, height: 720, duration: 10),
        ]
        #expect(EditValidation.check(EditTimeline.new(canvas: story, main: [clip(pitch: 12.2)]), sources: sources).isEmpty)
        #expect(EditValidation.check(EditTimeline.new(canvas: story, main: [clip(pitch: -12)]), sources: sources).isEmpty)
        let high = EditValidation.check(EditTimeline.new(canvas: story, main: [clip(pitch: 12.5)]), sources: sources)
        #expect(high == [.range(path: "main[0].pitch")])
        let o = EditOverlay(id: "cBBBBBBBB", item: "Ab3dEf6hIj9kLm2n", at: 0, in: 0, out: 2, frame: EditFrame(x: 0.6, y: 0.05, w: 0.35), pitch: -13)
        let low = EditValidation.check(EditTimeline(canvas: story, main: [clip()], overlay: [o]), sources: sources)
        #expect(low.contains(.range(path: "overlay[0].pitch")))
    }
}

// MARK: - capabilities

struct EditPitchCapabilityTests {
    private func caps(_ limits: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":{"editor":true}\#(limits),"key":"valid"}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func editPitchIsReadAndFalseWhenAbsent() throws {
        #expect(try caps(#","limits":{"edit_pitch":true}"#).limits.editPitch)
        #expect(try !caps(#","limits":{"edit_pitch":false}"#).limits.editPitch)
        #expect(try !caps(#","limits":{"edit_max_clips":50}"#).limits.editPitch)
        #expect(try !caps("").limits.editPitch)
        #expect(!Capabilities.Limits.fork.editPitch)
    }

    @Test func theEditorPreviewsAdvertiseIt() {
        #expect(PreviewData.capabilities(for: .happy).limits.editPitch)
        #expect(PreviewData.capabilities(for: .editorRendering).limits.editPitch)
        #expect(!PreviewData.capabilities(for: .plainCobalt).limits.editPitch)
    }
}

// MARK: - the cache key

struct EditPitchKeyTests {
    @Test func aClipWithNoPitchNeedsNoCopy() {
        #expect(EditPitchKey(clip: clip()) == nil)
        #expect(EditPitchKey(clip: clip(pitch: 0.2)) == nil)
    }

    @Test func theKeyIsTheItemTheRangeAndThePitch() throws {
        let a = try #require(EditPitchKey(clip: clip(pitch: 3)))
        #expect(a == EditPitchKey(clip: clip(pitch: 3.1)))                    // the same after rounding
        #expect(a != EditPitchKey(clip: clip(pitch: 3.5)))
        var later = clip(pitch: 3)
        later.out = 4.5
        #expect(a != EditPitchKey(clip: later))
        var other = clip(pitch: 3)
        other.id = "cZZZZZZZZ"                                               // another clip of the same range shares the copy
        #expect(a == EditPitchKey(clip: other))
        #expect(a.fileName == "pitch-Ab3dEf6hIj9kLm2n-0-4000-6.caf")
        #expect(a.inSeconds == 0 && a.outSeconds == 4 && a.semitones == 3)
        let down = EditPitchKey(item: "Ab3dEf6hIj9kLm2n", in: 2.0004, out: 8.75, pitch: -2.5)
        #expect(down.fileName == "pitch-Ab3dEf6hIj9kLm2n-2000-8750--5.caf")
    }
}

// MARK: - the session

@MainActor
private struct PitchRig {
    let h: Harness
    let session: EditSession

    init() async throws {
        h = Harness(.happy)
        let client = h.ctx.client as! PreviewClient
        let (full, named) = try await client.editProject(id: PreviewEditorIDs.beach)
        var summary = full
        summary.timeline = nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edit-pitch-\(UUID().uuidString)", isDirectory: true)
        let cache = EditSourceCache(directory: dir, client: { [ctx = h.ctx] in ctx.client }, provider: { _ in nil })
        session = EditSession(
            project: summary, timeline: try #require(full.timeline), sources: named, context: h.ctx, cache: cache,
            onProject: { _ in }, onRender: { _ in })
    }

    var server: PreviewEditorState { (h.ctx.client as! PreviewClient).editorState }
    var pier: EditClip { session.timeline.main.first { $0.item == PreviewEditorIDs.pier }! }
    func finish() { session.tearDown() }
}

@MainActor
struct EditSessionPitchTests {
    @Test func pitchIsClampedAndRounded() async throws {
        let rig = try await PitchRig()
        defer { rig.finish() }
        let id = rig.pier.id
        rig.session.setPitch(2.8, clip: id)
        #expect(rig.pier.pitch == 3)
        rig.session.setPitch(30, clip: id)
        #expect(rig.pier.pitch == 12)
        rig.session.setPitch(-30, clip: id)
        #expect(rig.pier.pitch == -12)
        rig.session.setPitch(.nan, clip: id)
        #expect(rig.pier.pitch == 0)
        #expect(rig.session.problems.isEmpty)
    }

    @Test func aPitchDragIsOneUndoStep() async throws {
        let rig = try await PitchRig()
        defer { rig.finish() }
        let id = rig.pier.id
        rig.session.setPitch(1, clip: id)
        rig.session.setPitch(2, clip: id)
        rig.session.setPitch(3, clip: id)
        rig.session.undo()
        #expect(rig.pier.pitch == 0)
        #expect(!rig.session.canUndo)
        rig.session.redo()
        #expect(rig.pier.pitch == 3)
        rig.session.endGesture()
        rig.session.setPitch(-4, clip: id)
        rig.session.undo()
        #expect(rig.pier.pitch == 3)
    }

    @Test func anOverlayPitchIsItsOwnRun() async throws {
        let rig = try await PitchRig()
        defer { rig.finish() }
        let overlay = rig.session.timeline.overlay[0].id
        rig.session.setOverlayPitch(5.2, overlay: overlay)
        rig.session.setOverlayPitch(6.6, overlay: overlay)
        #expect(rig.session.timeline.overlay[0].pitch == 6.5)
        rig.session.setPitch(2, clip: rig.pier.id)                        // another key: a step of its own
        rig.session.undo()
        #expect(rig.pier.pitch == 0 && rig.session.timeline.overlay[0].pitch == 6.5)
        rig.session.undo()
        #expect(rig.session.timeline.overlay[0].pitch == 0)
    }

    @Test func thePitchIsSavedWhenTheServerKnowsIt() async throws {
        let rig = try await PitchRig()
        defer { rig.finish() }
        rig.session.setPitch(3, clip: rig.pier.id)
        await rig.h.drive(until: { rig.session.saveState == .saved })
        #expect(rig.server.timeline(of: PreviewEditorIDs.beach)?.main[0].pitch == 3)
    }

    @Test func aServerWithoutPitchNeverGetsOne() async throws {
        let rig = try await PitchRig()
        defer { rig.finish() }
        rig.session.setPitch(3, clip: rig.pier.id)
        rig.h.ctx.capabilities.limits.editPitch = false                   // e.g. the server changed under an open editor
        rig.session.setPitch(5, clip: rig.pier.id)                        // refused
        #expect(rig.pier.pitch == 3)
        rig.session.setVolume(0.5, clip: rig.pier.id)
        await rig.h.drive(until: { rig.session.saveState == .saved })
        let saved = try #require(rig.server.timeline(of: PreviewEditorIDs.beach))
        #expect(saved.main[0].pitch == 0 && saved.main[0].volume == 0.5)
        #expect(rig.pier.pitch == 3)                                      // the session keeps it; only the wire drops it
        #expect(rig.session.saveState == .saved)                          // and does not think it is still unsaved
    }
}

// MARK: - the shifter

struct EditPitchShifterTests {
    /// 1 s of a 440 Hz sine, mono, 48 kHz, as a .caf.
    private func sine(at url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let samples = try #require(buffer.floatChannelData)[0]
        for i in 0..<48_000 { samples[i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48_000) * 0.5) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    @Test func anOctaveUpKeepsTheLengthAndDoublesTheFrequency() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pitch-shift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("sine.caf")
        try sine(at: source)
        let dest = dir.appendingPathComponent("shifted.caf")
        try await EditPitchShifter.render(source: source, in: 0, out: 1, semitones: 12, to: dest)

        let out = try AVAudioFile(forReading: dest)
        #expect(abs(out.length - 48_000) <= 2)
        #expect(out.processingFormat.sampleRate == 48_000)
        // the working files are gone
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["shifted.caf", "sine.caf"])

        // zero crossings in the middle half second: 880 Hz crosses 880 times, 440 Hz 440 times
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(out.length)))
        try out.read(into: buffer)
        let ch = try #require(buffer.floatChannelData)[0]
        var crossings = 0
        for i in 12_001..<36_000 where (ch[i - 1] < 0) != (ch[i] < 0) { crossings += 1 }
        #expect(crossings > 780 && crossings < 980)
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import CobaltKit

// The editor's pure parts (apple/CONTRACT-EDITOR.md 3.1-3.5, APP-API-CONTRACT 31.2-31.6, 31.12): the canonical JSON and its
// rounding, the frame arithmetic, the integer-pixel geometry, the validator, and the server shapes with their refusals.

private func beachFixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "timeline-beach", withExtension: "json", subdirectory: "Fixtures/Editor"))
    return try Data(contentsOf: url)
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try CobaltJSON.decoder().decode(T.self, from: Data(json.utf8))
}

private let story = EditCanvas(w: 1080, h: 1920, fps: 30)

private func video(_ id: String, w: Int = 1280, h: Int = 720, seconds: Double = 10) -> EditSource {
    EditSource(id: id, name: "\(id).mp4", kind: .video, width: w, height: h, duration: seconds)
}

// MARK: - canonical JSON

struct EditJSONTests {
    @Test func theFixtureRoundTripsToTheSameBytes() throws {
        let data = try beachFixture()
        let timeline = try EditJSON.decode(data)
        #expect(try EditJSON.encode(timeline) == data)
    }

    @Test func theFixtureDecodesToWhatTheContractShows() throws {
        let t = try EditJSON.decode(try beachFixture())
        #expect(t.version == 1)
        #expect(t.canvas == story)
        #expect(t.main.count == 2 && t.overlay.count == 1)
        #expect(t.main[0].id == "cA1b2C3d4" && t.main[0].speed == 1.5 && t.main[0].`in` == 2 && t.main[0].out == 9.5)
        #expect(t.main[0].crop == EditCrop(aspect: .story, x: 0.3, y: 0, w: 0.3164, h: 1))
        #expect(t.main[1].crop == nil && t.main[1].volume == 0.7)
        #expect(t.overlay[0].frame == EditFrame(x: 0.6, y: 0.05, w: 0.35) && t.overlay[0].muted)
    }

    @Test func aNilCropIsLeftOutAndKeysAreSorted() throws {
        let t = EditTimeline.new(canvas: story, main: [EditClip(id: "cAAAAAAAA", item: "Ab3dEf6hIj9kLm2n", in: 0, out: 4)])
        let text = String(decoding: try EditJSON.encode(t), as: UTF8.self)
        #expect(!text.contains("crop"))
        #expect(text == #"{"canvas":{"fps":30,"h":1920,"w":1080},"main":[{"fit":"fill","id":"cAAAAAAAA","in":0,"item":"Ab3dEf6hIj9kLm2n","muted":false,"out":4,"speed":1,"volume":1}],"overlay":[],"version":1}"#)
    }

    @Test func numbersAreRoundedTheWayTheServerRoundsThem() throws {
        var clip = EditClip(id: "cAAAAAAAA", item: "Ab3dEf6hIj9kLm2n", in: 2.0004, out: 9.5006, speed: 1.53, volume: 0.456)
        clip.crop = EditCrop(aspect: .free, x: 0.31644, y: 0.00004, w: 0.5, h: 1)
        let overlay = EditOverlay(
            id: "cBBBBBBBB", item: "Gh7jKl0nOp3rSt6v", at: 3.0004, in: 0, out: 3, frame: EditFrame(x: 0.60004, y: 0.05, w: 0.34996),
            opacity: 0.456, volume: 0.994)
        let r = EditJSON.rounded(EditTimeline(canvas: story, main: [clip], overlay: [overlay]))
        #expect(r.main[0].`in` == 2 && r.main[0].out == 9.501)
        #expect(r.main[0].speed == 1.55)
        #expect(r.main[0].volume == 0.46)
        #expect(r.main[0].crop?.x == 0.3164 && r.main[0].crop?.y == 0)
        #expect(r.overlay[0].at == 3 && r.overlay[0].opacity == 0.46 && r.overlay[0].volume == 0.99)
        #expect(r.overlay[0].frame == EditFrame(x: 0.6, y: 0.05, w: 0.35))
    }

    @Test func speedSnapsToTheNearestTwentieth() {
        #expect(EditJSON.speed(1.52) == 1.5)
        #expect(EditJSON.speed(1.53) == 1.55)
        #expect(EditJSON.speed(0.26) == 0.25)
        #expect(EditJSON.speed(4) == 4)
    }

    @Test func idsAreAnCPlusEightBase62Characters() {
        let id = EditID.mint()
        #expect(id.count == 9 && id.first == "c")
        #expect(id.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        #expect(Set((0..<200).map { _ in EditID.mint() }).count == 200)
    }

    @Test func aNewClipIsTheWholeFileAtSpeedOne() {
        let c = EditClip.added(item: "Ab3dEf6hIj9kLm2n", duration: 12.5)
        #expect(c.`in` == 0 && c.out == 12.5 && c.speed == 1 && c.crop == nil && c.fit == .fill && c.volume == 1 && !c.muted)
    }

    @Test func aNewOverlayIsCutToTheRoomItHas() {
        let gif = EditOverlay.added(item: "Gh7jKl0nOp3rSt6v", kind: .gif, duration: 1.2, at: 2, remaining: 10)
        #expect(gif.`in` == 0 && gif.out == 3 && gif.muted && gif.frame == EditFrame(x: 0.6, y: 0.05, w: 0.35))
        let shortRoom = EditOverlay.added(item: "Gh7jKl0nOp3rSt6v", kind: .photo, duration: nil, at: 2, remaining: 1.2)
        #expect(shortRoom.out == 1.2)
        let clip = EditOverlay.added(item: "Gh7jKl0nOp3rSt6v", kind: .video, duration: 8, at: 0, remaining: 5)
        #expect(clip.out == 5)
    }
}

// MARK: - canvas

struct EditCanvasTests {
    @Test func theCanvasFollowsTheFirstVideo() {
        #expect(EditCanvas.forFirstVideo(width: 1080, height: 1920) == EditCanvas(w: 1080, h: 1920, fps: 30))
        #expect(EditCanvas.forFirstVideo(width: 1920, height: 1080) == EditCanvas(w: 1920, h: 1080, fps: 30))
        #expect(EditCanvas.forFirstVideo(width: 1000, height: 1000) == EditCanvas(w: 1080, h: 1080, fps: 30))
        // 10 % either way still counts as square
        #expect(EditCanvas.forFirstVideo(width: 1000, height: 1100) == EditCanvas(w: 1080, h: 1080, fps: 30))
        #expect(EditCanvas.forFirstVideo(width: 1000, height: 1101) == EditCanvas(w: 1080, h: 1920, fps: 30))
    }

    @Test func theSixSizesAreTheOnlyValidOnes() {
        #expect(EditCanvas.sizes.count == 6)
        for size in EditCanvas.sizes { #expect(EditCanvas(w: size.w, h: size.h, fps: 30).isValidSize) }
        #expect(!EditCanvas(w: 1000, h: 1000, fps: 30).isValidSize)
        #expect(EditCanvas(shape: .wide, resolution: .p720, fps: 60) == EditCanvas(w: 1280, h: 720, fps: 60))
        #expect(EditCanvas(shape: .story, resolution: .p720, fps: 30).shape == .story)
        #expect(EditCanvas(w: 1280, h: 720, fps: 30).resolution == .p720)
    }

    @Test func aCentredCropIsTheLargestRectangleOfThatShape() {
        let crop = EditCrop.centred(.story, display: CGSize(width: 1920, height: 1080))
        #expect(crop == EditCrop(aspect: .story, x: 0.3418, y: 0, w: 0.3164, h: 1))
        let tall = EditCrop.centred(.wide, display: CGSize(width: 1080, height: 1920))
        #expect(tall.w == 1 && tall.x == 0 && tall.h == 0.3164)
        #expect(EditCrop.centred(.free, display: CGSize(width: 1920, height: 1080)).isFull)
    }
}

// MARK: - timing (31.4)

struct EditTimingTests {
    private func beach() -> EditTimeline { PreviewData.editorBeachTimeline() }

    @Test func framesAreTheUnitAndTheCountIsTheSumOfTheClips() {
        let timing = EditTiming(beach())
        #expect(timing.fps == 30)
        #expect(timing.main.map(\.frames) == [360, 135, 165, 120])
        #expect(timing.main.map(\.start) == [0, 360, 495, 660])
        #expect(timing.frames == 780 && timing.seconds == 26)
        #expect(timing.main[0].samples == 360 * 1_600)
    }

    @Test func theEffectiveSpeedIsWhatMakesTheClipLastItsFrames() {
        let timing = EditTiming(beach())
        #expect(timing.main[1].speed == 1.5)
        // 3.333 s of source at 1.5x is 2.222 s: 66.67 frames, rounded to 67, so the speed is 3.333 * 30 / 67
        var t = beach()
        t.main[1].`in` = 0
        t.main[1].out = 3.333
        let odd = EditTiming(t).main[1]
        #expect(odd.frames == 67)
        #expect(abs(odd.speed - 3.333 * 30 / 67) < 1e-12)
    }

    @Test func theOverlayStartsAtItsRoundedFrame() {
        let timing = EditTiming(beach())
        #expect(timing.overlay.count == 1)
        #expect(timing.overlay[0].start == 90 && timing.overlay[0].frames == 90 && timing.overlay[0].speed == 1)
    }

    @Test func halfFramesRoundUp() {
        #expect(EditMath.roundHalfUp(2.5) == 3)
        #expect(EditMath.roundHalfUp(2.4999999999) == 2)
        #expect(EditMath.evenNearest(5) == 6)       // 2 * roundHalfUp(2.5)
        #expect(EditMath.evenNearest(3) == 4)
        #expect(EditMath.evenFloor(7) == 6)
        #expect(EditMath.evenFloor(8) == 8)
    }

    @Test func aTimeAndAFrameFindEachOther() {
        let timing = EditTiming(beach())
        #expect(timing.time(ofFrame: 45) == 1.5)
        #expect(timing.frame(at: 12) == 360)
        #expect(timing.frame(at: 1_000) == 779)
        #expect(timing.frame(at: -3) == 0)
        #expect(timing.clip(atFrame: 359)?.index == 0 && timing.clip(atFrame: 359)?.offset == 359)
        #expect(timing.clip(atFrame: 360)?.index == 1 && timing.clip(atFrame: 360)?.offset == 0)
        #expect(timing.clip(atFrame: 780) == nil)
        #expect(timing.clip(atFrame: -1) == nil)
    }

    @Test func theSourceTimeFollowsTheSpeed() {
        let t = beach()
        let timing = EditTiming(t)
        #expect(timing.sourceTime(clip: 1, offset: 30, in: t) == 3.5)      // in 2 + 1 s of output at 1.5x
        #expect(timing.sourceTime(clip: 0, offset: 0, in: t) == 0)
    }

    @Test func sixtyFramesASecondDoublesTheFrames() {
        var t = beach()
        t.canvas.fps = 60
        let timing = EditTiming(t)
        #expect(timing.frames == 1_560 && timing.seconds == 26)
        #expect(timing.main[0].samples == 360 * 2 * 800)
    }
}

// MARK: - geometry (31.6)

struct EditGeometryTests {
    @Test func fillCoversTheCanvasAndTheExcessIsCutByItsEdge() throws {
        let g = try #require(EditGeometry.main(
            display: PixelSize(w: 1920, h: 1080), crop: nil, fit: .fill, canvas: story))
        #expect(g.crop == PixelRect(x: 0, y: 0, w: 1920, h: 1080))
        #expect(g.scaled == PixelSize(w: 3414, h: 1920))
        #expect(g.place == PixelPoint(x: -1167, y: 0))
    }

    @Test func fitKeepsTheWholePictureWithBars() throws {
        let g = try #require(EditGeometry.main(
            display: PixelSize(w: 1920, h: 1080), crop: nil, fit: .fit, canvas: story))
        #expect(g.scaled == PixelSize(w: 1080, h: 608))
        #expect(g.place == PixelPoint(x: 0, y: 656))
    }

    @Test func aCropIsInEvenPixelsAndThenScaled() throws {
        let crop = EditCrop(aspect: .story, x: 0.3418, y: 0, w: 0.3164, h: 1)
        let g = try #require(EditGeometry.main(
            display: PixelSize(w: 1920, h: 1080), crop: crop, fit: .fill, canvas: story))
        #expect(g.crop == PixelRect(x: 656, y: 0, w: 608, h: 1080))
        #expect(g.scaled == PixelSize(w: 1080, h: 1920))
        #expect(g.place == PixelPoint(x: 0, y: 0))
    }

    @Test func aCropUnderSixtyFourPixelsIsRefused() {
        let tiny = EditCrop(aspect: .free, x: 0, y: 0, w: 0.01, h: 0.01)
        #expect(EditGeometry.cropPixels(tiny, display: PixelSize(w: 1920, h: 1080)) == nil)
        #expect(EditGeometry.main(display: PixelSize(w: 1920, h: 1080), crop: tiny, fit: .fill, canvas: story) == nil)
        #expect(EditGeometry.cropPixels(EditCrop(aspect: .free, x: 0, y: 0, w: 1, h: 1), display: PixelSize(w: 1, h: 1)) == nil)
    }

    @Test func anOddDisplayLosesItsLastPixelInsteadOfBreakingTheEvenRule() throws {
        let g = try #require(EditGeometry.main(
            display: PixelSize(w: 1081, h: 1921), crop: nil, fit: .fill, canvas: story))
        #expect(g.crop == PixelRect(x: 0, y: 0, w: 1080, h: 1920))
        #expect(g.scaled == PixelSize(w: 1080, h: 1920))
    }

    @Test func anOverlayKeepsItsOwnShape() {
        let r = EditGeometry.overlay(display: PixelSize(w: 480, h: 360), frame: EditFrame(x: 0.6, y: 0.05, w: 0.35), canvas: story)
        #expect(r == PixelRect(x: 648, y: 96, w: 378, h: 284))
    }

    @Test func anOverlayStaysInsideTheCanvasWhateverItIsAsked() {
        let r = EditGeometry.overlay(display: PixelSize(w: 480, h: 360), frame: EditFrame(x: 0.99, y: 0.99, w: 0.35), canvas: story)
        #expect(r.x + r.w <= 1_080 && r.y + r.h <= 1_920 && r.x >= 0 && r.y >= 0)
    }

    @Test func theHeightFractionFollowsTheSourceAspect() {
        let h = EditGeometry.overlayHeightFraction(
            display: PixelSize(w: 480, h: 360), frame: EditFrame(x: 0, y: 0, w: 0.35), canvas: story)
        #expect(abs(h - 0.14765625) < 1e-12)
    }

    @Test func clampingMovesTheFrameBackInsideTheCanvas() {
        let f = EditGeometry.clampInside(
            EditFrame(x: 0.8, y: 0.9, w: 0.35), display: PixelSize(w: 480, h: 360), canvas: story)
        #expect(f == EditFrame(x: 0.65, y: 0.8523, w: 0.35))
        let wide = EditGeometry.clampInside(
            EditFrame(x: -1, y: -1, w: 3), display: PixelSize(w: 480, h: 360), canvas: story)
        #expect(wide.x == 0 && wide.y == 0 && wide.w == 1)
    }

    @Test func aTallOverlayIsMadeNarrowerSoItsHeightFits() {
        // a 1:10 sliver on a 1:1 canvas would be ten canvases tall at full width
        let f = EditGeometry.clampInside(
            EditFrame(x: 0, y: 0, w: 1), display: PixelSize(w: 100, h: 1_000), canvas: EditCanvas(w: 1080, h: 1080, fps: 30))
        #expect(f.w == 0.1)
    }
}

// MARK: - validation (31.3)

struct EditValidationTests {
    private func sources() -> [String: EditSource] { PreviewData.editorSources() }
    private func check(_ t: EditTimeline) -> [EditProblem] { EditValidation.check(t, sources: sources()) }
    private func one(_ item: String = PreviewEditorIDs.pier, in i: Double = 0, out: Double = 4) -> EditClip {
        EditClip(id: EditID.mint(), item: item, in: i, out: out)
    }

    @Test func theBeachTimelineHasNoProblem() {
        #expect(check(PreviewData.editorBeachTimeline()).isEmpty)
        #expect(check(PreviewData.editorCatsTimeline()).isEmpty)
    }

    @Test func anEmptyTimelineIsEmpty() {
        #expect(check(EditTimeline(canvas: story, main: [])) == [.empty])
    }

    @Test func aBadCanvasIsACanvasProblem() {
        let t = EditTimeline(canvas: EditCanvas(w: 1000, h: 1000, fps: 30), main: [one()])
        #expect(check(t).contains(.canvas))
        let fps = EditTimeline(canvas: EditCanvas(w: 1080, h: 1920, fps: 24), main: [one()])
        #expect(check(fps).contains(.canvas))
    }

    @Test func moreThanFiftyClipsIsTooMany() {
        let t = EditTimeline(canvas: story, main: (0..<51).map { _ in one(out: 0.2) })
        #expect(check(t).contains(.tooManyClips))
    }

    @Test func overTenMinutesIsTooLong() {
        var long = PreviewData.editorSources()
        long[PreviewEditorIDs.pier]?.duration = 400
        let t = EditTimeline(canvas: story, main: [one(out: 320), one(out: 320)])
        #expect(EditValidation.check(t, sources: long).contains(.tooLong))
        let ok = EditTimeline(canvas: story, main: [one(out: 300), one(out: 300)])
        #expect(!EditValidation.check(ok, sources: long).contains(.tooLong))
    }

    @Test func rangeProblemsNameTheirField() {
        var c = one()
        c.speed = 5
        #expect(check(EditTimeline(canvas: story, main: [one(), c])).contains(.range(path: "main[1].speed")))
        var short = one(out: 0.05)
        short.speed = 1
        #expect(check(EditTimeline(canvas: story, main: [short])).contains(.range(path: "main[0].out")))
        var loud = one()
        loud.volume = 1.5
        #expect(check(EditTimeline(canvas: story, main: [loud])).contains(.range(path: "main[0].volume")))
        var cropped = one()
        cropped.crop = EditCrop(aspect: .free, x: 0.8, y: 0, w: 0.5, h: 1)
        #expect(check(EditTimeline(canvas: story, main: [cropped])).contains(.range(path: "main[0].crop")))
        var tiny = one()
        tiny.crop = EditCrop(aspect: .free, x: 0, y: 0, w: 0.02, h: 1)
        #expect(check(EditTimeline(canvas: story, main: [tiny])).contains(.range(path: "main[0].crop")))
    }

    @Test func overlaysMayNotOverlapOrRunPastTheEnd() {
        let a = EditOverlay(id: "cOverA001", item: PreviewEditorIDs.dance, at: 0, in: 0, out: 2, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3))
        let b = EditOverlay(id: "cOverB001", item: PreviewEditorIDs.dance, at: 1, in: 0, out: 2, frame: EditFrame(x: 0.1, y: 0.5, w: 0.3))
        let overlapping = EditTimeline(canvas: story, main: [one(out: 8)], overlay: [a, b])
        #expect(check(overlapping).contains(.overlayOverlap(path: "overlay[1]")))
        let late = EditOverlay(id: "cOverC001", item: PreviewEditorIDs.dance, at: 7, in: 0, out: 2, frame: EditFrame(x: 0.1, y: 0.1, w: 0.3))
        let past = EditTimeline(canvas: story, main: [one(out: 8)], overlay: [late])
        #expect(check(past).contains(.overlayPastEnd(path: "overlay[0]")))
    }

    @Test func anOverlayOutsideTheCanvasIsARangeProblem() {
        let o = EditOverlay(id: "cOverA001", item: PreviewEditorIDs.dance, at: 0, in: 0, out: 2, frame: EditFrame(x: 0.8, y: 0.1, w: 0.35))
        #expect(check(EditTimeline(canvas: story, main: [one(out: 8)], overlay: [o])).contains(.range(path: "overlay[0].frame.x")))
        let low = EditOverlay(id: "cOverA001", item: PreviewEditorIDs.dance, at: 0, in: 0, out: 2, frame: EditFrame(x: 0.1, y: 0.95, w: 0.35))
        #expect(check(EditTimeline(canvas: story, main: [one(out: 8)], overlay: [low])).contains(.range(path: "overlay[0].frame.y")))
    }

    @Test func sourceProblemsNameTheFiles() {
        var s = sources()
        s[PreviewEditorIDs.surf]?.available = false
        let t = EditTimeline(canvas: story, main: [one(), one(PreviewEditorIDs.surf), one(PreviewEditorIDs.dance), one("ZzZzZzZzZzZzZzZz")])
        let problems = EditValidation.check(t, sources: s)
        #expect(problems.contains(.sourceMissing([PreviewEditorIDs.surf, "ZzZzZzZzZzZzZzZz"])))
        #expect(problems.contains(.notVideo([PreviewEditorIDs.dance])))
        s[PreviewEditorIDs.pier]?.kind = .unsupported
        #expect(EditValidation.check(t, sources: s).contains(.unsupportedSource([PreviewEditorIDs.pier])))
    }

    @Test func aClipMayEndFiftyMillisecondsAfterItsFileDoes() {
        // pier lasts 12 s
        #expect(check(EditTimeline(canvas: story, main: [one(out: 12.04)])).isEmpty)
        #expect(check(EditTimeline(canvas: story, main: [one(out: 12.2)])).contains(.pastSourceEnd(path: "main[0].out")))
    }

    @Test func everyProblemHasTheServersCodeAndPath() {
        #expect(EditProblem.canvas.code == "error.edit.canvas" && EditProblem.canvas.path == "canvas")
        #expect(EditProblem.empty.code == "error.edit.empty" && EditProblem.empty.path == "main")
        #expect(EditProblem.tooLong.code == "error.edit.too_long")
        #expect(EditProblem.range(path: "main[2].speed").path == "main[2].speed")
        #expect(EditProblem.overlayOverlap(path: "overlay[1]").code == "error.edit.overlay_overlap")
        #expect(EditProblem.sourceMissing(["a"]).items == ["a"] && EditProblem.sourceMissing(["a"]).path == nil)
        #expect(EditProblem.pastSourceEnd(path: "main[0].out").code == "error.edit.past_source_end")
    }
}

// MARK: - server shapes (31.12)

struct EditWireTests {
    private let projectJSON = """
    {"id":"AbCdEfGhIjKlMnOp","title":"beach day edit","revision":3,"canvas":{"w":1080,"h":1920,"fps":30},"duration":26,
     "clip_count":4,"cover_url":"https://media.capybaraharmony.com/c.jpg","created_at":1790000000000,"updated_at":1790000900000,
     "render":null}
    """

    @Test func aProjectSummaryDecodes() throws {
        let p = try decode(EditProject.self, projectJSON)
        #expect(p.id == "AbCdEfGhIjKlMnOp" && p.title == "beach day edit" && p.revision == 3)
        #expect(p.canvas == story && p.duration == 26 && p.clipCount == 4)
        #expect(p.coverURL?.absoluteString == "https://media.capybaraharmony.com/c.jpg")
        #expect(p.timeline == nil && p.render == nil)
        #expect(p.updatedAt.timeIntervalSince1970 == 1_790_000_900)
    }

    @Test func aProjectWithOptionalFieldsMissingStillDecodes() throws {
        let p = try decode(EditProject.self, #"{"id":"AbCdEfGhIjKlMnOp","revision":1,"canvas":{"w":1280,"h":720,"fps":60}}"#)
        #expect(p.title == "" && p.duration == 0 && p.clipCount == 0 && p.coverURL == nil)
        #expect(p.canvas.fps == 60)
    }

    @Test func aFullProjectCarriesItsTimeline() throws {
        let timeline = String(decoding: try beachFixture(), as: UTF8.self)
        let json = #"{"id":"AbCdEfGhIjKlMnOp","title":"t","revision":2,"canvas":{"w":1080,"h":1920,"fps":30},"timeline":\#(timeline)}"#
        let p = try decode(EditProject.self, json)
        #expect(p.timeline?.main.count == 2)
    }

    @Test func aRenderDecodesWithItsProgress() throws {
        let r = try decode(EditRender.self, """
        {"id":"r1","project_id":"p1","revision":3,"title":"beach","status":"rendering","progress":0.4,"seconds_done":10.4,
         "seconds_total":26,"cancel_requested":false,"created_at":1790000000000,"started_at":1790000001000}
        """)
        #expect(r.status == .rendering && r.progress == 0.4 && r.secondsTotal == 26 && r.isActive && !r.isEnded)
        #expect(r.startedAt?.timeIntervalSince1970 == 1_790_000_001 && r.finishedAt == nil)
        #expect(r.lastMoment == r.startedAt)
    }

    @Test func aFinishedRenderNamesItsLibraryItem() throws {
        let r = try decode(EditRender.self, """
        {"id":"r1","project_id":"p1","revision":3,"title":"beach","status":"done","progress":1,"seconds_total":26,
         "item_id":"PrEvIeWitem000001","poster_url":"https://media.capybaraharmony.com/p.jpg","bytes":8400000,"width":1080,
         "height":1920,"duration":26,"created_at":1790000000000,"finished_at":1790000030000}
        """)
        #expect(r.status == .done && r.itemID == "PrEvIeWitem000001" && r.bytes == 8_400_000 && r.isEnded)
        #expect(r.lastMoment.timeIntervalSince1970 == 1_790_000_030)
    }

    @Test func aRenderWithAnUnknownStatusIsDroppedFromAList() throws {
        struct Wire: Decodable { var renders: [Lossy<EditRender>] }
        let wire = try decode(Wire.self, """
        {"renders":[{"id":"a","status":"queued","seconds_total":4,"created_at":1790000000000},
                    {"id":"b","status":"sparkling","seconds_total":4,"created_at":1790000000000}]}
        """)
        #expect(wire.renders.compactMap(\.value).map(\.id) == ["a"])
    }

    @Test func aSourceDecodesAndAWordItDoesNotKnowIsUnsupported() throws {
        let s = try decode(EditSource.self, """
        {"id":"Ab3dEf6hIj9kLm2n","name":"pier.mp4","kind":"video","content_type":"video/mp4","width":1280,"height":720,
         "duration":12,"bytes":9400000,"poster_url":"https://media.capybaraharmony.com/p.jpg","available":true}
        """)
        #expect(s.kind == .video && s.display == PixelSize(w: 1280, h: 720) && s.duration == 12 && s.available)
        #expect(s.shortName == "pier")
        let odd = try decode(EditSource.self, #"{"id":"Ab3dEf6hIj9kLm2n","name":"x.stl","kind":"model"}"#)
        #expect(odd.kind == .unsupported && odd.display == nil && odd.available)
    }

    @Test func renderOrderingPrefersTheLaterStateAndMoreProgress() {
        func render(_ status: EditRender.Status, _ progress: Double?) -> EditRender {
            EditRender(id: "r", projectID: "p", revision: 1, title: "t", status: status, progress: progress, secondsTotal: 4, createdAt: Date())
        }
        #expect(render(.done, 1).isFresher(than: render(.rendering, 0.9)))
        #expect(!render(.rendering, 0.9).isFresher(than: render(.done, 1)))
        #expect(render(.rendering, 0.5).isFresher(than: render(.rendering, 0.4)))
        #expect(render(.rendering, 0.4).isFresher(than: render(.rendering, 0.4)))      // a tie is "yes": the caller's own copy wins
        #expect(!render(.preparing, 0.05).isFresher(than: render(.rendering, 0.1)))
    }
}

struct EditErrorTests {
    private let project = EditProject(
        id: "AbCdEfGhIjKlMnOp", title: "t", revision: 5, canvas: story, duration: 4, clipCount: 1,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))

    @Test func everyCodeMapsToItsCase() {
        func e(_ code: String, path: String? = nil, items: [String] = [], project: EditProject? = nil) -> EditError {
            EditError(code: code, path: path, items: items, project: project)
        }
        #expect(e("error.edit.off") == .off)
        #expect(e("error.edit.not_found") == .notFound)
        #expect(e("error.edit.conflict", project: project) == .conflict(project))
        #expect(e("error.edit.conflict") == .other("error.edit.conflict"))
        #expect(e("error.edit.too_many") == .tooMany)
        #expect(e("error.edit.queue_full") == .queueFull)
        #expect(e("error.edit.finished") == .finished)
        #expect(e("error.edit.too_large") == .tooLarge)
        #expect(e("error.edit.canvas") == .invalid(.canvas))
        #expect(e("error.edit.empty") == .invalid(.empty))
        #expect(e("error.edit.too_many_clips") == .invalid(.tooManyClips))
        #expect(e("error.edit.too_long") == .invalid(.tooLong))
        #expect(e("error.edit.range", path: "main[1].speed") == .invalid(.range(path: "main[1].speed")))
        #expect(e("error.edit.overlay_overlap", path: "overlay[1]") == .invalid(.overlayOverlap(path: "overlay[1]")))
        #expect(e("error.edit.overlay_past_end", path: "overlay[0]") == .invalid(.overlayPastEnd(path: "overlay[0]")))
        #expect(e("error.edit.source_missing", items: ["a", "b"]) == .invalid(.sourceMissing(["a", "b"])))
        #expect(e("error.edit.not_video", items: ["a"]) == .invalid(.notVideo(["a"])))
        #expect(e("error.edit.unsupported_source", items: ["a"]) == .invalid(.unsupportedSource(["a"])))
        #expect(e("error.edit.past_source_end", path: "main[0].out") == .invalid(.pastSourceEnd(path: "main[0].out")))
        #expect(e("error.api.generic") == .unavailable)
        #expect(e("error.edit.something_new") == .other("error.edit.something_new"))
    }

    @Test func otherErrorsAreMappedToo() {
        #expect(EditError.from(CobaltError.network(.notConnectedToInternet)) == .offline)
        #expect(EditError.from(CobaltError.api(code: "error.edit.queue_full", httpStatus: 429)) == .queueFull)
        #expect(EditError.from(CobaltError.api(code: "error.api.something", httpStatus: 503)) == .unavailable)
        #expect(EditError.from(URLError(.timedOut)) == .offline)
        #expect(EditError.from(EditError.tooMany) == .tooMany)
        #expect(EditError.offline.isTransient && EditError.unavailable.isTransient)
        #expect(!EditError.queueFull.isTransient && !EditError.notFound.isTransient)
    }
}

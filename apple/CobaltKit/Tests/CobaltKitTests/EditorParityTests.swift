import Foundation
import Testing
@testable import CobaltKit

// The renderer's shared fixtures (deploy/cloudflare/editor/helper/test/fixtures, copied to Fixtures/Editor): the Swift timing and
// geometry give the same numbers as the server's, case by case.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Editor"))
    return try Data(contentsOf: url)
}

struct EditParityTests {
    private struct TimingCase: Decodable {
        struct Clip: Decodable { var id: String; var start: Int; var frames: Int; var speed: Double; var samples: Int }
        struct Expect: Decodable { var fps: Int; var frames: Int; var seconds: Double; var main: [Clip]; var overlay: [Clip] }
        var name: String
        var timeline: EditTimeline
        var expect: Expect
    }

    @Test func timingMatchesTheRenderersFixture() throws {
        let cases = try JSONDecoder().decode([TimingCase].self, from: try fixture("timing"))
        #expect(!cases.isEmpty)
        for c in cases {
            let t = EditTiming(c.timeline)
            #expect(t.fps == c.expect.fps && t.frames == c.expect.frames, "\(c.name)")
            #expect(abs(t.seconds - c.expect.seconds) < 1e-9, "\(c.name)")
            for (mine, theirs) in Array(zip(t.main, c.expect.main)) + Array(zip(t.overlay, c.expect.overlay)) {
                #expect(mine.id == theirs.id && mine.start == theirs.start && mine.frames == theirs.frames, "\(c.name)")
                #expect(mine.samples == theirs.samples && abs(mine.speed - theirs.speed) < 1e-9, "\(c.name)")
            }
            #expect(t.main.count == c.expect.main.count && t.overlay.count == c.expect.overlay.count, "\(c.name)")
        }
    }

    private struct Px: Decodable { var w: Int; var h: Int }
    private struct Rect: Decodable { var x: Int; var y: Int; var w: Int; var h: Int }
    private struct Pt: Decodable { var x: Int; var y: Int }
    private struct MainCase: Decodable {
        struct Expect: Decodable { var crop: Rect; var place: Pt; var scaled: Px }
        var display: Px
        var crop: EditCrop?
        var fit: EditFit
        var canvas: Px
        var expect: Expect
    }
    private struct OverlayCase: Decodable {
        var display: Px
        var frame: EditFrame
        var canvas: Px
        var expect: Rect
    }
    private struct Geometry: Decodable { var main: [MainCase]; var overlay: [OverlayCase] }

    @Test func geometryMatchesTheRenderersFixture() throws {
        let g = try JSONDecoder().decode(Geometry.self, from: try fixture("geometry"))
        #expect(g.main.count > 100 && g.overlay.count > 50)
        for c in g.main {
            let canvas = EditCanvas(w: c.canvas.w, h: c.canvas.h, fps: 30)
            let r = try #require(EditGeometry.main(display: PixelSize(w: c.display.w, h: c.display.h), crop: c.crop, fit: c.fit, canvas: canvas))
            #expect(r.crop == PixelRect(x: c.expect.crop.x, y: c.expect.crop.y, w: c.expect.crop.w, h: c.expect.crop.h))
            #expect(r.place == PixelPoint(x: c.expect.place.x, y: c.expect.place.y))
            #expect(r.scaled == PixelSize(w: c.expect.scaled.w, h: c.expect.scaled.h))
        }
        for c in g.overlay {
            let canvas = EditCanvas(w: c.canvas.w, h: c.canvas.h, fps: 30)
            let r = EditGeometry.overlay(display: PixelSize(w: c.display.w, h: c.display.h), frame: c.frame, canvas: canvas)
            #expect(r == PixelRect(x: c.expect.x, y: c.expect.y, w: c.expect.w, h: c.expect.h))
        }
    }

    @Test func speedIsRoundedBeforeItIsRangeChecked() {
        let source = EditSource(id: "AAAAAAAAAAAAAAAA", name: "a.mp4", kind: .video, width: 1280, height: 720, duration: 10)
        func problems(_ speed: Double) -> [EditProblem] {
            let clip = EditClip(id: "c1", item: source.id, in: 0, out: 4, speed: speed)
            return EditValidation.check(EditTimeline(canvas: EditCanvas(w: 1080, h: 1920, fps: 30), main: [clip]), sources: [source.id: source])
        }
        #expect(problems(0.24).isEmpty)       // 0.25
        #expect(problems(4.02).isEmpty)       // 4
        #expect(!problems(4.03).isEmpty)      // 4.05
    }
}

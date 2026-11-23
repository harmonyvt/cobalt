import CoreGraphics
import Foundation
import Testing
@testable import CobaltKit

// The touchable picture (apple/CONTRACT-EDITOR.md 15.3): which clip a tap picks (turned and off-canvas boxes, keyed clips
// passed over, the same spot again for the clip below), and the gestures' box arithmetic (edge and centre snaps, angle
// clicks, corner resize about the opposite corner, the knob's turn).

private let wide = EditCanvas(w: 1920, h: 1080, fps: 30)
private let landscape = PixelSize(w: 1920, h: 1080)
private let square = PixelSize(w: 1000, h: 1000)

private func clip(
    _ id: String, lane: Int, at: Double = 0, out: Double = 4, frame: EditFrame? = nil, fit: EditFit = .fill,
    keyed: Bool = false, hidden: Bool = false
) -> EditLaneClip {
    EditLaneClip(
        id: id, item: "item-\(id)", lane: lane, at: at, in: 0, out: out, fit: fit, frame: frame, hidden: hidden,
        key: keyed ? EditChromaKey() : nil)
}

/// What the session answers: the picture size per clip, and its frame or the fit/fill box.
private func layers(_ clips: [EditLaneClip], sizes: [String: PixelSize] = [:], at k: Int = 0) -> [EditPicturePick.Layer] {
    let t = EditTimeline(canvas: wide, clips: clips)
    let timing = EditTiming(t)
    return EditPicturePick.layers(
        timeline: t, timing: timing, frame: k,
        picture: { id in sizes[id] ?? landscape },
        frameBox: { id in
            guard let c = clips.first(where: { $0.id == id }) else { return nil }
            if let f = c.frame { return f }
            return EditGeometry.fitFrame(display: sizes[id] ?? landscape, crop: c.crop, fit: c.fit, canvas: wide)
        })
}

private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 1e-6) -> Bool {
    abs(Double(a.x - b.x)) <= tolerance && abs(Double(a.y - b.y)) <= tolerance
}

struct EditorPicturePickTests {
    // MARK: boxes

    @Test func aFrameBecomesABoxAndBack() {
        let frame = EditFrame(x: -0.25, y: 0.1, w: 0.5, r: 30)
        let box = EditPictureBox(frame: frame, picture: landscape, canvas: wide)!
        #expect(box.width == 960)
        #expect(abs(box.height - 540) < 1e-9)
        #expect(near(box.center, CGPoint(x: 0, y: 108 + 270)))
        let back = box.frame(canvas: wide)
        #expect(abs(back.x - frame.x) < 1e-12 && abs(back.y - frame.y) < 1e-12 && abs(back.w - frame.w) < 1e-12)
        #expect(back.r == 30)
    }

    @Test func aTurnedBoxIsHitAlongItsTurnedAxes() {
        // 400 x 100, turned a quarter: on screen it is tall and narrow
        let box = EditPictureBox(center: CGPoint(x: 500, y: 500), width: 400, height: 100, r: 90)
        #expect(box.contains(CGPoint(x: 500, y: 680)))
        #expect(box.contains(CGPoint(x: 540, y: 330)))
        #expect(!box.contains(CGPoint(x: 680, y: 500)))
        #expect(!box.contains(CGPoint(x: 560, y: 500)))
        // 45°: the unturned corner region is empty, the turned diagonal is not
        let diamond = EditPictureBox(center: CGPoint(x: 0, y: 0), width: 200, height: 200, r: 45)
        #expect(!diamond.contains(CGPoint(x: 95, y: 95)))
        #expect(diamond.contains(CGPoint(x: 0, y: 140)))
        // agrees with the compositor's integer box for the same frame
        let frame = EditFrame(x: 0.3, y: 0.2, w: 0.3, r: 60)
        let lane = EditGeometry.laneBox(display: landscape, frame: frame, canvas: wide)!
        let float = EditPictureBox(frame: frame, picture: landscape, canvas: wide)!
        for p in [CGPoint(x: 900, y: 500), CGPoint(x: 700, y: 300), CGPoint(x: 1100, y: 700), CGPoint(x: 600, y: 600)] {
            #expect(lane.contains(p) == float.contains(p), "\(p)")
        }
    }

    @Test func aTapPicksTheTopClipIncludingTurnedAndPastTheEdge() {
        let ls = layers([
            clip("bg", lane: 0),
            clip("turned", lane: 1, frame: EditFrame(x: 0.4, y: 0.3, w: 0.3, r: 90)),
            clip("hanging", lane: 2, frame: EditFrame(x: -0.2, y: 0.6, w: 0.4)),
        ])
        #expect(ls.map(\.id) == ["bg", "turned", "hanging"])
        // inside the turned box, where the unturned one would not reach (above its unturned top)
        let turned = ls[1].box
        let up = turned.point(local: -0.9 * turned.width / 2, 0)   // along its long axis, now vertical
        #expect(up.y < 0.3 * 1080)
        #expect(EditPicturePick.pick(ls, at: up, previous: nil, samePlace: 10) == "turned")
        // the visible part of a box hanging past the left edge
        #expect(EditPicturePick.pick(ls, at: CGPoint(x: 40, y: 0.7 * 1080), previous: nil, samePlace: 10) == "hanging")
        // elsewhere the fill clip covers the canvas
        #expect(EditPicturePick.pick(ls, at: CGPoint(x: 1800, y: 100), previous: nil, samePlace: 10) == "bg")
    }

    @Test func nothingUnderTheFingerPicksNothing() {
        let ls = layers([clip("small", lane: 1, frame: EditFrame(x: 0.1, y: 0.1, w: 0.2))])
        #expect(EditPicturePick.pick(ls, at: CGPoint(x: 1500, y: 900), previous: nil, samePlace: 10) == nil)
        #expect(EditPicturePick.pick([], at: .zero, previous: nil, samePlace: 10) == nil)
    }

    @Test func hiddenOffTimeAndOffCanvasClipsAreNotOnThePicture() {
        let ls = layers([
            clip("bg", lane: 0),
            clip("hidden", lane: 1, hidden: true),
            clip("later", lane: 2, at: 2, out: 1),
            clip("gone", lane: 3, frame: EditFrame(x: 1.2, y: 0.2, w: 0.3)),
            clip("fit", lane: 4, fit: .fit),
        ], sizes: ["fit": square])
        #expect(ls.map(\.id) == ["bg", "fit"])
        // `fit` of a square on 16:9: the middle 1080 x 1080 only
        #expect(EditPicturePick.pick(ls, at: CGPoint(x: 960, y: 540), previous: nil, samePlace: 10) == "fit")
        #expect(EditPicturePick.pick(ls, at: CGPoint(x: 100, y: 540), previous: nil, samePlace: 10) == "bg")
        // at 2.5 s the later clip is up
        let later = layers([clip("bg", lane: 0), clip("later", lane: 2, at: 2, out: 1)], at: 75)
        #expect(later.map(\.id) == ["bg", "later"])
    }

    @Test func aKeyedClipIsPassedOverWhenSomethingShowsThroughIt() {
        let ls = layers([clip("under", lane: 0), clip("green", lane: 1, keyed: true)])
        let p = CGPoint(x: 960, y: 540)
        #expect(EditPicturePick.pick(ls, at: p, previous: nil, samePlace: 10) == "under")
        // tapping again reaches the keyed clip
        #expect(EditPicturePick.pick(ls, at: p, previous: .init(id: "under", point: p), samePlace: 10) == "green")
        // nothing below it: the keyed clip itself
        let alone = layers([clip("green", lane: 1, keyed: true)])
        #expect(EditPicturePick.pick(alone, at: p, previous: nil, samePlace: 10) == "green")
        // a keyed clip only partly over the lower one: outside the lower clip it is the pick
        let partly = layers([
            clip("small", lane: 0, frame: EditFrame(x: 0, y: 0, w: 0.25)),
            clip("green", lane: 1, keyed: true),
        ])
        #expect(EditPicturePick.pick(partly, at: CGPoint(x: 100, y: 100), previous: nil, samePlace: 10) == "small")
        #expect(EditPicturePick.pick(partly, at: CGPoint(x: 1500, y: 900), previous: nil, samePlace: 10) == "green")
    }

    @Test func theSameSpotAgainPicksTheNextClipDownAndWrapsRound() {
        let ls = layers([
            clip("a", lane: 0),
            clip("b", lane: 1, frame: EditFrame(x: 0.2, y: 0.2, w: 0.6)),
            clip("c", lane: 2, frame: EditFrame(x: 0.4, y: 0.4, w: 0.2)),
        ])
        let p = CGPoint(x: 960, y: 540)
        var previous: EditPicturePick.Previous?
        var picks: [String] = []
        for _ in 0..<4 {
            let id = EditPicturePick.pick(ls, at: p, previous: previous, samePlace: 12)!
            picks.append(id)
            previous = .init(id: id, point: CGPoint(x: p.x + 3, y: p.y - 2))
        }
        #expect(picks == ["c", "b", "a", "c"])
        // somewhere else: the top clip there, whatever was picked before
        #expect(EditPicturePick.pick(ls, at: CGPoint(x: 960, y: 300), previous: .init(id: "c", point: p), samePlace: 12) == "b")
        // a previous pick no longer under the finger: back to the top
        #expect(EditPicturePick.pick(ls, at: CGPoint(x: 100, y: 100), previous: .init(id: "c", point: CGPoint(x: 101, y: 100)),
                                     samePlace: 12) == "a")
    }

    // MARK: snaps

    @Test func aMoveSnapsEdgesAndCentreLinesWithinTheThreshold() {
        let canvas = wide
        // left edge 4 px from the canvas edge
        let left = EditPictureBox(center: CGPoint(x: 204, y: 300), width: 400, height: 200)
        let (l, lg) = EditPicturePick.snapMove(left, canvas: canvas, threshold: 6)
        #expect(abs(Double(l.bounds.minX)) < 1e-9)
        #expect(lg == [.left])
        // centre 5 px off the middle both ways
        let mid = EditPictureBox(center: CGPoint(x: 965, y: 535), width: 300, height: 200)
        let (m, mg) = EditPicturePick.snapMove(mid, canvas: canvas, threshold: 6)
        #expect(near(m.center, CGPoint(x: 960, y: 540)))
        #expect(mg == [.centerX, .centerY])
        // bottom-right
        let corner = EditPictureBox(center: CGPoint(x: 1920 - 103, y: 1080 - 52), width: 200, height: 100)
        let (c, cg) = EditPicturePick.snapMove(corner, canvas: canvas, threshold: 6)
        #expect(abs(Double(c.bounds.maxX) - 1920) < 1e-9 && abs(Double(c.bounds.maxY) - 1080) < 1e-9)
        #expect(cg == [.right, .bottom])
        // past the threshold: untouched
        let free = EditPictureBox(center: CGPoint(x: 700, y: 300), width: 300, height: 200)
        let (f, fg) = EditPicturePick.snapMove(free, canvas: canvas, threshold: 6)
        #expect(f == free)
        #expect(fg.isEmpty)
        // a box as wide as the canvas sits on both edges and the middle
        let full = EditPictureBox(center: CGPoint(x: 962, y: 300), width: 1920, height: 200)
        #expect(EditPicturePick.snapMove(full, canvas: canvas, threshold: 6).guides == [.left, .centerX, .right])
        // a turned box snaps by what it covers on screen
        let turned = EditPictureBox(center: CGPoint(x: 103, y: 500), width: 400, height: 200, r: 90)
        let (t, tg) = EditPicturePick.snapMove(turned, canvas: canvas, threshold: 6)
        #expect(abs(Double(t.bounds.minX)) < 1e-6)
        #expect(tg == [.left])
    }

    @Test func aTurnClicksToTheQuarterAnglesWithinThreeDegrees() {
        #expect(EditPicturePick.snapAngle(2.5) == (0, 0))
        #expect(EditPicturePick.snapAngle(-2.9) == (0, 0))
        #expect(EditPicturePick.snapAngle(87.5) == (90, 90))
        #expect(EditPicturePick.snapAngle(-92) == (-90, -90))
        #expect(EditPicturePick.snapAngle(178) == (180, 180))
        #expect(EditPicturePick.snapAngle(-178.5) == (180, 180))
        #expect(EditPicturePick.snapAngle(176).stop == nil)
        #expect(EditPicturePick.snapAngle(176).r == 176)
        #expect(EditPicturePick.snapAngle(3.5).stop == nil)
        #expect(EditPicturePick.snapAngle(370) == (10, nil))
        #expect(EditPicturePick.snapAngle(-268) == (90, 90))
    }

    // MARK: corner resize

    @Test func aCornerResizeKeepsTheOppositeCornerAndTheShapeInATurnedBox() {
        let box = EditPictureBox(center: CGPoint(x: 900, y: 500), width: 400, height: 225, r: 30)
        for corner in 0..<4 {
            let anchor = box.corners[(corner + 2) % 4]
            // outward along the diagonal by half again, and off it a little (projected)
            let dragged = box.corners[corner]
            let out = CGPoint(x: anchor.x + (dragged.x - anchor.x) * 1.5 + 7, y: anchor.y + (dragged.y - anchor.y) * 1.5 - 4)
            let r = EditPicturePick.resize(box, corner: corner, to: out, minWidth: 10, maxWidth: 10_000)
            #expect(near(r.corners[(corner + 2) % 4], anchor, 1e-6), "corner \(corner)")
            #expect(abs(r.width / r.height - box.width / box.height) < 1e-9)
            #expect(r.r == 30)
            #expect(r.width > box.width * 1.4 && r.width < box.width * 1.6)
            // exactly on the diagonal: the dragged corner lands under the finger
            let on = CGPoint(x: anchor.x + (dragged.x - anchor.x) * 0.5, y: anchor.y + (dragged.y - anchor.y) * 0.5)
            let half = EditPicturePick.resize(box, corner: corner, to: on, minWidth: 10, maxWidth: 10_000)
            #expect(near(half.corners[corner], on, 1e-6))
            #expect(abs(half.width - 200) < 1e-9)
        }
        // past the opposite corner: held at the smallest width, still anchored
        let anchor = box.corners[0]
        let tiny = EditPicturePick.resize(box, corner: 2, to: CGPoint(x: anchor.x - 50, y: anchor.y - 50), minWidth: 96, maxWidth: 7680)
        #expect(tiny.width == 96)
        #expect(near(tiny.corners[0], anchor, 1e-6))
        // and at the largest
        let huge = EditPicturePick.resize(box, corner: 2, to: CGPoint(x: 1e6, y: 1e6), minWidth: 96, maxWidth: 7680)
        #expect(huge.width == 7680)
        #expect(near(huge.corners[0], anchor, 1e-6))
    }

    // MARK: the knob and the pinch

    @Test func theKnobTurnsByTheAngleTheFingerSweeps() {
        let c = CGPoint(x: 0, y: 0)
        #expect(EditPicturePick.angle(from: c, to: CGPoint(x: 0, y: -100)) == 0)
        #expect(abs(EditPicturePick.angle(from: c, to: CGPoint(x: 100, y: 0)) - 90) < 1e-9)
        #expect(abs(EditPicturePick.angle(from: c, to: CGPoint(x: -100, y: 0)) + 90) < 1e-9)
        #expect(abs(abs(EditPicturePick.angle(from: c, to: CGPoint(x: 0, y: 100))) - 180) < 1e-9)
        // grabbed on the knob of an unturned box, dragged a quarter round clockwise
        #expect(abs(EditPicturePick.turn(startR: 0, center: c, from: CGPoint(x: 0, y: -100), to: CGPoint(x: 100, y: 0)) - 90) < 1e-9)
        // grabbed a little off the knob of a box at 10°: no jump, only the sweep is added
        let grab = CGPoint(x: 30, y: -100)
        #expect(abs(EditPicturePick.turn(startR: 10, center: c, from: grab, to: grab) - 10) < 1e-9)
        // across ±180 it wraps
        let start = CGPoint(x: 10, y: 100), past = CGPoint(x: -30, y: 100)
        let wrapped = EditPicturePick.turn(startR: 170, center: c, from: start, to: past)
        #expect(wrapped < -160 && wrapped > -180)
        // the knob sits above the top edge and turns with the box
        let box = EditPictureBox(center: CGPoint(x: 500, y: 500), width: 200, height: 100, r: 90)
        #expect(near(box.knob(distance: 20), CGPoint(x: 570, y: 500), 1e-9))
        #expect(abs(EditPicturePick.angle(from: box.center, to: box.knob(distance: 20)) - box.r) < 1e-9)
    }

    @Test func aPinchSizesAboutTheCentreAndATwistTurns() {
        let box = EditPictureBox(center: CGPoint(x: 600, y: 400), width: 400, height: 300, r: 170)
        let s = box.scaled(by: 1.5, minWidth: 96, maxWidth: 7680).turned(by: 20)
        #expect(s.center == box.center)
        #expect(s.width == 600 && s.height == 450)
        #expect(abs(s.r + 170) < 1e-9)
        #expect(box.scaled(by: 0.01, minWidth: 96, maxWidth: 7680).width == 96)
        #expect(box.scaled(by: 0.01, minWidth: 96, maxWidth: 7680).height == 72)
    }
}

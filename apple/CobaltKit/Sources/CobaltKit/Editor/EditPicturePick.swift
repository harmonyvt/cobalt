import CoreGraphics
import Foundation

// The touchable picture (apple/CONTRACT-EDITOR.md 15.3): which clip a tap on the picture picks, and the box arithmetic the
// picture's gestures run on (move with edge and centre snaps, resize from a corner with the opposite corner fixed, turn from
// the knob, pinch and twist). Pure: canvas pixels in, canvas pixels out (origin top-left, y down, degrees clockwise). The
// view turns its points into pixels with the canvas scale and passes thresholds in pixels.

/// A clip's box on the canvas in unrounded pixels: the centre, the unturned size and the turn about the centre. The picture's
/// gestures work on this and write it back with `frame(canvas:)`, so a drag is smooth and the even rounding of `laneBox` is
/// left to the session's frame rounding.
public struct EditPictureBox: Sendable, Equatable {
    public var center: CGPoint
    public var width: Double
    public var height: Double
    /// Degrees clockwise about `center`.
    public var r: Double

    public init(center: CGPoint, width: Double, height: Double, r: Double = 0) {
        self.center = center
        self.width = width
        self.height = height
        self.r = r
    }

    /// The box `frame` gives a picture `picture` pixels big (already cropped) on `canvas`. Nil for an unusable size.
    public init?(frame: EditFrame, picture: PixelSize, canvas: EditCanvas) {
        guard picture.w > 0, picture.h > 0, canvas.w > 0, canvas.h > 0 else { return nil }
        let w = frame.w * Double(canvas.w)
        let h = w * Double(picture.h) / Double(picture.w)
        self.init(
            center: CGPoint(x: frame.x * Double(canvas.w) + w / 2, y: frame.y * Double(canvas.h) + h / 2), width: w, height: h,
            r: frame.r)
    }

    /// Back to a frame (fractions of the canvas). Not clamped or rounded: `EditSession.setClipFrame` does both.
    public func frame(canvas: EditCanvas) -> EditFrame {
        let cw = Double(max(1, canvas.w)), ch = Double(max(1, canvas.h))
        return EditFrame(
            x: (Double(center.x) - width / 2) / cw, y: (Double(center.y) - height / 2) / ch, w: width / cw, r: r)
    }

    /// A point given relative to the centre in the box's own (unturned) axes, on the canvas.
    public func point(local dx: Double, _ dy: Double) -> CGPoint {
        let p = EditPicturePick.rotate(dx: dx, dy: dy, degrees: r)
        return CGPoint(x: Double(center.x) + p.x, y: Double(center.y) + p.y)
    }

    /// A canvas point in the box's own (unturned) axes, relative to the centre.
    public func local(_ p: CGPoint) -> CGPoint {
        EditPicturePick.rotate(dx: Double(p.x - center.x), dy: Double(p.y - center.y), degrees: -r)
    }

    /// Top-left, top-right, bottom-right, bottom-left of the unturned box, turned.
    public var corners: [CGPoint] {
        let hw = width / 2, hh = height / 2
        return [point(local: -hw, -hh), point(local: hw, -hh), point(local: hw, hh), point(local: -hw, hh)]
    }

    /// The upright rectangle that holds the turned box.
    public var bounds: CGRect {
        let cs = corners
        let xs = cs.map(\.x), ys = cs.map(\.y)
        let minX = xs.min() ?? center.x, maxX = xs.max() ?? center.x
        let minY = ys.min() ?? center.y, maxY = ys.max() ?? center.y
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// True when canvas point `p` is on the turned box (`slop` pixels of grace on every side).
    public func contains(_ p: CGPoint, slop: Double = 0) -> Bool {
        let q = local(p)
        return abs(Double(q.x)) <= width / 2 + slop && abs(Double(q.y)) <= height / 2 + slop
    }

    /// The knob: `distance` pixels above the middle of the top edge, along the box's own up (so it turns with the box).
    public func knob(distance: Double) -> CGPoint { point(local: 0, -height / 2 - distance) }

    public func moved(dx: Double, dy: Double) -> EditPictureBox {
        var b = self
        b.center = CGPoint(x: Double(center.x) + dx, y: Double(center.y) + dy)
        return b
    }

    /// Sized about the centre, the shape kept. `width` stays within `minWidth...maxWidth` pixels.
    public func scaled(by factor: Double, minWidth: Double, maxWidth: Double) -> EditPictureBox {
        guard width > 0, factor.isFinite else { return self }
        let w = min(max(width * factor, minWidth), max(minWidth, maxWidth))
        var b = self
        b.height = height * w / width
        b.width = w
        return b
    }

    /// Turned by `degrees` about the centre, wrapped into -180...180.
    public func turned(by degrees: Double) -> EditPictureBox {
        var b = self
        b.r = EditPicturePick.wrap(r + degrees)
        return b
    }
}

public enum EditPicturePick {
    // MARK: - Which clip a tap picks

    /// A clip the picture shows at the playhead, with its box.
    public struct Layer: Sendable, Equatable {
        public var id: String
        /// 0 is the bottom. A version 1 overlay is its track + 1.
        public var lane: Int
        /// The clip has a greenscreen key (`key`).
        public var keyed: Bool
        public var box: EditPictureBox

        public init(id: String, lane: Int, keyed: Bool, box: EditPictureBox) {
            self.id = id
            self.lane = lane
            self.keyed = keyed
            self.box = box
        }
    }

    /// The clip the last tap on the picture picked, and where (canvas pixels).
    public struct Previous: Sendable, Equatable {
        public var id: String
        public var point: CGPoint

        public init(id: String, point: CGPoint) {
            self.id = id
            self.point = point
        }
    }

    /// The clips drawn at output frame `frame`, bottom first (the compositor's draw order: lane, then `at`, then array order;
    /// version 1: the main clip, then overlays by track). Hidden clips and boxes wholly off the canvas (`laneBox` nil) are left
    /// out. `picture` is a clip's picture size (cropped); `frameBox` its frame, or the box `fit`/`fill` gives it. A clip either
    /// closure answers nil for (its file's size not known yet) is left out.
    public static func layers(
        timeline: EditTimeline, timing: EditTiming, frame k: Int,
        picture: (String) -> PixelSize?, frameBox: (String) -> EditFrame?
    ) -> [Layer] {
        let canvas = timeline.canvas
        func layer(id: String, lane: Int, keyed: Bool) -> Layer? {
            guard let size = picture(id), let frame = frameBox(id),
                  EditGeometry.laneBox(display: size, frame: frame, canvas: canvas) != nil,
                  let box = EditPictureBox(frame: frame, picture: size, canvas: canvas) else { return nil }
            return Layer(id: id, lane: lane, keyed: keyed, box: box)
        }
        var out: [Layer] = []
        if timeline.version >= 2 {
            guard timing.laneClips.count == timeline.clips.count else { return [] }
            for index in EditLanes.drawOrder(timeline) {
                let clip = timeline.clips[index], row = timing.laneClips[index]
                guard !clip.hidden, k >= row.start, k < row.start + row.frames else { continue }
                if let l = layer(id: clip.id, lane: clip.lane, keyed: clip.key?.normalized() != nil) { out.append(l) }
            }
            return out
        }
        if let (index, _) = timing.clip(atFrame: k), timeline.main.indices.contains(index),
           let l = layer(id: timeline.main[index].id, lane: 0, keyed: false) {
            out.append(l)
        }
        let overlays = timeline.overlay
        for j in timeline.overlayDrawOrder where j < timing.overlay.count {
            let o = overlays[j], row = timing.overlay[j]
            guard !o.hidden, k >= row.start, k < row.start + row.frames else { continue }
            if let l = layer(id: o.id, lane: o.track + 1, keyed: o.hasKey) { out.append(l) }
        }
        return out
    }

    /// The clips under canvas point `point`, top first, in the order taps go through them: the first pick first, then on
    /// down, then round from the top. The first pick is the top clip, passing over a keyed clip while a lower clip is also
    /// under the point (a tap in a greenscreen hole picks what shows through it).
    public static func cycle(_ layers: [Layer], at point: CGPoint) -> [Layer] {
        let under = layers.reversed().filter { $0.box.contains(point) }
        guard !under.isEmpty else { return [] }
        let first = under.firstIndex { !$0.keyed } ?? under.count - 1
        return Array(under[first...] + under[..<first])
    }

    /// The clip a tap at `point` picks; nil when no clip is under it. `layers` is bottom first (`layers(...)`). When the
    /// last tap picked `previous` within `samePlace` pixels of here and that clip is still under the point, the next one in
    /// `cycle` is picked: tap the same spot again for the clip below.
    public static func pick(_ layers: [Layer], at point: CGPoint, previous: Previous?, samePlace: Double) -> String? {
        let order = cycle(layers, at: point)
        guard let top = order.first else { return nil }
        if let previous, distance(previous.point, point) <= samePlace,
           let i = order.firstIndex(where: { $0.id == previous.id }) {
            return order[(i + 1) % order.count].id
        }
        return top.id
    }

    // MARK: - Snaps

    /// The canvas lines a box snapped to.
    public struct Guides: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// x = 0, the middle, the right edge.
        public static let left = Guides(rawValue: 1 << 0)
        public static let centerX = Guides(rawValue: 1 << 1)
        public static let right = Guides(rawValue: 1 << 2)
        /// y = 0, the middle, the bottom edge.
        public static let top = Guides(rawValue: 1 << 3)
        public static let centerY = Guides(rawValue: 1 << 4)
        public static let bottom = Guides(rawValue: 1 << 5)
    }

    /// A moved box held to the canvas edges and centre lines: on each axis the nearest of the box's edges and middle (of the
    /// turned box's upright bounds) to the matching canvas line, when within `threshold` pixels. `guides` names every line
    /// the box then sits on.
    public static func snapMove(_ box: EditPictureBox, canvas: EditCanvas, threshold: Double) -> (box: EditPictureBox, guides: Guides) {
        let cw = Double(canvas.w), ch = Double(canvas.h)
        let b = box.bounds
        func best(_ pairs: [(have: Double, want: Double)]) -> Double {
            var delta = 0.0, gap = Double.infinity
            for p in pairs where abs(p.want - p.have) <= threshold && abs(p.want - p.have) < gap {
                gap = abs(p.want - p.have)
                delta = p.want - p.have
            }
            return delta
        }
        let dx = best([(Double(b.minX), 0), (Double(b.midX), cw / 2), (Double(b.maxX), cw)])
        let dy = best([(Double(b.minY), 0), (Double(b.midY), ch / 2), (Double(b.maxY), ch)])
        let out = box.moved(dx: dx, dy: dy)
        return (out, guides(of: out, canvas: canvas))
    }

    /// The canvas lines the upright bounds of `box` sit on (within half a pixel).
    static func guides(of box: EditPictureBox, canvas: EditCanvas, edgesOnCentre: Bool = false) -> Guides {
        let cw = Double(canvas.w), ch = Double(canvas.h)
        let o = box.bounds
        let on = 0.5
        var guides: Guides = []
        if abs(Double(o.minX)) <= on { guides.insert(.left) }
        if abs(Double(o.midX) - cw / 2) <= on { guides.insert(.centerX) }
        if abs(Double(o.maxX) - cw) <= on { guides.insert(.right) }
        if abs(Double(o.minY)) <= on { guides.insert(.top) }
        if abs(Double(o.midY) - ch / 2) <= on { guides.insert(.centerY) }
        if abs(Double(o.maxY) - ch) <= on { guides.insert(.bottom) }
        if edgesOnCentre {
            // a resized box's edge on a centre line shows it too
            if abs(Double(o.minX) - cw / 2) <= on || abs(Double(o.maxX) - cw / 2) <= on { guides.insert(.centerX) }
            if abs(Double(o.minY) - ch / 2) <= on || abs(Double(o.maxY) - ch / 2) <= on { guides.insert(.centerY) }
        }
        return guides
    }

    /// The angles a turn clicks to.
    public static let angleStops: [Double] = [-90, 0, 90, 180]

    /// `r` wrapped into -180...180 and pulled to 0, ±90 or 180 when within `within` degrees. `stop` is the angle it clicked
    /// to (180 for both ±180), nil when it did not.
    public static func snapAngle(_ r: Double, within: Double = 3) -> (r: Double, stop: Double?) {
        let a = wrap(r)
        for stop in angleStops {
            var gap = abs(a - stop)
            if stop == 180 { gap = min(gap, abs(a + 180)) }
            if gap <= within { return (stop, stop) }
        }
        return (a, nil)
    }

    /// Degrees into -180...180.
    public static func wrap(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var a = degrees.truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 } else if a < -180 { a += 360 }
        return a
    }

    // MARK: - Corner resize

    /// The box with corner `corner` (0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left, as `EditPictureBox.corners`)
    /// dragged to `finger`: the opposite corner stays put and the shape is kept, in the box's own turned axes. The finger is
    /// projected on the diagonal; the width stays within `minWidth...maxWidth` pixels.
    public static func resize(
        _ box: EditPictureBox, corner: Int, to finger: CGPoint, minWidth: Double, maxWidth: Double
    ) -> EditPictureBox {
        guard box.width > 0, box.height > 0 else { return box }
        let signs: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        let c = ((corner % 4) + 4) % 4
        let (sx, sy) = signs[c]
        let anchor = box.corners[(c + 2) % 4]
        // the diagonal from the fixed corner to the dragged one, in the box's own axes
        let dx = sx * box.width, dy = sy * box.height
        let length = (dx * dx + dy * dy).squareRoot()
        let v = rotate(dx: Double(finger.x - anchor.x), dy: Double(finger.y - anchor.y), degrees: -box.r)
        let along = (Double(v.x) * dx + Double(v.y) * dy) / length
        let w = min(max(box.width * along / length, minWidth), max(minWidth, maxWidth))
        let k = w / box.width
        let half = rotate(dx: dx * k / 2, dy: dy * k / 2, degrees: box.r)
        return EditPictureBox(
            center: CGPoint(x: Double(anchor.x) + Double(half.x), y: Double(anchor.y) + Double(half.y)),
            width: w, height: box.height * k, r: box.r)
    }

    /// A box `resize` made, held to the canvas edges and centre lines. The opposite corner `corner` was dragged from stays
    /// fixed and the shape is kept, so the only freedom is the size: every edge of the turned box's upright bounds that
    /// moves with it (and its middle) is tried against the canvas lines, and the size that puts the nearest one (within
    /// `threshold` pixels) on its line wins. A size outside `minWidth...maxWidth` pixels is not offered. `guides` names every
    /// line the box then sits on.
    public static func snapResize(
        _ box: EditPictureBox, corner: Int, canvas: EditCanvas, threshold: Double, minWidth: Double, maxWidth: Double
    ) -> (box: EditPictureBox, guides: Guides) {
        guard box.width > 0, box.height > 0 else { return (box, guides(of: box, canvas: canvas, edgesOnCentre: true)) }
        let cw = Double(canvas.w), ch = Double(canvas.h)
        let c = ((corner % 4) + 4) % 4
        let anchor = box.corners[(c + 2) % 4]
        let b = box.bounds
        var factor = 1.0, gap = Double.infinity
        // an edge at `have` moves to `anchor + f * (have - anchor)` when the box is sized by f about the fixed corner
        func consider(_ have: Double, anchor a: Double, lines: [Double]) {
            let offset = have - a
            guard abs(offset) > 1e-9 else { return }
            for line in lines {
                let f = (line - a) / offset
                let w = box.width * f
                guard f > 0, w >= minWidth - 1e-9, w <= max(minWidth, maxWidth) + 1e-9 else { continue }
                let d = abs(line - have)
                if d <= threshold, d < gap {
                    gap = d
                    factor = f
                }
            }
        }
        let ax = Double(anchor.x), ay = Double(anchor.y)
        consider(Double(b.minX), anchor: ax, lines: [0, cw / 2, cw])
        consider(Double(b.maxX), anchor: ax, lines: [0, cw / 2, cw])
        consider(Double(b.midX), anchor: ax, lines: [cw / 2])
        consider(Double(b.minY), anchor: ay, lines: [0, ch / 2, ch])
        consider(Double(b.maxY), anchor: ay, lines: [0, ch / 2, ch])
        consider(Double(b.midY), anchor: ay, lines: [ch / 2])
        guard factor != 1 else { return (box, guides(of: box, canvas: canvas, edgesOnCentre: true)) }
        var out = box
        out.center = CGPoint(
            x: ax + (Double(box.center.x) - ax) * factor, y: ay + (Double(box.center.y) - ay) * factor)
        out.width = box.width * factor
        out.height = box.height * factor
        return (out, guides(of: out, canvas: canvas, edgesOnCentre: true))
    }

    // MARK: - Turn from the knob

    /// The direction from `center` to `finger` in degrees clockwise from straight up (the knob's place on an unturned box).
    public static func angle(from center: CGPoint, to finger: CGPoint) -> Double {
        let dx = Double(finger.x - center.x), dy = Double(finger.y - center.y)
        guard dx != 0 || dy != 0 else { return 0 }
        return atan2(dx, -dy) * 180 / .pi
    }

    /// The turn after the knob, grabbed at `start` while the box was turned `startR`, is dragged to `finger`: the angle the
    /// finger swept about the centre is added, so grabbing the knob a little off its middle does not make it jump. Wrapped
    /// into -180...180, not snapped.
    public static func turn(startR: Double, center: CGPoint, from start: CGPoint, to finger: CGPoint) -> Double {
        wrap(startR + angle(from: center, to: finger) - angle(from: center, to: start))
    }

    // MARK: - helpers

    /// (dx, dy) turned clockwise on screen (y down) by `degrees`.
    static func rotate(dx: Double, dy: Double, degrees: Double) -> CGPoint {
        guard degrees != 0 else { return CGPoint(x: dx, y: dy) }
        let a = degrees * .pi / 180
        return CGPoint(x: dx * cos(a) - dy * sin(a), y: dx * sin(a) + dy * cos(a))
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - The session's picture

extension EditSession {
    /// The clips the picture shows at the playhead, bottom first, with their boxes (a clip with no `frame` has the box `fit` or
    /// `fill` gives it). See `EditPicturePick.layers`.
    public func pictureLayers() -> [EditPicturePick.Layer] {
        EditPicturePick.layers(
            timeline: timeline, timing: timing, frame: playhead,
            picture: { self.pictureSize(ofClip: $0) }, frameBox: { self.frameBox(ofClip: $0) })
    }

    /// The selected clip's id, whichever row it is on.
    public var pictureSelectionID: String? {
        switch selection {
        case .main(let id), .overlay(let id): id
        case .none: nil
        }
    }

    /// Selects a clip picked on the picture: lane 0 is the main row, every higher lane an overlay row (as the timeline does).
    public func selectFromPicture(_ layer: EditPicturePick.Layer) {
        selection = layer.lane == 0 ? .main(layer.id) : .overlay(layer.id)
    }

    /// The clip's lane is locked on this device (`setClipFrame` refuses it). Lane 0 is never locked.
    public func pictureLaneLocked(_ lane: Int) -> Bool {
        lane > 0 && isTrackLocked(lane - 1)
    }
}

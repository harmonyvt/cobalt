import CoreGraphics
import Foundation

// Geometry: integer pixels (APP-API-CONTRACT 31.6). Both renderers use exactly this, so the crop rectangle, the scale and the
// place of a clip on the canvas are the same numbers in the preview and in the render.

public struct PixelSize: Sendable, Equatable {
    public var w: Int, h: Int
    public init(w: Int, h: Int) { self.w = w; self.h = h }
    public var cgSize: CGSize { CGSize(width: w, height: h) }
}

public struct PixelPoint: Sendable, Equatable {
    public var x: Int, y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct PixelRect: Sendable, Equatable {
    public var x: Int, y: Int, w: Int, h: Int
    public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

public enum EditGeometry {
    /// Smallest cropped width and height in pixels (`api/helper/crop.js` `MIN_CROP_PX`).
    public static let minCropPixels = 64

    /// A main clip on the canvas: the source rectangle kept, the size it is scaled to, and where the scaled picture's top-left
    /// sits on the canvas (negative for `fill`: the excess is cut by the canvas edge).
    public struct Main: Sendable, Equatable {
        public var crop: PixelRect
        public var scaled: PixelSize
        public var place: PixelPoint

        public init(crop: PixelRect, scaled: PixelSize, place: PixelPoint) {
            self.crop = crop
            self.scaled = scaled
            self.place = place
        }
    }

    /// `mainPlacement` of 31.6. Nil when the crop is under 64 px on a side (`error.edit.range` at render) or the display size is
    /// unusable.
    public static func main(display: PixelSize, crop: EditCrop?, fit: EditFit, canvas: EditCanvas) -> Main? {
        let cropRect: PixelRect
        if let crop {
            guard let px = cropPixels(crop, display: display) else { return nil }
            cropRect = px
        } else {
            let w = EditMath.evenFloor(Double(display.w)), h = EditMath.evenFloor(Double(display.h))
            guard w >= 2, h >= 2 else { return nil }
            cropRect = PixelRect(x: 0, y: 0, w: w, h: h)
        }
        let cw = Double(cropRect.w), ch = Double(cropRect.h)
        let cvW = Double(canvas.w), cvH = Double(canvas.h)
        let k = fit == .fit ? min(cvW / cw, cvH / ch) : max(cvW / cw, cvH / ch)
        var dw = EditMath.evenNearest(cw * k)
        var dh = EditMath.evenNearest(ch * k)
        if fit == .fit {
            dw = min(dw, canvas.w)
            dh = min(dh, canvas.h)
        } else {
            dw = max(dw, canvas.w)
            dh = max(dh, canvas.h)
        }
        // every term is even: integers. `fit`: the bars; `fill`: minus the excess the canvas cuts.
        let place = PixelPoint(x: (canvas.w - dw) / 2, y: (canvas.h - dh) / 2)
        return Main(crop: cropRect, scaled: PixelSize(w: dw, h: dh), place: place)
    }

    /// `overlayPlacement` of 31.6: the overlay's rectangle on the canvas.
    public static func overlay(display: PixelSize, frame: EditFrame, canvas: EditCanvas) -> PixelRect {
        let sw = Double(max(1, display.w)), sh = Double(max(1, display.h))
        let ow = clamp(EditMath.evenNearest(frame.w * Double(canvas.w)), 2, EditMath.evenFloor(Double(canvas.w)))
        let oh = clamp(EditMath.evenNearest(Double(ow) * sh / sw), 2, EditMath.evenFloor(Double(canvas.h)))
        let ox = clamp(EditMath.roundHalfUp(frame.x * Double(canvas.w)), 0, canvas.w - ow)
        let oy = clamp(EditMath.roundHalfUp(frame.y * Double(canvas.h)), 0, canvas.h - oh)
        return PixelRect(x: ox, y: oy, w: ow, h: oh)
    }

    /// The overlay's height as a fraction of the canvas height (31.2: `h = w * canvas.w / canvas.h * srcH / srcW`).
    public static func overlayHeightFraction(display: PixelSize, frame: EditFrame, canvas: EditCanvas) -> Double {
        guard display.w > 0, canvas.h > 0 else { return 0 }
        return frame.w * Double(canvas.w) / Double(canvas.h) * Double(display.h) / Double(display.w)
    }

    /// The frame moved (and, if it cannot otherwise fit, shrunk) so `x, y >= 0`, `x + w <= 1`, `y + h <= 1`, and `w >= 0.05`.
    public static func clampInside(_ frame: EditFrame, display: PixelSize, canvas: EditCanvas) -> EditFrame {
        var w = min(1, max(0.05, frame.w.isFinite ? frame.w : 0.35))
        // too tall for the canvas: narrower, so the height fits
        if display.w > 0, display.h > 0, canvas.w > 0 {
            let widthForFullHeight = Double(canvas.h) / Double(canvas.w) * Double(display.w) / Double(display.h)
            if widthForFullHeight >= 0.05 { w = min(w, widthForFullHeight) }
        }
        w = EditJSON.fraction(w)
        let h = overlayHeightFraction(display: display, frame: EditFrame(x: 0, y: 0, w: w), canvas: canvas)
        let x = min(max(0, frame.x.isFinite ? frame.x : 0), max(0, 1 - w))
        let y = min(max(0, frame.y.isFinite ? frame.y : 0), max(0, 1 - h))
        return EditFrame(x: EditJSON.fraction(x), y: EditJSON.fraction(y), w: w, r: frame.r)
    }

    // MARK: - Version 2 boxes (APP-API-CONTRACT 69.7)

    /// True when a version 2 frame is also a valid version 1 overlay frame: unturned and inside the canvas (the server's
    /// `frameIsV1`). `v2ToV1` refuses every other frame with `needs_timeline_v2` at `clips[i].frame`.
    public static func isV1Frame(_ f: EditFrame) -> Bool {
        f.r == 0 && f.x >= 0 && f.y >= 0 && f.w <= 1 && f.x + f.w <= 1 + 1e-3
    }

    /// A version 2 clip's box on the canvas (`laneBoxPlacement` of `timeline.js`): like `overlay`, but not pushed back inside the
    /// canvas, so it may hang past any edge and be up to 4 canvases wide. Pixels, origin top-left, y down.
    public struct LaneBox: Sendable, Equatable {
        /// The unturned box.
        public var x: Int, y: Int, w: Int, h: Int
        /// Degrees clockwise about the box centre.
        public var r: Double
        /// The even-sized box that holds the turned picture, placed so the centre stays put. Nil when `r` is 0.
        public var turned: PixelRect?

        public init(x: Int, y: Int, w: Int, h: Int, r: Double, turned: PixelRect?) {
            self.x = x; self.y = y; self.w = w; self.h = h; self.r = r; self.turned = turned
        }

        /// What the picture covers on the canvas, turned or not.
        public var bounds: PixelRect { turned ?? PixelRect(x: x, y: y, w: w, h: h) }
        /// The centre both the box and the turn use.
        public var center: CGPoint { CGPoint(x: Double(x) + Double(w) / 2, y: Double(y) + Double(h) / 2) }

        /// The four corners after the turn: top-left, top-right, bottom-right, bottom-left (of the unturned box).
        public var corners: [CGPoint] {
            let c = center, hw = Double(w) / 2, hh = Double(h) / 2
            return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { dx, dy in
                let p = Self.turn(dx: dx, dy: dy, degrees: r)
                return CGPoint(x: c.x + p.x, y: c.y + p.y)
            }
        }

        /// True when canvas point `p` (pixels, y down) is on the turned picture.
        public func contains(_ p: CGPoint) -> Bool {
            let c = center
            let local = Self.turn(dx: Double(p.x - c.x), dy: Double(p.y - c.y), degrees: -r)
            return abs(local.x) <= Double(w) / 2 && abs(local.y) <= Double(h) / 2
        }

        /// (dx, dy) turned clockwise on screen (y down) by `degrees`.
        static func turn(dx: Double, dy: Double, degrees: Double) -> CGPoint {
            guard degrees != 0 else { return CGPoint(x: dx, y: dy) }
            let a = degrees * .pi / 180
            return CGPoint(x: dx * cos(a) - dy * sin(a), y: dx * sin(a) + dy * cos(a))
        }

        /// Core Image's way onto the canvas: maps a picture drawn at (0, 0, w, h) (y up) to the canvas (y up, the canvas
        /// `canvasHeight` tall), turned clockwise about the box centre.
        public func coreImageTransform(canvasHeight: Int) -> CGAffineTransform {
            let c = center
            return CGAffineTransform(translationX: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
                .concatenating(CGAffineTransform(rotationAngle: -CGFloat(r * .pi / 180)))
                .concatenating(CGAffineTransform(translationX: c.x, y: CGFloat(canvasHeight) - c.y))
        }
    }

    /// The box of a version 2 clip whose picture is `display` (already cropped when the clip has a crop). Nil when nothing of it
    /// would be on the canvas: it draws nothing (its sound still plays).
    public static func laneBox(display: PixelSize, frame: EditFrame, canvas: EditCanvas) -> LaneBox? {
        let cw = Double(canvas.w), ch = Double(canvas.h)
        let sw = Double(max(1, display.w)), sh = Double(max(1, display.h))
        let maxW = Int(EditValidation.frameMaxWidth)
        let ow = min(max(EditMath.evenNearest(frame.w * cw), 2), max(2, EditMath.evenFloor(cw * Double(maxW))))
        let oh = min(max(EditMath.evenNearest(Double(ow) * sh / sw), 2), max(2, EditMath.evenFloor(ch * Double(maxW) * 4)))
        let ox = EditMath.roundHalfUp(frame.x * cw)
        let oy = EditMath.roundHalfUp(frame.y * ch)
        let r = frame.r
        var turned: PixelRect?
        var bx = ox, by = oy, bw = ow, bh = oh
        if r != 0 {
            let a = r * .pi / 180
            let c = abs(cos(a)), s = abs(sin(a))
            let rw = 2 * Int(((Double(ow) * c + Double(oh) * s) / 2 - 1e-6).rounded(.up))
            let rh = 2 * Int(((Double(ow) * s + Double(oh) * c) / 2 - 1e-6).rounded(.up))
            let rect = PixelRect(x: ox + (ow - rw) / 2, y: oy + (oh - rh) / 2, w: rw, h: rh)
            turned = rect
            bx = rect.x; by = rect.y; bw = rw; bh = rh
        }
        if bx >= canvas.w || by >= canvas.h || bx + bw <= 0 || by + bh <= 0 { return nil }
        return LaneBox(x: ox, y: oy, w: ow, h: oh, r: r, turned: turned)
    }

    /// The box `fit` or `fill` gives a clip that has no `frame`, as a frame: a first move, size or turn starts from it, so the
    /// picture does not jump. `display` is the whole picture; `crop` is the clip's own. A `fill` of a very wide picture is
    /// narrower than it was (a frame is up to 4 canvas widths), about the same centre. Nil when the picture is unusable
    /// (a crop under 64 px).
    public static func fitFrame(display: PixelSize, crop: EditCrop?, fit: EditFit, canvas: EditCanvas) -> EditFrame? {
        guard let g = main(display: display, crop: crop, fit: fit, canvas: canvas), canvas.w > 0, canvas.h > 0 else { return nil }
        let cw = Double(canvas.w), ch = Double(canvas.h)
        var w = Double(g.scaled.w) / cw
        var x = Double(g.place.x) / cw
        let y = Double(g.place.y) / ch
        if w > EditValidation.frameMaxWidth {
            let centre = x + w / 2
            w = EditValidation.frameMaxWidth
            x = centre - w / 2
        }
        return EditFrame(x: EditJSON.fraction(x), y: EditJSON.fraction(y), w: EditJSON.fraction(w))
    }

    /// `cropToPixels` of `api/helper/crop.js` (section 10): each of x, y, w, h to the nearest even number, the size clamped to
    /// the even frame, the position clamped inside it. Nil under 64 px a side or for an unusable display size.
    public static func cropPixels(_ crop: EditCrop, display: PixelSize) -> PixelRect? {
        guard display.w >= 2, display.h >= 2 else { return nil }
        let sw = Double(display.w), sh = Double(display.h)
        let maxW = EditMath.evenFloor(sw), maxH = EditMath.evenFloor(sh)
        let w = min(EditMath.evenNearest(crop.w * sw), maxW)
        let h = min(EditMath.evenNearest(crop.h * sh), maxH)
        guard w >= minCropPixels, h >= minCropPixels else { return nil }
        let x = max(0, min(EditMath.evenNearest(crop.x * sw), EditMath.evenFloor(Double(display.w - w))))
        let y = max(0, min(EditMath.evenNearest(crop.y * sh), EditMath.evenFloor(Double(display.h - h))))
        return PixelRect(x: x, y: y, w: w, h: h)
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), max(lo, hi)) }
}

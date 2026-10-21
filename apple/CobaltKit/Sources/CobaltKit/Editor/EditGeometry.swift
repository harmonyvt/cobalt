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
        return EditFrame(x: EditJSON.fraction(x), y: EditJSON.fraction(y), w: w)
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

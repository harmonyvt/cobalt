import CoreGraphics
import Foundation

/// A spatial crop for a webp (CONTRACT-ORBIT 2d): a rectangle in the source's DISPLAY orientation
/// (after rotation metadata), normalized to 0...1. It rides on `POST /studio/<sid>/render` as
/// `crop: {x, y, w, h}` and is left out when it covers the whole frame.
public struct CropRect: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public static let full = CropRect(x: 0, y: 0, w: 1, h: 1)

    /// The server rejects a crop under this many pixels on either side (`error.webp.invalid_params`).
    public static let minPixels: Double = 64

    /// Covers the whole frame (within a thousandth): nothing to send.
    public var isFull: Bool {
        abs(x) < 0.001 && abs(y) < 0.001 && abs(w - 1) < 0.001 && abs(h - 1) < 0.001
    }

    // MARK: Aspect presets

    public enum Aspect: String, Sendable, CaseIterable, Equatable {
        case original, square, fourFive, nineSixteen, sixteenNine, free

        /// "original", "1:1", "4:5", "9:16", "16:9", "free".
        public var label: String {
            switch self {
            case .original: return "original"
            case .square: return "1:1"
            case .fourFive: return "4:5"
            case .nineSixteen: return "9:16"
            case .sixteenNine: return "16:9"
            case .free: return "free"
            }
        }

        /// Width over height; nil for `original` (the source's own) and `free`.
        public var ratio: Double? {
            switch self {
            case .square: return 1
            case .fourFive: return 4.0 / 5.0
            case .nineSixteen: return 9.0 / 16.0
            case .sixteenNine: return 16.0 / 9.0
            case .original, .free: return nil
            }
        }
    }

    /// The largest crop of `aspect` that fits `sourceSize` (pixels, display orientation), centred.
    /// `original` is the whole frame. `free` has no shape of its own: the whole frame as a start.
    public static func centered(_ aspect: Aspect, in sourceSize: CGSize) -> CropRect {
        guard let r = aspect.ratio, sourceSize.width > 0, sourceSize.height > 0 else { return .full }
        let sourceRatio = Double(sourceSize.width / sourceSize.height)
        var rect: CropRect
        if sourceRatio > r {
            rect = CropRect(x: 0, y: 0, w: r / sourceRatio, h: 1)        // pillar: full height, narrower
        } else {
            rect = CropRect(x: 0, y: 0, w: 1, h: sourceRatio / r)        // letterbox: full width, shorter
        }
        rect.x = (1 - rect.w) / 2
        rect.y = (1 - rect.h) / 2
        return rect.clamped(in: sourceSize)
    }

    /// This crop reshaped to `aspect` around its own centre, as large as fits inside the frame
    /// without growing past the current area's longer side; `original` and `free` return it as it is
    /// (`original` means the whole frame: `centered(.original, ...)`).
    public func applying(_ aspect: Aspect, in sourceSize: CGSize) -> CropRect {
        switch aspect {
        case .original: return .full
        case .free: return clamped(in: sourceSize)
        default: return Self.centered(aspect, in: sourceSize)
        }
    }

    // MARK: Clamping

    /// Inside the frame, at least `minPixels` wide and tall (when the source size is known; else 1 %
    /// of the frame), moved rather than shrunk when it overhangs an edge.
    public func clamped(in sourceSize: CGSize? = nil) -> CropRect {
        var minW = 0.01, minH = 0.01
        if let s = sourceSize, s.width > 0, s.height > 0 {
            minW = min(1, Self.minPixels / Double(s.width))
            minH = min(1, Self.minPixels / Double(s.height))
        }
        var r = self
        r.w = min(1, max(minW, r.w.isFinite ? r.w : 1))
        r.h = min(1, max(minH, r.h.isFinite ? r.h : 1))
        r.x = min(1 - r.w, max(0, r.x.isFinite ? r.x : 0))
        r.y = min(1 - r.h, max(0, r.y.isFinite ? r.y : 0))
        return r
    }

    // MARK: Pixels

    /// The crop in source pixels, rounded down to even numbers like the server's.
    public func pixelSize(in sourceSize: CGSize) -> CGSize {
        func even(_ v: Double) -> Double { max(2, (v / 2).rounded(.down) * 2) }
        return CGSize(width: even(w * Double(sourceSize.width)), height: even(h * Double(sourceSize.height)))
    }

    /// The preset this crop matches within a pixel or so, for the "crop 1:1" badge; nil when it is
    /// a free shape.
    public func matchedAspect(in sourceSize: CGSize) -> Aspect? {
        if isFull { return .original }
        let px = pixelSize(in: sourceSize)
        guard px.height > 0 else { return nil }
        let ratio = Double(px.width / px.height)
        for a in Aspect.allCases {
            if let r = a.ratio, abs(ratio - r) / r < 0.012 { return a }
        }
        return nil
    }

    // MARK: Wire

    /// The JSON object sent as `crop`, rounded to four decimals.
    var wire: [String: Double] {
        func r4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        return ["x": r4(x), "y": r4(y), "w": r4(w), "h": r4(h)]
    }
}

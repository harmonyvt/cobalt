import CoreGraphics
import Foundation
import ImageIO

// Cropping pictures on the device (APP-API-CONTRACT 44.1, apple/CONTRACT-EDITOR.md 13): the same rules as the server's
// `api/src/image-crop-core.ts`. The box is in fractions of the picture as stored (top-left origin, before any turn), rounded
// outward to whole pixels and clamped to the edge, at least 2 x 2 px; then the quarter turn (clockwise), then the flip. The
// result is a PNG at full resolution, uploaded as is (`content-type: image/png`).

/// A box in fractions of a picture's width and height, from its top-left corner.
public struct ImageCropRect: Sendable, Equatable, Codable {
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

    public static let whole = ImageCropRect(x: 0, y: 0, w: 1, h: 1)

    /// The whole picture (within a millionth).
    public var isWhole: Bool { x <= 1e-6 && y <= 1e-6 && x + w >= 1 - 1e-6 && y + h >= 1 - 1e-6 }

    /// Inside the picture, as the route takes it: `0 ≤ x, y < 1`, `0 < w, h`, `x + w ≤ 1`, `y + h ≤ 1`.
    public var clamped: ImageCropRect {
        func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
        let cx = min(max(0, finite(x, 0)), 1 - 1e-6), cy = min(max(0, finite(y, 0)), 1 - 1e-6)
        let cw = min(max(1e-6, finite(w, 1)), 1 - cx), ch = min(max(1e-6, finite(h, 1)), 1 - cy)
        return ImageCropRect(x: cx, y: cy, w: cw, h: ch)
    }
}

/// A mirror after the turn: `h` left to right, `v` top to bottom.
public enum ImageCropFlip: String, Sendable, Codable, CaseIterable {
    case none, h, v
}

/// What to make of a picture (the route's JSON body, and the query of an upload).
public struct ImageCropSpec: Sendable, Equatable {
    /// Fractions of the picture as stored; nil = the whole picture.
    public var crop: ImageCropRect?
    /// 0, 90, 180 or 270: degrees clockwise, after the crop.
    public var rotate: Int
    /// After the turn.
    public var flip: ImageCropFlip
    /// Take the background out of the cropped picture (`auto`), then trim to the subject.
    public var cutout: Bool
    public var title: String?

    public init(crop: ImageCropRect? = nil, rotate: Int = 0, flip: ImageCropFlip = .none, cutout: Bool = false, title: String? = nil) {
        self.crop = crop.map(\.clamped).flatMap { $0.isWhole ? nil : $0 }
        self.rotate = Self.quarter(rotate)
        self.flip = flip
        self.cutout = cutout
        self.title = title
    }

    /// `degrees` as one of 0, 90, 180, 270 (the nearest quarter turn, any sign).
    public static func quarter(_ degrees: Int) -> Int {
        let q = Int((Double(degrees) / 90).rounded()) * 90
        return ((q % 360) + 360) % 360
    }

    /// The server refuses a body that changes nothing (44.1: at least one of crop, rotate, flip, cutout).
    public var changesSomething: Bool { crop != nil || rotate != 0 || flip != .none || cutout }

    // MARK: wire

    /// The JSON body (sorted keys; defaults left out).
    public func jsonBody() throws -> Data {
        struct Box: Encodable { var x: Double; var y: Double; var w: Double; var h: Double }
        struct Body: Encodable {
            var crop: Box?
            var rotate: Int?
            var flip: String?
            var cutout: Bool?
            var title: String?
        }
        let body = Body(
            crop: crop.map { Box(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }, rotate: rotate == 0 ? nil : rotate,
            flip: flip == .none ? nil : flip.rawValue, cutout: cutout ? true : nil, title: title)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    /// The query of an upload (`?title=&x=&y=&w=&h=&rotate=&flip=&cutout=`): what the device did, recorded by the server.
    public var query: [(String, String)] {
        var out: [(String, String)] = []
        if let title { out.append(("title", title)) }
        if let crop {
            out.append(("x", Self.number(crop.x)))
            out.append(("y", Self.number(crop.y)))
            out.append(("w", Self.number(crop.w)))
            out.append(("h", Self.number(crop.h)))
        }
        if rotate != 0 { out.append(("rotate", String(rotate))) }
        if flip != .none { out.append(("flip", flip.rawValue)) }
        if cutout { out.append(("cutout", "auto")) }
        return out
    }

    /// At most 6 decimals, no trailing zeros.
    static func number(_ v: Double) -> String {
        var text = String(format: "%.6f", v)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: the picture as shown (turned and flipped)

    /// Where point `p` (fractions of the stored picture) is in the picture turned `rotate` clockwise, then flipped.
    public static func displayedPoint(_ p: (x: Double, y: Double), rotate: Int, flip: ImageCropFlip) -> (x: Double, y: Double) {
        var q: (x: Double, y: Double)
        switch quarter(rotate) {
        case 90: q = (1 - p.y, p.x)
        case 180: q = (1 - p.x, 1 - p.y)
        case 270: q = (p.y, 1 - p.x)
        default: q = p
        }
        switch flip {
        case .h: q.x = 1 - q.x
        case .v: q.y = 1 - q.y
        case .none: break
        }
        return q
    }

    /// The inverse: a point of the shown picture in fractions of the stored one.
    public static func storedPoint(_ p: (x: Double, y: Double), rotate: Int, flip: ImageCropFlip) -> (x: Double, y: Double) {
        var q = p
        switch flip {
        case .h: q.x = 1 - q.x
        case .v: q.y = 1 - q.y
        case .none: break
        }
        return displayedPoint(q, rotate: (360 - quarter(rotate)) % 360, flip: .none)
    }

    /// A box of the stored picture as it sits in the shown one.
    public static func displayed(_ r: ImageCropRect, rotate: Int, flip: ImageCropFlip) -> ImageCropRect {
        let a = displayedPoint((x: r.x, y: r.y), rotate: rotate, flip: flip)
        let b = displayedPoint((x: r.x + r.w, y: r.y + r.h), rotate: rotate, flip: flip)
        return ImageCropRect(x: min(a.x, b.x), y: min(a.y, b.y), w: abs(a.x - b.x), h: abs(a.y - b.y))
    }

    /// A box of the shown picture in fractions of the stored one (what `crop` takes).
    public static func stored(_ r: ImageCropRect, rotate: Int, flip: ImageCropFlip) -> ImageCropRect {
        let a = storedPoint((x: r.x, y: r.y), rotate: rotate, flip: flip)
        let b = storedPoint((x: r.x + r.w, y: r.y + r.h), rotate: rotate, flip: flip)
        return ImageCropRect(x: min(a.x, b.x), y: min(a.y, b.y), w: abs(a.x - b.x), h: abs(a.y - b.y))
    }

    /// The turn after the shown picture is turned a quarter left. A mirrored picture turns the other way underneath
    /// (left after a mirror = a mirror after right), so the flip stays and the turn goes clockwise.
    public static func turnedLeft(rotate: Int, flip: ImageCropFlip) -> Int {
        quarter(rotate + (flip == .none ? 270 : 90))
    }
}

/// What can go wrong (the route's codes, 44.1, and the device's own).
public enum ImageCropError: Error, Sendable, Equatable {
    case notFound, notImage, badRequest, tooLarge
    /// The box is under 2 x 2 px.
    case tooSmall
    /// The background removal left nothing.
    case empty
    /// The server cannot make this one (no Cloudflare Images, or no route).
    case off
    case failed, offline, unavailable
    case other(String)

    init(code: String, status: Int) {
        switch code {
        case "error.crop.not_found": self = .notFound
        case "error.crop.not_image": self = .notImage
        case "error.crop.bad_request": self = .badRequest
        case "error.crop.too_large": self = .tooLarge
        case "error.crop.empty": self = .empty
        case "error.crop.off": self = .off
        case "error.crop.failed", "error.crop.storage": self = .failed
        default: self = status == 503 ? .unavailable : (status == 404 ? .notFound : .other(code))
        }
    }
}

public enum ImageCropper {
    /// The smallest crop, in pixels a side (the server's `CROP_MIN_PX`).
    public static let minSide = 2
    /// The largest PNG side the route stores (44.1).
    public static let maxUploadSide = 8_192
    /// The largest PNG the route stores (44.1).
    public static let maxUploadBytes = 20_000_000

    /// A box in whole pixels.
    public struct PixelRect: Sendable, Equatable {
        public var x: Int
        public var y: Int
        public var w: Int
        public var h: Int

        public init(x: Int, y: Int, w: Int, h: Int) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
        }
    }

    /// `crop` of a `width` x `height` picture in whole pixels, as the server reads it: rounded outward, clamped to the picture.
    /// nil when it is under `minSide` a side. A nil crop is the whole picture.
    public static func pixelRect(_ crop: ImageCropRect?, width: Int, height: Int) -> PixelRect? {
        guard width > 0, height > 0 else { return nil }
        guard let c = crop else {
            return width >= minSide && height >= minSide ? PixelRect(x: 0, y: 0, w: width, h: height) : nil
        }
        let W = Double(width), H = Double(height)
        let x0 = max(0, Int((c.x * W + 1e-6).rounded(.down)))
        let y0 = max(0, Int((c.y * H + 1e-6).rounded(.down)))
        let x1 = min(width, Int((min(1, c.x + c.w) * W - 1e-6).rounded(.up)))
        let y1 = min(height, Int((min(1, c.y + c.h) * H - 1e-6).rounded(.up)))
        guard x1 - x0 >= minSide, y1 - y0 >= minSide else { return nil }
        return PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// The size of the result (before any background removal): the pixel box, its sides swapped by a quarter turn. nil when
    /// the box is too small.
    public static func outputSize(_ spec: ImageCropSpec, width: Int, height: Int) -> (width: Int, height: Int)? {
        guard let box = pixelRect(spec.crop, width: width, height: height) else { return nil }
        return spec.rotate % 180 == 0 ? (box.w, box.h) : (box.h, box.w)
    }

    /// The crop, turn and flip of `image` at full resolution (no background removal).
    public static func crop(_ image: CGImage, _ spec: ImageCropSpec) throws -> CGImage {
        guard let rgba = RGBA(image) else { throw ImageCropError.failed }
        guard let box = pixelRect(spec.crop, width: rgba.width, height: rgba.height) else { throw ImageCropError.tooSmall }
        let out = rgba.cropped((x: box.x, y: box.y, w: box.w, h: box.h)).rotated(spec.rotate).flipped(spec.flip)
        guard let made = out.image() else { throw ImageCropError.failed }
        return made
    }

    /// `image` turned and flipped, nothing cut: the crop sheet's picture as shown.
    public static func turned(_ image: CGImage, rotate: Int, flip: ImageCropFlip) -> CGImage? {
        if ImageCropSpec.quarter(rotate) == 0, flip == .none { return image }
        return RGBA(image)?.rotated(rotate).flipped(flip).image()
    }

    /// The whole job on the device: the crop, then (with `spec.cutout`) the background taken out with Vision and trimmed to
    /// the subject (`CutoutMaker`, `auto`). `CutoutError`s pass through: the caller may ask the server instead.
    public static func make(_ image: CGImage, _ spec: ImageCropSpec) throws -> CGImage {
        let cropped = try crop(image, spec)
        guard spec.cutout else { return cropped }
        return try CutoutMaker.make(cropped, CutoutMaker.Options(mode: .auto))
    }

    /// The PNG to upload, or nil when it is over the route's limits (the server should make it instead).
    public static func png(_ image: CGImage) -> Data? {
        guard image.width <= maxUploadSide, image.height <= maxUploadSide, let data = CutoutMaker.png(image),
              data.count <= maxUploadBytes else { return nil }
        return data
    }

    /// The picture in a file at full size (EXIF orientation applied, at most `maxUploadSide` a side; a gif's first frame).
    public static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxUploadSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A decoded picture carried across tasks (a `CGImage` is not `Sendable`; it is never changed once made).
public final class ImageCropPicture: @unchecked Sendable {
    public let image: CGImage
    public init(_ image: CGImage) { self.image = image }
}

extension RGBA {
    /// A quarter turn clockwise (`api/src/image-crop-core.ts` `rotate`): source (x, y) lands at (h-1-y, x) for 90.
    func rotated(_ degrees: Int) -> RGBA {
        let deg = ImageCropSpec.quarter(degrees)
        guard deg != 0 else { return self }
        let w = width, h = height
        let ow = deg == 180 ? w : h, oh = deg == 180 ? h : w
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let nx: Int, ny: Int
                switch deg {
                case 90: nx = h - 1 - y; ny = x
                case 180: nx = w - 1 - x; ny = h - 1 - y
                default: nx = y; ny = w - 1 - x
                }
                let s = (y * w + x) * 4, d = (ny * ow + nx) * 4
                out[d] = pixels[s]; out[d + 1] = pixels[s + 1]; out[d + 2] = pixels[s + 2]; out[d + 3] = pixels[s + 3]
            }
        }
        return RGBA(width: ow, height: oh, pixels: out)
    }

    /// A mirror: `h` left to right, `v` top to bottom.
    func flipped(_ f: ImageCropFlip) -> RGBA {
        guard f != .none else { return self }
        let w = width, h = height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let sx = f == .h ? w - 1 - x : x, sy = f == .v ? h - 1 - y : y
                let s = (sy * w + sx) * 4, d = (y * w + x) * 4
                out[d] = pixels[s]; out[d + 1] = pixels[s + 1]; out[d + 2] = pixels[s + 2]; out[d + 3] = pixels[s + 3]
            }
        }
        return RGBA(width: w, height: h, pixels: out)
    }
}

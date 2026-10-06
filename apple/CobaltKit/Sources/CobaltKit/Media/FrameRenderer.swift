import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The repost tools' renderer (apple/CONTRACT-GALLERY.md 1.22-1.24, wave A7): one photo drawn into a frame on the device,
// with Core Image and ImageIO, no server. A pure function of (source file, spec): the same spec gives the same pixels.
//
//   aspect  `1:1` · `4:5` · `9:16` · `3:4` · `free` (a crop only: the rectangle keeps its own shape)
//   fill    `cut`  the frame is a movable, zoomable rectangle over the photo; what is outside it is cut
//           `blur` the whole photo sits centred on a blurred, darkened copy of itself (the slideshow's own fill)
//   output  JPEG 0.9, sRGB, 1080 px on the short side; never upscaled (a smaller source keeps its size)
//
// Used three ways: `crop` (stored as a made file of the post, `PUT /library/items/<id>/made`), `repost frame` (made on
// demand, to Photos or the share sheet, not stored) and `keep in cobalt` (a repost frame made into a crop).

/// What a frame is made of: its shape, how the photo meets it, and (for a cut) where the rectangle sits. This is also the
/// wire's `made_spec` of a crop: `{"aspect":"9:16","fill":"blur","rect":[x,y,w,h]}` (rect normalised 0-1 of the photo as
/// the owner sees it, after rotation; only for a cut).
public struct FrameSpec: Sendable, Equatable, Codable {
    public enum Aspect: String, Sendable, Codable, CaseIterable, Equatable {
        case square = "1:1", portrait = "4:5", story = "9:16", classic = "3:4", free

        /// "1:1", "4:5", "9:16", "3:4", "free".
        public var label: String { rawValue }

        /// Width over height; nil for `free`.
        public var ratio: Double? {
            switch self {
            case .square: return 1
            case .portrait: return 4.0 / 5.0
            case .story: return 9.0 / 16.0
            case .classic: return 3.0 / 4.0
            case .free: return nil
            }
        }

        /// The shapes a repost frame offers (a crop offers all five).
        public static let repost: [Aspect] = [.story, .square, .portrait]
    }

    public enum Fill: String, Sendable, Codable, Equatable { case cut, blur }

    public var aspect: Aspect
    public var fill: Fill
    /// Normalised 0-1 of the photo. Only a cut has one: `nil` is the largest centred rectangle of the shape (the whole
    /// photo for `free`).
    public var rect: CGRect?

    public init(aspect: Aspect, fill: Fill = .blur, rect: CGRect? = nil) {
        self.aspect = aspect
        self.fill = fill
        self.rect = rect
    }

    /// `free` has nothing to put bars around: it is always a cut.
    public var effectiveFill: Fill { aspect == .free ? .cut : fill }

    /// The crop's tab: `crop 9:16`; a free crop is just `crop`.
    public var tabName: String { aspect == .free ? "crop" : "crop \(aspect.label)" }

    // MARK: Wire

    private enum CodingKeys: String, CodingKey { case aspect, fill, rect }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.aspect = (try? c.decode(Aspect.self, forKey: .aspect)) ?? .free
        self.fill = (try? c.decode(Fill.self, forKey: .fill)) ?? .cut
        if let r = try? c.decode([Double].self, forKey: .rect), r.count == 4 {
            self.rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        } else {
            self.rect = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(aspect, forKey: .aspect)
        try c.encode(fill, forKey: .fill)
        if effectiveFill == .cut, let rect {
            func r4(_ v: CGFloat) -> Double { (Double(v) * 10_000).rounded() / 10_000 }
            try c.encode([r4(rect.minX), r4(rect.minY), r4(rect.width), r4(rect.height)], forKey: .rect)
        }
    }

    /// The JSON the server stores as `made_spec` (well under its 512 byte limit).
    public var wireData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    /// From a crop's `made_spec`; nil when it is not a JSON object with an `aspect` this build knows.
    public init?(wire data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = object["aspect"] as? String, Aspect(rawValue: raw) != nil,
              let spec = try? JSONDecoder().decode(FrameSpec.self, from: data)
        else { return nil }
        self = spec
    }
}

extension MadeSpec {
    /// A crop's frame (`aspect`, `fill`, `rect`), read back from what the server stored.
    public var frame: FrameSpec? { FrameSpec(wire: data) }
}

public enum FrameRenderer {
    public enum Failure: Error, Equatable { case unreadable, failed }

    /// The short side of an output, in pixels.
    public static let shortSide = 1080
    /// JPEG quality of an output.
    public static let quality = 0.9
    /// The largest side a source is decoded at (a bigger one is scaled down once, before anything else).
    static let decodeCap = 8192

    // MARK: - The plan (pure)

    /// Where the pixels come from and go: the source region a cut keeps, or where the whole photo sits on the blur.
    public struct Plan: Sendable, Equatable {
        /// The picture to make, in pixels.
        public var output: CGSize
        /// The part of the source that is drawn (a cut's rectangle; the whole source for a blur), pixels, top-left origin.
        public var region: CGRect
        /// A blur: where the photo sits in the output (centred, top-left origin). `nil` for a cut.
        public var photo: CGRect?
        /// A blur: the Gaussian radius of the background, scaled to the output (24 at 1080 px).
        public var blurRadius: CGFloat
    }

    /// The largest rectangle of `aspect` inside `rect` (pixels), centred in it; `free` keeps `rect`.
    static func fitted(_ rect: CGRect, aspect: FrameSpec.Aspect) -> CGRect {
        guard let ratio = aspect.ratio, rect.width > 0, rect.height > 0 else { return rect }
        var w = rect.width, h = rect.height
        if w / h > CGFloat(ratio) { w = h * CGFloat(ratio) } else { h = w / CGFloat(ratio) }
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// The pixels a cut keeps: the rectangle (normalised of the source) reshaped to the aspect, else the largest centred
    /// one, whole pixels, inside the source.
    public static func cutRegion(source: CGSize, spec: FrameSpec) -> CGRect {
        let full = CGRect(origin: .zero, size: source)
        var r = full
        if let n = spec.rect, n.width > 0, n.height > 0, n.width.isFinite, n.height.isFinite {
            r = CGRect(x: n.minX * source.width, y: n.minY * source.height, width: n.width * source.width, height: n.height * source.height)
                .intersection(full)
            if r.isNull || r.width < 1 || r.height < 1 { r = full }
        }
        r = fitted(r, aspect: spec.aspect)
        let x = max(0, r.minX.rounded(.down)), y = max(0, r.minY.rounded(.down))
        let w = min(source.width - x, max(1, r.width.rounded())), h = min(source.height - y, max(1, r.height.rounded()))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// An output of `ratio` (width over height) whose short side is `side`.
    private static func size(side: CGFloat, ratio: Double) -> CGSize {
        let r = CGFloat(ratio)
        return r < 1 ? CGSize(width: side.rounded(), height: (side / r).rounded()) : CGSize(width: (side * r).rounded(), height: side.rounded())
    }

    /// What a render of `source` (pixels, as the owner sees it) with `spec` does. `shortSide` is the output's short side
    /// (1080; a smaller one makes a quick preview). Never upscales: a source smaller than the short side keeps its size.
    public static func plan(source: CGSize, spec: FrameSpec, shortSide: Int = FrameRenderer.shortSide) -> Plan {
        let cap = CGFloat(max(2, shortSide))
        switch spec.effectiveFill {
        case .cut:
            let region = cutRegion(source: source, spec: spec)
            let side = min(cap, min(region.width, region.height))
            let output: CGSize
            if let ratio = spec.aspect.ratio {
                output = size(side: side, ratio: ratio)
            } else {
                let k = min(1, cap / max(1, min(region.width, region.height)))
                output = CGSize(width: max(1, (region.width * k).rounded()), height: max(1, (region.height * k).rounded()))
            }
            return Plan(output: output, region: region, photo: nil, blurRadius: 0)
        case .blur:
            // the smallest frame of the shape that holds the whole photo at its own size, then scaled down to the short side
            let ratio = spec.aspect.ratio ?? Double(source.width / max(1, source.height))
            let photoRatio = Double(source.width / max(1, source.height))
            let frame = photoRatio > ratio
                ? CGSize(width: source.width, height: source.width / CGFloat(ratio))
                : CGSize(width: source.height * CGFloat(ratio), height: source.height)
            let output = size(side: min(cap, min(frame.width, frame.height)), ratio: ratio)
            let scale = output.width / max(1, frame.width)
            let w = (source.width * scale).rounded(), h = (source.height * scale).rounded()
            let photo = CGRect(x: ((output.width - w) / 2).rounded(), y: ((output.height - h) / 2).rounded(), width: w, height: h)
            return Plan(
                output: output, region: CGRect(origin: .zero, size: source), photo: photo,
                blurRadius: 24 * min(output.width, output.height) / CGFloat(FrameRenderer.shortSide))
        }
    }

    /// The size of the picture a render would make (the readout under the frame).
    public static func outputSize(source: CGSize, spec: FrameSpec) -> CGSize {
        plan(source: source, spec: spec).output
    }

    // MARK: - Reading a source

    /// The photo's size as the owner sees it (after the file's rotation).
    public static func sourceSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// The photo, rotated upright, at its own size (at most `decodeCap` on the long side).
    private static func decode(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let size = sourceSize(of: url) else { throw Failure.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(decodeCap, Int(max(size.width, size.height).rounded(.up))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { throw Failure.unreadable }
        return image
    }

    // MARK: - Rendering

    /// Makes the frame and writes it as a JPEG to `destination` (its folder is made). Off the caller's thread. Throws
    /// `Failure.unreadable` for a file that is not a picture. Returns the picture's size and the file's size.
    @discardableResult
    public static func render(
        _ source: URL, spec: FrameSpec, shortSide: Int = FrameRenderer.shortSide, to destination: URL
    ) async throws -> (width: Int, height: Int, bytes: Int64) {
        try await Task.detached(priority: .userInitiated) {
            try renderNow(source, spec: spec, shortSide: shortSide, to: destination)
        }.value
    }

    private static func renderNow(_ source: URL, spec: FrameSpec, shortSide: Int, to destination: URL) throws -> (width: Int, height: Int, bytes: Int64) {
        let image = try decode(source)
        let pixels = CGSize(width: image.width, height: image.height)
        let plan = plan(source: pixels, spec: spec, shortSide: shortSide)
        let out = plan.output
        guard out.width >= 1, out.height >= 1 else { throw Failure.failed }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
        let frame = CGRect(origin: .zero, size: out)
        let upright = CIImage(cgImage: image)

        /// Scales `picture` (origin at 0,0) by `sx`, `sy` with Lanczos when it shrinks.
        func scaled(_ picture: CIImage, sx: CGFloat, sy: CGFloat) -> CIImage {
            guard abs(sx - 1) > 0.0005 || abs(sy - 1) > 0.0005 else { return picture }
            if sx < 1, sy < 1 {
                let f = CIFilter.lanczosScaleTransform()
                f.inputImage = picture
                f.scale = Float(sy)
                f.aspectRatio = Float(sx / sy)
                if let result = f.outputImage { return result }
            }
            return picture.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        var result: CIImage
        switch spec.effectiveFill {
        case .cut:
            let r = plan.region
            // Core Image's origin is bottom-left
            let ciRect = CGRect(x: r.minX, y: pixels.height - r.maxY, width: r.width, height: r.height)
            let part = upright.cropped(to: ciRect).transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
            result = scaled(part, sx: out.width / r.width, sy: out.height / r.height)
        case .blur:
            guard let place = plan.photo else { throw Failure.failed }
            let fit = scaled(upright, sx: place.width / pixels.width, sy: place.height / pixels.height)
            let placed = fit.transformed(by: CGAffineTransform(translationX: place.minX, y: out.height - place.maxY))
            if place.width >= out.width - 1, place.height >= out.height - 1 {
                result = placed                                          // the photo is the frame's own shape: no bars
            } else {
                // the photo covers the frame (more than it), blurred and darkened
                let cover = max(out.width / pixels.width, out.height / pixels.height)
                let big = upright.transformed(by: CGAffineTransform(scaleX: cover, y: cover))
                let centred = big.transformed(by: CGAffineTransform(
                    translationX: (out.width - big.extent.width) / 2, y: (out.height - big.extent.height) / 2))
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = centred.clampedToExtent()
                blur.radius = Float(plan.blurRadius)
                let dim = CIFilter.colorControls()
                dim.inputImage = blur.outputImage
                dim.brightness = -0.08
                let background = (dim.outputImage ?? centred).cropped(to: frame)
                result = placed.composited(over: background)
            }
        }
        guard let cg = context.createCGImage(result.cropped(to: frame), from: frame, format: .RGBA8, colorSpace: srgb) else { throw Failure.failed }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        guard let sink = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.failed }
        CGImageDestinationAddImage(sink, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(sink) else { throw Failure.failed }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return (cg.width, cg.height, bytes)
    }
}

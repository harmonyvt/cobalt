import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// Cutouts made on the device (APP-API-CONTRACT 39.3, apple/CONTRACT-EDITOR.md 12): `auto` with Vision's foreground mask, `white`
// and `color` with the same flood fill the server runs (`api/src/cutout-core.ts`): colour distance as a percent of black-to-white,
// from the picture's edge (or everywhere), a softened edge, then cropped to what is left. The PNG goes to the server as is.

public enum CutoutMaker {
    /// A pixel this transparent already counts as background.
    static let clearAlpha: UInt8 = 16
    /// A pixel at least this opaque counts as subject when trimming.
    static let subjectAlpha: UInt8 = 8
    /// The longest side a cutout keeps (the server's limit for the ones it makes).
    public static let maxSide = 2_048

    public struct Options: Sendable, Equatable {
        public var mode: CutoutMode
        /// RGB 0...255 of the colour to take out (`.color`); white for `.white`.
        public var key: (r: UInt8, g: UInt8, b: UInt8)
        public var tolerance: Double
        public var edgesOnly: Bool
        public var soften: Int
        public var trim: Bool

        public init(mode: CutoutMode, key: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255), tolerance: Double = 20,
                    edgesOnly: Bool = true, soften: Int = 1, trim: Bool = true) {
            self.mode = mode
            self.key = mode == .white ? (255, 255, 255) : key
            self.tolerance = tolerance
            self.edgesOnly = edgesOnly
            self.soften = soften
            self.trim = trim
        }

        public static func == (a: Options, b: Options) -> Bool {
            a.mode == b.mode && a.key == b.key && a.tolerance == b.tolerance && a.edgesOnly == b.edgesOnly
                && a.soften == b.soften && a.trim == b.trim
        }
    }

    /// The cutout of `image`; `CutoutError.empty` when nothing is left, `.failed` when Vision cannot find a subject.
    public static func make(_ image: CGImage, _ options: Options) throws -> CGImage {
        let small = scaledDown(image, maxSide: maxSide) ?? image
        switch options.mode {
        case .auto:
            let lifted = try foreground(small)
            guard var rgba = RGBA(lifted) else { throw CutoutError.failed }
            if options.trim {
                guard let box = rgba.subjectBox() else { throw CutoutError.empty }
                rgba = rgba.cropped(box)
            }
            guard let out = rgba.image() else { throw CutoutError.failed }
            return out
        case .white, .color:
            guard var rgba = RGBA(small) else { throw CutoutError.failed }
            rgba.removeBackground(options)
            if options.trim {
                guard let box = rgba.subjectBox() else { throw CutoutError.empty }
                rgba = rgba.cropped(box)
            } else if rgba.subjectBox() == nil {
                throw CutoutError.empty
            }
            guard let out = rgba.image() else { throw CutoutError.failed }
            return out
        }
    }

    /// Vision's foreground: the picture with everything that is not a subject made transparent, full size.
    static func foreground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { throw CutoutError.failed }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw CutoutError.empty }
        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        } catch {
            throw CutoutError.failed
        }
        let ci = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let out = context.createCGImage(ci, from: ci.extent) else { throw CutoutError.failed }
        return out
    }

    /// PNG bytes (with alpha).
    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// `#rgb` / `#rrggbb` (with or without `#`) as RGB; nil when it is not one.
    public static func parseHex(_ text: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let v = UInt32(hex, radix: 16) else { return nil }
        return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    public static func hex(_ c: (r: UInt8, g: UInt8, b: UInt8)) -> String {
        String(format: "#%02x%02x%02x", c.r, c.g, c.b)
    }

    /// The most common colour along the picture's edge: the background a `.color` cutout most likely wants out.
    public static func edgeColour(_ image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let rgba = RGBA(scaledDown(image, maxSide: 256) ?? image) else { return nil }
        var counts: [UInt32: Int] = [:]
        func note(_ x: Int, _ y: Int) {
            let i = (y * rgba.width + x) * 4
            guard rgba.pixels[i + 3] > 200 else { return }
            // bucket to 5 bits a channel so near colours count together
            let key = UInt32(rgba.pixels[i] >> 3) << 10 | UInt32(rgba.pixels[i + 1] >> 3) << 5 | UInt32(rgba.pixels[i + 2] >> 3)
            counts[key, default: 0] += 1
        }
        for x in 0..<rgba.width { note(x, 0); note(x, rgba.height - 1) }
        for y in 0..<rgba.height { note(0, y); note(rgba.width - 1, y) }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        func channel(_ shift: UInt32) -> UInt8 { UInt8(min(255, ((best >> shift) & 0x1F) << 3 | 4)) }
        return (channel(10), channel(5), channel(0))
    }

    /// The colour at `point` (fractions of the width and height, from the top-left), un-premultiplied; nil outside or on a
    /// clear pixel. The colour picker of the cutout sheet.
    public static func colour(at point: CGPoint, in image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        let x = min(image.width - 1, Int(point.x * CGFloat(image.width)))
        let y = min(image.height - 1, Int(point.y * CGFloat(image.height)))
        guard let px = RGBA(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) ?? image) else { return nil }
        let a = Double(px.pixels[3])
        guard a >= Double(clearAlpha) else { return nil }
        func un(_ v: UInt8) -> UInt8 { UInt8(min(255, (Double(v) * 255 / a).rounded())) }
        return (un(px.pixels[0]), un(px.pixels[1]), un(px.pixels[2]))
    }

    /// A smaller copy for the sheet's live preview (nil when it is small already).
    public static func previewSized(_ image: CGImage, maxSide: Int = 640) -> CGImage? { scaledDown(image, maxSide: maxSide) }

    /// `image` with its longest side at most `maxSide` (nil when it already fits or cannot be drawn).
    static func scaledDown(_ image: CGImage, maxSide: Int) -> CGImage? {
        let side = max(image.width, image.height)
        guard side > maxSide else { return nil }
        let scale = Double(maxSide) / Double(side)
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = RGBA.context(width: w, height: h, data: nil) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// Premultiplied RGBA8 pixels in sRGB, top row first.
struct RGBA {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    static func context(width: Int, height: Int, data: UnsafeMutableRawPointer?) -> CGContext? {
        CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = Self.context(width: w, height: h, data: raw.baseAddress) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, pixels: buffer)
    }

    func image() -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { raw in
            Self.context(width: width, height: height, data: raw.baseAddress)?.makeImage()
        }
    }

    /// Clears the background as `cutout-core.ts` does: a pixel is background when it is already nearly clear or its colour is
    /// within `tolerance` percent of the key (Euclidean RGB over black-to-white); with `edgesOnly` only background connected
    /// (4 ways) to the edge goes. Then the edge is softened over `soften` px.
    mutating func removeBackground(_ o: CutoutMaker.Options) {
        let n = width * height
        let limit = o.tolerance / 100 * (3.0 * 255 * 255).squareRoot()
        let limit2 = limit * limit
        let kr = Double(o.key.r), kg = Double(o.key.g), kb = Double(o.key.b)
        var background = [Bool](repeating: false, count: n)
        for p in 0..<n {
            let i = p * 4
            let a = pixels[i + 3]
            if a < CutoutMaker.clearAlpha { background[p] = true; continue }
            // un-premultiply for the distance
            let s = 255.0 / Double(a)
            let dr = Double(pixels[i]) * s - kr, dg = Double(pixels[i + 1]) * s - kg, db = Double(pixels[i + 2]) * s - kb
            background[p] = dr * dr + dg * dg + db * db <= limit2 + 1e-9
        }
        var remove = [Bool](repeating: false, count: n)
        if o.edgesOnly {
            var stack: [Int] = []
            func seed(_ p: Int) { if background[p], !remove[p] { remove[p] = true; stack.append(p) } }
            for x in 0..<width { seed(x); seed((height - 1) * width + x) }
            for y in 0..<height { seed(y * width); seed(y * width + width - 1) }
            while let p = stack.popLast() {
                let x = p % width, y = p / width
                if x > 0 { seed(p - 1) }
                if x + 1 < width { seed(p + 1) }
                if y > 0 { seed(p - width) }
                if y + 1 < height { seed(p + width) }
            }
        } else {
            remove = background
        }
        for p in 0..<n where remove[p] {
            let i = p * 4
            pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
        }
        let r = max(0, min(3, o.soften))
        guard r > 0 else { return }
        // integral image of removed pixels
        let iw = width + 1
        var sum = [Int32](repeating: 0, count: iw * (height + 1))
        for y in 0..<height {
            var row: Int32 = 0
            for x in 0..<width {
                row += remove[y * width + x] ? 1 : 0
                sum[(y + 1) * iw + x + 1] = sum[y * iw + x + 1] + row
            }
        }
        for y in 0..<height {
            for x in 0..<width where !remove[y * width + x] {
                let x0 = max(0, x - r), y0 = max(0, y - r), x1 = min(width - 1, x + r), y1 = min(height - 1, y + r)
                let count = sum[(y1 + 1) * iw + x1 + 1] - sum[y0 * iw + x1 + 1] - sum[(y1 + 1) * iw + x0] + sum[y0 * iw + x0]
                guard count > 0 else { continue }
                let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
                let keep = 1 - 0.9 * Double(count) / area
                let i = (y * width + x) * 4
                for c in 0..<4 { pixels[i + c] = UInt8((Double(pixels[i + c]) * keep).rounded()) }
            }
        }
    }

    /// The smallest box holding every pixel at least `subjectAlpha` opaque; nil when there is none.
    func subjectBox() -> (x: Int, y: Int, w: Int, h: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= CutoutMaker.subjectAlpha {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    func cropped(_ box: (x: Int, y: Int, w: Int, h: Int)) -> RGBA {
        var out = [UInt8](repeating: 0, count: box.w * box.h * 4)
        for row in 0..<box.h {
            let from = ((box.y + row) * width + box.x) * 4
            out.replaceSubrange(row * box.w * 4..<(row + 1) * box.w * 4, with: pixels[from..<from + box.w * 4])
        }
        return RGBA(width: box.w, height: box.h, pixels: out)
    }
}

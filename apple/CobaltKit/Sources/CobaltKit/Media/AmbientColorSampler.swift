import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

// MARK: - Ambient Cinema Color Palette

/// A single sRGB color point in `[0, 1]` used by the Ambient Cinema backdrop.
public struct AmbientRGB: Equatable, Hashable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    /// Deep dark neutral stage fallback (`#0b0b0e`) used before media loads or for pure-black frames.
    public static let darkStage = AmbientRGB(r: 0.043, g: 0.043, b: 0.055)

    /// Peak-to-trough channel spread (`0` for pure greyscale).
    public var chroma: Double {
        max(r, max(g, b)) - min(r, min(g, b))
    }

    /// Rec. 709 relative luminance.
    public var luminance: Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Linearly blends this color toward `other` by `factor` in `[0, 1]`.
    public func blended(with other: AmbientRGB, factor: Double) -> AmbientRGB {
        let t = min(max(factor, 0), 1)
        let inv = 1 - t
        return AmbientRGB(
            r: r * inv + other.r * t,
            g: g * inv + other.g * t,
            b: b * inv + other.b * t
        )
    }
}

/// Quarter-turn display orientation of a decoded video frame, derived from `AVAssetTrack.preferredTransform`.
///
/// `AVPlayerItemVideoOutput` delivers pixel buffers in raw sensor orientation (for example, portrait phone
/// recordings encoded landscape with a 90° clockwise `preferredTransform`). Rotating the 3×3 spatial field
/// keeps sky/top and ground/bottom glow aligned with what the user sees on screen.
public enum AmbientOrientation: Equatable, Hashable, Sendable {
    /// No rotation (0°).
    case up
    /// Rotated 90° clockwise to display upright (`a = 0, b = 1, c = -1, d = 0`).
    case right
    /// Rotated 180° (`a = -1, b = 0, c = 0, d = -1`).
    case down
    /// Rotated 270° clockwise / 90° counter-clockwise (`a = 0, b = -1, c = 1, d = 0`).
    case left

    /// Maps an `AVAssetTrack.preferredTransform` into the nearest quarter-turn orientation.
    public init(preferredTransform t: CGAffineTransform) {
        let angle = atan2(t.b, t.a)
        let quarterTurns = Int((angle / (.pi / 2)).rounded())
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: self = .right
        case 2: self = .down
        case 3: self = .left
        default: self = .up
        }
    }
}

/// Spatial 3×3 color field extracted directly from the active photo or playing video frame.
///
/// Row-major order (9 points):
/// `0: top-leading, 1: top-center, 2: top-trailing,`
/// `3: mid-leading, 4: center,     5: mid-trailing,`
/// `6: bot-leading, 7: bot-center, 8: bot-trailing`
public struct AmbientPalette: Equatable, Hashable, Sendable {
    public static let gridDimension = 3
    public static let pointCount = gridDimension * gridDimension

    public let points: [AmbientRGB]

    public init(points: [AmbientRGB]) {
        if points.count == Self.pointCount {
            self.points = points
        } else if let first = points.first {
            self.points = (0..<Self.pointCount).map { i in
                i < points.count ? points[i] : first
            }
        } else {
            self.points = Array(repeating: .darkStage, count: Self.pointCount)
        }
    }

    /// Neutral dark cinema backdrop with zero color cast.
    public static let darkNeutral = AmbientPalette(points: Array(repeating: .darkStage, count: pointCount))

    public static func uniform(_ color: AmbientRGB) -> AmbientPalette {
        AmbientPalette(points: Array(repeating: color, count: pointCount))
    }

    public var averageLuminance: Double {
        points.reduce(0) { $0 + $1.luminance } / Double(Self.pointCount)
    }

    public var maxChroma: Double {
        points.map(\.chroma).max() ?? 0
    }

    /// True when every zone in the palette is essentially greyscale / monochrome.
    public var isAchromatic: Bool {
        maxChroma < 0.03
    }

    /// Rotates the 3×3 grid from raw buffer orientation into display orientation.
    public func rotated(by orientation: AmbientOrientation) -> AmbientPalette {
        guard orientation != .up else { return self }
        let n = Self.gridDimension
        var out: [AmbientRGB] = []
        out.reserveCapacity(Self.pointCount)
        for dy in 0..<n {
            for dx in 0..<n {
                let (rx, ry): (Int, Int)
                switch orientation {
                case .up:
                    (rx, ry) = (dx, dy)
                case .right:
                    (rx, ry) = (dy, (n - 1) - dx)
                case .down:
                    (rx, ry) = ((n - 1) - dx, (n - 1) - dy)
                case .left:
                    (rx, ry) = ((n - 1) - dy, dx)
                }
                out.append(points[ry * n + rx])
            }
        }
        return AmbientPalette(points: out)
    }

    /// Exponentially smooths between palettes so live video frames glide without strobing.
    public func blended(with other: AmbientPalette, factor: Double) -> AmbientPalette {
        AmbientPalette(points: zip(points, other.points).map { $0.blended(with: $1, factor: factor) })
    }
}

// MARK: - Pixel-Accurate Off-Main-Thread Sampler

/// Extracts authentic spatial ambient lighting palettes from `CGImage`, `CVPixelBuffer`, or raw RGBA bytes.
///
/// Designed to run strictly off the main thread:
/// - Images are downscaled into a 12×12 sRGB bitmap and grouped into a 3×3 spatial field.
/// - 32-bit BGRA `CVPixelBuffer` video frames are stride-sampled directly without allocating a `CIContext`.
/// - Achromatic / greyscale scenes stay strictly neutral silver-charcoal (never inventing warm/orange hues).
public enum AmbientColorSampler {
    private static let sampleGridSize = 12
    private static let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    nonisolated private static let fallbackCIContext = CIContext(options: [.workingColorSpace: srgbSpace])

    /// Samples a `CGImage` into a 3×3 spatial `AmbientPalette`.
    nonisolated public static func sample(cgImage: CGImage) -> AmbientPalette {
        let dim = sampleGridSize
        let bytesPerRow = dim * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * dim)

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: dim,
                      height: dim,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: srgbSpace,
                      bitmapInfo: bitmapInfo
                  )
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dim, height: dim))
            return true
        }
        guard drawn else { return .darkNeutral }
        return sample(rgbaBytes: rgba, width: dim, height: dim, bytesPerRow: bytesPerRow)
    }

    /// Samples a live `CVPixelBuffer` video frame into a 3×3 spatial `AmbientPalette`, applying `orientation`
    /// so portrait videos encoded in landscape match their on-screen display orientation.
    nonisolated public static func sample(
        pixelBuffer: CVPixelBuffer,
        orientation: AmbientOrientation = .up
    ) -> AmbientPalette {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let raw: AmbientPalette
        if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32RGBA {
            raw = sampleInterleavedPixelBuffer(pixelBuffer, isBGRA: format == kCVPixelFormatType_32BGRA)
        } else {
            // Fallback for planar YUV formats if requested without BGRA pixel attributes.
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let extent = ciImage.extent
            guard extent.width > 0, extent.height > 0 else { return .darkNeutral }
            let dim = CGFloat(sampleGridSize)
            let scaled = ciImage.transformed(by: CGAffineTransform(
                scaleX: dim / extent.width,
                y: dim / extent.height
            ))
            guard let cg = fallbackCIContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: dim, height: dim)) else {
                return .darkNeutral
            }
            raw = sample(cgImage: cg)
        }
        return raw.rotated(by: orientation)
    }

    /// Pure pixel-buffer sampler taking premultiplied or opaque 8-bit RGBA bytes (`R, G, B, A`).
    nonisolated public static func sample(
        rgbaBytes: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int? = nil
    ) -> AmbientPalette {
        let stride = bytesPerRow ?? (width * 4)
        return rgbaBytes.withUnsafeBufferPointer { buffer in
            sample(rgbaBytes: buffer, width: width, height: height, bytesPerRow: stride)
        }
    }

    nonisolated public static func sample(
        rgbaBytes: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> AmbientPalette {
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              rgbaBytes.count >= (height - 1) * bytesPerRow + width * 4
        else {
            return .darkNeutral
        }

        let grid = AmbientPalette.gridDimension
        var rawZones: [AmbientRGB] = []
        rawZones.reserveCapacity(AmbientPalette.pointCount)
        var totalWeight = 0.0

        for gy in 0..<grid {
            let y0 = (gy * height) / grid
            let y1 = max(y0 + 1, ((gy + 1) * height) / grid)
            for gx in 0..<grid {
                let x0 = (gx * width) / grid
                let x1 = max(x0 + 1, ((gx + 1) * width) / grid)

                var sumR = 0.0
                var sumG = 0.0
                var sumB = 0.0
                var weightSum = 0.0

                for y in y0..<min(y1, height) {
                    let rowBase = y * bytesPerRow
                    for x in x0..<min(x1, width) {
                        let offset = rowBase + x * 4
                        let aByte = rgbaBytes[offset + 3]
                        guard aByte > 0 else { continue }

                        let alpha = Double(aByte) / 255.0
                        // Un-premultiply if alpha < 1 so translucent PNG/WebP edges stay color-accurate.
                        let invScale = aByte == 255 ? (1.0 / 255.0) : (1.0 / (255.0 * alpha))
                        let r = min(Double(rgbaBytes[offset]) * invScale, 1.0)
                        let g = min(Double(rgbaBytes[offset + 1]) * invScale, 1.0)
                        let b = min(Double(rgbaBytes[offset + 2]) * invScale, 1.0)

                        sumR += r * alpha
                        sumG += g * alpha
                        sumB += b * alpha
                        weightSum += alpha
                    }
                }

                totalWeight += weightSum
                if weightSum > 0.0001 {
                    rawZones.append(AmbientRGB(
                        r: sumR / weightSum,
                        g: sumG / weightSum,
                        b: sumB / weightSum
                    ))
                } else {
                    rawZones.append(.darkStage)
                }
            }
        }

        guard totalWeight > 0.0001 else { return .darkNeutral }

        // Compute overall mean for gentle spatial cohesion so the 3×3 mesh glides smoothly without harsh blocks.
        let meanR = rawZones.reduce(0.0) { $0 + $1.r } / Double(rawZones.count)
        let meanG = rawZones.reduce(0.0) { $0 + $1.g } / Double(rawZones.count)
        let meanB = rawZones.reduce(0.0) { $0 + $1.b } / Double(rawZones.count)
        let mean = AmbientRGB(r: meanR, g: meanG, b: meanB)

        let mapped = rawZones.map { zone -> AmbientRGB in
            let cohesive = zone.blended(with: mean, factor: 0.22)
            return toneMap(cohesive)
        }

        return AmbientPalette(points: mapped)
    }

    // MARK: - Internals

    nonisolated private static func sampleInterleavedPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        isBGRA: Bool
    ) -> AmbientPalette {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return .darkNeutral
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            return .darkNeutral
        }

        let dim = sampleGridSize
        var rgba = [UInt8](repeating: 255, count: dim * dim * 4)
        let src = baseAddress.assumingMemoryBound(to: UInt8.self)

        for sy in 0..<dim {
            let y = min(height - 1, ((sy * 2 + 1) * height) / (dim * 2))
            let srcRow = y * bytesPerRow
            let dstRow = sy * dim * 4
            for sx in 0..<dim {
                let x = min(width - 1, ((sx * 2 + 1) * width) / (dim * 2))
                let s = srcRow + x * 4
                let d = dstRow + sx * 4
                if isBGRA {
                    rgba[d] = src[s + 2]
                    rgba[d + 1] = src[s + 1]
                    rgba[d + 2] = src[s]
                    rgba[d + 3] = src[s + 3]
                } else {
                    rgba[d] = src[s]
                    rgba[d + 1] = src[s + 1]
                    rgba[d + 2] = src[s + 2]
                    rgba[d + 3] = src[s + 3]
                }
            }
        }

        return sample(rgbaBytes: rgba, width: dim, height: dim, bytesPerRow: dim * 4)
    }

    /// Maps a sampled sRGB zone to an atmospheric cinema glow color:
    /// - Strictly preserves greyscale neutrality on low-chroma / monochrome scenes (zero false hue shift).
    /// - Keeps deep dark frames genuinely dark theatrical rather than muddy grey/brown.
    /// - Lifts chromatic scenes gently so vivid blues, purples, greens, and ambers shine without washing out glass HUD pills.
    nonisolated private static func toneMap(_ rgb: AmbientRGB) -> AmbientRGB {
        let luma = rgb.luminance
        let chroma = rgb.chroma

        // Near-black frames stay deep theatrical dark.
        if luma < 0.02 && chroma < 0.025 {
            return .darkStage
        }

        // Strict achromatic preservation: B&W portraits / greyscale stills stay neutral charcoal-silver.
        let achromaticThreshold = 0.035
        if chroma < achromaticThreshold {
            let mappedLuma = 0.045 + 0.23 * pow(luma, 0.90)
            return AmbientRGB(r: mappedLuma, g: mappedLuma, b: mappedLuma)
        }

        // Smooth saturation boost only once clearly chromatic, so near-grey hues never jump or tint.
        let chromaRamp = smoothstep(edge0: achromaticThreshold, edge1: 0.14, x: chroma)
        let satFactor = 1.0 + 0.30 * chromaRamp

        var r = luma + (rgb.r - luma) * satFactor
        var g = luma + (rgb.g - luma) * satFactor
        var b = luma + (rgb.b - luma) * satFactor
        r = min(max(r, 0), 1)
        g = min(max(g, 0), 1)
        b = min(max(b, 0), 1)

        // Theatrical brightness shaping: keep bright frames rich and dark-mode friendly behind Clear Liquid Glass.
        let currentLuma = max(0.001, 0.2126 * r + 0.7152 * g + 0.0722 * b)
        let targetLuma = 0.055 + 0.42 * pow(luma, 0.85)
        let gain = min(targetLuma / currentLuma, 1.35)

        r *= gain
        g *= gain
        b *= gain

        // Soft ceiling compression that preserves exact hue ratio if a single channel is very bright.
        let peak = max(r, max(g, b))
        let maxChannel = 0.74
        if peak > maxChannel {
            let compress = maxChannel / peak
            r *= compress
            g *= compress
            b *= compress
        }

        return AmbientRGB(r: r, g: g, b: b)
    }

    nonisolated private static func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

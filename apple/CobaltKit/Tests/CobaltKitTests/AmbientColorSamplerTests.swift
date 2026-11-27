import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import CobaltKit

@Suite struct AmbientColorSamplerTests {
    /// Helper to build a solid-color or procedural RGBA buffer.
    private func makeRGBA(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r
                bytes[i + 1] = g
                bytes[i + 2] = b
                bytes[i + 3] = a
            }
        }
        return bytes
    }

    /// Helper to build a `CGImage` from premultiplied RGBA bytes.
    private func makeCGImage(rgba: [UInt8], width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }

    /// Helper to build a 32BGRA `CVPixelBuffer` with a procedural `(x, y) -> (R, G, B, A)` generator.
    private func makeBGRAPixelBuffer(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let offset = x * 4
                row[offset] = b
                row[offset + 1] = g
                row[offset + 2] = r
                row[offset + 3] = a
            }
        }
        return buffer
    }

    @Test func greyscalePortraitStaysStrictlyNeutralWithoutOrangeCast() {
        // Simulates a monochrome portrait (bright top backdrop, medium-grey mid, dark jacket bottom).
        let rgba = makeRGBA(width: 24, height: 24) { _, y in
            let v: UInt8 = y < 8 ? 175 : (y < 16 ? 120 : 40)
            return (v, v, v, 255)
        }
        let image = makeCGImage(rgba: rgba, width: 24, height: 24)
        let palette = AmbientColorSampler.sample(cgImage: image)

        #expect(palette.points.count == 9)
        #expect(palette.isAchromatic)
        for point in palette.points {
            #expect(point.chroma < 0.005, "Expected strictly neutral greyscale, got \(point)")
        }
        // Top backdrop is brighter than dark jacket at bottom.
        #expect(palette.points[1].luminance > palette.points[7].luminance)
    }

    @Test func blueSkyImageProducesBlueGlowNotOrange() {
        // Simulates the cool blue/white NASA launch gallery photo.
        let rgba = makeRGBA(width: 24, height: 24) { _, _ in (95, 130, 220, 255) }
        let palette = AmbientColorSampler.sample(cgImage: makeCGImage(rgba: rgba, width: 24, height: 24))

        #expect(!palette.isAchromatic)
        for point in palette.points {
            #expect(point.b > point.r + 0.08, "Expected blue dominant over red, got \(point)")
            #expect(point.b > point.g + 0.04, "Expected blue dominant over green, got \(point)")
        }
    }

    @Test func spatialRegionsPreserveTopBottomAndLeftRightColors() {
        // Top half cool sky blue, bottom half violet-purple.
        let rgba = makeRGBA(width: 24, height: 24) { _, y in
            if y < 12 {
                return (50, 140, 235, 255)
            } else {
                return (180, 95, 215, 255)
            }
        }
        let palette = AmbientColorSampler.sample(rgbaBytes: rgba, width: 24, height: 24)

        let topCenter = palette.points[1]
        let bottomCenter = palette.points[7]

        // Top row stays cool blue (green > red, blue highest).
        #expect(topCenter.b > topCenter.g)
        #expect(topCenter.g > topCenter.r)

        // Bottom row shifts magenta/purple (red > green, blue highest).
        #expect(bottomCenter.r > bottomCenter.g)
        #expect(bottomCenter.b > bottomCenter.g)
    }

    @Test func cgImageSamplingPreservesTopBottomAndLeftRightOrientation() {
        // Top-left blue, top-right green, bottom-left red, bottom-right yellow.
        let rgba = makeRGBA(width: 24, height: 24) { x, y in
            switch (x < 12, y < 12) {
            case (true, true): return (30, 90, 235, 255)   // top-left: blue
            case (false, true): return (35, 210, 80, 255)  // top-right: green
            case (true, false): return (235, 50, 45, 255)  // bottom-left: red
            case (false, false): return (240, 210, 35, 255) // bottom-right: yellow
            }
        }
        let palette = AmbientColorSampler.sample(cgImage: makeCGImage(rgba: rgba, width: 24, height: 24))

        let topLeft = palette.points[0]
        let topRight = palette.points[2]
        let bottomLeft = palette.points[6]
        let bottomRight = palette.points[8]

        #expect(topLeft.b > topLeft.r && topLeft.b > topLeft.g)
        #expect(topRight.g > topRight.r && topRight.g > topRight.b)
        #expect(bottomLeft.r > bottomLeft.g && bottomLeft.r > bottomLeft.b)
        #expect(bottomRight.r > bottomRight.b && bottomRight.g > bottomRight.b)
    }

    @Test func pureBlackAndTransparentFramesStayDarkTheatrical() {
        let black = makeRGBA(width: 12, height: 12) { _, _ in (0, 0, 0, 255) }
        let blackPalette = AmbientColorSampler.sample(rgbaBytes: black, width: 12, height: 12)
        #expect(blackPalette.averageLuminance < 0.08)
        #expect(blackPalette.isAchromatic)

        let clear = makeRGBA(width: 12, height: 12) { _, _ in (0, 0, 0, 0) }
        let clearPalette = AmbientColorSampler.sample(rgbaBytes: clear, width: 12, height: 12)
        #expect(clearPalette == .darkNeutral)
    }

    @Test func bgraPixelBufferMatchesVideoFrameColors() throws {
        let buffer = try makeBGRAPixelBuffer(width: 32, height: 32) { x, _ in
            if x < 16 {
                return (40, 190, 210, 255)  // cool teal/cyan on left
            } else {
                return (230, 140, 40, 255)  // warm amber on right
            }
        }

        let palette = AmbientColorSampler.sample(pixelBuffer: buffer)
        let midLeft = palette.points[3]
        let midRight = palette.points[5]

        #expect(midLeft.b > midLeft.r, "Left half should be cool teal/cyan, got \(midLeft)")
        #expect(midRight.r > midRight.b, "Right half should be warm amber, got \(midRight)")
    }

    @Test func preferredTransformMapsToQuarterTurnOrientations() {
        #expect(AmbientOrientation(preferredTransform: .identity) == .up)
        #expect(AmbientOrientation(preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)) == .right)
        #expect(AmbientOrientation(preferredTransform: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)) == .down)
        #expect(AmbientOrientation(preferredTransform: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)) == .left)
    }

    @Test func rotatedPortraitVideoBufferAlignsTopAndBottomGlow() throws {
        // Raw landscape sensor buffer: left half (x < 16) is blue sky, right half (x >= 16) is warm amber ground.
        // Rotating 90° clockwise (.right) turns raw-left into display-top and raw-right into display-bottom.
        let buffer = try makeBGRAPixelBuffer(width: 32, height: 32) { x, _ in
            if x < 16 {
                return (45, 130, 235, 255) // sky blue
            } else {
                return (235, 145, 40, 255) // warm amber
            }
        }

        let rotatedRight = AmbientColorSampler.sample(pixelBuffer: buffer, orientation: .right)
        #expect(rotatedRight.points[1].b > rotatedRight.points[1].r, "Display top should be blue sky")
        #expect(rotatedRight.points[7].r > rotatedRight.points[7].b, "Display bottom should be warm amber")

        // Rotating 270° clockwise (.left) turns raw-right into display-top and raw-left into display-bottom.
        let rotatedLeft = AmbientColorSampler.sample(pixelBuffer: buffer, orientation: .left)
        #expect(rotatedLeft.points[1].r > rotatedLeft.points[1].b, "Display top should be warm amber")
        #expect(rotatedLeft.points[7].b > rotatedLeft.points[7].r, "Display bottom should be blue sky")
    }

    @Test func paletteBlendingInterpolatesSmoothly() {
        let a = AmbientPalette.uniform(AmbientRGB(r: 0.1, g: 0.2, b: 0.6))
        let b = AmbientPalette.uniform(AmbientRGB(r: 0.7, g: 0.2, b: 0.2))
        let mid = a.blended(with: b, factor: 0.5)

        #expect(abs(mid.points[4].r - 0.4) < 0.001)
        #expect(abs(mid.points[4].g - 0.2) < 0.001)
        #expect(abs(mid.points[4].b - 0.4) < 0.001)
    }
}

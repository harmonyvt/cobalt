import CoreGraphics
import CoreText
import Metal
import SyncGlowKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One row of monospaced ASCII, white on black, top row first. The shader samples this as the stars
/// and the line characters between them. Layout (which cell is which glyph) lives in `GlyphAtlasLayout`.
@MainActor
enum GlyphAtlasBaker {
    struct Image {
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    static func rasterize(_ layout: GlyphAtlasLayout = GlyphAtlasLayout(cell: 64)) -> Image? {
        let width = layout.pixelWidth
        let height = layout.pixelHeight
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // A bitmap context's first row is its bottom. Flip so the rects below are top-left, then
        // Core Text (which draws upward) is flipped back per line. Row 0 of `pixels` is the top of
        // the atlas after this, which is what the shader's v = 0 expects.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = CGInterpolationQuality.high

        let fontSize = CGFloat(layout.cell) * 0.62
        let cell = CGFloat(layout.cell)
        let lineHeight = fontSize * 1.2
        let color = CGColor(gray: 1, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: monospaced(size: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        for (index, glyph) in GlyphAtlasLayout.glyphs.enumerated() {
            let rect = CGRect(
                x: CGFloat(index) * cell,
                y: (cell - lineHeight) / 2,
                width: cell,
                height: lineHeight)
            let text = NSAttributedString(string: String(glyph), attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let path = CGPath(rect: rect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), path, nil)
            // The context is already flipped to a top-left origin, which is the Core Text recipe
            // (translate by the height, scale y by -1, then CTFrameDraw).
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
        }
        return Image(width: width, height: height, pixels: pixels)
    }

    static func texture(device: MTLDevice, image: Image) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: image.width, height: image.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        image.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: image.width)
        }
        return texture
    }

    private static func monospaced(size: CGFloat) -> Any {
        #if os(iOS)
        UIFont.monospacedSystemFont(ofSize: size, weight: .medium)
        #else
        NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        #endif
    }
}

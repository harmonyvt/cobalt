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
        // Core Graphics owns the buffer: a pointer into a Swift array is only good for the call it is
        // passed to, and this context is drawn into long after its initialiser returns.
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // No flip. A bitmap context has its origin at the bottom left with y growing upward, which is
        // the space Core Text draws upright in, and its memory starts with the top scanline. So row 0
        // of the pixels is the top of the atlas, which is what the shader's v = 0 expects. Flipping
        // here as well baked every glyph upside down: `/` came out as `\` and `.` hung from the top.
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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
            // Each cell's line box is centred in the cell, so it is the same rect from either edge.
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
        }
        guard let data = context.data else { return nil }
        // The context may pad its rows. Copy them out one by one, top row first.
        let rowBytes = context.bytesPerRow
        guard rowBytes >= width else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { out in
            guard let base = out.baseAddress else { return }
            for row in 0 ..< height {
                (base + row * width).copyMemory(from: UnsafeRawPointer(data) + row * rowBytes, byteCount: width)
            }
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

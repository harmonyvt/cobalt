import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Draws a wallpaper frame with its depth look: the subject (found by Vision, corrected by the owner's strokes) stays
/// sharp and still; the background blurs and drifts. The depth is two planes: the subject is near, everything else far.
/// iOS keeps its clock on top of a Live Photo wallpaper, so nothing here draws a clock.
public final class WallpaperRenderer: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    /// The subject's mask for `image` (white = subject), the size of the image. Nil when Vision finds no subject.
    public func subjectMask(_ image: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            // a one-channel float buffer: copy its red into all three colours, opaque, so every filter reads it as gray
            let red = CIVector(x: 1, y: 0, z: 0, w: 0)
            return CIImage(cvPixelBuffer: buffer).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": red, "inputGVector": red, "inputBVector": red,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        } catch {
            return nil
        }
    }

    /// The mask with the owner's strokes and the edge softness applied, cropped to `extent`. Without a found subject
    /// the strokes alone make the mask.
    public func finalMask(found: CIImage?, look: WallpaperLook, extent: CGRect) -> CIImage {
        let black = CIImage(color: .black).cropped(to: extent)
        var mask = (found.map { scaled($0, to: extent) } ?? black)
        if !look.findsSubject { mask = black }
        if let adds = strokeImage(look.strokes.filter(\.adds), extent: extent) {
            mask = adds.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }
        if let removes = strokeImage(look.strokes.filter { !$0.adds }, extent: extent) {
            let keep = removes.applyingFilter("CIColorInvert")
            mask = keep.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }
        let soft = look.softness * 0.01 * min(extent.width, extent.height)
        if soft > 0.5 {
            mask = mask.clampedToExtent().applyingGaussianBlur(sigma: soft)
        }
        return mask.cropped(to: extent)
    }

    /// One frame. `phase` runs 0...1 over a Live Photo; the drift is a full sine, so phase 0 and 1 are the picture as is.
    public func compose(_ frame: CIImage, mask: CIImage, look: WallpaperLook, phase: Double) -> CIImage {
        let extent = frame.extent
        if look.isPlain { return frame }
        let short = min(extent.width, extent.height)
        // the background: the subject's area smeared over with its surroundings, so a drift shows no sharp ghost
        let grown = mask.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: short * 0.02])
            .cropped(to: extent)
        let smear = frame.clampedToExtent().applyingGaussianBlur(sigma: short * 0.05).cropped(to: extent)
        var background = smear.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: frame, kCIInputMaskImageKey: grown,
        ])
        let sigma = look.blur * 0.025 * short
        if sigma > 0.3 {
            background = background.clampedToExtent().applyingGaussianBlur(sigma: sigma)
        }
        let reach = look.parallax * 0.03 * extent.width
        if reach > 0.5 {
            let dx = reach * sin(2 * .pi * phase)
            let zoom = 1 + (2 * reach) / extent.width
            let mid = CGPoint(x: extent.midX, y: extent.midY)
            let move = CGAffineTransform(translationX: mid.x + dx, y: mid.y)
                .scaledBy(x: zoom, y: zoom)
                .translatedBy(x: -mid.x, y: -mid.y)
            background = background.clampedToExtent().transformed(by: move)
        }
        background = background.cropped(to: extent)
        return frame.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
    }

    /// The depth map the editor shows: the subject white (near), the rest a dark gradient that lightens towards the
    /// bottom (the ground is nearer than the sky).
    public func depthMap(mask: CIImage, extent: CGRect) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: extent.midX, y: extent.minY)
        gradient.point1 = CGPoint(x: extent.midX, y: extent.maxY)
        gradient.color0 = CIColor(red: 0.35, green: 0.35, blue: 0.35)
        gradient.color1 = CIColor(red: 0.06, green: 0.06, blue: 0.06)
        let far = (gradient.outputImage ?? CIImage(color: .black)).cropped(to: extent)
        let near = CIImage(color: .white).cropped(to: extent)
        return near.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: far, kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
    }

    public func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Renders into a 32BGRA pixel buffer (the Live Photo's video frames).
    public func render(_ image: CIImage, into buffer: CVPixelBuffer) {
        context.render(image, to: buffer, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: helpers

    private func scaled(_ image: CIImage, to extent: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: extent.width / e.width, y: extent.height / e.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX - e.minX * extent.width / e.width,
                                               y: extent.minY - e.minY * extent.height / e.height))
            .cropped(to: extent)
    }

    /// The strokes drawn white on black at the extent's size. Stroke points are top-left based; Core Image is
    /// bottom-left, so y flips.
    private func strokeImage(_ strokes: [WallpaperStroke], extent: CGRect) -> CIImage? {
        guard !strokes.isEmpty else { return nil }
        let w = Int(extent.width.rounded()), h = Int(extent.height.rounded())
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceGray(),
                                                 bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let short = CGFloat(min(w, h))
        for stroke in strokes {
            let r = CGFloat(stroke.radius) * short
            let pts = stroke.points.map { CGPoint(x: $0.x * CGFloat(w), y: (1 - $0.y) * CGFloat(h)) }
            guard let first = pts.first else { continue }
            if pts.count == 1 {
                ctx.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: 2 * r, height: 2 * r))
                continue
            }
            ctx.setLineWidth(2 * r)
            ctx.beginPath()
            ctx.addLines(between: pts)
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}

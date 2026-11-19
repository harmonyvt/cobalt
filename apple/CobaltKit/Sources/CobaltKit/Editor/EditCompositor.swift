import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ImageIO

// The custom compositor (APP-API-CONTRACT 31.5, apple/CONTRACT-EDITOR.md 3.3): per output frame, black canvas, then the main clip's
// frame (orientation, crop, scale with Lanczos, place; geometry from `EditGeometry`, so the same integers as the server's ffmpeg
// graph), then every overlay that is up, lowest layer first (39.1), at its rectangle with alpha x opacity. Colour management is switched off end to end: pixel values
// go through untouched, as they do through ffmpeg.

/// Moves a non-Sendable AVFoundation object onto the compositor's own queue.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

enum EditComposeError: Error { case badInstruction, noBuffer }

public final class EditCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "capystore.editor.compositor", qos: .userInitiated)
    nonisolated(unsafe) private static let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
    ])

    /// The last frame each source track delivered: a clip whose source ends early holds it (31.4: a clip is exactly its frames).
    nonisolated(unsafe) private var lastFrames: [CMPersistentTrackID: CIImage] = [:]

    public override init() { super.init() }

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        let box = UncheckedBox(asyncVideoCompositionRequest)
        queue.async {
            let request = box.value
            guard let instruction = request.videoCompositionInstruction as? EditInstruction else {
                request.finish(with: EditComposeError.badInstruction)
                return
            }
            guard let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: EditComposeError.noBuffer)
                return
            }
            let plan = instruction.plan
            let k = max(0, Int((request.compositionTime.seconds * Double(plan.timing.fps)).rounded()))
            let opts: [CIImageOption: Any] = [.colorSpace: NSNull()]
            // Version 2 is its own path so the version 1 picture (PR 195's never-black change, on
            // `cursor/overlay-preview-black-7971`) can land in the block below without rewriting this one.
            // A missing frame keeps the last good one; a clip that has never delivered a frame is skipped and the
            // request still finishes, so one bad clip does not turn the preview black.
            if instruction.rendersLanes {
                var frames: [String: CIImage] = [:]
                for id in instruction.laneIDs {
                    guard case .video(let trackID, _, _) = plan.lanes[id] else { continue }
                    if let buffer = request.sourceFrame(byTrackID: trackID) {
                        let frame = CIImage(cvPixelBuffer: buffer, options: opts)
                        frames[id] = frame
                        self.lastFrames[trackID] = frame
                    } else if let held = self.lastFrames[trackID] {
                        frames[id] = held
                    }
                }
                var image = EditFrameComposer.composeLanes(plan: plan, frame: k, videos: frames)
                let bw = CVPixelBufferGetWidth(output), bh = CVPixelBufferGetHeight(output)
                if bw > 0, bh > 0, abs(image.extent.width - CGFloat(bw)) > 1 || abs(image.extent.height - CGFloat(bh)) > 1 {
                    image = EditFrameComposer.scale(image, to: PixelSize(w: bw, h: bh))
                }
                Self.context.render(
                    image, to: output, bounds: CGRect(x: 0, y: 0, width: bw, height: bh), colorSpace: nil)
                request.finish(withComposedVideoFrame: output)
                return
            }
            var main: CIImage?
            let mainTrack = plan.main[instruction.mainIndex].trackID
            if let buffer = request.sourceFrame(byTrackID: mainTrack) {
                main = CIImage(cvPixelBuffer: buffer, options: opts)
                self.lastFrames[mainTrack] = main
            } else {
                main = self.lastFrames[mainTrack]
            }
            var overlayVideos: [Int: CIImage] = [:]
            for j in instruction.overlayIndices where j < plan.overlay.count {
                guard case .video(let trackID, _) = plan.overlay[j].source else { continue }
                if let buffer = request.sourceFrame(byTrackID: trackID) {
                    let frame = CIImage(cvPixelBuffer: buffer, options: opts)
                    overlayVideos[j] = frame
                    self.lastFrames[trackID] = frame
                } else {
                    overlayVideos[j] = self.lastFrames[trackID]   // an overlay file that ends early holds its last frame
                }
            }
            var image = EditFrameComposer.compose(plan: plan, frame: k, main: main, overlayVideos: overlayVideos)
            let bw = CVPixelBufferGetWidth(output), bh = CVPixelBufferGetHeight(output)
            if bw > 0, bh > 0, abs(image.extent.width - CGFloat(bw)) > 1 || abs(image.extent.height - CGFloat(bh)) > 1 {
                image = EditFrameComposer.scale(image, to: PixelSize(w: bw, h: bh))
            }
            Self.context.render(
                image, to: output, bounds: CGRect(x: 0, y: 0, width: bw, height: bh), colorSpace: nil)
            request.finish(withComposedVideoFrame: output)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {}
}

/// The picture of one output frame, from the plan and the source frames. Pure Core Image, so a test draws a frame with no player.
enum EditFrameComposer {
    /// Version 2: black for the whole edit, then each visible clip bottom to top. A clip with no picture is skipped,
    /// which leaves the black base or the last clip that did draw.
    static func composeLanes(plan: EditRenderPlan, frame k: Int, videos: [String: CIImage]) -> CIImage {
        let canvas = plan.timeline.canvas
        let rect = CGRect(x: 0, y: 0, width: canvas.w, height: canvas.h)
        var out = CIImage(color: CIColor.black).cropped(to: rect)
        guard plan.timing.laneClips.count == plan.timeline.clips.count else { return out }
        for index in EditLanes.drawOrder(plan.timeline) {
            let clip = plan.timeline.clips[index]
            let row = plan.timing.laneClips[index]
            guard !clip.hidden, k >= row.start, k < row.start + row.frames, let picture = plan.lanes[clip.id] else { continue }
            guard var source = laneSource(picture, video: videos[clip.id], at: k, start: row.start, fps: plan.timing.fps) else {
                continue
            }
            if plan.proxy, source.extent.width > 960 || source.extent.height > 960 {
                let long = max(source.extent.width, source.extent.height)
                let scale = 960 / long
                source = scale(source, to: PixelSize(
                    w: max(2, Int((source.extent.width * scale).rounded())),
                    h: max(2, Int((source.extent.height * scale).rounded()))))
            }
            let oriented = orientLane(source, picture)
            if let key = clip.key?.normalized() {
                let keyed = EditChroma.apply(oriented, key: key, mask: plan.previewMaskID == clip.id)
                source = plan.previewSplitID == clip.id ? EditChroma.split(original: oriented, keyed: keyed) : keyed
            } else {
                source = oriented
            }
            out = drawLane(source, clip: clip, canvas: canvas, under: out)
        }
        return out.cropped(to: rect)
    }

    private static func laneSource(
        _ picture: EditRenderPlan.LanePicture, video: CIImage?, at k: Int, start: Int, fps: Int
    ) -> CIImage? {
        switch picture {
        case .video:
            return video
        case .gif(_, let delays, _, let images):
            let seconds = Double(k - start) / Double(max(1, fps))
            guard let index = gifFrameIndex(count: images.count, delays, at: seconds), index < images.count else { return nil }
            return images[index]
        case .photo(_, _, let image):
            return image
        }
    }

    private static func orientLane(_ image: CIImage, _ picture: EditRenderPlan.LanePicture) -> CIImage {
        switch picture {
        case .video(_, let orientation, let display):
            return squarePixels(orient(image, orientation), display: display)
        case .gif, .photo:
            return image
        }
    }

    /// A lane clip on the canvas. A `frame` uses the overlay placement; without one, crop and fit cover the canvas.
    private static func drawLane(_ image: CIImage, clip: EditLaneClip, canvas: EditCanvas, under: CIImage) -> CIImage {
        if let frame = clip.frame {
            let overlay = EditOverlay(
                id: clip.id, item: clip.item, at: clip.at, in: clip.`in`, out: clip.out, frame: frame, opacity: clip.opacity,
                volume: clip.volume, muted: clip.muted, pitch: clip.pitch, hidden: false, key: nil, background: clip.background)
            return drawOverlay(image, overlay: overlay, canvas: canvas, under: under) ?? under
        }
        let main = EditClip(
            id: clip.id, item: clip.item, in: clip.`in`, out: clip.out, speed: clip.speed, crop: clip.crop, fit: clip.fit,
            volume: clip.volume, muted: clip.muted, pitch: clip.pitch)
        guard var drawn = drawMain(image, clip: main, canvas: canvas) else { return under }
        if clip.opacity < 0.9999 {
            drawn = drawn.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, clip.opacity))),
            ])
        }
        return drawn.composited(over: under)
    }

    /// The canvas for output frame `k`. `main` is the main clip's decoded frame as the track delivers it (not yet oriented);
    /// `overlayVideos` is the same for each video overlay that is up, by its index in `overlay`. A GIF or a photo overlay comes
    /// from the plan. Overlays are drawn in `overlayDrawOrder` (lowest layer first, so a higher one is on top).
    static func compose(plan: EditRenderPlan, frame k: Int, main: CIImage?, overlayVideos: [Int: CIImage]) -> CIImage {
        let canvas = plan.timeline.canvas
        let rect = CGRect(x: 0, y: 0, width: canvas.w, height: canvas.h)
        var out = CIImage(color: CIColor.black).cropped(to: rect)

        if let (index, _) = plan.timing.clip(atFrame: k), let main, index < plan.timeline.main.count, index < plan.main.count {
            let clip = plan.timeline.main[index]
            let oriented = squarePixels(orient(main, plan.main[index].orientation), display: plan.main[index].display)
            if let drawn = drawMain(oriented, clip: clip, canvas: canvas) { out = drawn.composited(over: out) }
        }

        for j in plan.timeline.overlayDrawOrder {
            guard j < plan.timing.overlay.count, j < plan.overlay.count else { continue }
            let t = plan.timing.overlay[j]
            guard k >= t.start, k < t.start + t.frames else { continue }
            let o = plan.timeline.overlay[j]
            if o.hidden { continue }
            var source: CIImage?
            switch plan.overlay[j].source {
            case .video(_, let orientation):
                source = overlayVideos[j].map { squarePixels(orient($0, orientation), display: plan.overlay[j].display) }
            case .gif(let frames, let delays):
                let seconds = Double(k - t.start) / Double(plan.timing.fps)
                let images = plan.overlay[j].images
                if let i = gifFrameIndex(count: frames.count, delays, at: seconds) {
                    source = i < images.count ? images[i] : ciImage(frames[i])
                }
            case .photo(let image):
                source = plan.overlay[j].images.first ?? ciImage(image)
            }
            if var source {
                if plan.proxy, source.extent.width > 960 || source.extent.height > 960 {
                    let long = max(source.extent.width, source.extent.height)
                    let s = 960 / long
                    source = scale(source, to: PixelSize(
                        w: max(2, Int((source.extent.width * s).rounded())),
                        h: max(2, Int((source.extent.height * s).rounded()))))
                }
                let original = source
                if let key = o.key?.normalized() {
                    source = EditChroma.apply(source, key: key, mask: plan.previewMaskID == o.id)
                    if plan.previewSplitID == o.id { source = EditChroma.split(original: original, keyed: source) }
                }
                if let drawn = drawOverlay(source, overlay: o, canvas: canvas, under: out) { out = drawn }
            }
        }
        return out.cropped(to: rect)
    }

    // MARK: pieces

    /// The frame as displayed, its origin at (0, 0).
    static func orient(_ image: CIImage, _ orientation: CGImagePropertyOrientation) -> CIImage {
        let o = orientation == .up ? image : image.oriented(orientation)
        return o.transformed(by: CGAffineTransform(translationX: -o.extent.origin.x, y: -o.extent.origin.y))
    }

    /// A picture whose pixels are not square (anamorphic): widened to the square-pixel display size the server probed (31.6), keeping
    /// its height. A frame whose shape already matches is returned as it is.
    static func squarePixels(_ image: CIImage, display: PixelSize) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        guard display.w > 0, display.h > 0, w > 0, h > 0 else { return image }
        let wanted = Double(display.w) / Double(display.h), have = Double(w / h)
        guard abs(wanted / have - 1) > 0.01 else { return image }
        return scale(image, to: PixelSize(w: max(2, Int((Double(h) * wanted).rounded())), h: Int(h.rounded())))
    }

    static func ciImage(_ image: CGImage) -> CIImage {
        CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

    /// The GIF frame on screen `seconds` after the overlay started: the GIF loops end to start for as long as the overlay lasts.
    static func gifFrame(_ frames: [CGImage], _ delays: [Double], at seconds: Double) -> CGImage? {
        gifFrameIndex(count: frames.count, delays, at: seconds).map { frames[$0] }
    }

    /// The index of that frame among `count` frames; nil when there are none.
    static func gifFrameIndex(count: Int, _ delays: [Double], at seconds: Double) -> Int? {
        guard count > 0 else { return nil }
        let total = delays.reduce(0, +)
        guard total > 0, delays.count == count else { return 0 }
        var t = seconds.truncatingRemainder(dividingBy: total)
        if t < 0 { t += total }
        var passed = 0.0
        for (i, d) in delays.enumerated() {
            passed += d
            if t < passed { return i }
        }
        return count - 1
    }

    /// A main clip on the canvas: crop, Lanczos scale, place (y flipped: Core Image's origin is the bottom-left).
    static func drawMain(_ image: CIImage, clip: EditClip, canvas: EditCanvas) -> CIImage? {
        let display = PixelSize(w: Int(image.extent.width.rounded()), h: Int(image.extent.height.rounded()))
        guard let g = EditGeometry.main(display: display, crop: clip.crop, fit: clip.fit, canvas: canvas) else { return nil }
        let cropRect = CGRect(x: g.crop.x, y: display.h - g.crop.y - g.crop.h, width: g.crop.w, height: g.crop.h)
        var c = image.cropped(to: cropRect)
        c = c.transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        c = scale(c, to: g.scaled)
        return c.transformed(by: CGAffineTransform(
            translationX: CGFloat(g.place.x), y: CGFloat(canvas.h - (g.place.y + g.scaled.h))))
    }

    /// An overlay at its rectangle, its alpha times the overlay's opacity, composited over `under` (so a colour or a blur
    /// can sit behind just this overlay).
    static func drawOverlay(_ image: CIImage, overlay: EditOverlay, canvas: EditCanvas, under: CIImage? = nil) -> CIImage? {
        let display = PixelSize(w: Int(image.extent.width.rounded()), h: Int(image.extent.height.rounded()))
        guard display.w > 0, display.h > 0 else { return nil }
        let r = EditGeometry.overlay(display: display, frame: overlay.frame, canvas: canvas)
        var c = scale(image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)),
                      to: PixelSize(w: r.w, h: r.h))
        if overlay.opacity < 0.9999 {
            c = c.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, overlay.opacity))),
            ])
        }
        let placed = c.transformed(by: CGAffineTransform(translationX: CGFloat(r.x), y: CGFloat(canvas.h - r.y - r.h)))
        guard let under else { return placed }
        var base = under
        let plate = CGRect(x: r.x, y: canvas.h - r.y - r.h, width: r.w, height: r.h)
        switch overlay.background {
        case .color(let raw):
            if let rgb = EditChromaKey(color: raw).rgb {
                let color = CIImage(color: CIColor(red: rgb.r, green: rgb.g, blue: rgb.b)).cropped(to: plate)
                base = color.composited(over: base)
            }
        case .blur:
            let crop = under.cropped(to: plate)
            let blurred = crop.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18]).cropped(to: plate)
            base = blurred.composited(over: base)
        case .clip, nil:
            break
        }
        return placed.composited(over: base)
    }

    /// Scales to exactly `size` with Lanczos (a no-op when it is that size already).
    static func scale(_ image: CIImage, to size: PixelSize) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        guard w > 0, h > 0, size.w > 0, size.h > 0 else { return image }
        let sx = CGFloat(size.w) / w, sy = CGFloat(size.h) / h
        if abs(sx - 1) < 1e-6, abs(sy - 1) < 1e-6 { return image }
        let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy,
        ])
        return scaled
            .transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
            .cropped(to: CGRect(x: 0, y: 0, width: size.w, height: size.h))
    }
}

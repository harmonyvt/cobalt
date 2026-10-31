import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import CobaltKit

// The preview composition on real files (apple/CONTRACT-EDITOR.md 3.3, 3.8): the generated clips are decoded, the beach timeline is
// built, and its segment times, track layout and instructions are checked against the frame arithmetic of 31.4. The compositor's
// picture is checked on a plain red frame, so the geometry (31.6) is seen in pixels.

private let mediaDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("capystore-editor-test-media", isDirectory: true)

@MainActor
private func assets(for sources: [EditSource]) async throws -> [String: EditSourceAsset] {
    let media = PreviewEditorMedia(directory: mediaDirectory)
    let cache = EditSourceCache(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("edit-cache-\(UUID().uuidString)"),
        client: { PreviewClient() }, provider: { await media.url(forFile: $0) })
    var out: [String: EditSourceAsset] = [:]
    for source in sources { out[source.id] = try await cache.asset(for: source) }
    return out
}

@MainActor
struct EditorCompositionTests {
    private let sources = PreviewData.editorSources()

    @Test func theGeneratedFilesDecode() async throws {
        var friends = sources[PreviewEditorIDs.friends]!
        friends.width = nil
        friends.height = nil
        let decoded = try await assets(for: [sources[PreviewEditorIDs.pier]!, friends, sources[PreviewEditorIDs.dance]!, sources[PreviewEditorIDs.photo]!])
        guard case .video(_, _, let pierAudio) = decoded[PreviewEditorIDs.pier]! else { Issue.record("pier"); return }
        #expect(pierAudio)
        guard case .video(_, let display, let friendsAudio) = decoded[PreviewEditorIDs.friends]! else { Issue.record("friends"); return }
        #expect(!friendsAudio)
        #expect(display == PixelSize(w: 180, h: 320))                  // the 90 degree flag turns 320 x 180 upright
        guard case .gif(let frames, let delays, _) = decoded[PreviewEditorIDs.dance]! else { Issue.record("dance"); return }
        #expect(frames.count == 12 && delays.allSatisfy { abs($0 - 0.1) < 1e-9 })
        #expect(decoded[PreviewEditorIDs.photo]!.display == PixelSize(w: 160, h: 120))
    }

    @Test func theBeachTimelineIsBuiltFrameForFrame() async throws {
        let timeline = EditJSON.rounded(PreviewData.editorBeachTimeline())
        let decoded = try await assets(for: Array(sources.values))
        let playable = try await EditComposition.build(timeline, assets: decoded)
        #expect(playable.timing.frames == 780)
        #expect(abs(playable.composition.duration.seconds - 26) < 0.1)

        let video = playable.composition.tracks(withMediaType: .video)
        #expect(video.count == 1 && video[0].trackID == 1)              // the gif overlay has no track
        let starts = video[0].segments.map { $0.timeMapping.target.start.seconds }
        let lengths = video[0].segments.map { $0.timeMapping.target.duration.seconds }
        for (got, want) in zip(starts, [0, 12, 16.5, 22]) { #expect(abs(got - want) < 1e-3) }
        for (got, want) in zip(lengths, [12, 4.5, 5.5, 4]) { #expect(abs(got - want) < 1e-3) }
        #expect(starts.count == 4)
        #expect(playable.composition.tracks(withMediaType: .audio).first?.trackID == 2)

        let vc = playable.videoComposition
        #expect(vc.renderSize == CGSize(width: 1080, height: 1920))
        #expect(vc.frameDuration == CMTime(value: 1, timescale: 30))
        let breaks = vc.instructions.map { $0.timeRange.start.seconds }
        for (got, want) in zip(breaks, [0, 3, 6, 12, 16.5, 22]) { #expect(abs(got - want) < 1e-3) }
        #expect(breaks.count == 6)
        #expect(abs(vc.instructions.last!.timeRange.end.seconds - 26) < 0.1)
    }

    @Test func aTimelineWithAMissingFileIsRefused() async {
        do {
            _ = try await EditComposition.build(PreviewData.editorBeachTimeline(), assets: [:])
            Issue.record("should have thrown")
        } catch {
            #expect(EditError.from(error) == .other("source:\(PreviewEditorIDs.pier)"))
        }
    }

    @Test func aFrameIsRenderedFromTheRealCompositor() async throws {
        let timeline = EditTimeline.new(
            canvas: EditCanvas(w: 1080, h: 1920, fps: 30), main: [EditClip(id: "cOne00001", item: PreviewEditorIDs.pier, in: 0, out: 4)])
        let decoded = try await assets(for: [sources[PreviewEditorIDs.pier]!])
        let playable = try await EditComposition.build(timeline, assets: decoded)
        let generator = AVAssetImageGenerator(asset: playable.composition)
        generator.videoComposition = playable.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: 30, timescale: 30)).image
        #expect(image.width == 1080 && image.height == 1920)
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -540, y: -960, width: 1080, height: 1920))
        // the board colour #3b5b73 (59, 91, 115), within what colour handling may move
        #expect(abs(Int(pixel[0]) - 59) < 40 && abs(Int(pixel[1]) - 91) < 40 && abs(Int(pixel[2]) - 115) < 40)
    }
}

// MARK: - the picture (31.5, 31.6)

struct EditFrameComposerTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func plan(
        fit: EditFit = .fill, overlay: Bool = false
    ) -> EditRenderPlan {
        var clip = EditClip(id: "cOne00001", item: PreviewEditorIDs.pier, in: 0, out: 8)
        clip.fit = fit
        var overlays: [EditOverlay] = []
        var info: [EditRenderPlan.OverlayClip] = []
        if overlay {
            overlays = [EditOverlay(id: "cTwo00001", item: PreviewEditorIDs.dance, at: 3, in: 0, out: 3, frame: EditFrame(x: 0.6, y: 0.05, w: 0.35))]
            let side = CGImageSource_solid(width: 48, height: 36)
            info = [EditRenderPlan.OverlayClip(display: PixelSize(w: 480, h: 360), source: .gif(frames: [side], delays: [0.1]))]
        }
        let t = EditTimeline(canvas: EditCanvas(w: 1080, h: 1920, fps: 30), main: [clip], overlay: overlays)
        return EditRenderPlan(
            timeline: t, timing: EditTiming(t),
            main: [EditRenderPlan.MainClip(display: PixelSize(w: 1280, h: 720), orientation: .up, trackID: 1)], overlay: info)
    }

    private func CGImageSource_solid(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func red() -> CIImage {
        CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    /// RGBA of the canvas, top row first.
    private func pixels(_ image: CIImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 1080 * 1920 * 4)
        context.render(image, toBitmap: &buffer, rowBytes: 1080 * 4, bounds: CGRect(x: 0, y: 0, width: 1080, height: 1920), format: .RGBA8, colorSpace: nil)
        return buffer
    }

    private func at(_ p: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * 1080 + x) * 4
        return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]))
    }

    @Test func fillCoversEveryPixel() {
        let p = plan()
        let px = pixels(EditFrameComposer.compose(plan: p, frame: 10, main: red(), overlayVideos: [:]))
        for (x, y) in [(2, 2), (540, 960), (1077, 1917), (3, 1900)] { #expect(at(px, x, y).r > 240 && at(px, x, y).g < 15) }
    }

    @Test func fitLeavesBlackBarsWhereTheGeometrySays() {
        let p = plan(fit: .fit)
        let px = pixels(EditFrameComposer.compose(plan: p, frame: 10, main: red(), overlayVideos: [:]))
        // 1280 x 720 fits 1080 wide as 1080 x 608, placed at y 656
        #expect(at(px, 540, 100).r < 15 && at(px, 540, 1800).r < 15 && at(px, 540, 650).r < 15 && at(px, 540, 1270).r < 15)
        #expect(at(px, 540, 662).r > 240 && at(px, 540, 960).r > 240 && at(px, 540, 1258).r > 240)
    }

    @Test func theOverlayAppearsInItsRectangleOnlyWhileItIsUp() {
        let p = plan(overlay: true)
        let before = pixels(EditFrameComposer.compose(plan: p, frame: 10, main: red(), overlayVideos: [:]))
        #expect(at(before, 800, 200).b < 15)
        let during = pixels(EditFrameComposer.compose(plan: p, frame: 100, main: red(), overlayVideos: [:]))
        // (648, 96, 378 x 284)
        #expect(at(during, 800, 200).b > 240 && at(during, 800, 200).r < 15)
        #expect(at(during, 640, 200).r > 240 && at(during, 656, 200).b > 240)
        #expect(at(during, 1034, 200).r > 240 && at(during, 1018, 200).b > 240)
        #expect(at(during, 800, 88).r > 240 && at(during, 800, 104).b > 240)
        #expect(at(during, 800, 388).r > 240 && at(during, 800, 372).b > 240)
        let after = pixels(EditFrameComposer.compose(plan: p, frame: 180, main: red(), overlayVideos: [:]))
        #expect(at(after, 800, 200).b < 15)
    }

    @Test func anamorphicPixelsAreWidenedToTheSquarePixelDisplay() {
        let narrow = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 960, height: 1080))
        let fixed = EditFrameComposer.squarePixels(narrow, display: PixelSize(w: 1920, h: 1080))
        #expect(Int(fixed.extent.width) == 1920 && Int(fixed.extent.height) == 1080)
        let same = EditFrameComposer.squarePixels(narrow, display: PixelSize(w: 960, h: 1080))
        #expect(same.extent == narrow.extent)
    }

    @Test func aGifLoopsForAsLongAsTheOverlayLasts() {
        let a = CGImageSource_solid(width: 4, height: 4), b = CGImageSource_solid(width: 5, height: 5)
        #expect(EditFrameComposer.gifFrame([a, b], [0.1, 0.1], at: 0.05)?.width == 4)
        #expect(EditFrameComposer.gifFrame([a, b], [0.1, 0.1], at: 0.15)?.width == 5)
        #expect(EditFrameComposer.gifFrame([a, b], [0.1, 0.1], at: 0.25)?.width == 4)
        #expect(EditFrameComposer.gifFrame([], [], at: 1) == nil)
    }
}

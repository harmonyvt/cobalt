import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CobaltKit

// The one media pipeline (8.17): sizes from points × scale, stills downsampled to that size, frames shrunk without ever
// growing, the frame gate letting one frame through at a time, and the motion budget's first-come slots.

/// A `width` × `height` PNG, all one colour.
private func png(width: Int, height: Int) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let ctx = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(ctx.makeImage())
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

private func sides(_ size: (Int, Int)) -> [Int] { [size.0, size.1] }

@Suite struct MediaPipelineTests {
    @Test func maxPixelIsPointsTimesScaleRoundedUp() {
        #expect(MediaPipeline.maxPixel(points: 40, scale: 3) == 120)
        #expect(MediaPipeline.maxPixel(points: 40.2, scale: 2) == 81)
        // a scale under 1 (a test host) never makes a picture smaller than its points
        #expect(MediaPipeline.maxPixel(points: 64, scale: 0) == 64)
        #expect(MediaPipeline.maxPixel(points: 0, scale: 3) == 1)
        #expect(MediaPipeline.maxPixel(points: .infinity, scale: 3) == 1)
    }

    @Test func fittedShrinksTheLongSideAndNeverGrows() {
        #expect(sides(MediaPipeline.fitted(width: 1024, height: 512, maxPixel: 512)) == [512, 256])
        #expect(sides(MediaPipeline.fitted(width: 300, height: 900, maxPixel: 120)) == [40, 120])
        #expect(sides(MediaPipeline.fitted(width: 100, height: 50, maxPixel: 512)) == [100, 50])
        #expect(sides(MediaPipeline.fitted(width: 0, height: 0, maxPixel: 0)) == [1, 1])
    }

    @Test func stillIsDownsampledOffMain() async throws {
        let data = try png(width: 600, height: 300)
        let box = try #require(await Task.detached { MediaPipeline.still(data: data, maxPixel: 120) }.value)
        #expect(max(box.image.width, box.image.height) == 120)
        #expect(box.image.width == 120 && box.image.height == 60)
    }

    @Test func fileStillGoesThroughTheSharedCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString).png")
        try png(width: 200, height: 200).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try #require(await Task.detached { MediaPipeline.still(file: url, maxPixel: 64) }.value)
        #expect(first.image.width == 64)
        let cached = try #require(MediaPipeline.memory.image(forKey: MediaPipeline.key("f", url, maxPixel: 64)))
        #expect(cached.image === first.image)
        // another size is another entry
        #expect(MediaPipeline.memory.image(forKey: MediaPipeline.key("f", url, maxPixel: 32)) == nil)
        MediaPipeline.memory.remove(forKey: MediaPipeline.key("f", url, maxPixel: 64))
        #expect(MediaPipeline.memory.image(forKey: MediaPipeline.key("f", url, maxPixel: 64)) == nil)
    }

    @Test func shrinkMakesADisplayReadyFrameAtMostMaxPixel() async throws {
        let data = try png(width: 800, height: 400)
        let full = try #require(await Task.detached { MediaPipeline.still(data: data, maxPixel: 800) }.value)
        let small = await Task.detached { ImageBox(MediaPipeline.shrink(full.image, maxPixel: 200)) }.value.image
        #expect(small.width == 200 && small.height == 100)
        let same = await Task.detached { ImageBox(MediaPipeline.shrink(full.image, maxPixel: 2000)) }.value.image
        #expect(same.width == 800 && same.height == 400)
    }

    @Test func emoteStillDecodesAtTheTileSizeAndCaches() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-emotes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = try png(width: 128, height: 128)
        let emotes = EmoteCache(directory: dir, fetch: { _ in bytes })
        let url = URL(string: "https://cdn.7tv.app/emote/pipeline-\(UUID().uuidString)/2x.webp")!
        #expect(MediaPipeline.cachedEmoteStill(url, maxPixel: 120) == nil)
        let box = try #require(await MediaPipeline.emoteStill(url, maxPixel: 120, emotes: emotes))
        #expect(box.image.width == 120)
        #expect(MediaPipeline.cachedEmoteStill(url, maxPixel: 120)?.image === box.image)
    }

    @Test func frameGateLetsOneFrameThroughAtATime() {
        let gate = FrameGate()
        #expect(gate.claim())
        #expect(!gate.claim())
        gate.release()
        #expect(gate.claim())
    }

    @Test func mediaAnimationFrameDelayClampsFastAndZeroDelays() {
        let zeroGIF: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.0]]
        #expect(MediaAnimation.frameDelay(zeroGIF, minimum: 0.05) == 0.1)

        let fastWebP: [CFString: Any] = [kCGImagePropertyWebPDictionary: [kCGImagePropertyWebPUnclampedDelayTime: 0.025]]
        #expect(MediaAnimation.frameDelay(fastWebP, minimum: 0.05) == 0.05)
        #expect(MediaAnimation.frameDelay(fastWebP, minimum: 1.0 / 30.0) == 1.0 / 30.0)

        let slowWebP: [CFString: Any] = [kCGImagePropertyWebPDictionary: [kCGImagePropertyWebPDelayTime: 0.2]]
        #expect(MediaAnimation.frameDelay(slowWebP, minimum: 0.05) == 0.2)
    }

    @Test func mediaAnimationDecodesDownsampledFramesOffMainAndStops() async throws {
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "com.compuserve.gif" as CFString, 2, nil))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        let frameImage = try #require(ctx.makeImage())
        let props: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]]
        CGImageDestinationAddImage(dest, frameImage, props as CFDictionary)
        CGImageDestinationAddImage(dest, frameImage, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let received = await withCheckedContinuation { (cont: CheckedContinuation<ImageBox?, Never>) in
            final class Once: @unchecked Sendable {
                var done = false
                var animation: MediaAnimation?
            }
            let once = Once()
            once.animation = MediaAnimation.play(data: out as Data, maxPixel: 40) { box in
                guard !once.done else { return }
                once.done = true
                once.animation?.stop()
                cont.resume(returning: box)
            }
            if once.animation == nil { cont.resume(returning: nil) }
        }
        let box = try #require(received)
        #expect(box.image.width == 40 && box.image.height == 20)
    }
}

@MainActor @Suite struct MotionBudgetTests {
    @Test func firstComeFirstServedUpToTheLimit() {
        let budget = MotionBudget(limit: 2, watchPower: false)
        let a = MotionTicket(), b = MotionTicket(), c = MotionTicket()
        budget.want(a, true)
        budget.want(b, true)
        budget.want(c, true)
        #expect(a.granted && b.granted && !c.granted)
        #expect(budget.playingCount == 2)

        // one leaves the screen: the next in line moves, the one that left shows its still
        budget.want(a, false)
        #expect(!a.granted && b.granted && c.granted)

        // coming back queues at the end
        budget.want(a, true)
        #expect(!a.granted)
        #expect(budget.playingCount == 2)
    }

    @Test func askingTwiceChangesNothing() {
        let budget = MotionBudget(limit: 1, watchPower: false)
        let a = MotionTicket(), b = MotionTicket()
        budget.want(a, true)
        budget.want(b, true)
        budget.want(a, true)
        #expect(a.granted && !b.granted)
        budget.want(b, false)
        budget.want(b, false)
        #expect(a.granted && !b.granted)
    }

    @Test func lowPowerStopsEverything() {
        let budget = MotionBudget(limit: 4, watchPower: false)
        let a = MotionTicket()
        budget.want(a, true)
        #expect(a.granted)
        budget.setLowPower(true)
        #expect(!a.granted)
        budget.setLowPower(false)
        #expect(a.granted)
    }

    @Test func aTicketThatWentAwayGivesItsSlotBack() {
        let budget = MotionBudget(limit: 1, watchPower: false)
        var gone: MotionTicket? = MotionTicket()
        budget.want(gone!, true)
        #expect(gone!.granted)
        gone = nil
        let next = MotionTicket()
        budget.want(next, true)
        #expect(next.granted)
    }

    @Test func zeroLimitNeverMoves() {
        let budget = MotionBudget(limit: 0, watchPower: false)
        let a = MotionTicket()
        budget.want(a, true)
        #expect(!a.granted)
    }

    @Test func ungrantedTicketsLeavingDoNotDisturbActiveSlots() {
        let budget = MotionBudget(limit: 2, watchPower: false)
        let a = MotionTicket(), b = MotionTicket(), c = MotionTicket(), d = MotionTicket()
        budget.want(a, true)
        budget.want(b, true)
        budget.want(c, true)
        budget.want(d, true)
        #expect(a.granted && b.granted && !c.granted && !d.granted)
        budget.want(c, false)
        #expect(a.granted && b.granted && !c.granted && !d.granted)
        budget.want(a, false)
        #expect(!a.granted && b.granted && d.granted)
    }
}

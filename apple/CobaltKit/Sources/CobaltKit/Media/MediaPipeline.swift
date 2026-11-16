import CoreGraphics
import Foundation
import ImageIO
import Synchronization

// One media pipeline (8.17). Every still, poster, webp, gif and 7TV emote the app draws is decoded here, off the main
// thread: downsampled with ImageIO to the pixels its view really has (view size × screen scale), decoded at once
// (`kCGImageSourceShouldCacheImmediately`, not on first draw mid-scroll, 8.15), kept in one memory cache bounded by
// decoded bytes, and, when it moves, played through `MediaAnimation`: each frame shrunk off the main thread and at most
// one frame on its way to the main actor at a time. Which things move at all is `MotionBudget`'s choice (and the
// library mosaic's own `AnimationBudget`, which picks the tiles nearest the centre).
//
// 8.16 measured why: the 7TV tab hitched 401 ms per second (worst frame 779 ms) because each emote handed every
// animation frame to the main thread at full size, with no gate and no limit, while the library, which already did all
// of the above, scrolled smoothly. The main thread only assigns the finished `ImageBox`.

/// A CGImage moved between threads once and never touched again.
public struct ImageBox: @unchecked Sendable {
    public let image: CGImage
    public init(_ image: CGImage) { self.image = image }
}

public enum MediaPipeline {
    // MARK: sizes

    /// The pixels a view of `points` needs on its long side at `scale` (rounded up, at least 1).
    public static func maxPixel(points: CGFloat, scale: CGFloat) -> Int {
        guard points.isFinite, points > 0 else { return 1 }
        let pixels = (Double(points) * Double(max(scale, 1))).rounded(.up)
        return max(1, Int(min(pixels, 16_384)))
    }

    // MARK: the shared memory cache

    /// Decoded pictures for the whole app: about 192 MB of decoded bytes in the app (the library needed 160 MB to find its
    /// pictures again on scroll back, 8.15), 24 MB in an extension, whose whole memory allowance is far smaller.
    public static let memory: MediaMemoryCache = {
        let inExtension = Bundle.main.bundleURL.pathExtension == "appex"
        return MediaMemoryCache(
            costLimit: (inExtension ? 24 : 192) * 1024 * 1024,
            countLimit: inExtension ? 300 : 1_000)
    }()

    /// The cache key of one picture at one size. `kind` keeps a file's still apart from an emote's or a video's frame.
    public static func key(_ kind: String, _ url: URL, maxPixel: Int) -> String {
        "\(kind)|\(maxPixel)|\(url.absoluteString)"
    }

    // MARK: decoding (never on the main thread)

    /// The first frame of `source` (an animated webp's or gif's too), at most `maxPixel` on its long side, decoded now.
    public static func thumbnail(of source: CGImageSource, maxPixel: Int) -> ImageBox? {
        MainThreadGuard.assertOffMain()
        return EngineClock.measure("media.still") { () -> ImageBox? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                // decoded here, off the main thread, not on first draw mid-scroll (8.15)
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(ImageBox.init)
        }
    }

    /// The still of some bytes, downsampled. Not cached: the caller knows the key.
    public static func still(data: Data, maxPixel: Int) -> ImageBox? {
        MainThreadGuard.assertOffMain()
        // the source itself keeps no full-size copy: only the thumbnail is wanted
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(of: source, maxPixel: maxPixel)
    }

    /// The still of a file on disk, downsampled, through the shared cache.
    public static func still(file url: URL, maxPixel: Int) -> ImageBox? {
        MainThreadGuard.assertOffMain()
        let key = key("f", url, maxPixel: maxPixel)
        if let hit = memory.image(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let box = thumbnail(of: source, maxPixel: maxPixel)
        else { return nil }
        memory.store(box, forKey: key)
        return box
    }

    /// A 7TV emote's first frame at `maxPixel`: the shared cache, else the bytes from `EmoteCache` (memory, disk, else one
    /// fetch) decoded and downsampled. Runs off the caller's actor; nil when the picture cannot be had.
    public static func emoteStill(_ url: URL, maxPixel: Int, emotes: EmoteCache = .shared) async -> ImageBox? {
        let key = key("e", url, maxPixel: maxPixel)
        if let hit = memory.image(forKey: key) { return hit }
        guard let data = await emotes.data(for: url), !Task.isCancelled,
              let box = still(data: data, maxPixel: maxPixel)
        else { return nil }
        memory.store(box, forKey: key)
        return box
    }

    /// An emote's still when it is already decoded at this size: synchronous, for a tile's first frame (no blank flash
    /// when it scrolls back).
    public static func cachedEmoteStill(_ url: URL, maxPixel: Int) -> ImageBox? {
        memory.image(forKey: key("e", url, maxPixel: maxPixel))
    }

    /// The frame at most `maxPixel` on its long side, drawn into a display-ready bitmap (premultiplied BGRA, sRGB), so the
    /// main thread only hands it to Core Animation. A frame already small enough is still drawn, at its own size, for the
    /// same reason.
    public static func shrink(_ image: CGImage, maxPixel: Int) -> CGImage {
        MainThreadGuard.assertOffMain()
        return EngineClock.measure("media.frame") { () -> CGImage in
            let (tw, th) = fitted(width: image.width, height: image.height, maxPixel: maxPixel)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return image }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
            return ctx.makeImage() ?? image
        }
    }

    /// `width` × `height` scaled down (never up) so the long side is at most `maxPixel`; at least 1 × 1.
    static func fitted(width: Int, height: Int, maxPixel: Int) -> (Int, Int) {
        let scale = min(1, Double(max(maxPixel, 1)) / Double(max(width, height, 1)))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
}

/// Decoded pictures, bounded by decoded bytes and count. Thread safe (NSCache), so a view can look a picture up
/// synchronously in its first frame.
public final class MediaMemoryCache: @unchecked Sendable {
    private final class Holder: Sendable {
        let box: ImageBox
        init(_ box: ImageBox) { self.box = box }
    }

    private let cache = NSCache<NSString, Holder>()

    public init(costLimit: Int, countLimit: Int) {
        cache.totalCostLimit = costLimit
        cache.countLimit = countLimit
    }

    public func image(forKey key: String) -> ImageBox? {
        cache.object(forKey: key as NSString)?.box
    }

    public func store(_ box: ImageBox, forKey key: String) {
        cache.setObject(Holder(box), forKey: key as NSString, cost: max(1, box.image.bytesPerRow * box.image.height))
    }

    public func remove(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }
}

// MARK: - moving pictures

/// One frame on its way to the main actor at a time: a frame that comes while the last is not shown yet is dropped
/// before any work is spent on it.
final class FrameGate: Sendable {
    private let pending = Mutex(false)

    /// True (and the gate shut) when no frame is waiting.
    func claim() -> Bool {
        pending.withLock { busy in
            if busy { return false }
            busy = true
            return true
        }
    }

    func release() { pending.withLock { $0 = false } }
}

/// One playing webp or gif. ImageIO keeps time and calls back once a frame; that callback only claims the gate and hands
/// the frame to a background task, which shrinks it to `maxPixel`, so the main actor gets one small display-ready frame
/// at a time whatever queue ImageIO calls back on. `stop()` ends it at the next frame; the owner must call it.
public final class MediaAnimation: Sendable {
    private let stopped = Mutex(false)
    private let gate = FrameGate()

    private init() {}

    public var isStopped: Bool { stopped.withLock { $0 } }

    public func stop() { stopped.withLock { $0 = true } }

    /// Plays `data`; nil when ImageIO cannot animate it (nothing will be shown).
    public static func play(
        data: Data, maxPixel: Int, onFrame: @escaping @MainActor @Sendable (ImageBox) -> Void
    ) -> MediaAnimation? {
        let animation = MediaAnimation()
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { @Sendable _, image, halt in
            animation.arrived(image, halt, maxPixel: maxPixel, onFrame: onFrame)
        }
        return status == noErr ? animation : nil
    }

    /// Plays a file on disk; nil when ImageIO cannot animate it.
    public static func play(
        file url: URL, maxPixel: Int, onFrame: @escaping @MainActor @Sendable (ImageBox) -> Void
    ) -> MediaAnimation? {
        let animation = MediaAnimation()
        let status = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { @Sendable _, image, halt in
            animation.arrived(image, halt, maxPixel: maxPixel, onFrame: onFrame)
        }
        return status == noErr ? animation : nil
    }

    private func arrived(
        _ image: CGImage, _ halt: UnsafeMutablePointer<Bool>, maxPixel: Int,
        onFrame: @escaping @MainActor @Sendable (ImageBox) -> Void
    ) {
        if isStopped { halt.pointee = true; return }
        guard gate.claim() else { return }
        let raw = ImageBox(image)
        let gate = self.gate
        Task.detached(priority: .userInitiated) { [self] in
            let frame = ImageBox(MediaPipeline.shrink(raw.image, maxPixel: maxPixel))
            await MainActor.run {
                if !self.isStopped { onFrame(frame) }
                gate.release()
            }
        }
    }
}

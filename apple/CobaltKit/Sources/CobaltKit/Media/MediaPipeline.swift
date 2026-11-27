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
    /// pictures again on scroll back, 8.15), 24 MB in an extension, whose whole memory allowance is far smaller. Emptied
    /// when the app leaves the screen and on a memory warning (`purgedWithApp`); every picture is decoded again from disk.
    public static let memory: MediaMemoryCache = {
        let inExtension = Bundle.main.bundleURL.pathExtension == "appex"
        return MediaMemoryCache(
            costLimit: (inExtension ? 24 : 192) * 1024 * 1024,
            countLimit: inExtension ? 300 : 1_000)
            .purgedWithApp()
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

    /// Forgets every picture (memory only: nothing here is on disk).
    public func removeAll() {
        cache.removeAllObjects()
    }

    /// Signs this cache up to be emptied by `AppLifecycle` (the app leaving the screen, a memory warning). Call it once,
    /// where the cache is made; returns the cache so a `static let` can end with it.
    @discardableResult
    public func purgedWithApp() -> MediaMemoryCache {
        Task { @MainActor [weak self] in
            guard let self else { return }
            PurgeHook.register { [weak self] _ in self?.removeAll() }
        }
        return self
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

/// One playing webp or gif. Decodes every frame completely off the main thread via `CGImageSource` thumbnails at
/// `maxPixel` (never calling `CGAnimateImageDataWithBlock`, which decodes on `DispatchQueue.main`), clamps rapid emote
/// frame rates, and caches small looping emotes in memory only while playing. `stop()` cancels the decode task
/// immediately; the owner must call it, or hold it in a `MediaAnimationSlot`, which stops it when freed.
public final class MediaAnimation: Sendable {
    private struct State {
        var stopped = false
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())

    private init() {}

    public var isStopped: Bool { state.withLock { $0.stopped } }

    public func stop() {
        let task = state.withLock { s -> Task<Void, Never>? in
            s.stopped = true
            let existing = s.task
            s.task = nil
            return existing
        }
        task?.cancel()
    }

    /// Plays `data`; nil when `data` is empty.
    public static func play(
        data: Data,
        maxPixel: Int,
        onFail: (@MainActor @Sendable () -> Void)? = nil,
        onFrame: @escaping @MainActor @Sendable (ImageBox) -> Void
    ) -> MediaAnimation? {
        guard !data.isEmpty else { return nil }
        let animation = MediaAnimation()
        animation.start {
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            await animation.run(source: source, maxPixel: maxPixel, onFail: onFail, onFrame: onFrame)
        }
        return animation
    }

    /// Plays a file on disk; nil when `url` is not a file URL.
    public static func play(
        file url: URL,
        maxPixel: Int,
        onFail: (@MainActor @Sendable () -> Void)? = nil,
        onFrame: @escaping @MainActor @Sendable (ImageBox) -> Void
    ) -> MediaAnimation? {
        guard url.isFileURL else { return nil }
        let animation = MediaAnimation()
        animation.start {
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            await animation.run(source: source, maxPixel: maxPixel, onFail: onFail, onFrame: onFrame)
        }
        return animation
    }

    private func start(_ work: @escaping @Sendable () async -> Void) {
        let task = Task.detached(priority: .utility) {
            await work()
        }
        let alreadyStopped = state.withLock { s -> Bool in
            if s.stopped { return true }
            s.task = task
            return false
        }
        if alreadyStopped { task.cancel() }
    }

    private func run(
        source: CGImageSource?,
        maxPixel: Int,
        onFail: (@MainActor @Sendable () -> Void)?,
        onFrame: @escaping @MainActor @Sendable (ImageBox) -> Void
    ) async {
        MainThreadGuard.assertOffMain()
        guard let source else {
            if let onFail, !isStopped, !Task.isCancelled {
                await MainActor.run { if !self.isStopped { onFail() } }
            }
            return
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            if let onFail, !isStopped, !Task.isCancelled {
                await MainActor.run { if !self.isStopped { onFail() } }
            }
            return
        }

        let clampedPixel = max(1, maxPixel)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: clampedPixel,
        ]

        if count == 1 {
            guard !isStopped, !Task.isCancelled else { return }
            let box: ImageBox? = EngineClock.measure("media.frame") {
                CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(ImageBox.init)
            }
            if let box, !isStopped, !Task.isCancelled {
                await MainActor.run { if !self.isStopped { onFrame(box) } }
            } else if box == nil, let onFail, !isStopped, !Task.isCancelled {
                await MainActor.run { if !self.isStopped { onFail() } }
            }
            return
        }

        let minDelay: Double = clampedPixel <= 160 ? 0.05 : (1.0 / 30.0)
        var delays: [Double] = []
        delays.reserveCapacity(count)
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            delays.append(Self.frameDelay(props, minimum: minDelay))
        }

        // Small chat emotes (<= 160 px, <= 64 frames, ~0.2–1.5 MB) cache decoded thumbnails for the lifetime of this
        // playback so subsequent loops spend zero CPU re-decoding WebP/GIF bitstreams. Freed immediately on stop().
        let canCacheFrames = clampedPixel <= 160 && count <= 64
        var cached: [ImageBox?] = canCacheFrames ? Array(repeating: nil, count: count) : []
        var emittedAny = false

        while !isStopped && !Task.isCancelled {
            for i in 0..<count {
                if isStopped || Task.isCancelled { return }
                let startedAt = ContinuousClock.now
                let box: ImageBox?
                if canCacheFrames, let hit = cached[i] {
                    box = hit
                } else {
                    let decoded: ImageBox? = EngineClock.measure("media.frame") {
                        CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary).map(ImageBox.init)
                    }
                    if canCacheFrames { cached[i] = decoded }
                    box = decoded
                }

                if let box {
                    emittedAny = true
                    await MainActor.run {
                        if !self.isStopped { onFrame(box) }
                    }
                } else if !emittedAny, i == 0 {
                    if let onFail, !isStopped, !Task.isCancelled {
                        await MainActor.run { if !self.isStopped { onFail() } }
                    }
                    return
                }

                let wait = Duration.seconds(delays[i]) - startedAt.duration(to: .now)
                if wait > .zero {
                    try? await Task.sleep(for: wait)
                }
            }
        }
    }

    /// Reads per-frame delay from WebP, GIF, or APNG metadata, matching browser/ffmpeg convention (< 20 ms -> 100 ms)
    /// and clamping to `minimum` so tiny emotes never spam 60–100 fps main-actor updates.
    static func frameDelay(_ props: [CFString: Any]?, minimum: Double) -> Double {
        let raw: Double?
        if let webp = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            raw = (webp[kCGImagePropertyWebPUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (webp[kCGImagePropertyWebPDelayTime] as? NSNumber)?.doubleValue
        } else if let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            raw = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        } else if let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            raw = (png[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (png[kCGImagePropertyAPNGDelayTime] as? NSNumber)?.doubleValue
        } else {
            raw = nil
        }
        let seconds = (raw ?? 0) < 0.02 ? 0.1 : (raw ?? 0.1)
        return max(minimum, seconds)
    }
}

/// Holds an owner's one `MediaAnimation` and stops it when it is replaced, cleared, or freed along with its owner. The
/// safety net for a view torn down without `onDisappear` (a parent that went away whole, a model dropped by SwiftUI): a
/// model keeps one of these as a `let`, so its animation stops decoding without the model's deinit touching main-actor
/// state (the app's deployment targets have no `isolated deinit`).
public final class MediaAnimationSlot: Sendable {
    private let current = Mutex<MediaAnimation?>(nil)

    public init() {}

    /// The animation playing now, nil when none.
    public var animation: MediaAnimation? { current.withLock { $0 } }

    /// Puts `next` in (nil empties the slot); the one it replaces stops.
    public func set(_ next: MediaAnimation?) {
        let old = current.withLock { value -> MediaAnimation? in
            let old = value
            value = next
            return old
        }
        if let old, old !== next { old.stop() }
    }

    public func stop() { set(nil) }

    deinit { current.withLock { $0 }?.stop() }
}

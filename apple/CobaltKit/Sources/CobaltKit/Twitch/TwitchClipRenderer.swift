@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Off-main rendering engine for Twitch clip drafts (iOS & macOS):
// 1. `renderChatGIF`: produces a compact, event-driven transparent animated GIF (`image/gif`) with real
//    7TV/Twitch emotes (animating when `animated == true`, static when `animated == false`), badges, and
//    7TV paints so "Send to Studio (without rendering)" carries real synced chat onto Lane 2.
// 2. `renderCompositeMP4`: renders the final 9:16 1080×1920 H.264/AAC MP4 with Region A / B split-frame
//    and burned-in chat overlay with frame-accurate animated & static 7TV/Twitch emotes, zero-width stacks,
//    badges, and 7TV gradient paints.

public enum TwitchClipRendererError: Error, Sendable, Equatable {
    case unreadableSource
    case cannotCreateWriter(String)
    case exportFailed(String)
    case gifFailed
}

/// Summary telemetry produced by `TwitchClipRenderer.renderCompositeMP4`.
public struct TwitchClipRenderStats: Sendable, Equatable {
    public var renderMs: Int
    public var chatEntries: Int
    public var emotesPrefetched: Int
    public var animatedEmotes: Int
    public var badgesPrefetched: Int
    public var overlayRasterizations: Int

    public init(
        renderMs: Int = 0,
        chatEntries: Int = 0,
        emotesPrefetched: Int = 0,
        animatedEmotes: Int = 0,
        badgesPrefetched: Int = 0,
        overlayRasterizations: Int = 0
    ) {
        self.renderMs = renderMs
        self.chatEntries = chatEntries
        self.emotesPrefetched = emotesPrefetched
        self.animatedEmotes = animatedEmotes
        self.badgesPrefetched = badgesPrefetched
        self.overlayRasterizations = overlayRasterizations
    }
}

/// Pre-decoded bitmap (single frame for static emotes, timed multi-frame sequence for animated WebP/GIF/APNG emotes).
public struct DecodedEmoteAsset: @unchecked Sendable {
    public let frames: [CGImage]
    public let cumulativeEndTimes: [Double]
    public let totalDuration: Double
    public let isAnimated: Bool
    public let aspect: Double

    public init(frames: [CGImage], frameDurations: [Double], animated: Bool) {
        self.frames = frames
        let first = frames.first
        let rawAspect = first.map { Double($0.width) / Double(max(1, $0.height)) } ?? 1.0
        self.aspect = max(0.5, min(4.0, rawAspect))
        if animated && frames.count > 1 {
            var ends: [Double] = []
            ends.reserveCapacity(frames.count)
            var sum = 0.0
            for i in frames.indices {
                let d = i < frameDurations.count ? max(1.0 / 30.0, frameDurations[i]) : 0.1
                sum += d
                ends.append(sum)
            }
            self.cumulativeEndTimes = ends
            self.totalDuration = sum
            self.isAnimated = sum > 0
        } else {
            self.cumulativeEndTimes = [0]
            self.totalDuration = 0
            self.isAnimated = false
        }
    }

    /// Returns the frame index active at playback timestamp `time` (seconds).
    /// Always returns `0` for static assets (`isAnimated == false`).
    public func frameIndex(at time: Double) -> Int {
        guard isAnimated, frames.count > 1, totalDuration > 0 else { return 0 }
        var wrapped = time.truncatingRemainder(dividingBy: totalDuration)
        if wrapped < 0 { wrapped += totalDuration }
        for (i, end) in cumulativeEndTimes.enumerated() where wrapped < end {
            return i
        }
        return frames.count - 1
    }

    public func frame(at time: Double) -> CGImage {
        frames[frameIndex(at: time)]
    }
}

public enum TwitchClipRenderer {
    public static let canvasWidth = 1080
    public static let canvasHeight = 1920
    public static let renderFPS = 30

    private static let inlineAttachmentKey = NSAttributedString.Key("cobalt.twitch.inlineAttachment")
    private static let paintGradientKey = NSAttributedString.Key("cobalt.twitch.paintGradient")

    private final class InlineAttachment: NSObject {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let images: [(image: CGImage, aspect: CGFloat)]

        init(width: CGFloat, ascent: CGFloat, descent: CGFloat, images: [(image: CGImage, aspect: CGFloat)]) {
            self.width = width
            self.ascent = ascent
            self.descent = descent
            self.images = images
        }
    }

    private final class PaintBox: NSObject {
        let paint: RecordedChatPaint
        init(_ paint: RecordedChatPaint) { self.paint = paint }
    }

    // MARK: - Asset Decoding & Concurrent Prefetch

    /// Decodes raw WebP/GIF/APNG/PNG bytes off-main via ImageIO, respecting `animated`:
    /// - `animated == false` decodes ONLY frame 0 (static emote stays static).
    /// - `animated == true` decodes up to `maxFrames` frames with WebP/GIF/APNG frame delays so recordings
    ///   play real animated 7TV/Twitch emotes at their authored timing.
    public static func decodeAsset(
        data: Data,
        animated: Bool,
        maxPixel: Int = 128,
        maxFrames: Int = 96
    ) -> DecodedEmoteAsset? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        let clampedPixel = max(16, maxPixel)
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: clampedPixel,
        ]

        func decodeFrame(_ index: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(source, index, thumbOptions as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, index, nil)
        }

        if !animated || count == 1 {
            guard let first = decodeFrame(0) else { return nil }
            return DecodedEmoteAsset(frames: [first], frameDurations: [0], animated: false)
        }

        let limit = min(count, max(2, maxFrames))
        var frames: [CGImage] = []
        var durations: [Double] = []
        frames.reserveCapacity(limit)
        durations.reserveCapacity(limit)

        for i in 0..<limit {
            guard let img = decodeFrame(i) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let delay = frameDelay(props, minimum: 1.0 / 30.0)
            frames.append(img)
            durations.append(delay)
        }
        guard !frames.isEmpty else { return nil }
        return DecodedEmoteAsset(frames: frames, frameDurations: durations, animated: frames.count > 1)
    }

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

    private struct PrefetchSummary: Sendable {
        let assets: [URL: DecodedEmoteAsset]
        let emoteCount: Int
        let animatedEmoteCount: Int
        let badgeCount: Int
    }

    /// Concurrently loads and decodes all unique 7TV/Twitch emotes (including zero-width overlays) and badges
    /// referenced by `log`, reading from `EmoteCache.shared` first so cached live-chat emotes decode instantly.
    private static func prefetchAssets(
        for log: RecordedChatLog,
        config: TwitchClipChatConfig,
        maxPixel: Int
    ) async -> PrefetchSummary {
        guard config.showEmotes || config.showBadges else {
            return PrefetchSummary(assets: [:], emoteCount: 0, animatedEmoteCount: 0, badgeCount: 0)
        }

        // Track URL -> (animated, isBadge)
        var requested: [URL: (animated: Bool, isBadge: Bool)] = [:]
        func register(_ url: URL, animated: Bool, isBadge: Bool) {
            if let existing = requested[url] {
                requested[url] = (
                    animated: existing.animated || animated,
                    isBadge: existing.isBadge && isBadge
                )
            } else if requested.count < 96 {
                requested[url] = (animated: animated, isBadge: isBadge)
            }
        }

        for entry in log.entries {
            if config.showBadges {
                for badge in entry.badges.prefix(3) {
                    register(badge.url, animated: badge.animated, isBadge: true)
                }
            }
            if config.showEmotes {
                for frag in entry.fragments {
                    switch frag {
                    case .emote(let e):
                        register(e.url, animated: e.animated, isBadge: false)
                    case .stack(let base, let overlays):
                        register(base.url, animated: base.animated, isBadge: false)
                        for over in overlays {
                            register(over.url, animated: over.animated, isBadge: false)
                        }
                    case .text, .mention, .link:
                        break
                    }
                }
            }
            if requested.count >= 96 { break }
        }

        guard !requested.isEmpty else {
            return PrefetchSummary(assets: [:], emoteCount: 0, animatedEmoteCount: 0, badgeCount: 0)
        }

        let work = Array(requested)
        var out: [URL: DecodedEmoteAsset] = [:]
        var emoteCount = 0
        var animatedEmoteCount = 0
        var badgeCount = 0

        await withTaskGroup(of: (URL, Bool, DecodedEmoteAsset?)?.self) { group in
            var nextIdx = 0
            let maxConcurrent = 6

            func enqueueNext() {
                guard nextIdx < work.count else { return }
                let (url, meta) = work[nextIdx]
                nextIdx += 1
                let px = meta.isBadge ? min(64, maxPixel) : maxPixel
                group.addTask {
                    guard let data = await EmoteCache.shared.data(for: url) else { return nil }
                    let decoded = Self.decodeAsset(data: data, animated: meta.animated, maxPixel: px)
                    return (url, meta.isBadge, decoded)
                }
            }

            for _ in 0..<min(maxConcurrent, work.count) {
                enqueueNext()
            }

            for await item in group {
                enqueueNext()
                guard let (url, isBadge, asset) = item, let asset else { continue }
                out[url] = asset
                if isBadge {
                    badgeCount += 1
                } else {
                    emoteCount += 1
                    if asset.isAnimated { animatedEmoteCount += 1 }
                }
            }
        }

        return PrefetchSummary(
            assets: out,
            emoteCount: emoteCount,
            animatedEmoteCount: animatedEmoteCount,
            badgeCount: badgeCount
        )
    }

    // MARK: - 1. Event-Driven Transparent Chat Overlay GIF (for Studio Lane 2 without rendering video)

    /// Generates a lightweight, transparent animated GIF (`image/gif`) whose per-frame delays match the
    /// exact arrival times of recorded chat messages (plus sync nudge, disconnect gap notices, and animated
    /// 7TV/Twitch emote stepping when animated emotes are on screen).
    /// Returns the pixel dimensions of the generated GIF.
    public static func renderChatGIF(
        log: RecordedChatLog,
        config: TwitchClipEditConfig,
        duration: Double,
        canvasSize: PixelSize = PixelSize(w: canvasWidth, h: canvasHeight),
        to url: URL
    ) async throws -> PixelSize {
        let clipDuration = max(0.5, duration)
        let chatRect = TwitchClipTimelineBridge.chatOverlayRect(for: config)
        // Render GIF at half of 1080p (~500px wide) so it stays crisp on phones while remaining compact.
        let targetW = max(160, min(540, Int((chatRect.w * Double(canvasSize.w) * 0.5).rounded()) & ~1))
        let targetH = max(80, min(420, Int((chatRect.h * Double(canvasSize.h) * 0.5).rounded()) & ~1))
        let size = CGSize(width: targetW, height: targetH)

        let prefetched = await prefetchAssets(for: log, config: config.chat, maxPixel: 72)
        let emoteAssets = prefetched.assets
        let maxLines = config.chat.placement == .band ? 4 : 6

        // Collect key timestamps where visible chat changes, subdividing intervals containing animated emotes
        // so animated 7TV/Twitch emotes also animate inside the Studio Lane 2 chat GIF.
        let baseKeyframes = buildChatKeyframes(log: log, config: config.chat, duration: clipDuration, maxFrames: 90)
        let keyframes = expandKeyframesForAnimation(
            baseKeyframes: baseKeyframes,
            log: log,
            config: config.chat,
            maxLines: maxLines,
            emoteAssets: emoteAssets,
            maxTotalFrames: 120
        )
        guard keyframes.count >= 2 else { throw TwitchClipRendererError.gifFailed }

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }

        let frameCount = keyframes.count - 1
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw TwitchClipRendererError.gifFailed
        }

        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        for i in 0..<frameCount {
            let t0 = keyframes[i]
            let t1 = keyframes[i + 1]
            let delay = max(0.05, t1 - t0)
            let sampleTime = t0 + 0.01
            let tt = sampleTime - config.chat.syncOffset
            let inGap = log.isInGap(at: tt)
            let lines = inGap ? [] : log.visibleEntries(at: sampleTime, syncOffset: config.chat.syncOffset, maxLines: maxLines)

            guard let cgImage = rasterizeChatOverlay(
                entries: lines,
                inGap: inGap,
                config: config.chat,
                size: size,
                at: sampleTime,
                emoteAssets: emoteAssets
            ) else {
                continue
            }
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                    kCGImagePropertyGIFDelayTime: delay,
                ],
            ]
            CGImageDestinationAddImage(dest, cgImage, frameProps as CFDictionary)
        }

        guard CGImageDestinationFinalize(dest) else {
            throw TwitchClipRendererError.gifFailed
        }
        return PixelSize(w: targetW, h: targetH)
    }

    /// Computes coalesced change timestamps across `[0, duration]` for event-driven GIF synthesis.
    public static func buildChatKeyframes(
        log: RecordedChatLog,
        config: TwitchClipChatConfig,
        duration: Double,
        maxFrames: Int = 90
    ) -> [Double] {
        let dur = max(0.5, duration)
        var raw: [Double] = [0, dur]
        let off = config.syncOffset
        for entry in log.entries {
            let appear = entry.t + off
            let expire = appear + 9.0
            if appear > 0.02 && appear < dur - 0.02 { raw.append(appear) }
            if expire > 0.02 && expire < dur - 0.02 { raw.append(expire) }
        }
        for gap in log.gaps {
            let s = gap.start + off
            let e = gap.end + off
            if s > 0.02 && s < dur - 0.02 { raw.append(s) }
            if e > 0.02 && e < dur - 0.02 { raw.append(e) }
        }
        raw.sort()

        let minGap = max(0.20, dur / Double(max(10, maxFrames)))
        var coalesced: [Double] = [0]
        for t in raw.dropFirst() {
            if t >= dur - 0.01 { continue }
            if t - coalesced[coalesced.count - 1] >= minGap {
                coalesced.append(t)
                if coalesced.count >= maxFrames { break }
            }
        }
        if let last = coalesced.last, dur - last < 0.05, coalesced.count > 1 {
            coalesced[coalesced.count - 1] = dur
        } else {
            coalesced.append(dur)
        }
        return coalesced
    }

    private static func expandKeyframesForAnimation(
        baseKeyframes: [Double],
        log: RecordedChatLog,
        config: TwitchClipChatConfig,
        maxLines: Int,
        emoteAssets: [URL: DecodedEmoteAsset],
        maxTotalFrames: Int
    ) -> [Double] {
        guard baseKeyframes.count >= 2,
              emoteAssets.values.contains(where: \.isAnimated) else {
            return baseKeyframes
        }
        let budget = max(0, maxTotalFrames - (baseKeyframes.count - 1))
        guard budget > 0 else { return baseKeyframes }

        // Measure total animated duration so we distribute subdivision ticks evenly within `budget`.
        var animatedSpan = 0.0
        var intervalHasAnim: [Bool] = []
        intervalHasAnim.reserveCapacity(baseKeyframes.count - 1)
        for i in 0..<(baseKeyframes.count - 1) {
            let t0 = baseKeyframes[i]
            let t1 = baseKeyframes[i + 1]
            let sample = t0 + 0.01
            let tt = sample - config.syncOffset
            let lines = log.isInGap(at: tt) ? [] : log.visibleEntries(at: sample, syncOffset: config.syncOffset, maxLines: maxLines)
            let hasAnim = entriesHaveAnimatedAsset(lines, config: config, emoteAssets: emoteAssets)
            intervalHasAnim.append(hasAnim)
            if hasAnim { animatedSpan += max(0, t1 - t0) }
        }
        guard animatedSpan > 0.1 else { return baseKeyframes }

        let step = max(0.10, animatedSpan / Double(budget))
        var expanded: [Double] = [baseKeyframes[0]]
        for i in 0..<(baseKeyframes.count - 1) {
            let t0 = baseKeyframes[i]
            let t1 = baseKeyframes[i + 1]
            if intervalHasAnim[i] && (t1 - t0) > step * 1.4 {
                var cursor = t0 + step
                while cursor < t1 - 0.05 && expanded.count < maxTotalFrames {
                    expanded.append(cursor)
                    cursor += step
                }
            }
            expanded.append(t1)
        }
        return expanded
    }

    private static func entriesHaveAnimatedAsset(
        _ entries: [RecordedChatEntry],
        config: TwitchClipChatConfig,
        emoteAssets: [URL: DecodedEmoteAsset]
    ) -> Bool {
        for entry in entries {
            if config.showBadges {
                for b in entry.badges.prefix(3) where b.animated {
                    if emoteAssets[b.url]?.isAnimated == true { return true }
                }
            }
            if config.showEmotes {
                for frag in entry.fragments {
                    switch frag {
                    case .emote(let e):
                        if e.animated && emoteAssets[e.url]?.isAnimated == true { return true }
                    case .stack(let base, let overlays):
                        if base.animated && emoteAssets[base.url]?.isAnimated == true { return true }
                        for over in overlays where over.animated {
                            if emoteAssets[over.url]?.isAnimated == true { return true }
                        }
                    case .text, .mention, .link:
                        break
                    }
                }
            }
        }
        return false
    }

    // MARK: - 2. Full 9:16 Split-Frame + Synced Chat MP4 Render

    /// Renders the final 9:16 `1080×1920` H.264/AAC MP4 with Region A / B split-frame and burned-in chat overlay
    /// featuring real animated & static 7TV/Twitch emotes, zero-width overlays, badges, and 7TV gradient paints.
    @discardableResult
    public static func renderCompositeMP4(
        videoURL: URL,
        log: RecordedChatLog,
        config: TwitchClipEditConfig,
        duration: Double,
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TwitchClipRenderStats {
        let renderStartedAt = ContinuousClock.now
        let asset = AVURLAsset(url: videoURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw TwitchClipRendererError.unreadableSource
        }
        let naturalSize = try await sourceVideo.load(.naturalSize)
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        let transformed = naturalSize.applying(preferredTransform)
        let srcW = max(2.0, abs(Double(transformed.width)))
        let srcH = max(2.0, abs(Double(transformed.height)))
        let sourceAspect = srcW / srcH

        let assetDuration = try await asset.load(.duration).seconds
        let totalDuration = max(0.5, min(duration > 0 ? duration : assetDuration, assetDuration > 0 ? assetDuration : duration))

        let prefetched: PrefetchSummary
        if config.chat.enabled {
            prefetched = await prefetchAssets(for: log, config: config.chat, maxPixel: 128)
        } else {
            prefetched = PrefetchSummary(assets: [:], emoteCount: 0, animatedEmoteCount: 0, badgeCount: 0)
        }
        let emoteAssets = prefetched.assets

        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) { try? fm.removeItem(at: outputURL) }

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw TwitchClipRendererError.cannotCreateWriter(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        // Video reader (BGRA pixel buffers for Core Image)
        let videoReaderOutput = AVAssetReaderTrackOutput(
            track: sourceVideo,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoReaderOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReaderOutput) else {
            throw TwitchClipRendererError.unreadableSource
        }
        reader.add(videoReaderOutput)

        // Video writer (1080×1920 H.264)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: canvasWidth,
            AVVideoHeightKey: canvasHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: renderFPS,
            ],
        ]
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoWriterInput) else {
            throw TwitchClipRendererError.cannotCreateWriter("cannot add H.264 video input")
        }
        writer.add(videoWriterInput)

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: canvasWidth,
            kCVPixelBufferHeightKey as String: canvasHeight,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )

        // Optional audio reader + writer (PCM -> AAC 128 kbps stereo)
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var audioWriterInput: AVAssetWriterInput?
        if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
            let aOut = AVAssetReaderTrackOutput(
                track: sourceAudio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            let aIn = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ]
            )
            aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(aOut) && writer.canAdd(aIn) {
                reader.add(aOut)
                writer.add(aIn)
                audioReaderOutput = aOut
                audioWriterInput = aIn
            }
        }

        guard reader.startReading() else {
            throw TwitchClipRendererError.exportFailed(reader.error?.localizedDescription ?? "reader failed to start")
        }
        guard writer.startWriting() else {
            throw TwitchClipRendererError.exportFailed(writer.error?.localizedDescription ?? "writer failed to start")
        }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let outW = Double(canvasWidth)
        let outH = Double(canvasHeight)
        let slots = TwitchClipTimelineBridge.slots(for: config)
        let chatBox = TwitchClipTimelineBridge.chatOverlayRect(for: config)
        let maxLines = config.chat.placement == .band ? 4 : 6

        var cachedChatKey: String?
        var cachedChatImage: CIImage?
        var overlayRasterizations = 0
        var lastProgress = -1.0

        // Interleave audio alongside video so AVAssetWriter never stalls waiting for earlier audio samples.
        var pendingAudio: CMSampleBuffer?
        var audioEOF = (audioReaderOutput == nil || audioWriterInput == nil)

        func drainAudio(upTo targetSeconds: Double?) {
            guard !audioEOF, let aOut = audioReaderOutput, let aIn = audioWriterInput else { return }
            while writer.status == .writing && aIn.isReadyForMoreMediaData {
                let sample: CMSampleBuffer
                if let buffered = pendingAudio {
                    sample = buffered
                    pendingAudio = nil
                } else if let next = aOut.copyNextSampleBuffer() {
                    sample = next
                } else {
                    audioEOF = true
                    aIn.markAsFinished()
                    return
                }
                if let limit = targetSeconds {
                    let aSec = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if aSec.isFinite && aSec > limit {
                        pendingAudio = sample
                        return
                    }
                }
                _ = aIn.append(sample)
            }
        }

        // Process video frames (interleaving audio chunks within 0.5 s of video PTS)
        while let sampleBuffer = videoReaderOutput.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let t = max(0, pts.seconds)

            let srcCI = CIImage(cvPixelBuffer: pixelBuffer)
            let srcExtent = srcCI.extent
            var composite = CIImage(color: CIColor(red: 0.043, green: 0.043, blue: 0.043, alpha: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))

            // Draw each slot (Region B, then Region A / PiP)
            for slot in slots {
                let cropNorm = TwitchClipTimelineBridge.cropRect(
                    for: slot.region,
                    config: config,
                    sourceAspect: sourceAspect
                )
                // CoreImage origin is bottom-left (y up), while our normalized rect is top-left (y down).
                let cropX = srcExtent.minX + cropNorm.x * srcExtent.width
                let cropW = max(2.0, cropNorm.w * srcExtent.width)
                let cropH = max(2.0, cropNorm.h * srcExtent.height)
                let cropY = srcExtent.maxY - (cropNorm.y + cropNorm.h) * srcExtent.height
                let cropCGRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH).intersection(srcExtent)
                guard cropCGRect.width >= 2, cropCGRect.height >= 2 else { continue }

                let destX = slot.rect.x * outW
                let destW = max(2.0, slot.rect.w * outW)
                let destH = max(2.0, slot.rect.h * outH)
                let destY = outH - (slot.rect.y + slot.rect.h) * outH
                let destRect = CGRect(x: destX, y: destY, width: destW, height: destH)

                let cropped = srcCI.cropped(to: cropCGRect)
                let sx = destW / cropCGRect.width
                let sy = destH / cropCGRect.height
                let positioned = cropped
                    .transformed(by: CGAffineTransform(translationX: -cropCGRect.minX, y: -cropCGRect.minY))
                    .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                    .transformed(by: CGAffineTransform(translationX: destRect.minX, y: destRect.minY))
                    .cropped(to: destRect)

                if slot.isPiP {
                    let masked = roundedPiP(positioned, in: destRect, radius: 28)
                    composite = masked.composited(over: composite)
                } else {
                    composite = positioned.composited(over: composite)
                }
            }

            // Composite chat overlay (re-rasterized whenever visible messages OR any visible animated emote frame changes)
            if config.chat.enabled {
                let tt = t - config.chat.syncOffset
                let inGap = log.isInGap(at: tt)
                let visible = inGap ? [] : log.visibleEntries(at: t, syncOffset: config.chat.syncOffset, maxLines: maxLines)
                let key = overlayCacheKey(
                    inGap: inGap,
                    entries: visible,
                    config: config.chat,
                    at: t,
                    emoteAssets: emoteAssets
                )
                if key != cachedChatKey {
                    cachedChatKey = key
                    let chatW = max(120, Int((chatBox.w * outW).rounded()))
                    let chatH = max(80, Int((chatBox.h * outH).rounded()))
                    if let cg = rasterizeChatOverlay(
                        entries: visible,
                        inGap: inGap,
                        config: config.chat,
                        size: CGSize(width: chatW, height: chatH),
                        at: t,
                        emoteAssets: emoteAssets
                    ) {
                        overlayRasterizations += 1
                        let chatDestX = chatBox.x * outW
                        let chatDestY = outH - (chatBox.y + chatBox.h) * outH
                        cachedChatImage = CIImage(cgImage: cg)
                            .transformed(by: CGAffineTransform(translationX: chatDestX, y: chatDestY))
                    } else {
                        cachedChatImage = nil
                    }
                }
                if let chatCI = cachedChatImage {
                    composite = chatCI.composited(over: composite)
                }
            }

            // Interleave audio up to t + 0.5s before waiting on video input
            drainAudio(upTo: t + 0.5)

            while !videoWriterInput.isReadyForMoreMediaData && writer.status == .writing {
                drainAudio(upTo: t + 0.5)
                try? await Task.sleep(for: .milliseconds(2))
            }
            guard writer.status == .writing else { break }
            guard let pool = adaptor.pixelBufferPool else { continue }
            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer)
            guard let dstBuffer = outBuffer else { continue }
            ciContext.render(
                composite,
                to: dstBuffer,
                bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                colorSpace: colorSpace
            )
            adaptor.append(dstBuffer, withPresentationTime: pts)

            let pct = min(0.95, max(0, t / totalDuration))
            if pct - lastProgress >= 0.03 {
                lastProgress = pct
                progress?(pct)
            }
        }
        videoWriterInput.markAsFinished()

        // Drain any remaining audio samples after video completes
        if !audioEOF, let audioWriterInput {
            while !audioEOF && writer.status == .writing {
                drainAudio(upTo: nil)
                if !audioEOF && !audioWriterInput.isReadyForMoreMediaData {
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
            if !audioEOF {
                audioWriterInput.markAsFinished()
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TwitchClipRendererError.exportFailed(writer.error?.localizedDescription ?? "MP4 render failed")
        }
        progress?(1.0)

        let elapsed = renderStartedAt.duration(to: .now)
        let renderMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let stats = TwitchClipRenderStats(
            renderMs: max(0, renderMs),
            chatEntries: log.entries.count,
            emotesPrefetched: prefetched.emoteCount,
            animatedEmotes: prefetched.animatedEmoteCount,
            badgesPrefetched: prefetched.badgeCount,
            overlayRasterizations: overlayRasterizations
        )
        Telemetry.log(.info, .live, "twitch.clip.render", data: [
            "render_ms": .int(stats.renderMs),
            "chat_entries": .int(stats.chatEntries),
            "emotes": .int(stats.emotesPrefetched),
            "animated_emotes": .int(stats.animatedEmotes),
            "badges": .int(stats.badgesPrefetched),
            "overlay_frames": .int(stats.overlayRasterizations),
        ])
        return stats
    }

    /// Computes a deterministic cache key for the chat overlay at timestamp `time`, incorporating both visible
    /// entry IDs and the active frame index of every currently visible animated emote/badge.
    public static func overlayCacheKey(
        inGap: Bool,
        entries: [RecordedChatEntry],
        config: TwitchClipChatConfig,
        at time: Double,
        emoteAssets: [URL: DecodedEmoteAsset]
    ) -> String {
        if inGap { return "gap" }
        var parts: [String] = []
        parts.reserveCapacity(entries.count * 2)
        for entry in entries {
            parts.append(entry.id)
            if config.showBadges {
                for badge in entry.badges.prefix(3) where badge.animated {
                    if let asset = emoteAssets[badge.url], asset.isAnimated {
                        parts.append("b\(asset.frameIndex(at: time))")
                    }
                }
            }
            if config.showEmotes {
                for frag in entry.fragments {
                    switch frag {
                    case .emote(let e):
                        if e.animated, let asset = emoteAssets[e.url], asset.isAnimated {
                            parts.append("e\(asset.frameIndex(at: time))")
                        }
                    case .stack(let base, let overlays):
                        if base.animated, let asset = emoteAssets[base.url], asset.isAnimated {
                            parts.append("e\(asset.frameIndex(at: time))")
                        }
                        for over in overlays where over.animated {
                            if let asset = emoteAssets[over.url], asset.isAnimated {
                                parts.append("o\(asset.frameIndex(at: time))")
                            }
                        }
                    case .text, .mention, .link:
                        break
                    }
                }
            }
        }
        return parts.joined(separator: ",")
    }

    // MARK: - CoreGraphics Chat Overlay Rasterizer

    /// Draws the chat overlay box (Liquid Glass pills, Clear Text with crisp shadow, or solid bottom Band)
    /// into a transparent RGBA `CGImage` with real inline 7TV/Twitch emotes (static or frame-accurate animated),
    /// zero-width emote stacks, badges, and 7TV gradient paints.
    public static func rasterizeChatOverlay(
        entries: [RecordedChatEntry],
        inGap: Bool,
        config: TwitchClipChatConfig,
        size: CGSize,
        at time: Double = 0,
        emoteAssets: [URL: DecodedEmoteAsset] = [:]
    ) -> CGImage? {
        let w = max(2, Int(size.width.rounded()))
        let h = max(2, Int(size.height.rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        let isBand = config.placement == .band
        if isBand {
            ctx.setFillColor(CGColor(red: 0.043, green: 0.043, blue: 0.043, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // Subtle top separator line
            ctx.setFillColor(CGColor(red: 0.22, green: 0.22, blue: 0.22, alpha: 1))
            ctx.fill(CGRect(x: 0, y: CGFloat(h) - 1.5, width: CGFloat(w), height: 1.5))
        }

        let baseFontSize = max(13.0, min(42.0, Double(w) * 0.036 * config.scale))
        let padX = CGFloat(w) * (isBand ? 0.04 : 0.025)
        let padY = CGFloat(h) * 0.04
        let lineSpacing = CGFloat(baseFontSize) * 0.34
        let pillPadX = CGFloat(baseFontSize) * 0.60
        let pillPadY = CGFloat(baseFontSize) * 0.30
        let maxTextWidth = max(60, CGFloat(w) - padX * 2 - (config.look == .liquidGlass && !isBand ? pillPadX * 2 : 0))

        struct RenderedRow {
            let framesetter: CTFramesetter
            let textSize: CGSize
            let boxSize: CGSize
            let isPill: Bool
        }

        let itemsToDraw: [(attr: NSAttributedString, isNotice: Bool)]
        if inGap {
            let noticeFont = CTFontCreateWithName("HelveticaNeue" as CFString, CGFloat(baseFontSize * 0.92), nil)
            let attr = NSAttributedString(string: "chat was not recorded here", attributes: [
                kCTFontAttributeName as NSAttributedString.Key: noticeFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 1, green: 1, blue: 1, alpha: 0.72),
            ])
            itemsToDraw = [(attr, true)]
        } else {
            itemsToDraw = entries.map { entry in
                (
                    buildAttributedLine(
                        entry: entry,
                        config: config,
                        fontSize: CGFloat(baseFontSize),
                        at: time,
                        emoteAssets: emoteAssets
                    ),
                    false
                )
            }
        }

        let usePill = config.look == .liquidGlass && !isBand
        var rows: [RenderedRow] = []
        for item in itemsToDraw {
            let fs = CTFramesetterCreateWithAttributedString(item.attr)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                fs, CFRange(location: 0, length: 0), nil,
                CGSize(width: maxTextWidth, height: CGFloat(h) * 0.5),
                nil
            )
            let tw = ceil(min(maxTextWidth, max(20, suggested.width)))
            let th = ceil(max(CGFloat(baseFontSize * 1.25), suggested.height))
            let bw = usePill ? min(CGFloat(w) - padX * 2, tw + pillPadX * 2) : tw
            let bh = usePill ? th + pillPadY * 2 : th
            rows.append(RenderedRow(framesetter: fs, textSize: CGSize(width: tw, height: th), boxSize: CGSize(width: bw, height: bh), isPill: usePill))
        }

        // Bottom-aligned stack (in CG coordinates, y = 0 is bottom, so start at padY and walk upward from newest -> oldest!)
        var yCursor = padY
        for row in rows.reversed() {
            if yCursor + row.boxSize.height > CGFloat(h) - padY * 0.5 {
                break
            }
            let boxRect = CGRect(x: padX, y: yCursor, width: row.boxSize.width, height: row.boxSize.height)
            if row.isPill {
                let radius = min(row.boxSize.height * 0.45, CGFloat(baseFontSize) * 0.85)
                let pillPath = CGPath(roundedRect: boxRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                ctx.saveGState()
                ctx.addPath(pillPath)
                ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 0.58))
                ctx.fillPath()
                ctx.addPath(pillPath)
                ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.24))
                ctx.setLineWidth(max(1.0, CGFloat(baseFontSize) * 0.055))
                ctx.strokePath()
                ctx.restoreGState()
            }

            let textRect = CGRect(
                x: boxRect.minX + (row.isPill ? pillPadX : 0),
                y: boxRect.minY + (row.isPill ? pillPadY : 0),
                width: row.textSize.width + 2,
                height: row.textSize.height + 2
            )
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(row.framesetter, CFRange(location: 0, length: 0), path, nil)

            ctx.saveGState()
            if !row.isPill {
                ctx.setShadow(
                    offset: CGSize(width: 0, height: -1.5),
                    blur: 4.5,
                    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.92)
                )
            }
            CTFrameDraw(frame, ctx)
            drawInlineRuns(in: frame, textRect: textRect, ctx: ctx, colorSpace: colorSpace)
            ctx.restoreGState()

            yCursor += row.boxSize.height + lineSpacing
        }

        return ctx.makeImage()
    }

    private static func drawInlineRuns(
        in frame: CTFrame,
        textRect: CGRect,
        ctx: CGContext,
        colorSpace: CGColorSpace
    ) {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        for (lineIdx, line) in lines.enumerated() {
            let lineOrigin = origins[lineIdx]
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            for run in runs {
                let attrs = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]

                // 1. 7TV gradient paint overlay on username runs
                if let paintBox = attrs[paintGradientKey] as? PaintBox, paintBox.paint.stops.count >= 2 {
                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    var leading: CGFloat = 0
                    let runWidth = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, &leading))
                    let range = CTRunGetStringRange(run)
                    let xOffset = CTLineGetOffsetForStringIndex(line, range.location, nil)
                    let runRect = CGRect(
                        x: textRect.minX + lineOrigin.x + xOffset,
                        y: textRect.minY + lineOrigin.y - descent,
                        width: max(1, runWidth),
                        height: max(1, ascent + descent)
                    )
                    drawPaintedRun(
                        run: run,
                        paint: paintBox.paint,
                        lineOrigin: CGPoint(x: textRect.minX + lineOrigin.x, y: textRect.minY + lineOrigin.y),
                        bounds: runRect,
                        ctx: ctx,
                        colorSpace: colorSpace
                    )
                }

                // 2. Inline bitmap attachments (badges, 7TV/Twitch emotes, and zero-width overlay stacks)
                if let attachment = attrs[inlineAttachmentKey] as? InlineAttachment {
                    let range = CTRunGetStringRange(run)
                    let xOffset = CTLineGetOffsetForStringIndex(line, range.location, nil)
                    let slotRect = CGRect(
                        x: textRect.minX + lineOrigin.x + xOffset,
                        y: textRect.minY + lineOrigin.y - attachment.descent,
                        width: attachment.width,
                        height: attachment.ascent + attachment.descent
                    )
                    ctx.saveGState()
                    ctx.interpolationQuality = .high
                    for (idx, layer) in attachment.images.enumerated() {
                        let drawRect: CGRect
                        if idx == 0 {
                            drawRect = aspectFitRect(aspect: layer.aspect, inside: slotRect)
                        } else {
                            // Zero-width overlay centered over the base emote
                            let overlayH = slotRect.height
                            let overlayW = min(slotRect.width * 1.35, overlayH * layer.aspect)
                            let target = CGRect(
                                x: slotRect.midX - overlayW / 2,
                                y: slotRect.midY - overlayH / 2,
                                width: overlayW,
                                height: overlayH
                            )
                            drawRect = aspectFitRect(aspect: layer.aspect, inside: target)
                        }
                        ctx.draw(layer.image, in: drawRect)
                    }
                    ctx.restoreGState()
                }
            }
        }
    }

    private static func drawPaintedRun(
        run: CTRun,
        paint: RecordedChatPaint,
        lineOrigin: CGPoint,
        bounds: CGRect,
        ctx: CGContext,
        colorSpace: CGColorSpace
    ) {
        let sortedStops = paint.stops.sorted { $0.at < $1.at }
        let colors = sortedStops.map { rgbaColor($0.rgba) } as CFArray
        var locations = sortedStops.map { CGFloat(max(0, min(1, $0.at))) }
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: &locations) else { return }

        // CSS angle: 0 points up, 90 points right
        let rad = paint.angle * .pi / 180.0
        let dx = CGFloat(sin(rad)) * bounds.width * 0.5
        let dy = CGFloat(cos(rad)) * bounds.height * 0.5
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let start = CGPoint(x: center.x - dx, y: center.y - dy)
        let end = CGPoint(x: center.x + dx, y: center.y + dy)

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.textMatrix = .identity
        ctx.textPosition = lineOrigin
        ctx.setTextDrawingMode(.clip)
        CTRunDraw(run, ctx, CFRange(location: 0, length: 0))
        ctx.drawLinearGradient(
            gradient,
            start: start,
            end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }

    private static func aspectFitRect(aspect: CGFloat, inside bounds: CGRect) -> CGRect {
        let safeAspect = max(0.25, min(4.0, aspect))
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let boxAspect = bounds.width / bounds.height
        if safeAspect >= boxAspect {
            let h = bounds.width / safeAspect
            return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
        } else {
            let w = bounds.height * safeAspect
            return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: bounds.height)
        }
    }

    private static func appendInlineAttachment(
        _ attachment: InlineAttachment,
        to out: NSMutableAttributedString,
        font: CTFont
    ) {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { refCon in
                Unmanaged<InlineAttachment>.fromOpaque(refCon).release()
            },
            getAscent: { refCon in
                Unmanaged<InlineAttachment>.fromOpaque(refCon).takeUnretainedValue().ascent
            },
            getDescent: { refCon in
                Unmanaged<InlineAttachment>.fromOpaque(refCon).takeUnretainedValue().descent
            },
            getWidth: { refCon in
                Unmanaged<InlineAttachment>.fromOpaque(refCon).takeUnretainedValue().width
            }
        )
        let refCon = Unmanaged.passRetained(attachment).toOpaque()
        guard let delegate = CTRunDelegateCreate(&callbacks, refCon) else {
            Unmanaged<InlineAttachment>.fromOpaque(refCon).release()
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTRunDelegateAttributeName as NSAttributedString.Key: delegate,
            inlineAttachmentKey: attachment,
        ]
        out.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
    }

    private static func buildAttributedLine(
        entry: RecordedChatEntry,
        config: TwitchClipChatConfig,
        fontSize: CGFloat,
        at time: Double,
        emoteAssets: [URL: DecodedEmoteAsset]
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let boldFont = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let regularFont = CTFontCreateWithName("HelveticaNeue" as CFString, fontSize, nil)
        let spacerFont = CTFontCreateWithName("HelveticaNeue" as CFString, fontSize * 0.45, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 0.96)
        let colonColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.65)

        func appendSpace() {
            out.append(NSAttributedString(string: " ", attributes: [
                kCTFontAttributeName as NSAttributedString.Key: regularFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: white,
            ]))
        }

        func appendTightSpace() {
            out.append(NSAttributedString(string: " ", attributes: [
                kCTFontAttributeName as NSAttributedString.Key: spacerFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: white,
            ]))
        }

        // 1. Badges (real bitmap when fetched, compact colored glyph fallback otherwise)
        if config.showBadges && !entry.badges.isEmpty {
            let badgeFont = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize * 0.72, nil)
            let badgeH = fontSize * 1.05
            for badge in entry.badges.prefix(3) {
                if let asset = emoteAssets[badge.url] {
                    let img = badge.animated ? asset.frame(at: time) : asset.frames[0]
                    let aspect = CGFloat(max(0.5, min(2.0, asset.aspect)))
                    let attachment = InlineAttachment(
                        width: badgeH * aspect,
                        ascent: badgeH * 0.80,
                        descent: badgeH * 0.20,
                        images: [(img, aspect)]
                    )
                    appendInlineAttachment(attachment, to: out, font: regularFont)
                    appendTightSpace()
                } else {
                    let tag = badgeSymbol(for: badge)
                    out.append(NSAttributedString(string: "\(tag) ", attributes: [
                        kCTFontAttributeName as NSAttributedString.Key: badgeFont,
                        kCTForegroundColorAttributeName as NSAttributedString.Key: badgeColor(for: badge),
                    ]))
                }
            }
        }

        // 2. Username colored with 7TV paint gradient (when enabled) or Twitch user color
        let nameColor = resolvedNameColor(entry: entry, usePaint: config.showPaints)
        var nameAttrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: boldFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key: nameColor,
        ]
        if config.showPaints, let paint = entry.paint, paint.stops.count >= 2 {
            nameAttrs[paintGradientKey] = PaintBox(paint)
        }
        out.append(NSAttributedString(string: entry.displayName, attributes: nameAttrs))
        if entry.isAction {
            appendSpace()
        } else {
            out.append(NSAttributedString(string: ": ", attributes: [
                kCTFontAttributeName as NSAttributedString.Key: regularFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: colonColor,
            ]))
        }

        // 3. Message fragments (real inline 7TV/Twitch emotes & zero-width stacks + space-preserving text)
        let bodyColor = entry.isAction ? nameColor : white
        let emoteH = fontSize * 1.38
        var needsSpace = false

        func appendTextRun(_ text: String, bold: Bool = false) {
            guard !text.isEmpty else { return }
            if needsSpace, let first = text.first, !first.isWhitespace {
                appendSpace()
            }
            out.append(NSAttributedString(string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: bold ? boldFont : regularFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: bodyColor,
            ]))
            needsSpace = text.last.map { !$0.isWhitespace } ?? false
        }

        func appendEmoteStack(base: RecordedChatEmote, overlays: [RecordedChatEmote]) {
            guard config.showEmotes else {
                let names = ([base.name] + overlays.map(\.name)).joined(separator: " ")
                appendTextRun(names)
                return
            }
            guard let baseAsset = emoteAssets[base.url] else {
                let names = ([base.name] + overlays.map(\.name)).joined(separator: " ")
                appendTextRun(names)
                return
            }
            if needsSpace { appendSpace() }
            let baseImg = base.animated ? baseAsset.frame(at: time) : baseAsset.frames[0]
            let resolvedAspect = CGFloat(max(0.5, min(4.0, base.aspect > 0.1 ? base.aspect : baseAsset.aspect)))
            var layers: [(CGImage, CGFloat)] = [(baseImg, resolvedAspect)]
            for over in overlays {
                if let overAsset = emoteAssets[over.url] {
                    let overImg = over.animated ? overAsset.frame(at: time) : overAsset.frames[0]
                    let overAspect = CGFloat(max(0.5, min(4.0, over.aspect > 0.1 ? over.aspect : overAsset.aspect)))
                    layers.append((overImg, overAspect))
                }
            }
            let attachment = InlineAttachment(
                width: emoteH * resolvedAspect,
                ascent: emoteH * 0.76,
                descent: emoteH * 0.24,
                images: layers
            )
            appendInlineAttachment(attachment, to: out, font: regularFont)
            needsSpace = true
        }

        // Collapse any standalone zero-width `.emote` onto its preceding base emote before drawing.
        var idx = 0
        while idx < entry.fragments.count {
            let frag = entry.fragments[idx]
            switch frag {
            case .text(let s):
                appendTextRun(s)
                idx += 1
            case .emote(let e):
                var overlays: [RecordedChatEmote] = []
                var nextIdx = idx + 1
                while nextIdx < entry.fragments.count {
                    if case .emote(let nextEmote) = entry.fragments[nextIdx], nextEmote.zeroWidth {
                        overlays.append(nextEmote)
                        nextIdx += 1
                    } else {
                        break
                    }
                }
                appendEmoteStack(base: e, overlays: overlays)
                idx = nextIdx
            case .stack(let base, let overlays):
                appendEmoteStack(base: base, overlays: overlays)
                idx += 1
            case .mention(let m):
                appendTextRun("@\(m)", bold: true)
                idx += 1
            case .link(let u):
                appendTextRun(u.host() ?? u.absoluteString)
                idx += 1
            }
        }

        return out
    }

    private static func resolvedNameColor(entry: RecordedChatEntry, usePaint: Bool) -> CGColor {
        if usePaint, let paint = entry.paint {
            if let firstStop = paint.stops.first {
                return rgbaColor(firstStop.rgba)
            }
            if let plain = paint.color {
                return rgbaColor(plain)
            }
        }
        let rgb = entry.resolvedColorRGB
        return CGColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    private static func rgbaColor(_ rgba: UInt32) -> CGColor {
        CGColor(
            red: CGFloat((rgba >> 24) & 0xFF) / 255.0,
            green: CGFloat((rgba >> 16) & 0xFF) / 255.0,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    private static func badgeSymbol(for badge: RecordedChatBadge) -> String {
        let lower = badge.title.lowercased()
        if lower.contains("broadcaster") { return "●" }
        if lower.contains("mod") { return "◆" }
        if lower.contains("vip") { return "✦" }
        return "★"
    }

    private static func badgeColor(for badge: RecordedChatBadge) -> CGColor {
        let lower = badge.title.lowercased()
        if lower.contains("broadcaster") { return CGColor(red: 0.93, green: 0.14, blue: 0.21, alpha: 1) }
        if lower.contains("mod") { return CGColor(red: 0.0, green: 0.68, blue: 0.01, alpha: 1) }
        if lower.contains("vip") { return CGColor(red: 0.88, green: 0.02, blue: 0.73, alpha: 1) }
        return CGColor(red: 0.65, green: 0.48, blue: 1.0, alpha: 1)
    }

    private static func roundedPiP(_ image: CIImage, in rect: CGRect, radius: CGFloat) -> CIImage {
        guard let mask = makeRoundedRectMask(rect: rect, radius: radius) else { return image }
        let clear = CIImage.empty().cropped(to: rect)
        guard let filter = CIFilter(name: "CIBlendWithAlphaMask") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(clear, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        return filter.outputImage?.cropped(to: rect) ?? image
    }

    private static func makeRoundedRectMask(rect: CGRect, radius: CGFloat) -> CIImage? {
        let w = max(2, Int(rect.width.rounded()))
        let h = max(2, Int(rect.height.rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

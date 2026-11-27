@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Off-main rendering engine for Twitch clip drafts (iOS & macOS):
// 1. `renderChatGIF`: produces a compact, event-driven transparent animated GIF (`image/gif`) so
//    "Send to Studio (without rendering)" can carry synced chat onto Lane 2 of Cobalt Studio without
//    transcoding the 16:9 video!
// 2. `renderCompositeMP4`: renders the final 9:16 1080×1920 H.264/AAC MP4 with Region A / B split-frame
//    and burned-in chat overlay for direct Private Library export.

public enum TwitchClipRendererError: Error, Sendable, Equatable {
    case unreadableSource
    case cannotCreateWriter(String)
    case exportFailed(String)
    case gifFailed
}

public enum TwitchClipRenderer {
    public static let canvasWidth = 1080
    public static let canvasHeight = 1920
    public static let renderFPS = 30

    // MARK: - 1. Event-Driven Transparent Chat Overlay GIF (for Studio Lane 2 without rendering video)

    /// Generates a lightweight, transparent animated GIF (`image/gif`) whose per-frame delays match the
    /// exact arrival times of recorded chat messages (plus sync nudge and disconnect gap notices).
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
        // Render GIF at half of 1080p (~500px wide) so it stays crisp on phones while remaining <200 KB.
        let targetW = max(160, min(540, Int((chatRect.w * Double(canvasSize.w) * 0.5).rounded()) & ~1))
        let targetH = max(80, min(420, Int((chatRect.h * Double(canvasSize.h) * 0.5).rounded()) & ~1))
        let size = CGSize(width: targetW, height: targetH)

        // Pre-fetch remote emote/badge bitmaps (best-effort, short timeout) so rendered chat shows real emotes!
        let emoteImages = await prefetchImages(for: log, config: config.chat)

        // Collect key timestamps where visible chat changes (coalesced to >= 0.2s apart, capped at 90 frames).
        let keyframes = buildChatKeyframes(log: log, config: config.chat, duration: clipDuration, maxFrames: 90)
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

        let maxLines = config.chat.placement == .band ? 4 : 6
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
                emoteImages: emoteImages
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

    // MARK: - 2. Full 9:16 Split-Frame + Synced Chat MP4 Render

    /// Renders the final 9:16 `1080×1920` H.264/AAC MP4 with Region A / B split-frame and rendered chat overlay.
    public static func renderCompositeMP4(
        videoURL: URL,
        log: RecordedChatLog,
        config: TwitchClipEditConfig,
        duration: Double,
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
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

        let emoteImages = config.chat.enabled ? await prefetchImages(for: log, config: config.chat) : [:]

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
        var lastProgress = -1.0

        // Process video frames
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

            // Composite chat overlay (re-rasterized only when visible messages change)
            if config.chat.enabled {
                let tt = t - config.chat.syncOffset
                let inGap = log.isInGap(at: tt)
                let visible = inGap ? [] : log.visibleEntries(at: t, syncOffset: config.chat.syncOffset, maxLines: maxLines)
                let key = "\(inGap)|" + visible.map(\.id).joined(separator: ",")
                if key != cachedChatKey {
                    cachedChatKey = key
                    let chatW = max(120, Int((chatBox.w * outW).rounded()))
                    let chatH = max(80, Int((chatBox.h * outH).rounded()))
                    if let cg = rasterizeChatOverlay(
                        entries: visible,
                        inGap: inGap,
                        config: config.chat,
                        size: CGSize(width: chatW, height: chatH),
                        emoteImages: emoteImages
                    ) {
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

            while !videoWriterInput.isReadyForMoreMediaData && writer.status == .writing {
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

        // Process audio samples
        if let audioReaderOutput, let audioWriterInput {
            while let sb = audioReaderOutput.copyNextSampleBuffer() {
                while !audioWriterInput.isReadyForMoreMediaData && writer.status == .writing {
                    try? await Task.sleep(for: .milliseconds(2))
                }
                guard writer.status == .writing else { break }
                audioWriterInput.append(sb)
            }
            audioWriterInput.markAsFinished()
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TwitchClipRendererError.exportFailed(writer.error?.localizedDescription ?? "MP4 render failed")
        }
        progress?(1.0)
    }

    // MARK: - CoreGraphics Chat Overlay Rasterizer

    /// Draws the chat overlay box (Liquid Glass pills, Clear Text with crisp shadow, or solid bottom Band)
    /// into a transparent RGBA `CGImage` ready for both animated GIF and MP4 compositing.
    public static func rasterizeChatOverlay(
        entries: [RecordedChatEntry],
        inGap: Bool,
        config: TwitchClipChatConfig,
        size: CGSize,
        emoteImages: [URL: CGImage] = [:]
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

        // Flip to top-left origin for intuitive layout, then draw text unflipped per-line.
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
                (buildAttributedLine(entry: entry, config: config, fontSize: CGFloat(baseFontSize)), false)
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
            let th = ceil(max(CGFloat(baseFontSize * 1.15), suggested.height))
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
            ctx.restoreGState()

            yCursor += row.boxSize.height + lineSpacing
        }

        _ = emoteImages // reserved for future inline bitmap attachment runs
        return ctx.makeImage()
    }

    private static func buildAttributedLine(
        entry: RecordedChatEntry,
        config: TwitchClipChatConfig,
        fontSize: CGFloat
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let boldFont = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let regularFont = CTFontCreateWithName("HelveticaNeue" as CFString, fontSize, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 0.96)

        // Optional compact badge tag indicators
        if config.showBadges && !entry.badges.isEmpty {
            let badgeFont = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize * 0.72, nil)
            for badge in entry.badges.prefix(2) {
                let tag = badgeSymbol(for: badge)
                out.append(NSAttributedString(string: "\(tag) ", attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: badgeFont,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: badgeColor(for: badge),
                ]))
            }
        }

        // Username colored with 7TV paint accent (if enabled) or Twitch user color
        let nameColor = resolvedNameColor(entry: entry, usePaint: config.showPaints)
        out.append(NSAttributedString(string: "\(entry.displayName) ", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: boldFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key: nameColor,
        ]))

        // Message fragments
        let bodyColor = entry.isAction ? nameColor : white
        var bodyParts: [String] = []
        for frag in entry.fragments {
            switch frag {
            case .text(let s):
                bodyParts.append(s)
            case .emote(let e):
                bodyParts.append(config.showEmotes ? "[\(e.name)]" : e.name)
            case .stack(let base, let overlays):
                let joined = ([base.name] + overlays.map(\.name)).joined(separator: "+")
                bodyParts.append(config.showEmotes ? "[\(joined)]" : joined)
            case .mention(let m):
                bodyParts.append("@\(m)")
            case .link(let u):
                bodyParts.append(u.host() ?? u.absoluteString)
            }
        }
        let body = bodyParts.joined()
        if !body.isEmpty {
            out.append(NSAttributedString(string: body, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: regularFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: bodyColor,
            ]))
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

    private static func prefetchImages(for log: RecordedChatLog, config: TwitchClipChatConfig) async -> [URL: CGImage] {
        guard config.showEmotes else { return [:] }
        var urls: Set<URL> = []
        for entry in log.entries {
            for frag in entry.fragments {
                if case .emote(let e) = frag { urls.insert(e.url) }
                if case .stack(let base, _) = frag { urls.insert(base.url) }
            }
            if urls.count >= 24 { break }
        }
        guard !urls.isEmpty else { return [:] }
        var out: [URL: CGImage] = [:]
        let session = URLSession.shared
        for url in urls.prefix(16) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            guard let (data, _) = try? await session.data(for: req),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { continue }
            out[url] = img
        }
        return out
    }
}

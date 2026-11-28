import Foundation

// Pure, deterministic split-frame geometry and Cobalt Studio Editor v2 timeline bridge.
//
// Matches Fable's approved mockup math:
// - Aspect-locked Region A & B boxes on the 16:9 source frame so nothing is ever stretched.
// - Draggable split seam snapping to 35 / 40 / 50 / 60 / 65%.
// - Dedicated bottom chat "band" shrinks the video area cleanly (`bandHeight = 0.20`).
// - Builds a valid Cobalt Editor v2 `EditTimeline` (1080x1920 @ 30fps) so any draft can be
//   sent straight to Cobalt Studio WITHOUT rendering the video first!

public struct NormalizedRect: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var midX: Double { x + w / 2 }
    public var midY: Double { y + h / 2 }
}

public struct TwitchClipCanvasSlot: Sendable, Equatable {
    public var region: TwitchClipRegionID
    public var rect: NormalizedRect
    public var isPiP: Bool

    public init(region: TwitchClipRegionID, rect: NormalizedRect, isPiP: Bool = false) {
        self.region = region
        self.rect = rect
        self.isPiP = isPiP
    }
}

public enum TwitchClipResizeCorner: String, Sendable, Equatable, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

public enum TwitchClipTimelineBridge {
    /// Dedicated bottom chat band fraction of the 9:16 canvas height.
    public static let chatBandFraction: Double = 0.20
    /// Dedicated right chat sidebar fraction of the 16:9 landscape canvas width.
    public static let landscapeChatSidebarFraction: Double = 0.26
    /// Minimum normalized crop width on the source frame.
    public static let minRegionWidth: Double = 0.12
    /// Snap stops for the split seam.
    public static let splitSnapStops: [Double] = [0.35, 0.40, 0.50, 0.60, 0.65]
    public static let splitSnapTolerance: Double = 0.018
    public static let minSplitRatio: Double = 0.25
    public static let maxSplitRatio: Double = 0.75

    /// Canvas pixel dimensions (`1080×1920` for portrait, `1920×1080` for landscape).
    public static func canvasSize(for config: TwitchClipEditConfig) -> PixelSize {
        switch config.orientation {
        case .portrait: return PixelSize(w: 1080, h: 1920)
        case .landscape: return PixelSize(w: 1920, h: 1080)
        }
    }

    /// Canvas aspect ratio (`width / height`).
    public static func canvasAspect(for config: TwitchClipEditConfig) -> Double {
        switch config.orientation {
        case .portrait: return 9.0 / 16.0
        case .landscape: return 16.0 / 9.0
        }
    }

    /// Height fraction reserved at the bottom for the dedicated chat band in portrait `.band` mode (`0` in landscape or overlays).
    public static func bandHeight(for config: TwitchClipEditConfig) -> Double {
        (config.orientation == .portrait && config.chat.enabled && config.chat.placement == .band) ? chatBandFraction : 0
    }

    /// Width fraction reserved on the right for the dedicated chat column in landscape `.band` mode (`0` in portrait or overlays).
    public static func bandWidth(for config: TwitchClipEditConfig) -> Double {
        (config.orientation == .landscape && config.chat.enabled && config.chat.placement == .band) ? landscapeChatSidebarFraction : 0
    }

    /// Snaps a dragged split ratio to 35 / 40 / 50 / 60 / 65% when within tolerance.
    public static func snapSplitRatio(_ raw: Double) -> Double {
        let clamped = clamp(raw, minSplitRatio, maxSplitRatio)
        for stop in splitSnapStops {
            if abs(clamped - stop) < splitSnapTolerance {
                return stop
            }
        }
        return (clamped * 1000).rounded() / 1000
    }

    /// Where each visible region lands on the canvas (normalized 0...1).
    /// Ordered bottom-to-top in draw order (in PiP mode, B fills the background and A floats above).
    public static func slots(for config: TwitchClipEditConfig) -> [TwitchClipCanvasSlot] {
        switch config.orientation {
        case .portrait:
            let vh = 1.0 - bandHeight(for: config)
            switch config.layout {
            case .single:
                return [TwitchClipCanvasSlot(region: .b, rect: NormalizedRect(x: 0, y: 0, w: 1, h: vh))]

            case .pip:
                let pw = clamp(config.pip.w, 0.20, 0.65)
                // Keep PiP box 16:9-ish / slightly wide on 9:16 (`h = pw * 0.5` in canvas fraction -> aspect ~1.125)
                let ph = min(vh - 0.04, pw * 0.5)
                let px = clamp(config.pip.x, 0.02, 0.98 - pw)
                let py = clamp(config.pip.y, 0.02, max(0.02, vh - 0.02 - ph))
                return [
                    TwitchClipCanvasSlot(region: .b, rect: NormalizedRect(x: 0, y: 0, w: 1, h: vh), isPiP: false),
                    TwitchClipCanvasSlot(region: .a, rect: NormalizedRect(x: px, y: py, w: pw, h: ph), isPiP: true),
                ]

            case .split:
                let split = clamp(config.splitRatio, minSplitRatio, maxSplitRatio)
                let h1 = vh * split
                let top = config.topRegion
                let bottom = top.other
                return [
                    TwitchClipCanvasSlot(region: top, rect: NormalizedRect(x: 0, y: 0, w: 1, h: h1)),
                    TwitchClipCanvasSlot(region: bottom, rect: NormalizedRect(x: 0, y: h1, w: 1, h: vh - h1)),
                ]
            }

        case .landscape:
            let vw = 1.0 - bandWidth(for: config)
            // When the right chat sidebar is active, center a full 16:9 slot (`h = vw`) vertically
            // so the 16:9 stream renders with ZERO cropping beside the full-height chat column.
            let vy = bandWidth(for: config) > 0 ? (1.0 - vw) / 2.0 : 0.0
            let vh = bandWidth(for: config) > 0 ? vw : 1.0

            switch config.layout {
            case .single:
                return [TwitchClipCanvasSlot(region: .b, rect: NormalizedRect(x: 0, y: vy, w: vw, h: vh))]

            case .pip:
                let pw = clamp(config.pip.w, 0.16, 0.45) * vw
                let ph = min(vh - 0.06, pw)
                let px = clamp(config.pip.x * vw, 0.02, max(0.02, vw - 0.02 - pw))
                let py = clamp(vy + config.pip.y * vh, vy + 0.02, max(vy + 0.02, vy + vh - 0.02 - ph))
                return [
                    TwitchClipCanvasSlot(region: .b, rect: NormalizedRect(x: 0, y: vy, w: vw, h: vh), isPiP: false),
                    TwitchClipCanvasSlot(region: .a, rect: NormalizedRect(x: px, y: py, w: pw, h: ph), isPiP: true),
                ]

            case .split:
                let split = clamp(config.splitRatio, minSplitRatio, maxSplitRatio)
                let w1 = vw * split
                let left = config.topRegion
                let right = left.other
                return [
                    TwitchClipCanvasSlot(region: left, rect: NormalizedRect(x: 0, y: 0, w: w1, h: 1.0)),
                    TwitchClipCanvasSlot(region: right, rect: NormalizedRect(x: w1, y: 0, w: vw - w1, h: 1.0)),
                ]
            }
        }
    }

    /// Pixel aspect ratio (`width / height`) of the canvas slot belonging to `region`.
    public static func slotAspect(
        for region: TwitchClipRegionID,
        config: TwitchClipEditConfig,
        canvasAspect: Double? = nil
    ) -> Double {
        let resolvedCanvasAspect = canvasAspect ?? self.canvasAspect(for: config)
        if let slot = slots(for: config).first(where: { $0.region == region }), slot.rect.h > 0 {
            return (slot.rect.w / slot.rect.h) * resolvedCanvasAspect
        }
        // Fallback for hidden Region A in `.single` mode
        return config.orientation == .landscape ? (16.0 / 9.0) : 1.125
    }

    /// Computes the aspect-locked normalized crop rectangle on the source frame for `region`.
    /// Never stretches: the crop's pixel aspect ratio matches the slot's pixel aspect ratio.
    public static func cropRect(
        for region: TwitchClipRegionID,
        config: TwitchClipEditConfig,
        sourceAspect: Double = 16.0 / 9.0,
        canvasAspect: Double? = nil
    ) -> NormalizedRect {
        let resolvedCanvasAspect = canvasAspect ?? self.canvasAspect(for: config)
        let target = config.target(for: region)
        let asp = max(0.1, slotAspect(for: region, config: config, canvasAspect: resolvedCanvasAspect))
        let srcAsp = sourceAspect > 0 ? sourceAspect : (16.0 / 9.0)

        var w = clamp(target.w, minRegionWidth, 1.0)
        // Since pixelW = w * srcW and pixelH = h * srcH, (w * srcAsp) / h = asp => h = w * srcAsp / asp
        var h = w * srcAsp / asp
        if h > 1.0 {
            h = 1.0
            w = clamp(asp / srcAsp, minRegionWidth, 1.0)
        }
        let cx = clamp(target.cx, w / 2.0, 1.0 - w / 2.0)
        let cy = clamp(target.cy, h / 2.0, 1.0 - h / 2.0)
        return NormalizedRect(x: cx - w / 2.0, y: cy - h / 2.0, w: w, h: h)
    }

    /// Moves a region on the source frame starting from its resolved (clamped) crop rect so dragging
    /// back away from an edge responds immediately with zero dead zone.
    public static func movedTarget(
        from startRect: NormalizedRect,
        preservingWidth: Double? = nil,
        deltaX: Double,
        deltaY: Double
    ) -> TwitchClipRegionTarget {
        let halfW = clamp(startRect.w, 0, 1.0) / 2.0
        let halfH = clamp(startRect.h, 0, 1.0) / 2.0
        let cx = clamp(startRect.midX + deltaX, halfW, 1.0 - halfW)
        let cy = clamp(startRect.midY + deltaY, halfH, 1.0 - halfH)
        let storedW = clamp(preservingWidth ?? startRect.w, minRegionWidth, 1.0)
        return TwitchClipRegionTarget(cx: cx, cy: cy, w: storedW)
    }

    /// Pans a region's source crop directly from a drag gesture inside its preview canvas slot.
    /// Dragging the video content right/down shifts the source crop window left/up 1:1 with the touch.
    public static func pannedSlotTarget(
        from startRect: NormalizedRect,
        preservingWidth: Double? = nil,
        translationX: Double,
        translationY: Double,
        slotWidth: Double,
        slotHeight: Double
    ) -> TwitchClipRegionTarget {
        let safeW = max(1.0, slotWidth)
        let safeH = max(1.0, slotHeight)
        let deltaCropX = -(translationX / safeW) * startRect.w
        let deltaCropY = -(translationY / safeH) * startRect.h
        return movedTarget(
            from: startRect,
            preservingWidth: preservingWidth,
            deltaX: deltaCropX,
            deltaY: deltaCropY
        )
    }

    /// Zooms a region's source crop around its current center while preserving exact slot aspect lock.
    /// `scale > 1` zooms in (smaller source crop); `scale < 1` zooms out (larger source crop).
    public static func zoomedTarget(
        from startRect: NormalizedRect,
        scale: Double,
        region: TwitchClipRegionID,
        config: TwitchClipEditConfig,
        sourceAspect: Double = 16.0 / 9.0,
        canvasAspect: Double? = nil
    ) -> TwitchClipRegionTarget {
        let resolvedCanvasAspect = canvasAspect ?? self.canvasAspect(for: config)
        let asp = max(0.1, slotAspect(for: region, config: config, canvasAspect: resolvedCanvasAspect))
        let srcAsp = sourceAspect > 0 ? sourceAspect : (16.0 / 9.0)
        let ratio = srcAsp / asp
        let maxW = min(1.0, 1.0 / ratio)
        let effectiveMinW = min(minRegionWidth, maxW)
        let safeScale = clamp(scale, 0.25, 8.0)
        let nw = clamp(startRect.w / safeScale, effectiveMinW, maxW)
        let nh = nw * ratio
        let cx = clamp(startRect.midX, nw / 2.0, 1.0 - nw / 2.0)
        let cy = clamp(startRect.midY, nh / 2.0, 1.0 - nh / 2.0)
        return TwitchClipRegionTarget(cx: cx, cy: cy, w: nw)
    }

    /// Resizes a region from its bottom-right corner handle while keeping the top-left corner anchored
    /// and maintaining exact slot aspect lock.
    public static func resizedTarget(
        from startRect: NormalizedRect,
        deltaWidth: Double,
        region: TwitchClipRegionID,
        config: TwitchClipEditConfig,
        sourceAspect: Double = 16.0 / 9.0,
        canvasAspect: Double? = nil
    ) -> TwitchClipRegionTarget {
        resizedTarget(
            from: startRect,
            corner: .bottomRight,
            deltaX: deltaWidth,
            deltaY: 0,
            region: region,
            config: config,
            sourceAspect: sourceAspect,
            canvasAspect: canvasAspect
        )
    }

    /// Resizes a region from any corner handle while keeping the opposite corner anchored
    /// and maintaining exact slot aspect lock across horizontal, vertical, and diagonal drags.
    public static func resizedTarget(
        from startRect: NormalizedRect,
        corner: TwitchClipResizeCorner,
        deltaX: Double,
        deltaY: Double,
        region: TwitchClipRegionID,
        config: TwitchClipEditConfig,
        sourceAspect: Double = 16.0 / 9.0,
        canvasAspect: Double? = nil
    ) -> TwitchClipRegionTarget {
        let resolvedCanvasAspect = canvasAspect ?? self.canvasAspect(for: config)
        let asp = max(0.1, slotAspect(for: region, config: config, canvasAspect: resolvedCanvasAspect))
        let srcAsp = sourceAspect > 0 ? sourceAspect : (16.0 / 9.0)
        let ratio = srcAsp / asp

        let signedDX: Double
        let signedDY: Double
        let anchorX: Double
        let anchorY: Double
        let maxWByX: Double
        let maxWByY: Double

        switch corner {
        case .bottomRight:
            signedDX = deltaX
            signedDY = deltaY
            anchorX = startRect.x
            anchorY = startRect.y
            maxWByX = max(0.0, 1.0 - anchorX)
            maxWByY = max(0.0, (1.0 - anchorY) / ratio)
        case .bottomLeft:
            signedDX = -deltaX
            signedDY = deltaY
            anchorX = startRect.maxX
            anchorY = startRect.y
            maxWByX = max(0.0, anchorX)
            maxWByY = max(0.0, (1.0 - anchorY) / ratio)
        case .topRight:
            signedDX = deltaX
            signedDY = -deltaY
            anchorX = startRect.x
            anchorY = startRect.maxY
            maxWByX = max(0.0, 1.0 - anchorX)
            maxWByY = max(0.0, anchorY / ratio)
        case .topLeft:
            signedDX = -deltaX
            signedDY = -deltaY
            anchorX = startRect.maxX
            anchorY = startRect.maxY
            maxWByX = max(0.0, anchorX)
            maxWByY = max(0.0, anchorY / ratio)
        }

        let deltaWFromY = signedDY / ratio
        let effectiveDeltaW = abs(signedDX) >= abs(deltaWFromY) ? signedDX : deltaWFromY
        let maxW = min(1.0, min(maxWByX, maxWByY))
        let effectiveMinW = min(minRegionWidth, maxW)
        let nw = clamp(startRect.w + effectiveDeltaW, effectiveMinW, maxW)
        let nh = nw * ratio

        let cx: Double
        let cy: Double
        switch corner {
        case .bottomRight:
            cx = anchorX + nw / 2.0
            cy = anchorY + nh / 2.0
        case .bottomLeft:
            cx = anchorX - nw / 2.0
            cy = anchorY + nh / 2.0
        case .topRight:
            cx = anchorX + nw / 2.0
            cy = anchorY - nh / 2.0
        case .topLeft:
            cx = anchorX - nw / 2.0
            cy = anchorY - nh / 2.0
        }

        return TwitchClipRegionTarget(
            cx: clamp(cx, nw / 2.0, 1.0 - nw / 2.0),
            cy: clamp(cy, nh / 2.0, 1.0 - nh / 2.0),
            w: nw
        )
    }

    /// Moves a floating PiP box on the canvas and clamps it within the visible video area
    /// (respecting portrait bottom chat bands and landscape right chat sidebars).
    public static func movedPiPBox(
        from startBox: TwitchClipPiPBox,
        deltaX: Double,
        deltaY: Double,
        config: TwitchClipEditConfig
    ) -> TwitchClipPiPBox {
        var box = startBox
        switch config.orientation {
        case .portrait:
            let vh = 1.0 - bandHeight(for: config)
            let pw = clamp(box.w, 0.20, 0.65)
            let ph = min(vh - 0.04, pw * 0.5)
            box.x = clamp(startBox.x + deltaX, 0.02, max(0.02, 0.98 - pw))
            box.y = clamp(startBox.y + deltaY, 0.02, max(0.02, vh - 0.02 - ph))
        case .landscape:
            let vw = max(0.1, 1.0 - bandWidth(for: config))
            let vh = bandWidth(for: config) > 0 ? vw : 1.0
            let pwNorm = clamp(box.w, 0.16, 0.45)
            let phNorm = min(1.0 - 0.06 / max(0.1, vh), pwNorm * vw / max(0.1, vh))
            let maxX = max(0.02 / vw, 1.0 - 0.02 / vw - pwNorm)
            let maxY = max(0.02 / vh, 1.0 - 0.02 / vh - phNorm)
            box.x = clamp(startBox.x + deltaX / vw, 0.02 / vw, maxX)
            box.y = clamp(startBox.y + deltaY / vh, 0.02 / vh, maxY)
        }
        return box
    }

    /// Normalized rectangle on the canvas where the chat layer sits.
    public static func chatOverlayRect(for config: TwitchClipEditConfig) -> NormalizedRect {
        switch config.orientation {
        case .portrait:
            let vh = 1.0 - bandHeight(for: config)
            switch config.chat.placement {
            case .band:
                return NormalizedRect(x: 0, y: vh, w: 1.0, h: max(0.12, 1.0 - vh))
            case .bottom:
                return NormalizedRect(x: 0.04, y: 0.67, w: 0.92, h: 0.30)
            case .top:
                return NormalizedRect(x: 0.04, y: 0.05, w: 0.92, h: 0.27)
            case .seam:
                let seamY: Double
                if config.layout == .split, let first = slots(for: config).first {
                    seamY = first.rect.h
                } else {
                    seamY = vh * 0.5
                }
                let h = 0.26
                let y = clamp(seamY - h / 2.0, 0.04, max(0.04, vh - h - 0.02))
                return NormalizedRect(x: 0.04, y: y, w: 0.92, h: h)
            }

        case .landscape:
            let bw = bandWidth(for: config)
            switch config.chat.placement {
            case .band:
                return NormalizedRect(x: 1.0 - bw, y: 0, w: max(0.20, bw), h: 1.0)
            case .bottom:
                return NormalizedRect(x: 0.03, y: 0.60, w: 0.42, h: 0.36)
            case .top:
                return NormalizedRect(x: 0.03, y: 0.04, w: 0.42, h: 0.34)
            case .seam:
                // Right-side translucent chat overlay over the 16:9 stream
                return NormalizedRect(x: 0.69, y: 0.05, w: 0.28, h: 0.90)
            }
        }
    }

    /// Recommended maximum visible chat lines for the current orientation & placement.
    public static func maxVisibleChatLines(for config: TwitchClipEditConfig) -> Int {
        switch config.orientation {
        case .portrait:
            return config.chat.placement == .band ? 4 : 6
        case .landscape:
            switch config.chat.placement {
            case .band, .seam: return 12
            case .bottom, .top: return 6
            }
        }
    }

    /// Builds a Cobalt Studio Editor v2 `EditTimeline` (`1080×1920` portrait or `1920×1080` landscape @ 30fps)
    /// directly from a draft, referencing the raw uploaded 16:9 clip on Lanes 0 & 1 (zero video re-encoding)
    /// and an optional animated chat overlay clip on Lane 2.
    public static func buildStudioTimeline(
        draft: TwitchClipDraft,
        videoItemID: String,
        chatItemID: String? = nil,
        fps: Int = 30
    ) -> EditTimeline {
        let shape: EditCanvas.Shape = draft.edit.orientation == .landscape ? .wide : .story
        let canvas = EditCanvas(shape: shape, resolution: .p1080, fps: fps)
        let clipOut = max(EditValidation.minClipSeconds, min(EditValidation.maxSeconds, EditJSON.time(draft.duration)))
        let currentSlots = slots(for: draft.edit)
        let slotByRegion = Dictionary(uniqueKeysWithValues: currentSlots.map { ($0.region, $0) })

        var clips: [EditLaneClip] = []

        // Lane 0: Region B (unmuted audio anchor; always present)
        if let slotB = slotByRegion[.b] {
            let cropB = cropRect(for: .b, config: draft.edit, sourceAspect: draft.sourceAspect)
            clips.append(EditLaneClip(
                id: EditID.mint(),
                item: videoItemID,
                lane: 0,
                at: 0,
                in: 0,
                out: clipOut,
                speed: 1,
                crop: makeEditCrop(cropB),
                fit: .fill,
                frame: EditFrame(
                    x: EditJSON.fraction(slotB.rect.x),
                    y: EditJSON.fraction(slotB.rect.y),
                    w: EditJSON.fraction(slotB.rect.w)
                ),
                opacity: 1,
                volume: 1,
                muted: false
            ))
        }

        // Lane 1: Region A (muted so audio does not double; omitted in `.single` layout)
        if draft.edit.layout != .single, let slotA = slotByRegion[.a] {
            let cropA = cropRect(for: .a, config: draft.edit, sourceAspect: draft.sourceAspect)
            clips.append(EditLaneClip(
                id: EditID.mint(),
                item: videoItemID,
                lane: 1,
                at: 0,
                in: 0,
                out: clipOut,
                speed: 1,
                crop: makeEditCrop(cropA),
                fit: .fill,
                frame: EditFrame(
                    x: EditJSON.fraction(slotA.rect.x),
                    y: EditJSON.fraction(slotA.rect.y),
                    w: EditJSON.fraction(slotA.rect.w)
                ),
                opacity: 1,
                volume: 0,
                muted: true
            ))
        }

        // Lane 2: Optional transparent animated chat overlay (image/gif)
        if let chatItemID, draft.edit.chat.enabled {
            let chatBox = chatOverlayRect(for: draft.edit)
            clips.append(EditLaneClip(
                id: EditID.mint(),
                item: chatItemID,
                lane: 2,
                at: 0,
                in: 0,
                out: clipOut,
                speed: 1,
                crop: nil,
                fit: .fit,
                frame: EditFrame(
                    x: EditJSON.fraction(chatBox.x),
                    y: EditJSON.fraction(chatBox.y),
                    w: EditJSON.fraction(chatBox.w)
                ),
                opacity: 1,
                volume: 0,
                muted: true
            ))
        }

        return EditTimeline(
            canvas: canvas,
            clips: clips
        )
    }

    private static func makeEditCrop(_ r: NormalizedRect) -> EditCrop {
        let x = clamp(EditJSON.fraction(r.x), 0, 0.99)
        let y = clamp(EditJSON.fraction(r.y), 0, 0.99)
        let w = clamp(EditJSON.fraction(r.w), 0.01, max(0.01, 1.0 - x))
        let h = clamp(EditJSON.fraction(r.h), 0.01, max(0.01, 1.0 - y))
        return EditCrop(aspect: .free, x: x, y: y, w: w, h: h)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, v))
    }
}

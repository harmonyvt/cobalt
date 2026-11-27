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

public enum TwitchClipTimelineBridge {
    /// Dedicated bottom chat band fraction of the 9:16 canvas height.
    public static let chatBandFraction: Double = 0.20
    /// Minimum normalized crop width on the source frame.
    public static let minRegionWidth: Double = 0.12
    /// Snap stops for the vertical split seam.
    public static let splitSnapStops: [Double] = [0.35, 0.40, 0.50, 0.60, 0.65]
    public static let splitSnapTolerance: Double = 0.018
    public static let minSplitRatio: Double = 0.25
    public static let maxSplitRatio: Double = 0.75

    /// Height fraction reserved at the bottom for the dedicated chat band (0 when not in `.band` mode).
    public static func bandHeight(for config: TwitchClipEditConfig) -> Double {
        (config.chat.enabled && config.chat.placement == .band) ? chatBandFraction : 0
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

    /// Where each visible region lands on the 9:16 canvas (normalized 0...1).
    /// Ordered bottom-to-top in draw order (in PiP mode, B fills the background and A floats above).
    public static func slots(for config: TwitchClipEditConfig) -> [TwitchClipCanvasSlot] {
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
    }

    /// Pixel aspect ratio (`width / height`) of the canvas slot belonging to `region`.
    public static func slotAspect(
        for region: TwitchClipRegionID,
        config: TwitchClipEditConfig,
        canvasAspect: Double = 9.0 / 16.0
    ) -> Double {
        if let slot = slots(for: config).first(where: { $0.region == region }), slot.rect.h > 0 {
            return (slot.rect.w / slot.rect.h) * canvasAspect
        }
        // Fallback for hidden Region A in `.single` mode (50/50 half aspect = 9/8 = 1.125)
        return 1.125
    }

    /// Computes the aspect-locked normalized crop rectangle on the source frame for `region`.
    /// Never stretches: the crop's pixel aspect ratio matches the slot's pixel aspect ratio.
    public static func cropRect(
        for region: TwitchClipRegionID,
        config: TwitchClipEditConfig,
        sourceAspect: Double = 16.0 / 9.0,
        canvasAspect: Double = 9.0 / 16.0
    ) -> NormalizedRect {
        let target = config.target(for: region)
        let asp = max(0.1, slotAspect(for: region, config: config, canvasAspect: canvasAspect))
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

    /// Resizes a region from its bottom-right corner handle while keeping the top-left corner anchored
    /// and maintaining exact slot aspect lock.
    public static func resizedTarget(
        from startRect: NormalizedRect,
        deltaWidth: Double,
        region: TwitchClipRegionID,
        config: TwitchClipEditConfig,
        sourceAspect: Double = 16.0 / 9.0,
        canvasAspect: Double = 9.0 / 16.0
    ) -> TwitchClipRegionTarget {
        let asp = max(0.1, slotAspect(for: region, config: config, canvasAspect: canvasAspect))
        let srcAsp = sourceAspect > 0 ? sourceAspect : (16.0 / 9.0)
        let maxWByRight = max(minRegionWidth, 1.0 - startRect.x)
        let maxWByBottom = max(minRegionWidth, (1.0 - startRect.y) * asp / srcAsp)
        let maxW = min(maxWByRight, maxWByBottom)
        let nw = clamp(startRect.w + deltaWidth, minRegionWidth, maxW)
        let nh = nw * srcAsp / asp
        return TwitchClipRegionTarget(cx: startRect.x + nw / 2.0, cy: startRect.y + nh / 2.0, w: nw)
    }

    /// Normalized rectangle on the 9:16 canvas where the chat layer sits.
    public static func chatOverlayRect(for config: TwitchClipEditConfig) -> NormalizedRect {
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
    }

    /// Builds a Cobalt Studio Editor v2 `EditTimeline` (1080×1920 @ 30fps) directly from a draft,
    /// referencing the raw uploaded 16:9 clip on Lanes 0 & 1 (with exact crops & frames, zero
    /// video re-encoding!) and an optional animated chat overlay clip on Lane 2.
    public static func buildStudioTimeline(
        draft: TwitchClipDraft,
        videoItemID: String,
        chatItemID: String? = nil,
        fps: Int = 30
    ) -> EditTimeline {
        let canvas = EditCanvas(shape: .story, resolution: .p1080, fps: fps)
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

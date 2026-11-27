import CoreGraphics
import Foundation

// Pure geometry & layout rules for the dual-stream Twitch stage (Opus Best-of-Breed Hybrid Spec).
//
// Core rules:
// - Default mode is V2 Focus-First (`.focusInset`): focused stream fills the stage; the other
//   stream renders as an interactive 16:9 inset tile (1-tap inset swaps focus).
// - 1-tap `50/50` mode (`.split5050`): places the two 16:9 streams side-by-side ONLY when
//   `stageWidth / stageHeight > 16.0 / 9.0`; otherwise stacks them vertically so each 16:9 stream
//   receives up to 4x the rendered video area.

/// Active visual layout mode for the dual-stream video stage.
public enum TwitchDualStageMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Focused stream fills the stage; secondary renders as a tappable 16:9 inset tile.
    case focusInset
    /// Both streams share the stage equally (stacked vertically unless `width / height > 16/9`).
    case split5050

    public var toggled: TwitchDualStageMode {
        self == .focusInset ? .split5050 : .focusInset
    }
}

/// Which of the two concurrent Twitch stream slots is referenced.
public enum TwitchDualSlot: String, Codable, Sendable, Equatable, CaseIterable {
    case primary
    case secondary

    public var other: TwitchDualSlot {
        self == .primary ? .secondary : .primary
    }

    public var streamSlot: TwitchStreamSlot {
        self == .primary ? .a : .b
    }
}

/// Resolved axis for `50/50` dual-stream presentation.
public enum TwitchDualSplitAxis: String, Sendable, Equatable {
    /// Side-by-side (`HStack`): only used on ultra-wide stages (`width / height > 16/9`).
    case horizontal
    /// Stacked vertically (`VStack`): maximizes 16:9 stream area on portrait, square, and standard wide stages.
    case vertical
}

/// Pure, testable geometry solver for dual-stream stage layouts (in-app stage, iOS PiP, macOS floating panel).
public enum TwitchDualLayout {
    /// Aspect ratio threshold above which 50/50 splits horizontally (side-by-side) rather than vertically (stacked).
    public static let sideBySideAspectThreshold: CGFloat = 16.0 / 9.0

    /// Resolves whether `50/50` mode arranges the two streams side-by-side or stacked vertically.
    /// Side-by-side is selected ONLY when `stageSize.width / stageSize.height > 16.0 / 9.0`.
    public static func splitAxis(for stageSize: CGSize) -> TwitchDualSplitAxis {
        guard stageSize.width > 0, stageSize.height > 0 else { return .vertical }
        return (stageSize.width / stageSize.height) > sideBySideAspectThreshold ? .horizontal : .vertical
    }

    /// Computes the crisp 16:9 inset tile size for Focus-First mode.
    /// Keeps the tile comfortably tappable (>= 44 pt tall, >= 112 pt wide) without swallowing the focused hero.
    public static func insetSize(
        for stageSize: CGSize,
        widthFraction: CGFloat = 0.30,
        minWidth: CGFloat = 112,
        maxWidth: CGFloat = 224
    ) -> CGSize {
        guard stageSize.width > 0, stageSize.height > 0 else {
            return CGSize(width: minWidth, height: (minWidth * 9 / 16).rounded())
        }
        // Keep height <= 38% of stage height so the inset never collides with top/bottom HUD chrome.
        let maxFromHeight = max(minWidth, (stageSize.height * 0.38) * 16 / 9)
        let rawWidth = stageSize.width * widthFraction
        let clampedWidth = min(max(rawWidth, minWidth), min(maxWidth, maxFromHeight, max(minWidth, stageSize.width * 0.44)))
        let height = max(44, (clampedWidth * 9 / 16).rounded())
        return CGSize(width: clampedWidth.rounded(), height: height)
    }

    /// Returns which slot renders as hero and which renders as inset for the current `focusedSlot`.
    public static func heroAndInset(focused: TwitchDualSlot) -> (hero: TwitchDualSlot, inset: TwitchDualSlot) {
        (hero: focused, inset: focused.other)
    }

    /// Effective 16:9 video area for a single stream inside `stageSize` under a given `splitAxis` (used in tests
    /// and diagnostics to prove the 16:9 threshold maximizes video area).
    public static func tileVideoArea(stageSize: CGSize, axis: TwitchDualSplitAxis, spacing: CGFloat = 2) -> CGFloat {
        guard stageSize.width > 0, stageSize.height > 0 else { return 0 }
        let tileW: CGFloat
        let tileH: CGFloat
        switch axis {
        case .horizontal:
            tileW = max(0, (stageSize.width - spacing) / 2)
            tileH = stageSize.height
        case .vertical:
            tileW = stageSize.width
            tileH = max(0, (stageSize.height - spacing) / 2)
        }
        guard tileW > 0, tileH > 0 else { return 0 }
        let aspect: CGFloat = 16.0 / 9.0
        let fittedW: CGFloat
        let fittedH: CGFloat
        if tileW / tileH > aspect {
            fittedH = tileH
            fittedW = tileH * aspect
        } else {
            fittedW = tileW
            fittedH = tileW / aspect
        }
        return fittedW * fittedH
    }
}

// MARK: - Multi-stream (1...4) generalized slots, layouts & quality budget

/// Generalized Twitch stream slot supporting up to 4 simultaneous live streams.
public enum TwitchStreamSlot: Int, Codable, Sendable, Equatable, Hashable, CaseIterable, Comparable, Identifiable {
    case a = 0
    case b = 1
    case c = 2
    case d = 3

    public var id: Int { rawValue }

    public static func < (lhs: TwitchStreamSlot, rhs: TwitchStreamSlot) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(_ dual: TwitchDualSlot) {
        self = dual == .primary ? .a : .b
    }

    public var dualSlot: TwitchDualSlot? {
        switch self {
        case .a: .primary
        case .b: .secondary
        case .c, .d: nil
        }
    }

    public var channelSlot: TwitchChannelSlot {
        switch self {
        case .a: .primary
        case .b: .secondary
        case .c: .tertiary
        case .d: .quaternary
        }
    }

    public var label: String {
        switch self {
        case .a: "A"
        case .b: "B"
        case .c: "C"
        case .d: "D"
        }
    }

    public var letter: String { label }

    public var darkRGB: UInt32 {
        switch self {
        case .a: TwitchChannelAccent.primaryDarkRGB
        case .b: TwitchChannelAccent.secondaryDarkRGB
        case .c: TwitchChannelAccent.tertiaryDarkRGB
        case .d: TwitchChannelAccent.quaternaryDarkRGB
        }
    }

    public var lightRGB: UInt32 {
        switch self {
        case .a: TwitchChannelAccent.primaryLightRGB
        case .b: TwitchChannelAccent.secondaryLightRGB
        case .c: TwitchChannelAccent.tertiaryLightRGB
        case .d: TwitchChannelAccent.quaternaryLightRGB
        }
    }

    /// Ordered active slots for `count` streams (clamped to `0...4`).
    public static func slots(forCount count: Int) -> [TwitchStreamSlot] {
        let clamped = max(0, min(count, allCases.count))
        return Array(allCases.prefix(clamped))
    }

    /// Next slot wrapping within `count` active slots.
    public func next(inCount count: Int) -> TwitchStreamSlot {
        let clamped = max(1, min(count, Self.allCases.count))
        let nextIndex = (rawValue + 1) % clamped
        return TwitchStreamSlot(rawValue: nextIndex) ?? .a
    }

    /// Previous slot wrapping within `count` active slots.
    public func previous(inCount count: Int) -> TwitchStreamSlot {
        let clamped = max(1, min(count, Self.allCases.count))
        let prevIndex = (rawValue - 1 + clamped) % clamped
        return TwitchStreamSlot(rawValue: prevIndex) ?? .a
    }
}

/// Visual layout mode for 2...4 simultaneous Twitch streams.
public enum TwitchMultiStageMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// One large spotlight hero plus compact companion strip (or 16:9 inset when N = 2).
    case spotlight
    /// Multi-tile grid: 50/50 split (N = 2), 2+1 / Duo fold-safe split (N = 3), or 2×2 quad grid (N = 4).
    case grid

    public init(_ dual: TwitchDualStageMode) {
        self = dual == .focusInset ? .spotlight : .grid
    }

    public var dualStageMode: TwitchDualStageMode {
        self == .spotlight ? .focusInset : .split5050
    }

    public var toggled: TwitchMultiStageMode {
        self == .spotlight ? .grid : .spotlight
    }
}

/// Resolved grid geometry for `TwitchMultiStageMode.grid` across 2, 3, and 4 streams.
public enum TwitchMultiGridKind: String, Sendable, Equatable {
    /// 2 streams side-by-side (`width / height > 16/9`).
    case splitHorizontal
    /// 2 streams stacked vertically.
    case splitVertical
    /// 3 streams: 1 spotlight on the left half + 2 stacked on the right half (never spans a Duo vertical crease).
    case duoFoldSafeThree
    /// 3 streams: 1 wide hero on top + 2 side-by-side companions below.
    case mosaicThree
    /// 4 streams: symmetric 2×2 quad grid (crease-safe on Duo and crisp 16:9 on widescreen).
    case quadGrid
}

/// Placement of companion tiles in `TwitchMultiStageMode.spotlight` for 3–4 streams.
public enum TwitchMultiSpotlightDock: String, Sendable, Equatable {
    /// Companions stacked in a trailing vertical rail beside the spotlight hero.
    case trailingColumn
    /// Companions arranged in a horizontal strip beneath the spotlight hero.
    case bottomRow
}

/// Pure, testable geometry solver for 2...4 simultaneous Twitch streams across compact, regular, Duo, and Mac stages.
public enum TwitchMultiLayout {
    /// Resolves the grid topology for `count` streams inside `stageSize`.
    /// When `hasVerticalCrease` is true (e.g., iPhone Duo open side-by-side), 3 streams prefer `.duoFoldSafeThree`
    /// so no video tile crosses the center fold crease.
    public static func gridKind(
        count: Int,
        stageSize: CGSize,
        hasVerticalCrease: Bool = false
    ) -> TwitchMultiGridKind {
        if count >= 4 {
            return .quadGrid
        }
        if count == 3 {
            if hasVerticalCrease {
                return .duoFoldSafeThree
            }
            guard stageSize.width > 0, stageSize.height > 0 else { return .mosaicThree }
            return (stageSize.width / stageSize.height) > 1.15 ? .duoFoldSafeThree : .mosaicThree
        }
        return TwitchDualLayout.splitAxis(for: stageSize) == .horizontal ? .splitHorizontal : .splitVertical
    }

    /// Resolves where the 2 or 3 companion tiles dock in `.spotlight` mode.
    public static func spotlightDock(
        count: Int,
        stageSize: CGSize,
        hasVerticalCrease: Bool = false
    ) -> TwitchMultiSpotlightDock {
        guard count >= 3 else { return .bottomRow }
        if hasVerticalCrease {
            return .trailingColumn
        }
        guard stageSize.width > 0, stageSize.height > 0 else { return .bottomRow }
        return (stageSize.width / stageSize.height) > 1.25 ? .trailingColumn : .bottomRow
    }

    /// Fraction of the primary axis allocated to the spotlight hero when `count >= 3`.
    public static func spotlightHeroFraction(
        count: Int,
        dock: TwitchMultiSpotlightDock,
        hasVerticalCrease: Bool = false
    ) -> CGFloat {
        if hasVerticalCrease && dock == .trailingColumn {
            // Keep the split squarely on the 50% Duo center crease.
            return 0.50
        }
        switch (count, dock) {
        case (3, .trailingColumn): return 0.66
        case (3, .bottomRow): return 0.64
        case (_, .trailingColumn): return 0.72
        case (_, .bottomRow): return 0.68
        }
    }

    /// Ordered companion slots for `count` active streams excluding `spotlight`.
    public static func companionSlots(count: Int, spotlight: TwitchStreamSlot) -> [TwitchStreamSlot] {
        TwitchStreamSlot.slots(forCount: count).filter { $0 != spotlight }
    }
}

/// Pure, testable quality tier budget policy for 1...4 concurrent hardware-decoded Twitch HLS streams.
/// Protects VideoToolbox decoder headroom, thermal envelope, and network bandwidth while keeping the
/// spotlight stream crisp (1080p nominal, 720p under thermal pressure).
public enum TwitchQualityBudgetPolicy {
    /// Maximum target video height in pixels (`nil` means uncapped / source quality).
    public static func maxHeight(
        streamCount: Int,
        isSpotlight: Bool,
        isThermalThrottled: Bool
    ) -> Int? {
        switch streamCount {
        case ...1:
            return isThermalThrottled ? 720 : nil
        case 2:
            if isSpotlight {
                return isThermalThrottled ? 720 : nil
            }
            return isThermalThrottled ? 480 : nil
        default: // 3 or 4 streams
            if isSpotlight {
                return isThermalThrottled ? 720 : 1080
            }
            return isThermalThrottled ? 360 : 480
        }
    }

    /// Whether a slot should prefer a 30fps variant over 60fps when multiple variants share the same height.
    public static func preferLowerFrameRate(
        streamCount: Int,
        isSpotlight: Bool,
        isThermalThrottled: Bool
    ) -> Bool {
        if streamCount >= 3 && !isSpotlight { return true }
        if isThermalThrottled && streamCount >= 2 { return true }
        return false
    }

    /// Selects the best native-compatible video variant within the budget for the slot.
    /// Returns `nil` when uncapped (caller keeps default/source variant) or when no video variants exist.
    public static func preferredVariant(
        from variants: [TwitchVariant],
        streamCount: Int,
        isSpotlight: Bool,
        isThermalThrottled: Bool
    ) -> TwitchVariant? {
        let videoVariants = variants.filter { !$0.isAudioOnly && $0.isNativeCompatible }
        guard !videoVariants.isEmpty else { return nil }
        guard let capHeight = maxHeight(
            streamCount: streamCount,
            isSpotlight: isSpotlight,
            isThermalThrottled: isThermalThrottled
        ) else {
            return videoVariants.first(where: \.isSource) ?? videoVariants.max(by: { $0.bandwidth < $1.bandwidth })
        }

        let prefer30 = preferLowerFrameRate(
            streamCount: streamCount,
            isSpotlight: isSpotlight,
            isThermalThrottled: isThermalThrottled
        )
        let eligible = videoVariants.filter { ($0.height ?? 0) > 0 && ($0.height ?? Int.max) <= capHeight }
        let pool = eligible.isEmpty ? videoVariants : eligible

        if eligible.isEmpty {
            // Every available variant exceeds cap: pick the smallest height / lowest bandwidth video stream.
            return pool.min { a, b in
                let ah = a.height ?? Int.max
                let bh = b.height ?? Int.max
                if ah != bh { return ah < bh }
                return a.bandwidth < b.bandwidth
            }
        }

        // Highest height <= capHeight; tie-break frame rate according to `prefer30`.
        return pool.max { a, b in
            let ah = a.height ?? 0
            let bh = b.height ?? 0
            if ah != bh { return ah < bh }
            let afps = a.frameRate ?? 30
            let bfps = b.frameRate ?? 30
            if prefer30 {
                if abs(afps - bfps) > 1 { return afps > bfps }
                return a.bandwidth > b.bandwidth
            }
            if abs(afps - bfps) > 1 { return afps < bfps }
            return a.bandwidth < b.bandwidth
        }
    }

    public static func preferredVariant(
        from variants: [TwitchVariant],
        hint: TwitchQualityBudgetHint
    ) -> TwitchVariant? {
        preferredVariant(
            from: variants,
            streamCount: hint.streamCount,
            isSpotlight: hint.isSpotlight,
            isThermalThrottled: hint.isThermalThrottled
        )
    }
}

/// Startup quality budget hint passed into `TwitchNativeEngine.start` so companion streams select their
/// budgeted variant directly on first join instead of starting source quality and immediately restarting.
public struct TwitchQualityBudgetHint: Sendable, Equatable {
    public let streamCount: Int
    public let isSpotlight: Bool
    public let isThermalThrottled: Bool

    public init(streamCount: Int, isSpotlight: Bool, isThermalThrottled: Bool) {
        self.streamCount = streamCount
        self.isSpotlight = isSpotlight
        self.isThermalThrottled = isThermalThrottled
    }
}

/// Visual role of a single persistent stream tile inside `TwitchDualStage`.
public enum TwitchStageTileRole: String, Sendable, Equatable {
    /// Full-bleed hero tile (Focus-Inset hero or Spotlight hero).
    case hero
    /// Floating 16:9 inset tile in 2-stream Focus-Inset mode (1-tap swaps focus).
    case inset
    /// Companion tile inside the Spotlight dock strip (1-tap promotes to spotlight).
    case dock
    /// Tile in 3–4 stream Grid / Mosaic / Duo fold-safe mode.
    case grid
    /// Tile in 2-stream 50/50 Split mode.
    case split
}

/// Computed frame and interaction metadata for one persistent stream slot inside `TwitchDualStage`.
/// Keeping every active slot in a single flat `ForEach` and animating these rects avoids destroying or
/// reparenting `AVSampleBufferDisplayLayer` surfaces across layout transitions.
public struct TwitchStageTileGeometry: Sendable, Equatable {
    public let slot: TwitchStreamSlot
    public let rect: CGRect
    public let zIndex: Double
    public let role: TwitchStageTileRole
    public let cornerRadius: CGFloat
    public let compact: Bool
    public let tappableTile: Bool
    public let tappableBadge: Bool

    public init(
        slot: TwitchStreamSlot,
        rect: CGRect,
        zIndex: Double = 0,
        role: TwitchStageTileRole,
        cornerRadius: CGFloat = 0,
        compact: Bool = false,
        tappableTile: Bool = false,
        tappableBadge: Bool = false
    ) {
        self.slot = slot
        self.rect = rect
        self.zIndex = zIndex
        self.role = role
        self.cornerRadius = cornerRadius
        self.compact = compact
        self.tappableTile = tappableTile
        self.tappableBadge = tappableBadge
    }
}

public extension TwitchMultiLayout {
    /// Computes deterministic tile rects and roles for all active streams (`count` in `2...4`) inside `stageSize`.
    /// Every returned rect is clamped to non-negative dimensions within `(0, 0, stageSize.width, stageSize.height)`.
    static func stageGeometries(
        count rawCount: Int,
        stageSize: CGSize,
        dualMode: TwitchDualStageMode,
        multiMode: TwitchMultiStageMode,
        dualFocused: TwitchDualSlot,
        spotlight: TwitchStreamSlot,
        hasVerticalCrease: Bool = false,
        hudVisible: Bool = true,
        compactChrome: Bool = false,
        spacing: CGFloat = 2
    ) -> [TwitchStreamSlot: TwitchStageTileGeometry] {
        let count = max(2, min(4, rawCount))
        let slots = TwitchStreamSlot.slots(forCount: count)
        let w = max(1, stageSize.width)
        let h = max(1, stageSize.height)
        let full = CGRect(x: 0, y: 0, width: w, height: h)

        var out: [TwitchStreamSlot: TwitchStageTileGeometry] = [:]

        if count == 2 {
            switch dualMode {
            case .focusInset:
                let pair = TwitchDualLayout.heroAndInset(focused: dualFocused)
                let heroSlot = pair.hero.streamSlot
                let insetSlot = pair.inset.streamSlot
                let insetSize = TwitchDualLayout.insetSize(for: CGSize(width: w, height: h))
                let bottomPad: CGFloat = hudVisible ? (compactChrome ? 62 : 76) : 14
                let trailingPad: CGFloat = 12
                let insetW = min(insetSize.width, max(44, w - trailingPad * 2))
                let insetH = min(insetSize.height, max(44, h - bottomPad - 12))
                let insetX = max(8, w - trailingPad - insetW)
                let insetY = max(8, h - bottomPad - insetH)
                out[heroSlot] = TwitchStageTileGeometry(
                    slot: heroSlot,
                    rect: full,
                    zIndex: 0,
                    role: .hero,
                    cornerRadius: 0,
                    compact: false,
                    tappableTile: false,
                    tappableBadge: false
                )
                out[insetSlot] = TwitchStageTileGeometry(
                    slot: insetSlot,
                    rect: CGRect(x: insetX, y: insetY, width: insetW, height: insetH),
                    zIndex: 10,
                    role: .inset,
                    cornerRadius: 12,
                    compact: true,
                    tappableTile: true,
                    tappableBadge: false
                )
                return out

            case .split5050:
                let axis = TwitchDualLayout.splitAxis(for: CGSize(width: w, height: h))
                if axis == .horizontal {
                    let halfW = max(1, (w - spacing) / 2)
                    out[.a] = TwitchStageTileGeometry(
                        slot: .a,
                        rect: CGRect(x: 0, y: 0, width: halfW, height: h),
                        zIndex: 0,
                        role: .split,
                        cornerRadius: 0,
                        compact: false,
                        tappableTile: false,
                        tappableBadge: true
                    )
                    out[.b] = TwitchStageTileGeometry(
                        slot: .b,
                        rect: CGRect(x: halfW + spacing, y: 0, width: max(1, w - halfW - spacing), height: h),
                        zIndex: 0,
                        role: .split,
                        cornerRadius: 0,
                        compact: false,
                        tappableTile: false,
                        tappableBadge: true
                    )
                } else {
                    let halfH = max(1, (h - spacing) / 2)
                    out[.a] = TwitchStageTileGeometry(
                        slot: .a,
                        rect: CGRect(x: 0, y: 0, width: w, height: halfH),
                        zIndex: 0,
                        role: .split,
                        cornerRadius: 0,
                        compact: false,
                        tappableTile: false,
                        tappableBadge: true
                    )
                    out[.b] = TwitchStageTileGeometry(
                        slot: .b,
                        rect: CGRect(x: 0, y: halfH + spacing, width: w, height: max(1, h - halfH - spacing)),
                        zIndex: 0,
                        role: .split,
                        cornerRadius: 0,
                        compact: false,
                        tappableTile: false,
                        tappableBadge: true
                    )
                }
                return out
            }
        }

        // N = 3 or N = 4
        let activeSpotlight = slots.contains(spotlight) ? spotlight : .a
        let others = slots.filter { $0 != activeSpotlight }

        switch multiMode {
        case .spotlight:
            let dock = spotlightDock(count: count, stageSize: CGSize(width: w, height: h), hasVerticalCrease: hasVerticalCrease)
            let heroFraction = spotlightHeroFraction(count: count, dock: dock, hasVerticalCrease: hasVerticalCrease)
            let bottomReserve: CGFloat = (dock == .bottomRow && hudVisible) ? (compactChrome ? 58 : 68) : 0

            if dock == .trailingColumn {
                let heroW = min(max(120, w * heroFraction), max(120, w - 80))
                let dockX = heroW + spacing
                let dockW = max(1, w - dockX)
                let dockCount = CGFloat(max(1, others.count))
                let tileH = max(1, (h - spacing * max(0, dockCount - 1)) / dockCount)

                out[activeSpotlight] = TwitchStageTileGeometry(
                    slot: activeSpotlight,
                    rect: CGRect(x: 0, y: 0, width: heroW, height: h),
                    zIndex: 0,
                    role: .hero,
                    cornerRadius: 0,
                    compact: false,
                    tappableTile: false,
                    tappableBadge: false
                )
                for (i, slot) in others.enumerated() {
                    let y = CGFloat(i) * (tileH + spacing)
                    let resolvedH = (i == others.count - 1) ? max(1, h - y) : tileH
                    out[slot] = TwitchStageTileGeometry(
                        slot: slot,
                        rect: CGRect(x: dockX, y: y, width: dockW, height: resolvedH),
                        zIndex: 1,
                        role: .dock,
                        cornerRadius: 6,
                        compact: true,
                        tappableTile: true,
                        tappableBadge: false
                    )
                }
            } else {
                let usableH = max(80, h - bottomReserve)
                let heroH = min(max(80, usableH * heroFraction), max(80, usableH - 60))
                let dockY = heroH + spacing
                let dockH = max(1, usableH - dockY)
                let dockCount = CGFloat(max(1, others.count))
                let tileW = max(1, (w - spacing * max(0, dockCount - 1)) / dockCount)

                out[activeSpotlight] = TwitchStageTileGeometry(
                    slot: activeSpotlight,
                    rect: CGRect(x: 0, y: 0, width: w, height: heroH),
                    zIndex: 0,
                    role: .hero,
                    cornerRadius: 0,
                    compact: false,
                    tappableTile: false,
                    tappableBadge: false
                )
                for (i, slot) in others.enumerated() {
                    let x = CGFloat(i) * (tileW + spacing)
                    let resolvedW = (i == others.count - 1) ? max(1, w - x) : tileW
                    out[slot] = TwitchStageTileGeometry(
                        slot: slot,
                        rect: CGRect(x: x, y: dockY, width: resolvedW, height: dockH),
                        zIndex: 1,
                        role: .dock,
                        cornerRadius: 6,
                        compact: true,
                        tappableTile: true,
                        tappableBadge: false
                    )
                }
            }
            return out

        case .grid:
            let kind = gridKind(count: count, stageSize: CGSize(width: w, height: h), hasVerticalCrease: hasVerticalCrease)
            let isCompactQuad = (count == 4 && w < 600)

            switch kind {
            case .quadGrid:
                let colW = max(1, (w - spacing) / 2)
                let rowH = max(1, (h - spacing) / 2)
                let rightW = max(1, w - colW - spacing)
                let bottomH = max(1, h - rowH - spacing)
                let rects: [(TwitchStreamSlot, CGRect)] = [
                    (.a, CGRect(x: 0, y: 0, width: colW, height: rowH)),
                    (.b, CGRect(x: colW + spacing, y: 0, width: rightW, height: rowH)),
                    (.c, CGRect(x: 0, y: rowH + spacing, width: colW, height: bottomH)),
                    (.d, CGRect(x: colW + spacing, y: rowH + spacing, width: rightW, height: bottomH)),
                ]
                for (slot, rect) in rects where slots.contains(slot) {
                    out[slot] = TwitchStageTileGeometry(
                        slot: slot,
                        rect: rect,
                        zIndex: 0,
                        role: .grid,
                        cornerRadius: 0,
                        compact: isCompactQuad,
                        tappableTile: false,
                        tappableBadge: true
                    )
                }

            case .duoFoldSafeThree:
                let leftW = max(1, (w - spacing) / 2)
                let rightX = leftW + spacing
                let rightW = max(1, w - rightX)
                let rightCount = CGFloat(max(1, others.count))
                let rightTileH = max(1, (h - spacing * max(0, rightCount - 1)) / rightCount)

                out[activeSpotlight] = TwitchStageTileGeometry(
                    slot: activeSpotlight,
                    rect: CGRect(x: 0, y: 0, width: leftW, height: h),
                    zIndex: 0,
                    role: .grid,
                    cornerRadius: 0,
                    compact: false,
                    tappableTile: false,
                    tappableBadge: true
                )
                for (i, slot) in others.enumerated() {
                    let y = CGFloat(i) * (rightTileH + spacing)
                    let resolvedH = (i == others.count - 1) ? max(1, h - y) : rightTileH
                    out[slot] = TwitchStageTileGeometry(
                        slot: slot,
                        rect: CGRect(x: rightX, y: y, width: rightW, height: resolvedH),
                        zIndex: 0,
                        role: .grid,
                        cornerRadius: 0,
                        compact: w < 520,
                        tappableTile: false,
                        tappableBadge: true
                    )
                }

            case .mosaicThree:
                if w >= h {
                    let leftW = max(1, w * 0.62)
                    let rightX = leftW + spacing
                    let rightW = max(1, w - rightX)
                    let rightCount = CGFloat(max(1, others.count))
                    let rightTileH = max(1, (h - spacing * max(0, rightCount - 1)) / rightCount)

                    out[activeSpotlight] = TwitchStageTileGeometry(
                        slot: activeSpotlight,
                        rect: CGRect(x: 0, y: 0, width: leftW, height: h),
                        zIndex: 0,
                        role: .grid,
                        cornerRadius: 0,
                        compact: false,
                        tappableTile: false,
                        tappableBadge: true
                    )
                    for (i, slot) in others.enumerated() {
                        let y = CGFloat(i) * (rightTileH + spacing)
                        let resolvedH = (i == others.count - 1) ? max(1, h - y) : rightTileH
                        out[slot] = TwitchStageTileGeometry(
                            slot: slot,
                            rect: CGRect(x: rightX, y: y, width: rightW, height: resolvedH),
                            zIndex: 0,
                            role: .grid,
                            cornerRadius: 0,
                            compact: w < 520,
                            tappableTile: false,
                            tappableBadge: true
                        )
                    }
                } else {
                    let topH = max(1, h * 0.56)
                    let bottomY = topH + spacing
                    let bottomH = max(1, h - bottomY)
                    let bottomCount = CGFloat(max(1, others.count))
                    let bottomTileW = max(1, (w - spacing * max(0, bottomCount - 1)) / bottomCount)

                    out[activeSpotlight] = TwitchStageTileGeometry(
                        slot: activeSpotlight,
                        rect: CGRect(x: 0, y: 0, width: w, height: topH),
                        zIndex: 0,
                        role: .grid,
                        cornerRadius: 0,
                        compact: false,
                        tappableTile: false,
                        tappableBadge: true
                    )
                    for (i, slot) in others.enumerated() {
                        let x = CGFloat(i) * (bottomTileW + spacing)
                        let resolvedW = (i == others.count - 1) ? max(1, w - x) : bottomTileW
                        out[slot] = TwitchStageTileGeometry(
                            slot: slot,
                            rect: CGRect(x: x, y: bottomY, width: resolvedW, height: bottomH),
                            zIndex: 0,
                            role: .grid,
                            cornerRadius: 0,
                            compact: w < 520,
                            tappableTile: false,
                            tappableBadge: true
                        )
                    }
                }

            case .splitHorizontal:
                let n = CGFloat(max(1, slots.count))
                let tileW = max(1, (w - spacing * max(0, n - 1)) / n)
                for (i, slot) in slots.enumerated() {
                    let x = CGFloat(i) * (tileW + spacing)
                    let resolvedW = (i == slots.count - 1) ? max(1, w - x) : tileW
                    out[slot] = TwitchStageTileGeometry(
                        slot: slot,
                        rect: CGRect(x: x, y: 0, width: resolvedW, height: h),
                        zIndex: 0,
                        role: .grid,
                        cornerRadius: 0,
                        compact: false,
                        tappableTile: false,
                        tappableBadge: true
                    )
                }

            case .splitVertical:
                let n = CGFloat(max(1, slots.count))
                let tileH = max(1, (h - spacing * max(0, n - 1)) / n)
                for (i, slot) in slots.enumerated() {
                    let y = CGFloat(i) * (tileH + spacing)
                    let resolvedH = (i == slots.count - 1) ? max(1, h - y) : tileH
                    out[slot] = TwitchStageTileGeometry(
                        slot: slot,
                        rect: CGRect(x: 0, y: y, width: w, height: resolvedH),
                        zIndex: 0,
                        role: .grid,
                        cornerRadius: 0,
                        compact: false,
                        tappableTile: false,
                        tappableBadge: true
                    )
                }
            }
            return out
        }
    }
}


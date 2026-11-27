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
}

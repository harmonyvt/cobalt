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

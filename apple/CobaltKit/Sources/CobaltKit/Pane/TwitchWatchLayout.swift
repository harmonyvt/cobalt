import CoreGraphics

/// Pure layout decisions for `TwitchStreamPage` across every device posture and pane shape.
///
/// The watch surface always renders the same three parts — video/TV stage, unified stream bar, and
/// live chat — arranged into two predictable geometries (stacked or side-by-side) rather than
/// morphing into separate screens per posture.
public enum TwitchWatchLayout: Equatable, Sendable {
    /// Video + stream bar stacked over live chat (iPhone portrait, folded Duo, Duo wide `screen`, iPad/Mac column).
    case stacked(videoMaxHeight: CGFloat?)
    /// Video + stream bar beside live chat (Duo tall `screen`, landscape iPhone sheet, iPad/Mac spanned).
    case sideBySide(chatWidth: CGFloat)

    /// Minimum container width to switch a single landscape container (`.tall` in a rotated iPhone sheet) to side-by-side.
    public static let sideBySideMinWidth: CGFloat = 560
    /// Aspect threshold (`width > height * ratio`) for switching a single container to side-by-side.
    public static let sideBySideAspect: CGFloat = 1.15
    /// Width at or above which the stream bar uses a single horizontal row (identity leading, controls trailing).
    public static let inlineBarMinWidth: CGFloat = 480
    /// Clamped chat column width range in side-by-side layouts.
    public static let chatMinWidth: CGFloat = 280
    public static let chatMaxWidth: CGFloat = 400
    /// Target chat share of width in side-by-side layouts before clamping.
    public static let chatFraction: CGFloat = 0.42
    /// Maximum share of height the stacked 16:9 player may take, keeping live chat and the composer visible.
    public static let stackedVideoMaxHeightFraction: CGFloat = 0.38
    /// Floor for the stacked video cap so playback stays watchable even with the software keyboard up.
    public static let stackedVideoMinCap: CGFloat = 140
    /// Target chat share of width in single-focus Unfolded Wide watch (~62% video / 38% chat).
    public static let singleFocusChatFraction: CGFloat = 0.38
    /// Video height range in stacked postures while the software keyboard is active (Keyboard-Open Guarantee).
    public static let keyboardVideoMinHeight: CGFloat = 132
    public static let keyboardVideoMaxHeight: CGFloat = 180
    public static let keyboardVideoHeightFraction: CGFloat = 0.34

    /// Resolves how a single-container watch pane (`.tall` or `.wide`) arranges video, stream bar, and chat.
    ///
    /// - Parameters:
    ///   - isWideShape: `true` when `PaneShape == .wide` (Duo tall `screen`, iPad/Mac spanned, or single-focus wide).
    ///   - size: The measured container size (`CGSize.zero` before the first layout pass).
    public static func resolve(isWideShape: Bool, size: CGSize) -> TwitchWatchLayout {
        let measured = size.width > 0 && size.height > 0
        let landscapeCompact = measured && size.width >= sideBySideMinWidth && size.width > size.height * sideBySideAspect
        if isWideShape || landscapeCompact {
            return .sideBySide(chatWidth: chatWidth(for: size.width))
        }
        return .stacked(videoMaxHeight: stackedVideoMaxHeight(for: size))
    }

    /// Adaptive chat column width for side-by-side layouts: compact on Duo tall (~281 pt), desktop-proportioned on Mac/iPad (400 pt).
    public static func chatWidth(for totalWidth: CGFloat) -> CGFloat {
        guard totalWidth > 0 else { return 320 }
        let proposed = (totalWidth * chatFraction).rounded()
        let upperBound = min(chatMaxWidth, max(chatMinWidth, (totalWidth * 0.48).rounded()))
        return min(max(proposed, chatMinWidth), upperBound)
    }

    /// Adaptive chat column width for single-focus full-canvas wide layouts (~62% video / 38% chat, clamped 280–400 pt).
    public static func singleFocusChatWidth(for totalWidth: CGFloat) -> CGFloat {
        guard totalWidth > 0 else { return 340 }
        let proposed = (totalWidth * singleFocusChatFraction).rounded()
        let upperBound = min(chatMaxWidth, max(chatMinWidth, (totalWidth * 0.44).rounded()))
        return min(max(proposed, chatMinWidth), upperBound)
    }

    /// Maximum height for the 16:9 player in stacked mode: full 16:9 width on tall panes, capped on shorter/keyboard panes.
    public static func stackedVideoMaxHeight(for size: CGSize) -> CGFloat? {
        guard size.width > 0, size.height > 0 else { return nil }
        let natural = size.width * 9 / 16
        let cap = max(stackedVideoMinCap, (size.height * stackedVideoMaxHeightFraction).rounded())
        return min(natural, cap)
    }

    /// Keyboard-aware stacked video height cap guaranteeing live video + readable chat + composer + keyboard
    /// all remain comfortably visible simultaneously.
    public static func stackedVideoMaxHeight(for size: CGSize, keyboardOpen: Bool) -> CGFloat? {
        guard keyboardOpen else { return stackedVideoMaxHeight(for: size) }
        guard size.width > 0, size.height > 0 else { return nil }
        let natural = size.width * 9 / 16
        let proposed = (size.height * keyboardVideoHeightFraction).rounded()
        let cap = min(keyboardVideoMaxHeight, max(keyboardVideoMinHeight, proposed))
        return min(natural, cap)
    }

    /// Whether the separate stream bar should condense into compact Clear Liquid Glass controls overlaid on the video
    /// stage (Tabletop above the crease, or stacked portrait while the software keyboard is open).
    public static func compactOverlayStreamBar(isStacked: Bool, isTabletop: Bool, keyboardOpen: Bool) -> Bool {
        isTabletop || (isStacked && keyboardOpen)
    }

    /// Whether the stream bar sits on one horizontal row (identity leading, controls trailing) instead of two rows.
    public static func isInlineStreamBar(width: CGFloat, accessibilityText: Bool) -> Bool {
        !accessibilityText && width >= inlineBarMinWidth
    }
}

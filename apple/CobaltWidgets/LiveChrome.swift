import SwiftUI

// What the job island (`JobLiveActivity`, `SwarmLiveViews`) shares: the two inks, the mono type, the star mark, the small
// action capsules and the Lock Screen's budget (CONTRACT-JOBLIVE.md 5). Live Activities only animate what the system
// animates on a state change; nothing here loops.

// MARK: - the Lock Screen's budget

/// iOS gives the Lock Screen presentation at most ~160 pt of height and clips what lies beyond it, from both ends (a taller
/// card loses its top row and its buttons); it adds no padding of its own, so the card pads itself:
///
///     160 pt card = 12 pt top + 136 pt content + 12 pt bottom
///
/// Rows are one line each, and what cannot shrink is dropped rather than wrapped. Dynamic Type is clamped to
/// `largestType` because the card cannot grow with it.
enum LiveLock {
    /// What iOS allows the Lock Screen presentation.
    static let height: CGFloat = 160
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 12
    /// Space between rows.
    static let gap: CGFloat = 6
    /// The largest text size the card honours: one step above this and the in-progress card would no longer fit its 160 pt.
    static let largestType = DynamicTypeSize.xLarge
}

// MARK: - ink

/// The two inks and the track, one set per luminance. The Always-On Lock Screen asks for a dimmer card: the same layout,
/// lower contrast, no filled pills.
struct LiveInk {
    var reduced = false

    var primary: Color { Color(hex: 0xe1e1e1, opacity: reduced ? 0.72 : 1) }
    var secondary: Color { Color(hex: 0x8f8f8f, opacity: reduced ? 0.8 : 1) }
    var track: Color { Color.white.opacity(reduced ? 0.07 : 0.12) }
    var ring: Color { Color.white.opacity(reduced ? 0.14 : 0.24) }
}

func liveFont(_ size: CGFloat, _ weight: CobaltFont.Weight = .regular) -> Font {
    Font.cobalt(size, weight, relativeTo: .caption)
}

// MARK: - pieces

/// The star motif, small: a core, a soft halo and one ring. The app's star gathers rings for every frame read; here it is
/// only the mark.
struct LiveStar: View {
    var size: CGFloat = 14
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        ZStack {
            Circle().fill(RadialGradient(
                colors: [ink.primary.opacity(0.55), ink.primary.opacity(0)],
                center: .center, startRadius: 0, endRadius: size / 2))
            Circle().strokeBorder(ink.primary.opacity(0.5), lineWidth: 0.75).frame(width: size * 0.72, height: size * 0.72)
            Circle().fill(ink.primary).frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "open" and "copy link": a small capsule that opens the app through its URL scheme.
struct LiveActionLink: View {
    let destination: URL
    let title: String
    let symbol: String
    let prominent: Bool
    /// The Lock Screen's buttons: a little shorter, so the whole done card fits its 160 pt.
    var compact = false

    var body: some View {
        Link(destination: destination) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(liveFont(11.5, .semibold))
                .lineLimit(1)
                .foregroundStyle(prominent ? Color.black : Color(hex: 0xe1e1e1))
                .padding(.horizontal, compact ? 11 : 12)
                .frame(height: compact ? 26 : 28)
                .background {
                    if prominent { Capsule().fill(Color(hex: 0xe1e1e1)) }
                    else { Capsule().strokeBorder(Color(hex: 0x8f8f8f), lineWidth: 1) }
                }
        }
        .accessibilityLabel(title)
    }
}

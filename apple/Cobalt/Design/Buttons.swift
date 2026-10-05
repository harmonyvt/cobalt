import CobaltKit
import SwiftUI

// The one button system (CONTRACT amendment, native-HIG + Liquid Glass pass).
//
//   primary      .buttonStyle(.cobaltPrimary())    system `.glassProminent`, cobalt monochrome tint
//                                                  (black fill + white label in light, #e1e1e1 fill +
//                                                  black label in dark). One per card.
//   secondary    .buttonStyle(.cobaltSecondary())  system `.glass`
//   done         .buttonStyle(.cobaltDone())       `.glassProminent` in success green with a black
//                                                  label (copied, saved, link copied)
//   destructive  role: .destructive                on any of the above: the system paints it red
//   icon         CloseButton / toolbar buttons     system `.glass` circle, or the bar's own style
//   circles      CircleButtonStyle                 the ONLY custom-styled buttons (paste, file)
//
// Every style wraps the system shape rather than hand-drawing one: size comes from `controlSize`
// (`.large` on iOS so a card action is at least 44 pt, `.regular` on the Mac), the corner shape is a
// capsule on iOS and the platform's own on the Mac, and press, focus, hover, Increase Contrast and
// Reduce Transparency are the system's.

struct CobaltButtonStyle: PrimitiveButtonStyle {
    enum Kind { case primary, secondary, done }

    var kind: Kind = .primary
    /// Fills the width of its container (card actions). Inline buttons turn it off.
    var fullWidth = true
    /// A step smaller, for buttons that sit in a row beside other controls.
    var compact = false

    private var size: ControlSize {
        #if os(iOS)
        return compact ? .regular : .large
        #else
        return compact ? .small : .regular
        #endif
    }

    /// Compact buttons still clear 44 pt on iOS.
    private var minHeight: CGFloat? {
        #if os(iOS)
        return compact ? Metrics.hit : nil
        #else
        return nil
        #endif
    }

    private var font: Font { compact ? CobaltType.buttonSmall : CobaltType.button }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .primary:
            base(configuration, ink: CobaltColor.onText).buttonStyle(.glassProminent).tint(CobaltColor.text)
        case .done:
            base(configuration, ink: .black).buttonStyle(.glassProminent).tint(CobaltColor.success)
        case .secondary:
            #if os(macOS)
            // On the Mac a glass button over the glass card washes out to a pale slab with a pale
            // label; the platform's own bordered button keeps its contrast in both appearances.
            base(configuration, ink: nil).buttonStyle(.bordered)
            #else
            base(configuration, ink: nil).buttonStyle(.glass)
            #endif
        }
    }

    private func base(_ configuration: Configuration, ink: Color?) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(font)
                .foregroundStyle(ink ?? .primary)
                .lineLimit(1)
                // A label is never wrapped or cut: it keeps its natural width, and a `ButtonRow`
                // stacks its buttons when they would not fit side by side.
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: minHeight)
        }
        .controlSize(size)
        #if os(iOS)
        .buttonBorderShape(.capsule)
        #endif
    }
}

extension PrimitiveButtonStyle where Self == CobaltButtonStyle {
    static func cobaltPrimary(fullWidth: Bool = true, compact: Bool = false) -> CobaltButtonStyle {
        CobaltButtonStyle(kind: .primary, fullWidth: fullWidth, compact: compact)
    }
    static func cobaltSecondary(fullWidth: Bool = true, compact: Bool = false) -> CobaltButtonStyle {
        CobaltButtonStyle(kind: .secondary, fullWidth: fullWidth, compact: compact)
    }
    static func cobaltDone(fullWidth: Bool = true, compact: Bool = false) -> CobaltButtonStyle {
        CobaltButtonStyle(kind: .done, fullWidth: fullWidth, compact: compact)
    }
}

/// Buttons that share a line when they fit and stack when they do not (a label never wraps: large
/// text sizes and narrow cards fall back to a column). Inside one `GlassEffectContainer` so the
/// glass reads as one family.
struct ButtonRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { content() }
                VStack(spacing: 8) { content() }
            }
        }
    }
}

/// The round paste and file buttons: the only custom-styled buttons, kept from the boards. A
/// Liquid Glass circle tinted white on dark and black on light (`CobaltColor.circle`), interactive
/// so it presses and shimmers like the system's own glass.
struct CircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = Metrics.circle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(CobaltColor.circleInk)
            .frame(width: diameter, height: diameter)
            .glassEffect(.regular.tint(CobaltColor.circle).interactive(), in: .circle)
            .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
            .contentShape(.circle)
    }
}

/// An icon-only close button: a system glass circle, labelled for VoiceOver.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        #if os(iOS)
        .controlSize(.large)
        #endif
        .accessibilityLabel(Copy.closeA11y)
    }
}

/// An action button with its states: secondary at rest, green with a checkmark once done (the symbol
/// bounces), red when it failed, pulsing while it works.
struct StatusButton: View {
    let title: String
    let systemImage: String
    let status: ActionStatus
    /// The card's one prominent button: it rests as `.glassProminent` instead of `.glass`.
    var prominent = false
    let action: () -> Void

    private var isFailed: Bool { if case .failed = status { return true } else { return false } }

    var body: some View {
        Group {
            if status == .done {
                Button(title, systemImage: Symbol.checkmark, action: action).buttonStyle(.cobaltDone())
            } else if prominent && !isFailed {
                Button(title, systemImage: systemImage, action: action).buttonStyle(.cobaltPrimary())
            } else {
                Button(title, systemImage: isFailed ? Symbol.retry : systemImage, role: isFailed ? .destructive : nil, action: action)
                    .buttonStyle(.cobaltSecondary())
            }
        }
        .symbolBounce(on: status == .done)
        .symbolEffect(.pulse, isActive: status == .working)
        .disabled(status == .working)
    }
}

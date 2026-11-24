import CobaltKit
import SwiftUI

/// Which of the card's shapes the pipeline is in. A landed video is no longer a card: it becomes the
/// focused planet (FocusView.swift), so only the progress card, the failure and the image post remain.
enum CardKind: Equatable {
    case progress
    case failure
    case image

    /// Every card sizes to its content: a card never has a gap the content does not fill.
    var minHeight: CGFloat { 0 }

    var radius: CGFloat {
        switch self {
        case .failure: return 24
        default: return Metrics.cardRadius
        }
    }

    var isCompact: Bool { self == .failure }
}

private struct ShakeEffect: ViewModifier {
    let trigger: Int
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, dx in
                view.offset(x: dx)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-6, duration: 0.084)
                    LinearKeyframe(5, duration: 0.105)
                    LinearKeyframe(-3, duration: 0.105)
                    LinearKeyframe(0, duration: 0.126)
                }
            }
        } else {
            content
        }
    }
}

/// The card the tapped circle opens into. It is one piece of Liquid Glass that carries the same
/// `glassEffectID` as the circle that was tapped ("paste" or "file"), so inside the home's
/// `GlassEffectContainer` the circle itself grows into the card (and back). It owns the shape
/// (height, radius); what is inside comes from the caller. Under Reduce Motion the morph becomes a
/// crossfade.
struct WorkCard<Content: View>: View {
    let kind: CardKind
    /// "paste" when the paste circle opened it, "file" for the file circle.
    let glassID: String
    let glass: Namespace.ID
    let failureToken: Int
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: kind.radius, style: .continuous)
        content()
            // in: after the glass has grown; out: at once, so the card never lingers over the focus choices
            .transition(.asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.25).delay(reduceMotion ? 0 : 0.18)),
                removal: .opacity.animation(.easeOut(duration: 0.12))))
            .padding(kind == .failure ? EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 12)
                : EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, minHeight: kind.minHeight, alignment: kind.isCompact ? .leading : .topLeading)
            .glassEffect(.regular, in: shape)
            .glassEffectID(glassID, in: glass)
            .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
            .modifier(ShakeEffect(trigger: failureToken, active: kind == .failure && !reduceMotion))
            .motion(Motion.morph, value: kind, reduced: .fade)
            .transition(reduceMotion ? .opacity : .identity)
    }
}

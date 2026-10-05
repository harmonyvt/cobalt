import SwiftUI

/// The springs of CONTRACT section 6, matched by feel to the boards' cubic-beziers.
enum Motion {
    static let press = Animation.spring(duration: 0.2, bounce: 0.4)
    static let morph = Animation.spring(duration: 0.62, bounce: 0.22)
    static let orbitSize = Animation.spring(duration: 0.7, bounce: 0.18)
    static let chip = Animation.spring(duration: 0.55, bounce: 0.4)
    static let rail = Animation.spring(duration: 0.5, bounce: 0.35)
    static let develop = Animation.spring(duration: 0.6, bounce: 0.3)
    static let developFade = Animation.easeOut(duration: 0.5)
    static let bracketIn = Animation.spring(duration: 0.55, bounce: 0.4)
    static let snap = Animation.spring(duration: 0.5, bounce: 0.4)
    static let lights = Animation.easeInOut(duration: 0.3)
    static let result = Animation.spring(duration: 0.75, bounce: 0.4)
    static let orbitPop = Animation.spring(duration: 0.8, bounce: 0.45)
    static let copy = Animation.easeInOut(duration: 0.25)
    static let card = Animation.spring(duration: 0.5, bounce: 0.2)
    static let rows = Animation.spring(duration: 0.4, bounce: 0.35)
    static let dissolve = Animation.easeIn(duration: 0.42)
    static let tier = Animation.spring(duration: 0.75, bounce: 0.12)
    static let shareToApp = Animation.spring(duration: 0.6, bounce: 0.1)
    /// What every spring becomes under Reduce Motion: a short crossfade.
    static let fade = Animation.easeOut(duration: 0.2)
}

/// What an animation turns into under Reduce Motion.
enum ReducedMotion: Sendable {
    /// A 0.2 s crossfade (the default).
    case fade
    /// No animation at all (a jump).
    case jump
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    let reduced: ReducedMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? (reduced == .fade ? Motion.fade : nil) : animation, value: value)
    }
}

extension View {
    /// `.animation(_, value:)` that obeys Reduce Motion: a crossfade, or a jump.
    func motion<V: Equatable>(_ animation: Animation, value: V, reduced: ReducedMotion = .fade) -> some View {
        modifier(MotionModifier(animation: animation, value: value, reduced: reduced))
    }

    /// A haptic that obeys Settings › haptics (a nil feedback plays nothing).
    func haptic<T: Equatable>(_ feedback: SensoryFeedback, trigger: T, enabled: Bool) -> some View {
        sensoryFeedback(trigger: trigger) { _, _ in enabled ? feedback : nil }
    }

    /// A haptic that plays only when the trigger changes to a value the predicate accepts.
    func haptic<T: Equatable>(_ feedback: SensoryFeedback, trigger: T, enabled: Bool, when accepts: @escaping (T) -> Bool) -> some View {
        sensoryFeedback(trigger: trigger) { _, new in enabled && accepts(new) ? feedback : nil }
    }
}

/// A transition that is a spring-and-blur on its way in, and a plain fade under Reduce Motion.
struct DevelopModifier: ViewModifier {
    let developed: Bool
    let reduced: Bool

    func body(content: Content) -> some View {
        content
            .opacity(developed ? 1 : 0)
            .blur(radius: developed || reduced ? 0 : 8)
            .scaleEffect(developed || reduced ? 1 : 1.12)
    }
}

private struct HapticsKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// `Settings.haptics`, pushed down from the shell.
    var hapticsEnabled: Bool {
        get { self[HapticsKey.self] }
        set { self[HapticsKey.self] = newValue }
    }
}

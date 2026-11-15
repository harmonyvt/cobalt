import SwiftUI

// Skeleton loading: grey shapes where content is about to land, crossed by one soft band of light. Never a spinner, never
// blocking: the shapes take the exact room the content will, so nothing moves when it arrives. Under Reduce Motion the
// band does not move (the grey alone says "loading"). Every shimmer on screen reads the same clock, so the bands line up
// across tiles, rows and chips instead of each one sweeping on its own.

enum Skeleton {
    /// The grey of a placeholder shape (the same grey as a chip or an empty tile).
    static let fill = CobaltColor.elevated
    /// One sweep plus its rest, in seconds.
    static let period: Double = 1.8
    /// The part of the period the band is moving (the rest is a pause, so it reads calm, not busy).
    static let sweep: Double = 0.62

    /// Where the band is at `date`: -1 (off the leading edge) to 1 (off the trailing edge); nil while resting.
    static func phase(at date: Date) -> Double? {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        guard t < sweep else { return nil }
        let x = t / sweep
        // ease in and out across the shape
        let eased = x * x * (3 - 2 * x)
        return eased * 2 - 1
    }
}

/// The band of light, drawn over a shape and clipped to it.
private struct SkeletonShimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.overlay {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    GeometryReader { proxy in
                        if let phase = Skeleton.phase(at: context.date) {
                            let width = max(proxy.size.width, 1)
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0), location: 0),
                                    .init(color: .white.opacity(scheme == .dark ? 0.07 : 0.5), location: 0.5),
                                    .init(color: .white.opacity(0), location: 1),
                                ],
                                startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 0.9)
                            .offset(x: phase * width * 1.0 + width * 0.05)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .mask(content)
        } else {
            content
        }
    }
}

extension View {
    /// Crosses the view with the skeleton's band of light while `active` (still under Reduce Motion).
    func skeletonShimmer(_ active: Bool = true) -> some View {
        modifier(SkeletonShimmer(active: active))
    }
}

/// A grey rounded placeholder of a fixed size, shimmering.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat = 5

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Skeleton.fill)
            .frame(width: width, height: height)
            .skeletonShimmer()
            .accessibilityHidden(true)
    }
}

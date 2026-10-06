import CobaltKit
import SwiftUI

// The two drawn parts of the progress card (CONTRACT-ORBIT 2c): the bar and the stepper. They live in
// Design/ because the app, the share sheet and the Live Activity all draw them; each passes its own ink.

/// The colours a progress card draws with.
struct ProgressInk {
    /// Filled things: the bar, a finished dot, the step name that is current.
    var fill: Color
    /// A mark on a filled dot (the checkmark).
    var onFill: Color
    /// The bar's track and the line between dots that is not reached yet.
    var track: Color
    /// Upcoming dots and names, the "step 2 of 4" text.
    var quiet: Color
    var error: Color

    static let app = ProgressInk(
        fill: CobaltColor.text, onFill: CobaltColor.onText,
        track: CobaltColor.text.opacity(0.16), quiet: CobaltColor.captionOnElevated, error: CobaltColor.errorText)
}

// MARK: - the bar

/// A 4 pt linear bar. Determinate when the number is real (`ProgressView(value:total:)` in a monochrome
/// style); otherwise a calm sweep (still, a dim full track, under Reduce Motion or where nothing can loop).
struct StoryBar: View {
    /// 0...1, or nil for "no number".
    let fraction: Double?
    var ink: ProgressInk = .app
    /// False in a Live Activity, which can only animate what the system animates.
    var sweeps = true
    /// 4 pt on the progress card; the tray's mini cards draw it at 3.
    var height: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let fraction {
                ProgressView(value: min(1, max(0, fraction)), total: 1)
                    .progressViewStyle(MonochromeBarStyle(ink: ink))
            } else {
                IndeterminateBar(ink: ink, moving: sweeps && !reduceMotion)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct MonochromeBarStyle: ProgressViewStyle {
    let ink: ProgressInk

    func makeBody(configuration: Configuration) -> some View {
        let value = min(1, max(0, configuration.fractionCompleted ?? 0))
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.track)
                // a real 0 stays an empty bar; anything else shows at least a dot's worth
                Capsule().fill(ink.fill)
                    .frame(width: value <= 0 ? 0 : max(proxy.size.height, proxy.size.width * value))
            }
            .animation(.linear(duration: 0.25), value: value)
        }
    }
}

private struct IndeterminateBar: View {
    let ink: ProgressInk
    let moving: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.track)
                if moving {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        // one pass every 1.8 s, easing in and out of each end
                        let phase = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8
                        let eased = phase < 0.5 ? 2 * phase * phase : 1 - pow(-2 * phase + 2, 2) / 2
                        let w = proxy.size.width * 0.34
                        Capsule().fill(ink.fill)
                            .frame(width: w)
                            .offset(x: (proxy.size.width - w) * eased)
                    }
                } else {
                    // still: a short segment mid-track says "working, no number" without moving
                    Capsule().fill(ink.fill.opacity(0.55))
                        .frame(width: proxy.size.width * 0.34)
                        .frame(maxWidth: .infinity)
                }
            }
            .clipShape(Capsule())
        }
    }
}

// MARK: - the stepper

/// Small dots joined by a line: done = filled with a checkmark, current = a ring with a gentle pulse
/// (still under Reduce Motion), upcoming = hollow. Tiny names under the dots where there is width.
/// Not a control: nothing here is tappable, selected or highlighted.
struct ProgressStepper: View {
    let story: ProgressStory
    var ink: ProgressInk = .app
    /// False in a Live Activity (nothing can loop there).
    var pulses = true
    var names = true

    @ScaledMetric(relativeTo: .caption) private var dot: CGFloat = 16
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 300

    private var showsNames: Bool {
        names && !typeSize.isAccessibilitySize && width / CGFloat(max(story.count, 1)) >= 56
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(story.steps.enumerated()), id: \.offset) { i, step in
                column(i, step)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .motion(.easeOut(duration: 0.3), value: story.index, reduced: .jump)
        .motion(.easeOut(duration: 0.3), value: story.finished, reduced: .jump)
        .motion(.easeOut(duration: 0.3), value: story.waiting, reduced: .jump)
        .accessibilityHidden(true)
    }

    private func column(_ i: Int, _ step: Rail.Step) -> some View {
        let state = dotState(i)
        return VStack(spacing: 4) {
            ZStack {
                HStack(spacing: 0) {
                    segment(i > 0 && reached(i))
                        .opacity(i == 0 ? 0 : 1)
                    Color.clear.frame(width: dot + 6, height: 1)
                    segment(i < story.count - 1 && reached(i + 1))
                        .opacity(i == story.count - 1 ? 0 : 1)
                }
                StepDot(state: state, size: dot, ink: ink, pulses: pulses && !reduceMotion && !story.waiting)
            }
            .frame(height: dot + 4)
            if showsNames {
                Text(Copy.step(step))
                    .font(state == .current ? Font.cobalt(11, .semibold, relativeTo: .caption2) : CobaltType.tab)
                    .foregroundStyle(state == .upcoming || state == .failed ? ink.quiet : ink.fill)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Has the run reached step `i` (its dot is done or current)?
    private func reached(_ i: Int) -> Bool { story.finished || i <= story.index && !(story.awaiting && i == story.index) }

    private func segment(_ on: Bool) -> some View {
        Rectangle().fill(on ? ink.fill : ink.track).frame(height: 2)
    }

    private func dotState(_ i: Int) -> StepDot.State {
        if story.finished || i < story.index { return .done }
        if i == story.index, !story.awaiting { return story.failed ? .failed : .current }
        return .upcoming
    }
}

private struct StepDot: View {
    enum State: Equatable { case done, current, upcoming, failed }
    let state: State
    let size: CGFloat
    let ink: ProgressInk
    let pulses: Bool

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(ink.fill)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(ink.onFill)
            case .current:
                if pulses { PulseHalo(color: ink.fill, size: size) }
                Circle().strokeBorder(ink.fill, lineWidth: 2)
                Circle().fill(ink.fill).frame(width: size * 0.32, height: size * 0.32)
            case .upcoming:
                Circle().strokeBorder(ink.quiet.opacity(0.75), lineWidth: 1.5)
            case .failed:
                Circle().strokeBorder(ink.error, lineWidth: 2)
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.42, weight: .heavy))
                    .foregroundStyle(ink.error)
            }
        }
        .frame(width: size, height: size)
        .transition(.opacity)
    }
}

/// The current dot's pulse: a soft disc that grows and fades once every 1.6 s.
private struct PulseHalo: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 1.6) / 1.6
            let out = 1 - pow(1 - phase, 2)
            Circle()
                .fill(color)
                .opacity(0.3 * (1 - out))
                .scaleEffect(1 + 0.9 * out)
        }
        .frame(width: size, height: size)
    }
}

import CobaltKit
import SwiftUI
import WidgetKit

// The Live Activity's Lock Screen card (also the banner a push shows).
//
// iOS gives the Lock Screen presentation at most ~160 pt of height and clips what lies beyond it, from
// both ends (a taller card loses its top row and its buttons); it adds no padding of its own, so this
// card pads itself. Everything here is built to a budget:
//
//   160 pt card = 12 pt top + 136 pt content + 12 pt bottom
//
// and every state is measured against it (see `LiveLock`). The rows are one line each, and what cannot
// shrink is dropped rather than wrapped: step names under the dots, the waking footnote, the done card's
// stepper. Dynamic Type is clamped to `LiveLock.largestType` because the card cannot grow with it.

enum LiveLock {
    /// What iOS allows the Lock Screen presentation.
    static let height: CGFloat = 160
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 12
    /// Space between rows.
    static let gap: CGFloat = 6
    /// The largest text size the card honours: one step above this and the in-progress card would no
    /// longer fit its 160 pt. (The harness renders the card at xxxLarge to prove the clamp holds.)
    static let largestType = DynamicTypeSize.xLarge
    /// The stepper's dot: fixed, it does not scale with text.
    static let dot: CGFloat = 14
    /// Step names are drawn up to this size; beyond it only the dots and "step n of 4" remain.
    static let namesUpTo = DynamicTypeSize.large
}

struct LiveLockScreenView: View {
    let facts: LiveFacts
    @Environment(\.isLuminanceReduced) private var reduced
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        let story = facts.story
        VStack(alignment: .leading, spacing: LiveLock.gap) {
            VStack(alignment: .leading, spacing: LiveLock.gap) {
                header(ink)
                if facts.isDone {
                    LiveLockDone(facts: facts)
                } else {
                    progress(story, ink)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Copy.progressA11y)
            .accessibilityValue(facts.showsStale ? "\(story.spoken), \(Copy.Live.waitingForCobalt)" : story.spoken)
            // outside the combined element so the two links stay reachable
            if facts.isDone && !reduced {
                LiveActions(facts: facts, compact: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LiveLock.horizontalPadding)
        .padding(.vertical, LiveLock.verticalPadding)
        .dynamicTypeSize(...LiveLock.largestType)
        .widgetURL(facts.openURL)
    }

    // MARK: rows

    /// Star, source and the clock (or the ✓ / ! of a finished run), on one line.
    private func header(_ ink: LiveInk) -> some View {
        HStack(spacing: 8) {
            LiveStar()
            Text(facts.source)
                .font(liveFont(12))
                .foregroundStyle(ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if facts.isTerminal {
                LiveMetricView(metric: .symbol(facts.isFailed ? Symbol.liveFailed : Symbol.liveDone), size: 12)
            } else {
                LiveTimer(since: facts.since, size: 12)
            }
        }
    }

    /// Headline, detail with "step n of 4", the bar and the stepper (a run in progress or a failed one).
    @ViewBuilder
    private func progress(_ story: ProgressStory, _ ink: LiveInk) -> some View {
        let failed = facts.isFailed
        Text(story.headline)
            .font(liveFont(failed ? 13 : 15, .semibold))
            .foregroundStyle(ink.primary)
            .lineLimit(failed ? 2 : 1)
            .truncationMode(.tail)
            .minimumScaleFactor(failed ? 1 : 0.75)
            .fixedSize(horizontal: false, vertical: failed)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if facts.showsStale {
                Text(Copy.Live.waitingForCobalt)
                    .font(liveFont(12))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                LiveDetailLine(story: story)
            }
            Spacer(minLength: 0)
            Text(story.stepText)
                .font(liveFont(12))
                .monospacedDigit()
                .foregroundStyle(ink.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
        }
        if !facts.isTerminal && !facts.showsStale && story.phase != .ready {
            StoryBar(fraction: story.fraction, ink: ink.progress, sweeps: false)
        }
        // A failed card is already two lines of reason: its stepper stays dots only.
        LiveStepper(story: story, ink: ink.progress, names: !failed && typeSize <= LiveLock.namesUpTo)
    }
}

// MARK: - done

/// The finished webp: "webp ready" and `480×270 · 10.1 s · 918 KB` on one row (two short lines where
/// the row would not fit), then the link as a single middle-truncated line. No stepper: with every dot
/// checked it says nothing the ✓ in the header does not.
struct LiveLockDone: View {
    let facts: LiveFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        let title = facts.story.headline
        let result = Copy.Live.result(facts.state)
        VStack(alignment: .leading, spacing: LiveLock.gap) {
            if let result {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleText(title, ink).fixedSize()
                        Spacer(minLength: 8)
                        resultText(result, ink).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        titleText(title, ink)
                        resultText(result, ink)
                    }
                }
            } else {
                titleText(title, ink)
            }
            if let url = facts.state.resultURL {
                Text(Copy.Live.link(url))
                    .font(liveFont(11.5))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func titleText(_ text: String, _ ink: LiveInk) -> some View {
        Text(text)
            .font(liveFont(15, .semibold))
            .foregroundStyle(ink.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private func resultText(_ text: String, _ ink: LiveInk) -> some View {
        Text(text)
            .font(liveFont(12, .medium))
            .monospacedDigit()
            .foregroundStyle(ink.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

// MARK: - the compact stepper

/// Dots joined by a line: done = filled with a check, current = a ring around a dot, upcoming = hollow,
/// failed = a ring with an ✕. 14 pt dots that do not scale with text; the step names under them are
/// optional (the Lock Screen has the height for them only at the default text size).
/// Not a control, and nothing in it moves: a Live Activity only animates what the system animates.
struct LiveStepper: View {
    let story: ProgressStory
    var ink: ProgressInk
    var names = true

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(story.steps.enumerated()), id: \.offset) { i, step in
                column(i, step)
            }
        }
        .accessibilityHidden(true)
    }

    private func column(_ i: Int, _ step: Rail.Step) -> some View {
        let state = dotState(i)
        let dot = LiveLock.dot
        return VStack(spacing: 3) {
            ZStack {
                HStack(spacing: 0) {
                    segment(i > 0 && reached(i)).opacity(i == 0 ? 0 : 1)
                    Color.clear.frame(width: dot + 6, height: 1)
                    segment(i < story.count - 1 && reached(i + 1)).opacity(i == story.count - 1 ? 0 : 1)
                }
                LiveStepDot(state: state, size: dot, ink: ink)
            }
            .frame(height: dot)
            if names {
                Text(Copy.step(step))
                    .font(Font.cobalt(10.5, state == .current ? .semibold : .regular, relativeTo: .caption2))
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

    private func dotState(_ i: Int) -> LiveStepDot.State {
        if story.finished || i < story.index { return .done }
        if i == story.index, !story.awaiting { return story.failed ? .failed : .current }
        return .upcoming
    }
}

struct LiveStepDot: View {
    enum State: Equatable { case done, current, upcoming, failed }
    let state: State
    let size: CGFloat
    let ink: ProgressInk

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(ink.fill)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(ink.onFill)
            case .current:
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
    }
}

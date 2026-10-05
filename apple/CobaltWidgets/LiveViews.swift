import ActivityKit
import CobaltKit
import SwiftUI
import WidgetKit

// The Live Activity's views (CONTRACT-LIVE.md 2.7, CONTRACT-ORBIT 2c): monochrome on black, IBM Plex Mono
// (the system monospaced font when the files did not register), the progress card's headline, detail, bar
// and stepper, the star as a small glyph. Everything reads `LiveFacts`, a plain value made from the activity's attributes and
// content state, so every presentation (compact, minimal, expanded, Lock Screen) says the same
// thing and the previews can build any state without an `ActivityViewContext`.
//
// Live Activities only animate what the system animates on a state change (a width, a content
// transition); nothing here loops, so "the current step" is drawn as a still ring, not a pulse, and the
// indeterminate bar is a still segment.

// MARK: - what to show

struct LiveFacts {
    let attributes: CobaltActivityAttributes
    let state: LiveContentState
    var isStale = false

    /// What sits where the number goes.
    enum Metric: Equatable {
        /// A live timer from `since`: the system ticks it, no pushes needed.
        case timer(Date)
        case text(String)
        case symbol(String)
    }

    var service: String? { attributes.service.isEmpty ? nil : attributes.service }

    /// "instagram · Dd7P496wolG", or the file's name.
    var source: String { Copy.Live.source(service: attributes.service, ref: attributes.ref, input: attributes.input) }

    /// Just the service, for the narrow expanded leading slot ("instagram"); a file keeps its name.
    var shortSource: String {
        attributes.input == "file" || attributes.service == "file" || attributes.service.isEmpty
            ? attributes.ref : attributes.service
    }

    var isTerminal: Bool { state.isTerminal }
    var isFailed: Bool { state.stage == .failed }
    var isDone: Bool { state.stage == .done }
    /// A stale activity that is still running: the line says so instead of showing an old number.
    var showsStale: Bool { isStale && !isTerminal }

    var railIndex: Int { min(max(state.rail, 0), 3) }
    /// The activity does not say whether the server is plain cobalt: a run is drawn with the fork's four
    /// steps, and a plain cobalt run that finished saving on the device (done, no link) with its three.
    var railSteps: [Rail.Step] {
        let first: Rail.Step = attributes.input == "file" ? .upload : .fetch
        if state.stage == .done && state.resultURL == nil { return [first, .save, .read] }
        return [first, .save, .read, .webp]
    }

    var since: Date { Date(timeIntervalSince1970: state.since) }

    /// The progress card's value for this state: the same headline, detail, bar and steps the app shows.
    var story: ProgressStory {
        let steps = railSteps
        let index = min(railIndex, steps.count - 1)
        func make(
            _ phase: ProgressStory.Phase, _ headline: String, detail: ProgressStory.Detail? = nil,
            fraction: Double? = nil, read: Int = 0, waking: Bool = false, footnote: String? = nil
        ) -> ProgressStory {
            ProgressStory(
                phase: phase, headline: headline, detail: detail, fraction: fraction.map { min(1, max(0, $0)) },
                framesRead: read, waking: waking, footnote: footnote, steps: steps, index: index)
        }
        func ratio(_ done: Int64?, _ total: Int64?) -> Double? {
            guard let done, let total, total > 0 else { return nil }
            return Double(done) / Double(total)
        }
        let headline = Copy.Live.stage(state, service: service)
        switch state.stage {
        case .fetching:
            return make(
                .fetching, headline, detail: .elapsed(prefix: state.waking ? Copy.waking : nil, since: since),
                waking: state.waking, footnote: state.waking ? Copy.wakingNote : nil)
        case .uploading, .saving:
            let phase: ProgressStory.Phase = state.stage == .uploading ? .uploading : .saving
            var detail: ProgressStory.Detail?
            if let bytes = state.bytes {
                detail = .text(state.total.map { $0 > 0 ? Copy.bytesOf(bytes, $0) : Format.bytes(bytes) } ?? Format.bytes(bytes))
            } else {
                detail = .elapsed(prefix: nil, since: since)
            }
            return make(phase, headline, detail: detail, fraction: ratio(state.bytes, state.total))
        case .reading:
            let done = state.framesDone ?? 0
            let total = state.framesTotal
            return make(
                .reading, headline, detail: total.map { .text(Copy.frameOf(done, $0)) } ?? .elapsed(prefix: nil, since: since),
                fraction: ratio(Int64(done), total.map(Int64.init)), read: done)
        case .ready:
            // the video is read and the run waits for the trim: three steps done, none current
            var story = make(.ready, headline)
            story.index = min(railIndex + 1, steps.count)
            story.awaiting = true
            return story
        case .rendering:
            if state.packing { return make(.rendering, headline, detail: .elapsed(prefix: nil, since: since)) }
            if let done = state.framesDone, let total = state.framesTotal, total > 0 {
                return make(.rendering, headline, detail: .text(Copy.frameOf(done, total)), fraction: Double(done) / Double(total))
            }
            return make(.rendering, headline, detail: .elapsed(prefix: nil, since: since))
        case .done:
            var story = make(.finished, headline)
            story.index = steps.count
            return story
        case .failed:
            var story = make(.failed, headline)
            story.failed = true
            return story
        }
    }

    /// 0...1 for bytes and frames when the total is known; nil is indeterminate.
    var fraction: Double? { isTerminal ? nil : story.fraction }

    // MARK: deep links (CONTRACT-LIVE.md 2.7; copy is handled by the app's `onOpenURL`)

    /// Where a tap goes: the share sheet's run opens its job, any other run just opens cobalt.
    var openURL: URL {
        if attributes.origin == "share", UUID(uuidString: attributes.run) != nil {
            return URL(string: "cobalt-apple://job/\(attributes.run)") ?? Self.home
        }
        return Self.home
    }

    /// `cobalt-apple://copy?url=<link>`: the app copies the link when it opens.
    var copyURL: URL? {
        guard let link = state.resultURL else { return nil }
        var parts = URLComponents()
        parts.scheme = "cobalt-apple"
        parts.host = "copy"
        parts.queryItems = [URLQueryItem(name: "url", value: link)]
        return parts.url
    }

    private static let home = URL(string: "cobalt-apple://open")!
}

extension LiveFacts {
    init(_ context: ActivityViewContext<CobaltActivityAttributes>) {
        self.init(attributes: context.attributes, state: context.state, isStale: context.isStale)
    }
}

// MARK: - ink

/// The two inks and the track, one set per luminance. The Always-On Lock Screen asks for a dimmer
/// card: the same layout, lower contrast, no filled pills.
struct LiveInk {
    var reduced = false

    var primary: Color { Color(hex: 0xe1e1e1, opacity: reduced ? 0.72 : 1) }
    var secondary: Color { Color(hex: 0x8f8f8f, opacity: reduced ? 0.8 : 1) }
    var track: Color { Color.white.opacity(reduced ? 0.07 : 0.12) }
    var ring: Color { Color.white.opacity(reduced ? 0.14 : 0.24) }
    var onPrimary: Color { .black }
}

func liveFont(_ size: CGFloat, _ weight: CobaltFont.Weight = .regular) -> Font {
    Font.cobalt(size, weight, relativeTo: .caption)
}

// MARK: - pieces

/// The star motif, small: a core, a soft halo and one ring. The app's star gathers rings for every
/// frame read; here it is only the mark.
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

/// The ticking timer. Fixed width: a timer `Text` otherwise claims whatever the island offers.
struct LiveTimer: View {
    let since: Date
    var size: CGFloat = 12
    var weight: CobaltFont.Weight = .regular
    var width: CGFloat = 44
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        Text(since, style: .timer)
            .font(liveFont(size, weight))
            .monospacedDigit()
            .foregroundStyle(LiveInk(reduced: reduced).primary)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

/// A metric as the compact slots and the expanded trailing show it.
struct LiveMetricView: View {
    let metric: LiveFacts.Metric
    var size: CGFloat = 12
    var weight: CobaltFont.Weight = .medium
    var timerWidth: CGFloat = 44
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        switch metric {
        case .timer(let since):
            LiveTimer(since: since, size: size, weight: weight, width: timerWidth)
        case .text(let text):
            Text(text)
                .font(liveFont(size, weight))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(ink.primary)
        }
    }
}

extension LiveInk {
    /// The progress card's colours in this luminance.
    var progress: ProgressInk {
        ProgressInk(fill: primary, onFill: onPrimary, track: track, quiet: secondary, error: primary)
    }
}

/// The detail line: "2.1 of 4.3 MB", "frame 42 of 150", "waking the server · 4 s". A bare elapsed time is
/// left out (the header's timer already counts it).
struct LiveDetailLine: View {
    let story: ProgressStory
    var size: CGFloat = 12
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        switch story.detail {
        case .text(let text):
            Text(text)
                .font(liveFont(size))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(ink.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        case .elapsed(let prefix?, let since):
            HStack(spacing: 4) {
                Text("\(prefix) ·")
                    .font(liveFont(size))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(since, style: .timer)
                    .font(liveFont(size))
                    .monospacedDigit()
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                    .frame(width: 38, alignment: .leading)
            }
        case .elapsed, nil:
            EmptyView()
        }
    }
}

/// "step 2 of 4", beside the detail.
struct LiveStepText: View {
    let story: ProgressStory
    var size: CGFloat = 12
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        Text(story.stepText)
            .font(liveFont(size))
            .monospacedDigit()
            .foregroundStyle(LiveInk(reduced: reduced).secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Compact leading: the glyph of the step the run is in (done and failed have their own mark).
struct LiveStepGlyph: View {
    let facts: LiveFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        Image(systemName: facts.isDone ? Symbol.liveDone : facts.isFailed ? Symbol.liveFailed : Symbol.step(facts.story.currentStep))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ink.primary)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

/// A tiny circular progress: the compact trailing slot (alone) and the minimal presentation (around the
/// step glyph). Determinate (bytes, frames) it fills; otherwise it is a dim full ring. Done is a solid
/// disc with a check, failed a ring with a mark.
struct LiveRing: View {
    let facts: LiveFacts
    /// The step's glyph in the middle (the minimal island); the compact trailing slot is the ring alone.
    var glyph = true
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        ZStack {
            if facts.isDone {
                Circle().fill(ink.primary)
                Image(systemName: Symbol.liveDone).font(.system(size: 9, weight: .bold)).foregroundStyle(ink.onPrimary)
            } else if facts.isFailed {
                Circle().strokeBorder(ink.primary, lineWidth: 2)
                Image(systemName: Symbol.liveFailed).font(.system(size: 10, weight: .bold)).foregroundStyle(ink.primary)
            } else {
                Circle().strokeBorder(ink.ring, lineWidth: 2)
                if let fraction = facts.fraction {
                    Circle()
                        .trim(from: 0, to: max(0.04, fraction))
                        .stroke(ink.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1)
                }
                if glyph {
                    Image(systemName: Symbol.step(facts.story.currentStep))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ink.primary)
                }
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// "copy link" and "open": two small capsules that open the app through its URL scheme.
struct LiveActions: View {
    let facts: LiveFacts
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            if let copy = facts.copyURL {
                LiveActionLink(destination: copy, title: Copy.Live.copyLink, symbol: Symbol.copyLink, prominent: true, compact: compact)
            }
            LiveActionLink(destination: facts.openURL, title: Copy.Live.open, symbol: Symbol.openApp, prominent: false, compact: compact)
        }
    }
}

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

/// The finished webp: `480×854 · 10.1 s · 4.5 MB`, the link without its scheme, and the actions.
struct LiveDoneDetails: View {
    let facts: LiveFacts
    var actions: Bool
    var compact = false
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let line = Copy.Live.result(facts.state) {
                    Text(line).font(liveFont(12, .medium)).foregroundStyle(ink.primary).monospacedDigit().lineLimit(1)
                }
                if let url = facts.state.resultURL {
                    Text(Copy.Live.link(url))
                        .font(liveFont(11.5))
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if actions && !reduced { LiveActions(facts: facts, compact: compact) }
        }
    }
}

// MARK: - the activity

struct LiveExpandedCenter: View {
    let facts: LiveFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        Text(facts.story.headline)
            .font(liveFont(facts.isFailed ? 12.5 : 14, .semibold))
            .foregroundStyle(LiveInk(reduced: reduced).primary)
            .lineLimit(facts.isFailed ? 2 : 1)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.center)
    }
}

/// Expanded bottom: the detail and "step n of 4", the bar (or the finished webp).
struct LiveExpandedBottom: View {
    let facts: LiveFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        let story = facts.story
        VStack(alignment: .leading, spacing: 8) {
            // a finished run says "done" in the center and the check at the right already
            if !facts.isDone {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if facts.showsStale {
                        Text(Copy.Live.waitingForCobalt).font(liveFont(11.5)).foregroundStyle(ink.secondary).lineLimit(1)
                    } else {
                        LiveDetailLine(story: story, size: 11.5)
                    }
                    Spacer(minLength: 0)
                    LiveStepText(story: story, size: 11.5)
                }
            }
            if facts.isDone {
                LiveDoneDetails(facts: facts, actions: true, compact: true)
            } else if !facts.isTerminal && !facts.showsStale && story.phase != .ready {
                StoryBar(fraction: story.fraction, ink: ink.progress, sweeps: false)
            }
        }
        .padding(.top, 4)
        .dynamicTypeSize(...LiveLock.largestType)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Copy.progressA11y)
        .accessibilityValue(story.spoken)
    }
}

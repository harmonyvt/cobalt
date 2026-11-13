import ActivityKit
import CobaltKit
import SwiftUI
import WidgetKit

// The one Live Activity for every job (apple/CONTRACT-JOBLIVE.md): a save, an upload, a webp, an editor render, a chat
// reply, or several of them at once. The server writes every word (headline, detail, compact text, result); this file only
// draws `JobLiveState`. It never decides what a step is called or what a failure means.
//
// The Lock Screen card, top to bottom:
//
//   star, title, [agent], ............ clock (or a mark once it ended)
//   headline                           16 pt, semibold; red when it failed or was lost
//   detail                             13 pt, grey, tabular numbers
//   ======== bar ========             5 pt; working and waiting only; a still segment when there is no number
//   o download  o store  o publish     one 8 pt dot per step the job really has (never "step n of N")
//   [open] [copy link]                 done only
//
// "Several at once" (any state with rows) swaps the dots for up to three one-line rows.
//
// Looks: the app's own tokens, not the mockup's. The mockup's mono type is IBM Plex Mono through `liveFont` (as the
// other widgets), and its "accent" is the app's one ink (0xe1e1e1 on black, `LiveInk.primary`); green and red are the app's
// `success` and (dark) `errorText`. Live Activities only animate what the system animates, so the bar's no-number state is
// a still segment (`StoryBar`'s own, as in the other widgets), not a sliding one.

struct JobLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CobaltJobActivityAttributes.self) { context in
            JobLockScreenView(facts: JobFacts(context))
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(Color(hex: 0xe1e1e1))
        } dynamicIsland: { context in
            let facts = JobFacts(context)
            return DynamicIsland {
                // Top: star, the headline, and the clock or mark.
                DynamicIslandExpandedRegion(.leading) { LiveStar() }
                DynamicIslandExpandedRegion(.center) { JobExpandedHeadline(facts: facts) }
                DynamicIslandExpandedRegion(.trailing) { JobClock(facts: facts, size: 12) }
                // Below: the detail and a small bar.
                DynamicIslandExpandedRegion(.bottom) { JobExpandedBottom(facts: facts) }
            } compactLeading: {
                JobCompactLeading(facts: facts)
            } compactTrailing: {
                JobCompactTrailing(facts: facts)
            } minimal: {
                JobRing(facts: facts)
            }
            .keylineTint(Color(hex: 0xe1e1e1).opacity(0.35))
            .widgetURL(facts.openURL)
        }
    }
}

// MARK: - what to show

/// A plain value made from the activity's attributes and state, so every presentation says the same thing and the
/// previews can build any state without an `ActivityViewContext`.
struct JobFacts {
    let attributes: JobLiveAttributes
    let state: JobLiveState
    /// The system says the activity has not been updated since its `staleDate`.
    var isStale = false

    init(attributes: JobLiveAttributes, state: JobLiveState, isStale: Bool = false) {
        self.attributes = attributes
        self.state = state
        self.isStale = isStale
    }

    init(_ context: ActivityViewContext<CobaltJobActivityAttributes>) {
        self.init(attributes: context.attributes.job, state: context.state, isStale: context.isStale)
    }

    // MARK: phase

    var isDone: Bool { state.phase == .done }
    var isFailed: Bool { state.phase == .failed }
    var isLost: Bool { state.phase == .lost }
    var isTerminal: Bool { state.isTerminal }
    /// Red words and a red current dot: it did not finish.
    var isBad: Bool { isFailed || isLost }
    /// No news for a while: the server said so (`quiet`), or the system marked the activity stale. Never for a job that
    /// already ended.
    var isQuiet: Bool { !isTerminal && (state.phase == .quiet || isStale) }

    // MARK: words (all from the server; only the quiet text is ours, it is fixed in CONTRACT-JOBLIVE 3)

    /// The source line: "twitch · KindStupidClip", "IMG_0412.mov", "3 jobs".
    /// The source line. Several jobs at once say how many from the state, not the attributes: a busy period that kept
    /// the first run's activity still has that run's title, and a period's own activity froze its count when it began.
    var title: String {
        guard showsRows else { return attributes.title }
        // compact is "done/total" for several jobs; fall back to the rows shown
        let total = state.compact?.split(separator: "/").last.flatMap { Int($0) } ?? rows.count
        return "\(total) jobs"
    }
    var headline: String { isQuiet ? "still working, no news for 3 min" : state.headline }
    /// A finished job's detail is its result line ("1280×720 · 30 s · 8.9 MB"); a chat reply has only the first words.
    var detail: String? {
        if isQuiet { return showsRows ? nil : "open capystore to check on it" }
        if isDone { return state.result ?? state.detail }
        return state.detail
    }

    var since: Date { Date(timeIntervalSince1970: state.since) }

    // MARK: bar, rows, dots

    /// The bar is for a job still going (working, waiting, quiet); nil number = no known fraction.
    var showsBar: Bool { !isTerminal }
    /// A quiet job has no trustworthy number, so its bar has none either.
    var barFraction: Double? { isQuiet ? nil : state.fraction }
    var isChat: Bool { attributes.kind == "chat" }

    /// Several at once: at most three rows, newest first as the app wrote them.
    var rows: [JobLiveState.Row] { Array((state.rows ?? []).prefix(3)) }
    /// Rows decide the layout, not the kind: a busy period may write its rows into the first run's activity, whose
    /// kind stays "save" (attributes never change once an activity starts).
    var showsRows: Bool { !rows.isEmpty }

    enum Dot: Equatable { case done, current, failed, upcoming }

    /// Done steps are before the current one; when the job is done every step is done.
    func dot(_ i: Int) -> Dot {
        if isDone || i < state.step { return .done }
        if i == state.step { return isBad ? .failed : .current }
        return .upcoming
    }

    /// A finished job has its buttons, except Always-On, where nothing can be tapped.
    func showsActions(reduced: Bool) -> Bool { isDone && !reduced }

    // MARK: links

    /// A tap: the job's own link, else the library.
    var openURL: URL {
        attributes.open.flatMap(URL.init(string:)) ?? URL(string: "cobalt-apple://library")!
    }

    /// Widgets cannot write to the clipboard. The app's `handleAppLink` copies `cobalt-apple://copy?url=<link>` when it opens
    /// (the same route the old widgets' "copy link" uses; web links only).
    var copyURL: URL? {
        guard let link = state.link else { return nil }
        var parts = URLComponents()
        parts.scheme = "cobalt-apple"
        parts.host = "copy"
        parts.queryItems = [URLQueryItem(name: "url", value: link)]
        return parts.url
    }

    /// What VoiceOver reads for the whole card.
    var spoken: String {
        [title, headline, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - ink

/// The card's colours for this luminance. `reduced` is the Always-On Lock Screen: same layout, dimmer.
struct JobInk {
    var reduced = false

    private var base: LiveInk { LiveInk(reduced: reduced) }
    private var dim: Double { reduced ? 0.7 : 1 }

    /// The "accent": the app's one ink. Text on it is `onAccent`.
    var accent: Color { base.primary }
    var onAccent: Color { .black }
    var secondary: Color { base.secondary }
    var track: Color { base.track }
    var ring: Color { base.ring }
    /// `CobaltColor.success`.
    var green: Color { Color(hex: 0x30bd1b, opacity: dim) }
    /// `CobaltColor.errorText` in dark: the card is always on black, so the appearance-aware token is not used.
    var red: Color { Color(hex: 0xff5c6c, opacity: dim) }

    /// The bar's colours (the shared `StoryBar` takes a `ProgressInk`).
    var bar: ProgressInk {
        ProgressInk(fill: accent, onFill: onAccent, track: track, quiet: secondary, error: red)
    }
}

// MARK: - the Lock Screen card

struct JobLockScreenView: View {
    let facts: JobFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = JobInk(reduced: reduced)
        // One column, six points between rows; the card pads itself (iOS adds nothing) and must stay in 160 pt.
        VStack(alignment: .leading, spacing: LiveLock.gap) {
            VStack(alignment: .leading, spacing: LiveLock.gap) {
                JobTopLine(facts: facts)
                Text(facts.headline)
                    .font(liveFont(16, .semibold))
                    .foregroundStyle(facts.isBad ? ink.red : LiveInk(reduced: reduced).primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let detail = facts.detail {
                    Text(detail)
                        .font(liveFont(13))
                        .monospacedDigit()
                        .foregroundStyle(ink.secondary)
                        // A result line is short and sits above two rows (dots, buttons): one line. A reason or a reply
                        // may take two.
                        .lineLimit(facts.isDone && facts.state.result != nil ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if facts.showsBar {
                    StoryBar(fraction: facts.barFraction, ink: ink.bar, sweeps: false, height: 5)
                }
                if facts.showsRows {
                    JobRows(rows: facts.rows)
                } else if !facts.showsActions(reduced: reduced) {
                    JobSteps(facts: facts)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(facts.spoken)
            // Outside the combined element so the two links stay reachable. Not drawn Always-On: it cannot be tapped there.
            if facts.showsActions(reduced: reduced) {
                // The dots (all green) share a row with the buttons when they fit, else the buttons go below: the card
                // has no height for both rows once a reply or a result wraps to two lines.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        JobSteps(facts: facts)
                        JobActions(facts: facts)
                    }
                    VStack(alignment: .leading, spacing: LiveLock.gap) {
                        JobSteps(facts: facts)
                        JobActions(facts: facts)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LiveLock.horizontalPadding)
        .padding(.vertical, LiveLock.verticalPadding)
        // The card cannot grow with text: clamp at the budget's largest size, as the other widgets do.
        .dynamicTypeSize(...LiveLock.largestType)
        .widgetURL(facts.openURL)
    }
}

/// Star, title, the "agent" chip, and the clock (or the mark of an ended job) on the right.
struct JobTopLine: View {
    let facts: JobFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = JobInk(reduced: reduced)
        HStack(spacing: 8) {
            LiveStar()
            Text(facts.title)
                .font(liveFont(12))
                .foregroundStyle(ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if facts.attributes.agent {
                // small, accent-filled, dark text
                Text("agent")
                    .font(liveFont(10, .medium))
                    .foregroundStyle(ink.onAccent)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(ink.accent))
                    .fixedSize()
            }
            Spacer(minLength: 8)
            JobClock(facts: facts, size: 12)
        }
    }
}

/// The clock counting from `state.since` while the job goes (the system ticks it, no pushes needed); a green check when it
/// is done, a red "!" when it failed, a red "?" when it was lost.
struct JobClock: View {
    let facts: JobFacts
    var size: CGFloat
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = JobInk(reduced: reduced)
        Group {
            if facts.isDone {
                mark("checkmark", ink.green)
            } else if facts.isFailed {
                mark(Symbol.liveFailed, ink.red)
            } else if facts.isLost {
                mark("questionmark", ink.red)
            } else {
                // A timer `Text` claims whatever width the row offers, which squeezed the title. Size the slot from a
                // same-width template instead ("0:00", or "0:00:00" once the job is past an hour) and draw the live timer
                // over it, trailing: the title only gives way when the row is really full.
                Text(Date.now.timeIntervalSince(facts.since) >= 3600 ? "0:00:00" : "0:00")
                    .font(liveFont(size))
                    .monospacedDigit()
                    .hidden()
                    .overlay(alignment: .trailing) {
                        Text(facts.since, style: .timer)
                            .font(liveFont(size))
                            .monospacedDigit()
                            .foregroundStyle(ink.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
            }
        }
    }

    private func mark(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
    }
}

// MARK: - step dots

/// One 8 pt dot per step the job really has, each with its name under 11 pt mono beside it. Done = filled green, current =
/// accent with a soft ring (red when it failed or was lost), later = hollow. Nothing here moves.
struct JobSteps: View {
    let facts: JobFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = JobInk(reduced: reduced)
        HStack(spacing: 12) {
            ForEach(Array(facts.state.steps.enumerated()), id: \.offset) { i, name in
                let dot = facts.dot(i)
                HStack(spacing: 2) {
                    JobStepDot(dot: dot, ink: ink)
                    Text(name)
                        .font(liveFont(11, dot == .current ? .semibold : .regular))
                        .foregroundStyle(dot == .upcoming ? ink.secondary : JobInk(reduced: reduced).accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                // A long name shrinks before it pushes a later step off the card.
                .layoutPriority(dot == .current ? 1 : 0)
            }
            Spacer(minLength: 0)
        }
        // The dots sit in 14 pt boxes (room for the ring); pull the first one back to the card's text edge.
        .padding(.leading, -(JobStepDot.box - JobStepDot.size) / 2)
        .accessibilityHidden(true)
    }
}

struct JobStepDot: View {
    let dot: JobFacts.Dot
    let ink: JobInk
    /// The dot itself, and the box it sits in (the current dot's soft ring fills the box).
    static let size: CGFloat = 8
    static let box: CGFloat = 14

    var body: some View {
        ZStack {
            switch dot {
            case .done:
                Circle().fill(ink.green).frame(width: Self.size, height: Self.size)
            case .current:
                Circle().fill(ink.accent.opacity(0.25)).frame(width: Self.box, height: Self.box) // the soft ring
                Circle().fill(ink.accent).frame(width: Self.size, height: Self.size)
            case .failed:
                Circle().fill(ink.red.opacity(0.25)).frame(width: Self.box, height: Self.box)
                Circle().fill(ink.red).frame(width: Self.size, height: Self.size)
            case .upcoming:
                Circle().strokeBorder(ink.secondary.opacity(0.75), lineWidth: 1.5).frame(width: Self.size, height: Self.size)
            }
        }
        .frame(width: Self.box, height: Self.box)
    }
}

// MARK: - several at once

/// Up to three one-line rows: a status dot, the row's title, and its status on the right.
struct JobRows: View {
    let rows: [JobLiveState.Row]
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = JobInk(reduced: reduced)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    JobRowDot(phase: row.phase, ink: ink)
                    Text(row.title)
                        .font(liveFont(12))
                        .foregroundStyle(LiveInk(reduced: reduced).primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(row.status)
                        .font(liveFont(12))
                        .monospacedDigit()
                        .foregroundStyle(row.phase == .failed || row.phase == .lost ? ink.red : ink.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
        }
    }
}

/// Done = green, working = accent, waiting = hollow, failed = red.
struct JobRowDot: View {
    let phase: JobLiveState.Phase
    let ink: JobInk

    var body: some View {
        Group {
            switch phase {
            case .done: Circle().fill(ink.green)
            case .working, .quiet: Circle().fill(ink.accent)
            case .waiting: Circle().strokeBorder(ink.secondary.opacity(0.75), lineWidth: 1.5)
            case .failed, .lost: Circle().fill(ink.red)
            }
        }
        .frame(width: JobStepDot.size, height: JobStepDot.size)
    }
}

// MARK: - done: the two buttons

/// "open" (white, dark text) and "copy link" (outlined, only when the job has a link). Widgets cannot copy: both are links
/// into the app, which does the copying (`JobFacts.copyURL`).
struct JobActions: View {
    let facts: JobFacts

    var body: some View {
        HStack(spacing: 8) {
            LiveActionLink(destination: facts.openURL, title: Copy.Live.open, symbol: Symbol.openApp, prominent: true, compact: true)
            if let copy = facts.copyURL {
                LiveActionLink(destination: copy, title: Copy.Live.copyLink, symbol: Symbol.copyLink, prominent: false, compact: true)
            }
        }
        // Never squeezed: the footer's `ViewThatFits` must see their real width to know if the dots fit beside them.
        .fixedSize()
    }
}

// MARK: - Dynamic Island

/// A small progress ring: the compact leading slot and the minimal presentation. Filled by the fraction; a short arc when
/// there is no number; a green disc with a check when done; a red ring with a mark when failed or lost.
struct JobRing: View {
    let facts: JobFacts
    var size: CGFloat = 20
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = JobInk(reduced: reduced)
        ZStack {
            if facts.isDone {
                Circle().fill(ink.green)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(ink.onAccent)
            } else if facts.isBad {
                Circle().strokeBorder(ink.red, lineWidth: 2)
                Image(systemName: facts.isLost ? "questionmark" : Symbol.liveFailed)
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(ink.red)
            } else {
                Circle().strokeBorder(ink.ring, lineWidth: 2.5)
                // No number: a quarter arc says "working" without moving.
                Circle()
                    .trim(from: 0, to: max(0.04, facts.barFraction ?? 0.25))
                    .stroke(ink.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.25)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Compact leading: the ring, or three small dots for a chat reply (it has no number to fill a ring with).
struct JobCompactLeading: View {
    let facts: JobFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        if facts.isChat && !facts.isTerminal {
            let ink = JobInk(reduced: reduced)
            HStack(spacing: 3) {
                // Still dots, growing in strength: the three beats of "thinking".
                ForEach([0.45, 0.7, 1.0], id: \.self) { opacity in
                    Circle().fill(ink.accent.opacity(opacity)).frame(width: 4, height: 4)
                }
            }
            .frame(height: 20)
            .accessibilityHidden(true)
        } else {
            JobRing(facts: facts)
        }
    }
}

/// Compact trailing: the server's short text ("46%", "42/150", "3") in accent tabular numbers; "…" when quiet or when the
/// server sent none; the mark once the job ended.
struct JobCompactTrailing: View {
    let facts: JobFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        if facts.isTerminal {
            JobClock(facts: facts, size: 12)
        } else {
            let ink = JobInk(reduced: reduced)
            Text(facts.isQuiet ? "…" : facts.state.compact ?? "…")
                .font(liveFont(12, .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(ink.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// Expanded, top: the headline (red when it did not finish).
struct JobExpandedHeadline: View {
    let facts: JobFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        Text(facts.headline)
            .font(liveFont(14, .semibold))
            .foregroundStyle(facts.isBad ? JobInk(reduced: reduced).red : LiveInk(reduced: reduced).primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Expanded, below: the detail and a small 4 pt bar (a job still going).
struct JobExpandedBottom: View {
    let facts: JobFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = JobInk(reduced: reduced)
        VStack(alignment: .leading, spacing: 8) {
            if let detail = facts.detail {
                Text(detail)
                    .font(liveFont(12))
                    .monospacedDigit()
                    .foregroundStyle(ink.secondary)
                    .lineLimit(2)
            }
            if facts.showsBar {
                StoryBar(fraction: facts.barFraction, ink: ink.bar, sweeps: false, height: 4)
            }
        }
        .padding(.top, 4)
        .dynamicTypeSize(...LiveLock.largestType)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(facts.spoken)
    }
}

#if DEBUG
// MARK: - previews

/// States built from the values in `deploy/cloudflare/api/test/fixtures/job-live-states.json`, with their clocks moved to
/// "just now" (the fixture's fixed epoch would show weeks on the timer).
enum JobPreview {
    static func attributes(
        _ kind: String, _ title: String, agent: Bool = false, open: String? = nil
    ) -> CobaltJobActivityAttributes {
        CobaltJobActivityAttributes(JobLiveAttributes(id: "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11", kind: kind, title: title, agent: agent, open: open))
    }

    static let save = attributes("save", "twitch · KindStupidClip", agent: true)
    static let upload = attributes("upload", "IMG_0412.mov")
    static let make = attributes("make", "twitch · KindStupidClip", agent: true)
    static let edit = attributes("edit", "edit · birthday cut", open: "cobalt-apple://jobs")
    static let chat = attributes("chat", "chat · save that clip", open: "cobalt-apple://chat/thread01")
    static let many = attributes("many", "3 jobs")

    private static func state(
        _ phase: JobLiveState.Phase, _ steps: [String], _ step: Int, _ headline: String, detail: String? = nil,
        fraction: Double? = nil, compact: String? = nil, result: String? = nil, link: String? = nil,
        rows: [JobLiveState.Row]? = nil, running: Double = 7
    ) -> JobLiveState {
        JobLiveState(
            phase: phase, steps: steps, step: step, headline: headline, detail: detail, fraction: fraction, compact: compact,
            since: Date().timeIntervalSince1970 - running, result: result, link: link, rows: rows)
    }

    // save
    static func saveWorking() -> JobLiveState {
        state(.working, ["download", "store"], 0, "downloading from twitch", detail: "4.2 MB of 9.1 MB", fraction: 0.462, compact: "46%")
    }
    static func saveNoNumber() -> JobLiveState { state(.working, ["download", "store"], 0, "waking the server") }
    static func saveDone() -> JobLiveState {
        state(.done, ["download", "store"], 2, "saved", result: "1280×720 · 30 s · 8.9 MB")
    }
    static func saveFailed() -> JobLiveState {
        state(.failed, ["download", "store"], 0, "couldn't save", detail: "the link could not be fetched.")
    }
    static func saveLost() -> JobLiveState {
        state(.lost, ["download", "store"], 0, "lost track of this save", detail: "it may still finish: look in your library.", running: 620)
    }
    static func quiet() -> JobLiveState {
        state(.quiet, ["download", "store"], 1, "storing in your library", detail: "8.9 MB of 8.9 MB", fraction: 1, compact: "100%", running: 200)
    }
    // upload
    static func uploadWorking() -> JobLiveState {
        state(.working, ["upload", "store"], 0, "uploading", detail: "38.0 MB of 96.0 MB", fraction: 0.396, compact: "40%")
    }
    // make
    static func makeWaiting() -> JobLiveState {
        state(.waiting, ["wait", "make", "publish"], 0, "waiting for its turn", detail: "2 ahead", compact: "+2")
    }
    static func makeWorking() -> JobLiveState {
        state(.working, ["make"], 0, "making the webp", detail: "frame 42 of 150", fraction: 0.28, compact: "42/150")
    }
    static func makeDone() -> JobLiveState {
        state(
            .done, ["make"], 1, "webp ready", result: "480×854 · 10.1 s · 918 KB",
            link: "https://media.capybaraharmony.com/PrEvIeW001.webp")
    }
    // edit
    static func editWorking() -> JobLiveState {
        state(.working, ["prepare", "render", "save"], 1, "rendering", detail: "63%", fraction: 0.63, compact: "63%")
    }
    static func editFailed() -> JobLiveState {
        state(.failed, ["prepare", "render", "save"], 1, "couldn't render", detail: "a clip in this edit couldn't be used.")
    }
    // chat
    static func chatWorking() -> JobLiveState {
        state(.working, ["think", "tools", "write"], 1, "using tools", detail: "3 so far · search, save, look", compact: "3")
    }
    static func chatDone() -> JobLiveState {
        state(.done, ["think", "tools", "write"], 3, "reply ready", detail: "saved it (=^･ω･^=) it's in your library now")
    }
    // several at once
    static func manyWorking() -> JobLiveState {
        state(
            .working, [], 0, "1 done, 2 going", fraction: 0.333, compact: "1/3",
            rows: [
                .init(title: "twitch · KindStupidClip", status: "saved", phase: .done),
                .init(title: "IMG_0412.mov", status: "40%", phase: .working),
                .init(title: "edit · birthday cut", status: "2 ahead", phase: .waiting),
            ])
    }

    // Worst cases for the budget: the longest copy the server may send, five steps, and a long title.
    static let longTitle = "twitch · the whole afternoon at the harbour before the wind came up"
    static func worstWorking() -> JobLiveState {
        state(
            .working, ["wait", "download", "store", "read", "publish"], 2, "downloading from a very long service name",
            detail: "a very long detail line that runs on and on for ninety characters, the most it may be", fraction: 0.5, compact: "50%")
    }
    static func worstFailed() -> JobLiveState {
        state(
            .failed, ["wait", "download", "store", "read", "publish"], 1, "couldn't make the webp",
            detail: "a very long reason that runs on and on for ninety characters, the most it may be.")
    }
    static func worstDone() -> JobLiveState {
        state(
            .done, ["wait", "make", "publish"], 3, "webp ready",
            result: "a very long result line that runs on for a good while, 60 chars!!", link: "https://media.capybaraharmony.com/PrEvIeW001.webp")
    }
}

#Preview("save · lock screen", as: .content, using: JobPreview.save) {
    JobLiveActivity()
} contentStates: {
    JobPreview.saveNoNumber()
    JobPreview.saveWorking()
    JobPreview.quiet()
    JobPreview.saveDone()
    JobPreview.saveFailed()
    JobPreview.saveLost()
}

#Preview("upload · lock screen", as: .content, using: JobPreview.upload) {
    JobLiveActivity()
} contentStates: {
    JobPreview.uploadWorking()
}

#Preview("make · lock screen", as: .content, using: JobPreview.make) {
    JobLiveActivity()
} contentStates: {
    JobPreview.makeWaiting()
    JobPreview.makeWorking()
    JobPreview.makeDone()
}

#Preview("edit · lock screen", as: .content, using: JobPreview.edit) {
    JobLiveActivity()
} contentStates: {
    JobPreview.editWorking()
    JobPreview.editFailed()
}

#Preview("chat · lock screen", as: .content, using: JobPreview.chat) {
    JobLiveActivity()
} contentStates: {
    JobPreview.chatWorking()
    JobPreview.chatDone()
}

#Preview("many · lock screen", as: .content, using: JobPreview.many) {
    JobLiveActivity()
} contentStates: {
    JobPreview.manyWorking()
}

#Preview("save · island compact", as: .dynamicIsland(.compact), using: JobPreview.save) {
    JobLiveActivity()
} contentStates: {
    JobPreview.saveWorking()
    JobPreview.quiet()
    JobPreview.saveDone()
    JobPreview.saveFailed()
}

#Preview("chat · island compact", as: .dynamicIsland(.compact), using: JobPreview.chat) {
    JobLiveActivity()
} contentStates: {
    JobPreview.chatWorking()
    JobPreview.chatDone()
}

#Preview("save · island minimal", as: .dynamicIsland(.minimal), using: JobPreview.save) {
    JobLiveActivity()
} contentStates: {
    JobPreview.saveWorking()
    JobPreview.saveDone()
}

#Preview("save · island expanded", as: .dynamicIsland(.expanded), using: JobPreview.save) {
    JobLiveActivity()
} contentStates: {
    JobPreview.saveWorking()
    JobPreview.saveDone()
    JobPreview.saveFailed()
}

// The system's stale flag is not a content state, so the card is drawn directly: stale shows the quiet words.
#Preview("stale · lock screen", traits: .sizeThatFitsLayout) {
    JobLockScreenView(facts: JobFacts(attributes: JobPreview.make.job, state: JobPreview.makeWorking(), isStale: true))
        .background(Color.black)
        .padding()
        .background(Color.black)
}

/// The 160 pt budget: every kind and phase in the largest type the card honours, each boxed at the full height, then the
/// worst-case copy and the Always-On dimming.
#Preview("budget · xLarge", traits: .sizeThatFitsLayout) {
    let cases: [(CobaltJobActivityAttributes, JobLiveState)] = [
        (JobPreview.save, JobPreview.saveWorking()), (JobPreview.save, JobPreview.saveDone()),
        (JobPreview.upload, JobPreview.uploadWorking()), (JobPreview.make, JobPreview.makeWaiting()),
        (JobPreview.make, JobPreview.makeWorking()), (JobPreview.make, JobPreview.makeDone()),
        (JobPreview.edit, JobPreview.editWorking()), (JobPreview.edit, JobPreview.editFailed()),
        (JobPreview.chat, JobPreview.chatWorking()), (JobPreview.chat, JobPreview.chatDone()),
        (JobPreview.many, JobPreview.manyWorking()), (JobPreview.save, JobPreview.quiet()),
        (JobPreview.save, JobPreview.saveLost()),
        (JobPreview.make, JobPreview.worstWorking()), (JobPreview.make, JobPreview.worstFailed()),
        (JobPreview.make, JobPreview.worstDone()),
    ]
    ScrollView {
        VStack(spacing: 12) {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, c in
                JobLockScreenView(facts: JobFacts(attributes: c.0.job, state: c.1))
                    .environment(\.dynamicTypeSize, .xLarge)
                    .frame(width: 370, height: LiveLock.height, alignment: .top)
                    .background(Color.black)
                    .overlay(Rectangle().stroke(Color.red.opacity(0.4), lineWidth: 0.5))
            }
            JobLockScreenView(facts: JobFacts(attributes: JobPreview.make.job, state: JobPreview.makeDone()))
                .environment(\.isLuminanceReduced, true)
                .frame(width: 370)
                .background(Color.black)
        }
        .padding()
    }
    .background(Color.black)
}
#endif

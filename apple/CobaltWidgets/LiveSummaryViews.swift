import CobaltKit
import SwiftUI
import WidgetKit

// The busy period's one Live Activity (CONTRACT-PARALLEL.md section 6): while two or more jobs are live the activity
// shows the LEAD job's own card (headline, detail, bar, stepper) and, under it, "+2 more · 1 waiting for the server";
// when nothing is live any more it says what came out of it ("3 saved · 1 webp"). The content state carries `jobs` and
// `waiting` (and, once it is over, `savedCount`, `webpCount`, `failedCount`); a per-run activity carries none of them and
// is drawn exactly as before.

// MARK: - copy

extension Copy.Live {
    /// The Lock Screen header and the island's leading slot: the activity is not one run's, so it names the count.
    static func summarySource(jobs: Int, waiting: Int) -> String {
        waiting >= jobs ? "\(jobs) waiting" : "\(jobs) running"
    }

    /// Every job is in a line (queued on the server, or behind another in the device's line).
    static let waitingForServer = "waiting for the server"

    static func inLine(_ jobs: Int) -> String { "\(jobs) in line" }

    /// "+2 more · 1 waiting for the server": under the lead's card. Nil when there is nothing besides the lead.
    static func more(jobs: Int, waiting: Int) -> String? {
        let others = jobs - 1
        guard others > 0 else { return nil }
        let head = "+\(others) more"
        return waiting > 0 ? "\(head) · \(waiting) \(waitingForServer)" : head
    }

    /// The period is over: "3 saved · 1 webp", "2 saved · 1 couldn't be saved", "2 couldn't be saved".
    static func summaryDone(saved: Int, webps: Int, failed: Int) -> String {
        var parts: [String] = []
        if saved > 0 { parts.append("\(saved) saved") }
        if webps > 0 { parts.append("\(webps) \(webps == 1 ? "webp" : "webps")") }
        if failed > 0 { parts.append("\(failed) couldn't be saved") }
        return parts.isEmpty ? "done" : parts.joined(separator: " · ")
    }

    static func summaryDone(_ s: LiveContentState) -> String {
        summaryDone(saved: s.savedCount ?? 0, webps: s.webpCount ?? 0, failed: s.failedCount ?? 0)
    }

    /// The header of a finished summary (the run's own source line would name the first job only).
    static let summaryDoneSource = "cobalt"
}

// MARK: - what the summary adds to `LiveFacts`

extension LiveFacts {
    /// The jobs this activity speaks for (1 for a per-run activity).
    var jobCount: Int { max(state.jobs ?? 1, 1) }
    var waitingCount: Int { state.waiting ?? 0 }
    /// A busy period's activity, in progress or over.
    var isSummary: Bool { state.isSummary }
    var isFinishedSummary: Bool { state.isFinishedSummary }
    /// Every live job waits in a line: the headline says so instead of a step nobody is doing.
    var allWaiting: Bool { isSummary && !state.isTerminal && waitingCount >= jobCount }
    /// "3" in the compact slot and the minimal ring: only when there is more than one job to count.
    var showsCount: Bool { isSummary && !state.isTerminal && jobCount > 1 }
    /// "+2 more · …" under the lead's card.
    var more: String? {
        guard isSummary, !state.isTerminal, !allWaiting else { return nil }
        return Copy.Live.more(jobs: jobCount, waiting: waitingCount)
    }
}

// MARK: - views

/// "+2 more · 1 waiting for the server": one line under the lead's stepper, or under the bar in the island.
struct LiveSummaryMore: View {
    let text: String
    var size: CGFloat = 12
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        Text(text)
            .font(liveFont(size))
            .monospacedDigit()
            .foregroundStyle(LiveInk(reduced: reduced).secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityLabel(text)
    }
}

/// The compact trailing slot of a summary: the lead's ring and how many jobs there are.
struct LiveCompactTrailing: View {
    let facts: LiveFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        HStack(spacing: 4) {
            LiveRing(facts: facts, glyph: false)
            if facts.showsCount {
                Text("\(facts.jobCount)")
                    .font(liveFont(11, .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(LiveInk(reduced: reduced).primary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// The finished period on the Lock Screen: "3 saved · 1 webp" and nothing else (no link to copy, no stepper); the card's
/// "open" button takes the owner to the tray.
struct LiveSummaryDone: View {
    let facts: LiveFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = LiveInk(reduced: reduced)
        VStack(alignment: .leading, spacing: 2) {
            Text(facts.story.headline)
                .font(liveFont(15, .semibold))
                .foregroundStyle(ink.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            if let detail = detail {
                Text(detail)
                    .font(liveFont(12))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// What the headline does not say: when some did not finish, that the others did, and where to look.
    private var detail: String? {
        let failed = facts.state.failedCount ?? 0
        let finished = (facts.state.savedCount ?? 0) + (facts.state.webpCount ?? 0)
        if failed > 0, finished > 0 { return "open cobalt to try the rest again." }
        if failed > 0 { return "open cobalt to try again." }
        return nil
    }
}

#if DEBUG
// MARK: - previews: one job, three running, ended

private enum SummaryPreview {
    /// The summary states with their clocks moved to "just now".
    static func states(_ names: [String], running: Double = 7) -> [LiveContentState] {
        let now = Date().timeIntervalSince1970
        return names.compactMap { name in
            guard var s = LiveContentState.summarySamples[name] else { return nil }
            s.since = now - running
            return s
        }
    }

    static let attributes = CobaltActivityAttributes(LiveRunAttributes(
        run: UUID(), input: "link", service: "instagram", ref: "Dd7P496wolG", origin: "app"))
    static let running = ["running_3", "running_3_waiting", "reading_3", "all_waiting", "last_one"]
    static let ended = ["done_3_1", "done_mixed", "failed_all"]
}

#Preview("3 running · lock screen", as: .content, using: SummaryPreview.attributes) {
    CobaltLiveActivity()
} contentStates: {
    for state in SummaryPreview.states(SummaryPreview.running) { state }
}

#Preview("3 running · island expanded", as: .dynamicIsland(.expanded), using: SummaryPreview.attributes) {
    CobaltLiveActivity()
} contentStates: {
    for state in SummaryPreview.states(SummaryPreview.running) { state }
}

#Preview("3 running · island compact", as: .dynamicIsland(.compact), using: SummaryPreview.attributes) {
    CobaltLiveActivity()
} contentStates: {
    for state in SummaryPreview.states(SummaryPreview.running) { state }
}

#Preview("3 running · island minimal", as: .dynamicIsland(.minimal), using: SummaryPreview.attributes) {
    CobaltLiveActivity()
} contentStates: {
    for state in SummaryPreview.states(SummaryPreview.running) { state }
}

#Preview("ended · lock screen", as: .content, using: SummaryPreview.attributes) {
    CobaltLiveActivity()
} contentStates: {
    for state in SummaryPreview.states(SummaryPreview.ended) { state }
}

#Preview("ended · island expanded", as: .dynamicIsland(.expanded), using: SummaryPreview.attributes) {
    CobaltLiveActivity()
} contentStates: {
    for state in SummaryPreview.states(SummaryPreview.ended) { state }
}

#Preview("ended · island compact", as: .dynamicIsland(.compact), using: SummaryPreview.attributes) {
    CobaltLiveActivity()
} contentStates: {
    for state in SummaryPreview.states(SummaryPreview.ended) { state }
}

/// The 160 pt budget: the busiest summary card (a lead mid-save, the more line) next to the busiest per-run card, in the
/// largest type the card honours, and the Always-On dimming.
#Preview("3 running · budget", traits: .sizeThatFitsLayout) {
    VStack(spacing: 12) {
        ForEach(["running_3_waiting", "reading_3"], id: \.self) { name in
            LiveLockScreenView(facts: LiveFacts(attributes: SummaryPreview.attributes, state: SummaryPreview.states([name])[0]))
                .frame(height: LiveLock.height)
                .background(Color.black)
        }
        LiveLockScreenView(facts: LiveFacts(attributes: SummaryPreview.attributes, state: SummaryPreview.states(["running_3_waiting"])[0]))
            .environment(\.isLuminanceReduced, true)
            .background(Color.black)
    }
    .padding()
    .background(Color.black)
}
#endif

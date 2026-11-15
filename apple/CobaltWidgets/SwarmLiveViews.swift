import AppIntents
import CobaltKit
import SwiftUI
import WidgetKit

// The `swarm` kind of the job Live Activity (APP-API-CONTRACT 61.5, apple/CONTRACT-SWARMS.md 4). Same card as every job, but
// drawn from the three extra fields of `JobLiveState`: `cells` (one small cell per agent, one bar past 40), `actions` (the
// buttons) and `hash` / `count` (what approve and apply send / say). Like the rest of the widget it only draws: the server
// writes every word.
//
//   star, "swarm · rename emotes", ........ clock
//   headline                               the swarm's name, or "12 of 20 agents done", "342 changes ready"
//   [ cells ........................ ]     small rounded cells, one per agent
//   detail                                 one line while there are cells (two without)
//   [decline] [approve]                    approve and apply are App Intents that ask for Face ID first
//
// The compact island says what is wanted of you: an amber "?" and "swarm" while it waits for you, the ring and "12/20" while
// it runs.

extension JobFacts {
    var isSwarm: Bool { attributes.kind == SwarmLiveActivities.kind }

    /// The swarm's id (the activity's run id is `swarm:<id>`).
    var swarmID: String {
        attributes.id.hasPrefix("swarm:") ? String(attributes.id.dropFirst("swarm:".count)) : attributes.id
    }

    /// It waits for you: an approve or an apply button. Never "no news".
    var swarmWaits: Bool { isSwarm && state.swarmWaitsForYou }

    var swarmStrip: SwarmLiveStrip? { isSwarm ? state.swarmStrip : nil }

    /// `cobalt-apple://swarm/<id>/review`: "check first".
    var reviewURL: URL { URL(string: "cobalt-apple://swarm/\(swarmID)/review") ?? openURL }

    /// The swarm's own screen (the attributes' `open`).
    var swarmURL: URL { attributes.open.flatMap(URL.init(string:)) ?? URL(string: "cobalt-apple://swarm/\(swarmID)") ?? openURL }

    /// The buttons in the order they are drawn: no on the left of yes (decline before approve; the server lists approve first).
    var swarmButtons: [SwarmLiveAction] {
        var actions = state.swarmActions
        if let approve = actions.firstIndex(of: .approve), let decline = actions.firstIndex(of: .decline), decline > approve {
            actions.swapAt(approve, decline)
        }
        return actions
    }

    /// Buttons are not drawn Always-On: nothing can be tapped there.
    func showsSwarmButtons(reduced: Bool) -> Bool { isSwarm && !reduced && !swarmButtons.isEmpty }
}

// MARK: - colours

extension JobInk {
    /// The "it is asking a question" amber (the design's `--amber`).
    var amber: Color { Color(hex: 0xf5ad5b, opacity: reduced ? 0.7 : 1) }

    /// One agent's cell: grey waiting its turn, white running, amber asking a question, green done, red failed.
    func cell(_ status: SwarmCell.Status) -> Color {
        switch status {
        case .queued: return track
        case .running: return accent
        case .waiting: return amber
        case .done: return green
        case .failed: return red
        case .skipped: return secondary.opacity(0.45)
        }
    }
}

// MARK: - the strip

/// Small rounded cells up to 40; past that one bar split by share of done, running, waiting, failed.
struct SwarmStripView: View {
    let strip: SwarmLiveStrip
    let ink: JobInk
    var height: CGFloat = 9

    var body: some View {
        Group {
            switch strip.layout {
            case .cells(let cells):
                HStack(spacing: 2) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, status in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(ink.cell(status))
                            .frame(maxWidth: cells.count < 20 ? 14 : .infinity)
                    }
                    if cells.count < 20 { Spacer(minLength: 0) }
                }
            case .bar(let segments):
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            Rectangle()
                                .fill(ink.cell(segment.status))
                                .frame(width: geo.size.width * CGFloat(segment.count) / CGFloat(max(1, strip.total)))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - buttons

enum SwarmButtonKind { case primary, plain, danger, small }

/// One button's look: a capsule. Primary is the one ink with black text; the others are a faint fill.
struct SwarmButtonLabel: View {
    let title: String
    let kind: SwarmButtonKind
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = JobInk(reduced: reduced)
        let small = kind == .small
        Text(title)
            .font(liveFont(small ? 12 : 13, .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(foreground(ink))
            .padding(.horizontal, small ? 14 : 8)
            .frame(maxWidth: small ? nil : .infinity)
            .frame(height: small ? 26 : 32)
            .background(Capsule().fill(kind == .primary ? ink.accent : Color.white.opacity(0.12)))
            .contentShape(Capsule())
    }

    private func foreground(_ ink: JobInk) -> Color {
        switch kind {
        case .primary: return ink.onAccent
        case .danger: return ink.red
        case .plain, .small: return ink.accent
        }
    }
}

/// The card's buttons, from `actions`. approve and apply (Face ID first) and decline and stop are App Intents: they run
/// without opening the app. check and open are links. An approve or apply with no hash cannot be sent: it opens the swarm.
struct SwarmActionRow: View {
    let facts: JobFacts

    var body: some View {
        HStack(spacing: 8) {
            ForEach(facts.swarmButtons, id: \.self) { action in
                button(action)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func button(_ action: SwarmLiveAction) -> some View {
        let id = facts.swarmID
        switch action {
        case .approve:
            if let hash = facts.state.hash {
                Button(intent: ApproveSwarmIntent(swarm: id, hash: hash)) { SwarmButtonLabel(title: action.title, kind: .primary) }
                    .buttonStyle(.plain)
            } else {
                Link(destination: facts.swarmURL) { SwarmButtonLabel(title: action.title, kind: .primary) }
            }
        case .apply:
            let title = facts.state.count.map { "apply \($0)" } ?? action.title
            if let hash = facts.state.hash {
                Button(intent: ApplySwarmIntent(swarm: id, hash: hash)) { SwarmButtonLabel(title: title, kind: .primary) }
                    .buttonStyle(.plain)
            } else {
                Link(destination: facts.swarmURL) { SwarmButtonLabel(title: title, kind: .primary) }
            }
        case .decline:
            Button(intent: DeclineSwarmIntent(swarm: id)) { SwarmButtonLabel(title: action.title, kind: .danger) }
                .buttonStyle(.plain)
        case .stop:
            Button(intent: StopSwarmIntent(swarm: id)) { SwarmButtonLabel(title: action.title, kind: .small) }
                .buttonStyle(.plain)
        case .check:
            Link(destination: facts.reviewURL) { SwarmButtonLabel(title: action.title, kind: .plain) }
        case .open:
            Link(destination: facts.swarmURL) { SwarmButtonLabel(title: action.title, kind: .small) }
        }
    }
}

// MARK: - the Lock Screen card

struct SwarmLockScreenView: View {
    let facts: JobFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = JobInk(reduced: reduced)
        let strip = facts.swarmStrip
        VStack(alignment: .leading, spacing: LiveLock.gap) {
            VStack(alignment: .leading, spacing: LiveLock.gap) {
                JobTopLine(facts: facts)
                Text(facts.headline)
                    .font(liveFont(16, .semibold))
                    .foregroundStyle(facts.isBad ? ink.red : LiveInk(reduced: reduced).primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let strip { SwarmStripView(strip: strip, ink: ink) }
                if let detail = facts.detail {
                    Text(detail)
                        .font(liveFont(13))
                        .monospacedDigit()
                        .foregroundStyle(ink.secondary)
                        // With the strip and the buttons on the card there is room for one line; without the strip, two.
                        .lineLimit(strip != nil && facts.showsSwarmButtons(reduced: reduced) ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if facts.showsBar { StoryBar(fraction: facts.barFraction, ink: ink.bar, sweeps: false, height: 5) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(facts.spoken)
            // Outside the combined element so the buttons stay reachable.
            if facts.showsSwarmButtons(reduced: reduced) { SwarmActionRow(facts: facts) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LiveLock.horizontalPadding)
        .padding(.vertical, LiveLock.verticalPadding)
        .dynamicTypeSize(...LiveLock.largestType)
        .widgetURL(facts.swarmURL)
    }
}

// MARK: - the Dynamic Island

/// Expanded: the headline row, detail, strip and buttons (the same words as the card).
struct SwarmExpandedBottom: View {
    let facts: JobFacts
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = JobInk(reduced: reduced)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    LiveStar()
                    JobExpandedHeadline(facts: facts)
                    Spacer(minLength: 8)
                    JobClock(facts: facts, size: 12)
                }
                if let strip = facts.swarmStrip { SwarmStripView(strip: strip, ink: ink, height: 7) }
                if let detail = facts.detail {
                    Text(detail)
                        .font(liveFont(12))
                        .monospacedDigit()
                        .foregroundStyle(ink.secondary)
                        .lineLimit(facts.showsSwarmButtons(reduced: reduced) ? 1 : 2)
                }
                if facts.showsBar { StoryBar(fraction: facts.barFraction, ink: ink.bar, sweeps: false, height: 4) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(facts.spoken)
            if facts.showsSwarmButtons(reduced: reduced) { SwarmActionRow(facts: facts) }
        }
        .padding(.horizontal, 6)
        .dynamicTypeSize(...LiveLock.largestType)
    }
}

/// An amber disc with a "?": the swarm is waiting for you (compact leading and minimal).
struct SwarmQuestionMark: View {
    let facts: JobFacts
    var size: CGFloat = 20
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        let ink = JobInk(reduced: reduced)
        ZStack {
            Circle().fill(ink.amber)
            Text("?")
                .font(liveFont(size * 0.62, .semibold))
                .foregroundStyle(ink.onAccent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Compact trailing while it waits for you: "swarm" in amber.
struct SwarmWaitingTrailing: View {
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        Text("swarm")
            .font(liveFont(12, .medium))
            .foregroundStyle(JobInk(reduced: reduced).amber)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

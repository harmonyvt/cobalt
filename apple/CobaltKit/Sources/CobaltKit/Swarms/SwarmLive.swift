import Foundation

// The `swarm` kind of the job Live Activity (APP-API-CONTRACT 61.5, apple/CONTRACT-SWARMS.md 4). The server writes every
// word the island shows; this file reads the three new fields of `JobLiveState` and builds the same state locally from a
// `Swarm` (for updating the activity at once after a button, without waiting for the push). The builder follows the 61.5
// table row by row, and its output goes through `canonical()` like the server's.

/// The buttons of a swarm activity (61.5 `actions`). `approve` and `apply` need Face ID first (App Intents,
/// `authenticationPolicy = .requiresAuthentication`); `decline` and `stop` do not; `check` and `open` are links.
public enum SwarmLiveAction: String, Sendable, CaseIterable {
    case approve, decline, stop, check, apply, open

    /// The button's words.
    public var title: String {
        switch self {
        case .approve: return "approve"
        case .decline: return "decline"
        case .stop: return "stop"
        case .check: return "check first"
        case .apply: return "apply"
        case .open: return "open"
        }
    }

    /// Needs Face ID / Touch ID before it sends.
    public var needsAuthentication: Bool { self == .approve || self == .apply }

    /// Calls the API (the rest open the app).
    public var isCall: Bool { self != .check && self != .open }
}

extension JobLiveState {
    /// The buttons, in order; an unknown name (a newer server) is skipped. Empty for any other kind of job.
    public var swarmActions: [SwarmLiveAction] { (actions ?? []).compactMap(SwarmLiveAction.init(rawValue:)) }

    /// One status per agent, from `cells`. A letter this build does not know is shown as queued so the squares keep their place.
    public var swarmCells: [SwarmCell.Status] {
        (cells ?? "").map { SwarmCell.Status(letter: $0) ?? .queued }
    }

    /// The state of a swarm as the 61.5 table says it (a local mirror of the server's `jobOfSwarm`). `now` is for the
    /// minutes an unanswered plan has left.
    public init(swarm s: Swarm, now: Date) {
        let propose = s.mode == .propose
        let steps = propose ? ["approve", "run", "review", "apply"] : ["approve", "run"]
        let spent = SwarmWords.money(s.spentUSD)
        let letters = String(s.tasks.cells.prefix(200).map { $0.status.letter })
        let cells = letters.isEmpty ? nil : letters
        let seconds = { (d: Date?) in d.map { $0.timeIntervalSince1970.rounded(.down) } }

        var state = JobLiveState(phase: .working, steps: steps, step: 0, headline: s.name, since: seconds(s.createdAt) ?? 0)
        state.cells = cells

        switch s.status {
        case .awaitingApproval:
            state.phase = .waiting
            state.step = 0
            state.headline = s.name
            var detail: [String] = []
            if let planner = s.planner { detail.append("from \(planner)") }
            if let e = s.estimateUSD {
                let low = SwarmWords.money(e.low)
                let high = SwarmWords.money(e.high)
                detail.append("about \(low == high ? low : "\(low)..\(high)")")
            }
            if let expires = s.expiresAt {
                let minutes = max(0, Int((expires.timeIntervalSince(now) / 60).rounded(.up)))
                detail.append("expires in \(minutes) min")
            }
            state.detail = detail.isEmpty ? nil : detail.joined(separator: " · ")
            state.actions = ["approve", "decline"]
            state.hash = s.specHash

        case .running, .stopping:
            state.phase = .working
            state.step = 1
            state.since = seconds(s.approvedAt ?? s.createdAt) ?? state.since
            state.headline = "\(s.tasks.done) of \(s.tasks.total) agents done"
            if s.tasks.waiting > 0 {
                let who = s.planner ?? "its owner"
                state.detail = s.tasks.waiting == 1
                    ? "1 agent is asking \(who) a question" : "\(s.tasks.waiting) agents are asking \(who) a question"
            } else if propose, let found = s.changes?.total {
                state.detail = "\(found) changes · \(spent)"
            } else {
                state.detail = spent
            }
            if s.tasks.total > 0 {
                state.fraction = Double(s.tasks.done) / Double(s.tasks.total)
                state.compact = "\(s.tasks.done)/\(s.tasks.total)"
            }
            state.actions = s.status == .stopping ? nil : ["stop"]

        case .done:
            switch s.apply.status {
            case .ready:
                let kept = s.changes?.kept ?? s.apply.total
                state.phase = .waiting
                state.step = 2
                state.since = seconds(s.finishedAt ?? s.approvedAt) ?? state.since
                state.headline = "\(kept) changes ready"
                state.detail = s.clashCount > 0
                    ? "\(s.clashCount) look like duplicates and are left out · \(spent)" : spent
                state.actions = ["check", "apply"]
                state.hash = s.specHash
                state.count = s.applyCount
            case .applying:
                state.phase = .working
                state.step = 3
                state.since = seconds(s.finishedAt ?? s.approvedAt) ?? state.since
                state.headline = "applying changes"
                state.detail = "\(s.apply.done) of \(s.apply.total)"
                if s.apply.total > 0 { state.fraction = Double(s.apply.done) / Double(s.apply.total) }
                state.compact = s.apply.total > 0 ? "\(s.apply.done)/\(s.apply.total)" : nil
            case .applied, .failed:
                state.phase = .done
                state.step = steps.count
                state.since = seconds(s.finishedAt) ?? state.since
                state.headline = "applied \(s.apply.done) changes"
                state.detail = "\(s.apply.failed) failed · \(spent)"
                state.actions = ["open"]
            case .none:
                state.phase = .done
                state.step = steps.count
                state.since = seconds(s.finishedAt) ?? state.since
                state.headline = "done"
                state.detail = s.reduce.map { Self.firstWords($0) } ?? spent
                state.actions = ["open"]
            }

        case .failed, .stopped, .declined, .expired:
            state.phase = .failed
            state.step = (s.status == .declined || s.status == .expired) ? 0 : 1
            state.since = seconds(s.finishedAt) ?? state.since
            switch s.status {
            case .declined: state.headline = "declined"
            case .expired: state.headline = "expired"
            case .stopped: state.headline = s.error?.contains("over_cap") == true ? "stopped at its cap" : "stopped"
            default: state.headline = "failed"
            }
            state.detail = Self.reason(s.error, status: s.status, spent: spent)
            state.actions = ["open"]
        }
        self = state.canonical()
    }

    /// The first words of a reduce summary: its first sentence or line, cut at 90 characters.
    static func firstWords(_ text: String) -> String {
        let line = text.split(whereSeparator: { $0 == "\n" }).first.map(String.init) ?? text
        return JobText.cap(line.trimmingCharacters(in: .whitespaces), 90)
    }

    /// Why a swarm ended without finishing, in plain words.
    static func reason(_ code: String?, status: Swarm.Status, spent: String) -> String? {
        let c = code ?? ""
        if c.contains("over_cap") { return "it reached its dollar cap · \(spent)" }
        if c.contains("daily_cap") { return "today's swarm budget is spent" }
        if c.contains("too_many_failed") { return "too many agents failed · \(spent)" }
        if c.contains("all_failed") { return "no agent finished · \(spent)" }
        if c.contains("stalled") { return "an agent stalled · \(spent)" }
        if c.contains("model") { return "the model failed · \(spent)" }
        switch status {
        case .declined: return "you said no"
        case .expired: return "nobody answered in time"
        case .stopped: return "stopped · \(spent)"
        default: return c.isEmpty ? nil : "something went wrong · \(spent)"
        }
    }
}

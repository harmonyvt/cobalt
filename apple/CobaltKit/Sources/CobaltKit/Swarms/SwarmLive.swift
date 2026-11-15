import Foundation

// The `swarm` kind of the job Live Activity (APP-API-CONTRACT 61.5, apple/CONTRACT-SWARMS.md 4). The server writes every
// word the island shows (`jobOfSwarm` in deploy/cloudflare/api/src/job-live.ts); this file reads the new fields of
// `JobLiveState` (cells, actions, hash, count) and builds the same state locally from a `Swarm` (for updating the activity at
// once after a button, without waiting for the push). The builder is a line by line port of `jobOfSwarm`: same branches in
// the same order, same words, same numbers. It is pinned to the server's fixture (`swarm_*` in test/fixtures/job-live-states.json,
// JobLiveTests) and to a table of more inputs run through the server's own code (Tests/gen-swarm-live-cases.mjs).

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

/// What the swarm island is drawn from: a port of the server's `SwarmLiveInput` (`src/job-live.ts`, filled from D1 by
/// `swarmLiveInput` in `src/swarm-live.ts`). Times are milliseconds. `JobLiveState(swarm:now:)` fills it from a `Swarm`; the
/// tests fill it with the server fixture's own inputs (`test/job-live-cases.ts`).
public struct SwarmLiveInput: Hashable, Sendable {
    public struct Changes: Hashable, Sendable {
        /// Every change; the kept ones; the kept ones not applied yet and how many of those clash; applied; failed.
        public var total = 0, kept = 0, open = 0, clashes = 0, done = 0, failed = 0

        public init(total: Int = 0, kept: Int = 0, open: Int = 0, clashes: Int = 0, done: Int = 0, failed: Int = 0) {
            self.total = total
            self.kept = kept
            self.open = open
            self.clashes = clashes
            self.done = done
            self.failed = failed
        }
    }

    public var id: String
    public var name: String
    public var mode: Swarm.Mode
    public var status: Swarm.Status
    public var applyStatus: Swarm.Apply.Status
    public var specHash: String
    public var planner: String
    public var estLow: Double
    public var estHigh: Double
    public var spentUSD: Double
    public var capUSD: Double
    public var error: String?
    public var reduce: String?
    public var createdAt: Double
    public var approvedAt: Double?
    public var finishedAt: Double?
    public var expiresAt: Double?
    /// One letter per agent, in order: q queued, r running, w waiting on a question, d done, f failed, s skipped.
    public var cells: String
    public var changes: Changes

    public init(
        id: String, name: String, mode: Swarm.Mode, status: Swarm.Status, applyStatus: Swarm.Apply.Status = .none, specHash: String,
        planner: String, estLow: Double, estHigh: Double, spentUSD: Double, capUSD: Double, error: String? = nil, reduce: String? = nil,
        createdAt: Double, approvedAt: Double? = nil, finishedAt: Double? = nil, expiresAt: Double? = nil, cells: String,
        changes: Changes = Changes()
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.status = status
        self.applyStatus = applyStatus
        self.specHash = specHash
        self.planner = planner
        self.estLow = estLow
        self.estHigh = estHigh
        self.spentUSD = spentUSD
        self.capUSD = capUSD
        self.error = error
        self.reduce = reduce
        self.createdAt = createdAt
        self.approvedAt = approvedAt
        self.finishedAt = finishedAt
        self.expiresAt = expiresAt
        self.cells = cells
        self.changes = changes
    }

    /// The input a `Swarm` answer stands for (what `swarmLiveInput` reads from D1 for the same swarm). The server's `open` is
    /// the kept changes not done yet; `clashes` is the app's own count (`Swarm.clashCount`, from the change list it read).
    public init(swarm s: Swarm) {
        let ms = { (d: Date) in (d.timeIntervalSince1970 * 1000).rounded() }
        let kept = s.changes?.kept ?? s.apply.total
        let done = s.changes?.done ?? s.apply.done
        let open = max(0, kept - done)
        self.init(
            id: s.id, name: s.name, mode: s.mode, status: s.status, applyStatus: s.apply.status, specHash: s.specHash,
            planner: s.planner ?? "mcp", estLow: s.estimateUSD?.low ?? 0, estHigh: s.estimateUSD?.high ?? 0, spentUSD: s.spentUSD,
            capUSD: s.capUSD, error: s.error, reduce: s.reduce, createdAt: ms(s.createdAt), approvedAt: s.approvedAt.map(ms),
            finishedAt: s.finishedAt.map(ms), expiresAt: s.expiresAt.map(ms),
            cells: String(s.tasks.cells.map { $0.status.letter }),
            changes: s.mode == .propose
                ? Changes(
                    total: s.changes?.total ?? 0, kept: kept, open: open, clashes: min(s.clashCount, open), done: done,
                    failed: s.changes?.failed ?? s.apply.failed)
                : Changes())
    }

    /// An awaiting plan whose hour has passed is shown as expired even before the server's sweep says so.
    public func isExpired(now: Double) -> Bool {
        status == .expired || (status == .awaitingApproval && expiresAt.map { $0 <= now } == true)
    }
}

extension JobLiveAttributes {
    /// The swarm's activity attributes, as the server writes them (`jobOfSwarm`): `swarm:<id>`, "swarm · <name>" cut to 40, agent
    /// chip, and the deep link.
    public init(swarm id: String, name: String) {
        self.init(
            id: SwarmLiveActivities.runID(id), kind: SwarmLiveActivities.kind, title: SwarmLiveWords.cut("swarm · \(name)", 40),
            agent: true, open: "cobalt-apple://swarm/\(id)")
    }
}

/// The words of the swarm island, as `src/job-live.ts` writes them.
enum SwarmLiveWords {
    /// "21¢", "<1¢" under $1; "$1.40", "$2.00" from $1 (the server never drops the cents, unlike `SwarmWords.money`).
    static func money(_ usd: Double) -> String {
        let cents = Int((usd * 100).rounded(.toNearestOrAwayFromZero))
        if cents >= 100 { return "$\(cents / 100).\(String(format: "%02d", cents % 100))" }
        return usd > 0 && cents == 0 ? "<1¢" : "\(cents)¢"
    }

    /// The server's `cut`: by characters (code points), the tail trimmed, then "…".
    static func cut(_ s: String, _ n: Int) -> String {
        let points = Array(s.unicodeScalars)
        guard points.count > n else { return s }
        var head = String(String.UnicodeScalarView(points.prefix(n - 1)))
        while let last = head.unicodeScalars.last, last.properties.isWhitespace { head.unicodeScalars.removeLast() }
        return head + "…"
    }

    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// Why a swarm ended without finishing (`swarmReason`).
    static func reason(_ s: SwarmLiveInput) -> String {
        switch s.status {
        case .declined: return "you declined it."
        case .expired: return "nobody approved it within an hour."
        default: break
        }
        switch s.error {
        case "error.swarm.over_cap": return "it reached its \(money(s.capUSD)) cap."
        case "error.swarm.daily_cap": return "today's swarm budget is spent."
        case "error.swarm.too_many_failed": return "too many agents failed."
        case "error.swarm.all_failed": return "no agent finished."
        case "error.swarm.off": return "swarms are off on this server."
        case nil where s.status == .stopped: return "it was stopped. nothing was undone."
        default: return "something went wrong. open capystore to see what happened."
        }
    }

    /// JS `s.replace(/\s+/g, " ").trim()`.
    static func collapsed(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
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
        self.init(swarm: SwarmLiveInput(swarm: s), nowMs: (now.timeIntervalSince1970 * 1000).rounded())
    }

    /// A line by line port of `jobOfSwarm` (`src/job-live.ts`): same branches in the same order, same words. `nowMs` is
    /// milliseconds since the epoch.
    public init(swarm s: SwarmLiveInput, nowMs now: Double) {
        typealias W = SwarmLiveWords
        let steps = s.mode == .propose ? ["approve", "run", "review", "apply"] : ["approve", "run"]
        let cells = String(s.cells.prefix(200))
        func n(_ c: Character) -> Int { cells.filter { $0 == c }.count }
        let total = cells.count
        let done = n("d")
        let ended = done + n("f") + n("s")
        let waiting = n("w")
        let spent = W.money(s.spentUSD)
        func secs(_ ms: Double?) -> Double { ((ms ?? s.createdAt) / 1000).rounded(.down) }
        let expired = s.isExpired(now: now)
        let ratio = { (a: Int, b: Int) -> Double? in b > 0 ? Double(a) / Double(b) : nil }
        var state: JobLiveState

        if s.status == .awaitingApproval && !expired {
            let mins = max(1, Int((((s.expiresAt ?? now) - now) / 60_000).rounded(.up)))
            state = JobLiveState(
                phase: .waiting, steps: steps, step: 0, headline: s.name,
                detail: "from \(s.planner) · about \(W.money(s.estLow))–\(W.money(s.estHigh)) · expires in \(mins) min",
                since: secs(s.createdAt), cells: cells, actions: ["approve", "decline"], hash: s.specHash)
        } else if s.status == .running {
            let detail: String
            if waiting > 0 {
                detail = waiting == 1 ? "1 agent is asking \(s.planner) a question" : "\(waiting) agents are asking \(s.planner) questions"
            } else if s.mode == .propose {
                detail = "\(W.plural(s.changes.total, "change", "changes")) · \(spent)"
            } else {
                detail = "\(spent) spent"
            }
            state = JobLiveState(
                phase: .working, steps: steps, step: 1, headline: "\(done) of \(total) agents done", detail: detail,
                fraction: ratio(ended, total), compact: "\(done)/\(total)", since: secs(s.approvedAt), cells: cells, actions: ["stop"])
        } else if s.status == .stopping {
            state = JobLiveState(
                phase: .working, steps: steps, step: 1, headline: "stopping", detail: "\(done) of \(total) agents done · \(spent)",
                fraction: ratio(ended, total), compact: "\(done)/\(total)", since: secs(s.approvedAt), cells: cells)
        } else if s.mode == .propose && s.applyStatus == .applying {
            let all = s.changes.kept
            state = JobLiveState(
                phase: .working, steps: steps, step: 3, headline: "applying changes", detail: "\(s.changes.done) of \(all)",
                fraction: ratio(s.changes.done, all), compact: "\(s.changes.done)/\(all)", since: secs(s.finishedAt), cells: cells)
        } else if s.mode == .propose && s.applyStatus == .ready && s.changes.open > 0
            && (s.status == .done || s.status == .stopped || s.status == .failed)
        {
            let count = s.changes.open - s.changes.clashes
            let clashes = s.changes.clashes
            state = JobLiveState(
                phase: .waiting, steps: steps, step: 2, headline: "\(W.plural(s.changes.open, "change", "changes")) ready",
                detail: clashes > 0
                    ? "\(clashes) \(clashes == 1 ? "looks like a duplicate and is" : "look like duplicates and are") left out · \(spent)"
                    : "\(spent) spent",
                since: secs(s.finishedAt), cells: cells, actions: count > 0 ? ["check", "apply"] : ["check"], hash: s.specHash, count: count)
        } else if s.mode == .propose && (s.applyStatus == .applied || s.applyStatus == .failed) {
            state = JobLiveState(
                phase: .done, steps: steps, step: steps.count, headline: "applied \(W.plural(s.changes.done, "change", "changes"))",
                detail: s.changes.failed > 0 ? "\(s.changes.failed) failed · \(spent)" : "\(spent) spent", since: secs(s.finishedAt),
                cells: cells, actions: ["open"])
        } else if s.status == .done {
            let words = s.reduce.map(W.collapsed)
            state = JobLiveState(
                phase: .done, steps: steps, step: steps.count, headline: "done",
                detail: (words?.isEmpty == false ? words : nil) ?? "\(done) of \(total) agents done · \(spent)",
                since: secs(s.finishedAt), cells: cells, actions: ["open"])
        } else {
            let capped = s.error == "error.swarm.over_cap" || s.error == "error.swarm.daily_cap"
            let headline = expired ? "expired" : s.status == .declined ? "declined" : capped ? "stopped at its cap" : s.status == .stopped ? "stopped" : "failed"
            var asExpired = s
            if expired { asExpired.status = .expired }
            state = JobLiveState(
                phase: .failed, steps: steps, step: expired || s.status == .declined ? 0 : 1, headline: headline,
                detail: W.reason(asExpired), since: secs(s.finishedAt ?? s.expiresAt), cells: cells, actions: ["open"])
        }
        self = state.canonical()
    }
}

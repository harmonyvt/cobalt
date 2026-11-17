import Foundation

/// The plain words of the swarm screens (apple/CONTRACT-SWARMS.md 3, the approved design). Pure functions, so the app, the
/// widget and the tests say the same thing. Lowercase house copy; never "propose", "scope", "batch", "spec" or "mode".
public enum SwarmWords {
    // MARK: money

    /// "21¢" under $1, "$1.40" above, "$1" for a whole number of dollars. Under half a cent is "<1¢"; nothing is "0¢".
    public static func money(_ usd: Double) -> String {
        guard usd.isFinite, usd > 0 else { return "0¢" }
        let cents = Int((usd * 100).rounded(.toNearestOrAwayFromZero))
        if cents == 0 { return "<1¢" }
        if cents < 100 { return "\(cents)¢" }
        let dollars = cents / 100
        let rest = cents % 100
        return rest == 0 ? "$\(dollars)" : "$\(dollars).\(rest < 10 ? "0" : "")\(rest)"
    }

    // MARK: the list row

    /// The second line of a list row: "claude code asks · 48 min left", "running · 12 of 20", "applied 336", "declined".
    public static func rowLine(_ swarm: Swarm, now: Date) -> String {
        switch swarm.status {
        case .awaitingApproval:
            let who = swarm.planner.map { "\($0) asks" } ?? "asks you"
            guard let expires = swarm.expiresAt else { return who }
            return "\(who) · \(timeLeft(until: expires, now: now))"
        case .running:
            return "running · \(swarm.tasks.done) of \(swarm.tasks.total)"
        case .stopping:
            return "stopping · \(swarm.tasks.done) of \(swarm.tasks.total)"
        case .done:
            switch swarm.apply.status {
            case .ready:
                return "\(swarm.changes?.kept ?? swarm.apply.total) changes ready"
            case .applying:
                return "applying · \(swarm.apply.done) of \(swarm.apply.total)"
            case .applied:
                return "applied \(swarm.apply.done)"
            case .failed:
                return swarm.apply.done > 0 ? "applied \(swarm.apply.done), \(swarm.apply.failed) failed" : "\(swarm.apply.failed) failed"
            case .none:
                return "done"
            }
        case .failed: return "failed"
        case .stopped: return "stopped"
        case .declined: return "declined"
        case .expired: return "expired"
        }
    }

    /// "48 min left", "1 h 5 min left", "less than a minute left", "expired".
    public static func timeLeft(until date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "expired" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 1 { return "less than a minute left" }
        if minutes < 60 { return "\(minutes) min left" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) h left" : "\(h) h \(m) min left"
    }

    // MARK: the three facts

    /// What happens to your data. propose: "you check every change before it happens"; read: "it only looks, nothing
    /// changes"; act: "it changes things itself, only <writes in words>".
    public static func whatHappens(_ swarm: Swarm) -> String {
        switch swarm.mode {
        case .propose: return "you check every change before it happens"
        case .read: return "it only looks, nothing changes"
        case .act:
            let words = writesInWords(swarm.writes)
            return words.isEmpty ? "it changes things itself" : "it changes things itself, only \(words)"
        }
    }

    /// "20 agents, 50 each": the agents and how many items each is given.
    public static func size(_ swarm: Swarm) -> String {
        let agents = swarm.tasks.total > 0 ? swarm.tasks.total : (swarm.tasks.cells.count)
        let who = "\(agents) \(agents == 1 ? "agent" : "agents")"
        return swarm.batchSize > 0 ? "\(who), \(swarm.batchSize) each" : who
    }

    /// "about 30¢–50¢, never more than $1" (the estimate, then the cap). Without an estimate: just the cap.
    public static func cost(_ swarm: Swarm) -> String {
        let cap = "never more than \(money(swarm.capUSD))"
        guard let e = swarm.estimateUSD else { return cap }
        let low = money(e.low)
        let high = money(e.high)
        return low == high ? "about \(low), \(cap)" : "about \(low)–\(high), \(cap)"
    }

    // MARK: the board

    /// A score, 0...1, as "0.75".
    public static func score(_ score: Double) -> String {
        String(format: "%.2f", min(1, max(0, score.isFinite ? score : 0)))
    }

    /// One agent's outcome on its sheet: "20 items · 18 answered · 3 lookups failed · 41 s · 1¢ · score 0.75". Lookups that
    /// failed are left out when there are none.
    public static func outcome(_ o: SwarmOutcome) -> String {
        var parts = ["\(o.items) \(o.items == 1 ? "item" : "items")", "\(o.answered) answered"]
        if o.toolErrors > 0 { parts.append("\(o.toolErrors) \(o.toolErrors == 1 ? "lookup" : "lookups") failed") }
        if let ms = o.ms { parts.append(elapsed(Double(ms) / 1000)) }
        parts.append(money(o.usd))
        if let value = o.score { parts.append("score \(score(value))") }
        return parts.joined(separator: " · ")
    }

    // MARK: writes in words

    /// What an op does, as a verb phrase ("rename emotes"). An op this build does not know is its name with spaces.
    public static func writeWords(_ op: String) -> String {
        switch op {
        case "seventv.rename": return "rename emotes"
        case "seventv.add": return "add emotes to a set"
        case "seventv.remove": return "remove emotes from a set"
        case "library.title": return "change titles"
        case "library.about.set": return "change tags"
        default: return op.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        }
    }

    /// "rename emotes", "rename emotes and change titles", "add emotes, change titles and change tags".
    public static func writesInWords(_ writes: [String]) -> String {
        var seen = Set<String>()
        let words = writes.map(writeWords).filter { seen.insert($0).inserted }
        switch words.count {
        case 0: return ""
        case 1: return words[0]
        default: return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        }
    }

    // MARK: the swarm screen

    /// The small line above the sentence: "claude code asks · expires in 52 min", "running · 3 min", "342 changes ready".
    public static func statusLine(_ swarm: Swarm, now: Date) -> String {
        switch swarm.status {
        case .awaitingApproval:
            let who = swarm.planner.map { "\($0) asks" } ?? "waiting for you"
            guard let expires = swarm.expiresAt else { return who }
            let left = expires.timeIntervalSince(now)
            if left <= 0 { return "\(who) · expired" }
            return "\(who) · expires in \(Int((left / 60).rounded(.up))) min"
        case .running, .stopping:
            let since = swarm.approvedAt ?? swarm.createdAt
            return "\(swarm.status == .stopping ? "stopping" : "running") · \(elapsed(max(0, now.timeIntervalSince(since))))"
        default:
            return rowLine(swarm, now: now)
        }
    }

    /// "40 s", "3 min", "1 h 5 min".
    public static func elapsed(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// The agent sheet's second line: "done in 41 s · 1¢ · items 151–200", "failed twice · items 301–350".
    public static func agentLine(_ agent: SwarmAgent, batchSize: Int) -> String {
        let range = batchSize > 0 ? "items \((agent.agent - 1) * batchSize + 1)–\(agent.agent * batchSize)" : nil
        var parts: [String] = []
        switch agent.status {
        case .done:
            parts.append(agent.seconds.map { "done in \(elapsed($0))" } ?? "done")
            parts.append(money(agent.usd))
        case .failed:
            parts.append(agent.attempts > 1 ? "failed \(agent.attempts == 2 ? "twice" : "\(agent.attempts) times")" : "failed")
        case .running: parts.append("working")
        case .waiting: parts.append("waiting for an answer")
        case .skipped: parts.append("skipped")
        case .queued: parts.append("waiting its turn")
        }
        if let range { parts.append(range) }
        return parts.joined(separator: " · ")
    }
}

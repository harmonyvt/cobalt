import Foundation
import Synchronization

// Swarms in previews (APP-API-CONTRACT 59, 61, 62; apple/CONTRACT-SWARMS.md). Every preview server has swarms, so the screens,
// the tests and the simulator run offline. The data is the approved design's story (swarms in the app, v2).
//
// STARTING STATE, for screenshots and simulator evidence: launch with `-previewSwarm <state>` (UserDefaults key
// `previewSwarm`, read in DEBUG and release alike like the other preview flags, e.g. `-previewMoreList 1`):
//
//     awaiting   "rename 1,000 emotes in capybaraharmony to house style" asks claude code (expires in 52 min)   [default]
//     running    the same swarm, 12 of 20 agents done, agent 7 failed, 13 to 15 running, agent 3 waiting on a question
//     review     the same swarm, finished: 342 changes ready, 4 of them clash ("duplicate name: also proposed by #118")
//     applying   the same swarm applying its changes (about 6 s, then applied)
//     done       the same swarm applied: 336 renamed, 2 could not be renamed
//     failed     "tag dog videos", no agent finished
//     declined   "rename sets in capybaraharmony", declined
//     board      "find christmas variants of nyaphelia emotes": a general read swarm with a results board (about 380 rows)
//     list       nothing featured: just the list
//
// The story swarm (`PreviewSwarmIDs.story`) is in that state; `PreviewSwarmStart.swarmID` is the swarm a screen opens on that
// flag. The list always holds the story swarm and nine others in every other state (a plan from chatgpt waiting, a tag run
// done yesterday, a title fix applied, one applying, failed, declined, expired, stopped, and the board swarm).
//
// The server behaves like the real one: approve needs the plan's hash and starts the run (an agent finishes every 2 s, then the
// swarm is ready or done), decline ends it, stop goes through "stopping", decide ticks and renames changes and refreshes the
// clashes, apply (with `skipClashes` unticking them) takes about 6 s and ends applied, send adds a `you` message and wakes an
// agent that waits on a question. All of it runs on the pipeline's clock.

/// What `-previewSwarm` says the preview starts on.
public enum PreviewSwarmStart: String, Sendable, CaseIterable {
    case awaiting, running, review, applying, done, failed, declined, board, list

    /// The flag, when it is set to one of these.
    public static var launch: PreviewSwarmStart? {
        UserDefaults.standard.string(forKey: "previewSwarm").flatMap(PreviewSwarmStart.init(rawValue:))
    }

    /// The swarm a screen opens on this start; nil for `list`.
    public var swarmID: String? {
        switch self {
        case .awaiting, .running, .review, .applying, .done: return PreviewSwarmIDs.story
        case .failed: return PreviewSwarmIDs.failed
        case .declined: return PreviewSwarmIDs.declined
        case .board: return PreviewSwarmIDs.board
        case .list: return nil
        }
    }
}

public enum PreviewSwarmIDs {
    static func id(_ n: Int) -> String { "PrEvIeWswarm" + String(format: "%04d", n) }
    /// The design's story: "rename 1,000 emotes in capybaraharmony to house style", in whatever state the start says.
    public static let story = id(1)
    /// "merge duplicate titles", chatgpt asks.
    public static let merge = id(2)
    public static let tag = id(3)
    public static let streamTitles = id(4)
    public static let shorten = id(5)
    public static let failed = id(6)
    public static let declined = id(7)
    public static let expired = id(8)
    public static let stopped = id(9)
    /// A general read swarm with a results board.
    public static let board = id(10)
}

// MARK: - the data

enum PreviewSwarmData {
    static let storyName = "rename 1,000 emotes in capybaraharmony to house style"
    static let setID = "01PREVIEWSET0000000000001"
    static let emoteBase: [String] = [
        "CatJam", "pepe Laugh", "BONK", "Capy Wave", "HYPERS", "sad cat", "o7 Salute", "widePeepo", "Clapping", "Pog Champ",
        "catNod", "KEKW", "monkaS", "sleepyCapy", "Wide Capy", "Yippee Dance", "COPIUM", "Sadge Rain", "peepoClap", "OMEGALUL",
        "bocchi Nod", "Kappa Pride", "gigaChad", "pepeJAM",
    ]

    /// The old name of emote `i` (0-based): a base name, numbered after the first round.
    static func emoteName(_ i: Int) -> String {
        let base = emoteBase[i % emoteBase.count]
        return i < emoteBase.count ? base : "\(base) \(i / emoteBase.count + 1)"
    }

    static func houseStyle(_ name: String) -> String { name.lowercased().filter { !$0.isWhitespace } }
    static func emoteID(_ i: Int) -> String { "01PREVIEWEMOTE" + String(format: "%010d", i) }

    /// 342 renames across 20 agents; #3 and #118 both become "bonk", #40 and #201 both become "clapclap".
    static func storyChanges() -> [SwarmChange] {
        let special: [Int: String] = [118: "Bonk", 40: "Clap Clap", 201: "clapClap"]
        var out: [SwarmChange] = (1...342).map { n in
            let old = special[n] ?? emoteName(n - 1)
            let new = houseStyle(old)
            return SwarmChange(
                n: n, task: (n - 1) * 20 / 342, op: "seventv.rename",
                args: .dictionary(["set_id": .string(setID), "emote_id": .string(emoteID(n)), "alias": .string(new)]),
                target: "capybaraharmony", before: old, after: new, editArg: "alias",
                previewURL: URL(string: "https://cdn.7tv.app/emote/\(emoteID(n))/2x.webp"))
        }
        refreshClashes(&out)
        return out
    }

    /// The server's check (59.6): kept changes of one op and target that take the same name, without case.
    static func refreshClashes(_ changes: inout [SwarmChange]) {
        var groups: [String: [Int]] = [:]
        for c in changes where c.keep && c.status != .done {
            guard let after = c.after, !after.isEmpty else { continue }
            groups["\(c.op)\n\(c.target ?? "")\n\(after.lowercased())", default: []].append(c.n)
        }
        var clash: [Int: String] = [:]
        for ns in groups.values where ns.count > 1 {
            for n in ns { clash[n] = "duplicate name: also proposed by #" + ns.filter { $0 != n }.prefix(3).map(String.init).joined(separator: ", #") }
        }
        for i in changes.indices { changes[i].clash = changes[i].keep && changes[i].status != .done ? clash[changes[i].n] : nil }
    }

    static func cells(_ statuses: [SwarmCell.Status], failure: [Int: String] = [:]) -> [SwarmCell] {
        statuses.enumerated().map { i, s in
            let step: String?
            switch s {
            case .done: step = "done"
            case .running: step = "read seventv.set"
            case .waiting: step = "asked a question"
            case .failed: step = "failed: bad_answer"
            default: step = nil
            }
            return SwarmCell(idx: i, status: s, error: failure[i], step: step)
        }
    }

    /// The design's running grid: 12 done (1, 2, 4 to 6, 8 to 12, 16, 17), 7 failed, 13 to 15 running, 3 waiting, 18 to 20 queued.
    static func runningCells() -> [SwarmCell] {
        var s = [SwarmCell.Status](repeating: .queued, count: 20)
        for a in [1, 2, 4, 5, 6, 8, 9, 10, 11, 12, 16, 17] { s[a - 1] = .done }
        s[6] = .failed
        for a in 13...15 { s[a - 1] = .running }
        s[2] = .waiting
        return cells(s, failure: [6: "error.swarm.bad_answer: its answer could not be read"])
    }

    static func sample(_ i: Int) -> JSONValue { .dictionary(["id": .string(emoteID(i)), "name": .string(emoteName(i))]) }

    /// One swarm with the values every state shares; the caller changes the rest.
    static func base(
        _ n: Int, _ name: String, mode: Swarm.Mode = .propose, status: Swarm.Status, agents: Int, each: Int, planner: String,
        writes: [String], now: Date, ageMinutes: Double
    ) -> Swarm {
        let id = PreviewSwarmIDs.id(n)
        var s = Swarm(
            id: id, name: name, mode: mode, status: status, specHash: "PrEvIeWhash" + String(format: "%04d", n),
            prompt: "for each item, look it up and answer exactly the JSON the schema says. be short; never guess.",
            tools: mode == .propose || writes.contains("seventv.rename") ? ["seventv.set", "seventv.emote"] : ["library.search", "look"],
            writes: writes, scope: .dictionary(["set_id": .string(setID)]), items: agents * each, batchSize: each, concurrency: 5,
            tasks: Swarm.Tasks(total: agents, queued: agents, cells: cells([SwarmCell.Status](repeating: .queued, count: agents))),
            estimateUSD: .init(low: 0.0015 * Double(agents) * 10, high: 0.0025 * Double(agents) * 10), capUSD: 1,
            createdAt: now.addingTimeInterval(-ageMinutes * 60), planner: planner,
            approveURL: URL(string: "https://cobalt.capybaraharmony.com/swarms/\(id)"), job: "swarm:\(id)")
        s.preview = Swarm.SpecPreview(
            itemsSample: (0..<10).map(sample),
            source: .init(call: "seventv.set", args: ["set_id": .string(setID)], path: "emotes"),
            outputSchema: nil, reducePrompt: nil, turnsPerTask: 6, attempts: 2, stopAfterFailedTasks: 5)
        s.messages = .init()
        if status == .awaitingApproval { s.expiresAt = now.addingTimeInterval(52 * 60) }
        return s
    }
}

// MARK: - the server

/// What the preview "server" holds for the swarm routes: the swarms, their changes, messages and boards, every call made.
final class PreviewSwarmState: Sendable {
    struct Record: Sendable {
        var swarm: Swarm
        var changes: [SwarmChange] = []
        var messages: [SwarmMessage] = []
        var boardRows: [BoardRow] = []
        var boardGroups: Bool = false
        /// Past agent details kept for the ones that were given a story (steps), by agent number.
        var outcomes: [Int: SwarmOutcome] = [:]
        /// The run is live: an agent ends every 2 s from here.
        var runStart: Date?
        /// A stop was asked at this time: "stopping" for 2 s, then "stopped".
        var stopAt: Date?
        /// Applying: the changes it sends (their numbers) and when it started; it takes 6 s.
        var applyStart: Date?
        var applyPlan: [Int] = []
    }

    private struct State {
        var records: [Record] = []
        var calls: [String] = []
        var counter = 0
    }

    private let state = Mutex(State())
    static let secondsPerAgent = 2.0
    static let applySeconds = 6.0

    var calls: [String] { state.withLock { $0.calls } }
    func record(_ call: String) { state.withLock { $0.calls.append(call) } }
    var swarms: [Swarm] { state.withLock { $0.records.map(\.swarm) } }

    // MARK: seeding

    func seed(_ start: PreviewSwarmStart, now: Date) {
        typealias D = PreviewSwarmData
        var records: [Record] = []

        // the story, in the state the start says
        var story = Record(swarm: D.base(1, D.storyName, status: .awaitingApproval, agents: 20, each: 50, planner: "claude code", writes: ["seventv.rename"], now: now, ageMinutes: 8))
        story.swarm.estimateUSD = .init(low: 0.30, high: 0.50)
        story.changes = D.storyChanges()
        story.messages = Self.storyMessages(now: now)
        switch start {
        case .running:
            story.swarm.status = .running
            story.swarm.expiresAt = nil
            story.swarm.approvedAt = now.addingTimeInterval(-192)
            story.swarm.spentUSD = 0.21
            story.swarm.tasks.cells = D.runningCells()
            story.swarm.messages = .init(total: story.messages.count, waiting: 1)
        case .review, .applying, .done:
            story.swarm.status = .done
            story.swarm.expiresAt = nil
            story.swarm.approvedAt = now.addingTimeInterval(-9 * 60)
            story.swarm.finishedAt = now.addingTimeInterval(-3 * 60)
            story.swarm.spentUSD = 0.44
            story.swarm.score = 0.91
            story.swarm.tasks.cells = D.cells([SwarmCell.Status](repeating: .done, count: 20))
            story.messages = Array(story.messages.dropLast())          // the last question was answered
            story.messages[story.messages.count - 1].answered = true
            story.swarm.messages = .init(total: story.messages.count, waiting: 0)
            story.swarm.apply = .init(status: .ready)
            if start == .applying {
                Self.beginApply(&story, skipClashes: true, now: now.addingTimeInterval(-2))
            } else if start == .done {
                Self.beginApply(&story, skipClashes: true, now: now.addingTimeInterval(-3600))
                story.applyStart = nil
                Self.finishApply(&story, now: now.addingTimeInterval(-3500))
            }
        default: break
        }
        Self.refresh(&story, now: now)
        records.append(story)

        // a plan from chatgpt, waiting
        var merge = Record(swarm: D.base(2, "merge duplicate titles", status: .awaitingApproval, agents: 6, each: 50, planner: "chatgpt", writes: ["library.title"], now: now, ageMinutes: 12))
        merge.swarm.expiresAt = now.addingTimeInterval(48 * 60)
        merge.swarm.estimateUSD = .init(low: 0.18, high: 0.30)
        merge.swarm.capUSD = 0.5
        merge.swarm.tools = ["library.search", "look"]
        merge.swarm.scope = .dictionary(["id": .string("all posts")])
        records.append(merge)

        // a tag run that acted on its own, done yesterday
        var tag = Record(swarm: D.base(3, "tag gaming clips", mode: .act, status: .done, agents: 20, each: 50, planner: "claude code", writes: ["library.about.set"], now: now, ageMinutes: 26 * 60))
        tag.swarm.approvedAt = now.addingTimeInterval(-25.9 * 3600)
        tag.swarm.finishedAt = now.addingTimeInterval(-25.6 * 3600)
        tag.swarm.spentUSD = 0.38
        tag.swarm.score = 0.91
        tag.swarm.reduce = "tagged 971 clips; 29 had no clear game."
        tag.swarm.tasks.cells = D.cells([SwarmCell.Status](repeating: .done, count: 20))
        Self.refresh(&tag, now: now)
        records.append(tag)

        // a small title fix, applied
        var titles = Record(swarm: D.base(4, "fix stream titles", status: .done, agents: 3, each: 20, planner: "chat", writes: ["library.title"], now: now, ageMinutes: 2 * 3600))
        titles.swarm.approvedAt = now.addingTimeInterval(-119 * 60)
        titles.swarm.finishedAt = now.addingTimeInterval(-115 * 60)
        titles.swarm.spentUSD = 0.07
        titles.swarm.score = 0.88
        titles.swarm.tasks.cells = D.cells([SwarmCell.Status](repeating: .done, count: 3))
        titles.changes = (1...41).map { n in
            SwarmChange(n: n, task: (n - 1) * 3 / 41, op: "library.title", target: "library", before: "stream clip \(n)", after: "stream · clip \(n)", editArg: "title", status: .done)
        }
        titles.swarm.apply = .init(status: .applied, done: 41, failed: 0, total: 41)
        Self.refresh(&titles, now: now)
        records.append(titles)

        // one applying for good (frozen, so the list always has a progress row)
        var shorten = Record(swarm: D.base(5, "shorten old clip titles", status: .done, agents: 8, each: 25, planner: "claude code", writes: ["library.title"], now: now, ageMinutes: 30))
        shorten.swarm.approvedAt = now.addingTimeInterval(-25 * 60)
        shorten.swarm.finishedAt = now.addingTimeInterval(-10 * 60)
        shorten.swarm.spentUSD = 0.12
        shorten.swarm.tasks.cells = D.cells([SwarmCell.Status](repeating: .done, count: 8))
        shorten.changes = (1...200).map { n in
            SwarmChange(n: n, task: (n - 1) * 8 / 200, op: "library.title", target: "library", before: "old clip title \(n)", after: "clip \(n)", editArg: "title", status: n <= 120 ? .done : .proposed)
        }
        shorten.swarm.apply = .init(status: .applying, done: 120, failed: 0, total: 200)
        Self.refresh(&shorten, now: now)
        records.append(shorten)

        var failed = Record(swarm: D.base(6, "tag dog videos", mode: .act, status: .failed, agents: 10, each: 50, planner: "mcp", writes: ["library.about.set"], now: now, ageMinutes: 5 * 3600))
        failed.swarm.approvedAt = now.addingTimeInterval(-299 * 60)
        failed.swarm.finishedAt = now.addingTimeInterval(-296 * 60)
        failed.swarm.spentUSD = 0.05
        failed.swarm.error = "error.swarm.all_failed"
        failed.swarm.tasks.cells = D.cells([SwarmCell.Status](repeating: .failed, count: 10), failure: Dictionary(uniqueKeysWithValues: (0..<10).map { ($0, "error.swarm.model") }))
        Self.refresh(&failed, now: now)
        records.append(failed)

        var declined = Record(swarm: D.base(7, "rename sets in capybaraharmony", status: .declined, agents: 4, each: 25, planner: "claude code", writes: ["seventv.rename"], now: now, ageMinutes: 7 * 3600))
        declined.swarm.finishedAt = now.addingTimeInterval(-419 * 60)
        records.append(declined)

        var expired = Record(swarm: D.base(8, "retag cat clips", mode: .act, status: .expired, agents: 6, each: 50, planner: "mcp", writes: ["library.about.set"], now: now, ageMinutes: 9 * 3600))
        expired.swarm.finishedAt = now.addingTimeInterval(-479 * 60)
        records.append(expired)

        var stopped = Record(swarm: D.base(9, "tag music clips", mode: .act, status: .stopped, agents: 12, each: 50, planner: "claude code", writes: ["library.about.set"], now: now, ageMinutes: 30 * 3600))
        stopped.swarm.approvedAt = now.addingTimeInterval(-29.9 * 3600)
        stopped.swarm.finishedAt = now.addingTimeInterval(-29.8 * 3600)
        stopped.swarm.spentUSD = 1.0
        stopped.swarm.error = "error.swarm.over_cap"
        var stoppedCells = [SwarmCell.Status](repeating: .done, count: 12)
        for i in 7..<12 { stoppedCells[i] = .skipped }
        stopped.swarm.tasks.cells = D.cells(stoppedCells)
        Self.refresh(&stopped, now: now)
        records.append(stopped)

        records.append(Self.boardRecord(now: now))
        state.withLock { s in
            s.records = records
            s.calls = []
            s.counter = 100
        }
    }

    // MARK: messages of the story

    static func storyMessages(now: Date) -> [SwarmMessage] {
        let id = PreviewSwarmIDs.story
        func m(_ n: Int, _ agent: Int?, _ dir: SwarmMessage.Dir, _ kind: SwarmMessage.Kind, _ sender: SwarmMessage.Sender, _ text: String, ago: Double, answered: Bool = false) -> SwarmMessage {
            SwarmMessage(id: n, swarm: id, agent: agent, dir: dir, kind: kind, sender: sender, text: text, at: now.addingTimeInterval(-ago), answered: answered)
        }
        return [
            m(1, 7, .up, .ask, .agent, "\"o7 Salute\": should it be o7salute or salute? the 7 might be meaningful.", ago: 170, answered: true),
            m(2, 7, .down, .reply, .owner, "keep the o7, it's a salute emote. o7salute.", ago: 150),
            m(3, 7, .up, .tell, .agent, "thanks, done: 11 renames.", ago: 120),
            m(4, nil, .down, .tell, .owner, "keep numbers in names, e.g. 7tv not seventv.", ago: 100),
            m(5, 9, .up, .tell, .agent, "found 3 emotes that aren't in the set any more, skipped them.", ago: 80),
            m(6, 3, .up, .ask, .agent, "\"wide Peepo\": widepeepo, or keep the capital as widePeepo? it reads as two words.", ago: 40),
        ]
    }

    // MARK: moving a record

    /// The counts, spent and score a record shows, from its cells and changes.
    static func refresh(_ r: inout Record, now: Date) {
        let cells = r.swarm.tasks.cells
        func count(_ s: SwarmCell.Status) -> Int { cells.filter { $0.status == s }.count }
        r.swarm.tasks.total = cells.count
        r.swarm.tasks.queued = count(.queued)
        r.swarm.tasks.running = count(.running)
        r.swarm.tasks.done = count(.done)
        r.swarm.tasks.failed = count(.failed)
        r.swarm.tasks.waiting = count(.waiting)
        if r.swarm.mode == .propose, !r.changes.isEmpty {
            let visible = r.swarm.status == .running || r.swarm.status == .stopping
                ? r.changes.filter { $0.task < cells.count && cells[$0.task].status == .done } : r.changes
            let hidden = r.swarm.status == .awaitingApproval || r.swarm.status == .declined || r.swarm.status == .expired
            if hidden {
                r.swarm.changes = .init()
            } else {
                let kept = visible.filter(\.keep)
                r.swarm.changes = .init(
                    total: visible.count, kept: kept.count, done: kept.filter { $0.status == .done }.count,
                    failed: kept.filter { $0.status == .failed }.count)
            }
            if r.swarm.apply.status == .ready || r.swarm.apply.status == .applied || r.swarm.apply.status == .failed {
                r.swarm.apply.total = r.swarm.changes?.kept ?? 0
                if r.swarm.apply.status != .ready {
                    r.swarm.apply.done = r.swarm.changes?.done ?? 0
                    r.swarm.apply.failed = r.swarm.changes?.failed ?? 0
                }
            }
        } else if r.swarm.mode == .propose {
            r.swarm.changes = r.swarm.status == .awaitingApproval ? .init() : r.swarm.changes ?? .init()
        }
        r.swarm.messages = .init(total: r.messages.count, waiting: r.messages.filter(\.isOpenAsk).count)
    }

    /// Moves a record with the clock: the run, a stop, an apply.
    static func advance(_ r: inout Record, now: Date) {
        if let at = r.stopAt, now >= at.addingTimeInterval(2) {
            r.swarm.status = .stopped
            r.swarm.finishedAt = now
            r.swarm.error = nil
            for i in r.swarm.tasks.cells.indices where [.queued, .running, .waiting].contains(r.swarm.tasks.cells[i].status) {
                r.swarm.tasks.cells[i].status = .skipped
                r.swarm.tasks.cells[i].step = nil
            }
            r.stopAt = nil
            r.runStart = nil
        } else if let start = r.runStart, r.swarm.status == .running {
            let total = r.swarm.tasks.cells.count
            let done = min(total, Int(max(0, now.timeIntervalSince(start)) / secondsPerAgent))
            for i in 0..<total {
                r.swarm.tasks.cells[i].status = i < done ? .done : i < done + 3 ? .running : .queued
                r.swarm.tasks.cells[i].step = i < done ? "done" : i < done + 3 ? "read seventv.set" : nil
            }
            r.swarm.spentUSD = 0.022 * Double(done)
            if done == total {
                r.swarm.status = .done
                r.swarm.finishedAt = start.addingTimeInterval(Double(total) * secondsPerAgent)
                r.swarm.score = 0.9
                r.runStart = nil
                if r.swarm.mode == .propose, !r.changes.isEmpty { r.swarm.apply.status = .ready }
            }
        }
        if let start = r.applyStart, r.swarm.apply.status == .applying {
            let plan = r.applyPlan
            let progress = min(1, max(0, now.timeIntervalSince(start)) / applySeconds)
            let done = Int(progress * Double(plan.count))
            if progress >= 1 {
                finishApply(&r, now: start.addingTimeInterval(applySeconds))
            } else {
                let sent = Set(plan.prefix(done))
                for i in r.changes.indices where sent.contains(r.changes[i].n) { r.changes[i].status = .done }
                r.swarm.apply.done = done
            }
        }
        refresh(&r, now: now)
    }

    static func beginApply(_ r: inout Record, skipClashes: Bool, now: Date) {
        if skipClashes {
            for i in r.changes.indices where r.changes[i].clash != nil && r.changes[i].keep && r.changes[i].status != .done { r.changes[i].keep = false }
            PreviewSwarmData.refreshClashes(&r.changes)
        }
        for i in r.changes.indices where r.changes[i].keep && r.changes[i].status == .failed { r.changes[i].status = .proposed; r.changes[i].error = nil }
        r.applyPlan = r.changes.filter { $0.keep && $0.status != .done }.map(\.n)
        r.applyStart = now
        r.swarm.apply = .init(status: .applying, done: 0, failed: 0, total: r.changes.filter(\.keep).count)
    }

    /// Everything sent: the last two of a long list could not be renamed ("failed" like the server when any change failed).
    static func finishApply(_ r: inout Record, now: Date) {
        let plan = r.applyPlan
        let failing = plan.count > 100 ? Set(plan.suffix(2)) : []
        for i in r.changes.indices where plan.contains(r.changes[i].n) {
            if failing.contains(r.changes[i].n) {
                r.changes[i].status = .failed
                r.changes[i].error = "error.seventv.not_found"
            } else {
                r.changes[i].status = .done
            }
        }
        r.swarm.apply.status = failing.isEmpty ? .applied : .failed
        r.applyStart = nil
        r.applyPlan = []
        r.swarm.finishedAt = now
    }

    // MARK: the board swarm

    static func boardRecord(now: Date) -> Record {
        typealias D = PreviewSwarmData
        var s = D.base(10, "find christmas variants of nyaphelia emotes", mode: .read, status: .done, agents: 21, each: 20, planner: "claude code", writes: [], now: now, ageMinutes: 60)
        s.items = 419
        s.tools = ["seventv.search", "look"]
        s.scope = nil
        s.approvedAt = now.addingTimeInterval(-55 * 60)
        s.finishedAt = now.addingTimeInterval(-50 * 60)
        s.spentUSD = 0.31
        s.reduce = "found 371 variants; 8 look wrong."
        s.estimateUSD = .init(low: 0.25, high: 0.45)
        s.tasks.cells = D.cells((0..<21).map { $0 == 11 ? .failed : .done }, failure: [11: "error.swarm.out_of_turns"])

        let words = ["santa", "snowman", "reindeer", "tree", "wreath", "elf", "gift", "stocking", "candy cane", "snowflake", "cocoa", "lights", "bells", "star", "sleigh", "mittens", "cookie", "fireplace", "scarf", "angel"]
        var rows: [BoardRow] = []
        var outcomes: [Int: SwarmOutcome] = [:]
        var uniq = 0
        for agent in 1...21 {
            let items = agent == 21 ? 19 : 20
            if agent == 12 {
                let names = (0..<3).map { "nyaphelia \(words[($0 + 5) % words.count])" }.joined(separator: ", ") + ", and 17 more"
                rows.append(BoardRow(agent: 12, n: 1, title: "agent 12 failed: ran out of turns", fields: [BoardField(key: "items", value: names)]))
                outcomes[12] = SwarmOutcome(status: .failed, items: items, answered: 0, toolCalls: 31, toolErrors: 9, asks: 0, turns: 6, usd: 0.02, ms: 52_000, score: 0)
                continue
            }
            let answered = items - (agent % 5 == 0 ? 2 : agent % 3 == 0 ? 1 : 0)
            let toolCalls = 24 + agent % 4
            let toolErrors = agent % 7 == 0 ? 3 : agent % 4 == 0 ? 1 : 0
            let score = (Double(answered) / Double(items)) * (1 - Double(toolErrors) / Double(max(toolCalls, 1)))
            outcomes[agent] = SwarmOutcome(status: .done, items: items, answered: answered, toolCalls: toolCalls, toolErrors: toolErrors, asks: 0, turns: 4, usd: 0.012, ms: 31_000 + agent * 700, score: (score * 100).rounded() / 100)
            for n in 1...answered {
                uniq += 1
                let word = words[(uniq + agent) % words.count]
                let title = "nyaphelia \(word)" + (uniq > words.count ? " \(uniq / words.count + 1)" : "")
                let eid = D.emoteID(5_000 + uniq)
                var media: [MediaRef] = [
                    MediaRef(ref: eid, kind: .emote, previewURL: URL(string: "https://cdn.7tv.app/emote/\(eid)/2x.webp"), openURL: URL(string: "https://7tv.app/emotes/\(eid)"), title: title, animated: uniq % 3 != 0),
                ]
                if uniq % 11 == 0 {
                    let key = String(format: "PrEvIeW%03d", uniq % 17)
                    media.append(MediaRef(ref: key, kind: .post, previewURL: URL(string: "https://media.capybaraharmony.com/\(key).jpg"), openURL: URL(string: "https://share.capybaraharmony.com/\(key)"), title: "stream clip with it"))
                }
                if uniq % 29 == 0 {
                    media.append(MediaRef(ref: "PrEvIeWclip\(uniq)", kind: .video, previewURL: URL(string: "https://media.capybaraharmony.com/PrEvIeW009.jpg"), openURL: URL(string: "https://media.capybaraharmony.com/PrEvIeW009.mp4"), title: "the clip it came from", animated: true))
                }
                if uniq % 41 == 0 { media.append(MediaRef(ref: "https://example.com/nope.png", error: "that host is not allowed")) }
                let sc = max(0.1, min(1, 0.95 - Double((uniq * 7) % 60) / 100))
                let grade = sc >= 0.75 ? "exact" : sc >= 0.5 ? "close" : "different"
                rows.append(BoardRow(
                    agent: agent, n: n, title: title, score: (sc * 100).rounded() / 100, group: grade,
                    fields: [
                        BoardField(key: "emote", value: title.replacingOccurrences(of: " ", with: "_")),
                        BoardField(key: "set", value: "nyaphelia"),
                        BoardField(key: "uses", value: String(120 + (uniq * 37) % 900)),
                        BoardField(key: "animated", value: uniq % 3 != 0 ? "yes" : "no"),
                        BoardField(key: "reason", value: grade == "exact" ? "wears a santa hat on the original" : grade == "close" ? "same pose, winter colours" : "only the name matches"),
                    ],
                    media: media, links: [URL(string: "https://7tv.app/emotes/\(eid)")!]))
            }
        }
        s.score = 0.84
        var r = Record(swarm: s)
        r.boardRows = rows
        r.boardGroups = true
        r.outcomes = outcomes
        refresh(&r, now: now)
        return r
    }

    // MARK: reads

    private func advanced(_ now: Date) -> [Record] {
        state.withLock { s in
            for i in s.records.indices { Self.advance(&s.records[i], now: now) }
            return s.records
        }
    }

    func list(now: Date) -> [Swarm] { advanced(now).map(\.swarm) }

    func get(_ id: String, now: Date) throws -> Swarm {
        guard let r = advanced(now).first(where: { $0.swarm.id == id }) else { throw SwarmError.notFound }
        return r.swarm
    }

    func changes(_ id: String, offset: Int, limit: Int, now: Date) throws -> SwarmChangePage {
        guard let r = advanced(now).first(where: { $0.swarm.id == id }) else { throw SwarmError.notFound }
        let visible = Self.visibleChanges(r)
        let start = min(max(0, offset), visible.count)
        return SwarmChangePage(changes: Array(visible[start..<min(visible.count, start + max(1, min(200, limit)))]), total: visible.count, offset: start)
    }

    static func visibleChanges(_ r: Record) -> [SwarmChange] {
        switch r.swarm.status {
        case .awaitingApproval, .declined, .expired: return []
        case .running, .stopping:
            let cells = r.swarm.tasks.cells
            return r.changes.filter { $0.task < cells.count && cells[$0.task].status == .done }
        default: return r.changes
        }
    }

    func messages(_ id: String, agent: Int?, now: Date) throws -> [SwarmMessage] {
        guard let r = advanced(now).first(where: { $0.swarm.id == id }) else { throw SwarmError.notFound }
        guard let agent else { return r.messages }
        return r.messages.filter { $0.agent == agent || $0.agent == nil }
    }

    func agent(_ id: String, _ n: Int, now: Date) throws -> SwarmAgent {
        guard let r = advanced(now).first(where: { $0.swarm.id == id }) else { throw SwarmError.notFound }
        guard r.swarm.tasks.cells.indices.contains(n - 1) else { throw SwarmError.notFound }
        let cell = r.swarm.tasks.cells[n - 1]
        let each = max(1, r.swarm.batchSize)
        let items: [JSONValue] = r.swarm.id == PreviewSwarmIDs.story
            ? (0..<each).map { PreviewSwarmData.sample((n - 1) * each + $0) } : (0..<min(each, 10)).map { .string("item \((n - 1) * each + $0 + 1)") }
        let own = r.changes.filter { $0.task == n - 1 }
        let ago: Double = cell.status == .done ? 60 + Double(n) * 3 : 30
        let at = { (s: Double) in now.addingTimeInterval(-ago + s) }
        var steps: [SwarmAgent.Step] = []
        if cell.status != .queued {
            steps.append(.init(at: at(0), text: "started"))
            steps.append(.init(at: at(4), text: r.swarm.id == PreviewSwarmIDs.story ? "read seventv.set" : "read library.search"))
        }
        if cell.status == .waiting { steps.append(.init(at: at(20), text: "asked a question")) }
        if cell.status == .failed { steps.append(.init(at: at(30), text: "retrying")); steps.append(.init(at: at(41), text: "failed: bad_answer")) }
        if cell.status == .done {
            if !own.isEmpty { steps.append(.init(at: at(20), text: "proposed \(own.count) changes")) }
            steps.append(.init(at: at(Double(30 + n)), text: "done"))
        }
        let thread = r.messages.filter { $0.agent == n || $0.agent == nil }
        let outcome = r.outcomes[n]
        var agent = SwarmAgent(
            swarm: id, agent: n, status: cell.status, items: items, attempts: cell.status == .failed ? 2 : cell.status == .queued ? 0 : 1,
            inTokens: cell.status == .queued ? 0 : 9_200 + n * 40, outTokens: cell.status == .queued ? 0 : 1_300 + n * 10,
            usd: cell.status == .queued ? 0 : cell.status == .done ? 0.011 : 0.006,
            startedAt: cell.status == .queued ? nil : at(0),
            endedAt: cell.status == .done || cell.status == .failed ? at(Double(30 + n)) : nil,
            error: cell.error, steps: steps, messages: thread, changes: own)
        if let outcome { agent.usd = outcome.usd; agent.endedAt = agent.startedAt.map { $0.addingTimeInterval(Double(outcome.ms) / 1000) } }
        return agent
    }

    // MARK: the board

    func board(
        _ id: String, query: String?, agent: Int?, status: String?, group: String?, sort: BoardSort, offset: Int, limit: Int, now: Date
    ) throws -> SwarmBoard {
        guard let r = advanced(now).first(where: { $0.swarm.id == id }) else { throw SwarmError.notFound }
        let cells = r.swarm.tasks.cells
        let outcomes = r.outcomes
        let agents: [BoardAgent] = cells.map { c in
            BoardAgent(agent: c.agent, status: c.status, outcome: outcomes[c.agent] ?? Self.outcome(of: r, cell: c), error: c.error)
        }
        var rows = Self.boardRows(r)
        let groups = Dictionary(grouping: rows.compactMap(\.group), by: { $0 }).map { BoardGroup(value: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.value) > ($1.count, $0.value) }
        if let agent { rows = rows.filter { $0.agent == agent } }
        if let status, !status.isEmpty {
            let allowed = Set(cells.filter { $0.status.rawValue == status }.map(\.agent))
            rows = rows.filter { allowed.contains($0.agent) }
        }
        if let group, !group.isEmpty { rows = rows.filter { $0.group == group } }
        if let q = query?.lowercased(), !q.isEmpty {
            rows = rows.filter { row in
                ([row.title, row.group].compactMap { $0 } + row.fields.map(\.value) + row.media.compactMap(\.title)).contains { $0.lowercased().contains(q) }
            }
        }
        switch sort {
        case .agent: break
        case .score: rows.sort { ($0.score ?? -1) > ($1.score ?? -1) }
        case .title: rows.sort { ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending }
        }
        let start = min(max(0, offset), rows.count)
        let page = Array(rows[start..<min(rows.count, start + max(1, min(200, limit)))])
        return SwarmBoard(swarm: r.swarm, total: rows.count, offset: start, groups: groups, agents: agents, rows: page)
    }

    /// The rows a swarm has: its own board, else one per proposed change, else one per agent that ended.
    static func boardRows(_ r: Record) -> [BoardRow] {
        if !r.boardRows.isEmpty { return r.boardRows }
        let changes = visibleChanges(r)
        if !changes.isEmpty {
            return changes.map { c in
                BoardRow(
                    agent: c.agent, n: c.n, title: "\(c.before ?? "?") → \(c.after ?? "?")", score: c.clash == nil ? 0.9 : 0.4,
                    group: c.clash == nil ? "ready" : "clash",
                    fields: [BoardField(key: "op", value: c.op), BoardField(key: "target", value: c.target ?? "")] + (c.clash.map { [BoardField(key: "clash", value: $0)] } ?? []),
                    media: c.previewURL.map { [MediaRef(ref: c.args?.dictionaryValue?["emote_id"]?.stringValue ?? "emote", kind: .emote, previewURL: $0, title: c.before)] } ?? [])
            }
        }
        return r.swarm.tasks.cells.filter { $0.status == .done || $0.status == .failed }.map { c in
            c.status == .failed
                ? BoardRow(agent: c.agent, n: 1, title: "agent \(c.agent) failed: \(c.error ?? "unknown")")
                : BoardRow(agent: c.agent, n: 1, title: "agent \(c.agent)", score: 0.9, fields: [BoardField(key: "step", value: c.step ?? "")])
        }
    }

    private static func outcome(of r: Record, cell c: SwarmCell) -> SwarmOutcome? {
        guard c.status == .done || c.status == .failed else { return nil }
        let items = max(1, r.swarm.batchSize)
        if c.status == .failed { return SwarmOutcome(status: .failed, items: items, turns: 6, ms: 41_000) }
        return SwarmOutcome(status: .done, items: items, answered: items, toolCalls: 12, toolErrors: 0, turns: 3, usd: 0.011, ms: 30_000 + c.agent * 1_000, score: 1)
    }

    // MARK: writes

    private func update<T>(_ id: String, now: Date, _ body: (inout Record) throws -> T) throws -> T {
        try state.withLock { s in
            guard let i = s.records.firstIndex(where: { $0.swarm.id == id }) else { throw SwarmError.notFound }
            Self.advance(&s.records[i], now: now)
            let out = try body(&s.records[i])
            Self.refresh(&s.records[i], now: now)
            return out
        }
    }

    func approve(_ id: String, hash: String, now: Date) throws -> Swarm {
        try update(id, now: now) { r in
            if r.swarm.status == .expired { throw SwarmError.expired }
            guard r.swarm.status == .awaitingApproval else { throw SwarmError.notAwaiting }
            guard r.swarm.specHash == hash else { throw SwarmError.hashMismatch }
            r.swarm.status = .running
            r.swarm.approvedAt = now
            r.swarm.expiresAt = nil
            r.swarm.error = nil
            r.runStart = now
            for i in r.swarm.tasks.cells.indices { r.swarm.tasks.cells[i].status = i < 3 ? .running : .queued }
            return r.swarm
        }
    }

    func decline(_ id: String, now: Date) throws -> Swarm {
        try update(id, now: now) { r in
            guard r.swarm.status == .awaitingApproval else { throw SwarmError.notAwaiting }
            r.swarm.status = .declined
            r.swarm.expiresAt = nil
            r.swarm.finishedAt = now
            return r.swarm
        }
    }

    func stop(_ id: String, now: Date) throws -> Swarm {
        try update(id, now: now) { r in
            switch r.swarm.status {
            case .awaitingApproval:
                r.swarm.status = .stopped
                r.swarm.expiresAt = nil
                r.swarm.finishedAt = now
            case .running:
                r.swarm.status = .stopping
                r.stopAt = now
            default:
                if r.swarm.apply.status == .applying {
                    r.applyStart = nil
                    r.swarm.apply.status = .ready
                }
            }
            return r.swarm
        }
    }

    func retry(_ id: String, now: Date) throws -> Swarm {
        try update(id, now: now) { r in
            guard [.done, .failed, .stopped].contains(r.swarm.status),
                r.swarm.tasks.cells.contains(where: { $0.status == .failed || $0.status == .skipped })
            else { throw SwarmError.notReady }
            for i in r.swarm.tasks.cells.indices where [.failed, .skipped].contains(r.swarm.tasks.cells[i].status) {
                r.swarm.tasks.cells[i].status = .queued
                r.swarm.tasks.cells[i].error = nil
                r.swarm.tasks.cells[i].step = nil
            }
            r.swarm.status = .awaitingApproval
            r.swarm.specHash += "r"
            r.swarm.expiresAt = now.addingTimeInterval(3600)
            r.swarm.error = nil
            r.swarm.finishedAt = nil
            return r.swarm
        }
    }

    func decide(_ id: String, _ decisions: [SwarmDecision], now: Date) throws -> SwarmDecided {
        try update(id, now: now) { r in
            guard !decisions.isEmpty, decisions.count <= 500 else { throw SwarmError.badRequest }
            guard r.swarm.mode == .propose, r.swarm.status == .done || r.swarm.status == .stopped, r.swarm.apply.status != .applying else {
                throw SwarmError.notReady
            }
            // an edit of a change with no editable field refuses the whole request, nothing written
            for d in decisions where d.after != nil || d.clearAfter {
                if let c = r.changes.first(where: { $0.n == d.n }), c.editArg == nil { throw SwarmError.badRequest }
            }
            for d in decisions {
                guard let i = r.changes.firstIndex(where: { $0.n == d.n }), r.changes[i].status != .done else { continue }
                if let keep = d.keep {
                    r.changes[i].keep = keep
                    if keep, r.changes[i].status == .failed { r.changes[i].status = .proposed; r.changes[i].error = nil }
                }
                if d.clearAfter || d.after != nil, let arg = r.changes[i].editArg {
                    var dict = r.changes[i].args?.dictionaryValue ?? [:]
                    dict[arg] = d.clearAfter ? nil : .string(d.after ?? "")
                    r.changes[i].args = .dictionary(dict)
                    r.changes[i].after = d.clearAfter ? nil : d.after
                }
            }
            PreviewSwarmData.refreshClashes(&r.changes)
            let named = Set(decisions.map(\.n))
            Self.refresh(&r, now: now)
            return SwarmDecided(swarm: r.swarm, changes: r.changes.filter { named.contains($0.n) })
        }
    }

    func apply(_ id: String, hash: String, skipClashes: Bool, now: Date) throws -> Swarm {
        try update(id, now: now) { r in
            guard r.swarm.mode == .propose, r.swarm.status == .done else { throw SwarmError.notReady }
            guard r.swarm.specHash == hash else { throw SwarmError.hashMismatch }
            guard [.ready, .applied, .failed].contains(r.swarm.apply.status), r.changes.contains(where: { $0.keep && $0.status != .done }) else {
                throw SwarmError.notReady
            }
            Self.beginApply(&r, skipClashes: skipClashes, now: now)
            return r.swarm
        }
    }

    func send(_ id: String, to: SwarmRecipient, text: String, now: Date) throws -> SwarmSent {
        try update(id, now: now) { r in
            guard r.swarm.status == .running || r.swarm.status == .stopping else { throw SwarmError.notRunning }
            if case .agent(let n) = to, !r.swarm.tasks.cells.indices.contains(n - 1) { throw SwarmError.badRequest }
            let next = (r.messages.map(\.id).max() ?? 0) + 1
            var woke = false
            if case .agent(let n) = to {
                for i in r.messages.indices where r.messages[i].agent == n && r.messages[i].isOpenAsk { r.messages[i].answered = true }
                let ci = n - 1
                if r.swarm.tasks.cells[ci].status == .waiting {
                    r.swarm.tasks.cells[ci].status = .running
                    r.swarm.tasks.cells[ci].step = "answer arrived"
                    woke = true
                }
            }
            var agent: Int?
            if case .agent(let n) = to { agent = n }
            r.messages.append(SwarmMessage(id: next, swarm: id, agent: agent, dir: .down, kind: agent == nil ? .tell : .reply, sender: .you, text: text, at: now))
            return SwarmSent(sent: 1, to: to, woke: woke)
        }
    }
}

// MARK: - the client

extension PreviewClient {
    public func swarms() async throws -> [Swarm] {
        swarmState.record("GET swarms")
        return swarmState.list(now: clock.now())
    }

    public func swarm(id: String) async throws -> Swarm {
        swarmState.record("GET swarm \(id)")
        return try swarmState.get(id, now: clock.now())
    }

    public func swarmAgent(id: String, agent: Int) async throws -> SwarmAgent {
        swarmState.record("GET agent \(id) \(agent)")
        return try swarmState.agent(id, agent, now: clock.now())
    }

    public func swarmChanges(id: String, offset: Int, limit: Int) async throws -> SwarmChangePage {
        swarmState.record("GET changes \(id) \(offset)")
        return try swarmState.changes(id, offset: offset, limit: limit, now: clock.now())
    }

    public func swarmMessages(id: String, agent: Int?) async throws -> [SwarmMessage] {
        swarmState.record("GET messages \(id)")
        return try swarmState.messages(id, agent: agent, now: clock.now())
    }

    public func approveSwarm(id: String, hash: String) async throws -> Swarm {
        swarmState.record("POST approve \(id)")
        return try swarmState.approve(id, hash: hash, now: clock.now())
    }

    public func declineSwarm(id: String) async throws -> Swarm {
        swarmState.record("POST decline \(id)")
        return try swarmState.decline(id, now: clock.now())
    }

    public func stopSwarm(id: String) async throws -> Swarm {
        swarmState.record("POST stop \(id)")
        return try swarmState.stop(id, now: clock.now())
    }

    public func retrySwarm(id: String) async throws -> Swarm {
        swarmState.record("POST retry \(id)")
        return try swarmState.retry(id, now: clock.now())
    }

    public func decideSwarm(id: String, changes: [SwarmDecision]) async throws -> SwarmDecided {
        swarmState.record("POST decide \(id)")
        return try swarmState.decide(id, changes, now: clock.now())
    }

    public func applySwarm(id: String, hash: String, skipClashes: Bool) async throws -> Swarm {
        swarmState.record("POST apply \(id)" + (skipClashes ? " skip" : ""))
        return try swarmState.apply(id, hash: hash, skipClashes: skipClashes, now: clock.now())
    }

    public func sendSwarm(id: String, to: SwarmRecipient, text: String) async throws -> SwarmSent {
        swarmState.record("POST send \(id)")
        return try swarmState.send(id, to: to, text: text, now: clock.now())
    }

    public func swarmBoard(
        id: String, query: String?, agent: Int?, status: String?, group: String?, sort: BoardSort, offset: Int, limit: Int
    ) async throws -> SwarmBoard {
        swarmState.record("GET board \(id) \(offset)")
        return try swarmState.board(id, query: query, agent: agent, status: status, group: group, sort: sort, offset: offset, limit: limit, now: clock.now())
    }
}

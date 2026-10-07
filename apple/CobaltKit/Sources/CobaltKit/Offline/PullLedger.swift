import Foundation

// The ledger of the Mac's pull (CONTRACT-OFFLINE.md 13.8): `Sync/pull.json`, one `CoordinatedFile` like the other ledgers.
//
//     { v: 1, enabledAt, watermark, lastCheck, problem, server, done: { "<server file id>": { at, state, why } },
//       own: { "<library file id>": <noted at> }, backlog: [{ cursor, floor }], calibrate, brake: { saves, files, upTo, choice } }
//
// `enabledAt` is the baseline ("saves from now on"): nothing created on or before it is ever fetched. `watermark` is the
// newest `created_at` a complete walk saw (the next walk stops a little below it). `done` is the pull's memory: a file
// that was queued, or that this Mac decided not to fetch, is never looked at again. `server` is the library the baseline
// belongs to: another server is another library and takes a new baseline. `own` and `backlog` are additive to 13.8: `own` is
// the library ids of uploads this Mac made (an image upload leaves no local record that could tell the pull whose it is);
// `backlog` is what a walk capped at 10 pages did not reach (so a long absence is caught up over several checks).
// `calibrate` (wave M review S2): the baseline was taken from the Mac's clock and has not yet been checked against the server's
// own dates; the first check that reaches the library right after raises it to the newest file the library holds, so a Mac
// clock that runs behind the server never fetches what the library already had. `brake` (S5): one check found more saves than
// it will fetch unasked; they wait for the owner's "download them" or "skip" (`choice`).

struct PullDone: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Handed to the download engine. Forever, whatever happens to the file after.
        case queued
        /// Not fetched: the download ended `gone`, this Mac already had it, or this Mac made it.
        case skipped
    }
    /// The file's `created_at` (what `prune` ages it by).
    var at: Date
    var state: State
    var why: String?
}

/// A stretch of the library a capped walk did not reach: from `cursor` (a library page cursor) down to `floor`.
struct PullSegment: Codable, Equatable, Sendable {
    var cursor: String
    var floor: Date
}

/// One check found more new saves than the pull fetches without asking (wave M review S5): the owner decides.
struct PullBrake: Codable, Equatable, Sendable {
    enum Choice: String, Codable, Sendable { case download, skip }
    /// posts with something to fetch
    var saves: Int
    /// files in them
    var files: Int
    /// the newest file the check held back: a "skip" covers up to here, a save made after it is looked at on its own
    var upTo: Date
    var choice: Choice?
}

struct PullFile: Codable, Equatable, Sendable {
    var v: Int = 1
    var enabledAt: Date?
    var watermark: Date?
    var lastCheck: Date?
    var problem: String?
    var server: String?
    var done: [String: PullDone] = [:]
    var own: [String: Date] = [:]
    var backlog: [PullSegment] = []
    var calibrate = false
    var brake: PullBrake?

    init() {}

    enum CodingKeys: String, CodingKey { case v, enabledAt, watermark, lastCheck, problem, server, done, own, backlog, calibrate, brake }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 1
        enabledAt = try? c.decodeIfPresent(Date.self, forKey: .enabledAt)
        watermark = try? c.decodeIfPresent(Date.self, forKey: .watermark)
        lastCheck = try? c.decodeIfPresent(Date.self, forKey: .lastCheck)
        problem = (try? c.decodeIfPresent(String.self, forKey: .problem)) ?? nil
        server = (try? c.decodeIfPresent(String.self, forKey: .server)) ?? nil
        done = ((try? c.decodeIfPresent([String: PullDone].self, forKey: .done)) ?? nil) ?? [:]
        own = ((try? c.decodeIfPresent([String: Date].self, forKey: .own)) ?? nil) ?? [:]
        backlog = ((try? c.decodeIfPresent([PullSegment].self, forKey: .backlog)) ?? nil) ?? []
        calibrate = ((try? c.decodeIfPresent(Bool.self, forKey: .calibrate)) ?? nil) ?? false
        brake = (try? c.decodeIfPresent(PullBrake.self, forKey: .brake)) ?? nil
    }
}

final class PullLedger: Sendable {
    /// `done` is the pull's memory of what it has decided, and it does not age out: an entry is the only thing that remembers a
    /// file the owner removed from this Mac (the record is gone, so nothing local does), and a walk can reach an old file again
    /// when its post gets a new one (wave M review S1). The walk also refuses any file older than its stop line, so this is
    /// belt and braces; the cap only stops a ledger that has run for years from growing without end (the oldest go first).
    static let maxDone = 5_000
    /// Uploads this Mac made are remembered this long (a library row of one is a candidate only while it is new).
    static let ownAge: TimeInterval = 8 * 24 * 60 * 60

    private let file: CoordinatedFile<PullFile>

    /// `directory` is `Sync/`.
    init(directory: URL) {
        file = CoordinatedFile(url: directory.appendingPathComponent("pull.json"), empty: PullFile())
    }

    var url: URL { file.url }

    func read() -> PullFile { file.read() }

    // MARK: baseline

    /// The baseline, taken now. Everything the library holds today is older and is never fetched. `server` names the
    /// library it belongs to.
    func rebaseline(now: Date, server: String?) {
        file.mutate { f in
            f.enabledAt = now
            f.watermark = nil
            f.lastCheck = nil
            f.problem = nil
            f.server = server
            f.done = [:]
            f.backlog = []
            f.brake = nil
            f.calibrate = true
            // what this Mac uploaded stays remembered: the rows are older than the new baseline anyway, but a clock that
            // is a little behind the server's must not bring them in
        }
    }

    /// "keep new saves offline" went off: the next time it is on is a new baseline (saves made meanwhile are not fetched).
    func disarm() {
        file.mutate { f in
            f.enabledAt = nil
            f.watermark = nil
            f.done = [:]
            f.backlog = []
            f.brake = nil
            f.calibrate = false
        }
    }

    /// The baseline is raised to `floor` (the newest file the library holds, when the server's clock is ahead of the Mac's);
    /// never lowered. The calibration is spent either way.
    @discardableResult
    func calibrate(floor: Date?) -> Date? {
        var result: Date?
        file.mutate { f in
            if let floor, let enabled = f.enabledAt, floor > enabled { f.enabledAt = floor }
            f.calibrate = false
            result = f.enabledAt
        }
        return result
    }

    /// A check held `saves` back (S5). Nothing else changes: the watermark stays, so the same saves are found again by the walk
    /// that carries out the owner's answer.
    func setBrake(_ brake: PullBrake?) {
        file.mutate { $0.brake = brake }
    }

    func chooseBrake(_ choice: PullBrake.Choice) {
        file.mutate { f in if f.brake != nil { f.brake?.choice = choice } }
    }

    // MARK: one check's writes

    func finishCheck(now: Date, watermark: Date?, backlog: [PullSegment], problem: String?, markSeen: Bool) {
        file.mutate { f in
            if markSeen { f.lastCheck = now }
            f.problem = problem
            f.backlog = backlog
            if let watermark { f.watermark = watermark }
            if f.done.count > Self.maxDone {
                let keep = f.done.sorted { $0.value.at > $1.value.at }.prefix(Self.maxDone)
                f.done = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            f.own = f.own.filter { now.timeIntervalSince($0.value) <= Self.ownAge }
        }
    }

    func setProblem(_ problem: String?) {
        file.mutate { $0.problem = problem }
    }

    /// Files handed to the engine, or that this Mac decided not to fetch (`state`).
    func record(_ ids: [String], at: Date, state: PullDone.State, why: String? = nil) {
        guard !ids.isEmpty else { return }
        file.mutate { f in
            for id in ids {
                // a queued entry stays queued (a later skip must not erase that it was handed over)
                if let known = f.done[id], known.state == .queued, state == .skipped { continue }
                f.done[id] = PullDone(at: at, state: state, why: why)
            }
        }
    }

    /// A download that ended `gone`: skipped, whatever it was before.
    func markGone(_ ids: [String]) {
        file.mutate { f in
            for id in ids {
                guard let known = f.done[id] else { continue }
                f.done[id] = PullDone(at: known.at, state: .skipped, why: "gone")
            }
        }
    }

    func noteOwn(_ ids: [String], now: Date) {
        guard !ids.isEmpty else { return }
        file.mutate { f in
            for id in ids where f.own[id] == nil { f.own[id] = now }
        }
    }
}

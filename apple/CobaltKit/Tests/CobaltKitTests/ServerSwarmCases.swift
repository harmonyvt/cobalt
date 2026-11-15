import Foundation
@testable import CobaltKit

// The swarm cases of the server's Live Activity fixture (deploy/cloudflare/api/test/fixtures/job-live-states.json, the
// `swarm_*` entries), with the inputs they are built from: copied from deploy/cloudflare/api/test/job-live-cases.ts. The
// fixture is the one file both sides pin; these inputs are what the server's `jobOfSwarm(input, now)` was called with.

private let serverT = 1_790_000_000.0
private let serverMS = serverT * 1000
private let noChanges = SwarmLiveInput.Changes()

/// The `swarm` constant of job-live-cases.ts (a running propose swarm), with the case's own overrides applied by `make`.
private func serverSwarm(_ edit: (inout SwarmLiveInput) -> Void = { _ in }) -> SwarmLiveInput {
    var s = SwarmLiveInput(
        id: "Sw4rmIdSw4rmId01", name: "clean emote names", mode: .propose, status: .running, applyStatus: .none,
        specHash: "a1b2c3d4e5f60718", planner: "claude code", estLow: 0.12, estHigh: 0.4, spentUSD: 0.21, capUSD: 2,
        createdAt: serverMS, approvedAt: serverMS + 60_000, expiresAt: serverMS + 3_600_000, cells: "ddrwq",
        changes: .init(total: 7))
    edit(&s)
    return s
}

private func ended(_ s: inout SwarmLiveInput) {
    s.finishedAt = serverMS + 600_000
    s.cells = "ddddf"
}

struct ServerSwarmCase {
    var name: String
    var input: SwarmLiveInput
    /// The `now` (ms) the server built the case at.
    var nowMs: Double
}

/// In the fixture's order (job-live-cases.ts).
let serverSwarmCases: [ServerSwarmCase] = [
    .init(name: "swarm_awaiting", input: serverSwarm {
        $0.status = .awaitingApproval; $0.approvedAt = nil; $0.spentUSD = 0; $0.cells = "qqqqq"; $0.changes = noChanges
    }, nowMs: serverMS + 20 * 60_000),
    .init(name: "swarm_running", input: serverSwarm(), nowMs: serverMS + 120_000),
    .init(name: "swarm_running_read", input: serverSwarm { $0.mode = .read; $0.cells = "ddrrq"; $0.spentUSD = 1.4 }, nowMs: serverMS + 120_000),
    .init(name: "swarm_stopping", input: serverSwarm { $0.status = .stopping; $0.cells = "ddrss" }, nowMs: serverMS + 120_000),
    .init(name: "swarm_ready", input: serverSwarm {
        ended(&$0); $0.status = .done; $0.applyStatus = .ready
        $0.changes = .init(total: 7, kept: 6, open: 6, clashes: 2, done: 0, failed: 0)
    }, nowMs: serverMS + 700_000),
    .init(name: "swarm_applying", input: serverSwarm {
        ended(&$0); $0.status = .done; $0.applyStatus = .applying
        $0.changes = .init(total: 7, kept: 6, open: 3, clashes: 0, done: 3, failed: 0)
    }, nowMs: serverMS + 700_000),
    .init(name: "swarm_applied", input: serverSwarm {
        ended(&$0); $0.status = .done; $0.applyStatus = .applied
        $0.changes = .init(total: 7, kept: 6, open: 0, clashes: 0, done: 6, failed: 0)
    }, nowMs: serverMS + 700_000),
    .init(name: "swarm_done_read", input: serverSwarm {
        ended(&$0); $0.mode = .read; $0.status = .done; $0.reduce = "12 of 40 emotes  look\nseasonal; the rest are fine"
    }, nowMs: serverMS + 700_000),
    .init(name: "swarm_capped", input: serverSwarm {
        ended(&$0); $0.mode = .read; $0.status = .failed; $0.error = "error.swarm.over_cap"; $0.spentUSD = 2.01
    }, nowMs: serverMS + 700_000),
    .init(name: "swarm_declined", input: serverSwarm {
        $0.status = .declined; $0.approvedAt = nil; $0.finishedAt = serverMS + 30_000; $0.cells = "sssss"
    }, nowMs: serverMS + 30_000),
    .init(name: "swarm_expired", input: serverSwarm {
        $0.status = .awaitingApproval; $0.approvedAt = nil; $0.cells = "qqqqq"
    }, nowMs: serverMS + 3_600_000),
]

let serverSwarmCaseNames = serverSwarmCases.map(\.name)

func serverSwarmCase(_ name: String) -> ServerSwarmCase {
    guard let c = serverSwarmCases.first(where: { $0.name == name }) else { fatalError("no server swarm case \(name)") }
    return c
}

/// The `Swarm` that `GET /swarms/<id>` answers for a case's input (59.5 + 61.3): counts from the letters, `changes` only in
/// propose mode, `apply.total` the kept changes, the clashes as the app counts them from the change list.
func swarmAnswer(for i: SwarmLiveInput) -> Swarm {
    let letters = Array(i.cells)
    let cells = letters.enumerated().map { SwarmCell(idx: $0.offset, status: SwarmCell.Status(letter: $0.element) ?? .queued) }
    func n(_ s: SwarmCell.Status) -> Int { cells.filter { $0.status == s }.count }
    func date(_ ms: Double?) -> Date? { ms.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var s = Swarm(
        id: i.id, name: i.name, mode: i.mode, status: i.status, specHash: i.specHash,
        tasks: Swarm.Tasks(
            total: cells.count, queued: n(.queued), running: n(.running), done: n(.done), failed: n(.failed), waiting: n(.waiting),
            cells: cells),
        estimateUSD: .init(low: i.estLow, high: i.estHigh), capUSD: i.capUSD, spentUSD: i.spentUSD,
        createdAt: date(i.createdAt)!, approvedAt: date(i.approvedAt), finishedAt: date(i.finishedAt), expiresAt: date(i.expiresAt),
        reduce: i.reduce, error: i.error, planner: i.planner)
    if i.mode == .propose {
        s.changes = .init(total: i.changes.total, kept: i.changes.kept, done: i.changes.done, failed: i.changes.failed)
    }
    s.apply = .init(status: i.applyStatus, done: i.changes.done, failed: i.changes.failed, total: i.changes.kept)
    s.clashCount = i.changes.clashes
    return s
}

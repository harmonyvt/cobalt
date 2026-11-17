import Foundation

// What the swarm Live Activity draws for its agents (apple/CONTRACT-SWARMS.md 4): a row of small cells while there are few
// agents, one proportional bar when there are many. The widget only paints this; the decision is here so the macOS test run
// covers it.

public struct SwarmLiveStrip: Hashable, Sendable {
    /// One run of the bar: how many agents are in this status.
    public struct Segment: Hashable, Sendable {
        public var status: SwarmCell.Status
        public var count: Int
    }

    public enum Layout: Hashable, Sendable {
        /// One rounded cell per agent, in agent order.
        case cells([SwarmCell.Status])
        /// One bar split by share, in the order done, running, waiting, failed, skipped, queued; empty runs left out.
        case bar([Segment])
    }

    /// Up to this many agents are drawn as cells.
    public static let maxCells = 40

    public var layout: Layout
    public var total: Int

    public init(cells: [SwarmCell.Status]) {
        total = cells.count
        if cells.count <= Self.maxCells {
            layout = .cells(cells)
        } else {
            let order: [SwarmCell.Status] = [.done, .running, .waiting, .failed, .skipped, .queued]
            layout = .bar(order.compactMap { status in
                let n = cells.filter { $0 == status }.count
                return n > 0 ? Segment(status: status, count: n) : nil
            })
        }
    }
}

extension JobLiveState {
    /// The agents' strip; nil when the state carries no `cells` (any other kind of job, or a swarm with no agents yet).
    public var swarmStrip: SwarmLiveStrip? {
        guard let cells, !cells.isEmpty else { return nil }
        return SwarmLiveStrip(cells: swarmCells)
    }

    /// The state asks its owner for something: an approve or an apply button, while it waits.
    public var swarmWaitsForYou: Bool {
        phase == .waiting && swarmActions.contains { $0 == .approve || $0 == .apply }
    }
}

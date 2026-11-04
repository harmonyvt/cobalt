import Foundation

/// What the menu bar glyph draws, from the jobs that are actually running. `ring` is nil when nothing
/// is live (no ring). `failed` is the red dot: a job has failed, whether or not others are still going.
public struct MenuBarIconState: Equatable, Sendable {
    public var ring: Double?
    public var failed: Bool

    public init(ring: Double?, failed: Bool) {
        self.ring = ring
        self.failed = failed
    }

    public static let idle = MenuBarIconState(ring: nil, failed: false)
}

public enum MenuBarIcon {
    /// One live job's share of the ring. Checking and waiting sit near the start (0.05). A download
    /// fills the first 80%. Saving, reading and rendering fill the last 20%. The same split the
    /// menu bar mock uses, so the ring moves the way the rows do.
    public enum Phase: Equatable, Sendable {
        case checking
        case waiting
        case downloading(Double)
        case saving(Double)
    }

    public static func contribution(_ phase: Phase) -> Double {
        switch phase {
        case .checking, .waiting: return 0.05
        case .downloading(let fraction): return 0.8 * clamp(fraction)
        case .saving(let fraction): return 0.8 + 0.2 * clamp(fraction)
        }
    }

    /// The mean of the live jobs. No live jobs: no ring. `failed` is independent, so a failure keeps
    /// the dot while other jobs are still running.
    public static func state(phases: [Phase], failed: Bool) -> MenuBarIconState {
        guard !phases.isEmpty else { return MenuBarIconState(ring: nil, failed: failed) }
        let total = phases.reduce(0) { $0 + contribution($1) }
        return MenuBarIconState(ring: total / Double(phases.count), failed: failed)
    }

    private static func clamp(_ fraction: Double) -> Double { min(1, max(0, fraction)) }
}

import Foundation

/// Spaces out the polls of a session. The server long-polls (`wait=1`), but it can also answer
/// at once: the Worker's fallback while the container or D1 has a bad moment says "saving"
/// immediately, and a loop that re-asks with no gap would hammer it many times a second.
///
/// Polls start at least 1 s apart; while the same reply keeps coming back at once the gap doubles
/// (1, 2, 4, 8, then 10 s at most), and any change in the reply puts it back to 1 s. A reply that
/// was held for most of the long-poll wait is the server working as designed, not a hammering
/// risk: it does not count as "the same reply again", so a healthy slow save is never slowed down.
struct PollPacer {
    static let floor: Double = 1
    static let ceiling: Double = 10

    /// What counts as "the reply changed".
    private struct Reply: Equatable {
        var status: SessionStatus
        var step: SaveStep?
        var stepBytes: Int64?
        var stepTotal: Int64?
        var waking: Bool?
        var title: String?
        var duration: Double?
    }

    /// A reply faster than this (seconds) did not come from a long poll that actually waited.
    static let heldReply: Double = 0.9

    private var lastStart: Date?
    private var lastReply: Reply?
    private var unchanged = 0

    /// The gap the next poll must keep from the start of the last one.
    var interval: Double { min(PollPacer.ceiling, PollPacer.floor * pow(2, Double(unchanged))) }

    /// Waits out what is left of the interval, then marks this poll as started.
    mutating func beforePoll(clock: any PipelineClock) async throws {
        if let lastStart {
            let remaining = interval - clock.now().timeIntervalSince(lastStart)
            if remaining > 0 { try await clock.sleep(seconds: remaining) }
        }
        lastStart = clock.now()
    }

    mutating func observe(_ s: StudioSession, clock: any PipelineClock) {
        let reply = Reply(
            status: s.status, step: s.step, stepBytes: s.stepBytes, stepTotal: s.stepTotal, waking: s.waking,
            title: s.title, duration: s.duration)
        let took = lastStart.map { clock.now().timeIntervalSince($0) } ?? 0
        unchanged = (reply == lastReply && took < PollPacer.heldReply) ? unchanged + 1 : 0
        lastReply = reply
    }
}

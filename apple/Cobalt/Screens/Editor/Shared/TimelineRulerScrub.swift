import CobaltKit
import SwiftUI

/// The Mac and iPad ruler's scrub (a click or drag on the ruler seeks to that time): the seeks go through `TimelineSeeker`
/// (one in flight, the newest wins, an exact seek when the mouse is released) and a light tick plays when the playhead passes
/// a clip edge. The playhead itself is the session's, so nothing here needs to be observed except `tick`.
@MainActor @Observable
final class TimelineRulerScrub {
    /// Counts up when the playhead passes a clip edge; a haptic watches it.
    private(set) var tick = 0
    private(set) var active = false

    @ObservationIgnored private let session: EditSession
    @ObservationIgnored private let seeker: TimelineSeeker
    @ObservationIgnored private var edges: [Double] = []
    @ObservationIgnored private var last = 0.0
    @ObservationIgnored private var lastTick = ContinuousClock.now

    init(session: EditSession) {
        self.session = session
        self.seeker = TimelineSeeker(session: session)
    }

    /// The pointer is on the ruler at `seconds`.
    func move(to seconds: Double) {
        if !active {
            active = true
            if session.isPlaying { session.pause() }
            edges = session.timelineEdgeSeconds
            last = session.playheadSeconds
            seeker.begin()
        }
        let frame = session.timing.frame(at: seconds)
        let target = session.timing.time(ofFrame: frame)
        if TimelineEdges.crossed(from: last, to: target, edges: edges) {
            let now = ContinuousClock.now
            if now - lastTick > .milliseconds(30) {
                lastTick = now
                tick += 1
            }
        }
        last = target
        seeker.move(toFrame: frame)
    }

    /// The pointer lifted: the picture ends on the exact frame.
    func end(at seconds: Double) {
        guard active else { return }
        active = false
        seeker.release(toFrame: session.timing.frame(at: seconds))
    }
}

import CobaltKit
import SwiftUI

// How the timeline feels under a finger (apple/CONTRACT-EDITOR.md 15.5). Two pieces:
//
//  - `TimelineSeeker` sits between the timeline and the player: one seek in flight, the newest target waits and wins, and a
//    release always ends with an exact seek (`SeekCoalescer`, in the kit).
//  - `TimelineScrubber` (iPhone and iPad) keeps the time under the fixed playhead as a continuous number, not a frame, so the
//    blocks glide under the finger even when a frame is 16 pt wide. A drag moves it, a release with speed flings it (decay
//    0.998 per ms, stopping at 0 and the end), a touch stops it, and a light tick plays when it passes a clip edge.

/// The one place the timeline moves the picture while a finger is down.
@MainActor
final class TimelineSeeker {
    private let session: EditSession
    private var coalescer = SeekCoalescer()
    private var landing: Task<Void, Never>?

    init(session: EditSession) {
        self.session = session
    }

    /// A scrub (or a trim drag) starts.
    func begin() {
        coalescer.begin()
    }

    /// The finger is on `frame`.
    func move(toFrame frame: Int) {
        if let seek = coalescer.request(frame: frame) { send(seek) }
    }

    /// The finger lifted on `frame`: the picture ends on exactly that frame.
    func release(toFrame frame: Int) {
        if let seek = coalescer.release(frame: frame) { send(seek) }
    }

    func cancel() {
        landing?.cancel()
        landing = nil
        coalescer.reset()
    }

    /// Hands a seek to the session, which sets the playhead and has the player show the frame. `seek.exact` is false while the
    /// finger is down; the session seeks exactly either way until it takes a tolerance (see the report), so the pacing here
    /// is what keeps the player from being flooded: the next one goes out a display frame after the last.
    private func send(_ seek: ScrubSeek) {
        session.seek(frame: seek.frame, exact: seek.exact)
        landing?.cancel()
        let wait = seek.exact ? 1 : 16
        landing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled, let self else { return }
            if let next = coalescer.landed() { send(next) }
        }
    }
}

extension EditSession {
    /// Every clip's start and end on the output timeline, in seconds, for the tick on a clip edge.
    var timelineEdgeSeconds: [Double] {
        var spans: [(start: Double, end: Double)] = []
        if timeline.isV2 {
            for row in timing.laneClips {
                spans.append((timing.time(ofFrame: row.start), timing.time(ofFrame: row.start + row.frames)))
            }
        } else {
            for span in mainSpans + overlaySpans { spans.append((span.start, span.end)) }
        }
        return TimelineEdges.edges(of: spans)
    }
}

@MainActor @Observable
final class TimelineScrubber {
    /// The time under the playhead, in seconds of output. Continuous: the blocks are placed from this, not from the frame.
    var seconds: Double = 0
    /// Counts up when a clip edge passes the playhead or a trimmed edge snaps; a haptic watches it.
    private(set) var tick = 0
    /// Where a trimmed edge snapped to (a guide line is drawn there while the finger is down), nil when it did not.
    private(set) var snapGuide: Double?
    private(set) var dragging = false
    private(set) var flinging = false
    private(set) var trimming = false
    /// The playhead line fades while an edge is trimmed (the picture shows that edge, the timeline stays still).
    var autoscrolling: Bool { autoscrollSpeed != 0 }

    @ObservationIgnored private let session: EditSession
    @ObservationIgnored private let seeker: TimelineSeeker
    @ObservationIgnored private var base = 0.0
    @ObservationIgnored private var edges: [Double] = []
    @ObservationIgnored private var flingTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var autoscrollTask: Task<Void, Never>?
    @ObservationIgnored private var autoscrollSpeed = 0.0
    @ObservationIgnored private var lastTick = ContinuousClock.now

    init(session: EditSession) {
        self.session = session
        self.seeker = TimelineSeeker(session: session)
        self.seconds = session.playheadSeconds
    }

    /// A finger, a fling, a trim or an edge-scroll is moving the timeline; playback and seeks from elsewhere do not move it then.
    var interacting: Bool { dragging || flinging || trimming || autoscrolling }

    private var duration: Double { max(0, session.timing.seconds) }

    // MARK: following the session

    /// The session's playhead moved (playback, a transport button, the picture): follow it unless a finger is moving things.
    func followSession() {
        guard !interacting else { return }
        let target = session.playheadSeconds
        let frame = 1 / Double(max(1, session.timing.fps))
        if abs(target - seconds) > frame * 0.5 + 1e-6 { seconds = target }
    }

    /// While playing, the player's own clock moves the timeline every display frame (the session's playhead only steps 30 times
    /// a second).
    func playbackChanged() {
        playbackTask?.cancel()
        playbackTask = nil
        guard session.isPlaying else {
            followSession()
            return
        }
        playbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, session.isPlaying else { return }
                if !interacting {
                    let now = session.player.currentTime().seconds
                    if now.isFinite { seconds = min(max(0, now), duration) }
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop() {
        flingTask?.cancel()
        playbackTask?.cancel()
        autoscrollTask?.cancel()
        seeker.cancel()
    }

    // MARK: a finger on the timeline

    /// A touch landed: a fling in progress stops where it is.
    func touchDown() {
        guard flinging else { return }
        flingTask?.cancel()
        flingTask = nil
        flinging = false
        seeker.release(toFrame: session.timing.frame(at: seconds))
    }

    /// A drag begins.
    func beginDrag() {
        flingTask?.cancel()
        flinging = false
        if session.isPlaying { session.pause() }
        base = seconds
        edges = session.timelineEdgeSeconds
        dragging = true
        seeker.begin()
    }

    /// The finger is `translation` points from where it started (positive = right, which moves earlier).
    func drag(translation: CGFloat, pointsPerSecond: CGFloat) {
        guard dragging else { return }
        apply(base - Double(translation / max(1, pointsPerSecond)))
    }

    /// The finger lifted at `velocity` points per second (positive = right). Fast enough, and it keeps going.
    func endDrag(velocity: CGFloat, pointsPerSecond: CGFloat, fling allowed: Bool) {
        guard dragging else { return }
        dragging = false
        let speed = Double(-velocity / max(1, pointsPerSecond))
        guard allowed, abs(velocity) > 120 else {
            settle()
            return
        }
        let fling = TimelineFling(position: seconds, velocity: speed, bounds: 0...duration)
        guard fling.duration > 0.03 else {
            settle()
            return
        }
        flinging = true
        flingTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = clock.now - start
                let t = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                apply(fling.position(at: t))
                if fling.isFinished(at: t) { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard !Task.isCancelled, let self else { return }
            flinging = false
            settle()
        }
    }

    /// The timeline stopped moving: the picture goes to exactly the frame under the playhead.
    private func settle() {
        seeker.release(toFrame: session.timing.frame(at: seconds))
    }

    /// Moves the playhead to `target` (clamped to the edit): the picture follows (coalesced) and an edge passed ticks.
    private func apply(_ target: Double) {
        let next = min(max(0, target.isFinite ? target : 0), duration)
        let previous = seconds
        seconds = next
        if TimelineEdges.crossed(from: previous, to: next, edges: edges) { ring() }
        seeker.move(toFrame: session.timing.frame(at: next))
    }

    private func ring() {
        let now = ContinuousClock.now
        guard now - lastTick > .milliseconds(30) else { return }
        lastTick = now
        tick += 1
    }

    // MARK: a clip dragged to the edge of the timeline

    /// While a lifted clip sits near the left or right edge the timeline scrolls: `speed` is seconds of output per second
    /// (negative = earlier), 0 stops it. It keeps going with a still finger.
    func autoscroll(speed: Double) {
        guard speed != autoscrollSpeed else { return }
        let starting = autoscrollSpeed == 0
        autoscrollSpeed = speed
        if speed == 0 {
            autoscrollTask?.cancel()
            autoscrollTask = nil
            seeker.release(toFrame: session.timing.frame(at: seconds))
            return
        }
        guard starting else { return }
        if session.isPlaying { session.pause() }
        edges = session.timelineEdgeSeconds
        seeker.begin()
        autoscrollTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                guard let self else { return }
                let now = clock.now
                let elapsed = now - last
                last = now
                let dt = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                apply(seconds + autoscrollSpeed * dt)
            }
        }
    }

    // MARK: an edge being trimmed

    /// A trim handle is picked up: the timeline stays where it is under the finger; the picture shows the edge.
    func beginTrim() {
        flingTask?.cancel()
        flinging = false
        if session.isPlaying { session.pause() }
        trimming = true
        seeker.begin()
    }

    /// The picture shows the frame at `frame` (coalesced). `snap` is where the edge snapped to, nil when it is free.
    func trimMoved(toFrame frame: Int, snap: Double?) {
        guard trimming else { return }
        seeker.move(toFrame: frame)
        if snap != snapGuide {
            if snap != nil { ring() }
            snapGuide = snap
        }
    }

    /// The handle is let go: the exact frame, and the timeline eases back to put the playhead on it.
    func endTrim(settleAt frame: Int) {
        guard trimming else { return }
        seeker.release(toFrame: frame)
        trimming = false
        snapGuide = nil
        let target = session.timing.time(ofFrame: frame)
        withAnimation(.easeOut(duration: 0.22)) { seconds = target }
    }
}

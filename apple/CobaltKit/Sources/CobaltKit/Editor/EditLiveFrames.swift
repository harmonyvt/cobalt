import Foundation
import Synchronization

// The picture follows a finger (apple/CONTRACT-EDITOR.md 15.3). A move, resize or turn of a clip on the picture is a run of
// `setClipFrame` edits, and the player item is rebuilt only when the run ends (`endGesture`): swapping the item on every tick
// would flicker and costs a whole composition build. In between, the frames (and opacity) the session has now and the playing
// item was not built with sit here; the compositor reads them for every output frame, and the session asks a paused player to
// draw the current frame again (one seek in flight, the latest wins). Playing, the next frame picks them up by itself.
//
// One store per session, handed to every build, so an item that is still playing while a newer one loads reads the same
// values. The session replaces the whole map after each change: an entry is a clip whose `frame` or `opacity` differs from
// what the playing item was built with.

/// What the compositor draws for some clips instead of what its plan was built with. Read on the compositor's queue, written
/// on the main actor.
public final class EditLiveFrames: Sendable {
    /// A clip's place and opacity as the session has them now. `frame` nil is "no frame" (fit or fill across the canvas), so
    /// a reset shows straight away too.
    struct Clip: Sendable, Equatable {
        var frame: EditFrame?
        var opacity: Double
    }

    private let state = Mutex<[String: Clip]>([:])

    public init() {}

    /// Every override, as one copy: the compositor takes it once per output frame.
    func snapshot() -> [String: Clip] {
        state.withLock { $0 }
    }

    /// Replaces every override. True when that changed anything (the session redraws only then).
    @discardableResult
    func replace(_ next: [String: Clip]) -> Bool {
        state.withLock { current in
            guard current != next else { return false }
            current = next
            return true
        }
    }

    /// The clip as the picture should draw it now.
    static func applied(_ overrides: [String: Clip], to clip: EditLaneClip) -> EditLaneClip {
        guard let live = overrides[clip.id] else { return clip }
        var out = clip
        out.frame = live.frame
        out.opacity = live.opacity
        return out
    }

    /// The clips whose `frame` or `opacity` in `current` differ from `playing` (the rounded timeline the playing item was built
    /// from), with the values `current` has, rounded the way a build would round them. Clips added or removed since are left
    /// out: those need the rebuild. Both must be version 2; a version 1 timeline gives none.
    static func overrides(playing: EditTimeline, current: EditTimeline) -> [String: Clip] {
        guard playing.version >= 2, current.version >= 2 else { return [:] }
        let now = EditJSON.rounded(current)
        var before: [String: EditLaneClip] = [:]
        for clip in playing.clips { before[clip.id] = clip }
        var out: [String: Clip] = [:]
        for clip in now.clips {
            guard let old = before[clip.id] else { continue }
            if old.frame != clip.frame || old.opacity != clip.opacity {
                out[clip.id] = Clip(frame: clip.frame, opacity: clip.opacity)
            }
        }
        return out
    }
}

/// The player's seeks, one in flight, the latest wins (CONTRACT-EDITOR 15.5): a scrub's newer targets wait and only the
/// last is sent when the one in flight lands; a redraw of the picture (`redraw`) is a seek to the playhead and rides the same
/// queue, so it never cancels a scrub and a burst of frame changes is one seek per frame the player can draw. Pure, so the
/// rule is tested without a player.
struct EditSeekChase: Equatable, Sendable {
    struct Target: Equatable, Sendable {
        var frame: Int
        /// False while a finger scrubs: any frame near the target will do.
        var exact: Bool
        /// The picture must be composed again even if the player already shows this frame. A paused AVPlayer does not compose
        /// again for a seek to the time it is at, so the session nudges such a seek by a thousandth of a frame.
        var redraw = false
    }

    private(set) var inFlight = false
    private(set) var pending: Target?

    /// A seek is wanted. Non-nil: send that now. Nil: one is on its way, and this one replaces whatever waits behind it.
    mutating func request(_ target: Target) -> Target? {
        if inFlight {
            pending = target
            return nil
        }
        inFlight = true
        return target
    }

    /// The picture must be drawn again at `frame` (the playhead). A seek already waiting draws it too, so it is kept (and
    /// marked as a redraw); else an exact seek to `frame` goes now or after the one in flight.
    mutating func redraw(at frame: Int) -> Target? {
        if inFlight {
            if pending == nil { pending = Target(frame: frame, exact: true) }
            pending?.redraw = true
            return nil
        }
        inFlight = true
        return Target(frame: frame, exact: true, redraw: true)
    }

    /// The seek in flight landed. Non-nil: send the waiting one now (it is in flight from here).
    mutating func landed() -> Target? {
        guard inFlight else { return nil }
        if let next = pending {
            pending = nil
            return next
        }
        inFlight = false
        return nil
    }

    /// A seek outside the queue (a rebuild's seek to the playhead) supersedes whatever was waiting.
    mutating func dropPending() {
        pending = nil
    }
}

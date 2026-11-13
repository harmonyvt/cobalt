import Foundation

// The numbers the glow shader branches on. They match the paper mockup:
// 0 up to date, 1 syncing, 2 offline, 3 refused, 4 full re-pull, 5 nudge, 6 off.
public enum SyncGlowState: Int, Sendable, Equatable, CaseIterable {
    case upToDate = 0
    case syncing = 1
    case offlinePending = 2
    case refused = 3
    case repull = 4
    case nudge = 5
    case off = 6
    /// New posts came in with a pull: two lights run in from the ends and meet in the middle.
    case arrived = 7

    public var title: String {
        switch self {
        case .upToDate: return "Up to date"
        case .syncing: return "Syncing"
        case .offlinePending: return "Offline"
        case .refused: return "Refused"
        case .repull: return "Full re-pull"
        case .nudge: return "Nudge"
        case .off: return "Off"
        case .arrived: return "New posts"
        }
    }
}

/// The latest thing the engine told the glow. The shader does not read this; screens and tests do.
public enum SyncGlowEvent: String, Sendable, Equatable {
    case none
    case passBegan
    case caughtUp
    case wentOffline
    case cameOnline
    case refused
    case repull
    case nudge
    case arrived
    case fellBack

    public static func debugMirror(of state: SyncGlowState) -> SyncGlowEvent {
        switch state {
        case .upToDate: return .caughtUp
        case .syncing: return .passBegan
        case .offlinePending: return .wentOffline
        case .refused: return .refused
        case .repull: return .repull
        case .nudge: return .nudge
        case .off: return .fellBack
        case .arrived: return .arrived
        }
    }
}

/// How long a one-shot moment lasts, and where a debug screenshot should sit inside it.
public enum SyncGlowTiming {
    public static let transition: TimeInterval = 0.85
    /// One red flash of the glow and the line, then back.
    public static let refused: TimeInterval = 1.15
    /// One gentle pulse of light travels along the edge.
    public static let nudge: TimeInterval = 1.8
    /// The line is wiped, then drawn back in from the left. Held longer while the restart pull is still running.
    public static let repull: TimeInterval = 2.4
    /// Two lights run in from the ends, meet in the middle and flare once.
    public static let arrived: TimeInterval = 1.6
    /// Brighter dashes shown for an offline outbox. The count uniform never goes above this.
    public static let visiblePendingCap = 8
    /// A frozen clock for Reduce Motion: the syncing light's breath sits mid-phase, not at its dimmest.
    public static let stillTime: Float = 1.7

    public static func duration(of event: SyncGlowEvent) -> TimeInterval? {
        switch event {
        case .refused: return refused
        case .nudge: return nudge
        case .repull: return repull
        case .arrived: return arrived
        default: return nil
        }
    }

    public static func screenshotAge(_ state: SyncGlowState) -> TimeInterval {
        switch state {
        case .refused: return 0.32
        case .repull: return 1.35
        case .nudge: return 0.7
        case .offlinePending: return 0.40
        case .syncing: return 4.0
        case .arrived: return 0.6
        case .upToDate, .off: return 1.7
        }
    }
}

/// Everything `SyncGlowResolve` needs. Built by `SyncGlowStatus`; tests build it directly.
public struct SyncGlowFacts: Sendable, Equatable {
    public var engineEnabled: Bool
    public var routeActive: Bool
    public var reachable: Bool
    public var passRunning: Bool
    public var pendingCount: Int
    public var transient: SyncGlowEvent
    public var transientAge: TimeInterval

    public init(
        engineEnabled: Bool = true,
        routeActive: Bool = true,
        reachable: Bool = true,
        passRunning: Bool = false,
        pendingCount: Int = 0,
        transient: SyncGlowEvent = .none,
        transientAge: TimeInterval = 10
    ) {
        self.engineEnabled = engineEnabled
        self.routeActive = routeActive
        self.reachable = reachable
        self.passRunning = passRunning
        self.pendingCount = pendingCount
        self.transient = transient
        self.transientAge = transientAge
    }
}

public enum SyncGlowResolve {
    /// Steady state, with a one-shot event laid on top. `tick` clears that event when its moment
    /// is over; until then it wins, so a refusal, a 410, or a nudge is still visible after a slow
    /// pass. Offline wins over "syncing": a pass that cannot reach the server should not light the edge.
    public static func state(_ facts: SyncGlowFacts) -> SyncGlowState {
        if !facts.engineEnabled || !facts.routeActive { return .off }
        switch facts.transient {
        case .refused: return .refused
        case .nudge: return .nudge
        case .repull: return .repull
        case .arrived: return .arrived
        default: break
        }
        if !facts.reachable { return .offlinePending }
        if facts.passRunning || facts.pendingCount > 0 { return .syncing }
        return .upToDate
    }
}

/// The uniform block. Every field is a `Float` so the memory matches `GlowUniforms` in
/// `SyncGlow.metal` with no padding. `Index` is the order both sides share. Twenty floats,
/// 80 bytes: `setFragmentBytes` wants a multiple of 16.
public struct SyncGlowUniforms: Sendable, Equatable {
    public var time: Float
    public var state: Float
    public var previous: Float
    public var transition: Float
    public var pending: Float
    public var intensity: Float
    public var reducedMotion: Float
    public var headroom: Float
    public var lowPower: Float
    public var eventAge: Float
    public var width: Float
    public var height: Float
    /// Drawable pixels per point, so the shader can size the line and the travelling light in points.
    public var pointScale: Float
    /// 1 in dark mode, where the glow is light added to the page. Light mode tints with ink instead.
    public var dark: Float
    /// The owner's own saves and uploads: -1 none, 0...1 how far (a lit run along the line with a
    /// bright head), 2 working with no known length (a short light loops along the line).
    public var activity: Float
    /// A finger or the pointer, in points from the band's left edge; -1 when there is none.
    public var touchX: Float
    /// How strongly the light pools under that finger or pointer, 0...1 (eases out after a release).
    public var touchLevel: Float
    /// How fast the owner is scrolling, 0...1: the whole line brightens with it and settles back.
    public var scroll: Float
    public var pad0: Float
    public var pad1: Float

    public enum Index {
        public static let time = 0
        public static let state = 1
        public static let previous = 2
        public static let transition = 3
        public static let pending = 4
        public static let intensity = 5
        public static let reducedMotion = 6
        public static let headroom = 7
        public static let lowPower = 8
        public static let eventAge = 9
        public static let width = 10
        public static let height = 11
        public static let pointScale = 12
        public static let dark = 13
        public static let activity = 14
        public static let touchX = 15
        public static let touchLevel = 16
        public static let scroll = 17
        public static let pad0 = 18
        public static let pad1 = 19
        public static let count = 20
    }

    public var packed: [Float] {
        [time, state, previous, transition, pending, intensity, reducedMotion, headroom, lowPower, eventAge,
         width, height, pointScale, dark, activity, touchX, touchLevel, scroll, pad0, pad1]
    }
}

public enum SyncGlowComposer {
    public static let defaultIntensity: Float = 1

    /// 0 at the start of a crossfade, 1 at the end. Reduce Motion jumps to the new state.
    public static func transition(elapsed: TimeInterval, duration: TimeInterval = SyncGlowTiming.transition, reduceMotion: Bool) -> Float {
        if reduceMotion || duration <= 0 { return 1 }
        if elapsed <= 0 { return 0 }
        if elapsed >= duration { return 1 }
        return Float(elapsed / duration)
    }

    public static func uniforms(
        time: Float,
        state: SyncGlowState,
        previous: SyncGlowState,
        transition: Float,
        pendingCount: Int,
        reduceMotion: Bool,
        lowPower: Bool,
        headroom: Float,
        eventAge: TimeInterval,
        width: Float,
        height: Float,
        intensity: Float = defaultIntensity,
        pointScale: Float = 1,
        dark: Bool = true,
        activity: Double? = nil,
        touchX: Float = -1,
        touchLevel: Float = 0,
        scroll: Float = 0
    ) -> SyncGlowUniforms {
        let fade: Float = reduceMotion ? 1 : min(max(transition, 0), 1)
        let room = headroom.isFinite ? max(headroom, 1) : 1
        let level = max(0, intensity) * (lowPower ? 0.8 : 1)
        let capped = min(max(pendingCount, 0), SyncGlowTiming.visiblePendingCap)
        return SyncGlowUniforms(
            time: reduceMotion ? SyncGlowTiming.stillTime : time,
            state: Float(state.rawValue),
            previous: Float(previous.rawValue),
            transition: fade,
            pending: Float(capped),
            intensity: level,
            reducedMotion: reduceMotion ? 1 : 0,
            headroom: room,
            lowPower: lowPower ? 1 : 0,
            eventAge: Float(max(0, eventAge)),
            width: max(0, width),
            height: max(0, height),
            pointScale: pointScale.isFinite ? max(pointScale, 1) : 1,
            dark: dark ? 1 : 0,
            activity: SyncGlowActivity.uniform(activity),
            touchX: touchX.isFinite && touchX >= 0 && !reduceMotion ? touchX : -1,
            // Reduce Motion: nothing follows a finger or a scroll.
            touchLevel: reduceMotion || !touchLevel.isFinite ? 0 : min(max(touchLevel, 0), 1),
            scroll: reduceMotion || !scroll.isFinite ? 0 : min(max(scroll, 0), 1),
            pad0: 0,
            pad1: 0)
    }
}

/// Nil means do not schedule another frame: the view draws one still and waits for the next change.
/// That is Reduce Motion, and also an up to date or offline band once its crossfade has finished:
/// neither moves, so a library that is simply in sync (or waiting for a network) costs one frame.
public enum SyncGlowPace {
    /// The syncing light drifts slowly and softly; this is enough for it to glide.
    public static let slow = 20
    /// Crossfades and one-shot moments.
    public static let active = 30
    public static let lowPowerSlow = 10
    public static let lowPowerActive = 15

    public static func framesPerSecond(
        state: SyncGlowState,
        transitioning: Bool,
        reduceMotion: Bool,
        lowPower: Bool,
        visible: Bool,
        sceneActive: Bool,
        live: Bool = false
    ) -> Int? {
        if !visible || !sceneActive || state == .off { return nil }
        if reduceMotion { return nil }
        // `live`: a save or upload is running, or a finger, the pointer or a scroll is moving the light.
        if transitioning || isOneShot(state) || live { return lowPower ? lowPowerActive : active }
        if state == .syncing { return lowPower ? lowPowerSlow : slow }
        return nil
    }

    /// A moment that plays once and is then cleared by `SyncGlowStatus.tick`.
    public static func isOneShot(_ state: SyncGlowState) -> Bool {
        state == .refused || state == .repull || state == .nudge || state == .arrived
    }

    /// Whether the view has to keep calling `tick`. Only a one-shot moment ends by the clock. The
    /// scene does not matter: a one-shot is the state until a tick clears it however old it is, so a
    /// window left in the background would come back showing a moment that ended long ago. The loop
    /// costs a few ticks, then the state is steady and it stops.
    public static func needsTick(state: SyncGlowState) -> Bool {
        isOneShot(state)
    }

    /// A frame drawn at this point of the crossfade is the finished picture and may be kept as the still.
    public static func isSettled(transition: Float) -> Bool {
        transition >= 0.999
    }
}

/// How the band looks, in numbers the shader repeats. Kept here so a test can hold the readability
/// rules: the glow is concentrated at the bottom edge, under the bars, and gone a short way above them.
public enum SyncGlowLook {
    /// The visible band above any bars, in points. The bottom safe area (tab bar, home indicator) is
    /// added on top, so the bars' glass sits over the brightest part.
    public static let bandHeight: Double = 56
    /// Tint cover at the very bottom edge, where bars cover it. This is what sits over content;
    /// light in dark mode is added on top of it (see `coreLift`) without covering anything more.
    public static func peakCover(dark: Bool) -> Float { dark ? 0.46 : 0.5 }
    /// The cover curve's exponent: higher is a steeper fall above the bars.
    public static let falloff: Float = 2
    /// Where no bars cover the edge (the Mac's detail column, a window's foot), content runs right
    /// down to it, so the peak is this share of `peakCover`. Full strength once this many points
    /// of the band are under bars.
    public static let barelessShare: Float = 0.7
    public static let fullBars: Float = 40

    /// The peak for a band whose bottom `bars` points are covered by bars.
    public static func edgePeak(dark: Bool, bars: Float) -> Float {
        let b = bars.isFinite ? min(max(bars / fullBars, 0), 1) : 0
        return peakCover(dark: dark) * (barelessShare + (1 - barelessShare) * b)
    }
    /// Nothing anywhere covers more than this.
    public static let totalCoverCap: Float = 0.6
    /// Dark mode: the core's light is lifted by up to this much at the edge in SDR, more with headroom.
    public static let coreBoost: Float = 1.4
    /// The horizon line: its centre above the bottom edge and its soft thickness, in points.
    public static let horizonHeight: Float = 3
    public static let horizonThickness: Float = 1.5
    /// Offline dashes: one every `dashPeriod` points, each `dashLength` long.
    public static let dashPeriod: Float = 15
    public static let dashLength: Float = 9
    /// The syncing light: how fast it drifts, in points a second, and its soft half-width in points.
    public static let lightSpeed: Float = 80
    public static let lightWidth: Float = 90

    /// How strongly each state tints the band, as a share of the peak.
    public static func amplitude(_ state: SyncGlowState) -> Float {
        switch state {
        case .upToDate: return 0.75
        case .syncing: return 0.6
        case .offlinePending: return 0.55
        case .refused: return 0.9
        case .repull: return 0.8
        case .nudge: return 0.65
        case .off: return 0
        case .arrived: return 0.7
        }
    }

    /// Cover at `heightFraction` of the band (0 at the bottom edge, 1 at its top). Flat at the bottom
    /// so the bars' glass has an even core to pick up, steepest just above the bars, flat again at the
    /// top so the band has no visible edge. Same curve as `washCover` in the shader.
    public static func washCover(heightFraction: Float, dark: Bool, amplitude: Float = 1, bars: Float = fullBars) -> Float {
        let f = min(max(heightFraction.isFinite ? heightFraction : 1, 0), 1)
        let a = min(max(amplitude, 0), 1)
        let s = f * f * (3 - 2 * f)
        return edgePeak(dark: dark, bars: bars) * a * pow(1 - s, falloff)
    }

    /// Dark mode light per unit of cover: 1 is plain tint, more is the hot core under the bars. It
    /// reaches into the display's headroom where there is some; the shader tone-maps it back for SDR.
    public static func coreLift(heightFraction: Float, headroom: Float) -> Float {
        let f = min(max(heightFraction.isFinite ? heightFraction : 1, 0), 1)
        let room = headroom.isFinite ? min(max(headroom, 1), 4) : 1
        let core = pow(1 - f, 3)
        return 1 + coreBoost * core * (1 + 0.5 * (room - 1))
    }
}

/// The offline line's dashes. The bright ones (one per waiting edit, up to the cap) sit in the
/// middle of the band, and the dash grid is lined up on them. Same maths as the shader's `dashes`.
public enum SyncGlowDashes {
    /// Dash slot `x` points from the left falls in, counted so the bright run is slots 0..<pending.
    public static func slot(x: Float, width: Float, pending: Int) -> Float {
        let n = Float(min(max(pending, 0), SyncGlowTiming.visiblePendingCap))
        return (x - width * 0.5) / SyncGlowLook.dashPeriod + n * 0.5
    }

    /// Whether `x` is on a dash at all (not in a gap).
    public static func onDash(x: Float, width: Float, pending: Int) -> Bool {
        let s = slot(x: x, width: width, pending: pending)
        let phase = (s - s.rounded(.down)) * SyncGlowLook.dashPeriod
        let gap = (SyncGlowLook.dashPeriod - SyncGlowLook.dashLength) * 0.5
        return phase >= gap && phase < gap + SyncGlowLook.dashLength
    }

    /// Whether `x` is on one of the bright dashes that count the waiting edits.
    public static func isBright(x: Float, width: Float, pending: Int) -> Bool {
        let n = Float(min(max(pending, 0), SyncGlowTiming.visiblePendingCap))
        let s = slot(x: x, width: width, pending: pending)
        return s >= 0 && s < n && onDash(x: x, width: width, pending: pending)
    }
}

/// Where the glow lives. It sits under the bars, at the bottom of each tab's content (iPhone, iPad),
/// of the detail column (Mac) and of the sheet, cover or window that has its own. A tab's band steps
/// aside while the queue sheet or the editor cover draws one, so two are never drawing at once.
public enum SyncGlowPlacement {
    public static func tabShowsBand(queueSheet: Bool, editorCover: Bool) -> Bool {
        !queueSheet && !editorCover
    }

    /// The band's full height: the visible part plus whatever the bars cover at the bottom.
    public static func bandHeight(bottomInset: Double) -> Double {
        SyncGlowLook.bandHeight + (bottomInset.isFinite ? max(bottomInset, 0) : 0)
    }
}

/// Launch arguments and the debug menu. `-previewSyncGlow syncing`, `-previewSyncGlowPending 4`.
public enum SyncGlowDebugParse {
    public static func state(from raw: String?) -> SyncGlowState? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "uptodate", "up-to-date", "up_to_date", "idle", "caughtup", "calm":
            return .upToDate
        case "syncing", "sync", "pull":
            return .syncing
        case "offline", "offlinepending", "pending":
            return .offlinePending
        case "refused", "refuse", "rollback":
            return .refused
        case "repull", "re-pull", "reroll", "410", "stale":
            return .repull
        case "nudge", "pulse":
            return .nudge
        case "off", "hidden", "disabled", "none":
            return .off
        case "arrived", "new", "newposts", "new-posts":
            return .arrived
        default:
            return nil
        }
    }

    public static func pending(from raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return max(0, value)
    }
}

/// The owner's own saves and uploads, as the line shows them. `nil` is none; 0...1 is how far the
/// work has got; `indeterminate` is work with no known length.
public enum SyncGlowActivity {
    public static let indeterminate: Double = 2

    /// What the shader reads: -1 none, 0...1 a fraction, 2 no known length.
    public static func uniform(_ value: Double?) -> Float {
        guard let value, value.isFinite, value >= 0 else { return -1 }
        if value > 1 { return Float(indeterminate) }
        return Float(value)
    }

    /// One value for several pieces of work. Each is a fraction 0...1, or nil when its length is not
    /// known. Any unknown makes the whole unknown; none at all is no activity. Rounded to half a
    /// percent, so a fast upload does not redraw the band for every few bytes.
    public static func combine(_ parts: [Double?]) -> Double? {
        guard !parts.isEmpty else { return nil }
        var sum = 0.0
        for part in parts {
            guard let part, part.isFinite else { return indeterminate }
            sum += min(max(part, 0), 1)
        }
        return (sum / Double(parts.count) * 200).rounded(.down) / 200
    }
}

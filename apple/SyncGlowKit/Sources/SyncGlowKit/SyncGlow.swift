import Foundation

// The numbers the constellation shader branches on. They match the paper mockup:
// 0 up to date, 1 syncing, 2 offline, 3 refused, 4 full re-pull, 5 nudge, 6 off.
public enum SyncGlowState: Int, Sendable, Equatable, CaseIterable {
    case upToDate = 0
    case syncing = 1
    case offlinePending = 2
    case refused = 3
    case repull = 4
    case nudge = 5
    case off = 6

    public var title: String {
        switch self {
        case .upToDate: return "Up to date"
        case .syncing: return "Syncing"
        case .offlinePending: return "Offline"
        case .refused: return "Refused"
        case .repull: return "Full re-pull"
        case .nudge: return "Nudge"
        case .off: return "Off"
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
        }
    }
}

/// How long a one-shot moment lasts, and where a debug screenshot should sit inside it.
public enum SyncGlowTiming {
    public static let transition: TimeInterval = 0.85
    /// Warm flicker: the constellation breaks, then has re-formed.
    public static let refused: TimeInterval = 1.15
    /// One shooting star crosses the band.
    public static let nudge: TimeInterval = 1.8
    /// Dissolve, then redraw from left to right. Held longer while the restart pull is still running.
    public static let repull: TimeInterval = 2.4
    /// Waiting stars drawn for an offline outbox. The count uniform never goes above this.
    public static let visiblePendingCap = 8
    /// A frozen clock for Reduce Motion. The twinkle sits in a middle phase, not on a dark frame.
    public static let stillTime: Float = 1.7

    public static func duration(of event: SyncGlowEvent) -> TimeInterval? {
        switch event {
        case .refused: return refused
        case .nudge: return nudge
        case .repull: return repull
        default: return nil
        }
    }

    public static func screenshotAge(_ state: SyncGlowState) -> TimeInterval {
        switch state {
        case .refused: return 0.32
        case .repull: return 1.35
        case .nudge: return 0.55
        case .offlinePending: return 0.40
        case .syncing: return 0.80
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
    /// pass. Offline wins over "syncing": a pass that cannot reach the server should not light the sweep.
    public static func state(_ facts: SyncGlowFacts) -> SyncGlowState {
        if !facts.engineEnabled || !facts.routeActive { return .off }
        switch facts.transient {
        case .refused: return .refused
        case .nudge: return .nudge
        case .repull: return .repull
        default: break
        }
        if !facts.reachable { return .offlinePending }
        if facts.passRunning || facts.pendingCount > 0 { return .syncing }
        return .upToDate
    }
}

/// The uniform block. Every field is a `Float` so the memory matches `GlowUniforms` in
/// `SyncConstellation.metal` with no padding. `Index` is the order both sides share.
public struct SyncGlowUniforms: Sendable, Equatable {
    public var time: Float
    public var state: Float
    public var previous: Float
    public var transition: Float
    public var pending: Float
    public var intensity: Float
    public var density: Float
    public var reducedMotion: Float
    public var headroom: Float
    public var lowPower: Float
    public var eventAge: Float
    public var width: Float
    public var height: Float
    public var atlasColumns: Float
    public var glyphsEnabled: Float
    /// Pads the block to 64 bytes. `setFragmentBytes` wants a multiple of 16.
    public var pad: Float

    public enum Index {
        public static let time = 0
        public static let state = 1
        public static let previous = 2
        public static let transition = 3
        public static let pending = 4
        public static let intensity = 5
        public static let density = 6
        public static let reducedMotion = 7
        public static let headroom = 8
        public static let lowPower = 9
        public static let eventAge = 10
        public static let width = 11
        public static let height = 12
        public static let atlasColumns = 13
        public static let glyphsEnabled = 14
        public static let pad = 15
        public static let count = 16
    }

    public var packed: [Float] {
        [time, state, previous, transition, pending, intensity, density, reducedMotion, headroom, lowPower, eventAge, width, height, atlasColumns, glyphsEnabled, pad]
    }

    public static let settled = SyncGlowUniforms(
        time: SyncGlowTiming.stillTime, state: 0, previous: 0, transition: 1, pending: 0,
        intensity: SyncGlowComposer.defaultIntensity, density: SyncGlowComposer.defaultDensity,
        reducedMotion: 0, headroom: 1, lowPower: 0, eventAge: 10, width: 0, height: 0,
        atlasColumns: Float(GlyphAtlasLayout.columns), glyphsEnabled: 1, pad: 0)
}

public enum SyncGlowComposer {
    public static let defaultIntensity: Float = 0.72
    public static let defaultDensity: Float = 0.70

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
        glyphsEnabled: Bool = true,
        intensity: Float = defaultIntensity,
        density: Float = defaultDensity
    ) -> SyncGlowUniforms {
        let fade: Float = reduceMotion ? 1 : min(max(transition, 0), 1)
        let room = max(headroom, 1)
        let level = max(0, intensity) * (lowPower ? 0.8 : 1)
        let capped = min(max(pendingCount, 0), SyncGlowTiming.visiblePendingCap)
        return SyncGlowUniforms(
            time: reduceMotion ? SyncGlowTiming.stillTime : time,
            state: Float(state.rawValue),
            previous: Float(previous.rawValue),
            transition: fade,
            pending: Float(capped),
            intensity: level,
            density: min(max(density, 0), 1),
            reducedMotion: reduceMotion ? 1 : 0,
            headroom: room,
            lowPower: lowPower ? 1 : 0,
            eventAge: Float(max(0, eventAge)),
            width: max(0, width),
            height: max(0, height),
            atlasColumns: Float(GlyphAtlasLayout.columns),
            glyphsEnabled: glyphsEnabled ? 1 : 0,
            pad: 0)
    }
}

/// Nil means do not schedule another frame. The view draws one still when Reduce Motion is on.
public enum SyncGlowPace {
    public static let idle = 15
    public static let active = 30
    public static let lowPowerIdle = 8
    public static let lowPowerActive = 15

    public static func framesPerSecond(
        state: SyncGlowState,
        transitioning: Bool,
        reduceMotion: Bool,
        lowPower: Bool,
        visible: Bool,
        sceneActive: Bool
    ) -> Int? {
        if !visible || !sceneActive || state == .off { return nil }
        if reduceMotion { return nil }
        let moving = transitioning || state == .syncing || state == .refused || state == .repull || state == .nudge
        if lowPower { return moving ? lowPowerActive : lowPowerIdle }
        return moving ? active : idle
    }
}

public struct GlyphUV: Sendable, Equatable {
    public var u0: Float
    public var v0: Float
    public var u1: Float
    public var v1: Float
}

/// Twelve cells in one row. Stars first, then the line characters the constellations are drawn with.
/// The shader indexes the same order; the bitmap itself is baked at runtime from a monospaced font.
public struct GlyphAtlasLayout: Sendable, Equatable {
    public static let stars: [Character] = [".", "*", "+", "o", "'", "`"]
    public static let links: [Character] = ["-", "/", "\\", "|", "_", ":"]
    public static let glyphs: [Character] = stars + links
    public static let columns = 12
    public static let starCount = 6

    public var cell: Int

    public init(cell: Int = 64) {
        self.cell = max(8, cell)
    }

    public var pixelWidth: Int { cell * Self.columns }
    public var pixelHeight: Int { cell }

    public func index(of glyph: Character) -> Int? {
        Self.glyphs.firstIndex(of: glyph)
    }

    public func glyph(at index: Int) -> Character? {
        Self.glyphs.indices.contains(index) ? Self.glyphs[index] : nil
    }

    /// Origin at the top-left of the atlas, y growing downward, which is how the baker stores rows.
    public func uv(index: Int) -> GlyphUV? {
        guard Self.glyphs.indices.contains(index) else { return nil }
        let cols = Float(Self.columns)
        let i = Float(index)
        return GlyphUV(u0: i / cols, v0: 0, u1: (i + 1) / cols, v1: 1)
    }

    /// Which line character joins two stars. `dx`/`dy` are in screen space, y growing downward.
    /// `/` rises to the right, so its deltas have opposite signs. `salt` (0...1) occasionally picks
    /// `_` or `:` so those cells in the atlas are actually used.
    public static func linkGlyph(dx: Float, dy: Float, salt: Float = 0) -> Character {
        let ax = abs(dx)
        let ay = abs(dy)
        if ay < ax * 0.35 || (ax < 0.000_1 && ay < 0.000_1) {
            return salt > 0.72 ? "_" : "-"
        }
        if ax < ay * 0.35 {
            return salt > 0.78 ? ":" : "|"
        }
        return (dx * dy) < 0 ? "/" : "\\"
    }

    public static func linkGlyphIndex(dx: Float, dy: Float, salt: Float = 0) -> Int {
        let glyph = linkGlyph(dx: dx, dy: dy, salt: salt)
        return glyphs.firstIndex(of: glyph) ?? 6
    }
}

/// The same decisions the shader makes, so a test can pin them without compiling Metal.
public enum SyncGlowField {
    public static func hash(_ x: Float, _ y: Float) -> Float {
        let value = sin(x * Float(127.1) + y * Float(311.7)) * Float(43_758.545_312_3)
        return value - floor(value)
    }

    public static func cellGrid(density: Float) -> (x: Float, y: Float) {
        let d = min(max(density, 0), 1)
        return (7 + 12 * d, 3 + 2.2 * d)
    }

    public static func showsStar(hash: Float, density: Float) -> Bool {
        let d = min(max(density, 0), 1)
        return hash < 0.22 + 0.28 * d
    }

    public static func starGlyphIndex(hash: Float) -> Int {
        let h = min(max(hash, 0), 0.999)
        return Int(h * Float(GlyphAtlasLayout.starCount))
    }
}

/// Where the one glow in a window lives. A full-screen sheet or the editor cover draws it itself;
/// the window band steps aside so two Metal views are never up in that window together.
public enum SyncGlowPlacement {
    public static func windowShowsBand(queueSheet: Bool, editorCover: Bool) -> Bool {
        !queueSheet && !editorCover
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
        case "nudge", "shooting", "shootingstar":
            return .nudge
        case "off", "hidden", "disabled", "none":
            return .off
        default:
            return nil
        }
    }

    public static func pending(from raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return max(0, value)
    }
}

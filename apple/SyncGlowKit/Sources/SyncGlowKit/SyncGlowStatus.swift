import Foundation
import Observation

/// What the library glow is showing. `LibrarySync` writes it when a pass, a refusal, a 410 or a
/// nudge happens. Reading it does not send, roll back, or pull.
@MainActor @Observable
public final class SyncGlowStatus {
    public private(set) var state: SyncGlowState = .upToDate
    public private(set) var pendingCount: Int = 0
    public private(set) var lastEvent: SyncGlowEvent = .none
    /// The owner's own saves and uploads (`SyncGlowActivity`): nil is none. It rides on top of every
    /// state, so it never changes `state`.
    public private(set) var activity: Double?

    @ObservationIgnored private var engineEnabled = true
    @ObservationIgnored private var routeActive = true
    /// A pass began while the route was marked missing. The engine only starts one then if it was
    /// reset for another server or account, so how this pass ends says whether the route is there now.
    @ObservationIgnored private var retryingRoute = false
    @ObservationIgnored private var reachable = true
    @ObservationIgnored private var passRunning = false
    /// The outbox count the engine last reported. A debug force displays its own count until cleared.
    @ObservationIgnored private var enginePending = 0
    @ObservationIgnored private var transient: SyncGlowEvent = .none
    @ObservationIgnored private var transientAt: Date?
    @ObservationIgnored private var forced: SyncGlowState?
    @ObservationIgnored private var pinnedAge: TimeInterval?
    @ObservationIgnored private var clock: @MainActor () -> Date

    public init(clock: @escaping @MainActor () -> Date = { Date() }) {
        self.clock = clock
    }

    /// A debug force pins the one-shot animations so a screenshot can land mid-flicker.
    public var pinsEventAge: Bool { pinnedAge != nil }

    public func eventAge(at now: Date) -> TimeInterval {
        if let pinnedAge { return pinnedAge }
        guard let transientAt else { return 10 }
        return max(0, now.timeIntervalSince(transientAt))
    }

    public func passBegan() {
        passRunning = true
        if !routeActive { retryingRoute = true }
        guard forced == nil else { return }
        // A nudge is set just before this pass. Catching up must not replace it, even when the
        // pass took long enough that the animation window would already have elapsed. `tick` ends it.
        // While the route is still marked missing the band is off and the last event stays "fell back".
        if transient == .none, routeActive {
            lastEvent = .passBegan
        }
        publish(clock())
    }

    public func passEnded(pending: Int) {
        passRunning = false
        enginePending = max(0, pending)
        // The pass that was tried after a fallback ended without another 404: sync is running again
        // (a new server, or the route was deployed), so the band comes back. The pass that fell back
        // itself also ends here, and must leave the band off.
        if retryingRoute {
            retryingRoute = false
            routeActive = true
        }
        guard forced == nil else { return }
        pendingCount = enginePending
        // A refusal, a nudge, or a re-pull stays up when the pass returns. Wall time spent inside
        // the pass (a slow pull, or a test whose main actor is busy) is not time the animation has
        // already played. `tick` is what lets it end. A pass with no one-shot event just settles.
        if transient == .none {
            lastEvent = steadyEvent()
        }
        publish(clock())
    }

    public func refused(pending: Int) {
        enginePending = max(0, pending)
        guard forced == nil else { return }
        pendingCount = enginePending
        beginTransient(.refused)
    }

    public func repullBegan() {
        guard forced == nil else { return }
        beginTransient(.repull)
    }

    public func nudged() {
        guard forced == nil else { return }
        beginTransient(.nudge)
    }

    /// A pull brought posts this device did not have. A refusal or a re-pull still playing is not
    /// cut short for it, and neither is the offline line (nothing arrives while offline anyway).
    public func arrived(count: Int) {
        guard forced == nil, count > 0 else { return }
        let now = clock()
        if transientActive(at: now), transient == .refused || transient == .repull { return }
        beginTransient(.arrived)
    }

    /// The owner's own saves and uploads, from `SyncGlowActivity.combine`. Nil when there are none.
    public func setActivity(_ value: Double?) {
        let next = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if next != activity { activity = next }
    }

    public func reachability(_ up: Bool, pending: Int) {
        enginePending = max(0, pending)
        reachable = up
        guard forced == nil else { return }
        pendingCount = enginePending
        let now = clock()
        if !transientActive(at: now) {
            lastEvent = up ? .cameOnline : .wentOffline
        }
        publish(now)
    }

    /// `GET /sync` answered 404. The glow goes away; today's library loading takes over.
    public func routeFellBack() {
        forced = nil
        pinnedAge = nil
        routeActive = false
        retryingRoute = false
        passRunning = false
        transient = .none
        transientAt = nil
        lastEvent = .fellBack
        publish(clock())
    }

    public func setEngineEnabled(_ on: Bool) {
        guard forced == nil else { return }
        engineEnabled = on
        if !on {
            transient = .none
            lastEvent = .fellBack
        }
        publish(clock())
    }

    /// Drops a transient whose moment has ended. The view calls this from its frame and when the
    /// scene becomes active again, so a flicker still ends if the shader was paused.
    public func tick(now: Date? = nil) {
        guard forced == nil else { return }
        let now = now ?? clock()
        if transient != .none, !transientActive(at: now) {
            transient = .none
            lastEvent = steadyEvent()
        }
        publish(now)
    }

    #if DEBUG
    /// Holds one state for screenshots. `nil` lets the engine drive again.
    public func debugForce(_ state: SyncGlowState?, pending: Int) {
        if let state {
            forced = state
            pinnedAge = SyncGlowTiming.screenshotAge(state)
            pendingCount = max(0, pending)
            lastEvent = SyncGlowEvent.debugMirror(of: state)
            self.state = state
        } else {
            forced = nil
            pinnedAge = nil
            pendingCount = enginePending
            publish(clock())
        }
    }
    #endif

    private func beginTransient(_ event: SyncGlowEvent) {
        lastEvent = event
        transient = event
        transientAt = clock()
        publish(clock())
    }

    private func transientActive(at now: Date) -> Bool {
        guard let duration = SyncGlowTiming.duration(of: transient) else { return false }
        if transient == .repull, passRunning { return true }
        return eventAge(at: now) < duration
    }

    private func steadyEvent() -> SyncGlowEvent {
        if !routeActive || !engineEnabled { return .fellBack }
        if !reachable { return .wentOffline }
        if passRunning || pendingCount > 0 { return .passBegan }
        return .caughtUp
    }

    private func publish(_ now: Date) {
        let facts = SyncGlowFacts(
            engineEnabled: engineEnabled,
            routeActive: routeActive,
            reachable: reachable,
            passRunning: passRunning,
            pendingCount: pendingCount,
            transient: transient,
            transientAge: eventAge(at: now))
        let resolved = SyncGlowResolve.state(facts)
        if resolved != state { state = resolved }
    }
}

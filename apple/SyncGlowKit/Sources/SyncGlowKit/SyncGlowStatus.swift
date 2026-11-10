import Foundation
import Observation

/// What the library glow is showing. `LibrarySync` writes it when a pass, a refusal, a 410 or a
/// nudge happens. Reading it does not send, roll back, or pull.
@MainActor @Observable
public final class SyncGlowStatus {
    public private(set) var state: SyncGlowState = .upToDate
    public private(set) var pendingCount: Int = 0
    public private(set) var lastEvent: SyncGlowEvent = .none

    @ObservationIgnored private var engineEnabled = true
    @ObservationIgnored private var routeActive = true
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
        guard forced == nil else { return }
        if !transientActive(at: clock()) {
            lastEvent = .passBegan
            transient = .none
        }
        publish(clock())
    }

    public func passEnded(pending: Int) {
        passRunning = false
        enginePending = max(0, pending)
        guard forced == nil else { return }
        pendingCount = enginePending
        let now = clock()
        if !transientActive(at: now) {
            transient = .none
            lastEvent = steadyEvent()
        }
        publish(now)
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

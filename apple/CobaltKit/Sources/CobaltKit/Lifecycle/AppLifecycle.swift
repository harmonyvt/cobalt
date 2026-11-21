import Foundation

// The app's one listener for "is the app active, in the background, low on memory" (apple/ARCHITECTURE.md, "Who owns
// what"). Before this, 37 places each read scenePhase or watched the app notifications themselves, with mixed Will/Did
// names, and a launch in the background (a finished download, an intent) never reached the scenePhase readers at all.
//
// Shape (from the SwiftUI structure review, 2026-11-21):
// - A process object, started by the app delegate before any window exists, so it also runs on background wakes.
// - It hears the OS's own app notifications, by name (CobaltKit builds into extensions, where there is no UIApplication
//   or NSApplication), on both platforms. scenePhase is not a source: it belongs to one window, never fires without a
//   window, and misses most Mac events.
// - It is deliberately NOT @Observable. App and Scene bodies and `.commands` must never read it (a read there makes the
//   whole scene list depend on it: the #113 loop). Views get a plain `LifecycleSnapshot` value through the Environment,
//   put there by the root window view (`publishesLifecycle()` in the app target).
// - Subscribers are called in a fixed order (`LifecycleOrder`), then caches are purged. The decision of what an event
//   means is one pure function, `LifecycleRules.apply`, unit-tested without any notification.

/// Where the app is, as far as the whole process is concerned (not one window).
public enum AppPhase: String, Sendable, Equatable {
    /// The process started and has not been told it is active yet (a cold launch, or a background wake).
    case launching
    /// In front and taking touches (iOS) or the frontmost app (Mac).
    case active
    /// On screen but not taking input: Control Center, an incoming call, the app switcher (iOS); behind another app (Mac).
    case inactive
    /// Off screen. On iOS the next step may be suspension or the process ending.
    case background
}

/// One thing the OS told the app.
public enum LifecycleEvent: Sendable, Equatable {
    case becameActive
    case willResignActive
    case willEnterForeground
    case didEnterBackground
    case willTerminate
    case memoryWarning
    case thermalChanged(ProcessInfo.ThermalState)
    /// Mac: Cmd-H / the app was hidden, and shown again.
    case hidden
    case unhidden
}

/// What the view tree may read: a value, compared before it is published, so an unchanged snapshot never re-runs a body.
public struct LifecycleSnapshot: Sendable, Equatable {
    public var phase: AppPhase
    /// A memory warning arrived since the app last became active.
    public var memoryPressure: Bool
    public var thermal: ProcessInfo.ThermalState

    public init(phase: AppPhase = .launching, memoryPressure: Bool = false, thermal: ProcessInfo.ThermalState = .nominal) {
        self.phase = phase
        self.memoryPressure = memoryPressure
        self.thermal = thermal
    }

    /// On screen (active or inactive). Polling, animation and playback may run.
    public var isForeground: Bool { phase == .active || phase == .inactive }
    /// Taking input. Things that only make sense while the owner is using the app (timers on screen, auto-refresh).
    public var isActive: Bool { phase == .active }
    /// Heavy, optional work (animation, prefetch) should hold back: serious or critical thermal state, or memory pressure.
    public var shouldThrottle: Bool { memoryPressure || thermal == .serious || thermal == .critical }
}

/// How hard a cache should let go.
public enum PurgeLevel: Int, Sendable, Comparable {
    /// The app left the screen: drop what is held in memory and can be rebuilt from disk.
    case background = 0
    /// The OS asked for memory: drop everything held in memory.
    case memoryWarning = 1

    public static func < (a: PurgeLevel, b: PurgeLevel) -> Bool { a.rawValue < b.rawValue }
}

/// The order subscribers are called in, lowest first. Telemetry first so the log shows the event before what it caused;
/// work and Live Activities before media, so a summary or a grace period starts before players pause.
public enum LifecycleOrder: Int, Sendable, Comparable {
    case telemetry = 0
    case work = 10
    case liveActivities = 20
    case media = 30
    case screens = 40

    public static func < (a: LifecycleOrder, b: LifecycleOrder) -> Bool { a.rawValue < b.rawValue }
}

/// A process-lifetime object that reacts to the app's state. Called on the main actor, outside any view update.
@MainActor
public protocol LifecycleAware: AnyObject {
    func lifecycle(_ event: LifecycleEvent, snapshot: LifecycleSnapshot)
}

/// Something that holds memory it can give back (an in-memory cache, idle players). Never deletes disk copies.
@MainActor
public protocol Purgeable: AnyObject {
    func purge(_ level: PurgeLevel)
}

/// The pure part: what an event does to the snapshot, and whether caches should be purged.
public enum LifecycleRules {
    public struct Outcome: Sendable, Equatable {
        public var snapshot: LifecycleSnapshot
        public var purge: PurgeLevel?
        /// False when the event changes nothing worth telling subscribers (a repeat).
        public var deliver: Bool
    }

    public static func apply(_ event: LifecycleEvent, to s: LifecycleSnapshot) -> Outcome {
        var next = s
        var purge: PurgeLevel?
        switch event {
        case .becameActive:
            next.phase = .active
            next.memoryPressure = false
        case .willResignActive:
            // the Mac's "resign" means another app is in front: on screen, not frontmost
            next.phase = .inactive
        case .willEnterForeground, .unhidden:
            next.phase = .inactive
        case .didEnterBackground, .hidden:
            next.phase = .background
            purge = .background
        case .willTerminate:
            next.phase = .background
        case .memoryWarning:
            next.memoryPressure = true
            purge = .memoryWarning
        case .thermalChanged(let state):
            next.thermal = state
        }
        // Repeats (a second "did become active", the same thermal state) are not delivered, but a memory warning always is.
        let deliver = next != s || event == .memoryWarning || event == .willTerminate
        return Outcome(snapshot: next, purge: purge, deliver: deliver)
    }
}

/// The one listener. `AppLifecycle.shared.start()` from the app delegate; subscribers `register` themselves once.
@MainActor
public final class AppLifecycle {
    public static let shared = AppLifecycle()

    /// The state now. Read it from code; views read the Environment copy.
    public private(set) var snapshot = LifecycleSnapshot()

    private struct Entry { weak var target: (any LifecycleAware)?; let order: LifecycleOrder; let seq: Int }
    private struct PurgeEntry { weak var target: (any Purgeable)? }
    private var entries: [Entry] = []
    private var purgeables: [PurgeEntry] = []
    private var observers: [any NSObjectProtocol] = []
    private var continuations: [UUID: AsyncStream<LifecycleSnapshot>.Continuation] = [:]
    private var seq = 0
    private(set) var started = false

    /// For tests: a fresh listener that hears nothing until `feed` is called.
    public init() {}

    /// Installs the notification observers, once. Safe to call again.
    public func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        func watch(_ name: String, _ event: LifecycleEvent) {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.feed(event) }
            })
        }
        #if os(macOS)
        watch("NSApplicationDidBecomeActiveNotification", .becameActive)
        watch("NSApplicationWillResignActiveNotification", .willResignActive)
        watch("NSApplicationDidHideNotification", .hidden)
        watch("NSApplicationDidUnhideNotification", .unhidden)
        watch("NSApplicationWillTerminateNotification", .willTerminate)
        #else
        watch("UIApplicationDidBecomeActiveNotification", .becameActive)
        watch("UIApplicationWillResignActiveNotification", .willResignActive)
        watch("UIApplicationWillEnterForegroundNotification", .willEnterForeground)
        watch("UIApplicationDidEnterBackgroundNotification", .didEnterBackground)
        watch("UIApplicationWillTerminateNotification", .willTerminate)
        watch("UIApplicationDidReceiveMemoryWarningNotification", .memoryWarning)
        #endif
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            MainActor.assumeIsolated { self?.feed(.thermalChanged(state)) }
        })
        let state = ProcessInfo.processInfo.thermalState
        if state != snapshot.thermal { snapshot.thermal = state }
    }

    /// Signs a process-lifetime object up for events, called in `order` (then in the order they registered). Held weakly.
    public func register(_ target: any LifecycleAware, order: LifecycleOrder) {
        entries.removeAll { $0.target == nil || $0.target === target }
        seq += 1
        entries.append(Entry(target: target, order: order, seq: seq))
        entries.sort { ($0.order, $0.seq) < ($1.order, $1.seq) }
    }

    /// Signs a cache (or anything holding rebuildable memory) up for purges. Held weakly.
    public func register(purgeable target: any Purgeable) {
        purgeables.removeAll { $0.target == nil || $0.target === target }
        purgeables.append(PurgeEntry(target: target))
    }

    /// Every snapshot from now on, starting with the current one. The root window view feeds the Environment from this.
    public func snapshots() -> AsyncStream<LifecycleSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(snapshot)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    /// Delivers one event: snapshot first, then subscribers in order, then purges. Public for the app delegate and tests.
    public func feed(_ event: LifecycleEvent) {
        let outcome = LifecycleRules.apply(event, to: snapshot)
        guard outcome.deliver else { return }
        snapshot = outcome.snapshot
        for c in continuations.values { c.yield(snapshot) }
        entries.removeAll { $0.target == nil }
        for entry in entries { entry.target?.lifecycle(event, snapshot: snapshot) }
        if let level = outcome.purge {
            purgeables.removeAll { $0.target == nil }
            for p in purgeables { p.target?.purge(level) }
        }
    }

    /// How many live subscribers (tests).
    var subscriberCount: Int { entries.filter { $0.target != nil }.count }
}

import AVFoundation
import Foundation

// The app's video players, seen from one place (the lifecycle audit: "heavy players have no shared pause/cap rule").
// Before this each owner (the orbit's pool, the focused planet, the loops, the detail's hero, the trims) paused its own
// player when its view went away and nothing else: the app going to the background, Control Center, a memory warning or a
// seventh player on screen changed nothing, and Home alone could hold five or six decoders.
//
// This is a small register, not a lease: owners still make, show and drop their players. They tell the pool when a player
// should play (`play`), when they paused it themselves (`pause`) and when they are done with it (`forget`). The pool then
// - keeps at most `maxPlaying` playing, pausing the oldest that is not a hero or a trim (`PlayerCap`),
// - pauses everything when the app leaves the screen (iOS: resigning active or the background; Mac: hidden) and plays
//   again, on becoming active, the ones that were playing and that their owner still has,
// - on a memory warning lets idle players go through the owner's `release` (an owner that gives none keeps its player).
// Players are held weakly: an owner that drops a player without `forget` loses nothing but its entry.
//
// In CobaltKit, not the app, because the focus layer's trim preview (Cobalt/Shared/TrimPreview.swift) is also compiled into
// the share and keyboard extensions. There AppLifecycle is never started, so only the cap applies.

@MainActor
public final class PlayerPool: LifecycleAware, Purgeable {
    public static let shared = PlayerPool()

    /// Who owns a player. Heroes (the detail's video, the full-screen player) and trims are what the owner is watching or
    /// working on: they count towards the cap but are never paused to make room.
    public enum Role: Sendable {
        case orbit, focus, loop, hero, trim

        public var isProtected: Bool { self == .hero || self == .trim }
    }

    /// At most this many players play at once. UNMEASURED: a guess from the audit's count (three orbit loops plus the
    /// focused planet is the busiest normal Home); check it on the owner's phone (Instruments, the video decoder count and
    /// memory with Home, a detail and a trim open) before trusting it.
    public static let maxPlaying = 4

    private final class Entry {
        let id: Int
        weak var player: AVPlayer?
        var role: Role
        var started = 0
        /// The owner's way to let the player go on a memory warning (nil: the owner keeps it).
        var release: (@MainActor () -> Void)?

        init(id: Int, player: AVPlayer, role: Role) {
            self.id = id
            self.player = player
            self.role = role
        }

        var isPlaying: Bool {
            guard let player else { return false }
            return player.rate != 0 || player.timeControlStatus != .paused
        }
    }

    private var entries: [Entry] = []
    /// Entry ids the pool paused when the app left the screen, to play again when it is back.
    private var held: Set<Int> = []
    /// The app is off screen (or not taking input on iOS): new plays wait in `held` instead of starting.
    private var holding = false
    private var nextID = 0
    private var clock = 0
    private let cap: Int
    /// Non-AVPlayer hardware video decoders (e.g. concurrent `TwitchNativeEngine` streams) borrowing decoder slots.
    private var externalReservations: [String: Int] = [:]
    /// True while Low Power Mode or serious/critical thermal pressure should pause unprotected autoplay loops.
    private var conservingPower = false

    /// Total hardware decoder slots currently reserved by external engines (e.g. Twitch multi-stream).
    public var reservedExternalCount: Int {
        externalReservations.values.reduce(0, +)
    }

    /// Effective AVPlayer cap after subtracting external decoder reservations and power/thermal limits.
    public var effectiveCap: Int {
        if conservingPower { return 0 }
        return max(0, cap - reservedExternalCount)
    }

    private static func shouldPauseAutoplay(_ snapshot: LifecycleSnapshot) -> Bool {
        snapshot.isLowPowerMode || snapshot.thermal == .serious || snapshot.thermal == .critical
    }

    /// `lifecycle` is the app's listener; tests pass their own.
    init(lifecycle: AppLifecycle = .shared, cap: Int = PlayerPool.maxPlaying) {
        self.cap = cap
        self.conservingPower = Self.shouldPauseAutoplay(lifecycle.snapshot)
        lifecycle.register(self, order: .media)
        lifecycle.register(purgeable: self)
    }

    // MARK: external decoders

    /// Reserves `count` hardware video decoder slots for an external subsystem (such as 1...4 live Twitch streams)
    /// and immediately pauses excess unprotected background `AVPlayer` instances (e.g. Home orbit loops).
    public func reserveExternalDecoders(id: String, count: Int) {
        let clamped = max(0, count)
        if clamped == 0 {
            externalReservations.removeValue(forKey: id)
        } else {
            externalReservations[id] = clamped
        }
        enforceCap(keeping: nil)
    }

    /// Releases a previously registered external decoder reservation.
    public func releaseExternalDecoders(id: String) {
        externalReservations.removeValue(forKey: id)
    }

    // MARK: owners

    /// Plays `player` (now, or when the app is back on screen) and makes room under the cap. `release`, when given,
    /// replaces the owner's memory-warning hook; nil keeps the one it had.
    public func play(_ player: AVPlayer, as role: Role, release: (@MainActor () -> Void)? = nil) {
        let known = entry(for: player, as: role, release: release)
        if holding {
            held.insert(known.id)
            return
        }
        if conservingPower && !role.isProtected {
            player.pause()
            return
        }
        clock += 1
        known.started = clock
        player.play()
        enforceCap(keeping: known.id)
    }

    /// Knows about `player` without playing it (a player handed over already playing: the orbit adopting the focused
    /// planet's, the hero showing the orbit's). Changes the role of one it already knows.
    public func track(_ player: AVPlayer, as role: Role, release: (@MainActor () -> Void)? = nil) {
        _ = entry(for: player, as: role, release: release)
    }

    private func entry(for player: AVPlayer, as role: Role, release: (@MainActor () -> Void)?) -> Entry {
        prune()
        if let known = entries.first(where: { $0.player === player }) {
            known.role = role
            if let release { known.release = release }
            return known
        }
        nextID += 1
        clock += 1
        let entry = Entry(id: nextID, player: player, role: role)
        entry.started = clock
        entry.release = release
        entries.append(entry)
        return entry
    }

    /// The owner paused it: the pool will not start it again when the app comes back.
    public func pause(_ player: AVPlayer) {
        player.pause()
        if let entry = entries.first(where: { $0.player === player }) { held.remove(entry.id) }
    }

    /// The owner is done with it (it pauses and empties it itself).
    public func forget(_ player: AVPlayer) {
        if let index = entries.firstIndex(where: { $0.player === player }) {
            held.remove(entries[index].id)
            entries.remove(at: index)
        }
    }

    // MARK: the cap

    private func enforceCap(keeping id: Int?) {
        let playing = entries.filter(\.isPlaying)
        let slots = playing.map { PlayerCap.Slot(id: $0.id, started: $0.started, protected: $0.role.isProtected) }
        let pause = Set(PlayerCap.toPause(slots, cap: effectiveCap, keep: id))
        guard !pause.isEmpty else { return }
        for entry in playing where pause.contains(entry.id) { entry.player?.pause() }
        Telemetry.log(.info, .ui, "players.cap", data: ["paused": .int(pause.count)])
    }

    // MARK: the app's state

    public func lifecycle(_ event: LifecycleEvent, snapshot: LifecycleSnapshot) {
        let nextConserving = Self.shouldPauseAutoplay(snapshot)
        if nextConserving != conservingPower {
            conservingPower = nextConserving
            if conservingPower {
                enforceCap(keeping: nil)
            }
        }
        switch event {
        #if os(iOS)
        case .willResignActive, .didEnterBackground: hold()
        #else
        // the Mac's "resign" is another app in front: still on screen, so a video the owner watches goes on
        case .hidden, .didEnterBackground: hold()
        case .unhidden: resume()
        #endif
        case .becameActive: resume()
        default: break
        }
    }

    /// Pauses every playing player and remembers it.
    private func hold() {
        prune()
        holding = true
        for entry in entries where entry.isPlaying {
            entry.player?.pause()
            held.insert(entry.id)
        }
    }

    /// Plays again what `hold` paused and the owner still has (an owner that let its player go took it out with `forget`).
    private func resume() {
        guard holding else { return }
        holding = false
        prune()
        let back = entries.filter { held.contains($0.id) }.sorted { $0.started < $1.started }
        held = []
        for entry in back {
            clock += 1
            entry.started = clock
            entry.player?.play()
        }
        if let newest = back.last { enforceCap(keeping: newest.id) }
    }

    // MARK: memory

    /// A memory warning lets idle players go: paused (by the cap or their owner) and not waiting to resume, through the
    /// owner's `release`. A background purge changes nothing here: the hold already paused them.
    public func purge(_ level: PurgeLevel) {
        prune()
        guard level == .memoryWarning else { return }
        let idle = entries.filter { !$0.isPlaying && !held.contains($0.id) && $0.release != nil }
        for entry in idle {
            let release = entry.release
            if let player = entry.player { forget(player) }
            release?()
        }
        if !idle.isEmpty { Telemetry.log(.info, .ui, "players.purged", data: ["count": .int(idle.count)]) }
    }

    private func prune() {
        entries.removeAll { $0.player == nil }
    }

    /// How many players the pool knows and how many play (evidence runs, tests).
    public var counts: (known: Int, playing: Int) {
        prune()
        return (entries.count, entries.filter(\.isPlaying).count)
    }
}

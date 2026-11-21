import Foundation

// The rule behind the app's player pool (`PlayerPool`, next to this file): at most a few video decoders play at once.
// A phone has a handful of hardware decoders and each playing AVPlayer holds one plus its buffers; the lifecycle audit
// counted up to six on Home alone (three orbit loops, the lent one, the focused planet, the warm-up player, the hero, a
// trim). The pool asks this pure function which players to pause, so the choice is testable without AVFoundation.

public enum PlayerCap {
    /// One playing player, as the pool sees it.
    public struct Slot: Sendable, Equatable {
        /// The pool's own number for it.
        public var id: Int
        /// When it last started playing (bigger is newer).
        public var started: Int
        /// The owner is watching or working with it (the detail's hero, a trim): never paused to make room.
        public var protected: Bool

        public init(id: Int, started: Int, protected: Bool) {
            self.id = id
            self.started = started
            self.protected = protected
        }
    }

    /// The players to pause so at most `cap` play: the oldest unprotected ones first, never `keep` (the one that just
    /// asked to play). Protected players count towards the cap but are never chosen, so a cap of 4 with 2 heroes leaves
    /// room for 2 more. Returns ids, oldest first.
    public static func toPause(_ playing: [Slot], cap: Int, keep: Int? = nil) -> [Int] {
        let over = playing.count - max(0, cap)
        guard over > 0 else { return [] }
        let candidates = playing
            .filter { !$0.protected && $0.id != keep }
            .sorted { $0.started != $1.started ? $0.started < $1.started : $0.id < $1.id }
        return candidates.prefix(over).map(\.id)
    }
}

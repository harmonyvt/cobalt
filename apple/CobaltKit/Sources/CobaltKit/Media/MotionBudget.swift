import Foundation
import Observation

#if canImport(UIKit)
import UIKit
#endif

/// How many small moving pictures (7TV emotes, in grids, sheets, chat cards and the keyboard) play at once. Every emote
/// that is on screen and wants to move asks for a slot; the first `limit` to ask get one, in the order they asked, and
/// keep it until they leave the screen or stop wanting it, when the next in line gets it. Everything else shows its first
/// frame. Low Power Mode stops them all. (The library mosaic keeps its own `AnimationBudget`, which picks the tiles
/// nearest the centre and stops while the scroll moves; emotes are small and many, so first come, first served is enough.)
///
/// 8.16's 7TV tab played every animated emote it had drawn, visible or not, which was most of its 401 ms/s of hitches.
@MainActor
public final class MotionBudget: LifecycleAware {
    public static let shared = MotionBudget(limit: MotionBudget.deviceLimit)
    /// Dedicated budget for GPU-only animated 7TV name paint shaders so they pause in Low Power Mode / thermal pressure
    /// without taking decode slots away from animated WebP emotes.
    public static let shader = MotionBudget(limit: MotionBudget.shaderDeviceLimit)

    /// 10 on iPhone, 16 on iPad and Mac so busy dual-stream chats stay smooth during scrolls and rotations.
    public static var deviceLimit: Int {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? 10 : 16
        #else
        return 16
        #endif
    }

    /// 8 on iPhone, 12 on iPad and Mac to keep per-frame Metal paint overhead bounded.
    public static var shaderDeviceLimit: Int {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? 8 : 12
        #else
        return 12
        #endif
    }

    public let limit: Int
    private var dynamicLimitOverride: Int?
    private var line: [WeakTicket] = []
    private var lowPower: Bool

    /// Active animated emote limit after accounting for concurrent multi-stream playback.
    public var effectiveLimit: Int {
        guard let override = dynamicLimitOverride else { return limit }
        return min(limit, max(0, override))
    }

    private struct WeakTicket {
        weak var ticket: MotionTicket?
    }

    /// `watchPower: false` for tests: the budget then never registers with `AppLifecycle`.
    public init(limit: Int, watchPower: Bool = true) {
        self.limit = max(0, limit)
        if watchPower {
            let snap = AppLifecycle.shared.snapshot
            self.lowPower = snap.shouldConservePower || ProcessInfo.processInfo.isLowPowerModeEnabled
            AppLifecycle.shared.register(self, order: .media)
        } else {
            self.lowPower = false
        }
    }

    public func lifecycle(_ event: LifecycleEvent, snapshot: LifecycleSnapshot) {
        setLowPower(snapshot.shouldConservePower || !snapshot.isForeground)
    }

    /// Tightens animated emote budget when 3+ live Twitch streams are decoding concurrently so busy multi-channel
    /// chats stay at 60/120 fps on iPhone and iPad/Mac.
    public func setActiveStreamCount(_ count: Int) {
        let nextOverride: Int?
        if count >= 3 {
            nextOverride = limit <= 8 ? 4 : (limit <= 10 ? 6 : 8)
        } else {
            nextOverride = nil
        }
        guard nextOverride != dynamicLimitOverride else { return }
        dynamicLimitOverride = nextOverride
        recompute()
    }

    /// The ticket wants to move (on screen and animated) or not any more. Granting is the ticket's `granted`.
    public func want(_ ticket: MotionTicket, _ wants: Bool) {
        let slots = lowPower ? 0 : effectiveLimit
        if wants {
            var write = 0
            var compactedUnderSlots = false
            var found = false
            for i in line.indices {
                guard let current = line[i].ticket else {
                    if i < slots { compactedUnderSlots = true }
                    continue
                }
                if current === ticket { found = true }
                if write != i { line[write] = line[i] }
                write += 1
            }
            if write != line.count { line.removeLast(line.count - write) }
            guard !found else {
                if compactedUnderSlots { syncGrants(slots: slots) }
                return
            }
            let newIndex = line.count
            line.append(WeakTicket(ticket: ticket))
            if compactedUnderSlots {
                syncGrants(slots: slots)
            } else {
                let shouldGrant = newIndex < slots
                if ticket.granted != shouldGrant { ticket.granted = shouldGrant }
            }
        } else {
            guard let idx = line.firstIndex(where: { $0.ticket === ticket }) else {
                if ticket.granted { ticket.granted = false }
                return
            }
            line.remove(at: idx)
            if ticket.granted { ticket.granted = false }
            // Leaving a slot past `slots` never promotes any waiting ticket.
            if idx < slots {
                recompute()
            }
        }
    }

    /// How many tickets move now (tests and diagnostics).
    public var playingCount: Int { line.reduce(0) { $0 + (($1.ticket?.granted ?? false) ? 1 : 0) } }

    func setLowPower(_ value: Bool) {
        guard value != lowPower else { return }
        lowPower = value
        recompute()
    }

    private func recompute() {
        // a ticket whose view went away without saying so leaves the line here
        line.removeAll { $0.ticket == nil }
        syncGrants(slots: lowPower ? 0 : effectiveLimit)
    }

    private func syncGrants(slots: Int) {
        for (i, entry) in line.enumerated() {
            guard let ticket = entry.ticket else { continue }
            let granted = i < slots
            if ticket.granted != granted { ticket.granted = granted }
        }
    }
}

/// One moving picture's place in `MotionBudget`. Observable on its own, so a change of who plays re-draws only the
/// pictures whose answer changed.
@MainActor @Observable
public final class MotionTicket {
    public internal(set) var granted = false
    public init() {}
}

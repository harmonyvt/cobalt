import Foundation
import Observation

// Equal-power dual-stream audio crossfader + follow-focus pin state machine (Wave 2).
//
// UX rules (Opus Best-of-Breed Hybrid Spec):
// - Single >= 44 pt `A · Mix · B` segmented/scrubbable control driving continuous `balance` in `0.0...1.0`.
// - Equal-power crossfade law: `gainA = cos(balance * pi/2)`, `gainB = sin(balance * pi/2)` so
//   `gainA^2 + gainB^2 == 1.0` with no perceptual volume dip at 50/50 Mix.
// - Smooth 200-250 ms equal-power ramps via `TwitchNativeEngine.rampVolume(to:duration:curve:updateMuteOnEndpoints:)`,
//   toggling `isMuted` only at exact `0.0` endpoints to avoid CoreAudio clicks.
// - Audio follows focus by default; any manual preset/scrub pins the mix (surfaced via a clear pin badge)
//   so tapping focus does not overwrite balance until unpinned/reset.
// - Speaker indicator shows on the louder stream ONLY (nil when balanced in Mix).
// - On screen lock when NOT in PiP, suspends the muted secondary stream immediately and resumes on foreground.

/// Quick-select presets for the `A · Mix · B` audio crossfader.
public enum TwitchDualAudioPreset: String, Sendable, Equatable, CaseIterable {
    case primary
    case mix
    case secondary

    public var balance: Double {
        switch self {
        case .primary: 0.0
        case .mix: 0.5
        case .secondary: 1.0
        }
    }
}

/// Snapshot of equal-power linear gains and mute endpoints for Stream A (`primary`) and Stream B (`secondary`).
public struct TwitchDualAudioGains: Sendable, Equatable {
    public var primary: Float
    public var secondary: Float
    public var primaryMuted: Bool
    public var secondaryMuted: Bool

    /// The strictly louder stream slot for showing a single speaker glyph; `nil` when both are equal (50/50 Mix)
    /// or both muted.
    public var louderSlot: TwitchDualSlot? {
        if primaryMuted && secondaryMuted { return nil }
        if primaryMuted { return .secondary }
        if secondaryMuted { return .primary }
        if primary > secondary + 0.015 { return .primary }
        if secondary > primary + 0.015 { return .secondary }
        return nil
    }

    public init(primary: Float, secondary: Float, primaryMuted: Bool, secondaryMuted: Bool) {
        self.primary = primary
        self.secondary = secondary
        self.primaryMuted = primaryMuted
        self.secondaryMuted = secondaryMuted
    }
}

/// Bridge from `TwitchDualAudioMixer` to the live `TwitchNativeEngine` pair (mockable in unit tests).
@MainActor
public protocol TwitchDualAudioTarget: AnyObject {
    func applyDualAudioRamp(
        primaryGain: Float,
        secondaryGain: Float,
        duration: TimeInterval,
        curve: TwitchVolumeRampCurve,
        updateMuteOnEndpoints: Bool
    )
    func setDualSlotSuspended(_ slot: TwitchDualSlot, suspended: Bool)
}

/// Coordinates equal-power audio crossfading, follow-focus pinning, and lock-screen secondary suspension
/// across Stream A (`primary`) and Stream B (`secondary`).
@MainActor @Observable
public final class TwitchDualAudioMixer {
    /// Smooth 220 ms ramp duration (Opus spec: 200-250 ms equal-power ramp).
    public static let defaultRampDuration: TimeInterval = 0.22
    /// Tighter ramp used during interactive finger scrubbing so drag feels immediate without clicks.
    public static let scrubRampDuration: TimeInterval = 0.04

    /// Continuous crossfade balance in `0.0...1.0`: `0.0` = 100% primary (A), `0.5` = Mix, `1.0` = 100% secondary (B).
    public private(set) var balance: Double = 0.0
    /// Currently visually focused stream slot.
    public private(set) var focusedSlot: TwitchDualSlot = .primary
    /// True once the user manually adjusted `A · Mix · B`; keeps balance pinned across focus swaps until unpinned.
    public private(set) var isPinned: Bool = false
    /// Slot currently suspended to save power/bandwidth while screen is locked (not in PiP).
    public private(set) var suspendedSlot: TwitchDualSlot? = nil

    @ObservationIgnored public weak var target: (any TwitchDualAudioTarget)?

    public init() {}

    /// Current equal-power gains and mute states derived from `balance`.
    public var gains: TwitchDualAudioGains {
        Self.equalPowerGains(for: balance)
    }

    /// Nearest `A · Mix · B` segment highlighted in the control.
    public var activePreset: TwitchDualAudioPreset {
        if balance <= 0.15 { return .primary }
        if balance >= 0.85 { return .secondary }
        return .mix
    }

    /// The single slot that should display a speaker glyph (`nil` in balanced Mix so two equal speakers never compete).
    public var louderSlot: TwitchDualSlot? {
        gains.louderSlot
    }

    /// Computes constant-power (`cos` / `sin`) linear gains for `balance` in `0.0...1.0`.
    /// Endpoint snap within `0.001` guarantees clean `0.0` / `1.0` mute transitions.
    public static func equalPowerGains(for rawBalance: Double) -> TwitchDualAudioGains {
        let b = min(max(rawBalance, 0.0), 1.0)
        if b <= 0.001 {
            return TwitchDualAudioGains(primary: 1.0, secondary: 0.0, primaryMuted: false, secondaryMuted: true)
        }
        if b >= 0.999 {
            return TwitchDualAudioGains(primary: 0.0, secondary: 1.0, primaryMuted: true, secondaryMuted: false)
        }
        let angle = b * (.pi / 2.0)
        let gA = Float(cos(angle))
        let gB = Float(sin(angle))
        return TwitchDualAudioGains(primary: gA, secondary: gB, primaryMuted: false, secondaryMuted: false)
    }

    /// Resets mixer state for a newly started dual-stream session (unpinned, following `focused`).
    public func reset(focused: TwitchDualSlot = .primary, animated: Bool = false) {
        resumeSuspendedSlotIfNeeded()
        focusedSlot = focused
        isPinned = false
        balance = focused == .primary ? 0.0 : 1.0
        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
    }

    /// Re-applies current gains to `target` (for instance, right after Stream B finishes attaching).
    public func syncToTarget(animated: Bool = false) {
        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
    }

    /// Updates focused stream slot (e.g. 1-tap inset swap). Follows audio automatically unless pinned.
    public func setFocus(_ slot: TwitchDualSlot, animated: Bool = true) {
        let changed = focusedSlot != slot
        focusedSlot = slot
        guard !isPinned else { return }
        let nextBalance = slot == .primary ? 0.0 : 1.0
        if changed || abs(balance - nextBalance) > 0.001 {
            balance = nextBalance
            dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
        }
    }

    /// Toggles visual focus `primary <-> secondary`. Follows audio unless pinned.
    public func swapFocus(animated: Bool = true) {
        setFocus(focusedSlot.other, animated: animated)
    }

    /// Swaps audio focus for Lock Screen / Control Center remote track commands (`onNextTrack` / `onPreviousTrack`).
    /// Always moves audio cleanly to the other stream, even when previously pinned or locked with a suspended slot.
    public func swapAudioFocusForRemoteCommand(animated: Bool = true) {
        let nextSlot: TwitchDualSlot
        if let louder = louderSlot {
            nextSlot = louder.other
        } else {
            nextSlot = focusedSlot.other
        }
        let wasSuspended = suspendedSlot
        if wasSuspended == nextSlot {
            suspendedSlot = nil
            target?.setDualSlotSuspended(nextSlot, suspended: false)
        }
        focusedSlot = nextSlot
        isPinned = false
        balance = nextSlot == .primary ? 0.0 : 1.0
        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
        if wasSuspended != nil {
            // Still locked/backgrounded without PiP: suspend the newly muted slot immediately.
            let newlyMuted = nextSlot.other
            suspendedSlot = newlyMuted
            target?.setDualSlotSuspended(newlyMuted, suspended: true)
        }
    }

    /// Selects a discrete `A · Mix · B` preset. Pins the mix so subsequent focus taps preserve balance.
    public func selectPreset(_ preset: TwitchDualAudioPreset, animated: Bool = true) {
        isPinned = true
        balance = preset.balance
        if preset == .mix {
            resumeSuspendedSlotIfNeeded()
        }
        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
    }

    /// Continuously scrubs balance in `0.0...1.0`. Pins the mix so subsequent focus taps preserve balance.
    public func scrubBalance(to rawBalance: Double) {
        let clamped = min(max(rawBalance, 0.0), 1.0)
        isPinned = true
        balance = clamped
        if !gains.primaryMuted && !gains.secondaryMuted {
            resumeSuspendedSlotIfNeeded()
        }
        dispatchRamp(duration: Self.scrubRampDuration)
    }

    /// Unpins manual mix and smoothly returns audio to follow the focused stream.
    public func unpin(animated: Bool = true) {
        guard isPinned else { return }
        isPinned = false
        balance = focusedSlot == .primary ? 0.0 : 1.0
        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
    }

    /// Called when the app backgrounds / screen locks. When NOT in PiP, suspends whichever stream is muted
    /// immediately to save battery, thermal budget, and bandwidth.
    public func handleBackgrounded(isPiPActive: Bool) {
        guard !isPiPActive else { return }
        let g = gains
        let toSuspend: TwitchDualSlot?
        if g.secondaryMuted {
            toSuspend = .secondary
        } else if g.primaryMuted {
            toSuspend = .primary
        } else {
            toSuspend = nil
        }
        if let toSuspend, suspendedSlot != toSuspend {
            if let prior = suspendedSlot {
                target?.setDualSlotSuspended(prior, suspended: false)
            }
            suspendedSlot = toSuspend
            target?.setDualSlotSuspended(toSuspend, suspended: true)
        }
    }

    /// Called when returning to foreground (or when PiP begins while backgrounded): resumes any suspended slot.
    public func handleForegrounded() {
        resumeSuspendedSlotIfNeeded()
    }

    private func resumeSuspendedSlotIfNeeded() {
        guard let slot = suspendedSlot else { return }
        suspendedSlot = nil
        target?.setDualSlotSuspended(slot, suspended: false)
    }

    private func dispatchRamp(duration: TimeInterval) {
        let g = gains
        target?.applyDualAudioRamp(
            primaryGain: g.primary,
            secondaryGain: g.secondary,
            duration: duration,
            curve: .equalPower,
            updateMuteOnEndpoints: true
        )
    }
}

// MARK: - Multi-stream (2...4) Equal-Power Audio Mixer

/// Audio routing mode across 2...4 concurrent Twitch streams.
public enum TwitchMultiAudioMode: Sendable, Equatable {
    /// Audio automatically follows whichever stream is in spotlight (100% spotlight, 0% companions).
    case followSpotlight
    /// Audio is pinned exclusively to one slot regardless of visual spotlight swaps.
    case pinned(TwitchStreamSlot)
    /// Continuous multi-stream mix: per-slot raw weights in `0.0...1.0`, normalized with equal-power (`sum(g_i^2) == 1`).
    case multi(weights: [TwitchStreamSlot: Float])
}

/// Snapshot of normalized equal-power linear gains across active stream slots.
public struct TwitchMultiAudioGains: Sendable, Equatable {
    public var gains: [TwitchStreamSlot: Float]
    public var muted: [TwitchStreamSlot: Bool]

    public init(gains: [TwitchStreamSlot: Float], muted: [TwitchStreamSlot: Bool]) {
        self.gains = gains
        self.muted = muted
    }

    public func gain(for slot: TwitchStreamSlot) -> Float {
        gains[slot] ?? 0
    }

    public func isMuted(_ slot: TwitchStreamSlot) -> Bool {
        muted[slot] ?? true
    }

    /// Slots currently producing audio (`gain > 0` and not muted).
    public var audibleSlots: Set<TwitchStreamSlot> {
        Set(gains.compactMap { slot, g in
            (!isMuted(slot) && g > 0.001) ? slot : nil
        })
    }

    /// Strictly loudest audible slot (`nil` if all muted or top two are tied within `0.015`).
    public var louderSlot: TwitchStreamSlot? {
        let audible = gains
            .filter { !isMuted($0.key) && $0.value > 0.001 }
            .sorted { $0.value > $1.value }
        guard let top = audible.first else { return nil }
        if audible.count >= 2, top.value - audible[1].value <= 0.015 {
            return nil
        }
        return top.key
    }
}

/// Bridge from `TwitchMultiAudioMixer` to up to 4 live `TwitchNativeEngine` instances (mockable in unit tests).
@MainActor
public protocol TwitchMultiAudioTarget: AnyObject {
    func applyMultiAudioRamp(
        gains: [TwitchStreamSlot: Float],
        duration: TimeInterval,
        curve: TwitchVolumeRampCurve,
        updateMuteOnEndpoints: Bool
    )
    func setMultiSlotSuspended(_ slot: TwitchStreamSlot, suspended: Bool)
}

/// Generalized equal-power N-slot audio mixer (`1...4` streams) with Follow-Spotlight, Pin-to-Slot,
/// Multi-Mix equal-power normalization (`sum(g_i^2) == 1`), Lock Screen cycling, and background suspension.
@MainActor @Observable
public final class TwitchMultiAudioMixer {
    public static let defaultRampDuration: TimeInterval = 0.22
    public static let scrubRampDuration: TimeInterval = 0.04

    public private(set) var activeSlots: [TwitchStreamSlot] = [.a, .b]
    public private(set) var spotlightSlot: TwitchStreamSlot = .a
    public private(set) var mode: TwitchMultiAudioMode = .followSpotlight
    public private(set) var suspendedSlots: Set<TwitchStreamSlot> = []

    @ObservationIgnored public weak var target: (any TwitchMultiAudioTarget)?

    public init() {}

    /// True when audio is manually pinned or custom-mixed instead of following spotlight.
    public var isPinned: Bool {
        if case .followSpotlight = mode { return false }
        return true
    }

    /// Normalized equal-power gains across `activeSlots`.
    public var gains: TwitchMultiAudioGains {
        Self.equalPowerGains(activeSlots: activeSlots, spotlight: spotlightSlot, mode: mode)
    }

    /// Strictly loudest audible slot (`nil` when balanced or all muted).
    public var louderSlot: TwitchStreamSlot? { gains.louderSlot }

    /// Set of audible slots (`gain > 0` and unmuted).
    public var audibleSlots: Set<TwitchStreamSlot> { gains.audibleSlots }

    /// Alias for `audibleSlots` used by stage and floating panel mixer views.
    public var activeAudioSlots: Set<TwitchStreamSlot> { audibleSlots }

    /// Raw user slider weight in `0.0...1.0` for `slot` (reflects solo/pinned/multi state for mixer UI sliders).
    public func weight(for slot: TwitchStreamSlot) -> Float {
        switch mode {
        case .followSpotlight:
            return slot == spotlightSlot ? 1.0 : 0.0
        case .pinned(let pinned):
            return slot == pinned ? 1.0 : 0.0
        case .multi(let weights):
            return max(0, min(1, weights[slot] ?? 0))
        }
    }

    public func slotWeight(for slot: TwitchStreamSlot) -> Float { weight(for: slot) }
    public func followSpotlight(animated: Bool = true) { unpin(animated: animated) }
    public func mixAll(animated: Bool = true) { mixAllEqually(animated: animated) }
    public func solo(_ slot: TwitchStreamSlot, animated: Bool = true) { pinAudio(to: slot, animated: animated) }
    public func toggleAudio(for slot: TwitchStreamSlot, animated: Bool = true) { toggleInMix(slot, animated: animated) }
    public func setVolume(for slot: TwitchStreamSlot, to value: Float, scrubbing: Bool = true) {
        setMultiWeight(value, for: slot, scrubbing: scrubbing)
    }

    /// Computes equal-power normalized gains (`sum(g_i^2) == 1.0` whenever any slot is audible) so mixing
    /// 2, 3, or 4 streams never clips or dips perceptually.
    public static func equalPowerGains(
        activeSlots: [TwitchStreamSlot],
        spotlight: TwitchStreamSlot,
        mode: TwitchMultiAudioMode
    ) -> TwitchMultiAudioGains {
        var rawWeights: [TwitchStreamSlot: Float] = [:]
        for slot in activeSlots { rawWeights[slot] = 0 }

        switch mode {
        case .followSpotlight:
            if activeSlots.contains(spotlight) {
                rawWeights[spotlight] = 1.0
            } else if let first = activeSlots.first {
                rawWeights[first] = 1.0
            }
        case .pinned(let pinned):
            if activeSlots.contains(pinned) {
                rawWeights[pinned] = 1.0
            } else if activeSlots.contains(spotlight) {
                rawWeights[spotlight] = 1.0
            } else if let first = activeSlots.first {
                rawWeights[first] = 1.0
            }
        case .multi(let weights):
            for slot in activeSlots {
                let w = max(0, min(1, weights[slot] ?? 0))
                rawWeights[slot] = w < 0.001 ? 0 : w
            }
        }

        let sumSquares = rawWeights.values.reduce(Float(0)) { $0 + ($1 * $1) }
        var normalized: [TwitchStreamSlot: Float] = [:]
        var muted: [TwitchStreamSlot: Bool] = [:]

        if sumSquares <= 1e-6 {
            for slot in activeSlots {
                normalized[slot] = 0
                muted[slot] = true
            }
        } else {
            let denom = sqrt(sumSquares)
            for slot in activeSlots {
                let w = rawWeights[slot] ?? 0
                if w < 0.001 {
                    normalized[slot] = 0
                    muted[slot] = true
                } else {
                    let g = min(1.0, w / denom)
                    normalized[slot] = g >= 0.999 ? 1.0 : g
                    muted[slot] = false
                }
            }
        }

        return TwitchMultiAudioGains(gains: normalized, muted: muted)
    }

    /// Configures active slot count (`1...4`) while preserving any still-valid pin/multi weights.
    public func configure(slotCount: Int, spotlight: TwitchStreamSlot? = nil, animated: Bool = false) {
        let nextSlots = TwitchStreamSlot.slots(forCount: max(1, min(slotCount, 4)))
        let nextSlotSet = Set(nextSlots)
        // Resume/clear suspension tracking for removed slots
        for removed in suspendedSlots where !nextSlotSet.contains(removed) {
            suspendedSlots.remove(removed)
        }
        activeSlots = nextSlots
        if let spotlight, nextSlotSet.contains(spotlight) {
            spotlightSlot = spotlight
        } else if !nextSlotSet.contains(spotlightSlot) {
            spotlightSlot = nextSlots.first ?? .a
        }

        switch mode {
        case .followSpotlight:
            break
        case .pinned(let pinned):
            if !nextSlotSet.contains(pinned) {
                mode = .followSpotlight
            }
        case .multi(var weights):
            weights = weights.filter { nextSlotSet.contains($0.key) && $0.value > 0.001 }
            if weights.isEmpty {
                mode = .followSpotlight
            } else {
                mode = .multi(weights: weights)
            }
        }

        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
    }

    /// Resets back to Follow-Spotlight mode.
    public func reset(slotCount: Int, spotlight: TwitchStreamSlot = .a, animated: Bool = false) {
        resumeAllSuspended()
        activeSlots = TwitchStreamSlot.slots(forCount: max(1, min(slotCount, 4)))
        spotlightSlot = activeSlots.contains(spotlight) ? spotlight : (activeSlots.first ?? .a)
        mode = .followSpotlight
        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
    }

    /// Re-applies current gains to `target` (e.g. after a newly added stream finishes attaching).
    public func syncToTarget(animated: Bool = false) {
        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
    }

    /// Updates visual spotlight slot; follows audio automatically unless pinned or multi-mixed.
    public func setSpotlight(_ slot: TwitchStreamSlot, animated: Bool = true) {
        guard activeSlots.contains(slot) else { return }
        let changed = spotlightSlot != slot
        spotlightSlot = slot
        guard case .followSpotlight = mode else { return }
        if changed {
            resumeSlotIfSuspended(slot)
            dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
        }
    }

    /// Pins exclusive audio to `slot` regardless of visual spotlight changes.
    public func pinAudio(to slot: TwitchStreamSlot, animated: Bool = true) {
        guard activeSlots.contains(slot) else { return }
        mode = .pinned(slot)
        resumeSlotIfSuspended(slot)
        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
    }

    /// Unpins manual audio routing and smoothly returns to following the spotlight slot.
    public func unpin(animated: Bool = true) {
        guard isPinned else { return }
        mode = .followSpotlight
        resumeSlotIfSuspended(spotlightSlot)
        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
    }

    /// Adjusts an individual stream's mix weight in `0.0...1.0` (continuous multi-stream mixer).
    public func setMultiWeight(_ rawWeight: Float, for slot: TwitchStreamSlot, scrubbing: Bool = false) {
        guard activeSlots.contains(slot) else { return }
        let clamped = max(0, min(1, rawWeight))
        var weights: [TwitchStreamSlot: Float]
        switch mode {
        case .multi(let existing):
            weights = existing
        case .followSpotlight:
            weights = [spotlightSlot: 1.0]
        case .pinned(let pinned):
            weights = [pinned: 1.0]
        }
        weights[slot] = clamped < 0.001 ? 0 : clamped
        mode = .multi(weights: weights)
        if clamped >= 0.001 {
            resumeSlotIfSuspended(slot)
        }
        dispatchRamp(duration: scrubbing ? Self.scrubRampDuration : Self.defaultRampDuration)
    }

    /// Toggles `slot` in/out of the active multi-stream mix (keeping at least one slot audible when possible).
    public func toggleInMix(_ slot: TwitchStreamSlot, animated: Bool = true) {
        guard activeSlots.contains(slot) else { return }
        let current = weight(for: slot)
        if current > 0.001 {
            // If this is the only audible slot, mute it cleanly to 0; otherwise drop it from the mix.
            setMultiWeight(0, for: slot, scrubbing: false)
        } else {
            setMultiWeight(1.0, for: slot, scrubbing: false)
        }
        if !animated {
            dispatchRamp(duration: 0)
        }
    }

    /// Sets a balanced N-way equal-power mix across all active slots.
    public func mixAllEqually(animated: Bool = true) {
        var weights: [TwitchStreamSlot: Float] = [:]
        for slot in activeSlots { weights[slot] = 1.0 }
        mode = .multi(weights: weights)
        resumeAllSuspended()
        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
    }

    /// Sets continuous 2-stream balance in `0.0...1.0` (matches `A · Mix · B` equal-power curve for N=2).
    public func setDualBalance(_ rawBalance: Double, scrubbing: Bool = false) {
        let g = TwitchDualAudioMixer.equalPowerGains(for: rawBalance)
        if g.secondaryMuted {
            mode = .pinned(.a)
        } else if g.primaryMuted {
            mode = .pinned(.b)
        } else {
            mode = .multi(weights: [.a: g.primary, .b: g.secondary])
            resumeSlotIfSuspended(.a)
            resumeSlotIfSuspended(.b)
        }
        dispatchRamp(duration: scrubbing ? Self.scrubRampDuration : Self.defaultRampDuration)
    }

    /// Cycles audio & spotlight focus across active slots for Lock Screen next/previous track commands.
    public func cycleAudioFocusForRemoteCommand(forward: Bool = true, animated: Bool = true) {
        guard activeSlots.count >= 2 else { return }
        let anchor = louderSlot ?? spotlightSlot
        let nextSlot = forward
            ? anchor.next(inCount: activeSlots.count)
            : anchor.previous(inCount: activeSlots.count)
        let hadSuspended = !suspendedSlots.isEmpty
        resumeSlotIfSuspended(nextSlot)
        spotlightSlot = nextSlot
        mode = .followSpotlight
        dispatchRamp(duration: animated ? Self.defaultRampDuration : 0)
        if hadSuspended {
            // Still locked/backgrounded without PiP: suspend all newly muted slots immediately.
            let newlyMuted = Set(activeSlots.filter { $0 != nextSlot })
            applySuspensions(newlyMuted)
        }
    }

    /// Suspends every muted stream immediately when backgrounded without PiP (or any muted non-PiP slot).
    public func handleBackgrounded(isPiPActive: Bool, pipSlots: Set<TwitchStreamSlot> = []) {
        let currentGains = gains
        var toSuspend = Set<TwitchStreamSlot>()
        for slot in activeSlots {
            let isMuted = currentGains.isMuted(slot)
            if !isPiPActive {
                if isMuted { toSuspend.insert(slot) }
            } else if !pipSlots.contains(slot) && isMuted {
                toSuspend.insert(slot)
            }
        }
        applySuspensions(toSuspend)
    }

    /// Resumes all suspended slots when returning to foreground.
    public func handleForegrounded() {
        resumeAllSuspended()
    }

    private func resumeSlotIfSuspended(_ slot: TwitchStreamSlot) {
        guard suspendedSlots.remove(slot) != nil else { return }
        target?.setMultiSlotSuspended(slot, suspended: false)
    }

    private func resumeAllSuspended() {
        guard !suspendedSlots.isEmpty else { return }
        let toResume = suspendedSlots
        suspendedSlots.removeAll()
        for slot in toResume {
            target?.setMultiSlotSuspended(slot, suspended: false)
        }
    }

    private func applySuspensions(_ desired: Set<TwitchStreamSlot>) {
        let toResume = suspendedSlots.subtracting(desired)
        let toSuspend = desired.subtracting(suspendedSlots)
        suspendedSlots = desired
        for slot in toResume {
            target?.setMultiSlotSuspended(slot, suspended: false)
        }
        for slot in toSuspend {
            target?.setMultiSlotSuspended(slot, suspended: true)
        }
    }

    private func dispatchRamp(duration: TimeInterval) {
        let g = gains
        target?.applyMultiAudioRamp(
            gains: g.gains,
            duration: duration,
            curve: .equalPower,
            updateMuteOnEndpoints: true
        )
    }
}

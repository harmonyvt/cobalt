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

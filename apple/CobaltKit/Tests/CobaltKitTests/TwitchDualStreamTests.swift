import CoreGraphics
import Foundation
import Testing
@testable import CobaltKit

@MainActor
private final class SpyDualAudioTarget: TwitchDualAudioTarget {
    struct RampCall: Equatable {
        let primaryGain: Float
        let secondaryGain: Float
        let duration: TimeInterval
        let curve: TwitchVolumeRampCurve
        let updateMuteOnEndpoints: Bool
    }

    struct SuspendCall: Equatable {
        let slot: TwitchDualSlot
        let suspended: Bool
    }

    var ramps: [RampCall] = []
    var suspends: [SuspendCall] = []

    func applyDualAudioRamp(
        primaryGain: Float,
        secondaryGain: Float,
        duration: TimeInterval,
        curve: TwitchVolumeRampCurve,
        updateMuteOnEndpoints: Bool
    ) {
        ramps.append(RampCall(
            primaryGain: primaryGain,
            secondaryGain: secondaryGain,
            duration: duration,
            curve: curve,
            updateMuteOnEndpoints: updateMuteOnEndpoints
        ))
    }

    func setDualSlotSuspended(_ slot: TwitchDualSlot, suspended: Bool) {
        suspends.append(SuspendCall(slot: slot, suspended: suspended))
    }
}

@Suite struct TwitchDualStreamTests {

    // MARK: - Equal-Power Audio Law & Crossfader Mixer

    @Test @MainActor func equalPowerLawMaintainsConstantAcousticPower() {
        let samples: [Double] = [0.0, 0.15, 0.25, 0.5, 0.75, 0.85, 1.0]
        for balance in samples {
            let gains = TwitchDualAudioMixer.equalPowerGains(for: balance)
            let power = Double(gains.primary * gains.primary + gains.secondary * gains.secondary)
            #expect(abs(power - 1.0) < 0.001, "Expected gA² + gB² ≈ 1 at balance \(balance), got \(power)")
        }

        let primaryOnly = TwitchDualAudioMixer.equalPowerGains(for: 0.0)
        #expect(primaryOnly.primary == 1.0)
        #expect(primaryOnly.secondary == 0.0)
        #expect(primaryOnly.primaryMuted == false)
        #expect(primaryOnly.secondaryMuted == true)

        let mix = TwitchDualAudioMixer.equalPowerGains(for: 0.5)
        #expect(abs(mix.primary - 0.7071) < 0.002)
        #expect(abs(mix.secondary - 0.7071) < 0.002)
        #expect(mix.primaryMuted == false)
        #expect(mix.secondaryMuted == false)

        let secondaryOnly = TwitchDualAudioMixer.equalPowerGains(for: 1.0)
        #expect(secondaryOnly.primary == 0.0)
        #expect(secondaryOnly.secondary == 1.0)
        #expect(secondaryOnly.primaryMuted == true)
        #expect(secondaryOnly.secondaryMuted == false)
    }

    @Test @MainActor func followFocusUntilPinnedThenUnpinRestoresFollowFocus() {
        let spy = SpyDualAudioTarget()
        let mixer = TwitchDualAudioMixer()
        mixer.target = spy

        #expect(mixer.isPinned == false)
        #expect(mixer.balance == 0.0)
        #expect(mixer.louderSlot == .primary)

        // Focus swap follows focus automatically when unpinned
        mixer.swapFocus()
        #expect(mixer.focusedSlot == .secondary)
        #expect(mixer.balance == 1.0)
        #expect(mixer.louderSlot == .secondary)
        #expect(spy.ramps.last?.curve == .equalPower)
        #expect(spy.ramps.last?.updateMuteOnEndpoints == true)

        // Manual preset pins audio so subsequent focus changes do NOT move audio
        mixer.selectPreset(.mix)
        #expect(mixer.isPinned == true)
        #expect(mixer.balance == 0.5)
        #expect(mixer.louderSlot == nil) // Never two equal speaker badges at 50/50 mix

        mixer.setFocus(.primary)
        #expect(mixer.focusedSlot == .primary)
        #expect(mixer.balance == 0.5) // Still pinned to Mix!
        #expect(mixer.isPinned == true)

        // Manual scrub keeps pin and tracks the louder stream strictly
        mixer.scrubBalance(to: 0.2)
        #expect(mixer.isPinned == true)
        #expect(mixer.louderSlot == .primary)
        mixer.scrubBalance(to: 0.8)
        #expect(mixer.louderSlot == .secondary)

        // Unpin immediately snaps back to focused slot (.primary)
        mixer.unpin()
        #expect(mixer.isPinned == false)
        #expect(mixer.balance == 0.0)
        #expect(mixer.louderSlot == .primary)
    }

    @Test @MainActor func remoteTrackSwapUnpinsAndSwapsAudioFocus() {
        let spy = SpyDualAudioTarget()
        let mixer = TwitchDualAudioMixer()
        mixer.target = spy

        mixer.selectPreset(.mix)
        #expect(mixer.isPinned == true)

        // From Mix (neither louder), Lock Screen Next Track swaps to the opposite of focusedSlot (.secondary)
        mixer.swapAudioFocusForRemoteCommand()
        #expect(mixer.focusedSlot == .secondary)
        #expect(mixer.isPinned == false)
        #expect(mixer.balance == 1.0)
        #expect(mixer.louderSlot == .secondary)

        // Calling again swaps back to .primary
        mixer.swapAudioFocusForRemoteCommand()
        #expect(mixer.focusedSlot == .primary)
        #expect(mixer.balance == 0.0)
    }

    @Test @MainActor func lockScreenSuspendsMutedSecondaryOnlyWhenNotInPiP() {
        let spy = SpyDualAudioTarget()
        let mixer = TwitchDualAudioMixer()
        mixer.target = spy

        // Primary audible, secondary muted; screen locks WITHOUT PiP -> secondary suspended immediately
        mixer.handleBackgrounded(isPiPActive: false)
        #expect(mixer.suspendedSlot == .secondary)
        #expect(spy.suspends.last == .init(slot: .secondary, suspended: true))

        // Foreground resumes the suspended slot
        mixer.handleForegrounded()
        #expect(mixer.suspendedSlot == nil)
        #expect(spy.suspends.last == .init(slot: .secondary, suspended: false))

        // When PiP IS active, neither stream is suspended
        spy.suspends.removeAll()
        mixer.handleBackgrounded(isPiPActive: true)
        #expect(mixer.suspendedSlot == nil)
        #expect(spy.suspends.isEmpty)

        // When in 50/50 Mix (both audible), neither stream is muted so neither is suspended
        mixer.selectPreset(.mix)
        mixer.handleBackgrounded(isPiPActive: false)
        #expect(mixer.suspendedSlot == nil)
        #expect(spy.suspends.isEmpty)
    }

    // MARK: - Opus 16:9 Split Axis & Inset Geometry Solver

    @Test func splitAxisIsHorizontalStrictlyWhenAspectExceeds16By9() {
        // Exact 16:9 -> vertical (strictly > 16/9 required)
        #expect(TwitchDualLayout.splitAxis(for: CGSize(width: 1600, height: 900)) == .vertical)
        // Duo Wide video stage (62% of ~1100 pt = ~682 x 760) -> vertical
        #expect(TwitchDualLayout.splitAxis(for: CGSize(width: 682, height: 760)) == .vertical)
        // Folded Outer portrait (402 x 360) -> vertical
        #expect(TwitchDualLayout.splitAxis(for: CGSize(width: 402, height: 360)) == .vertical)
        // Ultrawide / full-width landscape stage (900 x 380 -> 2.37 > 1.778) -> horizontal
        #expect(TwitchDualLayout.splitAxis(for: CGSize(width: 900, height: 380)) == .horizontal)
        // 32:9 macOS floating panel (768 x 216 -> 3.55 > 1.778) -> horizontal
        #expect(TwitchDualLayout.splitAxis(for: CGSize(width: 768, height: 216)) == .horizontal)
    }

    @Test func verticalStackDeliversMoreVideoAreaThanHorizontalWhenAspectAtOrBelow16By9() {
        let duoWideStage = CGSize(width: 682, height: 760)
        let verticalArea = TwitchDualLayout.tileVideoArea(stageSize: duoWideStage, axis: .vertical)
        let horizontalArea = TwitchDualLayout.tileVideoArea(stageSize: duoWideStage, axis: .horizontal)
        #expect(verticalArea > horizontalArea)

        let ultrawideStage = CGSize(width: 1200, height: 420)
        let ultraH = TwitchDualLayout.tileVideoArea(stageSize: ultrawideStage, axis: .horizontal)
        let ultraV = TwitchDualLayout.tileVideoArea(stageSize: ultrawideStage, axis: .vertical)
        #expect(ultraH > ultraV)
    }

    @Test func insetSizeMaintains16By9AndAtLeast44PtHitHeight() {
        let small = TwitchDualLayout.insetSize(for: CGSize(width: 320, height: 200))
        #expect(small.height >= 44)
        #expect(abs((small.width / small.height) - (16.0 / 9.0)) < 0.05)

        let wide = TwitchDualLayout.insetSize(for: CGSize(width: 1000, height: 600))
        #expect(wide.width <= 260)
        #expect(wide.height >= 44)
        #expect(abs((wide.width / wide.height) - (16.0 / 9.0)) < 0.05)
    }

    @Test func heroAndInsetFollowsFocus() {
        let primaryFocus = TwitchDualLayout.heroAndInset(focused: .primary)
        #expect(primaryFocus.hero == .primary && primaryFocus.inset == .secondary)
        let secondaryFocus = TwitchDualLayout.heroAndInset(focused: .secondary)
        #expect(secondaryFocus.hero == .secondary && secondaryFocus.inset == .primary)
    }

    // MARK: - PaneItem.dualStream & PaneMachine Seamless Promotion / Demotion

    @Test func paneItemDualStreamPromotionDemotionAndProperties() throws {
        let single = PaneItem.stream("yawning")
        let dual = try #require(single.promotedToDual(secondary: "onigiri"))
        #expect(dual == .dualStream(primary: "yawning", secondary: "onigiri"))
        #expect(dual.keepsRunning == true)
        #expect(dual.barRank == 1)
        #expect(dual.isStream == true)
        #expect(dual.streamChannels == ["yawning", "onigiri"])

        // Promoting with the same channel returns nil
        #expect(single.promotedToDual(secondary: "YAWNING") == nil)

        // Demotion keeps chosen channel
        #expect(dual.demotedToSingle(keeping: "onigiri") == .stream("onigiri"))
        #expect(dual.demotedToSingle(keeping: "yawning") == .stream("yawning"))
    }

    @Test func paneMachinePromotesAndDemotesDualStreamWithoutGhostBar() {
        var m = PaneMachine()
        m.open(.stream("yawning"))
        m.setRunning(true, for: .stream("yawning"))
        #expect(m.isRunning == true)
        #expect(m.background == nil)

        // 1 -> 2 promotion keeps pane running and does NOT push old single stream into the mini bar
        m.open(.dualStream(primary: "yawning", secondary: "onigiri"))
        #expect(m.item == .dualStream(primary: "yawning", secondary: "onigiri"))
        #expect(m.isRunning == true)
        #expect(m.background == nil)
        #expect(m.barItem == nil)

        // Minimizing dual-stream goes cleanly to the bar
        m.close()
        #expect(m.state == .bar)
        #expect(m.barItem == .dualStream(primary: "yawning", secondary: "onigiri"))

        // Re-opening & demoting 2 -> 1 keeps pane running with zero ghost bar
        m.tapBar()
        m.open(.stream("onigiri"))
        #expect(m.item == .stream("onigiri"))
        #expect(m.isRunning == true)
        #expect(m.background == nil)
    }
}

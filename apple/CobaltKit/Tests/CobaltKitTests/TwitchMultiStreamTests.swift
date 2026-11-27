import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import CobaltKit

@MainActor
private final class SpyMultiAudioTarget: TwitchMultiAudioTarget {
    struct RampCall: Equatable {
        let gains: [TwitchStreamSlot: Float]
        let duration: TimeInterval
        let curve: TwitchVolumeRampCurve
        let updateMuteOnEndpoints: Bool
    }

    struct SuspendCall: Equatable {
        let slot: TwitchStreamSlot
        let suspended: Bool
    }

    var ramps: [RampCall] = []
    var suspends: [SuspendCall] = []

    func applyMultiAudioRamp(
        gains: [TwitchStreamSlot: Float],
        duration: TimeInterval,
        curve: TwitchVolumeRampCurve,
        updateMuteOnEndpoints: Bool
    ) {
        ramps.append(RampCall(
            gains: gains,
            duration: duration,
            curve: curve,
            updateMuteOnEndpoints: updateMuteOnEndpoints
        ))
    }

    func setMultiSlotSuspended(_ slot: TwitchStreamSlot, suspended: Bool) {
        suspends.append(SuspendCall(slot: slot, suspended: suspended))
    }
}

@Suite struct TwitchMultiStreamTests {

    // MARK: - PaneItem 1...4 Stream Transitions & Coding

    @Test func paneItemPromotesDemotesReplacesAndCapsAtFour() throws {
        let single = PaneItem.stream("alpha")
        #expect(single.isStream == true)
        #expect(single.keepsRunning == true)
        #expect(single.barRank == 1)
        #expect(single.streamChannels == ["alpha"])

        // 1 -> 2
        let dual = try #require(single.addingStream("Beta"))
        #expect(dual == .dualStream(primary: "alpha", secondary: "beta"))
        #expect(dual.addingStream("alpha") == nil) // duplicate rejected

        // 2 -> 3
        let triple = try #require(dual.addingStream("gamma"))
        #expect(triple == .multiStream(channels: ["alpha", "beta", "gamma"]))
        #expect(triple.kind == "multiStream")
        #expect(triple.keepsRunning == true)
        #expect(triple.barRank == 1)

        // 3 -> 4
        let quad = try #require(triple.addingStream("delta"))
        #expect(quad == .multiStream(channels: ["alpha", "beta", "gamma", "delta"]))

        // 4 -> 5 rejected at cap
        #expect(quad.addingStream("epsilon") == nil)

        // Replace slot 2 (gamma -> zeta)
        let replaced = try #require(quad.replacingStream(at: 2, with: "Zeta"))
        #expect(replaced == .multiStream(channels: ["alpha", "beta", "zeta", "delta"]))
        #expect(quad.replacingStream(at: 2, with: "alpha") == nil) // already active

        // 4 -> 3 -> 2 -> 1 -> nil
        let back3 = try #require(replaced.removingStream("beta"))
        #expect(back3 == .multiStream(channels: ["alpha", "zeta", "delta"]))
        let back2 = try #require(back3.removingStream("zeta"))
        #expect(back2 == .dualStream(primary: "alpha", secondary: "delta"))
        let back1 = try #require(back2.removingStream("alpha"))
        #expect(back1 == .stream("delta"))
        #expect(back1.removingStream("delta") == nil)

        // Keep only from 4-stream jumps directly to single stream
        #expect(quad.demotedToSingle(keeping: "gamma") == .stream("gamma"))
        #expect(quad.demotedToSingle(keeping: "missing") == nil)

        // Canonical factory deduplicates and caps at 4
        #expect(PaneItem.streams(["A", "a", "B", "C", "D", "E"]) == .multiStream(channels: ["a", "b", "c", "d"]))
        #expect(PaneItem.streams([]) == nil)
    }

    @Test func paneItemMultiStreamCodableRoundTripAndValidation() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let triple = PaneItem.multiStream(channels: ["shroud", "summit1g", "hasanabi"])
        let tripleData = try encoder.encode(triple)
        let decodedTriple = try decoder.decode(PaneItem.self, from: tripleData)
        #expect(decodedTriple == triple)

        let quad = PaneItem.multiStream(channels: ["a", "b", "c", "d"])
        let quadData = try encoder.encode(quad)
        let decodedQuad = try decoder.decode(PaneItem.self, from: quadData)
        #expect(decodedQuad == quad)

        // Reject invalid payloads with duplicates or fewer than 3 channels
        let badJSON = Data(#"{"kind":"multiStream","channels":["a","a","b"]}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(PaneItem.self, from: badJSON)
        }
    }

    // MARK: - TwitchMultiLayout Geometry & Duo Crease Safety

    @Test func multiLayoutGridKindAndDuoCreaseSafety() {
        let portrait = CGSize(width: 390, height: 700)
        let landscape = CGSize(width: 1200, height: 700)
        let duoSquare = CGSize(width: 820, height: 800)

        // 2 streams preserve 16:9 side-by-side threshold
        #expect(TwitchMultiLayout.gridKind(count: 2, stageSize: landscape) == .splitVertical)
        #expect(TwitchMultiLayout.gridKind(count: 2, stageSize: CGSize(width: 1400, height: 700)) == .splitHorizontal)

        // 3 streams: portrait -> mosaicThree, wide -> duoFoldSafeThree, Duo crease ALWAYS duoFoldSafeThree
        #expect(TwitchMultiLayout.gridKind(count: 3, stageSize: portrait, hasVerticalCrease: false) == .mosaicThree)
        #expect(TwitchMultiLayout.gridKind(count: 3, stageSize: landscape, hasVerticalCrease: false) == .duoFoldSafeThree)
        #expect(TwitchMultiLayout.gridKind(count: 3, stageSize: duoSquare, hasVerticalCrease: true) == .duoFoldSafeThree)

        // 4 streams ALWAYS 2x2 quadGrid
        #expect(TwitchMultiLayout.gridKind(count: 4, stageSize: portrait, hasVerticalCrease: false) == .quadGrid)
        #expect(TwitchMultiLayout.gridKind(count: 4, stageSize: duoSquare, hasVerticalCrease: true) == .quadGrid)
    }

    @Test func multiLayoutSpotlightDockAndHeroFraction() {
        let portrait = CGSize(width: 390, height: 700)
        let wide = CGSize(width: 1280, height: 720)
        let duoOpen = CGSize(width: 820, height: 800)

        #expect(TwitchMultiLayout.spotlightDock(count: 3, stageSize: portrait, hasVerticalCrease: false) == .bottomRow)
        #expect(TwitchMultiLayout.spotlightDock(count: 3, stageSize: wide, hasVerticalCrease: false) == .trailingColumn)
        #expect(TwitchMultiLayout.spotlightDock(count: 3, stageSize: duoOpen, hasVerticalCrease: true) == .trailingColumn)

        // On iPhone Duo with vertical crease, spotlight hero split locks cleanly to 50% center crease
        #expect(TwitchMultiLayout.spotlightHeroFraction(count: 3, dock: .trailingColumn, hasVerticalCrease: true) == 0.50)
        #expect(TwitchMultiLayout.spotlightHeroFraction(count: 4, dock: .trailingColumn, hasVerticalCrease: true) == 0.50)

        // Non-Duo hero takes majority of the stage
        #expect(TwitchMultiLayout.spotlightHeroFraction(count: 3, dock: .trailingColumn, hasVerticalCrease: false) > 0.60)
        #expect(TwitchMultiLayout.spotlightHeroFraction(count: 4, dock: .trailingColumn, hasVerticalCrease: false) > 0.65)
    }

    @Test func streamSlotWrappingAcrossCounts() {
        #expect(TwitchStreamSlot.a.next(inCount: 3) == .b)
        #expect(TwitchStreamSlot.b.next(inCount: 3) == .c)
        #expect(TwitchStreamSlot.c.next(inCount: 3) == .a)
        #expect(TwitchStreamSlot.a.previous(inCount: 3) == .c)

        #expect(TwitchStreamSlot.c.next(inCount: 4) == .d)
        #expect(TwitchStreamSlot.d.next(inCount: 4) == .a)
        #expect(TwitchStreamSlot.a.previous(inCount: 4) == .d)
    }

    // MARK: - Quality Budget Policy

    @Test func qualityBudgetPolicySelectsCorrectVariantsUnderNormalAndThermalLoad() {
        let baseURL = URL(string: "https://example.invalid/live.m3u8")!
        let variants: [TwitchVariant] = [
            TwitchVariant(id: "chunked", name: "1080p60 (source)", bandwidth: 6_500_000, width: 1920, height: 1080, frameRate: 60, codecs: "avc1.64002a,mp4a.40.2", url: baseURL),
            TwitchVariant(id: "720p60", name: "720p60", bandwidth: 3_500_000, width: 1280, height: 720, frameRate: 60, codecs: "avc1.4d4020,mp4a.40.2", url: baseURL),
            TwitchVariant(id: "720p30", name: "720p", bandwidth: 2_300_000, width: 1280, height: 720, frameRate: 30, codecs: "avc1.4d401f,mp4a.40.2", url: baseURL),
            TwitchVariant(id: "480p60", name: "480p60", bandwidth: 1_800_000, width: 852, height: 480, frameRate: 60, codecs: "avc1.4d401f,mp4a.40.2", url: baseURL),
            TwitchVariant(id: "480p30", name: "480p", bandwidth: 1_200_000, width: 852, height: 480, frameRate: 30, codecs: "avc1.4d401f,mp4a.40.2", url: baseURL),
            TwitchVariant(id: "360p30", name: "360p", bandwidth: 650_000, width: 640, height: 360, frameRate: 30, codecs: "avc1.4d401e,mp4a.40.2", url: baseURL),
            TwitchVariant(id: "audio_only", name: "audio_only", bandwidth: 160_000, width: nil, height: nil, frameRate: nil, codecs: "mp4a.40.2", url: baseURL),
        ]

        // 1 & 2 streams nominal -> source
        #expect(TwitchQualityBudgetPolicy.maxHeight(streamCount: 1, isSpotlight: true, isThermalThrottled: false) == nil)
        #expect(TwitchQualityBudgetPolicy.maxHeight(streamCount: 2, isSpotlight: false, isThermalThrottled: false) == nil)

        // 3–4 streams nominal -> spotlight 1080p60, companions 480p30 (prefers 30fps over 60fps!)
        let spot3 = TwitchQualityBudgetPolicy.preferredVariant(from: variants, streamCount: 3, isSpotlight: true, isThermalThrottled: false)
        #expect(spot3?.id == "chunked")

        let comp3 = TwitchQualityBudgetPolicy.preferredVariant(from: variants, streamCount: 3, isSpotlight: false, isThermalThrottled: false)
        #expect(comp3?.id == "480p30")

        // 3–4 streams thermal throttled -> spotlight 720p30, companions 360p30
        let spotHot = TwitchQualityBudgetPolicy.preferredVariant(from: variants, streamCount: 4, isSpotlight: true, isThermalThrottled: true)
        #expect(spotHot?.id == "720p30")

        let compHot = TwitchQualityBudgetPolicy.preferredVariant(from: variants, streamCount: 4, isSpotlight: false, isThermalThrottled: true)
        #expect(compHot?.id == "360p30")

        // Fallback when only 1080p exists picks lowest available video variant rather than audio_only
        let onlyHigh = [variants[0], variants[6]]
        let fallback = TwitchQualityBudgetPolicy.preferredVariant(from: onlyHigh, streamCount: 4, isSpotlight: false, isThermalThrottled: true)
        #expect(fallback?.id == "chunked")
    }

    // MARK: - Equal-Power N-Slot Audio Mixer

    @Test @MainActor func multiAudioMixerMaintainsConstantEqualPowerInvariant() {
        let spy = SpyMultiAudioTarget()
        let mixer = TwitchMultiAudioMixer()
        mixer.target = spy
        mixer.reset(slotCount: 4, spotlight: .a)

        // Follow-spotlight: A=1, B/C/D=0
        #expect(mixer.gains.gain(for: .a) == 1.0)
        #expect(mixer.gains.isMuted(.b) == true)
        #expect(mixer.gains.isMuted(.c) == true)
        #expect(mixer.gains.isMuted(.d) == true)
        #expect(mixer.louderSlot == .a)

        // Mix all 4 equally -> each gain == 0.5, sum(g^2) == 1.0, no single louder badge
        mixer.mixAllEqually(animated: false)
        let quadGains = mixer.gains
        let quadPower = TwitchStreamSlot.allCases.reduce(Float(0)) { $0 + quadGains.gain(for: $1) * quadGains.gain(for: $1) }
        #expect(abs(quadPower - 1.0) < 0.001)
        for slot in TwitchStreamSlot.allCases {
            #expect(abs(quadGains.gain(for: slot) - 0.5) < 0.002)
            #expect(quadGains.isMuted(slot) == false)
        }
        #expect(mixer.louderSlot == nil)

        // Mix 3 equally -> each gain == 1/sqrt(3) ≈ 0.57735, sum(g^2) == 1.0
        mixer.configure(slotCount: 3, animated: false)
        let triGains = mixer.gains
        let triPower = [TwitchStreamSlot.a, .b, .c].reduce(Float(0)) { $0 + triGains.gain(for: $1) * triGains.gain(for: $1) }
        #expect(abs(triPower - 1.0) < 0.001)
        #expect(abs(triGains.gain(for: .a) - (1.0 / sqrt(3.0))) < 0.002)

        // Custom weighted mix preserves equal-power normalization and reports strictly loudest slot
        mixer.setMultiWeight(0.9, for: .b)
        mixer.setMultiWeight(0.3, for: .a)
        mixer.setMultiWeight(0.0, for: .c)
        let customGains = mixer.gains
        let customPower = [TwitchStreamSlot.a, .b, .c].reduce(Float(0)) { $0 + customGains.gain(for: $1) * customGains.gain(for: $1) }
        #expect(abs(customPower - 1.0) < 0.001)
        #expect(customGains.isMuted(.c) == true)
        #expect(mixer.louderSlot == .b)
    }

    @Test @MainActor func multiAudioMixerSpotlightPinningRemoteCycleAndBackgroundSuspension() {
        let spy = SpyMultiAudioTarget()
        let mixer = TwitchMultiAudioMixer()
        mixer.target = spy
        mixer.reset(slotCount: 3, spotlight: .a)

        // Unpinned spotlight change moves audio cleanly
        mixer.setSpotlight(.c)
        #expect(mixer.spotlightSlot == .c)
        #expect(mixer.louderSlot == .c)
        #expect(mixer.isPinned == false)

        // Pinning audio to B keeps audio on B even when spotlight moves to A
        mixer.pinAudio(to: .b)
        #expect(mixer.isPinned == true)
        #expect(mixer.louderSlot == .b)
        mixer.setSpotlight(.a)
        #expect(mixer.spotlightSlot == .a)
        #expect(mixer.louderSlot == .b)

        // Unpin snaps audio back to spotlight (.a)
        mixer.unpin()
        #expect(mixer.isPinned == false)
        #expect(mixer.louderSlot == .a)

        // Background without PiP suspends muted slots (.b and .c)
        mixer.handleBackgrounded(isPiPActive: false)
        #expect(mixer.suspendedSlots == [.b, .c])

        // Remote track next cycles .a -> .b while still locked: resumes .b, suspends .a & .c
        mixer.cycleAudioFocusForRemoteCommand(forward: true)
        #expect(mixer.spotlightSlot == .b)
        #expect(mixer.louderSlot == .b)
        #expect(mixer.suspendedSlots == [.a, .c])

        // Foreground resumes all suspended slots
        mixer.handleForegrounded()
        #expect(mixer.suspendedSlots.isEmpty)

        // Shrinking slot count drops an invalid pin back to followSpotlight
        mixer.pinAudio(to: .c)
        mixer.configure(slotCount: 2)
        #expect(mixer.isPinned == false)
        #expect(mixer.activeSlots == [.a, .b])
    }

    // MARK: - 4-Channel Chat Accents & 2-Letter Collision Disambiguation

    @Test func fourChannelChatAccentsAndTwoLetterInitialCollisionResolution() {
        let channels = ["shroud", "summit1g", "xqc", "hasanabi"]
        let displayNames = [
            "shroud": "Shroud",
            "summit1g": "Summit1g",
            "xqc": "xQc",
            "hasanabi": "HasanAbi",
        ]
        let accents = TwitchChannelAccent.resolvedAccents(for: channels, displayNames: displayNames)

        #expect(accents["shroud"]?.slot == .primary)
        #expect(accents["summit1g"]?.slot == .secondary)
        #expect(accents["xqc"]?.slot == .tertiary)
        #expect(accents["hasanabi"]?.slot == .quaternary)

        // Colliding leading initials ('S') expand to 2 letters while non-colliding stay crisp 1-letter marks
        #expect(accents["shroud"]?.mark == "SH")
        #expect(accents["summit1g"]?.mark == "SU")
        #expect(accents["xqc"]?.mark == "X")
        #expect(accents["hasanabi"]?.mark == "H")

        // Distinct accent colors for all 4 slots
        let darkRGBs = Set(channels.compactMap { accents[$0]?.darkRGB })
        #expect(darkRGBs.count == 4)
        #expect(accents["xqc"]?.darkRGB == TwitchChannelAccent.tertiaryDarkRGB)
        #expect(accents["hasanabi"]?.darkRGB == TwitchChannelAccent.quaternaryDarkRGB)
    }

    // MARK: - PlayerPool External Decoder Reservations & MotionBudget Throttling

    @Test @MainActor func playerPoolExternalDecoderReservationReducesCapAndPausesBackgroundPlayers() {
        let lifecycle = AppLifecycle()
        let pool = PlayerPool(lifecycle: lifecycle, cap: 4)
        let p1 = AVPlayer()
        let p2 = AVPlayer()

        pool.play(p1, as: .orbit)
        pool.play(p2, as: .orbit)
        #expect(pool.effectiveCap == 4)

        // Reserving 3 external Twitch decoders lowers AVPlayer cap to 1 and pauses oldest orbit player
        pool.reserveExternalDecoders(id: "twitch.multi", count: 3)
        #expect(pool.reservedExternalCount == 3)
        #expect(pool.effectiveCap == 1)

        // Reserving 4 decoders leaves 0 background AVPlayer slots
        pool.reserveExternalDecoders(id: "twitch.multi", count: 4)
        #expect(pool.effectiveCap == 0)

        // Releasing restores full cap
        pool.releaseExternalDecoders(id: "twitch.multi")
        #expect(pool.reservedExternalCount == 0)
        #expect(pool.effectiveCap == 4)
    }

    @Test @MainActor func motionBudgetThrottlesAnimatedEmotesForThreePlusStreams() {
        let phoneBudget = MotionBudget(limit: 10, watchPower: false)
        let tickets = (0..<10).map { _ in MotionTicket() }
        for t in tickets { phoneBudget.want(t, true) }
        #expect(phoneBudget.effectiveLimit == 10)
        #expect(phoneBudget.playingCount == 10)

        // 3+ streams throttles 10 -> 6 on phone-sized budgets
        phoneBudget.setActiveStreamCount(3)
        #expect(phoneBudget.effectiveLimit == 6)
        #expect(phoneBudget.playingCount == 6)

        // Dropping back to 2 restores full 10
        phoneBudget.setActiveStreamCount(2)
        #expect(phoneBudget.effectiveLimit == 10)
        #expect(phoneBudget.playingCount == 10)

        // Larger iPad/Mac budget (16) throttles 16 -> 10
        let macBudget = MotionBudget(limit: 16, watchPower: false)
        macBudget.setActiveStreamCount(4)
        #expect(macBudget.effectiveLimit == 10)
        macBudget.setActiveStreamCount(1)
        #expect(macBudget.effectiveLimit == 16)
    }
}

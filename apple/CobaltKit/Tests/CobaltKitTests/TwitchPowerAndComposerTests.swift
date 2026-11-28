import Foundation
import Testing
@testable import CobaltKit

@Suite("Twitch Power, Low Power Mode, ISO8601 & Composer Rules")
struct TwitchPowerAndComposerTests {

    private func makeVariant(
        id: String,
        height: Int,
        fps: Double,
        bandwidth: Int,
        isSource: Bool = false
    ) -> TwitchVariant {
        TwitchVariant(
            id: isSource ? "chunked" : id,
            name: isSource ? "\(height)p\(Int(fps)) (source)" : "\(height)p\(Int(fps))",
            bandwidth: bandwidth,
            width: height * 16 / 9,
            height: height,
            frameRate: fps,
            codecs: "avc1.64002a,mp4a.40.2",
            url: URL(string: "https://example.com/\(id).m3u8")!
        )
    }

    // MARK: - Quality Budget Policy (Thermal + Low Power Mode)

    @Test("Caps single-stream quality to 720p30 under Low Power Mode or thermal pressure")
    func singleStreamPowerBudget() {
        let variants = [
            makeVariant(id: "1080p60", height: 1080, fps: 60, bandwidth: 6_500_000, isSource: true),
            makeVariant(id: "720p60", height: 720, fps: 60, bandwidth: 3_500_000),
            makeVariant(id: "720p30", height: 720, fps: 30, bandwidth: 2_200_000),
            makeVariant(id: "480p30", height: 480, fps: 30, bandwidth: 1_200_000),
        ]

        // Nominal single stream: uncapped -> source
        #expect(TwitchQualityBudgetPolicy.maxHeight(streamCount: 1, isSpotlight: true, isThermalThrottled: false, isLowPowerMode: false) == nil)
        let nominal = TwitchQualityBudgetPolicy.preferredVariant(from: variants, streamCount: 1, isSpotlight: true, isThermalThrottled: false, isLowPowerMode: false)
        #expect(nominal?.id == "chunked")

        // Low Power Mode single stream: capped at 720p and prefers 30fps
        #expect(TwitchQualityBudgetPolicy.maxHeight(streamCount: 1, isSpotlight: true, isThermalThrottled: false, isLowPowerMode: true) == 720)
        #expect(TwitchQualityBudgetPolicy.preferLowerFrameRate(streamCount: 1, isSpotlight: true, isThermalThrottled: false, isLowPowerMode: true) == true)
        let lpm = TwitchQualityBudgetPolicy.preferredVariant(from: variants, streamCount: 1, isSpotlight: true, isThermalThrottled: false, isLowPowerMode: true)
        #expect(lpm?.id == "720p30")

        // Thermal throttled single stream: also capped at 720p30
        let thermal = TwitchQualityBudgetPolicy.preferredVariant(from: variants, streamCount: 1, isSpotlight: true, isThermalThrottled: true, isLowPowerMode: false)
        #expect(thermal?.id == "720p30")
    }

    @Test("Caps dual and multi-stream companions aggressively under Low Power Mode")
    func multiStreamPowerBudget() {
        let variants = [
            makeVariant(id: "1080p60", height: 1080, fps: 60, bandwidth: 6_500_000, isSource: true),
            makeVariant(id: "720p60", height: 720, fps: 60, bandwidth: 3_500_000),
            makeVariant(id: "720p30", height: 720, fps: 30, bandwidth: 2_200_000),
            makeVariant(id: "480p30", height: 480, fps: 30, bandwidth: 1_200_000),
            makeVariant(id: "360p30", height: 360, fps: 30, bandwidth: 650_000),
        ]

        // Dual companion in LPM -> 480p30
        let dualCompanion = TwitchQualityBudgetPolicy.preferredVariant(from: variants, streamCount: 2, isSpotlight: false, isThermalThrottled: false, isLowPowerMode: true)
        #expect(dualCompanion?.id == "480p30")

        // 3-stream companion in LPM -> 360p30
        let multiCompanion = TwitchQualityBudgetPolicy.preferredVariant(from: variants, streamCount: 3, isSpotlight: false, isThermalThrottled: false, isLowPowerMode: true)
        #expect(multiCompanion?.id == "360p30")

        // 3-stream spotlight nominal -> 1080p60; in LPM -> 720p30
        let multiSpotNominal = TwitchQualityBudgetPolicy.preferredVariant(from: variants, streamCount: 3, isSpotlight: true, isThermalThrottled: false, isLowPowerMode: false)
        #expect(multiSpotNominal?.id == "chunked")
        let multiSpotLPM = TwitchQualityBudgetPolicy.preferredVariant(from: variants, streamCount: 3, isSpotlight: true, isThermalThrottled: false, isLowPowerMode: true)
        #expect(multiSpotLPM?.id == "720p30")
    }

    // MARK: - MotionBudget Lifecycle Power Conservation

    @Test("MotionBudget pauses all tickets on Low Power Mode / serious thermal and restores on nominal active")
    @MainActor
    func motionBudgetConservesPower() {
        let budget = MotionBudget(limit: 4, watchPower: false)
        let ticket = MotionTicket()
        budget.want(ticket, true)
        #expect(ticket.granted == true)

        // Low Power Mode -> revokes slot immediately
        let lpmSnap = LifecycleSnapshot(phase: .active, thermal: .nominal, isLowPowerMode: true)
        budget.lifecycle(.lowPowerModeChanged(true), snapshot: lpmSnap)
        #expect(ticket.granted == false)

        // Exit LPM -> restores slot
        let nominalSnap = LifecycleSnapshot(phase: .active, thermal: .nominal, isLowPowerMode: false)
        budget.lifecycle(.lowPowerModeChanged(false), snapshot: nominalSnap)
        #expect(ticket.granted == true)

        // Serious thermal pressure -> revokes slot via shouldConservePower
        let hotSnap = LifecycleSnapshot(phase: .active, thermal: .serious, isLowPowerMode: false)
        budget.lifecycle(.thermalChanged(.serious), snapshot: hotSnap)
        #expect(hotSnap.shouldConservePower == true)
        #expect(ticket.granted == false)

        // Cooling back to fair -> restores slot
        let fairSnap = LifecycleSnapshot(phase: .active, thermal: .fair, isLowPowerMode: false)
        budget.lifecycle(.thermalChanged(.fair), snapshot: fairSnap)
        #expect(fairSnap.shouldConservePower == false)
        #expect(ticket.granted == true)
    }

    // MARK: - Fast ISO8601 Parser

    @Test("Fast ISO8601 parser matches Foundation ISO8601DateFormatter across UTC, fractional seconds, and offsets")
    func fastISO8601ParserAccuracy() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterNoFrac = ISO8601DateFormatter()
        formatterNoFrac.formatOptions = [.withInternetDateTime]

        let samples = [
            "2026-11-28T10:15:30Z",
            "2026-11-28T10:15:30.250Z",
            "2026-11-28T10:15:30.123456Z",
            "2024-02-29T23:59:59.500Z",
            "2026-11-28T21:15:30+11:00",
            "2026-11-28T05:15:30-05:00",
            "2026-11-28T10:15:30.75+00:00",
        ]

        for s in samples {
            let fast = TwitchHLSParser.parseISO8601(s)
            let ref = formatter.date(from: s) ?? formatterNoFrac.date(from: s)
            #expect(fast != nil, "Failed to parse: \(s)")
            #expect(ref != nil, "Reference failed to parse: \(s)")
            if let fast, let ref {
                #expect(abs(fast.timeIntervalSince1970 - ref.timeIntervalSince1970) < 0.001, "Mismatch for \(s)")
            }
        }

        #expect(TwitchHLSParser.parseISO8601("not-a-date") == nil)
        #expect(TwitchHLSParser.parseISO8601("2026-13-40T99:99:99Z") == nil)
    }

    // MARK: - Chat Composer Rules

    @Test("Chat composer rules enforce 500-char Twitch limit, collapse newlines, and handle emote token replacement")
    func chatComposerRules() {
        #expect(TwitchChatComposerRules.preparedForSend("  hello\nworld\r\nagain  ") == "hello world again")
        #expect(TwitchChatComposerRules.canSend("   \n  ") == false)
        #expect(TwitchChatComposerRules.canSend("hi") == true)

        let atLimit = String(repeating: "a", count: 500)
        #expect(TwitchChatComposerRules.characterCount(atLimit) == 500)
        #expect(TwitchChatComposerRules.remainingCharacters(atLimit) == 0)
        #expect(TwitchChatComposerRules.tone(for: atLimit) == .caution)
        #expect(TwitchChatComposerRules.canSend(atLimit) == true)

        let overLimit = String(repeating: "a", count: 501)
        #expect(TwitchChatComposerRules.remainingCharacters(overLimit) == -1)
        #expect(TwitchChatComposerRules.tone(for: overLimit) == .overLimit)
        #expect(TwitchChatComposerRules.canSend(overLimit) == false)

        #expect(TwitchChatComposerRules.currentToken(in: "hello\nKEK") == "KEK")
        #expect(TwitchChatComposerRules.replacingCurrentToken(in: "hello\nKEK", with: "KEKW") == "hello\nKEKW ")
    }
}

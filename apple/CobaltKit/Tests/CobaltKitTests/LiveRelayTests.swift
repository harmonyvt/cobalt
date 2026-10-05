import Foundation
import Synchronization
import Testing
@testable import CobaltKit

/// The share sheet's half of a Live Activity: registration with a push-to-start, the relay of the
/// device's own steps, and the server's quiet refusals (CONTRACT-LIVE.md 2.5, APP-API-CONTRACT.md 8.2).
@MainActor
struct ShareRig {
    let h: Harness
    let core: ShareCore
    let pipeline: Pipeline
    let log: LiveCallLog
    let notifier = FakeNotifier()

    init(
        _ scenario: PreviewScenario = .shortClip, push: Bool = true, environment: LiveEnvironment? = .sandbox, key: Bool = true,
        reply: @escaping @Sendable (LiveRunRegistration, Int) async throws -> LiveRunReply = { _, _ in
            LiveRunReply(pushing: true, started: true)
        }
    ) {
        h = Harness(scenario)
        log = LiveCallLog()
        h.ctx.capabilities.livePush = push
        if !key { h.ctx.settings.clearAPIKey() }
        h.ctx.client = recordingClient(over: h.ctx.client, log: log, reply: reply)
        pipeline = Pipeline(context: h.ctx)
        core = ShareCore(context: h.ctx, pipeline: pipeline, notifier: notifier, liveEnvironment: environment)
        core.complete = {}
        core.openApp = { _ in true }
    }

    func settle() async {
        await h.settle()
        await core.relay.settle()
    }

    func drive(_ condition: @escaping @MainActor () -> Bool) async {
        await h.drive(until: condition)
        await core.relay.settle()
    }

    var starts: [Bool] { log.runs.map(\.start) }
}

@MainActor
@Suite(.serialized)
struct ShareRelayTests {
    @Test func theRunIdIsTheJobIdAndTheFirstRegistrationAsksForAPushStart() async throws {
        let rig = ShareRig()
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.settle()
        #expect(rig.pipeline.liveRunID == rig.core.jobID)
        let first = try #require(rig.log.runs.first)
        #expect(first.start && first.updateToken == nil && first.environment == .sandbox)
        #expect(first.run == rig.core.jobID)
        #expect(first.attributes == LiveRunAttributes(
            run: rig.core.jobID, input: "link", service: "x", ref: "2105435404002562056", origin: "share"))
        #expect(first.state.stage == .fetching)
        #expect(rig.log.runs.dropFirst().allSatisfy { !$0.start }, "a start is asked for once")
        await rig.drive { rig.pipeline.state == .ready }
        #expect(rig.log.runs.last?.session == rig.pipeline.sessionID, "the server needs the session to map its events")
        #expect(rig.starts.filter { $0 }.count == 1)
    }

    @Test func onlyTheDeviceStepsAreRelayed() async throws {
        let rig = ShareRig()
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.drive { rig.pipeline.state == .ready }
        rig.pipeline.makeWebp()
        await rig.drive { if case .done = rig.pipeline.state { true } else { false } }
        let relayed = Set(rig.log.relays.map(\.stage))
        #expect(relayed.isSubset(of: [.uploading, .reading, .ready, .failed]), "\(relayed)")
        #expect(relayed.contains(.reading) && relayed.contains(.ready))
        #expect(rig.log.relays.last?.stage == .ready, "the server pushes the render and the result")
        // never twice in a row, and counters at most once a second
        for (a, b) in zip(rig.log.relays, rig.log.relays.dropFirst()) { #expect(a != b) }
        #expect(rig.log.relays.filter { $0.stage == .reading }.count < 9)
    }

    @Test func anUploadRegistersTheFileAndRelaysTheUpload() async throws {
        let rig = ShareRig(.happy)
        let file = try makeTempFile("IMG_0412.mov", bytes: 300_000)
        rig.pipeline.start(file: file)
        await rig.drive { rig.pipeline.state == .ready }
        let first = try #require(rig.log.runs.first)
        #expect(first.start && first.attributes.input == "file" && first.attributes.service == "file")
        #expect(first.attributes.ref == "IMG_0412.mov" && first.attributes.origin == "share")
        #expect(first.state.stage == .uploading && first.state.title == "IMG_0412")
        let stages = rig.log.relays.map(\.stage)
        #expect(stages.contains(.uploading) || first.state.stage == .uploading)
        #expect(stages.contains(.reading) && stages.contains(.ready))
    }

    @Test func aFailureIsRelayedSoTheServerEndsTheActivityWithIt() async throws {
        let rig = ShareRig(.renderLost)
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.drive { rig.pipeline.state == .ready }
        rig.pipeline.makeWebp()
        await rig.drive { if case .failed = rig.pipeline.state { true } else { false } }
        let last = try #require(rig.log.relays.last)
        #expect(last.stage == .failed && last.failure == "renderLost" && last.rail == 3)
    }

    @Test func aRunThatFailsAtOnceHasNoActivityToFail() async throws {
        let rig = ShareRig(.tooBig)
        let file = try makeTempFile("huge.mov", bytes: 200_000)
        rig.pipeline.start(file: file)
        await rig.drive { if case .failed = rig.pipeline.state { true } else { false } }
        #expect(rig.log.isEmpty)
    }

    @Test func startUnconfirmedIsNeverStartedAgain() async throws {
        let rig = ShareRig(reply: { _, _ in LiveRunReply(pushing: true, started: false, reason: "start_unconfirmed") })
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.drive { rig.pipeline.state == .ready }
        #expect(rig.starts.first == true)
        #expect(rig.starts.filter { $0 }.count == 1, "never a second start: it may already be on screen")
        #expect(rig.log.runs.count >= 2, "the session is still registered")
    }

    @Test func startRateLimitedBacksOffTenSecondsAndThenAsksAgain() async throws {
        let rig = ShareRig(reply: { r, n in
            n == 1 ? LiveRunReply(pushing: true, started: false, reason: "start_rate_limited") : LiveRunReply(pushing: true, started: true)
        })
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.drive { rig.pipeline.state == .ready }
        #expect(rig.starts.filter { $0 }.count == 1, "inside the window nothing asks again")
        let before = rig.h.clock.elapsed
        await rig.drive { rig.starts.filter { $0 }.count >= 2 }
        let starts = rig.log.runs.filter(\.start)
        #expect(starts.count == 2, "asked once more, after the key's window")
        #expect(rig.h.clock.elapsed - before >= 9 || rig.h.clock.elapsed >= 10.4)
        await rig.h.drive(until: { false }, maxVirtualSeconds: rig.h.clock.elapsed + 40)
        #expect(rig.log.runs.filter(\.start).count == 2, "once it started, no more")
    }

    @Test func startRateLimitedForeverGivesUpAfterAFewTries() async throws {
        let rig = ShareRig(reply: { _, _ in LiveRunReply(pushing: true, started: false, reason: "start_rate_limited") })
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.drive { rig.pipeline.state == .ready }
        await rig.h.drive(until: { false }, maxVirtualSeconds: rig.h.clock.elapsed + 80)
        await rig.core.relay.settle()
        #expect(rig.log.runs.filter(\.start).count == 1 + ShareLiveRelay.maxStartRetries)
    }

    @Test func tooManyRunsMeansNoActivityAndNothingMoreIsSent() async throws {
        let rig = ShareRig(reply: { _, _ in throw CobaltError.api(code: "error.live.too_many_runs", httpStatus: 429) })
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.drive { rig.pipeline.state == .ready }
        #expect(rig.log.runs.count == 1)
        #expect(rig.log.relays.isEmpty)
        #expect(rig.pipeline.state == .ready, "the run itself is untouched")
        #expect(await rig.core.close() == .dismissed)
        #expect(rig.log.ends.isEmpty, "the server never took the run")
    }

    @Test func aFailedRegistrationNeverStartsTwiceAndTheSheetCarriesOn() async throws {
        let rig = ShareRig(reply: { _, n in
            if n == 1 { throw CobaltError.network(.timedOut) }
            return LiveRunReply(pushing: true, started: false)
        })
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.drive { rig.pipeline.state == .ready }
        await rig.h.drive(until: { false }, maxVirtualSeconds: rig.h.clock.elapsed + 12)
        #expect(rig.log.runs.filter(\.start).count == 1, "after an error the outcome of a start is unknown")
        #expect(rig.pipeline.state == .ready)
    }

    @Test func closingTheSheetMidSaveEndsTheRunOnTheServer() async throws {
        let rig = ShareRig()
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.drive { rig.pipeline.state == .ready }
        let result = await rig.core.close()
        #expect(result == .dismissed)
        #expect(rig.log.ends == [rig.core.jobID])
    }

    @Test func closingMidRenderLeavesTheRunToTheServer() async throws {
        let rig = ShareRig()
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.drive { rig.pipeline.state == .ready }
        rig.pipeline.makeWebp()
        await rig.drive { rig.pipeline.renderJobID != nil }
        let result = await rig.core.close()
        #expect(result == .continuesInBackground)
        #expect(rig.log.ends.isEmpty)
        let count = rig.log.all.count
        await rig.h.drive(until: { false }, maxVirtualSeconds: rig.h.clock.elapsed + 5)
        #expect(rig.log.all.count == count, "a detached sheet sends nothing more")
    }

    @Test func trimInCobaltLeavesTheRunToTheApp() async throws {
        let rig = ShareRig()
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.drive { rig.pipeline.state == .ready }
        await rig.core.handOffToApp()
        #expect(rig.log.ends.isEmpty)
        let job = try #require(rig.h.ctx.jobs.all().first)
        #expect(job.id == rig.core.jobID, "the app adopts this id as the run id")
    }

    @Test func nothingIsSentWhenTheServerCannotPushOrTheBuildCannotReceiveOrThereIsNoKey() async throws {
        for rig in [ShareRig(push: false), ShareRig(environment: nil), ShareRig(key: false)] {
            rig.pipeline.start(link: URL(string: shortLink)!)
            await rig.drive { rig.pipeline.state == .ready }
            _ = await rig.core.close()
            #expect(rig.log.isEmpty)
        }
    }

    @Test func capabilitiesThatArriveAfterTheFirstStateStillStartTheActivity() async throws {
        let rig = ShareRig(push: false)
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.settle()
        #expect(rig.log.isEmpty)
        rig.h.ctx.capabilities.livePush = true
        rig.h.ctx.capabilitiesChanged?(rig.h.ctx.capabilities)       // what `refreshCapabilities` does
        await rig.settle()
        #expect(rig.log.runs.first?.start == true)
    }

    @Test func aRunThatIsAlreadyOverStartsNoActivity() async throws {
        let rig = ShareRig(push: false)
        rig.pipeline.start(pastedText: "no link in here")
        await rig.settle()
        rig.h.ctx.capabilities.livePush = true
        rig.h.ctx.capabilitiesChanged?(rig.h.ctx.capabilities)
        await rig.settle()
        #expect(rig.log.isEmpty)
    }
}

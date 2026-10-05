import Foundation
import Synchronization
import Testing
@testable import CobaltKit

// MARK: - The state builder (CONTRACT-LIVE.md 2.3, parity with the fixture of 2.4)

private func fixture() throws -> [String: LiveContentState] {
    let url = try #require(Bundle.module.url(forResource: "live-states", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode([String: LiveContentState].self, from: try Data(contentsOf: url))
}

private let clip = "instagram_Dd7P496wolG"

private func snap(_ now: Double, title: String? = nil, duration: Double? = nil, previous: LiveContentState? = nil) -> LiveSnapshot {
    LiveSnapshot(title: title, duration: duration, now: now, previous: previous)
}

private func build(_ state: PipelineState, _ s: LiveSnapshot) -> LiveContentState? { LiveContentState.make(from: state, s) }

struct LiveStateBuilderTests {
    /// Each fixture entry, built from the pipeline state and the previous content the way the driver
    /// chains them.
    @Test func everyFixtureEntryIsWhatTheBuilderMakes() throws {
        let f = try fixture()
        func expect(_ name: String, _ got: LiveContentState?, line: Int = #line) throws -> LiveContentState {
            let want = try #require(f[name])
            #expect(got == want, "builder output for \(name) differs from the fixture")
            return try #require(got)
        }

        let fetching = try expect("fetching_waking", build(
            .fetching(since: Date(timeIntervalSince1970: 1_790_000_000), waking: true), snap(1_790_000_000)))
        _ = try expect("uploading", build(
            .uploading(TransferProgress(bytes: 1_200_000, total: 18_200_000)),
            snap(1_790_000_001, title: "IMG_0412.mov", previous: fetching)))
        _ = try expect("saving_storing", build(
            .saving(bytes: 2_100_000, total: 4_331_778, since: Date(timeIntervalSince1970: 1_790_000_000)),
            snap(1_790_000_003, previous: fetching)))
        let reading = try expect("reading", build(
            .reading(developed: 4, of: 9), snap(1_790_000_005, title: clip, duration: 14.77)))
        let ready = try expect("ready", build(.ready, snap(1_790_000_007, title: clip, duration: 14.77, previous: reading)))
        let decoding = try expect("decoding", build(
            .rendering(.decoding(done: 42, total: 150)), snap(1_790_000_020, title: clip, duration: 14.77, previous: ready)))
        let packing = try expect("packing", build(
            .rendering(.packing(since: Date(timeIntervalSince1970: 1_790_000_021))),
            snap(1_790_000_021, title: clip, duration: 14.77, previous: decoding)))
        _ = try expect("done", build(
            .done(WebpResult(
                job: "job", url: URL(string: "https://media.capybaraharmony.com/PrEvIeW001.webp")!,
                bytes: 4_500_000, width: 480, height: 854, seconds: 10.1)),
            snap(1_790_000_043, title: clip, duration: 14.77, previous: packing)))
        _ = try expect("failed_render_lost", build(
            .failed(.renderLost), snap(1_790_000_030, title: clip, duration: 14.77, previous: decoding)))
        _ = try expect("failed_fetch", build(
            .failed(.fetchFailed(code: "error.api.fetch.empty")), snap(1_790_000_002, previous: fetching)))
        #expect(f.count == 10)
    }

    @Test func idleBuildsNothing() {
        #expect(build(.idle, snap(1)) == nil)
    }

    @Test func pickerImageAndSavedLocally() throws {
        let picker = try #require(build(.picker(items: []), snap(10, title: "x", duration: 4)))
        #expect(picker.stage == .ready && picker.rail == 0 && picker.duration == nil)
        let image = try #require(build(.image(MediaInfo(name: "p.png", duration: nil, width: 1, height: 1, bytes: 1, isImage: true)), snap(10, title: "p.png")))
        #expect(image.stage == .ready && image.rail == 3)
        let video = StoredVideo(
            id: "a", kind: .original, fileURL: nil, posterURL: nil, name: "n", duration: nil, width: nil, height: nil,
            bytes: 4_331_778, sessionID: nil, link: nil, remoteURL: nil, createdAt: Date())
        let saved = try #require(build(.savedLocally(video), snap(20, title: "n")))
        #expect(saved.stage == .done && saved.rail == 2 && saved.resultBytes == 4_331_778 && saved.resultURL == nil)
    }

    @Test func aStageChangeResetsCountersAndRestartsTheClockASameStageDoesNot() throws {
        let first = try #require(build(.saving(bytes: 10, total: 100, since: Date()), snap(100)))
        #expect(first.since == 100 && first.bytes == 10)
        let sameStage = try #require(build(.saving(bytes: 50, total: 100, since: Date()), snap(105, previous: first)))
        #expect(sameStage.since == 100, "counters moving is not a new stage")
        #expect(sameStage.bytes == 50)
        let reading = try #require(build(.reading(developed: 1, of: 9), snap(106, previous: sameStage)))
        #expect(reading.since == 106 && reading.bytes == nil && reading.total == nil && reading.framesDone == 1)
    }

    @Test func fetchingKeepsTheRunsStartAndTitleAndDurationCarryOver() throws {
        let start = Date(timeIntervalSince1970: 500)
        let f = try #require(build(.fetching(since: start, waking: false), snap(900)))
        #expect(f.since == 500)
        let reading = try #require(build(.reading(developed: 1, of: 9), snap(901, title: "a", duration: 3, previous: f)))
        let ready = try #require(build(.ready, snap(902, previous: reading)))       // media unknown now: carried
        #expect(ready.title == "a" && ready.duration == 3)
        let late = try #require(build(.ready, snap(903, title: "b", duration: 4, previous: ready)))
        #expect(late.title == "b" && late.duration == 4)
    }

    @Test func packingKeepsTheFrameCountsTheServerReports() throws {
        let decoding = try #require(build(.rendering(.decoding(done: 7, total: 150)), snap(1)))
        let packing = try #require(build(.rendering(.packing(since: Date())), snap(2, previous: decoding)))
        #expect(packing.packing && packing.framesDone == 150 && packing.framesTotal == 150 && packing.since == 1)
        let working = try #require(build(.rendering(.working(since: Date())), snap(3)))
        #expect(!working.packing && working.framesDone == nil)
    }

    @Test func failuresNameTheCaseAndCarryTheCodeWhenThereIsOne() throws {
        let cases: [(PipelineFailure, String, String?)] = [
            (.noLink, "noLink", nil), (.tooLarge(limit: 5), "tooLarge", nil),
            (.fetchFailed(code: "error.api.fetch.empty"), "fetchFailed", "error.api.fetch.empty"),
            (.unsupported, "unsupported", nil), (.serverBusy, "serverBusy", "error.studio.busy"),
            (.renderBusy, "renderBusy", "error.webp.busy"), (.renderLost, "renderLost", "error.webp.job_lost"),
            (.expired, "expired", "error.studio.expired"), (.keyMissing, "keyMissing", "error.api.auth.key.missing"),
            (.keyInvalid, "keyInvalid", "error.api.auth.key.invalid"), (.unreachable, "unreachable", nil),
            (.server(code: "error.x"), "server", "error.x"),
            (.server(code: PipelineFailure.renderPhasePrefix + "error.webp.weird"), "server", "error.webp.weird"),
        ]
        let previous = try #require(build(.reading(developed: 2, of: 9), snap(1)))
        for (failure, name, code) in cases {
            let s = try #require(build(.failed(failure), snap(2, previous: previous)))
            #expect(s.stage == .failed && s.failure == name && s.code == code && s.rail == 2, "\(failure)")
            #expect(s.isTerminal)
        }
    }

    @Test func theBuiltStatesEncodeWithPlainKeysAndNoNulls() throws {
        let s = try #require(build(.rendering(.decoding(done: 1, total: 2)), snap(7, title: "t")))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        #expect(Set(object.keys) == ["stage", "rail", "since", "waking", "packing", "framesDone", "framesTotal", "title"])
    }
}

// MARK: - The manager (CONTRACT-LIVE.md 2.1, 2.5, 2.6) on a fake ActivityKit

@MainActor
struct LiveRig {
    let h: Harness
    let manager: LiveActivityManager
    let adapter: FakeLiveAdapter
    let log: LiveCallLog
    let grace: FakeGrace
    var pipeline: Pipeline { h.pipeline }
    var handle: FakeLiveHandle? { adapter.handles.first }

    init(
        _ scenario: PreviewScenario = .shortClip, push: Bool = false, environment: LiveEnvironment? = nil,
        reply: @escaping @Sendable (LiveRunRegistration, Int) async throws -> LiveRunReply = { _, _ in
            LiveRunReply(pushing: true, started: true)
        },
        startToken: @escaping @Sendable (String, Int) async throws -> Void = { _, _ in }
    ) {
        h = Harness(scenario)
        log = LiveCallLog()
        h.ctx.capabilities.livePush = push
        h.ctx.client = recordingClient(over: h.ctx.client, log: log, reply: reply, startToken: startToken)
        adapter = FakeLiveAdapter()
        let clock = h.clock
        adapter.clock = { clock.now() }
        grace = FakeGrace()
        manager = LiveActivityManager(context: h.ctx, adapter: adapter, environment: environment, grace: grace)
        h.ctx.live = manager
        h.app.liveManager = manager
    }

    func settle() async {
        await h.settle()
        await manager.settle()
    }

    func drive(_ condition: @escaping @MainActor () -> Bool) async {
        await h.drive(until: condition)
        await manager.settle()
    }

    func runToReady(link: String = shortLink) async {
        pipeline.start(link: URL(string: link)!)
        await drive { self.pipeline.state == .ready }
    }

    func runToDone() async {
        await runToReady()
        pipeline.makeWebp()
        await drive { if case .done = self.pipeline.state { true } else { false } }
    }

    /// The stages the activity showed: the request's content, every update, the end.
    func stages(of handle: FakeLiveHandle, request: LiveContentState? = nil) -> [LiveContentState.Stage] {
        var out: [LiveContentState.Stage] = []
        if let request { out.append(request.stage) }
        out += handle.updates.map(\.state.stage)
        if let end = handle.end { out.append(end.state.stage) }
        var collapsed: [LiveContentState.Stage] = []
        for s in out where collapsed.last != s { collapsed.append(s) }
        return collapsed
    }
}

@MainActor private func isDone(_ p: Pipeline) -> Bool { if case .done = p.state { true } else { false } }

@MainActor
@Suite(.serialized)
struct LiveManagerLocalModeTests {
    @Test func everyStageIsWrittenLocallyAndDoneEndsWithAFifteenMinuteDismissal() async throws {
        let rig = LiveRig(push: false)                                    // plain: no push from this server
        await rig.runToDone()
        #expect(isDone(rig.pipeline))
        #expect(rig.adapter.requests.count == 1)
        let request = try #require(rig.adapter.requests.first)
        #expect(!request.push, "local mode asks for no push token")
        #expect(request.attributes.input == "link" && request.attributes.service == "x")
        #expect(request.attributes.ref == "2105435404002562056" && request.attributes.origin == "app")
        #expect(request.attributes.run == rig.pipeline.liveRunID.uuidString.lowercased())
        #expect(request.state.stage == .fetching)
        #expect(request.staleDate.timeIntervalSince(rig.h.clock.epoch) >= 119)

        let handle = try #require(rig.handle)
        let stages = rig.stages(of: handle, request: request.state)
        #expect(isSubsequence(["fetching", "saving", "reading", "ready", "rendering", "done"], of: stages.map(\.rawValue)), "\(stages)")
        let end = try #require(handle.end)
        #expect(end.state.stage == .done && end.state.resultURL != nil)
        let dismiss = try #require(end.dismissAt)
        #expect(abs(dismiss.timeIntervalSince(rig.h.clock.now()) - 900) < 30)
        #expect(handle.endCalls.count == 1)
        #expect(rig.log.runs.isEmpty && rig.log.startTokens.isEmpty, "a server without push is never asked to register")
    }

    @Test func countersAreWrittenAtMostOncePerSecondStageChangesAtOnce() async throws {
        let rig = LiveRig(push: false)
        await rig.runToDone()
        let handle = try #require(rig.handle)
        let request = try #require(rig.adapter.requests.first)
        // when the manager sent each write: its stale date is that moment plus 120 s (1800 s for ready)
        var writes: [(LiveContentState, Date)] = [(request.state, rig.h.clock.epoch)]
        writes += handle.updates.map { u in
            (u.state, u.staleDate!.addingTimeInterval(u.state.stage == .ready ? -1800 : -120))
        }
        var checked = 0
        for (a, b) in zip(writes, writes.dropFirst()) {
            if LiveActivityManager.onlyCounters(differ: a.0, b.0), a.0.stage == b.0.stage {
                #expect(b.1.timeIntervalSince(a.1) >= 0.99, "counter writes \(a.0.stage) are closer than 1 s: \(a) -> \(b)")
                checked += 1
            }
        }
        #expect(checked >= 1, "the run should have had counter-only writes to check")
        // nine frames are developed in ~1.4 s: far fewer than nine writes
        #expect(handle.updates.filter { $0.state.stage == .reading }.count < 9)
        // a stage change is never held back: every stage the run went through was written
        let stages = rig.stages(of: handle, request: request.state)
        #expect(stages.contains(.saving) && stages.contains(.reading) && stages.contains(.ready) && stages.contains(.rendering))
        // equal states are never re-sent
        for (a, b) in zip(writes, writes.dropFirst()) { #expect(a.0 != b.0) }
    }

    @Test func aFailureEndsWithAFiveMinuteDismissal() async throws {
        let rig = LiveRig(.renderLost, push: false)
        await rig.runToReady(link: pastedLink)
        rig.pipeline.makeWebp()
        await rig.drive { if case .failed = rig.pipeline.state { true } else { false } }
        let handle = try #require(rig.handle)
        let end = try #require(handle.end)
        #expect(end.state.stage == .failed && end.state.failure == "renderLost" && end.state.rail == 3)
        let dismiss = try #require(end.dismissAt)
        #expect(abs(dismiss.timeIntervalSince(rig.h.clock.now()) - 300) < 30)
    }

    @Test func aRunThatFailsBeforeAnythingHappenedGetsNoActivity() async throws {
        let rig = LiveRig(push: false)
        rig.pipeline.start(pastedText: "nothing to see here")
        await rig.settle()
        #expect(rig.adapter.requests.isEmpty)
        // and the next real run is not blocked by it
        await rig.runToReady()
        #expect(rig.adapter.requests.count == 1)
    }

    @Test func aNewRunEndsTheUnfinishedActivityAtOnceAndANewOneStarts() async throws {
        let rig = LiveRig(push: false)
        await rig.runToReady()
        let first = try #require(rig.handle)
        #expect(first.end == nil)
        rig.pipeline.start(link: URL(string: pastedLink)!)
        await rig.settle()
        let ended = try #require(first.end)
        #expect(ended.dismissAt == nil, "immediate")
        #expect(rig.adapter.requests.count == 2)
        #expect(rig.adapter.handles.last?.attributes.ref == "Dd7P496wolG")
        #expect(rig.adapter.requests[0].attributes.run != rig.adapter.requests[1].attributes.run)
    }

    @Test func aFinishedActivityKeepsItsDismissalWhenTheNextRunBegins() async throws {
        let rig = LiveRig(push: false)
        await rig.runToDone()
        let first = try #require(rig.handle)
        let endBefore = try #require(first.end)
        rig.pipeline.start(link: URL(string: pastedLink)!)
        await rig.settle()
        #expect(first.endCalls.count == 1 && first.end?.dismissAt == endBefore.dismissAt)
    }

    @Test func idleEndsAnUnfinishedActivity() async throws {
        let rig = LiveRig(push: false)
        await rig.runToReady()
        rig.pipeline.reset()
        await rig.settle()
        let handle = try #require(rig.handle)
        #expect(handle.ended && handle.end?.dismissAt == nil)
    }

    @Test func goingBackToTheTrimAfterAFinishedRunIsANewRunWithItsOwnActivity() async throws {
        let rig = LiveRig(push: false)
        await rig.runToDone()
        let first = try #require(rig.handle)
        let firstRun = rig.pipeline.liveRunID
        rig.pipeline.backToTrim()
        await rig.settle()
        #expect(rig.pipeline.state == .ready)
        #expect(rig.pipeline.liveRunID != firstRun)
        #expect(rig.adapter.requests.count == 2)
        #expect(first.endCalls.count == 1, "the finished activity is left alone")
        // and the second render finishes on its own activity
        rig.pipeline.makeWebp()
        await rig.drive { isDone(rig.pipeline) }
        let second = try #require(rig.adapter.handles.last)
        #expect(second !== first && second.end?.state.stage == .done)
    }

    @Test func liveActivitiesTurnedOffRequestNothing() async throws {
        let rig = LiveRig(push: false)
        rig.adapter.isAvailable = false
        await rig.runToReady()
        #expect(rig.adapter.requests.isEmpty)
        #expect(rig.pipeline.state == .ready)
    }

    @Test func aRefusedRequestNeverBreaksTheRun() async throws {
        let rig = LiveRig(push: false)
        rig.adapter.requestError = URLError(.unknown)
        await rig.runToReady()
        #expect(rig.pipeline.state == .ready && rig.adapter.handles.isEmpty)
    }

    @Test func theActivityWaitsForCapabilitiesSoItsPushTypeIsRight() async throws {
        let rig = LiveRig(push: true, environment: .sandbox)
        rig.h.ctx.capabilities = .unknown                                    // a cold launch pasting at once
        rig.pipeline.start(link: URL(string: shortLink)!)
        #expect(rig.adapter.requests.isEmpty, "capabilities are unknown: not yet")
        rig.h.ctx.capabilities = PreviewData.capabilities(for: .shortClip)
        rig.h.ctx.capabilities.livePush = true
        rig.h.app.apply(rig.h.ctx.capabilities)
        #expect(rig.adapter.requests.count == 1 && rig.adapter.requests[0].push)
    }

    @Test func aPictureOrFileRunNamesTheFile() async throws {
        let rig = LiveRig(.happy, push: false)
        let file = try makeTempFile("IMG_0412.mov", bytes: 200_000)
        rig.pipeline.start(file: file)
        await rig.settle()
        let request = try #require(rig.adapter.requests.first)
        #expect(request.attributes.input == "file" && request.attributes.service == "file" && request.attributes.ref == "IMG_0412.mov")
        #expect(request.state.stage == .uploading && request.state.title == "IMG_0412")
    }

    @Test func theBackgroundGraceIsHeldOnlyWhileWorkIsInFlightInLocalMode() async throws {
        let rig = LiveRig(push: false)
        rig.pipeline.start(link: URL(string: shortLink)!)
        await rig.h.drive { if case .saving = rig.pipeline.state { true } else { false } }
        #expect(rig.grace.begins == 0, "in the foreground there is nothing to ask for")
        rig.manager.didEnterBackground()
        #expect(rig.grace.active && rig.grace.begins == 1)
        await rig.drive { rig.pipeline.state == .ready }
        #expect(!rig.grace.active, "ready waits on the owner, not on the server")
        rig.manager.foreground()
        #expect(!rig.grace.active)
    }

    @Test func noGraceInPushMode() async throws {
        let rig = LiveRig(push: true, environment: .sandbox)
        rig.pipeline.start(link: URL(string: shortLink)!)
        rig.handle?.sendToken(hexToken)
        await rig.settle()
        rig.manager.didEnterBackground()
        #expect(!rig.grace.active, "the server keeps writing; the app is not needed")
    }
}

@MainActor
@Suite(.serialized)
struct LiveManagerPushModeTests {
    @Test func theAppWritesOnlyTheDeviceStepsAndTheServerTheRest() async throws {
        let rig = LiveRig(push: true, environment: .sandbox)
        rig.pipeline.start(link: URL(string: shortLink)!)
        let handle = try #require(rig.handle)
        #expect(rig.adapter.requests[0].push, "a build that can push asks for a token")
        handle.sendToken(hexToken)
        await rig.settle()
        let registrations = rig.log.runs
        #expect(!registrations.isEmpty)
        #expect(registrations.allSatisfy { $0.updateToken == hexToken && !$0.start && $0.environment == .sandbox })
        #expect(registrations.allSatisfy { $0.attributes == rig.adapter.requests[0].attributes })

        await rig.drive { rig.pipeline.state == .ready }
        rig.pipeline.makeWebp()
        await rig.drive { isDone(rig.pipeline) }

        let written = rig.stages(of: handle, request: nil).filter { $0 != .done }
        #expect(!written.contains(.saving) && !written.contains(.rendering) && !written.contains(.fetching),
                "the server's steps are not written by the app in push mode: \(written)")
        #expect(written.contains(.reading) && written.contains(.ready))
        let end = try #require(handle.end)
        #expect(end.state.stage == .done, "the app ends with the same content the server pushes")
        #expect(registrations.last?.session == nil || registrations.last?.session == rig.pipeline.sessionID)
        #expect(rig.log.runs.last?.session == rig.pipeline.sessionID, "the server needs the session to map its events")
    }

    @Test func aReplyThatSaysNotPushingSwitchesTheRunToLocalMode() async throws {
        let rig = LiveRig(push: true, environment: .sandbox, reply: { _, _ in LiveRunReply(pushing: false, started: false) })
        rig.pipeline.start(link: URL(string: shortLink)!)
        let handle = try #require(rig.handle)
        handle.sendToken(hexToken)
        await rig.settle()
        await rig.drive { rig.pipeline.state == .ready }
        rig.pipeline.makeWebp()
        await rig.drive { isDone(rig.pipeline) }
        let stages = rig.stages(of: handle)
        #expect(stages.contains(.saving) && stages.contains(.rendering), "the app writes everything itself: \(stages)")
    }

    @Test func tooManyRunsIsFinalForTheRunAndTheRunCarriesOnLocally() async throws {
        let rig = LiveRig(push: true, environment: .sandbox, reply: { _, _ in
            throw CobaltError.api(code: "error.live.too_many_runs", httpStatus: 429)
        })
        rig.pipeline.start(link: URL(string: shortLink)!)
        let handle = try #require(rig.handle)
        handle.sendToken(hexToken)
        await rig.settle()
        await rig.drive { rig.pipeline.state == .ready }
        #expect(rig.log.runs.count == 1, "no hot retry, no re-registration for the session: \(rig.log.runs.count)")
        let stages = rig.stages(of: handle)
        #expect(stages.contains(.saving), "local mode: the app writes the save itself")
        #expect(rig.pipeline.state == .ready)
        // the run is still ended cleanly
        rig.pipeline.reset()
        await rig.settle()
        #expect(handle.ended)
    }

    @Test func aFailedRegistrationFallsBackToLocalWritesQuietly() async throws {
        let rig = LiveRig(push: true, environment: .sandbox, reply: { _, _ in throw CobaltError.network(.timedOut) })
        rig.pipeline.start(link: URL(string: shortLink)!)
        let handle = try #require(rig.handle)
        handle.sendToken(hexToken)
        await rig.settle()
        await rig.drive { rig.pipeline.state == .ready }
        #expect(rig.stages(of: handle).contains(.saving))
        #expect(rig.pipeline.state == .ready)
    }

    @Test func aNewTokenAndALateSessionAreRegisteredAgain() async throws {
        let rig = LiveRig(push: true, environment: .sandbox)
        await rig.runToReady()
        let handle = try #require(rig.handle)
        handle.sendToken(hexToken)
        await rig.settle()
        let before = rig.log.runs.count
        handle.sendToken(otherHexToken)
        await rig.settle()
        #expect(rig.log.runs.count == before + 1 && rig.log.runs.last?.updateToken == otherHexToken)
        handle.sendToken(otherHexToken)
        await rig.settle()
        #expect(rig.log.runs.count == before + 1, "the same token and session is not sent again")
    }

    @Test func aNewRunTellsTheServerTheOldOneIsOver() async throws {
        let rig = LiveRig(push: true, environment: .sandbox)
        rig.pipeline.start(link: URL(string: shortLink)!)
        let first = try #require(rig.handle)
        let firstRun = rig.pipeline.liveRunID
        first.sendToken(hexToken)
        await rig.settle()
        rig.pipeline.start(link: URL(string: pastedLink)!)
        await rig.settle()
        #expect(rig.log.ends == [firstRun])
        #expect(first.end?.dismissAt == nil)
    }

    @Test func aRunNeverRegisteredIsNotEndedOnTheServer() async throws {
        let rig = LiveRig(push: false)
        await rig.runToReady()
        rig.pipeline.reset()
        await rig.settle()
        #expect(rig.log.isEmpty)
    }

    @Test func noRegistrationWithoutAnEnvironmentOrPush() async throws {
        let sim = LiveRig(push: true, environment: nil)                    // the simulator, an unsigned build
        sim.pipeline.start(link: URL(string: shortLink)!)
        sim.handle?.sendToken(hexToken)
        await sim.settle()
        #expect(sim.adapter.requests[0].push == false)
        #expect(sim.log.runs.isEmpty)
        let plain = LiveRig(push: false, environment: .sandbox)            // a server that does not push
        plain.pipeline.start(link: URL(string: shortLink)!)
        plain.handle?.sendToken(hexToken)
        await plain.settle()
        #expect(plain.log.runs.isEmpty && plain.adapter.requests[0].push == false)
    }

    @Test func aTokenThatArrivesBeforeCapabilitiesIsRegisteredWhenTheyDo() async throws {
        let rig = LiveRig(push: false, environment: .sandbox)
        rig.pipeline.start(link: URL(string: shortLink)!)
        rig.handle?.sendToken(hexToken)
        await rig.settle()
        #expect(rig.log.runs.isEmpty)
        rig.h.ctx.capabilities.livePush = true
        rig.manager.capabilitiesChanged()
        await rig.settle()
        #expect(rig.log.runs.first?.updateToken == hexToken)
    }
}

// MARK: - Start token, push-started activities, orphans (2.5)

@MainActor
@Suite(.serialized)
struct LiveManagerLaunchTests {
    @Test func theStartTokenIsReadAtLaunchAndSentOncePerServerKeyAndToken() async throws {
        let rig = LiveRig(push: true, environment: .production)
        rig.adapter.currentStartToken = hexToken
        rig.manager.start(observeLifecycle: false)
        await rig.settle()
        #expect(rig.log.all == [.startToken(hexToken, .production)])
        rig.manager.foreground()
        rig.adapter.pushStartToken(hexToken)
        await rig.settle()
        #expect(rig.log.startTokens.count == 1, "same token: not sent again")
        rig.adapter.pushStartToken(otherHexToken)
        await rig.settle()
        #expect(rig.log.startTokens == [hexToken, otherHexToken])
    }

    @Test func theObserverStartsBeforeAnyRunSoALateTokenIsNotLost() async throws {
        let rig = LiveRig(push: true, environment: .sandbox)
        rig.manager.start(observeLifecycle: false)
        await rig.h.settle()
        rig.adapter.pushStartToken(hexToken)               // the system hands it over after launch
        await rig.settle()
        #expect(rig.log.startTokens == [hexToken])
    }

    @Test func aTokenWaitsForCapabilitiesAndAKey() async throws {
        let rig = LiveRig(push: false, environment: .sandbox)
        rig.adapter.currentStartToken = hexToken
        rig.manager.start(observeLifecycle: false)
        await rig.settle()
        #expect(rig.log.isEmpty, "the server does not push (yet)")
        rig.h.ctx.capabilities.livePush = true
        rig.h.ctx.settings.clearAPIKey()
        rig.manager.capabilitiesChanged()
        await rig.settle()
        #expect(rig.log.isEmpty, "no key: the call would be refused")
        try rig.h.ctx.settings.setAPIKey(pasted: "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21")
        rig.manager.foreground()
        await rig.settle()
        #expect(rig.log.startTokens == [hexToken])
    }

    @Test func aFailedTokenRegistrationIsTriedAgainOnTheNextForeground() async throws {
        let rig = LiveRig(push: true, environment: .sandbox, startToken: { _, n in
            if n == 1 { throw CobaltError.network(.notConnectedToInternet) }
        })
        rig.adapter.currentStartToken = hexToken
        rig.manager.start(observeLifecycle: false)
        await rig.settle()
        #expect(rig.log.startTokens.count == 1)
        rig.manager.foreground()
        await rig.settle()
        #expect(rig.log.startTokens.count == 2)
        rig.manager.foreground()
        await rig.settle()
        #expect(rig.log.startTokens.count == 2, "it went through: done")
    }

    @Test func noStartTokenWithoutAnEnvironment() async throws {
        let rig = LiveRig(push: true, environment: nil)
        rig.adapter.currentStartToken = hexToken
        rig.manager.start(observeLifecycle: false)
        await rig.settle()
        #expect(rig.log.isEmpty)
    }

    private func pushStarted(run: UUID, origin: String = "share", staleIn: TimeInterval? = 120, clock: Harness) -> FakeLiveHandle {
        let attributes = LiveRunAttributes(run: run, input: "link", service: "x", ref: "2105435404002562056", origin: origin)
        let state = LiveContentState.samples["fetching_waking"]!
        return FakeLiveHandle(
            attributes: attributes, state: state, staleDate: staleIn.map { clock.clock.now().addingTimeInterval($0) },
            clock: { clock.clock.now() })
    }

    @Test func aPushStartedActivityGetsItsUpdateTokenRegisteredWithTheRunsSession() async throws {
        let rig = LiveRig(push: true, environment: .sandbox)
        let run = UUID()
        rig.h.ctx.jobs.upsert(SharedJob(
            id: run, origin: .shareExtension, link: URL(string: shortLink), sessionID: "PrEvIeWsession00000007",
            media: nil, trim: nil, stage: .saving, wantsTrim: false, pickedUp: false, updatedAt: rig.h.clock.now()))
        rig.manager.start(observeLifecycle: false)
        await rig.h.settle()
        let started = pushStarted(run: run, clock: rig.h)
        rig.adapter.systemStarts(started)
        await rig.h.settle()
        started.sendToken(hexToken)
        await rig.settle()
        let r = try #require(rig.log.runs.first)
        #expect(rig.log.runs.count == 1)
        #expect(r.run == run && r.updateToken == hexToken && !r.start && r.session == "PrEvIeWsession00000007")
        #expect(r.attributes == started.attributes && r.state == started.state && r.environment == .sandbox)
        // reading the same activity again on a foreground does not register it twice
        rig.manager.foreground()
        await rig.settle()
        #expect(rig.log.runs.count == 1)
    }

    @Test func aPushStartedActivityIsLeftAloneWhenTheServerCannotPush() async throws {
        let rig = LiveRig(push: false, environment: .sandbox)
        rig.manager.start(observeLifecycle: false)
        await rig.h.settle()
        let started = pushStarted(run: UUID(), clock: rig.h)
        rig.adapter.systemStarts(started)
        started.sendToken(hexToken)
        await rig.settle()
        #expect(rig.log.isEmpty)
    }

    @Test func orphansAreEndedAtOnceButTheOwnRunSharedJobsAndFreshOnesStay() async throws {
        let rig = LiveRig(push: false)
        rig.pipeline.start(link: URL(string: shortLink)!)
        let own = try #require(rig.handle)
        let orphan = pushStarted(run: UUID(), staleIn: nil, clock: rig.h)                  // nobody follows it, not fresh
        let pastStale = pushStarted(run: UUID(), staleIn: -30, clock: rig.h)
        let fresh = pushStarted(run: UUID(), staleIn: 90, clock: rig.h)                    // someone is writing it
        let jobRun = UUID()
        let inFlight = pushStarted(run: jobRun, staleIn: nil, clock: rig.h)
        rig.h.ctx.jobs.upsert(SharedJob(
            id: jobRun, origin: .shareExtension, link: nil, sessionID: "S", media: nil, trim: nil,
            stage: .rendering(job: "j"), wantsTrim: false, pickedUp: false, updatedAt: rig.h.clock.now()))
        let finished = pushStarted(run: UUID(), staleIn: nil, clock: rig.h)
        finished.ended = true
        for handle in [orphan, pastStale, fresh, inFlight, finished] { rig.adapter.handles.append(handle) }

        rig.manager.start(observeLifecycle: false)
        await rig.settle()
        #expect(orphan.ended && orphan.end?.dismissAt == nil)
        #expect(pastStale.ended)
        #expect(!fresh.ended && !inFlight.ended && !own.ended)
        #expect(finished.endCalls.isEmpty)
    }

    @Test func aRunAdoptsTheActivityThatAlreadyCarriesItsRunId() async throws {
        // "trim in cobalt": the share sheet's push-started activity, taken over by the app's pipeline
        let rig = LiveRig(push: false)
        let jobID = UUID()
        let job = SharedJob(
            id: jobID, origin: .shareExtension, link: URL(string: shortLink), sessionID: "PrEvIeWsession00000009",
            media: MediaInfo(name: "twitter_2105435404002562056", duration: 5.46, width: 480, height: 568, bytes: 1, isImage: false),
            trim: nil, stage: .ready, wantsTrim: true, pickedUp: false, updatedAt: rig.h.clock.now())
        rig.h.ctx.jobs.upsert(job)
        let existing = pushStarted(run: jobID, clock: rig.h)
        rig.adapter.handles.append(existing)
        rig.pipeline.resume(job)
        await rig.settle()
        #expect(rig.pipeline.liveRunID == jobID)
        #expect(rig.adapter.requests.isEmpty, "no second activity for the same run")
        #expect(rig.pipeline.state != .idle)
        await rig.drive { rig.pipeline.state == .ready }
        #expect(existing.updates.contains { $0.state.stage == .reading })
        #expect(existing.updates.last?.state.stage == .ready)
    }
}

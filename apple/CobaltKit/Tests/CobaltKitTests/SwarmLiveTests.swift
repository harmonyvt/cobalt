import Foundation
import Testing
@testable import CobaltKit

// Wave 2B: the swarm Live Activity's buttons and strip, the intents' seam (`SwarmIntentHost`), deep links, the Mac
// notification's words, and the manager adopting a push-started swarm. (The server's fixture states themselves are pinned by
// `SwarmLiveTests` in SwarmTests.swift and `JobLiveBuilderParityTests`.)

private let T = 1_790_000_000.0
private let at = Date(timeIntervalSince1970: T)

private func make(
    _ status: Swarm.Status, apply: Swarm.Apply = .init(), cells letters: String = "dddd", expires: Date? = nil,
    hash: String = "HASH-1", estimate: Swarm.Range2? = nil, planner: String? = "claude code"
) -> Swarm {
    let cells = letters.enumerated().map { SwarmCell(idx: $0.offset, status: SwarmCell.Status(letter: $0.element) ?? .queued) }
    var s = Swarm(
        id: "abc123", name: "rename 1,000 emotes", mode: .propose, status: status, specHash: hash,
        tasks: Swarm.Tasks(total: cells.count, done: cells.filter { $0.status == .done }.count, cells: cells),
        capUSD: 1, spentUSD: 0.44, createdAt: at.addingTimeInterval(-600), planner: planner)
    s.apply = apply
    s.expiresAt = expires
    s.estimateUSD = estimate
    return s
}

/// The swarm cases of the server's one fixture (deploy/cloudflare/api/test/fixtures/job-live-states.json), by name.
private func fixtureStates() throws -> [String: JobLiveState] {
    var out: [String: JobLiveState] = [:]
    for c in try fixtureCases() where c.name.hasPrefix("swarm_") { out[c.name] = try decodeState(c.state) }
    return out
}

// MARK: - buttons

struct SwarmLiveButtonTests {
    @Test func theButtonsOfEveryFixtureStateAndWhichOnesWaitForYou() throws {
        let states = try fixtureStates()
        func state(_ name: String) throws -> JobLiveState { try #require(states[name], "\(name)") }
        let want: [(String, [SwarmLiveAction], Bool)] = [
            ("swarm_awaiting", [.approve, .decline], true),
            ("swarm_running", [.stop], false),
            ("swarm_running_read", [.stop], false),
            ("swarm_stopping", [], false),
            ("swarm_ready", [.check, .apply], true),
            ("swarm_applying", [], false),
            ("swarm_applied", [.open], false),
            ("swarm_done_read", [.open], false),
            ("swarm_capped", [.open], false),
            ("swarm_declined", [.open], false),
            ("swarm_expired", [.open], false),
        ]
        for (name, actions, waits) in want {
            let s = try state(name)
            #expect(s.swarmActions == actions, "\(name)")
            #expect(s.swarmWaitsForYou == waits, "\(name)")
        }
        // approve and apply carry what they send; stop and decline need nothing
        #expect(try state("swarm_awaiting").hash == "a1b2c3d4e5f60718")
        #expect(try state("swarm_ready").hash == "a1b2c3d4e5f60718" && state("swarm_ready").count == 4)
        #expect(try state("swarm_running").hash == nil)
    }

    @Test func anUnknownButtonIsSkippedAndEveryOtherKindOfJobHasNone() throws {
        var s = try #require(try fixtureStates()["swarm_awaiting"])
        s.actions = ["approve", "teleport", "decline"]
        #expect(s.swarmActions == [.approve, .decline])
        let save = JobLiveState(phase: .working, steps: ["download"], step: 0, headline: "saving", since: T)
        #expect(save.swarmActions.isEmpty && save.swarmStrip == nil && !save.swarmWaitsForYou)
    }

    @Test func onlyApproveAndApplyAskForFaceIdAndOnlyCheckAndOpenAreLinks() {
        for action in SwarmLiveAction.allCases {
            #expect(action.needsAuthentication == (action == .approve || action == .apply), "\(action)")
            #expect(action.isCall == !(action == .check || action == .open), "\(action)")
        }
    }

    /// The intents live in the app and widget targets (no test target can import them), so the auth policy is pinned in the
    /// source: approve and apply declare `.requiresAuthentication`, decline and stop declare none, and the widget extension
    /// compiles the same file.
    @Test func theIntentsDeclareTheAuthPolicyTheActionsSay() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: apple.appendingPathComponent("Cobalt/Intents/SwarmLiveIntents.swift"), encoding: .utf8)
        let structs = source.components(separatedBy: "\nstruct ").dropFirst()
        func block(_ name: String) throws -> String { try #require(structs.first { $0.hasPrefix(name) }, "\(name)") }
        let policy = "static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication"
        for (name, action) in [
            ("ApproveSwarmIntent", SwarmLiveAction.approve), ("ApplySwarmIntent", .apply),
            ("DeclineSwarmIntent", .decline), ("StopSwarmIntent", .stop),
        ] {
            let b = try block(name)
            #expect(b.hasPrefix("\(name): LiveActivityIntent"), "\(name) is a LiveActivityIntent")
            #expect(b.contains(policy) == action.needsAuthentication, "\(name)")
            #expect(b.contains("SwarmIntentHost.run") || b.contains("runSwarmAction(.\(action.rawValue)"), "\(name) runs \(action)")
        }
        let project = try String(contentsOf: apple.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(project.contains("- path: Cobalt/Intents/SwarmLiveIntents.swift"), "the widget extension compiles the intents too")
    }
}

// MARK: - the strip

struct SwarmLiveStripTests {
    @Test func upToFortyAgentsAreCells() throws {
        let s = JobLiveState(phase: .working, steps: [], step: 0, headline: "x", since: T, cells: "ddwrqfs")
        let strip = try #require(s.swarmStrip)
        #expect(strip.total == 7)
        #expect(strip.layout == .cells([.done, .done, .waiting, .running, .queued, .failed, .skipped]))
        let forty = try #require(JobLiveState(phase: .working, steps: [], step: 0, headline: "x", since: T, cells: String(repeating: "d", count: 40)).swarmStrip)
        #expect(forty.layout == .cells(Array(repeating: .done, count: 40)))
    }

    @Test func pastFortyOneBarSplitByShareInTheCardsOrder() throws {
        // 41 agents: 20 done, 3 failed, 2 waiting, 6 running, 10 queued; "s" and unknown letters count as skipped / queued
        let letters = String(repeating: "q", count: 10) + "fff" + String(repeating: "r", count: 6) + "ww" + String(repeating: "d", count: 20)
        let strip = try #require(JobLiveState(phase: .working, steps: [], step: 0, headline: "x", since: T, cells: letters).swarmStrip)
        #expect(strip.total == 41)
        #expect(strip.layout == .bar([
            .init(status: .done, count: 20), .init(status: .running, count: 6), .init(status: .waiting, count: 2),
            .init(status: .failed, count: 3), .init(status: .queued, count: 10),
        ]))
        // the most the server sends: 200
        let big = try #require(JobLiveState(
            phase: .working, steps: [], step: 0, headline: "x", since: T, cells: String(repeating: "d", count: 150) + String(repeating: "s", count: 50)).swarmStrip)
        #expect(big.total == 200 && big.layout == .bar([.init(status: .done, count: 150), .init(status: .skipped, count: 50)]))
    }

    @Test func aLetterThisBuildDoesNotKnowKeepsItsPlaceAsQueued() throws {
        let strip = try #require(JobLiveState(phase: .working, steps: [], step: 0, headline: "x", since: T, cells: "dXd").swarmStrip)
        #expect(strip.layout == .cells([.done, .queued, .done]))
    }

    @Test func noCellsMeansNoStrip() {
        #expect(JobLiveState(phase: .waiting, steps: [], step: 0, headline: "x", since: T).swarmStrip == nil)
        #expect(JobLiveState(phase: .waiting, steps: [], step: 0, headline: "x", since: T, cells: "").swarmStrip == nil)
    }
}

// MARK: - the activity after a button

struct SwarmActivityUpdateTests {
    @Test func declinedAndExpiredEndAtOnceTheRestKeepOrDismissLater() {
        func u(_ s: Swarm) -> SwarmActivityUpdate { SwarmActivityUpdate(swarm: s, now: at) }
        #expect(u(make(.declined)).ending == .immediately)
        #expect(u(make(.expired)).ending == .immediately)
        #expect(u(make(.declined)).state.headline == "declined" && u(make(.declined)).state.actions == ["open"])
        #expect(u(make(.running, cells: "ddrq")).ending == .none)
        #expect(u(make(.awaitingApproval, cells: "qqqq", expires: at.addingTimeInterval(3000))).ending == .none)
        #expect(u(make(.stopped)).ending == .after(seconds: 300))
        #expect(u(make(.failed)).ending == .after(seconds: 300))
        #expect(u(make(.done, apply: .init(status: .applied, done: 5, total: 5))).ending == .after(seconds: 60))
        // changes ready to apply stay on the Lock Screen: still waiting for you
        let ready = u(make(.done, apply: .init(status: .ready, total: 5)))
        #expect(ready.ending == .none && ready.state.phase == .waiting && ready.state.actions == ["check", "apply"])
        // approve answered: it is running now
        let running = u(make(.running, cells: "rrqq"))
        #expect(running.state.phase == .working && running.state.actions == ["stop"] && running.state.step == 1)
    }
}

// MARK: - the intents' seam

@MainActor
private func previewClient() -> PreviewClient {
    PreviewClient(scenario: .happy, timeScale: 1, clock: VirtualClock(), swarms: .awaiting)
}

@MainActor
@Suite(.serialized)
struct SwarmIntentHostTests {
    @Test func withoutTheAppsHookItCannotRun() async {
        SwarmIntentHost.setClient(nil)
        await #expect(throws: SwarmIntentHostError.noSession) {
            try await SwarmIntentHost.run(.decline, swarm: "x", hash: nil)
        }
    }

    @Test func approveSendsThePlansHashWithTheDevicesClientAndDeclineAndStopSendNothingElse() async throws {
        let client = previewClient()
        SwarmIntentHost.setClient { client }
        defer { SwarmIntentHost.setClient(nil) }
        let awaiting = try await client.swarm(id: PreviewSwarmIDs.story)
        #expect(awaiting.status == .awaitingApproval)

        // a wrong plan is refused by the server and nothing starts
        await #expect(throws: SwarmError.hashMismatch) {
            try await SwarmIntentHost.run(.approve, swarm: PreviewSwarmIDs.story, hash: "not-the-plan")
        }
        // no hash: never sent
        await #expect(throws: SwarmError.missingHash) {
            try await SwarmIntentHost.run(.approve, swarm: PreviewSwarmIDs.story, hash: nil)
        }
        #expect(client.swarmState.calls.filter { $0.contains("approve") }.count == 1, "only the wrong-plan try reached the server")

        let approved = try await SwarmIntentHost.run(.approve, swarm: PreviewSwarmIDs.story, hash: awaiting.specHash)
        #expect(approved.status == .running)
        // links are not calls
        await #expect(throws: SwarmError.notACall) {
            try await SwarmIntentHost.run(.open, swarm: PreviewSwarmIDs.story, hash: nil)
        }

        let stopped = try await SwarmIntentHost.run(.stop, swarm: PreviewSwarmIDs.story, hash: nil)
        #expect(stopped.status == .stopped || stopped.status == .stopping)
    }

    @Test func declineAndAnAnswerThatCameTooLate() async throws {
        let client = previewClient()
        SwarmIntentHost.setClient { client }
        defer { SwarmIntentHost.setClient(nil) }
        let declined = try await SwarmIntentHost.run(.decline, swarm: PreviewSwarmIDs.story, hash: nil)
        #expect(declined.status == .declined)
        // answered already (from another device): a plain refusal, in words
        await #expect(throws: SwarmError.notAwaiting) {
            try await SwarmIntentHost.run(.decline, swarm: PreviewSwarmIDs.story, hash: nil)
        }
        #expect(SwarmError.notAwaiting.words == "it was answered already")
    }

    @Test func aCountMismatchRefreshesTheIslandAndThrowsThePlainError() async throws {
        let client = PreviewClient(scenario: .happy, timeScale: 1, clock: VirtualClock(), swarms: .review)
        SwarmIntentHost.setClient { client }
        let seen = SeenUpdates()
        SwarmIntentHost.setActivitySink { update, id in seen.add(update, id) }
        defer { SwarmIntentHost.setClient(nil); SwarmIntentHost.setActivitySink(nil) }
        let hash = try await client.swarm(id: PreviewSwarmIDs.story).specHash

        // what the island showed: 338 (342 kept, 4 clash); another device then unticks one, so the server would apply 337
        _ = try await client.decideSwarm(id: PreviewSwarmIDs.story, changes: [SwarmDecision(n: 1, keep: false)])
        do {
            try await SwarmIntentHost.run(.apply, swarm: PreviewSwarmIDs.story, hash: hash, count: 338)
            Issue.record("the apply should have been refused")
        } catch {
            #expect(error as? SwarmError == .countMismatch)
            #expect((error as? SwarmError)?.words == "the number of changes moved on: look again")
        }
        #expect(client.swarmState.calls.contains { $0.contains("POST apply") && $0.contains("count=338") })
        // nothing started, and the island was redrawn with the number that is true now (the clashes left out)
        #expect(try await client.swarm(id: PreviewSwarmIDs.story).apply.status == .ready)
        let updates = seen.all
        #expect(updates.count == 1 && updates[0].1 == PreviewSwarmIDs.story)
        #expect(updates[0].0.state.count == 337 && updates[0].0.state.hash == hash)

        // the same tap with the fresh number goes through
        let applying = try await SwarmIntentHost.run(.apply, swarm: PreviewSwarmIDs.story, hash: hash, count: 337)
        #expect(applying.apply.status == .applying)
    }

    @Test func applyWithoutACountSendsNone() async throws {
        let client = PreviewClient(scenario: .happy, timeScale: 1, clock: VirtualClock(), swarms: .review)
        SwarmIntentHost.setClient { client }
        SwarmIntentHost.setActivitySink { _, _ in }
        defer { SwarmIntentHost.setClient(nil); SwarmIntentHost.setActivitySink(nil) }
        let hash = try await client.swarm(id: PreviewSwarmIDs.story).specHash
        _ = try await SwarmIntentHost.run(.apply, swarm: PreviewSwarmIDs.story, hash: hash)
        let call = try #require(client.swarmState.calls.last { $0.contains("POST apply") })
        #expect(!call.contains("count="))
    }

    @Test func theHooksClientIsTheModelsOwnSessionClient() async throws {
        let rig = SwarmRig(.awaiting)
        rig.app.installSwarmIntentHost()
        defer { SwarmIntentHost.setClient(nil) }
        let story = try await rig.client.swarm(id: SwarmRig.story)
        _ = try await SwarmIntentHost.run(.approve, swarm: SwarmRig.story, hash: story.specHash)
        #expect(rig.calls(containing: "POST approve") == 1)
    }
}

// MARK: - links

struct SwarmRouteTests {
    @Test func swarmReviewAndResultsLinks() throws {
        func route(_ s: String) -> SwarmRoute? { URL(string: s).flatMap(SwarmRoute.init(url:)) }
        #expect(route("cobalt-apple://swarm/PrEvIeWswarm0001") == .swarm("PrEvIeWswarm0001"))
        #expect(route("cobalt-apple://swarm/PrEvIeWswarm0001/") == .swarm("PrEvIeWswarm0001"))
        #expect(route("cobalt-apple://swarm/PrEvIeWswarm0001/review") == .review("PrEvIeWswarm0001"))
        #expect(route("cobalt-apple://swarm/PrEvIeWswarm0001/results") == .board("PrEvIeWswarm0001"))
        #expect(route("cobalt-apple://SWARM/abc123/REVIEW") == .review("abc123"))
        #expect(try #require(route("cobalt-apple://swarm/abc123")).swarmID == "abc123")
    }

    @Test func junkIsNotARoute() {
        func route(_ s: String) -> SwarmRoute? { URL(string: s).flatMap(SwarmRoute.init(url:)) }
        #expect(route("cobalt-apple://swarm") == nil)
        #expect(route("cobalt-apple://swarm/") == nil)
        #expect(route("cobalt-apple://swarm/abc123/nonsense") == nil)
        #expect(route("cobalt-apple://swarm/ab-c%20d") == nil)
        #expect(route("cobalt-apple://swarms/abc123") == nil)
        #expect(route("https://swarm/abc123") == nil)
        #expect(route("cobalt-apple://library") == nil)
        #expect(route("cobalt-apple://job/6f1c1d1e-0000-0000-0000-000000000000") == nil)
    }
}

// MARK: - the Mac notification

struct SwarmNoticeTests {
    @Test func theWordsTheLinkAndWhatTheButtonsGetBack() throws {
        let s = make(.awaitingApproval, cells: "qqqq", expires: at.addingTimeInterval(3000), estimate: .init(low: 0.3, high: 0.5))
        let notice = try #require(SwarmNotice(swarm: s))
        #expect(notice.body == "claude code asks: rename 1,000 emotes · about 50¢")
        #expect(notice.url == "cobalt-apple://swarm/abc123" && notice.identifier == "swarm-abc123")
        #expect(notice.userInfo == ["url": "cobalt-apple://swarm/abc123", "swarm": "abc123", "hash": "HASH-1"])
        let back = try #require(SwarmNotice.decode(userInfo: notice.userInfo))
        #expect(back.swarm == "abc123" && back.hash == "HASH-1")
        #expect(SwarmNotice.decode(userInfo: ["url": "cobalt-apple://swarm/abc123"]) == nil)
        #expect(SwarmNotice(swarm: make(.running)) == nil && SwarmNotice(swarm: make(.awaitingApproval, hash: "")) == nil)
        // no planner, no estimate: still a sentence
        let bare = try #require(SwarmNotice(swarm: make(.awaitingApproval, planner: nil)))
        #expect(bare.body == "an agent asks: rename 1,000 emotes")
    }

    @Test func eachWaitingSwarmIsToldOnceAndTakenDownWhenAnswered() {
        var a = make(.awaitingApproval, expires: at.addingTimeInterval(600)); a.id = "a"; a.createdAt = at.addingTimeInterval(-100)
        var b = make(.awaitingApproval, expires: at.addingTimeInterval(600)); b.id = "b"; b.createdAt = at.addingTimeInterval(-300)
        var old = make(.awaitingApproval, expires: at.addingTimeInterval(-5)); old.id = "old"
        var done = make(.done); done.id = "done"
        let list = [a, b, old, done]
        #expect(SwarmNotice.fresh(in: list, seen: [], now: at).map(\.swarm) == ["b", "a"], "oldest first; an expired plan is skipped")
        #expect(SwarmNotice.fresh(in: list, seen: ["b"], now: at).map(\.swarm) == ["a"])
        #expect(SwarmNotice.fresh(in: list, seen: ["a", "b"], now: at).isEmpty)
        // told about "a" and "done": "done" was answered (no longer waiting); a swarm that left the list is kept in `seen`
        #expect(SwarmNotice.answered(in: list, seen: ["a", "done", "gone"]) == ["done"])
    }
}

// MARK: - the manager follows a push-started swarm

@MainActor
struct SwarmAdoptionTests {
    private func pushedSwarm(_ rig: LiveRig, staleIn: TimeInterval? = nil) -> FakeLiveHandle {
        let attributes = JobLiveAttributes(
            id: "swarm:PrEvIeWswarm0001", kind: "swarm", title: "swarm · rename 1,000 emotes", agent: true,
            open: "cobalt-apple://swarm/PrEvIeWswarm0001")
        let state = JobLiveState(swarm: make(.awaitingApproval, cells: "qqqq", expires: rig.h.clock.now().addingTimeInterval(3000)), now: rig.h.clock.now())
        return FakeLiveHandle(
            job: JobLiveJob(attributes: attributes, state: state),
            staleDate: staleIn.map { rig.h.clock.now().addingTimeInterval($0) }, clock: { rig.h.clock.now() })
    }

    @Test func swarmIsOneOfTheKindsTheSaveManagerFollows() {
        #expect(JobLiveKinds.saves.contains("swarm"))
        #expect(!JobLiveKinds.edits.contains("swarm") && !JobLiveKinds.chats.contains("swarm"))
    }

    @Test func aPushStartedSwarmIsAdoptedAndItsTokenRegisteredAsAJobUnderItsOwnName() async throws {
        let rig = LiveRig(push: true, environment: .sandbox)
        rig.manager.start(observeLifecycle: false)
        await rig.h.settle()
        let started = pushedSwarm(rig)
        rig.adapter.systemStarts(started)
        await rig.h.settle()
        started.sendToken(hexToken)
        await rig.settle()
        let r = try #require(rig.log.runs.first)
        #expect(rig.log.runs.count == 1)
        #expect(r.runName == "swarm:PrEvIeWswarm0001" && r.attributes.run == "swarm:PrEvIeWswarm0001")
        #expect(r.updateToken == hexToken && r.job && !r.start && r.environment == .sandbox)
        #expect(!started.ended && started.updates.isEmpty, "the server writes it: the app only hands over the token")
        // a foreground does not register it twice
        rig.manager.foreground()
        await rig.settle()
        #expect(rig.log.runs.count == 1)
    }

    @Test func aSwarmWaitingForItsOwnerIsNotAnOrphanEvenWhenItsStaleDatePassed() async throws {
        let rig = LiveRig(push: true, environment: .sandbox)
        let waiting = pushedSwarm(rig, staleIn: -600)           // unanswered for ten minutes: nothing changed, nothing pushed
        rig.adapter.handles.append(waiting)
        rig.manager.start(observeLifecycle: false)
        await rig.settle()
        rig.manager.foreground()
        await rig.settle()
        #expect(!waiting.ended, "an unanswered plan stays on the Lock Screen: the server ends it when it expires")
    }

    @Test func theRegistrationPathNamesTheSwarmRun() throws {
        let attributes = LiveRunAttributes(run: LiveRunRegistration.swarmPlaceholder, input: "link", service: "swarm", ref: "", origin: "share")
        let reg = LiveRunRegistration(
            run: LiveRunRegistration.swarmPlaceholder, environment: .sandbox, updateToken: hexToken, session: nil, start: false,
            attributes: attributes, state: LiveContentState(stage: .fetching, rail: 0, since: T), job: true, runName: "swarm:abc")
        let body = try JSONSerialization.jsonObject(with: reg.requestBody()) as? [String: Any]
        #expect(body?["type"] as? String == "job" && body?["update_token"] as? String == hexToken)
        #expect(LiveRunRegistration(
            run: UUID(), environment: .sandbox, updateToken: nil, session: nil, start: false, attributes: attributes,
            state: LiveContentState(stage: .fetching, rail: 0, since: T)).runName == nil)
    }
}

/// What the intent host put on the island, in order.
private final class SeenUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(SwarmActivityUpdate, String)] = []
    func add(_ update: SwarmActivityUpdate, _ id: String) { lock.withLock { list.append((update, id)) } }
    var all: [(SwarmActivityUpdate, String)] { lock.withLock { list } }
}

// MARK: - the apply request's body

struct SwarmApplyRequestTests {
    private func client(_ server: LoopbackServer) -> HTTPCobaltClient {
        HTTPCobaltClient(baseURL: server.base, apiKey: { "7c1f2a60-4b0e-4d2f-9a53-3f1d8e9b6a21" })
    }

    private func body(_ request: LoopbackServer.Request) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test func countIsInTheBodyOnlyWhenGiven() async throws {
        let server = try await LoopbackServer.start { _ in .json(#"{"swarm":"s1","apply":{"status":"applying","total":338}}"#) }
        defer { server.stop() }
        let c = client(server)
        _ = try await c.applySwarm(id: "s1", hash: "h", skipClashes: true, count: 338)
        _ = try await c.applySwarm(id: "s1", hash: "h", skipClashes: true, count: nil)
        _ = try await c.applySwarm(id: "s1", hash: "h", skipClashes: false, count: 0)
        _ = try await c.applySwarm(id: "s1", hash: "h", skipClashes: false, count: nil)
        let sent = try server.requests.map(body)
        #expect(server.requests.allSatisfy { $0.method == "POST" && $0.path == "/swarms/s1/apply" })
        #expect(sent[0]["spec_hash"] as? String == "h" && sent[0]["skip_clashes"] as? Bool == true && sent[0]["count"] as? Int == 338)
        #expect(sent[1]["count"] == nil && sent[1]["skip_clashes"] as? Bool == true)
        #expect(sent[2]["count"] as? Int == 0 && sent[2]["skip_clashes"] == nil, "zero is a number: it is sent")
        #expect(sent[3].keys.sorted() == ["spec_hash"])
    }

    @Test func aMismatchIsThePlainErrorNotAGenericOne() async throws {
        let server = try await LoopbackServer.start { _ in
            .json(#"{"status":"error","error":{"code":"error.swarm.count_mismatch"}}"#, status: 409)
        }
        defer { server.stop() }
        await #expect(throws: SwarmError.countMismatch) {
            try await client(server).applySwarm(id: "s1", hash: "h", skipClashes: true, count: 5)
        }
    }
}

import Foundation
import Testing
@testable import CobaltKit

// Wave 2B: the swarm Live Activity's buttons and strip, the intents' seam (`SwarmIntentHost`), deep links, the Mac
// notification's words, and the manager adopting a push-started swarm. (The server's fixture states themselves are pinned by
// `SwarmLiveTests` in SwarmTests.swift.)

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

private func fixtureStates() throws -> [String: JobLiveState] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/job-live-swarm-states.json")
    let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var out: [String: JobLiveState] = [:]
    for (name, value) in root {
        let object = try #require(value as? [String: Any])
        let state = try #require(object["state"])
        out[name] = try JSONDecoder().decode(JobLiveState.self, from: JSONSerialization.data(withJSONObject: state))
    }
    return out
}

// MARK: - buttons

struct SwarmLiveButtonTests {
    @Test func theButtonsOfEveryFixtureStateAndWhichOnesWaitForYou() throws {
        let states = try fixtureStates()
        func state(_ name: String) throws -> JobLiveState { try #require(states[name], "\(name)") }
        let want: [(String, [SwarmLiveAction], Bool)] = [
            ("swarm_awaiting", [.approve, .decline], true),
            ("swarm_running_asking", [.stop], false),
            ("swarm_running_changes", [.stop], false),
            ("swarm_ready", [.check, .apply], true),
            ("swarm_applying", [], false),
            ("swarm_applied", [.open], false),
            ("swarm_done_read", [.open], false),
            ("swarm_declined", [.open], false),
            ("swarm_stopped_cap", [.open], false),
            ("swarm_expired", [.open], false),
        ]
        for (name, actions, waits) in want {
            let s = try state(name)
            #expect(s.swarmActions == actions, "\(name)")
            #expect(s.swarmWaitsForYou == waits, "\(name)")
        }
        // approve and apply carry what they send; stop and decline need nothing
        #expect(try state("swarm_awaiting").hash == "PrEvIeWhash0001")
        #expect(try state("swarm_ready").hash == "PrEvIeWhash0001" && state("swarm_ready").count == 338)
        #expect(try state("swarm_running_asking").hash == nil)
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

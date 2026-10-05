import Foundation
import Testing
@testable import CobaltKit

// The notify bridge keeps the LAST intent per session (NotifyBridge). Every test here forces the
// ordering with gates and never waits on a clock: a PUT is parked on the wire, the next intent is
// made, and only then does the PUT answer.

/// Counts arrivals; `next()` returns once one has arrived (each arrival is consumed once).
actor Arrivals {
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func fire() {
        if waiters.isEmpty { pending += 1 } else { waiters.removeFirst().resume() }
    }
    func next() async {
        if pending > 0 { pending -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A client whose notify PUTs park until the test lets them through, on top of the preview server.
@MainActor
struct GatedNotify {
    let server: PreviewServer
    let client: ScriptedClient
    let puts = Arrivals()          // a PUT reached the wire (not yet applied by the server)
    let gate = Gate()              // lets the parked PUTs through
    let clock: VirtualClock

    init(_ base: any CobaltClient, clock: VirtualClock) {
        let preview = base as! PreviewClient
        server = preview.server
        self.clock = clock
        let puts = puts, gate = gate
        var stub = ScriptedClient(base: base)
        stub.setNotifyHook = { id, optIn in
            await puts.fire()
            await gate.wait()
            try await base.setNotify(session: id, optIn)
        }
        client = stub
    }

    var calls: [String] { server.notifyCalls }
}

@MainActor
@Suite(.serialized)
struct NotifyOrderingTests {
    private let optIn = NotifyOptIn(on: [.saved, .failed], label: "clip")
    private let other = NotifyOptIn(on: [.rendered, .failed], label: "clip")

    private func rig() -> (bridge: NotifyBridge, g: GatedNotify) {
        let h = Harness(.shortClip)
        return (NotifyBridge(), GatedNotify(h.ctx.client, clock: h.clock))
    }

    @Test func aCancelWhileThePutIsOnTheWireStillTakesItBack() async {
        let (bridge, g) = rig()
        let put = bridge.enqueueRegister(session: "S", optIn, source: .background, client: g.client, clock: g.clock)
        await g.puts.next()                                   // the PUT is in flight, the server has not seen it
        #expect(g.calls.isEmpty && bridge.isRegistered("S"), "the intent is held before the server has answered")
        let del = bridge.enqueueCancel(session: "S", client: g.client)
        #expect(!bridge.isRegistered("S"))
        #expect(g.calls.isEmpty, "the DELETE waits for the PUT: it is never sent past it")
        await g.gate.open()
        _ = await put.value
        await del.value
        #expect(g.calls == ["PUT S", "DELETE S"], "the PUT lands first, then is undone")
        #expect(g.server.notifications["S"] == nil)
        #expect(bridge.log == ["PUT S", "DELETE S"])
    }

    @Test func aPutQueuedBehindANewerCancelIsNeverSent() async {
        let (bridge, g) = rig()
        let first = bridge.enqueueRegister(session: "S", optIn, source: .background, client: g.client, clock: g.clock)
        await g.puts.next()
        let second = bridge.enqueueRegister(session: "S", other, source: .background, client: g.client, clock: g.clock)
        let del = bridge.enqueueCancel(session: "S", client: g.client)
        await g.gate.open()
        let ok1 = await first.value
        let ok2 = await second.value
        await del.value
        #expect(ok1 && !ok2, "the overtaken PUT reports that nothing is registered")
        #expect(g.calls == ["PUT S", "DELETE S"], "one PUT went out; the queued one was dropped: \(g.calls)")
        #expect(g.server.notifications["S"] == nil)
    }

    @Test func theNewestRegisterWins() async {
        let (bridge, g) = rig()
        let first = bridge.enqueueRegister(session: "S", optIn, source: .background, client: g.client, clock: g.clock)
        await g.puts.next()
        let second = bridge.enqueueRegister(session: "S", other, source: .detached, client: g.client, clock: g.clock)
        let del = bridge.enqueueCancel(session: "S", client: g.client)
        let third = bridge.enqueueRegister(session: "S", other, source: .detached, client: g.client, clock: g.clock)
        await g.gate.open()
        _ = await (first.value, second.value, third.value)
        await del.value
        #expect(g.calls == ["PUT S", "PUT S"], "the stale PUT (in flight) and the newest; the middle ones are dropped")
        #expect(Set(g.server.notifications["S"]?.on ?? []) == [.rendered, .failed], "the last intent's opt-in is what the server holds")
        #expect(bridge.registered["S"] == .detached)
    }

    @Test func aCancelRightAfterARegisterStillUndoesIt() async {
        let (bridge, g) = rig()
        let put = bridge.enqueueRegister(session: "S", optIn, source: .background, client: g.client, clock: g.clock)
        let del = bridge.enqueueCancel(session: "S", client: g.client)   // same turn: the PUT task has not even started
        await g.gate.open()
        _ = await put.value
        await del.value
        #expect(g.server.notifications["S"] == nil)
        #expect(g.calls.isEmpty, "the PUT was overtaken before it left, so nothing was sent and nothing needs undoing")
    }

    @Test func sessionsDoNotWaitOnEachOther() async {
        let (bridge, g) = rig()
        let a = bridge.enqueueRegister(session: "A", optIn, source: .background, client: g.client, clock: g.clock)
        await g.puts.next()                                   // A is parked
        // B has nothing registered, so its cancel is a no-op that returns at once, not behind A
        await bridge.enqueueCancel(session: "B", client: g.client).value
        await g.gate.open()
        _ = await a.value
        await bridge.settled()
        #expect(g.calls == ["PUT A"] && g.server.notifications["A"] != nil)
    }

    // MARK: A PUT that got no answer may still have landed

    /// The fake server records the PUT, then the call fails the way a dropped connection does.
    private func landedThenFailed(_ h: Harness, error: any Error) -> (client: ScriptedClient, server: PreviewServer) {
        let base = h.ctx.client
        var stub = ScriptedClient(base: base)
        stub.setNotifyHook = { id, optIn in
            try await base.setNotify(session: id, optIn)
            throw error
        }
        return (stub, (base as! PreviewClient).server)
    }

    @Test func aPutThatFailsInTransitButLandedIsStillTakenBack() async {
        let h = Harness(.shortClip)
        let bridge = NotifyBridge()
        let (client, server) = landedThenFailed(h, error: CobaltError.network(.timedOut))
        let ok = await bridge.register(session: "S", optIn, source: .background, client: client, clock: h.clock)
        #expect(!ok, "the caller still hears that it was not confirmed")
        #expect(server.notifications["S"] != nil, "the server did store it")
        #expect(!bridge.isRegistered("S") && bridge.mightHold("S"), "not told, but not known clean either")
        await bridge.cancel(session: "S", client: h.ctx.client)
        #expect(server.notifications["S"] == nil)
        #expect(server.notifyCalls == ["PUT S", "DELETE S"])
    }

    @Test func aPutThatTimesOutOnTheClockButLandedIsStillTakenBack() async {
        let h = Harness(.shortClip)
        let base = h.ctx.client
        let applied = Arrivals()
        var stub = ScriptedClient(base: base)
        stub.setNotifyHook = { id, optIn in
            try await base.setNotify(session: id, optIn)        // the server has it
            await applied.fire()
            try await Task.sleep(for: .seconds(3600))           // the answer never comes; the race's timeout cancels this
        }
        let server = (base as! PreviewClient).server
        let bridge = NotifyBridge()
        let put = bridge.enqueueRegister(session: "S", optIn, source: .background, client: stub, clock: h.clock, timeout: 8)
        await applied.next()
        await h.settle()                                        // the race's timer is parked on the virtual clock
        h.clock.advance()                                       // 8 virtual seconds pass
        #expect(await put.value == false)
        #expect(server.notifications["S"] != nil && bridge.mightHold("S") && !bridge.isRegistered("S"))
        await bridge.cancel(session: "S", client: base)
        #expect(server.notifications["S"] == nil && server.notifyCalls == ["PUT S", "DELETE S"])
    }

    @Test func aServerErrorIsUncertainAndALaterRegisterTriesAgain() async {
        let h = Harness(.shortClip)
        let bridge = NotifyBridge()
        let server = (h.ctx.client as! PreviewClient).server
        let ok = await bridge.register(
            session: "S", optIn, source: .background, client: RefusingNotifyClient(base: h.ctx.client), clock: h.clock)
        #expect(!ok && bridge.mightHold("S") && !bridge.isRegistered("S"), "a 500 says nothing about whether it was stored")
        // the retry (the expiry path asks again because `isRegistered` is false) goes through and is a normal opt-in
        #expect(await bridge.register(session: "S", optIn, source: .background, client: h.ctx.client, clock: h.clock))
        #expect(bridge.isRegistered("S") && server.notifications["S"] != nil)
    }

    @Test func aDefiniteRejectionLeavesNothingToTakeBack() async {
        for error in [CobaltError.api(code: "error.studio.not_found", httpStatus: 404),
                      CobaltError.api(code: "error.notify.invalid", httpStatus: 400), CobaltError.noAPIKey] {
            let h = Harness(.shortClip)
            let bridge = NotifyBridge()
            var stub = ScriptedClient(base: h.ctx.client)
            stub.setNotifyHook = { _, _ in throw error }
            let ok = await bridge.register(session: "S", optIn, source: .background, client: stub, clock: h.clock)
            #expect(!ok && !bridge.mightHold("S"), "\(error)")
            await bridge.cancel(session: "S", client: h.ctx.client)
            #expect((h.ctx.client as! PreviewClient).server.notifyCalls.isEmpty, "a rejected PUT is not followed by a DELETE: \(error)")
        }
    }
}

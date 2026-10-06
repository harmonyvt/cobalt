import Foundation
import Testing
@testable import CobaltKit

/// The device's line (CONTRACT-PARALLEL.md 3.1, "without features.line"): first come first served, the focused webp
/// ahead of saves that have not started, never pre-empting the one that holds the server.
@MainActor
struct LocalLineTests {
    private func rig() -> (LocalLine, VirtualClock, PositionLog) {
        let clock = VirtualClock()
        let line = LocalLine(clock: clock)
        let log = PositionLog()
        line.onChange = { job, position in log.last[job] = position }
        return (line, clock, log)
    }

    @MainActor final class PositionLog { var last: [UUID: LinePosition?] = [:] }

    /// Starts `enter` as a task; `granted` fills in grant order.
    @MainActor final class Grants {
        var order: [String] = []
        var errors: [String] = []
    }

    private func enter(_ line: LocalLine, _ name: String, _ id: UUID, _ kind: LineKind = .save, _ priority: LinePriority = .batch, _ grants: Grants) -> Task<Void, Never> {
        Task { @MainActor in
            do { try await line.enter(id, kind: kind, priority: priority); grants.order.append(name) }
            catch { grants.errors.append(name) }
        }
    }

    @Test func firstInFirstOut() async {
        let (line, _, _) = rig()
        let (a, b, c) = (UUID(), UUID(), UUID())
        let g = Grants()
        _ = enter(line, "a", a, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "b", b, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "c", c, .save, .batch, g)
        await yieldMain()
        #expect(g.order == ["a"])
        line.release(a)
        await yieldMain()
        #expect(g.order == ["a", "b"])
        line.release(b)
        await yieldMain()
        #expect(g.order == ["a", "b", "c"])
        line.release(c)
        #expect(line.isFree)
    }

    @Test func aFocusedWebpGoesAheadOfWaitingSavesButNeverPreEmpts() async {
        let (line, _, _) = rig()
        let (holder, save1, save2, webp) = (UUID(), UUID(), UUID(), UUID())
        let g = Grants()
        _ = enter(line, "holder", holder, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "save1", save1, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "save2", save2, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "webp", webp, .render, .focused, g)
        await yieldMain()
        #expect(g.order == ["holder"], "nothing that runs is ever interrupted")
        #expect(line.waiting == [webp, save1, save2])
        line.release(holder)
        await yieldMain()
        #expect(g.order == ["holder", "webp"])
        line.release(webp)
        await yieldMain()
        #expect(g.order == ["holder", "webp", "save1"])
    }

    @Test func twoFocusedWebpsKeepTheirOrder() async {
        let (line, _, _) = rig()
        let (holder, w1, w2) = (UUID(), UUID(), UUID())
        let g = Grants()
        _ = enter(line, "holder", holder, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "w1", w1, .render, .focused, g)
        await yieldMain()
        _ = enter(line, "w2", w2, .render, .focused, g)
        await yieldMain()
        line.release(holder)
        await yieldMain()
        line.release(w1)
        await yieldMain()
        #expect(g.order == ["holder", "w1", "w2"])
    }

    @Test func noteOnServerBlocksTheNextEnter() async {
        let (line, _, _) = rig()
        let (adopted, next) = (UUID(), UUID())
        let g = Grants()
        line.noteOnServer(adopted)                      // an upload's adopt (or a resumed run) holds the server
        _ = enter(line, "next", next, .save, .batch, g)
        await yieldMain()
        #expect(g.order.isEmpty)
        line.release(adopted)
        await yieldMain()
        #expect(g.order == ["next"])
    }

    @Test func cancellationWhileWaitingRemovesTheJobAndWakesNobodyWrongly() async {
        let (line, _, _) = rig()
        let (holder, waiting, third) = (UUID(), UUID(), UUID())
        let g = Grants()
        _ = enter(line, "holder", holder, .save, .batch, g)
        await yieldMain()
        let task = enter(line, "waiting", waiting, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "third", third, .save, .batch, g)
        await yieldMain()
        task.cancel()
        await yieldMain()
        #expect(g.errors == ["waiting"])
        #expect(line.waiting == [third])
        #expect(g.order == ["holder"], "cancelling a waiter grants nothing")
        line.release(holder)
        await yieldMain()
        #expect(g.order == ["holder", "third"])
    }

    @Test func aCancelledHolderStillReleasesTheSlot() async {
        let (line, _, _) = rig()
        let (holder, next) = (UUID(), UUID())
        let g = Grants()
        let task = enter(line, "holder", holder, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "next", next, .save, .batch, g)
        await yieldMain()
        task.cancel()                                   // the holder's run is cancelled after it was granted
        line.release(holder)                            // its `defer` still releases
        await yieldMain()
        #expect(g.order == ["holder", "next"])
        // a release that was never entered changes nothing
        line.release(UUID())
        #expect(line.holders == [next])
    }

    @Test func releasingAWaiterThatNeverGotItsTurnEndsItsWait() async {
        let (line, _, _) = rig()
        let (holder, waiter) = (UUID(), UUID())
        let g = Grants()
        _ = enter(line, "holder", holder, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "waiter", waiter, .save, .batch, g)
        await yieldMain()
        line.release(waiter)
        await yieldMain()
        #expect(g.errors == ["waiter"])
        #expect(line.holders == [holder])
    }

    @Test func positionsCountTheHolderAsFirst() async {
        let (line, _, log) = rig()
        let (a, b, c) = (UUID(), UUID(), UUID())
        let g = Grants()
        _ = enter(line, "a", a, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "b", b, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "c", c, .save, .batch, g)
        await yieldMain()
        #expect(line.position(of: a) == .inLine(1, behind: nil))
        #expect(line.position(of: b) == .inLine(2, behind: nil))
        #expect(line.position(of: c) == .inLine(3, behind: nil))
        #expect(line.position(of: UUID()) == nil)
        // the holder is running (reads nothing), the waiters read their place
        #expect(log.last[a] == .some(nil))
        #expect(log.last[b] == .some(.inLine(2, behind: nil)))
        line.release(a)
        await yieldMain()
        #expect(line.position(of: b) == .inLine(1, behind: nil) && line.position(of: c) == .inLine(2, behind: nil))
        #expect(log.last[c] == .some(.inLine(2, behind: nil)))
    }

    @Test func aForeignBusyReadsAsBusyElsewhere() async {
        let (line, clock, log) = rig()
        let a = UUID()
        let g = Grants()
        _ = enter(line, "a", a, .save, .batch, g)
        await yieldMain()
        line.noteBusyElsewhere(label: "a share from your iphone")
        let since = clock.now()
        #expect(line.position(of: a) == .serverBusy(since: since, label: "a share from your iphone"))
        #expect(log.last[a] == .some(.serverBusy(since: since, label: "a share from your iphone")))
        line.clearBusyElsewhere()
        #expect(line.position(of: a) == .inLine(1, behind: nil))
    }

    @Test func resetFailsEveryWaiterAndFreesTheLine() async {
        let (line, _, _) = rig()
        let (a, b) = (UUID(), UUID())
        let g = Grants()
        _ = enter(line, "a", a, .save, .batch, g)
        await yieldMain()
        _ = enter(line, "b", b, .save, .batch, g)
        await yieldMain()
        line.reset()
        await yieldMain()
        #expect(g.errors == ["b"] && line.isFree)
    }
}

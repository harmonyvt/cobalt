import Foundation
import Testing
@testable import CobaltKit

@Suite("engine clock")
struct EngineClockTests {
    private let second: UInt64 = 1_000_000_000

    @Test func aWindowTalliesEachName() throws {
        var t = EngineTallies(startedAt: 0)
        t.add("store.reconcile", ms: 4, main: false)
        t.add("store.reconcile", ms: 20, main: false)
        t.add("store.reconcile", ms: 150.04, main: true)
        t.add("feed.decode", ms: 1.25, main: false)
        let drained1 = t.drain(now: 60 * second)
        let values = try #require(drained1)
        #expect(values["store.reconcile_n"] == .int(3))
        #expect(values["store.reconcile_ms_total"] == .double(174))
        #expect(values["store.reconcile_ms_max"] == .double(150))
        #expect(values["store.reconcile_slow"] == .int(2))
        #expect(values["store.reconcile_slow100"] == .int(1))
        #expect(values["store.reconcile_main"] == .bool(true))
        #expect(values["feed.decode_n"] == .int(1))
        #expect(values["feed.decode_ms_total"] == .double(1.3))
        #expect(values["feed.decode_slow"] == .int(0))
        #expect(values["feed.decode_main"] == .bool(false))
        #expect(values["window_s"] == .int(60))
        #expect(values["ops"] == .int(2))
    }

    @Test func drainingStartsAFreshWindow() throws {
        var t = EngineTallies(startedAt: 0)
        t.add("a.op", ms: 1, main: false)
        let drained2 = t.drain(now: 10 * second)
        _ = try #require(drained2)
        #expect(t.startedAt == 10 * second)
        #expect(t.byAddress.isEmpty)
        // an idle window sends nothing
        let drainedNil = t.drain(now: 70 * second)
        #expect(drainedNil == nil)
        t.add("a.op", ms: 2, main: false)
        let drained3 = t.drain(now: 100 * second)
        let values = try #require(drained3)
        #expect(values["a.op_n"] == .int(1))
        #expect(values["window_s"] == .int(30))
    }

    // 8.17 (120) sent a window at once with window_s 18446744074: a clock read older than the window's start wrapped.
    @Test func aClockReadOlderThanTheWindowIsNotDue() throws {
        var t = EngineTallies(startedAt: 100 * second)
        #expect(!t.isDue(now: 50 * second, after: 60 * second))
        #expect(!t.isDue(now: 159 * second, after: 60 * second))
        #expect(t.isDue(now: 160 * second, after: 60 * second))
        t.add("a.op", ms: 1, main: false)
        let drained = t.drain(now: 50 * second)
        let values = try #require(drained)
        #expect(values["window_s"] == .int(0))
        #expect(t.startedAt == 100 * second)                            // the window never moves back
    }

    @Test func namesPastTheCapFoldIntoOther() throws {
        var t = EngineTallies(startedAt: 0)
        // distinct literals are distinct addresses; the cap counts addresses
        let names: [StaticString] = [
            "n00", "n01", "n02", "n03", "n04", "n05", "n06", "n07", "n08", "n09", "n10", "n11", "n12", "n13", "n14", "n15",
            "n16", "n17", "n18", "n19", "n20", "n21", "n22", "n23", "n24", "n25", "n26", "n27", "n28", "n29", "n30", "n31",
            "n32", "n33", "n34", "n35", "n36", "n37", "n38", "n39", "n40", "n41", "n42", "n43", "n44", "n45", "n46", "n47",
            "n48", "n49", "n50", "n51", "n52", "n53", "n54", "n55", "n56", "n57", "n58", "n59", "n60", "n61", "n62", "n63",
            "n64", "n65",
        ]
        for name in names { t.add(name, ms: 1, main: false) }
        t.add(names[0], ms: 1, main: false)
        #expect(t.byAddress.count == EngineTallies.maxNames + 1)
        let drained4 = t.drain(now: second)
        let values = try #require(drained4)
        #expect(values["other_n"] == .int(2))
        #expect(values["n00_n"] == .int(2))
        #expect(values["n65_n"] == nil)
    }

    // Synchronous on purpose: in an async context Swift prefers the async overload, so a sync call there needs `await`.
    @Test func measureReturnsAndRethrows() {
        struct Boom: Error {}
        #expect(EngineClock.measure("test.sync") { 41 + 1 } == 42)
        #expect(throws: Boom.self) { try EngineClock.measure("test.throws") { () throws -> Int in throw Boom() } }
    }

    @Test func measureAwaits() async {
        let value = await EngineClock.measure("test.async") { () async -> Int in
            await Task.yield()
            return 7
        }
        #expect(value == 7)
    }

    @Test func flushIsStoredSafely() {
        let before = EngineClock.flush
        defer { EngineClock.flush = before }
        EngineClock.flush = { _ in }
        #expect(EngineClock.flush != nil)
        EngineClock.flush = nil
        #expect(EngineClock.flush == nil)
    }
}

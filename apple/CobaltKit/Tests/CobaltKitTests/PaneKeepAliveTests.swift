import Foundation
import Testing
@testable import CobaltKit

// What pane pages keep across their rebuilds (fix pass item 6): an object lives exactly as long as the pane holds its item.
@MainActor
@Suite struct PaneKeepAliveTests {
    private final class Player: PaneKeptObject {
        var released = 0
        func paneReleased() { released += 1 }
    }

    private final class Other {}

    @Test func theSameObjectComesBackForTheSameItemAndName() {
        let store = PaneKeepAlive()
        var made = 0
        let a = store.object("player", for: .post("a")) { made += 1; return Player() }
        let b = store.object("player", for: .post("a")) { made += 1; return Player() }
        #expect(a === b && made == 1)
        let c = store.object("player", for: .post("b")) { Player() }
        let d = store.object("chat", for: .post("a")) { Player() }
        #expect(c !== a && d !== a && store.count == 3)
    }

    @Test func itIsDroppedWhenThePaneLetsGoOfItsItem() {
        let store = PaneKeepAlive()
        let a = store.object("player", for: .post("a")) { Player() }
        let s = store.object("player", for: .stream("ninja")) { Player() }
        store.retain(only: [.post("a"), .stream("ninja")])
        #expect(a.released == 0 && s.released == 0 && store.count == 2)
        store.retain(only: [.stream("ninja")])
        #expect(a.released == 1 && s.released == 0 && !store.contains("player", for: .post("a")))
        store.removeAll()
        #expect(s.released == 1 && store.count == 0)
    }

    @Test func aShapeChangeKeepsItAndAPeekKeepsWhatItCovers() {
        let store = PaneKeepAlive()
        var m = PaneMachine()
        m.open(.post("a"))
        let player = store.object("player", for: .post("a")) { Player() }
        m.span(); store.retain(only: m.heldItems)
        m.unspan(); store.retain(only: m.heldItems)
        m.open(.peek("p")); store.retain(only: m.heldItems)
        m.endPeek(); store.retain(only: m.heldItems)
        #expect(player.released == 0)
        #expect(store.object("player", for: .post("a")) { Player() } === player)
        m.close(); store.retain(only: m.heldItems)
        #expect(player.released == 1)
    }

    @Test func aBackgroundStreamKeepsItsObjects() {
        let store = PaneKeepAlive()
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.setRunning(true, for: .stream("ninja"))
        let player = store.object("player", for: .stream("ninja")) { Player() }
        m.open(.post("a")); store.retain(only: m.heldItems)
        m.close(); store.retain(only: m.heldItems)
        #expect(player.released == 0)
        m.tapBar(); store.retain(only: m.heldItems)
        #expect(player.released == 0 && store.count == 1)
    }

    @Test func anotherTypeUnderTheSameNameReplacesIt() {
        let store = PaneKeepAlive()
        let a = store.object("x", for: .post("a")) { Player() }
        _ = store.object("x", for: .post("a")) { Other() }
        #expect(a.released == 1 && store.count == 1)
    }
}

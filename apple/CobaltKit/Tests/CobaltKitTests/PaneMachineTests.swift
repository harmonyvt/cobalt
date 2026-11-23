import Foundation
import Testing
@testable import CobaltKit

// The screen pane's rules (apple/CONTRACT-PANE.md section 1), one per test.
@Suite struct PaneMachineTests {
    @Test func opensAtScreenFromHidden() {
        var m = PaneMachine()
        #expect(m.state == .hidden && m.item == nil)
        m.open(.post("a"))
        #expect(m.item == .post("a") && m.state == .screen && m.shelf == 0)
    }

    @Test func openReplacesAndKeepsScreenOrSpan() {
        var m = PaneMachine()
        m.open(.post("a"))
        m.open(.link("l"))
        #expect(m.item == .link("l") && m.state == .screen)
        m.span()
        m.open(.emote("e"))
        #expect(m.item == .emote("e") && m.state == .span)
    }

    @Test func openFromBarOpensAtScreen() {
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.close(running: true)
        #expect(m.state == .bar)
        m.open(.post("a"))
        #expect(m.item == .post("a") && m.state == .screen)
    }

    @Test func closeGoesToBarOnlyWhenRunning() {
        var running = PaneMachine()
        running.open(.save("job-1"))
        running.close(running: true)
        #expect(running.state == .bar && running.item == .save("job-1"))

        var idle = PaneMachine()
        idle.open(.save("job-1"))
        idle.close(running: false)
        #expect(idle.state == .hidden)
        // the item is kept while hidden: a drag held on the edge brings it back
        #expect(idle.item == .save("job-1"))
    }

    @Test func closeFromSpanHides() {
        var m = PaneMachine()
        m.open(.post("a"))
        m.span()
        m.close(running: false)
        #expect(m.state == .hidden)
    }

    @Test func spanOnlyFromScreenUnspanOnlyFromSpan() {
        var m = PaneMachine()
        m.span()
        #expect(m.state == .hidden)                     // nothing to span
        m.open(.post("a"))
        m.unspan()
        #expect(m.state == .screen)                     // not spanned: nothing to undo
        m.span()
        #expect(m.state == .span)
        m.span()
        #expect(m.state == .span)
        m.unspan()
        #expect(m.state == .screen)
        m.close(running: true)
        m.span()
        #expect(m.state == .bar)                        // the bar never spans directly
    }

    @Test func toggleSpan() {
        var m = PaneMachine()
        m.open(.post("a"))
        m.toggleSpan()
        #expect(m.state == .span)
        m.toggleSpan()
        #expect(m.state == .screen)
    }

    @Test func tapBarOpensAtScreen() {
        var m = PaneMachine()
        m.open(.job("j"))
        m.close(running: true)
        m.tapBar()
        #expect(m.state == .screen && m.item == .job("j"))
        m.tapBar()
        #expect(m.state == .screen)                     // only from the bar
    }

    @Test func stoppedRunningRemovesTheBarOnly() {
        var m = PaneMachine()
        m.open(.swarm("s"))
        m.stoppedRunning()
        #expect(m.state == .screen)                     // on screen it stays
        m.close(running: true)
        m.stoppedRunning()
        #expect(m.state == .hidden)
    }

    @Test func revealBringsBackTheLastItem() {
        var m = PaneMachine()
        m.reveal()
        #expect(m.state == .hidden)                     // nothing to bring back
        m.open(.collection("c"))
        m.close(running: false)
        m.reveal()
        #expect(m.state == .screen && m.item == .collection("c"))
    }

    @Test func shelfResetsForANewItemAndKeepsForTheSame() {
        var m = PaneMachine()
        m.open(.post("a"))
        m.setShelf(2)
        m.open(.post("a"))
        #expect(m.shelf == 2)
        m.open(.post("b"))
        #expect(m.shelf == 0)
    }

    @Test func shelfClamps() {
        var m = PaneMachine()
        m.open(.post("a"))
        m.setShelf(-3)
        #expect(m.shelf == 0)
        m.setShelf(9, count: 3)
        #expect(m.shelf == 2)
        m.setShelf(4, count: 0)
        #expect(m.shelf == 0)
    }

    @Test func peekIsTransient() {
        var m = PaneMachine()
        m.open(.link("l"))
        m.setShelf(1)
        m.span()
        m.open(.peek("p"))
        #expect(m.item == .peek("p") && m.state == .span && m.isPeeking)
        // the scene never saves the peek
        #expect(m.saved == PaneRoute(item: .link("l"), state: .span, shelf: 1))
        m.endPeek()
        #expect(m.route == PaneRoute(item: .link("l"), state: .span, shelf: 1) && !m.isPeeking)
    }

    @Test func peekFromHiddenClosesBackToHidden() {
        var m = PaneMachine()
        m.open(.peek("p"))
        #expect(m.state == .screen)
        m.close(running: false)                         // a close during a peek is the end of the peek
        #expect(m.state == .hidden && m.item == nil)
    }

    @Test func peekOverPeekRemembersTheFirstRoute() {
        var m = PaneMachine()
        m.open(.post("a"))
        m.open(.peek("p1"))
        m.open(.peek("p2"))
        m.endPeek()
        #expect(m.item == .post("a") && m.state == .screen)
    }

    @Test func openingARealItemDuringAPeekKeepsIt() {
        var m = PaneMachine()
        m.open(.post("a"))
        m.open(.peek("p"))
        m.open(.post("p"))
        #expect(!m.isPeeking && m.item == .post("p"))
        m.endPeek()
        #expect(m.item == .post("p"))
    }

    @Test func restoreDropsPeeksAndEmptyStates() {
        var m = PaneMachine()
        m.restore(PaneRoute(item: .peek("p"), state: .screen))
        #expect(m.route == .hidden)
        m.restore(PaneRoute(item: nil, state: .span))
        #expect(m.route == .hidden)
        m.restore(PaneRoute(item: .stream("x"), state: .bar, shelf: 1))
        #expect(m.route == PaneRoute(item: .stream("x"), state: .bar, shelf: 1))
    }

    @Test func keepsRunningKinds() {
        let running: [PaneItem] = [.stream("s"), .save("j"), .swarm("w"), .job("q"), .reward("r"), .poolVideo("v")]
        let never: [PaneItem] = [.post("p"), .peek("p"), .selection, .link("l"), .collection("c"), .emote("e"),
                                 .emoteAddToSet("e"), .booruPost(1), .booruFilters, .name("n")]
        #expect(running.allSatisfy { $0.keepsRunning })
        #expect(!never.contains { $0.keepsRunning })
    }
}

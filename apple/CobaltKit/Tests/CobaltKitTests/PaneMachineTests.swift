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
    // MARK: gone and finished items are never running (fix pass item 1)

    @Test func aBarItemThatStopsDropsToHidden() {
        var m = PaneMachine()
        m.open(.job("j"))
        m.setRunning(true, for: .job("j"))
        m.close()
        #expect(m.state == .bar && m.barItem == .job("j"))
        m.setRunning(false, for: .job("j"))
        #expect(m.state == .hidden && m.barItem == nil && !m.isRunning)
    }

    @Test func aGoneItemLeavesThePaneWhereverItIs() {
        // in the bar
        var bar = PaneMachine()
        bar.open(.job("j"))
        bar.close(running: true)
        bar.itemGone(.job("j"))
        #expect(bar.route == .hidden && bar.barItem == nil && !bar.isRunning)
        bar.reveal()
        #expect(bar.state == .hidden, "a gone item cannot be brought back")

        // on screen: the pane hides, and its close can never go back to a bar
        var shown = PaneMachine()
        shown.open(.save("s"))
        shown.setRunning(true, for: .save("s"))
        shown.itemGone(.save("s"))
        #expect(shown.route == .hidden && !shown.isRunning)
        shown.close()
        #expect(shown.state == .hidden && shown.barItem == nil)

        // a report for an item the pane does not hold changes nothing
        var other = PaneMachine()
        other.open(.post("a"))
        other.itemGone(.job("j"))
        #expect(other.route == PaneRoute(item: .post("a"), state: .screen))
    }

    @Test func aGoneBackgroundItemLetsGoOfTheBar() {
        var m = PaneMachine()
        m.open(.swarm("w"))
        m.setRunning(true, for: .swarm("w"))
        m.open(.post("a"))
        #expect(m.background == .swarm("w"))
        m.itemGone(.swarm("w"))
        #expect(m.background == nil && m.barItem == nil && m.item == .post("a") && m.state == .screen)
    }

    @Test func aRestoredBarMustBeConfirmed() {
        var confirmed = PaneMachine()
        confirmed.restore(PaneRoute(item: .job("j"), state: .bar))
        #expect(confirmed.isRunning && confirmed.unconfirmed == .job("j"))
        confirmed.setRunning(true, for: .job("j"))
        #expect(confirmed.unconfirmed == nil)
        confirmed.expireUnconfirmed()
        #expect(confirmed.state == .bar, "a page that confirmed keeps the bar")

        var silent = PaneMachine()
        silent.restore(PaneRoute(item: .job("j"), state: .bar))
        silent.expireUnconfirmed()
        #expect(silent.state == .hidden && !silent.isRunning && silent.item == .job("j"))

        var missing = PaneMachine()
        missing.restore(PaneRoute(item: .job("j"), state: .bar))
        missing.itemGone(.job("j"))                     // the page knows the job is not there
        #expect(missing.route == .hidden)

        var screen = PaneMachine()
        screen.restore(PaneRoute(item: .post("p"), state: .screen))
        #expect(!screen.isRunning && screen.unconfirmed == nil)
    }

    // MARK: a running item survives being replaced (fix pass item 5)

    @Test func openingOverARunningItemMovesItToTheBackground() {
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.setRunning(true, for: .stream("ninja"))
        m.open(.post("a"))
        #expect(m.item == .post("a") && m.state == .screen && !m.isRunning)
        #expect(m.background == .stream("ninja") && m.barItem == .stream("ninja"))
        #expect(m.holds(.stream("ninja")) && m.holds(.post("a")))
        // its page keeps reporting from the bar
        m.setRunning(true, for: .stream("ninja"))
        #expect(m.background == .stream("ninja"))
        // the post closes: the stream's bar stays
        m.close()
        #expect(m.state == .hidden && m.barItem == .stream("ninja"))
    }

    @Test func openingOverAnIdleItemReplacesIt() {
        var m = PaneMachine()
        m.open(.stream("ninja"))                        // its page has not said it is running
        m.open(.post("a"))
        #expect(m.background == nil && m.barItem == nil && !m.holds(.stream("ninja")))
    }

    @Test func openingFromTheBarMovesTheBarItemToTheBackground() {
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.close(running: true)
        m.open(.link("l"))
        #expect(m.item == .link("l") && m.state == .screen && m.barItem == .stream("ninja"))
    }

    @Test func tappingTheBackgroundBarBringsItBack() {
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.setRunning(true, for: .stream("ninja"))
        m.open(.post("a"))
        m.span()
        m.tapBar()
        // what was showing is replaced; the stream is back at screen and still running
        #expect(m.item == .stream("ninja") && m.state == .screen && m.isRunning)
        #expect(m.background == nil && m.barItem == nil && !m.holds(.post("a")))
    }

    @Test func tappingTheBarSwapsTwoRunningItems() {
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.setRunning(true, for: .stream("ninja"))
        m.open(.job("j"))
        m.setRunning(true, for: .job("j"))
        m.tapBar()
        #expect(m.item == .stream("ninja") && m.background == .job("j"))
    }

    @Test func openingTheBackgroundItemBringsItBack() {
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.setRunning(true, for: .stream("ninja"))
        m.open(.post("a"))
        m.open(.stream("ninja"))
        #expect(m.item == .stream("ninja") && m.isRunning && m.background == nil)
    }

    @Test func aStoppedBackgroundItemLosesItsBar() {
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.setRunning(true, for: .stream("ninja"))
        m.open(.post("a"))
        m.setRunning(false, for: .stream("ninja"))
        #expect(m.background == nil && m.barItem == nil && m.item == .post("a"))
    }

    @Test func oneBarAStreamOutranksTheRest() {
        // a running job replaced while a stream is in the background: the stream keeps the bar
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.setRunning(true, for: .stream("ninja"))
        m.open(.job("j"))
        m.setRunning(true, for: .job("j"))
        m.open(.post("a"))
        #expect(m.background == .stream("ninja"))
        // closing a running job over a background stream: the stream keeps the bar, the job's bar is let go of
        var c = PaneMachine()
        c.open(.stream("ninja"))
        c.setRunning(true, for: .stream("ninja"))
        c.open(.job("j"))
        c.setRunning(true, for: .job("j"))
        c.close()
        #expect(c.state == .hidden && c.barItem == .stream("ninja"))
        // a stream closing over a background job takes the bar from it
        var s = PaneMachine()
        s.open(.job("j"))
        s.setRunning(true, for: .job("j"))
        s.open(.stream("ninja"))
        s.setRunning(true, for: .stream("ninja"))
        #expect(s.background == .job("j"))
        s.close()
        #expect(s.state == .bar && s.item == .stream("ninja") && s.background == nil)
        // two of the same rank: the newer has it
        var n = PaneMachine()
        n.open(.job("j1"))
        n.setRunning(true, for: .job("j1"))
        n.open(.job("j2"))
        n.setRunning(true, for: .job("j2"))
        n.open(.post("a"))
        #expect(n.background == .job("j2"))
    }

    @Test func neverABarAndABackgroundAtOnce() {
        var m = PaneMachine()
        m.open(.save("s"))
        m.setRunning(true, for: .save("s"))
        m.open(.swarm("w"))
        m.setRunning(true, for: .swarm("w"))
        m.close()
        #expect(m.state == .bar && m.background == nil && m.barItem == .swarm("w"))
    }

    // MARK: a peek never lets go of a running item

    @Test func aPeekOverARunningStreamKeepsItInTheBar() {
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.setRunning(true, for: .stream("ninja"))
        m.open(.peek("p"))
        #expect(m.item == .peek("p") && m.barItem == .stream("ninja") && m.holds(.stream("ninja")))
        // the stream page keeps reporting from the bar during the peek
        m.setRunning(true, for: .stream("ninja"))
        m.endPeek()
        #expect(m.route == PaneRoute(item: .stream("ninja"), state: .screen) && m.isRunning && m.barItem == nil)
    }

    @Test func aPeekOverTheBarKeepsTheBar() {
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.close(running: true)
        m.open(.peek("p"))
        #expect(m.barItem == .stream("ninja"))
        m.close()                                       // the peek's close is the end of the peek
        #expect(m.state == .bar && m.item == .stream("ninja") && m.isRunning)
    }

    @Test func openingARealItemFromAPeekMovesTheRunningItemAside() {
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.setRunning(true, for: .stream("ninja"))
        m.open(.peek("p"))
        m.open(.post("p"))
        #expect(!m.isPeeking && m.item == .post("p") && m.background == .stream("ninja"))
    }

    @Test func aStreamStoppingUnderAPeekComesBackHiddenFromTheBar() {
        var m = PaneMachine()
        m.open(.stream("ninja"))
        m.close(running: true)
        m.open(.peek("p"))
        m.setRunning(false, for: .stream("ninja"))
        #expect(m.barItem == nil)
        m.endPeek()
        #expect(m.state == .hidden && !m.isRunning)
    }

    // MARK: auto-opens never replace a running item or the owner's

    @Test func autoOpenWaitsForTheOwner() {
        var running = PaneMachine()
        running.open(.stream("ninja"))
        running.setRunning(true, for: .stream("ninja"))
        let opened1 = running.open(.save("s"), userInitiated: false)

        #expect(!opened1)
        #expect(running.item == .stream("ninja") && running.background == nil)
        running.close()                                 // in the bar, still running: still refused
        let opened2 = running.open(.selection, userInitiated: false)

        #expect(!opened2)
        #expect(running.state == .bar)

        var owners = PaneMachine()
        owners.open(.post("a"))
        let opened3 = owners.open(.selection, userInitiated: false)

        #expect(!opened3)
        #expect(owners.item == .post("a"))

        var peeking = PaneMachine()
        peeking.open(.peek("p"))
        let opened4 = peeking.open(.save("s"), userInitiated: false)

        #expect(!opened4)
    }

    @Test func autoOpenShowsWhenNothingIsInTheWay() {
        var empty = PaneMachine()
        let opened5 = empty.open(.save("s"), userInitiated: false)

        #expect(opened5)
        #expect(empty.item == .save("s") && empty.state == .screen && !empty.userOpened)
        // an auto-opened page may be replaced by another auto-open
        let opened6 = empty.open(.selection, userInitiated: false)

        #expect(opened6)
        #expect(empty.item == .selection)

        var closed = PaneMachine()
        closed.open(.post("a"))
        closed.close()
        let opened7 = closed.open(.save("s"), userInitiated: false)

        #expect(opened7)

        // a background stream stays where it is
        var bg = PaneMachine()
        bg.open(.stream("ninja"))
        bg.setRunning(true, for: .stream("ninja"))
        bg.open(.post("a"))
        bg.close()
        let opened8 = bg.open(.save("s"), userInitiated: false)

        #expect(opened8)
        #expect(bg.background == .stream("ninja") && bg.item == .save("s"))
    }

    // MARK: what the pane holds (keep-alive)

    @Test func heldItems() {
        var m = PaneMachine()
        #expect(m.heldItems.isEmpty)
        m.open(.post("a"))
        #expect(m.heldItems == [.post("a")])
        m.span()
        #expect(m.heldItems == [.post("a")], "a shape change keeps the item")
        m.open(.peek("p"))
        #expect(m.heldItems == [.post("a"), .peek("p")], "a peek keeps what it opened over")
        m.endPeek()
        m.close()
        #expect(m.heldItems.isEmpty, "a hidden item is let go of")
    }
}

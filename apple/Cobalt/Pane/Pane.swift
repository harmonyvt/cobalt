import CobaltKit
import Observation
import SwiftUI

// The screen pane (apple/CONTRACT-PANE.md): one panel per window, on the leading side, beside whatever tab is open.
//
// `Pane` is the window's store: it wraps the pure `PaneMachine` (CobaltKit, every rule unit tested), knows the window's
// `PanePlacement`, and logs each state change. One per scene, made by `AppShell` and handed down with
// `.environment(pane)`; `PaneHost` draws it and saves its route with `@SceneStorage("pane")`.
//
// What area lanes use (read this, not the views):
//
//   @Environment(Pane.self) private var pane
//
//   pane.open(.post(id))            show an item; replaces the current one, keeps screen / span, from hidden or bar opens
//                                   at screen. The page itself is picked by `PaneDestination` (Destinations/).
//   pane.peek(id) / pane.endPeek()  the library's hold-to-peek: opens `.peek(id)` over whatever is there; endPeek (the
//                                   finger lifted) puts that back exactly.
//   pane.close()                    hide (the header's xmark, swipe down, Escape do this): a running item goes to the bar.
//   pane.span() / unspan() / toggleSpan()
//   pane.setRunning(_:for:)         RUNNING ITEMS: a page whose item `keepsRunning` (stream, save, swarm, job, studio
//                                   reward / pool video, and a chat `.post` while its job runs) must report, in every
//                                   shape (bar included), whether it is still at work:
//                                       .onChange(of: isLive, initial: true) { pane.setRunning(isLive, for: item) }
//                                   A report for any item but the current one is ignored (a page on its way out cannot
//                                   change the next one). Closing while running leaves the bar; a bar whose item stops
//                                   running goes away. Opening another item resets it to false. A route restored at
//                                   launch in the bar counts as running until its page says otherwise.
//   pane.provide(obj) / pane.provided(T.self)
//                                   state that lives in a tab but the pane page needs (the library's controller for
//                                   `.selection`): the tab provides it (held weakly), the page reads it.
//
// The pane draws its own header (span, context label, more, xmark): a page never draws a close.
@MainActor
@Observable
final class Pane {
    private(set) var machine = PaneMachine()
    /// Where the pane goes in this window (set by `PaneHost` from the window's size).
    private(set) var placement: PanePlacement = .compact
    /// The current item is still at work (its page said so; see the header).
    private(set) var isRunning = false
    /// The page's title (set by `PanePage`), for VoiceOver's "pane, <title>"; the context label until a page sets one.
    private(set) var title: String?
    /// How many shelf cards the current page has (set by `PanePage`), so ⌘] stops at the last.
    private(set) var shelfCount = 0
    /// The scene's saved route has been read (once per scene, however often the host is rebuilt).
    @ObservationIgnored private(set) var restored = false
    @ObservationIgnored private var provided: [ObjectIdentifier: WeakBox] = [:]
    /// Bumped by `provide` so pages reading `provided(_:)` update.
    private var providedVersion = 0

    init(route: PaneRoute = .hidden) {
        machine.restore(route)
        isRunning = machine.state == .bar
    }

    // MARK: reading

    var route: PaneRoute { machine.route }
    var item: PaneItem? { machine.item }
    var state: PaneState { machine.state }
    var shelf: Int { machine.shelf }
    var isPeeking: Bool { machine.isPeeking }
    /// On screen or in a sheet (`screen` / `span` with an item).
    var isVisible: Bool { machine.route.isVisible }

    /// The room the tab keeps beside the pane in a window of `size`, or nil when the pane takes none (hidden, bar, or a
    /// sheet). Spanned, the tab keeps the room it had (it is covered, not reflowed). `AppShell` lays its tabs out for it.
    func tabSize(in size: CGSize) -> CGSize? {
        guard machine.route.isVisible else { return nil }
        return placement.tabExtent(in: size)
    }

    /// `tabSize`'s width for a window `width` wide.
    func tabWidth(of width: CGFloat) -> CGFloat? {
        tabSize(in: CGSize(width: width, height: 1))?.width
    }

    // MARK: actions

    func open(_ item: PaneItem) {
        let previous = machine.item
        change { $0.open(item) }
        if previous != item {
            isRunning = false
            title = nil
            shelfCount = 0
        }
    }

    func peek(_ id: String) { open(.peek(id)) }

    func endPeek() {
        guard machine.isPeeking else { return }
        change { $0.endPeek() }
        // what comes back was not running as far as we know until its page says so; a bar it was in stays
        isRunning = machine.state == .bar
        title = nil
    }

    /// Hides the pane: the bar when the item is still running, else hidden. Never stops anything.
    func close() {
        change { $0.close(running: isRunning) }
    }

    func span() { change { $0.span() } }
    func unspan() { change { $0.unspan() } }
    func toggleSpan() { change { $0.toggleSpan() } }
    func tapBar() { change { $0.tapBar() } }
    /// A drag held on the leading edge of a hidden pane: its last item comes back at `screen`.
    func reveal() { change { $0.reveal() } }

    /// A page reports whether `item` is still at work. Ignored unless `item` is the current one.
    func setRunning(_ running: Bool, for item: PaneItem) {
        guard item == machine.item, running != isRunning else { return }
        isRunning = running
        if !running { change { $0.stoppedRunning() } }
    }

    // MARK: shelf

    func setShelf(_ index: Int) { change { $0.setShelf(index, count: shelfCount > 0 ? shelfCount : nil) } }
    func shelfNext() { setShelf(machine.shelf + 1) }
    func shelfBack() { setShelf(machine.shelf - 1) }

    /// `PanePage` reports its card count (and the shelf is clamped to it).
    func reportShelf(count: Int) {
        guard count != shelfCount else { return }
        shelfCount = count
        if count > 0, machine.shelf >= count { change { $0.setShelf(count - 1) } }
    }

    /// `PanePage` reports its title.
    func reportTitle(_ title: String) {
        if self.title != title { self.title = title }
    }

    // MARK: placement and restoration (PaneHost)

    func place(_ placement: PanePlacement) {
        guard placement != self.placement else { return }
        let was = self.placement
        self.placement = placement
        if machine.item != nil, machine.state != .hidden {
            Breadcrumbs.add("pane.placement", ["from": .string(was.name), "to": .string(placement.name)])
        }
    }

    /// Restores the scene's saved route, once per scene.
    func restoreOnce(_ data: Data?) {
        guard !restored else { return }
        restored = true
        guard let route = PaneRoute.decoded(data), route != machine.route else { return }
        change { $0.restore(route) }
        isRunning = machine.state == .bar
    }

    // MARK: things a tab hands the pane

    /// Makes `object` available to pane pages (held weakly; the tab keeps it alive).
    func provide<T: AnyObject>(_ object: T) {
        provided[ObjectIdentifier(T.self)] = WeakBox(object)
        providedVersion += 1
    }

    /// Withdraws what `provide` gave for `T`.
    func withdraw<T: AnyObject>(_ type: T.Type) {
        provided[ObjectIdentifier(T.self)] = nil
        providedVersion += 1
    }

    /// What a tab provided for `T`, while it is alive.
    func provided<T: AnyObject>(_ type: T.Type) -> T? {
        _ = providedVersion
        return provided[ObjectIdentifier(T.self)]?.object as? T
    }

    // MARK: logging

    private func change(_ body: (inout PaneMachine) -> Void) {
        let before = machine
        body(&machine)
        guard machine.state != before.state || machine.item != before.item else { return }
        let state = machine.state.rawValue
        let kind = machine.item?.kind ?? "none"
        Analytics.event("pane.state", values: [
            "state": .string(state), "kind": .string(kind), "placement": .string(placement.name),
            "from": .string(before.state.rawValue),
        ])
        if machine.state != before.state {
            Breadcrumbs.add("pane.\(state)", ["kind": .string(kind)])
        }
    }
}

private final class WeakBox {
    weak var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
}
